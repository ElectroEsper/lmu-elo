class_name SuccessBallast
extends RefCounted
## Success ballast (league rules): each race finish adds or takes off weight for the next race.
##   - kg per class finish (P1, P2, ... the last entry = that place or lower): Settings > Success
##     ballast, by class (GT3 +15/+10/+5/0/-5/-10/-15, Hyper and LMP3 +10/+5/+2/0/-2/-5/-10);
##   - never below 0 kg, and never above the class's cap (GT3 45 kg, Hyper and LMP3 30 kg; 0 = no
##     cap): the result files show it (season 5: a GT3 at 45 kg and a Hypercar at 30 kg where the
##     table adds up to more);
##   - the class finish after the Penalties page; a DNF counts as the last line ("P7 or lower");
##     a disqualification, a no-start or a missed race changes nothing (0-lap starters never reach
##     the results, so they are left out too);
##   - one ballast per driver, season and series (Sprint and Enduro separate, both start each
##     season at 0). It follows the driver when they change class within the series (the result
##     files show it: s6 Sprint R4, a GT3 driver's 5 kg carried into LMP3), the table being the
##     class they raced that round.
## The result files record the ballast each car carried (<PenaltyMass>); season 6 replays to it
## exactly once the penalties are applied.

static var _cache := {}
static var _cache_key := ""


## Kg change for a class finish. `status` is the result file's finish status.
static func delta(cls: String, pos: int, status: String) -> int:
	var table := table_for(cls)
	if table.is_empty() or pos <= 0:
		return 0
	var st := status.to_upper()
	if st.begins_with("DQ") or st.contains("DISQ"):
		return 0
	var i := table.size() - 1 if st == "DNF" else mini(pos, table.size()) - 1
	return int(table[i])


## The kg table for a class (empty when the class has no ballast).
static func table_for(cls: String) -> Array:
	return _for_class(LeagueSettings.get_value("ballast"), cls, [])


## Most a car of the class carries (0 = no cap).
static func cap(cls: String) -> int:
	return int(_for_class(LeagueSettings.get_value("ballast_caps"), cls, 0))


static func _for_class(by_class: Dictionary, cls: String, none: Variant) -> Variant:
	if by_class.has(cls):
		return by_class[cls]
	for k in by_class:   # "GT3" also covers e.g. "LMGT3"
		if str(k) != "" and cls.to_upper().contains(str(k).to_upper()):
			return by_class[k]
	return none


static func _clamp(kg: int, cls: String) -> int:
	kg = maxi(kg, 0)
	return mini(kg, cap(cls)) if cap(cls) > 0 else kg


## Every driver's ballast through a season of one series (the series name, as Reports uses it):
## {driver: {"kg": kg for the next race, "rounds": [{"round", "cls", "pos", "status", "before",
## "delta", "after"}]}}, plus "_rounds": races run. Cached until ratings or settings change.
static func season(season_name: String, series: String) -> Dictionary:
	var key := "%d|%d" % [Elo.revision, LeagueSettings.revision]
	if key != _cache_key:
		_cache.clear()
		_cache_key = key
	var ck := season_name + "|" + series
	if _cache.has(ck):
		return _cache[ck]
	var out := {}
	var rnd := 0
	for ev in Elo.history:
		if Elo.season_of(ev) != season_name or Elo.series_of(ev) != series:
			continue
		var race := (ev["changes"] as Array).filter(func(c): return c["sess"] == "race")
		if race.is_empty():
			continue
		rnd += 1
		var stats: Dictionary = ev.get("stats", {}).get("race", {})
		for c in race:
			var d: String = c["driver"]
			var status := str(stats.get(c["cls"], {}).get(d, {}).get("status", ""))
			if not out.has(d):
				out[d] = {"kg": 0, "rounds": []}
			var before: int = out[d]["kg"]
			var after := _clamp(before + delta(str(c["cls"]), int(c["pos"]), status), str(c["cls"]))
			out[d]["kg"] = after
			out[d]["rounds"].append({"round": rnd, "cls": c["cls"], "pos": int(c["pos"]), "status": status,
				"before": before, "delta": after - before, "after": after})
	out["_rounds"] = rnd
	_cache[ck] = out
	return out


## Ballast each driver carries into the next race of a series, in the latest season it raced
## ({driver: kg}; drivers with no race this season are not in it: they carry 0).
static func current(series: String) -> Dictionary:
	var latest := ""
	for ev in Elo.history:
		if Elo.series_of(ev) == series:
			latest = Elo.season_of(ev)
	if latest == "":
		return {}
	var s := season(latest, series)
	var code := LeagueSettings.series_code(series)
	if code != "" and int(s["_rounds"]) >= LeagueSettings.season_rounds(code):
		return {}   # season complete: the next race opens a new season, everyone at 0
	var out := {}
	for d in s:
		if d != "_rounds":
			out[d] = int(s[d]["kg"])
	return out
