extends Node
## LMU_Elo test suite. Run it with tests/run_tests.bat (Windows) or tests/run_tests.sh, which
## point Godot at a separate data folder (LMU_Elo_tests) so your real ratings are never touched.
## Checks that need league result files read them from tests/data/xml (not in git: it holds
## driver names); without them those checks are skipped. Exit code 0 = all passed.

const TEST_DIR_NAME := "LMU_Elo_tests"
const DATA := "res://tests/data/xml"

var passed := 0
var failed := 0
var skipped := 0
var tmp := ""   # scratch folder for files made by the tests
var section := ""


func _ready() -> void:
	# never run against the real data folder
	if not OS.get_user_data_dir().contains(TEST_DIR_NAME):
		printerr("Refusing to run: the data folder is %s, not the test one. Start the tests with tests/run_tests.bat or tests/run_tests.sh." % OS.get_user_data_dir())
		get_tree().quit(2)
		return
	print("LMU_Elo tests  (data folder: %s)" % OS.get_user_data_dir())
	_wipe_user_dir()
	tmp = OS.get_user_data_dir().path_join("test_tmp")
	DirAccess.make_dir_recursive_absolute(tmp)
	_test_settings()
	_test_traffic_formula()
	_test_unreadable()
	_test_data_folder()
	_test_menu_order()
	var files := _league_files()
	if files.is_empty():
		_skip("league data", "put your result XMLs in tests/data/xml to run the import, duplicate, naming, training and prediction checks")
	else:
		_test_import(files)
		_test_duplicates(files)
		_test_session_ids(files)
		_test_best_lap_fallback(files)
		_test_practice_only(files)
		_test_league_naming(files)
		_test_training(files)
		_test_profiles_and_grades()
		await _test_predict()
		await _test_forecast_record()
		_test_penalties()
		await _test_season_scenarios()
		_test_ballast()
		await _test_screens()
		_test_backup_restore()
	# a script error the run survived is still a bug in the tool
	var errs := _script_errors()
	if not errs.is_empty():
		print("\nScript errors during the run")
		for e in errs:
			check(false, "Script error", e)
	print("\n%d passed, %d failed, %d skipped" % [passed, failed, skipped])
	get_tree().quit(1 if failed > 0 else 0)


# ---------- helpers ----------
func check(ok: bool, name: String, detail := "") -> void:
	_progress(name)
	if ok:
		passed += 1
		print("  PASS  " + name)
	else:
		failed += 1
		print("  FAIL  " + name + ("  (" + detail + ")" if detail != "" else ""))


func _skip(name: String, why: String) -> void:
	skipped += 1
	_progress(name)
	print("  SKIP  %s: %s" % [name, why])


func _section(title: String) -> void:
	section = title
	_progress("start")
	print("\n" + title)


# Tells the watchdog (tests/watchdog.gd, started by bootstrap.gd) the run is still moving.
func _progress(step: String) -> void:
	var w = get_parent().get("watchdog")
	if w != null:
		w.progress("%s > %s" % [section, step])


func _script_errors() -> Array:
	var w = get_parent().get("watchdog")
	return w.script_errors() if w != null else []


func _league_files() -> Array:
	var dir := ProjectSettings.globalize_path(DATA)
	if not DirAccess.dir_exists_absolute(dir):
		return []
	var out := Elo.collect_xml(PackedStringArray([dir]))
	out.sort()
	return out


# a copy of `src` in the scratch folder, under `name`, with `edit` applied to its text
func _variant(src: String, name: String, edit: Callable) -> String:
	var text := FileAccess.get_file_as_string(src)
	var dst := tmp.path_join(name)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	f.store_string(edit.call(text))
	f.close()
	return dst


func _wipe_user_dir() -> void:
	_wipe(OS.get_user_data_dir(), true)
	Elo.ratings.clear()
	Elo.processed.clear()
	Elo.sessions_seen.clear()
	Elo.history.clear()
	Elo.aliases.clear()
	Elo.revision += 1


func _wipe(path: String, keep_root: bool) -> void:
	for d in DirAccess.get_directories_at(path):
		if d in ["logs", "shader_cache", "vulkan"]:
			continue
		_wipe(path.path_join(d), false)
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	if not keep_root:
		DirAccess.remove_absolute(path)


# ---------- tests that need no data ----------
func _test_settings() -> void:
	_section("Settings and race rules")
	var r := LeagueSettings.rules_for("mc", 3)
	check(r["fuel"] == 2.0 and r["tyre"] == 2.0 and r["pits"], "Multiclass season 3 rule: fuel x2, tyres x2, stops")
	r = LeagueSettings.rules_for("mc", 5)
	check(r["tyre"] == 1.0, "Multiclass season 5 takes the later rule (tyres x1)")
	r = LeagueSettings.rules_for("mc", 0)
	check(r["tyre"] == 1.0, "Season 0 = the series' current rule")
	r = LeagueSettings.rules_for("zz", 2)
	check(r["fuel"] == 1.0 and not r["pits"] and not r["known"], "Unknown series: x1, no stops")
	check(LeagueSettings.label("LMP2_ELMS") == "LMP2+", "Class label LMP2_ELMS -> LMP2+")
	check(LeagueSettings.points().slice(0, 7) == [50, 47, 44, 41, 38, 35, 34] and LeagueSettings.points().size() == 40, "League points scale: 50, 47, 44, 41, 38, 35, 34... down to 1")
	check(LeagueSettings.drops_for(1) == 0 and LeagueSettings.drops_for(2) == 0 and LeagueSettings.drops_for(3) == 1, "One drop, only from round 3 (drops apply after round 2)")
	var names_ok := Elo.pretty("DAN POULIN") == "Dan Poulin" and Elo.pretty("p thom") == "P Thom" \
		and Elo.pretty("David Carter#4131") == "David Carter" and Elo.pretty("JD Bagnoli") == "JD Bagnoli" \
		and Elo.pretty("MCDONALD") == "McDonald" and Elo.pretty("jean-luc o'neil") == "Jean-Luc O'Neil"
	check(names_ok, "Driver names shown with normal capitals, without #tags")
	var ret := Predict.expected_dnfs([0.5, 0.5])
	check(is_equal_approx(float(ret["expected"]), 1.0) and is_equal_approx(float(ret["p_none"]), 0.25) and ret["range"] == "0 to 2", "Expected retirements: count and range", str(ret))
	check(LeagueSettings.label("Ligier LMGT3 car") == "Ligier LMGT3 car", "Class labels only replace whole words")
	check(Elo.league_name(6, "SC", 3, true) == "s6-sc3-r.xml" and Elo.league_name(2, "mc", 1, false) == "s2-mc1.xml", "League file names")
	check(Elo.season_number("s5-mc2-r.xml") == 5 and Elo.series_code("s5-mc2-r.xml") == "mc", "Season and series from the file name")
	check(Elo.season_number("2025_03_12_21_04_56-55R1.xml") == 0 and not Elo.is_league_name("2025_03_12_21_04_56-55R1.xml"), "Game default names have no season")


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _test_data_folder() -> void:
	_section("Data folder")
	check(AppPaths.in_user_dir() and AppPaths.data() == "user://", "Tests keep their data in the test folder", AppPaths.data())
	check(AppPaths.file("events/x.json") == "user://events/x.json", "Data paths", AppPaths.file("events/x.json"))
	# the first-start copy: everything but Godot's own folders, any depth, .tmp files left out
	var old := tmp.path_join("old_appdata")
	var new := tmp.path_join("Grid Ledger/Data")
	_write(old.path_join("elo.json"), "{}")
	_write(old.path_join("events/a.json"), "{\"a\": 1}")
	_write(old.path_join("xml/s6-mc2-r.xml"), "<x/>")
	_write(old.path_join("tracks/deep/t.json"), "{}")
	_write(old.path_join("logs/godot.log"), "log")
	_write(old.path_join("events/b.json.tmp"), "half")
	var err := AppPaths.copy_tree(old, new, AppPaths.GODOT_DIRS, ["elo.json"])
	check(err == OK and FileAccess.file_exists(new.path_join("events/a.json")) and FileAccess.file_exists(new.path_join("xml/s6-mc2-r.xml"))
		and FileAccess.file_exists(new.path_join("tracks/deep/t.json")), "First start copies the data over", str(err))
	check(not DirAccess.dir_exists_absolute(new.path_join("logs")) and not FileAccess.file_exists(new.path_join("events/b.json.tmp")),
		"Godot's logs and half-written files are not copied")
	check(not FileAccess.file_exists(new.path_join("elo.json")), "Ratings file copied last (a stopped copy is redone next start)")
	check(FileAccess.file_exists(old.path_join("events/a.json")), "The old copy is left in place")
	# a backup zip made by hand, with everything one folder down (Windows "Extract all", zipped again)
	var hand := tmp.path_join("hand.zip")
	var zp := ZIPPacker.new()
	zp.open(hand)
	for n in ["My backup/elo.json", "My backup/events/a.json", "My backup/events/b.json", "My backup/logs/x.log", "My backup/../evil.txt"]:
		zp.start_file(n)
		zp.write_file("{}".to_utf8_buffer())
		zp.close_file()
	zp.close()
	var info := AppPaths.inspect_backup(hand)
	check(info["ok"] and info["prefix"] == "My backup/" and info["events"] == 2 and info["files"] == 3,
		"Backup inside a folder of the zip is found", str(info))
	_write(tmp.path_join("not_a_backup/readme.txt"), "hi")
	zp = ZIPPacker.new()
	zp.open(tmp.path_join("other.zip"))
	zp.start_file("readme.txt")
	zp.write_file("hi".to_utf8_buffer())
	zp.close_file()
	zp.close()
	check(not AppPaths.inspect_backup(tmp.path_join("other.zip"))["ok"], "Any other zip is refused")
	# image folders: s6_r5, and folders from earlier versions renamed
	check(AppPaths.round_folder("Season 6", 5) == "s6_r5" and AppPaths.round_folder("Season 2", 7) == "s2_r7", "Round folder names")
	var gfx := tmp.path_join("gfx")
	DirAccess.make_dir_recursive_absolute(gfx.path_join("Season6_R4/Enduro"))
	DirAccess.make_dir_recursive_absolute(gfx.path_join("Season5_R6"))
	DirAccess.make_dir_recursive_absolute(gfx.path_join("s5_r6"))
	AppPaths.rename_round_folders(gfx)
	check(DirAccess.dir_exists_absolute(gfx.path_join("s6_r4/Enduro")) and not DirAccess.dir_exists_absolute(gfx.path_join("Season6_R4")),
		"Old round folders renamed")
	check(DirAccess.dir_exists_absolute(gfx.path_join("Season5_R6")), "An old folder is left alone when the new name is taken")


# Backs the test data up, changes it, restores: the data comes back exactly, the changed data
# is set aside, never deleted.
func _test_backup_restore() -> void:
	_section("Backup and restore")
	var before := _data_fingerprint()
	var zip := tmp.path_join("backup.zip")
	var r := AppPaths.write_backup(zip)
	check(r[0] == OK and r[1] > 0, "Backup written", str(r))
	var info := AppPaths.inspect_backup(zip)
	check(info["ok"] and info["prefix"] == "" and info["has_ratings"] and info["events"] > 0, "Backup recognised", str(info))
	var zr := ZIPReader.new()
	zr.open(zip)
	var names := zr.get_files()
	zr.close()
	check(not Array(names).any(func(n): return n.begins_with("test_tmp/") or n.begins_with("logs/") or n.begins_with("Backups/")),
		"Only the data goes in the backup")
	# change the data, then restore
	_write(AppPaths.file("elo.json"), "{\"changed\": true}")
	_write(AppPaths.file("events/zz_extra.json"), "{}")
	var safety := AppPaths.backups().path_join("Before restore test")
	var res := AppPaths.restore_backup(zip, safety)
	check(res["ok"] and res["files"] == r[1], "Backup restored", str(res))
	check(_data_fingerprint() == before, "Restored data is identical to the backup")
	check(FileAccess.get_file_as_string(safety.path_join("elo.json")).contains("changed")
		and FileAccess.file_exists(safety.path_join("events/zz_extra.json")), "The replaced data is kept in Backups")
	check(not FileAccess.file_exists(AppPaths.file("events/zz_extra.json")), "Nothing from the replaced data is left behind")
	# a zip that cannot be read: nothing changes
	_write(tmp.path_join("broken.zip"), "not a zip")
	var bad := AppPaths.restore_backup(tmp.path_join("broken.zip"), AppPaths.backups().path_join("Before restore bad"))
	check(not bad["ok"] and _data_fingerprint() == before, "A broken zip changes nothing")


# every data file (path and content hash), outside Godot's and the test's own folders
func _data_fingerprint() -> Dictionary:
	var out := {}
	var root := ProjectSettings.globalize_path(AppPaths.data())
	var todo := []
	for e in AppPaths._data_entries():
		if DirAccess.dir_exists_absolute(root.path_join(e)):
			todo.append(e)
		else:
			out[e] = FileAccess.get_md5(root.path_join(e))
	while not todo.is_empty():
		var rel: String = todo.pop_back()
		for d in DirAccess.get_directories_at(root.path_join(rel)):
			todo.append(rel.path_join(d))
		for f in DirAccess.get_files_at(root.path_join(rel)):
			out[rel.path_join(f)] = FileAccess.get_md5(root.path_join(rel).path_join(f))
	return out


# Success ballast: the rules table, and season 6 replayed against the ballast the result files
# say each car carried (the test data has no Penalties-page decisions, so a few cars differ).
func _test_ballast() -> void:
	_section("Success ballast")
	check(SuccessBallast.delta("GT3", 1, "Finished Normally") == 15 and SuccessBallast.delta("GT3", 4, "Finished Normally") == 0
		and SuccessBallast.delta("GT3", 12, "Finished Normally") == -15, "GT3 table (P1, P4, P12)")
	check(SuccessBallast.delta("Hyper", 3, "Finished Normally") == 2 and SuccessBallast.delta("LMP3", 6, "Finished Normally") == -5,
		"Hyper and LMP3 tables")
	check(SuccessBallast.delta("GT3", 2, "DNF") == -15 and SuccessBallast.delta("GT3", 1, "DQ") == 0, "DNF = P7 or lower, DQ changes nothing")
	check(SuccessBallast.delta("LMP2", 1, "Finished Normally") == 0, "A class without a table carries none")
	check(SuccessBallast.cap("GT3") == 45 and SuccessBallast.cap("Hyper") == 30 and SuccessBallast.cap("LMP3") == 30
		and SuccessBallast._clamp(60, "GT3") == 45 and SuccessBallast._clamp(40, "Hyper") == 30 and SuccessBallast._clamp(-5, "GT3") == 0,
		"Caps: GT3 45 kg, Hyper and LMP3 30 kg, never below 0")
	var same := 0
	var total := 0
	var worst := ""
	for series in ["Sprint", "Enduro"]:
		var sb := SuccessBallast.season("Season 6", series)
		var rnd := 0
		for ev in Elo.history:
			if Elo.season_of(ev) != "Season 6" or Elo.series_of(ev) != series:
				continue
			if not (ev["changes"] as Array).any(func(c): return c["sess"] == "race"):
				continue
			rnd += 1
			var saved = JSON.parse_string(FileAccess.get_file_as_string(AppPaths.file("events/%s.json" % ev["file"])))
			var drv: Dictionary = saved.get("fp", {}).get("race", {}).get("drivers", {}) if saved is Dictionary else {}
			for nm in drv:
				if not sb.has(nm):
					continue
				for r in sb[nm]["rounds"]:
					if int(r["round"]) == rnd:
						total += 1
						if int(r["before"]) == int(drv[nm].get("mass", -1)):
							same += 1
						elif worst == "":
							worst = "%s R%d %s: rules %d kg, file %d kg" % [series, rnd, nm, r["before"], drv[nm].get("mass", -1)]
	check(total > 50 and same >= total * 0.95, "Season 6 replays to the recorded ballast (%d of %d cars)" % [same, total], worst)
	_test_lap_records()
	_test_track_limits()
	_test_drive_throughs()
	var fit := Predict.ballast_effect()
	check(int(fit["races"]) > 0 and float(fit["k"]) > 0.0 and float(fit["k"]) < 0.03, "Ballast effect learned from the races with ballast", str(fit))
	_test_retune()
	check(Predict.DEFAULTS["fit"] == 0.0, "Driver-trait x track-trait fit off by default (the backtest is better without it)")
	check(Predict.DEFAULTS["p_tend"] == 0.0 and Predict.DEFAULTS["tend_sure"] == 1.0 and Predict.DEFAULTS["tend_cap"] == 1.5 and Predict.DEFAULTS["tend_new"] == 1.0,
		"Track tendencies off by default, applied the safer way when on")
	check(Predict.DEFAULTS["ballast"] == 0.0, "Ballast slowdown is off by default (an upgrade: the backtest is worse with it)")
	check(Predict.DEFAULTS["p_form"] == 1.0 and Predict.UPGRADES.any(func(u): return u[0] == "p_form"),
		"Current form is an upgrade, on by default (the backtest is better with it)")
	_test_form()
	_test_starts_fade_balance()
	var rows: Array = Reports.season_points("Season 6").values()
	check(rows.any(func(ch): return (ch["drivers"] as Dictionary).values().any(func(e): return int(e["ballast"]) > 0)),
		"Standings carry each driver's ballast")


# Penalties given mid-race are drive-throughs: what each cost is read from the files, and the
# forecast charges that (pulled towards the league's figure) instead of a flat setting.
func _test_drive_throughs() -> void:
	var all := []
	for day in Profiles.days:
		if not (day["race"] as Dictionary).is_empty():
			all.append_array(day["race"].get("dt", []))
	var dt := Profiles.drive_through("")
	check(all.size() >= 10 and float(dt["league"]) > 10.0 and float(dt["league"]) < 40.0,
		"Drive-throughs served mid-race measured from the files (%d, typical %.1f s)" % [all.size(), float(dt["league"])])
	var course := ""
	for day in Profiles.days:
		if not (day["race"] as Dictionary).is_empty() and not (day["race"].get("dt", []) as Array).is_empty():
			course = str(day["course"])
	var here := Profiles.drive_through(course)
	var info := Profiles.track_info(course, "GT3")
	var want := (float(here["track"]) * int(here["n"]) + float(here["league"]) * Profiles.K_DT) / (int(here["n"]) + Profiles.K_DT)
	check(int(here["n"]) > 0 and absf(float(info.get("pen_s", -1.0)) - want) < 1e-6,
		"A track's drive-through cost is its own pulled towards the league's (%s: %.1f s)" % [course, float(info.get("pen_s", -1.0))])


# A forecast settings file saved before the retune takes the retuned values once, keeps the rest.
func _test_retune() -> void:
	var keep: Dictionary = Predict.params.duplicate()
	var old := FileAccess.get_file_as_string(Predict.SETTINGS_PATH) if FileAccess.file_exists(Predict.SETTINGS_PATH) else ""
	var f := FileAccess.open(Predict.SETTINGS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"params": {"g_grid": 1.2, "sig_form": 0.6, "pen_s": 60.0, "traffic": 1.0, "c0": 2.0}}))
	f.close()
	Predict._load_settings()
	var data = JSON.parse_string(FileAccess.get_file_as_string(Predict.SETTINGS_PATH))
	check(Predict.params["g_grid"] == 3.5 and Predict.params["sig_form"] == 0.5 and Predict.params["traffic"] == 0.0
		and Predict.params["c0"] == 2.0 and int(data.get("tuning", 0)) == Predict.TUNING,
		"Old forecast settings take the retuned values once and keep the others", str(Predict.params))
	if old != "":
		var g := FileAccess.open(Predict.SETTINGS_PATH, FileAccess.WRITE)
		g.store_string(old)
		g.close()
	else:
		DirAccess.remove_absolute(Predict.SETTINGS_PATH)
	Predict.params = keep


# Lap-1 places gained, pace fade over a stint, and the car balance report.
func _test_starts_fade_balance() -> void:
	var starts := 0
	var fades := 0
	var sum_start := 0
	var bad := ""
	for day in Profiles.days:
		for nm in day["race"].get("drivers", {}):
			var r: Dictionary = day["race"]["drivers"][nm]
			if r.has("start"):
				starts += 1
				sum_start += int(r["start"])
				if absf(int(r["start"])) > 40 and bad == "":
					bad = "%s %s: %d places on lap 1" % [day["date"], nm, int(r["start"])]
			if r.has("fade"):
				fades += 1
				if absf(float(r["fade"])) > Fingerprint.FADE_CAP and bad == "":
					bad = "%s %s: fade %.2f%%" % [day["date"], nm, float(r["fade"])]
	var fv := []
	for day in Profiles.days:
		for nm in day["race"].get("drivers", {}):
			if day["race"]["drivers"][nm].has("fade"):
				fv.append(float(day["race"]["drivers"][nm]["fade"]))
	fv.sort()
	print("    fade per 10 laps: 1%% %.2f, 10%% %.2f, median %.2f, 90%% %.2f, 99%% %.2f" % [fv[fv.size() / 100], fv[fv.size() / 10], fv[fv.size() / 2], fv[fv.size() * 9 / 10], fv[fv.size() * 99 / 100]])
	check(starts > 100 and fades > 50 and bad == "", "Lap-1 places gained (%d) and stint fade (%d) read from the files" % [starts, fades], bad)
	var ids := DriverGrades.TRAITS.map(func(t): return t[0])
	check("starts" in ids and not ("stint" in ids), "Driver grades include Starts (stint pace is not graded: no signal yet)")
	check(DriverGrades._age_weight("2026_01_01", DriverGrades._unix("2026_06_30"), DriverGrades.HALF_LIFE) > 0.49
		and DriverGrades._age_weight("2026_01_01", DriverGrades._unix("2026_06_30"), DriverGrades.HALF_LIFE) < 0.51,
		"Grades: a race 180 days older counts half")
	var gcls := DriverGrades.for_class("GT3")
	var pace_ok := false
	for dn in gcls["grades"]:
		if str(gcls["grades"][dn]["race"]["value"]).contains("car taken out"):
			pace_ok = true
	check(pace_ok, "Race pace grade takes the car out")
	var cb: Array = Reports.car_balance()
	check(cb.size() > 0 and (cb[0]["rows"] as Array).size() >= 2 and (cb[0]["headers"] as Array).has("Car itself"),
		"Car balance report: each car with its drivers' level taken out", str(cb.size()))


# Current form: last 5 races against the driver's own average, only from 6 races on.
func _test_form() -> void:
	var shown := 0
	var hidden := 0
	var bad := ""
	for key in Profiles.hist:
		var parts: PackedStringArray = str(key).split("|")
		var n := (Profiles.hist[key] as Array).filter(func(rec): return not (rec["r"] as Dictionary).is_empty()).size()
		var f := Profiles.form(parts[1], parts[0])
		if n < Profiles.FORM_MIN:
			hidden += 1
			if not f.is_empty() and bad == "":
				bad = "%s: form with %d races" % [key, n]
		else:
			shown += 1
			if (f.is_empty() or absf(float(f["value"]) - (float(f["recent"]) - float(f["career"]))) > 1e-6) and bad == "":
				bad = "%s: %s" % [key, str(f)]
	check(shown > 10 and hidden > 0 and bad == "", "Current form shown from %d races (%d drivers shown, %d too few)" % [Profiles.FORM_MIN, shown, hidden], bad)
	var tables: Array = Reports.driver_profile(str(Profiles.hist.keys()[0]).split("|")[1])
	check(tables.size() > 0, "Driver profile builds with the Current form table")


# League lap records: the quickest best lap at each track and class, records only ever come down.
func _test_lap_records() -> void:
	var recs := LapRecords.all()
	var ok := not recs.is_empty()
	var falls := 0
	for course in recs:
		for cls in recs[course]:
			var lap: Dictionary = recs[course][cls].get("lap", {})
			var race: Dictionary = recs[course][cls].get("race", {})
			ok = ok and not lap.is_empty() and (race.is_empty() or float(race["time"]) >= float(lap["time"]))
			var hist: Array = lap.get("history", [])
			for i in range(1, hist.size()):
				ok = ok and float(hist[i]["time"]) < float(hist[i - 1]["time"])
			falls += maxi(hist.size() - 1, 0)
			# nobody in the league files went quicker at this track and class
			for ev in Elo.history:
				if str(ev.get("course", "")) != course:
					continue
				for sess in ["quali", "race"]:
					for d in ev.get("stats", {}).get(sess, {}).get(cls, {}):
						var s: Dictionary = ev["stats"][sess][cls][d]
						var b := float(s.get("best", 0.0))
						if b > 0.0 and b < float(lap["time"]) and not str(s.get("status", "")).begins_with("DQ"):
							# only a lap thrown out as impossible may be quicker
							ok = ok and b < float(lap["time"]) * (1.0 - LapRecords.SANE)
	check(ok and falls > 0, "Lap records: quickest lap per track and class, history only comes down (%d records lowered)" % falls)
	# a weekend that lowered one shows up for the recap
	var found := false
	for course in recs:
		for cls in recs[course]:
			var hist: Array = recs[course][cls]["lap"]["history"]
			if hist.size() > 1 and not found:
				var f := str(hist[-1]["file"])
				var race_file := f if f.ends_with("-r.xml") else f.replace(".xml", "-r.xml")
				var set := LapRecords.set_at(race_file, course, cls)
				found = not set.is_empty() and float(set[0]["record"]["time"]) == float(hist[-1]["time"]) and not (set[0]["before"] as Dictionary).is_empty()
	check(found, "Lap record lowered at a weekend is found for the race recap")


# Track limits by the game's decision: warnings and penalties are part of the events, warnings a
# minority, penalties rare; read from the text (the Resolution number changed between versions).
func _test_track_limits() -> void:
	var ev := 0.0
	var w := 0.0
	var pn := 0.0
	var ok := true
	for day in Profiles.days:
		if day["race"].is_empty():
			continue
		for nm in day["race"]["drivers"]:
			var r: Dictionary = day["race"]["drivers"][nm]
			var laps := float(r.get("laps", 0))
			ok = ok and r.has("tlw") and float(r.get("tlw", 0)) <= float(r.get("tl", 0)) + 1e-6
			ev += float(r.get("tl", 0)) * laps
			w += float(r.get("tlw", 0)) * laps
			pn += float(r.get("tlp", 0)) * laps
	check(ok and ev > 0.0 and w / ev > 0.03 and w / ev < 0.35 and pn / ev < 0.02,
		"Track limits split by the game's decision (%.1f%% warned, %.2f%% penalised)" % [100.0 * w / maxf(ev, 1.0), 100.0 * pn / maxf(ev, 1.0)])


func _test_menu_order() -> void:
	var names := GraphicsView.KINDS.map(func(k): return str(k[1]).to_lower()) if ClassDB.class_exists("GraphicsView") else []
	if names.is_empty():
		names = (load("res://graphics_view.gd") as GDScript).get_script_constant_map()["KINDS"].map(func(k): return str(k[1]).to_lower())
	var sorted := names.duplicate()
	sorted.sort()
	check(names == sorted, "Graphics menu in A-Z order", str(names))


func _test_traffic_formula() -> void:
	_section("Traffic")
	var t := Predict.traffic_rates({"GT3": {"n": 20.0, "ratio": 1.12}})
	check(absf(float(t["pass"]) - 20.0 * (1.0 - 1.0 / 1.12)) < 1e-6 and t["passed"] == 0.0, "Faster class laps the slower one: n x |1 - t/t_other|")
	t = Predict.traffic_rates({"Hyper": {"n": 8.0, "ratio": 0.9}})
	check(t["passed"] > 0.0 and t["pass"] == 0.0, "Slower class is lapped")
	Predict.rng.seed = 1
	var total := 0.0
	for i in 2000:
		total += Predict._traffic_loss(10.0, 0.3)
	check(absf(total / 2000.0 - 3.0) < 0.3, "Traffic loss averages encounters x loss per encounter", "%.2f" % (total / 2000.0))


func _test_unreadable() -> void:
	_section("Unreadable files")
	print("        (Godot prints \"Cannot open file\" errors here: they are expected)")
	var gone := tmp.path_join("does_not_exist-01R1.xml")
	check(Elo.import_training(gone) == "unreadable", "A missing training file is reported as unreadable, not practice")
	check(Elo.build_draft(gone).get("unreadable", false), "A missing league file is flagged unreadable")


# ---------- tests on league data ----------
func _test_import(files: Array) -> void:
	_section("League import (%d files)" % files.size())
	var rated := 0
	var t0 := Time.get_ticks_msec()
	for f in files:
		var d := Elo.build_draft(f)
		if Elo.has_sessions(d) and not d["duplicate"]:
			d["new_drivers"] = {}
			if not Elo.is_league_name(str(d["file"])):
				Elo.rename_draft(d, Elo.league_name(1, "zz", rated + 1, d["orders"].has("race")))
			Elo.confirm_draft(d)
			rated += 1
	print("        (%d rated in %.1f s)" % [rated, (Time.get_ticks_msec() - t0) / 1000.0])
	check(rated > 0, "League files are rated")
	check(Elo.history.size() == rated, "One history entry per rated file")
	check(not Elo.boards().is_empty(), "Leaderboards exist")
	# ratings depend on the order of events: "Recompute all" replays them by date, so it must give
	# exactly the same ratings every time it runs
	var s := Elo.rebuild_all()
	check(s["count"] == rated, "Recompute all replays every event")
	var first := Elo.ratings.duplicate(true)
	Elo.rebuild_all()
	var same := first.size() == Elo.ratings.size()
	for k in first:
		if absf(float(first[k]["r"]) - float(Elo.ratings.get(k, {"r": -1})["r"])) > 1e-9:
			same = false
	check(same, "Recompute all gives the same ratings every time")
	check(FileAccess.file_exists("user://elo.json"), "Ratings saved")
	Elo.load_ratings()
	check(Elo.history.size() == rated, "Ratings load back from disk")


func _test_duplicates(files: Array) -> void:
	_section("Duplicates")
	var f: String = files[files.size() / 2]
	check(Elo.build_draft(f)["duplicate"], "The same file again is a duplicate")
	var renamed := _variant(f, "renamed_copy.xml", func(t): return t)
	var d := Elo.build_draft(renamed)
	check(d["duplicate"], "A renamed copy is a duplicate")
	# another player's log of the same race: clocks a few seconds apart, other connection
	var other := _variant(f, "other_log.xml", func(t: String): return t.replace("<ConnectionType", "<ConnectionType test=\"1\"").replace("<DateTime>", "<DateTime>9"))
	d = Elo.build_draft(other)
	check(d["duplicate"] and d["duplicate_of"] == f.get_file(), "A different file of the same event is a duplicate", str(d.get("duplicate_of", "")))
	var before := Elo.history.size()
	Elo.confirm_draft(d)
	check(Elo.history.size() == before, "Confirming a duplicate does nothing")


func _test_session_ids(files: Array) -> void:
	_section("Event identity")
	var seen := {}
	var clash := ""
	for f in files:
		var p := Elo.parse_results(f)
		for id in Elo.session_ids(p, str(Elo._read_track(f).get("TrackCourse", ""))):
			if seen.has(id):
				clash = "%s and %s" % [seen[id], f.get_file()]
			seen[id] = f.get_file()
	check(clash == "", "No two league sessions share an id", clash)


func _test_best_lap_fallback(files: Array) -> void:
	_section("Season 1 files (BestLapTime 0)")
	var q := ""
	for f in files:   # a quali-only file: league name without "-r"
		if Elo.is_league_name(str(f).get_file()) and not str(f).get_file().ends_with("-r.xml"):
			q = f
			break
	if q == "":
		_skip("best lap fallback", "no quali-only file in the data")
		return
	var rx := RegEx.create_from_string("<BestLapTime>[0-9.]+</BestLapTime>")
	var zeroed := _variant(q, "zeroed_best.xml", func(t: String): return rx.sub(t, "<BestLapTime>0.0000</BestLapTime>", true))
	var a := Elo.build_draft(q)
	var b := Elo.build_draft(zeroed)
	check(b["orders"].has("quali"), "A quali file with BestLapTime 0 still has a quali result")
	check(a["orders"].get("quali", {}).hash() == b["orders"].get("quali", {}).hash(), "Its order matches the original file")


func _test_practice_only(files: Array) -> void:
	_section("Practice files")
	var f: String = files[0]
	var prac := _variant(f, "practice_only-01P1.xml", func(t: String): return t.replace("<Race>", "<Practice1>").replace("</Race>", "</Practice1>").replace("<Qualify>", "<Practice2>").replace("</Qualify>", "</Practice2>"))
	check(Elo.import_training(prac) == "practice only", "A practice-only file is skipped as practice")
	var d := Elo.build_draft(prac)
	check(not Elo.has_sessions(d) and d.get("practice_only", false), "...and is never rated as league")


func _test_league_naming(files: Array) -> void:
	_section("League naming")
	var src: String = files[0]
	var named := _variant(src, "2024_01_04_20_30_00-11R1.xml", func(t: String): return t.replace("<TrackCourse>", "<TrackCourse>Test "))
	var d := Elo.build_draft(named)
	check(not Elo.is_league_name(str(d["file"])), "A game default name is not a league name")
	var sug := Elo.suggest_league_name(d)
	check(int(sug["season"]) >= 1 and int(sug["round"]) >= 1, "A season / series / round is suggested", str(sug))
	var taken := str(Elo.history[0]["file"])
	check(Elo.rename_draft(d.duplicate(true), taken) != "", "A name already used is refused")
	var new_name := Elo.league_name(int(sug["season"]), str(sug["code"]), 99, d["orders"].has("race"))
	check(Elo.rename_draft(d, new_name) == "" and d["file"] == new_name, "The draft takes the league name")
	check(int(d["event_time"]) == Elo._name_time("2024_01_04_20_30_00-11R1.xml"), "...and keeps the date of its old name")


func _test_training(files: Array) -> void:
	_section("Training data")
	check(Elo.import_training(files[0]) == "duplicate", "A league event imported as training is a duplicate")
	var fresh := _variant(files[files.size() - 1], "2023_05_05_20_00_00-77R1.xml", func(t: String): return t.replace("<TrackCourse>", "<TrackCourse>Training "))
	var v := Elo.import_training(fresh)
	check(v == "added" or v == "no data", "A new training file is stored", v)
	if v == "added":
		var saved = JSON.parse_string(FileAccess.get_file_as_string("user://events/%s.json" % fresh.get_file()))
		var names_kept := false
		for k in ["race", "quali"]:
			for n in saved.get("fp", {}).get(k, {}).get("drivers", {}):
				if not str(n).begins_with("#"):
					names_kept = true
		check(not names_kept, "Training data keeps no driver names")
		check(Elo.import_training(fresh) == "duplicate", "Importing it again is a duplicate")


func _test_profiles_and_grades() -> void:
	_section("Profiles, grades, ranks")
	Profiles.rebuild()
	check(Profiles.has_data() and not Profiles.days.is_empty(), "Driver history built from the lap data")
	var cls: String = Elo.boards()[0][0]
	var rows := Profiles.driver_rows(cls)
	check(not rows.is_empty(), "Driver rows for " + cls)
	var g := DriverGrades.driver(rows[0]["name"], cls)
	var grades_ok := true
	for x in g:
		if int(x["grade"]) < 0 or int(x["grade"]) > 5:
			grades_ok = false
	check(grades_ok and not g.is_empty(), "Driver grades are between 0 and 5")
	var ranks := Ranks.all()
	check(ranks.has(cls), "Ranks computed per class")
	var tiers := LeagueSettings.ranks()
	var ok := true
	for d in ranks[cls]:
		var e: Dictionary = ranks[cls][d]
		if int(e["duels"]) < int(LeagueSettings.get_value("rank_settle_duels")) and int(e["tier"]) >= 0:
			ok = false
		if int(e["tier"]) >= tiers.size():
			ok = false
	check(ok, "Nobody is ranked before settling, no rank out of range")
	check(WetWeather.classes().size() >= 0, "Wet-weather analysis runs")
	var mc := Predict.series_classes("")
	check(not mc.is_empty(), "Series classes found", str(mc))


func _test_predict() -> void:
	_section("Predictor")
	var cls: String = Elo.boards()[0][0]
	var names := []
	for r in Elo.leaderboard(cls, "race").slice(0, 12):
		names.append(r["name"])
	Predict.rng.seed = 3
	var res: Dictionary = await Predict.forecast(names, cls, Predict.Mode.PREDICTED_QUALI)
	var win := 0.0
	var pole := 0.0
	for r in res["rows"]:
		win += float(r["win"])
		pole += float(r["pole"])
	check(res["rows"].size() == names.size(), "One row per driver")
	check(absf(win - 1.0) < 0.001 and absf(pole - 1.0) < 0.001, "Win and pole chances add up to 100%", "%.3f / %.3f" % [win, pole])
	var sorted := true
	for i in range(1, res["rows"].size()):
		if res["rows"][i]["exp_pos"] < res["rows"][i - 1]["exp_pos"]:
			sorted = false
	check(sorted, "Rows come in expected finishing order")
	var plan := {"pits": true, "fuel": 2.0, "tyre": 1.0, "min_stops": 1}
	res = await Predict.forecast(names, cls, Predict.Mode.ACTUAL_GRID, "", 60, 0.0, "", {}, plan)
	# race lap: a typed lap time first, else the telemetry lap x class factor, else the league results
	var tl_course := Profiles.latest_course()
	var tl_file := TrackStore.dir() + "/test_telemetry.json"
	DirAccess.make_dir_recursive_absolute(TrackStore.dir())
	var fa := FileAccess.open(tl_file, FileAccess.WRITE)
	fa.store_string(JSON.stringify({"course": tl_course, "class": cls, "map": [], "lap": {"time_s": 100.0}}))
	fa.close()
	TrackStore._list_cache = null
	var r_tel: Dictionary = await Predict.forecast(names, cls, Predict.Mode.ACTUAL_GRID, tl_course, 60, 0.0, "", {}, plan)
	var r_typed: Dictionary = await Predict.forecast(names, cls, Predict.Mode.ACTUAL_GRID, tl_course, 60, 95.0, "", {}, plan)
	DirAccess.remove_absolute(tl_file)
	TrackStore._list_cache = null
	var want := 100.0 * Predict.tel_ratio(cls)
	check(absf(float(r_tel["track"]["ref_s"]) - want) < 1e-6 and int(r_tel["laps"]) == int(3600.0 / want) + 1,
		"Forecast race lap = telemetry lap x class factor (%s: 100 s -> %.1f s)" % [cls, want], "%s s, %d laps" % [r_tel["track"]["ref_s"], r_tel["laps"]])
	check(absf(float(r_typed["track"]["ref_s"]) - 95.0) < 1e-6, "A lap time typed on the Predict screen wins over telemetry")
	# weather: "dry" gives exactly the old forecast; mixed rolls its own weather per run; wet is slower
	var wx_res := {}
	for wx in ["none", "dry", "mixed", "wet"]:
		Predict.rng.seed = 42
		Predict.pit_rng.seed = 43
		Predict.wx_rng.seed = 44
		var pl: Dictionary = plan.duplicate()
		if wx != "none":
			pl["weather"] = wx
			pl["rain"] = 0.5
		wx_res[wx] = await Predict.forecast(names, cls, Predict.Mode.ACTUAL_GRID, tl_course, 60, 0.0, "", {}, pl)
	var same := true
	for i in wx_res["none"]["rows"].size():
		same = same and wx_res["none"]["rows"][i]["name"] == wx_res["dry"]["rows"][i]["name"] \
			and wx_res["none"]["rows"][i]["win"] == wx_res["dry"]["rows"][i]["win"]
	check(same, "Weather Dry gives exactly the forecast without weather")
	var mix: Dictionary = wx_res["mixed"]
	var split_ok := true
	var sum_win := 0.0
	for r in mix["rows"]:
		split_ok = split_ok and float(r["win_rain"]) >= 0.0 and float(r["win_dry"]) >= 0.0
		sum_win += float(r["win"])
	check(mix["weather"] == "mixed" and split_ok and absf(sum_win - 1.0) < 0.01,
		"Mixed weather: win chances add up and split into dry / rain runs")
	var top_dry: float = wx_res["dry"]["rows"][0]["win"]
	var top_mix := 0.0
	for r in mix["rows"]:
		top_mix = maxf(top_mix, float(r["win"]))
	check(top_mix < top_dry, "Mixed weather makes the favourite less sure (%.0f%% dry, %.0f%% mixed)" % [100.0 * top_dry, 100.0 * top_mix])
	check(int(wx_res["wet"]["laps"]) < int(wx_res["dry"]["laps"]), "Wet race: fewer laps (%d vs %d dry)" % [wx_res["wet"]["laps"], wx_res["dry"]["laps"]])
	Predict.rng.randomize()
	Predict.pit_rng.randomize()
	Predict.wx_rng.randomize()
	# the league lap time at a track averages its dry races only (wet ones run 11-19% slower)
	var wet_checked := false
	for d in Profiles.days:
		if wet_checked or d["race"].is_empty() or float(d["race"].get("wet", 0.0)) < 0.5:
			continue
		for wc in d["race"]["classes"]:
			var dry := []
			for d2 in Profiles.days:
				if d2["course"] == d["course"] and not d2["race"].is_empty() and float(d2["race"].get("wet", 0.0)) < 0.5 \
						and d2["race"]["classes"].has(wc) and float(d2["race"]["classes"][wc].get("ref_s", 0.0)) > 0.0:
					dry.append(float(d2["race"]["classes"][wc]["ref_s"]))
			if dry.is_empty():
				continue
			var avg := 0.0
			for x in dry:
				avg += x / dry.size()
			check(absf(float(Profiles.track_info(str(d["course"]), str(wc))["ref_s"]) - avg) < 1e-3,
				"League lap time leaves out wet races (%s %s)" % [d["course"], wc])
			wet_checked = true
			break
	if not wet_checked:
		_skip("wet races left out of the lap time", "no wet race at a track that also has dry ones")
	var stops_ok := true
	for r in res["rows"]:
		if int(r["stops"]) < 1:
			stops_ok = false
	check(stops_ok, "Planned stops respect the minimum")
	res = await Predict.forecast(names, cls, Predict.Mode.ACTUAL_GRID, "", 30, 0.0, "", {}, {"pits": false})
	var none := true
	for r in res["rows"]:
		if int(r["stops"]) != 0:
			none = false
	check(none, "No stops when none are expected")
	# retirements: the rate only uses races before the forecast date (dates come as 2026_10_29)
	var last_ev: Dictionary = Elo.history[Elo.history.size() - 1]
	var day := Time.get_date_string_from_unix_time(int(last_ev["time"])).replace("-", "_")
	var someone: String = names[0]
	var r_all := Predict.dnf_rate(someone, cls, "")
	var r_before := Predict.dnf_rate(someone, cls, day)
	var r_none := Predict.dnf_rate(someone, cls, "1990_01_01")
	check(r_all > 0.0 and r_all < 1.0 and r_none == 0.0, "Retirement chance between 0 and 1; none known before the first race (%.3f)" % r_all)
	check(not is_equal_approx(Predict._dnf_cache.size(), 0) and r_before >= 0.0, "Retirement chance computed for a past date without later races")
	# aged track history: older visits count less, dates in either format
	check(DriverTrackFit._iso("2026_10_29") == "2026-10-29" and DriverTrackFit._iso("2026-10-29") == "2026-10-29", "Dates read in both formats (2026_10_29 / 2026-10-29)")
	var fit_now: Dictionary = DriverTrackFit.fit(someone, cls, "", TrackGrades.collect(cls), {}, true)
	var aged_ok := true
	for t in fit_now["tracks"]:
		if t.has("race_aged_n") and int(t["races"]) > 0:
			aged_ok = aged_ok and float(t["race_aged_n"]) > 0.0 and float(t["race_aged_n"]) <= float(t["races"]) + 1e-6
	check(aged_ok, "Track history weights: every visit counts, older ones less")


func _test_forecast_record() -> void:
	_section("Forecast record")
	# a forecast "made" the day before a past race, with that race's drivers
	var h: Dictionary = {}
	for e in Elo.history:
		for c in e["changes"]:
			if c["sess"] == "race":
				h = e
				break
	if h.is_empty():
		_skip("forecast record", "no race in the data")
		return
	var cls := ""
	var finish := {}
	for c in h["changes"]:
		if c["sess"] == "race" and (cls == "" or c["cls"] == cls):
			cls = c["cls"]
			finish[Elo.resolve(str(c["driver"]))] = int(c["pos"])
	var names := finish.keys()
	Predict.rng.seed = 9
	var res: Dictionary = await Predict.forecast(names, cls, Predict.Mode.RACE_ONLY)
	# made just before its race and for its series, so no other race of the class can come first
	var path := Predict.save_forecast(res, cls, Elo.series_code(str(h["file"])), Predict.Mode.RACE_ONLY, int(h["time"]) - 60)
	check(path != "" and FileAccess.file_exists(path), "A forecast is saved")
	var fc: Dictionary = {}
	for f in Predict.list_forecasts():
		if path.ends_with(str(f["file"])):
			fc = f
	var sc := Predict.score_forecast(fc)
	check(not sc.is_empty() and sc["event"] == h["file"], "It is matched to the first race after it", str(sc.get("event", "none")))
	var real_winner := ""
	for n in finish:
		if finish[n] == 1:
			real_winner = n
	check(sc.get("winner", "") == real_winner, "The winner comes from the real result", "%s vs %s" % [sc.get("winner", ""), real_winner])
	check(int(sc.get("podium_hits", -1)) >= 0 and int(sc["podium_hits"]) <= 3 and float(sc["pos_error"]) >= 0.0, "Podium hits and position error are in range")
	var later := Predict.save_forecast(res, cls, "", Predict.Mode.RACE_ONLY, int(Time.get_unix_time_from_system()) + 3600)
	var waiting := {}
	for f in Predict.list_forecasts():
		if later.ends_with(str(f["file"])):
			waiting = f
	check(Predict.score_forecast(waiting).is_empty(), "A forecast for a race not imported yet waits")
	var saved_rows: Array = waiting.get("rows", [])
	check(not saved_rows.is_empty() and saved_rows[0].has("pole") and saved_rows[0].has("grid"), "Saved forecasts keep pole chances and grid places (for the pole strip)")
	var tables := Reports.forecast_record()
	check(tables.size() == 2 and tables[0]["note"].contains("Waiting for results"), "The Forecast record report shows the summary, the forecasts and the waiting one")


func _test_penalties() -> void:
	_section("Penalties after the race")
	# the latest race with at least 4 classified finishers on the lead lap, in some class
	var file := ""
	var cls := ""
	for i in range(Elo.history.size() - 1, -1, -1):
		var orig := Elo.original_race(str(Elo.history[i]["file"]))
		for c in orig.get("orders", {}):
			var o: Array = orig["orders"][c]
			if o.size() >= 6 and float(orig["stats"].get(c, {}).get(o[1], {}).get("time", 0.0)) > 0.0:
				file = str(Elo.history[i]["file"])
				cls = c
				break
		if file != "":
			break
	if file == "":
		_skip("penalties", "no race with finishing times")
		return
	var orig := Elo.original_race(file)
	var order: Array = orig["orders"][cls]
	var st: Dictionary = orig["stats"][cls]
	var before := Elo.ratings.duplicate(true)
	# a time penalty just bigger than the gap to the car behind costs exactly one place
	var gap := float(st[order[2]]["time"]) - float(st[order[1]]["time"])
	var same_lap := int(st[order[2]]["laps"]) == int(st[order[1]]["laps"])
	var pen := {"id": "t", "cls": cls, "driver": order[1], "type": "time", "value": ceili(gap + 0.5), "reason": "", "at": 0}
	var r := Elo.penalised_order(order, st, [pen])
	if same_lap:
		check(r["order"][2] == order[1] and r["order"][1] == order[2], "Time penalty bigger than the gap behind costs a place")
	var small := pen.duplicate()
	small["value"] = maxi(1, floori(gap - 0.5)) if gap > 1.5 else 0
	if int(small["value"]) > 0 and same_lap:
		check(Elo.penalised_order(order, st, [small])["order"] == order, "Time penalty smaller than the gap behind changes nothing")
	r = Elo.penalised_order(order, st, [{"id": "p", "cls": cls, "driver": order[0], "type": "places", "value": 2, "reason": "", "at": 0}])
	check(r["order"][2] == order[0], "Drop 2 positions: P1 becomes P3")
	r = Elo.penalised_order(order, st, [{"id": "d", "cls": cls, "driver": order[0], "type": "dsq", "value": 0, "reason": "", "at": 0}])
	check(r["order"][-1] == order[0] and r["dsq"].has(order[0]), "Disqualified: to the back")
	# applied for real: the result, ratings and file change; undone: everything back
	var season_name := ""
	var series_name := ""
	for h in Elo.history:
		if h["file"] == file:
			season_name = Elo.season_of(h)
			series_name = Elo.series_of(h)
	var before_sp: Dictionary = Reports.season_points(season_name).get(("%s %s" % [series_name, cls]).strip_edges(), {}).get("drivers", {})
	Elo.set_race_penalties(file, [{"id": "d", "cls": cls, "driver": order[0], "type": "dsq", "value": 0, "reason": "", "at": 0}])
	var winner := ""
	for h in Elo.history:
		if h["file"] == file:
			for c in h["changes"]:
				if c["sess"] == "race" and c["cls"] == cls and int(c["pos"]) == 1:
					winner = c["driver"]
	check(winner == Elo.resolve(order[1]), "After a DSQ of the winner the 2nd is rated as the winner", winner)
	check(Elo.event_penalties(file).size() == 1 and Elo.original_race(file)["orders"][cls] == order, "The penalty is saved, the original result kept")
	# standings: the points of that race follow the corrected result (totals before dropped rounds)
	var key := ("%s %s" % [series_name, cls]).strip_edges()
	var after_sp: Dictionary = Reports.season_points(season_name).get(key, {}).get("drivers", {})
	var pts: Array = LeagueSettings.points()
	var p_at := func(pos: int) -> int: return int(pts[pos - 1]) if pos <= pts.size() else 0
	var won: Dictionary = before_sp.get(Elo.resolve(order[1]), {})
	var won2: Dictionary = after_sp.get(Elo.resolve(order[1]), {})
	var dq: Dictionary = before_sp.get(Elo.resolve(order[0]), {})
	var dq2: Dictionary = after_sp.get(Elo.resolve(order[0]), {})
	check(not won.is_empty() and int(won2["wins"]) == int(won["wins"]) + 1 and int(won2["total"]) - int(won["total"]) == p_at.call(1) - p_at.call(2),
		"Standings: the promoted driver gets the win and the winner's points", "%s -> %s" % [won, won2])
	check(not dq.is_empty() and int(dq2["wins"]) == int(dq["wins"]) - 1 and int(dq["total"]) - int(dq2["total"]) == p_at.call(1),
		"Standings: the disqualified driver loses the win and scores nothing for that race", "%s -> %s" % [dq, dq2])
	# a re-read of the race from the archived XML keeps the penalty (DQ status and order)
	var xml := Elo.stored_xml_path(file)
	if xml != "":
		Elo.attach_stats(Elo.build_draft(xml))
		var st_after: Dictionary = {}
		for h in Elo.history:
			if h["file"] == file:
				st_after = Reports._stats_for(h, "race", cls)
		var saved = JSON.parse_string(FileAccess.get_file_as_string("user://events/%s.json" % file))
		check(str(st_after.get(Elo.resolve(order[0]), {}).get("status", "")) == "DQ" and saved["orders"]["race"][cls][-1] == order[0],
			"Re-reading the race from its XML keeps the penalty (status DQ, order)")
	# the lap-data side (predictor backtest) uses the corrected places
	Profiles.rebuild()
	var lap_pos := -1
	for day in Profiles.days:
		var drv: Dictionary = day["race"].get("drivers", {}) if not day["race"].is_empty() else {}
		if drv.has(Elo.resolve(order[0])) and str(drv[Elo.resolve(order[0])].get("cls", "")) == cls and int(drv[Elo.resolve(order[0])].get("pos", 0)) == order.size():
			lap_pos = order.size()
	check(lap_pos == order.size(), "Lap data (predictor backtest) uses the corrected places")
	Elo.set_race_penalties(file, [])
	var same := true
	for k in before:
		if not Elo.ratings.has(k) or absf(float(before[k]["r"]) - float(Elo.ratings[k]["r"])) > 1e-9:
			same = false
	check(same and Elo.event_penalties(file).is_empty(), "Undoing every penalty restores every rating exactly")


func _test_season_scenarios() -> void:
	_section("Season scenarios")
	var pts := LeagueSettings.points()   # 50, 47, 44, 41...
	# series names: code in the file names <-> name shown (defaults: sc Sprint, mc Enduro)
	check(LeagueSettings.series_name("mc") == "Enduro" and LeagueSettings.series_code("Enduro") == "mc"
		and LeagueSettings.series_name("") == "" and LeagueSettings.series_code("Nope") == "" and LeagueSettings.series_name("xx") == "XX",
		"Series name <-> code helpers")
	# the test data folder starts from the default settings: 1 dropped round, from round 3 on
	check(LeagueSettings.drops_for(6) == 1, "Default settings: one dropped round at the end of a 6-round season")
	check(SeasonScenarios.final_score([50, 0, 47, 44], 6) == 141, "Final score drops the worst round (missed rounds count 0)")
	# leader 4 x 50, rival 4 x 47, two rounds left of 6, worst round dropped:
	# leader P3 next = 244, rival best = 241 -> settled; P4 (241) ties on points, and the leader has
	# more wins (4 against the rival's 2 at best) -> settled too; P5 (238) -> not
	var mk := func(name: String, p: int) -> Dictionary:
		var br := []
		for i in 4:
			br.append({"pts": p, "pos": 1 if p == 50 else 2})
		return {"name": name, "points": 4 * p, "wins": 4 if p == 50 else 0, "by_round": br, "alive": true}
	var rows := [mk.call("A", 50), mk.call("B", 47)]
	var cl := SeasonScenarios.clinch_next(rows, 2, 6, pts)
	check(int(cl["place"]) == 4, "Clinch maths: leader needs P4 or better next round (level on points, more wins)", "got P%d" % int(cl["place"]))
	var safe := [mk.call("A", 50), {"name": "B", "points": 40, "wins": 0, "by_round": [{"pts": 10, "pos": 30}, {"pts": 10, "pos": 30}, {"pts": 10, "pos": 30}, {"pts": 10, "pos": 30}], "alive": true}]
	check(int(SeasonScenarios.clinch_next(safe, 2, 6, pts)["place"]) == -1, "Clinch maths: a title already out of reach is settled whatever happens")
	# on the league data: a championship of the latest season builds, chances add up to 1
	var seasons := Elo.seasons()
	if seasons.is_empty():
		_skip("season scenarios on league data", "no league data")
	else:
		var season: String = seasons.back()
		var champs := Reports.season_points(season)
		if champs.is_empty():
			_skip("season scenarios on league data", "no championship in %s" % season)
		else:
			var sc := SeasonScenarios.build(season, str(champs.keys()[0]))
			await SeasonScenarios.title_chances(sc)
			# a round whose track is not confirmed: general form, no track fit, no error
			var names3: Array = (sc["rows"] as Array).slice(0, 6).map(func(r): return r["name"])
			var unk: Dictionary = await Predict.forecast(names3, str(sc["cls"]), Predict.Mode.PREDICTED_QUALI, SeasonScenarios.UNKNOWN_TRACK)
			var fit0 := true
			for r in unk["rows"]:
				fit0 = fit0 and absf(float(r["track_gap"])) < 1e-9
			check(unk["rows"].size() == names3.size() and fit0, "Forecast at a track not confirmed yet: general form only")
			var sum := 0.0
			for r in sc["rows"]:
				sum += float(r["title"])
			check(absf(sum - 1.0) < 1e-6 and int(sc["total"]) >= int(sc["done"]), "Season scenarios on %s: title chances add up (%d of %d rounds run)" % [season, sc["done"], sc["total"]])
			# what each of the top 3 needs: a card each, with lines; the leader's line is consistent with the clinch maths
			var req := SeasonScenarios.requirements(sc)
			var req_ok := req.size() == mini(3, (sc["rows"] as Array).size())
			for e in req:
				req_ok = req_ok and not (e["lines"] as Array).is_empty() and str(e.get("status", "")) != ""
			check(req_ok, "Season scenarios: what each of the top 3 needs", str(req.map(func(e): return e["lines"])))
			# the last round, place by place: a leader 6 clear (two rounds of 50, 41 vs 47, 44), one round left of 3, no drops in play
			var mk2 := func(name: String, p: Array, w: int) -> Dictionary:
				return {"name": name, "points": p[0] + p[1], "wins": w, "alive": true, "max": 0, "by_round": [{"pts": p[0], "pos": 1}, {"pts": p[1], "pos": 2}]}
			var sc2 := {"rows": [mk2.call("A", [50, 47], 1), mk2.call("B", [47, 44], 0)], "left": 1, "total": 3, "field": 20, "rounds_left": [{"round": 3, "course": "Monza"}]}
			var vals2 := LeagueSettings.all().duplicate(true)
			var before2 := LeagueSettings.all()
			vals2["drop_rounds"] = 0
			LeagueSettings.save_all(vals2)
			var r2 := SeasonScenarios.requirements(sc2)
			LeagueSettings.save_all(before2)
			# A (97) vs B (91): A champion with P3 (44 -> 141) or better whatever B does (B best 50 -> 141, A has more wins... level: A 1 win vs B 1 -> tie on wins); B: a win needs A P4 or lower
			check(str(r2[1]["lines"]).contains("A win: champion if A P"), "Last round: what the rival needs, place by place", str(r2.map(func(e): return e["lines"])))
			# three in it at the last round: P3's card names both P1 and P2 (not only the leader)
			var sc3 := {"rows": [mk2.call("Aa", [50, 50], 2), mk2.call("Bb", [47, 47], 0), mk2.call("Cc", [44, 47], 0)], "left": 1, "total": 3, "field": 20, "rounds_left": [{"round": 3, "course": "Monza"}]}
			LeagueSettings.save_all(vals2)
			var r3 := SeasonScenarios.requirements(sc3)
			LeagueSettings.save_all(before2)
			var c_lines := str(r3[2]["lines"])
			check(c_lines.contains("Aa P") and c_lines.contains("Bb P"), "What it takes: P3's conditions cover P1 and P2", c_lines)
			# both pages agree: the title fight's "champion with Px or better" = the leader's first line on page 2
			# (leader 12 clear with fewer wins than the rival: ties go the rival's way)
			var sc4 := {"rows": [mk2.call("Lead", [50, 41], 1), mk2.call("Chase", [47, 32], 0), mk2.call("Far", [20, 20], 0)], "left": 1, "total": 3, "field": 20,
				"rounds_left": [{"round": 3, "course": "Monza"}]}
			LeagueSettings.save_all(vals2)
			var cl4 := SeasonScenarios.clinch_next(sc4["rows"], 1, 3, LeagueSettings.points())
			var r4 := SeasonScenarios.requirements(sc4)
			LeagueSettings.save_all(before2)
			var q4 := int(cl4.get("place", 0))
			var first4 := str(r4[0]["lines"][0]) if not (r4[0]["lines"] as Array).is_empty() else ""
			check((q4 == 1 and first4.begins_with("Champion by winning")) or (q4 > 1 and first4.begins_with("Champion with P%d or better" % q4))
				or (q4 == -1 and first4.begins_with("Already champion")), "Title fight and What it takes agree on what the leader needs", "page 1: P%d, page 2: %s" % [q4, first4])
			# team championship: a team scores its two drivers' points (each after their own drops)
			var key := str(champs.keys()[0])
			var ch: Dictionary = champs[key]
			var ds: Array = ch["drivers"].keys()
			if ds.size() >= 2:
				var before := LeagueSettings.all()
				var vals := before.duplicate(true)
				var code := ""
				var names: Dictionary = LeagueSettings.get_value("series_names")
				for c in names:
					if str(names[c]) == str(ch["series"]):
						code = str(c)
				vals["teams"] = [{"season": int(season.trim_prefix("Season ")), "series": code, "cls": ch["cls"], "name": "Test Team", "drivers": [ds[0], ds[1]]}]
				LeagueSettings.save_all(vals)
				var tp: Dictionary = Reports.team_points(season).get(key, {}).get("teams", {}).get("Test Team", {})
				var want := int(ch["drivers"][ds[0]]["points"]) + int(ch["drivers"][ds[1]]["points"])
				check(not tp.is_empty() and int(tp["points"]) == want, "Team points: the sum of both drivers' points after their drops (%d)" % want)
				# team title fight: two full teams and a one-driver team (left out, as in the standings)
				if ds.size() >= 5:
					vals["teams"].append({"season": int(season.trim_prefix("Season ")), "series": code, "cls": ch["cls"], "name": "Other Team", "drivers": [ds[2], ds[3]]})
					vals["teams"].append({"season": int(season.trim_prefix("Season ")), "series": code, "cls": ch["cls"], "name": "Solo", "drivers": [ds[4]]})
					LeagueSettings.save_all(vals)
					var ts := SeasonScenarios.build_teams(season, key)
					var names_t: Array = (ts.get("rows", []) as Array).map(func(r): return r["name"])
					var sane := names_t.size() == 2 and not names_t.has("Solo")
					for r in ts.get("rows", []):
						sane = sane and int(r["max"]) >= int(r["min"]) and int(r["min"]) >= int(r["points"])
					check(sane, "Team scenarios: full teams only, best case above worst case", str(names_t))
					await SeasonScenarios.title_chances(ts)
					var tsum := 0.0
					for r in ts.get("rows", []):
						tsum += float(r["title"])
					check(absf(tsum - 1.0) < 1e-6, "Team title chances add up")
					var p := LeagueSettings.points()
					var pr := [[50, 50, 50, 50], [47, 47, 47, 47]]
					# 50s-driver wins both: 250 + 235; 47s-driver wins both: 247 + 241 (each drops their worst) -> 488
					check(SeasonScenarios._pair_score(pr, [int(p[0]), int(p[1])], 2, 6) == 488,
						"Team best case: the two drivers 1-2 in every round left, the better way round")
				LeagueSettings.save_all(before)
	# season recap: standings in points order, numbers and awards, at most one award each except the cleanest
	if not seasons.is_empty():
		var sr_season: String = seasons.back()
		var sr_champs := Reports.season_points(sr_season)
		if not sr_champs.is_empty():
			var sr := SeasonRecap.build(sr_season, str(sr_champs.keys()[0]))
			var st_ok := not sr.is_empty() and not (sr["standings"] as Array).is_empty()
			for i in range(1, (sr.get("standings", []) as Array).size()):
				st_ok = st_ok and int(sr["standings"][i - 1]["points"]) >= int(sr["standings"][i]["points"])
			var who := {}
			var dup := false
			for a in sr.get("awards", []):
				if who.has(a["name"]) and str(a["tag"]) != "CLEANEST DRIVER" and str(who[a["name"]]) != "CLEANEST DRIVER":
					dup = true
				who[a["name"]] = a["tag"]
			var races_ok := false
			for n in sr.get("numbers", []):
				races_ok = races_ok or (str(n["label"]) == "RACES" and int(n["value"]) == int(sr["done"]))
			check(st_ok and races_ok and not (sr["awards"] as Array).is_empty() and not dup,
				"Season recap of %s: standings, numbers and awards" % sr_champs.keys()[0], str(sr.get("awards", [])))
			check(not Reports.season_recap().is_empty(), "Season recap report builds")
			# timeline: one point per round, never going down (points only add up... until a round is dropped)
			var tl: Dictionary = sr.get("timeline", {})
			var tl_ok := (tl.get("leaders", []) as Array).size() == int(sr["done"]) and not (tl.get("lines", []) as Array).is_empty()
			for l in tl.get("lines", []):
				tl_ok = tl_ok and (l["points"] as Array).size() == int(sr["done"])
			for ld in tl.get("leaders", []):   # everyone who led is on the chart
				tl_ok = tl_ok and (tl["lines"] as Array).any(func(l): return l["name"] == ld)
			check(tl_ok, "Season recap timeline: every round, every leader on the chart")
			var tags := (sr["awards"] as Array).map(func(a): return str(a["tag"]))
			check(tags.has("IRON MAN") and tags.has("COMEBACK OF THE SEASON"), "Season recap awards include Iron man and Comeback of the season", str(tags))
			var place := {}
			for i in (sr["standings"] as Array).size():
				place[sr["standings"][i]["name"]] = i + 1
			var ud := (sr["awards"] as Array).filter(func(a): return a["tag"] == "UNDERDOG")
			check(ud.is_empty() or int(place.get(ud[0]["name"], 0)) > 3, "Underdog comes from outside the top 3")
	# race recap judged on a picked forecast: one that had the finishing order upside down makes the
	# winner its outsider and someone a surprise; "none" drops the forecast line
	for i in range(Elo.history.size() - 1, -1, -1):
		var h: Dictionary = Elo.history[i]
		var rows_r := (h["changes"] as Array).filter(func(c): return c["sess"] == "race")
		if rows_r.size() < 8:
			continue
		var cls_r := str(rows_r[0]["cls"])
		var field := rows_r.filter(func(c): return str(c["cls"]) == cls_r)
		field.sort_custom(func(a, b): return int(a["pos"]) < int(b["pos"]))
		var fake_rows := []
		for j in field.size():
			fake_rows.append({"name": str(field[j]["driver"]), "exp_pos": float(field.size() - j), "win": 0.01 if j == 0 else 0.1})
		var fake := {"class": cls_r, "made_at": 1, "rows": fake_rows}
		var rc_fc := RaceRecap.build(str(h["file"]), [fake])
		var rc_none := RaceRecap.build(str(h["file"]), [])
		var blk: Dictionary = (rc_fc["classes"] as Array).filter(func(b): return str(b["cls"]) == cls_r)[0]
		var blk0: Dictionary = (rc_none["classes"] as Array).filter(func(b): return str(b["cls"]) == cls_r)[0]
		var sur := (blk["highlights"] as Array).filter(func(x): return x["tag"] == "BIGGEST SURPRISE")
		check(not bool(blk["forecast"].get("fav_won", true)) and absf(float(blk["forecast"].get("chance", 0)) - 0.01) < 1e-9
			and not sur.is_empty() and str(sur[0]["text"]).contains("forecast") and (blk0["forecast"] as Dictionary).is_empty(),
			"Race recap judged on a picked forecast (and on none)", str(blk["forecast"]))
		break
	# race recap of the latest race: a block per class, podium of 3, a surprise only when deserved
	var last_race := ""
	for i in range(Elo.history.size() - 1, -1, -1):
		for c in Elo.history[i]["changes"]:
			if c["sess"] == "race":
				last_race = str(Elo.history[i]["file"])
				break
		if last_race != "":
			break
	if last_race != "":
		var rc := RaceRecap.build(last_race)
		var ok := not rc.is_empty() and int(rc["round"]) >= 1 and not (rc["classes"] as Array).is_empty()
		for b in rc.get("classes", []):
			ok = ok and (b["podium"] as Array).size() == mini(3, (b["podium"] as Array).size()) and int(b["podium"][0]["pos"]) == 1
			for h in b["highlights"]:
				if str(h["tag"]) == "BIGGEST SURPRISE":
					var parts := str(h["text"]).replace("P", "").split(", expected ")
					ok = ok and int(parts[0]) < int(parts[1])
		check(ok, "Race recap of %s: every class has its podium; a surprise beat its expected place" % last_race)
		# lap-by-lap leaders, clean chargers and firsts are consistent with the results
		var leads := RaceRecap._lead_info(last_race)
		var ok2 := true
		for b in rc.get("classes", []):
			var li: Dictionary = leads.get(b["cls"], {})
			if not li.is_empty():
				var sum := 0
				for d in li["led"]:
					sum += int(li["led"][d])
				ok2 = ok2 and sum == int(li["laps"]) and int(li["changes"]) < int(li["laps"])
			for h in b["highlights"]:
				if str(h["tag"]) == "CLEAN CHARGER":
					ok2 = ok2 and str(h["text"]).ends_with("no contact")
				if str(h["tag"]) == "FIRST WIN":
					ok2 = ok2 and str(b["podium"][0]["name"]) == str(h["name"])
		check(ok2, "Race recap highlights: laps led add up, clean chargers had no contact, a first win is the winner")


func _test_screens() -> void:
	_section("Screens")
	var screen = load("res://control.tscn").instantiate()
	add_child(screen)
	for i in 5:
		await get_tree().process_frame
	var ok := true
	for v in ["ratings", "drivers", "reports", "profiles", "predict", "penalties", "graphics", "settings", "review"]:
		screen.show_view(v)
		await get_tree().process_frame
		ok = ok and screen.has_method("show_view")
	check(ok, "Every screen opens")
	var rv = screen.reports_view
	var reports_ok := true
	for i in rv.report_picker.item_count:
		rv.report_picker.select(i)
		rv._run()
		await get_tree().process_frame
	check(reports_ok and rv.report_picker.item_count > 0, "Every report runs (%d)" % rv.report_picker.item_count)
	# names are shown tidied, but the stored name is still what gets looked up
	var tidy := true
	for t in Reports.consistency():
		for r in t["rows"]:
			tidy = tidy and str(r[0]) == Elo.pretty(str(r[0]))
	var dv = screen.driver_view
	var raw := str(dv.picker.get_item_metadata(0)) if dv.picker.item_count > 0 else ""
	check(tidy and raw != "" and Elo.known_names().has(raw) and dv.picker.get_item_text(0).begins_with(Elo.pretty(raw))
		and not Reports.driver_profile(raw)[0]["rows"].is_empty(),
		"Reports and the Drivers screen show tidied names and still find the driver")
	screen.show_view("predict")
	var pv = screen.predict_view
	for i in pv.class_pick.item_count:
		if str(pv.class_pick.get_item_metadata(i)) == pv.ALL:
			pv.class_pick.select(i)
			pv.class_pick.item_selected.emit(i)
	pv._fill_recent()
	await pv._run()
	check(pv.tree.get_root() != null and pv.tree.get_root().get_child_count() > 0, "All-classes forecast fills the table")
	screen.show_view("graphics")
	var gv = screen.graphics_view
	var built := 0
	for k in gv.KINDS.size():
		gv.kind_pick.select(k)
		gv.kind_pick.item_selected.emit(k)
		for f in gv.FORMATS.size():
			gv.format_pick.select(f)
			gv.format_pick.item_selected.emit(f)
			await get_tree().process_frame
			if gv.card.get_child_count() > 0 and gv.viewport.size == gv.FORMATS[f][1]:
				built += 1
	check(built == gv.KINDS.size() * gv.FORMATS.size(), "Every graphic builds in every size (%d)" % built)
	# a title font chosen after images were already made must be used on the next image
	var custom_font := SystemFont.new()
	custom_font.font_names = PackedStringArray(["serif"])
	var base_spec: Dictionary = gv.card.spec.duplicate()
	gv.card.set_spec(base_spec)
	var before_font: Font = gv.card._font("title")
	var with_font := base_spec.duplicate()
	with_font["brand"] = base_spec.get("brand", {}).duplicate()
	with_font["brand"]["title_font"] = custom_font
	gv.card.set_spec(with_font)
	var after_font: Font = gv.card._font("title")
	gv.card.set_spec(base_spec)
	check(after_font == custom_font and before_font != custom_font and gv.card._font("title") != custom_font, "A title font chosen later is used on the next image (and removed again)")
	# a background photo (a made-up image), and a class's driver cards for the batch
	var photo := Image.create(64, 40, false, Image.FORMAT_RGB8)
	photo.fill(Color("336699"))
	var photo_path := tmp.path_join("background.png")
	photo.save_png(photo_path)
	gv._set_background(photo_path)
	check(gv._background() is Texture2D and gv.card.photo, "A background photo is used on the image")
	gv._set_background("")
	check(gv._background() == null and not gv.card.photo, "Clearing it brings back the plain background")
	var cls0: String = Elo.boards()[0][0]
	var drivers: Array = gv.batch_drivers("", cls0, "")
	var all_raced := {}
	for e in Elo.history:
		for c in e["changes"]:
			if c["sess"] == "race" and c["cls"] == cls0:
				all_raced[Elo.resolve(str(c["driver"]))] = true
	check(drivers.size() == all_raced.size() and drivers.size() > 0, "Batch: every driver who raced the class gets a card (%d)" % drivers.size())
	var season: String = Elo.seasons()[-1]
	check(gv.batch_drivers("", cls0, season).size() <= drivers.size(), "Batch: a season narrows the list")
	var dspec: Dictionary = gv._driver_spec(str(drivers[0]), cls0)
	check(dspec["grade_class"] == cls0 and str(dspec["stats"][0][0]).begins_with(LeagueSettings.label(cls0)), "A driver card can be made for a chosen class")
	# track card for a series: a track the league raced, without a telemetry profile (none in the
	# test data): one row per class of the series, the race length given, notes kept
	var ev0: Dictionary = {}
	for e in Elo.history:
		if Elo.series_code(str(e["file"])) != "" and str(e.get("course", "")) != "":
			ev0 = e
	var code0 := Elo.series_code(str(ev0["file"]))
	var mins: int = gv.series_minutes(str(ev0["course"]), code0)
	check(mins > 0, "Track card: race length from the series' last race there (%d min)" % mins)
	var tspec: Dictionary = gv.track_spec(str(ev0["course"]), code0, 60, "Overtaking zones: T1")
	var ncls: int = Predict.series_classes(code0).size()
	check(tspec["map"].is_empty() and tspec["class_rows"].size() == ncls and ncls > 0, "Track card: one row per class of the series (%d)" % ncls)
	var with_laps: Array = tspec["class_rows"].filter(func(r): return str(r[2]).begins_with("~"))
	check(not with_laps.is_empty() and ["Race length", "60 min"] in tspec["facts"], "Track card: laps for the race length chosen")
	check(tspec["notes"] == "Overtaking zones: T1" and not tspec["winners"].is_empty(), "Track card keeps the notes and lists past winners")
	# pit stops column only for series that stop; favourites from the forecast on the Predict screen
	check(tspec["show_stops"] == bool(LeagueSettings.rules_for(code0, 0)["pits"]), "Track card: stops column only when the series makes pit stops")
	var split_ok: bool = tspec["grade_classes"].size() == ncls and tspec["grades"].all(func(g): return g["by_class"].size() == ncls)
	check(split_ok and not tspec["grades"].is_empty(), "Track card: grades kept per class for the split pips (%d lines)" % tspec["grades"].size())
	# a class with no league race at a track where another class raced: overtaking and incidents
	# estimated (hatched) on the card, never in the real grades
	var raced := {}   # course -> {class: true}
	for e in Elo.history:
		for c in e["changes"]:
			if c["sess"] == "race":
				if not raced.has(e["course"]):
					raced[e["course"]] = {}
				raced[e["course"]][c["cls"]] = true
	var gap := []
	for course in raced:
		for b in Elo.boards():
			if not raced[course].has(b[0]) and gap.is_empty():
				gap = [course, b[0]]
	if gap.is_empty():
		_skip("estimated grades", "every class raced every track in the data")
	else:
		var est_rows: Array = TrackGrades.grade(gap[0], gap[1], true).filter(func(r): return r.get("estimated", false))
		var real_rows: Array = TrackGrades.grade(gap[0], gap[1]).filter(func(r): return r["id"] in ["overtake", "incidents"] and int(r["grade"]) > 0)
		check(not est_rows.is_empty() and real_rows.is_empty(), "Estimated overtaking / incident grades for %s at %s, card only" % [gap[1], gap[0]], str(est_rows.map(func(r): return r["basis"])))
		var says_how: bool = est_rows.all(func(r): return str(r["basis"]).contains("typically within") or str(r["basis"]).contains("training"))
		check(says_how, "Each estimate names its method and typical error", str(est_rows.map(func(r): return r["basis"])))
		# the methods are scored on left-out tracks: every score is a real number with enough tracks
		var est: Dictionary = TrackGrades._estimator(gap[1], "incidents_10")
		var scores_ok: bool = not est["scores"].is_empty()
		for m in est["scores"]:
			scores_ok = scores_ok and int(est["scores"][m]["n"]) >= 5 and is_finite(float(est["scores"][m]["err"]))
		check(scores_ok, "Estimate methods scored on left-out tracks (%s)" % ", ".join(PackedStringArray(est["scores"].keys())))
	var no_pits := ""
	for code in LeagueSettings.get_value("series_names"):
		if not bool(LeagueSettings.rules_for(str(code), 0)["pits"]):
			no_pits = str(code)
	if no_pits != "":
		check(not gv.track_spec(str(ev0["course"]), no_pits, 30)["show_stops"], "Track card: no stops column for a series without stops (%s)" % no_pits)
	var fav: Dictionary = gv.track_spec(str(ev0["course"]), code0, 60, "", gv.WATCH_PREDICT)
	var series_cls: Array = Predict.series_classes(code0).map(func(c): return LeagueSettings.label(c))
	var fav_ok: bool = fav["watch_title"] == "FAVOURITES" and fav["watch"].all(func(w): return str(w[0]) in series_cls)
	check(fav_ok, "Track card: favourites from a forecast, only the series' classes (%d)" % fav["watch"].size())
	if DisplayServer.get_name() == "headless":   # nothing is drawn in headless mode, so no picture to check
		_skip("image rendering", "needs a window (the test scripts run without one)")
	else:
		await RenderingServer.frame_post_draw
		var img: Image = gv.viewport.get_texture().get_image()
		check(img != null and img.get_size() == gv.FORMATS[gv.FORMATS.size() - 1][1], "The image renders at its full size")
	screen.queue_free()
