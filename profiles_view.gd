class_name ProfilesView
extends VBoxContainer

## "Profiles" screen: driver, car and track fingerprints. Built in code.
## Needs the autoloads Elo and Profiles.
## Click a column header to sort by it, click again to reverse. Hover a tag for what it means.

signal notice(text: String)

# What each driver tag means. Shown as a tooltip on the Tags cell and on the Tags header.
const TAG_INFO := {
	"Tyre whisperer": "Wears the tyres far less than the rest of the class.",
	"Tyre shredder": "Wears the tyres far more than the rest of the class.",
	"Track-limit bandit": "Goes over the track limits far more often per lap than the class.",
	"Contact magnet": "Has far more contacts with other cars per lap than the class.",
	"Metronome": "Very consistent: lap times vary far less than in the rest of the class.",
	"Fuel sipper": "Uses clearly less fuel per lap than the class.",
	"Fuel guzzler": "Uses clearly more fuel per lap than the class.",
	"Straight-line speed": "Reaches a clearly higher top speed than the class.",
	"Saturday hero": "Quicker in qualifying than in the race (at least 0.4% better, over 2+ qualis).",
	"Sunday driver": "Quicker in the race than in qualifying (at least 0.4% better, over 2+ qualis).",
}
# Tooltips for the column headers (one per column, same order as the columns).
const DRIVER_TIPS := [
	"Driver name. Aliases you merged are combined.",
	"Races with lap data in this class.",
	"Qualifying pace against the class median, in percent. Negative = quicker. Drivers with few sessions are pulled toward 0.",
	"Race pace on clean laps against the class median, in percent. Negative = quicker.",
	"Tyre wear per km against the class median, in percent. Negative = gentler on the tyres.",
	"Top speed against the class median, in percent. Positive = faster in a straight line.",
	"Fuel use per km against the class median, in percent. Negative = more economical.",
	"Track-limit warnings per lap.",
	"Contacts with other cars per lap.",
	"Lap-time spread as a percent of the median lap. Lower = more consistent.",
	"",
]
const CAR_TIPS := [
	"Car model.",
	"Driver entries seen with this car (league and training data).",
	"Qualifying pace of this car against the class median, in percent. Negative = quicker.",
	"Race pace of this car against the class median, in percent. Negative = quicker.",
	"Top speed against the class median, in percent.",
	"Fuel use per km against the class median, in percent. Negative = more economical.",
	"Tyre wear per km against the class median, in percent. Negative = gentler.",
]
const TRACK_TIPS := [
	"Track layout.",
	"Sessions recorded here (league and training data).",
	"Track length in km.",
	"Average speed over the best qualifying laps.",
	"Highest top speed recorded.",
	"Share of the lap time spent in sector 1, in percent.",
	"Share of the lap time spent in sector 2, in percent.",
	"Share of the lap time spent in sector 3, in percent.",
	"Tyre wear per km at this track, in percent.",
	"Fuel use per km at this track.",
	"Track-limit warnings per lap.",
]
const TAG_RULES := "Tags need 3+ races. \"Far\" means at least one standard deviation from the class average, and needs 6+ drivers with 3+ races to compare against. At most 3 tags are shown."

var class_pick := OptionButton.new()
var tabs := TabContainer.new()
var drivers := Tree.new()
var cars := Tree.new()
var tracks := Tree.new()
var layout_view := TrackLayoutView.new()   # track profiles built from MoTeC exports
var legend := Label.new()

var _titles := {}      # tree -> column titles
var _first_asc := {}   # tree -> per column: does the first click sort ascending?
var _right := {}       # tree -> columns that are right-aligned (numbers)
var _rows := {}        # tree -> [{"text": [...], "key": [...], "tip": {column: text}}]
var _sort := {}        # tree -> {"col": int, "asc": bool}   (col -1 = default order)


func _ready() -> void:
	var bar := HFlowContainer.new()
	add_child(bar)
	class_pick.item_selected.connect(func(_i: int): _fill())
	bar.add_child(class_pick)
	legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	legend.theme_type_variation = "Muted"
	add_child(legend)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	# first_asc: true where the lowest value is the "best" (quicker pace, less wear...) or text
	_setup(drivers, "Drivers", ["Driver", "Races", "Quali %", "Race %", "Tyre wear %", "Top speed %", "Fuel %", "Limits / lap", "Contacts / lap", "Lap spread %", "Tags"],
		0, 10, [true, false, true, true, true, false, true, true, true, true, true], range(1, 10))
	_setup(cars, "Cars", ["Car", "Entries", "Quali %", "Race %", "Top speed %", "Fuel %", "Tyre wear %"],
		0, -1, [true, false, true, true, false, true, true], range(1, 7))
	_setup(tracks, "Tracks", ["Track", "Visits", "Length km", "Avg km/h", "Top km/h", "S1 %", "S2 %", "S3 %", "Wear %/km", "Fuel %/km", "Limits / lap"],
		0, -1, [true, false, false, false, false, false, false, false, false, false, false], range(1, 11))
	var driver_tips := DRIVER_TIPS.duplicate()
	driver_tips[10] = _glossary()   # the Tags header lists every tag and its meaning
	for pair in [[drivers, driver_tips], [cars, CAR_TIPS], [tracks, TRACK_TIPS]]:
		for i in pair[1].size():
			pair[0].set_column_title_tooltip_text(i, pair[1][i])
	tabs.add_child(layout_view)
	tabs.set_tab_title(tabs.get_tab_count() - 1, "Layout")


func _setup(tree: Tree, title: String, cols: Array, wide: int, wide2: int, first_asc: Array, right_cols: Array) -> void:
	tree.columns = cols.size()
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	for i in cols.size():
		tree.set_column_expand(i, i == wide or i == wide2)
		tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT if i in right_cols else HORIZONTAL_ALIGNMENT_LEFT)
	tree.set_column_custom_minimum_width(wide, 170)
	tree.column_title_clicked.connect(_on_header_clicked.bind(tree))
	_titles[tree] = cols
	_first_asc[tree] = first_asc
	_right[tree] = right_cols
	_rows[tree] = []
	_sort[tree] = {"col": -1, "asc": true}
	_update_titles(tree)
	tabs.add_child(tree)
	tabs.set_tab_title(tabs.get_tab_count() - 1, title)


# Text shown when hovering the Tags column header: every tag and what it means.
func _glossary() -> String:
	var lines := PackedStringArray()
	for t in TAG_INFO:
		lines.append("%s: %s" % [t, TAG_INFO[t]])
	lines.append("")
	lines.append(TAG_RULES)
	return "\n".join(lines)


# ---------- Sorting ----------

func _on_header_clicked(column: int, button: int, tree: Tree) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	var s: Dictionary = _sort[tree]
	if s["col"] == column:
		s["asc"] = not s["asc"]
	else:
		s["col"] = column
		s["asc"] = _first_asc[tree][column]
	_update_titles(tree)
	_render(tree)


# Marks the sorted column in its title: " ^" ascending, " v" descending.
func _update_titles(tree: Tree) -> void:
	var s: Dictionary = _sort[tree]
	var cols: Array = _titles[tree]
	for i in cols.size():
		var mark := ""
		if i == s["col"]:
			mark = "  ▲" if s["asc"] else "  ▼"
		tree.set_column_title(i, str(cols[i]) + mark)


# Rows with an empty value always go last; ties fall back to the name.
func _row_before(a: Dictionary, b: Dictionary, col: int, asc: bool) -> bool:
	var ka = a["key"][col]
	var kb = b["key"][col]
	if ka == null and kb == null:
		return str(a["key"][0]).to_lower() < str(b["key"][0]).to_lower()
	if ka == null:
		return false
	if kb == null:
		return true
	if typeof(ka) == TYPE_STRING:
		var x := str(ka).to_lower()
		var y := str(kb).to_lower()
		if x == y:
			return str(a["key"][0]).to_lower() < str(b["key"][0]).to_lower()
		return x < y if asc else x > y
	if ka == kb:
		return str(a["key"][0]).to_lower() < str(b["key"][0]).to_lower()
	return ka < kb if asc else ka > kb


func _render(tree: Tree) -> void:
	tree.clear()
	var root := tree.create_item()
	var rows: Array = _rows[tree].duplicate()
	var s: Dictionary = _sort[tree]
	if s["col"] >= 0:
		rows.sort_custom(_row_before.bind(s["col"], s["asc"]))
	var right: Array = _right[tree]
	for r in rows:
		var it := tree.create_item(root)
		var text: Array = r["text"]
		for c in text.size():
			it.set_text(c, text[c])
			if c in right:
				it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
		for c in r["tip"]:
			it.set_tooltip_text(c, r["tip"][c])


# ---------- Filling ----------

func refresh() -> void:
	layout_view.refresh()
	if get_node_or_null("/root/Profiles") == null:
		legend.text = "The Profiles autoload is not running. Check Project Settings > Globals > Autoload (name 'Profiles', below 'Elo')."
		return
	Profiles.rebuild()
	var keep := class_pick.get_item_text(class_pick.selected) if class_pick.selected >= 0 and class_pick.item_count > 0 else ""
	class_pick.clear()
	for c in Profiles.classes():
		class_pick.add_item(c)
	for i in class_pick.item_count:
		if class_pick.get_item_text(i) == keep:
			class_pick.select(i)
	_fill()


func _fill() -> void:
	if class_pick.item_count == 0:
		for t in [drivers, cars, tracks]:
			_rows[t] = []
			_render(t)
		legend.text = "No lap-data fingerprints yet. Drop result XMLs (or a whole folder) on the window and choose League results or Training data; files imported earlier are completed automatically."
		return
	var cls := class_pick.get_item_text(class_pick.selected)
	legend.text = "Percent columns compare with the class median (negative pace = quicker). Few-race drivers are pulled toward the field, so early numbers are cautious. Click a column header to sort. Hover a header or a tag to see what it means. Cars and tracks also use training data."
	_fill_drivers(cls)
	_fill_cars(cls)
	_fill_tracks(cls)


func _num(v: Variant, fmt := "%+.2f") -> String:
	return "-" if v == null else fmt % v


func _fill_drivers(cls: String) -> void:
	var rows := Profiles.driver_rows(cls)
	var z := {}
	for k in ["wear", "top", "fuel", "tl", "con", "cons"]:
		z[k] = _zscores(rows, k)
	var out := []
	for r in rows:
		var has_r: bool = r["n_r"] > 0
		var has_q: bool = r["n_q"] > 0
		var tags := _tags(r, z)
		var tag_text := ", ".join(PackedStringArray(tags))
		out.append({
			"text": [
				r["name"], "%d" % r["n_r"],
				_num(r["qpace"]) if has_q else "-",
				_num(r["pace"]) if has_r else "-",
				_num(r["wear"]) if has_r else "-",
				_num(r["top"]) if has_r else "-",
				_num(r["fuel"]) if has_r else "-",
				_num(r["tl"], "%.2f") if has_r else "-",
				_num(r["con"], "%.3f") if has_r else "-",
				_num(r["cons"], "%.2f") if has_r else "-",
				tag_text],
			"key": [
				r["name"], r["n_r"],
				r["qpace"] if has_q else null,
				r["pace"] if has_r else null,
				r["wear"] if has_r else null,
				r["top"] if has_r else null,
				r["fuel"] if has_r else null,
				r["tl"] if has_r else null,
				r["con"] if has_r else null,
				r["cons"] if has_r else null,
				tag_text if tag_text != "" else null],
			"tip": {10: _tag_tip(tags)} if not tags.is_empty() else {},
		})
	_rows[drivers] = out
	_render(drivers)


# Tooltip for a Tags cell: each of the driver's tags with its meaning.
func _tag_tip(tags: Array) -> String:
	var lines := PackedStringArray()
	for t in tags:
		lines.append("%s: %s" % [t, TAG_INFO.get(t, "")])
	return "\n".join(lines)


# z-score of one trait for every driver with 3+ races ({} if the field is too small)
func _zscores(rows: Array, key: String) -> Dictionary:
	var vals := []
	for r in rows:
		if r["n_r"] >= 3:
			vals.append(r[key])
	if vals.size() < 6:
		return {}
	var mean := 0.0
	for v in vals:
		mean += v
	mean /= vals.size()
	var sq := 0.0
	for v in vals:
		sq += (v - mean) * (v - mean)
	var sd := sqrt(sq / vals.size())
	if sd < 1e-9:
		return {}
	var out := {}
	for r in rows:
		if r["n_r"] >= 3:
			out[r["name"]] = (r[key] - mean) / sd
	return out


func _tags(r: Dictionary, z: Dictionary) -> Array:
	var tags := []
	var n: String = r["name"]
	if r["n_r"] < 3:
		return tags
	var g := func(k: String) -> float: return z[k].get(n, 0.0)
	if g.call("wear") <= -1.0:
		tags.append("Tyre whisperer")
	elif g.call("wear") >= 1.0:
		tags.append("Tyre shredder")
	if g.call("tl") >= 1.0:
		tags.append("Track-limit bandit")
	if g.call("con") >= 1.0:
		tags.append("Contact magnet")
	if g.call("cons") <= -1.0:
		tags.append("Metronome")
	if g.call("fuel") <= -1.0:
		tags.append("Fuel sipper")
	elif g.call("fuel") >= 1.0:
		tags.append("Fuel guzzler")
	if g.call("top") >= 1.0:
		tags.append("Straight-line speed")
	if r["n_q"] >= 2:
		if r["qpace"] + 0.4 <= r["pace"]:
			tags.append("Saturday hero")
		elif r["pace"] + 0.4 <= r["qpace"]:
			tags.append("Sunday driver")
	return tags.slice(0, 3)


func _fill_cars(cls: String) -> void:
	var out := []
	for r in Profiles.car_rows(cls):
		out.append({
			"text": [r["car"], "%d" % r["n"], _num(r["qpace"]), _num(r["pace"]),
				_num(r["top"]), _num(r["fuel"]), _num(r["wear"])],
			"key": [r["car"], r["n"], r["qpace"], r["pace"], r["top"], r["fuel"], r["wear"]],
			"tip": {},
		})
	_rows[cars] = out
	_render(cars)


func _fill_tracks(cls: String) -> void:
	var out := []
	for r in Profiles.track_rows(cls):
		var text := [r["course"], "%d" % r.get("visits", 0), "%.2f" % (r.get("length", 0.0) / 1000.0),
			_num(r.get("kmh"), "%.1f"), _num(r.get("top"), "%.0f")]
		var key := [r["course"], r.get("visits", 0), r.get("length", 0.0), r.get("kmh"), r.get("top")]
		for i in 3:
			var k := "s%d" % (i + 1)
			text.append(_num(100.0 * r[k], "%.1f") if r.has(k) else "-")
			key.append(r[k] if r.has(k) else null)
		text.append(_num(r.get("wear_km"), "%.3f"))
		key.append(r.get("wear_km"))
		text.append(_num(r.get("fuel_km"), "%.3f"))
		key.append(r.get("fuel_km"))
		text.append(_num(r.get("tl"), "%.2f"))
		key.append(r.get("tl"))
		out.append({"text": text, "key": key, "tip": {}})
	_rows[tracks] = out
	_render(tracks)
