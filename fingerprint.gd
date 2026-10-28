class_name Fingerprint
extends RefCounted

## Boils a result XML down to the numbers the profiles and predictions use.
## Names are the raw names from the file; Profiles resolves aliases when it reads them.
##
## extract(path) returns {
##   "v": 1,
##   "track": {"TrackVenue", "TrackCourse", "TrackLength"},
##   "race":  {"minutes": int,
##             "classes": {cls: {"ref_s", "kmh", "top", "wear_km", "fuel_km", "tl", "con", "n"}},
##             "drivers": {name: {"cls", "car", "laps", "grid", "pos", "pace", "pace_rel", "cons",
##                                "top_rel", "wear_rel", "fuel_rel", "tl", "con", "pen"}}},
##   "quali": {"classes": {cls: {"best_s", "kmh", "top", "s1", "s2", "s3"}},
##             "drivers": {name: {"cls", "car", "best", "rel"}}}
## }
## "_rel" values are % versus the class median of that session (negative pace = quicker).
## tl = track-limit events per lap, con = contacts with other cars per lap,
## cons = lap-time spread in % of the median clean lap, wear_km / fuel_km are % per km.

const VERSION := 1
const CLEAN_LIMIT := 1.04     # laps slower than 104% of the driver's own best-5 median are not "clean"
const INCIDENT_GAP := 5.0     # contact reports closer than this (s) count as one
const MIN_RUN := 6            # laps in a row of falling tyre wear needed to estimate a wear rate
const MIN_LAPS := 5
# Only race and qualifying sessions are read: practice and warmup laps are too far from a
# representative pace (fuel loads, setup runs, out-laps) to be useful.
const SESSION_TAGS := ["Race", "Qualify"]


# training = true: the file is training data. Driver names are dropped (entries become "#1", "#2", ...),
# so only track and car-model data remain.
static func extract(path: String, training := false) -> Dictionary:
	var p := XMLParser.new()
	if p.open(path) != OK:
		return {}
	var inc_rx := RegEx.new()
	inc_rx.compile("^(.*)\\((\\d+)\\) reported contact \\([\\d.]+\\) with another vehicle (.*)$")
	var track := {}
	var sessions := {}
	var cur := {}
	var session := ""
	var depth := 0
	var session_depth := -1
	var driver := {}
	var driver_depth := -1
	var field := ""
	var header_field := ""
	var session_field := ""
	var in_lap := false
	var in_incident := false
	var incident_et := 0.0
	var last_inc := {}
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				if p.is_empty():
					continue
				var tag := p.get_node_name()
				depth += 1
				if session == "" and tag in SESSION_TAGS:
					session = tag
					session_depth = depth
					cur = {"drivers": [], "minutes": 0, "tl": {}, "con": {}, "pens": {}}
					sessions[tag] = cur
				elif session == "" and (tag == "TrackVenue" or tag == "TrackCourse" or tag == "TrackLength"):
					header_field = tag
				elif session != "" and driver_depth == -1 and tag == "Driver":
					driver = {"laps": []}
					driver_depth = depth
				elif driver_depth != -1 and depth == driver_depth + 1:
					if tag == "Lap":
						var tw := 0.0
						for k in ["twfl", "twfr", "twrl", "twrr"]:
							var w := _attr(p, k)
							tw += w if w > 0.0 else 1.0
						driver["laps"].append({
							"n": int(p.get_named_attribute_value_safe("num")),
							"t": -1.0,
							"top": _attr(p, "topspeed"),
							"fu": _attr(p, "fuelUsed"),
							"tw": tw / 4.0,
							"s1": _attr(p, "s1"), "s2": _attr(p, "s2"), "s3": _attr(p, "s3"),
						})
						in_lap = true
					else:
						field = tag
				elif session != "" and driver_depth == -1:
					if tag == "Minutes":
						session_field = tag
					elif tag == "Incident":
						in_incident = true
						incident_et = float(p.get_named_attribute_value_safe("et"))
					elif tag == "TrackLimits":
						var who := p.get_named_attribute_value_safe("Driver")
						var tl: Dictionary = cur["tl"]
						if not tl.has(who):
							tl[who] = {}
						tl[who][p.get_named_attribute_value_safe("et")] = true
					elif tag == "Penalty" and p.has_attribute("Driver"):
						var pens: Dictionary = cur["pens"]
						var pw := p.get_named_attribute_value_safe("Driver")
						pens[pw] = pens.get(pw, 0) + 1
			XMLParser.NODE_TEXT:
				var txt := p.get_node_data().strip_edges()
				if txt == "":
					continue
				if in_lap:
					var laps: Array = driver["laps"]
					laps[laps.size() - 1]["t"] = txt.to_float() if txt.is_valid_float() else -1.0
				elif field != "" and driver_depth != -1:
					driver[field] = txt
				elif header_field != "":
					track[header_field] = txt
				elif session_field == "Minutes":
					cur["minutes"] = int(txt)
				elif in_incident:
					var m := inc_rx.search(txt)
					if m != null:
						var who2 := m.get_string(1)
						var key := who2 + "|" + m.get_string(3)
						if incident_et - float(last_inc.get(key, -1000.0)) > INCIDENT_GAP:
							var con: Dictionary = cur["con"]
							con[who2] = con.get(who2, 0) + 1
						last_inc[key] = incident_et
			XMLParser.NODE_ELEMENT_END:
				if in_lap and depth == driver_depth + 1:
					in_lap = false
				if driver_depth != -1 and depth == driver_depth:
					cur["drivers"].append(driver)
					driver_depth = -1
				elif session != "" and depth == session_depth:
					session = ""
					session_depth = -1
					last_inc.clear()
				field = ""
				header_field = ""
				session_field = ""
				in_incident = false
				depth -= 1

	var length := float(track.get("TrackLength", "0"))
	if length <= 0.0:
		return {}
	var out := {
		"v": VERSION,
		"track": {
			"venue": track.get("TrackVenue", ""),
			"course": track.get("TrackCourse", ""),
			"length": length,
		},
	}
	var race_src: Dictionary = sessions.get("Race", {})
	var quali_src: Dictionary = sessions.get("Qualify", {})
	if not race_src.is_empty() and not race_src["drivers"].is_empty():
		var r := _race(race_src, length)
		if not r["drivers"].is_empty():
			out["race"] = r
	if not quali_src.is_empty() and not quali_src["drivers"].is_empty():
		var q := _quali(quali_src, length)
		if not q["drivers"].is_empty():
			out["quali"] = q
	if training:
		out["kind"] = "training"
		for k in ["race", "quali"]:
			if out.has(k):
				out[k]["drivers"] = _anonymous(out[k]["drivers"])
	return out


# Same rows without driver names.
static func _anonymous(rows: Dictionary) -> Dictionary:
	var out := {}
	var i := 1
	for driver_name in rows:
		out["#%d" % i] = rows[driver_name]
		i += 1
	return out


# ---------- Race ----------

static func _race(cur: Dictionary, length: float) -> Dictionary:
	var km := length / 1000.0
	var rows := {}       # raw name -> metrics
	var raw := {}        # raw name -> unrounded extras for the class stats
	for d in cur["drivers"]:
		var nm: String = d.get("Name", "")
		var cls: String = d.get("CarClass", "")
		if nm == "" or cls == "" or d.get("FinishStatus", "") == "DQ":
			continue
		var n := int(d.get("Laps", "0"))
		if n == 0:
			n = d["laps"].size()   # some files carry no Laps field
		if n < MIN_LAPS:
			continue
		var times := []
		var tops := []
		var fuels := []
		var wear_series := []
		for l in d["laps"]:
			if l["n"] > 1 and l["t"] > 0.0:
				times.append(l["t"])
			if l["top"] > 0.0:
				tops.append(l["top"])
			if l["fu"] > 0.0:
				fuels.append(l["fu"])
			wear_series.append(l["tw"])
		if times.size() < MIN_LAPS:
			continue
		var sorted_t := times.duplicate()
		sorted_t.sort()
		var ref := _median(sorted_t.slice(0, 5))
		var clean := []
		for t in times:
			if t <= CLEAN_LIMIT * ref:
				clean.append(t)
		if clean.size() < MIN_LAPS:
			continue
		var pace := _median(clean)
		var m := {
			"cls": cls, "car": d.get("CarType", ""), "laps": n,
			"grid": int(d.get("ClassGridPos", "0")), "pos": int(d.get("ClassPosition", "0")),
			"pace": pace, "cons": _std(clean) / pace * 100.0,
			"tl": cur["tl"].get(nm, {}).size() / float(n),
			"con": cur["con"].get(nm, 0) / float(n),
			"pen": cur["pens"].get(nm, 0),
		}
		var x := {}
		if not tops.is_empty():
			x["top"] = tops.max()
		var wr := _wear_rate(wear_series)
		if wr >= 0.0:
			x["wear"] = wr / km
		if fuels.size() > MIN_LAPS:
			x["fuel"] = _median(fuels) / km
		rows[nm] = m
		raw[nm] = x

	var by_class := {}
	for nm in rows:
		var c: String = rows[nm]["cls"]
		if not by_class.has(c):
			by_class[c] = []
		by_class[c].append(nm)

	var classes := {}
	for c in by_class:
		var names: Array = by_class[c]
		var paces := []
		var tops := []
		var wears := []
		var fuels := []
		var tls := 0.0
		var cons := 0.0
		for nm in names:
			paces.append(rows[nm]["pace"])
			tls += rows[nm]["tl"]
			cons += rows[nm]["con"]
			if raw[nm].has("top"):
				tops.append(raw[nm]["top"])
			if raw[nm].has("wear"):
				wears.append(raw[nm]["wear"])
			if raw[nm].has("fuel"):
				fuels.append(raw[nm]["fuel"])
		var med_pace := _median(paces)
		var med_top := _median(tops) if not tops.is_empty() else 0.0
		var med_wear := _median(wears) if not wears.is_empty() else 0.0
		var med_fuel := _median(fuels) if not fuels.is_empty() else 0.0
		for nm in names:
			var m: Dictionary = rows[nm]
			m["pace_rel"] = _r((m["pace"] / med_pace - 1.0) * 100.0)
			if raw[nm].has("top") and med_top > 0.0:
				m["top_rel"] = _r((raw[nm]["top"] / med_top - 1.0) * 100.0)
			if raw[nm].has("wear") and med_wear > 0.0:
				m["wear_rel"] = _r((raw[nm]["wear"] / med_wear - 1.0) * 100.0)
			if raw[nm].has("fuel") and med_fuel > 0.0:
				m["fuel_rel"] = _r((raw[nm]["fuel"] / med_fuel - 1.0) * 100.0)
			m["pace"] = _r(m["pace"])
			m["cons"] = _r(m["cons"])
			m["tl"] = _r(m["tl"])
			m["con"] = _r(m["con"])
		# track numbers come from the five best finishers
		var top5 := names.filter(func(nm): return rows[nm]["pos"] > 0)
		top5.sort_custom(func(a, b): return rows[a]["pos"] < rows[b]["pos"])
		top5 = top5.slice(0, 5)
		if top5.is_empty():   # no finishing positions (practice): use the five quickest instead
			top5 = names.duplicate()
			top5.sort_custom(func(a, b): return rows[a]["pace"] < rows[b]["pace"])
			top5 = top5.slice(0, 5)
		var t5_pace := []
		var t5_top := []
		for nm in top5:
			t5_pace.append(rows[nm]["pace"])
			if raw[nm].has("top"):
				t5_top.append(raw[nm]["top"])
		var ref_s := _median(t5_pace)
		classes[c] = {
			"ref_s": _r(ref_s),
			"kmh": _r(length / ref_s * 3.6),
			"top": _r(_median(t5_top)) if not t5_top.is_empty() else 0.0,
			"wear_km": _r(med_wear * 100.0, 0.0001),
			"fuel_km": _r(med_fuel * 100.0, 0.0001),
			"tl": _r(tls / names.size()),
			"con": _r(cons / names.size()),
			"n": names.size(),
		}
	return {"minutes": cur["minutes"], "classes": classes, "drivers": rows}


# ---------- Quali ----------

static func _quali(cur: Dictionary, length: float) -> Dictionary:
	var rows := {}
	var info := {}   # raw name -> {"best", "top", "sec": [s1, s2, s3] of the best lap}
	for d in cur["drivers"]:
		var nm: String = d.get("Name", "")
		var cls: String = d.get("CarClass", "")
		if nm == "" or cls == "" or d.get("FinishStatus", "") == "DQ":
			continue
		var best := -1.0
		var sec := []
		var top := 0.0
		for l in d["laps"]:
			top = maxf(top, l["top"])
			if l["t"] > 0.0 and (best < 0.0 or l["t"] < best):
				best = l["t"]
				sec = [l["s1"], l["s2"], l["s3"]]
		if best < 0.0:
			var bl := float(d.get("BestLapTime", "-1"))
			if bl <= 0.0:
				continue
			best = bl
		rows[nm] = {"cls": cls, "car": d.get("CarType", ""), "best": best}
		info[nm] = {"best": best, "top": top, "sec": sec}
	var by_class := {}
	for nm in rows:
		var c: String = rows[nm]["cls"]
		if not by_class.has(c):
			by_class[c] = []
		by_class[c].append(nm)
	var classes := {}
	for c in by_class:
		var names: Array = by_class[c]
		var bests := []
		for nm in names:
			bests.append(rows[nm]["best"])
		var med := _median(bests)
		for nm in names:
			rows[nm]["rel"] = _r((rows[nm]["best"] / med - 1.0) * 100.0)
		names.sort_custom(func(a, b): return rows[a]["best"] < rows[b]["best"])
		var top5 := names.slice(0, 5)
		var t_best := []
		var t_top := []
		var shares := [0.0, 0.0, 0.0]
		var share_n := 0
		for nm in top5:
			t_best.append(info[nm]["best"])
			if info[nm]["top"] > 0.0:
				t_top.append(info[nm]["top"])
			var sec: Array = info[nm]["sec"]
			if sec.size() == 3 and sec[0] > 0.0 and sec[1] > 0.0 and sec[2] > 0.0:
				var tot: float = sec[0] + sec[1] + sec[2]
				for i in 3:
					shares[i] += sec[i] / tot
				share_n += 1
		var best_s := _median(t_best)
		var cs := {
			"best_s": _r(best_s),
			"kmh": _r(length / best_s * 3.6),
			"top": _r(_median(t_top)) if not t_top.is_empty() else 0.0,
		}
		if share_n > 0:
			cs["s1"] = _r(shares[0] / share_n, 0.0001)
			cs["s2"] = _r(shares[1] / share_n, 0.0001)
			cs["s3"] = _r(shares[2] / share_n, 0.0001)
		classes[c] = cs
	for nm in rows:
		rows[nm]["best"] = _r(rows[nm]["best"], 0.0001)
	return {"classes": classes, "drivers": rows}


# ---------- Helpers ----------

# Rate (per lap) of the longest run of falling tyre wear, or -1 if the run is too short.
static func _wear_rate(series: Array) -> float:
	var best_len := 0
	var best_rate := -1.0
	var i := 0
	while i < series.size() - 1:
		var j := i
		while j + 1 < series.size() and series[j + 1] <= series[j] + 1e-9:
			j += 1
		if j - i > best_len:
			best_len = j - i
			best_rate = (series[i] - series[j]) / float(j - i)
		i = maxi(j, i + 1)
	return best_rate if best_len >= MIN_RUN else -1.0


static func _attr(p: XMLParser, name: String) -> float:
	var s := p.get_named_attribute_value_safe(name)
	return s.to_float() if s.is_valid_float() else -1.0


static func _median(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var a := values.duplicate()
	a.sort()
	var n := a.size()
	if n % 2 == 1:
		return float(a[n / 2])
	return (float(a[n / 2 - 1]) + float(a[n / 2])) / 2.0


static func _std(values: Array) -> float:
	var n := values.size()
	if n < 2:
		return 0.0
	var mean := 0.0
	for v in values:
		mean += v
	mean /= n
	var s := 0.0
	for v in values:
		s += (v - mean) * (v - mean)
	return sqrt(s / n)


static func _r(v: float, step := 0.001) -> float:
	return snappedf(v, step)
