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
			# level on points: more wins takes it (as the standings and the "What it takes" page)
			var mine_w := int(lead["wins"]) + (1 if place == 1 else 0)
			var theirs_w := int(o["wins"]) + (1 if theirs_next == p1 else 0) + (left - 1)
			if not _beats(mine, mine_w, final_score(o_pts + [theirs_next] + _filled(left - 1, p1), total), theirs_w):
				beaten = true
				break
		if beaten:
			break
		best_place = place
	# place 0 = cannot be settled next round; -1 = settled whatever happens (even scoring nothing)
	if best_place == pts_table.size() and _safe_with(rows, lead_pts + _filled(left, 0), total, p1, left, int(lead["wins"])):
		best_place = -1
	return {"driver": lead["name"], "place": best_place}


# True when no rival can reach the leader's final score (leader scoring `lead_final_pts`).
static func _safe_with(rows: Array, lead_final_pts: Array, total: int, p1: int, left: int, lead_wins := 0) -> bool:
	var mine := final_score(lead_final_pts, total)
	for o in rows.slice(1):
		var o_pts := (o["by_round"] as Array).map(func(x): return int(x["pts"]))
		if not _beats(mine, lead_wins, final_score(o_pts + _filled(left, p1), total), int(o["wins"]) + left):
			return false
	return true


# Ahead at the end: more points, or level on points with more wins.
static func _beats(score: int, wins: int, o_score: int, o_wins: int) -> bool:
	return score > o_score or (score == o_score and wins > o_wins)


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


# ---------- what each contender needs ----------
# For each of the top 3 (drivers' championships), plain lines on what it takes to be champion,
# against every driver who can still win it (not only the leader), naming only the ones that
# actually constrain him:
#   - where he stands against the others in the fight (status);
#   - whether winning every round left is enough on its own (2+ rounds left);
#   - what makes him champion at the next round, place by place, with where each rival must finish
#     (at the last round: everything; before: only when it can already be settled there);
#   - what keeps him in the fight at the next round, rival by rival (2+ rounds left).
# [{"name", "place", "points", "max", "alive", "status", "lines": [...]}]. Exact maths under the
# same rules as the standings (dropped rounds; level on points: more wins).
const NEEDS_MAX_LINES := 5
const NEEDS_MAX_SHOWN := 3   # conditional place lines shown (the places checked go down the whole field)

static func requirements(sc: Dictionary) -> Array:
	var rows: Array = sc["rows"]
	var left := int(sc["left"])
	var total := int(sc["total"])
	var pts_table: Array = LeagueSettings.points()
	var pt := func(place: int) -> int: return int(pts_table[place - 1]) if place >= 1 and place <= pts_table.size() else 0
	var p1: int = pt.call(1)
	var p2: int = pt.call(2)
	var base := func(r: Dictionary) -> Array: return (r["by_round"] as Array).map(func(x): return int(x["pts"]))
	# final [score, wins] with `future` points in the rounds left
	var fin := func(r: Dictionary, future: Array) -> Array:
		return [final_score(base.call(r) + future, total), int(r["wins"]) + future.count(p1)]
	var ahead := func(a: Array, b: Array) -> bool: return a[0] > b[0] or (a[0] == b[0] and a[1] > b[1])
	# short names (surname) unless two drivers share one
	var surname := {}
	var count := {}
	for r in rows:
		var parts := Elo.pretty(str(r["name"])).split(" ", false)
		var sn: String = parts[parts.size() - 1] if parts.size() > 0 else str(r["name"])
		surname[r["name"]] = sn
		count[sn] = int(count.get(sn, 0)) + 1
	var nm := func(r: Dictionary) -> String:
		var sn: String = surname[r["name"]]
		return sn if int(count[sn]) == 1 else Elo.pretty(str(r["name"]))
	var nxt := ""
	if left > 0:
		nxt = "R%d" % int(sc["rounds_left"][0]["round"])
	# the field: the most cars of the class in one round this season (places beyond it never happen)
	var field := 0
	if not rows.is_empty():
		for i in (rows[0]["by_round"] as Array).size():
			var n := 0
			for r in rows:
				if i < (r["by_round"] as Array).size() and int(r["by_round"][i]["pos"]) > 0:
					n += 1
			field = maxi(field, n)
	field = maxi(int(sc.get("field", field)), 2)   # (a test can set the field size)
	var out := []
	for ci in mini(3, rows.size()):
		var c: Dictionary = rows[ci]
		var rivals := rows.filter(func(o): return o != c and bool(o["alive"]))
		var e := {"name": c["name"], "place": ci + 1, "points": int(c["points"]), "max": int(c["max"]), "alive": bool(c["alive"]), "lines": []}
		# status: the gaps to the others in the fight (top 3 and anyone close)
		var gaps := []
		for o in rows.slice(0, 4):
			if o == c or (not bool(o["alive"]) and o != rows[0]):
				continue
			var g := int(c["points"]) - int(o["points"])
			gaps.append(("%d ahead of %s" % [g, nm.call(o)]) if g > 0 else (("%d behind %s" % [-g, nm.call(o)]) if g < 0 else "level with %s" % nm.call(o)))
		e["status"] = ", ".join(PackedStringArray(gaps.slice(0, 2)))
		var lines: Array = e["lines"]
		if left == 0:
			lines.append("Champion" if ci == 0 else "Finished P%d" % (ci + 1))
			out.append(e)
			continue
		if not bool(c["alive"]):
			lines.append("Out of the title fight: even winning every round left is not enough")
			out.append(e)
			continue
		# 1. winning every round left: enough whatever the others do (they can be second at best)?
		if left > 1:
			var all_wins: Array = fin.call(c, _filled(left, p1))
			var spoiler := {}
			for o in rivals:
				if not ahead.call(all_wins, fin.call(o, _filled(left, p2))):
					spoiler = o
					break
			if spoiler.is_empty():
				lines.append("Champion by winning every round left, whatever the others do")
			else:
				lines.append("Needs help: even winning every round left, %s could beat him by finishing second every time" % nm.call(spoiler))
		# 2. champion at the next round: for each of his places there, where each rival must finish
		#    (rivals then win every round after; he scores nothing more)
		var places := []   # [q, needs]
		for q in range(1, mini(field, pts_table.size()) + 1):   # every place, as the title fight page does
			var mine: Array = fin.call(c, [pt.call(q)] + _filled(left - 1, 0))
			var needs := []
			var possible := true
			for o in rivals:
				var worst_ok := 0   # the best place the rival can take and still finish behind
				for k in range(1, pts_table.size() + 2):
					if k == q:
						continue
					if ahead.call(mine, fin.call(o, [pt.call(k)] + _filled(left - 1, p1))):
						worst_ok = k
						break
				if worst_ok == 0:
					possible = false
					break
				if worst_ok > 1 and not (worst_ok == 2 and q == 1):
					needs.append([o, worst_ok])
			if not possible:
				break
			places.append([q, needs])
		var cond := func(needs: Array) -> String:
			var parts := PackedStringArray()
			for nd in needs.slice(0, 3):
				# a place beyond the field: he must not score at all
				parts.append("%s scores nothing" % nm.call(nd[0]) if int(nd[1]) > field else "%s P%d or lower" % [nm.call(nd[0]), nd[1]])
			var txt := " and ".join(parts)
			if needs.size() > 3:
				txt += ", with %d other%s behind too" % [needs.size() - 3, "" if needs.size() == 4 else "s"]
			return txt
		# safe even scoring nothing there (every rival winning everything)
		var safe_blank := true
		for o in rivals:
			if not ahead.call(fin.call(c, _filled(left, 0)), fin.call(o, _filled(left, p1))):
				safe_blank = false
		if safe_blank:
			lines.append("Already champion, whatever happens")
			e["lines"] = lines.slice(0, NEEDS_MAX_LINES)
			out.append(e)
			continue
		var free_upto := 0
		for pl in places:
			if (pl[1] as Array).is_empty() and free_upto == int(pl[0]) - 1:
				free_upto = int(pl[0])
		var at := " at %s" % nxt if left > 1 else ""
		if free_upto > 0:
			lines.append("Champion%s %s, whatever the others do" % [at, "by winning" if free_upto == 1 else "with P%d or better" % free_upto])
		var shown := 0
		for pl in places:
			if int(pl[0]) <= free_upto or shown >= (NEEDS_MAX_SHOWN if left == 1 else 2):
				continue
			if left > 1 and (pl[1] as Array).size() > 2:
				continue   # before the last round: a long shot needing three rivals to falter is left out
			var what := "a win" if int(pl[0]) == 1 else "P%d" % int(pl[0])
			lines.append(("%s: champion if %s" % ["A win" if int(pl[0]) == 1 else what, cond.call(pl[1])]) if left == 1
				else "Champion%s with %s if %s" % [at, what, cond.call(pl[1])])
			shown += 1
		if places.is_empty():
			lines.append("Cannot be champion: even a win is not enough" if left == 1 else "Cannot be champion yet at %s: the fight goes on" % nxt)
		# 3. staying in the fight at the next round, rival by rival (each rival winning there and
		#    scoring nothing after, him winning every round after)
		if left > 1:
			var keeps := []   # [rival, worst place that keeps him in, or -1: out if that rival is ahead]
			for o in rivals:
				var safe0: bool = ahead.call(fin.call(c, [0] + _filled(left - 1, p1)), fin.call(o, [p1] + _filled(left - 1, 0)))
				if safe0:
					continue
				var keep := 0
				for q in range(1, pts_table.size() + 1):
					var mine: Array = fin.call(c, [pt.call(q)] + _filled(left - 1, p1))
					var theirs: Array = fin.call(o, [p2 if q == 1 else p1] + _filled(left - 1, 0))
					if ahead.call(mine, theirs):
						keep = q
					else:
						break
				# even winning is not enough against this rival: the places of his that knock him out
				var out_at := 0
				if keep == 0:
					var win_max: Array = fin.call(c, [p1] + _filled(left - 1, p1))
					for k in range(2, pts_table.size() + 1):
						if ahead.call(win_max, fin.call(o, [pt.call(k)] + _filled(left - 1, 0))):
							break
						out_at = k
				keeps.append([o, keep, out_at])
			if keeps.is_empty():
				lines.append("Still in the fight after %s, whatever happens" % nxt)
			else:
				keeps.sort_custom(func(a, b): return int(a[1]) < int(b[1]))
				var parts := PackedStringArray()
				var scores_only := true
				var threat: Dictionary = keeps[0][0]   # who a DNS (no points) would let through
				for kp in keeps:
					var k := int(kp[1])
					if k >= field or k >= pts_table.size():
						continue   # scoring is enough against this one
					if parts.size() >= 3:
						break
					scores_only = false
					parts.append(("out if %s finishes P%d or better" % [nm.call(kp[0]), kp[2]] if int(kp[2]) >= 2 else "out if %s scores" % nm.call(kp[0])) if k == 0
						else "%s if %s wins there" % ["a win" if k == 1 else "P%d or better" % k, nm.call(kp[0])])
				if scores_only:
					lines.append("Stays in the fight at %s as long as he scores (a DNS and a %s win would end it)" % [nxt, nm.call(threat)])
				else:
					lines.append("To stay in the fight at %s: %s" % [nxt, "; ".join(parts)])
		# 4. the swing at the next round (2+ rounds left), from the standings after it: him winning
		#    with his nearest rival second (or, for the leader, that rival winning with him second)
		if left > 1 and not rivals.is_empty():
			var done := total - left
			var after := func(r: Dictionary, x: int) -> int: return final_score(base.call(r) + [x], done + 1)
			var near: Dictionary = rows[1] if ci == 0 else rows[0]
			var later := "the final round" if left == 2 else "R%d" % (int(sc["rounds_left"][0]["round"]) + 1)
			if ci == 0:
				var g: int = after.call(c, p2) - after.call(near, p1)
				lines.append("If %s wins at %s with him second: %s going to %s" % [nm.call(near), nxt,
					("still %d ahead" % g) if g > 0 else (("%d behind" % -g) if g < 0 else "level"), later])
			else:
				var g2: int = after.call(c, p1) - after.call(near, p2)
				lines.append("A win at %s with %s second: %s going to %s" % [nxt, nm.call(near),
					("%d ahead" % g2) if g2 > 0 else (("%d behind" % -g2) if g2 < 0 else "level"), later])
				# to catch the ones ahead, per round (dropped rounds aside)
				var catch := PackedStringArray()
				for o in rows.slice(0, ci):
					var gap := int(o["points"]) - int(c["points"])
					if gap > 0:
						catch.append("%s about %d" % [nm.call(o), ceili((gap + 1) / float(left))])
				if not catch.is_empty():
					lines.append("Points a round to make up: %s" % ", ".join(catch))
		e["lines"] = lines.slice(0, NEEDS_MAX_LINES)
		out.append(e)
	return out


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
