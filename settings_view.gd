class_name SettingsView
extends ScrollContainer
## The Settings screen: league settings kept in user://league_settings.json (league_settings.gd).
## Nothing is saved until "Save settings" is pressed.

signal notice(text: String)
signal saved   # the main screen refreshes everything that depends on the settings

var box := VBoxContainer.new()
var rank_rows := VBoxContainer.new()
var unranked_edit := LineEdit.new()
var basis_pick := OptionButton.new()
var settle_spin := SpinBox.new()
var buffer_spin := SpinBox.new()
var idle_spin := SpinBox.new()
var points_edit := LineEdit.new()
var grade_spin := SpinBox.new()
var drop_spin := SpinBox.new()
var drop_after_spin := SpinBox.new()
var class_rows := GridContainer.new()   # game class name -> name shown on screen
var rule_rows := VBoxContainer.new()     # race rules: one row per series and starting season
var series_rows := VBoxContainer.new()   # series: code in the file name -> name shown
var rounds_box := HBoxContainer.new()    # rounds per season, one spin per series
var cal_rows := VBoxContainer.new()      # season calendar: rounds still to come
var brand_name := LineEdit.new()
var brand_color := ColorPickerButton.new()
var brand_logo := LineEdit.new()
var logo_dialog := FileDialog.new()
var brand_primary := ColorPickerButton.new()
var brand_secondary := ColorPickerButton.new()
var series_color_box := VBoxContainer.new()   # one colour per series
var title_font := LineEdit.new()
var font_dialog := FileDialog.new()
var preview := Label.new()

const BASES := [["average", "Average of race and quali rating"], ["race", "Race rating only"], ["quali", "Quali rating only"]]


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 14)
	add_child(box)

	# ranks
	var ranks := _card("DRIVER RANKS")
	ranks.add_child(_note("Each class has its own ranks. A driver gets the highest rank whose minimum rating they reach; the lowest rank covers everyone below the next one. Click a colour to change it."))
	var head := HBoxContainer.new()
	for h in [["Rank name", 200], ["From rating", 120], ["Colour", 80]]:
		var l := _label(h[0])
		l.theme_type_variation = "TableHeader"
		l.custom_minimum_size = Vector2(h[1], 0)
		head.add_child(l)
	ranks.add_child(head)
	ranks.add_child(rank_rows)
	var add := _btn("Add rank", func(): _add_rank_row("New rank", 1600.0, Color.WHITE))
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	ranks.add_child(add)
	var form := GridContainer.new()
	form.columns = 2
	ranks.add_child(form)
	for b in BASES:
		basis_pick.add_item(b[1])
	settle_spin.max_value = 2000
	settle_spin.step = 10
	buffer_spin.max_value = 200
	buffer_spin.step = 1
	_form_row(form, "Name before a rank is earned", unranked_edit, "")
	_form_row(form, "Rating used", basis_pick, "")
	_form_row(form, "Duels before a driver is ranked", settle_spin,
		"Race and quali duels together, in that class. Ratings move a lot at first; 120 is about 6 to 8 events.")
	_form_row(form, "Points below a rank before dropping", buffer_spin,
		"A driver moves up as soon as they reach a rank's minimum, but only moves down once they are this far below it, so a rank does not flicker from one race to the next.")
	idle_spin.max_value = 1000
	idle_spin.step = 1
	_form_row(form, "Days without a race before \"inactive\"", idle_spin,
		"A driver who has not raced in a class for this many days (counted back from the league's latest event) keeps their rank but is shown as inactive. 0 = never.")
	preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview.theme_type_variation = "Muted"
	ranks.add_child(preview)

	# standings
	var st := _card("STANDINGS")
	var st_form := GridContainer.new()
	st_form.columns = 2
	st.add_child(st_form)
	points_edit.custom_minimum_size = Vector2(320, 0)
	var pts_row := HBoxContainer.new()
	pts_row.add_child(points_edit)
	pts_row.add_child(_btn("League scale", func():
		points_edit.text = ", ".join(PackedStringArray(LeagueSettings.DEFAULTS["points"].map(func(p): return str(p))))))
	_form_row(st_form, "Points for P1, P2, P3...", pts_row, "Separated by commas. Places after the last number score nothing. League scale: 50, 47, 44, 41, 38, 35, then one less per place down to 1.")
	drop_spin.max_value = 10
	_form_row(st_form, "Dropped rounds per season", drop_spin, "Each driver's worst rounds of a season championship are not counted. A missed round counts as 0, so it is dropped first. Each series (Sprint, Enduro...) is its own championship.")
	drop_after_spin.min_value = 0
	drop_after_spin.max_value = 20
	_form_row(st_form, "Drops apply after round", drop_after_spin, "No round is dropped until this many rounds of the season are done (2 = the first drop shows in the standings after round 3).")

	# series names
	var se := _card("SERIES")
	se.add_child(_note("Each series is told apart by the code after the season in the result file names (\"s6-mc2-r.xml\": season 6, series mc, round 2). Set the name shown everywhere for each code: standings, reports, graphics. Renaming a series renames its past seasons too."))
	var shead := HBoxContainer.new()
	for h in [["Code in file names", 160], ["Name", 220]]:
		var l := _label(h[0])
		l.theme_type_variation = "TableHeader"
		l.custom_minimum_size = Vector2(h[1], 0)
		shead.add_child(l)
	se.add_child(shead)
	se.add_child(series_rows)
	var add_series := _btn("Add series", func(): _add_series_row("", ""))
	add_series.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	se.add_child(add_series)

	# race rules
	var rr := _card("RACE RULES")
	rr.add_child(_note("The fuel / energy and tyre wear multipliers each series runs with, whether routine pit stops are part of its races, and stops the rules make compulsory. A rule applies from its season on, until a later rule for the same series takes over. Past races are scaled back to x1 with the rule they ran under (so the series' fuel and tyre figures compare), and the Predict screen starts from each series' latest rule."))
	var rhead := HBoxContainer.new()
	for h in [["Series", 150], ["From season", 110], ["Fuel / energy x", 120], ["Tyre wear x", 110], ["Pit stops", 90], ["Min. stops", 100]]:
		var l := _label(h[0])
		l.theme_type_variation = "TableHeader"
		l.custom_minimum_size = Vector2(h[1], 0)
		rhead.add_child(l)
	rr.add_child(rhead)
	rr.add_child(rule_rows)
	var add_rule := _btn("Add rule", func(): _add_rule_row({"series": "mc", "from": 1, "fuel": 1.0, "tyre": 1.0, "pits": false, "min_stops": 0}))
	add_rule.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	rr.add_child(add_rule)

	# season: length and the rounds still to come
	var sc := _card("SEASON CALENDAR")
	sc.add_child(_note("How many rounds a season of each series has, and the rounds still to come with their track and expected weather. Used by the Season scenarios graphic (points still to play for, title chances)."))
	sc.add_child(rounds_box)
	var chead := HBoxContainer.new()
	for h in [["Series", 150], ["Season", 80], ["Round", 80], ["Track", 280], ["Weather", 110], ["Rain %", 90]]:
		var l := _label(h[0])
		l.theme_type_variation = "TableHeader"
		l.custom_minimum_size = Vector2(h[1], 0)
		chead.add_child(l)
	sc.add_child(chead)
	sc.add_child(cal_rows)
	var add_cal := _btn("Add round", func():
		var last := {"series": "mc", "season": 1, "round": 1}
		if cal_rows.get_child_count() > 0:
			last = _cal_values(cal_rows.get_child(cal_rows.get_child_count() - 1))
			last["round"] = int(last["round"]) + 1
		last["course"] = ""
		last["weather"] = "dry"
		last["rain"] = 0.5
		_add_cal_row(last))
	add_cal.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	sc.add_child(add_cal)

	# graphics
	var gr2 := _card("GRAPHICS")
	gr2.add_child(_note("Shown on every image made on the Graphics screen: the league name above the title, the league colours, and a logo (PNG, JPG or SVG with a transparent background; square badges and wide wordmarks both work, but on the dark background a logo needs light or coloured lettering). Images of one series (a Sprint forecast, Enduro standings) use that series' colour; the others use the accent colour."))
	var g_form := GridContainer.new()
	g_form.columns = 2
	gr2.add_child(g_form)
	brand_name.placeholder_text = "League name"
	brand_name.custom_minimum_size = Vector2(320, 0)
	_form_row(g_form, "League name", brand_name, "")
	brand_color.edit_alpha = false
	brand_color.custom_minimum_size = Vector2(120, 0)
	_form_row(g_form, "Accent colour", brand_color, "")
	brand_primary.edit_alpha = false
	brand_primary.custom_minimum_size = Vector2(120, 0)
	_form_row(g_form, "Main league colour", brand_primary, "The background glow behind every image.")
	brand_secondary.edit_alpha = false
	brand_secondary.custom_minimum_size = Vector2(120, 0)
	_form_row(g_form, "Secondary colour", brand_secondary, "The second class on the track card's split grades (the first class uses the series colour).")
	_form_row(g_form, "Series colours", series_color_box, "")
	var logo_row := HBoxContainer.new()
	brand_logo.placeholder_text = "no logo"
	brand_logo.custom_minimum_size = Vector2(320, 0)
	logo_row.add_child(brand_logo)
	logo_row.add_child(_btn("Choose...", func(): logo_dialog.popup_centered_ratio(0.6)))
	logo_row.add_child(_btn("Remove", func(): brand_logo.text = ""))
	_form_row(g_form, "Logo file", logo_row, "")
	var font_row := HBoxContainer.new()
	title_font.placeholder_text = "system font"
	title_font.custom_minimum_size = Vector2(320, 0)
	font_row.add_child(title_font)
	font_row.add_child(_btn("Choose...", func(): font_dialog.popup_centered_ratio(0.6)))
	font_row.add_child(_btn("Remove", func(): title_font.text = ""))
	_form_row(g_form, "Title font file", font_row, "A font for the big titles (TTF, OTF or WOFF2), e.g. the league's own display font.")
	font_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	font_dialog.access = FileDialog.ACCESS_FILESYSTEM
	font_dialog.filters = PackedStringArray(["*.ttf, *.otf, *.woff, *.woff2 ; Fonts"])
	font_dialog.use_native_dialog = true
	font_dialog.file_selected.connect(func(p: String): title_font.text = p)
	add_child(font_dialog)
	logo_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	logo_dialog.access = FileDialog.ACCESS_FILESYSTEM
	logo_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp, *.svg ; Images"])
	logo_dialog.use_native_dialog = true
	logo_dialog.file_selected.connect(func(p: String): brand_logo.text = p)
	add_child(logo_dialog)

	# class names
	var cn := _card("CLASS NAMES")
	cn.add_child(_note("How each class is called on screen and in exports. The data keeps the game's own class name, so classes with different specs (ELMS and WEC LMP2, for example) stay separate. Leave a name empty to show the game's name."))
	class_rows.columns = 2
	cn.add_child(class_rows)

	# grades
	var gr := _card("DRIVER GRADES")
	var gr_form := GridContainer.new()
	gr_form.columns = 2
	gr.add_child(gr_form)
	grade_spin.min_value = 1
	grade_spin.max_value = 20
	_form_row(gr_form, "Sessions before a driver is graded", grade_spin, "")

	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	var save := _btn("Save settings", _save)
	save.theme_type_variation = "AccentButton"
	buttons.add_child(save)
	buttons.add_child(_btn("Undo changes", refresh))
	buttons.add_child(_btn("Reset to defaults", _reset))


# Fills the form from the saved settings (also used to undo unsaved changes).
func refresh() -> void:
	for c in rank_rows.get_children():
		rank_rows.remove_child(c)
		c.queue_free()
	for r in LeagueSettings.ranks():
		_add_rank_row(r["name"], r["min"], r["color"])
	unranked_edit.text = str(LeagueSettings.get_value("unranked_name"))
	var basis := str(LeagueSettings.get_value("rank_basis"))
	for i in BASES.size():
		if BASES[i][0] == basis:
			basis_pick.select(i)
	settle_spin.value = float(LeagueSettings.get_value("rank_settle_duels"))
	buffer_spin.value = float(LeagueSettings.get_value("rank_buffer"))
	idle_spin.value = float(LeagueSettings.get_value("rank_inactive_days"))
	points_edit.text = ", ".join(PackedStringArray(LeagueSettings.points().map(func(p): return str(p))))
	grade_spin.value = float(LeagueSettings.get_value("grade_min_sessions"))
	drop_spin.value = float(LeagueSettings.get_value("drop_rounds"))
	drop_after_spin.value = float(LeagueSettings.get_value("drop_after"))
	for c in class_rows.get_children():
		class_rows.remove_child(c)
		c.queue_free()
	var labels: Dictionary = LeagueSettings.get_value("class_labels")
	var known := {}
	for b in Elo.boards():
		known[b[0]] = true
	for c in labels:
		known[c] = true
	var names := known.keys()
	names.sort()
	for c in names:
		var l := _label(str(c))
		l.theme_type_variation = "Muted"
		l.custom_minimum_size = Vector2(280, 0)
		class_rows.add_child(l)
		var e := LineEdit.new()
		e.placeholder_text = str(c)
		e.text = str(labels.get(c, ""))
		e.custom_minimum_size = Vector2(200, 0)
		e.set_meta("class", c)
		class_rows.add_child(e)
	brand_name.text = str(LeagueSettings.get_value("brand_name"))
	brand_color.color = Color.from_string(str(LeagueSettings.get_value("brand_accent")), Color("cdfe02"))
	brand_logo.text = str(LeagueSettings.get_value("brand_logo"))
	brand_primary.color = Color.from_string(str(LeagueSettings.get_value("brand_primary")), Color("512f89"))
	brand_secondary.color = Color.from_string(str(LeagueSettings.get_value("brand_secondary")), Color.WHITE)
	title_font.text = str(LeagueSettings.get_value("brand_title_font"))
	for c in series_rows.get_children():
		series_rows.remove_child(c)
		c.queue_free()
	var all_names: Dictionary = LeagueSettings.get_value("series_names")
	for code in all_names:
		_add_series_row(str(code), str(all_names[code]))
	for c in series_color_box.get_children():
		series_color_box.remove_child(c)
		c.queue_free()
	var snames: Dictionary = LeagueSettings.get_value("series_names")
	for code in snames:
		var srow := HBoxContainer.new()
		var sl := _label(str(snames[code]))
		sl.custom_minimum_size = Vector2(120, 0)
		srow.add_child(sl)
		var cp := ColorPickerButton.new()
		cp.edit_alpha = false
		cp.custom_minimum_size = Vector2(120, 0)
		cp.color = LeagueSettings.series_color(str(code))
		cp.set_meta("series", str(code))
		srow.add_child(cp)
		series_color_box.add_child(srow)
	for c in rule_rows.get_children():
		rule_rows.remove_child(c)
		c.queue_free()
	for r in LeagueSettings.get_value("race_rules"):
		if r is Dictionary:
			_add_rule_row(r)
	for c in rounds_box.get_children():
		rounds_box.remove_child(c)
		c.queue_free()
	var round_names: Dictionary = LeagueSettings.get_value("series_names")
	for code in round_names:
		var l := _label("%s rounds" % str(round_names[code]))
		rounds_box.add_child(l)
		var sb := SpinBox.new()
		sb.min_value = 1
		sb.max_value = 30
		sb.value = LeagueSettings.season_rounds(str(code))
		sb.set_meta("series", str(code))
		sb.custom_minimum_size = Vector2(90, 0)
		rounds_box.add_child(sb)
	for c in cal_rows.get_children():
		cal_rows.remove_child(c)
		c.queue_free()
	for r in LeagueSettings.get_value("calendar"):
		if r is Dictionary:
			_add_cal_row(r)
	_show_preview()


func _add_rule_row(r: Dictionary) -> void:
	var row := HBoxContainer.new()
	var series := OptionButton.new()
	series.custom_minimum_size = Vector2(150, 0)
	var names: Dictionary = LeagueSettings.get_value("series_names")
	var codes := names.keys()
	if not codes.has(str(r.get("series", ""))):
		codes.append(str(r.get("series", "")))
	for c in codes:
		series.add_item("%s (%s)" % [str(names.get(c, str(c).to_upper())), c])
		series.set_item_metadata(series.item_count - 1, str(c))
		if str(c) == str(r.get("series", "")):
			series.select(series.item_count - 1)
	row.add_child(series)
	var spins := []
	for spec in [["from", 1.0, 99.0, 1.0, 110], ["fuel", 0.1, 10.0, 0.1, 120], ["tyre", 0.1, 10.0, 0.1, 110]]:
		var sb := SpinBox.new()
		sb.min_value = spec[1]
		sb.max_value = spec[2]
		sb.step = spec[3]
		sb.value = float(r.get(spec[0], spec[1]))
		sb.custom_minimum_size = Vector2(spec[4], 0)
		row.add_child(sb)
	var pits := CheckBox.new()
	pits.button_pressed = bool(r.get("pits", false))
	pits.custom_minimum_size = Vector2(90, 0)
	row.add_child(pits)
	var mins := SpinBox.new()
	mins.max_value = 5
	mins.value = int(r.get("min_stops", 0))
	mins.custom_minimum_size = Vector2(100, 0)
	row.add_child(mins)
	var remove := _btn("Remove", func(): row.queue_free())
	remove.theme_type_variation = "SmallButton"
	row.add_child(remove)
	rule_rows.add_child(row)


func _add_series_row(code: String, series_name: String) -> void:
	var row := HBoxContainer.new()
	var ce := LineEdit.new()
	ce.text = code
	ce.placeholder_text = "e.g. mc"
	ce.custom_minimum_size = Vector2(160, 0)
	row.add_child(ce)
	var ne := LineEdit.new()
	ne.text = series_name
	ne.placeholder_text = "e.g. Enduro"
	ne.custom_minimum_size = Vector2(220, 0)
	row.add_child(ne)
	var remove := _btn("Remove", func(): row.queue_free())
	remove.theme_type_variation = "SmallButton"
	row.add_child(remove)
	series_rows.add_child(row)


func _add_cal_row(r: Dictionary) -> void:
	var row := HBoxContainer.new()
	var series := OptionButton.new()
	series.custom_minimum_size = Vector2(150, 0)
	var names: Dictionary = LeagueSettings.get_value("series_names")
	for c in names:
		series.add_item(str(names[c]))
		series.set_item_metadata(series.item_count - 1, str(c))
		if str(c) == str(r.get("series", "")):
			series.select(series.item_count - 1)
	row.add_child(series)
	for spec in [["season", 80], ["round", 80]]:
		var sb := SpinBox.new()
		sb.min_value = 1
		sb.max_value = 99
		sb.value = int(r.get(spec[0], 1))
		sb.custom_minimum_size = Vector2(spec[1], 0)
		row.add_child(sb)
	var track := OptionButton.new()
	track.custom_minimum_size = Vector2(280, 0)
	track.clip_text = true
	track.add_item("(not known)")
	track.set_item_metadata(0, "")
	for c in Profiles.courses():
		track.add_item(str(c))
		track.set_item_metadata(track.item_count - 1, str(c))
		if str(c) == str(r.get("course", "")):
			track.select(track.item_count - 1)
	row.add_child(track)
	var wx := OptionButton.new()
	wx.custom_minimum_size = Vector2(110, 0)
	for w in [["Dry", "dry"], ["Mixed", "mixed"], ["Wet", "wet"]]:
		wx.add_item(w[0])
		wx.set_item_metadata(wx.item_count - 1, w[1])
		if w[1] == str(r.get("weather", "dry")):
			wx.select(wx.item_count - 1)
	row.add_child(wx)
	var rain := SpinBox.new()
	rain.max_value = 100
	rain.step = 5
	rain.value = roundi(100.0 * float(r.get("rain", 0.5)))
	rain.custom_minimum_size = Vector2(90, 0)
	rain.tooltip_text = "Mixed weather: chance of rain per weather stage."
	row.add_child(rain)
	var remove := _btn("Remove", func(): row.queue_free())
	remove.theme_type_variation = "SmallButton"
	row.add_child(remove)
	cal_rows.add_child(row)


func _cal_values(row: Node) -> Dictionary:
	var sp := row.get_child(0) as OptionButton
	var tr := row.get_child(3) as OptionButton
	var wx := row.get_child(4) as OptionButton
	return {"series": str(sp.get_item_metadata(maxi(sp.selected, 0))),
		"season": int((row.get_child(1) as SpinBox).value), "round": int((row.get_child(2) as SpinBox).value),
		"course": str(tr.get_item_metadata(maxi(tr.selected, 0))), "weather": str(wx.get_item_metadata(maxi(wx.selected, 0))),
		"rain": snappedf((row.get_child(5) as SpinBox).value / 100.0, 0.01)}


func _add_rank_row(rank_name: String, from: float, colour: Color) -> void:
	var row := HBoxContainer.new()
	var name_edit := LineEdit.new()
	name_edit.text = rank_name
	name_edit.custom_minimum_size = Vector2(200, 0)
	row.add_child(name_edit)
	var min_spin := SpinBox.new()
	min_spin.max_value = 3000
	min_spin.step = 1
	min_spin.value = from
	min_spin.custom_minimum_size = Vector2(120, 0)
	row.add_child(min_spin)
	var pick := ColorPickerButton.new()
	pick.color = colour
	pick.edit_alpha = false
	pick.custom_minimum_size = Vector2(80, 0)
	row.add_child(pick)
	var remove := _btn("Remove", func(): row.queue_free())
	remove.theme_type_variation = "SmallButton"
	row.add_child(remove)
	rank_rows.add_child(row)


func _collect() -> Dictionary:
	var values := LeagueSettings.all()
	var ranks := []
	for row in rank_rows.get_children():
		if row.is_queued_for_deletion():
			continue
		var n: String = (row.get_child(0) as LineEdit).text.strip_edges()
		if n == "":
			continue
		ranks.append({"name": n, "min": int((row.get_child(1) as SpinBox).value),
			"color": "#" + (row.get_child(2) as ColorPickerButton).color.to_html(false)})
	ranks.sort_custom(func(a, b): return a["min"] < b["min"])
	values["ranks"] = ranks
	values["unranked_name"] = unranked_edit.text.strip_edges() if unranked_edit.text.strip_edges() != "" else "Unranked"
	values["rank_basis"] = BASES[maxi(basis_pick.selected, 0)][0]
	values["rank_settle_duels"] = int(settle_spin.value)
	values["rank_buffer"] = int(buffer_spin.value)
	values["rank_inactive_days"] = int(idle_spin.value)
	var pts := []
	for part in points_edit.text.split(",", false):
		if part.strip_edges().is_valid_int():
			pts.append(int(part.strip_edges()))
	values["points"] = pts
	values["grade_min_sessions"] = int(grade_spin.value)
	values["drop_rounds"] = int(drop_spin.value)
	values["drop_after"] = int(drop_after_spin.value)
	var labels := {}
	for c in class_rows.get_children():
		if c is LineEdit and (c as LineEdit).text.strip_edges() != "":
			labels[str(c.get_meta("class"))] = (c as LineEdit).text.strip_edges()
	values["class_labels"] = labels
	var rules := []
	for row in rule_rows.get_children():
		if row.is_queued_for_deletion():
			continue
		var sp := row.get_child(0) as OptionButton
		rules.append({"series": str(sp.get_item_metadata(maxi(sp.selected, 0))),
			"from": int((row.get_child(1) as SpinBox).value),
			"fuel": snappedf((row.get_child(2) as SpinBox).value, 0.01),
			"tyre": snappedf((row.get_child(3) as SpinBox).value, 0.01),
			"pits": (row.get_child(4) as CheckBox).button_pressed,
			"min_stops": int((row.get_child(5) as SpinBox).value)})
	rules.sort_custom(func(a, b):
		if a["series"] != b["series"]:
			return str(a["series"]) < str(b["series"])
		return int(a["from"]) < int(b["from"]))
	values["race_rules"] = rules
	var rounds := {}
	for c in rounds_box.get_children():
		if c is SpinBox:
			rounds[str(c.get_meta("series"))] = int((c as SpinBox).value)
	values["season_rounds"] = rounds
	var cal := []
	for row in cal_rows.get_children():
		if not row.is_queued_for_deletion():
			cal.append(_cal_values(row))
	cal.sort_custom(func(a, b):
		if a["series"] != b["series"]:
			return str(a["series"]) < str(b["series"])
		if a["season"] != b["season"]:
			return int(a["season"]) < int(b["season"])
		return int(a["round"]) < int(b["round"]))
	values["calendar"] = cal
	values["brand_name"] = brand_name.text.strip_edges()
	values["brand_accent"] = "#" + brand_color.color.to_html(false)
	values["brand_logo"] = brand_logo.text.strip_edges()
	values["brand_primary"] = "#" + brand_primary.color.to_html(false)
	values["brand_secondary"] = "#" + brand_secondary.color.to_html(false)
	values["brand_title_font"] = title_font.text.strip_edges()
	var scols := {}
	for srow in series_color_box.get_children():
		if srow.is_queued_for_deletion():
			continue
		var cp := srow.get_child(1) as ColorPickerButton
		scols[str(cp.get_meta("series"))] = "#" + cp.color.to_html(false)
	values["series_colors"] = scols
	var snames := {}
	for row in series_rows.get_children():
		if row.is_queued_for_deletion():
			continue
		var code := (row.get_child(0) as LineEdit).text.strip_edges().to_lower()
		var sname := (row.get_child(1) as LineEdit).text.strip_edges()
		if code != "":
			snames[code] = sname if sname != "" else code.to_upper()
	if not snames.is_empty():
		values["series_names"] = snames
	return values


func _save() -> void:
	var values := _collect()
	if values["ranks"].is_empty():
		notice.emit("Keep at least one rank.")
		return
	var err := LeagueSettings.save_all(values)
	if err != OK:
		notice.emit("Could not save the settings (error %d)." % err)
		return
	refresh()
	notice.emit("Settings saved.")
	saved.emit()


func _reset() -> void:
	LeagueSettings.reset()
	refresh()
	notice.emit("Settings reset to the defaults.")
	saved.emit()


# How many drivers each rank holds with the saved settings, per class.
func _show_preview() -> void:
	var lines := PackedStringArray()
	var tiers := LeagueSettings.ranks()
	var data := Ranks.all()
	var classes := data.keys()
	classes.sort()
	for cls in classes:
		var counts := []
		counts.resize(tiers.size() + 1)
		counts.fill(0)
		var idle := 0
		for d in data[cls]:
			if data[cls][d]["inactive"]:
				idle += 1
				continue
			counts[int(data[cls][d]["tier"]) + 1] += 1
		var parts := PackedStringArray()
		for i in range(tiers.size() - 1, -1, -1):
			parts.append("%s %d" % [tiers[i]["name"], counts[i + 1]])
		parts.append("%s %d" % [str(LeagueSettings.get_value("unranked_name")), counts[0]])
		if idle > 0:
			parts.append("inactive %d" % idle)
		lines.append("%s: %s" % [LeagueSettings.label(cls), ", ".join(parts)])
	preview.text = "With the saved settings: " + ("\n".join(lines) if not lines.is_empty() else "no rated drivers yet.")


func _card(title: String) -> VBoxContainer:
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	box.add_child(card)
	var inner := VBoxContainer.new()
	card.add_child(inner)
	var l := _label(title)
	l.theme_type_variation = "SectionLabel"
	inner.add_child(l)
	return inner


func _form_row(form: GridContainer, text: String, field: Control, tip: String) -> void:
	var l := _label(text)
	l.theme_type_variation = "Muted"
	l.custom_minimum_size = Vector2(280, 0)
	form.add_child(l)
	field.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if field is SpinBox or field is OptionButton:
		field.custom_minimum_size = Vector2(maxf(field.custom_minimum_size.x, 160), 0)
	if field is LineEdit and field.custom_minimum_size.x < 1:
		field.custom_minimum_size = Vector2(200, 0)
	if tip != "":
		field.tooltip_text = tip
		l.tooltip_text = tip
		l.mouse_filter = Control.MOUSE_FILTER_PASS
	form.add_child(field)


func _note(text: String) -> Label:
	var l := _label(text)
	l.theme_type_variation = "Muted"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _btn(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b
