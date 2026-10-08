@echo off
chcp 65001 >nul
cd /d "%~dp0"

REM ---------- locate iverilog ----------
set "IV=D:\Tools\iverilog\bin"
if not exist "%IV%\iverilog.exe" set "IV=C:\iverilog\bin"
if not exist "%IV%\iverilog.exe" (
    echo.
    echo [ERROR] iverilog.exe not found.
    echo   checked: D:\Tools\iverilog\bin
    echo   checked: C:\iverilog\bin
    echo.
    pause
    exit /b 1
)
echo iverilog : %IV%
echo.

set FAIL=0

REM ---------- 1/3  i2s_tx ----------
echo ============================================
echo   1/3  i2s_tx   (I2S transmitter)
echo ============================================
"%IV%\iverilog.exe" -g2005 -o sim_i2s.out rtl\i2s_tx.v sim\tb_i2s_tx.v
if errorlevel 1 (
    echo [COMPILE FAILED]
    set FAIL=1
) else (
    "%IV%\vvp.exe" sim_i2s.out
    if errorlevel 1 set FAIL=1
)
echo.

REM ---------- 2/3  tone_test_top ----------
echo ============================================
echo   2/3  tone_test_top   (440 Hz beep)
echo ============================================
"%IV%\iverilog.exe" -g2005 -o sim_tone.out rtl\i2s_tx.v rtl\tone_test_top.v sim\tb_tone_test.v
if errorlevel 1 (
    echo [COMPILE FAILED]
    set FAIL=1
) else (
    "%IV%\vvp.exe" sim_tone.out
    if errorlevel 1 set FAIL=1
)
echo.

REM ---------- 3/3  led_ctrl_top ----------
echo ============================================
echo   3/3  led_ctrl_top   (LED modes)
echo ============================================
"%IV%\iverilog.exe" -g2005 -o sim_led.out rtl\clk_div.v rtl\debounce.v rtl\pwm.v rtl\led_ctrl_top.v sim\tb_led_ctrl_top.v
if errorlevel 1 (
    echo [COMPILE FAILED]
    set FAIL=1
) else (
    "%IV%\vvp.exe" sim_led.out
    if errorlevel 1 set FAIL=1
)
echo.

REM ---------- summary ----------
echo ============================================
if "%FAIL%"=="0" (
    echo   ALL SIMULATIONS PASSED
    echo   waveforms: *.vcd   open with
    echo     C:\iverilog\gtkwave\bin\gtkwave.exe
) else (
    echo   SOME SIMULATIONS FAILED - see above
)
echo ============================================
echo.
pause
