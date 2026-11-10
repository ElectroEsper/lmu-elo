class_name AppPaths
extends RefCounted
## Where Grid Ledger keeps its files: Documents/Grid Ledger/ with
##   Data/      ratings, events, archived results, track profiles, forecasts, settings
##   Graphics/  saved images (s6_r4/...: season 6, round 4)
##   Backups/   backup zips, and the data set aside by a restore
##   Exports/   Excel files
## On the first start of this version, data from Godot's user data folder (AppData on Windows) is
## copied into Data/ (the old copy is left where it was) and a note (MOVED_NOTE) is left there, so
## it is never copied again: deleting Data/ to start fresh must not bring the old data back. The tests (data folder LMU_Elo_tests),
## and systems where Documents is missing or cannot be written, use Godot's user data folder.

const FOLDER := "Grid Ledger"
const OLD_GRAPHICS := "LMU_Elo graphics"   # where earlier versions saved images (in Documents)
const TEST_DIR_NAME := "LMU_Elo_tests"
const MOVED_NOTE := "MOVED TO DOCUMENTS.txt"   # in the old folder: its data was copied to Documents once
## Godot's own folders in the user data folder: never copied, backed up or restored
const GODOT_DIRS := ["logs", "shader_cache", "objectdb_snapshots", "vulkan"]
## Folders that sit next to the data when data and root are the same folder (tests, fallback)
const SIDE_DIRS := ["Data", "Graphics", "Backups", "Exports", "incoming", "test_tmp", OLD_GRAPHICS]

static var _root := ""
static var _data := ""
## Set when the first start copied data over: the folder it came from
static var migrated_from := ""
## Set when Documents could not be used: why (the user data folder is used instead)
static var fallback_reason := ""


static func root() -> String:
	_setup()
	return _root


## The data folder: elo.json, events/, xml/, tracks/, forecasts/, settings.
static func data() -> String:
	_setup()
	return _data


## A path inside the data folder ("events/x.json").
static func file(rel: String) -> String:
	return data().path_join(rel)


static func graphics() -> String:
	return _sub("Graphics")


static func backups() -> String:
	return _sub("Backups")


static func exports() -> String:
	return _sub("Exports")


static func _sub(name: String) -> String:
	var p := root().path_join(name)
	DirAccess.make_dir_recursive_absolute(p)
	return p


## Data and root share Godot's user data folder (tests, or Documents unusable).
static func in_user_dir() -> bool:
	_setup()
	return _data == "user://"


## Tests only: use `dir` (an absolute folder) as the Grid Ledger folder, without copying anything.
## An empty `dir` goes back to choosing as on start.
static func use_root(dir: String) -> void:
	_root = dir
	_data = dir.path_join("Data") if dir != "" else ""
	if dir != "":
		DirAccess.make_dir_recursive_absolute(_data)


static func _setup() -> void:
	if _data != "":
		return
	var user_dir := OS.get_user_data_dir()
	if user_dir.contains(TEST_DIR_NAME):
		_use_user_dir("")
		return
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs == "":
		_use_user_dir("")   # (Linux without xdg-user-dirs): quietly the user data folder
		return
	var root_dir := docs.path_join(FOLDER)
	var data_dir := root_dir.path_join("Data")
	if not _writable(data_dir):
		_use_user_dir("Documents/%s could not be written (is a folder protection blocking it?)." % FOLDER)
		return
	# first start of this version: copy the data over (elo.json last, so a copy that stopped
	# half way is simply done again on the next start), once only
	var first_move := should_move(user_dir, data_dir)
	if first_move:
		if copy_tree(user_dir, data_dir, GODOT_DIRS + SIDE_DIRS, ["elo.json"]) != OK \
				or DirAccess.copy_absolute(user_dir.path_join("elo.json"), data_dir.path_join("elo.json")) != OK:
			_use_user_dir("Your data could not be copied to Documents/%s; it stays where it was." % FOLDER)
			return
		migrated_from = user_dir.simplify_path()
	var old_gfx := docs.path_join(OLD_GRAPHICS)
	var gfx := root_dir.path_join("Graphics")
	if not is_moved(user_dir) and DirAccess.dir_exists_absolute(old_gfx) and not DirAccess.dir_exists_absolute(gfx):
		copy_tree(old_gfx, gfx, [], [])
	# from now on the old folder is done with (also for installs moved before this note existed)
	if FileAccess.file_exists(data_dir.path_join("elo.json")):
		mark_moved(user_dir)
	rename_round_folders(gfx)
	_root = root_dir
	_data = data_dir


static func _use_user_dir(why: String) -> void:
	_root = OS.get_user_data_dir()
	_data = "user://"
	fallback_reason = why


static func _writable(dir: String) -> bool:
	DirAccess.make_dir_recursive_absolute(dir)
	var probe := dir.path_join(".write_test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.close()
	DirAccess.remove_absolute(probe)
	return true


## True when the old folder's data should be copied into `data_dir`: it has data, Documents has
## none yet, and it was never copied before.
static func should_move(user_dir: String, data_dir: String) -> bool:
	return not FileAccess.file_exists(data_dir.path_join("elo.json")) and _has_data(user_dir) and not is_moved(user_dir)


static func is_moved(user_dir: String) -> bool:
	return FileAccess.file_exists(user_dir.path_join(MOVED_NOTE))


## Leaves the note in the old folder (only one that holds data). It says where the data went.
static func mark_moved(user_dir: String) -> void:
	if is_moved(user_dir) or not _has_data(user_dir):
		return
	var f := FileAccess.open(user_dir.path_join(MOVED_NOTE), FileAccess.WRITE)
	if f != null:
		f.store_string("Grid Ledger now keeps its data in Documents/%s/Data.\nThe files in this folder are the old copy, from before the move. Grid Ledger does not use them any more\nand will not copy them again. You can delete this folder once you are happy with your data.\n" % FOLDER)
		f.close()


static func _has_data(dir: String) -> bool:
	return FileAccess.file_exists(dir.path_join("elo.json"))


## Copies the folder `src` into `dst` (created if needed), all levels. Folders named in
## `skip_top_dirs` and files named in `skip_top_files` are left out at the top level only;
## .tmp files are never copied. Returns OK or the first error.
static func copy_tree(src: String, dst: String, skip_top_dirs: Array, skip_top_files: Array) -> Error:
	var todo := [""]
	while not todo.is_empty():
		var rel: String = todo.pop_back()
		var from := src.path_join(rel)
		var to := dst.path_join(rel)
		var err := DirAccess.make_dir_recursive_absolute(to)
		if err != OK:
			return err
		for d in DirAccess.get_directories_at(from):
			if rel == "" and d in skip_top_dirs:
				continue
			todo.append(rel.path_join(d))
		for f in DirAccess.get_files_at(from):
			if f.ends_with(".tmp") or (rel == "" and f in skip_top_files):
				continue
			err = DirAccess.copy_absolute(from.path_join(f), to.path_join(f))
			if err != OK:
				return err
	return OK


## Folder for a round's images: "Season 6", 4 -> "s6_r4".
static func round_folder(season: String, rounds: int) -> String:
	var n := season.trim_prefix("Season").strip_edges()
	var s := ("s" + n) if n.is_valid_int() else season.to_lower().replace(" ", "_").validate_filename()
	return "%s_r%d" % [s, rounds]


## Earlier versions named round folders "Season6_R4": renames them to "s6_r4" (left as they are
## when a folder of the new name is already there).
static func rename_round_folders(gfx: String) -> void:
	if not DirAccess.dir_exists_absolute(gfx):
		return
	var re := RegEx.create_from_string("^Season(\\d+)_R(\\d+)$")
	for d in DirAccess.get_directories_at(gfx):
		var m := re.search(d)
		if m == null:
			continue
		var new_name := "s%s_r%s" % [m.get_string(1), m.get_string(2)]
		if not DirAccess.dir_exists_absolute(gfx.path_join(new_name)):
			DirAccess.rename_absolute(gfx.path_join(d), gfx.path_join(new_name))


# ---------- Backup and restore ----------

## Top-level entries of the data folder that belong to it (not Godot's folders, not the
## Graphics/Backups/Exports folders when everything shares one folder).
static func _data_entries() -> Array:
	var root_abs := ProjectSettings.globalize_path(data())
	var out := []
	for d in DirAccess.get_directories_at(root_abs):
		if not (d in GODOT_DIRS or d in SIDE_DIRS):
			out.append(d)
	for f in DirAccess.get_files_at(root_abs):
		if not f.ends_with(".tmp") and f != ".write_test":
			out.append(f)
	return out


## Zips the data folder into `path`. Safe on a background thread. Returns [error, files written].
static func write_backup(path: String) -> Array:
	var zip := ZIPPacker.new()
	var err := zip.open(path)
	if err != OK:
		return [err, 0]
	var root_abs := ProjectSettings.globalize_path(data())
	var count := 0
	var todo := []
	for e in _data_entries():
		if DirAccess.dir_exists_absolute(root_abs.path_join(e)):
			todo.append(e)
		else:
			zip.start_file(e)
			zip.write_file(FileAccess.get_file_as_bytes(root_abs.path_join(e)))
			zip.close_file()
			count += 1
	while not todo.is_empty():
		var rel: String = todo.pop_back()
		var abs_dir := root_abs.path_join(rel)
		for d in DirAccess.get_directories_at(abs_dir):
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


## What a backup zip holds: {"ok", "error", "prefix" (folder inside the zip that holds the data,
## "" when the files sit at the top), "files", "events", "has_ratings"}.
## Works with zips re-made by hand, where everything sits one or more folders down.
static func inspect_backup(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"ok": false, "error": "The file could not be opened as a zip."}
	var names := zip.get_files()
	zip.close()
	var prefix := ""
	var found := false
	for marker in ["elo.json", "league_settings.json"]:
		for n in names:
			if n.get_file() == marker and (not found or n.length() - marker.length() < prefix.length()):
				prefix = n.substr(0, n.length() - marker.length())
				found = true
		if found:
			break
	if not found:
		return {"ok": false, "error": "This zip is not a Grid Ledger backup (no elo.json or league_settings.json in it)."}
	var files := 0
	var events := 0
	for n in names:
		if n.begins_with(prefix) and _safe_entry(n.trim_prefix(prefix)):
			files += 1
			if n.trim_prefix(prefix).begins_with("events/") and n.ends_with(".json"):
				events += 1
	return {"ok": true, "error": "", "prefix": prefix, "files": files, "events": events,
		"has_ratings": names.has(prefix + "elo.json")}


static func _safe_entry(rel: String) -> bool:
	if rel == "" or rel.ends_with("/") or rel.begins_with("/") or rel.contains(":") or rel.contains("\\"):
		return false
	var parts := rel.split("/")
	if ".." in parts or (parts.size() > 1 and (parts[0] in GODOT_DIRS or parts[0] in SIDE_DIRS)):
		return false
	return not rel.ends_with(".tmp")


## Replaces the data with the backup at `path`. The current data is first moved (not copied) to
## `safety_dir`; if unpacking fails it is moved back. Returns {"ok", "error", "files", "safety"}.
## Restart the app afterwards: what is in memory is the old data.
static func restore_backup(path: String, safety_dir: String) -> Dictionary:
	var info := inspect_backup(path)
	if not info["ok"]:
		return {"ok": false, "error": info["error"], "files": 0, "safety": ""}
	var root_abs := ProjectSettings.globalize_path(data())
	var moved := []
	var base := safety_dir
	var copy_n := 2
	while DirAccess.dir_exists_absolute(safety_dir):   # never mix with an earlier set-aside copy
		safety_dir = "%s (%d)" % [base, copy_n]
		copy_n += 1
	var err := DirAccess.make_dir_recursive_absolute(safety_dir)
	if err == OK:
		for e in _data_entries():
			err = DirAccess.rename_absolute(root_abs.path_join(e), safety_dir.path_join(e))
			if err != OK:
				break
			moved.append(e)
	if err != OK:
		_move_back(moved, safety_dir, root_abs)
		return {"ok": false, "error": "Your current data could not be set aside (error %d); nothing was changed." % err, "files": 0, "safety": ""}
	var zip := ZIPReader.new()
	err = zip.open(path)
	var count := 0
	var prefix: String = info["prefix"]
	if err == OK:
		for n in zip.get_files():
			if not n.begins_with(prefix):
				continue
			var rel := n.trim_prefix(prefix)
			if not _safe_entry(rel):
				continue
			var dst := root_abs.path_join(rel)
			err = DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
			var f := FileAccess.open(dst, FileAccess.WRITE) if err == OK else null
			if f == null:
				err = FAILED if err == OK else err
				break
			f.store_buffer(zip.read_file(n))
			f.close()
			count += 1
		zip.close()
	if err != OK:
		# put things back as they were: drop what was unpacked, return the set-aside data
		for e in _data_entries():
			_remove_tree(root_abs.path_join(e))
		_move_back(moved, safety_dir, root_abs)
		return {"ok": false, "error": "The backup could not be unpacked (error %d); your data was put back as it was." % err, "files": 0, "safety": ""}
	return {"ok": true, "error": "", "files": count, "safety": safety_dir}


static func _move_back(entries: Array, from_dir: String, to_dir: String) -> void:
	for e in entries:
		DirAccess.rename_absolute(from_dir.path_join(e), to_dir.path_join(e))
	if DirAccess.get_files_at(from_dir).is_empty() and DirAccess.get_directories_at(from_dir).is_empty():
		DirAccess.remove_absolute(from_dir)


static func _remove_tree(p: String) -> void:
	if not DirAccess.dir_exists_absolute(p):
		DirAccess.remove_absolute(p)
		return
	for d in DirAccess.get_directories_at(p):
		_remove_tree(p.path_join(d))
	for f in DirAccess.get_files_at(p):
		DirAccess.remove_absolute(p.path_join(f))
	DirAccess.remove_absolute(p)
