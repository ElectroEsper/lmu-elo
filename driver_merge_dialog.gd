class_name DriverMergeDialog
extends ConfirmationDialog
## "Merge drivers": makes two names one driver (or renames one), with a list of the merges made so
## far, each with Undo. Ratings are rebuilt from the saved events afterwards (elo.gd).

var shell: Node   # the main screen: status bar and data_changed()
var merge_from := OptionButton.new()
var merge_into := OptionButton.new()
var merge_new := LineEdit.new()
var merge_list := VBoxContainer.new()          # merges made so far, each with an Undo button


func _ready() -> void:
	title = "Merge drivers"
	ok_button_text = "Merge"
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	var intro := Label.new()
	intro.text = "Use this when one person appears under two names, or to rename a driver. All ratings are rebuilt from the saved events afterwards (the current ratings are backed up first), so every past result counts for the merged driver."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(intro)
	var grid := GridContainer.new()
	grid.columns = 2
	var l1 := Label.new()
	l1.text = "Merge this name:"
	grid.add_child(l1)
	grid.add_child(merge_from)
	var l2 := Label.new()
	l2.text = "into this driver:"
	grid.add_child(l2)
	grid.add_child(merge_into)
	var l3 := Label.new()
	l3.text = "or rename to:"
	grid.add_child(l3)
	merge_new.placeholder_text = "new name (leave empty to use the driver above)"
	merge_new.custom_minimum_size = Vector2(280, 0)
	grid.add_child(merge_new)
	box.add_child(grid)
	var made := Label.new()
	made.text = "Merges made so far:"
	box.add_child(made)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520, 140)
	merge_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(merge_list)
	box.add_child(scroll)
	add_child(box)
	confirmed.connect(_do_merge)


func open() -> void:
	var names := Elo.known_names()
	names.sort_custom(func(a, b): return str(a).to_lower() < str(b).to_lower())
	merge_from.clear()
	merge_into.clear()
	for n in names:
		merge_from.add_item(str(n))
		merge_into.add_item(str(n))
	if merge_into.item_count > 1:
		merge_into.select(1)
	merge_new.text = ""
	_fill_merge_list()
	popup_centered()


func _fill_merge_list() -> void:
	_clear(merge_list)
	var keys := Elo.aliases.keys()
	keys.sort_custom(func(a, b): return str(a).to_lower() < str(b).to_lower())
	if keys.is_empty():
		var none := Label.new()
		none.text = "none"
		merge_list.add_child(none)
	for a in keys:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "%s  ->  %s" % [a, Elo.aliases[a]]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		row.add_child(_btn("Undo", _undo_merge.bind(str(a))))
		merge_list.add_child(row)


func _do_merge() -> void:
	if merge_from.selected < 0:
		shell.set_status("No drivers to merge yet.")
		return
	var from_name := merge_from.get_item_text(merge_from.selected)
	var into := merge_new.text.strip_edges()
	if into == "" and merge_into.selected >= 0:
		into = merge_into.get_item_text(merge_into.selected)
	var s := Elo.merge_drivers(from_name, into)
	if s.has("error"):
		shell.set_status("Merge not done: " + str(s["error"]))
		return
	shell.set_status("%s is now %s. Ratings rebuilt from %d events." % [from_name, Elo.resolve(from_name), int(s["count"])])
	shell.data_changed()


func _undo_merge(alias_name: String) -> void:
	var s := Elo.unmerge_driver(alias_name)
	if s.has("error"):
		shell.set_status(str(s["error"]))
		return
	shell.set_status("%s is a separate driver again. Ratings rebuilt from %d events." % [alias_name, int(s["count"])])
	_fill_merge_list()
	shell.data_changed()


func _clear(container: Node) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()


func _btn(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b
