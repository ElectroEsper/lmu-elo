class_name RaceRecap
extends RefCounted
## What happened in one race (one event file), class by class, for the Race recap graphic:
## podium with gaps, pole and where it finished, highlights picked when worth saying (clean racing
## first: clean race, clean charger; then hard charger, biggest surprise, firsts, lead battle,
## strategy, fastest lap, biggest rating gain), the championship after
## the round, and how a saved forecast did.
## Use as: var rc = RaceRecap.build("s6-mc4-r.xml")

const MIN_CLIMB := 3       # places gained from the grid worth a "hard charger" line
const CLEAN_TOP := 5       # "clean race": best finisher in this top N with no contact
const SURPRISE_MIN_Z := 1.0   # beat the expected place by at least one standard deviation


static func build(file: String) -> Dictionary:
	var ev := {}
	for h in Elo.history:
		if str(h["file"]) == file:
			ev = h
	if ev.is_empty():
		return {}
	var season := Elo.season_of(ev)
	var series := Elo.series_of(ev)
	var champs := Reports.season_points(season)
	var leads := _lead_info(file)   # class -> {"changes", "laps", "led": {driver: laps}}
	var classes := {}
	for c in ev["changes"]:
		if c["sess"] == "race":
			if not classes.has(c["cls"]):
				classes[c["cls"]] = []
			classes[c["cls"]].append(c)
	var out := {"file": file, "season": season, "series": series, "course": str(ev.get("course", "")), "classes": []}
	for cls in classes:
		var rows: Array = classes[cls]
		rows.sort_custom(func(a, b): return int(a["pos"]) < int(b["pos"]))
		var st: Dictionary = ev.get("stats", {}).get("race", {}).get(cls, {})
		var key := ("%s %s" % [series, cls]).strip_edges()
		var block := {"cls": cls, "podium": _podium(rows, st), "highlights": _highlights(rows, st, leads.get(cls, {}), file, str(cls)),
			"champ": _champ_line(champs.get(key, {}), file), "forecast": _forecast_line(file, str(cls))}
		var pole := ""
		for d in st:
			if int(st[d].get("grid", 0)) == 1:
				pole = d
		if pole != "":
			for r in rows:
				if r["driver"] == pole:
					block["pole"] = {"name": pole, "pos": int(r["pos"])}
		out["classes"].append(block)
	# the round of this event in its series (for "Round 5")
	var rnd := 0
	for h in Elo.history:
		if Elo.season_of(h) == season and Elo.series_of(h) == series:
			var has_race := false
			for c in h["changes"]:
				if c["sess"] == "race":
					has_race = true
					break
			if has_race:
				rnd += 1
			if str(h["file"]) == file:
				break
	out["round"] = rnd
	return out


# P1-P3 with the gap to the winner ("+4.312", "+1 lap") and where they started.
static func _podium(rows: Array, st: Dictionary) -> Array:
	var out := []
	var w: Dictionary = st.get(rows[0]["driver"], {}) if not rows.is_empty() else {}
	for i in mini(3, rows.size()):
		var d: String = rows[i]["driver"]
		var s: Dictionary = st.get(d, {})
		var gap := ""
		if i > 0 and not s.is_empty() and not w.is_empty():
			var dl := int(w.get("laps", 0)) - int(s.get("laps", 0))
			if dl > 0:
				gap = "+%d lap%s" % [dl, "" if dl == 1 else "s"]
			elif float(s.get("time", 0.0)) > 0.0 and float(w.get("time", 0.0)) > 0.0:
				gap = "+%.3f" % (float(s["time"]) - float(w["time"]))
		out.append({"pos": i + 1, "name": d, "gap": gap, "grid": int(s.get("grid", 0))})
	return out


static func _highlights(rows: Array, st: Dictionary, lead: Dictionary, file: String, cls: String) -> Array:
	var out := []
	# clean race first (the league puts clean racing first): best finisher in the top CLEAN_TOP with no contact
	for i in mini(CLEAN_TOP, rows.size()):
		var s: Dictionary = st.get(rows[i]["driver"], {})
		if not s.is_empty() and int(s.get("inc", 1)) == 0:
			out.append({"tag": "CLEAN RACE", "name": rows[i]["driver"], "text": "P%d, no contact" % (i + 1)})
			break
	# clean charger: most places gained from the grid without touching anyone (finishers only)
	var clean := {}
	for r in rows:
		var s: Dictionary = st.get(r["driver"], {})
		var g := int(s.get("grid", 0))
		if g <= 0 or Reports._retired(s.get("status", "")) or int(s.get("inc", 1)) != 0:
			continue
		var gain := g - int(r["pos"])
		if gain >= MIN_CLIMB and gain > int(clean.get("gain", 0)):
			clean = {"gain": gain, "name": r["driver"], "from": g, "to": int(r["pos"])}
	if not clean.is_empty():
		out.append({"tag": "CLEAN CHARGER", "name": clean["name"], "text": "P%d → P%d, no contact" % [clean["from"], clean["to"]]})
	# hard charger: most places gained from the grid (finishers only)
	var best := {}
	for r in rows:
		var s: Dictionary = st.get(r["driver"], {})
		var g := int(s.get("grid", 0))
		if g <= 0 or Reports._retired(s.get("status", "")):
			continue
		var gain := g - int(r["pos"])
		if gain >= MIN_CLIMB and gain > int(best.get("gain", 0)):
			best = {"gain": gain, "name": r["driver"], "from": g, "to": int(r["pos"])}
	if not best.is_empty() and best["name"] != clean.get("name", ""):   # the clean charger already says it
		out.append({"tag": "HARD CHARGER", "name": best["name"], "text": "P%d → P%d" % [best["from"], best["to"]]})
	var sur := _surprise(rows, st)
	if not sur.is_empty():
		out.append(sur)
	var first := _first(rows, file, cls)
	if not first.is_empty():
		out.append(first)
	# the fight for the lead: lead changes, or a lights-to-flag win
	if int(lead.get("changes", 0)) >= 2:
		var top := ""
		for d in lead["led"]:
			if top == "" or int(lead["led"][d]) > int(lead["led"][top]):
				top = d
		out.append({"tag": "LEAD BATTLE", "name": top, "text": "%d lead changes, led %d of %d laps" % [int(lead["changes"]), int(lead["led"][top]), int(lead["laps"])]})
	elif int(lead.get("laps", 0)) > 0 and not rows.is_empty() and int(lead["led"].get(rows[0]["driver"], 0)) == int(lead["laps"]):
		out.append({"tag": "LIGHTS TO FLAG", "name": rows[0]["driver"], "text": "led every lap"})
	var strat := _strategy(rows, st)
	if not strat.is_empty():
		out.append(strat)
	# fastest lap
	var fl := {}
	for d in st:
		var b := float(st[d].get("best", 0.0))
		if b > 0.0 and (fl.is_empty() or b < float(fl["t"])):
			fl = {"t": b, "name": d}
	if not fl.is_empty():
		out.append({"tag": "FASTEST LAP", "name": fl["name"], "text": "%d:%06.3f" % [int(float(fl["t"]) / 60.0), fmod(float(fl["t"]), 60.0)]})
	# biggest rating gain
	var mv := {}
	for r in rows:
		var g := float(r["after"]) - float(r["before"])
		if g > float(mv.get("g", 0.0)):
			mv = {"g": g, "name": r["driver"]}
	if not mv.is_empty() and float(mv["g"]) >= 1.0:
		out.append({"tag": "RATING MOVER", "name": mv["name"], "text": "%+d Elo" % roundi(float(mv["g"]))})
	return out


# The class leader at the end of every lap (the car that completed it first), from the archived
# result file: {class: {"changes": n, "laps": n, "led": {driver: laps}}}. {} without the file.
static func _lead_info(file: String) -> Dictionary:
	var path := Elo.stored_xml_path(file)
	if path == "":
		return {}
	var parsed := Elo.parse_results(path)
	var best := {}   # class -> {lap: [elapsed, driver]}
	for d in parsed.get("Race", []):
		if not d.has("Name") or not d.has("CarClass"):
			continue
		var cls: String = d["CarClass"]
		if not best.has(cls):
			best[cls] = {}
		for lap in d["_laps"]:
			if float(lap[1]) > 0.0 and (not best[cls].has(lap[0]) or float(lap[1]) < float(best[cls][lap[0]][0])):
				best[cls][lap[0]] = [float(lap[1]), Elo.resolve(str(d["Name"]))]
	var out := {}
	for cls in best:
		var laps: Array = best[cls].keys()
		laps.sort()
		var led := {}
		var changes := 0
		var prev := ""
		for n in laps:
			var who: String = best[cls][n][1]
			led[who] = int(led.get(who, 0)) + 1
			if prev != "" and who != prev:
				changes += 1
			prev = who
		out[cls] = {"changes": changes, "laps": laps.size(), "led": led}
	return out


# Firsts in the class, best-placed first: first win, first podium, or a personal best finish
# (after 3+ races in the class, top 10 only). {} when nobody did something new.
static func _first(rows: Array, file: String, cls: String) -> Dictionary:
	var past := {}   # driver -> {"best": place, "races": n}
	for h in Elo.history:
		if str(h["file"]) == file:
			break
		for c in h["changes"]:
			if c["sess"] == "race" and c["cls"] == cls:
				var e: Dictionary = past.get(c["driver"], {"best": 999, "races": 0})
				e["best"] = mini(int(e["best"]), int(c["pos"]))
				e["races"] = int(e["races"]) + 1
				past[c["driver"]] = e
	for r in rows:
		var pos := int(r["pos"])
		var e: Dictionary = past.get(r["driver"], {"best": 999, "races": 0})
		if pos == 1 and int(e["best"]) > 1:
			return {"tag": "FIRST WIN", "name": r["driver"], "text": "in %d race%s" % [int(e["races"]) + 1, "" if int(e["races"]) == 0 else "s"]}
		if pos <= 3 and int(e["best"]) > 3:
			return {"tag": "FIRST PODIUM", "name": r["driver"], "text": "P%d" % pos}
		if pos <= 10 and int(e["races"]) >= 3 and pos < int(e["best"]):
			return {"tag": "PERSONAL BEST", "name": r["driver"], "text": "P%d (was P%d)" % [pos, int(e["best"])]}
	return {}


# Strategy: a top-5 finisher who made fewer stops than most of the top 5. {} when they all match.
static func _strategy(rows: Array, st: Dictionary) -> Dictionary:
	var stops := {}   # stops -> count among the top 5
	var top := []
	for i in mini(5, rows.size()):
		var s: Dictionary = st.get(rows[i]["driver"], {})
		if s.is_empty():
			return {}
		var n := int(s.get("pits", 0))
		stops[n] = int(stops.get(n, 0)) + 1
		top.append([rows[i]["driver"], n, i + 1])
	if stops.size() < 2:
		return {}
	var usual := -1
	for n in stops:
		if usual < 0 or int(stops[n]) > int(stops[usual]):
			usual = n
	for x in top:
		if int(x[1]) < usual:
			return {"tag": "STRATEGY", "name": x[0], "text": "P%d on %d stop%s, most of the top 5 made %d" % [int(x[2]), int(x[1]), "" if int(x[1]) == 1 else "s", usual]}
	return {}


# Biggest surprise: the finisher who beat the result their pre-race rating pointed to by the most.
# From the ratings, each driver's chance of finishing ahead of each other one (Elo) gives an expected
# place and how much it normally varies; the surprise is (expected - actual) / that spread, so P8
# from an expected P19 in a 30-car field and P2 from an expected P5 in an 11-car field compare.
# {} when nobody did clearly better than expected.
static func _surprise(rows: Array, st: Dictionary) -> Dictionary:
	var best := {}
	for r in rows:
		var s: Dictionary = st.get(r["driver"], {})
		if Reports._retired(s.get("status", "")):
			continue
		var expect := 1.0
		var vari := 0.0
		for o in rows:
			if o == r:
				continue
			var p := 1.0 / (1.0 + pow(10.0, (float(r["before"]) - float(o["before"])) / 400.0))   # o ahead of r
			expect += p
			vari += p * (1.0 - p)
		var z := (expect - float(r["pos"])) / sqrt(maxf(vari, 0.25))
		if z > float(best.get("z", SURPRISE_MIN_Z)):
			best = {"z": z, "name": r["driver"], "pos": int(r["pos"]), "exp": roundi(expect)}
	if best.is_empty() or int(best["exp"]) <= int(best["pos"]):
		return {}
	return {"tag": "BIGGEST SURPRISE", "name": best["name"], "text": "P%d, expected P%d" % [best["pos"], best["exp"]]}


# The championship after this round: leader, gap, and a change of leader. {} without one.
static func _champ_line(ch: Dictionary, file: String) -> Dictionary:
	if ch.is_empty():
		return {}
	# this event's round in the championship: rounds are counted in history order
	var idx := -1
	var n := 0
	var seen := {}
	for h in Elo.history:
		var hit := false
		for c in h["changes"]:
			if c["sess"] == "race" and c["cls"] == ch["cls"] and Elo.series_of(h) == ch["series"]:
				hit = true
				break
		if hit and not seen.has(h["file"]) and Elo.season_of(h) == _season_of_file(file):
			seen[h["file"]] = true
			if str(h["file"]) == file:
				idx = n
			n += 1
	if idx < 0:
		return {}
	var after := _table(ch, idx + 1)
	var before := _table(ch, idx) if idx > 0 else []
	if after.size() < 2:
		return {}
	var out := {"leader": after[0][0], "points": after[0][1], "second": after[1][0], "gap": after[0][1] - after[1][1]}
	if not before.is_empty() and before[0][0] != after[0][0]:
		out["new_leader"] = true
		out["previous"] = before[0][0]
	elif not before.is_empty() and before.size() > 1:
		out["gap_before"] = before[0][1] - before[1][1]
	return out


static func _season_of_file(file: String) -> String:
	for h in Elo.history:
		if str(h["file"]) == file:
			return Elo.season_of(h)
	return ""


# Standings after the first `rounds` rounds: [[driver, points], ...] best first (drops as set).
static func _table(ch: Dictionary, rounds: int) -> Array:
	var rows := []
	for d in ch["drivers"]:
		var br: Array = ch["drivers"][d]["by_round"]
		var pts := []
		for i in mini(rounds, br.size()):
			pts.append(int(br[i]["pts"]))
		rows.append([d, SeasonScenarios.final_score(pts, rounds)])
	rows.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	return rows


# How the latest saved forecast for this race and class did. {} without one.
static func _forecast_line(file: String, cls: String) -> Dictionary:
	var best := {}
	for fc in Predict.list_forecasts():
		if str(fc.get("class", "")) != cls:
			continue
		var s := Predict.score_forecast(fc)
		if s.is_empty() or str(s.get("event", "")) != file:
			continue
		if best.is_empty() or int(fc["made_at"]) > int(best["made_at"]):
			best = {"made_at": int(fc["made_at"]), "fav": s["fav"], "fav_won": bool(s["fav_won"]),
				"winner": s["winner"], "chance": float(s["winner_chance"])}
	return best
