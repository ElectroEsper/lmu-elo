class_name WetWeather
extends RefCounted
## Wet-weather pace: how much quicker or slower a driver is in the wet than their own dry form.
##
## Rain is read from the tyres: a session is wet when at least half of the laps were driven on
## wet tyres (Fingerprint "wet" share), dry when under 20%; sessions in between are left out.
## Pace is the driver's gap to the class median of that same session (race: lap by lap; quali:
## best lap), so the conditions of the day cancel out and only the driver's own change remains:
##   raw = average wet gap - average dry gap   (negative = quicker in the wet)
## Race and quali are combined, each weighted by how noisy it is. Few wet sessions say little,
## so the estimate is pulled towards 0 (no wet skill) until the evidence builds up.

const WET := 0.5          # share of laps on wet tyres for a wet session
const DRY := DriverTrackFit.WET_SHARE   # under this share: a dry session
const MIN_WET := 2        # wet sessions needed before a driver gets an estimate
const MIN_DRY := 3        # dry sessions of the same kind needed for the driver's baseline
const CONFIDENT := 2.0    # |effect| / uncertainty for "quicker / slower in the wet"
const EARLY := 1.5        # ... for "early sign"
# How different drivers really are in the wet (prior spread, % lap time). Measured from the
# league's own data on every rebuild, kept inside these limits so one odd season cannot make
# everyone a rain master or nobody one.
const TAU_MIN := 0.2
const TAU_MAX := 1.0
const SESSIONS := DriverTrackFit.SESSIONS   # [name, record key, field, wet-share key]

static var _cache := {}   # "stamp" -> String, "data" -> {cls: {driver: entry}}, "tau", "ratio"


# {driver: {"effect", "se", "raw", "n_wet", "n_dry", "wet_sessions": [String], "verdict"}} for one class.
# effect / raw in % of lap time, negative = quicker in the wet.
static func all(cls: String) -> Dictionary:
	_ensure()
	return _cache["data"].get(cls, {})


static func of(driver_name: String, cls: String) -> Dictionary:
	return all(cls).get(driver_name, {})


static func info() -> Dictionary:
	_ensure()
	return {"tau": _cache["tau"], "ratio": _cache["ratio"]}


static func classes() -> Array:
	_ensure()
	var out: Array = _cache["data"].keys()
	out.sort()
	return out


static func _ensure() -> void:
	Profiles.ensure()
	var stamp := "%d|%d" % [Profiles.revision, Elo.revision]
	if _cache.get("stamp", "") != stamp:
		_cache = _build()
		_cache["stamp"] = stamp


static func _build() -> Dictionary:
	# per class and driver: dry and wet values per session kind
	var per := {}   # cls -> driver -> {"race": {"dry": [], "wet": []}, "quali": ..., "list": [String]}
	for key in Profiles.hist:
		var parts: PackedStringArray = str(key).split("|", true, 1)
		var cls := parts[0]
		var nm := parts[1]
		var d := {"list": []}
		for s in SESSIONS:
			d[s[0]] = {"dry": [], "wet": []}
		for rec in Profiles.hist[key]:
			for s in SESSIONS:
				var e: Dictionary = rec.get(s[1], {})
				if not e.has(s[2]):
					continue
				var share := float(rec.get(s[3], 0.0))
				if share >= WET:
					d[s[0]]["wet"].append(float(e[s[2]]))
					d["list"].append("%s %s %s" % [str(rec.get("date", "")).replace("_", "-"), rec.get("course", ""), s[0]])
				elif share < DRY:
					d[s[0]]["dry"].append(float(e[s[2]]))
		if not per.has(cls):
			per[cls] = {}
		per[cls][nm] = d

	# wet laps scatter more than dry ones: pooled over every class, the ratio of the two
	# session-to-session scatters (within drivers), so a class with few wet races borrows it
	var ratio := {}
	for s in SESSIONS:
		var w := _pooled(per, s[0], "wet")
		var dr := _pooled(per, s[0], "dry")
		ratio[s[0]] = clampf(w / dr, 1.0, 3.0) if w > 0.0 and dr > 0.0 else 1.5

	# raw wet-minus-dry gap per driver, with its sampling variance
	var raws := {}   # cls -> driver -> {"raw", "var", "n_wet", "n_dry"}
	for cls in per:
		raws[cls] = {}
		var noise := {}
		for s in SESSIONS:
			noise[s[0]] = DriverTrackFit.class_noise(cls, s[1], s[2], s[3])
		for nm in per[cls]:
			var d: Dictionary = per[cls][nm]
			var num := 0.0
			var den := 0.0
			var n_wet := 0
			var n_dry := 0
			for s in SESSIONS:
				var dry: Array = d[s[0]]["dry"]
				var wet: Array = d[s[0]]["wet"]
				if dry.size() < MIN_DRY or wet.is_empty():
					n_dry += dry.size()
					continue
				var sd: float = noise[s[0]]
				var sw: float = sd * float(ratio[s[0]])
				var v := sw * sw / wet.size() + sd * sd / dry.size()
				num += (_mean(wet) - _mean(dry)) / v
				den += 1.0 / v
				n_wet += wet.size()
				n_dry += dry.size()
			if den > 0.0:
				raws[cls][nm] = {"raw": num / den, "var": 1.0 / den, "n_wet": n_wet, "n_dry": n_dry, "list": d["list"]}

	# how much drivers really differ: spread of the raw gaps beyond what noise explains
	var excess := 0.0
	var count := 0
	for cls in raws:
		for nm in raws[cls]:
			var r: Dictionary = raws[cls][nm]
			if r["n_wet"] >= MIN_WET:
				excess += r["raw"] * r["raw"] - r["var"]
				count += 1
	var tau := TAU_MIN
	if count > 0:
		tau = clampf(sqrt(maxf(excess / count, 0.0)), TAU_MIN, TAU_MAX)

	var data := {}
	for cls in raws:
		data[cls] = {}
		for nm in raws[cls]:
			var r: Dictionary = raws[cls][nm]
			var keep: float = tau * tau / (tau * tau + r["var"])   # how much of the raw gap is believed
			var e := {"raw": r["raw"], "effect": r["raw"] * keep, "se": sqrt(r["var"] * keep),
				"n_wet": r["n_wet"], "n_dry": r["n_dry"], "wet_sessions": r["list"]}
			e["verdict"] = verdict(e)
			data[cls][nm] = e
	return {"data": data, "tau": tau, "ratio": ratio}


# Plain words for one driver's estimate.
static func verdict(e: Dictionary) -> String:
	if e.is_empty() or int(e.get("n_wet", 0)) == 0:
		return "no wet sessions yet"
	if int(e["n_wet"]) < MIN_WET:
		return "only %d wet session so far" % int(e["n_wet"])
	var eff := float(e["effect"])
	var z := absf(eff) / maxf(float(e["se"]), 1e-6)
	var way := "quicker" if eff < 0.0 else "slower"
	if z >= CONFIDENT:
		return "%.1f%% %s in the wet" % [absf(eff), way]
	if z >= EARLY:
		return "early sign: %.1f%% %s in the wet" % [absf(eff), way]
	return "no clear difference"


# Pooled within-driver scatter of one kind of value ("wet" / "dry") for one session kind.
static func _pooled(per: Dictionary, sess: String, kind: String) -> float:
	var ss := 0.0
	var dof := 0
	for cls in per:
		for nm in per[cls]:
			var xs: Array = per[cls][nm][sess][kind]
			if xs.size() < 2:
				continue
			var m := _mean(xs)
			for x in xs:
				ss += (x - m) * (x - m)
			dof += xs.size() - 1
	return sqrt(ss / dof) if dof >= 5 else 0.0


static func _mean(a: Array) -> float:
	var s := 0.0
	for x in a:
		s += float(x)
	return s / maxf(a.size(), 1)
