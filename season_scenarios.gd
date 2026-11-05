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
const UNKNOWN_TRACK := "(track to be confirmed)"


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
# A team scenario (build_teams) simulates its drivers' championship and adds up each team.
static func title_chances(sc: Dictionary) -> void:
	var team_mode := bool(sc.get("team_mode", false))
	var dsc: Dictionary = sc["drivers_sc"] if team_mode else sc
	var rows: Array = sc["rows"]
	for r in rows:
		r["title"] = 0.0
	if rows.is_empty():
		return
	if int(sc["left"]) == 0:
		rows[0]["title"] = 1.0
		return
	var drows: Array = dsc["rows"]
	var attend := []
	for r in drows:
		attend.append(clampf(float(r["races"]) / maxf(float(dsc["done"]), 1.0), 0.05, 1.0))
	var pts_table: Array = LeagueSettings.points()
	var round_orders := await _round_orders(dsc)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var wins := []
	wins.resize(rows.size())
	wins.fill(0)
	var base := []
	var base_wins := []
	for r in drows:
		base.append((r["by_round"] as Array).map(func(x): return int(x["pts"])))
		base_wins.append(int(r["wins"]))
	var total := int(sc["total"])
	for s in TITLE_SIMS:
		var extra := _one_season(rng, round_orders, attend, pts_table, drows.size())
		# each driver's final score and wins
		var fin := []
		var w := []
		for i in drows.size():
			fin.append(final_score(base[i] + extra[i], total))
			w.append(int(base_wins[i]) + (extra[i] as Array).count(int(pts_table[0])))
		# champion: most points, ties to the most wins (level on both: either, by chance)
		var best := -1
		var best_score := -1
		var best_wins := -1
		for i in rows.size():
			var sc_i := 0
			var w_i := 0
			if team_mode:
				for m in rows[i]["member_idx"]:
					if int(m) >= 0:
						sc_i += int(fin[m])
						w_i += int(w[m])
					else:
						sc_i += 0
			else:
				sc_i = fin[i]
				w_i = w[i]
			if sc_i > best_score or (sc_i == best_score and (w_i > best_wins or (w_i == best_wins and rng.randf() < 0.5))):
				best_score = sc_i
				best_wins = w_i
				best = i
		wins[best] += 1
	for i in rows.size():
		rows[i]["title"] = wins[i] / float(TITLE_SIMS)


# Each round left: ROUND_SIMS finishing orders at its track and weather (indices into dsc rows).
static func _round_orders(dsc: Dictionary) -> Array:
	var names := (dsc["rows"] as Array).map(func(r): return r["name"])
	var round_orders := []
	for rd in dsc["rounds_left"]:
		var plan := LeagueSettings.rules_for(str(dsc["series"]), int(str(dsc["season"]).trim_prefix("Season ")))
		plan["weather"] = str(rd.get("weather", "dry"))
		plan["rain"] = float(rd.get("rain", 0.5))
		plan["keep_orders"] = true
		# a round whose track is not confirmed yet: general form only (a name no track has, so no
		# track fit and no track-specific pace), never quietly the latest track
		var course := str(rd.get("course", ""))
		var res: Dictionary = await Predict.forecast(names, str(dsc["cls"]), Predict.Mode.PREDICTED_QUALI,
			course if course != "" else UNKNOWN_TRACK, 0, 0.0, str(dsc["series"]), {}, plan)
		round_orders.append(res["orders"])
	return round_orders


# One simulated rest of the season: per driver, the points of each round left.
static func _one_season(rng: RandomNumberGenerator, round_orders: Array, attend: Array, pts_table: Array, n: int) -> Array:
	var extra := []
	for i in n:
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
		for i in n:
			extra[i].append(int(got.get(i, 0)))
	return extra


# ---------- teams ----------
# A team championship (one per series and class, Settings > Teams): each team scores both its
# drivers' points, each after their own dropped rounds. Teams with one driver set are left out (as
# in the team standings). Same shape as build(), rows being teams: "name", "members", "points",
# "wins", "pod", "max", "min", "alive", "member_idx" (rows of the drivers' scenario, -1 = no
# result yet); "drivers_sc" = the drivers' scenario the title chances are simulated with.
#   max: the two drivers finish 1-2 in every round left; min: neither scores again.
#   clinch: "place" -1 = champions whatever happens, 1 = champions with a 1-2 at the next round
#   (rivals at best 3-4 there, then 1-2 in every round after), 0 = not settled at the next round.
static func build_teams(season: String, key: String) -> Dictionary:
	var tp: Dictionary = Reports.team_points(season).get(key, {})
	var dsc := build(season, key)
	if tp.is_empty() or dsc.is_empty():
		return {}
	var left := int(dsc["left"])
	var total := int(dsc["total"])
	var pts_table: Array = LeagueSettings.points()
	var pt := func(place: int) -> int: return int(pts_table[place - 1]) if place <= pts_table.size() else 0
	var idx := {}
	for i in (dsc["rows"] as Array).size():
		idx[dsc["rows"][i]["name"]] = i
	var rows := []
	for tn in tp["teams"]:
		var e: Dictionary = tp["teams"][tn]
		var members: Array = (e["drivers"] as Array).map(func(d): return str(d["name"]))
		if members.size() < 2:
			continue
		var pts := []   # each member's points per round so far
		var mi := []
		for m in members:
			var i := int(idx.get(m, -1))
			mi.append(i)
			pts.append((dsc["rows"][i]["by_round"] as Array).map(func(x): return int(x["pts"])) if i >= 0 else [])
		rows.append({"name": str(tn), "members": members, "member_idx": mi, "pts": pts,
			"points": int(e["points"]), "wins": int(e["wins"]), "pod": int(e["pod"]),
			"max": _pair_score(pts, [pt.call(1), pt.call(2)], left, total),
			"min": _pair_score(pts, [0, 0], left, total)})
	rows.sort_custom(func(a, b):
		if a["points"] != b["points"]:
			return a["points"] > b["points"]
		return a["wins"] > b["wins"])
	for r in rows:
		var bar := 0
		for o in rows:
			if o != r:
				bar = maxi(bar, int(o["min"]))
		r["alive"] = (left > 0 and int(r["max"]) >= bar) or (left == 0 and r == rows[0])
	var out := {"season": season, "key": key, "series": dsc["series"], "cls": dsc["cls"], "done": dsc["done"],
		"total": total, "left": left, "rounds_left": dsc["rounds_left"], "rows": rows, "team_mode": true, "drivers_sc": dsc}
	if left > 0 and rows.size() >= 2:
		var lead: Dictionary = rows[0]
		var place := 0
		var safe := true
		for o in rows.slice(1):
			if int(o["max"]) >= int(lead["min"]):
				safe = false
		if safe:
			place = -1
		else:
			# a 1-2 at the next round, nothing after; each rival 3-4 there, then 1-2 in every round after
			var mine := _pair_score_next(lead["pts"], [pt.call(1), pt.call(2)], [0, 0], left, total)
			var settled := true
			for o in rows.slice(1):
				if bool(o["alive"]) and _pair_score_next(o["pts"], [pt.call(3), pt.call(4)], [pt.call(1), pt.call(2)], left, total) >= mine:
					settled = false
			place = 1 if settled else 0
		out["clinch"] = {"driver": lead["name"], "place": place}
	var watch := []
	for i in range(1, mini(rows.size() - 1, 6)):
		var gap := int(rows[i]["points"]) - int(rows[i + 1]["points"])
		if gap <= CLOSE_GAP and watch.size() < MAX_WATCH:
			watch.append({"kind": "fight", "text": "P%d-P%d: %s and %s, %s" % [i + 1, i + 2, rows[i]["name"], rows[i + 1]["name"],
				"level on points" if gap == 0 else "%d point%s apart" % [gap, "" if gap == 1 else "s"]]})
	out["watch"] = watch
	return out


# A team's final score when its two drivers score `each` (one value each) in every round left,
# whichever driver gets which (the better split, since drops are per driver).
static func _pair_score(pts: Array, each: Array, left: int, total: int) -> int:
	var a := final_score(pts[0] + _filled(left, each[0]), total) + final_score(pts[1] + _filled(left, each[1]), total)
	var b := final_score(pts[0] + _filled(left, each[1]), total) + final_score(pts[1] + _filled(left, each[0]), total)
	return maxi(a, b)


# The same with `next` at the next round and `after` in each round after it.
static func _pair_score_next(pts: Array, next: Array, after: Array, left: int, total: int) -> int:
	var best := 0
	for swap in [false, true]:
		var n0: int = next[1] if swap else next[0]
		var n1: int = next[0] if swap else next[1]
		var s := final_score(pts[0] + [n0] + _filled(left - 1, after[0]), total) + final_score(pts[1] + [n1] + _filled(left - 1, after[1]), total)
		best = maxi(best, s)
	return best


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
	var code := LeagueSettings.series_code(series_name)
	return code if code != "" else series_name.to_lower()
