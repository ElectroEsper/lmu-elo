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


# True when a result's FinishStatus means the driver retired or was disqualified. Older LMU
# files leave many finishers as "None", so only an explicit DNF / DQ counts as not finishing.
func _retired(status: Variant) -> bool:
	var t := str(status).strip_edges().to_lower()
	return t.begins_with("dnf") or t == "dq" or t.begins_with("disq")


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
		var finished: bool = not _retired(s["status"])
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
			if not s.is_empty() and _retired(s["status"]):
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


# ---------- 11. Driver profile ----------
# Every rated session of one driver, in date order, with that session's stored stats.
func _driver_rows(driver_name: String) -> Array:
	var out := []
	for i in Elo.history.size():
		var ev: Dictionary = Elo.history[i]
		for c in ev["changes"]:
			if c["driver"] == driver_name:
				out.append({
					"idx": i, "event": ev["file"], "cls": c["cls"], "sess": c["sess"],
					"pos": int(c["pos"]), "of": int(c["of"]),
					"before": c["before"], "after": c["after"],
					"stats": _stats_for(ev, c["sess"], c["cls"]).get(driver_name, {}),
				})
	return out


func _int_or_blank(s: Dictionary, key: String) -> Variant:
	if s.is_empty():
		return ""
	return int(s.get(key, 0))


# Returns tables: Overview, Ratings, Race record, Quali record, Results, Rating history.
# Tables without rows are left out.
func driver_profile(driver_name: String) -> Array:
	var rows := _driver_rows(driver_name)
	if rows.is_empty():
		return [_table("Profile", ["Stat", "Value"], [], "No results found for this driver.")]
	var tables := [
		_profile_overview(driver_name, rows),
		_profile_ratings(driver_name, rows),
		_profile_race(rows),
		_profile_quali(rows),
	]
	tables.append_array(_profile_track_fit(driver_name, rows))
	tables.append(_profile_results(rows))
	tables.append(_profile_chart(rows))
	var out := []
	for t in tables:
		if not t["rows"].is_empty():
			out.append(t)
	return out


# ---------- Track fit: pace vs the character of the track (driver_track_fit.gd) ----------

func _profile_track_fit(driver_name: String, rows: Array) -> Array:
	var classes := {}
	for r in rows:
		classes[r["cls"]] = true
	var cls_list := classes.keys()
	cls_list.sort()
	var out := []
	for cls in cls_list:
		var f := DriverTrackFit.fit(driver_name, cls)
		if f["tracks"].is_empty():
			continue
		var suffix := " (%s)" % cls if cls_list.size() > 1 else ""
		var trows := []
		for t in f["tracks"]:
			trows.append([t["course"], t["races"], _vs_own(t["race_y"]), t["quali"], _vs_own(t["quali_y"]),
				t["standout"] if t["standout"] != "" else "-"])
		out.append(_table("Tracks" + suffix,
			["Track", "Races", "Race pace", "Qualis", "Quali pace", "Track's stand-out grades"], trows,
			"Pace at each track compared with this driver's OWN average (league races only, best first). A fast driver is not quicker everywhere by this measure: it shows where they are stronger or weaker than usual. Stand-out grades are the track's 4s, 5s and 1s for %s (see Profiles > Layout > Grades)." % cls))
		var drows := []
		for t in f["tendencies"]:
			drows.append([t["name"], _tendency(t), _session_fx(t["race"]), _session_fx(t["quali"])])
		out.append(_table("Track tendencies" + suffix, ["Characteristic", "Tendency", "Race", "Quali"], drows,
			"Is the driver quicker or slower than their own average at tracks that score high on each characteristic? Effect = pace change at a track one step above the class average (about a grade 4), negative = quicker. Tendency combines race and quali. 'Early sign' = preliminary (about one season of data), 'quicker' / 'slower' = more confident (about two seasons). Estimates are pulled towards zero; race-to-race noise is measured over the whole class (%.2f%% race, %.2f%% quali). 'Goes with X' = this characteristic moves together with X over the tracks this driver raced, so it is not a separate finding. Needs %d sessions at %d different tracks." % [
				float(f["noise"]["race"]), float(f["noise"]["quali"]), DriverTrackFit.MIN_RACES, DriverTrackFit.MIN_TRACKS]))
	return out


func _vs_own(y) -> String:
	if y == null:
		return "-"
	var v := float(y)
	if absf(v) < 0.005:
		return "average"
	return "%.2f%% %s" % [absf(v), "quicker" if v < 0.0 else "slower"]


# Combined verdict and effect
func _tendency(t: Dictionary) -> String:
	if not t.has("effect"):
		return str(t["verdict"])
	return "%s: %+.2f%% (±%.2f), %d sessions at %d tracks" % [t["verdict"], float(t["effect"]), float(t["se"]),
		int(t["n"]), int(t["tracks"])]


# One session's effect, or why there is none
func _session_fx(e: Dictionary) -> String:
	if e.is_empty():
		return "-"
	if not e.has("effect"):
		return "not enough data (%d)" % int(e.get("n", 0))
	return "%+.2f%% (±%.2f)" % [float(e["effect"]), float(e["se"])]


func _profile_overview(driver_name: String, rows: Array) -> Dictionary:
	var events := {}
	var classes := {}
	var laps := 0
	var led := 0
	for r in rows:
		events[r["idx"]] = true
		classes[r["cls"]] = true
		if r["sess"] == "race" and not r["stats"].is_empty():
			laps += int(r["stats"]["laps"])
			led += int(r["stats"]["led"])
	var cls_list := classes.keys()
	cls_list.sort()
	var akas := []
	for alias in Elo.aliases:
		if Elo.aliases[alias] == driver_name:
			akas.append(alias)
	var duels := 0
	for k in Elo.ratings:
		if k.rsplit("|", true, 2)[0] == driver_name:
			duels += int(Elo.ratings[k]["d"])
	var out := [
		["Events", events.size()],
		["Sessions rated", rows.size()],
		["Classes", ", ".join(PackedStringArray(cls_list))],
		["First event", rows[0]["event"]],
		["Latest event", rows[rows.size() - 1]["event"]],
		["Race laps completed", laps],
		["Race laps led", led],
		["Duels fought (all ratings)", duels],
		["Also known as", ", ".join(PackedStringArray(akas)) if not akas.is_empty() else "-"],
	]
	return _table("Overview", ["Stat", "Value"], out,
		"Laps figures only count events that have stored stats.")


func _profile_ratings(driver_name: String, rows: Array) -> Dictionary:
	var out := []
	for board in Elo.boards():
		var key := "%s|%s|%s" % [driver_name, board[0], board[1]]
		if not Elo.ratings.has(key):
			continue
		var e: Dictionary = Elo.ratings[key]
		var lb := Elo.leaderboard(board[0], board[1])
		var rank := 0
		for i in lb.size():
			if lb[i]["name"] == driver_name:
				rank = i + 1
		var peak := -1.0e9
		var debut: float = Elo.START
		var seen := false
		for r in rows:
			if r["cls"] == board[0] and r["sess"] == board[1]:
				peak = maxf(peak, r["after"])
				if not seen:
					debut = r["before"]
					seen = true
		if peak < 0.0:
			peak = e["r"]
		out.append([board[0], board[1], roundi(e["r"]), rank, lb.size(), roundi(peak),
			roundi(e["r"] - debut), int(e["d"]),
			"settling" if e["d"] < Elo.K_RAMP_DUELS else "settled"])
	return _table("Ratings",
		["Class", "Session", "Rating", "Rank", "Of", "Peak", "Since debut", "Duels", "Status"],
		out, "Rank is within the class and session.")


func _profile_race(rows: Array) -> Dictionary:
	var by_class := {}
	for r in rows:
		if r["sess"] == "race":
			if not by_class.has(r["cls"]):
				by_class[r["cls"]] = []
			by_class[r["cls"]].append(r)
	var out := []
	var classes := by_class.keys()
	classes.sort()
	for cls in classes:
		var rs: Array = by_class[cls]
		var n := rs.size()
		var total := 0.0
		var wins := 0
		var podiums := 0
		var points := 0
		var best := 1000
		var worst := 0
		for r in rs:
			var p: int = r["pos"]
			total += p
			if p == 1:
				wins += 1
			if p <= 3:
				podiums += 1
			if p <= POINTS.size():
				points += POINTS[p - 1]
			best = mini(best, p)
			worst = maxi(worst, p)
		var mean := total / n
		var sq := 0.0
		for r in rs:
			sq += (r["pos"] - mean) * (r["pos"] - mean)

		# figures that need the stored stats
		var dnfs := 0
		var laps := 0
		var led := 0
		var pits := 0
		var inc := 0
		var env := 0
		var pens := 0
		var grid_total := 0.0
		var gain_total := 0.0
		var grid_n := 0
		var best_lap := 0.0
		for r in rs:
			var s: Dictionary = r["stats"]
			if s.is_empty():
				continue
			if _retired(s["status"]):
				dnfs += 1
			laps += int(s["laps"])
			led += int(s["led"])
			pits += int(s["pits"])
			inc += int(s["inc"])
			env += int(s["env"])
			pens += int(s["pens"])
			if int(s["grid"]) > 0:
				grid_total += int(s["grid"])
				gain_total += int(s["grid"]) - r["pos"]
				grid_n += 1
			if s["best"] > 0.0 and (best_lap == 0.0 or s["best"] < best_lap):
				best_lap = s["best"]
		var avg_grid: Variant = ""
		var avg_gain: Variant = ""
		if grid_n > 0:
			avg_grid = snappedf(grid_total / grid_n, 0.1)
			avg_gain = snappedf(gain_total / grid_n, 0.1)
		out.append([cls, n, wins, podiums, snappedf(mean, 0.1), snappedf(sqrt(sq / n), 0.1),
			best, worst, points, dnfs, laps, led, pits, inc, env, pens,
			avg_grid, avg_gain, _lap(best_lap)])
	return _table("Race record",
		["Class", "Races", "Wins", "Podiums", "Avg finish", "Std dev", "Best", "Worst", "Points",
			"DNFs", "Laps", "Led", "Pits", "Contacts", "Env", "Pens", "Avg grid", "Avg gained", "Best lap"],
		out, "Laps, laps led, pits, contacts, penalties, grid and best lap only count events with stored stats.")


func _profile_quali(rows: Array) -> Dictionary:
	var by_class := {}
	for r in rows:
		if r["sess"] == "quali":
			if not by_class.has(r["cls"]):
				by_class[r["cls"]] = []
			by_class[r["cls"]].append(r)
	var out := []
	var classes := by_class.keys()
	classes.sort()
	for cls in classes:
		var rs: Array = by_class[cls]
		var total := 0.0
		var poles := 0
		var top3 := 0
		var best := 1000
		var best_lap := 0.0
		for r in rs:
			var p: int = r["pos"]
			total += p
			if p == 1:
				poles += 1
			if p <= 3:
				top3 += 1
			best = mini(best, p)
			var s: Dictionary = r["stats"]
			if not s.is_empty() and s["best"] > 0.0 and (best_lap == 0.0 or s["best"] < best_lap):
				best_lap = s["best"]
		out.append([cls, rs.size(), poles, top3, snappedf(total / rs.size(), 0.1), best, _lap(best_lap)])
	return _table("Quali record",
		["Class", "Sessions", "Poles", "Top 3", "Avg pos", "Best pos", "Best lap"], out)


func _profile_results(rows: Array) -> Dictionary:
	var out := []
	for r in rows:
		var s: Dictionary = r["stats"]
		var is_race: bool = r["sess"] == "race"
		var status := ""
		if not s.is_empty() and _retired(s["status"]):
			status = s["status"]
		out.append([
			r["event"], r["cls"], r["sess"], r["pos"], r["of"],
			_int_or_blank(s, "grid") if is_race else "",
			_lap(s.get("best", 0.0)) if not s.is_empty() else "",
			_int_or_blank(s, "laps"),
			_int_or_blank(s, "pits") if is_race else "",
			_int_or_blank(s, "led") if is_race else "",
			roundi(r["after"]), roundi(r["after"] - r["before"]), status])
	return _table("Results",
		["Event", "Class", "Session", "Pos", "Of", "Grid", "Best lap", "Laps", "Pits", "Led",
			"Rating", "Change", "Status"],
		out, "One row per rated session, oldest first. Blank cells mean no stats were stored.")


func _profile_chart(rows: Array) -> Dictionary:
	var by_board := {}   # "GT3 race" -> [[event index, rating after], ...]
	for r in rows:
		var label := "%s %s" % [r["cls"], r["sess"]]
		if not by_board.has(label):
			by_board[label] = []
		by_board[label].append([r["idx"], r["after"]])
	var labels := by_board.keys()
	labels.sort()
	var series := []
	var out := []
	for k in labels.size():
		var pts: Array = by_board[labels[k]]
		series.append({
			"name": labels[k],
			"color": chart_colors[k % chart_colors.size()],
			"points": pts,
		})
		var peak := -1.0e9
		for pt in pts:
			peak = maxf(peak, pt[1])
		out.append([labels[k], pts.size(), roundi(pts[0][1]), roundi(pts.back()[1]), roundi(peak)])
	var t := _table("Rating history", ["Rating", "Events", "After first", "Latest", "Peak"], out,
		"Horizontal axis = event number across all events.")
	t["chart"] = {"series": series, "x_max": float(maxi(Elo.history.size() - 1, 1))}
	return t
