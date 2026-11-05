class_name LapRecords
extends RefCounted
## League lap records per track (layout) and class, from the best laps in the league's own result
## files (qualifying and race). Two records are kept:
##   "lap":  the fastest lap in any session (usually set in qualifying);
##   "race": the fastest lap in a race.
## Each holds {"time", "driver", "file", "session", "season", "series", "date"} plus "history":
## every time the record was lowered, oldest first. Disqualified drivers' laps never count, and a
## lap more than SANE below the class's median best of that session is left out (a timing glitch
## or a cut that the game did not catch).

const SANE := 0.08   # 8% quicker than the session's median best lap: not a real lap

static var _cache := {}
static var _cache_rev := -1


## {course: {cls: {"lap": record, "race": record}}}. Cached until the results change.
static func all() -> Dictionary:
	if _cache_rev == Elo.revision:
		return _cache
	_cache_rev = Elo.revision
	_cache = {}
	for ev in Elo.history:
		var course := str(ev.get("course", ""))
		if course == "":
			continue
		var stats: Dictionary = ev.get("stats", {})
		for sess in ["quali", "race"]:
			var by_cls: Dictionary = stats.get(sess, {})
			for cls in by_cls:
				var bests := []
				for d in by_cls[cls]:
					var b := float(by_cls[cls][d].get("best", 0.0))
					if b > 0.0:
						bests.append(b)
				if bests.is_empty():
					continue
				bests.sort()
				var floor_t: float = bests[bests.size() / 2] * (1.0 - SANE)
				# this session's quickest valid lap
				var top := {}
				for d in by_cls[cls]:
					var s: Dictionary = by_cls[cls][d]
					var b := float(s.get("best", 0.0))
					if b <= 0.0 or b < floor_t or str(s.get("status", "")).to_upper().begins_with("DQ"):
						continue
					if top.is_empty() or b < float(top["time"]):
						top = {"time": b, "driver": d}
				if top.is_empty():
					continue
				top.merge({"file": str(ev["file"]), "session": sess, "season": Elo.season_of(ev), "series": Elo.series_of(ev),
					"date": Time.get_date_string_from_unix_time(int(ev.get("time", 0))) if int(ev.get("time", 0)) > 0 else ""})
				if not _cache.has(course):
					_cache[course] = {}
				if not _cache[course].has(cls):
					_cache[course][cls] = {}
				for kind in (["lap", "race"] if sess == "race" else ["lap"]):
					var cur: Dictionary = _cache[course][cls].get(kind, {})
					if cur.is_empty() or float(top["time"]) < float(cur["time"]):
						var rec := top.duplicate()
						rec["history"] = (cur.get("history", []) as Array).duplicate()
						rec["history"].append(top.duplicate())
						_cache[course][cls][kind] = rec
	return _cache


## The records of one track and class: {"lap": record, "race": record} (either may be missing).
static func for_track(course: String, cls: String) -> Dictionary:
	return all().get(course, {}).get(cls, {})


## Records set at a race weekend: the race file and its qualifying ("s6-mc4-r.xml" and
## "s6-mc4.xml"), for one class. [{"kind": "lap"/"race", "record": entry, "before": the record it
## beat ({} = the first one at this track)}], the outright lap record first.
static func set_at(race_file: String, course: String, cls: String) -> Array:
	var weekend := [race_file]
	if race_file.ends_with("-r.xml"):
		weekend.append(race_file.replace("-r.xml", ".xml"))
	var out := []
	var rec := for_track(course, cls)
	for kind in ["lap", "race"]:
		var hist: Array = rec.get(kind, {}).get("history", [])
		for i in range(hist.size() - 1, -1, -1):   # the lowest this weekend reached
			if str(hist[i]["file"]) in weekend:
				var j := i - 1
				while j >= 0 and str(hist[j]["file"]) in weekend:
					j -= 1
				out.append({"kind": kind, "record": hist[i], "before": hist[j] if j >= 0 else {}})
				break
	return out


static func lap_text(t: float) -> String:
	var m := int(t / 60.0)
	return "%d:%06.3f" % [m, t - m * 60.0]
