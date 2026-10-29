class_name DriverGrades
extends RefCounted
## Grades a driver from 1 to 5 on eight characteristics, against the other drivers of the
## same class. Unlike track grades, 5 always means BETTER (quicker, steadier, cleaner...).
## A grade is the driver's position among the drivers with enough sessions, split in fifths:
## the best fifth gets 5, the worst fifth gets 1. Equal values share a position.
## Lap-data measures come from the "Profiles" autoload (already pulled toward the field for
## drivers with few sessions); grid, finish and retirements come from the Elo history.

const MIN_SESSIONS := 3   # races (or qualis, for quali pace) a driver needs to be graded
const MIN_FIELD := 5      # graded drivers a class needs before grades mean anything
# Finishing uses a fixed scale instead of positions (most drivers finish every race, so they
# would all share one position): share of races finished needed for grades 2, 3, 4 and 5.
const FINISH_CUTS := [0.80, 0.90, 0.95, 0.999]

# id, name, what it measures (tooltip / note)
const TRAITS := [
	["quali", "Quali pace", "Best qualifying lap against the class median. Quicker = better."],
	["race", "Race pace", "Clean race laps against the class median. Quicker = better."],
	["steady", "Consistency", "Lap-to-lap spread in races, as a percent of the typical lap. Smaller = better."],
	["craft", "Racecraft", "Places gained from the grid to the finish, compared with what drivers starting from the same grid spot usually gain (front-runners cannot gain much, so they are not penalised for it). More = better."],
	["clean", "Clean driving", "Contacts with other cars and track-limit warnings per lap, both compared with the class. Fewer = better."],
	["tyres", "Tyre management", "Tyre wear per km against the class median. Less wear = better."],
	["fuel", "Fuel saving", "Fuel use per km against the class median. Less = better."],
	["finish", "Finishing", "Share of races finished (DNF and disqualifications count against it). Fixed scale: 5 = every race, 4 = 95%+, 3 = 90%+, 2 = 80%+."],
]

static var _cache := {}   # cls -> {"stamp": String, "grades": {driver: {id: entry}}, "field": {id: int}}


# All grades of one class: {"grades": {driver: {id: {"grade", "value", "rank", "of"}}}, "field": {id: n}}
# "grade" is 0 when the driver has too few sessions or the class too few graded drivers.
static func for_class(cls: String) -> Dictionary:
	var stamp := "%d|%d" % [Elo.history.size(), Profiles.days.size()]
	if _cache.has(cls) and _cache[cls]["stamp"] == stamp:
		return _cache[cls]
	var raw := {}   # id -> {driver: [score (higher = better), shown value]}
	for t in TRAITS:
		raw[t[0]] = {}
	var everyone := {}

	# lap-data measures
	var rows := Profiles.driver_rows(cls)
	var clean_pool := []
	for r in rows:
		var nm: String = r["name"]
		everyone[nm] = true
		if r["n_q"] >= MIN_SESSIONS:
			raw["quali"][nm] = [-r["qpace"], "%+.2f%% vs class" % r["qpace"]]
		if r["n_r"] >= MIN_SESSIONS:
			raw["race"][nm] = [-r["pace"], "%+.2f%% vs class" % r["pace"]]
			raw["steady"][nm] = [-r["cons"], "%.2f%% lap spread" % r["cons"]]
			if absf(r["wear"]) > 0.0001:
				raw["tyres"][nm] = [-r["wear"], "%+.1f%% wear vs class" % r["wear"]]
			if absf(r["fuel"]) > 0.0001:
				raw["fuel"][nm] = [-r["fuel"], "%+.1f%% fuel vs class" % r["fuel"]]
			clean_pool.append(r)
	# clean driving: contacts and track limits per lap, each as a z-score within the class
	var zc := _z(clean_pool, "con")
	var zt := _z(clean_pool, "tl")
	for r in clean_pool:
		var nm: String = r["name"]
		raw["clean"][nm] = [-(zc.get(nm, 0.0) + zt.get(nm, 0.0)),
			"%.3f contacts, %.2f limits per lap" % [r["con"], r["tl"]]]

	# results: grid -> finish and retirements, from the rated races
	var starts := {}   # driver -> [[grid, finish], ...]
	var races := {}    # driver -> [races, retirements]
	for ev in Elo.history:
		var stats: Dictionary = Reports._stats_for(ev, "race", cls)
		for c in ev["changes"]:
			if c["sess"] != "race" or c["cls"] != cls:
				continue
			var d: String = c["driver"]
			everyone[d] = true
			var s: Dictionary = stats.get(d, {})
			var rr: Array = races.get(d, [0, 0])
			rr[0] += 1
			if not s.is_empty() and Reports._retired(s.get("status", "")):
				rr[1] += 1
			races[d] = rr
			if not s.is_empty() and int(s.get("grid", 0)) > 0 and not Reports._retired(s.get("status", "")):
				if not starts.has(d):
					starts[d] = []
				starts[d].append([int(s["grid"]), int(c["pos"])])
	for d in races:
		var rr: Array = races[d]
		if rr[0] >= MIN_SESSIONS:
			raw["finish"][d] = [1.0 - float(rr[1]) / rr[0],
				"%d of %d races finished" % [rr[0] - rr[1], rr[0]]]
	# racecraft: places gained minus what the class usually gains from the same grid spot
	var xs := []
	var ys := []
	for d in starts:
		for g in starts[d]:
			xs.append(float(g[0]))
			ys.append(float(g[0] - g[1]))
	var fit := _line(xs, ys)
	for d in starts:
		var list: Array = starts[d]
		if list.size() < MIN_SESSIONS:
			continue
		var gained := 0.0
		var extra := 0.0
		for g in list:
			gained += g[0] - g[1]
			extra += (g[0] - g[1]) - (fit[0] + fit[1] * g[0])
		gained /= list.size()
		extra /= list.size()
		raw["craft"][d] = [extra, "%+.1f places per race (%+.1f vs usual from the same grid spots)" % [gained, extra]]

	# rank each characteristic into fifths
	var grades := {}
	var field := {}
	for d in everyone:
		grades[d] = {}
	for t in TRAITS:
		var id: String = t[0]
		var pool: Dictionary = raw[id]
		field[id] = pool.size()
		var ranked := _rank(pool)
		for d in everyone:
			if not pool.has(d):
				grades[d][id] = {"grade": 0, "value": "-", "rank": 0, "of": pool.size()}
				continue
			var g := 0
			if id == "finish":
				g = 1
				for cut in FINISH_CUTS:
					if pool[d][0] >= cut:
						g += 1
			elif pool.size() >= MIN_FIELD:
				g = clampi(int(floor(ranked[d]["p"] * 5.0)) + 1, 1, 5)
			grades[d][id] = {"grade": g, "value": pool[d][1], "rank": ranked[d]["rank"], "of": pool.size()}
	var out := {"stamp": stamp, "grades": grades, "field": field}
	_cache[cls] = out
	return out


# One driver's grades in a class, in TRAITS order: [{"id", "name", "tip", "grade", "value", "rank", "of"}]
static func driver(driver_name: String, cls: String) -> Array:
	var all: Dictionary = for_class(cls)["grades"]
	var mine: Dictionary = all.get(driver_name, {})
	var out := []
	for t in TRAITS:
		var e: Dictionary = mine.get(t[0], {"grade": 0, "value": "-", "rank": 0, "of": 0})
		out.append({"id": t[0], "name": t[1], "tip": t[2], "grade": e["grade"], "value": e["value"],
			"rank": e["rank"], "of": e["of"]})
	return out


# driver -> {"p": 0 (worst) .. 1 (best), "rank": 1 = best}; equal scores share a position
static func _rank(pool: Dictionary) -> Dictionary:
	var names := pool.keys()
	names.sort_custom(func(a, b): return pool[a][0] < pool[b][0])
	var n := names.size()
	var out := {}
	var i := 0
	while i < n:
		var j := i
		while j + 1 < n and absf(pool[names[j + 1]][0] - pool[names[i]][0]) < 1e-9:
			j += 1
		var mid := (i + j) / 2.0
		for k in range(i, j + 1):
			out[names[k]] = {"p": mid / float(maxi(n - 1, 1)), "rank": n - j}
		i = j + 1
	return out


static func _z(rows: Array, key: String) -> Dictionary:
	if rows.size() < 2:
		return {}
	var mean := 0.0
	for r in rows:
		mean += r[key]
	mean /= rows.size()
	var sq := 0.0
	for r in rows:
		sq += (r[key] - mean) * (r[key] - mean)
	var sd := sqrt(sq / rows.size())
	var out := {}
	for r in rows:
		out[r["name"]] = 0.0 if sd < 1e-9 else (r[key] - mean) / sd
	return out


# least-squares line y = a + b x: [a, b]
static func _line(xs: Array, ys: Array) -> Array:
	var n := xs.size()
	if n < 2:
		return [0.0, 0.0]
	var mx := 0.0
	var my := 0.0
	for i in n:
		mx += xs[i]
		my += ys[i]
	mx /= n
	my /= n
	var sxx := 0.0
	var sxy := 0.0
	for i in n:
		sxx += (xs[i] - mx) * (xs[i] - mx)
		sxy += (xs[i] - mx) * (ys[i] - my)
	var b := 0.0 if sxx < 1e-9 else sxy / sxx
	return [my - b * mx, b]


static func ordinal(n: int) -> String:
	var suffix := "th"
	if n % 100 < 11 or n % 100 > 13:
		match n % 10:
			1:
				suffix = "st"
			2:
				suffix = "nd"
			3:
				suffix = "rd"
	return "%d%s" % [n, suffix]
