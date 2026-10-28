class_name TrackStore
extends RefCounted
## Saved track profiles, one per course and class.

const DIR := "user://tracks"


static func _safe(s: String) -> String:
	return s.validate_filename().replace(" ", "_")


static func path_for(course: String, cls: String) -> String:
	return "%s/%s__%s.json" % [DIR, _safe(course), _safe(cls)]


# Saves a profile unless a faster lap for the same course and class is already stored.
# Returns "saved", "replaced" or "kept" (the stored lap was faster).
static func save(profile: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := path_for(profile["course"], profile["class"])
	var verdict := "saved"
	if FileAccess.file_exists(path):
		var old = JSON.parse_string(FileAccess.get_file_as_string(path))
		# a profile from an older version of the analysis is always rebuilt
		if old is Dictionary and old.has("lap") and int(old.get("version", 1)) >= MotecProfile.VERSION \
				and float(old["lap"]["time_s"]) <= float(profile["lap"]["time_s"]):
			return "kept"
		verdict = "replaced"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(profile))
	f.close()
	return verdict


# All stored profiles, sorted by course and class
static func list() -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(DIR):
		return out
	for f in DirAccess.get_files_at(DIR):
		if not f.ends_with(".json"):
			continue
		var p = JSON.parse_string(FileAccess.get_file_as_string(DIR + "/" + f))
		if p is Dictionary and p.has("map") and p.has("course"):
			out.append(p)
	out.sort_custom(func(a, b): return (str(a["course"]) + str(a["class"])) < (str(b["course"]) + str(b["class"])))
	return out
