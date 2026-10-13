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

REM ---------- 1/9  i2s_tx ----------
echo ============================================
echo   1/5  i2s_tx   (I2S transmitter)
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

REM ---------- 2/9  note_alloc ----------
echo ============================================
echo   2/5  note_alloc   (voice allocation)
echo ============================================
"%IV%\iverilog.exe" -g2005 -o sim_alloc.out rtl\note_alloc.v sim\tb_note_alloc.v
if errorlevel 1 (
    echo [COMPILE FAILED]
    set FAIL=1
) else (
    "%IV%\vvp.exe" sim_alloc.out
    if errorlevel 1 set FAIL=1
)
echo.

REM ---------- 3/9  adsr ----------
echo ============================================
echo   3/5  adsr   (envelope generator)
echo ============================================
"%IV%\iverilog.exe" -g2005 -o sim_adsr.out rtl\adsr.v sim\tb_adsr.v
if errorlevel 1 (
    echo [COMPILE FAILED]
    set FAIL=1
) else (
    "%IV%\vvp.exe" sim_adsr.out
    if errorlevel 1 set FAIL=1
)
echo.

REM ---------- 4/9  synth_top (integration) ----------
echo ============================================
echo   4/5  synth_top   (polyphonic integration)
echo ============================================
"%IV%\iverilog.exe" -g2005 -o sim_synth.out rtl\clk_div.v rtl\i2s_tx.v rtl\note_table.v rtl\adsr.v rtl\osc_voice.v rtl\oscillator_array.v rtl\note_alloc.v rtl\mix_tree.v rtl\synth_top.v sim\tb_synth_top.v
if errorlevel 1 (
    echo [COMPILE FAILED]
    set FAIL=1
) else (
    "%IV%\vvp.exe" sim_synth.out
    if errorlevel 1 set FAIL=1
)
echo.

REM ---------- 5/9  tone_test_top ----------
echo ============================================
echo   5/5  tone_test_top   (440 Hz beep)
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

REM ---------- 6/9  synth_board_top (board level) ----------
echo ============================================
echo   6/7  synth_board_top   (board top: keys to audio)
echo ============================================
"%IV%\iverilog.exe" -g2005 -o sim_board.out rtl\clk_div.v rtl\debounce.v rtl\i2s_tx.v rtl\note_table.v rtl\adsr.v rtl\osc_voice.v rtl\oscillator_array.v rtl\note_alloc.v rtl\mix_tree.v rtl\synth_top.v rtl\synth_board_top.v sim\tb_synth_board.v
if errorlevel 1 (
    echo [COMPILE FAILED]
    set FAIL=1
) else (
    "%IV%\vvp.exe" sim_board.out
    if errorlevel 1 set FAIL=1
)
echo.

REM ---------- 7/9  led_ctrl_top ----------
echo ============================================
echo   7/7  led_ctrl_top   (LED modes)
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

REM ---------- 8/9  key_scan (12 keys) ----------
echo ============================================
echo   7/8  key_scan   (12-key scan + event dispatch)
echo ============================================
"%IV%\iverilog.exe" -g2005 -o sim_keyscan.out rtl\debounce.v rtl\key_scan.v sim\tb_key_scan.v
if errorlevel 1 (
    echo [COMPILE FAILED]
    set FAIL=1
) else (
    "%IV%\vvp.exe" sim_keyscan.out
    if errorlevel 1 set FAIL=1
)
echo.

REM ---------- 9/9  synth_board12_top (12-key board) ----------
echo ============================================
echo   8/8  synth_board12_top   (12-key playable board)
echo ============================================
"%IV%\iverilog.exe" -g2005 -o sim_board12.out rtl\clk_div.v rtl\debounce.v rtl\key_scan.v rtl\i2s_tx.v rtl\note_table.v rtl\adsr.v rtl\osc_voice.v rtl\oscillator_array.v rtl\note_alloc.v rtl\mix_tree.v rtl\synth_top.v rtl\synth_board12_top.v sim\tb_synth_board12.v
if errorlevel 1 (
    echo [COMPILE FAILED]
    set FAIL=1
) else (
    "%IV%\vvp.exe" sim_board12.out
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
