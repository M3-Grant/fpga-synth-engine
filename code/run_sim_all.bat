@echo off
REM ============================================================
REM  DEPRECATED - kept only as a double-click wrapper.
REM
REM  This file used to run 5 suites and judged success by EXIT CODE
REM  only, so it reported PASS even when a testbench printed [FAIL]
REM  (hit on 2026-10-15: 2 hidden FAILs in tb_synth_board12).
REM
REM  The real regression runner is run_sim_all.ps1 (10 suites, scans
REM  the output for [FAIL]).  This wrapper just calls it.
REM
REM  NOTE: keep this file pure ASCII and CRLF (cmd.exe reads .bat
REM        as the OEM codepage).
REM ============================================================

chcp 65001 >nul
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_sim_all.ps1"
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (echo [OK] all suites passed) else (echo [FAILED] exit code %RC%)
pause
exit /b %RC%
