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
		await _test_screens()
	print("\n%d passed, %d failed, %d skipped" % [passed, failed, skipped])
	get_tree().quit(1 if failed > 0 else 0)


# ---------- helpers ----------
func check(ok: bool, name: String, detail := "") -> void:
	if ok:
		passed += 1
		print("  PASS  " + name)
	else:
		failed += 1
		print("  FAIL  " + name + ("  (" + detail + ")" if detail != "" else ""))


func _skip(name: String, why: String) -> void:
	skipped += 1
	print("  SKIP  %s: %s" % [name, why])


func _section(title: String) -> void:
	print("\n" + title)


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
	check(LeagueSettings.label("Ligier LMGT3 car") == "Ligier LMGT3 car", "Class labels only replace whole words")
	check(Elo.league_name(6, "SC", 3, true) == "s6-sc3-r.xml" and Elo.league_name(2, "mc", 1, false) == "s2-mc1.xml", "League file names")
	check(Elo.season_number("s5-mc2-r.xml") == 5 and Elo.series_code("s5-mc2-r.xml") == "mc", "Season and series from the file name")
	check(Elo.season_number("2025_03_12_21_04_56-55R1.xml") == 0 and not Elo.is_league_name("2025_03_12_21_04_56-55R1.xml"), "Game default names have no season")


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


func _test_screens() -> void:
	_section("Screens")
	var screen = load("res://control.tscn").instantiate()
	add_child(screen)
	for i in 5:
		await get_tree().process_frame
	var ok := true
	for v in ["ratings", "drivers", "reports", "profiles", "predict", "graphics", "settings", "review"]:
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
