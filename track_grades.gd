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
	{"id": "overtake", "unit": "passes per car per 10 laps", "name": "Overtaking", "src": "res", "key": "passes_10", "cuts": [0.6, 1.0, 1.5, 2.2],
		"tip": "From league races: on-track passes, i.e. two cars of the class swapping places between the end of one lap and the next. Passes on the opening lap and swaps caused by pit stops are not counted. Per car, per 10 laps. High = lots of overtaking."},
	{"id": "incidents", "unit": "per driver per 10 laps", "name": "Incident risk", "src": "res", "key": "incidents_10", "cuts": [0.5, 1.0, 2.0, 3.5],
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
		out.append(row)
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
static func _results(cls: String) -> Dictionary:
	var acc := {}   # course -> lists of per-race values (passes, incidents, fuel...)
	for day in Profiles.days:
		if day.get("training", false) or day["race"].is_empty():
			continue
		var race: Dictionary = day["race"]
		if not race.get("classes", {}).has(cls):
			continue
		var course: String = day["course"]
		if not acc.has(course):
			acc[course] = {"passes_10": [], "passes": [], "lap1": [], "incidents": [], "contacts": [], "limits": [], "tank_lap": []}
		var a: Dictionary = acc[course]
		var c: Dictionary = race["classes"][cls]
		a["incidents"].append((float(c.get("con", 0.0)) + float(c.get("tl", 0.0))) * 10.0)
		a["contacts"].append(float(c.get("con", 0.0)) * 10.0)
		a["limits"].append(float(c.get("tl", 0.0)) * 10.0)
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
				parts.append("contacts %.2f, track-limit warnings %.2f (per driver per 10 laps)" % [float(t["contacts_10"]), float(t["limits_10"])])
			if t.has("incident_races"):
				parts.append("average of %d race%s" % [int(t["incident_races"]), "" if int(t["incident_races"]) == 1 else "s"])
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
