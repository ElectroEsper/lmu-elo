@echo off
rem LMU_Elo tests. Usage: tests\run_tests.bat "C:\Users\elect\OneDrive\Desktop\Godot\Godot_v4.7.2-stable_win64_console.exe"
rem (or set GODOT to that path once). Your real data is never touched: the tests use a separate
rem data folder (LMU_Elo_tests in %APPDATA%), switched on by tests\override.cfg while they run.
setlocal
set "GD=%~1"
if "%GD%"=="" set "GD=%GODOT%"
if "%GD%"=="" set "GD=godot"
cd /d "%~dp0.."
copy /y "tests\override.cfg" "override.cfg" >nul
"%GD%" --headless --path . --import >nul 2>&1
"%GD%" --headless --path . res://tests/run_tests.tscn
set "RESULT=%ERRORLEVEL%"
del "override.cfg"
exit /b %RESULT%
