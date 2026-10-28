class_name TrackGrades
extends RefCounted
## Grades a track from 1 to 5 on ten characteristics, separately for each class.
## Seven come from the telemetry profile (MotecProfile "traits"), two from the league results
## (the "Profiles" autoload). A grade ranks the track against the other tracks known for the
## same class; with fewer than MIN_RANKED tracks it uses the fixed scale in CUTS instead.
## 5 always means "the most": most time at full throttle, hardest braking, thirstiest, etc.

const MIN_RANKED := 5
# Near-ties share a grade: values closer than TIE_RANGE x (spread of the class) or
# TIE_VALUE x (typical value), whichever is larger, are grouped (chained, so A~B~C is one group).
const TIE_RANGE := 0.10
const TIE_VALUE := 0.03

# key: the raw value that is graded. cuts: fixed-scale limits for grades 2, 3, 4 and 5, set
# from LMP3 and GT3 laps of Bahrain, Sebring, Spa, Paul Ricard and COTA. alt / alt_cuts: what
# to grade when a profile lacks the key (e.g. an export without tyre wear channels).
const TRAITS := [
	{"id": "top", "name": "Full throttle", "src": "tel", "key": "full_throttle_pct", "cuts": [64.0, 67.0, 69.5, 71.0],
		"tip": "Share of the lap time at full throttle. High = power and low drag pay off (and the engine works hardest). Low = more braking, part-throttle and coasting."},
	{"id": "brake", "name": "Braking", "src": "tel", "key": "scrub_kmh_km", "cuts": [130.0, 145.0, 160.0, 175.0],
		"tip": "Speed taken off in braking zones, per km of track. High = many and/or big stops."},
	{"id": "hs", "name": "High-speed corners", "src": "tel", "key": "hs_corner_pct", "cuts": [12.0, 15.0, 18.0, 21.0],
		"tip": "Share of the lap time above 60% of top speed with at least 1 G of lateral load. High = downforce and commitment."},
	{"id": "traction", "name": "Traction", "src": "tel", "key": "slow_corners_km", "cuts": [0.75, 1.0, 1.25, 1.4],
		"tip": "Slow corners and hairpins per km. High = exits and traction decide the lap."},
	{"id": "density", "name": "Corner density", "src": "tel", "key": "corners_km", "cuts": [1.95, 2.1, 2.25, 2.4],
		"tip": "Corners per km (flat-out kinks not counted). High = busy and technical, low = long gaps between corners."},
	{"id": "tyres", "name": "Tyre stress", "src": "tel", "key": "tyre_wear_km", "cuts": [0.08, 0.11, 0.15, 0.20],
		"alt": "combined_g_avg", "alt_cuts": [0.90, 0.97, 1.03, 1.10],
		"tip": "Tyre wear per km on the telemetry lap (average of the four tyres), from the game's own wear model. High = hard on tyres. Without wear channels: average combined G over the lap."},
	{"id": "fuel", "name": "Fuel use", "src": "tel", "key": "fuel_l_min", "cuts": [1.45, 1.6, 1.75, 1.9],
		"tip": "Litres per minute of driving, which is what decides pit stops in a timed race."},
	{"id": "bumps", "name": "Bumpiness", "src": "tel", "key": "bump_g", "cuts": [0.065, 0.085, 0.105, 0.13],
		"tip": "Fast up-and-down motion (vertical G) where the car is going straight, so kerbs do not count: the typical 50 m section, so one big hit does not decide it. High = bumpy surface."},
	{"id": "overtake", "name": "Overtaking", "src": "res", "key": "changes_pct", "cuts": [8.0, 14.0, 20.0, 27.0],
		"tip": "From league races: average places gained or lost per driver, as % of the class field. High = positions change a lot."},
	{"id": "incidents", "name": "Incident risk", "src": "res", "key": "incidents_10", "cuts": [0.5, 1.0, 2.0, 3.5],
		"tip": "From league races: contacts plus track-limit warnings per driver per 10 laps."},
]


# One row per characteristic for this track and class:
# {"id", "name", "tip", "grade" (0 = no data), "value", "detail", "basis"}
static func grade(course: String, cls: String) -> Array:
	var values := collect(cls)   # course -> {key: value}
	var mine: Dictionary = values.get(course, {})
	var out := []
	for t in TRAITS:
		var key: String = t["key"]
		var cuts: Array = t["cuts"]
		if not mine.has(key) and t.has("alt") and mine.has(t["alt"]):
			key = t["alt"]
			cuts = t["alt_cuts"]
		var row := {"id": t["id"], "name": t["name"], "tip": t["tip"], "grade": 0,
			"value": "-", "detail": _detail(t["id"], mine), "basis": "no data"}
		if mine.has(key):
			var pool := {}   # course -> value
			for c in values:
				if values[c].has(key):
					pool[c] = float(values[c][key])
			var x := float(mine[key])
			row["value"] = _fmt(x)
			if pool.size() >= MIN_RANKED:
				var r := _ranked(course, pool)
				row["grade"] = r["grade"]
				row["basis"] = "ranked among %d tracks" % pool.size()
				if not r["tied"].is_empty():
					row["basis"] += ", tied with " + ", ".join(PackedStringArray(r["tied"]))
			else:
				row["grade"] = _fixed(x, cuts)
				row["basis"] = "fixed scale (%d track%s known)" % [pool.size(), "" if pool.size() == 1 else "s"]
		out.append(row)
	return out


# course -> raw values for one class, from the stored telemetry profiles and the league results
static func collect(cls: String) -> Dictionary:
	var out := {}
	for p in TrackStore.list():
		if str(p.get("class", "")) != cls or not p.has("traits"):
			continue
		out[str(p["course"])] = (p["traits"] as Dictionary).duplicate()
	var res := _results(cls)
	for course in res:
		if not out.has(course):
			out[course] = {}
		out[course].merge(res[course])
	return out


# Overtaking, incidents and fuel per tank from the league races of this class
static func _results(cls: String) -> Dictionary:
	var acc := {}   # course -> {"changes": [], "incidents": [], "tank_lap": [], "length": m}
	for day in Profiles.days:
		if day.get("training", false) or day["race"].is_empty():
			continue
		var race: Dictionary = day["race"]
		if not race.get("classes", {}).has(cls):
			continue
		var course: String = day["course"]
		if not acc.has(course):
			acc[course] = {"changes": [], "incidents": [], "tank_lap": []}
		var a: Dictionary = acc[course]
		var c: Dictionary = race["classes"][cls]
		a["incidents"].append((float(c.get("con", 0.0)) + float(c.get("tl", 0.0))) * 10.0)
		var length := float(day["track"].get("length", 0.0))
		if float(c.get("fuel_km", 0.0)) > 0.0 and length > 0.0:
			a["tank_lap"].append(float(c["fuel_km"]) * length / 1000.0)   # % of the tank per lap
		var moved := 0.0
		var counted := 0
		var field := 0
		for nm in race.get("drivers", {}):
			var d: Dictionary = race["drivers"][nm]
			if d.get("cls", "") != cls:
				continue
			field += 1
			if int(d.get("grid", 0)) > 0 and int(d.get("pos", 0)) > 0:
				moved += absi(int(d["grid"]) - int(d["pos"]))
				counted += 1
		if counted > 0 and field > 1:
			a["changes"].append(moved / counted / float(field - 1) * 100.0)
	var out := {}
	for course in acc:
		var a: Dictionary = acc[course]
		var r := {}
		if not a["changes"].is_empty():
			r["changes_pct"] = _mean(a["changes"])
			r["races"] = a["changes"].size()
		if not a["incidents"].is_empty():
			r["incidents_10"] = _mean(a["incidents"])
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
	var lo: float = pool[names[0]]
	var hi: float = pool[names[n - 1]]
	var mean := 0.0
	for c in names:
		mean += pool[c]
	mean /= n
	var tol := maxf(TIE_RANGE * (hi - lo), TIE_VALUE * absf(mean))
	# split the sorted list wherever the gap to the next value is bigger than the tolerance
	var groups := [[names[0]]]
	for i in range(1, n):
		if pool[names[i]] - pool[names[i - 1]] <= tol:
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


# The supporting numbers shown next to each grade
static func _detail(id: String, t: Dictionary) -> String:
	var parts := PackedStringArray()
	match id:
		"top":
			if t.has("longest_straight_m"):
				parts.append("longest straight %d m" % int(t["longest_straight_m"]))
			if t.has("top_kmh"):
				parts.append("top %d km/h" % int(t["top_kmh"]))
		"brake":
			if t.has("heavy_zones_km"):
				parts.append("%.2f heavy stops per km" % float(t["heavy_zones_km"]))
			if t.has("braking_pct"):
				parts.append("%.1f%% of the lap on the brakes" % float(t["braking_pct"]))
			if t.has("decel_avg_g"):
				parts.append("peak decel %.2f G on average" % float(t["decel_avg_g"]))
		"traction":
			if int(t.get("pickup_avg_m", -1)) >= 0:
				parts.append("full throttle %d m after the apex on average" % int(t["pickup_avg_m"]))
		"density":
			if t.has("direction_changes"):
				parts.append("%d quick direction changes" % int(t["direction_changes"]))
		"tyres":
			if t.has("tyre_wear_lap"):
				parts.append("%.2f%% wear per lap" % float(t["tyre_wear_lap"]))
			if t.has("combined_g_avg"):
				parts.append("average combined load %.2f G" % float(t["combined_g_avg"]))
		"fuel":
			if t.has("fuel_l_lap"):
				parts.append("%.2f L per lap" % float(t["fuel_l_lap"]))
			if t.has("fuel_l_km"):
				parts.append("%.3f L per km" % float(t["fuel_l_km"]))
			if float(t.get("tank_pct_lap", 0.0)) > 0.0:
				var tank := float(t["tank_pct_lap"])
				parts.append("%.1f%% of the tank per lap, about %d laps per tank (league races)" % [tank, int(100.0 / tank)])
		"bumps":
			if t.has("bump_g") and t.get("rough_spots", []).is_empty():
				parts.append("no rough spots")
			var spots: Array = t.get("rough_spots", [])
			for j in spots.size():
				var sp: Dictionary = spots[j]
				parts.append("B%d at %d-%d m (%d km/h)" % [j + 1, int(sp["at"]), int(sp["at"]) + int(sp.get("len", 50)), int(sp["kmh"])])
			if t.has("kerb_mm"):
				parts.append("kerb strikes %.1f mm (one-sided ride-height motion in corners)" % float(t["kerb_mm"]))
		"overtake":
			if t.has("races"):
				parts.append("%d race%s" % [int(t["races"]), "" if int(t["races"]) == 1 else "s"])
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
