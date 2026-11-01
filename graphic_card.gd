class_name GraphicCard
extends Control
## One broadcast / social-media image, built at its exact pixel size (rendered by graphics_view.gd
## in a SubViewport and saved as PNG). Kinds: "forecast", "standings", "ranks", "driver", "track".
## set_spec() takes everything the image shows, already gathered:
##   {"kind", "size": Vector2i, "title", "subtitle", "brand": {"name", "accent": Color, "logo": Texture2D|null},
##    "background": Texture2D|null (a race photo, shown under a purple tint), "tint": 0..1,
##    ...kind data (see the _build_* functions)}
## Layout scales with the width (1080 = 1x) and adapts to portrait (post, story) or landscape (stream).

const BG := Color("120d1d")        # near-black purple, like the league site
const PANEL := Color("221a36")
const PANEL_2 := Color("2e2547")
const TEXT := Color("f4f2f8")
const MUTED := Color("a39bbd")
const HEAD := Color("8c60dc")
const RAIN_BLUE := Color("5aa9e6")
const RAIN_MIN_SWING := 0.02   # win-chance swing (dry runs vs rain runs) worth showing      # section headings (the site's soft purple)
const PODIUM := [Color("eac45a"), Color("c3cad4"), Color("c98a5a")]
const FONT_NAMES := ["Segoe UI", "Inter", "Roboto", "Noto Sans", "DejaVu Sans", "sans-serif"]
const TITLE_FONTS := ["Bahnschrift", "Segoe UI", "Inter", "Roboto", "DejaVu Sans", "sans-serif"]

var spec := {}
var s := 1.0          # scale: image width / 1080 (portrait) or height / 1080 (landscape)
var landscape := false
var accent := Color("cdfe02")
var primary := Color("512f89")
var secondary := Color.WHITE
var photo := false    # a background photo is shown: panels become see-through
var _fonts := {}


func set_spec(new_spec: Dictionary) -> void:
	spec = new_spec
	_fonts.clear()   # the title font can change between images (Settings > Graphics)
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var size_px: Vector2i = spec["size"]
	custom_minimum_size = Vector2(size_px)
	size = Vector2(size_px)
	landscape = size_px.x > size_px.y
	s = (size_px.y if landscape else size_px.x) / 1080.0
	accent = spec.get("accent", spec.get("brand", {}).get("accent", accent))
	primary = spec.get("brand", {}).get("primary", primary)
	secondary = spec.get("brand", {}).get("secondary", secondary)
	photo = spec.get("background", null) is Texture2D
	_build()


# ---------- frame ----------
func _build() -> void:
	# league purple fading into the dark background (as on the site), a faint accent glow, and
	# an accent stripe on the left
	if photo:
		# a race photo filling the image (cropped, never stretched), under the league purple like
		# the broadcast graphics, darker towards the bottom where the tables are
		var pic := TextureRect.new()
		pic.texture = spec["background"]
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(pic)
		var tint := ColorRect.new()
		tint.color = Color(primary.darkened(0.2), clampf(float(spec.get("tint", 0.7)), 0.0, 1.0))
		tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(tint)
		var shade := TextureRect.new()
		shade.texture = _vertical_gradient(Color(BG, 0.0), Color(BG, 0.55))
		shade.stretch_mode = TextureRect.STRETCH_SCALE
		shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(shade)
	else:
		var bg := TextureRect.new()
		bg.texture = _vertical_gradient(primary.darkened(0.25), BG)
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(bg)
	var glow := TextureRect.new()
	glow.texture = _glow_texture()
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.size = Vector2(size.x * 0.9, size.y * 0.5)
	glow.position = Vector2(size.x * 0.35, -size.y * 0.15)
	glow.modulate = Color(accent, 0.10)
	add_child(glow)
	var stripe := ColorRect.new()
	stripe.color = accent
	stripe.size = Vector2(14 * s, size.y)
	add_child(stripe)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, int(70 * s))
	margin.add_theme_constant_override("margin_top", int(60 * s))
	margin.add_theme_constant_override("margin_bottom", int(44 * s))
	add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(22 * s))
	margin.add_child(col)
	col.add_child(_header())
	var body := VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", int(18 * s))
	col.add_child(body)
	match str(spec["kind"]):
		"forecast":
			_build_forecast(body)
		"standings":
			_build_standings(body)
		"ranks":
			_build_ranks(body)
		"driver":
			_build_driver(body)
		"track":
			_build_track(body)


func _header() -> Control:
	var logo = spec.get("brand", {}).get("logo", null)
	var aspect := 1.0
	if logo is Texture2D:
		aspect = float(logo.get_width()) / maxf(float(logo.get_height()), 1.0)
	var wide: bool = logo is Texture2D and aspect >= 1.6
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(28 * s))
	if logo is Texture2D and not wide:   # a square badge sits left of the titles
		var tr := _logo_rect(logo, Vector2(124, 124))
		row.add_child(tr)
	var texts := VBoxContainer.new()
	texts.add_theme_constant_override("separation", int(4 * s))
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(texts)
	# header texts never widen the image: long titles wrap, the rest ends in "..."
	var league := str(spec.get("brand", {}).get("name", ""))
	var top := HBoxContainer.new()   # league name, and a wide wordmark on the right
	top.add_child(_fit(_label(league.to_upper(), 26, accent, "bold", 4)))
	if wide:
		var h := 84.0 if not landscape else 96.0
		top.add_child(_logo_rect(logo, Vector2(minf(h * aspect, 420.0), h)))
	if league != "" or wide:
		texts.add_child(top)
	var tsize := 74 if not landscape else 72
	var tlen := str(spec["title"]).length()
	if tlen > 26 and not landscape:   # long names (tracks) get smaller type, not a cut-off line
		tsize = 54 if tlen > 34 else 62
	var title := _label(str(spec["title"]).to_upper(), tsize, TEXT, "title")
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size = Vector2(1, 0)
	title.max_lines_visible = 2
	texts.add_child(title)
	if str(spec.get("subtitle", "")) != "":
		texts.add_child(_fit(_label(str(spec["subtitle"]), 30, MUTED, "regular")))
	return row


func _logo_rect(logo: Texture2D, box: Vector2) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = logo
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = box * s
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return tr


func _fit(l: Label) -> Label:
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


# ---------- forecast ----------
# spec["classes"] = [{"cls", "rows": [{"name", "win", "podium", "exp_pos", "grid"?}]}], expected finishing order
func _build_forecast(body: VBoxContainer) -> void:
	var classes: Array = spec.get("classes", [])
	var n_cls := maxi(classes.size(), 1)
	var per := 10 if n_cls == 1 else (5 if not landscape else 6)
	if str(spec["size"]) == str(Vector2i(1080, 1920)):
		per = 16 if n_cls == 1 else 10
	if landscape and n_cls == 1:
		per = 8
	if bool(spec.get("rain_swing", false)) and not landscape:
		per -= 1   # room for the "if it rains" strip
	# Event predictions: qualifying (predicted pole) on top, then the race
	if _pole_strip(body, classes):
		body.add_child(_label("RACE" + _wx_tag(), 24, MUTED, "bold", 3))
	elif _wx_tag() != "":
		body.add_child(_label("RACE" + _wx_tag(), 24, MUTED, "bold", 3))
	var holder: BoxContainer = HBoxContainer.new() if landscape and n_cls > 1 else VBoxContainer.new()
	holder.add_theme_constant_override("separation", int(30 * s))
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(holder)
	for c in classes:
		var block := VBoxContainer.new()
		block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		block.add_theme_constant_override("separation", int(8 * s))
		holder.add_child(block)
		var h := HBoxContainer.new()
		var cl := _label(LeagueSettings.label(str(c["cls"])).to_upper(), 36, HEAD.lightened(0.15), "title")
		cl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(cl)
		h.add_child(_label("WIN", 24, MUTED, "bold", 2, 150))
		h.add_child(_label("PODIUM", 24, MUTED, "bold", 2, 130, HORIZONTAL_ALIGNMENT_RIGHT))
		block.add_child(h)
		var rows: Array = c["rows"]
		var top_win := 0.0
		for r in rows:
			top_win = maxf(top_win, float(r["win"]))
		for i in mini(per, rows.size()):
			var r: Dictionary = rows[i]
			block.add_child(_forecast_row(i, r, top_win))
	if bool(spec.get("rain_swing", false)):
		_rain_strip(body, classes)


# Top strip: each class's pole. Before quali, the driver most likely on pole and the chance;
# after quali, the driver who took it. Race-only forecasts have no quali, so no strip.
func _pole_strip(body: VBoxContainer, classes: Array) -> bool:
	var mode := int(spec.get("mode", -1))
	var entries := []   # [class, driver, text under it]
	for c in classes:
		if mode == Predict.Mode.RACE_ONLY:
			break   # no quali: no pole
		var best := {}
		for r in c["rows"]:
			if int(r.get("grid", 0)) == 1:
				best = {"name": r["name"], "note": "on pole"}
				break
			if mode != Predict.Mode.ACTUAL_GRID and float(r.get("pole", 0.0)) > float(best.get("p", 0.0)):
				best = {"name": r["name"], "p": float(r["pole"]), "note": "%d%% chance" % roundi(100.0 * float(r["pole"]))}
		if not best.is_empty():
			entries.append([c["cls"], best["name"], best["note"]])
	if entries.is_empty():
		return false
	body.add_child(_label("QUALIFYING" + _wx_tag(), 24, MUTED, "bold", 3))
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", int(16 * s))
	body.add_child(bottom)
	var known := mode == Predict.Mode.ACTUAL_GRID
	if not entries.is_empty():
		var panel := _panel(Color(accent, 0.14), accent)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", int(6 * s))
		panel.add_child(box)
		box.add_child(_label("POLE POSITION" if known else "PREDICTED POLE", 24, accent, "bold", 2))
		var row: Container = HBoxContainer.new() if landscape else VBoxContainer.new()   # portrait: one class per line
		row.add_theme_constant_override("separation", int((36 if landscape else 4) * s))
		box.add_child(row)
		for e in entries:
			var item := HBoxContainer.new()
			item.add_theme_constant_override("separation", int(14 * s))
			item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			item.add_child(_label(LeagueSettings.label(str(e[0])).to_upper(), 28, HEAD.lightened(0.25), "title", 0, 0.0 if landscape else 110))
			item.add_child(_fit(_label(str(e[1]), 32, TEXT, "bold")))
			item.add_child(_label(str(e[2]), 24, MUTED, "regular"))
			row.add_child(item)
		bottom.add_child(panel)
	return true


# Weather after a section label: "  ·  MIXED WEATHER" (nothing when dry).
func _wx_tag() -> String:
	match str(spec.get("weather", "dry")):
		"mixed":
			return "  ·  MIXED WEATHER"
		"wet":
			return "  ·  WET"
	return ""


# Mixed weather: per class, the driver who gains the most win chance when rain comes and the one
# who loses the most (runs with rain against runs that stayed dry). Small swings are left out.
func _rain_strip(body: VBoxContainer, classes: Array) -> void:
	var lines := []   # [class, [[tag, colour, name, dry, rain], ...]]
	for c in classes:
		var best := {}
		var worst := {}
		for r in c["rows"]:
			if float(r.get("win_rain", -1.0)) < 0.0:
				continue
			var d := float(r["win_rain"]) - float(r["win_dry"])
			if d > float(best.get("d", RAIN_MIN_SWING)):
				best = {"d": d, "r": r}
			if d < float(worst.get("d", -RAIN_MIN_SWING)):
				worst = {"d": d, "r": r}
		var items := []
		if not best.is_empty():
			items.append(["GAINS", Color("5cd68a"), best["r"]])
		if not worst.is_empty():
			items.append(["LOSES", Color("ef6b6b"), worst["r"]])
		if not items.is_empty():
			lines.append([c["cls"], items])
	if lines.is_empty():
		return
	body.add_child(_label("IF IT RAINS", 24, MUTED, "bold", 3))
	var panel := _panel(Color(RAIN_BLUE, 0.14), RAIN_BLUE)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(panel)
	var row: Container = HBoxContainer.new() if landscape else VBoxContainer.new()
	row.add_theme_constant_override("separation", int((36 if landscape else 2) * s))
	panel.add_child(row)
	for ln in lines:
		var block := VBoxContainer.new()
		block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		block.add_theme_constant_override("separation", int((2 if landscape else -4) * s))
		row.add_child(block)
		for it in ln[1]:
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", int(14 * s))
			var cls_txt := LeagueSettings.label(str(ln[0])).to_upper() if it == ln[1][0] else ""
			h.add_child(_label(cls_txt, 28, HEAD.lightened(0.25), "title", 0, 110))
			h.add_child(_label(str(it[0]), 20, it[1], "bold", 2, 96))
			h.add_child(_fit(_label(str(it[2]["name"]), 28 if not landscape else 30, TEXT, "bold")))
			h.add_child(_label("%d%% → %d%%" % [roundi(100.0 * float(it[2]["win_dry"])), roundi(100.0 * float(it[2]["win_rain"]))],
				26, MUTED, "regular", 0, 0.0, HORIZONTAL_ALIGNMENT_RIGHT))
			block.add_child(h)


func _forecast_row(i: int, r: Dictionary, top_win: float) -> Control:
	var tint: Color = PODIUM[i] if i < 3 else PANEL
	var panel := _panel(Color(tint, 0.18) if i < 3 else PANEL, tint if i < 3 else Color(0, 0, 0, 0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(20 * s))
	panel.add_child(row)
	row.add_child(_label("P%d" % (i + 1), 34, tint if i < 3 else MUTED, "title", 0, 76))
	var who := _label(str(r["name"]), 34, TEXT, "bold")
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.clip_text = true
	who.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(who)
	# win chance: a bar scaled to the favourite, with the number on it
	var bar_box := Control.new()
	bar_box.custom_minimum_size = Vector2(150, 40) * s
	var bar := ColorRect.new()
	bar.color = Color(accent, 0.85)
	bar.size = Vector2(150 * s * clampf(float(r["win"]) / maxf(top_win, 0.01), 0.04, 1.0), 40 * s)
	bar_box.add_child(bar)
	# the number sits on the bar: dark on a light accent (lime), light on a dark one
	var on_bar := Color("120d1d") if accent.get_luminance() > 0.55 and float(r["win"]) / maxf(top_win, 0.01) > 0.35 else TEXT
	var pct := _label("%d%%" % roundi(100.0 * float(r["win"])), 28, on_bar, "bold")
	pct.position = Vector2(10 * s, 0)
	pct.size = Vector2(140 * s, 40 * s)
	pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar_box.add_child(pct)
	row.add_child(bar_box)
	row.add_child(_label("%d%%" % roundi(100.0 * float(r["podium"])), 30, MUTED, "bold", 0, 130, HORIZONTAL_ALIGNMENT_RIGHT))
	return panel


# ---------- standings ----------
# spec["rows"] = [{"name", "points", "wins", "pod", "races", "dropped"}], best first; spec["rounds_note"]
func _build_standings(body: VBoxContainer) -> void:
	var rows: Array = spec.get("rows", [])
	var per := 10
	if str(spec["size"]) == str(Vector2i(1080, 1920)):
		per = 15
	if landscape:
		per = 8
	var h := HBoxContainer.new()
	var spacer := _label("", 22, MUTED, "bold", 0, 60)
	h.add_child(spacer)
	var dl := _label("DRIVER", 24, MUTED, "bold", 2)
	dl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(dl)
	h.add_child(_label("GAP", 22, MUTED, "bold", 2, 70, HORIZONTAL_ALIGNMENT_RIGHT))
	h.add_child(_label("WINS", 22, MUTED, "bold", 2, 84, HORIZONTAL_ALIGNMENT_RIGHT))
	h.add_child(_label("PODIUMS", 22, MUTED, "bold", 2, 124, HORIZONTAL_ALIGNMENT_RIGHT))
	h.add_child(_label("POINTS", 22, MUTED, "bold", 2, 120, HORIZONTAL_ALIGNMENT_RIGHT))
	body.add_child(h)
	var leader := float(rows[0]["points"]) if not rows.is_empty() else 0.0
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", int(10 * s))
	body.add_child(list)
	for i in mini(per, rows.size()):
		var r: Dictionary = rows[i]
		var tint: Color = PODIUM[i] if i < 3 else PANEL
		var panel := _panel(Color(tint, 0.18) if i < 3 else PANEL, tint if i < 3 else Color(0, 0, 0, 0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", int(14 * s))
		panel.add_child(row)
		row.add_child(_label(str(i + 1), 34, tint if i < 3 else MUTED, "title", 0, 40))
		var who := _fit(_label(str(r["name"]), 34, TEXT, "bold"))
		row.add_child(who)
		row.add_child(_label("-%d" % roundi(leader - float(r["points"])) if i > 0 else "", 24, MUTED, "regular", 0, 70, HORIZONTAL_ALIGNMENT_RIGHT))
		row.add_child(_label(str(int(r["wins"])), 30, TEXT, "bold", 0, 84, HORIZONTAL_ALIGNMENT_RIGHT))
		row.add_child(_label(str(int(r["pod"])), 30, TEXT, "bold", 0, 124, HORIZONTAL_ALIGNMENT_RIGHT))
		row.add_child(_label(str(int(r["points"])), 36, accent if i == 0 else TEXT, "title", 0, 100, HORIZONTAL_ALIGNMENT_RIGHT))
		list.add_child(panel)
	if str(spec.get("rounds_note", "")) != "":
		body.add_child(_label(str(spec["rounds_note"]), 24, MUTED, "regular"))


# ---------- ranks ----------
# spec["tiers"] = [{"name", "color": Color, "drivers": [names, best first]}], highest rank first
func _build_ranks(body: VBoxContainer) -> void:
	var tiers: Array = spec.get("tiers", [])
	var grid := GridContainer.new()
	grid.columns = tiers.size() if landscape else 2
	grid.add_theme_constant_override("h_separation", int(24 * s))
	grid.add_theme_constant_override("v_separation", int(24 * s))
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(grid)
	var max_names := 8 if not landscape else 11
	if str(spec["size"]) == str(Vector2i(1080, 1920)):
		max_names = 14
	for t in tiers:
		var col: Color = t["color"]
		var panel := _panel(Color(col, 0.12), col)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", int(6 * s))
		panel.add_child(box)
		var head := HBoxContainer.new()
		var tl := _label(str(t["name"]).to_upper(), 44, col, "title")
		tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(tl)
		head.add_child(_label(str(t["drivers"].size()), 44, TEXT, "title"))
		box.add_child(head)
		var names: Array = t["drivers"]
		for i in mini(max_names, names.size()):
			var l := _label(str(names[i]), 30, TEXT, "regular")
			l.clip_text = true
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			box.add_child(l)
		if names.size() > max_names:
			box.add_child(_label("+ %d more" % (names.size() - max_names), 26, MUTED, "regular"))
		grid.add_child(panel)
	if str(spec.get("rounds_note", "")) != "":
		body.add_child(_label(str(spec["rounds_note"]), 24, MUTED, "regular"))


# ---------- driver card ----------
# spec: "name", "ranks": [{"cls", "name", "color"}], "stats": [[label, value]], "grades": [{"name", "grade"}],
# "strong": [courses], "weak": [courses], "wet": String
func _build_driver(body: VBoxContainer) -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", int(16 * s))
	for rk in spec.get("ranks", []):
		var col: Color = rk["color"]
		var badge := _panel(Color(col, 0.2), col)
		badge.add_child(_label("%s  %s" % [LeagueSettings.label(str(rk["cls"])), str(rk["name"]).to_upper()], 30, col, "title"))
		top.add_child(badge)
	body.add_child(top)
	var cols: BoxContainer = HBoxContainer.new() if landscape else VBoxContainer.new()
	cols.add_theme_constant_override("separation", int(26 * s))
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(cols)
	# key numbers
	var stats := GridContainer.new()
	stats.columns = 3
	stats.add_theme_constant_override("h_separation", int(16 * s))
	stats.add_theme_constant_override("v_separation", int(16 * s))
	stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for st in spec.get("stats", []):
		var p := _panel(PANEL, Color(0, 0, 0, 0))
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 0)
		v.add_child(_label(str(st[1]), 52, TEXT, "title"))
		v.add_child(_label(str(st[0]).to_upper(), 22, MUTED, "bold", 2))
		p.add_child(v)
		stats.add_child(p)
	cols.add_child(stats)
	# grades: five pips each, coloured like the app's driver grades
	var gp := _panel(PANEL, Color(0, 0, 0, 0))
	gp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var gbox := VBoxContainer.new()
	gbox.add_theme_constant_override("separation", int(8 * s))
	gp.add_child(gbox)
	gbox.add_child(_label("GRADES  %s" % LeagueSettings.label(str(spec.get("grade_class", ""))), 26, HEAD.lightened(0.15), "bold", 2))
	for g in spec.get("grades", []):
		var row := HBoxContainer.new()
		var gl := _label(str(g["name"]), 30, TEXT, "regular")
		gl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(gl)
		var grade := int(g["grade"])
		for k in 5:
			var pip := ColorRect.new()
			pip.custom_minimum_size = Vector2(34, 18) * s
			pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			pip.color = UiTheme.driver_grade_color(grade) if k < grade else PANEL_2
			row.add_child(pip)
		gbox.add_child(row)
	cols.add_child(gp)
	var notes := PackedStringArray()
	if not spec.get("strong", []).is_empty():
		notes.append("Strong at: " + ", ".join(PackedStringArray(spec["strong"])))
	if not spec.get("weak", []).is_empty():
		notes.append("Weaker at: " + ", ".join(PackedStringArray(spec["weak"])))
	if str(spec.get("wet", "")) != "":
		notes.append("In the wet: " + str(spec["wet"]))
	for n in notes:
		var l := _label(n, 28, TEXT, "regular")
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(l)


# ---------- track ----------
# spec: "map": the telemetry profile (or {} without one), "facts": [[label, value]], "grades":
# [{"name", "grade"}], "watch": [names], "winners": [[season label, name]], "notes": String,
# "grade_class": class shown
func _build_track(body: VBoxContainer) -> void:
	var has_map: bool = not spec.get("map", {}).is_empty()
	# portrait: map with the numbers beside it, then grades, drivers and notes below.
	# landscape: the map on the left at full height, everything else in a column on the right.
	var main: BoxContainer = HBoxContainer.new()
	main.add_theme_constant_override("separation", int(24 * s))
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(main)
	var side := VBoxContainer.new()     # landscape: the right column; portrait: below the map row
	side.add_theme_constant_override("separation", int(16 * s))
	if has_map:
		var map_panel := _panel(PANEL, Color(0, 0, 0, 0))
		map_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		map_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		map_panel.size_flags_stretch_ratio = 1.15 if landscape else 1.0
		var m := BrandMap.new()
		m.profile = spec["map"]
		m.accent = accent
		m.scale_px = s
		m.show_corners = bool(spec.get("corner_numbers", false))
		m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		m.size_flags_vertical = Control.SIZE_EXPAND_FILL
		m.custom_minimum_size = Vector2(260, 260) * s
		map_panel.add_child(m)
		main.add_child(map_panel)
	var facts := GridContainer.new()
	facts.add_theme_constant_override("h_separation", int(12 * s))
	facts.add_theme_constant_override("v_separation", int(12 * s))
	facts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if landscape:
		facts.columns = 3
		side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		main.add_child(side)
		side.add_child(facts)
	elif has_map:
		facts.columns = 1
		facts.size_flags_horizontal = Control.SIZE_FILL
		facts.custom_minimum_size = Vector2(240, 0) * s
		main.add_child(facts)
		main.size_flags_vertical = Control.SIZE_EXPAND_FILL
		body.add_child(side)
	else:
		facts.columns = 3
		main.add_child(facts)
		main.size_flags_vertical = Control.SIZE_FILL
		body.add_child(side)
	var fact_list: Array = spec.get("facts", [])
	for f in fact_list:
		var p := _panel(PANEL, Color(0, 0, 0, 0))
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 0)
		v.add_child(_label(str(f[1]), 38, TEXT, "title"))
		v.add_child(_label(str(f[0]).to_upper(), 18, MUTED, "bold", 2))
		p.add_child(v)
		facts.add_child(p)

	# one row per class: race lap, laps, stops
	var crows: Array = spec.get("class_rows", [])
	if not crows.is_empty():
		var cp := _panel(PANEL, Color(0, 0, 0, 0))
		var cg := GridContainer.new()
		var ncol := 4 if spec.get("show_stops", true) else 3   # no stops column when the series has none
		cg.columns = ncol
		cg.add_theme_constant_override("h_separation", int(20 * s))
		cg.add_theme_constant_override("v_separation", int(2 * s))
		cp.add_child(cg)
		var heads := ["CLASS", "RACE LAP", "LAPS", "STOPS"]
		for k in ncol:
			var hl := _label(heads[k], 20, MUTED, "bold", 2, 0.0, HORIZONTAL_ALIGNMENT_LEFT if k == 0 else HORIZONTAL_ALIGNMENT_RIGHT)
			if k == 0:
				hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cg.add_child(hl)
		for r in crows:
			for k in ncol:
				var l := _label(str(r[k]), 32 if k > 0 else 30, HEAD.lightened(0.25) if k == 0 else TEXT, "title" if k > 0 else "bold", 0,
					0.0 if k == 0 else 110.0, HORIZONTAL_ALIGNMENT_LEFT if k == 0 else HORIZONTAL_ALIGNMENT_RIGHT)
				cg.add_child(l)
		side.add_child(cp)

	# grades in two columns: name and five pips in the series colour
	var grades: Array = spec.get("grades", [])
	if not grades.is_empty():
		var gp := _panel(PANEL, Color(0, 0, 0, 0))
		var gbox := VBoxContainer.new()
		gbox.add_theme_constant_override("separation", int(4 * s))
		gp.add_child(gbox)
		# with two classes every pip is split: top half the first (faster) class in the series
		# colour, bottom half the second in the secondary colour; a key in the heading
		var gcls: Array = spec.get("grade_classes", [])
		var split := gcls.size() >= 2
		var cols := [accent, secondary]
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", int(14 * s))
		head.add_child(_label("TRACK GRADES" if split else "TRACK GRADES  %s" % LeagueSettings.label(str(spec.get("grade_class", ""))), 22, HEAD.lightened(0.15), "bold", 2))
		if split:
			for k in 2:
				var key := ColorRect.new()
				key.color = cols[k]
				key.custom_minimum_size = Vector2(22, 7) * s
				key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				head.add_child(key)
				head.add_child(_label(str(gcls[k]), 22, cols[k], "bold"))
		gbox.add_child(head)
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", int(34 * s))
		grid.add_theme_constant_override("v_separation", int(2 * s))
		gbox.add_child(grid)
		for g in grades:
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(_fit(_label(str(g["name"]), 24, TEXT, "regular")))
			for k in 5:
				var hatch: Array = g.get("est_by_class", [false, false])
				if split:
					var by: Array = g.get("by_class", [g["grade"], 0])
					var pip2 := VBoxContainer.new()
					pip2.add_theme_constant_override("separation", int(2 * s))
					pip2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
					for half in 2:
						pip2.add_child(_pip(Vector2(22, 7) * s, cols[half] if k < int(by[half]) else PANEL_2, k < int(by[half]) and bool(hatch[half])))
					row.add_child(pip2)
				else:
					var pip := _pip(Vector2(22, 14) * s, accent if k < int(g["grade"]) else PANEL_2, k < int(g["grade"]) and bool(hatch[0]))
					pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
					row.add_child(pip)
			grid.add_child(row)
		var any_hatch := false
		for g in grades:
			for h in g.get("est_by_class", []):
				any_hatch = any_hatch or bool(h)
		if any_hatch:
			var hk := HBoxContainer.new()
			hk.add_theme_constant_override("separation", int(8 * s))
			var sample := _pip(Vector2(22, 12) * s, MUTED, true)
			sample.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			hk.add_child(sample)
			hk.add_child(_label("Hatched: from training races or estimated (no league race of that class here yet)", 18, MUTED, "regular"))
			gbox.add_child(hk)
		if str(spec.get("grade_note", "")) != "":
			var gn := _label(str(spec["grade_note"]), 18, MUTED, "regular")
			gn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			gn.custom_minimum_size = Vector2(1, 0)
			gbox.add_child(gn)
		side.add_child(gp)

	# who to watch and who won here
	var watch: Array = spec.get("watch", [])
	var winners: Array = spec.get("winners", [])
	if not watch.is_empty() or not winners.is_empty():
		var bottom := HBoxContainer.new()
		bottom.add_theme_constant_override("separation", int(16 * s))
		side.add_child(bottom)
		for part in [[str(spec.get("watch_title", "DRIVERS TO WATCH")), watch], ["PAST WINNERS", winners]]:
			var items: Array = part[1]
			if items.is_empty():
				continue
			var p := _panel(PANEL, Color(0, 0, 0, 0))
			p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var v := VBoxContainer.new()
			v.add_theme_constant_override("separation", 0)
			p.add_child(v)
			v.add_child(_label(str(part[0]), 22, accent, "bold", 2))
			for it in items:
				if it is Array:   # [season and class, winner] or [class, driver]
					var r := HBoxContainer.new()
					r.add_theme_constant_override("separation", int(10 * s))
					r.add_child(_label(str(it[0]), 20, MUTED, "regular", 0, 110))
					r.add_child(_fit(_label(str(it[1]), 26, TEXT, "bold")))
					v.add_child(r)
				else:
					v.add_child(_fit(_label(str(it), 26, TEXT, "bold")))
			bottom.add_child(p)

	var notes := str(spec.get("notes", "")).strip_edges()
	if notes != "":
		var np := _panel(Color(accent, 0.14), accent)
		var nl := _label(notes, 26, TEXT, "bold")
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.custom_minimum_size = Vector2(1, 0)
		np.add_child(nl)
		side.add_child(np)


# The circuit as on the broadcast slides: a white line with a dark edge, corner numbers in small
# accent badges and the start/finish line, fitted into the box (north up, as in the profile).
class BrandMap extends Control:
	var profile := {}
	var accent := Color.WHITE
	var scale_px := 1.0
	var show_corners := false

	func _draw() -> void:
		var pts: Array = profile.get("map", {}).get("pts", [])
		if pts.size() < 2:
			return
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p in pts:
			lo = Vector2(minf(lo.x, p[0]), minf(lo.y, p[1]))
			hi = Vector2(maxf(hi.x, p[0]), maxf(hi.y, p[1]))
		var margin := 30.0 * scale_px
		var avail := size - Vector2(margin, margin) * 2.0
		var k := minf(avail.x / maxf(hi.x - lo.x, 1.0), avail.y / maxf(hi.y - lo.y, 1.0))
		var origin := Vector2(margin, margin) + (avail - (hi - lo) * k) * 0.5
		var poly := PackedVector2Array()
		for p in pts:
			poly.append(origin + Vector2((p[0] - lo.x) * k, (hi.y - p[1]) * k))
		if poly[0].distance_to(poly[poly.size() - 1]) < 60.0 * scale_px:
			poly.append(poly[0])   # close the loop
		draw_polyline(poly, Color(0, 0, 0, 0.45), 16.0 * scale_px, true)
		draw_polyline(poly, Color.WHITE, 8.0 * scale_px, true)
		var step := int(profile["map"].get("step", 10))
		var font := ThemeDB.fallback_font
		var fs := int(20 * scale_px)
		var r := 15.0 * scale_px
		var centre := origin + (hi - lo) * k * 0.5
		var placed := []
		for c in (profile.get("corners", []) if show_corners else []):
			var at := clampi(int(int(c["apex"]) / float(step)), 0, poly.size() - 1)
			# badge pushed off the line, away from the middle of the track, so it does not hide it
			var out := (poly[at] - centre).normalized()
			var pos := poly[at] + out * 24.0 * scale_px
			# corners close together (a chicane): move the badge further out until it is clear
			for tries in 4:
				var clear := true
				for q in placed:
					if pos.distance_to(q) < r * 2.1:
						clear = false
				if clear:
					break
				pos += out * r * 1.6
			placed.append(pos)
			draw_circle(pos, r, accent)
			var txt := str(int(c["n"]))
			var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(font, pos + Vector2(-w * 0.5, fs * 0.35), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("120d1d"))
		# start / finish: a short chequered bar across the line
		if poly.size() > 2:
			var d := (poly[1] - poly[0]).normalized()
			var n := Vector2(-d.y, d.x)
			for j in 4:
				var a := poly[0] + n * (-12.0 + j * 6.0) * scale_px
				draw_line(a, a + n * 6.0 * scale_px, Color.BLACK if j % 2 == 0 else Color.WHITE, 8.0 * scale_px)


# A grade pip: solid, or hatched (diagonal stripes on a dim fill) for an estimate.
func _pip(box: Vector2, color: Color, hatched: bool) -> Control:
	if not hatched:
		var r := ColorRect.new()
		r.custom_minimum_size = box
		r.color = color
		return r
	var h := Hatch.new()
	h.custom_minimum_size = box
	h.color = color
	h.line_w = maxf(1.5, 2.0 * s)
	return h


class Hatch extends Control:
	var color := Color.WHITE
	var line_w := 2.0

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(color, 0.22))
		var step := line_w * 2.6
		var x := -size.y
		while x < size.x:
			# a 45-degree stripe from (x, h) to (x + h, 0), clipped to the box
			var a := Vector2(x, size.y)
			var b := Vector2(x + size.y, 0.0)
			if a.x < 0.0:
				a = Vector2(0.0, size.y + a.x)
			if b.x > size.x:
				b = Vector2(size.x, size.y - (size.x - x))
			draw_line(a, b, color, line_w, true)
			x += step


# ---------- building blocks ----------
func _font(kind: String) -> Font:
	if _fonts.has(kind):
		return _fonts[kind]
	var custom = spec.get("brand", {}).get("title_font", null)
	if kind == "title" and custom is Font:
		_fonts[kind] = custom
		return custom
	var f := SystemFont.new()
	f.font_names = PackedStringArray(TITLE_FONTS if kind == "title" else FONT_NAMES)
	f.font_weight = {"title": 800, "bold": 650, "regular": 400}[kind]
	_fonts[kind] = f
	return f


func _label(text: String, size_px: float, color: Color, kind: String, spacing := 0, width := 0.0,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(kind))
	l.add_theme_font_size_override("font_size", int(size_px * s))
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if width > 0.0:
		l.custom_minimum_size = Vector2(width * s, 0)
	return l


func _panel(fill: Color, edge: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	if photo:   # over a photo: the panel colour mixed in solid, then a little see-through
		var solid := PANEL.lerp(Color(fill, 1.0), fill.a) if fill.a < 1.0 else fill
		fill = Color(solid, 0.84)
	sb.bg_color = fill
	sb.set_corner_radius_all(int(10 * s))
	sb.content_margin_left = 22 * s
	sb.content_margin_right = 22 * s
	sb.content_margin_top = 8 * s
	sb.content_margin_bottom = 8 * s
	if edge.a > 0.0:
		sb.border_width_left = int(8 * s)
		sb.border_color = edge
	p.add_theme_stylebox_override("panel", sb)
	return p


func _vertical_gradient(top: Color, bottom: Color) -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, top)
	g.set_color(1, bottom)
	g.add_point(0.55, bottom)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0, 1)
	t.width = 8
	t.height = 256
	return t


func _glow_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 256
	t.height = 256
	return t
