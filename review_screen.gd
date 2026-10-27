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
	var paths := Elo.collect_xml(files)
	if paths.is_empty():
		status.text = "No .xml files found in what you dropped."
		return
	paths.sort_custom(func(a, b): return str(a).get_file() < str(b).get_file())
	pending = paths
	type_dialog.dialog_text = "%d file(s) dropped (%s to %s).\n\nLeague results are rated: their drivers feed ratings, profiles and predictions.\nTraining data only feeds track and car-model data: no driver is rated or stored." % [
		paths.size(), str(paths[0]).get_file(), str(paths[paths.size() - 1]).get_file()]
	type_dialog.popup_centered()


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
