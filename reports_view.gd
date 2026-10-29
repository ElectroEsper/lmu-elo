class_name ReportsView
extends VBoxContainer
## The Reports screen: pick a report, optionally an event or two drivers, and read the tables.
## Needs the autoloads "Elo" and "Reports", plus table_view.gd, sort_table.gd and rating_chart.gd.

signal notice(text: String)

const REPORTS := [
	{"name": "Biggest movers", "kind": "event", "fn": "movers"},
	{"name": "Upsets", "kind": "event", "fn": "upsets"},
	{"name": "Event detail", "kind": "event", "fn": "event_detail"},
	{"name": "Rating history", "kind": "all", "fn": "rating_history"},
	{"name": "Race vs quali", "kind": "all", "fn": "race_vs_quali"},
	{"name": "Consistency", "kind": "all", "fn": "consistency", "season": true},
	{"name": "Grid vs finish", "kind": "all", "fn": "grid_vs_finish", "season": true},
	{"name": "Rookies", "kind": "all", "fn": "rookies"},
	{"name": "Standings", "kind": "all", "fn": "standings", "season": true},
	{"name": "Ranks", "kind": "all", "fn": "ranks"},
	{"name": "Head to head", "kind": "pair", "fn": "head_to_head"},
	{"name": "Profile", "kind": "single", "fn": "driver_profile"},
]

var report_picker := OptionButton.new()
var event_picker := OptionButton.new()
var pair_box := HFlowContainer.new()
var board_picker := OptionButton.new()
var driver_a := OptionButton.new()
var driver_b := OptionButton.new()
var single_pick := OptionButton.new()   # any driver, for the Profile report
var season_pick := OptionButton.new()   # season filter for the season-aware reports
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
	season_pick.item_selected.connect(_on_param_changed)
	bar.add_child(season_pick)
	single_pick.custom_minimum_size = Vector2(240, 0)
	single_pick.item_selected.connect(_on_param_changed)
	bar.add_child(single_pick)
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
		board_picker.add_item(LeagueSettings.label("%s %s" % [b[0], b[1]]))
	if board_picker.item_count > 0:
		board_picker.select(0)
	_fill_drivers()
	# seasons, newest first; the latest season is preselected the first time
	var keep_season := season_pick.get_item_text(season_pick.selected) if season_pick.selected >= 0 else ""
	season_pick.clear()
	var seasons := Elo.seasons()
	seasons.reverse()
	for s in seasons:
		season_pick.add_item(s)
	season_pick.add_item("All seasons")
	season_pick.select(0)
	for i in season_pick.item_count:
		if season_pick.get_item_text(i) == keep_season:
			season_pick.select(i)
	var keep := single_pick.get_item_text(single_pick.selected) if single_pick.selected >= 0 else ""
	single_pick.clear()
	var names := Elo.known_names()
	names.sort_custom(func(a, b): return a.to_lower() < b.to_lower())
	for n in names:
		single_pick.add_item(n)
		if n == keep:
			single_pick.select(single_pick.item_count - 1)
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
	single_pick.visible = rep["kind"] == "single"
	season_pick.visible = rep.get("season", false)
	Reports.season = ""
	if season_pick.visible and season_pick.selected >= 0 and season_pick.get_item_text(season_pick.selected) != "All seasons":
		Reports.season = season_pick.get_item_text(season_pick.selected)

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
			if single_pick.selected < 0:
				_message("No drivers yet. Confirm a result file first.")
				return
			tables = Reports.driver_profile(single_pick.get_item_text(single_pick.selected))
		_:
			tables = Reports.call(rep["fn"])

	if tables.is_empty():
		_message("Nothing to show yet. Confirm a result file, or press Recompute all.")
		return
	shown = tables
	_clear(out_tabs)
	for t in tables:
		out_tabs.add_child(TableView.build(t))
		out_tabs.set_tab_title(out_tabs.get_tab_count() - 1, LeagueSettings.label(t["title"]))


# ---------- Excel export of the report on screen ----------
func _export() -> void:
	if shown.is_empty():
		notice.emit("Nothing to export in this report.")
		return
	var sheets := []
	for t in shown:
		sheets.append({"name": LeagueSettings.label(t["title"]), "headers": t["headers"], "rows": t["rows"]})
	var report_name: String = REPORTS[report_picker.selected]["name"]
	if Reports.season != "":
		report_name += " " + Reports.season
	var dir := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/lmu_%s_%s.xlsx" % [dir, report_name.to_lower().replace(" ", "_"), stamp]
	var err := Elo.write_xlsx(path, sheets)
	if err == OK:
		notice.emit("Exported: " + path)
		OS.shell_open(dir)
	else:
		notice.emit("Export failed (error %d)" % err)
