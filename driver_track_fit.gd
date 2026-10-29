class_name DriverTrackFit
extends RefCounted
## How a driver's pace changes with the character of the track, from their league results
## (race pace and quali pace vs the class median, as stored by Fingerprint / Profiles) and the
## track characteristics (TrackGrades). Needs the autoload "Profiles" and track_grades.gd.
##
## Everything is relative to the driver's OWN average, so a fast driver is not "good everywhere":
## the question is where they are quicker or slower than they usually are.
##
## Tendencies: for each characteristic, the slope of (pace vs own average) against the track's
## z-score in that characteristic (0 = average track of the class, +1 = one standard deviation
## above, about a grade 4), for race and quali separately and then combined (weighted by their
## uncertainty), so every race weekend counts twice. The slope is pulled towards 0 (ridge, LAMBDA).
## The race-to-race noise behind the uncertainty is measured once per class over all drivers:
## a driver's own handful of races cannot estimate it.
##
## Verdicts (combined effect / its uncertainty): >= CONFIDENT "quicker" / "slower", >= EARLY
## "early sign". Simulated on the GT3 tracks with seasons of 6 races, a real 0.4% tendency shows
## as an early sign after one season about 7 times in 10 and as confident after two seasons about
## 9 times in 10; a driver with no real tendency gets a false early sign about 1 time in 5 and a
## false confident claim about 1 time in 20.
## Characteristics that move together over the driver's tracks (|correlation| >= LINK_CORR) are
## not separate findings: only the strongest is the tendency, the others say "goes with ...".

const LAMBDA := 4.0        # shrinkage, in z^2 units: about four sessions' worth of spread before half weight
const MIN_RACES := 3       # sessions needed before a tendency is estimated
const MIN_TRACKS := 2      # ... at this many different tracks
const MIN_COURSES := 3     # tracks with a value needed to define "average" for a characteristic
const SIGMA_FLOOR := 0.3   # % pace: noise assumed at least this big
const CONFIDENT := 2.0     # |effect| / uncertainty for "quicker" / "slower"
const EARLY := 1.5         # ... for "early sign"
const LINK_CORR := 0.5     # characteristics this correlated over the driver's tracks are linked (with few tracks, above this they cannot be told apart)
const SESSIONS := [["race", "r", "pace_rel", "wet_r"], ["quali", "q", "rel", "wet_q"]]
# Sessions with at least this share of laps on wet tyres are left out: the track characteristics
# describe the dry track.
const WET_SHARE := 0.2
const OWN_WEIGHT := 10.0   # sessions' worth of weight the class noise keeps; with more sessions the driver's own scatter takes over
const STANDOUT := 2.0      # a track's gap / its uncertainty to be called a strong or weak spot
const MIN_PAIRS := 6       # tracks with both a race and a quali needed for the consistency verdict
const DEPENDENT := 1.65    # Fisher z of the race-quali agreement for "track-dependent"
const LEANING := 1.28      # ... for an early sign of it (about 1 all-rounder in 10 gets it by chance)
const LEAN_SPOT := 1.5     # a track's gap / its uncertainty to be listed as leaning strong or weak


# {"tracks": per-track rows, "tendencies": per-characteristic rows, "n": {"race", "quali"}}
# before: only sessions before this date ("YYYY_MM_DD"), so the predictor's backtest never peeks.
# values / class_sig: precomputed TrackGrades.collect(cls) and class noise, to save time when the
# predictor fits many drivers. light: skip the per-track stand-out grades (display only).
static func fit(driver_name: String, cls: String, before := "", values := {}, class_sig := {},
		light := false) -> Dictionary:
	var recs: Array = []
	for rec in Profiles.hist.get("%s|%s" % [cls, driver_name], []):
		if before == "" or str(rec.get("date", "")) < before:
			recs.append(rec)
	var pts := {"race": [], "quali": []}   # [{"course", "y"}], y = pace minus own average (negative = quicker)
	var wet := {"race": 0, "quali": 0}     # wet sessions left out
	for s in SESSIONS:
		var vals := []
		for rec in recs:
			var e: Dictionary = rec.get(s[1], {})
			if e.has(s[2]) and str(rec.get("course", "")) != "":
				if float(rec.get(s[3], 0.0)) >= WET_SHARE:
					wet[s[0]] += 1
					continue
				vals.append({"course": str(rec["course"]), "x": float(e[s[2]])})
		var mean := 0.0
		for v in vals:
			mean += v["x"]
		mean /= maxf(vals.size(), 1)
		for v in vals:
			pts[s[0]].append({"course": v["course"], "y": v["x"] - mean})
	var sigma := {}
	var class_sigma := {}
	for s in SESSIONS:
		var cs: float = class_sig[s[0]] if class_sig.has(s[0]) else class_noise(cls, s[1], s[2], s[3], before)
		class_sigma[s[0]] = cs
		sigma[s[0]] = _blend_noise(pts[s[0]], cs)
	var tracks := _tracks(pts, cls, sigma, light)
	return {
		"tracks": tracks,
		"tendencies": _tendencies(pts, cls, sigma, values),
		"consistency": _consistency(tracks),
		"noise": sigma,
		"class_noise": class_sigma,
		"wet_left_out": wet,
		"n": {"race": pts["race"].size(), "quali": pts["quali"].size()},
	}


# The driver's own session-to-session scatter, blended with the class figure: with few sessions
# it is mostly the class noise (one driver's handful of races cannot measure it), with many it is
# mostly their own. Consistent regulars then get uncertainties that match how they really drive.
# Simulated (13 tracks, 34 sessions, a consistent driver): a real 0.2% tendency is called
# confident 94% of the time instead of 61%, at about 1 false confident claim per 100 drivers.
static func _blend_noise(points: Array, class_sigma: float) -> float:
	var n := points.size()
	if n < 2:
		return class_sigma
	var ss := 0.0
	for p in points:
		ss += float(p["y"]) * float(p["y"])   # y is already relative to the driver's own average
	return maxf(sqrt((ss + OWN_WEIGHT * class_sigma * class_sigma) / (n - 1 + OWN_WEIGHT)), SIGMA_FLOOR)


# One row per track: sessions, average pace vs own average, and the track's stand-out grades
static func _tracks(pts: Dictionary, cls: String, sigma: Dictionary, light := false) -> Array:
	var acc := {}   # course -> {"race": [y], "quali": [y]}
	for sess in pts:
		for p in pts[sess]:
			if not acc.has(p["course"]):
				acc[p["course"]] = {"race": [], "quali": []}
			acc[p["course"]][sess].append(p["y"])
	var out := []
	for course in acc:
		var a: Dictionary = acc[course]
		var standout := PackedStringArray()
		if not light:
			for g in TrackGrades.grade(course, cls):
				if int(g["grade"]) >= 4 or (int(g["grade"]) == 1):
					standout.append("%s %d" % [g["name"], int(g["grade"])])
		# race and quali combined, weighted by how noisy each session type is
		var sessions := []   # [gap, variance] per session
		for sess in ["race", "quali"]:
			for y in a[sess]:
				sessions.append([float(y), pow(float(sigma[sess]), 2.0)])
		var z := _gap_z(sessions)
		# a spot must survive losing its most extreme session, so one wrecked race (damage, an
		# incident) cannot make a track look strong or weak on its own
		var z_rest := 0.0
		if sessions.size() >= 2:
			var worst := 0
			for i in sessions.size():
				if absf(sessions[i][0]) / sqrt(sessions[i][1]) > absf(sessions[worst][0]) / sqrt(sessions[worst][1]):
					worst = i
			var rest := sessions.duplicate()
			rest.remove_at(worst)
			z_rest = _gap_z(rest)
		var flag := ""
		if z <= -STANDOUT and z_rest <= -LEAN_SPOT:
			flag = "strong spot"
		elif z >= STANDOUT and z_rest >= LEAN_SPOT:
			flag = "weak spot"
		out.append({
			"course": course,
			"races": a["race"].size(),
			"quali": a["quali"].size(),
			"race_y": _mean(a["race"]) if not a["race"].is_empty() else null,
			"quali_y": _mean(a["quali"]) if not a["quali"].is_empty() else null,
			"z": z,
			"flag": flag,
			"standout": ", ".join(standout),
		})
	# best tracks first (race, else quali)
	out.sort_custom(func(x, y): return _key(x) < _key(y))
	return out


# Does the track matter for this driver? Race and quali are separate sessions with separate luck,
# so if a driver really is better at some tracks, their race and quali gaps track by track agree.
# If the gaps are just luck, they don't. {"verdict", "r", "pairs", "strong": [courses], "weak": [...]}
static func _consistency(tracks: Array) -> Dictionary:
	var rs := []
	var qs := []
	var strong := []
	var weak := []
	var lean_strong := []   # closer calls: shown so a track-dependent verdict can point somewhere
	var lean_weak := []
	for t in tracks:
		if t["race_y"] != null and t["quali_y"] != null:
			rs.append(float(t["race_y"]))
			qs.append(float(t["quali_y"]))
		if t["flag"] == "strong spot":
			strong.append(t["course"])
		elif t["flag"] == "weak spot":
			weak.append(t["course"])
		elif float(t["z"]) <= -LEAN_SPOT:
			lean_strong.append(t["course"])
		elif float(t["z"]) >= LEAN_SPOT:
			lean_weak.append(t["course"])
	var out := {"pairs": rs.size(), "strong": strong, "weak": weak, "lean_strong": lean_strong,
		"lean_weak": lean_weak, "verdict": "not enough tracks yet"}
	if rs.size() < MIN_PAIRS:
		return out
	var r := clampf(_corr(rs, qs), -0.999, 0.999)
	var fz := 0.5 * log((1.0 + r) / (1.0 - r)) * sqrt(rs.size() - 3.0)
	out["r"] = r
	out["fz"] = fz
	if fz >= DEPENDENT:
		out["verdict"] = "track-dependent"
	elif fz >= LEANING:
		out["verdict"] = "early sign: track-dependent"
	else:
		out["verdict"] = "all-rounder"
	return out


# Combined gap of several sessions divided by its uncertainty (inverse-variance weighted)
static func _gap_z(sessions: Array) -> float:
	var w := 0.0
	var wy := 0.0
	for s in sessions:
		w += 1.0 / float(s[1])
		wy += float(s[0]) / float(s[1])
	if w == 0.0:
		return 0.0
	return wy / w * sqrt(w)


static func _key(row: Dictionary) -> float:
	if row["race_y"] != null:
		return float(row["race_y"])
	if row["quali_y"] != null:
		return float(row["quali_y"])
	return 0.0


# One row per characteristic: {"name", "race", "quali" (each _slope result), "effect", "se",
# "ratio", "n", "tracks", "verdict"}. effect / se are the combined race + quali tendency.
static func _tendencies(pts: Dictionary, cls: String, sigma: Dictionary, values := {}) -> Array:
	if values.is_empty():
		values = TrackGrades.collect(cls)
	var out := []
	for t in TrackGrades.TRAITS:
		var key: String = t["key"]
		# class average and spread of this characteristic over all tracks that have it
		var xs := []
		for c in values:
			if values[c].has(key):
				xs.append(float(values[c][key]))
		var row := {"name": t["name"], "key": key, "src": t["src"], "race": {}, "quali": {},
			"verdict": "no track data", "zvec": []}
		if xs.size() >= MIN_COURSES:
			var m := _mean(xs)
			var sd := 0.0
			for x in xs:
				sd += (x - m) * (x - m)
			sd = sqrt(sd / (xs.size() - 1))
			row["mean"] = m   # so a track's z-score can be worked out (the predictor needs it)
			row["sd"] = sd
			if sd > 0.0:
				var all_tracks := {}
				for sess in ["race", "quali"]:
					var zs := []
					var ys := []
					var seen := {}
					for p in pts[sess]:
						if values.has(p["course"]) and values[p["course"]].has(key):
							zs.append((float(values[p["course"]][key]) - m) / sd)
							ys.append(p["y"])
							seen[p["course"]] = true
							all_tracks[p["course"]] = true
					row[sess] = _slope(zs, ys, seen.size(), float(sigma[sess]))
					row["zvec"].append_array(zs)
				_combine(row, all_tracks.size())
		out.append(row)
	_link(out)
	for r in out:
		r.erase("zvec")
	return out


# Inverse-variance average of the race and quali tendencies
static func _combine(row: Dictionary, tracks: int) -> void:
	var w := 0.0
	var wb := 0.0
	var n := 0
	for sess in ["race", "quali"]:
		var e: Dictionary = row[sess]
		n += int(e.get("n", 0))
		if e.has("effect"):
			var wi := 1.0 / (float(e["se"]) * float(e["se"]))
			w += wi
			wb += wi * float(e["effect"])
	row["n"] = n
	row["tracks"] = tracks
	if w == 0.0:
		row["verdict"] = "not enough data"
		return
	row["effect"] = wb / w
	row["se"] = 1.0 / sqrt(w)
	row["ratio"] = absf(row["effect"]) / row["se"]
	row["verdict"] = "no clear effect"


# Verdicts, strongest first; a flagged characteristic that moves with a stronger one is linked to it
static func _link(rows: Array) -> void:
	var flagged := []
	for r in rows:
		if r.has("ratio") and float(r["ratio"]) >= EARLY:
			flagged.append(r)
	flagged.sort_custom(func(a, b): return a["ratio"] > b["ratio"])
	var kept := []
	for r in flagged:
		var leader := ""
		for k in kept:
			if absf(_corr(r["zvec"], k["zvec"])) >= LINK_CORR:
				leader = k["name"]
				break
		if leader != "":
			r["verdict"] = "goes with " + leader
			continue
		kept.append(r)
		var word := "quicker" if float(r["effect"]) < 0.0 else "slower"
		r["verdict"] = word if float(r["ratio"]) >= CONFIDENT else "early sign: " + word


static func _corr(a: Array, b: Array) -> float:
	if a.size() != b.size() or a.size() < 3:
		return 0.0
	var am := _mean(a)
	var bm := _mean(b)
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in a.size():
		sab += (a[i] - am) * (b[i] - bm)
		saa += (a[i] - am) * (a[i] - am)
		sbb += (b[i] - bm) * (b[i] - bm)
	if saa == 0.0 or sbb == 0.0:
		return 0.0
	return sab / sqrt(saa * sbb)


# Shrunk slope of ys on zs: {"effect": % pace at +1 z (negative = quicker), "se", "n", "tracks"},
# without "effect" when there are too few sessions / tracks.
static func _slope(zs: Array, ys: Array, tracks: int, sigma: float) -> Dictionary:
	var n := zs.size()
	if n < MIN_RACES or tracks < MIN_TRACKS:
		return {"n": n, "tracks": tracks}
	var zm := _mean(zs)
	var ym := _mean(ys)
	var szz := 0.0
	var szy := 0.0
	for i in n:
		szz += (zs[i] - zm) * (zs[i] - zm)
		szy += (zs[i] - zm) * (ys[i] - ym)
	var b := szy / (szz + LAMBDA)
	return {"effect": b, "se": sigma / sqrt(szz + LAMBDA), "n": n, "tracks": tracks}


# Typical race-to-race scatter of a driver's pace around their own average, in %, over all
# drivers of the class with at least two sessions (degrees of freedom corrected).
static func class_noise(cls: String, sess_key: String, field: String, wet_key := "", before := "") -> float:
	var ss := 0.0
	var dof := 0
	for key in Profiles.hist:
		if not str(key).begins_with(cls + "|"):
			continue
		var xs := []
		for rec in Profiles.hist[key]:
			var e: Dictionary = rec.get(sess_key, {})
			if wet_key != "" and float(rec.get(wet_key, 0.0)) >= WET_SHARE:
				continue
			if before != "" and str(rec.get("date", "")) >= before:
				continue
			if e.has(field):
				xs.append(float(e[field]))
		if xs.size() < 2:
			continue
		var m := _mean(xs)
		for x in xs:
			ss += (x - m) * (x - m)
		dof += xs.size() - 1
	if dof == 0:
		return 1.0   # nothing to measure yet: assume 1% so nothing gets flagged
	return maxf(sqrt(ss / dof), SIGMA_FLOOR)


static func _mean(a: Array) -> float:
	var s := 0.0
	for x in a:
		s += float(x)
	return s / maxf(a.size(), 1)
