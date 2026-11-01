#!/bin/sh
# LMU_Elo tests. Usage: tests/run_tests.sh /path/to/godot   (or set GODOT)
# Your real data is never touched: the tests use a separate data folder (LMU_Elo_tests),
# switched on by tests/override.cfg while they run.
GD="${1:-${GODOT:-godot}}"
cd "$(dirname "$0")/.." || exit 1
cp tests/override.cfg override.cfg
trap 'rm -f override.cfg' EXIT
# Last-resort time limit on top of the watchdog inside the tests (tests/watchdog.gd).
T=""
command -v timeout > /dev/null 2>&1 && T="timeout -k 10"
$T ${T:+300} "$GD" --headless --path . --import > /dev/null 2>&1
$T ${T:+900} "$GD" --headless --path . res://tests/run_tests.tscn
CODE=$?
[ "$CODE" = 124 ] && echo "STOPPED: the run went over 15 minutes and was ended." >&2
exit $CODE
