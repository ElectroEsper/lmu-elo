extends Node
## Report builders. Register as an autoload named "Reports"
## (Project Settings > Globals > Autoload), after "Elo".
##
## Every report returns an Array of tables:
##   {"title": String, "note": String, "headers": Array, "rows": Array of Array,
##    "chart": {"series": [...], "x_max": float}}      # "chart" is optional
## Row cells are ints, floats or strings.

# League points for race finishing positions (P1, P2, ...). Edit to suit your series.
const POINTS := [25, 18, 15, 12, 10, 8, 6, 4, 2, 1]
const CHART_TOP_N := 6   # drivers drawn on each rating-history chart

var chart_colors := [
	Color(0.31, 0.76, 0.97), Color(1.0, 0.72, 0.30), Color(0.51, 0.78, 0.52),
	Color(0.90, 0.45, 0.45), Color(0.73, 0.41, 0.78), Color(1.0, 0.95, 0.46),
]


# ---------- Helpers ----------
func _table(title: String, headers: Array, rows: Array, note := "") -> Dictionary:
	return {"title": title, "note": note, "headers": headers, "rows": rows}


func _lap(t: float) -> String:
	if t <= 0.0:
		return "-"
	var m := int(t / 60.0)
	return "%d:%06.3f" % [m, t - m * 60.0]


# Class/session pairs rated in one event
func _event_boards(event_index: int) -> Array:
	var seen := {}
	for c in Elo.history[event_index]["changes"]:
		seen[c["cls"] + "|" + c["sess"]] = [c["cls"], c["sess"]]
	var out: Array = seen.values()
	out.sort_custom(func(a, b): return (a[0] + a[1]) < (b[0] + b[1]))
	return out


# Rating changes of one event for one class/session, in finishing order
func _event_rows(event_index: int, cls: String, sess: String) -> Array:
	var rows := []
	for c in Elo.history[event_index]["changes"]:
		if c["cls"] == cls and c["sess"] == sess:
			rows.append(c)
	rows.sort_custom(func(a, b): return a["pos"] < b["pos"])
	return rows


# Stored stats of one event for one class/session: {driver: {...}} (empty if none)
func _stats_for(ev: Dictionary, sess: String, cls: String) -> Dictionary:
	var all: Dictionary = ev.get("stats", {})
	var by_class: Dictionary = all.get(sess, {})
	return by_class.get(cls, {})


func _rating_of(driver_name: String, cls: String, sess: String) -> int:
	var e: Dictionary = Elo.ratings.get("%s|%s|%s" % [driver_name, cls, sess], {})
	return roundi(e.get("r", Elo.START))


# ---------- 1. Biggest movers (per event) ----------
func movers(event_index: int) -> Array:
	var tables := []
	for board in _event_boards(event_index):
		var rows := []
		var gain_name := ""
		var gain := -1.0e9
		var drop_name := ""
		var drop := 1.0e9
		for c in _event_rows(event_index, board[0], board[1]):
			var delta: float = c["after"] - c["before"]
			rows.append([int(c["pos"]), c["driver"], roundi(c["before"]), roundi(c["after"]), roundi(delta)])
			if delta > gain:
				gain = delta
				gain_name = c["driver"]
			if delta < drop:
				drop = delta
				drop_name = c["driver"]
		rows.sort_custom(func(r1, r2): return r1[4] > r2[4])
		var note := ""
		if not rows.is_empty():
			note = "Biggest gain: %s %+d.  Biggest drop: %s %+d." % [
				gain_name, roundi(gain), drop_name, roundi(drop)]
		tables.append(_table("%s %s" % [board[0], board[1]],
			["Pos", "Driver", "Before", "After", "Change"], rows, note))
	return tables


# ---------- 2. Upsets (per event) ----------
# A duel is an upset when the driver who finished ahead had under 50% pre-event win chance.
func upsets(event_index: int) -> Array:
	var found := []
	for board in _event_boards(event_index):
		var rs := _event_rows(event_index, board[0], board[1])
		for i in rs.size():
			for j in range(i + 1, rs.size()):
				var ahead: Dictionary = rs[i]
				var behind: Dictionary = rs[j]
				var chance := 1.0 / (1.0 + pow(10.0, (behind["before"] - ahead["before"]) / 400.0))
				if chance < 0.5:
					found.append([
						ahead["driver"], behind["driver"], "%s %s" % [board[0], board[1]],
						roundi(ahead["before"]), roundi(behind["before"]),
						snappedf(chance * 100.0, 0.1)])
	found.sort_custom(func(r1, r2): return r1[5] < r2[5])
	var top := found.slice(0, mini(10, found.size()))
	var note := "Top 10 duels by how unlikely the result was, using ratings before the event."
	if found.is_empty():
		note = "No upsets in this event: everyone finished roughly as rated."
	return [_table("Upsets",
		["Finished ahead", "Beat", "Session", "Winner rating", "Loser rating", "Win chance %"],
		top, note)]


# ---------- 3. Event detail (per event) ----------
# Race: grid, places gained, gap, pace vs class best, pit stops, laps led, contacts, penalties.
# Quali: best lap and pace gap to pole.
func event_detail(event_index: int) -> Array:
	var ev: Dictionary = Elo.history[event_index]
	var tables := []
	for board in _event_boards(event_index):
		var rs := _event_rows(event_index, board[0], board[1])
		var st := _stats_for(ev, board[1], board[0])
		var title := "%s %s" % [board[0], board[1]]
		if board[1] == "race":
			tables.append(_race_detail(title, rs, st))
		else:
			tables.append(_quali_detail(title, rs, st))
	return tables


func _gap(s: Dictionary, win: Dictionary) -> String:
	if win.is_empty():
		return ""
	var behind := int(win["laps"]) - int(s["laps"])
	if behind > 0:
		return "+%d lap%s" % [behind, "" if behind == 1 else "s"]
	if s["time"] <= 0.0 or win["time"] <= 0.0:
		return ""
	return "%+.3f" % (s["time"] - win["time"])


func _race_detail(title: String, rs: Array, st: Dictionary) -> Dictionary:
	var headers := ["Pos", "Driver", "Grid", "+/-", "Laps", "Gap", "Best lap", "Pace %",
		"Pits", "Led", "Contacts", "Env", "Pens", "Status"]
	var rows := []
	var win: Dictionary = {}
	if not rs.is_empty():
		win = st.get(rs[0]["driver"], {})
	var class_best := 0.0
	for driver_name in st:
		var b: float = st[driver_name]["best"]
		if b > 0.0 and (class_best == 0.0 or b < class_best):
			class_best = b
	for c in rs:
		var pos := int(c["pos"])
		var s: Dictionary = st.get(c["driver"], {})
		if s.is_empty():
			rows.append([pos, c["driver"], "", "", "", "", "", "", "", "", "", "", "", ""])
			continue
		var finished: bool = s["status"] == "Finished Normally"
		var pace: Variant = ""
		if s["best"] > 0.0 and class_best > 0.0:
			pace = snappedf((s["best"] / class_best - 1.0) * 100.0, 0.01)
		rows.append([
			pos, c["driver"], int(s["grid"]), int(s["grid"]) - pos, int(s["laps"]),
			"" if pos == 1 else _gap(s, win), _lap(s["best"]), pace,
			int(s["pits"]), int(s["led"]), int(s["inc"]), int(s["env"]), int(s["pens"]),
			"" if finished else s["status"]])
	var note := "+/- = places gained from the grid. Laps led and Pace % are within the class. " \
		+ "Contacts = car-to-car incidents, Env = hits with objects, Pens = in-race penalties."
	if st.is_empty():
		note = "No stats stored for this event. Drop its XML file on the Review screen to attach them."
	return _table(title, headers, rows, note)


func _quali_detail(title: String, rs: Array, st: Dictionary) -> Dictionary:
	var headers := ["Pos", "Driver", "Best lap", "Gap (s)", "Pace %"]
	var rows := []
	var pole := 0.0
	if not rs.is_empty():
		var ps: Dictionary = st.get(rs[0]["driver"], {})
		pole = ps.get("best", 0.0)
	for c in rs:
		var pos := int(c["pos"])
		var s: Dictionary = st.get(c["driver"], {})
		var gap: Variant = ""
		var pace: Variant = ""
		if not s.is_empty() and s["best"] > 0.0 and pole > 0.0:
			gap = snappedf(s["best"] - pole, 0.001)
			pace = snappedf((s["best"] / pole - 1.0) * 100.0, 0.01)
		rows.append([pos, c["driver"], _lap(s.get("best", 0.0)), gap, pace])
	var note := "Pace % is the gap to pole in percent."
	if st.is_empty():
		note = "No stats stored for this event. Drop its XML file on the Review screen to attach them."
	return _table(title, headers, rows, note)


# ---------- 4. Rating history (chart per class/session) ----------
func rating_history() -> Array:
	var tables := []
	var n_events := Elo.history.size()
	for board in Elo.boards():
		var pts := {}           # driver -> [[event index, rating after], ...]
		var first_before := {}  # driver -> rating before their first event
		for i in n_events:
			for c in Elo.history[i]["changes"]:
				if c["cls"] == board[0] and c["sess"] == board[1]:
					var d: String = c["driver"]
					if not pts.has(d):
						pts[d] = []
						first_before[d] = c["before"]
					pts[d].append([i, c["after"]])
		var names := pts.keys()
		names.sort_custom(func(n1, n2): return pts[n1].back()[1] > pts[n2].back()[1])

		var series := []
		for k in mini(CHART_TOP_N, names.size()):
			series.append({
				"name": names[k],
				"color": chart_colors[k % chart_colors.size()],
				"points": pts[names[k]],
			})
		var rows := []
		for d in names:
			var latest: float = pts[d].back()[1]
			var peak := -1.0e9
			for pt in pts[d]:
				peak = maxf(peak, pt[1])
			rows.append([d, roundi(first_before[d]), roundi(latest),
				roundi(latest - first_before[d]), roundi(peak), pts[d].size()])
		var t := _table("%s %s" % [board[0], board[1]],
			["Driver", "Start", "Now", "Change", "Peak", "Events"], rows,
			"Chart: top %d drivers by current rating. Horizontal axis = event number." % CHART_TOP_N)
		t["chart"] = {"series": series, "x_max": float(maxi(n_events - 1, 1))}
		tables.append(t)
	return tables


# ---------- 5. Race vs quali ----------
func race_vs_quali() -> Array:
	var by_class := {}   # class -> driver -> {"race": r, "quali": r}
	for k in Elo.ratings:
		var parts: PackedStringArray = k.rsplit("|", true, 2)
		if not by_class.has(parts[1]):
			by_class[parts[1]] = {}
		if not by_class[parts[1]].has(parts[0]):
			by_class[parts[1]][parts[0]] = {}
		by_class[parts[1]][parts[0]][parts[2]] = Elo.ratings[k]["r"]
	var tables := []
	var classes := by_class.keys()
	classes.sort()
	for cls in classes:
		var rows := []
		for driver_name in by_class[cls]:
			var e: Dictionary = by_class[cls][driver_name]
			if e.has("race") and e.has("quali"):
				rows.append([driver_name, roundi(e["race"]), roundi(e["quali"]),
					roundi(e["race"] - e["quali"])])
		rows.sort_custom(func(r1, r2): return r1[3] > r2[3])
		tables.append(_table(str(cls), ["Driver", "Race", "Quali", "Race - Quali"], rows,
			"Positive: better racer than qualifier. Negative: stronger over one lap."))
	return tables


# ---------- 6. Consistency (race) ----------
func consistency() -> Array:
	var data := {}   # class -> driver -> {"pos": [...], "dnf": int}
	var missing := 0
	for ev in Elo.history:
		var has_stats: bool = not ev.get("stats", {}).is_empty()
		if not has_stats:
			missing += 1
		for c in ev["changes"]:
			if c["sess"] != "race":
				continue
			var cls: String = c["cls"]
			var d: String = c["driver"]
			if not data.has(cls):
				data[cls] = {}
			if not data[cls].has(d):
				data[cls][d] = {"pos": [], "dnf": 0}
			data[cls][d]["pos"].append(int(c["pos"]))
			var s: Dictionary = _stats_for(ev, "race", cls).get(d, {})
			if not s.is_empty() and s["status"] != "Finished Normally":
				data[cls][d]["dnf"] += 1
	var tables := []
	var classes := data.keys()
	classes.sort()
	for cls in classes:
		var rows := []
		for d in data[cls]:
			var ps: Array = data[cls][d]["pos"]
			var n := ps.size()
			var total := 0.0
			for p in ps:
				total += p
			var mean := total / n
			var sq := 0.0
			for p in ps:
				sq += (p - mean) * (p - mean)
			var wins := 0
			var podiums := 0
			for p in ps:
				if p == 1:
					wins += 1
				if p <= 3:
					podiums += 1
			var dnfs: int = data[cls][d]["dnf"]
			rows.append([d, n, wins, podiums, snappedf(mean, 0.1), snappedf(sqrt(sq / n), 0.1),
				ps.min(), ps.max(), dnfs, snappedf(100.0 * dnfs / n, 0.1)])
		rows.sort_custom(func(r1, r2): return r1[4] < r2[4])
		var note := "Std dev = how much finishing positions vary (lower = more consistent)."
		if missing > 0:
			note += " %d event(s) have no stats, so DNFs there are not counted." % missing
		tables.append(_table(str(cls),
			["Driver", "Races", "Wins", "Podiums", "Avg finish", "Std dev", "Best", "Worst", "DNFs", "DNF %"],
			rows, note))
	return tables


# ---------- 7. Grid vs finish (race) ----------
func grid_vs_finish() -> Array:
	var data := {}   # class -> driver -> {"grid": [...], "pos": [...]}
	var skipped := 0
	for ev in Elo.history:
		for c in ev["changes"]:
			if c["sess"] != "race":
				continue
			var cls: String = c["cls"]
			var d: String = c["driver"]
			var s: Dictionary = _stats_for(ev, "race", cls).get(d, {})
			if s.is_empty() or int(s["grid"]) <= 0:
				skipped += 1
				continue
			if not data.has(cls):
				data[cls] = {}
			if not data[cls].has(d):
				data[cls][d] = {"grid": [], "pos": []}
			data[cls][d]["grid"].append(int(s["grid"]))
			data[cls][d]["pos"].append(int(c["pos"]))
	var tables := []
	var classes := data.keys()
	classes.sort()
	for cls in classes:
		var rows := []
		for d in data[cls]:
			var gs: Array = data[cls][d]["grid"]
			var ps: Array = data[cls][d]["pos"]
			var n := gs.size()
			var gain_total := 0.0
			var grid_total := 0.0
			var pos_total := 0.0
			var best_gain := -1000
			var worst_gain := 1000
			for i in n:
				var g: int = gs[i] - ps[i]
				gain_total += g
				grid_total += gs[i]
				pos_total += ps[i]
				best_gain = maxi(best_gain, g)
				worst_gain = mini(worst_gain, g)
			rows.append([d, n, snappedf(grid_total / n, 0.1), snappedf(pos_total / n, 0.1),
				snappedf(gain_total / n, 0.1), best_gain, worst_gain])
		rows.sort_custom(func(r1, r2): return r1[4] > r2[4])
		var note := "Places gained = grid position minus finishing position (positive = moved forward)."
		if skipped > 0:
			note += " %d result(s) skipped because the event has no stats." % skipped
		tables.append(_table(str(cls),
			["Driver", "Races", "Avg grid", "Avg finish", "Avg gained", "Best", "Worst"],
			rows, note))
	return tables


# ---------- 8. Rookies ----------
func rookies() -> Array:
	var tables := []
	for board in Elo.boards():
		var first := {}   # driver -> {"event": file, "before": rating}
		for ev in Elo.history:
			for c in ev["changes"]:
				if c["cls"] == board[0] and c["sess"] == board[1] and not first.has(c["driver"]):
					first[c["driver"]] = {"event": ev["file"], "before": c["before"]}
		var rows := []
		for r in Elo.leaderboard(board[0], board[1]):
			if r["d"] < Elo.K_RAMP_DUELS:
				var f: Dictionary = first.get(r["name"], {})
				rows.append([r["name"], roundi(r["r"]), int(r["d"]),
					roundi(r["r"] - float(f.get("before", Elo.START))), f.get("event", "")])
		rows.sort_custom(func(r1, r2): return r1[3] > r2[3])
		var note := "Drivers still on the higher K-factor (fewer than %d duels). Their ratings are provisional." % int(Elo.K_RAMP_DUELS)
		if rows.is_empty():
			note = "Nobody is still settling in this class."
		tables.append(_table("%s %s" % [board[0], board[1]],
			["Driver", "Rating", "Duels", "Change since debut", "First event"], rows, note))
	return tables


# ---------- 9. Championship standings (race points) ----------
func standings() -> Array:
	var data := {}   # class -> driver -> {"pts", "wins", "pod", "n"}
	for ev in Elo.history:
		for c in ev["changes"]:
			if c["sess"] != "race":
				continue
			var cls: String = c["cls"]
			var d: String = c["driver"]
			if not data.has(cls):
				data[cls] = {}
			if not data[cls].has(d):
				data[cls][d] = {"pts": 0, "wins": 0, "pod": 0, "n": 0}
			var e: Dictionary = data[cls][d]
			var p := int(c["pos"])
			e["n"] += 1
			if p <= POINTS.size():
				e["pts"] += POINTS[p - 1]
			if p == 1:
				e["wins"] += 1
			if p <= 3:
				e["pod"] += 1
	var pts_text := ""
	for i in POINTS.size():
		pts_text += ("" if i == 0 else "-") + str(POINTS[i])
	var tables := []
	var classes := data.keys()
	classes.sort()
	for cls in classes:
		var rows := []
		for d in data[cls]:
			var e: Dictionary = data[cls][d]
			rows.append([0, d, e["pts"], e["wins"], e["pod"], e["n"]])
		rows.sort_custom(func(r1, r2):
			if r1[2] != r2[2]:
				return r1[2] > r2[2]
			return r1[3] > r2[3])
		for i in rows.size():
			rows[i][0] = i + 1
		tables.append(_table(str(cls), ["Rank", "Driver", "Points", "Wins", "Podiums", "Races"], rows,
			"Points for P1 onwards: %s (edit POINTS in reports.gd). Race results only." % pts_text))
	return tables


# ---------- 10. Head to head ----------
func head_to_head(cls: String, sess: String, a: String, b: String) -> Array:
	if a == "" or b == "" or a == b:
		return [_table("Head to head", ["Event", "A", "B", "Ahead"], [], "Pick two different drivers.")]
	var rows := []
	var a_wins := 0
	var b_wins := 0
	for ev in Elo.history:
		var pa := 0
		var pb := 0
		for c in ev["changes"]:
			if c["cls"] == cls and c["sess"] == sess:
				if c["driver"] == a:
					pa = int(c["pos"])
				elif c["driver"] == b:
					pb = int(c["pos"])
		if pa > 0 and pb > 0:
			var ahead := a if pa < pb else b
			if pa < pb:
				a_wins += 1
			else:
				b_wins += 1
			rows.append([ev["file"], pa, pb, ahead])
	var note := "%s %d - %d %s over %d shared %s sessions.  Ratings now: %s %d, %s %d." % [
		a, a_wins, b_wins, b, rows.size(), sess,
		a, _rating_of(a, cls, sess), b, _rating_of(b, cls, sess)]
	if rows.is_empty():
		note = "These two have not been rated in the same %s %s session yet." % [cls, sess]
	return [_table("%s vs %s" % [a, b], ["Event", "%s pos" % a, "%s pos" % b, "Ahead"], rows, note)]
