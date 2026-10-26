class_name TableView
extends RefCounted
## Builds the on-screen widget for one report table: note, optional chart, grid of cells.
## Table format: {"title", "note", "headers", "rows", "chart": {"series", "x_max"}}


static func cell_text(v) -> String:
	match typeof(v):
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			return "%.2f" % v
		_:
			return str(v)


static func build(t: Dictionary) -> Control:
	var scroll := ScrollContainer.new()
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

	if t.get("note", "") != "":
		var note := Label.new()
		note.text = t["note"]
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size = Vector2(480, 0)
		box.add_child(note)

	if t.has("chart"):
		var legend := HFlowContainer.new()
		for s in t["chart"]["series"]:
			var l := Label.new()
			l.text = "[%s]" % s["name"]
			l.add_theme_color_override("font_color", s["color"])
			legend.add_child(l)
		box.add_child(legend)
		var chart := RatingChart.new()
		chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chart.set_data(t["chart"]["series"], t["chart"]["x_max"])
		box.add_child(chart)

	var grid := GridContainer.new()
	grid.columns = maxi(t["headers"].size(), 1)
	grid.add_theme_constant_override("h_separation", 16)
	for h in t["headers"]:
		var hl := Label.new()
		hl.text = str(h)
		hl.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
		grid.add_child(hl)
	for row in t["rows"]:
		for v in row:
			var l := Label.new()
			l.text = cell_text(v)
			grid.add_child(l)
	box.add_child(grid)
	return scroll
