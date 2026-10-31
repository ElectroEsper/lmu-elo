class_name MainScreen
extends Control
## The app's main window: sidebar, the screens, the status bar with its progress bar, and the
## data actions (recompute, export, re-read, backup). Each screen lives in its own script:
##   import_view.gd (Review: dropped result files), ratings_view.gd, profile_view.gd (Drivers),
##   reports_view.gd, profiles_view.gd, predict_view.gd, settings_view.gd; telemetry drops go to
##   motec_import.gd. They talk back through the public functions below: set_status, progress,
##   progress_done, in_background, show_view, data_changed, refresh_profiles.
## Attach to the root Control node of the main scene. Needs the autoloads Elo, Reports, Profiles
## and Predict.

# screens: [key, sidebar label, one line shown under the title]
const VIEWS := [
	["review", "Review", "Check a result file before it is rated. Drop result XMLs, whole folders or MoTeC CSVs anywhere on the window."],
	["ratings", "Ratings", "Elo per class and session. Click a column header to sort."],
	["drivers", "Drivers", "Everything known about one driver: ratings, history, fingerprint and track fit."],
	["reports", "Reports", "League reports. Each one can be exported to Excel."],
	["profiles", "Profiles", "Lap-data fingerprints of drivers, cars and tracks, and the telemetry track layouts."],
	["predict", "Predict", "Monte Carlo forecast of qualifying and the race."],
	["settings", "Settings", "League settings: rank names and limits, standings points, grading. Saved in league_settings.json in the app's data folder."],
]

# frame
var status := Label.new()
var clear_btn := Button.new()   # empties the status bar
const STATUS_LINES := 6         # the bar shows at most this many lines; hover it for the rest
var confirm_dialog := ConfirmationDialog.new()
var nav_buttons := {}               # view key -> sidebar Button
var progress_bar := ProgressBar.new()   # status bar, shown while files are being read
var busy := false                   # an import is running: further drops wait
var view_title := Label.new()
var view_sub := Label.new()

# screens
var import_view := ImportView.new()
var ratings_view := RatingsView.new()
var driver_view := ProfileView.new()
var reports_view := ReportsView.new()
var profiles_view := ProfilesView.new()
var predict_view := PredictView.new()
var settings_view := SettingsView.new()
var motec := MotecImport.new()


func _ready() -> void:
	# one theme for the whole window: every screen, dialog, popup and tooltip (see ui_theme.gd)
	# set on the window (tooltips, popups) and on this screen (everything inside it)
	var look := UiTheme.build()
	get_window().theme = look
	theme = look
	get_window().min_size = Vector2i(960, 600)
	RenderingServer.set_default_clear_color(UiTheme.BG)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := Panel.new()
	bg.theme_type_variation = "Background"
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var frame := HBoxContainer.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_constant_override("separation", 0)
	add_child(frame)

	# sidebar: screens at the top, data actions at the bottom
	var side := PanelContainer.new()
	side.theme_type_variation = "Sidebar"
	side.custom_minimum_size = Vector2(210, 0)
	frame.add_child(side)
	var nav := VBoxContainer.new()
	nav.add_theme_constant_override("separation", 4)
	side.add_child(nav)
	var app := Label.new()
	app.text = "LMU Elo"
	app.theme_type_variation = "HeaderLarge"
	nav.add_child(app)
	var tagline := Label.new()
	tagline.text = "Le Mans Ultimate league tool"
	tagline.theme_type_variation = "Muted"
	tagline.add_theme_font_size_override("font_size", 12)
	nav.add_child(tagline)
	nav.add_child(_gap(18))
	nav.add_child(_section("SCREENS"))
	var group := ButtonGroup.new()
	for v in VIEWS:
		var b := Button.new()
		b.text = v[1]
		b.theme_type_variation = "NavButton"
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(show_view.bind(v[0]))
		nav.add_child(b)
		nav_buttons[v[0]] = b
	var push := Control.new()
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	nav.add_child(push)
	nav.add_child(_section("DATA"))
	nav.add_child(_side_btn("Recompute all...", confirm_dialog.popup_centered,
		"Rebuild every rating from the saved events, oldest to newest."))
	nav.add_child(_side_btn("Export all to Excel", _export,
		"Ratings, history and events in one workbook, saved to Documents."))
	nav.add_child(_side_btn("Re-read archived XML", _reread,
		"Read the archived result files again, so newer lap-data measures are filled in."))
	nav.add_child(_side_btn("Back up data", _backup,
		"Save everything (ratings, events, archived results, track profiles, settings) in one .zip in Documents."))

	# main column: title, the screen, status bar
	var main := VBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 0)
	frame.add_child(main)
	var head := MarginContainer.new()
	_margins(head, 24, 18, 24, 10)
	main.add_child(head)
	var head_box := VBoxContainer.new()
	head_box.add_theme_constant_override("separation", 2)
	head.add_child(head_box)
	view_title.theme_type_variation = "HeaderLarge"
	head_box.add_child(view_title)
	view_sub.theme_type_variation = "Muted"
	view_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head_box.add_child(view_sub)
	var body := MarginContainer.new()
	_margins(body, 24, 4, 24, 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(body)
	var root := VBoxContainer.new()
	body.add_child(root)
	var status_bar := PanelContainer.new()
	status_bar.theme_type_variation = "StatusBar"
	main.add_child(status_bar)
	status.theme_type_variation = "Muted"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.text = "Ready." if Elo.load_error == "" else Elo.load_error
	_update_lap_data.call_deferred()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 16)
	status_bar.add_child(status_row)
	status_row.add_child(status)
	progress_bar.custom_minimum_size = Vector2(260, 0)
	progress_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	progress_bar.visible = false
	status_row.add_child(progress_bar)
	status.max_lines_visible = STATUS_LINES
	status.mouse_filter = Control.MOUSE_FILTER_PASS
	clear_btn.text = "Clear"
	clear_btn.theme_type_variation = "SmallButton"
	clear_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	clear_btn.tooltip_text = "Clear these messages."
	clear_btn.visible = false
	clear_btn.pressed.connect(func(): status.text = "")
	status_row.add_child(clear_btn)

	# the screens, one at a time in the body
	import_view.shell = self
	ratings_view.shell = self
	motec.shell = self
	for v in [import_view, ratings_view, driver_view, reports_view, profiles_view, predict_view, settings_view]:
		v.size_flags_vertical = Control.SIZE_EXPAND_FILL
		root.add_child(v)
	for v in [driver_view, reports_view, profiles_view, predict_view, settings_view]:
		v.notice.connect(set_status)
	settings_view.saved.connect(data_changed)
	add_child(motec)

	# recompute confirmation
	confirm_dialog.dialog_text = "Rebuild every rating from the saved events, oldest to newest?\nThe current ratings are backed up first."
	confirm_dialog.confirmed.connect(_recompute)
	add_child(confirm_dialog)

	show_view("review")
	get_window().files_dropped.connect(_on_files_dropped)


# ---------- Screens ----------
func show_view(view: String) -> void:
	for v in VIEWS:
		if v[0] == view:
			view_title.text = v[1]
			view_sub.text = v[2]
			nav_buttons[v[0]].button_pressed = true   # the button group releases the others
	var screens := {"review": import_view, "ratings": ratings_view, "drivers": driver_view, "reports": reports_view,
		"profiles": profiles_view, "predict": predict_view, "settings": settings_view}
	for key in screens:
		screens[key].visible = key == view
	if view != "review":
		screens[view].refresh()


# ---------- Shared by the screens ----------
func set_status(text: String) -> void:
	status.text = text


# Runs `work` (reading and analysing files) on a separate thread while the window keeps
# redrawing, and returns its result. Saving and rating stay on the main thread.
func in_background(work: Callable) -> Variant:
	var t := Thread.new()
	t.start(work)
	while t.is_alive():
		await get_tree().process_frame
	return t.wait_to_finish()


func progress(done: int, total: int, text: String) -> void:
	busy = true
	progress_bar.visible = true
	progress_bar.max_value = maxi(total, 1)
	progress_bar.value = done
	status.text = text


func progress_done() -> void:
	busy = false
	progress_bar.visible = false


func refresh_profiles() -> void:
	if profiles_view.visible:
		profiles_view.refresh()


# After any change to the data: driver history (Profiles) is rebuilt and the screen on display
# is redrawn, so profiles, track fit and predictions never show data from before an import,
# merge or recompute.
func data_changed() -> void:
	Profiles.rebuild()
	for v in [ratings_view, driver_view, reports_view, profiles_view, predict_view]:
		if v.visible:
			v.refresh()


# ---------- Dropped files ----------
# Result XMLs (files or whole folders) go to the Review screen's import; MoTeC CSV exports become
# track profiles.
func _on_files_dropped(files: PackedStringArray) -> void:
	if busy:
		status.text = "Still reading the previous files; drop these again when the progress bar is gone."
		return
	var csv_paths := Elo.collect_files(files, ".csv")
	var paths := Elo.collect_xml(files)
	if not csv_paths.is_empty():
		motec.start(csv_paths)
		if not paths.is_empty():
			status.text = "The .xml files were ignored: drop MoTeC .csv files and result .xml files separately."
		return
	if paths.is_empty():
		status.text = "No .xml or .csv files found in what you dropped."
		return
	import_view.start_files(paths)


# ---------- Recompute ----------
func _recompute() -> void:
	var s := Elo.rebuild_all()
	if s["count"] == 0:
		status.text = "No saved events to recompute."
		return
	var text := "Recomputed %d events, oldest to newest (%s to %s)." % [s["count"], s["first"], s["last"]]
	if not s["undated"].is_empty():
		text += " No date in file name, used save time: " + ", ".join(s["undated"])
	status.text = text
	data_changed()


# ---------- Backup ----------
# One zip with the whole data folder except Godot's own logs and caches. To restore: close the
# app, unzip into the data folder (Project > Open User Data Folder in the editor), start again.
func _backup() -> void:
	if busy:
		return
	var dir := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var path := "%s/lmu_elo_backup_%s.zip" % [dir, Time.get_datetime_string_from_system().replace(":", "-")]
	progress(0, 1, "Backing up...")
	var result: Array = await in_background(func(): return _write_backup(path))
	progress_done()
	if result[0] == OK:
		status.text = "Backed up %d files to %s" % [result[1], path]
		OS.shell_open(dir)
	else:
		status.text = "Backup failed (error %d)." % result[0]


# Runs on the background thread: [error, files written]
static func _write_backup(path: String) -> Array:
	var zip := ZIPPacker.new()
	var err := zip.open(path)
	if err != OK:
		return [err, 0]
	var count := 0
	var todo := [""]
	var root := ProjectSettings.globalize_path("user://")
	while not todo.is_empty():
		var rel: String = todo.pop_back()
		var abs_dir := root.path_join(rel)
		for d in DirAccess.get_directories_at(abs_dir):
			if rel == "" and d in ["logs", "shader_cache", "objectdb_snapshots", "vulkan"]:
				continue
			todo.append(rel.path_join(d))
		for f in DirAccess.get_files_at(abs_dir):
			if f.ends_with(".tmp"):
				continue
			zip.start_file(rel.path_join(f))
			zip.write_file(FileAccess.get_file_as_bytes(abs_dir.path_join(f)))
			zip.close_file()
			count += 1
	zip.close()
	return [OK, count]


# On start: if the lap-data reader was improved since the events were saved, re-read the
# archived results once in the background (nothing is rated again).
func _update_lap_data() -> void:
	var n := Elo.stale_fingerprints()
	if n == 0 or busy:
		return
	await _reread("Lap data updated for %d events (new measurements from your archived results)." % n)


func _reread(done_text := "") -> void:
	if busy:
		return
	var files := []
	if DirAccess.dir_exists_absolute(Elo.XML_DIR):
		for f in DirAccess.get_files_at(Elo.XML_DIR):
			if f.ends_with(".xml"):
				files.append("%s/%s" % [Elo.XML_DIR, f])
	var n := 0
	for i in files.size():
		progress(i, files.size(), "Re-reading archived results %d of %d..." % [i + 1, files.size()])
		var path: String = files[i]
		var d: Dictionary = await in_background(func(): return Elo.build_draft(path))
		if Elo.attach_stats(d):   # saving stays on the main thread
			n += 1
	progress_done()
	status.text = done_text if done_text != "" else "Refreshed %d events." % n
	data_changed()


# ---------- Excel export (current ratings) ----------
func _export() -> void:
	if Elo.boards().is_empty():
		status.text = "Nothing to export yet."
		return
	var dir := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/lmu_ratings_%s.xlsx" % [dir, stamp]
	var err := Elo.export_xlsx(path)
	if err == OK:
		status.text = "Exported: " + path
		OS.shell_open(dir)   # opens the Documents folder
	else:
		status.text = "Export failed (error %d)" % err


# ---------- Small builders ----------
func _btn(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b


func _side_btn(text: String, action: Callable, tip: String) -> Button:
	var b := _btn(text, action)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = tip
	return b


func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = "SectionLabel"
	return l


func _gap(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


func _margins(m: MarginContainer, left: int, top: int, right: int, bottom: int) -> void:
	m.add_theme_constant_override("margin_left", left)
	m.add_theme_constant_override("margin_top", top)
	m.add_theme_constant_override("margin_right", right)
	m.add_theme_constant_override("margin_bottom", bottom)


# Status bar upkeep: the Clear button shows only when there is something to clear, and a message
# longer than the bar can show is readable in full by hovering it.
var _status_seen := ""

func _process(_delta: float) -> void:
	if status.text == _status_seen:
		return
	_status_seen = status.text
	clear_btn.visible = status.text != "" and status.text != "Ready."
	status.tooltip_text = status.text if status.get_line_count() > STATUS_LINES else ""
