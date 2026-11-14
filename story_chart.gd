class_name StoryChart
extends Control
## The two charts of the Season story graphic (SeasonStory rounds):
##   "rounds": each round's grid spot (hollow) and finish (solid), joined in green when places were
##             gained and red when lost, ✕ for a retirement, POLE, laps led, the championship place
##             after the round and wet races (blue) along the bottom;
##   "pace":   race pace against the class's middle driver, bars down for faster (up for slower),
##             "fastest" when it was the class's best, time lost to mistakes when it mattered;
##   "multi", "multipace": the same two for a combined story, one dot pair / bar per championship
##             side by side in its series colour; "rating": rating lines per class (not shown now).
## Set `mode`, `rows`, `font`, `bold`, `px` and the colours before it is drawn.

var mode := "rounds"   # "rounds", "pace", "multi", "multipace" (combined story), "rating"
var rows: Array = []
var columns: Array = []   # "multi": [{"label", "sub", "wet", "entries": [{"color", "grid", "pos", "dnf", "pole", "raced"}]}]
var rating: Array = []    # "rating": [{"cls", "points": [[elo, colour or null]]}]
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
	if mode == "multi":
		_draw_multi()
		return
	if mode == "rating":
		_draw_rating()
		return
	if mode == "multipace":
		_draw_multi_pace()
		return
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


# Combined story: each round (or race) a column, each championship a dot pair side by side.
func _draw_multi() -> void:
	if columns.is_empty():
		return
	var s := px
	var left := 56.0 * s
	var bottom := 48.0 * s
	var top := 30.0 * s
	var h := size.y - top - bottom
	var maxp := 5
	for c in columns:
		for e in c["entries"]:
			if e["raced"]:   # a retirement's classified place does not stretch the scale
				maxp = maxi(maxp, maxi(int(e["grid"]), int(e["pos"]) if not e["dnf"] else 0))
	maxp = int(ceil(maxp / 5.0) * 5)
	var y := func(p: float) -> float: return top + h * (p - 1.0) / float(maxp - 1)
	var ticks := [1]
	var t := 5
	while t <= maxp:
		ticks.append(t)
		t += 5 if maxp <= 25 else 10
	for p in ticks:
		var yy: float = y.call(float(p))
		draw_line(Vector2(left, yy), Vector2(size.x, yy), grid_color, maxf(1.0, s))
		draw_string(font, Vector2(0, yy + 6 * s), "P%d" % p, HORIZONTAL_ALIGNMENT_RIGHT, left - 12 * s, int(16 * s), muted)
	var col_w := (size.x - left) / float(columns.size())
	var fs := int((17 if columns.size() <= 6 else 14) * s)
	for i in columns.size():
		var c: Dictionary = columns[i]
		var cx := left + col_w * (i + 0.5)
		var lab := ("%s %s" % [c["sub"], c["label"]]).strip_edges()
		draw_string(bold, Vector2(cx - col_w / 2 + 2 * s, size.y - 12 * s), lab, HORIZONTAL_ALIGNMENT_CENTER, col_w - 4 * s, fs, rain if c["wet"] else text_color)
		var es: Array = c["entries"]
		var gap := minf(48.0 * s, col_w / maxf(es.size(), 1))
		for k in es.size():
			var e: Dictionary = es[k]
			if not e["raced"]:
				continue
			var x := cx + (k - (es.size() - 1) / 2.0) * gap
			var g := int(e["grid"])
			var f := int(e["pos"])
			var gy: float = y.call(float(g)) if g > 0 else -1.0
			var fy: float = y.call(float(mini(f, maxp)))
			if g > 0 and g != f and not e["dnf"]:
				draw_line(Vector2(x, gy), Vector2(x, fy), up if f < g else down, 6.0 * s, true)
			if g > 0:
				draw_circle(Vector2(x, gy), 9.0 * s, panel)
				draw_arc(Vector2(x, gy), 8.0 * s, 0, TAU, 32, e["color"], 3.0 * s, true)
			# finish label beside the dot on the outer sides; the middle ones (3 or more) under it
			var side := -1 if (k == 0 and es.size() > 1) else (1 if k == es.size() - 1 else 0)
			var tw := 60 * s
			var al := HORIZONTAL_ALIGNMENT_RIGHT if side < 0 else (HORIZONTAL_ALIGNMENT_LEFT if side > 0 else HORIZONTAL_ALIGNMENT_CENTER)
			var tpos := Vector2(x - 16 * s - tw, 0) if side < 0 else (Vector2(x + 16 * s, 0) if side > 0 else Vector2(x - tw / 2, 0))
			var dy := 0.0 if side != 0 else 24.0 * s
			if e["dnf"]:
				var a := 8.0 * s
				draw_line(Vector2(x - a, fy - a), Vector2(x + a, fy + a), down, 5.0 * s, true)
				draw_line(Vector2(x + a, fy - a), Vector2(x - a, fy + a), down, 5.0 * s, true)
				var dl := HORIZONTAL_ALIGNMENT_RIGHT if side < 0 else HORIZONTAL_ALIGNMENT_LEFT   # beside the ✕, never under it
				draw_string(bold, Vector2(x - 14 * s - tw if side < 0 else x + 14 * s, fy + 6 * s), "DNF", dl, tw, int(15 * s), down)
			else:
				draw_circle(Vector2(x, fy), 10.0 * s, e["color"])
				draw_string(bold, Vector2(tpos.x, fy + 6 * s + dy), "P%d" % f, al, tw, int(15 * s), text_color)
			if e["pole"]:   # above the grid ring, so it never sits on a finish label
				draw_string(bold, Vector2(x - tw / 2, gy - 13 * s), "POLE", HORIZONTAL_ALIGNMENT_CENTER, tw, int(12 * s), e["color"])


# Combined story: the race rating through the season, one line per class, dots in series colours.
func _draw_rating() -> void:
	if rating.is_empty():
		return
	var s := px
	var left := 56.0 * s
	var right := 70.0 * s
	var top := 14.0 * s
	var bottom := 14.0 * s
	var lo := INF
	var hi := -INF
	var n := 0
	for line in rating:
		n = maxi(n, (line["points"] as Array).size())
		for p in line["points"]:
			lo = minf(lo, float(p[0]))
			hi = maxf(hi, float(p[0]))
	lo = floor((lo - 10.0) / 50.0) * 50.0
	hi = ceil((hi + 10.0) / 50.0) * 50.0
	var h := size.y - top - bottom
	var w := size.x - left - right
	var y := func(v: float) -> float: return top + h * (hi - v) / maxf(hi - lo, 1.0)
	var v := lo
	while v <= hi + 0.1:
		var yy: float = y.call(v)
		draw_line(Vector2(left, yy), Vector2(left + w, yy), grid_color, maxf(1.0, s))
		draw_string(font, Vector2(0, yy + 5 * s), "%d" % v, HORIZONTAL_ALIGNMENT_RIGHT, left - 10 * s, int(14 * s), muted)
		v += 50.0 if hi - lo <= 300.0 else 100.0
	var shades := [text_color, muted]
	for li in rating.size():
		var pts: Array = rating[li]["points"]
		var poly := PackedVector2Array()
		for i in pts.size():
			poly.append(Vector2(left + w * i / float(maxi(n - 1, 1)), y.call(float(pts[i][0]))))
		draw_polyline(poly, shades[li % 2], 3.0 * s, true)
		for i in range(1, pts.size()):
			draw_circle(poly[i], 6.0 * s, pts[i][1] if pts[i][1] != null else text_color)
		var gain := roundi(float(pts[-1][0]) - float(pts[0][0]))
		var tag := "%s %d" % [LeagueSettings.label(str(rating[li]["cls"])), roundi(float(pts[-1][0]))] if rating.size() > 1 else "%d" % roundi(float(pts[-1][0]))
		draw_string(bold, poly[-1] + Vector2(10 * s, 6 * s), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, int(16 * s), up if gain > 0 else (down if gain < 0 else text_color))
		draw_string(font, poly[0] + Vector2(-4 * s, 22 * s), "%d" % roundi(float(pts[0][0])), HORIZONTAL_ALIGNMENT_LEFT, -1, int(14 * s), muted)


# Combined story: race pace against each class's middle driver, one bar per championship side by
# side in its series colour; down = faster, as on the single story. Slower: outlined in red.
func _draw_multi_pace() -> void:
	if columns.is_empty():
		return
	var s := px
	var left := 56.0 * s
	var label_room := 62.0 * s
	var top := 8.0 * s
	var maxv := 0.1
	var maxneg := 0.0
	for c in columns:
		for e in c["entries"]:
			if e.has("pace"):
				maxv = maxf(maxv, float(e["pace"]))
				maxneg = maxf(maxneg, -float(e["pace"]))
	var avail := size.y - top - label_room - 28 * s
	var neg_h := 0.0
	if maxneg > 0.0:
		neg_h = avail * minf(0.4, maxneg / (maxv + maxneg))
	var pos_h := avail - neg_h
	var scale := minf(pos_h / maxv, neg_h / maxneg if maxneg > 0.0 else INF)
	scale = minf(scale, 240.0 * s / maxf(maxv, maxneg))
	if maxneg > 0.0:
		neg_h = maxneg * scale + 26 * s
	var base := top + neg_h
	draw_line(Vector2(left, base), Vector2(size.x, base), grid_color, maxf(1.0, s))
	var fs := int(16 * s)
	draw_string(font, Vector2(0, base + fs * 0.35), "0", HORIZONTAL_ALIGNMENT_RIGHT, left - 12 * s, fs, muted)
	var col_w := (size.x - left) / float(columns.size())
	var lfs := int((17 if columns.size() <= 6 else 14) * s)
	for i in columns.size():
		var c: Dictionary = columns[i]
		var cx := left + col_w * (i + 0.5)
		var lab := ("%s %s" % [c["sub"], c["label"]]).strip_edges()
		draw_string(bold, Vector2(cx - col_w / 2 + 2 * s, size.y - 8 * s), lab, HORIZONTAL_ALIGNMENT_CENTER, col_w - 4 * s, lfs, rain if c["wet"] else text_color)
		var es: Array = c["entries"].filter(func(e): return e["raced"])
		if es.is_empty():
			continue
		var slot := minf(col_w * 0.8 / es.size(), 64 * s)
		var bw := slot * 0.72
		for k in es.size():
			var e: Dictionary = es[k]
			var x := cx + (k - (es.size() - 1) / 2.0) * slot
			if not e.has("pace"):
				_dashed_rect(Rect2(x - bw / 2, base, bw, 34 * s), e["color"])
				draw_string(font, Vector2(x - slot / 2 - 10 * s, base + 54 * s), "DNF" if e["dnf"] else "—", HORIZONTAL_ALIGNMENT_CENTER, slot + 20 * s, int(14 * s), muted)
				continue
			var v := float(e["pace"])
			var hh := maxf(absf(v) * scale, 4 * s)
			var txt := "%+.1f%%" % v if absf(v) >= 0.05 else "even"
			var tcol := text_color if v > -0.05 else down
			if v >= 0.0:
				draw_rect(Rect2(x - bw / 2, base, bw, hh), e["color"])
				draw_string(bold, Vector2(x - slot / 2 - 10 * s, base + hh + 20 * s), txt, HORIZONTAL_ALIGNMENT_CENTER, slot + 20 * s, int(15 * s), tcol)
				if bool(e.get("fastest", false)):
					draw_string(font, Vector2(x - slot / 2 - 10 * s, base + hh + 38 * s), "fastest", HORIZONTAL_ALIGNMENT_CENTER, slot + 20 * s, int(13 * s), accent)
			else:
				draw_rect(Rect2(x - bw / 2, base - hh, bw, hh), e["color"].darkened(0.25))
				draw_rect(Rect2(x - bw / 2, base - hh, bw, hh), down, false, 2.0 * s)
				draw_string(bold, Vector2(x - slot / 2 - 10 * s, base - hh - 7 * s), txt, HORIZONTAL_ALIGNMENT_CENTER, slot + 20 * s, int(15 * s), tcol)
