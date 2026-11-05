class_name SeasonRecap
extends RefCounted
## A season of one championship (series and class), for the Season recap graphic and report:
##   - champion: the final top (or the order so far), the champion's margin, the round where the
##     title could no longer be lost, the team champions;
##   - season in numbers: races, different winners, most wins / poles / podiums / laps led, clean
##     races, the closest finish, league lap records set;
##   - awards picked from the results: cleanest driver, hard charger, rookie of the year, most
##     improved, Mr Consistent.
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
	out["numbers"] = _numbers(per, rounds, season, series, cls, drivers)
	out["awards"] = _awards(per, drivers, standings, season, cls, done)
	return out


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
			per[d] = {"races": 0, "inc": 0, "gained": 0, "led": 0, "poles": 0, "clean": 0, "places": [], "elo0": NAN, "elo1": NAN}
		return per[d]
	for ev in rounds:
		var st: Dictionary = ev.get("stats", {}).get("race", {}).get(cls, {})
		var lead: Dictionary = RaceRecap._lead_info(str(ev["file"])).get(cls, {})
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
			if g > 0 and str(s.get("status", "")) != "DNF":
				p["gained"] += g - int(c["pos"])
			p["places"].append(int(c["pos"]))
			p["led"] += int(lead.get("led", {}).get(d, 0))
			if is_nan(float(p["elo0"])):
				p["elo0"] = float(c["before"])
			p["elo1"] = float(c["after"])
		var q: Dictionary = quali.get(str(ev["file"]), {})
		for c in q.get("changes", []):
			if c["cls"] == cls and c["sess"] == "quali" and int(c["pos"]) == 1:
				get_d.call(str(c["driver"]))["poles"] += 1
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


static func _awards(per: Dictionary, drivers: Dictionary, standings: Array, season: String, cls: String, done: int) -> Array:
	var out := []
	var min_races := maxi(1, ceili(done * MIN_SHARE))
	var eligible := per.keys().filter(func(d): return int(per[d]["races"]) >= min_races)
	var place := {}
	for i in standings.size():
		place[standings[i]["name"]] = i + 1
	var better := func(a, b) -> bool: return int(place.get(a, 999)) < int(place.get(b, 999))
	# cleanest driver: fewest contacts a race (ties: more races, then higher in the standings)
	var clean := ""
	for d in eligible:
		if clean == "":
			clean = d
			continue
		var r_d: float = float(per[d]["inc"]) / float(per[d]["races"])
		var r_c: float = float(per[clean]["inc"]) / float(per[clean]["races"])
		if r_d < r_c or (r_d == r_c and (per[d]["races"] > per[clean]["races"] or (per[d]["races"] == per[clean]["races"] and better.call(d, clean)))):
			clean = d
	var awarded := {}   # one award each where possible (the cleanest driver always gets theirs)
	var rookie := ""
	var veterans := {}
	var seasons := Elo.seasons()
	var this_i := seasons.find(season)
	for ev in Elo.history:
		if seasons.find(Elo.season_of(ev)) >= this_i:
			continue   # this season or a later one
		for c in ev["changes"]:
			if c["cls"] == cls:
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
		out.append({"tag": "CLEANEST DRIVER", "name": clean, "text": "%s in %d races" % ["no contact" if n == 0 else "%d contact%s" % [n, "" if n == 1 else "s"], per[clean]["races"]]})
	# hard charger: most places gained from the grid over the season
	var charger := ""
	for d in eligible.filter(open):
		if int(per[d]["gained"]) > 0 and (charger == "" or int(per[d]["gained"]) > int(per[charger]["gained"])):
			charger = d
	if charger != "":
		awarded[charger] = true
		out.append({"tag": "HARD CHARGER", "name": charger, "text": "+%d places from the grid in %d races" % [per[charger]["gained"], per[charger]["races"]]})
	# rookie of the year: best placed driver whose first race in the class is this season
	if rookie != "":
		var rr: Dictionary = standings[int(place[rookie]) - 1]
		out.append({"tag": "ROOKIE OF THE YEAR", "name": rookie, "text": "P%d, %d points" % [place[rookie], rr["points"]]})
	# most improved: biggest race rating gain over the season
	var improved := ""
	for d in eligible.filter(open):
		var gain := float(per[d]["elo1"]) - float(per[d]["elo0"])
		if gain > 0.0 and (improved == "" or gain > float(per[improved]["elo1"]) - float(per[improved]["elo0"])):
			improved = d
	if improved != "":
		awarded[improved] = true
		out.append({"tag": "MOST IMPROVED", "name": improved, "text": "+%d Elo over the season" % roundi(float(per[improved]["elo1"]) - float(per[improved]["elo0"]))})
	# Mr Consistent: the steadiest finishing places (at least 3 races, two thirds of the rounds)
	var steady := ""
	var steady_sd := INF
	for d in per.keys().filter(open):
		var pl: Array = per[d]["places"]
		if pl.size() < maxi(3, ceili(done * 0.67)):
			continue
		var mean := 0.0
		for p in pl:
			mean += p
		mean /= pl.size()
		var v := 0.0
		for p in pl:
			v += (p - mean) * (p - mean)
		var sd := sqrt(v / pl.size()) + mean * 0.15   # a nudge so a steady P2 beats a steady P12
		if sd < steady_sd:
			steady_sd = sd
			steady = d
	if steady != "":
		var pl: Array = per[steady]["places"]
		out.append({"tag": "MR CONSISTENT", "name": steady, "text": "P%d to P%d in all %d races" % [pl.min(), pl.max(), pl.size()] if pl.min() != pl.max() else "P%d in all %d races" % [pl.min(), pl.size()]})
	return out
