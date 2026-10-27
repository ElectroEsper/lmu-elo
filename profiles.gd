extends Node

## Driver, car and track profiles built from the fingerprints saved with each event.
## Register as an autoload named "Profiles", AFTER "Elo".
## Call rebuild() after events or aliases change (the views do this when shown).
##
## Everything is "as of a date" on request (before = "2026_07_15" means only earlier days),
## so the backtest can replay history without peeking.

const K_PACE := 2.0        # shrinkage, in events, for pace-like traits (pulls few-race drivers to the field)
const K_RATE := 4.0        # for track limits / contacts per lap
const K_CONS := 6.0        # for lap-time consistency (a weak trait)
const PRIOR_TL := 0.79
const PRIOR_CON := 0.113
const PRIOR_CONS := 0.77
const MIN_TRACKS_FOR_Z := 4
const RACE_QUALI_RATIO := 1.03   # typical race lap / best quali lap, used for tracks without a race yet
const DEFAULT_MINUTES := 35
const DEFAULT_LAP_S := 110.0

var days := []     # chronological: {"date", "course", "track", "race", "quali"} (names resolved)
var hist := {}     # "cls|name" -> [{"date", "r": {...}, "q": {...}}], chronological


func _ready() -> void:
	rebuild()


func rebuild() -> void:
	days.clear()
	hist.clear()
	var by_date := {}
	for f in DirAccess.get_files_at("user://events"):
		if not f.ends_with(".json"):
			continue
		var draft = JSON.parse_string(FileAccess.get_file_as_string("user://events/" + f))
		if not (draft is Dictionary) or not draft.has("fp") or not draft.has("file"):
			continue
		var fp: Dictionary = draft["fp"]
		if fp.is_empty() or not fp.has("track"):
			continue
		var date: String = str(draft["file"]).left(10)
		if not by_date.has(date):
			by_date[date] = {"date": date, "course": "", "track": {}, "race": {}, "quali": {}}
		var day: Dictionary = by_date[date]
		day["track"] = fp["track"]
		day["course"] = fp["track"].get("course", "")
		if fp.has("race"):
			day["race"] = _resolved(fp["race"])
		if fp.has("quali"):
			day["quali"] = _resolved(fp["quali"])
	var dates := by_date.keys()
	dates.sort()
	for d in dates:
		days.append(by_date[d])
	for day in days:
		var recs := {}
		for nm in day["race"].get("drivers", {}):
			var e: Dictionary = day["race"]["drivers"][nm]
			var key: String = "%s|%s" % [e["cls"], nm]
			recs[key] = {"date": day["date"], "r": e, "q": {}}
		for nm in day["quali"].get("drivers", {}):
			var e: Dictionary = day["quali"]["drivers"][nm]
			var key: String = "%s|%s" % [e["cls"], nm]
			if not recs.has(key):
				recs[key] = {"date": day["date"], "r": {}, "q": {}}
			recs[key]["q"] = e
		for key in recs:
			if not hist.has(key):
				hist[key] = []
			hist[key].append(recs[key])


# Copy of a race/quali fingerprint with driver names resolved through the alias table.
func _resolved(sec: Dictionary) -> Dictionary:
	var out := sec.duplicate(false)
	var drivers := {}
	for raw_name in sec.get("drivers", {}):
		var nm: String = Elo.resolve(raw_name)
		if not drivers.has(nm):
			drivers[nm] = sec["drivers"][raw_name]
	out["drivers"] = drivers
	return out


func has_data() -> bool:
	return not days.is_empty()


# ---------- Drivers ----------

# Plain averages over the events before `before` ("" = all). Counts are per metric
# because wear / fuel / top speed are sometimes missing.
# {"n_r", "n_q", "pace", "qpace", "wear", "n_wear", "top", "n_top", "fuel", "n_fuel", "tl", "con", "cons", "car"}
func raw_stats(who: String, cls: String, before := "") -> Dictionary:
	var s := {"n_r": 0, "n_q": 0, "pace": 0.0, "qpace": 0.0, "wear": 0.0, "n_wear": 0,
		"top": 0.0, "n_top": 0, "fuel": 0.0, "n_fuel": 0, "tl": 0.0, "con": 0.0, "cons": 0.0, "car": ""}
	for rec in hist.get("%s|%s" % [cls, who], []):
		if before != "" and rec["date"] >= before:
			continue
		var r: Dictionary = rec["r"]
		if not r.is_empty():
			s["n_r"] += 1
			s["pace"] += r.get("pace_rel", 0.0)
			s["tl"] += r.get("tl", 0.0)
			s["con"] += r.get("con", 0.0)
			s["cons"] += r.get("cons", 0.0)
			s["car"] = r.get("car", s["car"])
			if r.has("wear_rel"):
				s["wear"] += r["wear_rel"]
				s["n_wear"] += 1
			if r.has("top_rel"):
				s["top"] += r["top_rel"]
				s["n_top"] += 1
			if r.has("fuel_rel"):
				s["fuel"] += r["fuel_rel"]
				s["n_fuel"] += 1
		var q: Dictionary = rec["q"]
		if not q.is_empty():
			s["n_q"] += 1
			s["qpace"] += q.get("rel", 0.0)
			if s["car"] == "":
				s["car"] = q.get("car", "")
	# sums -> means
	for k in ["pace", "tl", "con", "cons"]:
		if s["n_r"] > 0:
			s[k] /= s["n_r"]
	if s["n_q"] > 0:
		s["qpace"] /= s["n_q"]
	for k in ["wear", "top", "fuel"]:
		if s["n_" + k] > 0:
			s[k] /= s["n_" + k]
	return s


# (n * mean + k * prior) / (n + k)
static func shrunk(mean: float, n: int, k: float, prior: float) -> float:
	return (mean * n + prior * k) / (n + k)


# Average per-lap track-limit / contact / consistency numbers of the class (the shrinkage priors).
func class_means(cls: String, before := "") -> Dictionary:
	var tl := 0.0
	var con := 0.0
	var cons := 0.0
	var n := 0
	for day in days:
		if before != "" and day["date"] >= before:
			continue
		for nm in day["race"].get("drivers", {}):
			var r: Dictionary = day["race"]["drivers"][nm]
			if r["cls"] == cls:
				tl += r.get("tl", 0.0)
				con += r.get("con", 0.0)
				cons += r.get("cons", 0.0)
				n += 1
	if n < 10:
		return {"tl": PRIOR_TL, "con": PRIOR_CON, "cons": PRIOR_CONS}
	return {"tl": tl / n, "con": con / n, "cons": cons / n}


# Spread of driver averages (wear / top speed / fuel), used to turn a driver's trait into a z-score.
func trait_sd(cls: String, before := "") -> Dictionary:
	var vals := {"wear": [], "top": [], "fuel": []}
	for key in hist:
		if not key.begins_with(cls + "|"):
			continue
		var nm: String = key.substr(cls.length() + 1)
		var s := raw_stats(nm, cls, before)
		if s["n_r"] < 2:
			continue
		for k in vals:
			if s["n_" + k] >= 2:
				vals[k].append(s[k])
	var out := {}
	for k in vals:
		var a: Array = vals[k]
		if a.size() < 4:
			out[k] = 1.0
			continue
		var mean := 0.0
		for v in a:
			mean += v
		mean /= a.size()
		var sq := 0.0
		for v in a:
			sq += (v - mean) * (v - mean)
		out[k] = maxf(sqrt(sq / a.size()), 0.5)
	return out


# Display-ready profile (everything shrunk toward the field; no Elo involved).
# {"n_r", "n_q", "pace", "qpace", "wear", "top", "fuel", "tl", "con", "cons", "car"}
func profile(who: String, cls: String, before := "", cm: Dictionary = {}) -> Dictionary:
	var s := raw_stats(who, cls, before)
	if cm.is_empty():
		cm = class_means(cls, before)
	return {
		"n_r": s["n_r"], "n_q": s["n_q"], "car": s["car"],
		"pace": shrunk(s["pace"], s["n_r"], K_PACE, 0.0),
		"qpace": shrunk(s["qpace"], s["n_q"], K_PACE, 0.0),
		"wear": shrunk(s["wear"], s["n_wear"], K_PACE, 0.0),
		"top": shrunk(s["top"], s["n_top"], K_PACE, 0.0),
		"fuel": shrunk(s["fuel"], s["n_fuel"], K_PACE, 0.0),
		"tl": shrunk(s["tl"], s["n_r"], K_RATE, cm["tl"]),
		"con": shrunk(s["con"], s["n_r"], K_RATE, cm["con"]),
		"cons": shrunk(s["cons"], s["n_r"], K_CONS, cm["cons"]),
	}


# Drivers of a class with at least one race or quali in the data, for the Profiles table.
func driver_rows(cls: String) -> Array:
	var cm := class_means(cls)
	var rows := []
	for key in hist:
		if not key.begins_with(cls + "|"):
			continue
		var nm: String = key.substr(cls.length() + 1)
		var p := profile(nm, cls, "", cm)
		p["name"] = nm
		rows.append(p)
	rows.sort_custom(func(a, b): return a["pace"] + a["qpace"] < b["pace"] + b["qpace"])
	return rows


func classes() -> Array:
	var seen := {}
	for key in hist:
		seen[key.get_slice("|", 0)] = true
	var out := seen.keys()
	out.sort()
	return out


# ---------- Cars ----------

# One row per car model: how it compares with the class median (all drivers, all events).
func car_rows(cls: String) -> Array:
	var acc := {}
	for day in days:
		for nm in day["race"].get("drivers", {}):
			var r: Dictionary = day["race"]["drivers"][nm]
			if r["cls"] != cls:
				continue
			var a: Dictionary = acc.get(r["car"], {"n": 0, "pace": 0.0, "top": 0.0, "nt": 0, "fuel": 0.0, "nf": 0, "wear": 0.0, "nw": 0, "q": 0.0, "nq": 0})
			a["n"] += 1
			a["pace"] += r.get("pace_rel", 0.0)
			if r.has("top_rel"):
				a["top"] += r["top_rel"]
				a["nt"] += 1
			if r.has("fuel_rel"):
				a["fuel"] += r["fuel_rel"]
				a["nf"] += 1
			if r.has("wear_rel"):
				a["wear"] += r["wear_rel"]
				a["nw"] += 1
			acc[r["car"]] = a
		for nm in day["quali"].get("drivers", {}):
			var q: Dictionary = day["quali"]["drivers"][nm]
			if q["cls"] != cls:
				continue
			var a2: Dictionary = acc.get(q["car"], {"n": 0, "pace": 0.0, "top": 0.0, "nt": 0, "fuel": 0.0, "nf": 0, "wear": 0.0, "nw": 0, "q": 0.0, "nq": 0})
			a2["q"] += q.get("rel", 0.0)
			a2["nq"] += 1
			acc[q["car"]] = a2
	var rows := []
	for car in acc:
		var a: Dictionary = acc[car]
		rows.append({
			"car": car, "n": a["n"],
			"pace": a["pace"] / maxf(a["n"], 1),
			"qpace": a["q"] / maxf(a["nq"], 1),
			"top": a["top"] / maxf(a["nt"], 1),
			"fuel": a["fuel"] / maxf(a["nf"], 1),
			"wear": a["wear"] / maxf(a["nw"], 1),
		})
	rows.sort_custom(func(a, b): return a["pace"] + a["qpace"] < b["pace"] + b["qpace"])
	return rows


# ---------- Tracks ----------

func courses() -> Array:
	var seen := {}
	for day in days:
		seen[day["course"]] = day["date"]
	var out := seen.keys()
	out.sort_custom(func(a, b): return seen[a] > seen[b])   # most recent first
	return out


func latest_course() -> String:
	return "" if days.is_empty() else days[days.size() - 1]["course"]


# Per-course averages for the Tracks table: [{"course", "visits", "length", "kmh", "top", "s1", "s2", "s3", "wear_km", "fuel_km", "tl"}]
func track_rows(cls: String) -> Array:
	var rows := []
	for course in courses():
		var t := _course_stats(course, cls, "", "")
		if t.is_empty():
			continue
		t["course"] = course
		rows.append(t)
	return rows


# Averages over the visits to a course. Race numbers use days before `before`; quali numbers
# use days before `before` plus the quali of `quali_day` (the event being predicted).
func _course_stats(course: String, cls: String, before: String, quali_day: String) -> Dictionary:
	var acc := {}
	var cnt := {}
	var visits := 0
	var length := 0.0
	for day in days:
		if day["course"] != course:
			continue
		var in_past: bool = before == "" or day["date"] < before
		var race_ok: bool = in_past and not day["race"].is_empty()
		var quali_ok: bool = (in_past or day["date"] == quali_day) and not day["quali"].is_empty()
		length = day["track"].get("length", length)
		if race_ok and day["race"]["classes"].has(cls):
			var c: Dictionary = day["race"]["classes"][cls]
			_add(acc, cnt, "ref_s", c.get("ref_s", 0.0))
			_add(acc, cnt, "wear_km", c.get("wear_km", 0.0))
			_add(acc, cnt, "fuel_km", c.get("fuel_km", 0.0))
			_add(acc, cnt, "tl", c.get("tl", 0.0))
			_add(acc, cnt, "kmh_r", c.get("kmh", 0.0))
			_add(acc, cnt, "minutes", day["race"].get("minutes", 0.0))
			visits += 1
		if quali_ok and day["quali"]["classes"].has(cls):
			var q: Dictionary = day["quali"]["classes"][cls]
			_add(acc, cnt, "best_s", q.get("best_s", 0.0))
			_add(acc, cnt, "kmh", q.get("kmh", 0.0))
			_add(acc, cnt, "top", q.get("top", 0.0))
			for k in ["s1", "s2", "s3"]:
				if q.has(k):
					_add(acc, cnt, k, q[k])
	if acc.is_empty():
		return {}
	var out := {"visits": visits, "length": length}
	for k in acc:
		out[k] = acc[k] / cnt[k]
	return out


static func _add(acc: Dictionary, cnt: Dictionary, key: String, v: float) -> void:
	if v <= 0.0:
		return
	acc[key] = acc.get(key, 0.0) + v
	cnt[key] = cnt.get(key, 0) + 1


# What the lap-time model needs to know about a track:
# {"ref_s", "minutes", "top_z", "wear_z", "fuel_z", "known_race", "course"}
# before / quali_day work as in _course_stats (use them to replay history; leave "" for a live forecast).
func track_info(course: String, cls: String, before := "", quali_day := "") -> Dictionary:
	var t := _course_stats(course, cls, before, quali_day)
	var out := {"course": course, "ref_s": 0.0, "minutes": DEFAULT_MINUTES,
		"top_z": 0.0, "wear_z": 0.0, "fuel_z": 0.0, "known_race": false}
	if t.is_empty():
		out["ref_s"] = DEFAULT_LAP_S
		return out
	if t.has("ref_s"):
		out["ref_s"] = t["ref_s"]
		out["known_race"] = true
	elif t.has("best_s"):
		out["ref_s"] = t["best_s"] * RACE_QUALI_RATIO
	else:
		out["ref_s"] = DEFAULT_LAP_S
	if t.has("minutes"):
		out["minutes"] = roundi(t["minutes"])
	else:
		out["minutes"] = _last_minutes()
	# z-scores against every track seen so far (needs a few tracks to mean anything)
	var norms := _norms(cls, before, quali_day)
	for pair in [["top", "top_z"], ["wear_km", "wear_z"], ["fuel_km", "fuel_z"]]:
		var key: String = pair[0]
		if t.has(key) and norms.has(key):
			out[pair[1]] = (t[key] - norms[key][0]) / norms[key][1]
	return out


func _last_minutes() -> int:
	for i in range(days.size() - 1, -1, -1):
		var m: int = int(days[i]["race"].get("minutes", 0))
		if m > 0:
			return m
	return DEFAULT_MINUTES


# {"top": [mean, sd], "wear_km": [...], "fuel_km": [...]} across courses
func _norms(cls: String, before: String, quali_day: String) -> Dictionary:
	var per_key := {"top": [], "wear_km": [], "fuel_km": []}
	for course in courses():
		var t := _course_stats(course, cls, before, quali_day)
		for k in per_key:
			if t.has(k):
				per_key[k].append(t[k])
	var out := {}
	for k in per_key:
		var a: Array = per_key[k]
		if a.size() < MIN_TRACKS_FOR_Z:
			continue
		var mean := 0.0
		for v in a:
			mean += v
		mean /= a.size()
		var sq := 0.0
		for v in a:
			sq += (v - mean) * (v - mean)
		var sd := sqrt(sq / a.size())
		if sd > 1e-9:
			out[k] = [mean, sd]
	return out
