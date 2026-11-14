class_name CarBalanceChart
extends Control
## The Car balance graphic's chart: a row per car, quickest at the top. Hollow ring = the car as
## raced (its drivers included), solid dot = the car itself (drivers taken out), joined by a line;
## quicker to the right. On the right of a row: how much its drivers lifted it or held it back.
## Cars with few entries are faded, and clamped to the edge when off the scale.

var cars: Array = []        # CarBalance.compute()["cars"]
var span := 0.6             # percent at each edge (not "scale": a Control has one)
var thin := 5
var font: Font
var bold: Font
var px := 1.0
var text_color := Color.WHITE
var muted := Color(1, 1, 1, 0.6)
var up := Color("5fd38d")
var down := Color("ef6a6a")
var panel := Color("221a36")
var grid_color := Color(1, 1, 1, 0.08)


func _draw() -> void:
	if cars.is_empty():
		return
	var s := px
	var name_w := minf(320.0 * s, size.x * 0.33)
	var note_w := 150.0 * s
	var left := name_w
	var right := size.x - note_w - 12 * s
	var w := right - left
	var top := 30.0 * s
	var rowh := (size.y - top) / float(cars.size())
	if cars.size() < 8:   # a few cars: rows stay row-sized
		rowh = minf(rowh, 72.0 * s)
	var x_of := func(v: float) -> float:   # quicker (negative) to the right
		return left + w / 2.0 + clampf(-v / span, -1.0, 1.0) * (w / 2.0 - 12 * s)
	# scale: five marks, "level" in the middle
	for k in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		var v: float = k * span
		var x: float = x_of.call(v)
		draw_line(Vector2(x, top - 6 * s), Vector2(x, size.y), Color(1, 1, 1, 0.25) if k == 0.0 else grid_color, (2.0 if k == 0.0 else 1.0) * s)
		var lab := "level"
		if k != 0.0:
			lab = "%.1f%%" % absf(v)
			if absf(k) == 1.0:
				lab += " quicker" if v < 0.0 else " slower"
		var col := muted
		if k == -1.0:
			col = up
		elif k == 1.0:
			col = down
		var tw := 140.0 * s
		var al := HORIZONTAL_ALIGNMENT_CENTER
		var tx := x - tw / 2
		if k == 1.0:
			al = HORIZONTAL_ALIGNMENT_RIGHT
			tx = x - tw + 10 * s
		elif k == -1.0:
			al = HORIZONTAL_ALIGNMENT_LEFT
			tx = x - 10 * s
		draw_string(font if absf(k) != 1.0 else bold, Vector2(tx, top - 14 * s), lab, al, tw, int(15 * s), col)
	var fs := int(clampf(rowh * 0.40, 15 * s, 22 * s))
	var fs2 := int(clampf(rowh * 0.27, 12 * s, 15 * s))
	for i in cars.size():
		var c: Dictionary = cars[i]
		var y := top + rowh * (i + 0.5)
		if i % 2 == 0:
			draw_rect(Rect2(0, y - rowh / 2, size.x, rowh), Color(1, 1, 1, 0.025))
		var faded := int(c["n"]) < thin
		var a := 0.45 if faded else 1.0
		draw_string(bold, Vector2(8 * s, y - 2 * s), CarBalance.short(str(c["name"])), HORIZONTAL_ALIGNMENT_LEFT, name_w - 14 * s, fs, Color(text_color, a))
		draw_string(font, Vector2(8 * s, y + fs2 + 3 * s), "%d entr%s · %d driver%s" % [int(c["n"]), "y" if int(c["n"]) == 1 else "ies",
			int(c["drivers"]), "" if int(c["drivers"]) == 1 else "s"], HORIZONTAL_ALIGNMENT_LEFT, name_w - 14 * s, fs2, Color(muted, a))
		var xr: float = x_of.call(float(c["raw"]))
		var xe: float = x_of.call(float(c["eff"]))
		var dot := text_color
		if c["word"] == "quicker car":
			dot = up
		elif c["word"] == "slower car":
			dot = down
		var r := clampf(rowh * 0.2, 7 * s, 11 * s)
		draw_line(Vector2(xr, y), Vector2(xe, y), Color(muted, 0.5 * a), 4.0 * s)
		draw_circle(Vector2(xr, y), r * 0.85, panel)
		draw_arc(Vector2(xr, y), r * 0.85, 0, TAU, 32, Color(muted, a), 3.0 * s, true)
		draw_circle(Vector2(xe, y), r, Color(dot, a))
		var drv := float(c["drv"])
		if absf(drv) >= 0.1 and not faded:
			draw_string(bold, Vector2(right, y - 2 * s), "%.2f%%" % absf(drv), HORIZONTAL_ALIGNMENT_RIGHT, note_w + 12 * s, int(16 * s), text_color)
			draw_string(font, Vector2(right, y + fs2 + 3 * s), "drivers lift it" if drv < 0.0 else "drivers hold it back",
				HORIZONTAL_ALIGNMENT_RIGHT, note_w + 12 * s, fs2, muted)
		elif faded:
			draw_string(font, Vector2(right, y + 5 * s), "few entries", HORIZONTAL_ALIGNMENT_RIGHT, note_w + 12 * s, fs2, Color(muted, 0.7))
