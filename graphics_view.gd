class_name GraphicsView
extends HBoxContainer
## "Graphics" screen: images for social media and the stream (graphic_card.gd), previewed here and
## saved as PNG in Documents/LMU_Elo graphics. League name, colour and logo: Settings > Graphics.
## The background photo (it changes from race to race) is chosen here and remembered in
## user://ui.cfg, not in the league settings. Driver cards can also be saved in one go for every
## driver of a class (in a series and season).

signal notice(text: String)

const KINDS := [["forecast", "Event predictions"], ["standings", "Championship standings"], ["season", "Season scenarios"], ["teams", "Team standings"], ["ranks", "Driver ranks"], ["driver", "Driver card"],
	["track", "Track card"]]
const FORMATS := [["Instagram post (1080 x 1350)", Vector2i(1080, 1350)], ["Instagram story (1080 x 1920)", Vector2i(1080, 1920)],
	["Stream (1920 x 1080)", Vector2i(1920, 1080)]]
const OUT_DIR_NAME := "LMU_Elo graphics"
const UI_CFG := "user://ui.cfg"

var shell: Node   # the main screen: the Predict screen's current forecast lives there

var kind_pick := OptionButton.new()
var format_pick := OptionButton.new()
var source_label := Label.new()
var source_pick := OptionButton.new()   # forecast / season / class / driver, depending on the kind
var champ_label := Label.new()
var champ_pick := OptionButton.new()    # standings: which championship of the season; driver card: which class
var title_edit := LineEdit.new()
var corners_check := CheckBox.new()     # track card: show the detected corner numbers on the map
var rain_check := CheckBox.new()        # event predictions, mixed weather: the "if it rains" strip
var watch_label := Label.new()
var watch_pick := OptionButton.new()    # track card: drivers to watch from history or a forecast
var minutes_label := Label.new()
var minutes_spin := SpinBox.new()       # track card: race length
var notes_label := Label.new()
var notes_edit := TextEdit.new()        # track card: your own notes, kept per track
var save_btn := Button.new()
var info := Label.new()
var bg_path := LineEdit.new()           # shows the background photo's file name
var _bg_file := ""                      # its full path ("" = the plain league background)
var bg_dialog := FileDialog.new()
var tint_slider := HSlider.new()
var _bg_cache := {}                     # path -> Texture2D
var _font_cache := {}                   # path -> Font (or null when the file cannot be read)
var page_label := Label.new()
var page_pick := OptionButton.new()     # standings on the stream size: which page of 10 to preview
var batch_pages := CheckBox.new()       # on: Save writes every page, each marked "page x of y"
const STREAM_PER_PAGE := 10
var batch_box := VBoxContainer.new()    # driver cards for a whole class
var batch_series := OptionButton.new()
var batch_class := OptionButton.new()
var batch_season := OptionButton.new()
var batch_btn := Button.new()
var _batch_running := false
var viewport := SubViewport.new()
var card := GraphicCard.new()
var preview := TextureRect.new()


func _ready() -> void:
	add_theme_constant_override("separation", 20)
	var left_scroll := ScrollContainer.new()
	left_scroll.custom_minimum_size = Vector2(330, 0)
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(left_scroll)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 10)
	left_scroll.add_child(left)
	for k in KINDS:
		kind_pick.add_item(k[1])
	for f in FORMATS:
		format_pick.add_item(f[0])
	for pair in [["Image", kind_pick], ["Size", format_pick], [source_label, source_pick], [champ_label, champ_pick]]:
		var l: Label = pair[0] if pair[0] is Label else _muted(str(pair[0]))
		l.theme_type_variation = "Muted"
		left.add_child(l)
		var c: Control = pair[1]
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if c is OptionButton:
			(c as OptionButton).clip_text = true
		left.add_child(c)
	left.add_child(_muted("Title (empty = automatic)"))
	title_edit.placeholder_text = "automatic"
	left.add_child(title_edit)
	minutes_label.text = "Race length"
	minutes_label.theme_type_variation = "Muted"
	left.add_child(minutes_label)
	minutes_spin.min_value = 5
	minutes_spin.max_value = 1440
	minutes_spin.step = 5
	minutes_spin.suffix = "min"
	minutes_spin.tooltip_text = "Sets the laps and pit stops on the card. Starts at the length of the series' last race here."
	minutes_spin.value_changed.connect(func(_v): _render())
	left.add_child(minutes_spin)
	corners_check.text = "Corner numbers on the map"
	corners_check.tooltip_text = "The numbers come from the telemetry (each braking corner), not the official turn numbers, and can be off on some tracks."
	corners_check.toggled.connect(func(on: bool):
		_save_ui("corner_numbers", on)
		_render())
	left.add_child(corners_check)
	rain_check.text = "\"If it rains\" strip"
	rain_check.tooltip_text = "Mixed-weather forecasts: under the race results, who gains and who loses the most when rain comes."
	rain_check.button_pressed = true
	rain_check.toggled.connect(func(on: bool):
		_save_ui("rain_strip", on)
		_render())
	left.add_child(rain_check)
	watch_label.text = "Drivers to watch"
	watch_label.theme_type_variation = "Muted"
	left.add_child(watch_label)
	watch_pick.clip_text = true
	watch_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	watch_pick.tooltip_text = "Track history: drivers with this track as a strong spot. A forecast: its favourites, the two most likely winners of each class."
	watch_pick.item_selected.connect(func(_i): _render())
	left.add_child(watch_pick)
	notes_label.text = "Notes on the card (kept for this track)"
	notes_label.theme_type_variation = "Muted"
	left.add_child(notes_label)
	notes_edit.placeholder_text = "e.g. Overtaking zones: T1, T5, T11\nHard corners: T6, Corkscrew"
	notes_edit.custom_minimum_size = Vector2(0, 90)
	notes_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	notes_edit.text_changed.connect(func():
		if _kind() == "track" and source_pick.selected >= 0:
			_save_ui_section("track_notes", source_pick.get_item_text(source_pick.selected), notes_edit.text)
		_render())
	left.add_child(notes_edit)

	# background photo: usually a shot of this race's track or cars
	left.add_child(_muted("Background photo"))
	var bg_row := HBoxContainer.new()
	bg_path.placeholder_text = "none (league colours)"
	bg_path.editable = false
	bg_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg_path.tooltip_text = "A photo shown behind everything, under the league purple. Remembered until you change it."
	bg_row.add_child(bg_path)
	bg_row.add_child(_btn("Choose...", func(): bg_dialog.popup_centered_ratio(0.6)))
	bg_row.add_child(_btn("Clear", func(): _set_background("")))
	left.add_child(bg_row)
	var tint_row := HBoxContainer.new()
	tint_row.add_child(_muted("Purple tint"))
	tint_slider.min_value = 0.3
	tint_slider.max_value = 0.95
	tint_slider.step = 0.05
	tint_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tint_slider.tooltip_text = "How strongly the photo is covered by the league purple: more tint, easier to read."
	tint_row.add_child(tint_slider)
	left.add_child(tint_row)
	bg_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	bg_dialog.access = FileDialog.ACCESS_FILESYSTEM
	bg_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	bg_dialog.use_native_dialog = true
	bg_dialog.file_selected.connect(func(p: String): _set_background(p))
	add_child(bg_dialog)
	var cfg := ConfigFile.new()
	cfg.load(UI_CFG)
	_show_bg_name(str(cfg.get_value("graphics", "background", "")))
	tint_slider.value = float(cfg.get_value("graphics", "tint", 0.7))
	corners_check.set_pressed_no_signal(bool(cfg.get_value("graphics", "corner_numbers", false)))
	rain_check.set_pressed_no_signal(bool(cfg.get_value("graphics", "rain_strip", true)))
	tint_slider.value_changed.connect(func(v: float):
		_save_ui("tint", v)
		_render())
	page_label.text = "Page"
	page_label.theme_type_variation = "Muted"
	left.add_child(page_label)
	page_pick.tooltip_text = "The stream size shows the whole field, 10 drivers a page. Save PNG saves every page."
	page_pick.item_selected.connect(func(_i): _render())
	left.add_child(page_pick)
	batch_pages.text = "Batch save"
	batch_pages.button_pressed = true
	batch_pages.tooltip_text = "On: Save PNG saves every page, each marked \"page x of y\".\nOff: it saves only the page shown, without the page mark."
	batch_pages.toggled.connect(func(_on): _render())
	left.add_child(batch_pages)
	save_btn.text = "Save PNG"
	save_btn.theme_type_variation = "AccentButton"
	save_btn.pressed.connect(_save)
	left.add_child(save_btn)
	# all driver cards of a class at once
	batch_box.add_theme_constant_override("separation", 6)
	var bh := Label.new()
	bh.text = "ALL DRIVER CARDS OF A CLASS"
	bh.theme_type_variation = "HeaderSmall"
	batch_box.add_child(HSeparator.new())
	batch_box.add_child(bh)
	for pair in [["Series", batch_series], ["Class", batch_class], ["Season", batch_season]]:
		batch_box.add_child(_muted(str(pair[0])))
		var ob: OptionButton = pair[1]
		ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ob.clip_text = true
		ob.item_selected.connect(func(_i): _update_batch_count())
		batch_box.add_child(ob)
	batch_btn.pressed.connect(_save_batch)
	batch_box.add_child(batch_btn)
	var bn := _muted("Each driver who raced that class in the series and season gets a card (with their grades and ratings in that class), saved in one folder, in the size chosen above.")
	bn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	batch_box.add_child(bn)
	left.add_child(batch_box)

	info.theme_type_variation = "Muted"
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.text = "League name, colour and logo: Settings > Graphics. Images are saved in Documents/%s." % OUT_DIR_NAME
	left.add_child(info)

	kind_pick.item_selected.connect(func(_i):
		_fill_sources()
		_render())
	format_pick.item_selected.connect(func(_i): _render())
	source_pick.item_selected.connect(func(_i):
		_fill_champs()
		_render())
	champ_pick.item_selected.connect(func(_i):
		if _kind() == "track":
			_default_minutes()
		_render())
	title_edit.text_changed.connect(func(_t): _render())

	# the image is drawn off screen at full size; the preview shows it scaled to fit
	viewport.disable_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.add_child(card)
	add_child(viewport)
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = viewport.get_texture()
	add_child(preview)


func refresh() -> void:
	_fill_sources()
	_render()


# ---------- pickers ----------
func _kind() -> String:
	return KINDS[maxi(kind_pick.selected, 0)][0]


func _fill_sources() -> void:
	var keep := source_pick.get_item_text(source_pick.selected) if source_pick.selected >= 0 else ""
	source_pick.clear()
	champ_label.visible = false
	champ_pick.visible = false
	match _kind():
		"forecast":
			source_label.text = "Forecast"
			source_pick.add_item("The forecast on the Predict screen")
			source_pick.set_item_metadata(0, -1)
			var groups := _saved_forecast_groups()
			for i in range(groups.size() - 1, -1, -1):   # newest first
				var g: Array = groups[i]
				var classes := PackedStringArray(g.map(func(fc): return LeagueSettings.label(str(fc["class"]))))
				source_pick.add_item("Saved %s: %s, %s" % [Time.get_datetime_string_from_unix_time(int(g[0]["made_at"])).replace("T", " ").left(16),
					", ".join(classes), str(g[0].get("course", ""))])
				source_pick.set_item_metadata(source_pick.item_count - 1, i)
		"standings", "season", "teams":
			source_label.text = "Season"
			var seasons := Elo.seasons()
			for i in range(seasons.size() - 1, -1, -1):
				source_pick.add_item(str(seasons[i]))
			champ_label.text = "Championship"
			champ_label.visible = true
			champ_pick.visible = true
		"ranks":
			source_label.text = "Class"
			var classes := Ranks.all().keys()
			classes.sort()
			for c in classes:
				source_pick.add_item(LeagueSettings.label(str(c)))
				source_pick.set_item_metadata(source_pick.item_count - 1, c)
		"driver":
			source_label.text = "Driver"
			var names := Elo.known_names()
			names.sort_custom(func(a, b): return str(a).to_lower() < str(b).to_lower())
			for n in names:
				source_pick.add_item(str(n))
			champ_label.text = "Class"
			champ_label.visible = true
			champ_pick.visible = true
		"track":
			source_label.text = "Track"
			for c in _track_courses():
				source_pick.add_item(str(c))
			champ_label.text = "Series"
			champ_label.visible = true
			champ_pick.visible = true
	for i in source_pick.item_count:
		if source_pick.get_item_text(i) == keep:
			source_pick.select(i)
	_fill_champs()
	batch_box.visible = _kind() == "driver"
	notes_label.visible = _kind() == "track"
	minutes_label.visible = _kind() == "track"
	minutes_spin.visible = _kind() == "track"
	watch_label.visible = _kind() == "track"
	corners_check.visible = _kind() == "track"
	rain_check.visible = _kind() == "forecast"
	watch_pick.visible = _kind() == "track"
	notes_edit.visible = _kind() == "track"
	_load_notes()
	if batch_box.visible:
		_fill_batch()


func _fill_champs() -> void:
	if _kind() == "driver":
		_fill_driver_classes()
		return
	if _kind() == "track":
		_fill_track_series()
		_load_notes()
		_default_minutes()
		_fill_watch()
		return
	if _kind() != "standings" and _kind() != "season" and _kind() != "teams":
		return
	var keep := champ_pick.get_item_text(champ_pick.selected) if champ_pick.selected >= 0 else ""
	champ_pick.clear()
	if source_pick.selected < 0:
		return
	var src := source_pick.get_item_text(source_pick.selected)
	var champs := Reports.team_points(src) if _kind() == "teams" else Reports.season_points(src)
	var keys := champs.keys()
	keys.sort()
	for k in keys:
		champ_pick.add_item(LeagueSettings.label(str(k)))
		champ_pick.set_item_metadata(champ_pick.item_count - 1, k)
		if LeagueSettings.label(str(k)) == keep:
			champ_pick.select(champ_pick.item_count - 1)


# ---------- track card ----------
# Every track with a telemetry profile or a league result, alphabetical.
func _track_courses() -> Array:
	var seen := {}
	for p in TrackStore.list():
		seen[str(p["course"])] = true
	for ev in Elo.history:
		if str(ev.get("course", "")) != "":
			seen[str(ev["course"])] = true
	var out := seen.keys()
	out.sort()
	return out


# Series: the ones that raced this track first (latest first), then the others.
func _fill_track_series() -> void:
	var keep := champ_pick.get_item_text(champ_pick.selected) if champ_pick.selected >= 0 else ""
	champ_pick.clear()
	if source_pick.selected < 0:
		return
	var course := source_pick.get_item_text(source_pick.selected)
	var order := []
	for i in range(Elo.history.size() - 1, -1, -1):
		var ev: Dictionary = Elo.history[i]
		var code := Elo.series_code(str(ev["file"]))
		if str(ev.get("course", "")) == course and code != "" and code not in order:
			order.append(code)
	var names: Dictionary = LeagueSettings.get_value("series_names")
	for code in names:
		if code not in order:
			order.append(code)
	for code in order:
		champ_pick.add_item(str(names.get(code, str(code).to_upper())))
		champ_pick.set_item_metadata(champ_pick.item_count - 1, code)
		if champ_pick.get_item_text(champ_pick.item_count - 1) == keep:
			champ_pick.select(champ_pick.item_count - 1)


# Drivers to watch: track history, or a forecast (the Predict screen's, then saved ones, those for
# this track first).
const WATCH_HISTORY := -2
const WATCH_PREDICT := -1
var _watch_course := ""   # the track the watch choice was made for: a new track starts from history


func _fill_watch() -> void:
	var keep := watch_pick.get_item_text(watch_pick.selected) if watch_pick.selected >= 0 else ""
	var course_now := source_pick.get_item_text(source_pick.selected) if source_pick.selected >= 0 else ""
	if course_now != _watch_course:
		keep = ""
		_watch_course = course_now
	watch_pick.clear()
	watch_pick.add_item("Track history (strong spots)")
	watch_pick.set_item_metadata(0, WATCH_HISTORY)
	if shell != null and not shell.predict_view._last_results.is_empty():
		watch_pick.add_item("Forecast on the Predict screen")
		watch_pick.set_item_metadata(watch_pick.item_count - 1, WATCH_PREDICT)
	var course := source_pick.get_item_text(source_pick.selected) if source_pick.selected >= 0 else ""
	var groups := _saved_forecast_groups()
	var here := []
	var other := []
	for i in range(groups.size() - 1, -1, -1):   # newest first
		(here if str(groups[i][0].get("course", "")) == course else other).append(i)
	for i in here + other:
		var g: Array = groups[i]
		watch_pick.add_item("Saved forecast %s: %s, %s" % [Time.get_datetime_string_from_unix_time(int(g[0]["made_at"])).replace("T", " ").left(16),
			", ".join(PackedStringArray(g.map(func(fc): return LeagueSettings.label(str(fc["class"]))))), str(g[0].get("course", ""))])
		watch_pick.set_item_metadata(watch_pick.item_count - 1, i)
	for i in watch_pick.item_count:
		if watch_pick.get_item_text(i) == keep:
			watch_pick.select(i)


# The classes of a forecast: [{"cls", "rows"}]. src = WATCH_PREDICT or a saved group index.
func _forecast_classes(src: int) -> Array:
	var out := []
	if src == WATCH_PREDICT:
		if shell != null:
			for e in shell.predict_view._last_results:
				out.append({"cls": e["cls"], "rows": e["res"]["rows"]})
	elif src >= 0:
		var groups := _saved_forecast_groups()
		if src < groups.size():
			for fc in groups[src]:
				out.append({"cls": fc["class"], "rows": fc["rows"]})
	return out


# Race length: the series' last race at this track, else its last race anywhere.
func _default_minutes() -> void:
	if source_pick.selected < 0 or champ_pick.selected < 0:
		return
	minutes_spin.set_block_signals(true)
	minutes_spin.value = series_minutes(source_pick.get_item_text(source_pick.selected), str(champ_pick.get_item_metadata(champ_pick.selected)))
	minutes_spin.set_block_signals(false)


func series_minutes(course: String, series: String) -> int:
	Profiles.ensure()
	var anywhere := 0
	for i in range(Profiles.days.size() - 1, -1, -1):
		var day: Dictionary = Profiles.days[i]
		var m := roundi(float(day["race"].get("minutes", 0.0))) if not day["race"].is_empty() else 0
		if m <= 0 or str(day.get("series", "")) != series or day.get("training", false):
			continue
		if str(day["course"]) == course:
			return m
		if anywhere == 0:
			anywhere = m
	return anywhere if anywhere > 0 else 30


func _load_notes() -> void:
	if _kind() != "track" or source_pick.selected < 0:
		return
	var cfg := ConfigFile.new()
	cfg.load(UI_CFG)
	var t := str(cfg.get_value("track_notes", source_pick.get_item_text(source_pick.selected), ""))
	if notes_edit.text != t:
		notes_edit.set_block_signals(true)
		notes_edit.text = t
		notes_edit.set_block_signals(false)


func _track_spec() -> Dictionary:
	if source_pick.selected < 0 or champ_pick.selected < 0:
		return {"kind": "track", "title": "Track card", "subtitle": "No track data yet.", "empty": true}
	var course := source_pick.get_item_text(source_pick.selected)
	var series := str(champ_pick.get_item_metadata(champ_pick.selected))
	var watch_src := int(watch_pick.get_item_metadata(watch_pick.selected)) if watch_pick.selected >= 0 else WATCH_HISTORY
	return track_spec(course, series, int(minutes_spin.value), notes_edit.text, watch_src)


# Everything the track card shows for one track and series: grades averaged over the series'
# classes, one row per class (lap, laps, stops) for a race of `minutes`.
func track_spec(course: String, series: String, minutes: int, notes := "", watch_src := WATCH_HISTORY) -> Dictionary:
	var classes: Array = Predict.series_classes(series)   # fastest first
	var rule := LeagueSettings.rules_for(series, 0)
	var profs := {}    # class -> telemetry profile
	for p in TrackStore.list():
		if str(p["course"]) == course and str(p["class"]) in classes:
			profs[str(p["class"])] = p
	var prof := {}
	for c in classes:   # the map and length from the fastest class with telemetry
		if prof.is_empty() and profs.has(c):
			prof = profs[c]
	# grades: one value per class on each line (0 = no data for that class), in the usual order;
	# the card splits each pip between the classes
	var per := {}   # trait name -> {class: grade}
	var est := {}   # trait name -> {class: true} for grades from training races or estimates
	var est_notes := PackedStringArray()
	for c in classes:
		for g in TrackGrades.grade(course, c, true):
			if int(g["grade"]) > 0:
				if not per.has(g["name"]):
					per[g["name"]] = {}
					est[g["name"]] = {}
				per[g["name"]][c] = int(g["grade"])
				if g.get("estimated", false):
					est[g["name"]][c] = true
					est_notes.append("%s %s %s" % [LeagueSettings.label(c), str(g["name"]).to_lower(), g["basis"]])
	var grades := []
	for t in TrackGrades.TRAITS:
		if per.has(t["name"]):
			var by: Array = classes.map(func(c): return int(per[t["name"]].get(c, 0)))
			var hatched: Array = classes.map(func(c): return bool(est[t["name"]].get(c, false)))
			grades.append({"name": t["name"], "grade": by[0], "by_class": by, "est_by_class": hatched})
	var grade_note := ""
	# one row per class: race lap, laps in the race, planned stops
	var rows := []
	for c in classes:
		var info := Profiles.track_info(course, c)
		Predict.fill_pit_data(info, c, course)
		# race lap: the telemetry lap + its class factor (Predict.tel_ratio) when the class has telemetry here, else the front-runners'
		# race pace from the league results
		var ref := float(info.get("ref_s", 0.0))
		var tel := Predict.telemetry_race_lap(course, c)
		if tel > 0.0:
			ref = tel
		elif not bool(info.get("known_race", false)):
			rows.append([LeagueSettings.label(c), "-", "-", "-"])
			continue
		var laps := int(minutes * 60.0 / ref) + 1   # timed race: the lap running at the flag counts, as in the predictor
		var stops := 0
		if bool(rule["pits"]):
			stops = int(rule["min_stops"])
			if float(info.get("tank_laps", 0.0)) > 0.0:
				stops = maxi(stops, int(ceil(laps / (float(info["tank_laps"]) / float(rule["fuel"])))) - 1)
			if float(info.get("tyre_laps", 0.0)) > 0.0:
				stops = maxi(stops, int(ceil(laps / (float(info["tyre_laps"]) / float(rule["tyre"])))) - 1)
		rows.append([LeagueSettings.label(c), "%d:%04.1f" % [int(ref / 60.0), fmod(ref, 60.0)], "~%d" % laps, str(stops)])
	var facts := []
	var length := float(prof.get("lap", {}).get("length_m", 0.0)) / 1000.0
	if length > 0.0:
		facts.append(["Length", "%.2f km" % length])
	if prof.has("corners"):
		facts.append(["Corners", str(prof["corners"].size())])
	facts.append(["Race length", "%d min" % minutes])
	# past winners of the series' classes here, and drivers with this track as a strong spot
	var winners := []
	for i in range(Elo.history.size() - 1, -1, -1):
		var ev: Dictionary = Elo.history[i]
		if str(ev.get("course", "")) != course or Elo.series_code(str(ev["file"])) != series:
			continue
		for c in ev["changes"]:
			if c["sess"] == "race" and int(c["pos"]) == 1 and c["cls"] in classes and winners.size() < 4:
				winners.append(["%s %s" % [Elo.season_of(ev).replace("Season ", "S"), LeagueSettings.label(c["cls"])], Elo.resolve(str(c["driver"]))])
	var watch := []
	var watch_title := "DRIVERS TO WATCH"
	if watch_src == WATCH_HISTORY:
		for c in classes:
			for sp in DriverTrackFit.spots(course, c):
				if str(sp["flag"]) in ["strong spot", "leaning strong"] and watch.size() < 3:
					watch.append([LeagueSettings.label(c), sp["driver"]])
	else:
		# a forecast's favourites: the two most likely winners of each class, fastest class first
		watch_title = "FAVOURITES"
		var by_class := {}
		for e in _forecast_classes(watch_src):
			by_class[e["cls"]] = e["rows"]
		for c in classes:   # only the classes this series runs, fastest first
			if not by_class.has(c):
				continue
			var fav: Array = by_class[c].duplicate()
			fav.sort_custom(func(a, b): return float(a["win"]) > float(b["win"]))
			for r in fav.slice(0, 2):
				watch.append([LeagueSettings.label(c), "%s  %d%%" % [r["name"], roundi(100.0 * float(r["win"]))]])
	var sname := str(LeagueSettings.get_value("series_names").get(series, series.to_upper()))
	return {"kind": "track", "title": course, "subtitle": "%s · %s" % [sname, " / ".join(PackedStringArray(classes.map(func(c): return LeagueSettings.label(c))))],
		"map": prof, "facts": facts, "class_rows": rows, "grades": grades, "grade_note": grade_note,
		"grade_estimates": est_notes, "grade_class": sname, "grade_classes": classes.map(func(c): return LeagueSettings.label(c)), "watch": watch, "watch_title": watch_title, "winners": winners, "notes": notes,
		"show_stops": bool(rule["pits"]),
		"accent": LeagueSettings.series_color(series), "empty": classes.is_empty()}


# Driver card: "Main class" (the one with the most duels), then every class the driver has raced.
func _fill_driver_classes() -> void:
	var keep := champ_pick.get_item_text(champ_pick.selected) if champ_pick.selected >= 0 else ""
	champ_pick.clear()
	champ_pick.add_item("Main class")
	champ_pick.set_item_metadata(0, "")
	if source_pick.selected < 0:
		return
	var duels := _class_duels(source_pick.get_item_text(source_pick.selected))
	var classes := duels.keys()
	classes.sort()
	for c in classes:
		champ_pick.add_item(LeagueSettings.label(str(c)))
		champ_pick.set_item_metadata(champ_pick.item_count - 1, c)
		if LeagueSettings.label(str(c)) == keep:
			champ_pick.select(champ_pick.item_count - 1)


func _class_duels(nm: String) -> Dictionary:
	var duels := {}
	for k in Elo.ratings:
		var parts: PackedStringArray = str(k).rsplit("|", true, 2)
		if parts[0] == nm:
			duels[parts[1]] = int(duels.get(parts[1], 0)) + int(Elo.ratings[k]["d"])
	return duels


# Saved forecasts made together (an all-classes forecast saves one file per class) form one image.
func _saved_forecast_groups() -> Array:
	var groups := []
	for fc in Predict.list_forecasts():
		if not groups.is_empty() and int(groups[-1][0]["made_at"]) == int(fc["made_at"]):
			groups[-1].append(fc)
		else:
			groups.append([fc])
	return groups


# ---------- the image ----------
func _render() -> void:
	var size_px: Vector2i = FORMATS[maxi(format_pick.selected, 0)][1]
	viewport.size = size_px
	var sp := _spec()
	sp["size"] = size_px
	sp["brand"] = _brand()
	if title_edit.text.strip_edges() != "":
		sp["title"] = title_edit.text.strip_edges()
	sp["background"] = _background()
	sp["tint"] = tint_slider.value
	card.set_spec(_pretty_spec(sp))
	save_btn.disabled = bool(sp.get("empty", false))
	var pages := int(sp.get("pages", 1)) if _kind() == "standings" or _kind() == "teams" else 1
	page_label.visible = pages > 1
	page_pick.visible = pages > 1
	batch_pages.visible = pages > 1
	save_btn.text = "Save PNG" if pages <= 1 or not batch_pages.button_pressed else "Save PNG (%d pages)" % pages


# Stream size: the whole field over pages of 10 (the rest on the last page); sets "per_page",
# "page", "pages" and the "page x of y" mark (batch save only).
func _page_spec(sp: Dictionary, n: int, note: String) -> void:
	var size_px: Vector2i = FORMATS[maxi(format_pick.selected, 0)][1]
	var pages := 1
	if size_px.x > size_px.y:
		pages = maxi(1, ceili(n / float(STREAM_PER_PAGE)))
		_sync_pages(pages, STREAM_PER_PAGE, n)
		var page := clampi(page_pick.selected, 0, pages - 1)
		sp["per_page"] = STREAM_PER_PAGE
		sp["page"] = page
		if pages > 1 and batch_pages.button_pressed:
			sp["rounds_note"] = note + "  ·  page %d of %d" % [page + 1, pages]
	sp["pages"] = pages


# Team standings: teams by points (sum of both drivers after their own drops), then wins, podiums.
func _teams_spec() -> Dictionary:
	if source_pick.selected < 0 or champ_pick.selected < 0:
		return {"kind": "standings", "title": "Team standings", "subtitle": "No teams yet: add them in Settings > Teams.", "rows": [], "empty": true}
	var season := source_pick.get_item_text(source_pick.selected)
	var key := str(champ_pick.get_item_metadata(champ_pick.selected))
	var ch: Dictionary = Reports.team_points(season).get(key, {})
	var rows := []
	for tn in ch.get("teams", {}):
		var e: Dictionary = ch["teams"][tn]
		var members := PackedStringArray((e["drivers"] as Array).map(func(d): return Elo.pretty(str(d["name"]))))
		var short := PackedStringArray((e["drivers"] as Array).map(func(d):   # surnames, for the narrow sizes
			var parts := Elo.pretty(str(d["name"])).split(" ", false)
			return parts[parts.size() - 1] if parts.size() > 0 else str(d["name"])))
		rows.append({"name": str(tn), "members": " · ".join(members), "members_short": " · ".join(short), "points": e["points"], "wins": e["wins"], "pod": e["pod"], "dropped": e["dropped"]})
	rows.sort_custom(func(a, b):
		if a["points"] != b["points"]:
			return a["points"] > b["points"]
		if a["wins"] != b["wins"]:
			return a["wins"] > b["wins"]
		return a["pod"] > b["pod"])
	var rounds := int(ch.get("rounds", 0))
	var drops := LeagueSettings.drops_for(rounds)
	var note := "After %d round%s · both drivers' points, each after their dropped round%s" % [rounds, "" if rounds == 1 else "s", "" if drops <= 1 else "s"] if drops > 0 else "After %d round%s · both drivers' points" % [rounds, "" if rounds == 1 else "s"]
	var sp := {"kind": "standings", "team_mode": true, "title": "%s team standings" % LeagueSettings.label(key), "subtitle": season,
		"rows": rows, "rounds_note": note, "empty": rows.is_empty(), "show_dropped": drops > 0}
	_page_spec(sp, rows.size(), note)
	var code := ""
	var names: Dictionary = LeagueSettings.get_value("series_names")
	for c in names:
		if str(ch.get("series", "")) == str(names[c]):
			code = str(c)
	if code != "":
		sp["accent"] = LeagueSettings.series_color(code)
	return sp


# Page picker for paged standings: one entry per page, keeping the choice.
func _sync_pages(pages: int, per: int, n: int) -> void:
	var first_label := "1: P1-%d" % mini(per, n)
	if page_pick.item_count == pages and page_pick.get_item_text(0) == first_label:
		return
	var keep := maxi(page_pick.selected, 0)
	page_pick.clear()
	for p in pages:
		page_pick.add_item("%d: P%d-%d" % [p + 1, p * per + 1, mini((p + 1) * per, n)])
	page_pick.select(mini(keep, pages - 1))


func _brand() -> Dictionary:
	var out := {"name": str(LeagueSettings.get_value("brand_name")),
		"accent": Color.from_string(str(LeagueSettings.get_value("brand_accent")), Color("cdfe02")),
		"primary": Color.from_string(str(LeagueSettings.get_value("brand_primary")), Color("512f89")),
		"secondary": Color.from_string(str(LeagueSettings.get_value("brand_secondary")), Color.WHITE),
		"logo": null, "title_font": null}
	var font_path := str(LeagueSettings.get_value("brand_title_font"))
	if font_path != "":
		if not _font_cache.has(font_path):
			var f := FontFile.new()
			var ok := FileAccess.file_exists(font_path) and f.load_dynamic_font(font_path) == OK
			_font_cache[font_path] = f if ok else null
			if not ok:
				notice.emit("Could not read the title font %s (Settings > Graphics): using the default font." % font_path.get_file())
		out["title_font"] = _font_cache[font_path]
	var path := str(LeagueSettings.get_value("brand_logo"))
	if path != "" and FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null and not img.is_empty():
			out["logo"] = ImageTexture.create_from_image(img)
	return out


func _spec() -> Dictionary:
	match _kind():
		"forecast":
			return _forecast_spec()
		"standings":
			return _standings_spec()
		"season":
			return _season_spec()
		"teams":
			return _teams_spec()
		"ranks":
			return _ranks_spec()
		"track":
			var ts := _track_spec()
			ts["corner_numbers"] = corners_check.button_pressed
			return ts
		"driver":
			if source_pick.selected < 0:
				return {"kind": "driver", "title": "Driver card", "empty": true}
			var cls := str(champ_pick.get_item_metadata(champ_pick.selected)) if champ_pick.selected >= 0 else ""
			return _driver_spec(source_pick.get_item_text(source_pick.selected), cls)
	return {"kind": "standings", "title": "", "rows": [], "empty": true}


# ---------- season scenarios ----------
var _season_cache := {}     # inputs key -> scenarios (title chances take a few seconds: kept)
var _season_busy := ""


func _season_spec() -> Dictionary:
	if source_pick.selected < 0 or champ_pick.selected < 0:
		return {"kind": "season", "title": "Season scenarios", "subtitle": "No championship results yet.", "empty": true}
	var season := source_pick.get_item_text(source_pick.selected)
	var key := str(champ_pick.get_item_metadata(champ_pick.selected))
	var ck := "%s|%s|%d|%s|%s|%s" % [season, key, Elo.history.size(), JSON.stringify(LeagueSettings.get_value("calendar")),
		JSON.stringify(LeagueSettings.get_value("season_rounds")), JSON.stringify(LeagueSettings.points())]
	if not _season_cache.has(ck):
		if _season_busy != ck:
			_season_busy = ck
			_compute_season(season, key, ck)
		return {"kind": "season", "title": "%s title fight" % LeagueSettings.label(key), "subtitle": "Working out the title chances...", "empty": true}
	var sc: Dictionary = _season_cache[ck]
	var code := str(sc["series"])
	var series_name := str(LeagueSettings.get_value("series_names").get(code, code.to_upper()))
	var left := int(sc["left"])
	var sp := {"kind": "season", "title": "%s title fight" % LeagueSettings.label(str(sc["cls"])),
		"subtitle": "%s · %s · %s" % [season, series_name, "season over" if left == 0 else "%d round%s left" % [left, "" if left == 1 else "s"]],
		"empty": false}
	sp["accent"] = LeagueSettings.series_color(code)
	# rounds still to come
	var rl := []
	for rd in sc["rounds_left"]:
		var course := str(rd.get("course", ""))
		rl.append({"round": "R%d" % int(rd["round"]), "course": course if course != "" else "Track to be confirmed",
			"weather": {"dry": "Dry", "mixed": "Mixed weather", "wet": "Wet"}.get(str(rd.get("weather", "dry")), "Dry")})
	sp["rounds_left"] = rl
	# contenders: still able to win it, in table order, at most 6
	var rows := []
	var alive := 0
	for r in sc["rows"]:
		if not bool(r["alive"]):
			continue
		alive += 1
		if rows.size() < 6:
			rows.append({"name": r["name"], "points": r["points"], "max": r["max"], "title": float(r.get("title", 0.0))})
	sp["rows"] = rows
	sp["alive_note"] = "%d driver%s can still win it on points" % [alive, "" if alive == 1 else "s"] if left > 0 else ""
	# what settles it at the next round
	var cl: Dictionary = sc.get("clinch", {})
	var next_course := str(rl[0]["course"]) if not rl.is_empty() else ""
	var who := Elo.pretty(str(cl.get("driver", "")))
	if left == 0:
		sp["clinch"] = "%s is champion" % Elo.pretty(str(sc["rows"][0]["name"]))
	elif int(cl.get("place", 0)) == -1:
		sp["clinch"] = "%s is champion whatever happens" % who
	elif int(cl.get("place", 0)) == 1:
		sp["clinch"] = "%s is champion by winning at %s" % [who, next_course]
	elif int(cl.get("place", 0)) > 0:
		sp["clinch"] = "%s is champion at %s by finishing P%d or better" % [who, next_course, int(cl["place"])]
	elif left == 1:
		sp["clinch"] = "It all comes down to %s" % next_course
	else:
		sp["clinch"] = "It cannot be settled at %s: the fight goes on to the next round" % next_course
	var watch: Array = (sc["watch"] as Array).map(func(x): return str(x["text"]))
	var drop_line := _drop_line(sc)
	if drop_line != "":
		watch.push_front(drop_line)
	sp["watch"] = watch.slice(0, SeasonScenarios.MAX_WATCH)
	return sp


# The dropped rounds of the two likeliest champions, as a safety net: what each one finishes on
# even scoring nothing more (a dropped result comes back when a worse one replaces it), which the
# plain standings do not show. Only when the two nets differ (else there is no story).
func _drop_line(sc: Dictionary) -> String:
	var drops := LeagueSettings.drops_for(int(sc["total"]))
	if drops <= 0 or int(sc["left"]) == 0:
		return ""
	var top: Array = (sc["rows"] as Array).filter(func(r): return bool(r["alive"]) and float(r.get("title", 0.0)) >= 0.05)
	top.sort_custom(func(a, b): return float(a["title"]) > float(b["title"]))
	top = top.slice(0, 2)
	if top.size() < 2 or int(top[0]["min"]) - int(top[0]["points"]) == int(top[1]["min"]) - int(top[1]["points"]):
		return ""
	# "Bad-race insurance: Paret's worst result so far is a 44, Thom's is a missed round. A bad race
	#  costs Thom more." (a bad race replaces the dropped round, so a high worst result is a cushion)
	var info := []   # [name, worst, missed]
	for r in top:
		var pts := (r["by_round"] as Array).map(func(x): return int(x["pts"]))
		var raced := (r["by_round"] as Array).filter(func(x): return int(x["pos"]) > 0).size()
		while pts.size() < int(sc["done"]):
			pts.append(0)
		pts.sort()
		info.append([Elo.pretty(str(r["name"])), int(pts[0]), int(pts[0]) == 0 and raced < int(sc["done"])])
	if int(info[0][1]) == int(info[1][1]):
		return ""
	info.sort_custom(func(a, b): return int(a[1]) > int(b[1]))   # best cushion first
	var desc := func(x: Array) -> String:
		return "a missed round" if bool(x[2]) else "a %d" % int(x[1])
	return "Bad-race insurance: %s's worst result so far is %s, %s's is %s. A bad race costs %s more" % [
		info[0][0], desc.call(info[0]), info[1][0], desc.call(info[1]), info[1][0]]


func _compute_season(season: String, key: String, ck: String) -> void:
	var sc := SeasonScenarios.build(season, key)
	if not sc.is_empty():
		await SeasonScenarios.title_chances(sc)
	_season_cache[ck] = sc if not sc.is_empty() else {"series": "", "cls": key, "left": 0, "rounds_left": [], "rows": [], "watch": []}
	if _season_busy == ck:
		_season_busy = ""
	if _kind() == "season":
		_render()


func _forecast_spec() -> Dictionary:
	var classes := []
	var course := ""
	var series := ""
	var mode := -1
	var weather := "dry"
	var rain := 0.0
	var src := int(source_pick.get_item_metadata(source_pick.selected)) if source_pick.selected >= 0 else -1
	if src < 0:
		var pv = shell.predict_view if shell != null else null
		if pv != null:
			for e in pv._last_results:
				classes.append({"cls": e["cls"], "rows": e["res"]["rows"]})
				course = str(e["res"]["track"].get("course", ""))
				weather = str(e["res"].get("weather", "dry"))
				rain = float(e["res"].get("rain", 0.0))
			series = pv._current_series()
			mode = int(pv._last_mode)
	else:
		var g: Array = _saved_forecast_groups()[src]
		for fc in g:
			var rows: Array = fc["rows"].duplicate()
			rows.sort_custom(func(a, b): return float(a["exp_pos"]) < float(b["exp_pos"]))
			classes.append({"cls": fc["class"], "rows": rows})
			course = str(fc.get("course", ""))
			series = str(fc.get("series", ""))
			mode = int(fc.get("mode", -1))
			weather = str(fc.get("weather", "dry"))
			rain = float(fc.get("rain", 0.0))
	if classes.is_empty():
		return {"kind": "forecast", "title": "Event Predictions", "subtitle": "Run a forecast on the Predict screen first.", "classes": [], "empty": true}
	# fastest class first, GT3 last (top to bottom, or left to right on the stream size): the
	# series' usual order from lap times; a class not known there goes after them, GT classes last
	var order: Array = Predict.series_classes(series)
	var rank := func(c: Dictionary) -> int:
		var i := order.find(c["cls"])
		if i >= 0:
			return i
		return 100 + (50 if str(c["cls"]).to_upper().contains("GT") else 0)
	classes.sort_custom(func(a, b): return rank.call(a) < rank.call(b))
	var series_name := str(LeagueSettings.get_value("series_names").get(series, series.to_upper())) if series != "" else ""
	var sub := PackedStringArray()
	if course != "":
		sub.append(course)
	if series_name != "":
		sub.append(series_name)
	var sp := {"kind": "forecast", "title": "Event Predictions", "subtitle": " · ".join(sub), "classes": classes, "mode": mode,
		"weather": weather, "rain": rain, "rain_swing": rain_check.button_pressed and weather == "mixed"}
	if series != "":
		sp["accent"] = LeagueSettings.series_color(series)
	return sp


func _standings_spec() -> Dictionary:
	if source_pick.selected < 0 or champ_pick.selected < 0:
		return {"kind": "standings", "title": "Standings", "subtitle": "No championship results yet.", "rows": [], "empty": true}
	var season := source_pick.get_item_text(source_pick.selected)
	var key := str(champ_pick.get_item_metadata(champ_pick.selected))
	var ch: Dictionary = Reports.season_points(season).get(key, {})
	var rows := []
	for d in ch.get("drivers", {}):
		var e: Dictionary = ch["drivers"][d]
		rows.append({"name": d, "points": e["points"], "wins": e["wins"], "pod": e["pod"], "dropped": e.get("dropped", 0)})
	rows.sort_custom(func(a, b):
		if a["points"] != b["points"]:
			return a["points"] > b["points"]
		if a["wins"] != b["wins"]:
			return a["wins"] > b["wins"]
		return a["pod"] > b["pod"])
	var drops := LeagueSettings.drops_for(int(ch.get("rounds", 0)))
	var note := "After %d round%s" % [int(ch.get("rounds", 0)), "" if int(ch.get("rounds", 0)) == 1 else "s"]
	if drops > 0:
		note += " · worst %d result%s dropped" % [drops, "" if drops == 1 else "s"]
	var sp := {"kind": "standings", "title": "%s standings" % LeagueSettings.label(key), "subtitle": season, "rows": rows,
		"rounds_note": note, "empty": rows.is_empty(), "show_dropped": drops > 0}
	_page_spec(sp, rows.size(), note)
	var code := ""
	var names: Dictionary = LeagueSettings.get_value("series_names")
	for c in names:   # "Sprint GT3" -> "sc"
		if str(ch.get("series", "")) == str(names[c]):
			code = str(c)
	if code != "":
		sp["accent"] = LeagueSettings.series_color(code)
	return sp


func _ranks_spec() -> Dictionary:
	if source_pick.selected < 0:
		return {"kind": "ranks", "title": "Driver ranks", "subtitle": "No ranked drivers yet.", "tiers": [], "empty": true}
	var cls := str(source_pick.get_item_metadata(source_pick.selected))
	var data: Dictionary = Ranks.all().get(cls, {})
	var tiers := LeagueSettings.ranks()
	var out := []
	for t in range(tiers.size() - 1, -1, -1):
		var names := []
		for d in data:
			if int(data[d]["tier"]) == t and not data[d]["inactive"]:
				names.append(d)
		names.sort_custom(func(a, b): return float(data[a]["rating"]) > float(data[b]["rating"]))
		out.append({"name": tiers[t]["name"], "color": tiers[t]["color"], "drivers": names})
	var idle := int(LeagueSettings.get_value("rank_inactive_days"))
	return {"kind": "ranks", "title": "%s ranks" % LeagueSettings.label(cls), "subtitle": "Active ranked drivers, best rated first",
		"tiers": out, "rounds_note": ("Drivers who have not raced for %d days are left out." % idle) if idle > 0 else ""}


# A driver's card for one class (cls "" = their main class: the one with the most duels). Races,
# wins, podiums, ratings and grades are all from that class.
func _driver_spec(nm: String, cls := "") -> Dictionary:
	var duels := _class_duels(nm)
	var main := cls
	if main == "":
		for c in duels:
			if main == "" or duels[c] > duels[main]:
				main = c
	var ranks := []
	for c in duels:
		var rk := Ranks.of(nm, c)
		if int(rk["tier"]) >= 0 and not rk["inactive"]:
			ranks.append({"cls": c, "name": rk["name"], "color": rk["color"]})
	var races := 0
	var wins := 0
	var pods := 0
	for ev in Elo.history:
		for c in ev["changes"]:
			if c["sess"] == "race" and Elo.resolve(str(c["driver"])) == nm and (main == "" or c["cls"] == main):
				races += 1
				wins += 1 if int(c["pos"]) == 1 else 0
				pods += 1 if int(c["pos"]) <= 3 else 0
	var stats := [["%s races" % LeagueSettings.label(main) if main != "" else "Races", races], ["Wins", wins], ["Podiums", pods]]
	if main != "":
		stats.append(["Race rating", roundi(float(Elo.ratings.get("%s|%s|race" % [nm, main], {"r": Elo.START})["r"]))])
		stats.append(["Quali rating", roundi(float(Elo.ratings.get("%s|%s|quali" % [nm, main], {"r": Elo.START})["r"]))])
		stats.append(["Class", LeagueSettings.label(main)])
	var grades := []
	if main != "":
		for g in DriverGrades.driver(nm, main):
			if int(g["grade"]) > 0:
				grades.append({"name": g["name"], "grade": g["grade"]})
	var strong := []
	var weak := []
	var wet := ""
	if main != "":
		var fit := DriverTrackFit.fit(nm, main)
		strong = fit.get("consistency", {}).get("strong", [])
		weak = fit.get("consistency", {}).get("weak", [])
		var w := WetWeather.verdict(WetWeather.of(nm, main))
		if w.contains("in the wet"):
			wet = w
	return {"kind": "driver", "title": nm, "subtitle": "Driver card", "ranks": ranks, "stats": stats, "grades": grades,
		"grade_class": main, "strong": strong, "weak": weak, "wet": wet}


# Every driver name on an image as people expect to read it (Elo.pretty): "DAN POULIN" -> "Dan
# Poulin", "David Carter#4131" -> "David Carter". The data keeps the names as stored.
func _pretty_spec(sp: Dictionary) -> Dictionary:
	var out := sp.duplicate(true)
	match str(out.get("kind", "")):
		"forecast":
			for c in out.get("classes", []):
				for r in c["rows"]:
					r["name"] = Elo.pretty(str(r["name"]))
		"standings", "season":
			if not bool(out.get("team_mode", false)):   # team names are shown as typed
				for r in out.get("rows", []):
					r["name"] = Elo.pretty(str(r["name"]))
		"ranks":
			for t in out.get("tiers", []):
				t["drivers"] = t["drivers"].map(func(n): return Elo.pretty(str(n)))
		"driver":
			if title_edit.text.strip_edges() == "":
				out["title"] = Elo.pretty(str(out.get("title", "")))
		"track":
			for w in out.get("winners", []):
				w[1] = Elo.pretty(str(w[1]))
			for w in out.get("watch", []):
				var parts := str(w[1]).split("  ")   # "Name  47%" from a forecast
				parts[0] = Elo.pretty(parts[0])
				w[1] = "  ".join(parts)
	return out


# ---------- background ----------
func _set_background(path: String) -> void:
	_show_bg_name(path)
	_save_ui("background", path)
	_render()


func _show_bg_name(path: String) -> void:
	_bg_file = path
	bg_path.text = path.get_file()
	bg_path.tooltip_text = path if path != "" else "A photo shown behind everything, under the league purple. Remembered until you change it."


func _background() -> Variant:
	var path := _bg_file
	if path == "":
		return null
	if not _bg_cache.has(path):
		var img := Image.load_from_file(path) if FileAccess.file_exists(path) else null
		_bg_cache[path] = ImageTexture.create_from_image(img) if img != null and not img.is_empty() else null
		if _bg_cache[path] == null:
			notice.emit("Could not open the background photo %s." % path.get_file())
	return _bg_cache[path]


func _save_ui(key: String, value: Variant) -> void:
	_save_ui_section("graphics", key, value)


func _save_ui_section(section: String, key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(UI_CFG)
	cfg.set_value(section, key, value)
	cfg.save(UI_CFG)


# ---------- all driver cards of a class ----------
func _fill_batch() -> void:
	var keep := [batch_series.get_item_text(batch_series.selected) if batch_series.selected >= 0 else "",
		batch_class.get_item_text(batch_class.selected) if batch_class.selected >= 0 else "",
		batch_season.get_item_text(batch_season.selected) if batch_season.selected >= 0 else ""]
	batch_series.clear()
	batch_series.add_item("All series")
	batch_series.set_item_metadata(0, "")
	var names: Dictionary = LeagueSettings.get_value("series_names")
	for code in names:
		batch_series.add_item(str(names[code]))
		batch_series.set_item_metadata(batch_series.item_count - 1, str(code))
	batch_class.clear()
	var classes := {}
	for b in Elo.boards():
		classes[b[0]] = true
	var cl := classes.keys()
	cl.sort()
	for c in cl:
		batch_class.add_item(LeagueSettings.label(str(c)))
		batch_class.set_item_metadata(batch_class.item_count - 1, c)
	batch_season.clear()
	var seasons := Elo.seasons()
	for i in range(seasons.size() - 1, -1, -1):   # newest first
		batch_season.add_item(str(seasons[i]))
		batch_season.set_item_metadata(batch_season.item_count - 1, str(seasons[i]))
	batch_season.add_item("All seasons")
	batch_season.set_item_metadata(batch_season.item_count - 1, "")
	var obs := [batch_series, batch_class, batch_season]
	for k in 3:
		for i in obs[k].item_count:
			if obs[k].get_item_text(i) == keep[k]:
				obs[k].select(i)
	_update_batch_count()


# Drivers who raced the class in the series and season, alphabetical.
func batch_drivers(series: String, cls: String, season: String) -> Array:
	var seen := {}
	for ev in Elo.history:
		if series != "" and Elo.series_code(str(ev["file"])) != series:
			continue
		if season != "" and Elo.season_of(ev) != season:
			continue
		for c in ev["changes"]:
			if c["sess"] == "race" and c["cls"] == cls:
				seen[Elo.resolve(str(c["driver"]))] = true
	var out := seen.keys()
	out.sort_custom(func(a, b): return str(a).to_lower() < str(b).to_lower())
	return out


func _batch_choice() -> Array:
	return [str(batch_series.get_item_metadata(batch_series.selected)) if batch_series.selected >= 0 else "",
		str(batch_class.get_item_metadata(batch_class.selected)) if batch_class.selected >= 0 else "",
		str(batch_season.get_item_metadata(batch_season.selected)) if batch_season.selected >= 0 else ""]


func _update_batch_count() -> void:
	var ch := _batch_choice()
	var n := batch_drivers(ch[0], ch[1], ch[2]).size() if ch[1] != "" else 0
	batch_btn.text = "Save %d driver card%s" % [n, "" if n == 1 else "s"]
	batch_btn.disabled = n == 0 or _batch_running


func _save_batch() -> void:
	if _batch_running:
		return
	var ch := _batch_choice()
	var drivers := batch_drivers(ch[0], ch[1], ch[2])
	if drivers.is_empty():
		return
	_batch_running = true
	batch_btn.disabled = true
	var parts := PackedStringArray(["driver_cards", LeagueSettings.label(ch[1])])
	if ch[0] != "":
		parts.append(batch_series.get_item_text(batch_series.selected))
	parts.append(ch[2] if ch[2] != "" else "all_seasons")
	var dir := _out_dir().path_join("_".join(parts).validate_filename().replace(" ", "_"))
	DirAccess.make_dir_recursive_absolute(dir)
	var size_px: Vector2i = FORMATS[maxi(format_pick.selected, 0)][1]
	viewport.size = size_px
	var saved := 0
	for i in drivers.size():
		if shell != null:
			shell.progress(i, drivers.size(), "Driver cards: %d of %d (%s)" % [i + 1, drivers.size(), drivers[i]])
		var sp := _driver_spec(str(drivers[i]), ch[1])
		sp["size"] = size_px
		sp["brand"] = _brand()
		sp["background"] = _background()
		sp["tint"] = tint_slider.value
		card.set_spec(_pretty_spec(sp))
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := viewport.get_texture().get_image()
		if img != null and img.save_png(dir.path_join("%s.png" % Elo.pretty(str(drivers[i])).validate_filename().replace(" ", "_"))) == OK:
			saved += 1
	if shell != null:
		shell.progress_done()
	_batch_running = false
	_update_batch_count()
	_render()
	notice.emit("Saved %d driver cards in %s" % [saved, dir])
	OS.shell_open(dir)


# ---------- saving ----------
func _out_dir() -> String:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs == "":   # no Documents folder on this system: the app's data folder instead
		docs = OS.get_user_data_dir()
	return docs.path_join(OUT_DIR_NAME)


func _save() -> void:
	_render()
	var pages := int(card.spec.get("pages", 1)) if (_kind() == "standings" or _kind() == "teams") and batch_pages.button_pressed else 1
	var keep := page_pick.selected
	var dir := _out_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var label := str(card.spec.get("title", _kind())).to_lower().validate_filename().replace(" ", "_")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var saved := 0
	var err := OK
	for p in pages:   # paged standings: every page, same name with _p1, _p2...
		if pages > 1:
			page_pick.select(p)
			_render()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := viewport.get_texture().get_image()
		var path := dir.path_join("%s_%s%s.png" % [label, stamp, ("_p%d" % (p + 1)) if pages > 1 else ""])
		err = img.save_png(path)
		if err != OK:
			break
		saved += 1
	if pages > 1:
		page_pick.select(keep)
		_render()
	if err == OK:
		notice.emit("Saved %s" % (dir.path_join("%s_%s.png" % [label, stamp]) if pages <= 1 else "%d pages in %s" % [saved, dir]))
		OS.shell_open(dir)
	else:
		notice.emit("Could not save the image (error %d)." % err)


func _btn(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b


func _muted(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = "Muted"
	return l
