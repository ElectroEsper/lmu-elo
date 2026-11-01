extends Node
## Starts the test suite under a watchdog (tests/watchdog.gd), so a run always ends:
##   exit 3 = tests/run_tests.gd has an error and could not be loaded,
##   exit 4 = stopped by the watchdog (a script error killed a test, or it got stuck).

var watchdog: TestWatchdog


func _ready() -> void:
	watchdog = TestWatchdog.new()
	add_child(watchdog)
	var script = load("res://tests/run_tests.gd")
	if script == null or not (script is GDScript) or not script.can_instantiate():
		printerr("The tests could not be loaded: tests/run_tests.gd has an error (see the message above).")
		get_tree().quit(3)
		return
	var runner := Node.new()
	runner.set_script(script)
	add_child(runner)
