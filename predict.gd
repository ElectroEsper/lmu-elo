extends Node

## Race prediction: grid + Elo -> Monte Carlo.
## Register as an autoload named "Predict" (Project Settings > Globals > Autoload),
## AFTER "Elo".
##
## Strength = W_GRID * z(-grid position) + W_ELO * z(race Elo)      (z = within the class field)
## Each simulated race adds Normal(0, sigma) noise to every strength and sorts.
## Before quali (no grid) strength = z(race Elo) alone.
## Backtested on 25 historical races: sigma ~1.2 was best for both modes.

const W_GRID := 1.0
const W_ELO_WITH_GRID := 0.5
const W_ELO_ALONE := 1.0
const DEFAULT_SIGMA := 1.2
const N_SIMS := 5000
const BACKTEST_SIMS := 800
const SIGMA_GRID := [0.6, 0.8, 1.0, 1.2, 1.5, 1.8]
const SETTINGS_PATH := "user://predict.json"

var sigma := DEFAULT_SIGMA
var last_backtest := {}   # summary of the last backtest run
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	_load_settings()


# ---------- Strengths ----------

static func _z(values: Array) -> Array:
	var n := values.size()
	if n == 0:
		return []
	var mean := 0.0
	for v in values:
		mean += float(v)
	mean /= n
	var variance := 0.0
	for v in values:
		variance += (float(v) - mean) * (float(v) - mean)
	var sd := sqrt(variance / n) + 1e-9
	var out := []
	for v in values:
		out.append((float(v) - mean) / sd)
	return out


## Current race ratings of one class: {name: rating}
func current_elo(cls: String) -> Dictionary:
	var out := {}
	for k in Elo.ratings:
		var parts: PackedStringArray = k.rsplit("|", true, 2)
		if parts[1] == cls and parts[2] == "race":
			out[parts[0]] = float(Elo.ratings[k]["r"])
	return out


## order: driver names. With use_grid the list is the starting grid (pole first).
## elo: {name: rating}; drivers missing from it get the starting rating.
func strengths(order: Array, elo: Dictionary, use_grid: bool) -> Array:
	var ratings := []
	var grid := []
	for i in order.size():
		ratings.append(float(elo.get(order[i], Elo.START)))
		grid.append(-float(i))
	var zr := _z(ratings)
	var out := []
	if use_grid:
		var zg := _z(grid)
		for i in order.size():
			out.append(W_GRID * zg[i] + W_ELO_WITH_GRID * zr[i])
	else:
		for i in order.size():
			out.append(W_ELO_ALONE * zr[i])
	return out


# ---------- Monte Carlo ----------

## Returns {"win": [...], "podium": [...], "top10": [...], "exp_pos": [...]} (fractions / places),
## one entry per driver in the same order as `scores`.
func simulate(scores: Array, sims := N_SIMS, sig := -1.0) -> Dictionary:
	var m := scores.size()
	var s := sigma if sig < 0.0 else sig
	var win := []
	var pod := []
	var t10 := []
	var psum := []
	for i in m:
		win.append(0)
		pod.append(0)
		t10.append(0)
		psum.append(0)
	var idx := range(m)
	var noisy := []
	noisy.resize(m)
	for _s in sims:
		for j in m:
			noisy[j] = float(scores[j]) + rng.randfn(0.0, s)
		var order := idx.duplicate()
		order.sort_custom(func(a, b): return noisy[a] > noisy[b])
		for p in m:
			var d: int = order[p]
			psum[d] += p + 1
			if p == 0:
				win[d] += 1
			if p < 3:
				pod[d] += 1
			if p < 10:
				t10[d] += 1
	var out := {"win": [], "podium": [], "top10": [], "exp_pos": []}
	for i in m:
		out["win"].append(win[i] / float(sims))
		out["podium"].append(pod[i] / float(sims))
		out["top10"].append(t10[i] / float(sims))
		out["exp_pos"].append(psum[i] / float(sims))
	return out


## Convenience for the UI: rows sorted by win chance, best first.
## [{"name", "grid" (0 if no grid), "elo", "win", "podium", "top10", "exp_pos"}]
func predict(order: Array, cls: String, use_grid: bool) -> Array:
	var elo := current_elo(cls)
	var res := simulate(strengths(order, elo, use_grid))
	var rows := []
	for i in order.size():
		rows.append({
			"name": order[i],
			"grid": i + 1 if use_grid else 0,
			"elo": float(elo.get(order[i], Elo.START)),
			"win": res["win"][i], "podium": res["podium"][i],
			"top10": res["top10"][i], "exp_pos": res["exp_pos"][i],
		})
	rows.sort_custom(func(a, b): return a["exp_pos"] < b["exp_pos"])
	return rows


# ---------- Backtest ----------

## One record per historical race: {"date", "cls", "grid", "actual", "elo"}.
## Pre-race ratings come from Elo.history ("before" values), so run "Recompute all" first
## if events were ever added out of date order. Races where fewer than half the field has a
## rating yet are skipped. Quali is paired with the race by the date in the file name.
func backtest_races() -> Array:
	var events := {}   # file -> draft
	for f in DirAccess.get_files_at("user://events"):
		if not f.ends_with(".json"):
			continue
		var d = JSON.parse_string(FileAccess.get_file_as_string("user://events/" + f))
		if d is Dictionary and d.has("orders") and d.has("file"):
			events[d["file"]] = d
	var quali_by_date := {}   # "2026_10_14" -> {cls: order}
	for file in events:
		var q: Dictionary = events[file]["orders"].get("quali", {})
		if not q.is_empty():
			var day: String = str(file).left(10)
			if not quali_by_date.has(day):
				quali_by_date[day] = {}
			for cls in q:
				quali_by_date[day][cls] = q[cls]
	var races := []
	for h in Elo.history:
		var file: String = h["file"]
		if not events.has(file):
			continue
		var race_orders: Dictionary = events[file]["orders"].get("race", {})
		for cls in race_orders:
			var actual: Array = race_orders[cls]
			var quali: Array = quali_by_date.get(file.left(10), {}).get(cls, [])
			if actual.size() < 6 or quali.is_empty():
				continue
			var before := {}
			var known := 0
			for c in h["changes"]:
				if c["sess"] == "race" and c["cls"] == cls:
					before[c["driver"]] = float(c["before"])
					if absf(float(c["before"]) - Elo.START) > 0.001:
						known += 1
			var grid := []
			for n in quali:
				if n in actual:
					grid.append(n)
			if grid.size() < 6 or known < actual.size() * 0.5:
				continue
			var act := []
			for n in actual:
				if n in grid:
					act.append(n)
			races.append({"date": file.left(10), "cls": cls, "grid": grid, "actual": act, "elo": before})
	return races


## Fits sigma on the history (podium + top-10 Brier score) and stores it.
## Call with `await Predict.run_backtest()`; yields between races so the UI stays alive.
func run_backtest() -> Dictionary:
	var races := backtest_races()
	var summary := {"races": races.size(), "table": [], "sigma": sigma}
	if races.size() < 5:
		summary["note"] = "Need at least 5 races with quali to fit sigma."
		last_backtest = summary
		return summary
	var best_score := INF
	for s in SIGMA_GRID:
		var pb := 0.0
		var tb := 0.0
		var ll := 0.0
		for r in races:
			var grid: Array = r["grid"]
			var res := simulate(strengths(grid, r["elo"], true), BACKTEST_SIMS, s)
			var m := grid.size()
			var pod_hit := 0.0
			var t10_hit := 0.0
			for i in m:
				var apos: int = (r["actual"] as Array).find(grid[i]) + 1
				pod_hit = 1.0 if apos <= 3 else 0.0
				t10_hit = 1.0 if apos <= 10 else 0.0
				pb += pow(res["podium"][i] - pod_hit, 2) / m
				tb += pow(res["top10"][i] - t10_hit, 2) / m
			var winner_i: int = grid.find(r["actual"][0])
			ll += -log(maxf(res["win"][winner_i], 1.0 / BACKTEST_SIMS))
			await get_tree().process_frame
		pb /= races.size()
		tb /= races.size()
		ll /= races.size()
		summary["table"].append({"sigma": s, "podium_brier": pb, "top10_brier": tb, "win_logloss": ll})
		if pb + tb < best_score:
			best_score = pb + tb
			summary["sigma"] = s
	sigma = summary["sigma"]
	_save_settings()
	last_backtest = summary
	return summary


# ---------- Settings ----------

func _save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"sigma": sigma}))
	f.close()


func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if data is Dictionary:
		sigma = float(data.get("sigma", DEFAULT_SIGMA))
