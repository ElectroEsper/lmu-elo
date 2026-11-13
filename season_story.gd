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
	var lead := ("Champion" if bool(st["final"]) else "Leading the championship") if int(st["place"]) == 1 else ("Rookie season" if bool(st["rookie"]) else "")
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
	var fact := ""
	if int(st["place"]) == 1:
		fact = "%s, %s" % [_n(int(st["wins"]), "win"), _n(int(st["podiums"]), "podium")]
	elif int(st["wins"]) > 0:
		fact = _n(int(st["wins"]), "race win")
	elif fast >= 2:
		fact = "fastest race pace %s" % _word(fast)
	elif bool(st["improving"]):
		fact = "quicker round after round"
	elif bool(st["rookie"]) and poles > 0:
		fact = "pole-sitter by round %d" % int(rows.filter(func(r): return bool(r["pole"]))[0]["round"])
	elif clean == rows.size() and rows.size() >= 3:
		fact = "no contact all season"
	elif not climb.is_empty():
		fact = "from P%d to P%d at %s" % [climb["grid"], climb["pos"], climb["course"]]
	elif int(st["podiums"]) > 0:
		fact = _n(int(st["podiums"]), "podium")
	elif poles > 0:
		fact = _n(poles, "pole")
	else:
		var best := 999
		for r in rows:
			if not r["dnf"]:
				best = mini(best, int(r["pos"]))
		fact = "%s, best finish P%d" % [_n(rows.size(), "race"), best] if best < 999 else _n(rows.size(), "race")
	# a second clause: the championship fight, when it says more than the final place
	var extra := ""
	if led_after > 0 and int(st["place"]) != 1:
		extra = "led the championship after R%d" % led_after
	elif best_champ <= 3 and best_champ < int(st["place"]):
		extra = "up to P%d in the championship" % best_champ
	elif bool(st["improving"]) and fact != "quicker round after round":
		extra = "quicker round after round"
	if extra != "":
		fact += ", " + extra
	return {"lead": lead, "fact": fact, "text": (lead + ": " + fact) if lead != "" else fact.left(1).to_upper() + fact.substr(1)}


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
