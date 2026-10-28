class_name TrackMap
extends Control
## Draws a stored track profile: the circuit coloured by speed (blue = slow, red = fast),
## numbered corners, rough spots (magenta band, labelled B1, B2... from the roughest) and the
## start/finish point. North is up as reconstructed from the telemetry.

const ROUGH_COLOR := Color(1.0, 0.25, 0.9, 0.85)

var profile: Dictionary = {}


func set_profile(p: Dictionary) -> void:
	profile = p
	custom_minimum_size = Vector2(480, 380)
	queue_redraw()


func _speed_color(v: float, vmin: float, vmax: float) -> Color:
	var t := clampf((v - vmin) / maxf(vmax - vmin, 1.0), 0.0, 1.0)
	return Color.from_hsv((1.0 - t) * 0.66, 0.9, 1.0)


func _draw() -> void:
	if profile.is_empty() or not profile.has("map"):
		return
	var pts: Array = profile["map"]["pts"]
	if pts.size() < 2:
		return
	var minx := INF
	var maxx := -INF
	var miny := INF
	var maxy := -INF
	var vmin := INF
	var vmax := -INF
	for p in pts:
		minx = minf(minx, p[0])
		maxx = maxf(maxx, p[0])
		miny = minf(miny, p[1])
		maxy = maxf(maxy, p[1])
		vmin = minf(vmin, p[2])
		vmax = maxf(vmax, p[2])
	var margin := 28.0
	var avail := size - Vector2(margin * 2.0, margin * 2.0)
	if avail.x <= 10.0 or avail.y <= 10.0:
		return
	var k := minf(avail.x / maxf(maxx - minx, 1.0), avail.y / maxf(maxy - miny, 1.0))
	var origin := Vector2(margin, margin) + (avail - Vector2(maxx - minx, maxy - miny) * k) * 0.5

	var poly := PackedVector2Array()
	var colors := PackedColorArray()
	for p in pts:
		poly.append(origin + Vector2((p[0] - minx) * k, (maxy - p[1]) * k))   # screen y points down
		colors.append(_speed_color(p[2], vmin, vmax))
	var font := ThemeDB.fallback_font
	var step: int = int(profile["map"].get("step", 10))

	# rough spots: a wide band under the racing line
	var spots: Array = profile.get("traits", {}).get("rough_spots", [])
	for s in spots:
		var i0 := clampi(int(int(s["at"]) / float(step)), 0, poly.size() - 1)
		var i1 := clampi(int((int(s["at"]) + int(s.get("len", 50))) / float(step)), i0, poly.size() - 1)
		if i1 > i0:
			draw_polyline(poly.slice(i0, i1 + 1), ROUGH_COLOR, 12.0, true)
	draw_polyline_colors(poly, colors, 4.0, true)
	for j in spots.size():
		var s: Dictionary = spots[j]
		var mid := clampi(int((int(s["at"]) + int(s.get("len", 50)) / 2.0) / float(step)), 0, poly.size() - 1)
		draw_string(font, poly[mid] + Vector2(10.0, 14.0), "B%d" % (j + 1), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, ROUGH_COLOR)

	for c in profile.get("corners", []):
		var at := clampi(int(int(c["apex"]) / float(step)), 0, poly.size() - 1)
		draw_circle(poly[at], 10.0, Color(0, 0, 0, 0.75))
		draw_string(font, poly[at] + Vector2(-12.0, 5.0), str(int(c["n"])), HORIZONTAL_ALIGNMENT_CENTER, 24.0, 12, Color.WHITE)
	draw_circle(poly[0], 6.0, Color.WHITE)
	draw_string(font, poly[0] + Vector2(8.0, -8.0), "S/F", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, Color.WHITE)
