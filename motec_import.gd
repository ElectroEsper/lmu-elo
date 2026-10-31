class_name MotecImport
extends Node
## Telemetry (MoTeC CSV) import: asks the track and class of each file, then turns each one into
## a track profile (motec_profile.gd, stored by track_store.gd). Owned by the main screen.

var shell: Node   # the main screen (review_screen.gd): status bar, progress, background work

var motec_items: Array = []        # {"path", "course", "class"}
var motec_notes := ""
var motec_dialog := ConfirmationDialog.new()   # asks which track and class each file belongs to
var motec_rows_box := VBoxContainer.new()
var motec_rows: Array = []         # {"path", "track": OptionButton, "class": OptionButton}
var motec_courses: Array = []      # track names seen in result files, alphabetical (picker order)
var motec_classes: Array = []
var motec_info := AcceptDialog.new()


func _ready() -> void:
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


func start(paths: Array) -> void:
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
		shell.set_status("Telemetry not imported: no result files yet.")
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
			class_pick.add_item(LeagueSettings.label(str(motec_classes[i])))
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
	shell.set_status("Telemetry import cancelled.")


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
		shell.set_status("No telemetry imported." + motec_notes)
		return
	_import_motec()


func _import_motec() -> void:
	var saved := 0
	var kept := 0
	var failed := PackedStringArray()
	for i in motec_items.size():
		var item: Dictionary = motec_items[i]
		shell.progress(i, motec_items.size(), "Reading telemetry %d of %d: %s" % [i + 1, motec_items.size(), str(item["path"]).get_file()])
		var path: String = item["path"]
		var prof: Dictionary = await shell.in_background(func(): return MotecProfile.analyze(path))
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
	shell.progress_done()
	var text := "Track profiles: %d saved, %d skipped because a faster lap was already stored." % [saved, kept]
	if not failed.is_empty():
		text += " Could not use: " + ", ".join(failed) + "."
	shell.set_status(text + motec_notes)
	shell.refresh_profiles()
