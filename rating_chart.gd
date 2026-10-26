class_name RatingChart
extends Control
## Minimal line chart for rating history.
## series: [{"name": String, "color": Color, "points": [[x, y], ...]}, ...]
## x runs from 0 to x_max (event index), y is the rating.

var series: Array = []
var x_max := 1.0


func set_data(new_series: Array, new_x_max: float) -> void:
    series = new_series
    x_max = maxf(new_x_max, 1.0)
    custom_minimum_size = Vector2(480, 260)
    queue_redraw()


func _draw() -> void:
    var font := ThemeDB.fallback_font
    var left := 48.0
    var right := 12.0
    var top := 12.0
    var bottom := 28.0
    var plot := Rect2(left, top, size.x - left - right, size.y - top - bottom)
    if plot.size.x <= 10.0 or plot.size.y <= 10.0:
        return

    var lo := INF
    var hi := -INF
    for s in series:
        for pt in s["points"]:
            lo = minf(lo, pt[1])
            hi = maxf(hi, pt[1])
    if lo == INF:
        draw_string(font, Vector2(left, top + 20.0), "No data", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.7))
        return
    if hi - lo < 20.0:
        lo -= 10.0
        hi += 10.0
    var pad := (hi - lo) * 0.08
    lo -= pad
    hi += pad

    # horizontal grid lines with rating labels
    for i in 5:
        var f := i / 4.0
        var y := plot.position.y + plot.size.y * (1.0 - f)
        draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(1, 1, 1, 0.12))
        draw_string(font, Vector2(2.0, y + 5.0), str(roundi(lo + (hi - lo) * f)),
            HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.7))

    # event numbers along the bottom
    var label_y := plot.end.y + 18.0
    draw_string(font, Vector2(plot.position.x, label_y), "event 1", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.7))
    draw_string(font, Vector2(plot.end.x - 60.0, label_y), "event %d" % (int(x_max) + 1),
        HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.7))

    # one line per driver
    for s in series:
        var line := PackedVector2Array()
        for pt in s["points"]:
            var px := plot.position.x + plot.size.x * (float(pt[0]) / x_max)
            var py := plot.position.y + plot.size.y * (1.0 - (float(pt[1]) - lo) / (hi - lo))
            line.append(Vector2(px, py))
        if line.size() > 1:
            draw_polyline(line, s["color"], 2.0, true)
        for point in line:
            draw_circle(point, 3.0, s["color"])
