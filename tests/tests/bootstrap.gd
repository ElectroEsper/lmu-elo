extends Node
## Starts the test suite. Kept tiny on purpose: if run_tests.gd has an error and cannot be loaded,
## this says so and exits with code 3 instead of leaving Godot waiting forever.

func _ready() -> void:
	var script = load("res://tests/run_tests.gd")
	if script == null or not (script is GDScript) or not script.can_instantiate():
		printerr("The tests could not be loaded: tests/run_tests.gd has an error (see the message above).")
		get_tree().quit(3)
		return
	var runner := Node.new()
	runner.set_script(script)
	add_child(runner)
