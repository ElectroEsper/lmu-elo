class_name ImportView
extends VBoxContainer
## "Review" screen and the import of result files: dropped files are copied in, the user says
## whether they are league results or training data, and each new league file is reviewed here
## (order, names, league name) before it is rated. Training files are stored straight away.
## The main screen (review_screen.gd) hands the dropped .xml files to start_files().

var shell: Node   # the main screen: status bar, progress, background work, show_view, data_changed

var draft := {}
var drop_hint := VBoxContainer.new()   # shown while no file is loaded
var grid_check := CheckBox.new()
var warnings := VBoxContainer.new()
var tabs := TabContainer.new()
var confirm_btn := Button.new()
var skip_btn := Button.new()
var auto_btn := Button.new()
var type_dialog := AcceptDialog.new()   # league or training? asked every time files are dropped
var drop_note := ""            # files that could not be read at drop time, repeated in the summary
var pending: Array = []        # dropped files waiting for the league / training answer
var queue: Array = []          # league files still to review in this batch
var batch_active := false
var batch := {"total": 0, "rated": 0, "updated": 0, "skipped": 0, "suspects": {}, "practice": [], "unreadable": [], "empty": []}


func _ready() -> void:
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
	add_child(drop_hint)
	grid_check.text = "No quali file: use grid positions as quali"
	add_child(grid_check)
	add_child(warnings)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	var confirm_row := HFlowContainer.new()
	add_child(confirm_row)
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

	type_dialog.title = "What are these files?"
	type_dialog.ok_button_text = "League results"
	type_dialog.add_button("Training data", false, "training")
	type_dialog.add_cancel_button("Cancel")
	type_dialog.confirmed.connect(_start_batch.bind("league"))
	type_dialog.custom_action.connect(_on_type_action)
	type_dialog.canceled.connect(func(): pending.clear())
	add_child(type_dialog)
	_rebuild()


# ---------- Loading ----------
# One file, several files or whole folders can be dropped. Files are handled oldest first
# (their names start with a timestamp), after asking whether they are league or training data.
# Called by the main screen with the dropped result files (folders already expanded).
func start_files(paths: Array) -> void:
	paths.sort_custom(func(a, b): return str(a).get_file() < str(b).get_file())
	# Copied in right away: files dragged straight out of a .zip (or from a cloud folder) can be
	# temporary copies that are gone by the time League / Training is picked.
	var staged := _stage(paths)
	paths = staged["paths"]
	drop_note = _unreadable_note(staged["unreadable"]) if not staged["unreadable"].is_empty() else ""
	if paths.is_empty():
		shell.set_status(_unreadable_note(staged["unreadable"]))
		return
	if not staged["unreadable"].is_empty():
		shell.set_status(_unreadable_note(staged["unreadable"]))
	pending = paths
	type_dialog.dialog_text = "%d file(s) dropped (%s to %s).\n\nLeague results are rated: their drivers feed ratings, profiles and predictions.\nTraining data only feeds track and car-model data: no driver is rated or stored." % [
		paths.size(), str(paths[0]).get_file(), str(paths[paths.size() - 1]).get_file()]
	type_dialog.popup_centered()


const INCOMING := "user://incoming"


# Copies dropped result files into user://incoming (cleared first). Returns {"paths": copies,
# "unreadable": [file names that could not be read]}. Same-named files from different folders
# each get their own subfolder, so none overwrites another.
func _stage(paths: Array) -> Dictionary:
	if DirAccess.dir_exists_absolute(INCOMING):
		_clear_dir(INCOMING)
	DirAccess.make_dir_recursive_absolute(INCOMING)
	var out := []
	var bad := []
	var used := {}
	for src in paths:
		var fname: String = str(src).get_file()
		var dir := INCOMING
		var n := 2
		while used.has(dir + "/" + fname):
			dir = "%s/%d" % [INCOMING, n]
			n += 1
		DirAccess.make_dir_recursive_absolute(dir)
		var dst := dir + "/" + fname
		if not FileAccess.file_exists(str(src)) or DirAccess.copy_absolute(str(src), dst) != OK:
			bad.append(fname)
			continue
		used[dst] = true
		out.append(dst)
	return {"paths": out, "unreadable": bad}


func _clear_dir(path: String) -> void:
	for sub in DirAccess.get_directories_at(path):
		_clear_dir(path + "/" + sub)
		DirAccess.remove_absolute(path + "/" + sub)
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path + "/" + f)


func _unreadable_note(names: Array) -> String:
	return "Could not read %d file(s): %s. If they were dragged straight out of a .zip, extract the zip first and drop the extracted files; files in a cloud folder (OneDrive...) must be downloaded to the computer." % [
		names.size(), ", ".join(PackedStringArray(names))]


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
	batch = {"total": paths.size(), "rated": 0, "updated": 0, "skipped": 0, "suspects": {}, "practice": [], "unreadable": [], "empty": []}
	batch_active = true
	_next_in_queue()


# Training files: track and car-model data only, saved without any driver information.
func _import_training(paths: Array) -> void:
	var added := 0
	var known := 0
	var unusable := PackedStringArray()
	var practice := PackedStringArray()
	var unreadable := []
	for i in paths.size():
		shell.progress(i, paths.size(), "Reading training file %d of %d..." % [i + 1, paths.size()])
		var path: String = paths[i]
		var verdict: String = await shell.in_background(func(): return Elo.import_training(path))
		match verdict:
			"added":
				added += 1
			"duplicate":
				known += 1
			"practice only":
				practice.append(str(paths[i]).get_file())
			"unreadable":
				unreadable.append(str(paths[i]).get_file())
			_:
				unusable.append(str(paths[i]).get_file())
	var text := "Training data: %d added, %d already imported." % [added, known]
	if not unusable.is_empty():
		text += "\nNo usable lap data (too few laps): " + ", ".join(unusable)
	if not practice.is_empty():
		text += "\nSkipped, practice or warm-up only: " + ", ".join(practice)
	if not unreadable.is_empty():
		text += "\n" + _unreadable_note(unreadable)
	if drop_note != "":
		text += "\n" + drop_note
		drop_note = ""
	shell.progress_done()
	shell.set_status(text)
	shell.data_changed()


# League files: each new file opens in the review screen. Files that were already rated are
# not rated again; they only get their stats and lap data completed if those are missing.
func _next_in_queue() -> void:
	while not queue.is_empty():
		var path: String = queue.pop_front()
		shell.progress(batch["total"] - queue.size() - 1, batch["total"], "Checking %s (%d left)..." % [path.get_file(), queue.size()])
		var grid_q := grid_check.button_pressed
		var d: Dictionary = await shell.in_background(func(): return Elo.build_draft(path, grid_q))
		if d.get("unreadable", false):
			batch["unreadable"].append(path.get_file())
			continue
		if not Elo.has_sessions(d):   # practice / warm-up only (or no usable session): never rated
			batch["practice" if d.get("practice_only", false) else "empty"].append(path.get_file())
			continue
		if d["duplicate"]:
			if Elo.event_lacks_stats(d) and Elo.attach_stats(d):
				batch["updated"] += 1
			else:
				batch["skipped"] += 1
			shell.set_status("Checking files... %d left." % queue.size())
			await get_tree().process_frame
			continue
		shell.busy = false   # waiting for the review: the bar stays as a batch counter
		draft = d
		shell.show_view("review")
		_rebuild()
		skip_btn.visible = true
		auto_btn.visible = not queue.is_empty()
		shell.set_status("File %d of %d: %s" % [batch["total"] - queue.size(), batch["total"], d["file"]])
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
		if draft.has("league_name"):
			var err := Elo.rename_draft(draft, _league_file_name())
			if err != "":
				shell.set_status(err + " Pick another round or series.")
				return
		_note_suspects(draft)
		Elo.confirm_draft(draft)
		batch["rated"] += 1
		draft = {}
	skip_btn.visible = false
	auto_btn.visible = false
	confirm_btn.disabled = true
	while not queue.is_empty():
		var path: String = queue.pop_front()
		shell.progress(batch["total"] - queue.size() - 1, batch["total"], "Rating %s (%d left)..." % [path.get_file(), queue.size()])
		var grid_q := grid_check.button_pressed
		var d: Dictionary = await shell.in_background(func(): return Elo.build_draft(path, grid_q))
		if d.get("unreadable", false):
			batch["unreadable"].append(path.get_file())
			continue
		if not Elo.has_sessions(d):   # practice / warm-up only (or no usable session): never rated
			batch["practice" if d.get("practice_only", false) else "empty"].append(path.get_file())
			continue
		if d["duplicate"]:
			if Elo.event_lacks_stats(d) and Elo.attach_stats(d):
				batch["updated"] += 1
			else:
				batch["skipped"] += 1
			continue
		if not Elo.is_league_name(d["file"]):
			# needs a league name: stop here and ask, as the review screen does
			shell.busy = false
			draft = d
			shell.show_view("review")
			_rebuild()
			skip_btn.visible = true
			auto_btn.visible = not queue.is_empty()
			shell.set_status("File %d of %d: %s needs a league name before it is rated." % [batch["total"] - queue.size(), batch["total"], d["file"]])
			return
		_note_suspects(d)
		Elo.confirm_draft(d)
		batch["rated"] += 1
	_finish_batch()


func _finish_batch() -> void:
	shell.progress_done()
	batch_active = false
	skip_btn.visible = false
	auto_btn.visible = false
	draft = {}
	_rebuild()
	var text := "Batch done: %d rated, %d old event(s) completed with stats and lap data, %d skipped or already complete. If any file was older than events you had already rated, press Recompute all." % [
		batch["rated"], batch["updated"], batch["skipped"]]
	if not batch.get("practice", []).is_empty():
		text += "\nSkipped, practice or warm-up only (those sessions are not used): " + ", ".join(PackedStringArray(batch["practice"]))
	if not batch.get("empty", []).is_empty():
		text += "\nSkipped, no race or qualifying result in the file: " + ", ".join(PackedStringArray(batch["empty"]))
	if not batch.get("unreadable", []).is_empty():
		text += "\n" + _unreadable_note(batch["unreadable"])
	if drop_note != "":
		text += "\n" + drop_note
		drop_note = ""
	var sus: Dictionary = batch.get("suspects", {})
	if not sus.is_empty():
		var parts := PackedStringArray()
		for n in sus:
			parts.append("%s (like %s)" % [n, " / ".join(PackedStringArray(sus[n]))])
		text += "\nThese new names look like existing drivers and were kept separate: %s. If any are the same person, use Ratings > Merge drivers." % ", ".join(parts)
	batch["suspects"] = {}
	shell.set_status(text)
	shell.data_changed()


func _on_confirm() -> void:
	if draft.has("league_name"):
		var nm := _league_file_name()
		var err := Elo.rename_draft(draft, nm)
		if err != "":
			shell.set_status(err + " Pick another round or series.")
			return
	var done: String = draft["file"]
	Elo.confirm_draft(draft)
	draft = {}
	if batch_active:
		batch["rated"] += 1
		_next_in_queue()
		return
	_rebuild()
	shell.data_changed()
	var l := Label.new()
	l.text = "Rated and saved: " + done
	warnings.add_child(l)


func _attach_stats() -> void:
	if Elo.attach_stats(draft):
		shell.set_status("Stats attached to the saved event.")
	else:
		shell.set_status("Could not attach stats. Press Recompute all first, then try again.")
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
		var same: String = draft["duplicate_of"]
		l.text = ("Already processed: %s" % same) if Elo.processed.get(draft["hash"], "") == same \
			else ("Same event as %s, already processed under that name." % same)
		row.add_child(l)
		if Elo.event_lacks_stats(draft):
			row.add_child(_btn("Attach stats to the saved event", _attach_stats))
		warnings.add_child(row)
	if draft.get("replaces_training", "") != "":
		var t := Label.new()
		t.text = "This event was imported as training data (%s). Confirming rates it and replaces that training copy." % draft["replaces_training"]
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warnings.add_child(t)
	for n in draft["new_drivers"]:
		var row := HFlowContainer.new()
		var l := Label.new()
		l.text = "New driver '%s'. Same as:" % n
		row.add_child(l)
		for s in draft["new_drivers"][n]:
			row.add_child(_btn("Merge into " + s, _merge.bind(n, s)))
		row.add_child(_btn("Keep as new", _keep_new.bind(n)))
		warnings.add_child(row)
	if not draft["duplicate"] and not Elo.is_league_name(str(draft["file"])):
		warnings.add_child(_league_name_row())
	else:
		confirm_btn.text = "Confirm and rate"
	# Confirm stays disabled for duplicates and unresolved name suspicions
	confirm_btn.disabled = draft["duplicate"] or not draft["new_drivers"].is_empty()


# ---------- League name for files named another way ----------
# The file is saved under "s<season>-<series><round>[-r].xml", the name that gives it its season
# and championship (Standings). Choices live in the draft, so they survive the row being rebuilt.
func _league_name_row() -> Control:
	if not draft.has("league_name"):
		draft["league_name"] = Elo.suggest_league_name(draft)
	var ln: Dictionary = draft["league_name"]
	var box := VBoxContainer.new()
	var intro := Label.new()
	intro.text = "%s does not follow the league naming, so its season and series are unknown. Pick them (suggested from the events around it); the file is saved under the league name." % draft["file"]
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", UiTheme.ACCENT_SOFT)
	box.add_child(intro)
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	box.add_child(row)
	var preview := Label.new()
	row.add_child(_small_label("Season"))
	var season := SpinBox.new()
	season.min_value = 1
	season.max_value = 99
	season.value = int(ln["season"])
	season.value_changed.connect(func(v):
		ln["season"] = int(v)
		_update_league_name(preview))
	row.add_child(season)
	row.add_child(_small_label("Series"))
	var series := OptionButton.new()
	var names: Dictionary = LeagueSettings.get_value("series_names")
	var codes := names.keys()
	if not codes.has(ln["code"]):
		codes.append(ln["code"])
	for c in codes:
		series.add_item("%s (%s)" % [str(names.get(c, str(c).to_upper())), c])
		series.set_item_metadata(series.item_count - 1, str(c))
		if str(c) == str(ln["code"]):
			series.select(series.item_count - 1)
	series.item_selected.connect(func(i):
		ln["code"] = str(series.get_item_metadata(i))
		_update_league_name(preview))
	row.add_child(series)
	row.add_child(_small_label("Round"))
	var rnd := SpinBox.new()
	rnd.min_value = 1
	rnd.max_value = 99
	rnd.value = int(ln["round"])
	rnd.value_changed.connect(func(v):
		ln["round"] = int(v)
		_update_league_name(preview))
	row.add_child(rnd)
	row.add_child(preview)
	_update_league_name(preview)
	return box


func _league_file_name() -> String:
	var ln: Dictionary = draft["league_name"]
	return Elo.league_name(int(ln["season"]), str(ln["code"]), int(ln["round"]), draft["orders"].has("race"))


func _update_league_name(preview: Label) -> void:
	var nm := _league_file_name()
	var taken := Elo.name_taken(nm)
	preview.text = "-> %s%s" % [nm, "  (already used by another event)" if taken else ""]
	preview.add_theme_color_override("font_color", UiTheme.driver_grade_color(1) if taken else UiTheme.TEXT)
	confirm_btn.text = "Confirm as %s" % nm


func _small_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = "Muted"
	return l


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


# Batch auto-confirm keeps similar names separate; remember them for the end-of-batch message
func _note_suspects(d: Dictionary) -> void:
	for n in d["new_drivers"]:
		if not batch.has("suspects"):
			batch["suspects"] = {}
		batch["suspects"][n] = d["new_drivers"][n]
	d["new_drivers"].clear()


func _clear(container: Node) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()


func _btn(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b
