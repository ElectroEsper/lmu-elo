extends Control
## Main screen: review/edit a result file, view ratings, run reports, recompute, export.
## Attach to the root Control node of a new scene.
## Needs elo.gd and reports.gd registered as autoloads named "Elo" and "Reports",
## plus reports_view.gd and rating_chart.gd in the project.
## Drag a result XML onto the window to start.

var draft := {}

# top area
var status := Label.new()
var confirm_dialog := ConfirmationDialog.new()

# review view
var review_box := VBoxContainer.new()
var grid_check := CheckBox.new()
var warnings := VBoxContainer.new()
var tabs := TabContainer.new()
var confirm_btn := Button.new()

# ratings view
var ratings_view := TabContainer.new()

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
var batch := {"total": 0, "rated": 0, "updated": 0, "skipped": 0}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# top bar
	var top_bar := HFlowContainer.new()
	root.add_child(top_bar)
	top_bar.add_child(_btn("Review", _show_view.bind("review")))
	top_bar.add_child(_btn("Ratings", _show_view.bind("ratings")))
	top_bar.add_child(_btn("Reports", _show_view.bind("reports")))
	top_bar.add_child(_btn("Profiles", _show_view.bind("profiles")))
	top_bar.add_child(_btn("Predict", _show_view.bind("predict")))
	top_bar.add_child(_btn("Recompute all", confirm_dialog.popup_centered))
	top_bar.add_child(_btn("Export to Excel", _export))
	top_bar.add_child(_btn("Re-read archived XML", func(): status.text = "Refreshed %d events." % Elo.refresh_from_archive()))
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(status)

	# review view
	review_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(review_box)
	grid_check.text = "No quali file: use grid positions as quali"
	review_box.add_child(grid_check)
	review_box.add_child(warnings)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	review_box.add_child(tabs)
	var confirm_row := HFlowContainer.new()
	review_box.add_child(confirm_row)
	confirm_btn.text = "Confirm and rate"
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

	# ratings view
	ratings_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(ratings_view)

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
	get_window().files_dropped.connect(_on_files_dropped)


# ---------- Views ----------
func _show_view(view: String) -> void:
	review_box.visible = view == "review"
	ratings_view.visible = view == "ratings"
	reports_view.visible = view == "reports"
	profiles_view.visible = view == "profiles"
	predict_view.visible = view == "predict"
	if view == "ratings":
		_draw_ratings()
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
	batch = {"total": paths.size(), "rated": 0, "updated": 0, "skipped": 0}
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
	if profiles_view.visible:
		profiles_view.refresh()
	if predict_view.visible:
		predict_view.refresh()


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
		draft["new_drivers"].clear()
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
		d["new_drivers"].clear()
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
	if profiles_view.visible:
		profiles_view.refresh()
	if predict_view.visible:
		predict_view.refresh()


func _on_confirm() -> void:
	var done: String = draft["file"]
	Elo.confirm_draft(draft)
	draft = {}
	if batch_active:
		batch["rated"] += 1
		_next_in_queue()
		return
	_rebuild()
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
	if draft.is_empty():
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
	var label := Label.new()
	label.text = "%d. %s" % [i + 1, order[i]]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	row.add_child(_btn("Up", _move.bind(order, i, i - 1)))
	row.add_child(_btn("Down", _move.bind(order, i, i + 1)))
	row.add_child(_btn("Drop", _drop.bind(order, i)))
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
	_clear(ratings_view)
	for b in Elo.boards():
		var scroll := ScrollContainer.new()
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(list)
		var legend := Label.new()
		legend.text = "* = still settling (few duels so far)"
		list.add_child(legend)
		var rank := 1
		for row in Elo.leaderboard(b[0], b[1]):
			var mark := " *" if row["d"] < Elo.K_RAMP_DUELS else ""
			var l := Label.new()
			l.text = "%d. %s   %d%s   (%d duels)" % [
				rank, row["name"], roundi(row["r"]), mark, int(row["d"])]
			list.add_child(l)
			rank += 1
		ratings_view.add_child(scroll)
		ratings_view.set_tab_title(ratings_view.get_tab_count() - 1, "%s %s" % [b[0], b[1]])
	if ratings_view.get_tab_count() == 0:
		var empty := Label.new()
		empty.text = "No ratings yet. Confirm a result file first."
		ratings_view.add_child(empty)
		ratings_view.set_tab_title(0, "Empty")


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
	if ratings_view.visible:
		_draw_ratings()
	if reports_view.visible:
		reports_view.refresh()
	if profiles_view.visible:
		profiles_view.refresh()


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
