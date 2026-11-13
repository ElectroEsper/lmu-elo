class_name PenaltiesView
extends VBoxContainer
## "Penalties" screen: steward decisions applied to a race after it was rated. Time penalties
## (re-sorted by laps, then time + penalty), dropped positions and disqualifications. The original
## result stays in the event file; every penalty can be undone. Applying or undoing replays all
## events (Elo.set_race_penalties), so ratings, ranks, standings, grades and reports follow.

signal notice(text: String)

var shell: Node   # the main screen: data_changed() after a change

var event_pick := OptionButton.new()
var class_pick := OptionButton.new()
var table := Tree.new()            # the classification as it stands, penalties included
var driver_pick := OptionButton.new()
var type_pick := OptionButton.new()
var value_spin := SpinBox.new()
var reason_edit := LineEdit.new()
var preview := Label.new()
var apply_btn := Button.new()
var applied_box := VBoxContainer.new()   # every penalty applied so far, each with Undo

var pen_dialog := FileDialog.new()

const TYPES := [["time", "Time penalty"], ["places", "Drop positions"], ["dsq", "Disqualify"]]


func _ready() -> void:
	add_theme_constant_override("separation", 12)
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 12)
	bar.add_child(_muted("Race"))
	event_pick.custom_minimum_size = Vector2(420, 0)
	event_pick.clip_text = true
	event_pick.item_selected.connect(func(_i):
		_fill_classes()
		_show())
	bar.add_child(event_pick)
	bar.add_child(_muted("Class"))
	class_pick.custom_minimum_size = Vector2(140, 0)
	class_pick.item_selected.connect(func(_i): _show())
	bar.add_child(class_pick)
	add_child(bar)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 20)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(cols)
	# the classification
	table.columns = 6
	table.column_titles_visible = true
	table.hide_root = true
	table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var titles := ["Pos", "Driver", "Laps", "Time / gap", "Status", "Penalties"]
	for i in titles.size():
		table.set_column_title(i, titles[i])
		table.set_column_expand(i, i == 1 or i == 5)
		if i in [0, 2, 3, 4]:
			table.set_column_custom_minimum_width(i, [50, 0, 60, 110, 110][i])
	cols.add_child(table)

	# the form
	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(330, 0)
	form.add_theme_constant_override("separation", 8)
	cols.add_child(form)
	var h := Label.new()
	h.text = "ADD A PENALTY"
	h.theme_type_variation = "HeaderSmall"
	form.add_child(h)
	form.add_child(_muted("Driver"))
	driver_pick.clip_text = true
	driver_pick.item_selected.connect(func(_i): _update_preview())
	form.add_child(driver_pick)
	form.add_child(_muted("Penalty"))
	for t in TYPES:
		type_pick.add_item(t[1])
	type_pick.item_selected.connect(func(_i):
		_type_changed()
		_update_preview())
	form.add_child(type_pick)
	value_spin.min_value = 1
	value_spin.max_value = 600
	value_spin.value = 5
	value_spin.value_changed.connect(func(_v): _update_preview())
	form.add_child(value_spin)
	form.add_child(_muted("Reason (optional)"))
	reason_edit.placeholder_text = "e.g. avoidable contact, T1 lap 3"
	form.add_child(reason_edit)
	preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview.theme_type_variation = "Muted"
	form.add_child(preview)
	apply_btn.text = "Apply penalty"
	apply_btn.theme_type_variation = "AccentButton"
	apply_btn.pressed.connect(_apply)
	form.add_child(apply_btn)
	var note := _muted("Applying or undoing recomputes every rating, rank and the standings. The result as imported is kept, so any penalty can be undone. Lap data (pace, fuel, tyres) is not changed.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form.add_child(note)

	var ah_row := HBoxContainer.new()
	var ah := Label.new()
	ah.text = "APPLIED PENALTIES"
	ah.theme_type_variation = "HeaderSmall"
	ah.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ah_row.add_child(ah)
	var export_btn := Button.new()
	export_btn.text = "Export to Excel"
	export_btn.tooltip_text = "Every penalty (with positions before and after) and the corrected result of each race that has one."
	export_btn.pressed.connect(_export)
	ah_row.add_child(export_btn)
	var save_btn := Button.new()
	save_btn.text = "Save penalties file"
	save_btn.tooltip_text = "Every race's penalties in one file (penalties.json) you can import again later.\nThey are also kept automatically in the data folder and in Backups, and a race imported again after starting over gets its penalties back."
	save_btn.pressed.connect(_save_ledger)
	ah_row.add_child(save_btn)
	var load_btn := Button.new()
	load_btn.text = "Import penalties file..."
	load_btn.tooltip_text = "Apply a saved penalties file. Races already here get its penalties; races not imported yet get them when their result file is imported."
	load_btn.pressed.connect(func():
		pen_dialog.current_dir = AppPaths.exports()
		pen_dialog.popup_centered_ratio(0.6))
	ah_row.add_child(load_btn)
	add_child(ah_row)
	pen_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	pen_dialog.access = FileDialog.ACCESS_FILESYSTEM
	pen_dialog.filters = PackedStringArray(["*.json ; Penalties files"])
	pen_dialog.use_native_dialog = true
	pen_dialog.file_selected.connect(_load_ledger)
	add_child(pen_dialog)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 150)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	applied_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(applied_box)
	add_child(scroll)
	_type_changed()


func refresh() -> void:
	_fill_events()
	_fill_classes()
	_show()


# ---------- pickers ----------
# Rated events with a race result, newest first.
func _fill_events() -> void:
	var keep := str(event_pick.get_item_metadata(event_pick.selected)) if event_pick.selected >= 0 else ""
	event_pick.clear()
	for i in range(Elo.history.size() - 1, -1, -1):
		var h: Dictionary = Elo.history[i]
		var has_race := false
		for c in h["changes"]:
			if c["sess"] == "race":
				has_race = true
				break
		if not has_race:
			continue
		var date := Time.get_date_string_from_unix_time(int(h.get("time", 0))) if int(h.get("time", 0)) > 0 else ""
		var n_pen := Elo.event_penalties(str(h["file"])).size()
		event_pick.add_item("%s  %s  %s%s" % [str(h["file"]).get_basename(), str(h.get("course", "")), date,
			("  (%d penalt%s)" % [n_pen, "y" if n_pen == 1 else "ies"]) if n_pen > 0 else ""])
		event_pick.set_item_metadata(event_pick.item_count - 1, str(h["file"]))
		if str(h["file"]) == keep:
			event_pick.select(event_pick.item_count - 1)


func _fill_classes() -> void:
	var keep := class_pick.get_item_text(class_pick.selected) if class_pick.selected >= 0 else ""
	class_pick.clear()
	var orig := Elo.original_race(_file())
	var classes: Array = orig.get("orders", {}).keys()
	classes.sort()
	for c in classes:
		class_pick.add_item(LeagueSettings.label(str(c)))
		class_pick.set_item_metadata(class_pick.item_count - 1, c)
		if LeagueSettings.label(str(c)) == keep:
			class_pick.select(class_pick.item_count - 1)


func _file() -> String:
	return str(event_pick.get_item_metadata(event_pick.selected)) if event_pick.selected >= 0 else ""


func _cls() -> String:
	return str(class_pick.get_item_metadata(class_pick.selected)) if class_pick.selected >= 0 else ""


func _type() -> String:
	return TYPES[maxi(type_pick.selected, 0)][0]


func _type_changed() -> void:
	value_spin.visible = _type() != "dsq"
	value_spin.suffix = "s" if _type() == "time" else "places"
	value_spin.max_value = 600 if _type() == "time" else 60


# ---------- the classification ----------
func _show() -> void:
	table.clear()
	var root := table.create_item()
	driver_pick.clear()
	var file := _file()
	var cls := _cls()
	if file == "" or cls == "":
		preview.text = "No rated race yet."
		_fill_applied()
		return
	var orig := Elo.original_race(file)
	var pens := Elo.event_penalties(file).filter(func(p): return str(p["cls"]) == cls)
	var stats: Dictionary = orig["stats"].get(cls, {})
	var r := Elo.penalised_order(orig["orders"][cls], stats, pens)
	var adj := {}   # seconds added per driver
	for p in pens:
		if p["type"] == "time":
			adj[p["driver"]] = float(adj.get(p["driver"], 0.0)) + float(p["value"])
	var lead_t := 0.0
	var lead_l := 0
	for n in r["order"]:
		if not r["dsq"].has(n) and not Elo._retired_status(stats.get(n, {}).get("status", "")):
			lead_l = int(stats.get(n, {}).get("laps", 0))
			lead_t = float(stats.get(n, {}).get("time", 0.0)) + float(adj.get(n, 0.0))   # the leader's own penalty counts
			break
	var by_driver := {}
	for p in pens:
		if not by_driver.has(p["driver"]):
			by_driver[p["driver"]] = PackedStringArray()
		by_driver[p["driver"]].append(_describe(p))
	var orig_pos := {}
	for i in orig["orders"][cls].size():
		orig_pos[orig["orders"][cls][i]] = i + 1
	for i in r["order"].size():
		var n: String = r["order"][i]
		var s: Dictionary = stats.get(n, {})
		var it := table.create_item(root)
		it.set_text(0, str(i + 1))
		it.set_text(1, Elo.pretty(n))
		it.set_tooltip_text(1, "In the results file: %s. Finished P%d before penalties." % [n, int(orig_pos.get(n, 0))])
		it.set_text(2, str(int(s.get("laps", 0))))
		var t := float(s.get("time", 0.0))
		var my_adj := float(adj.get(n, 0.0))
		var gap := ""
		if r["dsq"].has(n) or Elo._retired_status(s.get("status", "")):
			gap = "-"
		elif int(s.get("laps", 0)) < lead_l:
			gap = "+%d lap%s" % [lead_l - int(s["laps"]), "" if lead_l - int(s["laps"]) == 1 else "s"]
		elif i == 0 or t <= 0.0:
			gap = _clock(t + my_adj) if t > 0.0 else "-"
		else:
			gap = "+%.3f" % (t + my_adj - lead_t)
		it.set_text(3, gap)
		var status := str(s.get("status", ""))
		it.set_text(4, "DQ" if r["dsq"].has(n) else ("Finished" if status.to_lower().begins_with("finished") else status))
		it.set_text(5, ", ".join(by_driver.get(n, PackedStringArray())))
		if by_driver.has(n):
			for c in 6:
				it.set_custom_color(c, Color("f0b36a"))
		driver_pick.add_item("%s (P%d)" % [Elo.pretty(n), i + 1])
		driver_pick.set_item_metadata(driver_pick.item_count - 1, n)
	_update_preview()
	_fill_applied()


func _describe(p: Dictionary) -> String:
	match str(p["type"]):
		"time":
			return "+%ds" % int(p["value"])
		"places":
			return "-%d place%s" % [int(p["value"]), "" if int(p["value"]) == 1 else "s"]
		"dsq":
			return "DSQ"
	return str(p["type"])


func _clock(t: float) -> String:
	var h := int(t / 3600.0)
	var m := int(fmod(t, 3600.0) / 60.0)
	return ("%d:%02d:%06.3f" % [h, m, fmod(t, 60.0)]) if h > 0 else "%d:%06.3f" % [m, fmod(t, 60.0)]


# ---------- adding ----------
func _new_penalty() -> Dictionary:
	if driver_pick.selected < 0:
		return {}
	return {"id": "%d-%d" % [Time.get_unix_time_from_system(), randi() % 100000], "cls": _cls(),
		"driver": str(driver_pick.get_item_metadata(driver_pick.selected)), "type": _type(),
		"value": 0 if _type() == "dsq" else int(value_spin.value), "reason": reason_edit.text.strip_edges(),
		"at": int(Time.get_unix_time_from_system())}


# What the new penalty would do: every driver whose position changes.
func _update_preview() -> void:
	var p := _new_penalty()
	apply_btn.disabled = p.is_empty()
	if p.is_empty():
		preview.text = ""
		return
	var orig := Elo.original_race(_file())
	var cls := _cls()
	var stats: Dictionary = orig["stats"].get(cls, {})
	var pens := Elo.event_penalties(_file()).filter(func(x): return str(x["cls"]) == cls)
	var before: Array = Elo.penalised_order(orig["orders"][cls], stats, pens)["order"]
	var after_r := Elo.penalised_order(orig["orders"][cls], stats, pens + [p])
	if not after_r["skipped"].is_empty():
		preview.text = "Cannot apply: %s has no finishing time (retired or disqualified)." % Elo.pretty(p["driver"])
		apply_btn.disabled = true
		return
	var after: Array = after_r["order"]
	var moves := PackedStringArray()
	for n in after:
		var a := before.find(n)
		var b := after.find(n)
		if a != b:
			moves.append("%s P%d → P%d" % [Elo.pretty(n), a + 1, b + 1])
	preview.text = ("Result: " + ", ".join(moves) + ".") if not moves.is_empty() else "No change in the order (the gap behind is larger than the penalty)."


func _apply() -> void:
	var p := _new_penalty()
	if p.is_empty():
		return
	var file := _file()
	var pens := Elo.event_penalties(file)
	pens.append(p)
	_save(file, pens, "Applied: %s %s in %s." % [Elo.pretty(p["driver"]), _describe(p), file.get_basename()])
	reason_edit.text = ""


func _undo(file: String, id: String) -> void:
	var pens := Elo.event_penalties(file)
	var gone := pens.filter(func(x): return str(x["id"]) == id)
	pens = pens.filter(func(x): return str(x["id"]) != id)
	var what := ("%s %s" % [Elo.pretty(gone[0]["driver"]), _describe(gone[0])]) if not gone.is_empty() else "penalty"
	_save(file, pens, "Undone: %s in %s." % [what, file.get_basename()])


func _save(file: String, pens: Array, done: String) -> void:
	notice.emit("Recomputing every rating...")
	await get_tree().process_frame
	var problems := Elo.set_race_penalties(file, pens)
	if shell != null:
		shell.data_changed()
	notice.emit(done + (" " + problems if problems != "" else " Ratings, ranks and standings recomputed."))
	refresh()


# ---------- applied penalties, all events ----------
func _fill_applied() -> void:
	for c in applied_box.get_children():
		applied_box.remove_child(c)
		c.queue_free()
	var any := false
	for i in range(Elo.history.size() - 1, -1, -1):
		var file := str(Elo.history[i]["file"])
		for p in Elo.event_penalties(file):
			any = true
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)
			var l := Label.new()
			l.text = "%s  ·  %s  ·  %s %s%s" % [file.get_basename(), LeagueSettings.label(str(p["cls"])), Elo.pretty(str(p["driver"])),
				_describe(p), ("  ·  " + str(p["reason"])) if str(p.get("reason", "")) != "" else ""]
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.clip_text = true
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			row.add_child(l)
			var b := Button.new()
			b.text = "Undo"
			b.pressed.connect(_undo.bind(file, str(p["id"])))
			row.add_child(b)
			applied_box.add_child(row)
	if not any:
		applied_box.add_child(_muted("None yet."))


# ---------- Excel ----------
func export_sheets() -> Array:
	var pen_rows := []
	var res_rows := []
	for h in Elo.history:
		var file := str(h["file"])
		var pens := Elo.event_penalties(file)
		if pens.is_empty():
			continue
		var date := Time.get_date_string_from_unix_time(int(h.get("time", 0))) if int(h.get("time", 0)) > 0 else ""
		var orig := Elo.original_race(file)
		var classes: Array = orig["orders"].keys()
		classes.sort()
		for cls in classes:
			var mine := pens.filter(func(p): return str(p["cls"]) == str(cls))
			if mine.is_empty():
				continue
			var o: Array = orig["orders"][cls]
			var stats: Dictionary = orig["stats"].get(cls, {})
			var r := Elo.penalised_order(o, stats, mine)
			for p in mine:
				pen_rows.append([file.get_basename(), date, str(h.get("course", "")), LeagueSettings.label(str(cls)),
					Elo.pretty(str(p["driver"])), _describe(p), str(p.get("reason", "")),
					Time.get_datetime_string_from_unix_time(int(p.get("at", 0))).replace("T", " ") if int(p.get("at", 0)) > 0 else "",
					o.find(p["driver"]) + 1, r["order"].find(p["driver"]) + 1])
			for i in r["order"].size():
				var n: String = r["order"][i]
				var notes := PackedStringArray()
				for p in mine:
					if p["driver"] == n:
						notes.append(_describe(p))
				var status := "DQ" if r["dsq"].has(n) else str(stats.get(n, {}).get("status", ""))
				res_rows.append([file.get_basename(), LeagueSettings.label(str(cls)), i + 1, Elo.pretty(n), o.find(n) + 1,
					int(stats.get(n, {}).get("laps", 0)), "Finished" if status.to_lower().begins_with("finished") else status, ", ".join(notes)])
	return [
		{"name": "Penalties", "headers": ["Race", "Date", "Track", "Class", "Driver", "Penalty", "Reason", "Applied", "Position before", "Position after"], "rows": pen_rows},
		{"name": "Corrected results", "headers": ["Race", "Class", "Pos", "Driver", "Pos before penalties", "Laps", "Status", "Penalties"], "rows": res_rows},
	]


func _export() -> void:
	var sheets := export_sheets()
	if sheets[0]["rows"].is_empty():
		notice.emit("No penalties to export yet.")
		return
	var dir := AppPaths.exports()
	var path := "%s/lmu_penalties_%s.xlsx" % [dir, Time.get_datetime_string_from_system().replace(":", "-")]
	var err := Elo.write_xlsx(path, sheets)
	if err == OK:
		notice.emit("Exported: " + path)
		OS.shell_open(dir)
	else:
		notice.emit("Export failed (error %d)" % err)


# Every race's penalties in one file, in Exports.
func _save_ledger() -> void:
	if Elo.penalty_ledger().is_empty():
		notice.emit("No penalties to save yet.")
		return
	var dir := AppPaths.exports()
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/penalties_%s.json" % [dir, Time.get_datetime_string_from_system().replace(":", "-")]
	var err := Elo.export_penalties(path)
	if err == OK:
		notice.emit("Penalties saved: " + path)
		OS.shell_open(dir)
	else:
		notice.emit("Could not save the penalties (error %d)" % err)


func _load_ledger(path: String) -> void:
	var r := Elo.import_penalties(path)
	if r.has("error"):
		notice.emit(str(r["error"]))
		return
	notice.emit("Penalties imported: %d race%s updated%s." % [r["applied"], "" if int(r["applied"]) == 1 else "s",
		", %d waiting for their result file" % r["waiting"] if int(r["waiting"]) > 0 else ""])
	if shell != null and int(r["applied"]) > 0:
		shell.data_changed()
	refresh()


func _muted(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = "Muted"
	return l
