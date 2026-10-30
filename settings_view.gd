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
var class_rows := GridContainer.new()   # game class name -> name shown on screen
var rule_rows := VBoxContainer.new()     # race rules: one row per series and starting season
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
	_form_row(st_form, "Points for P1, P2, P3...", points_edit, "Separated by commas. Places after the last number score nothing.")
	drop_spin.max_value = 10
	_form_row(st_form, "Dropped rounds per season", drop_spin, "Each driver's worst rounds of a season championship are not counted. A missed round counts as 0, so it is dropped first. Each series (Sprint, Multiclass...) is its own championship.")

	# race rules
	var rr := _card("RACE RULES")
	rr.add_child(_note("The fuel / energy and tyre wear multipliers each series runs with, whether routine pit stops are part of its races, and stops the rules make compulsory. A rule applies from its season on, until a later rule for the same series takes over. Past races are scaled back to x1 with the rule they ran under (so Sprint and Multiclass fuel and tyre figures compare), and the Predict screen starts from each series' latest rule."))
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
	for c in rule_rows.get_children():
		rule_rows.remove_child(c)
		c.queue_free()
	for r in LeagueSettings.get_value("race_rules"):
		if r is Dictionary:
			_add_rule_row(r)
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
