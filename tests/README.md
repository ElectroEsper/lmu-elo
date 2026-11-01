# LMU_Elo tests

One command checks the whole tool: settings and race rules, the traffic formula, importing and
rating your league files, Recompute all, duplicate detection (same file, renamed copy, another
player's log of the same race), league naming, season-1 quali files, practice and training
files, profiles, grades and ranks, the predictor, and that every screen and report opens.

## Run

Windows (use the *console* build of Godot so the results show in the window):

    tests\run_tests.bat "C:\path\to\Godot_v4.7-stable_win64_console.exe"

Linux / macOS:

    tests/run_tests.sh /path/to/godot

Or set a `GODOT` environment variable to that path once and run the script without it.
Each check prints PASS / FAIL / SKIP; the last line is the total. Exit code 0 = all passed,
1 = something failed, 2 = refused to run (see below).

## Test data

Copy your league result XMLs into `tests/data/xml/` (folders inside are fine). That folder is
not committed (it holds driver names), so each person keeps their own copy. Without it the
checks that need league files are skipped and the rest still run.

## Your real data is safe

The scripts copy `tests/override.cfg` to the project folder while the tests run, which makes
Godot use a separate data folder named `LMU_Elo_tests` (wiped at the start of every run), and
remove it afterwards. The tests refuse to start if they find themselves on the real `LMU_Elo`
data folder, so starting `run_tests.tscn` straight from the editor does nothing.
If a run is interrupted and `override.cfg` is left in the project folder, delete it before
using the app (it is in `.gitignore`, so it can never be committed).
