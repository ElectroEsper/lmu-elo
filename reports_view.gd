class_name ReportsView
extends VBoxContainer
## The Reports screen: pick a report, optionally an event or two drivers, and read the tables.
## Needs the autoloads "Elo" and "Reports", and rating_chart.gd in the project.

signal notice(text: String)

const REPORTS := [
	{"name": "Biggest movers", "kind": "event", "fn": "movers"},
	{"name": "Upsets", "kind": "event", "fn": "upsets"},
	{"name": "Event detail", "kind": "event", "fn": "event_detail"},
	{"name": "Rating history", "kind": "all", "fn": "rating_history"},
	{"name": "Race vs quali", "kind": "all", "fn": "race_vs_quali"},
	{"name": "Consistency", "kind": "all", "fn": "consistency"},
	{"name": "Grid vs finish", "kind": "all", "fn": "grid_vs_finish"},
	{"name": "Rookies", "kind": "all", "fn": "rookies"},
	{"name": "Standings", "kind": "all", "fn": "standings"},
	{"name": "Head to head", "kind": "pair", "fn": "head_to_head"},
	{"name": "Profile", "kind" : "single", "fn": "driver_profile"},
]

var report_picker := OptionButton.new()
var event_picker := OptionButton.new()
var pair_box := HFlowContainer.new()
var board_picker := OptionButton.new()
var driver_a := OptionButton.new()
var driver_b := OptionButton.new()
var out_tabs := TabContainer.new()

var shown: Array = []     # tables currently displayed
var _boards: Array = []   # class/session pairs for the head-to-head picker


func _ready() -> void:
	var bar := HFlowContainer.new()
	add_child(bar)
	for r in REPORTS:
		report_picker.add_item(r["name"])
	report_picker.item_selected.connect(_on_param_changed)
	bar.add_child(report_picker)
	event_picker.item_selected.connect(_on_param_changed)
	bar.add_child(event_picker)
	var export_btn := Button.new()
	export_btn.text = "Export report to Excel"
	export_btn.pressed.connect(_export)
	bar.add_child(export_btn)

	board_picker.item_selected.connect(_on_board_changed)
	pair_box.add_child(board_picker)
	driver_a.item_selected.connect(_on_param_changed)
	pair_box.add_child(driver_a)
	driver_b.item_selected.connect(_on_param_changed)
	pair_box.add_child(driver_b)
	add_child(pair_box)

	out_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(out_tabs)


# Called whenever the Reports screen is opened or the data changed
func refresh() -> void:
	event_picker.clear()
	for i in range(Elo.history.size() - 1, -1, -1):   # newest first
		event_picker.add_item(Elo.history[i]["file"], i)
	if event_picker.item_count > 0:
		event_picker.select(0)
	_boards = Elo.boards()
	board_picker.clear()
	for b in _boards:
		board_picker.add_item("%s %s" % [b[0], b[1]])
	if board_picker.item_count > 0:
		board_picker.select(0)
	_fill_drivers()
	_run()


func _fill_drivers() -> void:
	driver_a.clear()
	driver_b.clear()
	if board_picker.selected < 0:
		return
	var b: Array = _boards[board_picker.selected]
	for r in Elo.leaderboard(b[0], b[1]):
		driver_a.add_item(r["name"])
		driver_b.add_item(r["name"])
	if driver_b.item_count > 1:
		driver_b.select(1)


func _on_param_changed(_index: int) -> void:
	_run()


func _on_board_changed(_index: int) -> void:
	_fill_drivers()
	_run()


func _clear(container: Node) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()


func _message(text: String) -> void:
	shown = []
	_clear(out_tabs)
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(480, 0)
	out_tabs.add_child(l)
	out_tabs.set_tab_title(0, "Info")


func _run() -> void:
	if report_picker.selected < 0:
		return
	var rep: Dictionary = REPORTS[report_picker.selected]
	event_picker.visible = rep["kind"] == "event"
	pair_box.visible = rep["kind"] == "pair" 
	driver_a.visible = rep["kind"] == "pair" 
	driver_b.visible = rep["kind"] == "pair" 
	

	var tables: Array = []
	match rep["kind"]:
		"event":
			if event_picker.item_count == 0:
				_message("No history yet. Confirm a result file, or press Recompute all to build it from the saved events.")
				return
			tables = Reports.call(rep["fn"], event_picker.get_selected_id())
		"pair":
			if board_picker.selected < 0 or driver_a.item_count < 2:
				_message("Head to head needs at least two rated drivers in a class.")
				return
			var b: Array = _boards[board_picker.selected]
			tables = Reports.head_to_head(b[0], b[1],
				driver_a.get_item_text(driver_a.selected),
				driver_b.get_item_text(driver_b.selected))
		"single":
			if board_picker.selected < 0 or driver_a.item_count < 2:
				_message("Head to head needs at least two rated drivers in a class.")
				return
			pair_box.visible = true
			driver_a.visible = true
			driver_b.visible = false
			var b: Array = _boards[board_picker.selected]
			tables = Reports.driver_profile(driver_a.get_item_text(driver_a.selected))
			
		_:
			tables = Reports.call(rep["fn"])

	if tables.is_empty():
		_message("Nothing to show yet. Confirm a result file, or press Recompute all.")
		return
	shown = tables
	_clear(out_tabs)
	for t in tables:
		out_tabs.add_child(_table_view(t))
		out_tabs.set_tab_title(out_tabs.get_tab_count() - 1, t["title"])


func _cell_text(v) -> String:
	match typeof(v):
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			return "%.2f" % v
		_:
			return str(v)


func _table_view(t: Dictionary) -> Control:
	var scroll := ScrollContainer.new()
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

	if t.get("note", "") != "":
		var note := Label.new()
		note.text = t["note"]
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size = Vector2(480, 0)
		box.add_child(note)

	if t.has("chart"):
		var legend := HFlowContainer.new()
		for s in t["chart"]["series"]:
			var l := Label.new()
			l.text = "[%s]" % s["name"]
			l.add_theme_color_override("font_color", s["color"])
			legend.add_child(l)
		box.add_child(legend)
		var chart := RatingChart.new()
		chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chart.set_data(t["chart"]["series"], t["chart"]["x_max"])
		box.add_child(chart)

	var grid := GridContainer.new()
	grid.columns = maxi(t["headers"].size(), 1)
	grid.add_theme_constant_override("h_separation", 16)
	for h in t["headers"]:
		var hl := Label.new()
		hl.text = str(h)
		hl.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
		grid.add_child(hl)
	for row in t["rows"]:
		for v in row:
			var l := Label.new()
			l.text = _cell_text(v)
			grid.add_child(l)
	box.add_child(grid)
	return scroll


# ---------- Excel export of the report on screen ----------
func _export() -> void:
	if shown.is_empty():
		notice.emit("Nothing to export in this report.")
		return
	var sheets := []
	for t in shown:
		sheets.append({"name": t["title"], "headers": t["headers"], "rows": t["rows"]})
	var report_name: String = REPORTS[report_picker.selected]["name"]
	var dir := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/lmu_%s_%s.xlsx" % [dir, report_name.to_lower().replace(" ", "_"), stamp]
	var err := Elo.write_xlsx(path, sheets)
	if err == OK:
		notice.emit("Exported: " + path)
		OS.shell_open(dir)
	else:
		notice.emit("Export failed (error %d)" % err)
