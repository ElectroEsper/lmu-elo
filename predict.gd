extends Node

## Lap-time Monte Carlo for races and qualifying.
## Register as an autoload named "Predict", AFTER "Elo", "Profiles" (and remove the old v1 one).
##
## For every simulated race each driver gets a total race time:
##   N laps x lap time x (1 + race pace + track-fit adjustment + that day's form)    drivers' own pace, in %
##   + grid place x seconds-per-place                                                  track position
##   + lap-to-lap scatter (their consistency, summed over N laps)
##   + expected track-limit cost, plus a small chance of a track-limit penalty
##   + contacts: lost time now, plus damage that slows every lap that follows
##   + pit stops: stops needed for the race distance (from the track's fuel use and the driver's
##     own fuel use) x the track's typical pit-lane loss
## Pace (race and quali) can also be adjusted by the driver's own history at this track and by
## their track tendencies applied to this track's characteristics (driver_track_fit.gd).
## Each of those three upgrades has a strength setting, off by default: test_upgrades() replays
## past races with each on and off and keeps only the ones that make the forecasts better.
## The finishing order is the order of total times. Qualifying works the same way on quali pace.
## Defaults were calibrated on the first 19 events (see the model-assumptions panel in the view).

enum Mode { ACTUAL_GRID, PREDICTED_QUALI, RACE_ONLY }

const DEFAULTS := {
	"sig_form": 0.5,   # day-to-day form noise, % of lap time, constant over the race
	"g_grid": 1.2,     # seconds lost per grid place (track position)
	"c0": 1.0,         # seconds lost per contact straight away
	"dmg": 0.15,       # % of lap time lost on every following lap, per contact (damage adds up)
	"tl_cost": 0.04,   # seconds per track-limit event (expected value of the penalties they cause)
	"tl_pen": 0.0016,  # chance that a track-limit event turns into a penalty
	"pen_s": 25.0,     # seconds lost per penalty
	"fit": 1.0,        # strength of driver-trait x track-trait effects (0 = switched off)
	"lap_noise": 1.0,  # multiplier on the drivers' lap-time scatter
	"sq": 0.8,         # quali noise, % of lap time
	"p_track": 0.0,    # strength of the driver's own history at this track (0 = off, 1 = full)
	"p_tend": 0.0,     # strength of the driver's track tendencies (0 = off, 1 = full)
	"pits": 0.0,       # no longer used: pit stops follow the race rules (kept so old settings files load)
	"traffic": 0.0,    # strength of multiclass traffic (0 = off, 1 = as measured)
}
const K_TRACK := 2.0   # sessions at a track before the driver's own history there gets half weight
const PIT_SD := 3.0    # seconds of scatter per pit stop
# Pit stops are not an upgrade any more: they follow the race rules (Settings > Race rules, or the
# Predict screen), and the backtest replays every past race under its own rules.
const UPGRADES := [["p_track", "Own history at the track"], ["p_tend", "Track tendencies"],
	["traffic", "Traffic (multiclass)"]]
const DEFAULT_PIT_LOSS := 60.0   # s per stop when neither the track nor the class has a measured one
# Multiclass traffic. Encounters per lap with another class (passing it, or being passed by it)
# = cars of that class x |1 - own lap time / their lap time|: checked on the league's races, this
# matches the passes counted lap by lap from the sector times (correlation 0.93, within 1% on
# average). Each encounter costs a random amount of time; these are its typical size, in % of the
# lap time, measured as the extra lap-to-lap scatter on laps with encounters (autumn 2026). No
# driver was found to be reliably better or worse in traffic, so it is the same for everyone:
# traffic makes multiclass races less predictable, it does not favour anyone.
const TRAFFIC_PASS := 0.35     # lapping a slower car
const TRAFFIC_PASSED := 0.10   # being lapped by a faster one
const SERIES_RACES := 6        # recent races of a series used for its length and its other classes
const B_WEAR := 0.1    # % pace per (tyre-wear z of driver x tyre-wear z of track): hard-on-tyres drivers lose at tyre-killer tracks
const B_TOP := -0.1    # high-top-speed drivers gain at top-speed tracks
const B_FUEL := 0.1    # thirsty drivers lose at fuel-hungry tracks
const ELO_TO_PACE := -0.009  # fallback when a driver has no lap data: % pace per Elo point above 1500
							 # (was -0.03 before the rating model change spread ratings ~3.4x wider)
const N_SIMS := 4000
const BACKTEST_SIMS := 300
const STRENGTHS := [0.5, 1.5]    # extra strengths tried for a kept upgrade (1.0 is the first test)
const UPGRADE_MARGIN := 0.0005   # an upgrade must lower the backtest error by more than this to be kept
const SETTINGS_PATH := "user://predict.json"

var params := DEFAULTS.duplicate()
var rng := RandomNumberGenerator.new()
var pit_rng := RandomNumberGenerator.new()   # separate, so pit stops do not shift the other random draws
var last_backtest := {}


func _ready() -> void:
	rng.randomize()
	pit_rng.randomize()
	_load_settings()


# ---------- Inputs ----------

# One dict per driver with everything the simulation needs.
# before = "" uses all data plus current Elo as a fallback (live forecast);
# before = a date replays history without peeking (backtest, no Elo).
# course: the track being forecast (for the track-history and tendency terms; "" = none).
func driver_inputs(names: Array, cls: String, before := "", course := "") -> Array:
	var cm = Profiles.class_means(cls, before)
	var sd = Profiles.trait_sd(cls, before)
	# shared by every driver: the tracks' characteristics and the class noise
	var values := TrackGrades.collect(cls)
	var class_sig := {
		"race": DriverTrackFit.class_noise(cls, "r", "pace_rel", "wet_r", before),
		"quali": DriverTrackFit.class_noise(cls, "q", "rel", "wet_q", before),
	}
	var out := []
	for nm in names:
		var s = Profiles.raw_stats(nm, cls, before)
		var fit := _track_terms(nm, cls, before, course, values, class_sig)
		var prior_r := 0.0
		var prior_q := 0.0
		var has_elo := false
		if before == "":
			var kr := "%s|%s|race" % [nm, cls]
			var kq := "%s|%s|quali" % [nm, cls]
			if Elo.ratings.has(kr) and Elo.ratings[kr]["d"] > 0:
				prior_r = ELO_TO_PACE * (float(Elo.ratings[kr]["r"]) - Elo.START)
				prior_q = prior_r
				has_elo = true
			if Elo.ratings.has(kq) and Elo.ratings[kq]["d"] > 0:
				prior_q = ELO_TO_PACE * (float(Elo.ratings[kq]["r"]) - Elo.START)
		out.append({
			"name": nm,
			"n_r": s["n_r"],
			"known": s["n_r"] > 0 or s["n_q"] > 0 or has_elo,
			"pace": Profiles.shrunk(s["pace"], s["n_r"], Profiles.K_PACE, prior_r),
			"qpace": Profiles.shrunk(s["qpace"], s["n_q"], Profiles.K_PACE, prior_q),
			"wear_z": Profiles.shrunk(s["wear"], s["n_wear"], Profiles.K_PACE, 0.0) / sd["wear"],
			"top_z": Profiles.shrunk(s["top"], s["n_top"], Profiles.K_PACE, 0.0) / sd["top"],
			"fuel_z": Profiles.shrunk(s["fuel"], s["n_fuel"], Profiles.K_PACE, 0.0) / sd["fuel"],
			"tl": Profiles.shrunk(s["tl"], s["n_r"], Profiles.K_RATE, cm["tl"]),
			"con": Profiles.shrunk(s["con"], s["n_r"], Profiles.K_RATE, cm["con"]),
			"cons": Profiles.shrunk(s["cons"], s["n_r"], Profiles.K_CONS, cm["cons"]),
			"fuel_rel": Profiles.shrunk(s["fuel"], s["n_fuel"], Profiles.K_PACE, 0.0),
			"track_gap_r": fit["gap_r"],
			"track_gap_q": fit["gap_q"],
			"tend": fit["tend"],
		})
	return out


# The driver's own history at this course (gap to their own average, pulled towards 0 with
# few visits) and their track tendencies applied to this course's characteristics. Only
# tendencies the profile actually reports (early sign or stronger, not "goes with ...") and only
# telemetry characteristics count: those are fixed, so a backtest cannot peek at later results.
# All in % of lap time, negative = quicker.
func _track_terms(nm: String, cls: String, before: String, course: String, values: Dictionary,
		class_sig: Dictionary) -> Dictionary:
	var out := {"gap_r": 0.0, "gap_q": 0.0, "tend": 0.0}
	if course == "":
		return out
	var f := DriverTrackFit.fit(nm, cls, before, values, class_sig, true)
	for t in f["tracks"]:
		if t["course"] != course:
			continue
		if t["race_y"] != null:
			out["gap_r"] = float(t["race_y"]) * t["races"] / (t["races"] + K_TRACK)
		if t["quali_y"] != null:
			out["gap_q"] = float(t["quali_y"]) * t["quali"] / (t["quali"] + K_TRACK)
	if values.has(course):
		for t in f["tendencies"]:
			var verdict := str(t.get("verdict", ""))
			if t.get("src", "") != "tel" or not t.has("effect") or not t.has("sd"):
				continue
			if not (verdict == "quicker" or verdict == "slower" or verdict.begins_with("early sign")):
				continue
			if not values[course].has(t["key"]) or float(t["sd"]) <= 0.0:
				continue
			var z := (float(values[course][t["key"]]) - float(t["mean"])) / float(t["sd"])
			out["tend"] += float(t["effect"]) * z
	return out


# ---------- Simulation ----------

func _poisson(lam: float) -> int:
	if lam <= 0.0:
		return 0
	if lam > 30.0:
		return maxi(0, roundi(lam + sqrt(lam) * rng.randfn()))
	var limit := exp(-lam)
	var k := 0
	var p := rng.randf()
	while p > limit:
		k += 1
		p *= rng.randf()
	return k


# Time lost to n_mean expected encounters (Poisson), each an exponential loss of mean s seconds;
# for many encounters the sum is drawn from its normal approximation.
func _traffic_loss(n_mean: float, s: float) -> float:
	if n_mean <= 0.0 or s <= 0.0:
		return 0.0
	var n := _poisson(n_mean)
	if n == 0:
		return 0.0
	if n > 20:
		return maxf(0.0, n * s + sqrt(n) * s * rng.randfn())
	var t := 0.0
	for k in n:
		t += -s * log(maxf(rng.randf(), 1e-9))
	return t


# Encounters per lap for one class: {"pass", "passed", "text"}. others = {class: {"n": cars,
# "ratio": their lap time / ours}}.
func traffic_rates(others: Dictionary) -> Dictionary:
	var out := {"pass": 0.0, "passed": 0.0, "text": ""}
	var parts := PackedStringArray()
	for c in others:
		var n := float(others[c]["n"])
		var ratio := float(others[c]["ratio"])
		if n <= 0.0 or ratio <= 0.0:
			continue
		var rate := n * absf(1.0 - 1.0 / ratio)
		if ratio > 1.0:
			out["pass"] += rate     # they are slower: we lap them
		else:
			out["passed"] += rate   # they are quicker: they lap us
		parts.append("%d %s (%s, about %.1f per lap)" % [roundi(n), LeagueSettings.label(str(c)), "lapping them" if ratio > 1.0 else "being lapped", rate])
	out["text"] = ", ".join(parts)
	return out


# For a track where the class has no race yet: energy range and tyre life from the class's use per
# km at its other tracks (x1, median), scaled to this track's length. Marks the track "estimated".
func fill_pit_data(track: Dictionary, cls: String, course: String, before := "") -> void:
	if track.has("tank_laps") and track.has("tyre_laps"):
		return
	var length := 0.0
	var energy := []
	var wear := []
	var limit := {"fuel": 0, "virtual energy": 0}
	for day in Profiles.days:
		if str(day["course"]) == course and float(day["track"].get("length", 0.0)) > 0.0:
			length = float(day["track"]["length"])
		if day["race"].is_empty() or (before != "" and str(day["date"]) >= before):
			continue
		var c: Dictionary = day["race"].get("classes", {}).get(cls, {})
		var f := float(c.get("fuel_km", 0.0))
		var v := float(c.get("ve_km", 0.0))
		if maxf(f, v) > 0.0:
			energy.append(maxf(f, v))
			limit["virtual energy" if v > f else "fuel"] += 1
		if float(c.get("wear_km", 0.0)) > 0.0:
			wear.append(float(c["wear_km"]))
	if length <= 0.0:
		return
	if not track.has("tank_laps") and not energy.is_empty():
		energy.sort()
		track["tank_laps"] = 100.0 / (float(energy[energy.size() / 2]) * length / 1000.0)
		track["energy_limit"] = "virtual energy" if limit["virtual energy"] > limit["fuel"] else "fuel"
		track["pit_estimated"] = true
	if not track.has("tyre_laps") and not wear.is_empty():
		wear.sort()
		track["tyre_laps"] = Profiles.TYRE_USABLE / (float(wear[wear.size() / 2]) * length / 1000.0)
		track["pit_estimated"] = true


# Typical pit-stop loss of a class over all its races (before a date, for backtests), for tracks
# without a measured one.
func class_pit_loss(cls: String, before := "") -> float:
	var xs := []
	for day in Profiles.days:
		if day["race"].is_empty() or (before != "" and str(day["date"]) >= before):
			continue
		var c: Dictionary = day["race"].get("classes", {}).get(cls, {})
		if float(c.get("pit_loss", 0.0)) > 0.0:
			xs.append(float(c["pit_loss"]))
	if xs.is_empty():
		return DEFAULT_PIT_LOSS
	xs.sort()
	return xs[xs.size() / 2]


func _plan_note(track: Dictionary, plan: Dictionary, minutes: int) -> String:
	var parts := PackedStringArray()
	if float(track.get("tank_laps", 0.0)) > 0.0:
		parts.append("%s lasts about %.0f laps at x%.1f" % [str(track.get("energy_limit", "fuel")).capitalize(),
			float(track["tank_laps"]) / maxf(float(plan.get("fuel", 1.0)), 0.01), float(plan.get("fuel", 1.0))])
	else:
		parts.append("no fuel data for this track yet")
	if float(track.get("tyre_laps", 0.0)) > 0.0:
		parts.append("tyres about %.0f laps at x%.1f" % [float(track["tyre_laps"]) / maxf(float(plan.get("tyre", 1.0)), 0.01), float(plan.get("tyre", 1.0))])
	if int(plan.get("min_stops", 0)) > 0:
		parts.append("at least %d stop%s by the rules" % [int(plan["min_stops"]), "" if int(plan["min_stops"]) == 1 else "s"])
	return "Pit stops expected: %s; about %.0f s lost per stop." % ["; ".join(parts), float(track.get("pit_loss", 0.0))]


# Typical lap time of class `other` divided by that of `cls` (> 1: the other class is slower).
# From the series' own races if the two classes met there; else from every race where they met;
# else from both classes' laps at this track (race laps, or quali laps scaled to race pace);
# else from both classes' average speed over all their races. 0 if nothing is known.
func class_ratio(cls: String, other: String, course: String, ctx := {}) -> float:
	if ctx.get("others", {}).has(other):
		return float(ctx["others"][other]["ratio"])
	var met := _met_ratio(cls, other)
	if met > 0.0:
		return met
	# through a class both have raced with (LMP3 -> GT3 -> Hyper)
	var classes := {}
	for day in Profiles.days:
		if not day["race"].is_empty():
			for c in day["race"].get("classes", {}):
				classes[c] = true
	var chain := []
	for x in classes:
		if x == cls or x == other:
			continue
		var a := _met_ratio(cls, x)
		var b := _met_ratio(x, other)
		if a > 0.0 and b > 0.0:
			chain.append(a * b)
	if not chain.is_empty():
		return _avg(chain)
	if course != "":
		var a := Profiles.track_info(course, cls)
		var b := Profiles.track_info(course, other)
		if a["ref_s"] != Profiles.DEFAULT_LAP_S and b["ref_s"] != Profiles.DEFAULT_LAP_S and float(a["ref_s"]) > 0.0:
			return float(b["ref_s"]) / float(a["ref_s"])
	# average speed (km/h) of each class over all its races: slower class = higher lap time
	var kmh := {cls: [], other: []}
	for day in Profiles.days:
		var cs: Dictionary = day["race"].get("classes", {}) if not day["race"].is_empty() else {}
		for c in [cls, other]:
			if cs.has(c) and float(cs[c].get("kmh", 0.0)) > 0.0:
				kmh[c].append(float(cs[c]["kmh"]))
	if kmh[cls].is_empty() or kmh[other].is_empty():
		return 0.0
	return _avg(kmh[cls]) / _avg(kmh[other])


# Median lap-time ratio other / cls over the races where both classes ran, 0 if they never met.
func _met_ratio(cls: String, other: String) -> float:
	var ratios := []
	for day in Profiles.days:
		var cs: Dictionary = day["race"].get("classes", {}) if not day["race"].is_empty() else {}
		if cs.has(cls) and cs.has(other) and float(cs[cls].get("ref_s", 0.0)) > 0.0 and float(cs[other].get("ref_s", 0.0)) > 0.0:
			ratios.append(float(cs[other]["ref_s"]) / float(cs[cls]["ref_s"]))
	if ratios.is_empty():
		return 0.0
	ratios.sort()
	return ratios[ratios.size() / 2]


func _avg(a: Array) -> float:
	var s := 0.0
	for x in a:
		s += float(x)
	return s / maxf(a.size(), 1)


# The classes that regularly race in a series (in at least half of its last SERIES_RACES races),
# fastest first. code "" = the series of the latest race.
func series_classes(code: String) -> Array:
	var seen := {}    # class -> [lap time / quickest class's lap time, per race]
	var races := 0
	for i in range(Profiles.days.size() - 1, -1, -1):
		var day: Dictionary = Profiles.days[i]
		if day.get("training", false) or day["race"].is_empty():
			continue
		if code == "":
			code = str(day.get("series", ""))
		if str(day.get("series", "")) != code:
			continue
		races += 1
		var cs: Dictionary = day["race"].get("classes", {})
		var quickest := INF
		for c in cs:
			if float(cs[c].get("ref_s", 0.0)) > 0.0:
				quickest = minf(quickest, float(cs[c]["ref_s"]))
		for c in cs:
			if not seen.has(c):
				seen[c] = []
			seen[c].append(float(cs[c].get("ref_s", 0.0)) / quickest if quickest < INF and float(cs[c].get("ref_s", 0.0)) > 0.0 else 9.0)
		if races >= SERIES_RACES:
			break
	var out := []
	for c in seen:
		if seen[c].size() * 2 >= races:
			out.append(c)
	out.sort_custom(func(a, b): return _avg(seen[a]) < _avg(seen[b]))
	return out


# What a series looks like for one class, from its last SERIES_RACES races with that class:
# {"races", "minutes" (typical length, 0 = unknown), "others": {class: {"n", "ratio"}}}.
# code "" = any series (the latest races of the class, whatever their series).
func series_context(code: String, cls: String, before := "") -> Dictionary:
	var mins := []
	var others := {}   # class -> {"n": [], "ratio": []}
	var races := 0
	if code == "":
		# any series: follow the series of the class's latest race (mixing series would put
		# classes on track together that never meet)
		for i in range(Profiles.days.size() - 1, -1, -1):
			var d: Dictionary = Profiles.days[i]
			if not d.get("training", false) and not d["race"].is_empty() and d["race"].get("classes", {}).has(cls) \
					and (before == "" or str(d["date"]) < before):
				code = str(d.get("series", ""))
				break
	for i in range(Profiles.days.size() - 1, -1, -1):
		var day: Dictionary = Profiles.days[i]
		if day.get("training", false) or day["race"].is_empty() or not day["race"].get("classes", {}).has(cls):
			continue
		if code != "" and str(day.get("series", "")) != code:
			continue
		if before != "" and str(day["date"]) >= before:
			continue
		races += 1
		var cs: Dictionary = day["race"]["classes"]
		if int(day["race"].get("minutes", 0)) > 0:
			mins.append(int(day["race"]["minutes"]))
		var ref := float(cs[cls].get("ref_s", 0.0))
		for c in cs:
			if c == cls or ref <= 0.0 or float(cs[c].get("ref_s", 0.0)) <= 0.0:
				continue
			if not others.has(c):
				others[c] = {"n": [], "ratio": []}
			others[c]["n"].append(float(cs[c].get("n", 0)))
			others[c]["ratio"].append(float(cs[c]["ref_s"]) / ref)
		if races >= SERIES_RACES:
			break
	var out := {"races": races, "minutes": 0, "others": {}, "series": code}
	if not mins.is_empty():
		mins.sort()
		out["minutes"] = mins[mins.size() / 2]
	for c in others:
		# a class that ran in under half of these races is not a regular part of the series
		if others[c]["n"].size() * 2 < races:
			continue
		var r: Array = others[c]["ratio"]
		r.sort()
		var n_sum := 0.0
		for x in others[c]["n"]:
			n_sum += x
		out["others"][c] = {"n": n_sum / others[c]["n"].size(), "ratio": r[r.size() / 2]}
	return out


# inputs: driver_inputs(...) in GRID ORDER when mode is ACTUAL_GRID (pole first).
# Returns arrays (same order as inputs): pole, front, exp_grid, win, podium, top10, exp_pos.
func simulate(inputs: Array, track: Dictionary, mode: int, sims: int, prm: Dictionary = {}) -> Dictionary:
	var P := params if prm.is_empty() else prm
	var m := inputs.size()
	var t_ref: float = track["ref_s"]
	var laps := maxi(1, int(float(track["minutes"]) * 60.0 / t_ref) + 1)
	var base := []        # % pace incl. track-fit adjustment
	var qbase := []
	var lap_sd := []      # seconds, summed over the race
	var tl_cost := []     # expected seconds lost to track limits
	var tl_pen := []      # penalty rate over the race
	var con_rate := []    # contacts over the race
	var stops := []       # planned pit stops per driver
	# pit stops: track["plan"] = {"pits": expected?, "fuel": x, "tyre": x, "min_stops": n}
	var plan: Dictionary = track.get("plan", {})
	var pit_loss := float(track.get("pit_loss", 0.0))
	var tank_laps := float(track.get("tank_laps", 0.0)) / maxf(float(plan.get("fuel", 1.0)), 0.01)
	var tyre_laps := float(track.get("tyre_laps", 0.0)) / maxf(float(plan.get("tyre", 1.0)), 0.01)
	var tr: Dictionary = track.get("traffic", {})
	var tr_on := float(P.get("traffic", 0.0))
	var n_pass := float(tr.get("pass", 0.0)) * laps     # expected encounters over the race
	var n_passed := float(tr.get("passed", 0.0)) * laps
	var s_pass := tr_on * TRAFFIC_PASS / 100.0 * t_ref       # seconds per encounter
	var s_passed := tr_on * TRAFFIC_PASSED / 100.0 * t_ref
	for d in inputs:
		var adj: float = P["fit"] * (B_WEAR * d["wear_z"] * track["wear_z"]
			+ B_TOP * d["top_z"] * track["top_z"] + B_FUEL * d["fuel_z"] * track["fuel_z"])
		var p_track := float(P.get("p_track", 0.0))
		var p_tend := float(P.get("p_tend", 0.0))
		base.append(d["pace"] + adj + p_track * float(d.get("track_gap_r", 0.0)) + p_tend * float(d.get("tend", 0.0)))
		qbase.append(d["qpace"] + p_track * float(d.get("track_gap_q", 0.0)) + p_tend * float(d.get("tend", 0.0)))
		var n_stops := 0
		if bool(plan.get("pits", false)) and pit_loss > 0.0:
			# Everyone gets the class's number of stops: drivers save fuel to make the strategy rather
			# than make an extra stop. Giving thirstier drivers their own (sometimes one more) stop made
			# the backtest worse (autumn 2026: log-loss 1.55 -> 1.66 on races with planned stops);
			# with the class count it improves slightly (Brier 0.2313 -> 0.2304).
			if tank_laps > 0.0:
				n_stops = maxi(n_stops, int(ceil(float(laps) / tank_laps)) - 1)
			if tyre_laps > 0.0:
				n_stops = maxi(n_stops, int(ceil(float(laps) / tyre_laps)) - 1)
			n_stops = maxi(n_stops, int(plan.get("min_stops", 0)))
		stops.append(n_stops)
		lap_sd.append(d["cons"] * P["lap_noise"] / 100.0 * t_ref * sqrt(laps))
		tl_cost.append(d["tl"] * laps * P["tl_cost"])
		tl_pen.append(d["tl"] * laps * P["tl_pen"])
		con_rate.append(d["con"] * laps)
	var pole := []
	var front := []
	var egrid := []
	var win := []
	var pod := []
	var t10 := []
	var epos := []
	for i in m:
		pole.append(0)
		front.append(0)
		egrid.append(0)
		win.append(0)
		pod.append(0)
		t10.append(0)
		epos.append(0)
	var tot := []
	tot.resize(m)
	var qs := []
	qs.resize(m)
	var gpos := []
	gpos.resize(m)
	var idx := range(m)
	var qidx := range(m)
	var by_total := func(a, b): return tot[a] < tot[b]
	var by_quali := func(a, b): return qs[a] < qs[b]
	for s in sims:
		# --- grid ---
		if mode == Mode.ACTUAL_GRID:
			for i in m:
				gpos[i] = i + 1
		else:
			for i in m:
				qs[i] = qbase[i] + rng.randfn(0.0, P["sq"])
			qidx.sort_custom(by_quali)
			for k in m:
				gpos[qidx[k]] = k + 1
				if k == 0:
					pole[qidx[k]] += 1
				if k < 2:
					front[qidx[k]] += 1
			for i in m:
				egrid[i] += gpos[i]
		# --- race ---
		for i in m:
			var t: float = laps * t_ref * (1.0 + (base[i] + rng.randfn(0.0, P["sig_form"])) / 100.0)
			if mode != Mode.RACE_ONLY:
				t += gpos[i] * P["g_grid"]
			t += rng.randfn() * lap_sd[i] + tl_cost[i]
			t += _poisson(tl_pen[i]) * P["pen_s"]
			for c in _poisson(con_rate[i]):
				t += P["c0"] + t_ref * P["dmg"] / 100.0 * laps * (1.0 - rng.randf())
			for k in stops[i]:
				t += pit_loss + pit_rng.randfn(0.0, PIT_SD)
			if tr_on > 0.0:
				t += _traffic_loss(n_pass, s_pass) + _traffic_loss(n_passed, s_passed)
			tot[i] = t
		idx.sort_custom(by_total)
		for k in m:
			var who: int = idx[k]
			epos[who] += k + 1
			if k == 0:
				win[who] += 1
			if k < 3:
				pod[who] += 1
			if k < 10:
				t10[who] += 1
		if s % 500 == 499:
			await get_tree().process_frame
	var f := float(sims)
	var out := {"laps": laps, "stops": stops, "pole": [], "front": [], "exp_grid": [], "win": [], "podium": [], "top10": [], "exp_pos": []}
	for i in m:
		out["pole"].append(pole[i] / f)
		out["front"].append(front[i] / f)
		out["exp_grid"].append(egrid[i] / f)
		out["win"].append(win[i] / f)
		out["podium"].append(pod[i] / f)
		out["top10"].append(t10[i] / f)
		out["exp_pos"].append(epos[i] / f)
	return out


# ---------- Live forecast ----------

# names: grid order (pole first) for ACTUAL_GRID, any order otherwise.
# course "" = the most recent track in the data; minutes / lap_s of 0 = take them from the data.
# Returns {"rows": [...sorted by expected finish...], "track": {...}, "laps": int, "notes": [...]}
# field: the other classes in the race and their car counts ({class: cars}), as set on the Predict
# screen; empty = take them from the series' recent races.
# plan: pit stops for this race, {"pits": expected?, "fuel": x, "tyre": x, "min_stops": n}, as set on
# the Predict screen; empty = the series' current rules.
func forecast(names: Array, cls: String, mode: int, course := "", minutes := 0, lap_s := 0.0, series := "",
		field := {}, plan := {}) -> Dictionary:
	var notes := []
	if course == "":
		course = Profiles.latest_course()
	var track = Profiles.track_info(course, cls)
	if lap_s > 0.0:
		track["ref_s"] = lap_s
	var ctx := series_context(series, cls)
	var series_name := str(LeagueSettings.get_value("series_names").get(series, series.to_upper())) if series != "" else ""
	if minutes > 0:
		track["minutes"] = minutes
	elif int(ctx["minutes"]) > 0:
		track["minutes"] = int(ctx["minutes"])
		notes.append("%d min: the usual length of %s races with %s." % [ctx["minutes"],
			series_name if series_name != "" else "the latest", LeagueSettings.label(cls)])
	if series != "" and int(ctx["races"]) == 0:
		notes.append("No %s race with %s yet: series length and traffic unknown." % [series_name, LeagueSettings.label(cls)])
	var others: Dictionary = ctx["others"]
	if not field.is_empty() or field.has("_set"):
		others = {}
		for c in field:
			if str(c) == "_set" or int(field[c]) <= 0:
				continue
			var ratio := class_ratio(cls, str(c), course, ctx)
			if ratio <= 0.0:
				notes.append("No lap times to compare %s with %s yet: left out of the traffic." % [LeagueSettings.label(str(c)), LeagueSettings.label(cls)])
				continue
			others[c] = {"n": float(field[c]), "ratio": ratio}
	track["traffic"] = traffic_rates(others)
	if float(params.get("traffic", 0.0)) > 0.0:
		if str(track["traffic"]["text"]) != "":
			notes.append("Traffic: %s." % track["traffic"]["text"])
		else:
			notes.append("Traffic: none (no other class in %s)." % ("these races" if series == "" else series_name + " races"))
	if not Profiles.has_data():
		notes.append("No lap-data fingerprints saved yet: drivers are rated from Elo only. Drop your XML folder to backfill them.")
	elif not track["known_race"]:
		notes.append("No earlier race at this track: lap time comes from quali (or a default), and tyre / fuel track effects are off.")
	var inputs := driver_inputs(names, cls, "", course)
	var on := []
	for u in UPGRADES:
		if float(params.get(u[0], 0.0)) > 0.0:
			on.append(u[1].to_lower())
	if not on.is_empty():
		notes.append("Upgrades on: " + ", ".join(PackedStringArray(on)) + ".")
	if plan.is_empty():
		plan = LeagueSettings.rules_for(series if series != "" else str(ctx.get("series", "")), 0)
	track["plan"] = plan
	if bool(plan.get("pits", false)):
		if not track.has("pit_loss"):
			track["pit_loss"] = class_pit_loss(cls)
		fill_pit_data(track, cls, course)
		notes.append(_plan_note(track, plan, int(track["minutes"])))
		if track.get("pit_estimated", false):
			notes.append("No %s race at this track yet: fuel / energy and tyre use estimated from the class's other tracks." % LeagueSettings.label(cls))
	else:
		notes.append("No planned pit stops (as set for this race).")
	var res := await simulate(inputs, track, mode, N_SIMS)
	if bool(plan.get("pits", false)):
		var counts := {}
		for n in res["stops"]:
			counts[n] = int(counts.get(n, 0)) + 1
		var parts := PackedStringArray()
		var ks := counts.keys()
		ks.sort()
		for k in ks:
			parts.append("%d driver%s %d stop%s" % [counts[k], "" if counts[k] == 1 else "s", k, "" if k == 1 else "s"])
		notes.append("Planned stops: " + ", ".join(parts) + ".")
	var rows := []
	for i in inputs.size():
		var d: Dictionary = inputs[i]
		rows.append({
			"name": d["name"],
			"grid": i + 1 if mode == Mode.ACTUAL_GRID else 0,
			"pace": d["pace"], "qpace": d["qpace"], "n_r": d["n_r"], "known": d["known"],
			"pole": res["pole"][i], "front": res["front"][i], "exp_grid": res["exp_grid"][i],
			"win": res["win"][i], "podium": res["podium"][i], "top10": res["top10"][i],
			"exp_pos": res["exp_pos"][i],
			"stops": res["stops"][i],
			"track_gap": d["track_gap_r"], "tend": d["tend"],
		})
	rows.sort_custom(func(a, b): return a["exp_pos"] < b["exp_pos"])
	return {"rows": rows, "track": track, "laps": res["laps"], "notes": notes}


# ---------- Backtest ----------

# One record per past race with enough history: {"date", "cls", "course", "names" (in grid order), "pos"}
func backtest_races() -> Array:
	var races := []
	for day in Profiles.days:
		if day["race"].is_empty() or day.get("training", false):
			continue
		for cls in day["race"]["classes"]:
			var rows := []
			for nm in day["race"]["drivers"]:
				var r: Dictionary = day["race"]["drivers"][nm]
				if r["cls"] == cls and r["grid"] > 0 and r["pos"] > 0:
					rows.append({"name": nm, "grid": r["grid"], "pos": r["pos"]})
			if rows.size() < 8:
				continue
			var known := 0
			for r in rows:
				if Profiles.raw_stats(r["name"], cls, day["date"])["n_r"] > 0:
					known += 1
			if known < rows.size() * 0.5:
				continue
			rows.sort_custom(func(a, b): return a["grid"] < b["grid"])
			var names := []
			var pos := []
			for r in rows:
				names.append(r["name"])
				pos.append(r["pos"])
			var others := {}
			var cs: Dictionary = day["race"]["classes"]
			for c in cs:
				if c != cls and float(cs[c].get("ref_s", 0.0)) > 0.0 and float(cs[cls].get("ref_s", 0.0)) > 0.0:
					others[c] = {"n": float(cs[c].get("n", 0)), "ratio": float(cs[c]["ref_s"]) / float(cs[cls]["ref_s"])}
			races.append({"date": day["date"], "cls": cls, "course": day["course"], "names": names, "pos": pos,
				"others": others, "series": str(day.get("series", "")), "rules": day.get("rules", {})})
	return races


# Scores one mode on the past races: podium + top-10 Brier (lower is better), winner log-loss.
# cache (optional): race index -> {"inputs", "track"}, filled on first use, so several variants
# of the assumptions can be scored without recomputing every driver's history.
func _score(races: Array, mode: int, sims: int, prm: Dictionary, cache := {}) -> Dictionary:
	var brier := 0.0
	var ll := 0.0
	for ri in races.size():
		var r: Dictionary = races[ri]
		if not cache.has(ri):
			cache[ri] = {
				"inputs": driver_inputs(r["names"], r["cls"], r["date"], r["course"]),
				"track": Profiles.track_info(r["course"], r["cls"], r["date"], r["date"]),
			}
			cache[ri]["track"]["traffic"] = traffic_rates(r.get("others", {}))
			cache[ri]["track"]["plan"] = r.get("rules", {})
			if bool(r.get("rules", {}).get("pits", false)):
				if not cache[ri]["track"].has("pit_loss"):
					cache[ri]["track"]["pit_loss"] = class_pit_loss(r["cls"], r["date"])
				fill_pit_data(cache[ri]["track"], r["cls"], r["course"], r["date"])
		var inputs: Array = cache[ri]["inputs"]
		var track: Dictionary = cache[ri]["track"]
		var res := await simulate(inputs, track, mode, sims, prm)
		var m: int = inputs.size()
		var b := 0.0
		var winner := 0
		for i in m:
			var pos: int = r["pos"][i]
			b += pow(res["podium"][i] - (1.0 if pos <= 3 else 0.0), 2) / m
			b += pow(res["top10"][i] - (1.0 if pos <= 10 else 0.0), 2) / m
			if pos == 1:
				winner = i
		brier += b
		ll += -log(maxf(res["win"][winner], 1.0 / sims))
		await get_tree().process_frame
	return {"brier": brier / races.size(), "ll": ll / races.size()}


# Replays history in all three modes with the current assumptions.
# Use as: var s = await Predict.run_backtest()
func run_backtest() -> Dictionary:
	var races := backtest_races()
	var out := {"races": races.size(), "modes": {}}
	if races.size() < 4:
		out["note"] = "Need at least 4 past races with lap data. Drop your XML folder to backfill fingerprints."
		last_backtest = out
		return out
	# fixed random draws, so pressing Backtest twice gives the same numbers and settings compare fairly
	rng.seed = 20261028
	pit_rng.seed = 7
	out["modes"]["Actual grid"] = await _score(races, Mode.ACTUAL_GRID, BACKTEST_SIMS, {})
	out["modes"]["Predicted quali, then race"] = await _score(races, Mode.PREDICTED_QUALI, BACKTEST_SIMS, {})
	out["modes"]["Race only (no grid)"] = await _score(races, Mode.RACE_ONLY, BACKTEST_SIMS, {})
	rng.randomize()
	pit_rng.randomize()
	last_backtest = out
	return out


# Replays past races with each upgrade off and on (same random draws for every variant, so the
# comparison is fair), in both forecast modes, and switches on only the upgrades that make the
# forecasts better, then checks them together. Slow: a minute or more on a big archive.
# Returns {"races", "rows": [{"name", "brier", "ll"}], "on": [names kept], "note"?}
func test_upgrades() -> Dictionary:
	var races := backtest_races()
	var out := {"races": races.size(), "rows": [], "on": [], "strength": {}}
	if races.size() < 4:
		out["note"] = "Need at least 4 past races with lap data."
		return out
	var cache := {}
	var base := params.duplicate()
	for u in UPGRADES:
		base[u[0]] = 0.0
	var b0 := await _score_both(races, base, cache)
	out["rows"].append({"name": "Without upgrades", "brier": b0["brier"], "ll": b0["ll"]})
	var keep := base.duplicate()
	for u in UPGRADES:
		var prm := base.duplicate()
		prm[u[0]] = 1.0
		var sc := await _score_both(races, prm, cache)
		out["rows"].append({"name": "+ " + u[1], "brier": sc["brier"], "ll": sc["ll"]})
		if sc["brier"] < b0["brier"] - UPGRADE_MARGIN:
			keep[u[0]] = 1.0
			out["on"].append(u[1])
	# strength: each kept upgrade that has a strength (not the on/off pit stops) is also tried
	# at half and one-and-a-half, keeping whichever scores best
	for u in UPGRADES:
		if u[0] == "pits" or keep[u[0]] <= 0.0:
			continue
		var best_v := 1.0
		var best_b := INF
		for row in out["rows"]:
			if row["name"] == "+ " + u[1]:
				best_b = row["brier"]
		for v in STRENGTHS:
			var prm := base.duplicate()
			prm[u[0]] = v
			var sc := await _score_both(races, prm, cache)
			out["rows"].append({"name": "  %s at %.1f" % [u[1], v], "brier": sc["brier"], "ll": sc["ll"]})
			if sc["brier"] < best_b - UPGRADE_MARGIN:   # 1.0 stays unless another strength is clearly better
				best_b = sc["brier"]
				best_v = v
		keep[u[0]] = best_v
		out["strength"][u[1]] = best_v
	if out["on"].size() > 1:
		var together := await _score_both(races, keep, cache)
		out["rows"].append({"name": "Kept upgrades together", "brier": together["brier"], "ll": together["ll"]})
		if together["brier"] >= b0["brier"]:
			keep = base.duplicate()
			out["on"] = []
	for u in UPGRADES:
		params[u[0]] = keep[u[0]]
	save_settings()
	rng.randomize()
	pit_rng.randomize()
	return out


# Average of the actual-grid and predicted-quali scores, with fixed random draws
func _score_both(races: Array, prm: Dictionary, cache: Dictionary) -> Dictionary:
	rng.seed = 20261028
	pit_rng.seed = 7
	var a := await _score(races, Mode.ACTUAL_GRID, BACKTEST_SIMS, prm, cache)
	rng.seed = 20261029
	pit_rng.seed = 8
	var q := await _score(races, Mode.PREDICTED_QUALI, BACKTEST_SIMS, prm, cache)
	return {"brier": (a["brier"] + q["brier"]) / 2.0, "ll": (a["ll"] + q["ll"]) / 2.0}


# Tries a few race-day-noise levels (actual-grid mode) and keeps the best. Slow: a few tens of seconds.
func fit_noise() -> Dictionary:
	var races := backtest_races()
	var out := {"races": races.size(), "table": []}
	if races.size() < 4:
		out["note"] = "Need at least 4 past races with lap data."
		return out
	var best := INF
	var best_val := float(params["sig_form"])
	for v in [0.3, 0.4, 0.5, 0.6, 0.7]:
		var prm := params.duplicate()
		prm["sig_form"] = v
		var sc := await _score(races, Mode.ACTUAL_GRID, BACKTEST_SIMS, prm)
		out["table"].append({"sig_form": v, "brier": sc["brier"], "ll": sc["ll"]})
		if sc["brier"] < best:
			best = sc["brier"]
			best_val = v
	params["sig_form"] = best_val
	save_settings()
	out["best"] = best_val
	return out


# ---------- Settings ----------

func reset_params() -> void:
	params = DEFAULTS.duplicate()
	save_settings()


func save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"params": params}))
	f.close()


func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if data is Dictionary and data.get("params") is Dictionary:
		for k in DEFAULTS:
			if data["params"].has(k):
				params[k] = float(data["params"][k])
