class_name Fingerprint
extends RefCounted

## Boils a result XML down to the numbers the profiles and predictions use.
## Names are the raw names from the file; Profiles resolves aliases when it reads them.
##
## extract(path) returns {
##   "v": 1,
##   "track": {"TrackVenue", "TrackCourse", "TrackLength"},
##   "race":  {"minutes": int,
##             "classes": {cls: {"ref_s", "kmh", "top", "wear_km", "fuel_km", "tl", "tlw", "tlp", "con", "n",
##                               "passes", "passes_10", "lap1_moves", "pit_swaps"}},
##             "drivers": {name: {"cls", "car", "laps", "grid", "pos", "pace", "pace_rel", "cons",
##                                "top_rel", "wear_rel", "fuel_rel", "tl", "tlw", "tlp", "con", "pen", "mass"}}},
##   "quali": {"classes": {cls: {"best_s", "kmh", "top", "s1", "s2", "s3"}},
##             "drivers": {name: {"cls", "car", "best", "rel"}}}
## }
## "_rel" values are % versus the class median of that session (negative pace = quicker).
## tl = track-limit events per lap, con = contacts with other cars per lap,
## cons = lap-time spread in % of the median clean lap, wear_km / fuel_km are % per km.

# what the game decided on a track-limit event (from the text: "No Further Action", "Warning",
# "Invalid Lap Cut Track", "Drive Through Penalty", "Time Penalty")
const TL_NONE := 0
const TL_WARN := 1
const TL_INVALID := 2   # lap time deleted
const TL_PEN := 3
const VERSION := 14   # 14: costly laps ("costly" count, "costly_n" laps looked at, "costly_s" seconds lost), invalidated laps included. 13: the 5 quickest race laps ("best5"), the best lap ("best_lap") and clean laps ("clean_n"), for Clean race pace %. 12: places gained on lap 1 ("start"), pace fade over a stint ("fade"), invalidated laps count with the warnings. 11: drive-throughs served mid-race and what each cost ("dt"). 10: no track limits on lap 0 (formation lap and start). 9: track limits by the game's decision ("tlw" warnings, "tlp" penalties per lap). 7: success ballast carried ("mass", kg). 6: virtual energy per km ("ve_km") for the pit-stop forecast. 5: 5: no contacts / track limits after the chequered flag. 4: fuel per lap is an average of the normal laps (was the median)
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
	var dt_rx := RegEx.new()
	dt_rx.compile("^(.+?) served \\S+ Drive Thru penalty")
	var served_et := -1.0   # et of a Penalty element without a driver (its text says who served what)
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
	var tl_at := []   # [driver, et] of the TrackLimits element whose text (the decision) comes next
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
					cur = {"drivers": [], "minutes": 0, "tl": {}, "con": {}, "con_ev": [], "pens": {}, "dt": []}
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
							"et": _attr(p, "et"),
							"fl": _attr(p, "fuel"),
							"top": _attr(p, "topspeed"),
							"fu": _attr(p, "fuelUsed"),
							"ve": _attr(p, "veUsed"),   # virtual energy (GT3, Hyper): often runs out before the fuel
							"tw": tw / 4.0,
							"s1": _attr(p, "s1"), "s2": _attr(p, "s2"), "s3": _attr(p, "s3"),
							"p": int(_attr(p, "p")),   # race position at the end of the lap
							"pit": p.get_named_attribute_value_safe("pit") == "1",
							"wet": ("wet" in p.get_named_attribute_value_safe("fcompound").to_lower()
								or "wet" in p.get_named_attribute_value_safe("rcompound").to_lower()),
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
					elif tag == "TrackLimits" and p.get_named_attribute_value_safe("Lap") == "0":
						pass   # formation lap and start: the game's logic is unreliable there (drive-throughs the stewards overturn)
					elif tag == "TrackLimits":
						var who := p.get_named_attribute_value_safe("Driver")
						var tl: Dictionary = cur["tl"]
						if not tl.has(who):
							tl[who] = {}
						# the game's decision comes as the element's text (its Resolution number changed
						# between game versions); each event is written twice, with the same time: keyed by it
						tl_at = [who, p.get_named_attribute_value_safe("et")]
						tl[who][tl_at[1]] = TL_NONE
					elif tag == "Penalty" and p.has_attribute("Driver"):
						var pens: Dictionary = cur["pens"]
						var pw := p.get_named_attribute_value_safe("Driver")
						pens[pw] = pens.get(pw, 0) + 1
					elif tag == "Penalty":
						served_et = float(p.get_named_attribute_value_safe("et"))
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
				elif not tl_at.is_empty():
					var lower := txt.to_lower()
					cur["tl"][tl_at[0]][tl_at[1]] = TL_WARN if lower.contains("warning") else (TL_PEN if lower.contains("penalty")
						else (TL_INVALID if lower.contains("invalid") else TL_NONE))
					tl_at = []
				elif served_et >= 0.0:
					var dm := dt_rx.search(txt)
					if dm != null:
						cur["dt"].append([dm.get_string(1), served_et])
					served_et = -1.0
				elif in_incident:
					var m := inc_rx.search(txt)
					if m != null:
						var who2 := m.get_string(1)
						var key := who2 + "|" + m.get_string(3)
						if incident_et - float(last_inc.get(key, -1000.0)) > INCIDENT_GAP:
							cur["con_ev"].append([who2, incident_et])   # counted at the end of the session
						last_inc[key] = incident_et
			XMLParser.NODE_ELEMENT_END:
				if in_lap and depth == driver_depth + 1:
					in_lap = false
				if driver_depth != -1 and depth == driver_depth:
					cur["drivers"].append(driver)
					driver_depth = -1
				elif session != "" and depth == session_depth:
					_drop_after_finish(cur)
					session = ""
					session_depth = -1
					last_inc.clear()
				field = ""
				header_field = ""
				session_field = ""
				in_incident = false
				served_et = -1.0
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
# Contacts and track-limit events after a driver has taken the chequered flag (celebrations,
# crashing into walls on the cool-down lap) are not counted against them. Incidents come before
# the drivers in the file, so this runs at the end of the session, once finish times are known.
# Drivers who did not finish keep everything.
static func _drop_after_finish(cur: Dictionary) -> void:
	var fin := {}
	for d in cur["drivers"]:
		var ft := float(d.get("FinishTime", "0"))
		if ft > 0.0 and d.has("Name"):
			fin[d["Name"]] = ft
	var con := {}
	for ev in cur["con_ev"]:
		if fin.has(ev[0]) and float(ev[1]) > fin[ev[0]]:
			continue
		con[ev[0]] = con.get(ev[0], 0) + 1
	cur["con"] = con
	for who in cur["tl"]:
		if not fin.has(who):
			continue
		for et in cur["tl"][who].keys():
			if float(et) > fin[who]:
				cur["tl"][who].erase(et)


# Track-limit events of one driver by the game's decision: "warn" or "pen".
static func _tl_count(events: Dictionary, kind: String) -> int:
	var n := 0
	for et in events:
		var code := int(events[et])
		# an invalidated lap ("Invalid Lap Cut Track") counts with the warnings: a mistake or pushing too hard
		if (kind == "warn" and (code == TL_WARN or code == TL_INVALID)) or (kind == "pen" and code == TL_PEN):
			n += 1
	return n


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
	var lap_med := _lap_medians(cur["drivers"])   # class -> {lap number: median lap time}
	for d in cur["drivers"]:
		_full_times(d["laps"])
	var full_med := _lap_medians(cur["drivers"], "tt")   # the same with invalidated laps timed too
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
		var ves := []
		var wear_series := []
		for l in d["laps"]:
			if l["n"] > 1 and l["t"] > 0.0:
				times.append(l["t"])
			if l["top"] > 0.0:
				tops.append(l["top"])
			if l["fu"] > 0.0:
				fuels.append(l["fu"])
			if l.get("ve", 0.0) > 0.0:
				ves.append(l["ve"])
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
		# lap-by-lap pace: every lap against the class median of that same lap, so a changing
		# track (rain, drying, rubber, fuel burn) or retiring early does not skew the comparison
		var ratios := _lap_ratios(d["laps"], lap_med.get(cls, {}))
		# in a race that turns wet, laps far off the driver's dry best still count lap by lap
		if clean.size() < MIN_LAPS and ratios.size() < MIN_LAPS:
			continue
		if clean.size() < MIN_LAPS:
			clean = times
		var pace := _median(clean)
		var cons := _std(clean) / pace * 100.0
		var ratio := -1.0
		if ratios.size() >= MIN_LAPS:
			ratio = _median(ratios)
			var clean_r := []
			for r in ratios:
				if r <= CLEAN_LIMIT * ratio:
					clean_r.append(r)
			if clean_r.size() >= MIN_LAPS:
				cons = _std(clean_r) / ratio * 100.0
		var m := {
			"cls": cls, "car": d.get("CarType", ""), "laps": n,
			"grid": int(d.get("ClassGridPos", "0")), "pos": int(d.get("ClassPosition", "0")),
			"pace": pace, "cons": cons,
			# the community's "clean race pace": the average of the 5 quickest race laps (no pit or
			# first lap); with the best lap and the number of clean laps behind it
			"best5": _r(_mean(sorted_t.slice(0, 5)), 0.001), "best_lap": _r(sorted_t[0], 0.001), "clean_n": clean.size(),
			"tl": cur["tl"].get(nm, {}).size() / float(n),   # every event, whatever the game decided
			"tlw": _tl_count(cur["tl"].get(nm, {}), "warn") / float(n),   # warnings (cleanliness)
			"tlp": _tl_count(cur["tl"].get(nm, {}), "pen") / float(n),    # turned into a penalty
			"con": cur["con"].get(nm, 0) / float(n),
			"pen": cur["pens"].get(nm, 0),
			"mass": float(d.get("PenaltyMass", "0")),   # success ballast carried (kg)
		}
		var x := {}
		if ratio > 0.0:
			x["ratio"] = ratio
		if not tops.is_empty():
			x["top"] = tops.max()
		var wr := _wear_rate(wear_series)
		if wr >= 0.0:
			x["wear"] = wr / km
		if fuels.size() > MIN_LAPS:
			x["fuel"] = _fuel_per_lap(fuels) / km
		if ves.size() > MIN_LAPS:
			x["ve"] = _fuel_per_lap(ves) / km
		var cl := _costly(d["laps"], full_med.get(cls, {}))
		if int(cl["n"]) >= MIN_LAPS:
			m["costly"] = cl["k"]
			m["costly_n"] = cl["n"]
			m["costly_s"] = _r(cl["lost"], 0.1)
		var fd := _stint_fade(d["laps"], lap_med.get(cls, {}))
		if not fd.is_empty():
			m["fade"] = _r(fd["fade"], 0.0001)
			m["fade_laps"] = fd["laps"]
		rows[nm] = m
		raw[nm] = x
	_add_starts(cur["drivers"], rows)

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
		var ves := []
		var tls := 0.0
		var tlws := 0.0
		var tlps := 0.0
		var cons := 0.0
		for nm in names:
			paces.append(rows[nm]["pace"])
			tls += rows[nm]["tl"]
			tlws += rows[nm]["tlw"]
			tlps += rows[nm]["tlp"]
			cons += rows[nm]["con"]
			if raw[nm].has("top"):
				tops.append(raw[nm]["top"])
			if raw[nm].has("wear"):
				wears.append(raw[nm]["wear"])
			if raw[nm].has("fuel"):
				fuels.append(raw[nm]["fuel"])
			if raw[nm].has("ve"):
				ves.append(raw[nm]["ve"])
		var med_pace := _median(paces)
		var ratios_c := []
		for nm in names:
			if raw[nm].has("ratio"):
				ratios_c.append(raw[nm]["ratio"])
		var med_ratio := _median(ratios_c) if ratios_c.size() >= 3 else 0.0
		var med_top := _median(tops) if not tops.is_empty() else 0.0
		var med_wear := _median(wears) if not wears.is_empty() else 0.0
		var med_fuel := _median(fuels) if not fuels.is_empty() else 0.0
		for nm in names:
			var m: Dictionary = rows[nm]
			if med_ratio > 0.0 and raw[nm].has("ratio"):
				m["pace_rel"] = _r((raw[nm]["ratio"] / med_ratio - 1.0) * 100.0)
			else:   # too few comparable laps: whole-race medians as before
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
			m["tlw"] = _r(m["tlw"])
			m["tlp"] = _r(m["tlp"], 0.0001)
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
			"ve_km": _r(_median(ves) * 100.0, 0.0001) if not ves.is_empty() else 0.0,   # % of the energy allowance per km
			"tl": _r(tls / names.size()),
			"tlw": _r(tlws / names.size()),
			"tlp": _r(tlps / names.size(), 0.0001),
			"con": _r(cons / names.size()),
			"n": names.size(),
		}
		classes[c].merge(_passes(cur["drivers"], c))
		var pl := _pit_loss(cur["drivers"], c, lap_med.get(c, {}))
		if pl > 0.0:
			classes[c]["pit_loss"] = _r(pl, 0.1)
	return {"minutes": cur["minutes"], "classes": classes, "drivers": rows, "wet": _wet_share(cur["drivers"]),
		"dt": _drive_through_losses(cur)}


# Seconds each drive-through served mid-race cost: the lap that ran through the pit lane and the
# one after, against the driver's own median lap. The game logs the serve as the car leaves the
# lane, so the lane is in the lap that ended before that. Left out: the first two laps (start
# traffic, and the stewards usually overturn start drive-throughs) and serves combined with a
# service stop (fuel or tyres). Penalties given mid-race are drive-throughs, so this is what one
# costs at the track (median of the league's: about 20 s).
static func _drive_through_losses(cur: Dictionary) -> Array:
	var by_name := {}
	for d in cur["drivers"]:
		by_name[d.get("Name", "")] = d["laps"]
	var out := []
	for ev in cur.get("dt", []):
		var laps: Array = by_name.get(ev[0], [])
		var i := -1
		for k in laps.size():
			if float(laps[k]["et"]) >= float(ev[1]):
				i = k
				break
		if i < 1:
			continue
		var a: Dictionary = laps[i - 1]
		var b: Dictionary = laps[i]
		if int(a["n"]) <= 2 or a["t"] <= 0.0 or b["t"] <= 0.0:
			continue
		if b["fl"] > a["fl"] + 0.02 or b["tw"] > a["tw"] + 0.02:
			continue   # served together with a stop for fuel or tyres
		var clean := []
		for l in laps:
			if l["t"] > 0.0 and not l["pit"] and l["n"] > 1:
				clean.append(l["t"])
		if clean.size() < 5:
			continue
		var loss: float = a["t"] + b["t"] - 2.0 * _median(clean)
		if loss > 0.0 and loss < 120.0:
			out.append(_r(loss, 0.1))
	return out


# Places gained on the first lap, in class: grid place minus the place at the end of lap 1
# (positive = gained). The place after lap 1 is the rank among the cars of the class that
# completed it, so cars that never made it round count as places gained. Left out when the
# driver has no grid place or no first lap.
static func _add_starts(drivers: Array, rows: Dictionary) -> void:
	var by_cls := {}   # class -> [[overall place after lap 1, name]]
	for d in drivers:
		for l in d["laps"]:
			if l["n"] == 1:
				if int(l["p"]) > 0:
					var c: String = d.get("CarClass", "")
					if not by_cls.has(c):
						by_cls[c] = []
					by_cls[c].append([int(l["p"]), d.get("Name", "")])
				break
	for c in by_cls:
		var order: Array = by_cls[c]
		order.sort_custom(func(a, b): return a[0] < b[0])
		for i in order.size():
			var nm: String = order[i][1]
			if rows.has(nm) and int(rows[nm]["grid"]) > 0:
				rows[nm]["start"] = int(rows[nm]["grid"]) - (i + 1)


# Pace fade over a stint: how much the driver's lap times drift per 10 laps against the class
# median of the same laps (so fuel burn, rubber and weather, which everyone shares, drop out), in
# % of lap time; positive = fades more than the class (harder on the tyres as the stint goes on),
# negative = holds the pace better. A stint runs between pit stops; it needs FADE_MIN comparable
# laps, laps far off the stint's own median (traffic, a mistake) are left out, and stints are
# averaged by their length. {"fade", "laps"} or {} without a long enough stint.
const FADE_MIN := 10
const FADE_CAP := 3.0   # % per 10 laps (99% of races are within about 2.2)
static func _stint_fade(laps: Array, med: Dictionary) -> Dictionary:
	var stints := [[]]
	for i in laps.size():
		if laps[i]["pit"]:
			stints.append([])
		elif laps[i].get("wet", false):
			stints.append([])   # wet tyres: not the same stint as the dry laps around it
		elif _comparable(laps, i) and med.has(laps[i]["n"]):
			stints.back().append([float(laps[i]["n"]), laps[i]["t"] / float(med[laps[i]["n"]])])
	var sum := 0.0
	var total := 0
	for st in stints:
		if st.size() < FADE_MIN:
			continue
		var m := _median(st.map(func(p): return p[1]))
		var pts: Array = st.filter(func(p): return p[1] <= CLEAN_LIMIT * m)
		if pts.size() < FADE_MIN:
			continue
		var mx := 0.0
		var my := 0.0
		for p in pts:
			mx += p[0]
			my += p[1]
		mx /= pts.size()
		my /= pts.size()
		var sxx := 0.0
		var sxy := 0.0
		for p in pts:
			sxx += (p[0] - mx) * (p[0] - mx)
			sxy += (p[0] - mx) * (p[1] - my)
		if sxx <= 0.0:
			continue
		sum += sxy / sxx * 1000.0 * pts.size()   # ratio per lap -> % per 10 laps
		total += pts.size()
	# capped: a bigger drift is damage or a problem mid-stint, not how the driver manages a stint
	return {"fade": clampf(sum / total, -FADE_CAP, FADE_CAP), "laps": total} if total > 0 else {}


# Every lap timed, invalidated ones too (the file gives them no time): from the lap's own time, or
# else from the elapsed time at the start of the next lap. Stored as "tt" (-1 when unknown).
static func _full_times(laps: Array) -> void:
	for i in laps.size():
		var t := float(laps[i]["t"])
		if t <= 0.0 and i + 1 < laps.size() and float(laps[i + 1]["et"]) > float(laps[i]["et"]) and float(laps[i]["et"]) > 0.0:
			t = float(laps[i + 1]["et"]) - float(laps[i]["et"])
		laps[i]["tt"] = t


# Costly laps: laps lost to a mistake (a spin, an off, a big lock-up), at least COSTLY_LIMIT slower
# than the driver's own usual lap, both measured against the class's median of the same lap (so a
# safety car, rain or a drying track, which slow everyone, are not mistakes). Not the start, pit laps
# or out-laps. {"n": laps looked at, "k": costly laps, "lost": seconds lost on them}
const COSTLY_LIMIT := 0.04
static func _costly(laps: Array, med: Dictionary) -> Dictionary:
	var ratios := []   # [ratio, class median time]
	for i in laps.size():
		if _comparable(laps, i, "tt") and med.has(laps[i]["n"]):
			ratios.append([float(laps[i]["tt"]) / float(med[laps[i]["n"]]), float(med[laps[i]["n"]])])
	if ratios.size() < MIN_LAPS:
		return {"n": ratios.size(), "k": 0, "lost": 0.0}
	var own := _median(ratios.map(func(x): return x[0]))
	var k := 0
	var lost := 0.0
	for x in ratios:
		if x[0] > own * (1.0 + COSTLY_LIMIT):
			k += 1
			lost += (x[0] - own) * x[1]
	return {"n": ratios.size(), "k": k, "lost": lost}


# A lap that can be compared with other cars on the same lap: not the start, not a pit lap
# and not the out-lap after one, with a valid time.
static func _comparable(laps: Array, i: int, key := "t") -> bool:
	var l: Dictionary = laps[i]
	if l["n"] <= 1 or float(l.get(key, -1.0)) <= 0.0 or l["pit"]:
		return false
	return i == 0 or not laps[i - 1]["pit"]


# class -> {lap number: median time of the comparable laps}; a lap needs at least a third of
# the class (and 3 cars) to give a median worth comparing with
static func _lap_medians(drivers: Array, key := "t") -> Dictionary:
	var acc := {}     # class -> {lap: [times]}
	var count := {}   # class -> cars
	for d in drivers:
		var cls: String = d.get("CarClass", "")
		if cls == "":
			continue
		count[cls] = int(count.get(cls, 0)) + 1
		if not acc.has(cls):
			acc[cls] = {}
		var laps: Array = d["laps"]
		for i in laps.size():
			if _comparable(laps, i, key):
				var k: int = laps[i]["n"]
				if not acc[cls].has(k):
					acc[cls][k] = []
				acc[cls][k].append(laps[i][key])
	var out := {}
	for cls in acc:
		out[cls] = {}
		var need := maxi(3, int(ceil(int(count[cls]) / 3.0)))
		for k in acc[cls]:
			if acc[cls][k].size() >= need:
				out[cls][k] = _median(acc[cls][k])
	return out


# This driver's comparable laps divided by the class median of the same lap
static func _lap_ratios(laps: Array, med: Dictionary) -> Array:
	var out := []
	for i in laps.size():
		if _comparable(laps, i) and med.has(laps[i]["n"]):
			out.append(laps[i]["t"] / float(med[laps[i]["n"]]))
	return out


# Typical time lost to a routine pit stop in one class, in seconds: the in-lap and the out-lap
# compared with the class median of those same laps (lane, stop and slow out-lap together).
# Only races where at least half the class stopped count: in a sprint the few stops are repairs,
# far longer than a planned stop. 0 if that is not the case or fewer than two stops are usable.
static func _pit_loss(drivers: Array, cls: String, med: Dictionary) -> float:
	var losses := []
	var cars := 0
	var stopped := 0
	for d in drivers:
		if d.get("CarClass", "") != cls:
			continue
		cars += 1
		var laps: Array = d["laps"]
		for l in laps:
			if l["pit"]:
				stopped += 1
				break
		for i in range(laps.size() - 1):
			if not laps[i]["pit"]:
				continue
			var a: Dictionary = laps[i]
			var b: Dictionary = laps[i + 1]
			if a["t"] > 0.0 and b["t"] > 0.0 and med.has(a["n"]) and med.has(b["n"]):
				var loss: float = (a["t"] - med[a["n"]]) + (b["t"] - med[b["n"]])
				if loss > 5.0 and loss < 300.0:
					losses.append(loss)
	if stopped * 2 < cars:
		return 0.0
	return _median(losses) if losses.size() >= 2 else 0.0


# Share of all laps in a session driven on wet tyres (0 = dry, 1 = fully wet)
static func _wet_share(drivers: Array) -> float:
	var total := 0
	var wet := 0
	for d in drivers:
		for l in d["laps"]:
			total += 1
			if l.get("wet", false):
				wet += 1
	return _r(wet / float(total), 0.01) if total > 0 else 0.0


# On-track passes in one class, from the running order at the end of every lap (the lap's
# "p" = race position, which already accounts for laps done, so being lapped is not a pass).
# A pass = two cars of the class swapping order between the end of one lap and the next,
# with neither of them pitting on those laps. Lap 1 (start) and pit swaps are counted apart.
# {"passes": n, "passes_10": per car per 10 laps, "lap1_moves": swaps vs the grid, "pit_swaps": n}
static func _passes(drivers: Array, cls: String) -> Dictionary:
	var cars := []   # [{"grid": int, "laps": {num: [pos, pit]}}]
	for d in drivers:
		if d.get("CarClass", "") != cls:
			continue
		var laps := {}
		for l in d["laps"]:
			if int(l.get("p", 0)) > 0:
				laps[int(l["n"])] = [int(l["p"]), bool(l.get("pit", false))]
		if not laps.is_empty():
			cars.append({"grid": int(d.get("GridPos", "0")), "laps": laps})
	var passes := 0
	var lap1 := 0
	var pit := 0
	var car_laps := 0
	for i in cars.size():
		var a: Dictionary = cars[i]["laps"]
		car_laps += maxi(0, a.size() - 1)
		for j in range(i + 1, cars.size()):
			var b: Dictionary = cars[j]["laps"]
			var ga: int = cars[i]["grid"]
			var gb: int = cars[j]["grid"]
			if ga > 0 and gb > 0 and a.has(1) and b.has(1) and (ga < gb) != (a[1][0] < b[1][0]):
				lap1 += 1
			for k in a:
				if k < 2 or not b.has(k) or not a.has(k - 1) or not b.has(k - 1):
					continue
				if (a[k - 1][0] < b[k - 1][0]) == (a[k][0] < b[k][0]):
					continue
				if a[k][1] or b[k][1] or a[k - 1][1] or b[k - 1][1]:
					pit += 1
				else:
					passes += 1
	var out := {"passes": passes, "lap1_moves": lap1, "pit_swaps": pit}
	if car_laps > 0:
		out["passes_10"] = _r(passes / float(car_laps) * 10.0)
	return out


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
		rows[nm] = {"cls": cls, "car": d.get("CarType", ""), "best": best, "mass": float(d.get("PenaltyMass", "0"))}
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
	return {"classes": classes, "drivers": rows, "wet": _wet_share(cur["drivers"])}


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


# The game logs fuel used per lap in coarse steps (in Hypercar, one step is about 7% of a lap's
# fuel), so the median of a race snaps to one of two or three values and most drivers came out
# at exactly the class median while a few landed a whole step away. The average of the normal
# laps (refuels, pit laps and odd readings dropped) is far finer: 30 laps give 1/30 of a step.
static func _fuel_per_lap(fuels: Array) -> float:
	var mid := _median(fuels)
	var sum := 0.0
	var n := 0
	for f in fuels:
		if f >= 0.5 * mid and f <= 1.5 * mid:
			sum += f
			n += 1
	return sum / n if n > 0 else mid


static func _mean(xs: Array) -> float:
	if xs.is_empty():
		return 0.0
	var t := 0.0
	for x in xs:
		t += float(x)
	return t / xs.size()


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
