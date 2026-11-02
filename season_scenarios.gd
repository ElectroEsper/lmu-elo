class_name SeasonScenarios
extends RefCounted
## End-of-season scenarios for one championship (a series and class in a season):
##   - exact maths: each driver's best and worst possible final score with the rounds left
##     (dropped rounds included), who can still win the title, and what the leader needs at the
##     next round to clinch it;
##   - title chances: the rounds left are simulated with the predictor (each round at its track
##     and expected weather from Settings > Season calendar), every driver turning up as often as
##     they have this season;
##   - things to watch: close fights for places, streaks, the leading rookie.
## Use as: var sc = await SeasonScenarios.build("Season 6", "Multiclass GT3")

const TITLE_SIMS := 4000      # seasons simulated for the title chances
const ROUND_SIMS := 2000      # runs of each remaining round (title sims draw from these)
const CLOSE_GAP := 5          # points: a "close fight" for a place
const MAX_WATCH := 3


static func build(season: String, key: String) -> Dictionary:
	var ch: Dictionary = Reports.season_points(season).get(key, {})
	if ch.is_empty():
		return {}
	var code := _series_code(str(ch.get("series", "")))
	var season_n := int(season.trim_prefix("Season "))
	var done := int(ch["rounds"])
	var total := maxi(LeagueSettings.season_rounds(code), done)
	var left := total - done
	var pts_table: Array = LeagueSettings.points()
	var p1 := int(pts_table[0]) if not pts_table.is_empty() else 0
	# rounds still to come, from the calendar (a round not in it: track unknown, dry)
	var cal := {}
	for c in LeagueSettings.calendar_for(code, season_n):
		cal[int(c["round"])] = c
	var rounds_left := []
	for r in range(done + 1, total + 1):
		rounds_left.append(cal.get(r, {"round": r, "course": "", "weather": "dry", "rain": 0.0}))

	var drivers: Dictionary = ch["drivers"]
	var rows := []
	for d in drivers:
		var e: Dictionary = drivers[d]
		var pts := (e["by_round"] as Array).map(func(x): return int(x["pts"]))
		rows.append({"name": d, "points": int(e["points"]), "wins": int(e["wins"]), "pod": int(e["pod"]),
			"races": int(e["races"]), "by_round": e["by_round"],
			"max": final_score(pts + _filled(left, p1), total),
			"min": final_score(pts + _filled(left, 0), total)})
	rows.sort_custom(func(a, b):
		if a["points"] != b["points"]:
			return a["points"] > b["points"]
		return a["wins"] > b["wins"])
	# still in the fight: can reach the best of everyone else's worst case
	for r in rows:
		var bar := 0
		for o in rows:
			if o != r:
				bar = maxi(bar, int(o["min"]))
		r["alive"] = (left > 0 and int(r["max"]) >= bar) or (left == 0 and r == rows[0])
	var out := {"season": season, "key": key, "series": code, "cls": ch["cls"], "done": done, "total": total,
		"left": left, "rounds_left": rounds_left, "rows": rows}
	if left > 0 and rows.size() >= 2:
		out["clinch"] = clinch_next(rows, left, total, pts_table)
	out["watch"] = watch_items(rows, season, str(ch["cls"]))
	return out


# Season score: every round's points, the worst ones dropped as the settings say for `total` rounds.
static func final_score(pts: Array, total: int) -> int:
	var p := pts.duplicate()
	while p.size() < total:
		p.append(0)
	p.sort()
	var drops := LeagueSettings.drops_for(total)
	var s := 0
	for i in p.size():
		if i >= drops:
			s += int(p[i])
	return s


static func _filled(n: int, v: int) -> Array:
	var a := []
	for i in n:
		a.append(v)
	return a


# What the leader needs at the next round to be champion whatever happens after: the lowest
# place that still does it, even if the closest rival wins every round left (and wins the next
# one too when the leader does not). {} when the title cannot be settled at the next round.
static func clinch_next(rows: Array, left: int, total: int, pts_table: Array) -> Dictionary:
	var lead: Dictionary = rows[0]
	var p1 := int(pts_table[0])
	var lead_pts := (lead["by_round"] as Array).map(func(x): return int(x["pts"]))
	var best_place := 0
	for place in range(1, pts_table.size() + 1):
		var mine := final_score(lead_pts + [int(pts_table[place - 1])] + _filled(left - 1, 0), total)
		var beaten := false
		for o in rows:
			if o == lead or not o["alive"]:
				continue
			var theirs_next := p1   # the rival wins the next round, or is 2nd when the leader wins it
			if place == 1:
				theirs_next = int(pts_table[1]) if pts_table.size() > 1 else 0
			var o_pts := (o["by_round"] as Array).map(func(x): return int(x["pts"]))
			if final_score(o_pts + [theirs_next] + _filled(left - 1, p1), total) >= mine:
				beaten = true
				break
		if beaten:
			break
		best_place = place
	# place 0 = cannot be settled next round; -1 = settled whatever happens (even scoring nothing)
	if best_place == pts_table.size() and _safe_with(rows, lead_pts + _filled(left, 0), total, p1, left):
		best_place = -1
	return {"driver": lead["name"], "place": best_place}


# True when no rival can reach the leader's final score (leader scoring `lead_final_pts`).
static func _safe_with(rows: Array, lead_final_pts: Array, total: int, p1: int, left: int) -> bool:
	var mine := final_score(lead_final_pts, total)
	for o in rows.slice(1):
		var o_pts := (o["by_round"] as Array).map(func(x): return int(x["pts"]))
		if final_score(o_pts + _filled(left, p1), total) >= mine:
			return false
	return true


# Simulates the rounds left with the predictor; adds "title" (chance) to each row. Async.
static func title_chances(sc: Dictionary) -> void:
	var rows: Array = sc["rows"]
	for r in rows:
		r["title"] = 0.0
	if int(sc["left"]) == 0:
		rows[0]["title"] = 1.0
		return
	var names := []
	var attend := []
	for r in rows:
		names.append(r["name"])
		attend.append(clampf(float(r["races"]) / maxf(float(sc["done"]), 1.0), 0.05, 1.0))
	var pts_table: Array = LeagueSettings.points()
	# each round left: ROUND_SIMS finishing orders at its track and weather
	var round_orders := []
	for rd in sc["rounds_left"]:
		var plan := LeagueSettings.rules_for(str(sc["series"]), int(str(sc["season"]).trim_prefix("Season ")))
		plan["weather"] = str(rd.get("weather", "dry"))
		plan["rain"] = float(rd.get("rain", 0.5))
		plan["keep_orders"] = true
		var res: Dictionary = await Predict.forecast(names, str(sc["cls"]), Predict.Mode.PREDICTED_QUALI,
			str(rd.get("course", "")), 0, 0.0, str(sc["series"]), {}, plan)
		round_orders.append(res["orders"])
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var wins := []
	wins.resize(rows.size())
	wins.fill(0)
	var base := []
	var base_wins := []
	for r in rows:
		base.append((r["by_round"] as Array).map(func(x): return int(x["pts"])))
		base_wins.append(int(r["wins"]))
	for s in TITLE_SIMS:
		var extra := []
		for i in rows.size():
			extra.append([])
		for ro in round_orders:
			var order: PackedInt32Array = ro[rng.randi() % ro.size()]
			var place := 0
			var got := {}
			for idx in order:
				if rng.randf() > attend[idx]:
					continue   # did not turn up this round
				place += 1
				got[idx] = int(pts_table[place - 1]) if place <= pts_table.size() else 0
			for i in rows.size():
				extra[i].append(int(got.get(i, 0)))
		# champion: most points, ties to the most wins (level on both: either, by chance)
		var best := -1
		var best_score := -1
		var best_wins := -1
		for i in rows.size():
			var sc_i := final_score(base[i] + extra[i], int(sc["total"]))
			var w_i: int = int(base_wins[i]) + (extra[i] as Array).count(int(pts_table[0]))
			if sc_i > best_score or (sc_i == best_score and (w_i > best_wins or (w_i == best_wins and rng.randf() < 0.5))):
				best_score = sc_i
				best_wins = w_i
				best = i
		wins[best] += 1
	for i in rows.size():
		rows[i]["title"] = wins[i] / float(TITLE_SIMS)


# Close fights for places (not the title: that is the main table), ongoing podium streaks, the
# leading rookie. Short lines, most interesting first.
static func watch_items(rows: Array, season: String, cls: String) -> Array:
	var out := []
	# close fights between neighbours from P2 to P10
	for i in range(1, mini(rows.size() - 1, 10)):
		var gap := int(rows[i]["points"]) - int(rows[i + 1]["points"])
		if gap <= CLOSE_GAP and out.size() < 2:
			out.append({"kind": "fight", "text": "P%d-P%d: %s and %s, %s" % [i + 1, i + 2, Elo.pretty(rows[i]["name"]),
				Elo.pretty(rows[i + 1]["name"]), "level on points" if gap == 0 else "%d point%s apart" % [gap, "" if gap == 1 else "s"]]})
	# podium streaks still running (2+ rounds)
	var best_streak := {}
	for r in rows:
		var n := 0
		var br: Array = r["by_round"]
		for j in range(br.size() - 1, -1, -1):
			if int(br[j]["pos"]) >= 1 and int(br[j]["pos"]) <= 3:
				n += 1
			else:
				break
		if n >= 2 and n > int(best_streak.get("n", 0)):
			best_streak = {"n": n, "name": r["name"]}
	if not best_streak.is_empty():
		out.append({"kind": "streak", "text": "%s: on the podium in each of the last %d rounds" % [Elo.pretty(best_streak["name"]), best_streak["n"]]})
	# leading rookie: first races in this class are this season
	var veterans := {}
	for ev in Elo.history:
		if Elo.season_of(ev) == season:
			continue
		for c in ev["changes"]:
			if c["cls"] == cls and c["sess"] == "race":
				veterans[c["driver"]] = true
	for i in rows.size():
		if not veterans.has(rows[i]["name"]):
			out.append({"kind": "rookie", "text": "Top rookie: %s, P%d with %d points" % [Elo.pretty(rows[i]["name"]), i + 1, int(rows[i]["points"])]})
			break
	return out.slice(0, MAX_WATCH)


static func _series_code(series_name: String) -> String:
	var names: Dictionary = LeagueSettings.get_value("series_names")
	for c in names:
		if str(names[c]) == series_name:
			return str(c)
	return series_name.to_lower()
