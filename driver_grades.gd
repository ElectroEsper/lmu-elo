class_name DriverGrades
extends RefCounted
## Grades a driver from 1 to 5 on eight characteristics, against the other drivers of the
## same class. Unlike track grades, 5 always means BETTER (quicker, steadier, cleaner...).
## A grade is the driver's position among the drivers with enough sessions, split in fifths:
## the best fifth gets 5, the worst fifth gets 1. Equal values share a position.
## Lap-data measures come from the "Profiles" autoload (already pulled toward the field for
## drivers with few sessions); grid, finish and retirements come from the Elo history.

# Races (or qualis, for quali pace) a driver needs to be graded: Settings > Driver grades.
static func min_sessions() -> int:
	return maxi(int(LeagueSettings.get_value("grade_min_sessions")), 1)
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
	["tyres", "Tyre management", "Tyre wear per km compared with the field, after taking out how hard the car itself is on its tyres (worked out from everyone who drove it). Less wear = better. Wear varies a lot from race to race, so 3 = within normal variation; 4-5 and 1-2 only for drivers who are clearly gentler or harder on tyres."],
	["fuel", "Fuel saving", "Fuel use per km compared with the field, after taking out how thirsty the car itself is (worked out from everyone who drove it). Less = better. 3 = within normal variation; 4-5 and 1-2 only for drivers who clearly use less or more."],
	["finish", "Finishing", "Share of races finished (DNF and disqualifications count against it). Fixed scale: 5 = every race, 4 = 95%+, 3 = 90%+, 2 = 80%+."],
]

# Car correction for fuel and tyres: each race = car effect + driver effect + noise, solved
# together. Effects are pulled toward 0 as if they had this many extra average races, so a car
# seen in few races (or driven by one driver only) gets only part of the blame or credit.
const CAR_PRIOR := 8.0
const DRIVER_PRIOR := 3.0
# Fuel and tyres are noisy from race to race (about 4% and 15%), so a driver whose effect is
# within this many standard errors of zero is graded 3 ("normal variation"); only drivers who are
# clearly thriftier or thirstier get 4-5 or 1-2.
const NOISE_BAND := 1.0

static var _cache := {}   # cls -> {"stamp": String, "grades": {driver: {id: entry}}, "field": {id: int}}


# All grades of one class: {"grades": {driver: {id: {"grade", "value", "rank", "of"}}}, "field": {id: n}}
# "grade" is 0 when the driver has too few sessions or the class too few graded drivers.
static func for_class(cls: String) -> Dictionary:
	var stamp := "%d|%d|%d" % [Elo.revision, Profiles.revision, LeagueSettings.revision]   # any save, merge, rebuild or setting
	if _cache.has(cls) and _cache[cls]["stamp"] == stamp:
		return _cache[cls]
	var MIN_SESSIONS := min_sessions()
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
			clean_pool.append(r)
	# fuel and tyres: the driver's own effect once the car's effect is taken out
	for spec in [["fuel", "fuel_rel", "fuel"], ["tyres", "wear_rel", "wear"]]:
		var fx := car_adjusted(cls, spec[1])
		for nm in fx["drivers"]:
			var d: Dictionary = fx["drivers"][nm]
			if d["n"] < MIN_SESSIONS:
				continue
			var car_txt := ""
			if d["car"] != "":
				car_txt = ", car %s %+.1f%%" % [d["car"], fx["cars"][d["car_key"]]["effect"]]
			var z: float = d["effect"] / d["se"] if d["se"] > 0.0 else 0.0
			var verdict := " (normal variation)" if absf(z) < NOISE_BAND else ""
			raw[spec[0]][nm] = [-d["effect"], "%+.1f%% %s vs field%s%s" % [d["effect"], spec[2], car_txt, verdict], -z]
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
		# noisy measures: drivers clearly better (or worse) than average, ranked among themselves
		var clear_up := {}
		var clear_down := {}
		for d in pool:
			if pool[d].size() > 2 and absf(pool[d][2]) >= NOISE_BAND:
				if pool[d][2] > 0.0:
					clear_up[d] = pool[d]
				else:
					clear_down[d] = pool[d]
		var up_rank := _rank(clear_up)
		var down_rank := _rank(clear_down)
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
			elif pool.size() >= MIN_FIELD and pool[d].size() > 2:
				# noisy measures: 3 unless clearly different, then 4-5 / 1-2 by position
				var z: float = pool[d][2]
				if absf(z) < NOISE_BAND:
					g = 3
				elif z > 0.0:
					g = 5 if up_rank[d]["p"] >= 0.5 else 4     # better half of the clearly better
				else:
					g = 1 if down_rank[d]["p"] < 0.5 else 2   # worse half of the clearly worse
			elif pool.size() >= MIN_FIELD:
				g = clampi(int(floor(ranked[d]["p"] * 5.0)) + 1, 1, 5)
			grades[d][id] = {"grade": g, "value": pool[d][1], "rank": ranked[d]["rank"], "of": pool.size()}
	var out := {"stamp": stamp, "grades": grades, "field": field}
	_cache[cls] = out
	return out


# Splits a per-race measure (fuel_rel or wear_rel, % vs the class) into car and driver effects:
# value = car + driver + noise, fitted by alternating averages with both pulled toward 0.
# Returns {"drivers": {name: {"effect", "n", "car", "car_key"}}, "cars": {key: {"name", "effect", "n", "drivers"}}}
static func car_adjusted(cls: String, field: String) -> Dictionary:
	var obs := []   # [driver, car key, value]
	var car_names := {}
	for key in Profiles.hist:
		if not key.begins_with(cls + "|"):
			continue
		var nm: String = key.substr(cls.length() + 1)
		for e in Profiles.hist[key]:
			var r: Dictionary = e.get("r", {})
			if r.is_empty() or not r.has(field) or r.get(field) == null:
				continue
			var ck := car_key(str(r.get("car", "")))
			if not car_names.has(ck):
				car_names[ck] = str(r.get("car", ""))
			obs.append([nm, ck, float(r[field])])
	var d_eff := {}
	var c_eff := {}
	for o in obs:
		d_eff[o[0]] = 0.0
		c_eff[o[1]] = 0.0
	for _i in 30:
		var cs := {}
		var cn := {}
		for o in obs:
			cs[o[1]] = cs.get(o[1], 0.0) + o[2] - d_eff[o[0]]
			cn[o[1]] = cn.get(o[1], 0) + 1
		for k in cs:
			c_eff[k] = cs[k] / (cn[k] + CAR_PRIOR)
		var ds := {}
		var dn := {}
		for o in obs:
			ds[o[0]] = ds.get(o[0], 0.0) + o[2] - c_eff[o[1]]
			dn[o[0]] = dn.get(o[0], 0) + 1
		for k in ds:
			d_eff[k] = ds[k] / (dn[k] + DRIVER_PRIOR)
	# per driver: number of races and main car; per car: races and drivers
	var drivers := {}
	var cars := {}
	var usage := {}
	for o in obs:
		var u: Dictionary = usage.get(o[0], {})
		u[o[1]] = u.get(o[1], 0) + 1
		usage[o[0]] = u
		var c: Dictionary = cars.get(o[1], {"name": car_names[o[1]], "effect": c_eff[o[1]], "n": 0, "drivers": {}})
		c["n"] += 1
		c["drivers"][o[0]] = true
		cars[o[1]] = c
	for nm in usage:
		var best := ""
		var n := 0
		for k in usage[nm]:
			n += usage[nm][k]
			if best == "" or usage[nm][k] > usage[nm][best]:
				best = k
		drivers[nm] = {"effect": d_eff[nm], "n": n, "car": car_names.get(best, ""), "car_key": best}
	# race-to-race noise left after car and driver effects, and each driver's uncertainty
	var sq := 0.0
	for o in obs:
		var res: float = o[2] - c_eff[o[1]] - d_eff[o[0]]
		sq += res * res
	var sigma := sqrt(sq / maxi(obs.size() - 1, 1))
	for nm in drivers:
		drivers[nm]["se"] = sigma / sqrt(drivers[nm]["n"] + DRIVER_PRIOR)
	return {"drivers": drivers, "cars": cars, "sigma": sigma}


# One car model under slightly different names ("Genesis GMR-001" / "Genesis GMR001") counts once.
static func car_key(car: String) -> String:
	var out := ""
	for ch in car.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
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
