class_name ProfileView
extends VBoxContainer
## The Drivers screen: filter and pick any driver to see everything known about them.
## Needs the autoloads "Elo" and "Reports", plus table_view.gd and rating_chart.gd.

signal notice(text: String)

var search := LineEdit.new()
var picker := OptionButton.new()
var out_tabs := TabContainer.new()
var shown: Array = []   # tables currently displayed
var _typing := Timer.new()   # the profile is redrawn once typing pauses, not on every key


func _ready() -> void:
	var bar := HFlowContainer.new()
	add_child(bar)
	search.placeholder_text = "Type to filter drivers"
	search.custom_minimum_size = Vector2(220, 0)
	search.text_changed.connect(_on_search)
	_typing.one_shot = true
	_typing.wait_time = 0.35
	_typing.timeout.connect(_after_typing)
	add_child(_typing)
	bar.add_child(search)
	picker.custom_minimum_size = Vector2(240, 0)
	picker.item_selected.connect(_on_pick)
	bar.add_child(picker)
	var export_btn := Button.new()
	export_btn.text = "Export profile to Excel"
	export_btn.pressed.connect(_export)
	bar.add_child(export_btn)

	out_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(out_tabs)


# Called whenever the Drivers screen is opened or the data changed
func refresh() -> void:
	_fill_picker()
	_show()


func _fill_picker() -> void:
	var keep := _picked()
	var names := Elo.known_names()
	names.sort_custom(func(a, b): return Elo.pretty(a).to_lower() < Elo.pretty(b).to_lower())
	# tidied names (Elo.pretty); when two stored names tidy to the same, show the stored one too
	var seen := {}
	for n in names:
		var p := Elo.pretty(n)
		seen[p] = int(seen.get(p, 0)) + 1
	var filter := search.text.strip_edges().to_lower()
	picker.clear()
	for n in names:
		var p := Elo.pretty(n)
		if filter == "" or n.to_lower().contains(filter) or p.to_lower().contains(filter):
			picker.add_item(p if int(seen[p]) == 1 else "%s  [%s]" % [p, n])
			picker.set_item_metadata(picker.item_count - 1, n)
	for i in picker.item_count:
		if str(picker.get_item_metadata(i)) == keep:
			picker.select(i)
			return
	if picker.item_count > 0:
		picker.select(0)


# The stored name of the picked driver ("" if none).
func _picked() -> String:
	if picker.selected < 0:
		return ""
	return str(picker.get_item_metadata(picker.selected))


func _on_search(_text: String) -> void:
	_fill_picker()   # the list filters at once; the (slower) profile waits for a pause
	_typing.start()


func _after_typing() -> void:
	_show()


func _on_pick(_index: int) -> void:
	_show()


func _clear(container: Node) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()


func _message(text: String) -> void:
	shown = []
	_clear(out_tabs)
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(480, 0)
	out_tabs.add_child(l)
	out_tabs.set_tab_title(0, "Info")


func _show() -> void:
	if picker.item_count == 0:
		_message("No drivers to show. Confirm a result file first, or clear the filter.")
		return
	var keep := out_tabs.current_tab
	var tables := Reports.driver_profile(_picked())
	shown = tables
	_clear(out_tabs)
	for t in tables:
		out_tabs.add_child(TableView.build(t))
		out_tabs.set_tab_title(out_tabs.get_tab_count() - 1, LeagueSettings.label(t["title"]))
	out_tabs.current_tab = clampi(keep, 0, maxi(out_tabs.get_tab_count() - 1, 0))


# ---------- Excel export of the profile on screen ----------
func _export() -> void:
	if shown.is_empty():
		notice.emit("Nothing to export.")
		return
	var sheets := []
	for t in shown:
		sheets.append({"name": LeagueSettings.label(t["title"]), "headers": t["headers"], "rows": t["rows"]})
	var driver_name := Elo.pretty(_picked())
	var dir := AppPaths.exports()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/lmu_profile_%s_%s.xlsx" % [dir, driver_name.validate_filename().replace(" ", "_"), stamp]
	var err := Elo.write_xlsx(path, sheets)
	if err == OK:
		notice.emit("Exported: " + path)
		OS.shell_open(dir)
	else:
		notice.emit("Export failed (error %d)" % err)
