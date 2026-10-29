class_name Ranks
extends RefCounted
## Driver ranks (Bronze, Silver, Gold, Platinum... names and limits in LeagueSettings), one per
## class. Worked out by replaying the rated events in order, so the anti-flicker rule holds:
## a driver moves UP as soon as their rating reaches a rank's minimum, but only moves DOWN once
## they are "rank_buffer" points below the minimum of the rank they hold.
## The rating used is the average of race and quali rating (or one of them, see "rank_basis");
## a driver is unranked until they have fought "rank_settle_duels" duels in that class.
## A driver who has not raced in a class for "rank_inactive_days" (counted back from the league's
## latest event, so an old archive behaves the same) keeps their rank but is shown as inactive.

static var _cache := {}   # "stamp" -> String, "data" -> {cls: {driver: entry}}


# {cls: {driver: {"tier": index into LeagueSettings.ranks() or -1, "rating": float,
#   "duels": int, "since": event file where the current rank was reached}}}
static func all() -> Dictionary:
	var stamp := "%d|%d" % [Elo.revision, LeagueSettings.revision]
	if _cache.get("stamp", "") == stamp:
		return _cache["data"]
	var tiers := LeagueSettings.ranks()
	var basis := str(LeagueSettings.get_value("rank_basis"))
	var settle := int(LeagueSettings.get_value("rank_settle_duels"))
	var buffer := float(LeagueSettings.get_value("rank_buffer"))
	var cur := {}    # "cls|driver" -> {"race", "quali", "duels", "tier", "since"}
	for ev in Elo.history:
		var touched := {}
		for c in ev["changes"]:
			var key := "%s|%s" % [c["cls"], Elo.resolve(c["driver"])]
			var e: Dictionary = cur.get(key, {"race": Elo.START, "quali": Elo.START, "duels": 0, "tier": -1, "since": "", "last": 0})
			e["last"] = maxi(int(e["last"]), int(ev.get("time", 0)))
			e[c["sess"]] = float(c["after"])
			e["duels"] += maxi(int(c.get("of", 1)) - 1, 0)
			cur[key] = e
			touched[key] = true
		for key in touched:
			var e: Dictionary = cur[key]
			if e["duels"] < settle or tiers.is_empty():
				continue
			var r := _basis(e, basis)
			var target := _tier_for(r, tiers)
			var tier: int = e["tier"]
			if tier < 0 or target > tier:
				tier = target                                  # first rank, or a promotion
			elif target < tier and r < tiers[tier]["min"] - buffer:
				tier = target                                  # clearly below: demotion
			if tier != e["tier"]:
				e["tier"] = tier
				e["since"] = str(ev["file"])
	var latest := 0
	for ev in Elo.history:
		latest = maxi(latest, int(ev.get("time", 0)))
	var idle_days := int(LeagueSettings.get_value("rank_inactive_days"))
	var out := {}
	for key in cur:
		var parts: PackedStringArray = key.split("|", true, 1)
		if not out.has(parts[0]):
			out[parts[0]] = {}
		var e: Dictionary = cur[key]
		var idle := (latest - int(e["last"])) / 86400.0
		out[parts[0]][parts[1]] = {"tier": e["tier"], "rating": _basis(e, basis), "duels": e["duels"], "since": e["since"],
			"last": e["last"], "inactive": idle_days > 0 and int(e["last"]) > 0 and idle > idle_days}
	_cache = {"stamp": stamp, "data": out}
	return out


# One driver's rank in a class: {"name", "color", "tier", "rating", "duels", "since"}
static func of(driver_name: String, cls: String) -> Dictionary:
	var e: Dictionary = all().get(cls, {}).get(driver_name, {"tier": -1, "rating": float(Elo.START), "duels": 0, "since": "", "last": 0, "inactive": false})
	var tiers := LeagueSettings.ranks()
	var out := e.duplicate()
	if e["tier"] >= 0 and e["tier"] < tiers.size():
		out["name"] = tiers[e["tier"]]["name"]
		out["color"] = tiers[e["tier"]]["color"]
	else:
		out["name"] = str(LeagueSettings.get_value("unranked_name"))
		out["color"] = UiTheme.MUTED
	# At risk: holding a rank while the rating is already below its minimum (kept by the drop-down
	# buffer). Explains why someone can rate lower than a driver of the rank below.
	out["at_risk"] = e["tier"] >= 0 and e["tier"] < tiers.size() and float(e["rating"]) < float(tiers[e["tier"]]["min"])
	out["below_by"] = float(tiers[e["tier"]]["min"]) - float(e["rating"]) if out["at_risk"] else 0.0
	# "label" is what screens show: the rank name, plus "(at risk)" / "(inactive)", dimmed if idle
	out["label"] = out["name"]
	var tags := PackedStringArray()
	if out["at_risk"]:
		tags.append("at risk")
	if e["inactive"]:
		tags.append("inactive")
	if not tags.is_empty():
		out["label"] += " (%s)" % ", ".join(tags)
	if e["inactive"]:
		var col: Color = out["color"]
		out["color"] = Color(col, 0.5)
	return out


static func _basis(e: Dictionary, basis: String) -> float:
	match basis:
		"race":
			return e["race"]
		"quali":
			return e["quali"]
	return (e["race"] + e["quali"]) / 2.0


static func _tier_for(r: float, tiers: Array) -> int:
	var t := 0
	for i in tiers.size():
		if r >= tiers[i]["min"]:
			t = i
	return t
