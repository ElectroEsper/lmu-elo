#!/bin/sh
# LMU_Elo tests. Usage: tests/run_tests.sh /path/to/godot   (or set GODOT)
# Your real data is never touched: the tests use a separate data folder (LMU_Elo_tests),
# switched on by tests/override.cfg while they run.
GD="${1:-${GODOT:-godot}}"
cd "$(dirname "$0")/.." || exit 1
cp tests/override.cfg override.cfg
trap 'rm -f override.cfg' EXIT
"$GD" --headless --path . --import > /dev/null 2>&1
"$GD" --headless --path . res://tests/run_tests.tscn
