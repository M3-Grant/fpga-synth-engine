@echo off
REM ============================================================
REM  FPGA synth - web UI launcher (serial bridge, no permission)
REM
REM  bridge_server.py opens the CH340 port itself and republishes
REM  the 576-byte frames over HTTP, so the page needs NO Web
REM  Serial permission and NO device picker.
REM
REM  Keep this file ASCII only (cmd reads .bat with OEM codepage).
REM ============================================================
setlocal
set "PORT=8080"
set "DIR=%~dp0"
set "PY=C:\Python314\python.exe"
if not exist "%PY%" set "PY=python"
set "PYTHONIOENCODING=utf-8"

set "NETSTAT=C:\Windows\System32\netstat.exe"
set "FINDSTR=C:\Windows\System32\findstr.exe"

"%NETSTAT%" -ano | "%FINDSTR%" /R /C:":%PORT% .*LISTENING" >nul 2>&1
if errorlevel 1 (
  echo [1/2] starting serial bridge on 127.0.0.1:%PORT% ...
  start "synth-bridge" /min "%PY%" "%DIR%bridge_server.py" --port %PORT%
  timeout /t 3 /nobreak >nul
) else (
  echo [1/2] port %PORT% already in use - reusing it
)

echo [2/2] opening browser ...
start "" "http://127.0.0.1:%PORT%/index.html?auto=1"

echo.
echo   Live board : http://127.0.0.1:%PORT%/index.html?auto=1   (auto)
echo   No board   : http://127.0.0.1:%PORT%/index.html?replay=frames_12notes.bin
echo   Fake data  : http://127.0.0.1:%PORT%/index.html?fake=1
echo   Web Serial : http://127.0.0.1:%PORT%/index.html          (manual, needs permission)
echo.
echo   If the page says "no bridge server", check that the serial
echo   bridge window is alive and COM port is not opened elsewhere.
echo.
pause
