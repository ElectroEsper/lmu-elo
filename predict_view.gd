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
	["traffic", "Upgrade: multiclass traffic (0 = off, 1 = as measured)", 0.0, 2.0, 0.1],
]

var class_pick := OptionButton.new()
var series_pick := OptionButton.new()   # metadata = series code, "" = any
var grid_pick := OptionButton.new()     # past events to take a grid from; metadata = history index
var field_box := VBoxContainer.new()    # the other classes in the race: one row (tick + cars) per class
var pits_check := CheckBox.new()        # routine pit stops expected in this race
var fuel_spin := SpinBox.new()          # fuel / virtual-energy use multiplier
var tyre_spin := SpinBox.new()          # tyre wear multiplier
var min_stops_spin := SpinBox.new()     # stops the rules make compulsory
var _last_stops_on := false
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
	# two columns: settings and actions on the left, the forecast on the right, with a divider
	# that can be dragged (its position is remembered in user://ui.cfg)
	var cols := HSplitContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 16)
	cols.split_offset = _saved_split()
	cols.dragged.connect(func(offset: int): _save_split(offset))
	add_child(cols)
	var left_scroll := ScrollContainer.new()
	left_scroll.custom_minimum_size = Vector2(LEFT_MIN, 0)
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
	minutes_spin.tooltip_text = "Race length. 0 = the usual length of the chosen series (or of the latest races)."
	series_pick.tooltip_text = "Which championship the race belongs to. Sets the usual race length, which other classes share the track (traffic), and which drivers 'Recent drivers' and 'Load latest quali' use."
	lap_spin.min_value = 0
	lap_spin.max_value = 600
	lap_spin.step = 0.1
	lap_spin.tooltip_text = "Typical lap time. 0 = take it from the data."
	for pair in [["Class", class_pick], ["Series", series_pick], ["Forecast", mode_pick], ["Track", track_pick],
			["Minutes", minutes_spin], ["Lap time (s)", lap_spin]]:
		var l := _label(pair[0])
		l.theme_type_variation = "Muted"
		form.add_child(l)
		var c: Control = pair[1]
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if c is OptionButton:
			(c as OptionButton).clip_text = true
			c.custom_minimum_size = Vector2(120, 0)
		form.add_child(c)

	# the other classes on track (traffic), filled from the series' recent races
	var field_title := _label("Other classes in the race")
	field_title.theme_type_variation = "Muted"
	field_title.tooltip_text = "Tick the classes sharing the track with the forecast class and set their number of cars. Filled in from the chosen series' recent races; change it if this race is different. Used by the traffic upgrade."
	field_title.mouse_filter = Control.MOUSE_FILTER_PASS
	setup.add_child(field_title)
	setup.add_child(field_box)

	# pit stops, filled from Settings > Race rules for the series
	pits_check.text = "Pit stops expected"
	pits_check.tooltip_text = "Routine stops for fuel / energy and tyres. Off for races run on one tank (Sprint: stops there are repairs, which the contact model already covers). Filled in from Settings > Race rules for the chosen series."
	setup.add_child(pits_check)
	var pit_form := GridContainer.new()
	pit_form.columns = 2
	pit_form.add_theme_constant_override("h_separation", 12)
	setup.add_child(pit_form)
	for row in [["Fuel / energy use x", fuel_spin, 0.1, 10.0, 0.1, "Fuel (and virtual energy) multiplier set on the server for this race."],
			["Tyre wear x", tyre_spin, 0.1, 10.0, 0.1, "Tyre wear multiplier set on the server for this race."],
			["Minimum stops", min_stops_spin, 0.0, 5.0, 1.0, "Stops the rules make compulsory, even if fuel and tyres would last."]]:
		var l := _label(row[0])
		l.theme_type_variation = "Muted"
		pit_form.add_child(l)
		var sb: SpinBox = row[1]
		sb.min_value = row[2]
		sb.max_value = row[3]
		sb.step = row[4]
		sb.tooltip_text = row[5]
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pit_form.add_child(sb)
	pits_check.toggled.connect(func(on: bool):
		for sb in [fuel_spin, tyre_spin, min_stops_spin]:
			sb.editable = on)

	# entry list
	var entry := _card(left, "ENTRY LIST")
	entries.custom_minimum_size = Vector2(0, 230)
	entries.placeholder_text = "One driver per line.\nAfter quali: pole position first.\nBefore quali: just the entry list.\nAliases are resolved."
	entry.add_child(entries)
	var pick_row := HBoxContainer.new()
	entry.add_child(pick_row)
	var pick_label := _label("Grid from")
	pick_label.theme_type_variation = "Muted"
	pick_row.add_child(pick_label)
	grid_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_pick.clip_text = true
	grid_pick.custom_minimum_size = Vector2(120, 0)
	grid_pick.tooltip_text = "Fill the list with the grid of a past event of this class (and series): its qualifying order, pole first, or the race's starting grid when the event had no quali."
	grid_pick.item_selected.connect(_on_grid_pick)
	pick_row.add_child(grid_pick)
	class_pick.item_selected.connect(func(_i):
		_fill_grid_pick()
		_fill_field()
		_fill_plan())
	series_pick.item_selected.connect(func(_i):
		_fill_grid_pick()
		_fill_field()
		_fill_plan())
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

	tree.column_titles_visible = true
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# short titles keep the table narrow (it has to fit beside the settings on a 1080p screen);
	# the header tooltips say what each column is
	_setup_columns(11)
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
	class_pick.add_item("All classes (whole race)")
	class_pick.set_item_metadata(class_pick.item_count - 1, ALL)
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
	var keep_series := _current_series()
	series_pick.clear()
	series_pick.add_item("Any series")
	series_pick.set_item_metadata(0, "")
	var codes := {}
	for day in Profiles.days:
		if str(day.get("series", "")) != "":
			codes[str(day["series"])] = true
	var names: Dictionary = LeagueSettings.get_value("series_names")
	for c in names:
		codes[str(c)] = true
	var code_list := codes.keys()
	code_list.sort()
	for c in code_list:
		series_pick.add_item(str(names.get(c, str(c).to_upper())))
		series_pick.set_item_metadata(series_pick.item_count - 1, c)
		if c == keep_series:
			series_pick.select(series_pick.item_count - 1)
	for key in spins:
		spins[key].set_value_no_signal(float(Predict.params[key]))
	_fill_grid_pick()
	_fill_field()
	_fill_plan()
	if Profiles.has_data():
		info.text = "%d events with lap data. Odds come from pace, tyre wear, top speed, fuel use, track limits, contacts and consistency; they ignore strategy, weather and who actually shows up." % Profiles.days.size()
	else:
		info.text = "No lap-data fingerprints saved yet, so drivers are rated from Elo only. Drop the folder with your result XMLs on the window to backfill them."


# ---------- Classes ----------
const ALL := "*"   # class_pick metadata for "All classes": every class of the series, each simulated with the others as traffic


func _all_mode() -> bool:
	return _current_class() == ALL


# The series this forecast is about: the chosen one, or (any series) the latest race's series
func _series_code() -> String:
	var code := _current_series()
	if code == "":
		var cls := _current_class()
		code = str(Predict.series_context("", cls if cls != ALL and cls != "" else _first_class()).get("series", ""))
	return code


func _first_class() -> String:
	for i in class_pick.item_count:
		var c := str(class_pick.get_item_metadata(i))
		if c != ALL:
			return c
	return ""


# Classes of the forecast: the chosen one, or the series' regular classes (fastest first)
func _run_classes() -> Array:
	if not _all_mode():
		return [_current_class()] if _current_class() != "" else []
	return Predict.series_classes(_series_code())


# ---------- Grid from a chosen event ----------
# One entry per event of the class(es) (in the chosen series), newest first: the quali if the
# event had one, otherwise the race (its starting grid).
func _fill_grid_pick() -> void:
	grid_pick.clear()
	grid_pick.add_item("Pick an event...")
	grid_pick.set_item_metadata(0, -1)
	var classes := _run_classes()
	if classes.is_empty():
		return
	var full := Elo.full_events()
	var best := {}    # full event -> history index (quali preferred)
	var order := []   # full events, newest first
	for i in range(Elo.history.size() - 1, -1, -1):
		var h: Dictionary = Elo.history[i]
		if not _in_series(h):
			continue
		var sess := ""
		for c in h["changes"]:
			if c["cls"] in classes:
				sess = "quali" if c["sess"] == "quali" else (sess if sess != "" else "race")
				if sess == "quali":
					break
		if sess == "":
			continue
		var ev: int = full[i]
		if not best.has(ev):
			order.append(ev)
			best[ev] = i
		elif sess == "quali" and not _has_quali_any(Elo.history[best[ev]], classes):
			best[ev] = i
	for ev in order:
		var i: int = best[ev]
		var h: Dictionary = Elo.history[i]
		var date := Time.get_date_string_from_unix_time(int(h.get("time", 0))) if int(h.get("time", 0)) > 0 else ""
		grid_pick.add_item("%s  %s  %s (%s)" % [str(h["file"]).get_basename(), str(h.get("course", "")), date,
			"quali" if _has_quali_any(h, classes) else "race grid"])
		grid_pick.set_item_metadata(grid_pick.item_count - 1, i)
	grid_pick.select(0)


# One row per other known class: ticked, with its usual number of cars, when the chosen series
# (or, for any series, the latest races of the class) has it on track. With all classes, the
# traffic comes from the entry list itself.
func _fill_field() -> void:
	for c in field_box.get_children():
		field_box.remove_child(c)
		c.queue_free()
	var cls := _current_class()
	if cls == "":
		return
	if cls == ALL:
		var note := _label("All classes: each class is simulated with the others in the entry list as traffic.")
		note.theme_type_variation = "Muted"
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		field_box.add_child(note)
		return
	var ctx := Predict.series_context(_current_series(), cls)
	var classes := {}
	for c in Profiles.classes():
		classes[c] = true
	for b in Elo.boards():
		classes[b[0]] = true
	var names := classes.keys()
	names.sort()
	for c in names:
		if c == cls:
			continue
		var row := HBoxContainer.new()
		var tick := CheckBox.new()
		tick.text = LeagueSettings.label(str(c))
		tick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cars := SpinBox.new()
		cars.min_value = 1
		cars.max_value = 60
		cars.suffix = "cars"
		cars.custom_minimum_size = Vector2(96, 0)
		var on: bool = ctx["others"].has(c)
		tick.button_pressed = on
		cars.value = roundf(float(ctx["others"][c]["n"])) if on else 10.0
		cars.editable = on
		tick.toggled.connect(func(v: bool): cars.editable = v)
		row.set_meta("class", c)
		row.add_child(tick)
		row.add_child(cars)
		field_box.add_child(row)
	if field_box.get_child_count() == 0:
		var none := _label("No other class known yet.")
		none.theme_type_variation = "Muted"
		field_box.add_child(none)


# Pit-stop settings from the series' current race rules (Settings > Race rules). With "Any
# series", the series of the latest race.
func _fill_plan() -> void:
	var r := LeagueSettings.rules_for(_series_code(), 0)
	pits_check.button_pressed = bool(r["pits"])
	fuel_spin.value = float(r["fuel"])
	tyre_spin.value = float(r["tyre"])
	min_stops_spin.value = int(r["min_stops"])
	for sb in [fuel_spin, tyre_spin, min_stops_spin]:
		sb.editable = pits_check.button_pressed


func _plan() -> Dictionary:
	return {"pits": pits_check.button_pressed, "fuel": fuel_spin.value, "tyre": tyre_spin.value,
		"min_stops": int(min_stops_spin.value)}


# {class: cars} for the ticked classes; "_set" marks that the screen chose them (even none).
func _field() -> Dictionary:
	var out := {"_set": 1}
	for row in field_box.get_children():
		if row.has_meta("class") and str(row.get_meta("class")) != _current_class() and (row.get_child(0) as CheckBox).button_pressed:
			out[str(row.get_meta("class"))] = int((row.get_child(1) as SpinBox).value)
	return out


func _has_quali(h: Dictionary, cls: String) -> bool:
	for c in h["changes"]:
		if c["sess"] == "quali" and c["cls"] == cls:
			return true
	return false


func _has_quali_any(h: Dictionary, classes: Array) -> bool:
	for cls in classes:
		if _has_quali(h, cls):
			return true
	return false


# Grid of one class at the full event of history entry i: its quali order (pole first), else
# the race's starting grid. [driver names]
func _event_grid(i: int, cls: String) -> Array:
	var full := Elo.full_events()
	var entries_of := []
	for j in Elo.history.size():
		if full[j] == full[i]:
			entries_of.append(j)
	var rows := []   # [grid place, driver]
	for j in entries_of:
		if _has_quali(Elo.history[j], cls):
			for c in Elo.history[j]["changes"]:
				if c["sess"] == "quali" and c["cls"] == cls:
					rows.append([int(c["pos"]), str(c["driver"])])
			break
	if rows.is_empty():
		for j in entries_of:
			var h: Dictionary = Elo.history[j]
			var st: Dictionary = h.get("stats", {}).get("race", {}).get(cls, {})
			for c in h["changes"]:
				if c["sess"] == "race" and c["cls"] == cls:
					var g := int(st.get(c["driver"], {}).get("grid", 0))
					rows.append([g if g > 0 else 1000 + int(c["pos"]), str(c["driver"])])
			if not rows.is_empty():
				break
	rows.sort()
	return rows.map(func(r): return Elo.resolve(r[1]))


func _on_grid_pick(index: int) -> void:
	var i := int(grid_pick.get_item_metadata(index))
	if i < 0:
		return
	var groups := {}
	var total := 0
	for cls in _run_classes():
		var names := _event_grid(i, cls)
		if not names.is_empty():
			groups[cls] = names
			total += names.size()
	_set_entries(groups)
	mode_pick.select(mode_pick.get_item_index(Predict.Mode.ACTUAL_GRID))
	notice.emit("Loaded the grid of %s (%d drivers, pole first%s)." % [str(Elo.history[i]["file"]), total, ", by class" if _all_mode() else ""])


# ---------- Layout ----------
const LEFT_MIN := 280      # the settings column can be dragged down to this width
const LEFT_DEFAULT := 320  # ...and starts at this one
const UI_CFG := "user://ui.cfg"


# HSplitContainer offset: how far the divider sits from the left panel's minimum width
func _saved_split() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CFG) == OK:
		return int(cfg.get_value("predict", "split", LEFT_DEFAULT - LEFT_MIN))
	return LEFT_DEFAULT - LEFT_MIN


func _save_split(offset: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(UI_CFG)
	cfg.set_value("predict", "split", offset)
	cfg.save(UI_CFG)


func _current_series() -> String:
	if series_pick.item_count == 0 or series_pick.selected < 0:
		return ""
	return str(series_pick.get_item_metadata(series_pick.selected))


# True if this history entry belongs to the chosen series (always true for "Any series")
func _in_series(h: Dictionary) -> bool:
	var code := _current_series()
	return code == "" or Elo.series_code(str(h["file"])) == code


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

# The entry box: one driver per line; with all classes, each class under a "[Class]" line.
func _set_entries(groups: Dictionary) -> void:
	var lines := PackedStringArray()
	for cls in groups:
		if _all_mode():
			if not lines.is_empty():
				lines.append("")
			lines.append("[%s]" % LeagueSettings.label(str(cls)))
		for n in groups[cls]:
			lines.append(str(n))
	entries.text = "\n".join(lines)


# {class: [driver names]} from the entry box. "[Class]" lines (game name or display name) start a
# class; lines before any of them belong to the selected class (or, with all classes, the first).
func _entry_groups() -> Dictionary:
	var classes := _run_classes()
	var known := {}
	for c in Profiles.classes():
		known[str(c).to_lower()] = c
		known[LeagueSettings.label(str(c)).to_lower()] = c
	for b in Elo.boards():
		known[str(b[0]).to_lower()] = b[0]
		known[LeagueSettings.label(str(b[0])).to_lower()] = b[0]
	var cur: String = classes[0] if not classes.is_empty() else ""
	var out := {}
	for line in entries.text.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("[") and t.ends_with("]"):
			var key := t.substr(1, t.length() - 2).strip_edges().to_lower()
			cur = str(known.get(key, t.substr(1, t.length() - 2).strip_edges()))
			continue
		var n: String = Elo.resolve(t)
		if n == "" or cur == "":
			continue
		if not out.has(cur):
			out[cur] = []
		if n not in out[cur]:
			out[cur].append(n)
	return out


# Most recent quali of the selected class(es), taken from the rating history.
func _load_latest_quali() -> void:
	var classes := _run_classes()
	if classes.is_empty():
		notice.emit("No class with data yet.")
		return
	for i in range(Elo.history.size() - 1, -1, -1):
		if not _in_series(Elo.history[i]) or not _has_quali_any(Elo.history[i], classes):
			continue
		var groups := {}
		for cls in classes:
			var names := _event_grid(i, cls)
			if not names.is_empty():
				groups[cls] = names
		_set_entries(groups)
		mode_pick.select(mode_pick.get_item_index(Predict.Mode.ACTUAL_GRID))
		notice.emit("Loaded the quali from %s." % Elo.history[i]["file"])
		return
	notice.emit("No saved quali found%s." % ("" if _current_series() == "" else " in " + series_pick.get_item_text(series_pick.selected)))


# Entry list for a forecast before quali: everyone who raced the class(es) in the last 4 events.
func _fill_recent() -> void:
	var classes := _run_classes()
	if classes.is_empty():
		return
	var groups := {}
	var total := 0
	for cls in classes:
		var seen := {}
		var events_used := 0
		for i in range(Elo.history.size() - 1, -1, -1):
			if not _in_series(Elo.history[i]):
				continue
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
		if not names.is_empty():
			groups[cls] = names
			total += names.size()
	_set_entries(groups)
	mode_pick.select(mode_pick.get_item_index(Predict.Mode.PREDICTED_QUALI))
	var where := "" if _current_series() == "" else series_pick.get_item_text(series_pick.selected) + " "
	notice.emit("Filled with %d drivers from the last 4 %sraces of each class. Delete anyone who is not coming." % [total, where])


# ---------- Predict ----------

func _run() -> void:
	if _busy:
		return
	var groups := _entry_groups()
	var classes := []
	for cls in _run_classes():
		if groups.get(cls, []).size() >= 2:
			classes.append(cls)
	for cls in groups:   # a class typed in by hand, not a regular of the series: last
		if cls not in classes and groups[cls].size() >= 2 and _all_mode():
			classes.append(cls)
	if classes.is_empty():
		notice.emit("Pick a class and enter at least two drivers%s." % (" per class" if _all_mode() else ""))
		return
	_busy = true
	notice.emit("Simulating...")
	var mode := mode_pick.get_selected_id()
	var course := ""
	if track_pick.selected > 0:
		course = track_pick.get_item_text(track_pick.selected)
	var results := []   # [{"cls", "res"}], fastest class first
	for cls in classes:
		var field := _field()
		if _all_mode():   # traffic: the other classes of the entry list, with their car counts
			field = {"_set": 1}
			for other in classes:
				if other != cls:
					field[other] = groups[other].size()
		var res: Dictionary = await Predict.forecast(groups[cls], cls, mode, course, int(minutes_spin.value),
			lap_spin.value, _current_series(), field, _plan())
		results.append({"cls": cls, "res": res})
	_last_stops_on = pits_check.button_pressed
	_busy = false
	_show_all(results, mode)


# Column titles and widths; with several classes an "Overall" column is added.
const TITLES := ["Grid", "Driver", "Pole", "Front", "Exp. grid", "Win", "Podium", "Top 10", "Exp. pos", "Pace", "Stops", "Overall"]
const TITLE_TIPS := ["Starting place (after quali; ~ = predicted). Within the class.", "Driver.", "Chance of pole, %.",
	"Chance of a front-row start, %.", "Expected starting place.", "Chance to win, %.", "Chance of a podium, %.",
	"Chance of a top-10 finish, %.", "Expected finishing place.", "Race pace vs the class median, % (negative = quicker).",
	"Planned pit stops.", "Expected overall finishing place: the faster class finishes ahead on laps, then the order within each class."]


func _setup_columns(n: int) -> void:
	tree.columns = n
	for i in n:
		tree.set_column_title(i, TITLES[i])
		tree.set_column_title_tooltip_text(i, TITLE_TIPS[i])
		tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT if i >= 2 else HORIZONTAL_ALIGNMENT_LEFT)
		if i != 1:
			tree.set_column_custom_minimum_width(i, maxi(62, str(TITLES[i]).length() * 8 + 14))
		tree.set_column_expand(i, i == 1)
	tree.set_column_custom_minimum_width(1, 140 if n <= 11 else 130)
	tree.set_column_custom_minimum_width(0, 50)    # "Grid": small numbers
	tree.set_column_custom_minimum_width(9, 66)    # "Pace": "-1.38" needs more than its title
	tree.set_column_custom_minimum_width(7, 72)    # "Top 10" and "Exp. pos" on one line
	tree.set_column_custom_minimum_width(8, 84)
	tree.set_column_custom_minimum_width(6, 80)    # "Podium": bold capitals need a little more


func _show_all(results: Array, mode: int) -> void:
	var multi := results.size() > 1
	_setup_columns(12 if multi else 11)
	tree.clear()
	var root := tree.create_item()
	var lines := []
	var grid_parts := []
	var overall := 0   # drivers of the faster classes, ahead on the road
	var total := 0
	var seen_notes := {}
	for entry in results:
		var cls: String = entry["cls"]
		var res: Dictionary = entry["res"]
		if multi:
			var head := tree.create_item(root)
			head.set_text(1, "%s · %d" % [LeagueSettings.label(cls).to_upper(), res["rows"].size()])
			head.set_tooltip_text(1, "%s: %d drivers. Overall places count the faster classes first." % [LeagueSettings.label(cls), res["rows"].size()])
			head.set_selectable(1, false)
			for c in tree.columns:
				head.set_custom_bg_color(c, UiTheme.SURFACE_3)
				head.set_selectable(c, false)
			head.set_custom_color(1, UiTheme.ACCENT_SOFT)
		_add_rows(root, res["rows"], mode, overall if multi else -1)
		overall += res["rows"].size()
		total += res["rows"].size()
		var t: Dictionary = res["track"]
		lines.append("%sTrack: %s. %d laps of about %.1f s (%d min)." % [(LeagueSettings.label(cls) + ": ") if multi else "",
			t["course"] if t["course"] != "" else "unknown", res["laps"], t["ref_s"], t["minutes"]])
		for n in res["notes"]:
			if multi and str(n).begins_with("Upgrades on"):
				if seen_notes.has(n):
					continue
				seen_notes[n] = true
				lines.append(n)
			else:
				lines.append(((LeagueSettings.label(cls) + ": ") if multi else "") + str(n))
		if mode != Predict.Mode.ACTUAL_GRID:
			var by_grid: Array = res["rows"].duplicate()
			by_grid.sort_custom(func(a, b): return a["exp_grid"] < b["exp_grid"])
			var top := []
			for i in mini(5 if not multi else 3, by_grid.size()):
				top.append("%d. %s (%.0f%% pole)" % [i + 1, by_grid[i]["name"], 100.0 * by_grid[i]["pole"]])
			grid_parts.append(((LeagueSettings.label(cls) + ": ") if multi else "") + ", ".join(top))
	out_label.text = "\n".join(lines)
	grid_line.text = ("Predicted front of the grid: " + "  |  ".join(grid_parts)) if not grid_parts.is_empty() else ""
	notice.emit("Forecast ready: %d drivers%s, %d simulated races%s." % [total, " in %d classes" % results.size() if multi else "",
		Predict.N_SIMS, " per class" if multi else ""])


# The rows of one class, in expected finishing order; the predicted podium is tinted gold /
# silver / bronze. overall_offset >= 0: also the "Overall" column (drivers of faster classes first).
func _add_rows(root: TreeItem, rows: Array, mode: int, overall_offset: int) -> void:
	var has_quali := mode != Predict.Mode.ACTUAL_GRID
	# before quali: predicted starting place = rank by expected grid place ("~3")
	var pred_grid := {}
	if mode == Predict.Mode.PREDICTED_QUALI:
		var by_grid := rows.duplicate()
		by_grid.sort_custom(func(a, b): return a["exp_grid"] < b["exp_grid"])
		for k in by_grid.size():
			pred_grid[by_grid[k]["name"]] = k + 1
	var podium := [Color("eac45a"), Color("c3cad4"), Color("c98a5a")]
	var place := 0
	for r in rows:
		var it := tree.create_item(root)
		if place < podium.size():
			var tint: Color = podium[place]
			for c in tree.columns:
				it.set_custom_bg_color(c, Color(tint, 0.16))
			it.set_custom_color(1, tint.lightened(0.25))
			it.set_tooltip_text(1, "Predicted P%d in class: %s (expected finish %.1f)." % [place + 1, r["name"], float(r["exp_pos"])])
		place += 1
		if r["grid"] > 0:
			it.set_text(0, str(r["grid"]))
		elif pred_grid.has(r["name"]):
			it.set_text(0, "~%d" % pred_grid[r["name"]])
			it.set_tooltip_text(0, "Predicted starting place in class: ranked by expected grid place (%.1f)." % float(r["exp_grid"]))
		else:
			it.set_text(0, "-")
		it.set_text(1, r["name"] + ("" if r["known"] else " (new)"))
		if place > podium.size():   # podium rows already carry their own tooltip
			it.set_tooltip_text(1, str(r["name"]))
		it.set_text(2, "%.1f" % (100.0 * r["pole"]) if has_quali else "-")
		it.set_text(3, "%.1f" % (100.0 * r["front"]) if has_quali else "-")
		it.set_text(4, "%.1f" % r["exp_grid"] if has_quali else "-")
		it.set_text(5, "%.1f" % (100.0 * r["win"]))
		it.set_text(6, "%.1f" % (100.0 * r["podium"]))
		it.set_text(7, "%.1f" % (100.0 * r["top10"]))
		it.set_text(8, "%.1f" % r["exp_pos"])
		it.set_text(9, "%+.2f" % r["pace"])
		it.set_text(10, str(int(r.get("stops", 0))) if _last_stops_on else "-")
		if overall_offset >= 0:
			it.set_text(11, str(overall_offset + place))
		var tip := "Race pace vs class median, in %%. Track history here: %+.2f%%, track tendencies: %+.2f%% (negative = quicker; applied only when that upgrade is on)." % [
			float(r.get("track_gap", 0.0)), float(r.get("tend", 0.0))]
		it.set_tooltip_text(9, tip)
		for c in range(2, tree.columns):
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)


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
