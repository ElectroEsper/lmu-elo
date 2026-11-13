# Changelog

The version lives in `project.godot` (Project Settings > Application > Config > Version). The app
shows it next to its name in the sidebar and in the window title; an exported .exe takes it as its
file and product version when those export fields are left empty.

## 1.1.0
A tidier app: the same tools, easier to find. Nothing was removed.
- Sidebar in groups: Race weekend (Import, Predict, Penalties, Graphics), League (Ratings,
  Drivers, Profiles, Reports), then Settings and the new Data & backups at the bottom. "Review"
  is now called Import.
- New screen, Data & backups: back up (with the time of the last backup), restore, the penalties
  file, Export all to Excel, Merge drivers (moved from Ratings), Re-read archived XML, Recompute
  all, and buttons to open the data, Backups, Exports and Graphics folders. These used to sit at
  the bottom of the sidebar.
- Predict: the actions are now in one row at the top, always in view: Grid from latest quali,
  Recent drivers, Predict, Save for the record, and Make the graphic (opens Graphics on the
  forecast's image). Backtest, Fit noise, Test upgrades and the assumptions moved to a Tuning tab
  (costly laps added to the assumptions). Lap time, the other classes and pit stops fold away
  under "More".
- Settings in four tabs: Championship, Ranks & grades, Look, Import. Save settings stays in view
  below the tabs.
- Reports: a list on the left grouped by Race, Season, Drivers and Cars, instead of a menu.
- Graphics: the Image menu is grouped (Race weekend, Season, Drivers, Tracks); the folder path
  became an "Open Graphics folder" button.
- Drivers: 12 tabs became 7 (Overview, Grades, Current form, Seasons & results, Ratings,
  Records, Tracks); tables that belong together are shown one above the other.

## 1.0.38
- Penalties now have their own file: penalties.json in the data folder, with a copy in Backups
  (outside the data folder, so it survives starting over). Penalties already applied are copied
  into it on the first start.
- A race imported again (after a reset, or the same session under another file name) gets its
  penalties back automatically.
- Penalties screen: "Save penalties file" (to Exports) and "Import penalties file...". Races
  already imported get the file's penalties at once; races not imported yet get them when their
  result file comes in.
- Settings > Telemetry file names: class tags (bits of a file name that mean a class: "HY",
  "P3"...) and track codes ("BRN" = Brno). The telemetry window uses them to preselect the track
  and class of every file, and says how many it recognised.
- The app also learns track codes by itself from every telemetry file imported. A bit of a name
  seen with two different tracks (a driver or setup name) is ignored. Learned codes are listed in
  Settings, can be added to the list to edit them, or forgotten.

## 1.0.37
- Graphics: new image "Season story", one driver's season in one championship. Pick the season,
  the championship and the driver (listed in standings order). "Save every driver's story" saves
  the whole grid in one go.
- On the image: a headline made from the driver's strongest facts ("Rookie season: quicker round
  after round", "Fastest race pace three times, up to P2 in the championship", "From P24 to P8
  at Road Atlanta"); up to five numbers, the most telling ones for that driver (championship,
  best finish, then wins, podiums, fastest pace, poles, laps led, rating gained, places gained,
  clean races); round by round (grid and finish, retirements, pole, laps led, wet races,
  championship place after each round); race pace against the class's middle driver each round,
  the rounds where it was the fastest, time lost to mistakes when it was 15 s or more; and three
  beats: the high point, the toughest day, and an award from the season recap.
- Post, story and stream sizes. Track names are shortened on it ("Road Atlanta", "Laguna Seca").

## 1.0.36
- Costly laps: the app now spots laps lost to a mistake (a spin, an off, a big lock-up): at least
  4% slower than the driver's own usual lap, measured against the class on that same lap, so a
  safety car or rain does not count. Invalidated laps are included. Not the start, pit laps or
  out-laps. About one lap in 26 across the league, costing 11-12 s on average.
- Each driver's rate of costly laps is tracked (pulled towards the class until they have a few
  races). Not shown as a grade in the profiles.
- Forecast: new upgrade "Costly laps (mistakes)", on. Each simulated race, a driver makes a random
  number of mistakes at their own rate, each costing a random amount around the class average.
  Before, the forecast only knew the clean-lap pace and small lap-to-lap scatter, so nobody ever
  made a big mistake. Replaying 91 races: Brier 0.2108 -> 0.2067 with the real grid, 0.2254 ->
  0.2250 with predicted quali; the same on two more sets of random draws. Clearest in GT3.
- Lap data is read again once on the first start (new lap-data version), to measure costly laps
  in every archived race.

## 1.0.35
- Season recap: the Most improved card no longer shows how sure the app is ("Gained 1.1% on the
  grid this season. Next: Brown +0.8%, Bordiyan +0.7%"); the 85% bar still applies.

## 1.0.34
- Season recap: Most improved goes to the clearest improver even if they already hold another
  award (like Cleanest driver), and the card names the next two: "Gained 0.5% on the grid this
  season (96% sure). Next: Bordiyan +0.4%, Gonzales +0.3%".

## 1.0.33
- Season recap: Most improved is now worked out by a model of the whole season: every dry
  qualifying and race, each session's conditions (track, heat, rubber) worked out from everyone
  in it, a line through each driver's season, and uncertain gains (few sessions) pulled back.
  It measures the pace a driver gained on the grid, and is only awarded when the app is at least
  85% sure it is real (some seasons a championship has none). Card: "Gained 1.1% on the grid this
  season (99% sure)". How it works: the "How Most Improved is decided" doc.
- The clean race pace % from 1.0.32 is no longer used for the award (the reference laps stay).

## 1.0.32
- Reference laps from Ohne Speed's LMU laptimes sheet (the community's 100%, game patch 1.4+) for
  every class and track, built in; a newer copy saved as Data/reference_laps.json is used instead.
- "Clean race pace %": the average of a driver's 5 quickest race laps against the 100%: the
  sheet's reference lap in the dry, the class's best lap of the race when wet (the sheet does not
  cover wet conditions).
- Season recap: Most improved uses clean race pace %, judged against the middle of the field at
  each round (tracks sit very differently against the sheet: the whole Hypercar field was nearly 2%
  further off at Qatar than at Fuji), as a trend through every round with 10+ clean laps. The card
  shows both: "103.4% → 103.4% of the reference; from 0.2 under to 1.3 under the field".
- The archived results are re-read once on start to pick this up.

## 1.0.31
- Season recap: Most improved is now about pace, not Elo: the biggest gain in race pace on the
  class over the season (a line through the driver's pace against the class median, round by
  round, without success ballast), at least 0.2%. Newcomers count again: learning pace is
  improving too, and a slower driver closing the gap can win it.

## 1.0.30
- Season recap awards reworked:
  - Cleanest driver: fewest contacts per lap raced (was per race), so Enduro distances and
    missed laps weigh fairly.
  - Hard charger: most places gained beyond what drivers from the same grid spots usually gain
    that season (a driver starting at the back has more places to make up).
  - Rookie of the year: first season in the league (any class or series), not just in the class.
  - Most improved: only drivers with 3+ races in the class before the season (a newcomer's
    rating climbs as it settles anyway).
  - Mr Consistent: the steadiest lap times (lap spread on clean laps against the class in each
    race, the driver's typical race over the season), instead of finishing places.

## 1.0.29
- Fixed: deleting the data folder in Documents to start fresh brought back the old data from
  before the move to Documents (Godot's AppData folder), on the next start. Importing results
  then skipped every file as "already complete". The move to Documents now happens once: the old
  folder gets a note ("MOVED TO DOCUMENTS.txt") and is never copied from again.

## 1.0.28
- Driver grades:
  - Quali pace and Race pace take the car out: each driver's pace once the car's own pace
    (worked out from everyone who drove it) is removed, so a quick car does not make a quick
    driver. Race pace is also without success ballast.
  - Recent races count more: a race 180 days older than the latest league race counts half.
    Applies to pace, racecraft, starts, contacts, track limits, tyres and fuel (predicted
    drivers' latest races 3-5% better); consistency and finishing keep equal weights.
  - On GT3 about a quarter of pace grades move by one step; none by two.

## 1.0.27
- Driver grades reviewed against the league's races (how often a driver's grade on half their
  races holds on the other half):
  - Consistency, Racecraft, Clean driving and Track limits are now graded like Tyres and Fuel:
    3 = within normal variation, 4-5 and 1-2 only for drivers clearly better or worse than the
    middle of the class, judged against the class's own race-to-race spread (robust to the odd
    crash race). Before, they were split into equal fifths, which after a few races was mostly
    luck (racecraft and contacts especially).
  - The "normal variation" band is wider (1.5 standard errors instead of 1): clear calls now hold
    up 68-95% of the time instead of 59-88%.
  - Stint pace is no longer graded: it showed no repeatable difference between drivers yet (a
    coin flip). The fade figure is still read from the files.
  - Quali pace, Race pace and Finishing are unchanged: pace is reliable after 2 races.

## 1.0.26
- Driver grades: two new ones.
  - Starts: places gained or lost on the first lap, against what drivers from the same grid
    spot usually gain.
  - Stint pace: how much lap times drift over a dry stint of 10+ laps, against the class on the
    same laps (tyre and pace management).
  Both use a "normal variation" band like tyres and fuel: 4-5 and 1-2 only for clear cases.
- New report: Car balance. Each car's race pace as raced and with its drivers' own level taken
  out, so a strong car can be told from a car with strong drivers; plus the tracks where a car
  ran clearly above or below its usual level. Season filter applies.
- Track limits: an invalidated lap ("Invalid Lap Cut Track") now counts with the warnings for
  cleanliness (grades, "Warnings / lap", track grades).
- The archived results are re-read once on start to pick this up.

## 1.0.25
- Forecast: the chance that a track-limit event becomes a penalty is the same for every driver
  again (0.16% per event) instead of each driver's own penalty rate: penalties are too rare for a
  personal rate to mean much, and replaying 91 races the shared rate scored slightly better.
  Drivers with more track-limit events still get more penalties. Saved forecast settings take
  this once. Profiles and cleanliness grades are unchanged.
- Checked and kept (no measurable difference): contact and damage costs, the track-limit time
  cost, lap-to-lap scatter, random incident sizes, ageing of track history. Retirements stay on
  (clearly worse without).

## 1.0.24
- Forecast: the driver-trait x track-trait fit (hard on tyres at tyre-killer tracks, top speed at
  top-speed tracks, fuel use at fuel-hungry tracks) is off. Its effect sizes were set by hand and
  replaying 91 races it made every class worse (Brier 0.2294 -> 0.2271 predicted quali,
  0.2136 -> 0.2105 real grid with it off). Saved forecast settings take this once.

## 1.0.23
- Driver profile: Track tendencies lists only confident tendencies ("quicker" / "slower"); early
  signs are counted in the note but not shown until more races confirm them.

## 1.0.22
- Track tendencies reviewed on 91 past races. As built they made the forecast worse (GT3 only:
  the other classes rarely have one), and no version beat leaving them off, so the upgrade stays
  off. When switched on they are now applied the safer way: only confident tendencies (not early
  signs), extreme tracks capped at 1.5 standard deviations, and only at tracks where the driver
  has no history of their own (own history covers those).

## 1.0.21
- Forecast retuned on 91 past races (with current form in):
  - grid place costs 3.5 s instead of 1.2 s (real grid: Brier 0.2194 -> 0.2147, log-loss
    1.453 -> 1.291);
  - race-day noise 0.5% (was 0.6% in the saved settings);
  - Test upgrades now keeps own history at the track and current form, and drops track
    tendencies and traffic (they made it slightly worse).
  Forecast settings saved before take these values once (and the measured drive-through cost
  replaces a typed penalty size); other settings you changed stay.
- Checked and kept: quali noise 0.8%; how fast a driver's own pace takes over from the class
  average (2 races for half weight: half a race picks winners better but podiums slightly worse).

## 1.0.20
- Forecast: a penalty given mid-race costs what a drive-through costs at that track, measured from
  the drive-throughs served in the league's races (about 20 s typically; Spa about 7 s, Laguna Seca
  about 40 s), pulled towards the league's figure until a track has a few. The "Penalty size"
  setting is only used before any drive-through has been measured. Drive-throughs in the first two
  laps and those served together with a stop for fuel or tyres are left out.
- The archived results are re-read once on start to pick this up.

## 1.0.19
- Current form: each driver's race pace over their last 5 races against their own average
  (without success ballast), shown from 6 races in a class: new "Form %" column in Profiles >
  Drivers and a Current form table in the driver profile.
- Forecast: new Current form upgrade, on by default: half of each driver's form is carried into
  the next race (replaying 91 past races: Brier 0.2357 -> 0.2329 predicted quali, 0.2216 -> 0.2198
  real grid). The pace tooltip on the Predict screen shows each driver's form.
- Success ballast cost measured within each driver's season and series (ballast goes to drivers on
  form, so against their whole career it looked free): about 0.15 s per 10 kg on a 100 s lap.
- Forecast: the success ballast slowdown is off by default (still worse when replaying past races,
  with or without current form); Test upgrades can switch it on.

## 1.0.18
- Graphics: the Image menu lists the graphics in A-Z order.

## 1.0.17
- Fixed: the two season scenario pages could disagree on what the leader needs (Hyper: "P8 or
  better" on the title fight, "P6 or better" on What it takes). What it takes now checks every
  place down the field, both pages apply the same tie-break (level on points: more wins), and a
  title already settled reads "Already champion, whatever happens" on both.

## 1.0.16
- Track limits on lap 0 (formation lap and start) are no longer counted: the game's logic is
  unreliable there and its start drive-throughs are usually overturned by the stewards.

## 1.0.15
- Track limits split by what the game decided (read from the result files' text, as the decision
  codes changed between game versions): every event still counts for the forecast and the
  "Limits / lap" columns; only warnings count for cleanliness (penalties follow from them, and
  "No Further Action" costs nothing).
- Driver grades: "Clean driving" is contacts only; new "Track limits" grade from warnings per lap.
- Track grades: "Incident risk" is contacts only; new "Track limits" grade (warnings per driver
  per 10 laps). Profiles > Tracks shows how often events get warned and penalised there.
- Forecast: each driver's own track-limit penalty rate, learned from the files (backtest: level
  with the old fixed rate).
- The archived results are re-read once on start to pick this up.

## 1.0.14
- Fixed: "What it takes" on the stream size: the long status line pushed the third card off the
  image; it now wraps, and the three cards share the width equally.

## 1.0.13
- "What it takes": "a DNS" instead of "a blank" for scoring nothing.

## 1.0.12
- "What it takes": the swing at the next round (where he stands going into the next round if he
  wins with his nearest rival second, or for the leader, the other way round), the points a round
  to make up on each driver ahead, and who a DNS would let through.
- Fixed: the Hyper cards had lost most of their lines in 1.0.11.

## 1.0.11
- "What it takes" weighs every driver still in the fight, not only the leader: P2 and P3 against
  each other, and anyone further down close enough to matter. Each card says who it is ahead of
  or behind, what makes him champion at the next round (with where each rival must finish), and
  what keeps him in the fight there, rival by rival. Places beyond the class's field read
  "scores nothing"; long shots needing three rivals to falter are left out before the last round.

## 1.0.10
- Fixed: "What it takes" said a driver stays in the fight "with P25 or better" in a small class;
  it now says "as long as he scores", and "whatever happens" only when scoring nothing is safe too.

## 1.0.9
- Season scenarios: a second page, "What each needs": for each of the top 3, whether winning
  every round left is enough, what the next round means (what settles it for the leader, what
  keeps the others in it), the gap to close, and at the last round, place by place, where the
  rivals must finish. Tick the pages to save.
- The app version is shown in the sidebar and the window title.

## 1.0.8
- Race recap: pick the forecast it is judged on (automatic, ratings only, or any saved forecast).

## 1.0.7
- Season recap: tick the pages to save; the underdog comes from outside the top 3.

## 1.0.6
- Season recap: championship timeline with the turning point; comeback of the season, underdog
  and iron man awards.

## 1.0.5
- Season recap graphic and report (per series and class): champion and top 10, the season in
  numbers, awards.

## 1.0.4
- Team title fight scenarios.
- League lap records per track and class (Profiles > Layout > Records), and a race recap
  highlight when one falls.

## 1.0.3
- Success ballast caps per class (GT3 45 kg, Hypercar and LMP3 30 kg).

## 1.0.2
- Success ballast: worked out from the results, shown in the standings, used by the forecast.

## 1.0.1
- Graphics folders named after the round each image is for (`s6_r5`).

## 1.0.0
- First standalone release.
