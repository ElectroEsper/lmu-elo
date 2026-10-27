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
}
const B_WEAR := 0.1    # % pace per (tyre-wear z of driver x tyre-wear z of track): hard-on-tyres drivers lose at tyre-killer tracks
const B_TOP := -0.1    # high-top-speed drivers gain at top-speed tracks
const B_FUEL := 0.1    # thirsty drivers lose at fuel-hungry tracks
const ELO_TO_PACE := -0.03   # fallback when a driver has no lap data: % pace per Elo point above 1500
const N_SIMS := 4000
const BACKTEST_SIMS := 300
const SETTINGS_PATH := "user://predict.json"

var params := DEFAULTS.duplicate()
var rng := RandomNumberGenerator.new()
var last_backtest := {}


func _ready() -> void:
	rng.randomize()
	_load_settings()


# ---------- Inputs ----------

# One dict per driver with everything the simulation needs.
# before = "" uses all data plus current Elo as a fallback (live forecast);
# before = a date replays history without peeking (backtest, no Elo).
func driver_inputs(names: Array, cls: String, before := "") -> Array:
	var cm = Profiles.class_means(cls, before)
	var sd = Profiles.trait_sd(cls, before)
	var out := []
	for nm in names:
		var s = Profiles.raw_stats(nm, cls, before)
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
		})
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
	for d in inputs:
		var adj: float = P["fit"] * (B_WEAR * d["wear_z"] * track["wear_z"]
			+ B_TOP * d["top_z"] * track["top_z"] + B_FUEL * d["fuel_z"] * track["fuel_z"])
		base.append(d["pace"] + adj)
		qbase.append(d["qpace"])
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
	var out := {"laps": laps, "pole": [], "front": [], "exp_grid": [], "win": [], "podium": [], "top10": [], "exp_pos": []}
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
func forecast(names: Array, cls: String, mode: int, course := "", minutes := 0, lap_s := 0.0) -> Dictionary:
	var notes := []
	if course == "":
		course = Profiles.latest_course()
	var track = Profiles.track_info(course, cls)
	if lap_s > 0.0:
		track["ref_s"] = lap_s
	if minutes > 0:
		track["minutes"] = minutes
	if not Profiles.has_data():
		notes.append("No lap-data fingerprints saved yet: drivers are rated from Elo only. Drop your XML folder to backfill them.")
	elif not track["known_race"]:
		notes.append("No earlier race at this track: lap time comes from quali (or a default), and tyre / fuel track effects are off.")
	var inputs := driver_inputs(names, cls)
	var res := await simulate(inputs, track, mode, N_SIMS)
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
		})
	rows.sort_custom(func(a, b): return a["exp_pos"] < b["exp_pos"])
	return {"rows": rows, "track": track, "laps": res["laps"], "notes": notes}


# ---------- Backtest ----------

# One record per past race with enough history: {"date", "cls", "course", "names" (in grid order), "pos"}
func backtest_races() -> Array:
	var races := []
	for day in Profiles.days:
		if day["race"].is_empty():
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
			races.append({"date": day["date"], "cls": cls, "course": day["course"], "names": names, "pos": pos})
	return races


# Scores one mode on the past races: podium + top-10 Brier (lower is better), winner log-loss.
func _score(races: Array, mode: int, sims: int, prm: Dictionary) -> Dictionary:
	var brier := 0.0
	var ll := 0.0
	for r in races:
		var inputs := driver_inputs(r["names"], r["cls"], r["date"])
		var track = Profiles.track_info(r["course"], r["cls"], r["date"], r["date"])
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
	out["modes"]["Actual grid"] = await _score(races, Mode.ACTUAL_GRID, BACKTEST_SIMS, {})
	out["modes"]["Predicted quali, then race"] = await _score(races, Mode.PREDICTED_QUALI, BACKTEST_SIMS, {})
	out["modes"]["Race only (no grid)"] = await _score(races, Mode.RACE_ONLY, BACKTEST_SIMS, {})
	last_backtest = out
	return out


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
