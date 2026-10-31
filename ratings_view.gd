class_name RatingsView
extends VBoxContainer
## "Ratings" screen: one leaderboard per class and session, with the driver merge tool above.

var shell: Node   # the main screen (for the merge dialog's messages)
var tabs := TabContainer.new()
var merge_dialog := DriverMergeDialog.new()


func _ready() -> void:
	var bar := HFlowContainer.new()
	var merge_btn := Button.new()
	merge_btn.text = "Merge drivers..."
	merge_btn.pressed.connect(func(): merge_dialog.open())
	bar.add_child(merge_btn)
	add_child(bar)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	merge_dialog.shell = shell
	add_child(merge_dialog)


func refresh() -> void:
	var keep := tabs.current_tab
	_clear(tabs)
	for b in Elo.boards():
		var rows := []
		var colours := []
		var rank := 1
		for row in Elo.leaderboard(b[0], b[1]):
			var rk := Ranks.of(row["name"], b[0])
			rows.append([rank, row["name"], roundi(row["r"]), int(row["d"]), rk["label"],
				"Settling" if row["d"] < Elo.SETTLED_DUELS else ""])
			colours.append(rk["color"])
			rank += 1
		tabs.add_child(TableView.build({
			"note": "Settling = fewer than %d duels so far, so the rating still moves quickly. Rank is for the whole class (race and quali together, see Reports > Ranks and Settings)." % int(Elo.SETTLED_DUELS),
			"headers": ["#", "Driver", "Rating", "Duels", "Rank", "Status"],
			"rows": rows,
			"tips": ["Place on the leaderboard.", "", "Elo rating.", "Head-to-head comparisons counted so far.", "League rank in this class.", ""],
			"cell_colors": {4: colours},
		}))
		tabs.set_tab_title(tabs.get_tab_count() - 1, LeagueSettings.label("%s %s" % [b[0], b[1]]))
	if tabs.get_tab_count() == 0:
		var empty := Label.new()
		empty.text = "No ratings yet. Confirm a result file first."
		tabs.add_child(empty)
		tabs.set_tab_title(0, "Empty")
	tabs.current_tab = clampi(keep, 0, maxi(tabs.get_tab_count() - 1, 0))


func _clear(container: Node) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()
