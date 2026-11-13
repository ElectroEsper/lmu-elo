class_name StoryChart
extends Control
## The two charts of the Season story graphic (SeasonStory rounds):
##   "rounds": each round's grid spot (hollow) and finish (solid), joined in green when places were
##             gained and red when lost, ✕ for a retirement, POLE, laps led, the championship place
##             after the round and wet races (blue) along the bottom;
##   "pace":   race pace against the class's middle driver, bars down for faster (up for slower),
##             "fastest" when it was the class's best, time lost to mistakes when it mattered.
## Set `mode`, `rows`, `font`, `bold`, `px` and the colours before it is drawn.

var mode := "rounds"
var rows: Array = []
var font: Font
var bold: Font
var px := 1.0
var text_color := Color.WHITE
var muted := Color(1, 1, 1, 0.6)
var accent := Color.YELLOW
var up := Color("5fd38d")
var down := Color("ef6a6a")
var rain := Color("5aa9e6")
var panel := Color("221a36")
var grid_color := Color(1, 1, 1, 0.10)


func _draw() -> void:
	if rows.is_empty():
		return
	if mode == "pace":
		_draw_pace()
	else:
		_draw_rounds()


func _col_x(i: int, left: float) -> float:
	var w := size.x - left
	return left + w * (i + 0.5) / float(rows.size())


func _draw_rounds() -> void:
	var s := px
	var left := 56.0 * s
	var bottom := 64.0 * s
	var top := 18.0 * s
	var h := size.y - top - bottom
	var maxp := 5
	for r in rows:
		if r["raced"]:
			maxp = maxi(maxp, maxi(int(r.get("grid", 0)), int(r.get("pos", 0))))
	maxp = int(ceil(maxp / 5.0) * 5)
	var y := func(p: float) -> float: return top + h * (p - 1.0) / float(maxp - 1)
	var fs := int(17 * s)
	var ticks := [1]
	var t := 5
	while t <= maxp:
		ticks.append(t)
		t += 5 if maxp <= 25 else 10
	for p in ticks:
		var yy: float = y.call(float(p))
		draw_line(Vector2(left, yy), Vector2(size.x, yy), grid_color, maxf(1.0, s))
		draw_string(font, Vector2(0, yy + fs * 0.35), "P%d" % p, HORIZONTAL_ALIGNMENT_RIGHT, left - 12 * s, fs, muted)
	var col_w := (size.x - left) / float(rows.size())
	for i in rows.size():
		var r: Dictionary = rows[i]
		var x := _col_x(i, left)
		var lab_w := col_w - 8 * s
		draw_string(bold, Vector2(x - lab_w / 2, size.y - 34 * s), "R%d %s" % [r["round"], r["course"]], HORIZONTAL_ALIGNMENT_CENTER, lab_w, int(18 * s), text_color)
		var sub := ("wet · " if r["wet"] else "") + ("champ P%d" % r["champ"] if int(r["champ"]) > 0 else "")
		draw_string(font, Vector2(x - lab_w / 2, size.y - 8 * s), sub, HORIZONTAL_ALIGNMENT_CENTER, lab_w, int(16 * s), rain if r["wet"] else muted)
		if not r["raced"]:
			draw_string(font, Vector2(x - lab_w / 2, top + h * 0.5), "did not race", HORIZONTAL_ALIGNMENT_CENTER, lab_w, int(17 * s), muted)
			continue
		var g := int(r.get("grid", 0))
		var f := int(r.get("pos", 0))
		var gy: float = y.call(float(g)) if g > 0 else -1.0
		var fy: float = y.call(float(f))
		if g > 0 and g != f and not r["dnf"]:
			draw_line(Vector2(x, gy), Vector2(x, fy), up if f < g else down, 7.0 * s, true)
		if g > 0:
			draw_circle(Vector2(x, gy), 10.0 * s, panel)
			draw_arc(Vector2(x, gy), 9.0 * s, 0, TAU, 32, accent if bool(r["pole"]) else muted, 3.0 * s, true)
		var tx := x + 20 * s
		if r["dnf"]:
			var a := 9.0 * s
			draw_line(Vector2(x - a, fy - a), Vector2(x + a, fy + a), down, 6.0 * s, true)
			draw_line(Vector2(x + a, fy - a), Vector2(x - a, fy + a), down, 6.0 * s, true)
			draw_string(bold, Vector2(tx, fy + 8 * s), "DNF", HORIZONTAL_ALIGNMENT_LEFT, -1, int(21 * s), down)
		else:
			draw_circle(Vector2(x, fy), 12.0 * s, text_color)
			draw_string(bold, Vector2(tx, fy + 8 * s), "P%d" % f, HORIZONTAL_ALIGNMENT_LEFT, -1, int(21 * s), text_color)
		if bool(r["pole"]) and absf(gy - fy) > 18 * s:
			draw_string(bold, Vector2(tx, gy + 6 * s), "POLE", HORIZONTAL_ALIGNMENT_LEFT, -1, int(16 * s), accent)
		if int(r.get("led", 0)) > 0:
			draw_string(bold, Vector2(tx, fy + 30 * s), "led %d" % int(r["led"]), HORIZONTAL_ALIGNMENT_LEFT, -1, int(15 * s), accent)


func _draw_pace() -> void:
	var s := px
	var left := 56.0 * s
	var label_room := 72.0 * s   # value and notes under a bar
	var top := 6.0 * s
	var maxv := 0.1
	var maxneg := 0.0
	for r in rows:
		if r.has("pace"):
			maxv = maxf(maxv, float(r["pace"]))
			maxneg = maxf(maxneg, -float(r["pace"]))
	var avail := size.y - top - label_room - 26 * s
	var neg_h := 0.0
	if maxneg > 0.0:
		neg_h = avail * minf(0.4, maxneg / (maxv + maxneg))
	var pos_h := avail - neg_h
	var scale := minf(pos_h / maxv, neg_h / maxneg if maxneg > 0.0 else INF)
	scale = minf(scale, 240.0 * s / maxf(maxv, maxneg))   # no giant bars on the tall story size
	if maxneg > 0.0:
		neg_h = maxneg * scale + 26 * s
	var base := top + neg_h
	draw_line(Vector2(left, base), Vector2(size.x, base), grid_color, maxf(1.0, s))
	var fs := int(16 * s)
	draw_string(font, Vector2(0, base + fs * 0.35), "0", HORIZONTAL_ALIGNMENT_RIGHT, left - 12 * s, fs, muted)
	var col_w := (size.x - left) / float(rows.size())
	var bw := minf(col_w * 0.5, 80 * s)
	for i in rows.size():
		var r: Dictionary = rows[i]
		var x := _col_x(i, left)
		draw_string(font, Vector2(x - bw / 2 - 64 * s, base + 22 * s), "R%d" % r["round"], HORIZONTAL_ALIGNMENT_RIGHT, 56 * s, fs, rain if r["wet"] else muted)
		if not r["raced"]:
			continue
		if not r.has("pace"):
			var box := Rect2(x - bw / 2, base, bw, 40 * s)
			_dashed_rect(box, muted)
			draw_string(font, Vector2(x - col_w / 2, base + 66 * s), "DNF" if r["dnf"] else "no pace", HORIZONTAL_ALIGNMENT_CENTER, col_w, int(17 * s), muted)
			continue
		var v := float(r["pace"])
		var hh := maxf(absf(v) * scale, 4 * s)
		var col := rain if r["wet"] else (accent if v >= 0.0 else down)
		var lines := ["%+.1f%%" % v if absf(v) >= 0.05 else "even"]
		var colors := [text_color]
		if bool(r.get("fastest", false)):
			lines.append("fastest")
			colors.append(accent)
		if float(r.get("costly_s", 0.0)) >= SeasonStory.COSTLY_SHOWN:
			lines.append("%d mistake%s: −%d s" % [int(r["costly"]), "" if int(r["costly"]) == 1 else "s", roundi(float(r["costly_s"]))])
			colors.append(down)
		if v >= 0.0:
			draw_rect(Rect2(x - bw / 2, base, bw, hh), col)
			for k in lines.size():
				draw_string(bold if k == 0 else font, Vector2(x - col_w / 2, base + hh + (24 + 20 * k) * s), lines[k], HORIZONTAL_ALIGNMENT_CENTER, col_w, int((20 if k == 0 else 15) * s), colors[k])
		else:
			draw_rect(Rect2(x - bw / 2, base - hh, bw, hh), col)
			draw_string(bold, Vector2(x - col_w / 2, base - hh - 8 * s), lines[0], HORIZONTAL_ALIGNMENT_CENTER, col_w, int(20 * s), colors[0])
			for k in range(1, lines.size()):
				draw_string(font, Vector2(x - col_w / 2, base + (24 + 20 * k) * s), lines[k], HORIZONTAL_ALIGNMENT_CENTER, col_w, int(15 * s), colors[k])


func _dashed_rect(r: Rect2, c: Color) -> void:
	var pts := [r.position, r.position + Vector2(r.size.x, 0), r.end, r.position + Vector2(0, r.size.y), r.position]
	for k in 4:
		var a: Vector2 = pts[k]
		var b: Vector2 = pts[k + 1]
		var n := int(a.distance_to(b) / (10 * px))
		for j in n:
			if j % 2 == 0:
				draw_line(a.lerp(b, j / float(n)), a.lerp(b, (j + 1) / float(n)), c, 2 * px)
