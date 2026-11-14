class_name SeasonStory
extends RefCounted
## One driver's season in one championship (series and class), for the Season story graphic:
##   - a headline made from the season's strongest facts ("Rookie season: quicker every round");
##   - five numbers, the most telling ones for this driver (championship place and best finish,
##     then wins, podiums, fastest race pace, poles, laps led, rating gained, places gained, clean
##     races, whichever say the most);
##   - round by round: grid and finish, retirements, poles, laps led, wet races, the championship
##     place after each round;
##   - race pace against the class's middle driver each round (clean laps, at least MIN_CLEAN), the
##     rounds where it was the fastest in the class, laps lost to mistakes (Fingerprint costly laps);
##   - three beats: the high point, the toughest day and an award (or the best moment left).
## Use as: var st = SeasonStory.build("Season 6", "Sprint LMP3", "William Neron")

const MIN_CLEAN := 5            # clean laps for a race pace
const COSTLY_SHOWN := 15.0      # seconds lost to mistakes in a race worth a mention
const TREND_SURE := 0.85        # quicker through the season: Most improved's model this sure


# Drivers who raced the championship, in standings order.
static func drivers(season: String, key: String) -> Array:
	var ch: Dictionary = Reports.season_points(season).get(key, {})
	var names: Array = ch.get("drivers", {}).keys()
	var d: Dictionary = ch.get("drivers", {})
	names.sort_custom(func(a, b):
		if d[a]["points"] != d[b]["points"]:
			return d[a]["points"] > d[b]["points"]
		return str(a).to_lower() < str(b).to_lower())
	return names


static func build(season: String, key: String, driver: String, recap := {}) -> Dictionary:
	var sr: Dictionary = recap if not recap.is_empty() else SeasonRecap.build(season, key)
	if sr.is_empty():
		return {}
	var ch: Dictionary = Reports.season_points(season).get(key, {})
	if not ch.get("drivers", {}).has(driver):
		return {}
	var series := str(sr["series"])
	var cls := str(sr["cls"])
	var done := int(sr["done"])
	# the championship's race events and their qualifying (as the recap finds them)
	var rounds := []
	var quali := {}
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
	var lap_days := {}
	for day in Profiles.days:
		if day.has("race_file"):
			lap_days[str(day["race_file"])] = day
	var champ := _champ_places(ch, driver, done)
	var standings: Array = sr["standings"]
	var place := 0
	var me := {}
	for i in standings.size():
		if str(standings[i]["name"]) == driver:
			place = i + 1
			me = standings[i]
	var rows := []
	var elo0 := NAN
	var elo1 := NAN
	for ri in rounds.size():
		var ev: Dictionary = rounds[ri]
		var st: Dictionary = ev.get("stats", {}).get("race", {}).get(cls, {})
		var day: Dictionary = lap_days.get(str(ev["file"]), {})
		var lap_rows: Dictionary = day.get("race", {}).get("drivers", {})
		var row := {"round": ri + 1, "course": short(str(ev.get("course", ""))), "raced": false,
			"wet": float(day.get("race", {}).get("wet", 0.0)) > 0.2, "champ": int(champ[ri]) if ri < champ.size() else 0}
		# the class's middle race pace and the fastest, from drivers with enough clean laps
		var paces := []
		for nm in lap_rows:
			var r: Dictionary = lap_rows[nm]
			if str(r.get("cls", "")) == cls and float(r.get("pace", 0.0)) > 0.0 and int(r.get("clean_n", 0)) >= MIN_CLEAN:
				paces.append(float(r["pace"]))
		paces.sort()
		for c in ev["changes"]:
			if c["cls"] != cls or c["sess"] != "race" or str(c["driver"]) != driver:
				continue
			var s: Dictionary = st.get(driver, {})
			row["raced"] = true
			row["pos"] = int(c["pos"])
			row["grid"] = int(s.get("grid", 0))
			row["dnf"] = Reports._retired(s.get("status", ""))
			row["laps"] = int(s.get("laps", 0))
			row["inc"] = int(s.get("inc", 0))
			row["led"] = int(RaceRecap._lead_info(str(ev["file"])).get(cls, {}).get("led", {}).get(driver, 0))
			if is_nan(elo0):
				elo0 = float(c["before"])
			elo1 = float(c["after"])
			var r: Dictionary = lap_rows.get(driver, {})
			if paces.size() >= 3 and not row["dnf"] and float(r.get("pace", 0.0)) > 0.0 and int(r.get("clean_n", 0)) >= MIN_CLEAN:
				var mid: float = paces[paces.size() / 2] if paces.size() % 2 == 1 else (paces[paces.size() / 2 - 1] + paces[paces.size() / 2]) / 2.0
				row["pace"] = (mid / float(r["pace"]) - 1.0) * 100.0   # + = faster than the middle driver
				row["fastest"] = float(r["pace"]) <= float(paces[0]) + 1e-6
			if r.has("costly_n"):
				row["costly"] = int(r.get("costly", 0))
				row["costly_s"] = float(r.get("costly_s", 0.0))
		for c in quali.get(str(ev["file"]), {}).get("changes", []):
			if c["cls"] == cls and c["sess"] == "quali" and str(c["driver"]) == driver:
				row["quali"] = int(c["pos"])
		row["pole"] = int(row.get("quali", 0)) == 1
		rows.append(row)
	var raced := rows.filter(func(r): return r["raced"])
	if raced.is_empty():
		return {}
	var awards: Array = (sr.get("awards", []) as Array).filter(func(a): return str(a["name"]) == driver)
	var rookie := _rookie(season, driver)
	var imp := SeasonRecap.improvement(_sessions(rounds, cls, lap_days))
	var trend: Dictionary = imp.get(driver, {})
	var out := {"season": season, "key": key, "series": series, "cls": cls, "driver": driver, "done": done,
		"total": int(sr["total"]), "final": bool(sr["final"]), "place": place, "points": int(me.get("points", 0)),
		"wins": int(me.get("wins", 0)), "podiums": int(me.get("pod", 0)), "rounds": rows, "awards": awards,
		"rookie": rookie, "elo0": elo0, "elo1": elo1, "field": _field_size(rounds, cls)}
	out["improving"] = not trend.is_empty() and float(trend["gain"]) > 0.0 and float(trend["sure"]) >= TREND_SURE
	out["gain"] = float(trend.get("gain", 0.0))
	out["tiles"] = _tiles(out)
	out["headline"] = _headline(out, champ)
	out["beats"] = _beats(out)
	return out


# Championship place after each round (dropped rounds as the standings had them then).
static func _champ_places(ch: Dictionary, driver: String, done: int) -> Array:
	var drivers: Dictionary = ch["drivers"]
	var after := {}
	for d in drivers:
		var pts: Array = (drivers[d]["by_round"] as Array).map(func(x): return int(x["pts"]))
		var line := []
		for r in range(1, done + 1):
			line.append(SeasonScenarios.final_score(pts.slice(0, r), r))
		after[d] = line
	var out := []
	for r in done:
		var mine := int(after[driver][r]) if r < (after[driver] as Array).size() else 0
		var ahead := 0
		for d in after:
			if d != driver and int(after[d][r]) > mine:
				ahead += 1
		out.append(ahead + 1)
	return out


static func _rookie(season: String, driver: String) -> bool:
	var seasons := Elo.seasons()
	var this_i := seasons.find(season)
	for ev in Elo.history:
		if seasons.find(Elo.season_of(ev)) >= this_i:
			continue
		for c in ev["changes"]:
			if str(c["driver"]) == driver:
				return false
	return true


static func _field_size(rounds: Array, cls: String) -> int:
	var n := 0
	for ev in rounds:
		n = maxi(n, (ev["changes"] as Array).filter(func(c): return c["cls"] == cls and c["sess"] == "race").size())
	return n


# Every dry qualifying and race of the season (as Most improved takes them).
static func _sessions(rounds: Array, cls: String, lap_days: Dictionary) -> Array:
	var sessions := []
	for ri in rounds.size():
		var day: Dictionary = lap_days.get(str(rounds[ri]["file"]), {})
		var q: Dictionary = day.get("quali", {})
		if float(q.get("wet", 0.0)) <= 0.2:
			for nm in q.get("drivers", {}):
				var x: Dictionary = q["drivers"][nm]
				if str(x.get("cls", "")) == cls and float(x.get("best", 0.0)) > 0.0:
					sessions.append([nm, ri, "quali", 100.0 * log(float(x["best"])) - Predict.ballast_k_history() * float(x.get("mass", 0.0))])
		if float(day.get("race", {}).get("wet", 0.0)) <= 0.2:
			var rr: Dictionary = day.get("race", {}).get("drivers", {})
			for nm in rr:
				var x: Dictionary = rr[nm]
				if str(x.get("cls", "")) == cls and float(x.get("pace", 0.0)) > 0.0 and int(x.get("clean_n", 99)) >= 5:
					sessions.append([nm, ri, "race", 100.0 * log(float(x["pace"])) - Predict.ballast_k_history() * float(x.get("mass", 0.0))])
	return sessions


# Short track names for tight spaces ("Road Atlanta", "Spa"); unknown tracks keep their name.
const SHORT := {"Algarve International Circuit": "Portimão", "Autodromo Enzo e Dino Ferrari": "Imola",
	"Autodromo Nazionale Monza": "Monza", "Autódromo José Carlos Pace": "Interlagos", "Bahrain International Circuit": "Bahrain",
	"Bahrain Outer Circuit": "Bahrain Outer", "Circuit de Barcelona": "Barcelona", "Circuit de Spa-Francorchamps": "Spa",
	"Circuit de Spa-Francorchamps Endurance": "Spa", "Circuit de la Sarthe": "Le Mans", "Circuit of the Americas": "COTA",
	"Daytona International Speedway Road Course": "Daytona", "Fuji Speedway": "Fuji", "Fuji Speedway Classic": "Fuji Classic",
	"Lusail International Circuit": "Lusail", "Michelin Raceway Road Atlanta": "Road Atlanta", "Monza Curva Grande Circuit": "Monza Curva Grande",
	"Paul Ricard - ELMS": "Paul Ricard", "Sebring International Raceway": "Sebring", "Silverstone Grand Prix Circuit - ELMS": "Silverstone",
	"WeatherTech Raceway Laguna Seca": "Laguna Seca"}


static func short(course: String) -> String:
	if SHORT.has(course):
		return SHORT[course]
	var out := course.get_slice(" - ", 0)
	for w in ["International ", " International", "Circuit de ", "Circuit ", " Circuit", " Raceway", "Raceway ", " Speedway", "Autodromo ", "Autódromo "]:
		out = out.replace(w, " ").strip_edges()
	return out if out != "" else course


static func _n(x: int, one: String, many := "") -> String:
	return "%d %s" % [x, one if x == 1 else (many if many != "" else one + "s")]


static func _word(x: int) -> String:
	return ["no", "once", "twice", "three times", "four times", "five times"][x] if x <= 5 else "%d times" % x


static func _courses(rows: Array) -> String:
	var c := rows.map(func(r): return "R%d" % r["round"])
	if c.size() == 1:
		return str(rows[0]["course"])
	if c.size() == 2:
		return "%s and %s" % [c[0], c[1]]
	return ", ".join(PackedStringArray(c.slice(0, 3))) + (" +%d" % (c.size() - 3) if c.size() > 3 else "")


# Five numbers: [big value, label, line under it], the strongest first after place and best finish.
static func _tiles(st: Dictionary) -> Array:
	var rows: Array = (st["rounds"] as Array).filter(func(r): return r["raced"])
	var fin := rows.filter(func(r): return not r["dnf"])
	var out := [["P%d" % st["place"], "championship", _n(int(st["points"]), "pt")]]
	if not fin.is_empty():
		var best := 999
		for r in fin:
			best = mini(best, int(r["pos"]))
		var at := fin.filter(func(r): return int(r["pos"]) == best)
		out.append(["P%d" % best, "best finish", _word(at.size()) if at.size() > 1 else str(at[0]["course"])])
	var cand := []   # [weight, tile]
	var wins := rows.filter(func(r): return not r["dnf"] and int(r["pos"]) == 1)
	if wins.size() >= 2:   # a single win is the best finish already
		cand.append([10, [str(wins.size()), "wins" if wins.size() > 1 else "win", _courses(wins)]])
	var pods := rows.filter(func(r): return not r["dnf"] and int(r["pos"]) <= 3)
	if pods.size() >= 2 and pods.size() > wins.size():
		cand.append([8, [str(pods.size()), "podiums", _courses(pods)]])
	var fast := rows.filter(func(r): return bool(r.get("fastest", false)))
	if not fast.is_empty():
		cand.append([7 if fast.size() >= 2 else 4, ["%d×" % fast.size() if fast.size() > 1 else "1", "fastest pace", "in class" if fast.size() > 1 else str(fast[0]["course"])]])
	var poles := rows.filter(func(r): return bool(r["pole"]))
	if not poles.is_empty():
		cand.append([5, [str(poles.size()), "poles" if poles.size() > 1 else "pole", _courses(poles)]])
	var led := 0
	var led_races := 0
	for r in rows:
		led += int(r["led"])
		led_races += 1 if int(r["led"]) > 0 else 0
	if led > 0:
		cand.append([4 if led >= 10 else 2, [str(led), "laps led", "in " + _n(led_races, "race")]])
	if not is_nan(float(st["elo0"])):
		var gain := roundi(float(st["elo1"]) - float(st["elo0"]))
		if gain >= 30:
			cand.append([5, ["%+d" % gain, "rating", "%d → %d" % [roundi(float(st["elo0"])), roundi(float(st["elo1"]))], true]])
	var gained := 0
	for r in fin:
		if int(r["grid"]) > 0:
			gained += int(r["grid"]) - int(r["pos"])
	if gained >= 5:
		cand.append([3, ["%+d" % gained, "places gained", "from the grid"]])
	var clean := rows.filter(func(r): return int(r["inc"]) == 0)
	if clean.size() >= maxi(2, ceili(rows.size() * 0.6)):
		cand.append([3 if clean.size() < rows.size() else 6, ["%d of %d" % [clean.size(), rows.size()], "clean races", "no contact"]])
	cand.append([1, [str(rows.size()), "races", _n(_laps(rows), "lap")]])
	cand.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	for c in cand:
		if out.size() >= 5:
			break
		out.append(c[1])
	return out.map(func(t): return {"value": t[0], "label": t[1], "line": t[2], "good": t.size() > 3})


static func _laps(rows: Array) -> int:
	var n := 0
	for r in rows:
		n += int(r["laps"])
	return n


# One line: who they were this season (champion, rookie) and its strongest fact.
static func _headline(st: Dictionary, champ: Array) -> Dictionary:
	var rows: Array = (st["rounds"] as Array).filter(func(r): return r["raced"])
	var lead := ""
	if int(st["place"]) == 1:
		lead = "Champion" if bool(st["final"]) else "Leading the championship"
	elif int(st["place"]) == 2 and bool(st["final"]):
		lead = "Runner-up"
	elif bool(st["rookie"]):
		lead = "Rookie season"
	if _part_time(st) and int(st["place"]) > 2:   # a few races only: the championship place says little
		var pf := _results_fact(rows.map(func(r): return [r, ""]))
		return {"lead": lead, "fact": pf, "text": (lead + ": " + pf) if lead != "" else pf.left(1).to_upper() + pf.substr(1)}
	var fast := rows.filter(func(r): return bool(r.get("fastest", false))).size()
	var best_champ := 999
	var led_after := 0
	for i in champ.size():
		if i > 0 or (st["rounds"][i] as Dictionary)["raced"]:   # not "P1" after a round 1 nobody else scored in
			best_champ = mini(best_champ, int(champ[i]))
			if int(champ[i]) == 1 and led_after == 0:
				led_after = i + 1
	var poles := rows.filter(func(r): return bool(r["pole"])).size()
	var clean := rows.filter(func(r): return int(r["inc"]) == 0).size()
	var climb := {}   # the biggest climb from the grid, 8 places or more
	for r in rows:
		if not r["dnf"] and int(r["grid"]) - int(r["pos"]) >= 8 and (climb.is_empty() or int(r["grid"]) - int(r["pos"]) > int(climb["grid"]) - int(climb["pos"])):
			climb = r
	# the season's strongest facts, best first; the headline takes the top two
	var facts := []
	if int(st["place"]) == 1:
		facts.append("%s, %s" % [_n(int(st["wins"]), "win"), _n(int(st["podiums"]), "podium")])
	elif int(st["wins"]) > 0:
		facts.append(_n(int(st["wins"]), "race win"))
	if fast >= 2:
		facts.append("fastest race pace %s" % _word(fast))
	if bool(st["improving"]):
		facts.append("quicker round after round")
	if bool(st["rookie"]) and poles > 0:
		facts.append("pole-sitter by round %d" % int(rows.filter(func(r): return bool(r["pole"]))[0]["round"]))
	if clean == rows.size() and rows.size() >= 3:
		facts.append("no contact all season")
	if not climb.is_empty():
		facts.append("from P%d to P%d at %s" % [climb["grid"], climb["pos"], climb["course"]])
	if int(st["podiums"]) > 0 and int(st["place"]) != 1:
		facts.append(_n(int(st["podiums"]), "podium"))
	if poles > 0:
		facts.append(_n(poles, "pole"))
	if facts.is_empty():
		var best := 999
		for r in rows:
			if not r["dnf"]:
				best = mini(best, int(r["pos"]))
		facts.append("%s, best finish P%d" % [_n(rows.size(), "race"), best] if best < 999 else _n(rows.size(), "race"))
	var fact: String = facts[0]
	# a second clause: the championship fight, when it says more than the final place
	var extra := ""
	if led_after > 0 and int(st["place"]) != 1:
		extra = "led the championship after R%d" % led_after
	elif best_champ <= 3 and best_champ < int(st["place"]):
		extra = "up to P%d in the championship" % best_champ
	elif facts.size() > 1:
		extra = facts[1]
	if extra != "":
		fact += ", " + extra
	return {"lead": lead, "fact": fact, "text": (lead + ": " + fact) if lead != "" else fact.left(1).to_upper() + fact.substr(1)}


# Raced fewer than half of the championship's rounds.
static func _part_time(st: Dictionary) -> bool:
	var rounds: Array = st["rounds"]
	return rounds.filter(func(r): return r["raced"]).size() * 2 < rounds.size()


# The best results of a few races, for a part-time season: "won at Lusail from pole, 2 podiums in
# 3 races", "podium at Monza in 2 races", "best finish P5 at Lusail in 2 races", "a single start,
# P12 at Fuji from P19".
# races: [[round row, series name or ""]]
static func _results_fact(races: Array) -> String:
	var fin := races.filter(func(x): return not x[0]["dnf"])
	var at := func(x: Array) -> String:   # "at Lusail", or "in the Enduro at Lusail"
		return ("in the %s at %s" % [x[1], x[0]["course"]]) if str(x[1]) != "" else "at %s" % x[0]["course"]
	if races.size() == 1:   # one start (a single championship): the result itself
		var r: Dictionary = races[0][0]
		var what := "out after %s" % _n(int(r["laps"]), "lap") if r["dnf"] else ("won" if int(r["pos"]) == 1 else "P%d" % int(r["pos"]))
		var from := ""
		if not r["dnf"] and bool(r["pole"]):
			from = " from pole"
		elif not r["dnf"] and int(r["grid"]) > int(r["pos"]):
			from = " from P%d" % int(r["grid"])
		return "a single start, %s at %s%s" % [what, r["course"], from]
	var wins := fin.filter(func(x): return int(x[0]["pos"]) == 1)
	var pods := fin.filter(func(x): return int(x[0]["pos"]) <= 3)
	var main := ""
	if wins.size() == 1:
		main = "won %s%s" % [str(at.call(wins[0])).trim_prefix("in "), " from pole" if bool(wins[0][0]["pole"]) else ""]
	elif wins.size() > 1:
		main = _n(wins.size(), "win")
	elif pods.size() == 1:
		main = "podium " + str(at.call(pods[0]))
	elif pods.size() > 1:
		main = _n(pods.size(), "podium")
	elif not fin.is_empty():
		var best: Array = fin[0]
		for x in fin:
			if int(x[0]["pos"]) < int(best[0]["pos"]):
				best = x
		main = "best finish P%d %s" % [int(best[0]["pos"]), at.call(best)]
	else:
		return "%s, no finish" % _n(races.size(), "race")
	if wins.size() >= 1 and pods.size() > wins.size():
		main += ", %s" % _n(pods.size(), "podium")
	return main + " in %s" % _n(races.size(), "race")


# High point, toughest day, award (or the best of what is left). [{"kind", "title", "text"}]
static func _beats(st: Dictionary) -> Array:
	var rows: Array = (st["rounds"] as Array).filter(func(r): return r["raced"])
	var out := []
	# high point: the best race (a win, a podium, a pole, laps led, places gained, fastest pace)
	var high := {}
	var high_s := -1.0
	for r in rows:
		var sc := 0.0
		if not r["dnf"]:
			sc += 100.0 if int(r["pos"]) == 1 else (60.0 if int(r["pos"]) <= 3 else 30.0 / float(r["pos"]))
			if int(r["grid"]) > 0:
				sc += 3.0 * maxf(0.0, float(r["grid"]) - float(r["pos"]))
		sc += 25.0 if r["pole"] else 0.0
		sc += minf(float(r["led"]), 30.0)
		sc += 15.0 if bool(r.get("fastest", false)) else 0.0
		if sc > high_s:
			high_s = sc
			high = r
	if not high.is_empty():
		var bits := []
		if high["pole"]:
			bits.append("pole")
		elif int(high.get("grid", 0)) == 2:
			bits.append("front row")
		elif int(high.get("grid", 0)) > 0 and not high["dnf"] and int(high["grid"]) - int(high["pos"]) >= 3:
			bits.append("from P%d" % high["grid"])
		if int(high["led"]) > 0:
			bits.append("led %s" % _n(int(high["led"]), "lap"))
		if bool(high.get("fastest", false)):
			bits.append("fastest race pace")
		if not high["dnf"]:
			bits.append("won" if int(high["pos"]) == 1 else ("podium in P%d" % high["pos"] if int(high["pos"]) <= 3 else "finished P%d" % high["pos"]))
		var t := ", ".join(PackedStringArray(bits))
		out.append({"kind": "high", "title": "R%d %s" % [high["round"], high["course"]], "text": t.left(1).to_upper() + t.substr(1)})
	# toughest day: a retirement, else the most places lost or time lost to mistakes
	var low := {}
	var low_s := 0.0
	for r in rows:
		if r == high:
			continue
		var sc := 0.0
		if r["dnf"]:
			sc = 50.0
		else:
			if int(r["grid"]) > 0:
				sc += 4.0 * maxf(0.0, float(r["pos"]) - float(r["grid"]))
			sc += float(r.get("costly_s", 0.0)) / 3.0
		if sc > low_s and sc >= 10.0:
			low_s = sc
			low = r
	if not low.is_empty():
		var t := ""
		if low["dnf"]:
			t = "Out after %s" % _n(int(low["laps"]), "lap")
			if int(low.get("quali", 0)) > 0 and int(low["quali"]) > 3:
				t = "Qualified P%d, out after %s" % [low["quali"], _n(int(low["laps"]), "lap")]
		else:
			var parts := []
			if int(low["grid"]) > 0:
				parts.append("Started P%d" % low["grid"])
			if int(low["led"]) > 0:
				parts.append("led %s" % _n(int(low["led"]), "lap"))
			if float(low.get("costly_s", 0.0)) >= COSTLY_SHOWN:
				parts.append("%s cost %d s" % [_n(int(low["costly"]), "mistake"), roundi(float(low["costly_s"]))])
			parts.append("finished P%d" % low["pos"])
			t = ", ".join(PackedStringArray(parts))
		out.append({"kind": "low", "title": "R%d %s" % [low["round"], low["course"]], "text": t})
	# awards from the season recap, then the clean record, then the season's laps, up to three beats
	for a in st["awards"]:
		if out.size() < 3:
			var tag := str(a["tag"]).to_lower().capitalize().replace(" Of The ", " of the ")
			var text := str(a["text"])
			for full in SHORT:   # the recap's full track names, shortened to fit
				text = text.replace(full, SHORT[full])
			out.append({"kind": "award", "title": tag, "text": text})
	var clean := rows.filter(func(r): return int(r["inc"]) == 0).size()
	if out.size() < 3 and clean >= 2:
		out.append({"kind": "note", "title": "Clean racing", "text": "No contact in %d of %s" % [clean, _n(rows.size(), "race")]})
	var mistakes := 0
	var costly_n := 0
	for r in rows:
		if r.has("costly"):
			costly_n += 1
			mistakes += int(r["costly"])
	if out.size() < 3 and costly_n >= 3 and mistakes == 0:
		out.append({"kind": "note", "title": "No costly mistakes", "text": "Not one big mistake in %s" % _n(_laps(rows), "lap")})
	if out.size() < 3:
		out.append({"kind": "note", "title": "%s raced" % _n(_laps(rows), "lap"), "text": "in %s" % _n(rows.size(), "race")})
	return out


# ---------- Combined story: every championship a driver raced in a season ----------
# {"combined": true, "season", "driver", "stories": [single stories], "columns": [{"label", "sub",
#  "entries": [{"color", "grid", "pos", "dnf", "pole", "raced"}]}], "aligned": same calendar (one
#  column per round) or not (one column per race, in date order), "rating": [{"cls", "points":
#  [[elo, colour]]}], "tiles", "headline", "beats", "cards"}. A driver with one championship gets
#  that championship's story instead (no "combined" key).

const ALL := "*"   # the championship key meaning "all of them"


static func championships_of(season: String, driver: String) -> Array:
	var out := []
	var champs := Reports.season_points(season)
	for k in champs:
		if champs[k].get("drivers", {}).has(driver):
			out.append(k)
	out.sort()
	return out


# Everyone who raced the season, in alphabetical order of their shown name.
static func season_drivers(season: String) -> Array:
	var seen := {}
	var champs := Reports.season_points(season)
	for k in champs:
		for d in champs[k].get("drivers", {}):
			seen[d] = true
	var out := seen.keys()
	out.sort_custom(func(a, b): return Elo.pretty(str(a)).to_lower() < Elo.pretty(str(b)).to_lower())
	return out


static func build_combined(season: String, driver: String, recaps := {}) -> Dictionary:
	var keys := championships_of(season, driver)
	if keys.is_empty():
		return {}
	var stories := []
	for k in keys:
		var st := build(season, k, driver, recaps.get(k, {}))
		if not st.is_empty():
			stories.append(st)
	if stories.size() == 1:
		return stories[0]
	if stories.is_empty():
		return {}
	var series_seen := {}
	for st in stories:
		series_seen[str(st["series"])] = int(series_seen.get(str(st["series"]), 0)) + 1
	for st in stories:
		var sname := LeagueSettings.series_name(LeagueSettings.series_code(str(st["series"])))
		st["label"] = "%s %s" % [sname, LeagueSettings.label(str(st["cls"]))]
		st["short"] = sname if int(series_seen[str(st["series"])]) == 1 else str(st["label"])   # "Sprint", or "Sprint GT3" when it had two classes
		st["color"] = LeagueSettings.series_color(LeagueSettings.series_code(str(st["series"])))
	var used := {}   # a series' second class (Sprint GT3 and Sprint LMP3): a lighter shade of its colour
	for st in stories:
		var k := str(st["series"])
		if used.has(k):
			st["color"] = Color(st["color"]).lerp(Color.WHITE, 0.5 if int(used[k]) == 1 else 0.75)
		used[k] = int(used.get(k, 0)) + 1
	var out := {"combined": true, "season": season, "driver": driver, "stories": stories}
	# one column per round when every championship ran the same tracks in the same order
	var aligned := true
	var n := (stories[0]["rounds"] as Array).size()
	for st in stories:
		if (st["rounds"] as Array).size() != n:
			aligned = false
	if aligned:
		for i in n:
			for st in stories:
				if str(st["rounds"][i]["course"]) != str(stories[0]["rounds"][i]["course"]):
					aligned = false
	var columns := []
	if aligned:
		for i in n:
			var col := {"label": "R%d %s" % [i + 1, stories[0]["rounds"][i]["course"]], "sub": "", "entries": [], "wet": false}
			for st in stories:
				var r: Dictionary = st["rounds"][i]
				col["entries"].append(_entry(r, st))
				col["wet"] = col["wet"] or bool(r["wet"])
			columns.append(col)
	else:
		var races := []   # [order in Elo.history, story, round]
		for st in stories:
			for r in st["rounds"]:
				if r["raced"]:
					races.append([_event_order(season, str(st["series"]), int(r["round"])), st, r])
		races.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
		for x in races:
			columns.append({"label": "%s" % x[2]["course"], "sub": "R%d" % x[2]["round"], "entries": [_entry(x[2], x[1])], "wet": bool(x[2]["wet"])})
	out["aligned"] = aligned
	out["columns"] = columns
	var colors := {}
	for st in stories:
		colors["%s|%s" % [st["series"], st["cls"]]] = st["color"]
	out["rating"] = _rating_lines(season, driver, colors)
	out["cards"] = stories.map(func(st): return {"label": str(st["label"]), "color": st["color"], "place": int(st["place"]),
		"points": int(st["points"]), "line": _card_line(st)})
	out["tiles"] = _combined_tiles(out)
	out["headline"] = _combined_headline(out)
	out["beats"] = _combined_beats(out)
	return out


static func _entry(r: Dictionary, st: Dictionary) -> Dictionary:
	return {"color": st["color"], "raced": bool(r["raced"]), "grid": int(r.get("grid", 0)), "pos": int(r.get("pos", 0)),
		"dnf": bool(r.get("dnf", false)), "pole": bool(r.get("pole", false)), "series": str(st["label"]),
		"wet": bool(r.get("wet", false)), "fastest": bool(r.get("fastest", false)),
		"costly": int(r.get("costly", 0)), "costly_s": float(r.get("costly_s", 0.0))}.merged({"pace": r["pace"]} if r.has("pace") else {})


# Where a championship's round sits in the league's history (for the date order).
static func _event_order(season: String, series: String, round: int) -> int:
	var n := 0
	for i in Elo.history.size():
		var ev: Dictionary = Elo.history[i]
		if Elo.season_of(ev) == season and Elo.series_of(ev) == series and (ev["changes"] as Array).any(func(c): return c["sess"] == "race"):
			n += 1
			if n == round:
				return i
	return 0


# The driver's race rating through the season, one line per class: [{"cls", "points": [[elo, colour]]}]
# (the first point is the rating before the season's first race, without a colour).
static func _rating_lines(season: String, driver: String, colors := {}) -> Array:
	var lines := {}
	for ev in Elo.history:
		if Elo.season_of(ev) != season:
			continue
		for c in ev["changes"]:
			if str(c["driver"]) != driver or c["sess"] != "race":
				continue
			var cls := str(c["cls"])
			var col = colors.get("%s|%s" % [Elo.series_of(ev), cls], LeagueSettings.series_color(LeagueSettings.series_code(Elo.series_of(ev))))
			if not lines.has(cls):
				lines[cls] = [[float(c["before"]), null]]
			lines[cls].append([float(c["after"]), col])
	var out := []
	for cls in lines:
		out.append({"cls": cls, "points": lines[cls]})
	return out


static func _card_line(st: Dictionary) -> String:
	var rows: Array = (st["rounds"] as Array).filter(func(r): return r["raced"])
	var bits := []
	var wins := rows.filter(func(r): return not r["dnf"] and int(r["pos"]) == 1)
	var pods := rows.filter(func(r): return not r["dnf"] and int(r["pos"]) <= 3)
	var poles := rows.filter(func(r): return bool(r["pole"]))
	if wins.size() > 0:
		bits.append(_n(wins.size(), "win") if wins.size() > 1 else "Win at %s" % wins[0]["course"])
	if pods.size() > wins.size():
		bits.append(_n(pods.size(), "podium") if pods.size() > 1 else "Podium at %s" % pods[0]["course"])
	if poles.size() > 0:
		bits.append(_n(poles.size(), "pole") if poles.size() > 1 else "pole at %s" % poles[0]["course"])
	var led := 0
	for r in rows:
		led += int(r["led"])
	if led > 0 and bits.size() < 2:
		bits.append("%s led" % _n(led, "lap"))
	if bits.is_empty():
		var best := 999
		for r in rows:
			if not r["dnf"]:
				best = mini(best, int(r["pos"]))
		bits.append("%s, best finish P%d" % [_n(rows.size(), "race"), best] if best < 999 else _n(rows.size(), "race"))
	var t := " · ".join(PackedStringArray(bits))
	return t.left(1).to_upper() + t.substr(1)


static func _combined_tiles(c: Dictionary) -> Array:
	var all := []   # [story, round]
	for st in c["stories"]:
		for r in st["rounds"]:
			if r["raced"]:
				all.append([st, r])
	var fin := all.filter(func(x): return not x[1]["dnf"])
	var out := [{"value": str(all.size()), "label": "races", "line": "in %d championships" % (c["stories"] as Array).size(), "good": false}]
	if not fin.is_empty():
		var best := 999
		for x in fin:
			best = mini(best, int(x[1]["pos"]))
		var at := fin.filter(func(x): return int(x[1]["pos"]) == best)
		out.append({"value": "P%d" % best, "label": "best finish",
			"line": _word(at.size()) if at.size() > 1 else "%s, %s" % [at[0][0]["short"], at[0][1]["course"]], "good": false})
	var cand := []
	var wins := fin.filter(func(x): return int(x[1]["pos"]) == 1).size()
	var pods := fin.filter(func(x): return int(x[1]["pos"]) <= 3).size()
	if wins >= 2:
		cand.append([10, {"value": str(wins), "label": "wins", "line": "this season", "good": false}])
	if pods >= 2 and pods > wins:
		cand.append([8, {"value": str(pods), "label": "podiums", "line": "this season", "good": false}])
	var poles := all.filter(func(x): return bool(x[1]["pole"])).size()
	if poles > 0:
		var each := (c["stories"] as Array).all(func(st): return (st["rounds"] as Array).any(func(r): return bool(r.get("pole", false))))
		cand.append([5, {"value": str(poles), "label": "poles" if poles > 1 else "pole", "line": "one in each" if each and poles == (c["stories"] as Array).size() else "this season", "good": false}])
	var led := 0
	var led_r := 0
	for x in all:
		led += int(x[1]["led"])
		led_r += 1 if int(x[1]["led"]) > 0 else 0
	if led > 0:
		cand.append([4 if led >= 10 else 2, {"value": str(led), "label": "laps led", "line": "in " + _n(led_r, "race"), "good": false}])
	for line in c["rating"]:
		var p: Array = line["points"]
		var gain := roundi(float(p[-1][0]) - float(p[0][0]))
		if gain >= 30:
			cand.append([6, {"value": "%+d" % gain, "label": "%s rating" % LeagueSettings.label(str(line["cls"])), "line": "%d → %d" % [roundi(float(p[0][0])), roundi(float(p[-1][0]))], "good": true}])
	var clean := all.filter(func(x): return int(x[1]["inc"]) == 0).size()
	if clean >= maxi(3, ceili(all.size() * 0.6)):
		cand.append([3, {"value": "%d of %d" % [clean, all.size()], "label": "clean races", "line": "no contact", "good": false}])
	cand.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	for x in cand:
		if out.size() >= 5:
			break
		out.append(x[1])
	return out


static func _combined_headline(c: Dictionary) -> Dictionary:
	var stories: Array = c["stories"]
	var lead := ""
	var champs := stories.filter(func(st): return int(st["place"]) == 1 and bool(st["final"]))
	if not champs.is_empty():
		lead = ("%s champion" % champs[0]["label"]) if champs.size() == 1 else "Double champion"
	elif stories.any(func(st): return bool(st["rookie"])):
		lead = "Rookie season"
	var rest := stories.filter(func(st): return not st in champs) if champs.size() == 1 else stories
	# championships raced only now and then: their place says little, their best results say more
	var part := rest.filter(func(st): return _part_time(st) and int(st["place"]) > 2)
	if not part.is_empty() and part.size() == rest.size() and champs.size() < 2:
		var races := []
		for st in part:
			for r in st["rounds"]:
				if r["raced"]:
					races.append([r, str(st["short"])])
		var pf := _results_fact(races)
		return {"lead": lead, "fact": pf, "text": (lead + ": " + pf) if lead != "" else pf.left(1).to_upper() + pf.substr(1)}
	var places := rest.map(func(st): return int(st["place"]))
	var fact := ""
	if rest.size() > 1 and places.all(func(p): return p == places[0]):
		fact = "P%d in %s championships" % [places[0], "both" if stories.size() == 2 else "all %d" % stories.size()]
	else:
		var parts := PackedStringArray()
		for st in rest:
			parts.append("P%d in %s" % [st["place"], st["label"]])
		fact = ", ".join(parts)
	for line in c["rating"]:
		var p: Array = line["points"]
		var gain := roundi(float(p[-1][0]) - float(p[0][0]))
		if gain >= 30 and (c["rating"] as Array).size() == 1:
			fact += ", rating %+d" % gain
	return {"lead": lead, "fact": fact, "text": (lead + ": " + fact) if lead != "" else fact}


# High point and toughest day by weekend (both races that weekend) when the calendars match, else
# by race; then the awards of every championship (the same award twice: "×2").
static func _combined_beats(c: Dictionary) -> Array:
	var out := []
	var groups := []   # [[story, round], ...] per column
	if bool(c["aligned"]):
		var n := (c["stories"][0]["rounds"] as Array).size()
		for i in n:
			var g := []
			for st in c["stories"]:
				if st["rounds"][i]["raced"]:
					g.append([st, st["rounds"][i]])
			groups.append(g)
	else:
		for st in c["stories"]:
			for r in st["rounds"]:
				if r["raced"]:
					groups.append([[st, r]])
	var high := []
	var high_s := -1.0
	var low := []
	var low_s := 0.0
	for g in groups:
		if g.is_empty():
			continue
		var hs := 0.0
		var ls := 0.0
		for x in g:
			hs += _race_high(x[1])
			ls += _race_low(x[1])
		if hs > high_s:
			high_s = hs
			high = g
		if ls > low_s and ls >= 10.0:
			low_s = ls
			low = g
	if not high.is_empty():
		out.append({"kind": "high", "title": _group_title(high, bool(c["aligned"])), "text": _group_text(high, true)})
	if not low.is_empty() and low != high:
		out.append({"kind": "low", "title": _group_title(low, bool(c["aligned"])), "text": _group_text(low, false)})
	var tags := {}
	var order := []
	for st in c["stories"]:
		for a in st["awards"]:
			var tag := str(a["tag"]).to_lower().capitalize().replace(" Of The ", " of the ")
			if not tags.has(tag):
				tags[tag] = []
				order.append(tag)
			tags[tag].append(str(st["label"]))
	if not order.is_empty():
		var first: String = order[0]
		var title := first + (" ×%d" % tags[first].size() if tags[first].size() > 1 else "")
		var text := " and ".join(PackedStringArray(tags[first]))
		if order.size() > 1:
			var more := PackedStringArray()
			for t in order.slice(1):
				more.append("%s (%s)" % [t, ", ".join(PackedStringArray(tags[t]))])
			text += ". Also: " + "; ".join(more)
		out.append({"kind": "award", "title": title, "text": text})
	if out.size() < 3:
		var laps := 0
		var races := 0
		for st in c["stories"]:
			for r in st["rounds"]:
				if r["raced"]:
					laps += int(r["laps"])
					races += 1
		out.append({"kind": "note", "title": "%s raced" % _n(laps, "lap"), "text": "in %s, %d championships" % [_n(races, "race"), (c["stories"] as Array).size()]})
	return out


static func _race_high(r: Dictionary) -> float:
	var sc := 0.0
	if not r["dnf"]:
		sc += 100.0 if int(r["pos"]) == 1 else (60.0 if int(r["pos"]) <= 3 else 30.0 / float(r["pos"]))
		if int(r["grid"]) > 0:
			sc += 3.0 * maxf(0.0, float(r["grid"]) - float(r["pos"]))
	sc += 25.0 if r["pole"] else 0.0
	sc += minf(float(r["led"]), 30.0)
	return sc + (15.0 if bool(r.get("fastest", false)) else 0.0)


static func _race_low(r: Dictionary) -> float:
	if r["dnf"]:
		return 50.0
	var sc := 0.0
	if int(r["grid"]) > 0:
		sc += 4.0 * maxf(0.0, float(r["pos"]) - float(r["grid"]))
	return sc + float(r.get("costly_s", 0.0)) / 3.0


static func _group_title(g: Array, aligned: bool) -> String:
	var r: Dictionary = g[0][1]
	return "%s weekend" % r["course"] if aligned and g.size() > 1 else "R%d %s" % [r["round"], r["course"]]


static func _group_text(g: Array, good: bool) -> String:
	var parts := PackedStringArray()
	for x in g:
		var r: Dictionary = x[1]
		var who := str(x[0]["short"])
		var bits := []
		if good:
			if r["pole"]:
				bits.append("pole")
			if int(r["led"]) > 0:
				bits.append("led %s" % _n(int(r["led"]), "lap"))
			if not r["dnf"]:
				bits.append("won" if int(r["pos"]) == 1 else ("podium in P%d" % r["pos"] if int(r["pos"]) <= 3 else "P%d" % r["pos"]))
		else:
			if r["dnf"]:
				bits.append("out after %s" % _n(int(r["laps"]), "lap"))
			else:
				bits.append("P%d → P%d" % [r["grid"], r["pos"]] if int(r["grid"]) > 0 else "P%d" % r["pos"])
				if float(r.get("costly_s", 0.0)) >= COSTLY_SHOWN:
					bits.append("%s cost %d s" % [_n(int(r["costly"]), "mistake"), roundi(float(r["costly_s"]))])
		parts.append("%s: %s" % [who, ", ".join(PackedStringArray(bits))])
	return "; ".join(parts)
