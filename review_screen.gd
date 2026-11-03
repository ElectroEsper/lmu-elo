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
	["penalties", "Penalties", "Steward decisions after a race was rated: time penalties, dropped positions, disqualifications. Ratings, ranks and standings are recomputed."],
	["graphics", "Graphics", "Images for social media and the stream: race forecasts, standings, ranks and driver cards. Saved as PNG in Documents/Grid Ledger/Graphics."],
	["settings", "Settings", "League settings: rank names and limits, standings points, grading. Saved in league_settings.json in the app's data folder."],
]

# frame
var status := Label.new()
var clear_btn := Button.new()   # empties the status bar
const STATUS_LINES := 6         # the bar shows at most this many lines; hover it for the rest
var confirm_dialog := ConfirmationDialog.new()
var restore_picker := FileDialog.new()
var restore_dialog := ConfirmationDialog.new()
var restore_path := ""
var restore_safety := ""   # folder in Backups the current data is moved to
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
var graphics_view := GraphicsView.new()
var penalties_view := PenaltiesView.new()
var motec := MotecImport.new()
# The name people see (window title, sidebar). The project's internal name stays "LMU_Elo" in
# project.godot: Godot keeps the data folder under that name, so renaming the app never moves it.
const APP_NAME := "Grid Ledger"
var brand_box := HBoxContainer.new()   # sidebar header: league logo, name, tool name


func _ready() -> void:
	# one theme for the whole window: every screen, dialog, popup and tooltip (see ui_theme.gd)
	# set on the window (tooltips, popups) and on this screen (everything inside it)
	var look := UiTheme.build()
	get_window().theme = look
	theme = look
	get_window().min_size = Vector2i(960, 600)
	get_window().title = APP_NAME
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
	# header like the top of every graphic: league logo, league name in the accent, the tool's name
	nav.add_child(brand_box)
	_fill_brand()
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
		"Ratings, history and events in one workbook, saved to Documents/Grid Ledger/Exports."))
	nav.add_child(_side_btn("Re-read archived XML", _reread,
		"Read the archived result files again, so newer lap-data measures are filled in."))
	nav.add_child(_side_btn("Back up data", _backup,
		"Save everything (ratings, events, archived results, track profiles, settings) in one .zip in Documents/Grid Ledger/Backups."))
	nav.add_child(_side_btn("Restore backup...", _pick_backup,
		"Replace your data with a backup zip. Your current data is set aside in Backups first, then Grid Ledger restarts."))

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
	status.text = _start_message()
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
	graphics_view.shell = self
	penalties_view.shell = self
	for v in [import_view, ratings_view, driver_view, reports_view, profiles_view, predict_view, penalties_view, graphics_view, settings_view]:
		v.size_flags_vertical = Control.SIZE_EXPAND_FILL
		root.add_child(v)
	for v in [driver_view, reports_view, profiles_view, predict_view, penalties_view, graphics_view, settings_view]:
		v.notice.connect(set_status)
	settings_view.saved.connect(data_changed)
	settings_view.saved.connect(_restyle)
	add_child(motec)

	# recompute confirmation
	confirm_dialog.dialog_text = "Rebuild every rating from the saved events, oldest to newest?\nThe current ratings are backed up first."
	confirm_dialog.confirmed.connect(_recompute)
	add_child(confirm_dialog)
	restore_picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	restore_picker.access = FileDialog.ACCESS_FILESYSTEM
	restore_picker.filters = PackedStringArray(["*.zip ; Backup zips"])
	restore_picker.title = "Pick a backup to restore"
	restore_picker.use_native_dialog = true
	restore_picker.file_selected.connect(_confirm_restore)
	add_child(restore_picker)
	restore_dialog.title = "Restore backup"
	restore_dialog.ok_button_text = "Restore and restart"
	restore_dialog.confirmed.connect(_restore)
	add_child(restore_dialog)

	show_view("review")
	get_window().files_dropped.connect(_on_files_dropped)


# First line in the status bar: where the data is (when that changed or is unusual), load problems.
func _start_message() -> String:
	var lines := []
	if AppPaths.migrated_from != "":
		lines.append("Your data now lives in %s (copied from %s, where the old copy was left as it was)." % [AppPaths.root(), AppPaths.migrated_from])
	if AppPaths.fallback_reason != "":
		lines.append(AppPaths.fallback_reason + " Data is kept in " + OS.get_user_data_dir() + ".")
	if Elo.load_error != "":
		lines.append(Elo.load_error)
	return "\n".join(lines) if not lines.is_empty() else "Ready."


# ---------- Screens ----------
func show_view(view: String) -> void:
	for v in VIEWS:
		if v[0] == view:
			view_title.text = v[1]
			view_sub.text = v[2]
			nav_buttons[v[0]].button_pressed = true   # the button group releases the others
	var screens := {"review": import_view, "ratings": ratings_view, "drivers": driver_view, "reports": reports_view,
		"profiles": profiles_view, "predict": predict_view, "penalties": penalties_view, "graphics": graphics_view, "settings": settings_view}
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
func _fill_brand() -> void:
	for c in brand_box.get_children():
		brand_box.remove_child(c)
		c.queue_free()
	brand_box.add_theme_constant_override("separation", 10)
	var path := str(LeagueSettings.get_value("brand_logo"))
	if path != "" and FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null and not img.is_empty():
			var logo := TextureRect.new()
			logo.texture = ImageTexture.create_from_image(img)
			logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			logo.custom_minimum_size = Vector2(46, 46)
			brand_box.add_child(logo)
	var words := VBoxContainer.new()
	words.add_theme_constant_override("separation", 0)
	brand_box.add_child(words)
	var league := str(LeagueSettings.get_value("brand_name")).strip_edges()
	if league != "":
		var ll := Label.new()
		ll.text = league.to_upper()
		ll.add_theme_color_override("font_color", UiTheme.ACCENT)
		ll.add_theme_font_size_override("font_size", 12)
		words.add_child(ll)
	var app := Label.new()
	app.text = APP_NAME
	app.theme_type_variation = "HeaderLarge"
	words.add_child(app)
	if league == "":
		var tagline := Label.new()
		tagline.text = "Le Mans Ultimate league tool"
		tagline.theme_type_variation = "Muted"
		tagline.add_theme_font_size_override("font_size", 12)
		words.add_child(tagline)


# Settings saved: the brand colours, logo and name may have changed, so the look follows.
func _restyle() -> void:
	var look := UiTheme.build()
	get_window().theme = look
	theme = look
	RenderingServer.set_default_clear_color(UiTheme.BG)
	_fill_brand()


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


# ---------- Backup and restore ----------
# One zip with the whole data folder (see app_paths.gd), in Documents/Grid Ledger/Backups.
func _backup() -> void:
	if busy:
		return
	var dir := AppPaths.backups()
	var path := "%s/grid_ledger_backup_%s.zip" % [dir, Time.get_datetime_string_from_system().replace(":", "-")]
	progress(0, 1, "Backing up...")
	var result: Array = await in_background(func(): return AppPaths.write_backup(path))
	progress_done()
	if result[0] == OK:
		status.text = "Backed up %d files to %s" % [result[1], path]
		OS.shell_open(dir)
	else:
		status.text = "Backup failed (error %d)." % result[0]


# Restore: pick a zip, check it, confirm, set the current data aside, unpack, restart.
func _pick_backup() -> void:
	if busy:
		status.text = "Wait until the files being read are done, then restore."
		return
	restore_picker.current_dir = AppPaths.backups()
	restore_picker.popup_centered_ratio(0.6)


func _confirm_restore(path: String) -> void:
	var info := AppPaths.inspect_backup(path)
	if not info["ok"]:
		status.text = "Not restored: " + info["error"]
		return
	restore_path = path
	restore_safety = "Before restore " + Time.get_datetime_string_from_system().replace(":", "-").replace("T", " ")
	var local := FileAccess.get_modified_time(path) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var modified := Time.get_datetime_string_from_unix_time(local, true).left(16)
	restore_dialog.dialog_text = ("Replace your current data with this backup?\n\n%s\nmade %s, %d files%s\n\n"
		+ "Your current data is not deleted: it is moved to Backups/%s first.\nGrid Ledger restarts when the restore is done.") \
		% [path.get_file(), modified, info["files"],
		"" if info["has_ratings"] else " (no ratings file: they are rebuilt with Recompute all)", restore_safety]
	restore_dialog.popup_centered()


func _restore() -> void:
	var safety := AppPaths.backups().path_join(restore_safety)
	var r := AppPaths.restore_backup(restore_path, safety)
	if not r["ok"]:
		status.text = "Not restored: " + r["error"]
		return
	# everything in memory is the old data: start again on the restored files
	OS.set_restart_on_exit(true, OS.get_cmdline_args())
	get_tree().quit()


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
	var dir := AppPaths.exports()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/lmu_ratings_%s.xlsx" % [dir, stamp]
	var err := Elo.export_xlsx(path)
	if err == OK:
		status.text = "Exported: " + path
		OS.shell_open(dir)   # opens the Exports folder
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
