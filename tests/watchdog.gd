class_name TestWatchdog
extends Node
## Makes sure a test run always ends. Godot never quits on its own when a test goes wrong:
## a script error kills the function that was running, anything awaiting it waits forever,
## and a loop that never ends freezes the whole program. This node watches from its own thread,
## so it keeps working even when the tests are stuck, and ends the run with exit code 4,
## saying where it was and why.
##
## Tests call progress("what is running") as they go (the runner does it in check() and
## _section()). The run is stopped when:
##   - a script error happened and nothing moved for AFTER_ERROR_SEC (the test died),
##   - nothing moved for STALL_SEC (stuck, awaiting something that never comes, or looping),
##   - the whole run took longer than TOTAL_SEC.

const EXIT_STOPPED := 4

@export var stall_sec := 90.0
@export var after_error_sec := 5.0
@export var total_sec := 600.0

var _mutex := Mutex.new()
var _thread := Thread.new()
var _catcher := ErrorCatcher.new()
var _start_ms := 0
var _last_ms := 0
var _where := "starting"
var _done := false


# Collects script errors (not ordinary push_error/warnings) as they are printed.
class ErrorCatcher extends Logger:
	var mutex := Mutex.new()
	var errors: Array[String] = []
	var last_ms := -1

	func _log_error(_function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_SCRIPT:
			return
		var text := rationale if rationale != "" else code
		mutex.lock()
		errors.append("%s  (%s:%d)" % [text, file, line])
		last_ms = Time.get_ticks_msec()
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()
	_last_ms = _start_ms
	OS.add_logger(_catcher)
	_thread.start(_watch)


func _exit_tree() -> void:
	_mutex.lock()
	_done = true
	_mutex.unlock()
	if _thread.is_started():
		_thread.wait_to_finish()
	OS.remove_logger(_catcher)


## Call whenever something finished or started; `where` names it for the report.
func progress(where: String) -> void:
	_mutex.lock()
	_last_ms = Time.get_ticks_msec()
	_where = where
	_mutex.unlock()


## Script errors seen so far (a run that survives them still counts them as failures).
func script_errors() -> Array[String]:
	_catcher.mutex.lock()
	var out: Array[String] = _catcher.errors.duplicate()
	_catcher.mutex.unlock()
	return out


func _watch() -> void:
	while true:
		OS.delay_msec(250)
		var now := Time.get_ticks_msec()
		_mutex.lock()
		var done := _done
		var last := _last_ms
		var where := _where
		_mutex.unlock()
		if done:
			return
		_catcher.mutex.lock()
		var err_ms := _catcher.last_ms
		_catcher.mutex.unlock()
		var why := ""
		if err_ms >= last and now - err_ms > after_error_sec * 1000.0:
			why = "a script error stopped the test"
		elif now - last > stall_sec * 1000.0:
			why = "nothing finished for %d s (stuck or waiting on something that never comes)" % int(stall_sec)
		elif now - _start_ms > total_sec * 1000.0:
			why = "the whole run took over %d s" % int(total_sec)
		if why != "":
			_stop(why, where)
			return


func _stop(why: String, where: String) -> void:
	var lines := PackedStringArray(["", "STOPPED: " + why, "  last step: " + where])
	var errs := script_errors()
	if not errs.is_empty():
		lines.append("  script errors:")
		for e in errs.slice(-5):
			lines.append("    " + e)
	printerr("\n".join(lines))
	# ask for a clean quit; if the main thread is frozen it never happens, so then end the process
	(func() -> void: get_tree().quit(EXIT_STOPPED)).call_deferred()
	for i in 12:
		OS.delay_msec(250)
		_mutex.lock()
		var done := _done
		_mutex.unlock()
		if done:
			return
	printerr("The program is frozen; ending it.")
	OS.kill(OS.get_process_id())
