class_name TrackGrades
extends RefCounted
## Grades a track from 1 to 5 on ten characteristics, separately for each class.
## Seven come from the telemetry profile (MotecProfile "traits"), two from the league results
## (the "Profiles" autoload). A grade ranks the track against the other tracks known for the
## same class; with fewer than MIN_RANKED tracks it uses the fixed scale in CUTS instead.
## 5 always means "the most": most time at full throttle, hardest braking, thirstiest, etc.

const MIN_RANKED := 5
# Near-ties share a grade: a track joins a group when its value is within TIE_RANGE x (spread
# of the class) or TIE_VALUE x (typical value), whichever is larger, of the group's FIRST value.
# Groups do not chain (A~B and B~C does not put A with C), so with many tracks the grades still
# spread over 1 to 5.
const TIE_RANGE := 0.05
const TIE_VALUE := 0.01

# key: the raw value that is graded. cuts: fixed-scale limits for grades 2, 3, 4 and 5, set
# from LMP3 and GT3 laps of Bahrain, Sebring, Spa, Paul Ricard and COTA. alt / alt_cuts: what
# to grade when a profile lacks the key (e.g. an export without tyre wear channels).
# grade limits, per driver per 10 laps (league seasons 1-6, about the quintiles over the tracks
# of GT3, Hyper and LMP3)
const CUTS_INCIDENTS := [0.5, 0.65, 0.8, 0.95]   # contacts
const CUTS_WARNINGS := [0.3, 0.6, 0.9, 1.2]      # track-limit warnings
const TRAITS := [
	{"id": "top", "unit": "% of lap time", "name": "Full throttle", "src": "tel", "key": "full_throttle_pct", "cuts": [64.0, 67.0, 69.5, 71.0],
		"tip": "Share of the lap time at full throttle. High = power and low drag pay off (and the engine works hardest). Low = more braking, part-throttle and coasting."},
	{"id": "brake", "unit": "km/h per km", "name": "Braking", "src": "tel", "key": "scrub_kmh_km", "cuts": [130.0, 145.0, 160.0, 175.0],
		"tip": "Speed taken off in braking zones, per km of track. High = many and/or big stops."},
	{"id": "hs", "unit": "% of lap time", "name": "High-speed corners", "src": "tel", "key": "hs_corner_pct", "cuts": [12.0, 15.0, 18.0, 21.0],
		"tip": "Share of the lap time above 60% of top speed with at least 1 G of lateral load. High = downforce and commitment."},
	{"id": "traction", "unit": "per km", "name": "Traction", "src": "tel", "key": "slow_corners_km", "cuts": [0.75, 1.0, 1.25, 1.4],
		"tip": "Slow corners and hairpins per km. High = exits and traction decide the lap."},
	{"id": "density", "unit": "per km", "name": "Corner density", "src": "tel", "key": "corners_km", "cuts": [1.95, 2.1, 2.25, 2.4],
		"tip": "Corners per km (flat-out kinks not counted). High = busy and technical, low = long gaps between corners."},
	{"id": "tyres", "unit": "% wear per km", "name": "Tyre stress", "src": "tel", "key": "tyre_wear_km", "cuts": [0.08, 0.11, 0.15, 0.20],
		"alt": "combined_g_avg", "alt_cuts": [0.90, 0.97, 1.03, 1.10], "alt_unit": "G on average",
		"tip": "Tyre wear per km on the telemetry lap (average of the four tyres), from the game's own wear model. High = hard on tyres. Without wear channels: average combined G over the lap."},
	{"id": "fuel", "unit": "L per minute", "name": "Fuel use", "src": "tel", "key": "fuel_l_min", "cuts": [1.45, 1.6, 1.75, 1.9],
		"tip": "Litres per minute of driving, which is what decides pit stops in a timed race."},
	{"id": "bumps", "unit": "G (typical 50 m)", "name": "Bumpiness", "src": "tel", "key": "bump_g", "cuts": [0.065, 0.085, 0.105, 0.13],
		"tip": "Fast up-and-down motion (vertical G) where the car is going straight, so kerbs do not count: the typical 50 m section, so one big hit does not decide it. High = bumpy surface."},
	# graded the other way round ("invert"): fewer passes = harder to overtake = higher grade.
	# "fit_name" is what the driver track-fit report calls it, as that works on the raw pass count.
	{"id": "overtake", "unit": "passes per car per 10 laps", "name": "Overtaking difficulty", "src": "res", "key": "passes_10", "cuts": [0.6, 1.0, 1.5, 2.2],
		"invert": true, "fit_name": "Overtaking (many passes)",
		"tip": "How hard it is to pass, from league races: on-track passes, i.e. two cars of the class swapping places between the end of one lap and the next. Passes on the opening lap and swaps caused by pit stops are not counted. Per car, per 10 laps. High grade = few passes, hard to overtake; low grade = lots of overtaking."},
	{"id": "incidents", "unit": "per driver per 10 laps", "name": "Incident risk", "src": "res", "key": "incidents_10", "cuts": CUTS_INCIDENTS,
		"tip": "From league races: contacts with other cars per driver per 10 laps. (Track limits are graded on their own.)"},
	{"id": "limits", "unit": "warnings per driver per 10 laps", "name": "Track limits", "src": "res", "key": "warnings_10", "cuts": CUTS_WARNINGS,
		"tip": "From league races: track-limit warnings per driver per 10 laps (the events the game warned for or invalidated the lap for; those it took no action on are not counted). High = easy to get warned here."},
]


# One row per characteristic for this track and class:
# {"id", "name", "tip", "grade" (0 = no data), "value", "detail", "basis"}
# estimate: when the class has no league race at the track, the results grades (overtaking,
# incidents) come from its training races there, else from tendencies (see _estimate); such rows
# have "estimated": true. Only for display (the track card): analyses use real races only.
static func grade(course: String, cls: String, estimate := false) -> Array:
	var values := collect(cls)   # course -> {key: value}
	var mine: Dictionary = values.get(course, {})
	var out := []
	for t in TRAITS:
		var key: String = t["key"]
		var cuts: Array = t["cuts"]
		var unit: String = t["unit"]
		if not mine.has(key) and t.has("alt") and mine.has(t["alt"]):
			key = t["alt"]
			cuts = t["alt_cuts"]
			unit = t["alt_unit"]
		var row := {"id": t["id"], "name": t["name"], "tip": t["tip"], "grade": 0,
			"value": "-", "detail": _detail(t["id"], mine), "basis": "no data"}
		if mine.has(key):
			var pool := {}   # course -> value
			for c in values:
				if values[c].has(key):
					pool[c] = float(values[c][key])
			var x := float(mine[key])
			row["value"] = "%s %s" % [_fmt(x), unit]
			if pool.size() >= MIN_RANKED:
				var r := _ranked(course, pool)
				row["grade"] = r["grade"]
				row["basis"] = "ranked among %d tracks" % pool.size()
				if not r["tied"].is_empty():
					row["basis"] += ", tied with " + ", ".join(PackedStringArray(r["tied"]))
			else:
				row["grade"] = _fixed(x, cuts)
				row["basis"] = "fixed scale (%d track%s known)" % [pool.size(), "" if pool.size() == 1 else "s"]
			if t.get("invert", false) and int(row["grade"]) > 0:
				row["grade"] = 6 - int(row["grade"])
		elif estimate and t["src"] == "res":
			var est := _estimate(course, cls, t, values)
			if not est.is_empty():
				var pool := {}
				for c in values:
					if values[c].has(key):
						pool[c] = float(values[c][key])
				var x := float(est["value"])
				pool[course] = x
				row["value"] = "%s %s (estimate)" % [_fmt(x), unit]
				row["grade"] = _ranked(course, pool)["grade"] if pool.size() >= MIN_RANKED else _fixed(x, cuts)
				if t.get("invert", false):
					row["grade"] = 6 - int(row["grade"])
				row["basis"] = est["basis"]
				row["estimated"] = true
		out.append(row)
	return out


# A results value (passes or incidents per 10 laps) for a class that has no league race at the
# track. First its training races there. Otherwise a self-checking estimate: five methods are
# tried (see _predict_all), each scored by predicting every track the class HAS raced while that
# track is left out, and the one with the smallest typical error for this class and grade is used
# (among those that have the inputs they need at this track). Nothing qualifies: {} (no grade).
static func _estimate(course: String, cls: String, t: Dictionary, values: Dictionary) -> Dictionary:
	var key: String = t["key"]
	var tr: Dictionary = _training_results(cls)
	if tr.has(course) and tr[course].has(key):
		var n := int(tr[course].get("races", tr[course].get("incident_races", 1)))
		return {"value": float(tr[course][key]), "basis": "from %d training race%s here" % [n, "" if n == 1 else "s"]}
	var est := _estimator(cls, key)
	if est["rows"].is_empty():
		return {}
	var target := _row(course, key, values, est["oc"], false)
	var preds := _predict_all(est["rows"], target, est)
	var best := ""
	for m in preds:
		if est["scores"].has(m) and (best == "" or float(est["scores"][m]["err"]) < float(est["scores"][best]["err"])):
			best = m
	if best == "":
		return {}
	var sc: Dictionary = est["scores"][best]
	var pct := roundi((exp(float(sc["err"])) - 1.0) * 100.0)
	var oc_name := LeagueSettings.label(str(est["oc"]))
	var label := ""
	match best:
		"scaled":
			label = "%s here x%.2f" % [oc_name, float(preds["_ratio"])]
		"ridge_other":
			label = "this track's 8 traits + %s here" % oc_name
		"avg":
			label = "the average of %s here x%.2f and this track's 8 traits" % [oc_name, float(preds["_ratio"])]
		"ridge":
			label = "this track's 8 traits"
		"single":
			label = "its %s here" % str(preds["_single"]).to_lower()
		"mean":
			label = "the %s average" % LeagueSettings.label(cls)
	return {"value": maxf(0.0, exp(float(preds[best])) - 0.1),
		"basis": "estimated from %s (typically within ±%d%%, checked on %d tracks)" % [label, pct, int(sc["n"])],
		"method": best}


const _EST_MIN_SCORED := 5     # a method must have predicted at least this many left-out tracks
const _LAMBDAS := [1.0, 3.0, 10.0, 30.0, 100.0]
static var _est_cache := {}    # "cls|key" -> {"stamp", ...}


static func _tel_keys() -> Array:
	return TRAITS.filter(func(x): return x["src"] == "tel").map(func(x): return x["key"])


static func _ly(v: float) -> float:   # passes and incidents are compared on a log scale
	return log(maxf(v, 0.0) + 0.1)


# One track of the class: {"course", "y" (log, or NAN), "x" (8 traits, or empty), "o" (log value
# of the other class there, or NAN)}
static func _row(course: String, key: String, values: Dictionary, oc: String, need_y := true) -> Dictionary:
	var v: Dictionary = values.get(course, {})
	var x := PackedFloat64Array()
	for k in _tel_keys():
		if not v.has(k):
			x = PackedFloat64Array()
			break
		x.append(float(v[k]))
	var o := NAN
	if oc != "":
		var ov: Dictionary = collect(oc).get(course, {})
		if ov.has(key):
			o = _ly(float(ov[key]))
	var y := NAN
	if need_y and v.has(key):
		y = _ly(float(v[key]))
	return {"course": course, "y": y, "x": x, "o": o, "o_raw": exp(o) - 0.1 if not is_nan(o) else NAN}


# Which methods work for this class and grade, and how well: scored once per data change.
static func _estimator(cls: String, key: String) -> Dictionary:
	var stamp := "%d|%d" % [TrackStore.revision, Profiles.revision]
	var ck := cls + "|" + key
	var hit: Dictionary = _est_cache.get(ck, {})
	if hit.get("stamp", "") == stamp:
		return hit
	var values := collect(cls)
	# the other class: the one sharing the most tracks with a value for this grade
	var oc := ""
	var best_shared := 2
	for b in Elo.boards():
		var c2: String = b[0]
		if c2 == cls or b[1] != "race":
			continue
		var ov := collect(c2)
		var shared := 0
		for c in values:
			if values[c].has(key) and ov.has(c) and ov[c].has(key):
				shared += 1
		if shared > best_shared:
			best_shared = shared
			oc = c2
	var rows := []
	for c in values:
		if values[c].has(key):
			rows.append(_row(c, key, values, oc))
	var est := {"stamp": stamp, "oc": oc, "rows": rows, "scores": {}, "lam": 10.0, "lam_o": 10.0}
	est["lam"] = _pick_lambda(rows, false)
	est["lam_o"] = _pick_lambda(rows, true)
	var errs := {}
	for i in rows.size():
		var train := rows.duplicate()
		train.remove_at(i)
		var preds := _predict_all(train, rows[i], est)
		for m in preds:
			if str(m).begins_with("_"):
				continue
			if not errs.has(m):
				errs[m] = []
			errs[m].append(absf(float(preds[m]) - float(rows[i]["y"])))
	for m in errs:
		if errs[m].size() >= _EST_MIN_SCORED:
			est["scores"][m] = {"err": _mean(errs[m]), "n": errs[m].size()}
	_est_cache[ck] = est
	return est


# Predictions (log scale) of every method that has what it needs, from the training tracks:
#  mean: the class average; scaled: the other class here x (class / other class over shared
#  tracks, at least 3); ridge: the 8 telemetry traits (ridge regression); ridge_other: the 8
#  traits plus the other class's value here; avg: the average of scaled and ridge; single: the one
#  trait with the strongest link (at least 6 tracks, |r| >= 0.5).
static func _predict_all(train: Array, target: Dictionary, est: Dictionary) -> Dictionary:
	var out := {}
	var ys := train.map(func(r): return float(r["y"]))
	if ys.size() >= 2:
		out["mean"] = _mean(ys)
	var num := 0.0
	var den := 0.0
	var shared := 0
	for r in train:
		if not is_nan(float(r["o"])):
			num += exp(float(r["y"])) - 0.1
			den += float(r["o_raw"])
			shared += 1
	if shared >= 3 and den > 0.0 and not is_nan(float(target["o"])):
		out["_ratio"] = num / den
		out["scaled"] = _ly(float(target["o_raw"]) * num / den)
	var has_x: bool = not (target["x"] as PackedFloat64Array).is_empty()
	if has_x:
		var tx := train.filter(func(r): return not (r["x"] as PackedFloat64Array).is_empty())
		if tx.size() >= 5:
			var m := _ridge(tx.map(func(r): return r["x"]), tx.map(func(r): return float(r["y"])), float(est["lam"]))
			out["ridge"] = _ridge_at(m, target["x"])
			if out.has("scaled"):
				out["avg"] = (float(out["ridge"]) + float(out["scaled"])) / 2.0
		if not is_nan(float(target["o"])):
			var txo := tx.filter(func(r): return not is_nan(float(r["o"])))
			if txo.size() >= 5:
				var m2 := _ridge(txo.map(func(r): return _with_o(r)), txo.map(func(r): return float(r["y"])), float(est["lam_o"]))
				out["ridge_other"] = _ridge_at(m2, _with_o(target))
		if tx.size() >= 6:
			var keys := _tel_keys()
			var best := {}
			for j in keys.size():
				var fit := _line(tx.map(func(r): return float(r["x"][j])), tx.map(func(r): return float(r["y"])))
				if absf(float(fit["r"])) >= 0.5 and absf(float(fit["r"])) > absf(float(best.get("r", 0.0))):
					best = fit
					best["j"] = j
			if not best.is_empty():
				out["single"] = float(best["a"]) + float(best["b"]) * float(target["x"][int(best["j"])])
				var tname := ""
				for tt in TRAITS:
					if tt["key"] == keys[int(best["j"])]:
						tname = tt["name"]
				out["_single"] = tname
	return out


static func _with_o(r: Dictionary) -> PackedFloat64Array:
	var x: PackedFloat64Array = (r["x"] as PackedFloat64Array).duplicate()
	x.append(float(r["o"]))
	return x


# The ridge penalty that predicts left-out tracks best (once per class and grade).
static func _pick_lambda(rows: Array, with_other: bool) -> float:
	var rr := rows.filter(func(r): return not (r["x"] as PackedFloat64Array).is_empty() and (not with_other or not is_nan(float(r["o"]))))
	if rr.size() < 6:
		return 10.0
	var best_l := 10.0
	var best_e := INF
	for lam in _LAMBDAS:
		var e := 0.0
		for i in rr.size():
			var train := rr.duplicate()
			train.remove_at(i)
			var feats := train.map(func(r): return _with_o(r) if with_other else r["x"])
			var m := _ridge(feats, train.map(func(r): return float(r["y"])), lam)
			e += absf(_ridge_at(m, _with_o(rr[i]) if with_other else rr[i]["x"]) - float(rr[i]["y"]))
		if e < best_e:
			best_e = e
			best_l = lam
	return best_l


# Ridge regression on standardised inputs: {"mu", "sd", "w", "ym"}
static func _ridge(xs: Array, ys: Array, lam: float) -> Dictionary:
	var n := xs.size()
	var d: int = (xs[0] as PackedFloat64Array).size()
	var mu := PackedFloat64Array()
	var sd := PackedFloat64Array()
	mu.resize(d)
	sd.resize(d)
	for j in d:
		var col := xs.map(func(x): return float(x[j]))
		mu[j] = _mean(col)
		var v := 0.0
		for c in col:
			v += (c - mu[j]) * (c - mu[j])
		sd[j] = sqrt(v / n) + 1e-9
	var ym := _mean(ys)
	var a := []          # (Z'Z + lam I) | Z'(y - ym), as rows of an augmented matrix
	for p in d:
		var row := PackedFloat64Array()
		row.resize(d + 1)
		a.append(row)
	for i in n:
		var z := PackedFloat64Array()
		z.resize(d)
		for j in d:
			z[j] = (float(xs[i][j]) - mu[j]) / sd[j]
		var dy := float(ys[i]) - ym
		for p in d:
			var rp: PackedFloat64Array = a[p]
			for q in d:
				rp[q] += z[p] * z[q]
			rp[d] += z[p] * dy
			a[p] = rp
	for p in d:
		var rp: PackedFloat64Array = a[p]
		rp[p] += lam
		a[p] = rp
	return {"mu": mu, "sd": sd, "w": _solve(a, d), "ym": ym}


static func _ridge_at(m: Dictionary, x: PackedFloat64Array) -> float:
	var out := float(m["ym"])
	for j in x.size():
		out += (x[j] - m["mu"][j]) / m["sd"][j] * m["w"][j]
	return out


# Gaussian elimination with partial pivoting on an augmented d x (d+1) matrix.
static func _solve(a: Array, d: int) -> PackedFloat64Array:
	for col in d:
		var piv := col
		for r in range(col + 1, d):
			if absf(a[r][col]) > absf(a[piv][col]):
				piv = r
		var tmp = a[col]
		a[col] = a[piv]
		a[piv] = tmp
		var pr: PackedFloat64Array = a[col]
		if absf(pr[col]) < 1e-12:
			continue
		for r in range(col + 1, d):
			var rr: PackedFloat64Array = a[r]
			var f := rr[col] / pr[col]
			for c in range(col, d + 1):
				rr[c] -= f * pr[c]
			a[r] = rr
	var w := PackedFloat64Array()
	w.resize(d)
	for r in range(d - 1, -1, -1):
		var rr: PackedFloat64Array = a[r]
		var sum := rr[d]
		for c in range(r + 1, d):
			sum -= rr[c] * w[c]
		w[r] = sum / rr[r] if absf(rr[r]) > 1e-12 else 0.0
	return w


# Least-squares line y = a + b x and its correlation r.
static func _line(xs: Array, ys: Array) -> Dictionary:
	var mx := _mean(xs)
	var my := _mean(ys)
	var sxy := 0.0
	var sxx := 0.0
	var syy := 0.0
	for i in xs.size():
		sxy += (xs[i] - mx) * (ys[i] - my)
		sxx += (xs[i] - mx) * (xs[i] - mx)
		syy += (ys[i] - my) * (ys[i] - my)
	if sxx <= 0.0 or syy <= 0.0:
		return {"a": my, "b": 0.0, "r": 0.0, "n": xs.size()}
	var b := sxy / sxx
	return {"a": my - b * mx, "b": b, "r": sxy / sqrt(sxx * syy), "n": xs.size()}


# The same results values from training races only (course -> values), for _estimate.
static var _training_cache := {}   # cls -> {"stamp", "values"}


static func _training_results(cls: String) -> Dictionary:
	var stamp := str(Profiles.revision)
	var hit: Dictionary = _training_cache.get(cls, {})
	if hit.get("stamp", "") == stamp:
		return hit["values"]
	var out := _results(cls, true)
	_training_cache[cls] = {"stamp": stamp, "values": out}
	return out


# course -> raw values for one class, from the stored telemetry profiles and the league results
static var _collect_cache := {}   # cls -> {"stamp", "values"}


static func collect(cls: String) -> Dictionary:
	var stamp := "%d|%d" % [TrackStore.revision, Profiles.revision]
	var hit: Dictionary = _collect_cache.get(cls, {})
	if hit.get("stamp", "") == stamp:
		return hit["values"]
	var out := _collect(cls)
	_collect_cache[cls] = {"stamp": stamp, "values": out}
	return out


static func _collect(cls: String) -> Dictionary:
	var out := {}
	for p in TrackStore.list():
		if str(p.get("class", "")) != cls or not p.has("traits"):
			continue
		if not MotecProfile.is_full_lap(float(p.get("lap", {}).get("length_m", 0.0))):
			continue   # a broken profile (no full lap in the export) would distort every grade
		var t := (p["traits"] as Dictionary).duplicate()
		# context for the details: lap length and time, coasting share, kinks, wear per tyre
		t["lap_km"] = float(p["lap"]["length_m"]) / 1000.0
		t["lap_s"] = float(p["lap"]["time_s"])
		var st: Dictionary = p.get("stats", {})
		if st.has("coasting_pct"):
			t["coasting_pct"] = st["coasting_pct"]
		if st.has("flat_kinks"):
			t["flat_kinks"] = st["flat_kinks"]
		t["wear_tyres"] = p.get("resources", {}).get("tyre_wear_pct", {})
		out[str(p["course"])] = t
	var res := _results(cls)
	for course in res:
		if not out.has(course):
			out[course] = {}
		out[course].merge(res[course])
	return out


# Overtaking, incidents and fuel per tank from the league races of this class
static func _results(cls: String, training := false) -> Dictionary:
	var acc := {}   # course -> lists of per-race values (passes, incidents, fuel...)
	for day in Profiles.days:
		if bool(day.get("training", false)) != training or day["race"].is_empty():
			continue
		var race: Dictionary = day["race"]
		if not race.get("classes", {}).has(cls):
			continue
		var course: String = day["course"]
		if not acc.has(course):
			acc[course] = {"passes_10": [], "passes": [], "lap1": [], "incidents": [], "contacts": [], "limits": [], "warnings": [], "tank_lap": []}
		var a: Dictionary = acc[course]
		var c: Dictionary = race["classes"][cls]
		a["incidents"].append(float(c.get("con", 0.0)) * 10.0)   # contacts only (track limits apart)
		a["contacts"].append(float(c.get("con", 0.0)) * 10.0)
		a["limits"].append(float(c.get("tl", 0.0)) * 10.0)
		if c.has("tlw"):   # lap data read before version 8 has no decision
			a["warnings"].append(float(c["tlw"]) * 10.0)
		var length := float(day["track"].get("length", 0.0))
		if float(c.get("fuel_km", 0.0)) > 0.0 and length > 0.0:
			a["tank_lap"].append(float(c["fuel_km"]) * length / 1000.0)   # % of the tank per lap
		if c.has("passes_10"):   # events read before passes were counted lack these: re-read the XML
			a["passes_10"].append(float(c["passes_10"]))
			a["passes"].append(float(c["passes"]))
			a["lap1"].append(float(c["lap1_moves"]))
	var out := {}
	for course in acc:
		var a: Dictionary = acc[course]
		var r := {}
		if not a["passes_10"].is_empty():
			r["passes_10"] = _mean(a["passes_10"])
			r["passes_race"] = _mean(a["passes"])
			r["lap1_race"] = _mean(a["lap1"])
			r["races"] = a["passes_10"].size()
		if not a["incidents"].is_empty():
			r["incidents_10"] = _mean(a["incidents"])
			r["contacts_10"] = _mean(a["contacts"])
			r["limits_10"] = _mean(a["limits"])
			r["incident_races"] = a["incidents"].size()
		if not a["warnings"].is_empty():
			r["warnings_10"] = _mean(a["warnings"])
		if not a["tank_lap"].is_empty():
			r["tank_pct_lap"] = _mean(a["tank_lap"])
		out[course] = r
	return out


# 1..5 by position among all known tracks (course -> value). Near-ties are grouped and the
# group shares the average position of its members. Returns {"grade", "tied": [other courses]}.
static func _ranked(course: String, pool: Dictionary) -> Dictionary:
	var names := pool.keys()
	names.sort_custom(func(a, b): return pool[a] < pool[b])
	var n := names.size()
	# spread of the middle 80% of tracks, so one odd track cannot make everything else look equal
	var lo: float = pool[names[int(floor((n - 1) * 0.1))]]
	var hi: float = pool[names[int(ceil((n - 1) * 0.9))]]
	var mean := 0.0
	for c in names:
		mean += pool[c]
	mean /= n
	var tol := maxf(TIE_RANGE * (hi - lo), TIE_VALUE * absf(mean))
	# walk the sorted list; a new group starts when a value is too far from the group's first one
	var groups := [[names[0]]]
	for i in range(1, n):
		if pool[names[i]] - pool[groups.back()[0]] <= tol:
			groups.back().append(names[i])
		else:
			groups.append([names[i]])
	var pos := 0
	for g in groups:
		var first := pos
		pos += g.size()
		if not g.has(course):
			continue
		# average position of the group, 0 = lowest, 1 = highest
		var p := (first + pos - 1) / 2.0 / float(n - 1)
		var tied := []
		for c in g:
			if c != course:
				tied.append(c)
		return {"grade": clampi(int(floor(p * 5.0)) + 1, 1, 5), "tied": tied}
	return {"grade": 0, "tied": []}


static func _fixed(x: float, cuts: Array) -> int:
	var g := 1
	for c in cuts:
		if x >= c:
			g += 1
	return g


# The supporting numbers shown next to each grade. They use the same kind of measure as the
# grade (shares of the lap, per km, per minute...) so they cannot contradict it; plain counts
# are always given with the lap length.
static func _detail(id: String, t: Dictionary) -> String:
	var parts := PackedStringArray()
	var km := float(t.get("lap_km", 0.0))
	var on_lap := (" in %.1f km" % km) if km > 0.0 else ""
	match id:
		"top":
			# where the rest of the lap time goes
			if t.has("full_throttle_pct") and t.has("braking_pct") and t.has("coasting_pct"):
				var part := maxf(0.0, 100.0 - float(t["full_throttle_pct"]) - float(t["braking_pct"]) - float(t["coasting_pct"]))
				parts.append("rest of the lap: braking %.1f%%, part-throttle %.1f%%, coasting %.1f%%" % [
					float(t["braking_pct"]), part, float(t["coasting_pct"])])
		"brake":
			if t.has("heavy_zones_km"):
				parts.append("%.2f heavy stops per km" % float(t["heavy_zones_km"]))
			if t.has("braking_pct"):
				parts.append("on the brakes %.1f%% of the lap time" % float(t["braking_pct"]))
			if t.has("decel_avg_g"):
				parts.append("average peak deceleration %.2f G" % float(t["decel_avg_g"]))
		"hs":
			if t.has("flat_kinks"):
				parts.append("%d flat-out kink%s%s (counted here)" % [int(t["flat_kinks"]), "" if int(t["flat_kinks"]) == 1 else "s", on_lap])
		"traction":
			if t.has("slow_corners_km") and km > 0.0:
				parts.append("%d slow corners and hairpins%s" % [roundi(float(t["slow_corners_km"]) * km), on_lap])
			if int(t.get("pickup_avg_m", -1)) >= 0:
				parts.append("in those, full throttle %d m after the apex on average" % int(t["pickup_avg_m"]))
		"density":
			if t.has("corners_km") and km > 0.0:
				parts.append("%d corners%s" % [roundi(float(t["corners_km"]) * km), on_lap])
			if t.has("direction_changes"):
				parts.append("%d quick direction changes" % int(t["direction_changes"]))
		"tyres":
			var wear: Dictionary = t.get("wear_tyres", {})
			if not wear.is_empty() and km > 0.0:
				var worst := ""
				for k in wear:
					if worst == "" or float(wear[k]) > float(wear[worst]):
						worst = k
				parts.append("most worn: %s at %.3f%% per km" % [worst, float(wear[worst]) / km])
			if t.has("combined_g_avg"):
				parts.append("average combined load %.2f G" % float(t["combined_g_avg"]))
		"fuel":
			if t.has("fuel_l_km"):
				parts.append("%.3f L per km" % float(t["fuel_l_km"]))
			if t.has("fuel_l_lap"):
				parts.append("for pit planning: %.2f L per lap" % float(t["fuel_l_lap"]))
			if float(t.get("tank_pct_lap", 0.0)) > 0.0:
				var tank := float(t["tank_pct_lap"])
				var txt := "league races: %.1f%% of the tank per lap, about %d laps" % [tank, int(100.0 / tank)]
				if float(t.get("lap_s", 0.0)) > 0.0:
					txt += " or %d minutes" % int(100.0 / tank * float(t["lap_s"]) / 60.0)
				parts.append(txt + " per tank")
		"bumps":
			var spots: Array = t.get("rough_spots", [])
			if t.has("bump_g") and spots.is_empty():
				parts.append("no rough spots")
			for j in spots.size():
				var sp: Dictionary = spots[j]
				parts.append("B%d at %d-%d m (%d km/h)" % [j + 1, int(sp["at"]), int(sp["at"]) + int(sp.get("len", 50)), int(sp["kmh"])])
			if t.has("kerb_mm"):
				parts.append("kerb strikes %.1f mm, not graded (one-sided ride-height motion in corners)" % float(t["kerb_mm"]))
		"overtake":
			if t.has("passes_race"):
				parts.append("%.0f passes per race in the class, plus %.0f places changed on the opening lap (not counted)" % [
					float(t["passes_race"]), float(t["lap1_race"])])
			if t.has("races"):
				parts.append("average of %d race%s" % [int(t["races"]), "" if int(t["races"]) == 1 else "s"])
		"incidents":
			if t.has("contacts_10"):
				parts.append("contacts %.2f per driver per 10 laps" % float(t["contacts_10"]))
			if t.has("incident_races"):
				parts.append("average of %d race%s" % [int(t["incident_races"]), "" if int(t["incident_races"]) == 1 else "s"])
		"limits":
			if t.has("limits_10") and float(t["limits_10"]) > 0.0:
				parts.append("%.1f track-limit events per driver per 10 laps, %.0f%% of them warned" % [
					float(t["limits_10"]), 100.0 * float(t.get("warnings_10", 0.0)) / float(t["limits_10"])])
	return ", ".join(parts)


static func _fmt(x: float) -> String:
	if absf(x) < 0.1 and x != 0.0:
		return "%.4f" % x
	if absf(x) >= 100.0:
		return "%.0f" % x
	if absf(x) >= 10.0:
		return "%.1f" % x
	return "%.2f" % x


static func _mean(a: Array) -> float:
	var s := 0.0
	for x in a:
		s += float(x)
	return s / maxf(a.size(), 1)
