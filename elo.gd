extends Node
## Elo rating system for LMU result files.
## Register this script as an autoload named "Elo"
## (Project Settings > Globals > Autoload).

# ---------- Settings ----------
const START := 1500.0
# Tuned on four seasons of league results (90 events): replaying them with different settings,
# these predicted who finishes ahead in the next session best (75% right, was 73% with 32 -> 16).
const K_START := 128.0
const K_END := 64.0
const K_RAMP_DUELS := 480.0   # duels needed to go from K_START to K_END
const SETTLED_DUELS := 120.0  # below this many duels a rating is shown as "settling" (provisional)
# Ratings saved by an older model are replayed with this one at start-up (see _ready).
# 2: bigger K, and a driver's first quali (or race) rating starts from their race (or quali) one.
const RATING_MODEL := 2
const SAVE_PATH := "user://elo.json"
const INCIDENT_GAP := 5.0    # contact reports closer than this (seconds) count as one incident

# XML section -> which rating session it feeds, and which field gives the order
const SECTIONS := {
	"Race":    {"session": "race",  "field": "ClassPosition"},
	"Qualify": {"session": "quali", "field": "ClassPosition"},
}

# ---------- State ----------
var ratings := {}     # "name|class|session" -> {"r": rating, "d": duels fought}
var processed := {}   # file sha256 -> file name
# Session content id -> file name. Catches the same event arriving as another file: a renamed
# copy, or another player's log of the same race (different bytes, clocks a few seconds apart).
var sessions_seen := {}
var history := []     # per event: {"file", "time", "changes": [...], "stats": {...}}
var aliases := {}     # "John P" -> "John Peters"
var revision := 0     # goes up on every save, so caches elsewhere know the data changed
var load_error := ""  # set when elo.json could not be read at start-up (shown on the main screen)


var _model_loaded := RATING_MODEL
var _needs_backfill := false


func _ready() -> void:
	load_ratings()
	if _needs_backfill:
		_backfill_sessions()
	if _model_loaded < RATING_MODEL and not history.is_empty() and DirAccess.dir_exists_absolute("user://events"):
		rebuild_all()   # ratings from an older model: replay every event once with the new one
		load_error = ("" if load_error == "" else load_error + " ") + "Ratings were recalculated with the updated rating model (bigger steps, so they spread wider than before)."


# ---------- Seasons ----------
# The season an event belongs to, from the file name ("s5-mc2-r.xml" -> "Season 5"); files
# named another way are grouped by the year they were run.
var _season_rx := RegEx.create_from_string("(?i)^s(\\d+)[-_ ]")


func season_of(ev: Dictionary) -> String:
	var m := _season_rx.search(str(ev.get("file", "")))
	if m != null:
		return "Season %d" % int(m.get_string(1))
	var t := int(ev.get("time", 0))
	return Time.get_date_string_from_unix_time(t).left(4) if t > 0 else "Undated"


# The series an event belongs to, from the code after the season in the file name
# ("s5-mc2-r.xml" -> "mc" -> "Multiclass", names in Settings); "" when the name has no code.
var _series_rx := RegEx.create_from_string("(?i)^s\\d+[-_ ]([a-z]+)\\d")


func series_of(ev: Dictionary) -> String:
	var m := _series_rx.search(str(ev.get("file", "")))
	if m == null:
		return ""
	var code := m.get_string(1).to_lower()
	var names: Dictionary = LeagueSettings.get_value("series_names")
	return str(names.get(code, code.to_upper()))


# Seasons in the order they started
func seasons() -> Array:
	var first := {}
	for ev in history:
		var s := season_of(ev)
		if not first.has(s) or int(ev.get("time", 0)) < first[s]:
			first[s] = int(ev.get("time", 0))
	var out := first.keys()
	out.sort_custom(func(a, b): return first[a] < first[b])
	return out


# ---------- Elo core ----------
func _key(driver: String, cls: String, sess: String) -> String:
	return "%s|%s|%s" % [driver, cls, sess]


# A new rating starts at START, or, when the driver already has a rating for the other session
# of the same class (race for a first quali, quali for a first race), from that rating: someone
# rated in races is not a complete unknown in qualifying. From then on each moves on its own.
func _entry(k: String) -> Dictionary:
	if not ratings.has(k):
		var parts := k.rsplit("|", true, 2)
		var start := START
		if parts.size() == 3:
			var other := "%s|%s|%s" % [parts[0], parts[1], "race" if parts[2] == "quali" else "quali"]
			if ratings.has(other):
				start = float(ratings[other]["r"])
		ratings[k] = {"r": start, "d": 0}
	return ratings[k]


func _k_for(duels: float) -> float:
	return lerpf(K_START, K_END, clampf(duels / K_RAMP_DUELS, 0.0, 1.0))


# order: driver names, best position first, already filtered to ONE class
# Returns the list of rating changes (one per driver) for the history log.
func update_session(order: Array, cls: String, sess: String) -> Array:
	var n := order.size()
	if n < 2:
		return []
	var deltas := {}
	for i in n:
		var ki := _key(order[i], cls, sess)
		var ri: float = _entry(ki)["r"]
		var score := 0.0
		for j in n:
			if i == j:
				continue
			var rj: float = _entry(_key(order[j], cls, sess))["r"]
			var e := 1.0 / (1.0 + pow(10.0, (rj - ri) / 400.0))
			var s := 1.0 if i < j else 0.0
			score += s - e
		deltas[ki] = _k_for(_entry(ki)["d"]) * score / (n - 1)
	# apply together, so processing order doesn't matter
	var changes := []
	for i in n:
		var k := _key(order[i], cls, sess)
		var before: float = ratings[k]["r"]
		ratings[k]["r"] += deltas[k]
		ratings[k]["d"] += n - 1
		changes.append({
			"driver": order[i], "cls": cls, "sess": sess,
			"pos": i + 1, "of": n,
			"before": before, "after": ratings[k]["r"],
		})
	return changes


# ---------- XML parsing ----------
# Returns {"Qualify": [driver dicts], "Race": [driver dicts], "Notes": {...}}
# Each driver dict holds the direct child fields plus "_laps": [[lap number, elapsed time], ...].
# Notes[session] = {"inc": {driver: {"veh": n, "env": n}}, "pens": {driver: n}}
func parse_results(path: String) -> Dictionary:
	var out := {
		"Qualify": [], "Race": [],
		"Notes": {
			"Qualify": {"inc": {}, "pens": {}, "inc_ev": []},
			"Race": {"inc": {}, "pens": {}, "inc_ev": []},
		},
	}
	var p := XMLParser.new()
	if p.open(path) != OK:
		push_error("Can't open " + path)
		return out

	var inc_rx := RegEx.new()
	inc_rx.compile("^(.*)\\((\\d+)\\) reported contact \\([\\d.]+\\) with (.*)$")
	var last_inc := {}   # "driver|other" -> time of the last contact report

	var session := ""
	var driver := {}
	var depth := 0
	var session_depth := -1
	var driver_depth := -1
	var field := ""
	var in_incident := false
	var incident_et := 0.0

	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				if p.is_empty():
					continue   # self-closing tags carry nothing we need
				var tag := p.get_node_name()
				depth += 1
				if session == "" and (tag == "Race" or tag == "Qualify"):
					session = tag
					session_depth = depth
				elif session != "" and driver_depth == -1 and tag == "Driver":
					driver = {"_laps": []}
					driver_depth = depth
				elif driver_depth != -1 and depth == driver_depth + 1:
					if tag == "Lap":
						driver["_laps"].append([
							int(p.get_named_attribute_value_safe("num")),
							float(p.get_named_attribute_value_safe("et"))])
					else:
						field = tag
				elif session != "" and driver_depth == -1:
					if tag == "Incident":
						in_incident = true
						incident_et = float(p.get_named_attribute_value_safe("et"))
					elif tag == "Penalty" and p.has_attribute("Driver"):
						var pens: Dictionary = out["Notes"][session]["pens"]
						var penalised := p.get_named_attribute_value_safe("Driver")
						pens[penalised] = pens.get(penalised, 0) + 1
			XMLParser.NODE_TEXT:
				if field != "":
					driver[field] = p.get_node_data().strip_edges()
				elif in_incident:
					var m := inc_rx.search(p.get_node_data().strip_edges())
					if m != null:
						var who := m.get_string(1)
						var other := m.get_string(3)
						var k := who + "|" + other
						if incident_et - float(last_inc.get(k, -1000.0)) > INCIDENT_GAP:
							var kind := "veh" if other.begins_with("another vehicle") else "env"
							out["Notes"][session]["inc_ev"].append([who, kind, incident_et])   # counted at session end
						last_inc[k] = incident_et
			XMLParser.NODE_ELEMENT_END:
				if driver_depth != -1 and depth == driver_depth:
					out[session].append(driver)
					driver_depth = -1
				elif session != "" and depth == session_depth:
					_count_incidents(out, session)
					session = ""
					session_depth = -1
					last_inc.clear()
				field = ""
				in_incident = false
				depth -= 1
	return out


# Contacts after a driver's own chequered flag (celebrating into walls, cool-down lap bumps) do
# not count. Incidents come before the drivers in the file, so they are counted here, at the end
# of the session, once every driver's finish time is known. Non-finishers keep everything.
func _count_incidents(out: Dictionary, session: String) -> void:
	var fin := {}
	for d in out[session]:
		var ft := float(d.get("FinishTime", "0"))
		if ft > 0.0 and d.has("Name"):
			fin[d["Name"]] = ft
	var inc := {}
	for ev in out["Notes"][session]["inc_ev"]:
		if fin.has(ev[0]) and float(ev[2]) > fin[ev[0]]:
			continue
		var e: Dictionary = inc.get(ev[0], {"veh": 0, "env": 0})
		e[ev[1]] += 1
		inc[ev[0]] = e
	out["Notes"][session]["inc"] = inc


func _valid(d: Dictionary, section: String) -> bool:
	for f in ["Name", "CarClass", "ClassPosition"]:
		if not d.has(f):
			return false
	if d.get("FinishStatus", "") == "DQ":   # unverified string
		return false
	if section == "Race":
		return int(d.get("Laps", "0")) > 0          # 0 laps = never started
	return float(d.get("BestLapTime", "-1")) > 0.0  # quali: must have set a time


# Returns {class: [names in order]}
func _orders(drivers: Array, section: String, field: String) -> Dictionary:
	var by_class := {}
	for d in drivers:
		if _valid(d, section) and d.has(field):
			if not by_class.has(d["CarClass"]):
				by_class[d["CarClass"]] = []
			by_class[d["CarClass"]].append(d)
	var out := {}
	for cls in by_class:
		var entries: Array = by_class[cls]
		entries.sort_custom(func(a, b): return int(a[field]) < int(b[field]))
		var ids := []
		for e in entries:
			var driver_name: String = resolve(e["Name"])
			if driver_name not in ids:
				ids.append(driver_name)
		out[cls] = ids
	return out


# Laps led per driver, within their class: whoever has the lowest elapsed time at the
# end of each lap number among their class.
func _laps_led(drivers: Array) -> Dictionary:
	var best := {}   # "class|lap" -> [elapsed time, driver name]
	for d in drivers:
		if not d.has("Name") or not d.has("CarClass"):
			continue
		for lap in d["_laps"]:
			var key := "%s|%d" % [d["CarClass"], lap[0]]
			if lap[1] > 0.0 and (not best.has(key) or lap[1] < best[key][0]):
				best[key] = [lap[1], d["Name"]]
	var led := {}
	for key in best:
		var leader: String = best[key][1]
		led[leader] = led.get(leader, 0) + 1
	return led


# Per-driver extras for the reports: {class: {driver: {...}}}
func _stats(parsed: Dictionary, section: String) -> Dictionary:
	var notes: Dictionary = parsed["Notes"][section]
	var led := _laps_led(parsed[section])
	var out := {}
	for d in parsed[section]:
		if not _valid(d, section):
			continue
		var raw_name: String = d["Name"]
		var cls: String = d["CarClass"]
		var inc: Dictionary = notes["inc"].get(raw_name, {})
		if not out.has(cls):
			out[cls] = {}
		out[cls][resolve(raw_name)] = {
			"grid": int(d.get("ClassGridPos", "0")),
			"laps": int(d.get("Laps", "0")),
			"status": d.get("FinishStatus", ""),
			"best": float(d.get("BestLapTime", "0")),
			"time": float(d.get("FinishTime", "0")),
			"pits": int(d.get("Pitstops", "0")),
			"led": led.get(raw_name, 0),
			"inc": inc.get("veh", 0),
			"env": inc.get("env", 0),
			"pens": notes["pens"].get(raw_name, 0),
		}
	return out


# ---------- Drafts (review step before rating) ----------
# A file with no race and no qualifying result (practice or warm-up only) is never rated or
# stored: practice laps are not a reliable picture of pace, fuel or tyre use.
func has_sessions(draft: Dictionary) -> bool:
	return not draft.get("orders", {}).is_empty()


# grid_fallback: use ClassGridPos from the race file as quali when the file has no quali section
func build_draft(path: String, grid_fallback := false) -> Dictionary:
	var parsed := parse_results(path)
	var draft := {
		"file": path.get_file(),
		"path": path,
		"hash": FileAccess.get_sha256(path),
		"orders": {},   # orders[session][class] = [names]
		"stats": {},    # stats[session][class][name] = {...}
	}
	for section in SECTIONS:
		var cfg: Dictionary = SECTIONS[section]
		var o := _orders(parsed[section], section, cfg["field"])
		if not o.is_empty():
			draft["orders"][cfg["session"]] = o
			draft["stats"][cfg["session"]] = _stats(parsed, section)
	if grid_fallback and not draft["orders"].has("quali"):
		var g := _orders(parsed["Race"], "Race", "ClassGridPos")
		if not g.is_empty():
			draft["orders"]["quali"] = g
	draft["track"] = _read_track(path)
	draft["ids"] = session_ids(parsed, str(draft["track"].get("TrackCourse", "")))
	if _name_time(draft["file"]) < 0:
		draft["event_time"] = _xml_time(path)   # no date in the file name: use the session's own
	draft["fp"] = Fingerprint.extract(path)   # lap-data fingerprint, saved with the event for Profiles / Predict
	draft["duplicate_of"] = duplicate_of(draft)
	draft["duplicate"] = draft["duplicate_of"] != ""
	draft["replaces_training"] = _training_match(draft) if not draft["duplicate"] else ""
	draft["new_drivers"] = _find_suspects(draft)
	return draft


func _apply(draft: Dictionary) -> void:
	if processed.has(draft["hash"]):
		return
	if not draft.has("ids"):   # saved before session ids existed
		draft["ids"] = _ids_from_archive(str(draft["file"]))
	for id in draft["ids"]:
		sessions_seen[id] = draft["file"]
	if draft.get("kind", "league") == "training":
		processed[draft["hash"]] = draft["file"]   # remembered so it is not imported twice, but never rated
		return
	var changes := []
	var orders := _resolved_orders(draft["orders"])
	for sess in orders:
		for cls in orders[sess]:
			changes.append_array(update_session(orders[sess][cls], cls, sess))
	processed[draft["hash"]] = draft["file"]
	history.append({
		"file": draft["file"],
		"time": event_time(draft),
		"course": str(draft.get("track", {}).get("TrackCourse", "")),
		"changes": changes,
		"stats": _resolved_stats(draft.get("stats", {})),
	})


# Saved events keep the names they were rated with. Re-applying the aliases here means a merge
# made later (see merge_drivers) also merges every older result when the ratings are rebuilt.
# If both names are in the same session, the better-placed entry is kept.
func _resolved_orders(orders: Dictionary) -> Dictionary:
	var out := {}
	for sess in orders:
		out[sess] = {}
		for cls in orders[sess]:
			var names := []
			for n in orders[sess][cls]:
				var r := resolve(str(n))
				if r not in names:
					names.append(r)
			out[sess][cls] = names
	return out


func _resolved_stats(stats: Dictionary) -> Dictionary:
	var out := {}
	for sess in stats:
		out[sess] = {}
		for cls in stats[sess]:
			var by_name := {}
			for n in stats[sess][cls]:
				var r := resolve(str(n))
				if not by_name.has(r):
					by_name[r] = stats[sess][cls][n]
			out[sess][cls] = by_name
	return out


# Call after the draft has been reviewed/edited
func confirm_draft(draft: Dictionary) -> void:
	if duplicate_of(draft) != "" or not has_sessions(draft):
		return
	var training := _training_match(draft)
	if training != "":
		_drop_training(training)   # the league copy takes over; its lap data is not counted twice
	_apply(draft)
	archive_xml(draft)
	var saved := draft.duplicate(true)
	saved.erase("duplicate")
	saved.erase("duplicate_of")
	saved.erase("replaces_training")
	saved.erase("new_drivers")
	saved.erase("path")
	DirAccess.make_dir_recursive_absolute("user://events")
	var f := FileAccess.open("user://events/%s.json" % draft["file"], FileAccess.WRITE)
	f.store_string(JSON.stringify(saved))
	f.close()
	save_ratings()


# True if this (already processed) file's saved event has no stats yet
func event_lacks_stats(draft: Dictionary) -> bool:
	if not processed.has(draft["hash"]):
		return false
	var original: String = processed[draft["hash"]]
	for h in history:
		if h["file"] == original:
			return h.get("stats", {}).is_empty() or stored_xml_path(original) == "" or not _saved_has_fp(original)
	return false


# Adds the stats from a freshly parsed copy of an already processed file to its saved
# event, without rating anything again.
func attach_stats(draft: Dictionary) -> bool:
	if not processed.has(draft["hash"]):
		return false
	var original: String = processed[draft["hash"]]
	archive_xml(draft, original)
	var path := "user://events/%s.json" % original
	if not FileAccess.file_exists(path):
		return false
	var saved = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (saved is Dictionary):
		return false
	if saved.get("kind", "league") == "training":
		# training files keep no driver data: only the anonymous track / car fingerprint
		saved["fp"] = Fingerprint.extract(draft["path"], true)
		saved["track"] = draft.get("track", {})
	else:
		saved["stats"] = draft["stats"]
		saved["track"] = draft.get("track", {})
		saved["fp"] = draft.get("fp", {})
	if draft.has("event_time"):
		saved["event_time"] = draft["event_time"]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(saved))
	f.close()
	for h in history:
		if h["file"] == original:
			h["stats"] = draft["stats"]
	save_ratings()
	return true


var _time_cache := {}   # file name -> event time read from its archived XML


# When an event happened, as Unix time (local clock, like the file names): from the file name
# when it starts with a date, else from the session's own TimeString inside the XML (saved with
# the event as "event_time", or read once from the archived copy). -1 if neither is available.
func event_time(draft: Dictionary) -> int:
	var file_name := str(draft.get("file", ""))
	var t := _name_time(file_name)
	if t >= 0:
		return t
	if draft.has("event_time") and int(draft["event_time"]) >= 0:
		return int(draft["event_time"])
	if _time_cache.has(file_name):
		return _time_cache[file_name]
	var path := stored_xml_path(file_name)
	if path == "":
		path = str(draft.get("path", ""))
	t = _xml_time(path) if path != "" else -1
	_time_cache[file_name] = t
	return t


# Full events: a qualifying file and the race file of the same event (same date and track) share
# one number. Returns, for every entry of history, its full-event number (0, 1, 2...). A new full
# event starts when the date or track changes, or when the entry repeats a session the current
# event already has: a second race, or a second qualifying-only file, on the same day and track.
func full_events() -> Array:
	var out := []
	var n := -1
	var key := ""
	var sessions := {}
	for h in history:
		var t := int(h.get("time", -1))
		var date := ""
		if t >= 0:
			var d := Time.get_datetime_dict_from_unix_time(t)
			date = "%04d_%02d_%02d" % [int(d["year"]), int(d["month"]), int(d["day"])]
		var k := "%s|%s" % [date, str(h.get("course", ""))]
		var has := {}
		for c in h["changes"]:
			has[c["sess"]] = true
		# a race file (it may carry its own quali) repeats only a race; a quali-only file repeats a quali
		var repeats: bool = (has.has("race") and sessions.has("race")) \
				or (not has.has("race") and has.has("quali") and sessions.has("quali"))
		if n < 0 or date == "" or k != key or repeats:
			n += 1
			key = k
			sessions = {}
		sessions.merge(has)
		out.append(n)
	return out


# 0 for a file with only qualifying in it, 1 for one with a race: qualifying sorts first on a tie
func session_rank(draft: Dictionary) -> int:
	if draft.has("orders"):
		return 1 if draft["orders"].has("race") else 0
	return 1 if draft.get("fp", {}).has("race") else 0


# "YYYY_MM_DD" of the event (same form as the file-name dates), or "" if unknown
func event_date(draft: Dictionary) -> String:
	var t := event_time(draft)
	if t < 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(t)
	return "%04d_%02d_%02d" % [int(d["year"]), int(d["month"]), int(d["day"])]


# Start of the first session in a result XML, from <TimeString>2026/10/14 20:04:18</TimeString>
# (local time, matching the file names); falls back to <DateTime> (Unix time). -1 if missing.
func _xml_time(path: String) -> int:
	var p := XMLParser.new()
	if path == "" or p.open(path) != OK:
		return -1
	var tag := ""
	var unix := -1
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				tag = p.get_node_name()
				if tag == "Driver":
					break   # dates sit in the session headers, before the drivers
			XMLParser.NODE_TEXT:
				var txt := p.get_node_data().strip_edges()
				if tag == "TimeString":
					var m := RegEx.create_from_string("^(\\d{4})/(\\d{2})/(\\d{2}) (\\d{2}):(\\d{2}):(\\d{2})").search(txt)
					if m != null:
						return Time.get_unix_time_from_datetime_dict({
							"year": int(m.get_string(1)), "month": int(m.get_string(2)),
							"day": int(m.get_string(3)), "hour": int(m.get_string(4)),
							"minute": int(m.get_string(5)), "second": int(m.get_string(6)),
						})
				elif tag == "DateTime" and unix < 0 and txt.is_valid_int():
					unix = int(txt)
				tag = ""
			XMLParser.NODE_ELEMENT_END:
				tag = ""
	return unix


# Unix time from a file name like 2026_10_14_21_13_28-32R1.xml, or -1 if it has no date
func _name_time(file_name: String) -> int:
	var rx := RegEx.new()
	rx.compile("^(\\d{4})_(\\d{2})_(\\d{2})_(\\d{2})_(\\d{2})_(\\d{2})")
	var m := rx.search(file_name)
	if m == null:
		return -1
	return Time.get_unix_time_from_datetime_dict({
		"year": int(m.get_string(1)), "month": int(m.get_string(2)),
		"day": int(m.get_string(3)), "hour": int(m.get_string(4)),
		"minute": int(m.get_string(5)), "second": int(m.get_string(6)),
	})


# Rebuilds every rating from the saved events, oldest to newest.
# Order comes from the date in each result file's name (falls back to the time the
# event was saved). Ratings are backed up first, and nothing is touched if no events exist.
# Returns {"count": int, "first": String, "last": String, "undated": PackedStringArray}
func rebuild_all() -> Dictionary:
	var events := []   # {"time": int, "draft": Dictionary}
	var undated := PackedStringArray()
	for f in DirAccess.get_files_at("user://events"):
		if not f.ends_with(".json"):
			continue
		var path := "user://events/" + f
		var draft = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (draft is Dictionary) or not draft.has("file") or not (draft.has("orders") or draft.get("kind", "") == "training"):
			continue
		var t := event_time(draft)
		if t < 0:
			undated.append(draft["file"])
			t = FileAccess.get_modified_time(path)
		events.append({"time": t, "draft": draft})

	var summary := {"count": events.size(), "first": "", "last": "", "undated": undated}
	if events.is_empty():
		return summary

	# oldest first; on a tie (a quali file and its race file often carry the same start time)
	# qualifying comes first, then file name
	events.sort_custom(func(a, b):
		if a["time"] != b["time"]:
			return a["time"] < b["time"]
		if session_rank(a["draft"]) != session_rank(b["draft"]):
			return session_rank(a["draft"]) < session_rank(b["draft"])
		return a["draft"]["file"] < b["draft"]["file"])

	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.copy_absolute(SAVE_PATH, "user://elo.backup.json")
	ratings.clear()
	processed.clear()
	sessions_seen.clear()
	history.clear()
	for e in events:
		_apply(e["draft"])
	save_ratings()
	summary["first"] = events[0]["draft"]["file"]
	summary["last"] = events[-1]["draft"]["file"]
	return summary


# ---------- Names and aliases ----------
func resolve(driver_name: String) -> String:
	return aliases.get(driver_name, driver_name)


# Makes from_name the same driver as into (an existing driver, or a new name to rename to),
# then rebuilds every rating from the saved events so all past results are combined.
# Earlier aliases that pointed at from_name follow it. Returns rebuild_all()'s summary,
# or {"error": "..."}.
func merge_drivers(from_name: String, into: String) -> Dictionary:
	from_name = from_name.strip_edges()
	into = resolve(into.strip_edges())
	if from_name == "" or into == "":
		return {"error": "Pick two drivers."}
	if resolve(from_name) == into:
		return {"error": "%s is already %s." % [from_name, into]}
	aliases[from_name] = into
	for a in aliases.keys():
		if aliases[a] == from_name:
			aliases[a] = into
	aliases.erase(into)   # the target is never an alias of something else
	return _rebuild_keeping_aliases()


# Rebuilds the ratings; the alias table is saved even when there are no events to replay.
func _rebuild_keeping_aliases() -> Dictionary:
	var summary := rebuild_all()
	if int(summary["count"]) == 0:
		save_ratings()
	return summary


# Undoes a merge: from_name becomes its own driver again (ratings are rebuilt).
func unmerge_driver(from_name: String) -> Dictionary:
	if not aliases.has(from_name):
		return {"error": "%s is not merged into anyone." % from_name}
	aliases.erase(from_name)
	return _rebuild_keeping_aliases()


func known_names() -> Array:
	var s := {}
	for k in ratings:
		s[k.rsplit("|", true, 2)[0]] = true
	return s.keys()


func similar_to(driver_name: String, limit := 0.6) -> Array:
	var low := driver_name.to_lower()
	var out := []
	for known in known_names():
		var k: String = known.to_lower()
		if k.begins_with(low) or low.begins_with(k) or low.similarity(k) >= limit:
			out.append(known)
	return out


# New names that look like an existing driver: {name: [similar known names]}
func _find_suspects(draft: Dictionary) -> Dictionary:
	var known := known_names()
	var out := {}
	for sess in draft["orders"]:
		for cls in draft["orders"][sess]:
			for n in draft["orders"][sess][cls]:
				if n not in known and not out.has(n):
					var s := similar_to(n)
					if not s.is_empty():
						out[n] = s
	return out


func merge_driver(draft: Dictionary, driver_name: String, into: String) -> void:
	aliases[driver_name] = into
	for sess in draft["orders"]:
		for cls in draft["orders"][sess]:
			var order: Array = draft["orders"][sess][cls]
			var i := order.find(driver_name)
			if i == -1:
				continue
			if order.has(into):
				order.remove_at(i)
			else:
				order[i] = into
	# stats are keyed by name too
	for sess in draft.get("stats", {}):
		for cls in draft["stats"][sess]:
			var by_name: Dictionary = draft["stats"][sess][cls]
			if by_name.has(driver_name):
				if not by_name.has(into):
					by_name[into] = by_name[driver_name]
				by_name.erase(driver_name)
	draft["new_drivers"].erase(driver_name)


# ---------- Leaderboards ----------
# Every (class, session) pair that has ratings, e.g. [["GT3", "quali"], ["GT3", "race"]]
func boards() -> Array:
	var seen := {}
	for k in ratings:
		var parts: PackedStringArray = k.rsplit("|", true, 2)
		seen[parts[1] + "|" + parts[2]] = [parts[1], parts[2]]
	var out: Array = seen.values()
	out.sort_custom(func(a, b): return (a[0] + a[1]) < (b[0] + b[1]))
	return out


# Rows for one class/session, best rating first: [{"name", "r", "d"}]
func leaderboard(cls: String, sess: String) -> Array:
	var rows := []
	for k in ratings:
		var parts: PackedStringArray = k.rsplit("|", true, 2)
		if parts[1] == cls and parts[2] == sess:
			rows.append({"name": parts[0], "r": ratings[k]["r"], "d": ratings[k]["d"]})
	rows.sort_custom(func(a, b): return a["r"] > b["r"])
	return rows


# ---------- Excel export ----------
const _XML_HEAD := '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
const _NS_MAIN := "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
const _NS_REL := "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
const _NS_PKG := "http://schemas.openxmlformats.org/package/2006/relationships"
# style 0 = normal, style 1 = bold (used for header rows)
const _STYLES_XML := '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'


# Exports the current leaderboards: one sheet per class/session.
func export_xlsx(path: String) -> Error:
	var sheets := []
	for b in boards():
		var rows := []
		var rank := 1
		for r in leaderboard(b[0], b[1]):
			rows.append([rank, r["name"], roundi(r["r"]), int(r["d"]),
				"settling" if r["d"] < SETTLED_DUELS else ""])
			rank += 1
		sheets.append({
			"name": "%s %s" % [b[0], b[1]],
			"headers": ["Rank", "Driver", "Rating", "Duels", "Status"],
			"rows": rows,
		})
	return write_xlsx(path, sheets)


# Writes any list of sheets: [{"name": String, "headers": Array, "rows": Array of Array}].
# Cells may be ints, floats or strings. An .xlsx is a zip of XML files, so no plugin is
# needed. Returns an Error code.
func write_xlsx(path: String, sheets: Array) -> Error:
	if sheets.is_empty():
		return ERR_UNAVAILABLE

	var parts := {"[Content_Types].xml": ""}   # filled in below, but kept first in the zip
	var types := _XML_HEAD + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
	types += '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
	types += '<Default Extension="xml" ContentType="application/xml"/>'
	types += '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
	types += '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
	var book := _XML_HEAD + '<workbook xmlns="%s" xmlns:r="%s"><sheets>' % [_NS_MAIN, _NS_REL]
	var book_rels := _XML_HEAD + '<Relationships xmlns="%s">' % _NS_PKG

	var used_names := []
	for i in sheets.size():
		var n := i + 1
		var sheet_name := _unique_sheet_name(str(sheets[i]["name"]), used_names)
		used_names.append(sheet_name)
		types += '<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' % n
		book += '<sheet name="%s" sheetId="%d" r:id="rId%d"/>' % [sheet_name.xml_escape(true), n, n]
		book_rels += '<Relationship Id="rId%d" Type="%s/worksheet" Target="worksheets/sheet%d.xml"/>' % [n, _NS_REL, n]
		parts["xl/worksheets/sheet%d.xml" % n] = _sheet_xml(sheets[i])
	types += "</Types>"
	book += "</sheets></workbook>"
	book_rels += '<Relationship Id="rId%d" Type="%s/styles" Target="styles.xml"/></Relationships>' % [sheets.size() + 1, _NS_REL]

	parts["[Content_Types].xml"] = types
	parts["_rels/.rels"] = _XML_HEAD + '<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/></Relationships>' % [_NS_PKG, _NS_REL]
	parts["xl/workbook.xml"] = book
	parts["xl/_rels/workbook.xml.rels"] = book_rels
	parts["xl/styles.xml"] = _STYLES_XML

	var zip := ZIPPacker.new()
	var err := zip.open(path)
	if err != OK:
		return err
	for entry_name in parts:
		zip.start_file(entry_name)
		zip.write_file(parts[entry_name].to_utf8_buffer())
		zip.close_file()
	zip.close()
	return OK


# Excel sheet names: max 31 chars, none of [ ] : * ? / \, and unique
func _unique_sheet_name(wanted: String, used: Array) -> String:
	var s := wanted
	for ch in ["[", "]", ":", "*", "?", "/", "\\"]:
		s = s.replace(ch, "-")
	s = s.left(31)
	if s == "":
		s = "Sheet"
	var candidate := s
	var count := 2
	while candidate in used:
		var suffix := " %d" % count
		candidate = s.left(31 - suffix.length()) + suffix
		count += 1
	return candidate


func _col(i: int) -> String:
	return char(65 + i)   # A..Z (up to 26 columns)


func _cell(ref: String, v, style := 0) -> String:
	match typeof(v):
		TYPE_INT:
			return '<c r="%s" s="%d"><v>%d</v></c>' % [ref, style, v]
		TYPE_FLOAT:
			return '<c r="%s" s="%d"><v>%s</v></c>' % [ref, style, str(snappedf(v, 0.001))]
		_:
			return '<c r="%s" t="inlineStr" s="%d"><is><t>%s</t></is></c>' % [ref, style, str(v).xml_escape()]


func _sheet_xml(sheet: Dictionary) -> String:
	var headers: Array = sheet["headers"]
	var rows: Array = sheet["rows"]
	var widths := []
	for h in headers:
		widths.append(str(h).length() + 2)
	for row in rows:
		for i in mini(row.size(), widths.size()):
			widths[i] = maxi(widths[i], str(row[i]).length() + 2)

	var x := _XML_HEAD + '<worksheet xmlns="%s">' % _NS_MAIN
	x += '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
	x += "<cols>"
	for i in widths.size():
		x += '<col min="%d" max="%d" width="%d" customWidth="1"/>' % [i + 1, i + 1, clampi(widths[i], 6, 45)]
	x += "</cols>"
	x += '<sheetData><row r="1">'
	for i in headers.size():
		x += _cell("%s1" % _col(i), str(headers[i]), 1)
	x += "</row>"
	var r := 2
	for row in rows:
		x += '<row r="%d">' % r
		for i in row.size():
			x += _cell("%s%d" % [_col(i), r], row[i])
		x += "</row>"
		r += 1
	return x + "</sheetData></worksheet>"


# ---------- Persistence ----------
# Written to a temporary file first and then swapped in, so a crash or power cut in the middle
# of saving cannot leave a half-written elo.json behind.
func save_ratings() -> void:
	revision += 1
	var tmp := SAVE_PATH + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Could not save ratings (error %d)" % FileAccess.get_open_error())
		return
	f.store_string(JSON.stringify({
		"ratings": ratings,
		"processed": processed,
		"sessions_seen": sessions_seen,
		"aliases": aliases,
		"history": history,
		"model": RATING_MODEL,
	}))
	f.close()
	if DirAccess.rename_absolute(tmp, SAVE_PATH) != OK:
		# some systems refuse to rename over an existing file: remove it, then rename
		DirAccess.remove_absolute(SAVE_PATH)
		DirAccess.rename_absolute(tmp, SAVE_PATH)


# If elo.json cannot be read, it is kept aside as elo.unreadable-<time>.json (never overwritten
# by the next save) and the backup from the last Recompute all is used instead, if there is one.
func load_ratings() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if not data is Dictionary:
		var keep := "user://elo.unreadable-%s.json" % Time.get_datetime_string_from_system().replace(":", "-")
		DirAccess.copy_absolute(SAVE_PATH, keep)
		load_error = "Your ratings file could not be read; a copy was kept as %s." % keep.get_file()
		if FileAccess.file_exists("user://elo.backup.json"):
			data = JSON.parse_string(FileAccess.get_file_as_string("user://elo.backup.json"))
			if data is Dictionary:
				load_error += " The backup from the last Recompute all was loaded instead; press Recompute all to bring it up to date."
	if data is Dictionary:
		ratings = data.get("ratings", {})
		processed = data.get("processed", {})
		sessions_seen = data.get("sessions_seen", {})
		_needs_backfill = not data.has("sessions_seen") and not processed.is_empty()
		aliases = data.get("aliases", {})
		history = data.get("history", [])
		_model_loaded = int(data.get("model", 1))
	revision += 1

# ---------- XML archive ----------
# Every confirmed result file is copied here so it can be re-read later (new stats, tracks, etc.).
const XML_DIR := "user://xml"

# Copies the original XML into user://xml/<file name>. Returns true if the copy exists afterwards.
func archive_xml(draft: Dictionary, as_name := "") -> bool:
	var src: String = draft.get("path", "")
	if src == "" or not FileAccess.file_exists(src):
		return false
	var dst := "%s/%s" % [XML_DIR, as_name if as_name != "" else draft["file"]]
	if FileAccess.file_exists(dst):
		return true
	DirAccess.make_dir_recursive_absolute(XML_DIR)
	return DirAccess.copy_absolute(src, dst) == OK

# Path of the archived copy of a result file, or "" if it was never archived.
func stored_xml_path(file_name: String) -> String:
	var p := "%s/%s" % [XML_DIR, file_name]
	return p if FileAccess.file_exists(p) else ""

# Re-reads every archived XML and refreshes stats + track info of the saved events.
# Nothing is rated again. Returns how many events were updated.
func refresh_from_archive() -> int:
	var n := 0
	for f in DirAccess.get_files_at(XML_DIR):
		if f.ends_with(".xml") and attach_stats(build_draft("%s/%s" % [XML_DIR, f])):
			n += 1
	return n

# Track header fields from a result file: {"TrackVenue", "TrackCourse", "TrackLength", "RaceTime"}.
func _read_track(path: String) -> Dictionary:
	var out := {}
	var p := XMLParser.new()
	if p.open(path) != OK:
		return out
	var wanted := ["TrackVenue", "TrackCourse", "TrackLength", "RaceTime"]
	var tag := ""
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				var n := p.get_node_name()
				if n == "Race" or n == "Qualify" or n.begins_with("Practice") or n == "Warmup":
					break # header is over
				tag = n if n in wanted else ""
			XMLParser.NODE_TEXT:
				if tag != "":
					out[tag] = p.get_node_data().strip_edges()
					tag = ""
			XMLParser.NODE_ELEMENT_END:
				tag = ""
	return out


# True if the saved event file already holds a lap-data fingerprint.
func _saved_has_fp(file_name: String) -> bool:
	var path := "user://events/%s.json" % file_name
	if not FileAccess.file_exists(path):
		return false
	var saved = JSON.parse_string(FileAccess.get_file_as_string(path))
	return saved is Dictionary and saved.has("fp") and not saved["fp"].is_empty()


# Expands dropped files / folders into a flat list of .xml paths (folders are searched recursively).
func collect_xml(paths: PackedStringArray) -> Array:
	return collect_files(paths, ".xml")


# Same for any extension (".csv" for MoTeC exports).
func collect_files(paths: PackedStringArray, extension: String) -> Array:
	var out := []
	for p in paths:
		if DirAccess.dir_exists_absolute(p):
			for f in DirAccess.get_files_at(p):
				if f.to_lower().ends_with(extension):
					out.append(p.path_join(f))
			for sub in DirAccess.get_directories_at(p):
				out.append_array(collect_files(PackedStringArray([p.path_join(sub)]), extension))
		elif p.to_lower().ends_with(extension):
			out.append(p)
	return out


# Stores a TRAINING file: track and car-model data only. Nothing is rated, no driver names are
# kept (the fingerprint is anonymous) and it does not count as a league event.
# Returns "added", "duplicate" or "no data".
func import_training(path: String) -> String:
	var file_hash := FileAccess.get_sha256(path)
	if processed.has(file_hash):
		return "duplicate"
	var parsed := parse_results(path)
	if parsed["Race"].is_empty() and parsed["Qualify"].is_empty():
		return "practice only"
	var track := _read_track(path)
	var ids := session_ids(parsed, str(track.get("TrackCourse", "")))
	if duplicate_of({"hash": file_hash, "ids": ids}) != "":
		return "duplicate"   # same event already imported under another file name
	var fp := Fingerprint.extract(path, true)
	if not fp.has("race") and not fp.has("quali"):
		return "no data"
	var draft := {
		"file": path.get_file(), "path": path, "hash": file_hash,
		"kind": "training", "track": track, "fp": fp, "ids": ids,
	}
	archive_xml(draft)
	processed[file_hash] = draft["file"]
	for id in ids:
		sessions_seen[id] = draft["file"]
	var saved := draft.duplicate(true)
	saved.erase("path")
	DirAccess.make_dir_recursive_absolute("user://events")
	var f := FileAccess.open("user://events/%s.json" % draft["file"], FileAccess.WRITE)
	f.store_string(JSON.stringify(saved))
	f.close()
	save_ratings()
	return "added"


# ---------- Same event, different file ----------
# One id per session (quali, race) from what every player's log of that session agrees on: track,
# session, and each driver's name, class, class position, laps and best lap. Clock times, finish
# times (they drift by a few milliseconds between logs) and incident timings are left out.
func session_ids(parsed: Dictionary, course: String) -> Array:
	var out := []
	for section in ["Qualify", "Race"]:
		var rows := PackedStringArray()
		for d in parsed[section]:
			if _valid(d, section):
				rows.append("%s|%s|%s|%d|%.3f" % [d["Name"], d["CarClass"], d["ClassPosition"],
					int(d.get("Laps", "0")), float(d.get("BestLapTime", "0"))])
		if rows.is_empty():
			continue
		rows.sort()
		out.append(("%s|%s|%s" % [course, section, ";".join(rows)]).sha256_text().left(20))
	return out


# The file this one repeats ("" if it is new): the same bytes, or every session already seen.
# A league file is only blocked by a league event; one that repeats a training import replaces it.
func duplicate_of(draft: Dictionary) -> String:
	var earlier := _earlier_copy(draft)
	if earlier == "":
		return ""
	if draft.get("kind", "league") == "training" or _is_rated(earlier):
		return earlier
	return ""


# The training import this league file repeats, or "".
func _training_match(draft: Dictionary) -> String:
	var earlier := _earlier_copy(draft)
	return earlier if earlier != "" and not _is_rated(earlier) else ""


func _earlier_copy(draft: Dictionary) -> String:
	if processed.has(draft.get("hash", "")):
		return str(processed[draft["hash"]])
	var ids: Array = draft.get("ids", [])
	if ids.is_empty():
		return ""
	for id in ids:
		if not sessions_seen.has(id):
			return ""
	return str(sessions_seen[ids[0]])


func _is_rated(file_name: String) -> bool:
	for h in history:
		if h["file"] == file_name:
			return true
	return false


# Removes a training import (its saved event and ids). Its archived XML stays.
func _drop_training(file_name: String) -> void:
	DirAccess.remove_absolute("user://events/%s.json" % file_name)
	for id in sessions_seen.keys():
		if sessions_seen[id] == file_name:
			sessions_seen.erase(id)
	for h in processed.keys():
		if processed[h] == file_name:
			processed.erase(h)


func _ids_from_archive(file_name: String) -> Array:
	var path := stored_xml_path(file_name)
	if path == "":
		return []
	return session_ids(parse_results(path), str(_read_track(path).get("TrackCourse", "")))


# Once, for data saved before session ids existed: works out the ids of every saved event from
# its archived XML, and removes training imports that repeat a league event or an earlier
# training import (they were counting the same laps twice).
var backfill_removed := PackedStringArray()

func _backfill_sessions() -> void:
	if not DirAccess.dir_exists_absolute("user://events"):
		return
	var training := []
	for f in DirAccess.get_files_at("user://events"):
		if not f.ends_with(".json"):
			continue
		var path := "user://events/" + f
		var ev = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not ev is Dictionary or not ev.has("file"):
			continue
		if not ev.has("ids"):
			ev["ids"] = _ids_from_archive(str(ev["file"]))
			var w := FileAccess.open(path, FileAccess.WRITE)
			if w != null:
				w.store_string(JSON.stringify(ev))
				w.close()
		if ev.get("kind", "league") == "training":
			training.append(ev)
		else:
			for id in ev["ids"]:
				sessions_seen[id] = ev["file"]
	training.sort_custom(func(a, b): return str(a["file"]) < str(b["file"]))
	for ev in training:
		var ids: Array = ev["ids"]
		if not ids.is_empty() and ids.all(func(id): return sessions_seen.has(id)):
			_drop_training(str(ev["file"]))
			backfill_removed.append(str(ev["file"]))
			continue
		for id in ids:
			sessions_seen[id] = ev["file"]
	save_ratings()
	if not backfill_removed.is_empty():
		load_error = ("" if load_error == "" else load_error + " ") + \
			"%d training file(s) repeated an event that was already imported and were removed: %s." % [
				backfill_removed.size(), ", ".join(backfill_removed)]
