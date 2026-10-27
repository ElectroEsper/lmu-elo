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
	var bar := HFlowContainer.new()
	add_child(bar)
	bar.add_child(class_pick)
	mode_pick.add_item("After quali: use the grid below", Predict.Mode.ACTUAL_GRID)
	mode_pick.add_item("Before quali: predict quali, then race", Predict.Mode.PREDICTED_QUALI)
	mode_pick.add_item("Race only: ignore the grid", Predict.Mode.RACE_ONLY)
	mode_pick.select(0)
	bar.add_child(mode_pick)
	bar.add_child(track_pick)
	bar.add_child(_label("Minutes"))
	minutes_spin.min_value = 0
	minutes_spin.max_value = 240
	minutes_spin.step = 1
	minutes_spin.tooltip_text = "0 = take from the data"
	bar.add_child(minutes_spin)
	bar.add_child(_label("Lap (s)"))
	lap_spin.min_value = 0
	lap_spin.max_value = 600
	lap_spin.step = 0.1
	lap_spin.tooltip_text = "0 = take from the data"
	bar.add_child(lap_spin)

	var bar2 := HFlowContainer.new()
	add_child(bar2)
	bar2.add_child(_btn("Load grid from latest quali", _load_latest_quali))
	bar2.add_child(_btn("Fill with recent drivers", _fill_recent))
	bar2.add_child(_btn("Predict", _run))
	bar2.add_child(_btn("Backtest", _backtest))
	bar2.add_child(_btn("Fit noise (slow)", _fit_noise))
	var toggle := CheckButton.new()
	toggle.text = "Model assumptions"
	toggle.toggled.connect(func(on: bool): assumptions.visible = on)
	bar2.add_child(toggle)

	assumptions.visible = false
	add_child(assumptions)
	var grid := GridContainer.new()
	grid.columns = 4
	assumptions.add_child(grid)
	for row in PARAM_ROWS:
		grid.add_child(_label(row[1]))
		var sb := SpinBox.new()
		sb.min_value = row[2]
		sb.max_value = row[3]
		sb.step = row[4]
		sb.value = float(Predict.params[row[0]])
		sb.value_changed.connect(_on_param.bind(row[0]))
		grid.add_child(sb)
		spins[row[0]] = sb
	assumptions.add_child(_btn("Reset assumptions", _reset_params))

	entries.custom_minimum_size = Vector2(0, 150)
	entries.placeholder_text = "One driver per line.\nAfter quali: pole position first. Before quali: just the entry list.\nAliases are resolved."
	add_child(entries)

	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(info)
	grid_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(grid_line)

	tree.columns = 10
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var titles := ["Grid", "Driver", "Pole %", "Front row %", "Exp. grid", "Win %", "Podium %", "Top 10 %", "Exp. finish", "Race pace %"]
	for i in titles.size():
		tree.set_column_title(i, titles[i])
		tree.set_column_expand(i, i == 1)
	tree.set_column_custom_minimum_width(1, 170)
	add_child(tree)

	out_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(out_label)


# Called by the main screen whenever this view is shown.
func refresh() -> void:
	if get_node_or_null("/root/Predict") == null or get_node_or_null("/root/Profiles") == null:
		info.text = "The Predict / Profiles autoloads are not running. Check Project Settings > Globals > Autoload (names 'Profiles' and 'Predict', below 'Elo') and the Output panel for errors."
		return
	Profiles.rebuild()
	var keep := _current_class()
	class_pick.clear()
	var seen := {}
	for c in Profiles.classes():
		seen[c] = true
		class_pick.add_item(c)
	for b in Elo.boards():
		if b[1] == "race" and not seen.has(b[0]):
			seen[b[0]] = true
			class_pick.add_item(b[0])
	for i in class_pick.item_count:
		if class_pick.get_item_text(i) == keep:
			class_pick.select(i)
	var keep_track := track_pick.get_item_text(track_pick.selected) if track_pick.item_count > 0 and track_pick.selected >= 0 else ""
	track_pick.clear()
	track_pick.add_item("Track: latest event", 0)
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
	return class_pick.get_item_text(class_pick.selected)


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
		for c in range(2, 10):
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
