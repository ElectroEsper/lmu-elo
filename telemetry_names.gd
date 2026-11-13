class_name TelemetryNames
extends RefCounted
## Track and class of a telemetry file from its name, so many files can be imported at once:
##   - class tags (Settings > Telemetry file names): bits of a file name that mean a class
##     ("GT3", "HY", "P3"...);
##   - track codes: bits that mean a track ("BRN" = Brno). Set in Settings, and learned: every
##     telemetry file imported teaches the app the bits of its name with the track it was given.
##     A bit seen with two different tracks (a driver name, a setup name) means nothing.
## The telemetry window still shows every guess before importing.

const LEARNED_FILE := "telemetry_names.json"


# The bits of a file name: split on _ - . spaces and brackets, upper case, without numbers and
# dates (they say nothing about the track).
static func tokens(file_name: String) -> PackedStringArray:
	var base := file_name.get_file().get_basename()
	for sep in ["-", ".", " ", "(", ")", "[", "]"]:
		base = base.replace(sep, "_")
	var out := PackedStringArray()
	for t in base.split("_", false):
		var u := t.strip_edges().to_upper()
		if u.length() < 2 or u.is_valid_int() or u.is_valid_float():
			continue
		if not out.has(u):
			out.append(u)
	return out


# {class: [tags]} from the settings, each class's own name included.
static func class_tags() -> Dictionary:
	var out := {}
	var tags: Dictionary = LeagueSettings.get_value("telemetry_class_tags")
	for c in tags:
		var list := PackedStringArray([str(c).to_upper()])
		for t in tags[c]:
			if str(t).strip_edges() != "" and not list.has(str(t).strip_edges().to_upper()):
				list.append(str(t).strip_edges().to_upper())
		out[str(c)] = list
	return out


static func guess_class(file_name: String, classes: Array) -> String:
	# a class's own name in the file name, longest first ("LMP2_ELMS" before "LMP2")
	var base := file_name.get_basename().to_upper()
	var by_len := classes.duplicate()
	by_len.sort_custom(func(x, y): return str(x).length() > str(y).length())
	for c in by_len:
		if str(c).length() >= 3 and base.contains(str(c).to_upper()):
			return str(c)
	# then the class tags set in Settings, as whole bits of the name
	var toks := tokens(file_name)
	var tags := class_tags()
	for c in by_len:
		for t in tags.get(str(c), PackedStringArray()):
			if toks.has(t):
				return str(c)
	return ""


static func _is_class_tag(tok: String) -> bool:
	for list in class_tags().values():
		if (list as PackedStringArray).has(tok):
			return true
	return false


# Track codes set in Settings: {CODE: course}.
static func codes() -> Dictionary:
	var out := {}
	var c: Dictionary = LeagueSettings.get_value("telemetry_track_codes")
	for k in c:
		out[str(k).strip_edges().to_upper()] = str(c[k])
	return out


static func _load_learned() -> Dictionary:
	var path := AppPaths.file(LEARNED_FILE)
	if not FileAccess.file_exists(path):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d.get("tokens", {}) if d is Dictionary else {}


# Learned codes that point at one track only: {CODE: course}.
static func learned() -> Dictionary:
	var out := {}
	var seen := _load_learned()
	for tok in seen:
		var courses: Dictionary = seen[tok]
		if courses.size() == 1 and not _is_class_tag(str(tok)):
			out[str(tok)] = str(courses.keys()[0])
	return out


# Remembers the bits of an imported file's name with the track it was given.
static func learn(file_name: String, course: String) -> void:
	if course == "":
		return
	var seen := _load_learned()
	for tok in tokens(file_name):
		if _is_class_tag(tok):
			continue
		if not seen.has(tok):
			seen[tok] = {}
		seen[tok][course] = int(seen[tok].get(course, 0)) + 1
	var f := FileAccess.open(AppPaths.file(LEARNED_FILE), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"tokens": seen}))
		f.close()


static func forget_learned() -> void:
	DirAccess.remove_absolute(AppPaths.file(LEARNED_FILE))


# The track a file name points at ("" when it does not say): a code from Settings, else a learned
# code (the one seen most often if two disagree; a tie says nothing), else a track's name in it.
static func guess_track(file_name: String, courses: Array) -> String:
	var toks := tokens(file_name)
	var set_codes := codes()
	for t in toks:
		if set_codes.has(t) and courses.has(set_codes[t]):
			return set_codes[t]
	var seen := _load_learned()
	var votes := {}
	for t in toks:
		if seen.has(t) and (seen[t] as Dictionary).size() == 1 and not _is_class_tag(t):
			var c := str(seen[t].keys()[0])
			if courses.has(c):
				votes[c] = int(votes.get(c, 0)) + int(seen[t][c])
	if not votes.is_empty():
		var ranked := votes.keys()
		ranked.sort_custom(func(a, b): return int(votes[a]) > int(votes[b]))
		if ranked.size() == 1 or int(votes[ranked[0]]) > int(votes[ranked[1]]):
			return str(ranked[0])
	var base := _norm(file_name.get_basename())
	for c in courses:   # the track's name, or its short name, inside the file name ("Brno", "Road_Atlanta")
		for nm in [str(c), SeasonStory.short(str(c))]:
			if _norm(nm).length() >= 3 and base.contains(_norm(nm)):
				return str(c)
	return ""


static func _norm(s: String) -> String:
	return s.replace("_", " ").replace("-", " ").strip_edges().to_lower()
