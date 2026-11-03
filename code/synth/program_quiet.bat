@echo off
REM ============================================================
REM  Program the SILENT bench build (touch / latency / UART live,
REM  DAC data forced to zero).  For bench work and UI bring-up
REM  without making noise.
REM  Keep ASCII only.
REM ============================================================
setlocal
set "GOWINHOME=D:\Gowin\Gowin_V1.9.11.03_Education_x64"
set "FS=%~dp0..\..\build\synth_ttp229_quiet\impl\pnr\synth_ttp229_quiet.fs"
if not exist "%FS%" (
  echo [ERROR] bitstream not found: %FS%
  echo         Run: build.ps1 -Target synth_ttp229_quiet -Program none
  pause
  exit /b 1
)
echo Programming %FS%
"%GOWINHOME%\Programmer\bin\programmer_cli.exe" --device GW2AR-18C --operation_index 2 --fsFile "%FS%"
echo.
echo Done. Board is silent (touch still updates the UI and latency panel).
pause
