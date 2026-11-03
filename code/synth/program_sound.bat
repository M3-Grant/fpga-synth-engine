@echo off
REM ============================================================
REM  Program the NORMAL (audible) synth_ttp229 design into SRAM.
REM  Use this after bench work with the silent build.
REM  Keep ASCII only.
REM ============================================================
setlocal
set "GOWINHOME=D:\Gowin\Gowin_V1.9.11.03_Education_x64"
set "FS=%~dp0..\..\build\synth_ttp229\impl\pnr\synth_ttp229.fs"
if not exist "%FS%" (
  echo [ERROR] bitstream not found: %FS%
  echo         Run: build.ps1 -Target synth_ttp229 -Program none
  pause
  exit /b 1
)
echo Programming %FS%
"%GOWINHOME%\Programmer\bin\programmer_cli.exe" --device GW2AR-18C --operation_index 2 --fsFile "%FS%"
echo.
echo Done. Sound is back (touch a key to hear it).
pause
