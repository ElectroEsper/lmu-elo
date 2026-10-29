class_name PredictView
extends VBoxContainer

## "Predict" screen: forecast qualifying and the race from lap-time fingerprints.
## Built in code, like reports_view.gd. Needs the autoloads Elo, Profiles and Predict.

signal notice(text: String)

# [key, label, min, max, step]
const PARAM_ROWS := [
	["sig_form", "Race-day form noise (% of lap time)", 0.0, 2.0, 0.05],
	["sq", "Quali noise (% of lap time)", 0.0, 3.0, 0.05],
	["g_grid", "Seconds lost per grid place", 0.0, 5.0, 0.1],
	["c0", "Contact: seconds lost at once", 0.0, 10.0, 0.1],
	["dmg", "Contact: damage, % per lap (adds up)", 0.0, 2.0, 0.05],
	["tl_cost", "Track limits: seconds per event", 0.0, 1.0, 0.01],
	["tl_pen", "Track limits: chance of a penalty", 0.0, 0.05, 0.0005],
	["pen_s", "Penalty size (seconds)", 0.0, 60.0, 1.0],
	["fit", "Track-fit strength (0 = off)", 0.0, 3.0, 0.1],
	["lap_noise", "Lap-to-lap scatter (x)", 0.0, 3.0, 0.1],
	["p_track", "Upgrade: own history at the track (0 = off, 1 = on)", 0.0, 2.0, 0.1],
	["p_tend", "Upgrade: track tendencies (0 = off, 1 = on)", 0.0, 2.0, 0.1],
	["pits", "Upgrade: pit stops (0 = off, 1 = on)", 0.0, 1.0, 1.0],
]

var class_pick := OptionButton.new()
var mode_pick := OptionButton.new()
var track_pick := OptionButton.new()
var minutes_spin := SpinBox.new()
var lap_spin := SpinBox.new()
var entries := TextEdit.new()
var info := Label.new()
var grid_line := Label.new()
var tree := Tree.new()
var out_label := Label.new()
var assumptions := VBoxContainer.new()
var spins := {}
var _busy := false


func _ready() -> void:
	# two columns: settings and actions on the left, the forecast on the right
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 16)
	add_child(cols)
	var left_scroll := ScrollContainer.new()
	left_scroll.custom_minimum_size = Vector2(380, 0)
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cols.add_child(left_scroll)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 12)
	left_scroll.add_child(left)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)

	# race setup
	var setup := _card(left, "RACE SETUP")
	var form := GridContainer.new()
	form.columns = 2
	form.add_theme_constant_override("h_separation", 12)
	setup.add_child(form)
	mode_pick.add_item("After quali", Predict.Mode.ACTUAL_GRID)
	mode_pick.add_item("Before quali", Predict.Mode.PREDICTED_QUALI)
	mode_pick.add_item("Race only", Predict.Mode.RACE_ONLY)
	mode_pick.select(0)
	mode_pick.tooltip_text = "After quali: the race from the grid in the entry list (pole first).\nBefore quali: predict qualifying first, then the race from that grid.\nRace only: ignore the grid."
	minutes_spin.min_value = 0
	minutes_spin.max_value = 240
	minutes_spin.step = 1
	minutes_spin.tooltip_text = "Race length. 0 = take it from the data."
	lap_spin.min_value = 0
	lap_spin.max_value = 600
	lap_spin.step = 0.1
	lap_spin.tooltip_text = "Typical lap time. 0 = take it from the data."
	for pair in [["Class", class_pick], ["Forecast", mode_pick], ["Track", track_pick],
			["Minutes", minutes_spin], ["Lap time (s)", lap_spin]]:
		var l := _label(pair[0])
		l.theme_type_variation = "Muted"
		form.add_child(l)
		var c: Control = pair[1]
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if c is OptionButton:
			(c as OptionButton).clip_text = true
			c.custom_minimum_size = Vector2(150, 0)
		form.add_child(c)

	# entry list
	var entry := _card(left, "ENTRY LIST")
	entries.custom_minimum_size = Vector2(0, 230)
	entries.placeholder_text = "One driver per line.\nAfter quali: pole position first.\nBefore quali: just the entry list.\nAliases are resolved."
	entry.add_child(entries)
	var fill_row := HBoxContainer.new()
	entry.add_child(fill_row)
	var from_quali := _btn("Grid from latest quali", _load_latest_quali)
	from_quali.tooltip_text = "Fill the list with the latest qualifying result, pole first."
	var recent := _btn("Recent drivers", _fill_recent)
	recent.tooltip_text = "Fill the list with drivers who raced in this class recently."
	for b in [from_quali, recent]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fill_row.add_child(b)
	var go := _btn("Predict", _run)
	go.theme_type_variation = "AccentButton"
	entry.add_child(go)

	# model checks and settings
	var model := _card(left, "MODEL")
	var checks := HFlowContainer.new()
	model.add_child(checks)
	var bt := _btn("Backtest", _backtest)
	bt.tooltip_text = "Replay past races, each forecast only from earlier events, and score the odds."
	checks.add_child(bt)
	var fn := _btn("Fit noise", _fit_noise)
	fn.tooltip_text = "Try a few noise levels and keep the best. Slow."
	checks.add_child(fn)
	var tu := _btn("Test upgrades", _test_upgrades)
	tu.tooltip_text = "Test each upgrade and its strength against past races; the ones that help are switched on. Slow."
	checks.add_child(tu)
	var toggle := CheckButton.new()
	toggle.text = "Show assumptions"
	toggle.toggled.connect(func(on: bool): assumptions.visible = on)
	model.add_child(toggle)
	assumptions.visible = false
	model.add_child(assumptions)
	var grid := GridContainer.new()
	grid.columns = 2
	assumptions.add_child(grid)
	for row in PARAM_ROWS:
		var l := _label(row[1])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(200, 0)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(l)
		var sb := SpinBox.new()
		sb.min_value = row[2]
		sb.max_value = row[3]
		sb.step = row[4]
		sb.value = float(Predict.params[row[0]])
		sb.value_changed.connect(_on_param.bind(row[0]))
		grid.add_child(sb)
		spins[row[0]] = sb
	assumptions.add_child(_btn("Reset assumptions", _reset_params))

	# forecast
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.theme_type_variation = "Muted"
	right.add_child(info)
	grid_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(grid_line)

	tree.columns = 11
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var titles := ["Grid", "Driver", "Pole %", "Front row %", "Exp. grid", "Win %", "Podium %", "Top 10 %", "Exp. finish", "Race pace %", "Stops"]
	for i in titles.size():
		tree.set_column_title(i, titles[i])
		if i >= 2:
			tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT)
		else:
			tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_LEFT)
		if i != 1:
			tree.set_column_custom_minimum_width(i, maxi(64, str(titles[i]).length() * 9 + 26))
		tree.set_column_expand(i, i == 1)
	tree.set_column_custom_minimum_width(1, 170)
	right.add_child(tree)

	# notes and results of backtests: scrolls when long, so the table keeps its room
	var out_scroll := ScrollContainer.new()
	out_scroll.custom_minimum_size = Vector2(0, 110)
	out_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(out_scroll)
	out_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	out_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	out_scroll.add_child(out_label)


# A titled panel; returns the box to put its contents in.
func _card(parent: Control, title: String) -> VBoxContainer:
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	parent.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	card.add_child(box)
	var l := Label.new()
	l.text = title
	l.theme_type_variation = "SectionLabel"
	box.add_child(l)
	return box


# Called by the main screen whenever this view is shown.
func refresh() -> void:
	if get_node_or_null("/root/Predict") == null or get_node_or_null("/root/Profiles") == null:
		info.text = "The Predict / Profiles autoloads are not running. Check Project Settings > Globals > Autoload (names 'Profiles' and 'Predict', below 'Elo') and the Output panel for errors."
		return
	Profiles.ensure()
	var keep := _current_class()
	class_pick.clear()
	var seen := {}
	for c in Profiles.classes():
		seen[c] = true
		class_pick.add_item(LeagueSettings.label(c))
		class_pick.set_item_metadata(class_pick.item_count - 1, c)
	for b in Elo.boards():
		if b[1] == "race" and not seen.has(b[0]):
			seen[b[0]] = true
			class_pick.add_item(LeagueSettings.label(b[0]))
			class_pick.set_item_metadata(class_pick.item_count - 1, b[0])
	for i in class_pick.item_count:
		if str(class_pick.get_item_metadata(i)) == keep:
			class_pick.select(i)
	var keep_track := track_pick.get_item_text(track_pick.selected) if track_pick.item_count > 0 and track_pick.selected >= 0 else ""
	track_pick.clear()
	track_pick.add_item("Latest event", 0)
	for i in Profiles.courses().size():
		track_pick.add_item(Profiles.courses()[i], i + 1)
	for i in track_pick.item_count:
		if track_pick.get_item_text(i) == keep_track:
			track_pick.select(i)
	for key in spins:
		spins[key].set_value_no_signal(float(Predict.params[key]))
	if Profiles.has_data():
		info.text = "%d events with lap data. Odds come from pace, tyre wear, top speed, fuel use, track limits, contacts and consistency; they ignore strategy, weather and who actually shows up." % Profiles.days.size()
	else:
		info.text = "No lap-data fingerprints saved yet, so drivers are rated from Elo only. Drop the folder with your result XMLs on the window to backfill them."


func _current_class() -> String:
	if class_pick.item_count == 0 or class_pick.selected < 0:
		return ""
	return str(class_pick.get_item_metadata(class_pick.selected))   # the real class, not its label


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _btn(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b


func _on_param(value: float, key: String) -> void:
	Predict.params[key] = value
	Predict.save_settings()


func _reset_params() -> void:
	Predict.reset_params()
	for key in spins:
		spins[key].set_value_no_signal(float(Predict.params[key]))


# ---------- Filling the entry box ----------

# Most recent quali of the selected class, taken from the rating history.
func _load_latest_quali() -> void:
	var cls := _current_class()
	if cls == "":
		notice.emit("No class with data yet.")
		return
	for i in range(Elo.history.size() - 1, -1, -1):
		var rows := []
		for c in Elo.history[i]["changes"]:
			if c["sess"] == "quali" and c["cls"] == cls:
				rows.append(c)
		if rows.is_empty():
			continue
		rows.sort_custom(func(a, b): return a["pos"] < b["pos"])
		var names := []
		for r in rows:
			names.append(r["driver"])
		entries.text = "\n".join(names)
		mode_pick.select(mode_pick.get_item_index(Predict.Mode.ACTUAL_GRID))
		notice.emit("Loaded the %s quali from %s." % [cls, Elo.history[i]["file"]])
		return
	notice.emit("No saved quali found for " + cls + ".")


# Entry list for a forecast before quali: everyone who raced this class in the last 4 events.
func _fill_recent() -> void:
	var cls := _current_class()
	if cls == "":
		return
	var seen := {}
	var events_used := 0
	for i in range(Elo.history.size() - 1, -1, -1):
		var found := false
		for c in Elo.history[i]["changes"]:
			if c["sess"] == "race" and c["cls"] == cls:
				seen[c["driver"]] = true
				found = true
		if found:
			events_used += 1
		if events_used >= 4:
			break
	var names: Array = seen.keys()
	names.sort()
	entries.text = "\n".join(names)
	mode_pick.select(mode_pick.get_item_index(Predict.Mode.PREDICTED_QUALI))
	notice.emit("Filled with %d drivers from the last %d %s races. Delete anyone who is not coming." % [names.size(), events_used, cls])


func _entry_names() -> Array:
	var out := []
	for line in entries.text.split("\n"):
		var n: String = Elo.resolve(line.strip_edges())
		if n != "" and n not in out:
			out.append(n)
	return out


# ---------- Predict ----------

func _run() -> void:
	if _busy:
		return
	var cls := _current_class()
	var names := _entry_names()
	if cls == "" or names.size() < 2:
		notice.emit("Pick a class and enter at least two drivers.")
		return
	_busy = true
	notice.emit("Simulating...")
	var mode := mode_pick.get_selected_id()
	var course := ""
	if track_pick.selected > 0:
		course = track_pick.get_item_text(track_pick.selected)
	var res: Dictionary = await Predict.forecast(names, cls, mode, course, int(minutes_spin.value), lap_spin.value)
	_busy = false
	_show(res, mode)


func _show(res: Dictionary, mode: int) -> void:
	var rows: Array = res["rows"]
	tree.clear()
	var root := tree.create_item()
	var has_quali := mode != Predict.Mode.ACTUAL_GRID
	for r in rows:
		var it := tree.create_item(root)
		it.set_text(0, str(r["grid"]) if r["grid"] > 0 else "-")
		it.set_text(1, r["name"] + ("" if r["known"] else " (new)"))
		it.set_text(2, "%.1f" % (100.0 * r["pole"]) if has_quali else "-")
		it.set_text(3, "%.1f" % (100.0 * r["front"]) if has_quali else "-")
		it.set_text(4, "%.1f" % r["exp_grid"] if has_quali else "-")
		it.set_text(5, "%.1f" % (100.0 * r["win"]))
		it.set_text(6, "%.1f" % (100.0 * r["podium"]))
		it.set_text(7, "%.1f" % (100.0 * r["top10"]))
		it.set_text(8, "%.1f" % r["exp_pos"])
		it.set_text(9, "%+.2f" % r["pace"])
		it.set_text(10, str(int(r.get("stops", 0))) if float(Predict.params.get("pits", 0.0)) > 0.0 else "-")
		var tip := "Race pace vs class median, in %%. Track history here: %+.2f%%, track tendencies: %+.2f%% (negative = quicker; applied only when that upgrade is on)." % [
			float(r.get("track_gap", 0.0)), float(r.get("tend", 0.0))]
		it.set_tooltip_text(9, tip)
		for c in range(2, 11):
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
	var t: Dictionary = res["track"]
	var lines := ["Track: %s. %d laps of about %.1f s (%d min)." % [t["course"] if t["course"] != "" else "unknown", res["laps"], t["ref_s"], t["minutes"]]]
	lines.append_array(res["notes"])
	out_label.text = "\n".join(lines)
	if has_quali:
		var by_grid := rows.duplicate()
		by_grid.sort_custom(func(a, b): return a["exp_grid"] < b["exp_grid"])
		var top := []
		for i in mini(5, by_grid.size()):
			top.append("%d. %s (%.0f%% pole)" % [i + 1, by_grid[i]["name"], 100.0 * by_grid[i]["pole"]])
		grid_line.text = "Predicted front of the grid: " + ", ".join(top)
	else:
		grid_line.text = ""
	notice.emit("Forecast ready: %d drivers, %d simulated races." % [rows.size(), Predict.N_SIMS])


# ---------- Backtest ----------

func _backtest() -> void:
	if _busy:
		return
	_busy = true
	out_label.text = "Replaying past races (each forecast only from earlier events)..."
	var s: Dictionary = await Predict.run_backtest()
	_busy = false
	if s.has("note"):
		out_label.text = s["note"]
		return
	var lines := ["Backtest on %d past races. Podium + top-10 error (lower is better) and winner log-loss:" % s["races"]]
	for k in s["modes"]:
		lines.append("%s: %.3f   (log-loss %.2f)" % [k, s["modes"][k]["brier"], s["modes"][k]["ll"]])
	out_label.text = "\n".join(lines)


func _test_upgrades() -> void:
	if _busy:
		return
	_busy = true
	out_label.text = "Replaying past races with each upgrade off and on, in two forecast modes. This takes a while..."
	var s: Dictionary = await Predict.test_upgrades()
	_busy = false
	if s.has("note"):
		out_label.text = s["note"]
		return
	var lines := ["Upgrades tested on %d past races (podium + top-10 error, lower is better; winner log-loss):" % s["races"]]
	for row in s["rows"]:
		lines.append("%s: %.4f   (log-loss %.2f)" % [row["name"], row["brier"], row["ll"]])
	if s["on"].is_empty():
		lines.append("None of them made the forecasts better, so all stay off.")
	else:
		var on := PackedStringArray()
		for name in s["on"]:
			on.append("%s (strength %.1f)" % [name, float(s["strength"].get(name, 1.0))])
		lines.append("Switched on: " + ", ".join(on) + ". The others stay off.")
	out_label.text = "\n".join(lines)
	for key in spins:
		spins[key].set_value_no_signal(float(Predict.params[key]))


func _fit_noise() -> void:
	if _busy:
		return
	_busy = true
	out_label.text = "Trying a few noise levels. This takes a while..."
	var s: Dictionary = await Predict.fit_noise()
	_busy = false
	if s.has("note"):
		out_label.text = s["note"]
		return
	var lines := ["Race-day noise fitted on %d past races:" % s["races"]]
	for row in s["table"]:
		lines.append("%.1f%%: error %.3f" % [row["sig_form"], row["brier"]])
	lines.append("Using %.1f%% from now on." % s["best"])
	out_label.text = "\n".join(lines)
	refresh()
