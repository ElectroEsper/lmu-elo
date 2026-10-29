extends Control
## Main screen: review/edit a result file, view ratings, run reports, recompute, export.
## Attach to the root Control node of a new scene.
## Needs elo.gd and reports.gd registered as autoloads named "Elo" and "Reports",
## plus reports_view.gd and rating_chart.gd in the project.
## Drag a result XML onto the window to start.

var draft := {}

# screens: [key, sidebar label, one line shown under the title]
const VIEWS := [
	["review", "Review", "Check a result file before it is rated. Drop result XMLs, whole folders or MoTeC CSVs anywhere on the window."],
	["ratings", "Ratings", "Elo per class and session. Click a column header to sort."],
	["drivers", "Drivers", "Everything known about one driver: ratings, history, fingerprint and track fit."],
	["reports", "Reports", "League reports. Each one can be exported to Excel."],
	["profiles", "Profiles", "Lap-data fingerprints of drivers, cars and tracks, and the telemetry track layouts."],
	["predict", "Predict", "Monte Carlo forecast of qualifying and the race."],
]

# frame
var status := Label.new()
var confirm_dialog := ConfirmationDialog.new()
var nav_buttons := {}               # view key -> sidebar Button
var view_title := Label.new()
var view_sub := Label.new()
var drop_hint := VBoxContainer.new()   # shown on Review while no file is loaded

# review view
var review_box := VBoxContainer.new()
var grid_check := CheckBox.new()
var warnings := VBoxContainer.new()
var tabs := TabContainer.new()
var confirm_btn := Button.new()

# ratings view
var ratings_box := VBoxContainer.new()
var ratings_view := TabContainer.new()
var merge_dialog := ConfirmationDialog.new()   # makes two driver names one driver
var merge_from := OptionButton.new()
var merge_into := OptionButton.new()
var merge_new := LineEdit.new()
var merge_list := VBoxContainer.new()          # merges made so far, each with an Undo button

# drivers view: pick any driver and see their profile (incl. track fit)
var driver_view := ProfileView.new()

# reports view
var reports_view := ReportsView.new()
var predict_view := PredictView.new()
var profiles_view := ProfilesView.new()

# batch import
var type_dialog := AcceptDialog.new()

# telemetry (MoTeC CSV) import
var motec_items: Array = []        # {"path", "course", "class"}
var motec_notes := ""
var motec_dialog := ConfirmationDialog.new()   # asks which track and class each file belongs to
var motec_rows_box := VBoxContainer.new()
var motec_rows: Array = []         # {"path", "track": OptionButton, "class": OptionButton}
var motec_courses: Array = []      # track names seen in result files, alphabetical (picker order)
var motec_classes: Array = []
var motec_info := AcceptDialog.new()
var skip_btn := Button.new()
var auto_btn := Button.new()
var pending: Array = []        # dropped files waiting for the league / training answer
var queue: Array = []          # league files still to review in this batch
var batch_active := false
var batch := {"total": 0, "rated": 0, "updated": 0, "skipped": 0, "suspects": {}}


func _ready() -> void:
	# one theme for the whole window: every screen, dialog, popup and tooltip (see ui_theme.gd)
	get_window().theme = UiTheme.build()
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
		b.pressed.connect(_show_view.bind(v[0]))
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
	status.text = "Ready."
	status_bar.add_child(status)

	# review view
	review_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(review_box)
	drop_hint.size_flags_vertical = Control.SIZE_EXPAND_FILL
	drop_hint.alignment = BoxContainer.ALIGNMENT_CENTER
	var hint_big := Label.new()
	hint_big.text = "Drop result files here"
	hint_big.theme_type_variation = "HeaderMedium"
	hint_big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	drop_hint.add_child(hint_big)
	var hint_small := Label.new()
	hint_small.text = "Result XMLs or whole folders: you will be asked whether they are league results or training data.\nMoTeC CSV exports become track profiles."
	hint_small.theme_type_variation = "Muted"
	hint_small.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	drop_hint.add_child(hint_small)
	review_box.add_child(drop_hint)
	grid_check.text = "No quali file: use grid positions as quali"
	review_box.add_child(grid_check)
	review_box.add_child(warnings)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	review_box.add_child(tabs)
	var confirm_row := HFlowContainer.new()
	review_box.add_child(confirm_row)
	confirm_btn.text = "Confirm and rate"
	confirm_btn.theme_type_variation = "AccentButton"
	confirm_btn.disabled = true
	confirm_btn.pressed.connect(_on_confirm)
	confirm_row.add_child(confirm_btn)
	skip_btn.text = "Skip this file"
	skip_btn.visible = false
	skip_btn.pressed.connect(_skip_current)
	confirm_row.add_child(skip_btn)
	auto_btn.text = "Confirm this and all remaining without review"
	auto_btn.visible = false
	auto_btn.pressed.connect(_auto_confirm_rest)
	confirm_row.add_child(auto_btn)

	# ratings view, with the driver merge tool above the tables
	ratings_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(ratings_box)
	var ratings_bar := HFlowContainer.new()
	ratings_bar.add_child(_btn("Merge drivers...", _open_merge))
	ratings_box.add_child(ratings_bar)
	ratings_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ratings_box.add_child(ratings_view)
	_build_merge_dialog()

	# drivers view
	driver_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	driver_view.notice.connect(_on_notice)
	root.add_child(driver_view)

	# reports view
	reports_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	reports_view.notice.connect(_on_notice)
	root.add_child(reports_view)
	
	# profiles view
	profiles_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	profiles_view.notice.connect(_on_notice)
	root.add_child(profiles_view)

	# predict view
	predict_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	predict_view.notice.connect(_on_notice)
	root.add_child(predict_view)

	# recompute confirmation
	confirm_dialog.dialog_text = "Rebuild every rating from the saved events, oldest to newest?\nThe current ratings are backed up first."
	confirm_dialog.confirmed.connect(_recompute)
	add_child(confirm_dialog)

	# league or training? asked every time files are dropped
	type_dialog.title = "What are these files?"
	type_dialog.ok_button_text = "League results"
	type_dialog.add_button("Training data", false, "training")
	type_dialog.add_cancel_button("Cancel")
	type_dialog.confirmed.connect(_start_batch.bind("league"))
	type_dialog.custom_action.connect(_on_type_action)
	type_dialog.canceled.connect(func(): pending.clear())
	add_child(type_dialog)

	# telemetry files: which track and class?
	motec_dialog.title = "Which track and class?"
	motec_dialog.ok_button_text = "Import"
	var motec_layout := VBoxContainer.new()
	var motec_intro := Label.new()
	motec_intro.text = "Pick the track and class of each telemetry file. Only tracks and classes seen in your result files are listed, so the profile is matched to the right track for predictions."
	motec_intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	motec_intro.custom_minimum_size = Vector2(560, 0)
	motec_layout.add_child(motec_intro)
	var motec_scroll := ScrollContainer.new()
	motec_scroll.custom_minimum_size = Vector2(560, 220)
	motec_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	motec_scroll.add_child(motec_rows_box)
	motec_layout.add_child(motec_scroll)
	motec_dialog.add_child(motec_layout)
	motec_dialog.confirmed.connect(_finish_motec)
	motec_dialog.canceled.connect(_cancel_motec)
	add_child(motec_dialog)
	motec_info.title = "Track not known yet"
	add_child(motec_info)

	_show_view("review")
	_rebuild()
	get_window().files_dropped.connect(_on_files_dropped)


# ---------- Views ----------
func _show_view(view: String) -> void:
	for v in VIEWS:
		if v[0] == view:
			view_title.text = v[1]
			view_sub.text = v[2]
			nav_buttons[v[0]].set_pressed_no_signal(true)
	review_box.visible = view == "review"
	ratings_box.visible = view == "ratings"
	driver_view.visible = view == "drivers"
	reports_view.visible = view == "reports"
	profiles_view.visible = view == "profiles"
	predict_view.visible = view == "predict"
	if view == "ratings":
		_draw_ratings()
	elif view == "drivers":
		driver_view.refresh()
	elif view == "reports":
		reports_view.refresh()
	elif view == "profiles":
		profiles_view.refresh()
	elif view == "predict":                
		predict_view.refresh()


func _on_notice(text: String) -> void:
	status.text = text


func _clear(container: Node) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()


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


# ---------- Loading and confirming ----------
# One file, several files or whole folders can be dropped. Files are handled oldest first
# (their names start with a timestamp), after asking whether they are league or training data.
func _on_files_dropped(files: PackedStringArray) -> void:
	var csv_paths := Elo.collect_files(files, ".csv")
	var paths := Elo.collect_xml(files)
	if not csv_paths.is_empty():   # MoTeC telemetry exports become track profiles
		_start_motec(csv_paths)
		if not paths.is_empty():
			status.text = "The .xml files were ignored: drop MoTeC .csv files and result .xml files separately."
		return
	if paths.is_empty():
		status.text = "No .xml or .csv files found in what you dropped."
		return
	paths.sort_custom(func(a, b): return str(a).get_file() < str(b).get_file())
	pending = paths
	type_dialog.dialog_text = "%d file(s) dropped (%s to %s).\n\nLeague results are rated: their drivers feed ratings, profiles and predictions.\nTraining data only feeds track and car-model data: no driver is rated or stored." % [
		paths.size(), str(paths[0]).get_file(), str(paths[paths.size() - 1]).get_file()]
	type_dialog.popup_centered()


# ---------- MoTeC telemetry: track profiles ----------
# Every telemetry file is confirmed by hand: the track is picked from the tracks seen in result
# files (so the profile is attached to the course the predictor uses), and the class from the
# known classes. Both are preselected from the file name when it makes that possible.
func _norm(s: String) -> String:
	return s.replace("_", " ").replace("-", " ").strip_edges().to_lower()


func _guess_track(file_name: String, courses: Array) -> String:
	var info := MotecProfile.guess_from_name(file_name)
	for c in courses:
		if _norm(str(c)) == _norm(str(info.get("track", ""))):
			return str(c)
	var base := _norm(file_name.get_basename())
	for c in courses:   # e.g. "Brno" inside "GO_..._LMP3_Brno_Q"
		if _norm(str(c)).length() >= 3 and base.contains(_norm(str(c))):
			return str(c)
	return ""


func _guess_class(file_name: String, classes: Array) -> String:
	var info := MotecProfile.guess_from_name(file_name)
	for c in classes:
		if _norm(str(c)) == _norm(str(info.get("class", ""))):
			return str(c)
	for token in file_name.get_basename().split("_"):   # any part of the name that is a class
		for c in classes:
			if _norm(str(c)) == _norm(token):
				return str(c)
	return ""


func _start_motec(paths: Array) -> void:
	motec_courses = Profiles.courses().duplicate()
	motec_classes = Profiles.classes().duplicate()
	motec_courses.erase("")
	# alphabetical, ignoring case
	var by_name := func(a, b): return str(a).to_lower() < str(b).to_lower()
	motec_courses.sort_custom(by_name)
	motec_classes.sort_custom(by_name)
	if motec_courses.is_empty() or motec_classes.is_empty():
		motec_info.dialog_text = "No track is known yet.\n\nImport at least one result file (.xml) for this track first, then drop the telemetry again. Telemetry can only be attached to tracks and classes seen in your results."
		motec_info.popup_centered()
		status.text = "Telemetry not imported: no result files yet."
		return
	for c in motec_rows_box.get_children():
		motec_rows_box.remove_child(c)
		c.queue_free()
	motec_rows = []
	for p in paths:
		var file_name := str(p).get_file()
		var row := VBoxContainer.new()
		var label := Label.new()
		label.text = file_name
		row.add_child(label)
		var picks := HBoxContainer.new()
		var track_pick := OptionButton.new()
		track_pick.add_item("Choose the track...")
		var guess := _guess_track(file_name, motec_courses)
		for i in motec_courses.size():
			track_pick.add_item(str(motec_courses[i]))
			if str(motec_courses[i]) == guess:
				track_pick.select(i + 1)
		track_pick.add_item("Not in the list")
		track_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		track_pick.item_selected.connect(func(_i: int): _validate_motec())
		picks.add_child(track_pick)
		var class_pick := OptionButton.new()
		class_pick.add_item("Choose the class...")
		var cls_guess := _guess_class(file_name, motec_classes)
		for i in motec_classes.size():
			class_pick.add_item(str(motec_classes[i]))
			if str(motec_classes[i]) == cls_guess:
				class_pick.select(i + 1)
		class_pick.item_selected.connect(func(_i: int): _validate_motec())
		picks.add_child(class_pick)
		row.add_child(picks)
		row.add_child(HSeparator.new())
		motec_rows_box.add_child(row)
		motec_rows.append({"path": p, "track": track_pick, "class": class_pick})
	_validate_motec()
	motec_dialog.popup_centered()


# "Not in the list" sits after the known tracks
func _is_not_listed(pick: OptionButton) -> bool:
	return pick.selected == motec_courses.size() + 1


# Import stays disabled until every file has a track (or "Not in the list") and a class
func _validate_motec() -> void:
	var complete := not motec_rows.is_empty()
	for r in motec_rows:
		var track_pick: OptionButton = r["track"]
		var class_pick: OptionButton = r["class"]
		if track_pick.selected <= 0:
			complete = false
		elif not _is_not_listed(track_pick) and class_pick.selected <= 0:
			complete = false
	motec_dialog.get_ok_button().disabled = not complete


func _cancel_motec() -> void:
	motec_rows.clear()
	status.text = "Telemetry import cancelled."


func _finish_motec() -> void:
	motec_items = []
	var refused := PackedStringArray()
	for r in motec_rows:
		var track_pick: OptionButton = r["track"]
		var class_pick: OptionButton = r["class"]
		if _is_not_listed(track_pick):
			refused.append(str(r["path"]).get_file())
			continue
		motec_items.append({
			"path": r["path"],
			"course": str(motec_courses[track_pick.selected - 1]),
			"class": str(motec_classes[class_pick.selected - 1]),
		})
	motec_rows.clear()
	motec_notes = ""
	if not refused.is_empty():
		motec_notes = " Not imported (track not in your results yet): " + ", ".join(refused) + "."
		motec_info.dialog_text = "Telemetry needs a track that appears in your result files:\n\n%s\n\nImport a result file (.xml) for that track first, then drop the telemetry again." % "\n".join(refused)
		motec_info.popup_centered()
	if motec_items.is_empty():
		status.text = "No telemetry imported." + motec_notes
		return
	_import_motec()


func _import_motec() -> void:
	var saved := 0
	var kept := 0
	var failed := PackedStringArray()
	for i in motec_items.size():
		var item: Dictionary = motec_items[i]
		status.text = "Reading telemetry %d of %d: %s" % [i + 1, motec_items.size(), str(item["path"]).get_file()]
		await get_tree().process_frame
		var prof := MotecProfile.analyze(item["path"])
		if prof.has("error"):
			failed.append("%s (%s)" % [str(item["path"]).get_file(), prof["error"]])
			continue
		prof["course"] = item["course"]
		prof["class"] = item["class"]
		if TrackStore.save(prof) == "kept":
			kept += 1
		else:
			saved += 1
	motec_items.clear()
	var text := "Track profiles: %d saved, %d skipped because a faster lap was already stored." % [saved, kept]
	if not failed.is_empty():
		text += " Could not use: " + ", ".join(failed) + "."
	status.text = text + motec_notes
	if profiles_view.visible:
		profiles_view.refresh()


func _on_type_action(action: StringName) -> void:
	if action == "training":
		type_dialog.hide()
		_start_batch("training")


func _start_batch(kind: String) -> void:
	var paths := pending.duplicate()
	pending.clear()
	if paths.is_empty():
		return
	if kind == "training":
		_import_training(paths)
		return
	queue = paths
	batch = {"total": paths.size(), "rated": 0, "updated": 0, "skipped": 0, "suspects": {}}
	batch_active = true
	_next_in_queue()


# Training files: track and car-model data only, saved without any driver information.
func _import_training(paths: Array) -> void:
	var added := 0
	var known := 0
	var unusable := PackedStringArray()
	for i in paths.size():
		status.text = "Reading training file %d of %d..." % [i + 1, paths.size()]
		await get_tree().process_frame
		match Elo.import_training(paths[i]):
			"added":
				added += 1
			"duplicate":
				known += 1
			_:
				unusable.append(str(paths[i]).get_file())
	var text := "Training data: %d added, %d already imported." % [added, known]
	if not unusable.is_empty():
		text += " No usable lap data in: " + ", ".join(unusable)
	status.text = text
	_data_changed()


# League files: each new file opens in the review screen. Files that were already rated are
# not rated again; they only get their stats and lap data completed if those are missing.
func _next_in_queue() -> void:
	while not queue.is_empty():
		var path: String = queue.pop_front()
		var d := Elo.build_draft(path, grid_check.button_pressed)
		if d["duplicate"]:
			if Elo.event_lacks_stats(d) and Elo.attach_stats(d):
				batch["updated"] += 1
			else:
				batch["skipped"] += 1
			status.text = "Checking files... %d left." % queue.size()
			await get_tree().process_frame
			continue
		draft = d
		_show_view("review")
		_rebuild()
		skip_btn.visible = true
		auto_btn.visible = not queue.is_empty()
		status.text = "File %d of %d: %s" % [batch["total"] - queue.size(), batch["total"], d["file"]]
		return
	_finish_batch()


func _skip_current() -> void:
	batch["skipped"] += 1
	draft = {}
	_next_in_queue()


# Confirms the file on screen as it is (similar names stay separate drivers), then rates the rest
# of the batch without stopping for review.
func _auto_confirm_rest() -> void:
	if not draft.is_empty():
		_note_suspects(draft)
		Elo.confirm_draft(draft)
		batch["rated"] += 1
		draft = {}
	skip_btn.visible = false
	auto_btn.visible = false
	confirm_btn.disabled = true
	while not queue.is_empty():
		var path: String = queue.pop_front()
		status.text = "Rating %s (%d left)..." % [path.get_file(), queue.size()]
		await get_tree().process_frame
		var d := Elo.build_draft(path, grid_check.button_pressed)
		if d["duplicate"]:
			if Elo.event_lacks_stats(d) and Elo.attach_stats(d):
				batch["updated"] += 1
			else:
				batch["skipped"] += 1
			continue
		_note_suspects(d)
		Elo.confirm_draft(d)
		batch["rated"] += 1
	_finish_batch()


func _finish_batch() -> void:
	batch_active = false
	skip_btn.visible = false
	auto_btn.visible = false
	draft = {}
	_rebuild()
	status.text = "Batch done: %d rated, %d old event(s) completed with stats and lap data, %d skipped or already complete. If any file was older than events you had already rated, press Recompute all." % [
		batch["rated"], batch["updated"], batch["skipped"]]
	var sus: Dictionary = batch.get("suspects", {})
	if not sus.is_empty():
		var parts := PackedStringArray()
		for n in sus:
			parts.append("%s (like %s)" % [n, " / ".join(PackedStringArray(sus[n]))])
		status.text += "\nThese new names look like existing drivers and were kept separate: %s. If any are the same person, use Ratings > Merge drivers." % ", ".join(parts)
	batch["suspects"] = {}
	_data_changed()


func _on_confirm() -> void:
	var done: String = draft["file"]
	Elo.confirm_draft(draft)
	draft = {}
	if batch_active:
		batch["rated"] += 1
		_next_in_queue()
		return
	_rebuild()
	_data_changed()
	var l := Label.new()
	l.text = "Rated and saved: " + done
	warnings.add_child(l)


func _attach_stats() -> void:
	if Elo.attach_stats(draft):
		status.text = "Stats attached to the saved event."
	else:
		status.text = "Could not attach stats. Press Recompute all first, then try again."
	_show_warnings()


# ---------- Review view ----------
func _rebuild() -> void:
	var keep := tabs.current_tab
	_clear(tabs)
	var empty := draft.is_empty()
	drop_hint.visible = empty and not batch_active
	tabs.visible = not empty
	grid_check.visible = not empty
	confirm_btn.visible = not empty
	if empty:
		_show_warnings()
		return
	for sess in draft["orders"]:
		for cls in draft["orders"][sess]:
			var order: Array = draft["orders"][sess][cls]
			var scroll := ScrollContainer.new()
			var list := VBoxContainer.new()
			list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			scroll.add_child(list)
			for i in order.size():
				list.add_child(_row(order, i))
			tabs.add_child(scroll)
			tabs.set_tab_title(tabs.get_tab_count() - 1, "%s %s" % [sess, cls])
	tabs.current_tab = clampi(keep, 0, maxi(tabs.get_tab_count() - 1, 0))
	_show_warnings()


func _row(order: Array, i: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	var pos := Label.new()
	pos.text = "P%d" % (i + 1)
	pos.theme_type_variation = "Muted"
	pos.custom_minimum_size = Vector2(44, 0)
	pos.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(pos)
	var label := Label.new()
	label.text = str(order[i])
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var up := _btn("Up", _move.bind(order, i, i - 1))
	var down := _btn("Down", _move.bind(order, i, i + 1))
	var drop := _btn("Drop", _drop.bind(order, i))
	up.disabled = i == 0
	down.disabled = i == order.size() - 1
	for btn in [up, down, drop]:
		btn.theme_type_variation = "SmallButton"
		btn.focus_mode = Control.FOCUS_NONE
		row.add_child(btn)
	return row


func _show_warnings() -> void:
	_clear(warnings)
	if draft.is_empty():
		confirm_btn.disabled = true
		return
	if draft["duplicate"]:
		var row := HFlowContainer.new()
		var l := Label.new()
		l.text = "Already processed: %s" % Elo.processed[draft["hash"]]
		row.add_child(l)
		if Elo.event_lacks_stats(draft):
			row.add_child(_btn("Attach stats to the saved event", _attach_stats))
		warnings.add_child(row)
	for n in draft["new_drivers"]:
		var row := HFlowContainer.new()
		var l := Label.new()
		l.text = "New driver '%s'. Same as:" % n
		row.add_child(l)
		for s in draft["new_drivers"][n]:
			row.add_child(_btn("Merge into " + s, _merge.bind(n, s)))
		row.add_child(_btn("Keep as new", _keep_new.bind(n)))
		warnings.add_child(row)
	# Confirm stays disabled for duplicates and unresolved name suspicions
	confirm_btn.disabled = draft["duplicate"] or not draft["new_drivers"].is_empty()


func _move(order: Array, from: int, to: int) -> void:
	if to < 0 or to >= order.size():
		return
	order.insert(to, order.pop_at(from))
	_rebuild()


func _drop(order: Array, i: int) -> void:
	order.remove_at(i)
	_rebuild()


func _merge(driver_name: String, into: String) -> void:
	Elo.merge_driver(draft, driver_name, into)
	_rebuild()


func _keep_new(driver_name: String) -> void:
	draft["new_drivers"].erase(driver_name)
	_rebuild()


# ---------- Ratings view ----------
func _draw_ratings() -> void:
	var keep := ratings_view.current_tab
	_clear(ratings_view)
	for b in Elo.boards():
		var rows := []
		var rank := 1
		for row in Elo.leaderboard(b[0], b[1]):
			rows.append([rank, row["name"], roundi(row["r"]), int(row["d"]),
				"Settling" if row["d"] < Elo.K_RAMP_DUELS else ""])
			rank += 1
		ratings_view.add_child(TableView.build({
			"note": "Settling = fewer than %d duels so far, so the rating still moves quickly." % int(Elo.K_RAMP_DUELS),
			"headers": ["#", "Driver", "Rating", "Duels", "Status"],
			"rows": rows,
			"tips": ["Place on the leaderboard.", "", "Elo rating.", "Head-to-head comparisons counted so far.", ""],
		}))
		ratings_view.set_tab_title(ratings_view.get_tab_count() - 1, "%s %s" % [b[0], b[1]])
	if ratings_view.get_tab_count() == 0:
		var empty := Label.new()
		empty.text = "No ratings yet. Confirm a result file first."
		ratings_view.add_child(empty)
		ratings_view.set_tab_title(0, "Empty")
	ratings_view.current_tab = clampi(keep, 0, maxi(ratings_view.get_tab_count() - 1, 0))


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
	_data_changed()


# ---------- After any change to the data ----------
# Driver history (Profiles) is rebuilt and the screen on display is redrawn, so profiles,
# track fit and predictions never show data from before an import, merge or recompute.
func _data_changed() -> void:
	Profiles.rebuild()
	if ratings_box.visible:
		_draw_ratings()
	if driver_view.visible:
		driver_view.refresh()
	if reports_view.visible:
		reports_view.refresh()
	if profiles_view.visible:
		profiles_view.refresh()
	if predict_view.visible:
		predict_view.refresh()


func _reread() -> void:
	status.text = "Refreshed %d events." % Elo.refresh_from_archive()
	_data_changed()


# Batch auto-confirm keeps similar names separate; remember them for the end-of-batch message
func _note_suspects(d: Dictionary) -> void:
	for n in d["new_drivers"]:
		if not batch.has("suspects"):
			batch["suspects"] = {}
		batch["suspects"][n] = d["new_drivers"][n]
	d["new_drivers"].clear()


# ---------- Driver merge ----------
func _build_merge_dialog() -> void:
	merge_dialog.title = "Merge drivers"
	merge_dialog.ok_button_text = "Merge"
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	var intro := Label.new()
	intro.text = "Use this when one person appears under two names, or to rename a driver. All ratings are rebuilt from the saved events afterwards (the current ratings are backed up first), so every past result counts for the merged driver."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(intro)
	var grid := GridContainer.new()
	grid.columns = 2
	var l1 := Label.new()
	l1.text = "Merge this name:"
	grid.add_child(l1)
	grid.add_child(merge_from)
	var l2 := Label.new()
	l2.text = "into this driver:"
	grid.add_child(l2)
	grid.add_child(merge_into)
	var l3 := Label.new()
	l3.text = "or rename to:"
	grid.add_child(l3)
	merge_new.placeholder_text = "new name (leave empty to use the driver above)"
	merge_new.custom_minimum_size = Vector2(280, 0)
	grid.add_child(merge_new)
	box.add_child(grid)
	var made := Label.new()
	made.text = "Merges made so far:"
	box.add_child(made)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520, 140)
	merge_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(merge_list)
	box.add_child(scroll)
	merge_dialog.add_child(box)
	merge_dialog.confirmed.connect(_do_merge)
	add_child(merge_dialog)


func _open_merge() -> void:
	var names := Elo.known_names()
	names.sort_custom(func(a, b): return str(a).to_lower() < str(b).to_lower())
	merge_from.clear()
	merge_into.clear()
	for n in names:
		merge_from.add_item(str(n))
		merge_into.add_item(str(n))
	if merge_into.item_count > 1:
		merge_into.select(1)
	merge_new.text = ""
	_fill_merge_list()
	merge_dialog.popup_centered()


func _fill_merge_list() -> void:
	_clear(merge_list)
	var keys := Elo.aliases.keys()
	keys.sort_custom(func(a, b): return str(a).to_lower() < str(b).to_lower())
	if keys.is_empty():
		var none := Label.new()
		none.text = "none"
		merge_list.add_child(none)
	for a in keys:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "%s  ->  %s" % [a, Elo.aliases[a]]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		row.add_child(_btn("Undo", _undo_merge.bind(str(a))))
		merge_list.add_child(row)


func _do_merge() -> void:
	if merge_from.selected < 0:
		status.text = "No drivers to merge yet."
		return
	var from_name := merge_from.get_item_text(merge_from.selected)
	var into := merge_new.text.strip_edges()
	if into == "" and merge_into.selected >= 0:
		into = merge_into.get_item_text(merge_into.selected)
	var s := Elo.merge_drivers(from_name, into)
	if s.has("error"):
		status.text = "Merge not done: " + str(s["error"])
		return
	status.text = "%s is now %s. Ratings rebuilt from %d events." % [from_name, Elo.resolve(from_name), int(s["count"])]
	_data_changed()


func _undo_merge(alias_name: String) -> void:
	var s := Elo.unmerge_driver(alias_name)
	if s.has("error"):
		status.text = str(s["error"])
		return
	status.text = "%s is a separate driver again. Ratings rebuilt from %d events." % [alias_name, int(s["count"])]
	_fill_merge_list()
	_data_changed()


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
