class_name CarBalance
extends RefCounted
## Car balance: every car's race pace in a class against the average entry, as raced (its drivers
## included) and the car itself (each race = car + driver + luck, solved together, as for the fuel
## and tyre grades; DriverGrades.car_adjusted). League races only: training files keep no drivers.
## Used by Reports > Car balance and the Car balance graphic.

const THIN := 5   # cars with fewer entries are shown faded on the graphic and left out of its notes


# season "" = every season. {"cars": [{"key", "name", "n", "drivers", "raw", "eff", "drv", "unc",
# "word"}] quickest car first, "sigma", "entries", "lap": typical race lap in seconds (0 = unknown)}
# Values are percent against the average entry, negative = quicker, without success ballast.
static func compute(cls: String, season := "") -> Dictionary:
	var keep := func(e): return season == "" or str(e.get("season", "")) == season
	var fx := DriverGrades.car_adjusted(cls, "pace_rel", keep)
	var raw := {}
	var laps := []
	for key in Profiles.hist:
		if not str(key).begins_with(cls + "|"):
			continue
		for e in Profiles.hist[key]:
			var r: Dictionary = e.get("r", {})
			if r.is_empty() or not r.has("pace_rel") or not keep.call(e):
				continue
			var ck := DriverGrades.car_key(str(r.get("car", "")))
			var a: Array = raw.get(ck, [0.0, 0])
			a[0] += float(r["pace_rel"]) - Predict.ballast_k_history() * float(r.get("mass", 0.0))
			a[1] += 1
			raw[ck] = a
			if float(r.get("pace", 0.0)) > 0.0:
				laps.append(float(r["pace"]))
	# centred on the average entry, so "level" means level with the rest of the field: the car and
	# driver effects are only defined up to a shared offset
	var c_mid := 0.0
	var r_mid := 0.0
	var n_all := 0
	for ck in fx["cars"]:
		c_mid += float(fx["cars"][ck]["effect"]) * int(fx["cars"][ck]["n"])
		if raw.has(ck):
			r_mid += float(raw[ck][0])
		n_all += int(fx["cars"][ck]["n"])
	c_mid /= maxi(n_all, 1)
	r_mid /= maxi(n_all, 1)
	var cars := []
	for ck in fx["cars"]:
		var c: Dictionary = fx["cars"][ck]
		var n := int(c["n"])
		var as_raced := (float(raw[ck][0]) / int(raw[ck][1]) if raw.has(ck) else 0.0) - r_mid
		var eff := float(c["effect"]) - c_mid
		var unc := float(fx["sigma"]) / sqrt(n + DriverGrades.CAR_PRIOR)
		var word := "about level"
		if eff <= -2.0 * unc:
			word = "quicker car"
		elif eff >= 2.0 * unc:
			word = "slower car"
		cars.append({"key": ck, "name": str(c["name"]), "n": n, "drivers": (c["drivers"] as Dictionary).size(),
			"raw": as_raced, "eff": eff, "drv": as_raced - eff, "unc": unc, "word": word})
	cars.sort_custom(func(a, b): return float(a["eff"]) < float(b["eff"]))
	laps.sort()
	return {"cars": cars, "sigma": float(fx["sigma"]), "entries": n_all, "lap": laps[laps.size() / 2] if not laps.is_empty() else 0.0,
		"fx": fx}


# Tracks where a car ran clearly above or below its own usual level, drivers taken out:
# [{"course", "name", "n", "d"}] (d in percent, negative = stronger here).
static func by_track(cls: String, season: String, base: Dictionary, min_n: int) -> Array:
	var keep := func(e): return season == "" or str(e.get("season", "")) == season
	var fx: Dictionary = base["fx"]
	var out := []
	var courses := {}
	for key in Profiles.hist:
		if str(key).begins_with(cls + "|"):
			for e in Profiles.hist[key]:
				if not (e.get("r", {}) as Dictionary).is_empty() and keep.call(e):
					courses[str(e["course"])] = true
	var clist: Array = courses.keys()
	clist.sort()
	for course in clist:
		var keep_t := func(e): return keep.call(e) and str(e["course"]) == course
		var ft := DriverGrades.car_adjusted(cls, "pace_rel", keep_t)
		# both centred on the cars that raced here, weighted by their entries here
		var m_here := 0.0
		var m_usual := 0.0
		var n_here := 0
		for ck in ft["cars"]:
			if fx["cars"].has(ck):
				m_here += float(ft["cars"][ck]["effect"]) * int(ft["cars"][ck]["n"])
				m_usual += float(fx["cars"][ck]["effect"]) * int(ft["cars"][ck]["n"])
				n_here += int(ft["cars"][ck]["n"])
		if n_here == 0:
			continue
		m_here /= n_here
		m_usual /= n_here
		for ck in ft["cars"]:
			var c: Dictionary = ft["cars"][ck]
			if int(c["n"]) < min_n or not fx["cars"].has(ck):
				continue
			var d := (float(c["effect"]) - m_here) - (float(fx["cars"][ck]["effect"]) - m_usual)
			var unc := float(ft["sigma"]) / sqrt(int(c["n"]) + DriverGrades.CAR_PRIOR)
			if absf(d) >= 2.0 * unc and absf(d) >= 0.1:
				out.append({"course": course, "name": str(c["name"]), "n": int(c["n"]), "d": d})
	return out


# A car's name without the class in it: "BMW M4 LMGT3" -> "BMW M4", "Chevrolet Corvette Z06
# LMGT3.R" -> "Corvette Z06".
static func short(car: String) -> String:
	var words := []
	for w in car.split(" ", false):
		if w.to_upper().begins_with("LMGT3"):   # "911 GT3 R" keeps its GT3
			continue
		words.append(w)
	var out := " ".join(PackedStringArray(words))
	for brand in ["Chevrolet ", "Aston Martin "]:
		if out.begins_with(brand) and out.length() > brand.length() + 3:
			out = ("Aston " if brand == "Aston Martin " else "") + out.substr(brand.length())
	return out


static func _names(list: Array, most := 3) -> String:
	var n := list.map(func(c): return short(str(c["name"])))
	if n.size() > most:
		return "%s +%d" % [", ".join(PackedStringArray(n.slice(0, most))), n.size() - most]
	return ", ".join(PackedStringArray(n))


# Everything the graphic shows: {"cars", "headline", "tiles", "beats", "scale", "empty"}.
static func graphic(cls: String, season := "") -> Dictionary:
	var b := compute(cls, season)
	var cars: Array = b["cars"]
	if cars.size() < 2:
		return {"empty": true}
	var quick := cars.filter(func(c): return c["word"] == "quicker car")
	var slow := cars.filter(func(c): return c["word"] == "slower car")
	var first: Dictionary = cars[0]
	var last: Dictionary = cars[cars.size() - 1]
	var spread := float(last["eff"]) - float(first["eff"])
	var headline := ""
	if not quick.is_empty() and not slow.is_empty():
		headline = "%s the quickest car, %s the slowest: %.1f%% apart, drivers taken out" % [short(first["name"]), short(last["name"]), spread]
	elif not slow.is_empty():
		headline = "A close field: no car clearly quicker, %s" % ("the %s the only one clearly slower" % short(slow[0]["name"]) if slow.size() == 1 else "%d clearly slower" % slow.size())
	elif not quick.is_empty():
		headline = "A close field: no car clearly slower, %s" % ("the %s the only one clearly quicker" % short(quick[0]["name"]) if quick.size() == 1 else "%d clearly quicker" % quick.size())
	else:
		headline = "A close field: no car clearly quicker or slower than the rest, drivers taken out"
	var lap := float(b["lap"])
	var tiles := [
		{"value": str(cars.size()), "label": "cars", "line": "%s entries" % _thousands(int(b["entries"]))},
		{"value": "%.2f%%" % spread, "label": "quickest to slowest", "line": ("≈ %.1f s a lap" % (spread / 100.0 * lap)) if lap > 0.0 else "drivers taken out"},
		{"value": str(quick.size()), "label": "quicker car" if quick.size() == 1 else "quicker cars", "line": _names(quick) if not quick.is_empty() else "none clearly", "tone": "up"},
		{"value": str(slow.size()), "label": "slower car" if slow.size() == 1 else "slower cars", "line": _names(slow) if not slow.is_empty() else "none clearly", "tone": "down"}]
	# notes: the car its drivers held back most, the one they lifted most, then a track or thin data
	var beats := []
	var solid := cars.filter(func(c): return int(c["n"]) >= THIN)
	var shared := solid.filter(func(c): return int(c["drivers"]) >= 2)   # one driver's car says little about the car
	var held: Dictionary = {}
	var lifted: Dictionary = {}
	for c in shared:
		if float(c["drv"]) >= 0.1 and (held.is_empty() or float(c["drv"]) > float(held["drv"])):
			held = c
		if float(c["drv"]) <= -0.1 and (lifted.is_empty() or float(c["drv"]) < float(lifted["drv"])):
			lifted = c
	if not held.is_empty():
		var t := "Close to level: its drivers made it look %.2f%% slower" % float(held["drv"])
		if held["word"] == "quicker car":
			t = "A quicker car than its results: its drivers held it back by %.2f%%" % float(held["drv"])
		elif held["word"] == "slower car":
			t = "A slower car, and its drivers made it look %.2f%% slower still" % float(held["drv"])
		beats.append({"kind": "up", "head": "BETTER THAN IT LOOKS", "title": short(held["name"]), "text": t})
	if not lifted.is_empty():
		var t := "Looks %.2f%% quicker as raced than the car is: " % -float(lifted["drv"])
		t += {"quicker car": "a quicker car, helped by its drivers", "slower car": "a slower car, saved by its drivers"}.get(lifted["word"], "the car itself is level")
		beats.append({"kind": "down", "head": "FLATTERED BY ITS DRIVERS", "title": short(lifted["name"]), "text": t})
	var tracks := by_track(cls, season, b, 3)   # as the report (Reports.BALANCE_MIN_TRACK)
	if not tracks.is_empty():
		tracks.sort_custom(func(x, y): return absf(float(x["d"])) > absf(float(y["d"])))
		var tr: Dictionary = tracks[0]
		beats.append({"kind": "note", "head": "TRACK NOTE", "title": "%s at %s" % [short(tr["name"]), SeasonStory.short(str(tr["course"]))],
			"text": "%.2f%% %s than its usual level (%d entries)" % [absf(float(tr["d"])), "quicker" if float(tr["d"]) < 0.0 else "slower", int(tr["n"])]})
	var thin := cars.filter(func(c): return int(c["n"]) < THIN)
	if beats.size() < 3 and not thin.is_empty():
		var ns := thin.map(func(c): return str(int(c["n"])))
		beats.append({"kind": "note", "head": "THIN DATA", "title": _names(thin, 2),
			"text": "%s %s: held close to level until there are more" % [" and ".join(PackedStringArray(ns)) if ns.size() <= 2 else "Few", "entries" if not (ns.size() == 1 and ns[0] == "1") else "entry"]})
	# chart scale: the cars with enough entries; thin ones are clamped to the edge
	var top := 0.2
	for c in solid if not solid.is_empty() else cars:
		top = maxf(top, maxf(absf(float(c["raw"])), absf(float(c["eff"]))))
	var scale := ceilf(top / 0.2 - 0.001) * 0.2
	return {"empty": false, "cars": cars, "headline": headline, "tiles": tiles, "beats": beats.slice(0, 3), "scale": scale, "thin": THIN}


static func _thousands(n: int) -> String:
	var t := str(n)
	var out := ""
	while t.length() > 3:
		out = "," + t.right(3) + out
		t = t.left(t.length() - 3)
	return t + out
