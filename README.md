# Grid Ledger

A league tool for **Le Mans Ultimate**, built in Godot 4.7 (working name; the project's internal
name is still `LMU_Elo`). It reads the game's result XML files and turns them into driver ratings,
standings, reports, race forecasts and broadcast graphics for the OOFS Racing league.

Version: see `CHANGELOG.md`; the number lives in Project Settings > Application > Config > Version
and shows next to the app's name in the sidebar.

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
- **Success ballast**: each class finish adds or takes off kg for the next race (GT3 +15/+10/+5/0/-5/-10/-15,
  Hyper and LMP3 +10/+5/+2/0/-2/-5/-10 for P1 to P7 or lower; editable in Settings). A DNF counts as P7
  or lower; a disqualification, a no-start or a missed race changes nothing. Never below 0, at most
  45 kg for GT3 and 30 kg for Hypercars and LMP3 (the result files show both caps), per season and series, and it follows a driver
  who changes class. Positions are taken after the Penalties page. The result files record what
  each car carried, and season 6 replays to it. Shown in the standings report and graphic and on the
  Predict screen. Its cost is learned from the league's races, comparing each driver with their own
  races of the same season and series (about 0.15 s per 10 kg on a 100 s lap). Slowing the cars by
  it in the forecast is an upgrade, off by default: replaying past races it made the forecast
  worse, because ballast goes to the drivers on form.
- **Current form**: a driver's race pace over their last 5 races against their own average
  (Profiles > Drivers "Form %", and the driver profile), shown from 6 races in a class. The
  forecast carries half of it into the next race (Current form upgrade, on: replaying past races
  it made the forecasts better).
- **Lap records**: the league's own records per track (layout) and class, from the best laps in
  the result files: the lap record (any session) and the race lap record, with how each came down
  (Profiles > Layout > Records). A disqualified driver's lap never counts.
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

Event predictions, championship standings (driver and team), season scenarios (title fight, for
drivers and for teams), race recaps (with a highlight when a league lap record falls; the biggest surprise and the
forecast line can be judged on any saved forecast, or the ratings only), season
recaps (per series and class, four pages: champion and top 10; championship timeline with the
turning point; the season in numbers; awards: cleanest driver, hard charger, comeback of the
season, rookie of the year, most improved, underdog (from outside the top 3), iron man, Mr
Consistent; tick the pages to save; also a report),
track cards, driver cards (single or batch) and ranks, each in three sizes: Instagram post,
Instagram story and stream (1920 × 1080). Stream standings show the whole field, 10 per page.

Saved images go to `Documents/Grid Ledger/Graphics/`, filed the way they are sent to the broadcaster:

```
s6_r4/Enduro/Standings/enduro_gt3_standings_p1.png
s6_r4/Enduro/Championship Scenario/gt3_title_fight.png
```

(`s6_r4` = season 6, round 4: the round the image is for. Forecasts, track cards and title fights go in the next race's folder, standings, ranks, driver cards and recaps in the folder of the round they show. Folders from earlier versions named `Season6_R4` are renamed on start). Saving again replaces the file of the same name.

## Your data

Everything lives in `Documents/Grid Ledger/`:

| Folder | Contents |
|---|---|
| `Data/` | Ratings, events, archived results, track profiles, forecasts, settings (table below) |
| `Graphics/` | Saved images (`s6_r4/...`: season 6, round 4) |
| `Backups/` | Backup zips, and the data set aside by a restore (`Before restore <date>`) |
| `Exports/` | Excel files |

| In `Data/` | Contents |
|---|---|
| `elo.json` | Ratings and rating history (`elo.backup.json`: the previous save) |
| `events/` | One file per rated session: results, stats, penalties |
| `xml/` | Archived copies of every imported result file |
| `tracks/` | Telemetry track profiles |
| `forecasts/` | Saved forecasts (for the Forecast record report) |
| `league_settings.json` | Settings |
| `predict.json`, `ui.cfg` | Predictor training and screen choices |

Earlier versions kept the data in Godot's user data folder (`%APPDATA%\Godot\app_userdata\LMU_Elo\`
on Windows) and the images in `Documents/LMU_Elo graphics/`. On the first start of this version both
are copied into `Documents/Grid Ledger/`, and the old copies are left as they were (delete them once
you are happy). If Documents cannot be written (a folder protection such as Windows "Controlled
folder access" blocking it), the tool says so and keeps using the user data folder.

**Back up data** (sidebar) zips the `Data/` folder into `Backups/`. **Restore backup...** picks a
zip, shows what is in it and asks first; the current data is then moved (not deleted) to
`Backups/Before restore <date>/`, the backup is unpacked, and the tool restarts. A zip whose files
sit inside a folder (unzipped and zipped again) works too; any other zip is refused.
**Recompute all** rebuilds every rating from the saved events; **Re-read archived XML** refreshes
stats from the archived files without re-rating.

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
- Files: `app_paths.gd` (where everything is kept, first-start copy, backup and restore).
- Models: `driver_grades.gd`, `ranks.gd`, `track_grades.gd`, `driver_track_fit.gd`,
  `wet_weather.gd`, `season_scenarios.gd`, `league_settings.gd`.
