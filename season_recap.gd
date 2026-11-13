class_name SeasonRecap
extends RefCounted
## A season of one championship (series and class), for the Season recap graphic and report:
##   - champion: the final top (or the order so far), the champion's margin, the round where the
##     title could no longer be lost, the team champions;
##   - season in numbers: races, different winners, most wins / poles / podiums / laps led, clean
##     races, the closest finish, league lap records set;
##   - awards picked from the results: cleanest driver, hard charger, comeback of the season,
##     rookie of the year, most improved (pace gained on the grid), underdog, iron man,
##     Mr Consistent (lap times);
##   - the championship timeline (points round by round, top 5) and the turning point.
## Use as: var sr = SeasonRecap.build("Season 6", "Sprint GT3")

const MIN_SHARE := 0.5   # awards over the season: at least half the rounds raced


static func build(season: String, key: String) -> Dictionary:
	var ch: Dictionary = Reports.season_points(season).get(key, {})
	if ch.is_empty():
		return {}
	var series := str(ch["series"])
	var cls := str(ch["cls"])
	var code := LeagueSettings.series_code(series)
	var done := int(ch["rounds"])
	var total := maxi(LeagueSettings.season_rounds(code) if code != "" else done, done)
	var drivers: Dictionary = ch["drivers"]
	var names := drivers.keys()
	names.sort_custom(func(a, b):
		var ea: Dictionary = drivers[a]
		var eb: Dictionary = drivers[b]
		if ea["points"] != eb["points"]:
			return ea["points"] > eb["points"]
		if ea["wins"] != eb["wins"]:
			return ea["wins"] > eb["wins"]
		return ea["pod"] > eb["pod"])
	var standings := []
	for d in names:
		var e: Dictionary = drivers[d]
		standings.append({"name": d, "points": int(e["points"]), "wins": int(e["wins"]), "pod": int(e["pod"]), "races": int(e["races"])})
	# this championship's race events, in order (round i = rounds[i - 1]), with their qualifying
	var rounds := []
	var quali := {}   # race file -> its qualifying event
	for ev in Elo.history:
		if Elo.season_of(ev) != season or Elo.series_of(ev) != series:
			continue
		var has_race := false
		var has_quali := false
		for c in ev["changes"]:
			if c["cls"] == cls:
				has_race = has_race or c["sess"] == "race"
				has_quali = has_quali or c["sess"] == "quali"
		if has_race:
			rounds.append(ev)
		elif has_quali:
			quali[str(ev["file"]).replace(".xml", "-r.xml")] = ev
	var out := {"season": season, "key": key, "series": series, "cls": cls, "done": done, "total": total,
		"final": done >= total, "standings": standings, "rounds": rounds.map(func(ev): return str(ev.get("course", "")))}
	if standings.size() >= 2:
		out["margin"] = int(standings[0]["points"]) - int(standings[1]["points"])
	out["decided"] = _decided(ch, str(standings[0]["name"]) if not standings.is_empty() else "", done, total)
	# team champions (teams with both drivers set)
	var tp: Dictionary = Reports.team_points(season).get(key, {})
	var best_team := {}
	for tn in tp.get("teams", {}):
		var t: Dictionary = tp["teams"][tn]
		if (t["drivers"] as Array).size() < 2:
			continue
		if best_team.is_empty() or int(t["points"]) > int(best_team["points"]) \
				or (int(t["points"]) == int(best_team["points"]) and int(t["wins"]) > int(best_team["wins"])):
			best_team = {"name": str(tn), "points": int(t["points"]), "wins": int(t["wins"]),
				"members": (t["drivers"] as Array).map(func(x): return str(x["name"]))}
	out["team"] = best_team
	var per := _per_driver(rounds, quali, cls)
	var sessions: Array = per["_sessions"]
	per.erase("_sessions")
	out["numbers"] = _numbers(per, rounds, season, series, cls, drivers)
	out["awards"] = _awards(per, drivers, standings, season, cls, done, rounds, sessions)
	_timeline(out, ch, standings)
	return out


# Points after each round (dropped rounds as the standings had them then) for the top 5, the
# leader after each round, and the turning point: the round where the lead changed hands with the
# biggest swing between the two (no change of leader: the round the leader pulled furthest clear).
static func _timeline(out: Dictionary, ch: Dictionary, standings: Array) -> void:
	var done := int(ch["rounds"])
	var drivers: Dictionary = ch["drivers"]
	var after := {}   # driver -> points after each round
	for d in drivers:
		var pts: Array = (drivers[d]["by_round"] as Array).map(func(x): return int(x["pts"]))
		var line := []
		for r in range(1, done + 1):
			line.append(SeasonScenarios.final_score(pts.slice(0, r), r))
		after[d] = line
	var leaders := []
	for r in done:
		var best := ""
		for d in after:   # most points, then the final standings order
			if best == "" or int(after[d][r]) > int(after[best][r]):
				best = d
		leaders.append(best)
	# the top 5, plus anyone who led at some point (in standings order)
	var top := []
	for x in standings:
		if top.size() < 5 or leaders.has(str(x["name"])):
			top.append(str(x["name"]))
	out["timeline"] = {"lines": top.map(func(d): return {"name": d, "points": after[d]}), "leaders": leaders,
		"rounds": out["rounds"]}
	var turn := {}
	for r in range(1, done):
		var now: String = leaders[r]
		var was: String = leaders[r - 1]
		if now != was:
			var swing := (int(after[now][r]) - int(after[was][r])) - (int(after[now][r - 1]) - int(after[was][r - 1]))
			if turn.is_empty() or not bool(turn["change"]) or swing > int(turn["swing"]):
				turn = {"round": r + 1, "change": true, "swing": swing, "to": now, "from": was}
		elif turn.is_empty() or not bool(turn["change"]):
			# the gap to the nearest rival grew the most
			var gap_now := 999999
			var gap_was := 999999
			for d in after:
				if d != now:
					gap_now = mini(gap_now, int(after[now][r]) - int(after[d][r]))
					gap_was = mini(gap_was, int(after[now][r - 1]) - int(after[d][r - 1]))
			var grew := gap_now - gap_was
			if grew > 0 and (turn.is_empty() or grew > int(turn["swing"])):
				turn = {"round": r + 1, "change": false, "swing": grew, "to": now, "gap": gap_now}
	if not turn.is_empty():
		var course := str(out["rounds"][int(turn["round"]) - 1]) if int(turn["round"]) - 1 < (out["rounds"] as Array).size() else ""
		turn["course"] = course
		turn["text"] = ("R%d %s: %s took the lead from %s, a %d-point swing" % [turn["round"], course, Elo.pretty(str(turn["to"])), Elo.pretty(str(turn["from"])), turn["swing"]]) \
			if bool(turn["change"]) else ("%s led every round; the biggest step was R%d %s: %d more points clear, %d ahead" % [
				Elo.pretty(str(turn["to"])), turn["round"], course, turn["swing"], turn["gap"]])
	out["turning"] = turn


# The round after which the leader could no longer be caught (everyone else winning every round
# left, worst rounds dropped), {} when it is still open. {"round", "left"}: rounds still to go then.
static func _decided(ch: Dictionary, leader: String, done: int, total: int) -> Dictionary:
	if leader == "":
		return {}
	var pts_table: Array = LeagueSettings.points()
	var p1 := int(pts_table[0]) if not pts_table.is_empty() else 0
	var drivers: Dictionary = ch["drivers"]
	for r in range(1, done + 1):
		var left := total - r
		var upto := func(d: String) -> Array:
			return (drivers[d]["by_round"] as Array).slice(0, r).map(func(x): return int(x["pts"]))
		var mine := SeasonScenarios.final_score(upto.call(leader) + SeasonScenarios._filled(left, 0), total)
		var safe := true
		for d in drivers:
			if d != leader and SeasonScenarios.final_score(upto.call(d) + SeasonScenarios._filled(left, p1), total) >= mine:
				safe = false
				break
		if safe:
			return {"round": r, "left": left}
	return {}


# Per driver over the season: races, contacts, places gained, laps led, poles, clean races,
# finishing places, race rating before and after.
static func _per_driver(rounds: Array, quali: Dictionary, cls: String) -> Dictionary:
	var per := {}
	var get_d := func(d: String) -> Dictionary:
		if not per.has(d):
			per[d] = {"races": 0, "inc": 0, "gained": 0, "led": 0, "poles": 0, "clean": 0, "places": [], "elo0": NAN, "elo1": NAN,
				"laps": 0, "dnf": 0, "climb": {}, "beat": 0.0, "spread": [], "starts": []}
		return per[d]
	# every dry qualifying and race of the season, one pace per driver, for Most improved:
	# [driver, round index, "race"/"quali", 100 x ln(lap time) without success ballast]
	var sessions := []
	# lap data of each race (Profiles), for the lap-time spread
	var lap_days := {}
	for day in Profiles.days:
		if day.has("race_file"):
			lap_days[str(day["race_file"])] = day
	for ri in rounds.size():
		var ev: Dictionary = rounds[ri]
		var st: Dictionary = ev.get("stats", {}).get("race", {}).get(cls, {})
		var field := (ev["changes"] as Array).filter(func(c): return c["cls"] == cls and c["sess"] == "race")
		var lead: Dictionary = RaceRecap._lead_info(str(ev["file"])).get(cls, {})
		# lap-time spread of each driver against the class's middle one in this race (so a twitchy
		# track or a damp race does not count against whoever raced it)
		var lap_rows: Dictionary = lap_days.get(str(ev["file"]), {}).get("race", {}).get("drivers", {})
		var day_q: Dictionary = lap_days.get(str(ev["file"]), {}).get("quali", {})
		if float(day_q.get("wet", 0.0)) <= 0.2:
			for nm in day_q.get("drivers", {}):
				var q: Dictionary = day_q["drivers"][nm]
				if str(q.get("cls", "")) == cls and float(q.get("best", 0.0)) > 0.0:
					sessions.append([nm, ri, "quali", 100.0 * log(float(q["best"])) - Predict.ballast_k_history() * float(q.get("mass", 0.0))])
		var wet := float(lap_days.get(str(ev["file"]), {}).get("race", {}).get("wet", 0.0)) > 0.2   # wet tyres on more than a fifth of the laps
		if not wet:
			for nm in lap_rows:
				var rr: Dictionary = lap_rows[nm]
				if str(rr.get("cls", "")) == cls and float(rr.get("pace", 0.0)) > 0.0 and int(rr.get("clean_n", 99)) >= 5:
					sessions.append([nm, ri, "race", 100.0 * log(float(rr["pace"])) - Predict.ballast_k_history() * float(rr.get("mass", 0.0))])
		var spreads := []
		for nm in lap_rows:
			if str(lap_rows[nm].get("cls", "")) == cls and float(lap_rows[nm].get("cons", 0.0)) > 0.0:
				spreads.append(float(lap_rows[nm]["cons"]))
		spreads.sort()
		var mid_spread: float = spreads[spreads.size() / 2] if spreads.size() >= 3 else 0.0
		for c in ev["changes"]:
			if c["cls"] != cls or c["sess"] != "race":
				continue
			var d: String = c["driver"]
			var p: Dictionary = get_d.call(d)
			var s: Dictionary = st.get(d, {})
			p["races"] += 1
			p["inc"] += int(s.get("inc", 0))
			p["clean"] += 1 if not s.is_empty() and int(s.get("inc", 0)) == 0 else 0
			var g := int(s.get("grid", 0))
			var out_of_it := Reports._retired(s.get("status", ""))
			p["laps"] += int(s.get("laps", 0))
			p["dnf"] += 1 if out_of_it else 0
			if mid_spread > 0.0 and lap_rows.has(d) and float(lap_rows[d].get("cons", 0.0)) > 0.0 and not out_of_it:
				p["spread"].append([float(lap_rows[d]["cons"]), float(lap_rows[d]["cons"]) / mid_spread])
			if g > 0 and not out_of_it:
				p["starts"].append([g, g - int(c["pos"])])
				p["gained"] += g - int(c["pos"])
				if g - int(c["pos"]) > int(p["climb"].get("gain", 0)):
					p["climb"] = {"gain": g - int(c["pos"]), "from": g, "to": int(c["pos"]), "round": ri + 1, "course": str(ev.get("course", ""))}
			# places better than the ratings said (as the race recap's biggest surprise), finishers only
			if not out_of_it:
				var expect := 1.0
				for o in field:
					if o != c:
						expect += 1.0 / (1.0 + pow(10.0, (float(c["before"]) - float(o["before"])) / 400.0))
				p["beat"] += expect - float(c["pos"])
			p["places"].append(int(c["pos"]))
			p["led"] += int(lead.get("led", {}).get(d, 0))
			if is_nan(float(p["elo0"])):
				p["elo0"] = float(c["before"])
			p["elo1"] = float(c["after"])
		var q: Dictionary = quali.get(str(ev["file"]), {})
		for c in q.get("changes", []):
			if c["cls"] == cls and c["sess"] == "quali" and int(c["pos"]) == 1:
				get_d.call(str(c["driver"]))["poles"] += 1
	per["_sessions"] = sessions
	return per


# "Most X": the leader(s) and the count. [names, n]
static func _most(per: Dictionary, field: String) -> Array:
	var best := 0
	var who := []
	for d in per:
		var n := int(per[d][field])
		if n > best:
			best = n
			who = [d]
		elif n == best and n > 0:
			who.append(d)
	return [who, best]


static func _names(who: Array) -> String:
	var shown := who.slice(0, 2).map(func(d): return Elo.pretty(str(d)))
	return ", ".join(PackedStringArray(shown)) + (" +%d" % (who.size() - 2) if who.size() > 2 else "")


static func _numbers(per: Dictionary, rounds: Array, season: String, series: String, cls: String, drivers: Dictionary) -> Array:
	var out := []
	var winners := {}
	for d in drivers:
		for r in drivers[d]["by_round"]:
			if int(r["pos"]) == 1:
				winners[d] = true
	out.append({"label": "RACES", "value": str(rounds.size()), "who": "%d different winner%s" % [winners.size(), "" if winners.size() == 1 else "s"]})
	for f in [["wins", "MOST WINS", "win"], ["poles", "MOST POLES", "pole"], ["led", "MOST LAPS LED", "lap"]]:
		var m: Array
		if f[0] == "wins":
			var w := {}
			for d in drivers:
				w[d] = {"wins": int(drivers[d]["wins"])}
			m = _most(w, "wins")
		else:
			m = _most(per, f[0])
		if int(m[1]) > 0:
			out.append({"label": f[1], "value": str(m[1]), "who": _names(m[0])})
	var pods := {}
	for d in drivers:
		pods[d] = {"pod": int(drivers[d]["pod"])}
	var mp := _most(pods, "pod")
	if int(mp[1]) > 0:
		out.append({"label": "MOST PODIUMS", "value": str(mp[1]), "who": _names(mp[0])})
	var mc := _most(per, "clean")
	if int(mc[1]) > 0:
		var races := 0
		for d in mc[0]:
			races = maxi(races, int(per[d]["races"]))
		out.append({"label": "MOST CLEAN RACES", "value": str(mc[1]), "who": "%s, no contact in %d of %d" % [_names(mc[0]), mc[1], races]})
	# closest finish: the smallest gap from the winner to second on the same lap
	var closest := {}
	for i in rounds.size():
		var st: Dictionary = rounds[i].get("stats", {}).get("race", {}).get(cls, {})
		var by_pos := {}
		for c in rounds[i]["changes"]:
			if c["cls"] == cls and c["sess"] == "race":
				by_pos[int(c["pos"])] = st.get(c["driver"], {})
		var a: Dictionary = by_pos.get(1, {})
		var b: Dictionary = by_pos.get(2, {})
		if float(a.get("time", 0.0)) > 0.0 and float(b.get("time", 0.0)) > 0.0 and int(a.get("laps", 0)) == int(b.get("laps", 0)):
			var gap := float(b["time"]) - float(a["time"])
			if gap >= 0.0 and (closest.is_empty() or gap < float(closest["gap"])):
				closest = {"gap": gap, "round": i + 1, "course": str(rounds[i].get("course", ""))}
	if not closest.is_empty():
		out.append({"label": "CLOSEST FINISH", "value": "%.3f s" % float(closest["gap"]), "who": "R%d %s" % [closest["round"], str(closest["course"])]})
	# league lap records lowered this season in this class and series
	var tracks := []
	var n_rec := 0
	var recs := LapRecords.all()
	for course in recs:
		var hist: Array = recs[course].get(cls, {}).get("lap", {}).get("history", [])
		for i in range(1, hist.size()):   # the first visit is no record broken
			if str(hist[i]["season"]) == season and str(hist[i]["series"]) == series:
				n_rec += 1
				if not tracks.has(course):
					tracks.append(course)
	if n_rec > 0:
		out.append({"label": "LAP RECORDS", "value": str(n_rec), "who": ", ".join(PackedStringArray(tracks.slice(0, 2))) + (" +%d" % (tracks.size() - 2) if tracks.size() > 2 else "")})
	return out


static func _awards(per: Dictionary, drivers: Dictionary, standings: Array, season: String, cls: String, done: int, rounds: Array, sessions := []) -> Array:
	var out := []
	var min_races := maxi(1, ceili(done * MIN_SHARE))
	var eligible := per.keys().filter(func(d): return int(per[d]["races"]) >= min_races)
	var place := {}
	for i in standings.size():
		place[standings[i]["name"]] = i + 1
	var better := func(a, b) -> bool: return int(place.get(a, 999)) < int(place.get(b, 999))
	# cleanest driver: fewest contacts per lap raced, so Enduro distances and missed laps weigh fairly
	# (ties: more laps, then higher in the standings)
	var clean := ""
	for d in eligible:
		if int(per[d]["laps"]) <= 0:
			continue
		if clean == "":
			clean = d
			continue
		var r_d: float = float(per[d]["inc"]) / float(per[d]["laps"])
		var r_c: float = float(per[clean]["inc"]) / float(per[clean]["laps"])
		if r_d < r_c or (r_d == r_c and (per[d]["laps"] > per[clean]["laps"] or (per[d]["laps"] == per[clean]["laps"] and better.call(d, clean)))):
			clean = d
	var awarded := {}   # one award each where possible (the cleanest driver always gets theirs)
	var rookie := ""
	var veterans := {}       # raced in the league before this season (any class or series)
	var seasons := Elo.seasons()
	var this_i := seasons.find(season)
	for ev in Elo.history:
		if seasons.find(Elo.season_of(ev)) >= this_i:
			continue   # this season or a later one
		for c in ev["changes"]:
			veterans[c["driver"]] = true
	for r in standings:
		if not veterans.has(r["name"]):
			rookie = r["name"]
			break
	if clean != "":
		awarded[clean] = true
	if rookie != "":
		awarded[rookie] = true
	var open := func(d: String) -> bool: return not awarded.has(d)
	if clean != "":
		var n := int(per[clean]["inc"])
		out.append({"tag": "CLEANEST DRIVER", "name": clean, "text": "%s in %d laps" % ["no contact" if n == 0 else "%d contact%s" % [n, "" if n == 1 else "s"], per[clean]["laps"]]})
	# hard charger: most places gained beyond what drivers from the same grid spots usually gain this
	# season (a driver starting at the back has more places to make up; a pole-sitter can only lose)
	var gx := []
	var gy := []
	for d in per:
		for st in per[d]["starts"]:
			gx.append(float(st[0]))
			gy.append(float(st[1]))
	var gfit := _line(gx, gy)
	var extra := {}
	for d in per:
		var e := 0.0
		for st in per[d]["starts"]:
			e += float(st[1]) - (gfit[0] + gfit[1] * float(st[0]))
		extra[d] = e
	var charger := ""
	for d in eligible.filter(open):
		if float(extra[d]) >= 1.0 and (charger == "" or float(extra[d]) > float(extra[charger])):
			charger = d
	if charger != "":
		awarded[charger] = true
		out.append({"tag": "HARD CHARGER", "name": charger, "text": "%+d places from the grid (%+d vs usual from those spots)" % [
			per[charger]["gained"], roundi(float(extra[charger]))]})
	# comeback of the season: the biggest climb in a single race (any driver, any number of races)
	var comeback := ""
	for d in per.keys().filter(open):
		if int(per[d]["climb"].get("gain", 0)) > 0 and (comeback == "" or int(per[d]["climb"]["gain"]) > int(per[comeback]["climb"]["gain"])):
			comeback = d
	if comeback != "":
		awarded[comeback] = true
		var cb: Dictionary = per[comeback]["climb"]
		out.append({"tag": "COMEBACK OF THE SEASON", "name": comeback, "text": "P%d → P%d at R%d %s" % [cb["from"], cb["to"], cb["round"], cb["course"]]})
	# rookie of the year: best placed driver whose first league race (any class or series) is this season
	if rookie != "":
		var rr: Dictionary = standings[int(place[rookie]) - 1]
		out.append({"tag": "ROOKIE OF THE YEAR", "name": rookie, "text": "P%d, %d points" % [place[rookie], rr["points"]]})
	# most improved: who gained the most pace on the grid over the season (Improvement.fit: every dry
	# qualifying and race, the conditions of each session taken out, a line through each driver's
	# season, uncertain gains pulled back). Only when the app is IMPROVED_SURE sure it is real. Like
	# the cleanest driver, it goes to the clearest improver even if they already hold an award; the
	# next two improvers are named on the card.
	var imp := improvement(sessions)
	var ranked := eligible.filter(func(d): return imp.has(d) and float(imp[d]["gain"]) > 0.0)
	ranked.sort_custom(func(a, b): return float(imp[a]["gain"]) > float(imp[b]["gain"]))
	if not ranked.is_empty() and float(imp[ranked[0]]["sure"]) >= IMPROVED_SURE:
		var improved: String = ranked[0]
		awarded[improved] = true
		var next := PackedStringArray()
		for d in ranked.slice(1, 3):
			next.append("%s %+.1f%%" % [_surname(d), imp[d]["gain"]])
		out.append({"tag": "MOST IMPROVED", "name": improved, "text": "Gained %.1f%% on the grid this season%s" % [
			imp[improved]["gain"], ". Next: " + ", ".join(next) if not next.is_empty() else ""]})
	# underdog: the most places better than the ratings said, over the season
	var underdog := ""
	for d in eligible.filter(open):
		if int(place.get(d, 999)) <= 3:
			continue   # an underdog is not on the podium of the championship
		if float(per[d]["beat"]) >= 3.0 and (underdog == "" or float(per[d]["beat"]) > float(per[underdog]["beat"])):
			underdog = d
	if underdog != "":
		awarded[underdog] = true
		out.append({"tag": "UNDERDOG", "name": underdog, "text": "%d places better than the ratings said, over %d races" % [roundi(float(per[underdog]["beat"])), per[underdog]["races"]]})
	# iron man: the most laps raced (ties: fewer retirements)
	var iron := ""
	for d in per.keys().filter(open):
		if iron == "" or int(per[d]["laps"]) > int(per[iron]["laps"]) or (int(per[d]["laps"]) == int(per[iron]["laps"]) and int(per[d]["dnf"]) < int(per[iron]["dnf"])):
			iron = d
	if iron != "" and int(per[iron]["laps"]) > 0:
		awarded[iron] = true
		var all_rounds := int(per[iron]["races"]) == done and int(per[iron]["dnf"]) == 0
		out.append({"tag": "IRON MAN", "name": iron, "text": "%d laps%s" % [per[iron]["laps"],
			", every round to the flag" if all_rounds else " in %d races" % per[iron]["races"]]})
	# Mr Consistent: the steadiest lap times. Each race, the driver's lap-to-lap spread on clean laps
	# against the middle driver of the class in that race (so twitchy tracks and damp races count the
	# same for everyone); the season figure is the driver's typical (median) race, so one race with
	# a spin does not decide it. At least half the rounds with lap data.
	var steady := ""
	var steady_r := INF
	for d in eligible.filter(open):
		var sp: Array = per[d]["spread"]
		if sp.size() < min_races:
			continue
		var rel := sp.map(func(x): return x[1])
		rel.sort()
		var med: float = rel[rel.size() / 2] if rel.size() % 2 == 1 else (rel[rel.size() / 2 - 1] + rel[rel.size() / 2]) / 2.0
		if med < steady_r or (med == steady_r and better.call(d, steady)):
			steady_r = med
			steady = d
	if steady != "" and steady_r < 1.0:
		var raw := (per[steady]["spread"] as Array).map(func(x): return x[0])
		raw.sort()
		out.append({"tag": "MR CONSISTENT", "name": steady, "text": "%.2f%% lap spread, %d%% steadier than the class" % [
			raw[raw.size() / 2], roundi((1.0 - steady_r) * 100.0)]})
	return out


# Least-squares line y = a + b x: [a, b] (b = 0 with fewer than 2 distinct x).
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
	if sxx <= 0.0:
		return [my, 0.0]
	return [my - sxy / sxx * mx, sxy / sxx]


# ---------- Most improved: pace gained on the grid over the season ----------
# Every dry qualifying and race session gives one pace per driver (log of the lap time, so 1 = 1%
# of lap time, without success ballast), split into: the driver's own level + their improvement x
# how far into the season it is + the session's conditions (track, heat, rubber: the same for
# everyone, worked out from everyone who drove in it) + luck. Driver levels and improvements
# average 0 over the field: what everyone gains together cannot be told apart from the calendar,
# so improvement is against the rest of the grid. A session far off the driver's own line (a
# problem, not pace) is set aside. Uncertain gains are then pulled towards 0, by how unsure they
# are against how much drivers really differ in improvement that season.
# Tested on season 6 (1.0.33): improvements from races alone and from qualifying alone agree
# (correlation +0.42 over 49 drivers); in simulated seasons it finds the real most improved
# driver 31% of the time (comparing first races with last: 22-24%).
const IMPROVED_SURE := 0.85       # how sure the app must be that the winner really improved
const IMPROVED_MIN_ROUNDS := 3
const IMPROVED_MIN_SESSIONS := 4


## {driver: {"gain" (% on the grid, after the pull-in), "raw", "se", "sure" (0-1 that it is > 0),
## "best" (0-1 chance of being the most improved), "sessions"}} for every driver with
## IMPROVED_MIN_ROUNDS rounds and IMPROVED_MIN_SESSIONS dry sessions.
static func improvement(sessions: Array) -> Dictionary:
	var rounds := {}
	var count := {}
	for o in sessions:
		rounds[o[1]] = true
		if not count.has(o[0]):
			count[o[0]] = {}
		count[o[0]][str(o[1]) + o[2]] = o[1]
	var last := 0
	for r in rounds:
		last = maxi(last, int(r))
	if last < 2:
		return {}
	var keep := sessions.filter(func(o): return _imp_ok(sessions, o[0]))
	return _imp_fit(keep, float(last))


static func _imp_ok(obs: Array, d: String) -> bool:
	var rs := {}
	var n := 0
	for o in obs:
		if o[0] == d:
			rs[o[1]] = true
			n += 1
	return rs.size() >= IMPROVED_MIN_ROUNDS and n >= IMPROVED_MIN_SESSIONS


static func _imp_fit(obs: Array, last: float) -> Dictionary:
	var drivers := {}
	var sess := {}
	for o in obs:
		if not drivers.has(o[0]):
			drivers[o[0]] = drivers.size()
		var sk := "%d|%s" % [o[1], o[2]]
		if not sess.has(sk):
			sess[sk] = sess.size()
	var nD := drivers.size()
	var nS := sess.size()
	if nD < 4:
		return {}
	var p := 2 * nD + nS
	var sd := {"race": 0.5, "quali": 0.5}
	var used := obs.duplicate()
	var x := []   # solution
	for it in 6:
		x = _imp_solve(used, drivers, sess, nD, nS, sd, last)
		if x.is_empty():
			return {}
		# luck per session type: root-mean-square of what the model leaves, corrected for the fit;
		# a session more than 4 robust spreads off the driver's line is set aside
		var res := {"race": [], "quali": []}
		var all_res := []
		for o in obs:
			var e: float = float(o[3]) - _imp_pred(x, o, drivers, sess, nD, nS, last)
			all_res.append(e)
		var mad := {}
		for k in ["race", "quali"]:
			var a := []
			for i in obs.size():
				if obs[i][2] == k:
					a.append(absf(all_res[i]))
			a.sort()
			mad[k] = 1.4826 * float(a[a.size() / 2]) if a.size() > 10 else sd[k]
		var next := []
		for i in obs.size():
			if absf(all_res[i]) < 4.0 * maxf(float(mad[obs[i][2]]), 1e-4):
				next.append(obs[i])
				res[obs[i][2]].append(all_res[i])
		var share := 1.0 - float(p - 2) / maxf(next.size(), 1.0)
		for k in ["race", "quali"]:
			if res[k].size() > 10:
				var ss := 0.0
				for e in res[k]:
					ss += e * e
				sd[k] = maxf(sqrt(ss / (res[k].size() * maxf(share, 0.1))), 0.05)
		used = next
		# drivers must still meet the minimum once the odd sessions are out: refit without the others
		var short := drivers.keys().filter(func(d): return not _imp_ok(used, d))
		if not short.is_empty():
			return _imp_fit(used.filter(func(o): return not (o[0] in short)), last)
	var cov := _imp_cov(used, drivers, sess, nD, nS, sd, last)
	if cov.is_empty():
		return {}
	var raw := {}
	var se := {}
	var mean_se2 := 0.0
	var mean_g := 0.0
	for d in drivers:
		var k: int = nD + nS + drivers[d]
		raw[d] = -float(x[k])
		se[d] = sqrt(maxf(float(cov[drivers[d]]), 0.0))
		mean_se2 += se[d] * se[d] / nD
		mean_g += raw[d] / nD
	var var_g := 0.0
	for d in drivers:
		var_g += pow(raw[d] - mean_g, 2) / maxf(nD - 1, 1)
	var tau2 := maxf(var_g - mean_se2, 0.01)   # how much drivers really differ in improvement
	var out := {}
	var shr := {}
	var psd := {}
	for d in drivers:
		shr[d] = raw[d] * tau2 / (tau2 + se[d] * se[d])
		psd[d] = sqrt(tau2 * se[d] * se[d] / (tau2 + se[d] * se[d]))
	# chance of being the most improved: draws from each driver's likely range (fixed seed: the
	# same answer every time the recap is built)
	var rng := RandomNumberGenerator.new()
	rng.seed = 6
	var wins := {}
	var names: Array = drivers.keys()
	for i in 4000:
		var best_d := ""
		var best_v := -INF
		for d in names:
			var v: float = rng.randfn(shr[d], psd[d])
			if v > best_v:
				best_v = v
				best_d = d
		wins[best_d] = int(wins.get(best_d, 0)) + 1
	for d in names:
		var n := used.filter(func(o): return o[0] == d).size()
		out[d] = {"gain": shr[d], "raw": raw[d], "se": se[d], "sure": _phi(shr[d] / maxf(psd[d], 1e-9)),
			"best": float(wins.get(d, 0)) / 4000.0, "sessions": n}
	return out


static func _imp_t(o: Array, last: float) -> float:
	return float(o[1]) / last   # round index 0 .. last


static func _imp_pred(x: Array, o: Array, drivers: Dictionary, sess: Dictionary, nD: int, nS: int, last: float) -> float:
	var di: int = drivers[o[0]]
	return float(x[di]) + float(x[nD + sess["%d|%s" % [o[1], o[2]]]]) + float(x[nD + nS + di]) * _imp_t(o, last)


# Weighted least squares with the two constraints (driver levels and improvements average 0),
# solved as one linear system (Lagrange multipliers). Returns the parameters, or [] if singular.
static func _imp_system(obs: Array, drivers: Dictionary, sess: Dictionary, nD: int, nS: int, sd: Dictionary, last: float) -> Array:
	var p := 2 * nD + nS
	var n := p + 2
	var M := []
	for i in n:
		var row := []
		row.resize(n + 1)
		row.fill(0.0)
		M.append(row)
	for o in obs:
		var w: float = 1.0 / pow(float(sd[o[2]]), 2)
		var di: int = drivers[o[0]]
		var idx := [di, nD + int(sess["%d|%s" % [o[1], o[2]]]), nD + nS + di]
		var val := [1.0, 1.0, _imp_t(o, last)]
		for a in 3:
			for b in 3:
				M[idx[a]][idx[b]] += w * val[a] * val[b]
			M[idx[a]][n] += w * val[a] * float(o[3])
	for d in nD:
		M[d][p] = 1.0
		M[p][d] = 1.0
		M[nD + nS + d][p + 1] = 1.0
		M[p + 1][nD + nS + d] = 1.0
	return M


static func _imp_solve(obs: Array, drivers: Dictionary, sess: Dictionary, nD: int, nS: int, sd: Dictionary, last: float) -> Array:
	var M := _imp_system(obs, drivers, sess, nD, nS, sd, last)
	var n := M.size()
	if not _gauss(M, n, 1):
		return []
	var x := []
	for i in 2 * nD + nS:
		x.append(M[i][n])
	return x


# Variance of each driver's improvement: the matching diagonal of the inverse of the system.
static func _imp_cov(obs: Array, drivers: Dictionary, sess: Dictionary, nD: int, nS: int, sd: Dictionary, last: float) -> Array:
	var M := _imp_system(obs, drivers, sess, nD, nS, sd, last)
	var n := M.size()
	# replace the right-hand side by the unit columns of the improvement parameters
	for i in n:
		var row: Array = M[i]
		row.resize(n + nD)
		for d in nD:
			row[n + d] = 1.0 if i == nD + nS + d else 0.0
	if not _gauss(M, n, nD):
		return []
	var out := []
	for d in nD:
		out.append(M[nD + nS + d][n + d])
	return out


# Gauss-Jordan elimination with partial pivoting on an n x (n + k) system, in place.
static func _gauss(M: Array, n: int, k: int) -> bool:
	for c in n:
		var piv := c
		for r in range(c + 1, n):
			if absf(M[r][c]) > absf(M[piv][c]):
				piv = r
		if absf(M[piv][c]) < 1e-12:
			return false
		if piv != c:
			var tmp = M[c]
			M[c] = M[piv]
			M[piv] = tmp
		var row: Array = M[c]
		var f: float = row[c]
		for j in n + k:
			row[j] = float(row[j]) / f
		for r in n:
			if r == c:
				continue
			var rr: Array = M[r]
			var g: float = rr[c]
			if g == 0.0:
				continue
			for j in range(c, n + k):
				rr[j] = float(rr[j]) - g * float(row[j])
	return true


# Standard normal cumulative probability (Abramowitz-Stegun 26.2.17, error below 1e-7).
static func _phi(z: float) -> float:
	var t := 1.0 / (1.0 + 0.2316419 * absf(z))
	var y := 1.0 - 0.3989422804 * exp(-z * z / 2.0) * t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))))
	return y if z >= 0.0 else 1.0 - y



# The last word of a name, for short mentions ("Scarlett Brown" -> "Brown"; a "#1234" tag dropped).
static func _surname(full: String) -> String:
	var parts := full.split("#")[0].strip_edges().split(" ", false)
	return parts[parts.size() - 1] if not parts.is_empty() else full
