class_name UiTheme
extends RefCounted
## The look of the whole tool: colours, font, sizes and spacing, built in code.
## review_screen.gd applies it to the window once, so every screen, dialog, popup and tooltip uses it.
## To restyle the tool, change the constants below.

# ---------- Palette (dark) ----------
const BG := Color("14171c")          # window background
const SURFACE := Color("1b1f26")     # sidebar, panels, tables
const SURFACE_2 := Color("232933")   # inputs, buttons, table headers
const SURFACE_3 := Color("2c333f")   # hover
const BORDER := Color("323a46")
const TEXT := Color("e6e8eb")
const MUTED := Color("97a1ad")
const ACCENT := Color("e8833a")      # racing orange: active screen, main buttons, sorted column
const ACCENT_HOVER := Color("f09a55")
const ACCENT_SOFT := Color("f2b98c")  # table and grid headers
const SELECT := Color(0.91, 0.51, 0.23, 0.22)
const GOOD := Color("5cc98a")
const BAD := Color("e06666")
# track grades 1 to 5 (5 = the most of something): blue -> red
const GRADES := [Color(0.45, 0.65, 1.0), Color(0.45, 0.85, 0.85), Color(0.6, 0.9, 0.5), Color(1.0, 0.8, 0.35), Color(1.0, 0.45, 0.4)]
# driver grades 1 to 5 (5 = the best): red -> green, like a traffic light
const DRIVER_GRADES := [Color("ee5a5a"), Color("f0954a"), Color("e8d55a"), Color("a6dc5e"), Color("4fd27a")]

const FONT_SIZE := 15
const RADIUS := 6


static func grade_color(g: int) -> Color:
	return GRADES[clampi(g, 1, 5) - 1] if g > 0 else MUTED


static func driver_grade_color(g: int) -> Color:
	return DRIVER_GRADES[clampi(g, 1, 5) - 1] if g > 0 else MUTED


static func build() -> Theme:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Segoe UI", "Inter", "Roboto", "Noto Sans", "Open Sans", "sans-serif"])
	var bold := SystemFont.new()
	bold.font_names = font.font_names
	bold.font_weight = 650
	t.default_font = font
	t.default_font_size = FONT_SIZE

	# ---------- Text ----------
	t.set_color("font_color", "Label", TEXT)
	_variation(t, "HeaderLarge", "Label")
	t.set_font("font", "HeaderLarge", bold)
	t.set_font_size("font_size", "HeaderLarge", 22)
	_variation(t, "HeaderMedium", "Label")
	t.set_font("font", "HeaderMedium", bold)
	t.set_font_size("font_size", "HeaderMedium", 17)
	_variation(t, "SectionLabel", "Label")   # small caps-style label above a group of buttons
	t.set_font("font", "SectionLabel", bold)
	t.set_font_size("font_size", "SectionLabel", 12)
	t.set_color("font_color", "SectionLabel", MUTED)
	_variation(t, "Muted", "Label")
	t.set_color("font_color", "Muted", MUTED)
	_variation(t, "TableHeader", "Label")    # header row of grids built from labels
	t.set_font("font", "TableHeader", bold)
	t.set_color("font_color", "TableHeader", ACCENT_SOFT)

	# ---------- Panels ----------
	t.set_stylebox("panel", "Panel", _box(BG, 0))
	t.set_stylebox("panel", "PanelContainer", _box(SURFACE, RADIUS, 12))
	_variation(t, "Background", "Panel")
	t.set_stylebox("panel", "Background", _box(BG, 0))
	_variation(t, "Sidebar", "PanelContainer")
	var side := _box(SURFACE, 0, 14)
	side.border_width_right = 1
	side.border_color = BORDER
	t.set_stylebox("panel", "Sidebar", side)
	_variation(t, "StatusBar", "PanelContainer")
	var bar := _box(SURFACE, 0)
	bar.content_margin_left = 20
	bar.content_margin_right = 20
	bar.content_margin_top = 7
	bar.content_margin_bottom = 7
	bar.border_width_top = 1
	bar.border_color = BORDER
	t.set_stylebox("panel", "StatusBar", bar)
	_variation(t, "Card", "PanelContainer")
	var card := _box(SURFACE, RADIUS, 12)
	card.set_border_width_all(1)
	card.border_color = BORDER
	t.set_stylebox("panel", "Card", card)

	# ---------- Buttons (OptionButton and MenuButton use these too) ----------
	_buttons(t, "Button", SURFACE_2, SURFACE_3, BORDER, TEXT)
	t.set_constant("h_separation", "Button", 6)
	_variation(t, "AccentButton", "Button")  # the main action of a screen
	_buttons(t, "AccentButton", ACCENT, ACCENT_HOVER, ACCENT, Color("1a1208"))
	t.set_font("font", "AccentButton", bold)
	_variation(t, "SmallButton", "Button")   # Up / Down / Drop on the review lists
	var sm := _box(Color(0, 0, 0, 0), 4)
	sm.content_margin_left = 8
	sm.content_margin_right = 8
	sm.content_margin_top = 2
	sm.content_margin_bottom = 2
	var sm_h := sm.duplicate() as StyleBoxFlat
	sm_h.bg_color = SURFACE_3
	t.set_stylebox("normal", "SmallButton", sm)
	t.set_stylebox("disabled", "SmallButton", sm)
	t.set_stylebox("focus", "SmallButton", StyleBoxEmpty.new())
	for s in ["hover", "pressed", "hover_pressed"]:
		t.set_stylebox(s, "SmallButton", sm_h)
	t.set_color("font_color", "SmallButton", MUTED)
	t.set_font_size("font_size", "SmallButton", 13)
	_variation(t, "NavButton", "Button")     # screen buttons in the sidebar
	var nav := _box(Color(0, 0, 0, 0), RADIUS)
	nav.content_margin_left = 12
	nav.content_margin_top = 8
	nav.content_margin_bottom = 8
	var nav_h := nav.duplicate() as StyleBoxFlat
	nav_h.bg_color = SURFACE_3
	var nav_on := nav.duplicate() as StyleBoxFlat
	nav_on.bg_color = SURFACE_2
	nav_on.border_width_left = 3
	nav_on.border_color = ACCENT
	nav_on.content_margin_left = 9
	t.set_stylebox("normal", "NavButton", nav)
	t.set_stylebox("hover", "NavButton", nav_h)
	t.set_stylebox("pressed", "NavButton", nav_on)
	t.set_stylebox("hover_pressed", "NavButton", nav_on)
	t.set_stylebox("focus", "NavButton", StyleBoxEmpty.new())
	t.set_color("font_color", "NavButton", MUTED)
	t.set_color("font_hover_color", "NavButton", TEXT)
	t.set_color("font_pressed_color", "NavButton", TEXT)
	t.set_color("font_hover_pressed_color", "NavButton", TEXT)
	t.set_font("font", "NavButton", bold)
	# check boxes inherit from Button, so they need their backgrounds removed again
	for type in ["CheckBox", "CheckButton"]:
		for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			t.set_stylebox(s, type, StyleBoxEmpty.new())
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hover_color", type, TEXT)
		t.set_color("font_pressed_color", type, TEXT)
		t.set_color("font_hover_pressed_color", type, TEXT)

	# ---------- Inputs ----------
	var field := _box(SURFACE_2, RADIUS)
	field.set_border_width_all(1)
	field.border_color = BORDER
	field.content_margin_left = 10
	field.content_margin_right = 10
	field.content_margin_top = 5
	field.content_margin_bottom = 5
	var field_f := field.duplicate() as StyleBoxFlat
	field_f.border_color = ACCENT
	field_f.bg_color = Color(0, 0, 0, 0)
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, field)
		t.set_stylebox("read_only", type, field)
		t.set_stylebox("focus", type, field_f)
		t.set_color("font_color", type, TEXT)
		t.set_color("font_placeholder_color", type, MUTED)
		t.set_color("caret_color", type, ACCENT)
		t.set_color("selection_color", type, SELECT)

	# ---------- Tabs ----------
	var tab_off := _box(Color(0, 0, 0, 0), 0)
	tab_off.content_margin_left = 14
	tab_off.content_margin_right = 14
	tab_off.content_margin_top = 7
	tab_off.content_margin_bottom = 7
	var tab_hover := tab_off.duplicate() as StyleBoxFlat
	tab_hover.bg_color = SURFACE_3
	var tab_on := tab_off.duplicate() as StyleBoxFlat
	tab_on.bg_color = SURFACE
	tab_on.border_width_bottom = 2
	tab_on.border_color = ACCENT
	var tab_panel := _box(SURFACE, RADIUS, 12)
	for type in ["TabContainer", "TabBar"]:
		t.set_stylebox("tab_unselected", type, tab_off)
		t.set_stylebox("tab_hovered", type, tab_hover)
		t.set_stylebox("tab_selected", type, tab_on)
		t.set_stylebox("tab_disabled", type, tab_off)
		t.set_stylebox("tab_focus", type, StyleBoxEmpty.new())
		t.set_color("font_selected_color", type, TEXT)
		t.set_color("font_hovered_color", type, TEXT)
		t.set_color("font_unselected_color", type, MUTED)
	t.set_stylebox("panel", "TabContainer", tab_panel)
	t.set_stylebox("tabbar_background", "TabContainer", StyleBoxEmpty.new())

	# ---------- Tables (Tree) ----------
	t.set_stylebox("panel", "Tree", _box(SURFACE, RADIUS, 4))
	t.set_stylebox("focus", "Tree", StyleBoxEmpty.new())
	var sel := _box(SELECT, 3)
	t.set_stylebox("selected", "Tree", sel)
	t.set_stylebox("selected_focus", "Tree", sel)
	t.set_stylebox("cursor", "Tree", StyleBoxEmpty.new())
	t.set_stylebox("cursor_unfocused", "Tree", StyleBoxEmpty.new())
	var hov := _box(Color(1, 1, 1, 0.04), 3)
	t.set_stylebox("hovered", "Tree", hov)
	t.set_stylebox("hovered_dimmed", "Tree", hov)
	var th := _box(SURFACE_2, 0)
	th.content_margin_left = 8
	th.content_margin_right = 8
	th.content_margin_top = 6
	th.content_margin_bottom = 6
	th.border_width_bottom = 1
	th.border_color = BORDER
	var th_h := th.duplicate() as StyleBoxFlat
	th_h.bg_color = SURFACE_3
	t.set_stylebox("title_button_normal", "Tree", th)
	t.set_stylebox("title_button_hover", "Tree", th_h)
	t.set_stylebox("title_button_pressed", "Tree", th_h)
	t.set_font("title_button_font", "Tree", bold)
	t.set_color("title_button_color", "Tree", ACCENT_SOFT)
	t.set_color("font_color", "Tree", TEXT)
	t.set_color("font_selected_color", "Tree", TEXT)
	t.set_color("font_hovered_color", "Tree", TEXT)
	t.set_color("guide_color", "Tree", Color(1, 1, 1, 0.05))
	t.set_constant("draw_guides", "Tree", 1)
	t.set_constant("draw_relationship_lines", "Tree", 0)
	t.set_constant("v_separation", "Tree", 6)
	t.set_constant("h_separation", "Tree", 8)
	t.set_constant("item_margin", "Tree", 0)
	t.set_constant("inner_item_margin_left", "Tree", 8)
	t.set_constant("inner_item_margin_right", "Tree", 8)

	# ---------- Popups, dialogs, tooltips ----------
	var pop := _box(SURFACE_2, RADIUS, 6)
	pop.set_border_width_all(1)
	pop.border_color = BORDER
	t.set_stylebox("panel", "PopupMenu", pop)
	t.set_stylebox("hover", "PopupMenu", _box(SELECT, 4))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", TEXT)
	t.set_constant("v_separation", "PopupMenu", 6)
	t.set_stylebox("panel", "PopupPanel", pop)
	t.set_stylebox("panel", "AcceptDialog", _box(SURFACE, 0, 14))
	var win := _box(SURFACE, RADIUS)
	win.set_border_width_all(1)
	win.border_color = BORDER
	win.expand_margin_top = 30
	win.expand_margin_left = 1
	win.expand_margin_right = 1
	win.expand_margin_bottom = 1
	t.set_stylebox("embedded_border", "Window", win)
	t.set_stylebox("embedded_unfocused_border", "Window", win)
	t.set_constant("title_height", "Window", 30)
	t.set_color("title_color", "Window", TEXT)
	t.set_font("title_font", "Window", bold)
	t.set_stylebox("panel", "TooltipPanel", pop)
	t.set_color("font_color", "TooltipLabel", TEXT)

	# ---------- Scroll bars, separators ----------
	for type in ["VScrollBar", "HScrollBar"]:
		var track := StyleBoxFlat.new()
		track.bg_color = Color(0, 0, 0, 0)
		track.content_margin_left = 4
		track.content_margin_right = 4
		track.content_margin_top = 4
		track.content_margin_bottom = 4
		t.set_stylebox("scroll", type, track)
		t.set_stylebox("scroll_focus", type, track)
		t.set_stylebox("grabber", type, _box(Color(1, 1, 1, 0.14), 4))
		t.set_stylebox("grabber_highlight", type, _box(Color(1, 1, 1, 0.24), 4))
		t.set_stylebox("grabber_pressed", type, _box(Color(1, 1, 1, 0.32), 4))
	var line := StyleBoxLine.new()
	line.color = BORDER
	line.thickness = 1
	t.set_stylebox("separator", "HSeparator", line)
	t.set_constant("separation", "HSeparator", 12)

	# ---------- Spacing ----------
	t.set_constant("separation", "VBoxContainer", 10)
	t.set_constant("separation", "HBoxContainer", 8)
	t.set_constant("h_separation", "HFlowContainer", 8)
	t.set_constant("v_separation", "HFlowContainer", 8)
	t.set_constant("h_separation", "GridContainer", 16)
	t.set_constant("v_separation", "GridContainer", 6)
	return t


# A flat box with a colour, rounded corners and an even inner margin.
static func _box(colour: Color, radius := 0, margin := -1) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = colour
	b.set_corner_radius_all(radius)
	b.anti_aliasing = true
	if margin >= 0:
		b.set_content_margin_all(margin)
	return b


static func _buttons(t: Theme, type: String, bg: Color, hover: Color, border: Color, text: Color) -> void:
	var n := _box(bg, RADIUS)
	n.set_border_width_all(1)
	n.border_color = border
	n.content_margin_left = 14
	n.content_margin_right = 14
	n.content_margin_top = 6
	n.content_margin_bottom = 6
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = hover
	var p := n.duplicate() as StyleBoxFlat
	p.bg_color = hover.darkened(0.12)
	var d := n.duplicate() as StyleBoxFlat
	d.bg_color = bg.darkened(0.35)
	d.border_color = border.darkened(0.35)
	var f := StyleBoxFlat.new()
	f.draw_center = false
	f.set_border_width_all(1)
	f.border_color = ACCENT
	f.set_corner_radius_all(RADIUS)
	t.set_stylebox("normal", type, n)
	t.set_stylebox("hover", type, h)
	t.set_stylebox("pressed", type, p)
	t.set_stylebox("hover_pressed", type, p)
	t.set_stylebox("disabled", type, d)
	t.set_stylebox("focus", type, f)
	t.set_color("font_color", type, text)
	t.set_color("font_hover_color", type, text)
	t.set_color("font_pressed_color", type, text)
	t.set_color("font_hover_pressed_color", type, text)
	t.set_color("font_focus_color", type, text)
	t.set_color("font_disabled_color", type, Color(text, 0.4))


static func _variation(t: Theme, name: String, base: String) -> void:
	t.set_type_variation(name, base)
