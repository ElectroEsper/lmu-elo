# LMU Elo

A league tool for **Le Mans Ultimate**, built in Godot 4.7. It reads the game's result XML files and
turns them into driver ratings, standings, reports, race forecasts and broadcast graphics for the
OOFS Racing league.

## Getting started

1. Open the project in **Godot 4.7** (or run an exported build).
2. On the **Review** screen, drop result XMLs (or whole folders) anywhere on the window. Each file is
   checked, then rated. Telemetry exports (MoTeC CSV) can be dropped the same way.
3. Set the league up once in **Settings**: points scale, dropped rounds, series names, season length
   and calendar, teams.

File names carry the season, series and round: `s6-mc2-r.xml` = season 6, series `mc`, round 2,
race (`-q` = qualifying). The series code is mapped to a name in Settings → Series.

## Screens

| Screen | What it does |
|---|---|
| Review | Check and rate dropped result files; merge duplicate driver names |
| Ratings | Elo per class and session (race and quali are rated separately) |
| Drivers | Everything about one driver: ratings, history, grades, fingerprint, track fit |
| Reports | League reports (standings, consistency, head to head, forecast record…), each exportable to Excel |
| Profiles | Lap-data fingerprints of drivers, cars and tracks; telemetry track layouts |
| Predict | Monte Carlo forecast of qualifying and the race, with weather (Dry / Mixed / Wet) |
| Penalties | Steward decisions after a race: time penalties, dropped places, disqualifications |
| Graphics | Images for social media and the stream (see below) |
| Settings | League settings, saved in `league_settings.json` |

## League rules the tool applies

- **Points**: 50, 47, 44, 41, 38, 35, then one less per place down to 1 (editable in Settings).
- **Dropped rounds**: each driver's worst round is dropped, from round 3 on. A missed round counts 0
  and is dropped first.
- **Scoring**: a driver must complete at least 1 lap to score. 0 laps (no-start or lap-1 crash) =
  DNS = 0 points. A disqualification (in the file or applied on the Penalties page) = 0 points.
- **Championships**: one per season, series and class. Team championships: one per series and
  class, the sum of both drivers' points after their own drops (line-ups in Settings → Teams).

## Ratings

- Elo per class, with separate **race** and **quali** ratings. Every pair of drivers in a session is
  a duel. K starts at 128 and settles to 64 over a driver's first 480 duels. A new session rating
  starts from the driver's other rating.
- **Ranks** (Bronze to Platinum, names and limits in Settings) use the average of race and quali
  rating. Drivers are Unranked until 120 duels, promoted on reaching a limit, demoted only 30
  points below it, and marked inactive after 180 days without racing in the class.

## Graphics

Event predictions, championship standings (driver and team), season scenarios (title fight),
track cards, driver cards (single or batch) and ranks, each in three sizes: Instagram post,
Instagram story and stream (1920 × 1080). Stream standings show the whole field, 10 per page.

Saved images go to `Documents/LMU_Elo graphics/`, filed the way they are sent to the broadcaster:

```
Season6_R4/Enduro/Standings/enduro_gt3_standings_p1.png
Season6_R4/Enduro/Championship Scenario/gt3_title_fight.png
```

(`R4` = rounds run so far). Saving again replaces the file of the same name.

## Your data

Everything is stored in Godot's user data folder:

- Windows: `%APPDATA%\Godot\app_userdata\LMU_Elo\`
- Linux: `~/.local/share/godot/app_userdata/LMU_Elo/`
- macOS: `~/Library/Application Support/Godot/app_userdata/LMU_Elo/`

| Path | Contents |
|---|---|
| `elo.json` | Ratings and rating history (`elo.backup.json`: the previous save) |
| `events/` | One file per rated event: results, stats, penalties |
| `xml/` | Archived copies of every imported result file |
| `tracks/` | Telemetry track profiles |
| `forecasts/` | Saved forecasts (for the Forecast record report) |
| `league_settings.json` | Settings |

**Back up data** (sidebar) zips the whole folder into Documents. To restore, close the tool and
unzip the backup over the data folder. **Recompute all** rebuilds every rating from the saved
events; **Re-read archived XML** refreshes stats from the archived files without re-rating.

## Tests

```
tests/run_tests.sh /path/to/godot          # Linux / macOS
tests\run_tests.bat "C:\path\to\Godot_v4.7-stable_win64_console.exe"
```

The tests use a separate data folder, so your real data is never touched. Put league result XMLs
in `tests/data/xml/` to run the checks that need real races (that folder is not committed, as it
holds driver names). A watchdog makes every run end, with exit 4 and the last step if something
gets stuck. See `tests/README.md` for details.

## Project layout

- Autoloads: `Elo` (`elo.gd`: import, ratings, penalties, storage), `Reports` (`reports.gd`),
  `Predict` (`predict.gd`: forecast model), `Profiles` (`profiles.gd`: lap-data fingerprints).
- Screens: `review_screen.gd` (frame and sidebar) and one `*_view.gd` per screen.
- Graphics: `graphics_view.gd` (screen, data for each image, saving) and `graphic_card.gd`
  (drawing).
- Models: `driver_grades.gd`, `ranks.gd`, `track_grades.gd`, `driver_track_fit.gd`,
  `wet_weather.gd`, `season_scenarios.gd`, `league_settings.gd`.
