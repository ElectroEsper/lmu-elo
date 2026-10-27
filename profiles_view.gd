class_name ProfilesView
extends VBoxContainer

## "Profiles" screen: driver, car and track fingerprints. Built in code.
## Needs the autoloads Elo and Profiles.

signal notice(text: String)

var class_pick := OptionButton.new()
var tabs := TabContainer.new()
var drivers := Tree.new()
var cars := Tree.new()
var tracks := Tree.new()
var legend := Label.new()


func _ready() -> void:
	var bar := HFlowContainer.new()
	add_child(bar)
	class_pick.item_selected.connect(func(_i: int): _fill())
	bar.add_child(class_pick)
	legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(legend)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	_setup(drivers, "Drivers", ["Driver", "Races", "Quali %", "Race %", "Tyre wear %", "Top speed %", "Fuel %", "Limits / lap", "Contacts / lap", "Lap spread %", "Tags"], 0, 10)
	_setup(cars, "Cars", ["Car", "Entries", "Quali %", "Race %", "Top speed %", "Fuel %", "Tyre wear %"], 0, -1)
	_setup(tracks, "Tracks", ["Track", "Visits", "Length km", "Avg km/h", "Top km/h", "S1 %", "S2 %", "S3 %", "Wear %/km", "Fuel %/km", "Limits / lap"], 0, -1)


func _setup(tree: Tree, title: String, cols: Array, wide: int, wide2: int) -> void:
	tree.columns = cols.size()
	tree.column_titles_visible = true
	tree.hide_root = true
	for i in cols.size():
		tree.set_column_title(i, cols[i])
		tree.set_column_expand(i, i == wide or i == wide2)
	tree.set_column_custom_minimum_width(wide, 170)
	tabs.add_child(tree)
	tabs.set_tab_title(tabs.get_tab_count() - 1, title)


func refresh() -> void:
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
	drivers.clear()
	cars.clear()
	tracks.clear()
	if class_pick.item_count == 0:
		legend.text = "No lap-data fingerprints yet. Confirm a result file, or drop the folder with your result XMLs on the window to backfill the saved events."
		return
	var cls := class_pick.get_item_text(class_pick.selected)
	legend.text = "Percent columns compare with the class median (negative pace = quicker). Few-race drivers are pulled toward the field, so early numbers are cautious. Tags need 3+ races."
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
	var root := drivers.create_item()
	for r in rows:
		var it := drivers.create_item(root)
		it.set_text(0, r["name"])
		it.set_text(1, "%d" % r["n_r"])
		it.set_text(2, _num(r["qpace"]) if r["n_q"] > 0 else "-")
		it.set_text(3, _num(r["pace"]) if r["n_r"] > 0 else "-")
		it.set_text(4, _num(r["wear"]) if r["n_r"] > 0 else "-")
		it.set_text(5, _num(r["top"]) if r["n_r"] > 0 else "-")
		it.set_text(6, _num(r["fuel"]) if r["n_r"] > 0 else "-")
		it.set_text(7, _num(r["tl"], "%.2f") if r["n_r"] > 0 else "-")
		it.set_text(8, _num(r["con"], "%.3f") if r["n_r"] > 0 else "-")
		it.set_text(9, _num(r["cons"], "%.2f") if r["n_r"] > 0 else "-")
		it.set_text(10, ", ".join(_tags(r, z)))
		for c in range(1, 10):
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)


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
	var root := cars.create_item()
	for r in Profiles.car_rows(cls):
		var it := cars.create_item(root)
		it.set_text(0, r["car"])
		it.set_text(1, "%d" % r["n"])
		it.set_text(2, _num(r["qpace"]))
		it.set_text(3, _num(r["pace"]))
		it.set_text(4, _num(r["top"]))
		it.set_text(5, _num(r["fuel"]))
		it.set_text(6, _num(r["wear"]))
		for c in range(1, 7):
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)


func _fill_tracks(cls: String) -> void:
	var root := tracks.create_item()
	for r in Profiles.track_rows(cls):
		var it := tracks.create_item(root)
		it.set_text(0, r["course"])
		it.set_text(1, "%d" % r.get("visits", 0))
		it.set_text(2, "%.2f" % (r.get("length", 0.0) / 1000.0))
		it.set_text(3, _num(r.get("kmh"), "%.1f"))
		it.set_text(4, _num(r.get("top"), "%.0f"))
		for i in 3:
			var key := "s%d" % (i + 1)
			it.set_text(5 + i, _num(100.0 * r[key], "%.1f") if r.has(key) else "-")
		it.set_text(8, _num(r.get("wear_km"), "%.3f"))
		it.set_text(9, _num(r.get("fuel_km"), "%.3f"))
		it.set_text(10, _num(r.get("tl"), "%.2f"))
		for c in range(1, 11):
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
