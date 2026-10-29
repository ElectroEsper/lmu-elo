class_name TableView
extends RefCounted
## Builds the on-screen widget for one report table: note, optional chart, sortable table.
## Table format: {"title", "note", "headers", "rows", "chart": {"series", "x_max"}, "tips"}
## ("tips" is optional: one tooltip per column header.)


static func cell_text(v) -> String:
	return SortTable.cell_text(v)


static func build(t: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL

	if t.get("note", "") != "":
		var note := Label.new()
		note.text = LeagueSettings.label(t["note"])
		note.theme_type_variation = "Muted"
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size = Vector2(480, 0)
		box.add_child(note)

	if t.has("chart"):
		var legend := HFlowContainer.new()
		legend.add_theme_constant_override("h_separation", 18)
		for s in t["chart"]["series"]:
			var l := Label.new()
			l.text = "■ " + str(s["name"])
			l.add_theme_color_override("font_color", s["color"])
			legend.add_child(l)
		box.add_child(legend)
		var chart := RatingChart.new()
		chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chart.set_data(t["chart"]["series"], t["chart"]["x_max"])
		box.add_child(chart)

	if t["headers"].is_empty():
		return box
	if t["rows"].is_empty():
		var none := Label.new()
		none.text = "Nothing to show yet."
		none.theme_type_variation = "Muted"
		box.add_child(none)
		return box
	var table := SortTable.new()
	table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	table.custom_minimum_size = Vector2(0, 180)
	table.grade_col = int(t.get("grade_col", -1))
	table.cell_tips = t.get("cell_tips", {})
	table.cell_colors = t.get("cell_colors", {})
	table.set_table(t["headers"], t["rows"], t.get("tips", []))
	box.add_child(table)
	return box
