class_name DataView
extends VBoxContainer
## "Data & backups" screen: everything that copies, rebuilds or replaces the data, in one place.
## Back up and restore, the penalties file, the Excel export, maintenance (merge drivers, re-read
## the archived results, recompute every rating) and the data folder. The actions themselves live
## in the main screen (review_screen.gd), Elo and the merge dialog; this screen only arranges them.

signal notice(text: String)

var shell: Node   # the main screen
var merge_dialog := DriverMergeDialog.new()
var pen_dialog := FileDialog.new()
var backup_note := Label.new()
var pen_note := Label.new()
var folder_note := Label.new()


func _ready() -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var cols := HBoxContainer.new()
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 12)
	scroll.add_child(cols)
	var left := VBoxContainer.new()
	var right := VBoxContainer.new()
	for c in [left, right]:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.add_theme_constant_override("separation", 10)
		cols.add_child(c)

	var bk := _card(left, "BACK UP AND RESTORE")
	bk.add_child(backup_note)
	_note_style(backup_note)
	var bkr := _row(bk)
	var b := _btn(bkr, "Back up now", func(): await shell._backup(); refresh())
	b.theme_type_variation = "AccentButton"
	_btn(bkr, "Restore backup...", func(): shell._pick_backup()).tooltip_text = \
		"Replace your data with a backup zip. Your current data is set aside in Backups first, then Grid Ledger restarts."
	_btn(bkr, "Open Backups folder", func(): _open(AppPaths.backups()))

	var pf := _card(left, "PENALTIES FILE")
	pf.add_child(pen_note)
	_note_style(pen_note)
	var pfr := _row(pf)
	_btn(pfr, "Save penalties file", _save_penalties)
	_btn(pfr, "Import penalties file...", func():
		pen_dialog.current_dir = AppPaths.exports()
		pen_dialog.popup_centered_ratio(0.6))
	pen_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	pen_dialog.access = FileDialog.ACCESS_FILESYSTEM
	pen_dialog.filters = PackedStringArray(["*.json ; Penalties files"])
	pen_dialog.use_native_dialog = true
	pen_dialog.file_selected.connect(_import_penalties)
	add_child(pen_dialog)

	var ex := _card(left, "EXPORT")
	ex.add_child(_note("Ratings, history and events in one Excel workbook, in Documents/Grid Ledger/Exports. Each report and driver profile also has its own export button."))
	var exr := _row(ex)
	_btn(exr, "Export all to Excel", func(): shell._export())
	_btn(exr, "Open Exports folder", func(): _open(AppPaths.exports()))

	var mt := _card(right, "MAINTENANCE")
	mt.add_child(_note("Merge drivers: two names that are the same person (a typo, a new Steam name). Their history is joined and every rating recomputed."))
	_btn(_row(mt), "Merge drivers...", func(): merge_dialog.open())
	mt.add_child(_note("Re-read archived results: reads the saved result files again so newer lap-data measures are filled in. The app does this by itself after an update when needed."))
	_btn(_row(mt), "Re-read archived XML", func(): await shell._reread(); refresh())
	mt.add_child(_note("Recompute all: rebuilds every rating from the saved events, oldest to newest. The current ratings are backed up first."))
	var rc := _btn(_row(mt), "Recompute all...", func(): shell.confirm_dialog.popup_centered())
	rc.theme_type_variation = "DangerButton"

	var fd := _card(right, "DATA FOLDER")
	fd.add_child(folder_note)
	_note_style(folder_note)
	var fdr := _row(fd)
	_btn(fdr, "Open data folder", func(): _open(AppPaths.data()))
	_btn(fdr, "Open Graphics folder", func(): _open(AppPaths.graphics()))

	merge_dialog.shell = shell
	add_child(merge_dialog)


func refresh() -> void:
	var last := ""
	var last_t := 0
	var dir := AppPaths.backups()
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".zip"):
				var t := FileAccess.get_modified_time(dir.path_join(f))
				if t > last_t:
					last_t = t
					last = f
	var when := ""
	if last_t > 0:
		var local := last_t + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
		when = Time.get_datetime_string_from_unix_time(local, true).left(16)
	backup_note.text = "One .zip with everything: ratings, events, archived results, penalties, track profiles, settings, in Documents/Grid Ledger/Backups. " \
		+ ("Last backup: %s." % when if when != "" else "No backup yet.")
	var ledger := Elo.penalty_ledger()
	pen_note.text = "Kept by itself in the data folder and in Backups, and put back on a race imported again. %s" % \
		("%d race%s with penalties." % [ledger.size(), "" if ledger.size() == 1 else "s"] if not ledger.is_empty() else "No penalties yet.")
	var events := 0
	if DirAccess.dir_exists_absolute(AppPaths.file("events")):
		events = Array(DirAccess.get_files_at(AppPaths.file("events"))).filter(func(f): return str(f).ends_with(".json")).size()
	folder_note.text = "%s · %d events · %d with lap data" % [ProjectSettings.globalize_path(AppPaths.data()), events, Profiles.days.size()]


func _save_penalties() -> void:
	if Elo.penalty_ledger().is_empty():
		notice.emit("No penalties to save yet.")
		return
	var dir := AppPaths.exports()
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/penalties_%s.json" % [dir, Time.get_datetime_string_from_system().replace(":", "-")]
	var err := Elo.export_penalties(path)
	notice.emit("Penalties saved: " + path if err == OK else "Could not save the penalties (error %d)" % err)
	if err == OK:
		OS.shell_open(dir)


func _import_penalties(path: String) -> void:
	var r := Elo.import_penalties(path)
	if r.has("error"):
		notice.emit(str(r["error"]))
		return
	notice.emit("Penalties imported: %d race%s updated%s." % [r["applied"], "" if int(r["applied"]) == 1 else "s",
		", %d waiting for their result file" % r["waiting"] if int(r["waiting"]) > 0 else ""])
	if shell != null and int(r["applied"]) > 0:
		shell.data_changed()
	refresh()


func _open(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	OS.shell_open(dir)


# ---------- builders ----------
func _card(parent: Control, title: String) -> VBoxContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "Card"
	parent.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	var h := Label.new()
	h.text = title
	h.theme_type_variation = "SectionLabel"
	v.add_child(h)
	return v


func _row(parent: Control) -> HFlowContainer:
	var r := HFlowContainer.new()
	r.add_theme_constant_override("h_separation", 6)
	parent.add_child(r)
	return r


func _btn(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	_note_style(l)
	return l


func _note_style(l: Label) -> void:
	l.theme_type_variation = "Muted"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(200, 0)
