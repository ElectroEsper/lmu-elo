class_name LeagueSettings
extends RefCounted
## League settings that can be changed in the app (Settings screen), kept in
## user://league_settings.json. Anything missing from the file falls back to DEFAULTS, so new
## settings added later never break an older file. Read with LeagueSettings.get_value("key").

const PATH := "user://league_settings.json"

const DEFAULTS := {
	# Driver ranks, lowest first. A driver gets the highest rank whose "min" their rating reaches.
	"ranks": [
		{"name": "Bronze", "min": 0, "color": "#c98a5a"},
		{"name": "Silver", "min": 1395, "color": "#c3cad4"},
		{"name": "Gold", "min": 1580, "color": "#eac45a"},
		{"name": "Platinum", "min": 1750, "color": "#8edfee"},
	],
	"unranked_name": "Unranked",   # shown until a driver's rating has settled
	"rank_basis": "average",       # "average" of race and quali rating, or "race" / "quali" only
	"rank_settle_duels": 120,      # duels (race + quali together) before a driver gets a rank
	"rank_buffer": 30,             # promoted on reaching a rank's minimum, demoted only this far below it
	"rank_inactive_days": 180,     # no race in the class for this long (before the latest event): "inactive"; 0 = never
	"points": [25, 18, 15, 12, 10, 8, 6, 4, 2, 1],   # standings points for P1, P2, ...
	"grade_min_sessions": 3,       # sessions a driver needs before getting driver grades
	# Names shown on screen for classes (the data keeps the game's own class name, so specs
	# that really differ, like ELMS-spec and WEC-spec LMP2, stay separate)
	"class_labels": {"LMP2_ELMS": "LMP2+"},
	"rating_model": 2,             # rating scale the rank limits above are written for (Elo.RATING_MODEL)
	# Season championships: each series (from the file name, "s5-sc3" = Sprint) is scored on its
	# own, and each driver's worst rounds are dropped (a missed round counts as 0 and is dropped first).
	"drop_rounds": 1,
	"series_names": {"sc": "Sprint", "mc": "Multiclass"},
	# Race rules per series, from a season on (a later row for the same series takes over from its
	# season): fuel / virtual-energy use and tyre wear multipliers set on the server, whether
	# routine pit stops are part of the race, and stops the rules make compulsory.
	# Used to put past races on the same x1 footing and for the pit-stop forecast.
	"race_rules": [
		{"series": "sc", "from": 1, "fuel": 1.0, "tyre": 1.0, "pits": false, "min_stops": 0},
		{"series": "mc", "from": 1, "fuel": 2.0, "tyre": 2.0, "pits": true, "min_stops": 0},
		{"series": "mc", "from": 4, "fuel": 2.0, "tyre": 1.0, "pits": true, "min_stops": 0},
	],
}

# Rating model 2 spreads ratings about 3.4x wider around 1500 than model 1. Settings saved for
# model 1 get their rank limits and buffer stretched by this once, so ranks keep their meaning.
const MODEL1_TO_2 := 3.43

static var revision := 0      # goes up on every save, so caches know the settings changed
static var _data = null       # loaded lazily


static func get_value(key: String) -> Variant:
	_ensure()
	return _data.get(key, DEFAULTS.get(key))


static func all() -> Dictionary:
	_ensure()
	var out := DEFAULTS.duplicate(true)
	out.merge(_data, true)
	return out


# Replaces the settings with `values` (missing keys keep their defaults) and saves them.
static func save_all(values: Dictionary) -> Error:
	_data = values.duplicate(true)
	revision += 1
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(_data, "\t"))
	f.close()
	return OK


static func reset() -> Error:
	return save_all(DEFAULTS)


static func _ensure() -> void:
	if _data != null:
		return
	_data = {}
	if FileAccess.file_exists(PATH):
		var loaded = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if loaded is Dictionary:
			_data = loaded
			if int(_data.get("rating_model", 1)) < 2:
				_convert_from_model1()
	revision += 1


# Model 1 default limits -> the new defaults, which keep the same share of drivers in each rank
# (GT3, autumn 2026: 7 Platinum, 12 Gold, 46 Silver, 13 Bronze among active ranked drivers).
const MODEL1_DEFAULTS := {1475: 1395, 1520: 1580, 1575: 1750}


static func _convert_from_model1() -> void:
	if _data.has("ranks"):
		for r in _data["ranks"]:
			if r is Dictionary and float(r.get("min", 0)) > 0.0:
				var old := int(r["min"])
				if MODEL1_DEFAULTS.has(old):
					r["min"] = MODEL1_DEFAULTS[old]
				else:   # a limit the league set itself: stretched like the ratings
					r["min"] = int(snappedf(1500.0 + (float(old) - 1500.0) * MODEL1_TO_2, 5.0))
	if _data.has("rank_buffer"):
		var b := int(_data["rank_buffer"])
		_data["rank_buffer"] = 30 if b == 15 else int(snappedf(float(b) * MODEL1_TO_2, 5.0))
	_data["rating_model"] = 2
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_data, "\t"))
		f.close()


# ---------- Ranks, as the rest of the tool needs them ----------

# [{"name", "min": float, "color": Color}], sorted lowest first
static func ranks() -> Array:
	var out := []
	for r in get_value("ranks"):
		if r is Dictionary and str(r.get("name", "")).strip_edges() != "":
			out.append({"name": str(r["name"]), "min": float(r.get("min", 0)),
				"color": Color.from_string(str(r.get("color", "#ffffff")), Color.WHITE)})
	out.sort_custom(func(a, b): return a["min"] < b["min"])
	return out


# ---------- Class names on screen ----------
static var _label_rx := {}   # class -> RegEx, for the current labels
static var _label_rev := -1


# The text with every class name replaced by its display name (whole words only, so "GT3" never
# touches "LMGT3" inside a car name). Used for everything shown on screen and in exports.
static func label(text: String) -> String:
	var labels: Dictionary = get_value("class_labels")
	if labels.is_empty():
		return text
	if _label_rev != revision:
		_label_rx.clear()
		_label_rev = revision
		for cls in labels:
			var rx := RegEx.new()
			rx.compile("(?<![A-Za-z0-9_])" + _escape(str(cls)) + "(?![A-Za-z0-9_])")
			_label_rx[cls] = rx
	for cls in labels:
		if text.contains(str(cls)) and str(labels[cls]).strip_edges() != "":
			text = _label_rx[cls].sub(text, str(labels[cls]), true)
	return text


static func _escape(s: String) -> String:
	var out := ""
	for ch in s:
		out += ("\\" + ch) if ch in "\\.^$|?*+()[]{}" else ch
	return out


# The rules a race of this series and season ran under: {"fuel", "tyre", "pits", "min_stops"}.
# season 0 = the series' current rules (its latest row). A series without rules: x1, no stops.
static func rules_for(series: String, season: int) -> Dictionary:
	var best := {}
	for r in get_value("race_rules"):
		if not (r is Dictionary) or str(r.get("series", "")) != series:
			continue
		var from := int(r.get("from", 1))
		if season > 0 and from > season:
			continue
		if best.is_empty() or from >= int(best.get("from", 1)):
			best = r
	return {"fuel": float(best.get("fuel", 1.0)), "tyre": float(best.get("tyre", 1.0)),
		"pits": bool(best.get("pits", false)), "min_stops": int(best.get("min_stops", 0)),
		"known": not best.is_empty()}


static func points() -> Array:
	var out := []
	for p in get_value("points"):
		out.append(int(p))
	return out
