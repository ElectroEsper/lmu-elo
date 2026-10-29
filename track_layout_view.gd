class_name TrackLayoutView
extends VBoxContainer
## The "Layout" tab of the Profiles screen: pick a stored track profile (built from MoTeC
## exports) and see its map, grades, corners, straights and lap summary.
## Needs table_view.gd and track_grades.gd.

var picker := OptionButton.new()
var tabs := TabContainer.new()
var profiles: Array = []
var last_tab := 0


func _ready() -> void:
	var bar := HFlowContainer.new()
	add_child(bar)
	picker.item_selected.connect(_on_pick)
	bar.add_child(picker)
	var hint := Label.new()
	hint.text = "Drop MoTeC CSV exports on the window to add profiles. You pick the track (from the tracks in your result files) and the class for each file; one profile is kept per track and class, the fastest lap wins."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(480, 0)
	add_child(hint)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)


func refresh() -> void:
	var keep := ""
	if picker.selected >= 0 and picker.item_count > 0:
		keep = picker.get_item_text(picker.selected)
	profiles = TrackStore.list()
	picker.clear()
	for p in profiles:
		picker.add_item("%s - %s" % [p["course"], p["class"]])
	for i in picker.item_count:
		if picker.get_item_text(i) == keep:
			picker.select(i)
	_show()


func _on_pick(_index: int) -> void:
	_show()


func _clear() -> void:
	for c in tabs.get_children():
		tabs.remove_child(c)
		c.queue_free()


func _lap_text(t: float) -> String:
	var m := int(t / 60.0)
	return "%d:%06.3f" % [m, t - m * 60.0]


func _show() -> void:
	# remember the open tab so switching profiles keeps the same view (Map, Grades, Corners...)
	if tabs.get_tab_count() > 1:
		last_tab = tabs.current_tab
	_clear()
	if profiles.is_empty() or picker.selected < 0:
		var l := Label.new()
		l.text = "No track profiles yet. Drop one or more MoTeC CSV exports on the window."
		tabs.add_child(l)
		tabs.set_tab_title(0, "Info")
		return
	var p: Dictionary = profiles[picker.selected]
	var lap: Dictionary = p["lap"]

	# map
	var box := VBoxContainer.new()
	var title := Label.new()
	title.text = "%s, %s: %.3f km, lap %s, average %.1f km/h, top %d km/h, %d corners" % [
		p["course"], p["class"], float(lap["length_m"]) / 1000.0, _lap_text(float(lap["time_s"])),
		float(lap["avg_kmh"]), int(lap["top_kmh"]), p["corners"].size()]
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size = Vector2(480, 0)
	box.add_child(title)
	var map := TrackMap.new()
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map.set_profile(p)
	box.add_child(map)
	var legend := Label.new()
	var m: Dictionary = p["map"]
	legend.text = "Colour = speed (blue slow, red fast). Numbers = corners in lap order, S/F = start/finish, magenta B1, B2... = rough spots on the straights, roughest first (see Grades, Bumpiness). Shape rebuilt from lateral G (%s lap, closed to within %.0f m)." % [
		m["direction"], float(m["closure_m"])]
	if not m["closed"]:
		legend.text += " The lap did not close cleanly, so the shape is approximate."
	legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	legend.custom_minimum_size = Vector2(480, 0)
	box.add_child(legend)
	tabs.add_child(box)
	tabs.set_tab_title(tabs.get_tab_count() - 1, "Map")

	tabs.add_child(_grades_panel(p))
	tabs.set_tab_title(tabs.get_tab_count() - 1, "Grades")
	tabs.add_child(TableView.build(_corner_table(p)))
	tabs.set_tab_title(tabs.get_tab_count() - 1, "Corners")
	tabs.add_child(TableView.build(_straight_table(p)))
	tabs.set_tab_title(tabs.get_tab_count() - 1, "Straights")
	tabs.add_child(TableView.build(_summary_table(p)))
	tabs.set_tab_title(tabs.get_tab_count() - 1, "Summary")
	tabs.current_tab = clampi(last_tab, 0, tabs.get_tab_count() - 1)


# Grades 1 to 5 against the other tracks of the same class. Hover a name for what it measures.
func _grades_panel(p: Dictionary) -> Control:
	var scroll := ScrollContainer.new()
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var note := Label.new()
	note.text = "Each grade compares %s with the other tracks known for %s: 5 = the most (most time at full throttle, hardest braking, thirstiest...). Tracks with nearly equal values share a grade (Basis shows which). With fewer than %d tracks for the class, a fixed scale is used instead. Hover a characteristic for what it measures." % [
		p["course"], p["class"], TrackGrades.MIN_RANKED]
	if not p.has("traits"):
		note.text += " This profile was built by an older version: drop its CSV again to get the telemetry grades."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(480, 0)
	box.add_child(note)
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 16)
	for h in ["Characteristic", "Grade", "Value", "Details", "Basis"]:
		var hl := Label.new()
		hl.text = h
		hl.theme_type_variation = "TableHeader"
		grid.add_child(hl)
	for r in TrackGrades.grade(str(p["course"]), str(p["class"])):
		var name_l := Label.new()
		name_l.text = r["name"]
		name_l.tooltip_text = r["tip"]
		name_l.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(name_l)
		var g: int = r["grade"]
		var grade_l := Label.new()
		grade_l.text = "-" if g == 0 else "%d / 5" % g
		grade_l.add_theme_color_override("font_color", _grade_colour(g))
		grid.add_child(grade_l)
		for txt in [r["value"], r["detail"] if r["detail"] != "" else "-", r["basis"]]:
			var l := Label.new()
			l.text = txt
			grid.add_child(l)
	box.add_child(grid)
	return scroll


func _grade_colour(g: int) -> Color:
	match g:
		1:
			return Color(0.45, 0.65, 1.0)
		2:
			return Color(0.45, 0.85, 0.85)
		3:
			return Color(0.6, 0.9, 0.5)
		4:
			return Color(1.0, 0.8, 0.35)
		5:
			return Color(1.0, 0.45, 0.4)
	return Color(0.6, 0.6, 0.6)


func _corner_table(p: Dictionary) -> Dictionary:
	var rows := []
	for c in p["corners"]:
		var pickup := "-"
		if int(c["pickup"]) >= 0:
			pickup = str(int(c["pickup"]))
		rows.append([
			int(c["n"]), c["dir"], c["type"], int(c["apex"]), int(c["vmin"]), int(c["entry"]), int(c["exit"]),
			int(c["angle"]), int(c["radius"]), float(c["gmax"]), int(c["gear"]),
			int(c["brake_from"]), int(c["brake_len"]), int(c["brake_peak"]), float(c["decel"]), pickup])
	return {
		"title": "Corners",
		"note": "Corners are detected from lateral G, so a left and a right are separate corners. Dist = apex position on the lap. Type compares the apex speed with the top speed of the lap. Bends taken flat out (no lift near the apex) are not corners: they are listed with the straights. Brake columns describe the braking zone leading into the corner (blank = none): metres before the apex, length, peak pedal and peak deceleration. Pickup = metres after the apex until the throttle is back above 90%.",
		"headers": ["T", "Dir", "Type", "Dist m", "Apex km/h", "Entry km/h", "Exit km/h", "Angle", "Radius m",
			"Max lat G", "Gear", "Brake from m", "Brake len m", "Brake peak %", "Max decel G", "Pickup m"],
		"rows": rows,
	}


func _straight_table(p: Dictionary) -> Dictionary:
	var rows := []
	for s in p["straights"]:
		var kinks := PackedStringArray()
		for k in s.get("kinks", []):
			if k is Dictionary:
				kinks.append("%s %d km/h" % [k.get("dir", "?"), int(k.get("vmin", 0))])
			else:   # profile saved by an older version: re-import the CSV to refresh it
				kinks.append("T%d" % int(k))
		rows.append([int(s["start"]), int(s["end"]), int(s["length"]), int(s["vstart"]), int(s["vend"]),
			"T%d" % int(s["after"]), "T%d" % int(s["before"]), "-" if kinks.is_empty() else ", ".join(kinks)])
	return {
		"title": "Straights",
		"note": "Stretches at full throttle: at least 200 m long, or any length when they include a flat-out kink (a bend taken without lifting). Kinks lists those bends as direction and minimum speed. The start/finish straight is joined across the lap boundary.",
		"headers": ["From m", "To m", "Length m", "Start km/h", "End km/h", "Out of", "Into", "Kinks"],
		"rows": rows,
	}


func _summary_table(p: Dictionary) -> Dictionary:
	var lap: Dictionary = p["lap"]
	var st: Dictionary = p["stats"]
	var res: Dictionary = p["resources"]
	var rows := []
	rows.append(["Source file", p["source"]])
	rows.append(["Log date", p["date"]])
	if str(p.get("session", "")) != "":
		rows.append(["Session", str(p["session"])])
	rows.append(["Lap length", "%.3f km" % (float(lap["length_m"]) / 1000.0)])
	rows.append(["Lap time", _lap_text(float(lap["time_s"]))])
	rows.append(["Average speed", "%.1f km/h" % float(lap["avg_kmh"])])
	rows.append(["Top speed", "%d km/h at %d m" % [int(lap["top_kmh"]), int(lap["top_at_m"])]])
	rows.append(["Slowest point", "%d km/h" % int(lap["min_kmh"])])
	rows.append(["Corners", "%d" % p["corners"].size()])
	rows.append(["Flat-out kinks", "%d" % int(st.get("flat_kinks", 0))])
	rows.append(["Braking zones", "%d (%d heavy)" % [int(st["braking_zones"]), int(st["heavy_braking_zones"])]])
	rows.append(["Longest straight", "%d m" % int(st["longest_straight_m"])])
	rows.append(["Full throttle", "%.1f %% of the lap time" % float(st["full_throttle_pct"])])
	rows.append(["Braking", "%.1f %% of the lap time" % float(st["braking_pct"])])
	rows.append(["Coasting", "%.1f %% of the lap time" % float(st["coasting_pct"])])
	var gears := []
	var keys: Array = st["gear_pct"].keys()
	keys.sort()
	for g in keys:
		gears.append("%s: %.1f%%" % [g, float(st["gear_pct"][g])])
	rows.append(["Time in gear", ", ".join(PackedStringArray(gears))])
	rows.append(["Peak lateral G", "%.2f" % float(st["max_lat_g"])])
	rows.append(["Peak braking G", "%.2f" % float(st["max_brake_g"])])
	if res.has("fuel_used_l"):
		rows.append(["Fuel used on the lap", "%.2f l" % float(res["fuel_used_l"])])
	rows.append(["Tyre wear on the lap (%)", _wheels(res.get("tyre_wear_pct", {}), "%.3f")])
	rows.append(["Tyre temperature, lap average (C)", _wheels(res.get("tyre_temp_avg_c", {}), "%.1f")])
	rows.append(["Tyre pressure at the end (kPa)", _wheels(res.get("tyre_pressure_end_kpa", {}), "%.1f")])
	rows.append(["Hottest brakes (C)", _wheels(res.get("brake_temp_max_c", {}), "%.0f")])
	if res.has("water_temp_max_c"):
		rows.append(["Water temperature, max (C)", "%.1f" % float(res["water_temp_max_c"])])
	if res.has("ambient_c"):
		rows.append(["Air / track temperature (C)", "%.1f / %.1f" % [float(res["ambient_c"]), float(res.get("track_c", 0.0))]])
	return {
		"title": "Summary",
		"note": "Fuel, tyre and brake figures are for this single lap only, so a qualifying lap shows push-lap values, not race wear.",
		"headers": ["Stat", "Value"],
		"rows": rows,
	}


func _wheels(d: Dictionary, fmt: String) -> String:
	if d.is_empty():
		return "-"
	var parts := []
	for k in ["FL", "FR", "RL", "RR"]:
		if d.has(k):
			parts.append(("%s " + fmt) % [k, float(d[k])])
	return "   ".join(PackedStringArray(parts))
