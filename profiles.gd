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
var hist := {}     # "cls|name" -> [{"date", "course", "r": {...}, "q": {...}}], chronological
var revision := 0  # goes up on every rebuild, so caches elsewhere know the data changed


func _ready() -> void:
	rebuild()


# Rebuilds only if the ratings data changed since the last build (screens call this on every
# visit; a full rebuild takes ~0.15 s on four seasons of results).
func ensure() -> void:
	if _built_for != Elo.revision or _built_settings != LeagueSettings.revision:
		rebuild()


var _built_for := -1        # Elo.revision the current build was made from
var _built_settings := -1   # LeagueSettings.revision (race rules scale fuel and tyre figures)

# Share of the tread a set of tyres can use before a change is forced: in league races tyres were
# changed with about 80% left and at only 4-28% of stops, so wear rarely forces one; half the
# tread is the assumption for when it would.
const TYRE_USABLE := 50.0


func rebuild() -> void:
	_built_for = Elo.revision
	_built_settings = LeagueSettings.revision
	revision += 1
	days.clear()
	hist.clear()
	if not DirAccess.dir_exists_absolute("user://events"):
		return   # nothing imported yet (first start)
	var by_date := {}
	# events in the order they happened, so a quali is met before its race
	var drafts := []
	for f in DirAccess.get_files_at("user://events"):
		if not f.ends_with(".json"):
			continue
		var loaded = JSON.parse_string(FileAccess.get_file_as_string("user://events/" + f))
		if loaded is Dictionary and loaded.has("fp") and loaded.has("file"):
			drafts.append(loaded)
	drafts.sort_custom(func(a, b):
		var ta := Elo.event_time(a)
		var tb := Elo.event_time(b)
		if ta != tb:
			return ta < tb
		if Elo.session_rank(a) != Elo.session_rank(b):
			return Elo.session_rank(a) < Elo.session_rank(b)
		return str(a["file"]) < str(b["file"]))
	for draft in drafts:
		var fp: Dictionary = draft["fp"]
		if fp.is_empty() or not fp.has("track"):
			continue
		# event date from the file name, or from the XML itself when the name has none
		var date: String = Elo.event_date(draft)
		if date == "":
			date = str(draft["file"]).left(10)
		var training: bool = draft.get("kind", "league") == "training"
		var course: String = fp["track"].get("course", "")
		# a league event merges its quali and race files by date and track; a second event on the
		# same day and track (e.g. sprint and endurance) gets its own slot; training stays on its own
		var day_key: String = "%s|T|%s" % [date, draft["file"]]
		if not training:
			var base := "%s|%s" % [date, course]
			day_key = base
			var n := 2
			# a race file (which may carry its own quali) needs a slot without a race yet;
			# a quali-only file needs a slot without a quali yet
			while by_date.has(day_key) and ((fp.has("race") and not by_date[day_key]["race"].is_empty())
					or (not fp.has("race") and fp.has("quali") and not by_date[day_key]["quali"].is_empty())):
				day_key = "%s|%d" % [base, n]
				n += 1
		if not by_date.has(day_key):
			by_date[day_key] = {"date": date, "course": "", "track": {}, "race": {}, "quali": {}, "training": training}
		var day: Dictionary = by_date[day_key]
		day["track"] = fp["track"]
		day["course"] = fp["track"].get("course", "")
		if fp.has("race"):
			day["race"] = _resolved(fp["race"])
			day["series"] = Elo.series_code(str(draft["file"]))   # "sc", "mc"... ("" if the name has none)
			day["season"] = Elo.season_number(str(draft["file"]))
			# fuel, energy and tyre figures back to x1, so races run under different multipliers
			# (Sprint x1, Multiclass x2...) compare; the rules are set in Settings > Race rules
			var rules := LeagueSettings.rules_for(day["series"], day["season"])
			day["rules"] = rules
			for c in day["race"].get("classes", {}):
				var cs: Dictionary = day["race"]["classes"][c]
				for k in ["fuel_km", "ve_km"]:
					if float(cs.get(k, 0.0)) > 0.0:
						cs[k] = float(cs[k]) / maxf(rules["fuel"], 0.01)
				if float(cs.get("wear_km", 0.0)) > 0.0:
					cs["wear_km"] = float(cs["wear_km"]) / maxf(rules["tyre"], 0.01)
		if fp.has("quali"):
			day["quali"] = _resolved(fp["quali"])
	var dates := by_date.keys()
	dates.sort()
	for d in dates:
		days.append(by_date[d])
	for day in days:
		if day.get("training", false):
			continue   # training data never creates driver history
		var recs := {}
		for nm in day["race"].get("drivers", {}):
			var e: Dictionary = day["race"]["drivers"][nm]
			var key: String = "%s|%s" % [e["cls"], nm]
			recs[key] = {"date": day["date"], "course": day["course"], "r": e, "q": {},
				"wet_r": float(day["race"].get("wet", 0.0)), "wet_q": float(day["quali"].get("wet", 0.0))}
		for nm in day["quali"].get("drivers", {}):
			var e: Dictionary = day["quali"]["drivers"][nm]
			var key: String = "%s|%s" % [e["cls"], nm]
			if not recs.has(key):
				recs[key] = {"date": day["date"], "course": day["course"], "r": {}, "q": {},
					"wet_r": float(day["race"].get("wet", 0.0)), "wet_q": float(day["quali"].get("wet", 0.0))}
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
		if day.get("training", false) or (before != "" and day["date"] >= before):
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
	for day in days:   # classes that only appear in training data still get car and track tables
		for sec in ["race", "quali"]:
			for c in day[sec].get("classes", {}):
				seen[c] = true
	var out := seen.keys()
	out.sort()
	return out


# ---------- Cars ----------

# One row per car model: how it compares with the class median (all drivers, all events).
# Car models spelled slightly differently between game versions ("Genesis GMR-001" and
# "Genesis GMR001") count as one; the first spelling seen is shown.
func car_rows(cls: String) -> Array:
	var acc := {}
	var shown := {}   # car key -> name shown
	for day in days:
		for nm in day["race"].get("drivers", {}):
			var r: Dictionary = day["race"]["drivers"][nm]
			if r["cls"] != cls:
				continue
			var ck := DriverGrades.car_key(str(r["car"]))
			if not shown.has(ck):
				shown[ck] = r["car"]
			var a: Dictionary = acc.get(ck, {"n": 0, "pace": 0.0, "top": 0.0, "nt": 0, "fuel": 0.0, "nf": 0, "wear": 0.0, "nw": 0, "q": 0.0, "nq": 0})
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
			acc[ck] = a
		for nm in day["quali"].get("drivers", {}):
			var q: Dictionary = day["quali"]["drivers"][nm]
			if q["cls"] != cls:
				continue
			var ck2 := DriverGrades.car_key(str(q["car"]))
			if not shown.has(ck2):
				shown[ck2] = q["car"]
			var a2: Dictionary = acc.get(ck2, {"n": 0, "pace": 0.0, "top": 0.0, "nt": 0, "fuel": 0.0, "nf": 0, "wear": 0.0, "nw": 0, "q": 0.0, "nq": 0})
			a2["q"] += q.get("rel", 0.0)
			a2["nq"] += 1
			acc[ck2] = a2
	var rows := []
	for car in acc:
		var a: Dictionary = acc[car]
		rows.append({
			"car": shown[car], "n": a["n"],
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
			_add(acc, cnt, "ve_km", c.get("ve_km", 0.0))
			_add(acc, cnt, "tl", c.get("tl", 0.0))
			_add(acc, cnt, "kmh_r", c.get("kmh", 0.0))
			_add(acc, cnt, "minutes", day["race"].get("minutes", 0.0))
			_add(acc, cnt, "pit_loss", c.get("pit_loss", 0.0))
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
# {"ref_s", "minutes", "top_z", "wear_z", "fuel_z", "known_race", "course", and when known
# "pit_loss" (s per routine stop) and "tank_laps" (laps on a full tank)}
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
	# pit stops: typical loss per routine stop, and how many laps a full tank lasts
	if t.has("pit_loss"):
		out["pit_loss"] = t["pit_loss"]
	# at x1: laps on a full tank (or a full energy allowance, which usually runs out first) and
	# laps before the tyres are worn far enough to be changed
	var energy_km := maxf(float(t.get("fuel_km", 0.0)), float(t.get("ve_km", 0.0)))
	if energy_km > 0.0 and float(t.get("length", 0.0)) > 0.0:
		out["tank_laps"] = 100.0 / (energy_km * float(t["length"]) / 1000.0)
		out["energy_limit"] = "virtual energy" if float(t.get("ve_km", 0.0)) > float(t.get("fuel_km", 0.0)) else "fuel"
	if float(t.get("wear_km", 0.0)) > 0.0 and float(t.get("length", 0.0)) > 0.0:
		out["tyre_laps"] = TYRE_USABLE / (float(t["wear_km"]) * float(t["length"]) / 1000.0)
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
