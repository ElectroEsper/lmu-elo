class_name TimelineChart
extends Control
## Championship timeline for the season recap graphic: each driver's points after every round as
## a line, the round names along the bottom, the names at the end of the lines, and the turning
## point marked. Set `lines` ([{"name", "points": [...], "color"}]), `rounds` (labels), `mark`
## (round index of the turning point, -1 for none), `font`, `px` before it is drawn.

var lines: Array = []
var rounds: Array = []
var mark := -1
var font: Font
var bold: Font
var px := 1.0   # image scale (1 = 1080 px)
var text_color := Color.WHITE
var muted := Color(1, 1, 1, 0.6)
var grid_color := Color(1, 1, 1, 0.10)
var mark_color := Color.WHITE


func _draw() -> void:
	if lines.is_empty() or rounds.is_empty():
		return
	var s := px
	var fs := int(22 * s)
	var name_w := 250.0 * s           # room for the names at the end of the lines
	var left := 64.0 * s
	var bottom := 44.0 * s
	var top := 14.0 * s
	var w := size.x - left - name_w
	var h := size.y - top - bottom
	var n := rounds.size()
	var vmax := 1
	for l in lines:
		for v in l["points"]:
			vmax = maxi(vmax, int(v))
	var step := 50 if vmax > 200 else (25 if vmax > 80 else 10)
	vmax = int(ceil(vmax / float(step)) * step)
	var xy := func(i: int, v: float) -> Vector2:
		var x := left + (w * i / float(n - 1) if n > 1 else w * 0.5)
		return Vector2(x, top + h - h * v / float(vmax))
	# grid and axis labels
	var v := 0
	while v <= vmax:
		var y: float = xy.call(0, float(v)).y
		draw_line(Vector2(left, y), Vector2(left + w, y), grid_color, maxf(1.0, s))
		draw_string(font, Vector2(0, y + fs * 0.35), str(v), HORIZONTAL_ALIGNMENT_RIGHT, left - 12 * s, fs, muted)
		v += step
	for i in n:
		var p: Vector2 = xy.call(i, 0.0)
		var label := "R%d" % (i + 1)
		draw_string(font, Vector2(p.x - 40 * s, size.y - 10 * s), label, HORIZONTAL_ALIGNMENT_CENTER, 80 * s, fs, muted if i != mark else mark_color)
	# the turning point
	if mark >= 0 and mark < n:
		var x: float = xy.call(mark, 0.0).x
		var dash := 10.0 * s
		var y0 := top
		while y0 < top + h:
			draw_line(Vector2(x, y0), Vector2(x, minf(y0 + dash * 0.6, top + h)), Color(mark_color, 0.7), 2.0 * s)
			y0 += dash
	# lines, last first so the leader is on top
	var ends := []
	for li in range(lines.size() - 1, -1, -1):
		var l: Dictionary = lines[li]
		var pts := PackedVector2Array()
		for i in (l["points"] as Array).size():
			pts.append(xy.call(i, float(l["points"][i])))
		if pts.size() >= 2:
			draw_polyline(pts, l["color"], (6.0 if li == 0 else 4.0) * s, true)
		for p in pts:
			draw_circle(p, (7.0 if li == 0 else 5.0) * s, l["color"])
		if not pts.is_empty():
			ends.append([pts[pts.size() - 1].y, li, pts[pts.size() - 1].x])
	# names at the end of the lines, pushed apart so they never overlap
	ends.sort_custom(func(a, b): return a[0] < b[0])
	var min_gap := fs * 1.25
	for i in range(1, ends.size()):
		ends[i][0] = maxf(ends[i][0], ends[i - 1][0] + min_gap)
	for e in ends:
		var l: Dictionary = lines[e[1]]
		var txt := "%s  %d" % [l["name"], int((l["points"] as Array).back())]
		draw_string(bold if e[1] == 0 else font, Vector2(e[2] + 16 * s, e[0] + fs * 0.35), txt, HORIZONTAL_ALIGNMENT_LEFT, name_w - 20 * s, fs, l["color"])
