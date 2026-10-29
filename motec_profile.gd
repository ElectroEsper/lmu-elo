class_name MotecProfile
extends RefCounted
## Builds a track profile from a MoTeC CSV export (distance-based, one or more laps).
## No GPS is needed: the circuit shape is rebuilt from lateral G and speed, and the lap is
## split into corners, braking zones and straights. The fastest complete lap in the file is used.
## Useful channels: Distance, Ground Speed, Throttle Pos, Brake Pos, G Force Lat (required);
## G Force Long, Gear, Engine RPM, Lap Number, Fuel Level, Tyre Wear / Pressure / Temp,
## Brake Temp, Eng Water Temp, Ambient / Track Temperature (optional).

const CORNER_G := 0.5          # lateral G that counts as "in a corner"
const CORNER_MIN_LEN := 15     # metres
const CORNER_GAP := 15         # metres below CORNER_G that still belong to the same corner
const CORNER_MIN_ANGLE := 8.0  # degrees turned; smaller kinks are ignored
const BRAKE_ON := 5.0          # % brake that counts as braking
const BRAKE_GAP := 15
const BRAKE_MIN_LEN := 15
const STRAIGHT_THROTTLE := 95.0
const STRAIGHT_G := 0.35
const STRAIGHT_GAP := 40
const STRAIGHT_MIN := 200
const FLAT_WINDOW := 30   # metres either side of the apex that must stay at full throttle
const FLAT_MIN_RATIO := 0.53   # ... and the apex must be at least this share of the lap's top speed
const HS_SPEED := 0.6     # high-speed cornering: above 60% of the lap's top speed ...
const HS_G := 1.0         # ... with at least 1 G of lateral load
const FLIP_GAP := 150     # left-right (or right-left) within this many metres = direction change
const BUMP_WINDOW := 15   # metres: slower vertical motion (downforce squat, roll) is not a bump
const KERB_G := 0.8        # lateral G above which ride-height differences count as kerb strikes
const ROUGH_MIN_G := 0.15   # a rough spot shakes at least this much (vertical G, RMS) ...
const ROUGH_FACTOR := 1.5   # ... and at least this many times the track's typical section
const ROUGH_MAX := 5        # rough spots kept per lap
const ROUGH_SEG := 50     # metres per section when looking for the roughest spots
const VERSION := 6        # bump when the analysis changes, so stored profiles get rebuilt
const TRACE_STEP := 10         # metres between stored map / trace points
const WHEELS := ["FL", "FR", "RL", "RR"]


# Files are named trackname_class.csv, e.g. Brno_LMP3.csv -> {"track": "Brno", "class": "LMP3"}.
# The class is whatever follows the last underscore, so track names may contain underscores.
static func guess_from_name(file_name: String) -> Dictionary:
	var base := file_name.get_basename()
	var cut := base.rfind("_")
	if cut <= 0 or cut >= base.length() - 1:
		return {"track": "", "class": ""}
	return {"track": base.substr(0, cut).strip_edges(), "class": base.substr(cut + 1).strip_edges()}


# Returns the profile, or {"error": "..."} if the file cannot be used.
# Real circuits are 1.5 km or more; anything shorter is a fragment of a lap, not a lap.
const MIN_LAP_M := 1500.0


static func is_full_lap(length_m: float) -> bool:
	return length_m >= MIN_LAP_M


static func analyze(path: String) -> Dictionary:
	var data := _load(path)
	if data.is_empty():
		return {"error": "could not read the file"}
	var ch: Dictionary = data["ch"]
	for need in ["Distance", "Ground Speed", "Throttle Pos", "Brake Pos", "G Force Lat"]:
		if not ch.has(need) or ch[need].is_empty():
			return {"error": "no '%s' channel" % need}
	var n_raw: int = ch["Distance"].size()
	for optional in ["G Force Long", "Gear", "Engine RPM"]:
		if not ch.has(optional):
			var zeros := []
			zeros.resize(n_raw)
			zeros.fill(0.0)
			ch[optional] = zeros

	var seg := _best_segment(ch)
	if seg.is_empty():
		return {"error": "no complete lap found"}
	var a: int = seg[0]
	var b: int = seg[1]
	var r := _resample(ch, a, b, ["Ground Speed", "Throttle Pos", "Brake Pos", "G Force Lat", "G Force Long", "Gear", "Engine RPM"])
	if r.is_empty() or not is_full_lap(float(ch["Distance"][b]) - float(ch["Distance"][a])):
		return {"error": "no complete lap in the file (the longest piece is too short to be a lap)"}
	var n: int = r["len"] + 1

	var v: Array = r["Ground Speed"]
	var thr: Array = r["Throttle Pos"]
	var brk: Array = r["Brake Pos"]
	var gx: Array = r["G Force Long"]
	var gear: Array = r["Gear"]
	var gl := _sm(r["G Force Lat"], 5)
	var vs := _sm(v, 9)

	# time spent at every metre, lap time, speed extremes
	var dt := []
	dt.resize(n)
	var total_t := 0.0
	var vtop := 0.0
	var vtop_at := 0
	var vmin := 1.0e9
	for i in n:
		dt[i] = 1.0 / maxf(v[i] / 3.6, 5.0)
		total_t += dt[i]
		if v[i] > vtop:
			vtop = v[i]
			vtop_at = i
		vmin = minf(vmin, v[i])

	# circuit shape: curvature = lateral acceleration / speed^2, integrated into a heading
	var th := []
	th.resize(n)
	var acc := 0.0
	for i in n:
		acc += 9.81 * gl[i] / pow(maxf(v[i] / 3.6, 10.0), 2.0)
		th[i] = acc
	var total_h: float = th[n - 1]
	var closed: bool = absf(absf(total_h) - TAU) < 0.7   # a lap turns through one full circle
	var target := total_h
	if closed:
		target = TAU if total_h >= 0.0 else -TAU
	var mx := []
	var my := []
	mx.resize(n)
	my.resize(n)
	var cx := 0.0
	var cy := 0.0
	for i in n:
		var heading: float = th[i] + (target - total_h) * i / float(n - 1)
		cx += cos(heading)
		cy += sin(heading)
		mx[i] = cx
		my[i] = cy
	var closure := Vector2(cx, cy).length()
	for i in n:
		mx[i] -= cx * i / float(n - 1)
		my[i] -= cy * i / float(n - 1)

	var zones := _find_zones(brk, gx, n)
	var corners := _find_corners(gl, th, n)
	var kinks := _corner_details(corners, zones, v, vs, gl, thr, gear, th, vtop, n)
	var straights := _find_straights(thr, gl, v, corners, kinks, n)

	# shares of the lap
	var t_full := 0.0
	var t_brake := 0.0
	var t_coast := 0.0
	var gear_time := {}
	for i in n:
		if thr[i] >= 98.0:
			t_full += dt[i]
		if brk[i] >= BRAKE_ON:
			t_brake += dt[i]
		if thr[i] < 5.0 and brk[i] < BRAKE_ON:
			t_coast += dt[i]
		var g := str(roundi(gear[i]))
		gear_time[g] = float(gear_time.get(g, 0.0)) + dt[i]
	var gear_pct := {}
	for g in gear_time:
		gear_pct[g] = snappedf(gear_time[g] / total_t * 100.0, 0.1)
	var longest := 0
	for s in straights:
		longest = maxi(longest, int(s["length"]))
	var heavy := 0
	for z in zones:
		if z["peak"] >= 80.0 or z["decel"] >= 2.0:
			heavy += 1

	var traits := _traits(corners, zones, v, gl, gx, dt, total_t, t_full, t_brake, vtop, longest, n)
	var res := _resources(ch, a, b)
	if res.has("fuel_used_l") and float(res["fuel_used_l"]) > 0.0:
		traits["fuel_l_lap"] = res["fuel_used_l"]
		traits["fuel_l_min"] = snappedf(float(res["fuel_used_l"]) / total_t * 60.0, 0.01)
		traits["fuel_l_km"] = snappedf(float(res["fuel_used_l"]) / ((n - 1) / 1000.0), 0.001)
	var wear_sum := 0.0
	var wear_n := 0
	for k in res.get("tyre_wear_pct", {}):
		wear_sum += float(res["tyre_wear_pct"][k])
		wear_n += 1
	if wear_n > 0:
		traits["tyre_wear_lap"] = snappedf(wear_sum / wear_n, 0.001)
		traits["tyre_wear_km"] = snappedf(wear_sum / wear_n / ((n - 1) / 1000.0), 0.0001)
	traits.merge(_bumps(ch, a, b, gl, v))

	# reduced map and trace (one point every TRACE_STEP metres)
	var pts := []
	var speed_trace := []
	var throttle_trace := []
	var brake_trace := []
	for i in range(0, n, TRACE_STEP):
		pts.append([snappedf(mx[i], 0.1), snappedf(my[i], 0.1), roundi(v[i])])
		speed_trace.append(roundi(v[i]))
		throttle_trace.append(roundi(thr[i]))
		brake_trace.append(roundi(brk[i]))
	if closed:
		pts.append(pts[0].duplicate())

	return {
		"version": VERSION,
		"source": path.get_file(),
		"date": str(data["meta"].get("Log Date", "")),
		"lap": {
			"length_m": n - 1, "time_s": snappedf(total_t, 0.001),
			"avg_kmh": snappedf((n - 1) / total_t * 3.6, 0.1),
			"top_kmh": roundi(vtop), "top_at_m": vtop_at, "min_kmh": roundi(vmin),
		},
		"map": {
			"pts": pts, "step": TRACE_STEP, "closed": closed,
			"closure_m": snappedf(closure, 0.1), "heading_deg": roundi(rad_to_deg(total_h)),
			"direction": "clockwise" if total_h < 0.0 else "anticlockwise",
		},
		"corners": corners,
		"straights": straights,
		"stats": {
			"full_throttle_pct": snappedf(t_full / total_t * 100.0, 0.1),
			"braking_pct": snappedf(t_brake / total_t * 100.0, 0.1),
			"coasting_pct": snappedf(t_coast / total_t * 100.0, 0.1),
			"gear_pct": gear_pct,
			"braking_zones": zones.size(), "heavy_braking_zones": heavy,
			"longest_straight_m": longest, "flat_kinks": kinks.size(),
			"max_lat_g": snappedf(_max_abs(gl), 0.01),
			"max_brake_g": snappedf(_max_abs(gx), 0.01),
			"max_rpm": roundi(_max_abs(r["Engine RPM"])),
		},
		"resources": res,
		"traits": traits,
		"trace": {"step_m": TRACE_STEP, "speed": speed_trace, "throttle": throttle_trace, "brake": brake_trace},
	}


# ---------- reading the CSV ----------
static func _wanted() -> Array:
	var out := ["Distance", "Ground Speed", "Throttle Pos", "Brake Pos", "G Force Lat", "G Force Long",
		"G Force Vert", "Gear", "Engine RPM", "Lap Number", "Fuel Level", "Eng Water Temp",
		"Ambient Temperature", "Track Temperature"]
	for k in WHEELS:
		out.append("Ride Height " + k)
		out.append("Tyre Wear " + k)
		out.append("Tyre Pressure " + k)
		out.append("Brake Temp " + k)
		for zone in ["Outer", "Centre", "Inner"]:
			out.append("Tyre Temp %s %s" % [k, zone])
	return out


# {"meta": {...}, "ch": {channel: Array of floats}} or {} if the file cannot be read
static func _load(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var wanted := _wanted()
	var meta := {}
	var cols := {}   # channel -> column index
	var ch := {}     # channel -> Array
	var width := 0
	var header_seen := false
	var units_skipped := false
	while not f.eof_reached():
		var line := f.get_csv_line()
		if line.size() < 2:
			continue
		if not header_seen:
			if line[0] == "Distance":
				header_seen = true
				width = line.size()
				for i in line.size():
					if line[i] in wanted:
						cols[line[i]] = i
						ch[line[i]] = []
			else:
				meta[line[0]] = line[1]
			continue
		if not units_skipped:
			units_skipped = true   # the row under the channel names holds the units
			continue
		if line.size() < width:
			continue
		for channel in cols:
			ch[channel].append(float(line[cols[channel]]))
	if not header_seen:
		return {}
	return {"meta": meta, "ch": ch}


# The fastest complete lap, as [first row, last row + 1, lap time]. Laps are the stretches
# between changes of the Lap Number channel. Without such boundaries the whole file is used.
static func _best_segment(ch: Dictionary) -> Array:
	var d: Array = ch["Distance"]
	var v: Array = ch["Ground Speed"]
	var n := d.size()
	var bounds := []
	if ch.has("Lap Number"):
		var ln: Array = ch["Lap Number"]
		for i in range(n - 1):
			if ln[i + 1] != ln[i]:
				bounds.append(i + 1)
	var segs := []
	if bounds.size() < 2:
		bounds = [0, n]
	for k in range(bounds.size() - 1):
		var a: int = bounds[k]
		var b: int = bounds[k + 1]
		var t := 0.0
		for i in range(a + 1, b):
			t += (d[i] - d[i - 1]) / maxf((v[i] + v[i - 1]) / 7.2, 1.0)
		segs.append({"a": a, "b": b, "len": d[b - 1] - d[a], "time": t})
	var lens := []
	for s in segs:
		lens.append(s["len"])
	lens.sort()
	var median: float = lens[int(lens.size() / 2.0)]
	var best := {}
	for s in segs:
		if s["len"] >= 0.85 * median and (best.is_empty() or s["time"] < best["time"]):
			best = s
	if best.is_empty():
		return []
	return [best["a"], best["b"], best["time"]]


# Linear interpolation of the given channels onto a 1 m grid. Returns {"len": metres, channel: Array}.
static func _resample(ch: Dictionary, a: int, b: int, names: Array) -> Dictionary:
	var d: Array = ch["Distance"]
	var idx := [a]
	for i in range(a + 1, b):
		if d[i] > d[idx[idx.size() - 1]]:
			idx.append(i)
	if idx.size() < 50:
		return {}
	var d0: float = d[idx[0]]
	var length := int(d[idx[idx.size() - 1]] - d0)
	var out := {"len": length}
	for channel in names:
		var arr := []
		arr.resize(length + 1)
		out[channel] = arr
	var j := 0
	for m in range(length + 1):
		var target := d0 + m
		while j < idx.size() - 2 and d[idx[j + 1]] < target:
			j += 1
		var i0: int = idx[j]
		var i1: int = idx[j + 1]
		var span: float = d[i1] - d[i0]
		var f := 0.0
		if span > 0.0:
			f = clampf((target - d[i0]) / span, 0.0, 1.0)
		for channel in names:
			var src: Array = ch[channel]
			out[channel][m] = src[i0] + (src[i1] - src[i0]) * f
	return out


# Moving average over w samples
static func _sm(x: Array, w: int) -> Array:
	var n := x.size()
	var h: int = w >> 1
	var prefix := [0.0]
	for i in n:
		prefix.append(prefix[i] + x[i])
	var out := []
	out.resize(n)
	for i in n:
		var lo := maxi(0, i - h)
		var hi := mini(n - 1, i + h)
		out[i] = (prefix[hi + 1] - prefix[lo]) / float(hi - lo + 1)
	return out


static func _max_abs(x: Array) -> float:
	var m := 0.0
	for q in x:
		m = maxf(m, absf(q))
	return m


static func _mean(x: Array, from: int, to: int) -> float:
	var total := 0.0
	for q in range(from, to):
		total += x[q]
	return total / maxf(float(to - from), 1.0)


# ---------- finding things ----------
# Braking zones: brake above BRAKE_ON, short gaps merged
static func _find_zones(brk: Array, gx: Array, n: int) -> Array:
	var zones := []
	var pos := 0
	while pos < n:
		if brk[pos] >= BRAKE_ON:
			var s := pos
			var last := pos
			var j := pos
			while j < n - 1:
				j += 1
				if brk[j] >= BRAKE_ON:
					last = j
				elif j - last > BRAKE_GAP:
					break
			if last - s + 1 >= BRAKE_MIN_LEN:
				var peak := 0.0
				var decel := 0.0
				for q in range(s, last + 1):
					peak = maxf(peak, brk[q])
					decel = maxf(decel, gx[q])   # positive longitudinal G = braking in these exports
				zones.append({"start": s, "end": last, "peak": peak, "decel": decel})
			pos = last + 1
		else:
			pos += 1
	return zones


static func _sgn(x: float) -> int:
	return 1 if x >= 0.0 else -1


# A corner is a stretch of lateral G above CORNER_G with one sign (so a left and a right
# are always two corners). th is the heading in radians.
static func _find_corners(gl: Array, th: Array, n: int) -> Array:
	var corners := []
	var pos := 0
	while pos < n:
		if absf(gl[pos]) >= CORNER_G:
			var sg := _sgn(gl[pos])
			var s := pos
			var last := pos
			var j := pos
			while j < n - 1:
				j += 1
				if absf(gl[j]) >= CORNER_G:
					if _sgn(gl[j]) == sg:
						last = j
					else:
						break
				elif j - last > CORNER_GAP:
					break
			if last - s + 1 >= CORNER_MIN_LEN:
				var turned := rad_to_deg(th[last] - th[s])
				if absf(turned) >= CORNER_MIN_ANGLE:
					corners.append({"start": s, "end": last, "angle": turned})
			pos = last + 1
		else:
			pos += 1
	return corners


static func _corner_type(ratio: float) -> String:
	if ratio < 0.33:
		return "hairpin"
	if ratio < 0.45:
		return "slow"
	if ratio < 0.58:
		return "medium"
	return "fast"   # ratio = apex speed / top speed of the lap


# Fills in each corner. Bends taken flat out (no lift near the apex) are removed from
# the corner list and returned separately: they count as part of a straight.
static func _corner_details(corners: Array, zones: Array, v: Array, vs: Array, gl: Array,
		thr: Array, gear: Array, th: Array, vtop: float, n: int) -> Array:
	for k in corners.size():
		var c: Dictionary = corners[k]
		var s: int = c["start"]
		var e: int = c["end"]
		var ap := s
		var gmax := 0.0
		for q in range(s, e + 1):
			if vs[q] < vs[ap]:
				ap = q
			gmax = maxf(gmax, absf(gl[q]))
		var w0 := maxi(0, ap - 10)
		var w1 := mini(n - 1, ap + 10)
		var gav := 0.0
		for q in range(w0, w1 + 1):
			gav += absf(gl[q])
		gav /= float(w1 - w0 + 1)
		var radius := 9999.0
		if gav > 0.05:
			radius = minf(pow(vs[ap] / 3.6, 2.0) / (9.81 * gav), 9999.0)
		c["n"] = k + 1
		c["dir"] = "R" if c["angle"] < 0.0 else "L"
		c["angle"] = roundi(absf(c["angle"]))
		c["apex"] = ap
		c["vmin"] = roundi(vs[ap])
		c["type"] = _corner_type(vs[ap] / vtop)
		c["gmax"] = snappedf(gmax, 0.01)
		c["radius"] = roundi(radius)
		c["gear"] = roundi(gear[ap])
		c["entry"] = roundi(v[s])
		c["exit"] = roundi(v[e])
		c["brake_from"] = 0
		c["brake_len"] = 0
		c["brake_peak"] = 0
		c["decel"] = 0.0
		c["pickup"] = -1   # metres after the apex until the throttle is back above 90%
		for q in range(ap, mini(n - 1, e + 100) + 1):
			if thr[q] >= 90.0:
				c["pickup"] = q - ap
				break
		# flat-out kink: throttle never drops near the apex (no lift, no braking), and the bend is
		# fast. A slow bend taken at full throttle is the exit of the corner before, not a kink.
		var flat: bool = vs[ap] >= FLAT_MIN_RATIO * vtop
		for q in range(maxi(0, ap - FLAT_WINDOW), mini(n - 1, ap + FLAT_WINDOW) + 1):
			if not flat or thr[q] < STRAIGHT_THROTTLE:
				flat = false
				break
		c["flat"] = flat
	var kinks := []
	var kept := []
	for c in corners:
		if c["flat"]:
			kinks.append({"start": c["start"], "end": c["end"], "apex": c["apex"], "dir": c["dir"],
				"vmin": c["vmin"], "gmax": c["gmax"], "angle": c["angle"]})
		else:
			c.erase("flat")
			kept.append(c)
	corners.assign(kept)
	for k in corners.size():
		corners[k]["n"] = k + 1
	# a braking zone belongs to the first corner that ends after it
	for z in zones:
		for c in corners:
			if c["end"] > z["end"]:
				if c["start"] - z["end"] < 250:
					var zone_len: int = z["end"] - z["start"] + 1
					if c["brake_len"] < zone_len:
						c["entry"] = roundi(v[z["start"]])
						c["brake_from"] = c["apex"] - z["start"]
						c["brake_len"] = zone_len
						c["brake_peak"] = roundi(z["peak"])
						c["decel"] = snappedf(z["decel"], 0.01)
				break
	return kinks


# Full-throttle stretches that are (nearly) straight or only bend through flat-out kinks.
# At least STRAIGHT_MIN long, unless they contain a kink (a flat-out bend is always a straight).
static func _find_straights(thr: Array, gl: Array, v: Array, corners: Array, kinks: Array, n: int) -> Array:
	# samples inside a flat-out kink count as straight: the driver never lifts there
	var kink := PackedByteArray()
	kink.resize(n)
	for c in kinks:
		for q in range(c["start"], mini(n - 1, c["end"]) + 1):
			kink[q] = 1
	var runs := []
	var pos := 0
	while pos < n:
		if thr[pos] >= STRAIGHT_THROTTLE and (absf(gl[pos]) < STRAIGHT_G or kink[pos] == 1):
			var last := pos
			var j := pos
			while j < n - 1:
				j += 1
				if thr[j] >= STRAIGHT_THROTTLE and (absf(gl[j]) < STRAIGHT_G or kink[j] == 1):
					last = j
				elif j - last > STRAIGHT_GAP:
					break
			var has_kink := false
			for c in kinks:
				if c["apex"] >= pos and c["apex"] <= last:
					has_kink = true
			if last - pos >= STRAIGHT_MIN or has_kink:
				runs.append([pos, last])
			pos = last + 1
		else:
			pos += 1
	# the start/finish straight is cut by the lap boundary: join its two halves
	if runs.size() > 1 and runs[0][0] == 0 and runs[runs.size() - 1][1] >= n - 2:
		runs[0][0] = runs[runs.size() - 1][0] - n
		runs.pop_back()
	var out := []
	for run in runs:
		var s0: int = posmod(run[0], n)
		var e: int = run[1]
		var vend := 0.0
		for q in range(maxi(0, e - 60), e + 1):
			vend = maxf(vend, v[q])
		var before := 0   # the corner this straight leads into
		var after := 0    # the corner it comes out of
		if not corners.is_empty():
			before = corners[0]["n"]
			for c in corners:
				if c["start"] >= e - 20:
					before = c["n"]
					break
			after = corners[corners.size() - 1]["n"]
			for c in corners:
				if c["end"] <= s0 + 20:
					after = c["n"]
				else:
					break
		var inside := []   # flat-out kinks taken inside this straight
		for c in kinks:
			if c["apex"] >= run[0] and c["apex"] <= e:
				inside.append(c)
		out.append({
			"start": s0, "end": e, "length": e - run[0],
			"vstart": roundi(v[s0]), "vend": roundi(vend), "after": after, "before": before,
			"kinks": inside,
		})
	return out


# Raw numbers behind the track grades (TrackGrades). Everything is per km or a share of
# the lap, so long and short tracks compare fairly.
static func _traits(corners: Array, zones: Array, v: Array, gl: Array, gx: Array, dt: Array,
		total_t: float, t_full: float, t_brake: float, vtop: float, longest: int, n: int) -> Dictionary:
	var km := (n - 1) / 1000.0
	# braking: speed scrubbed in all braking zones
	var scrub := 0.0
	var heavy := 0
	var decel := 0.0
	for z in zones:
		scrub += maxf(0.0, v[z["start"]] - v[z["end"]])
		decel += z["decel"]
		if z["peak"] >= 80.0 or z["decel"] >= 2.0:
			heavy += 1
	# high-speed cornering, and the combined load the tyres carry
	var hs_t := 0.0
	var load := 0.0
	for i in n:
		if v[i] >= HS_SPEED * vtop and absf(gl[i]) >= HS_G:
			hs_t += dt[i]
		load += sqrt(gl[i] * gl[i] + gx[i] * gx[i])
	# slow corners, exits, direction changes
	var slow := 0
	var pickup_sum := 0.0
	var pickup_n := 0
	var flips := 0
	for k in corners.size():
		var c: Dictionary = corners[k]
		if c["type"] == "hairpin" or c["type"] == "slow":
			slow += 1
			if c["pickup"] >= 0:
				pickup_sum += c["pickup"]
				pickup_n += 1
		if k > 0 and c["dir"] != corners[k - 1]["dir"] and c["start"] - corners[k - 1]["end"] < FLIP_GAP:
			flips += 1
	return {
		"full_throttle_pct": snappedf(t_full / total_t * 100.0, 0.1),
		"longest_straight_m": longest,
		"top_kmh": roundi(vtop),
		"scrub_kmh_km": snappedf(scrub / km, 0.1),
		"heavy_zones_km": snappedf(heavy / km, 0.01),
		"braking_pct": snappedf(t_brake / total_t * 100.0, 0.1),
		"decel_avg_g": snappedf(decel / maxf(zones.size(), 1), 0.01),
		"hs_corner_pct": snappedf(hs_t / total_t * 100.0, 0.1),
		"slow_corners_km": snappedf(slow / km, 0.01),
		"pickup_avg_m": roundi(pickup_sum / pickup_n) if pickup_n > 0 else -1,
		"corners_km": snappedf(corners.size() / km, 0.01),
		"direction_changes": flips,
		"combined_g_avg": snappedf(load / n, 0.01),
	}


# Bumpiness and kerbs from the vertical channels (if the export has them).
# Bumps: fast vertical motion where the car is (nearly) straight, so kerbs do not count.
# Kerbs: left and right ride heights moving differently in corners (one side on the kerb).
static func _bumps(ch: Dictionary, a: int, b: int, gl: Array, v: Array) -> Dictionary:
	var out := {}
	var names := []
	if ch.has("G Force Vert"):
		names.append("G Force Vert")
	var rh := ["Ride Height FL", "Ride Height FR", "Ride Height RL", "Ride Height RR"]
	var has_rh := true
	for k in rh:
		if not ch.has(k):
			has_rh = false
	if has_rh:
		names.append_array(rh)
	if names.is_empty():
		return out
	var r := _resample(ch, a, b, names)
	if r.is_empty():
		return out
	var n := mini(int(r["len"]) + 1, gl.size())
	if r.has("G Force Vert"):
		var gv := _highpass(r["G Force Vert"])
		var sum := 0.0
		var cnt := 0
		var spots := []
		var seg_sum := 0.0
		var seg_cnt := 0
		for i in n:
			if absf(gl[i]) < STRAIGHT_G:
				sum += gv[i] * gv[i]
				cnt += 1
				seg_sum += gv[i] * gv[i]
				seg_cnt += 1
			if (i + 1) % ROUGH_SEG == 0:
				# a section counts when it is mostly straight
				if seg_cnt >= ROUGH_SEG * 0.7:
					spots.append({"at": i + 1 - ROUGH_SEG, "g": sqrt(seg_sum / seg_cnt), "kmh": roundi(v[i + 1 - ROUGH_SEG])})
				seg_sum = 0.0
				seg_cnt = 0
		if cnt > 0:
			out["bump_rms_g"] = snappedf(sqrt(sum / cnt), 0.001)
			spots.sort_custom(func(x, y): return x["g"] > y["g"])
			# the graded value is the typical (median) section, so one big hit does not decide it
			if not spots.is_empty():
				out["bump_g"] = snappedf(spots[int(spots.size() / 2.0)]["g"], 0.001)
			# rough spots: sections clearly rougher than the track's norm (and rough in absolute terms)
			var limit := ROUGH_MIN_G
			if out.has("bump_g"):
				limit = maxf(limit, ROUGH_FACTOR * float(out["bump_g"]))
			var rough := []
			for s in spots:
				if s["g"] >= limit:
					rough.append(s)
			# touching sections are one rough patch: merge them (roughest section gives g and speed)
			rough.sort_custom(func(x, y): return x["at"] < y["at"])
			var merged := []
			for s in rough:
				var last: Dictionary = merged.back() if not merged.is_empty() else {}
				if not last.is_empty() and int(s["at"]) == int(last["at"]) + int(last["len"]):
					last["len"] = int(last["len"]) + ROUGH_SEG
					if s["g"] > last["g"]:
						last["g"] = s["g"]
						last["kmh"] = s["kmh"]
				else:
					merged.append({"at": s["at"], "len": ROUGH_SEG, "g": s["g"], "kmh": s["kmh"]})
			merged.sort_custom(func(x, y): return x["g"] > y["g"])
			var top := []
			for s in merged.slice(0, ROUGH_MAX):
				top.append({"at": s["at"], "len": s["len"], "g": snappedf(s["g"], 0.001), "kmh": s["kmh"]})
			out["rough_spots"] = top
	if has_rh:
		var fl := _highpass(r["Ride Height FL"])
		var fr := _highpass(r["Ride Height FR"])
		var rl := _highpass(r["Ride Height RL"])
		var rr := _highpass(r["Ride Height RR"])
		var ksum := 0.0
		var kcnt := 0
		for i in n:
			if absf(gl[i]) >= KERB_G:
				var diff: float = ((fl[i] + rl[i]) - (fr[i] + rr[i])) / 2.0
				ksum += diff * diff
				kcnt += 1
		if kcnt > 0:
			out["kerb_mm"] = snappedf(sqrt(ksum / kcnt), 0.01)
	return out


static func _highpass(x: Array) -> Array:
	var slow := _sm(x, BUMP_WINDOW)
	var out := []
	out.resize(x.size())
	for i in x.size():
		out[i] = x[i] - slow[i]
	return out


# Use of fuel, tyres and brakes over the chosen lap (rows a .. b-1 of the export)
static func _resources(ch: Dictionary, a: int, b: int) -> Dictionary:
	var out := {}
	if ch.has("Fuel Level"):
		out["fuel_used_l"] = snappedf(ch["Fuel Level"][a] - ch["Fuel Level"][b - 1], 0.01)
	var wear := {}
	var pressure := {}
	var tyre_temp := {}
	var brake_max := {}
	for k in WHEELS:
		if ch.has("Tyre Wear " + k):
			wear[k] = snappedf(ch["Tyre Wear " + k][b - 1] - ch["Tyre Wear " + k][a], 0.001)
		if ch.has("Tyre Pressure " + k):
			pressure[k] = snappedf(_mean(ch["Tyre Pressure " + k], maxi(a, b - 60), b), 0.1)
		if ch.has("Brake Temp " + k):
			var hot := 0.0
			for q in range(a, b):
				hot = maxf(hot, ch["Brake Temp " + k][q])
			brake_max[k] = roundi(hot)
		var zone_sum := 0.0
		var zone_n := 0
		for zone in ["Outer", "Centre", "Inner"]:
			var key := "Tyre Temp %s %s" % [k, zone]
			if ch.has(key):
				zone_sum += _mean(ch[key], a, b)
				zone_n += 1
		if zone_n > 0:
			tyre_temp[k] = snappedf(zone_sum / zone_n, 0.1)
	out["tyre_wear_pct"] = wear
	out["tyre_pressure_end_kpa"] = pressure
	out["tyre_temp_avg_c"] = tyre_temp
	out["brake_temp_max_c"] = brake_max
	if ch.has("Eng Water Temp"):
		var water := 0.0
		for q in range(a, b):
			water = maxf(water, ch["Eng Water Temp"][q])
		out["water_temp_max_c"] = snappedf(water, 0.1)
	if ch.has("Ambient Temperature"):
		out["ambient_c"] = snappedf(ch["Ambient Temperature"][a], 0.1)
	if ch.has("Track Temperature"):
		out["track_c"] = snappedf(ch["Track Temperature"][a], 0.1)
	return out
