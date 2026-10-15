# ============================================================
#  Regression runner for fpga-synth-engine
#
#  WHY THIS EXISTS
#    run_sim_all.bat only checked the compiler/vvp EXIT CODE.
#    A testbench that prints "[FAIL]" still exits 0, so the batch
#    file happily reported "ALL SIMULATIONS PASSED" even with
#    real failures (hit on 2026-10-15: 2 hidden FAILs in
#    tb_synth_board12 after the AMP change).
#
#    This script inspects the test OUTPUT for "[FAIL]" markers,
#    so a failing check can never be reported as PASS.
#
#  Exit code : 0 = all suites passed, 1 = something failed
#  Requires  : Windows PowerShell 5.1 (no pwsh needed)
#  NOTE      : keep this file pure ASCII (PS 5.1 reads .ps1 as ANSI)
# ============================================================

$ErrorActionPreference = 'Continue'

# ---------- locate iverilog ----------
$IV = 'D:\Tools\iverilog\bin'
if (-not (Test-Path "$IV\iverilog.exe")) { $IV = 'C:\iverilog\bin' }
if (-not (Test-Path "$IV\iverilog.exe")) {
    Write-Host "[ERROR] iverilog.exe not found."
    Write-Host "        checked: D:\Tools\iverilog\bin"
    Write-Host "        checked: C:\iverilog\bin"
    exit 1
}

Set-Location $PSScriptRoot
Write-Host "iverilog : $IV"
Write-Host ""

# ---------- suite table ----------
$R = 'rtl\'
$S = 'sim\tb_'

$suites = [ordered]@{
    'i2s_tx' = @{
        out = 'sim_i2s.out'
        src = @("${R}i2s_tx.v", "${S}i2s_tx.v")
    }
    'note_alloc' = @{
        out = 'sim_alloc.out'
        src = @("${R}note_alloc.v", "${S}note_alloc.v")
    }
    'adsr' = @{
        out = 'sim_adsr.out'
        src = @("${R}adsr.v", "${S}adsr.v")
    }
    'synth_top' = @{
        out = 'sim_synth.out'
        src = @("${R}clk_div.v", "${R}i2s_tx.v", "${R}note_table.v", "${R}adsr.v",
                "${R}osc_voice.v", "${R}oscillator_array.v", "${R}note_alloc.v",
                "${R}mix_tree.v", "${R}synth_top.v", "${S}synth_top.v")
    }
    'tone_test' = @{
        out = 'sim_tone.out'
        src = @("${R}i2s_tx.v", "${R}tone_test_top.v", "${S}tone_test.v")
    }
    'synth_board' = @{
        out = 'sim_board.out'
        src = @("${R}clk_div.v", "${R}debounce.v", "${R}i2s_tx.v", "${R}note_table.v",
                "${R}adsr.v", "${R}osc_voice.v", "${R}oscillator_array.v",
                "${R}note_alloc.v", "${R}mix_tree.v", "${R}synth_top.v",
                "${R}synth_board_top.v", "${S}synth_board.v")
    }
    'led_ctrl_top' = @{
        out = 'sim_led.out'
        src = @("${R}clk_div.v", "${R}debounce.v", "${R}pwm.v",
                "${R}led_ctrl_top.v", "${S}led_ctrl_top.v")
    }
    'key_scan' = @{
        out = 'sim_keyscan.out'
        src = @("${R}debounce.v", "${R}key_scan.v", "${S}key_scan.v")
    }
    'synth_board12' = @{
        out = 'sim_board12.out'
        src = @("${R}clk_div.v", "${R}debounce.v", "${R}key_scan.v", "${R}i2s_tx.v",
                "${R}note_table.v", "${R}adsr.v", "${R}osc_voice.v",
                "${R}oscillator_array.v", "${R}note_alloc.v", "${R}mix_tree.v",
                "${R}synth_top.v", "${R}synth_board12_top.v", "${S}synth_board12.v")
    }
    'key12_notes' = @{
        out = 'sim_key12.out'
        src = @("${R}debounce.v", "${R}key_scan.v", "${S}key12_notes.v")
    }
}

$failed  = @()
$total   = $suites.Count
$idx     = 0
$bar     = '=' * 52

foreach ($name in $suites.Keys) {
    $idx++
    $s = $suites[$name]

    Write-Host $bar
    Write-Host ("  {0}/{1}  {2}" -f $idx, $total, $name)
    Write-Host $bar

    # ---- compile ----
    $compileArgs = @('-g2005', '-o', $s.out) + $s.src
    $cout = & "$IV\iverilog.exe" $compileArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [COMPILE FAILED]"
        $cout | ForEach-Object { Write-Host "    $_" }
        $failed += "$name (compile)"
        Write-Host ""
        continue
    }

    # ---- run ----
    $rout = & "$IV\vvp.exe" $s.out 2>&1
    $rout | ForEach-Object { Write-Host $_ }

    $fails = @($rout | Where-Object { $_ -match '\[FAIL\]' })
    $errs  = @($rout | Where-Object { $_ -match '\[ERROR\]' })

    if ($LASTEXITCODE -ne 0) {
        $failed += "$name (exit code $LASTEXITCODE)"
    }
    elseif ($fails.Count -gt 0) {
        $failed += ("{0} ({1} FAIL)" -f $name, $fails.Count)
    }
    elseif ($errs.Count -gt 0) {
        $failed += ("{0} ({1} ERROR)" -f $name, $errs.Count)
    }
    Write-Host ""
}

# ---------- summary ----------
Write-Host $bar
if ($failed.Count -eq 0) {
    Write-Host "  ALL SIMULATIONS PASSED   ($total suites)"
    Write-Host "  waveforms: *.vcd  (open with gtkwave)"
} else {
    Write-Host "  SOME SIMULATIONS FAILED  ($($failed.Count) of $total)"
    foreach ($f in $failed) { Write-Host "    - $f" }
}
Write-Host $bar

if ($failed.Count -gt 0) { exit 1 }
exit 0
