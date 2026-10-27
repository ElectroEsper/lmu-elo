class_name PredictView
extends VBoxContainer

## "Predict" screen: enter a grid (or an entry list), get win / podium / top-10 odds.
## Built entirely in code, like reports_view.gd. Needs predict.gd registered as autoload "Predict".

signal notice(text: String)

var class_pick := OptionButton.new()
var pre_quali := CheckBox.new()
var entries := TextEdit.new()
var info := Label.new()
var tree := Tree.new()
var backtest_out := Label.new()
var _busy := false


func _ready() -> void:
	var bar := HFlowContainer.new()
	add_child(bar)
	bar.add_child(class_pick)
	bar.add_child(_btn("Load grid from latest quali", _load_latest_quali))
	bar.add_child(_btn("Fill with recent drivers", _fill_recent))
	pre_quali.text = "Before quali (Elo only, ignore order)"
	bar.add_child(pre_quali)
	bar.add_child(_btn("Predict", _run))
	bar.add_child(_btn("Fit sigma (backtest)", _backtest))

	entries.custom_minimum_size = Vector2(0, 160)
	entries.placeholder_text = "One driver per line, pole position first.\nNames must match the ratings (aliases are resolved)."
	add_child(entries)

	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(info)

	tree.columns = 7
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var titles := ["Grid", "Driver", "Elo", "Win %", "Podium %", "Top 10 %", "Exp. pos"]
	for i in titles.size():
		tree.set_column_title(i, titles[i])
		tree.set_column_expand(i, i == 1)
	tree.set_column_custom_minimum_width(1, 180)
	add_child(tree)

	backtest_out.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(backtest_out)


## Called by the main screen whenever this view is shown.
func refresh() -> void:
	var keep := _current_class()
	class_pick.clear()
	var seen := {}
	for b in Elo.boards():
		if b[1] == "race" and not seen.has(b[0]):
			seen[b[0]] = true
			class_pick.add_item(b[0])
	for i in class_pick.item_count:
		if class_pick.get_item_text(i) == keep:
			class_pick.select(i)
	info.text = "Sigma (noise) = %.2f. Odds come from the grid plus race Elo; they ignore incidents, strategy and no-shows." % Predict.sigma


func _current_class() -> String:
	if class_pick.item_count == 0 or class_pick.selected < 0:
		return ""
	return class_pick.get_item_text(class_pick.selected)


func _btn(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b


# ---------- Filling the entry box ----------

## Most recent quali of the selected class, taken from the rating history.
func _load_latest_quali() -> void:
	var cls := _current_class()
	if cls == "":
		notice.emit("No class with ratings yet.")
		return
	for i in range(Elo.history.size() - 1, -1, -1):
		var rows := []
		for c in Elo.history[i]["changes"]:
			if c["sess"] == "quali" and c["cls"] == cls:
				rows.append(c)
		if rows.is_empty():
			continue
		rows.sort_custom(func(a, b): return a["pos"] < b["pos"])
		var names := []
		for r in rows:
			names.append(r["driver"])
		entries.text = "\n".join(names)
		pre_quali.button_pressed = false
		notice.emit("Loaded the %s quali from %s." % [cls, Elo.history[i]["file"]])
		return
	notice.emit("No saved quali found for " + cls + ".")


## Entry list for a pre-quali forecast: everyone who raced this class in the last 4 events.
func _fill_recent() -> void:
	var cls := _current_class()
	if cls == "":
		return
	var seen := {}
	var events_used := 0
	for i in range(Elo.history.size() - 1, -1, -1):
		var found := false
		for c in Elo.history[i]["changes"]:
			if c["sess"] == "race" and c["cls"] == cls:
				seen[c["driver"]] = true
				found = true
		if found:
			events_used += 1
		if events_used >= 4:
			break
	var elo = Predict.current_elo(cls)
	var names: Array = seen.keys()
	names.sort_custom(func(a, b): return elo.get(a, 0.0) > elo.get(b, 0.0))
	entries.text = "\n".join(names)
	pre_quali.button_pressed = true
	notice.emit("Filled with %d drivers from the last %d %s races. Delete anyone who is not coming." % [names.size(), events_used, cls])


# ---------- Predict ----------

func _entry_names() -> Array:
	var out := []
	for line in entries.text.split("\n"):
		var n: String = Elo.resolve(line.strip_edges())
		if n != "" and n not in out:
			out.append(n)
	return out


func _run() -> void:
	var cls := _current_class()
	var names := _entry_names()
	if cls == "" or names.size() < 2:
		notice.emit("Pick a class and enter at least two drivers.")
		return
	var rows = Predict.predict(names, cls, not pre_quali.button_pressed)
	var known = Predict.current_elo(cls)
	tree.clear()
	var root := tree.create_item()
	for r in rows:
		var it := tree.create_item(root)
		it.set_text(0, str(r["grid"]) if r["grid"] > 0 else "-")
		it.set_text(1, r["name"] + ("" if known.has(r["name"]) else " (new)"))
		it.set_text(2, str(roundi(r["elo"])))
		it.set_text(3, "%.1f" % (100.0 * r["win"]))
		it.set_text(4, "%.1f" % (100.0 * r["podium"]))
		it.set_text(5, "%.1f" % (100.0 * r["top10"]))
		it.set_text(6, "%.1f" % r["exp_pos"])
		for c in range(2, 7):
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
	notice.emit("Predicted %s with %d drivers (%d simulated races)." % [cls, names.size(), Predict.N_SIMS])


# ---------- Backtest ----------

func _backtest() -> void:
	if _busy:
		return
	_busy = true
	backtest_out.text = "Running backtest..."
	var s: Dictionary = await Predict.run_backtest()
	_busy = false
	if s.has("note"):
		backtest_out.text = s["note"]
		return
	var lines := ["Backtest on %d races (each predicted only from earlier ratings):" % s["races"]]
	for row in s["table"]:
		lines.append("sigma %.1f: podium Brier %.4f, top-10 Brier %.4f, winner log-loss %.2f" % [
			row["sigma"], row["podium_brier"], row["top10_brier"], row["win_logloss"]])
	lines.append("Using sigma = %.1f from now on." % s["sigma"])
	backtest_out.text = "\n".join(lines)
	refresh()
