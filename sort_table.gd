class_name SortTable
extends Tree
## A table that sorts itself: click a column header to sort by it, click again to reverse,
## a third time to go back to the original order.
## set_table(headers, rows): each row is an array of cell values. Numbers stay numbers, so
## they sort as numbers; text like "+1.25" or "12 %" sorts as a number too. Empty cells and
## "-" always go last. Number columns are right-aligned.

const MAX_SIZED_ROWS := 300   # rows looked at when choosing column widths

var headers: Array = []
var rows: Array = []
var header_tips: Array = []   # optional tooltip per column header
var grade_col := -1           # column holding "n / 5" driver grades, red (1) to green (5); -1 = none
var cell_tips := {}           # column -> [tooltip per row, in the original row order]
var cell_colors := {}         # column -> [Color per row, in the original row order] (e.g. ranks)

var _numeric: Array = []      # per column: holds numbers?
var _col := -1                # sorted column, -1 = original order
var _asc := true


func _init() -> void:
	hide_root = true
	column_titles_visible = true
	select_mode = Tree.SELECT_ROW
	column_title_clicked.connect(_on_title_clicked)


func set_table(new_headers: Array, new_rows: Array, tips: Array = []) -> void:
	headers = new_headers
	rows = new_rows
	header_tips = tips
	columns = maxi(headers.size(), 1)
	if _col >= columns:
		_col = -1
	_numeric = []
	for c in headers.size():
		_numeric.append(_is_numeric_column(c))
	_size_columns()
	_render()


static func cell_text(v) -> String:
	match typeof(v):
		TYPE_NIL:
			return ""
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			return "%.2f" % v
		_:
			return str(v)


# ---------- Sorting ----------
func _on_title_clicked(column: int, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_LEFT:
		return
	# text sorts A to Z first, numbers high to low first; the third click restores the order
	var natural: bool = not _numeric[column] if column < _numeric.size() else true
	if _col != column:
		_col = column
		_asc = natural
	elif _asc == natural:
		_asc = not natural
	else:
		_col = -1
	_render()


# Sort key of a cell: a float, a lowercase string, or null for an empty cell.
static func _key(v):
	match typeof(v):
		TYPE_NIL:
			return null
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_BOOL:
			return 1.0 if v else 0.0
	var s := str(v).strip_edges()
	if s == "" or s == "-":
		return null
	var n := s.trim_suffix("%").trim_suffix("s").strip_edges().trim_prefix("+")
	if n.is_valid_float():
		return n.to_float()
	return s.to_lower()


func _before(a: int, b: int) -> bool:
	var ka = _key(_cell(a, _col))
	var kb = _key(_cell(b, _col))
	if ka == null or kb == null:
		if ka == null and kb == null:
			return a < b
		return kb == null            # empty cells last, whatever the direction
	var na := typeof(ka) == TYPE_FLOAT
	var nb := typeof(kb) == TYPE_FLOAT
	if na != nb:
		return na                    # numbers before text
	if ka == kb:
		return a < b                 # ties keep the original order
	return ka < kb if _asc else ka > kb


func _cell(row: int, col: int):
	var r: Array = rows[row]
	return r[col] if col < r.size() else null


# ---------- Drawing ----------
func _render() -> void:
	clear()
	var root := create_item()
	for c in headers.size():
		var mark := ""
		if c == _col:
			mark = "  ▲" if _asc else "  ▼"
		set_column_title(c, LeagueSettings.label(str(headers[c])) + mark)
		set_column_title_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT if _numeric[c] else HORIZONTAL_ALIGNMENT_LEFT)
		var tip := str(header_tips[c]) if c < header_tips.size() else ""
		set_column_title_tooltip_text(c, (tip + "\n" if tip != "" else "") + "Click to sort.")
	var order := range(rows.size())
	if _col >= 0:
		order.sort_custom(_before)
	for i in order:
		var it := create_item(root)
		var r: Array = rows[i]
		for c in mini(r.size(), headers.size()):
			var txt := LeagueSettings.label(cell_text(r[c]))
			it.set_text(c, txt)
			if _numeric[c]:
				it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
			if txt.length() > 28:
				it.set_tooltip_text(c, txt)
			if c == grade_col and txt.length() == 5 and txt.ends_with(" / 5"):
				it.set_custom_color(c, UiTheme.driver_grade_color(txt.left(1).to_int()))   # "4 / 5" -> 4
			if cell_colors.has(c) and i < cell_colors[c].size() and cell_colors[c][i] is Color:
				it.set_custom_color(c, cell_colors[c][i])
			if cell_tips.has(c) and i < cell_tips[c].size():
				it.set_tooltip_text(c, str(cell_tips[c][i]))


# Every column gets the width that fits its header and values; the last text column
# (or the last column, if all hold numbers) takes the rest of the width.
func _size_columns() -> void:
	var grow_col := headers.size() - 1
	for c in headers.size():
		if not _numeric[c]:
			grow_col = c
	for c in headers.size():
		var chars := str(headers[c]).length() + 3   # room for the sort arrow
		for i in mini(rows.size(), MAX_SIZED_ROWS):
			chars = maxi(chars, cell_text(_cell(i, c)).length())
		chars = mini(chars, 48)
		var per_char := 8 if _numeric[c] else 10   # digits are narrow, capitals and names are not
		set_column_custom_minimum_width(c, clampi(chars * per_char + 24, 48, 440))
		set_column_expand(c, c == grow_col)
		set_column_expand_ratio(c, maxi(chars, 4))
		set_column_clip_content(c, true)


func _is_numeric_column(c: int) -> bool:
	var seen := false
	for i in mini(rows.size(), MAX_SIZED_ROWS):
		var k = _key(_cell(i, c))
		if k == null:
			continue
		if typeof(k) != TYPE_FLOAT:
			return false
		seen = true
	return seen
