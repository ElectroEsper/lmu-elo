class_name ReferenceLaps
extends RefCounted
## Reference lap times per track and class, from Ohne Speed's LMU laptimes spreadsheet (the
## "Class avgW" column, the 100% of its tiers: about 100% alien, 101% competitive, 102% good,
## 103-105% midpack, 106% tail-ender, 107% offline). A fixed yardstick per track, so a driver's
## pace can be followed from track to track against the same standard instead of against
## whoever raced that day. The table ships with the app (SHIPPED_TABLE); a newer copy saved as
## Data/reference_laps.json ({"patch": "...", "classes": {"LMGT3": {"Spa": 136.92, ...}, ...}}) is
## used instead, for a new game patch.

const FILE := "reference_laps.json"

## The sheet's class names for the game's.
const CLASSES := {"GT3": "LMGT3", "LMGT3": "LMGT3", "Hyper": "LMH", "LMH": "LMH", "Hypercar": "LMH",
	"LMP3": "LMP3", "LMP2": "LMP2 (WEC)", "LMP2_ELMS": "LMP2 (ELMS)", "GTE": "GTE"}

## The sheet's track names for the game's (TrackCourse in the result files). Checked against the
## saved telemetry laps: within half a second of the reference at every track.
const TRACKS := {
	"Algarve International Circuit": "Portimao",
	"Autodromo Enzo e Dino Ferrari": "Imola",
	"Autodromo Nazionale Monza": "Monza",
	"Monza Curva Grande Circuit": "Monza (curvagrande)",
	"Autódromo José Carlos Pace": "Interlagos",
	"Bahrain International Circuit": "Bahrain (wec)",
	"Bahrain Endurance Circuit": "Bahrain (endurance)",
	"Bahrain Outer Circuit": "Bahrain (outer)",
	"Bahrain Paddock Circuit": "Bahrain (paddock)",
	"Circuit de Barcelona": "Barcelona",
	"Circuit de Spa-Francorchamps": "Spa",
	"Circuit de Spa-Francorchamps Endurance": "Spa",
	"Circuit de la Sarthe": "Circuit de la Sarthe",
	"Circuit de la Sarthe Mulsanne": "Circuit de la Sarthe (straight)",
	"Circuit of the Americas": "COTA",
	"Circuit of the Americas National": "COTA (national)",
	"Daytona International Speedway Road Course": "Daytona",
	"Fuji Speedway": "Fuji (chicane)",
	"Fuji Speedway Classic": "Fuji (classic)",
	"Lusail International Circuit": "Qatar",
	"Lusail Short Circuit": "Qatar (short)",
	"Michelin Raceway Road Atlanta": "Road Atlanta",
	"Paul Ricard - ELMS": "Paul Ricard",
	"Sebring International Raceway": "Sebring",
	"Sebring School Circuit": "Sebring (school)",
	"Silverstone Grand Prix Circuit - ELMS": "Silverstone (GP)",
	"Silverstone National Circuit": "Silverstone (National)",
	"Silverstone International Circuit": "Silverstone (International)",
	"WeatherTech Raceway Laguna Seca": "Laguna Seca",
	"Long Beach Street Circuit": "Long Beach",
}

static var _table := {}
static var _loaded := false


static func table() -> Dictionary:
	if not _loaded:
		_loaded = true
		var path := AppPaths.file(FILE)
		var data = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		_table = data if data is Dictionary and data.get("classes") is Dictionary else SHIPPED_TABLE
	return _table


## Reference lap in seconds for a track (the game's TrackCourse) and class, 0 if there is none.
static func lap(course: String, cls: String) -> float:
	var c := str(CLASSES.get(cls, cls))
	var t := str(TRACKS.get(course, course))
	return float(table()["classes"].get(c, {}).get(t, 0.0))


## The 100% of a race for "clean race pace": the sheet's reference lap in the dry; in a wet race
## (the sheet covers dry conditions only) or at a track the sheet does not have, the quickest lap
## of the class in that race, as the league does. [seconds, "sheet" / "race best"].
static func race_reference(course: String, cls: String, wet: bool, class_best: float) -> Array:
	var ref := 0.0 if wet else lap(course, cls)
	if ref > 0.0:
		return [ref, "sheet"]
	return [class_best, "race best"] if class_best > 0.0 else [0.0, ""]


## A lap time as a percentage of the reference (100 = the reference), 0 without one.
static func pct(time_s: float, course: String, cls: String) -> float:
	var ref := lap(course, cls)
	return 100.0 * time_s / ref if ref > 0.0 and time_s > 0.0 else 0.0


## The shipped table: Ohne Speed's LMU laptimes spreadsheet, column 'Class avgW' (the 100% reference), game patch 1.4+, read 2026-11-11.
const SHIPPED_TABLE := {
	"patch": "1.4+",
	"classes": {
		"LMGT3": {
			"Bahrain (wec)": 118.45,
			"Bahrain (endurance)": 145.27,
			"Bahrain (outer)": 72.02,
			"Bahrain (paddock)": 80.62,
			"Barcelona": 100.52,
			"Circuit de la Sarthe": 233.70,
			"Circuit de la Sarthe (straight)": 218.20,
			"COTA": 125.33,
			"COTA (national)": 89.83,
			"Daytona": 104.75,
			"Fuji (chicane)": 99.67,
			"Fuji (classic)": 95.76,
			"Imola": 101.87,
			"Interlagos": 93.27,
			"Laguna Seca": 81.50,
			"Long Beach": 78.35,
			"Monza": 108.39,
			"Monza (curvagrande)": 98.84,
			"Paul Ricard": 123.09,
			"Paul Ricard (1A)": 109.90,
			"Paul Ricard (1A v2)": 115.00,
			"Paul Ricard (1A v2 short)": 105.60,
			"Paul Ricard (3A)": 79.52,
			"Portimao": 102.97,
			"Qatar": 113.73,
			"Qatar (short)": 68.69,
			"Road Atlanta": 77.95,
			"Silverstone (GP)": 117.67,
			"Silverstone (National)": 52.75,
			"Silverstone (International)": 60.93,
			"Sebring": 119.71,
			"Sebring (school)": 62.54,
			"Spa": 136.92,
		},
		"LMH": {
			"Bahrain (wec)": 104.76,
			"Bahrain (endurance)": 129.86,
			"Bahrain (outer)": 63.84,
			"Bahrain (paddock)": 71.31,
			"Barcelona": 88.12,
			"Circuit de la Sarthe": 202.28,
			"Circuit de la Sarthe (straight)": 188.80,
			"COTA": 111.48,
			"COTA (national)": 80.36,
			"Daytona": 92.39,
			"Fuji (chicane)": 87.80,
			"Fuji (classic)": 84.05,
			"Imola": 89.23,
			"Interlagos": 82.16,
			"Laguna Seca": 72.38,
			"Long Beach": 70.51,
			"Monza": 94.27,
			"Monza (curvagrande)": 85.91,
			"Paul Ricard": 108.19,
			"Paul Ricard (1A)": 96.00,
			"Paul Ricard (1A v2)": 100.75,
			"Paul Ricard (1A v2 short)": 93.23,
			"Paul Ricard (3A)": 69.81,
			"Portimao": 90.63,
			"Qatar": 99.15,
			"Qatar (short)": 59.38,
			"Road Atlanta": 68.74,
			"Silverstone (GP)": 101.96,
			"Silverstone (National)": 46.01,
			"Silverstone (International)": 53.32,
			"Sebring": 105.24,
			"Sebring (school)": 55.25,
			"Spa": 119.35,
		},
		"LMP3": {
			"Bahrain (wec)": 112.95,
			"Bahrain (endurance)": 138.90,
			"Bahrain (outer)": 68.98,
			"Bahrain (paddock)": 76.82,
			"Barcelona": 93.88,
			"Circuit de la Sarthe": 222.08,
			"Circuit de la Sarthe (straight)": 208.32,
			"COTA": 119.13,
			"COTA (national)": 85.13,
			"Daytona": 100.04,
			"Fuji (chicane)": 94.15,
			"Fuji (classic)": 90.10,
			"Imola": 96.82,
			"Interlagos": 88.12,
			"Laguna Seca": 77.45,
			"Long Beach": 75.23,
			"Monza": 102.94,
			"Monza (curvagrande)": 93.51,
			"Paul Ricard": 116.30,
			"Paul Ricard (1A)": 104.04,
			"Paul Ricard (1A v2)": 108.57,
			"Paul Ricard (1A v2 short)": 100.45,
			"Paul Ricard (3A)": 75.19,
			"Portimao": 97.52,
			"Qatar": 106.06,
			"Qatar (short)": 64.44,
			"Road Atlanta": 73.66,
			"Silverstone (GP)": 109.95,
			"Silverstone (National)": 49.78,
			"Silverstone (International)": 57.19,
			"Sebring": 113.25,
			"Sebring (school)": 58.96,
			"Spa": 129.72,
		},
		"LMP2 (WEC)": {
			"Bahrain (wec)": 109.75,
			"Bahrain (endurance)": 134.82,
			"Bahrain (outer)": 66.83,
			"Bahrain (paddock)": 74.31,
			"Barcelona": 91.17,
			"Circuit de la Sarthe": 212.47,
			"Circuit de la Sarthe (straight)": 197.71,
			"COTA": 115.62,
			"COTA (national)": 83.50,
			"Daytona": 97.06,
			"Fuji (chicane)": 91.21,
			"Fuji (classic)": 87.08,
			"Imola": 93.93,
			"Interlagos": 85.62,
			"Laguna Seca": 73.91,
			"Long Beach": 73.09,
			"Monza": 99.09,
			"Monza (curvagrande)": 90.04,
			"Paul Ricard": 112.84,
			"Paul Ricard (1A)": 100.11,
			"Paul Ricard (1A v2)": 104.76,
			"Paul Ricard (1A v2 short)": 97.70,
			"Paul Ricard (3A)": 72.82,
			"Portimao": 94.30,
			"Qatar": 102.61,
			"Qatar (short)": 61.65,
			"Road Atlanta": 70.25,
			"Silverstone (GP)": 106.35,
			"Silverstone (National)": 48.03,
			"Silverstone (International)": 55.27,
			"Sebring": 110.05,
			"Sebring (school)": 56.98,
			"Spa": 124.97,
		},
	},
}
