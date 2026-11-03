#Requires -Version 5.1
<#
    Gowin build / program helper for fpga-synth-engine
    Board : Sipeed Tang Nano 20K  (GW2AR-LV18QN88C8/I7, 27 MHz)

    Usage :
        .\build.ps1 -Target tone_test
        .\build.ps1 -Target tone_test     -Program sram
        .\build.ps1 -Target synth_board12 -Program sram

    NOTE (important) :
        Pins 54/55/56 are SSPI dual-purpose pins on GW2AR-18. Without
        "set_option -use_sspi_as_gpio 1" place&route fails with
            ERROR (PR2017) ... dedicated pin (SSPI)
        This script always emits that option.
#>
param(
    [ValidateSet('tone_test', 'chord_demo', 'synth_board12', 'synth_board', 'self_test_12notes', 'self_test_square', 'synth_ttp229', 'synth_ttp229_quiet', 'ttp229_debug', 'self_test_uart', 'self_test_flute', 'self_test_organ', 'self_test_marimba', 'self_test_ks')]
    [string]$Target = 'tone_test',

    [ValidateSet('none', 'sram', 'flash')]
    [string]$Program = 'none',

    [string]$GowinHome   = $env:GOWINHOME,
    [string]$Device      = 'GW2AR-LV18QN88C8/I7',
    [string]$DeviceShort = 'GW2AR-18C'
)

$ErrorActionPreference = 'Stop'

# ---------- auto-detect Gowin installation (keep this file ASCII only) ----------
if (-not $GowinHome -or -not (Test-Path $GowinHome)) {
    $cands = @()
    if ($env:GOWINHOME) { $cands += $env:GOWINHOME }
    foreach ($d in @('C','D','E','F')) {
        $cands += "${d}:\Gowin\Gowin_V1.9.11.03_Education_x64"
        $cands += "${d}:\Program Files\Gowin\Gowin_V1.9.11.03_Education_x64"
        $cands += "${d}:\Program Files (x86)\Gowin\Gowin_V1.9.11.03_Education_x64"
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path (Join-Path $c 'IDE\bin\gw_sh.exe'))) { $GowinHome = $c; break }
    }
}
if (-not $GowinHome -or -not (Test-Path $GowinHome)) {
    throw "Gowin installation not found. Pass -GowinHome '<dir containing IDE\bin\gw_sh.exe>' or set GOWINHOME."
}
$env:GOWINHOME = $GowinHome
Write-Host "Gowin    : $GowinHome"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$rtlDir   = Join-Path $repoRoot 'code\rtl'
$cstDir   = Join-Path $repoRoot 'code\constraints'
$buildDir = Join-Path $repoRoot "build\$Target"

$targets = @{
    'tone_test' = @{
        Top = 'tone_test_top'
        Rtl = @('i2s_tx.v', 'tone_test_top.v')
        Cst = 'tone_test.cst'
    }
    'chord_demo' = @{
        Top = 'chord_demo_top'
        Rtl = @('i2s_tx.v', 'note_table.v', 'adsr.v', 'osc_voice.v',
                'oscillator_array.v', 'note_alloc.v', 'mix_tree.v',
                'piano_engine.v', 'synth_top.v', 'chord_demo_top.v')
        Cst = 'tone_test.cst'   # same port map as tone_test_top, reuse its constraint
    }
    'synth_board12' = @{
        Top = 'synth_board12_top'
        Rtl = @('clk_div.v', 'debounce.v', 'key_scan.v', 'i2s_tx.v', 'note_table.v',
                'adsr.v', 'osc_voice.v', 'oscillator_array.v', 'note_alloc.v',
                'mix_tree.v', 'piano_engine.v', 'synth_top.v', 'ir_gesture.v',
                'synth_board12_top.v')
        Cst = 'synth_board12.cst'
    }
    'synth_board' = @{
        Top = 'synth_board_top'
        Rtl = @('clk_div.v', 'debounce.v', 'i2s_tx.v', 'note_table.v',
                'adsr.v', 'osc_voice.v', 'oscillator_array.v', 'note_alloc.v',
                'mix_tree.v', 'piano_engine.v', 'synth_top.v', 'synth_board_top.v')
        Cst = 'synth_board.cst'
    }
    # Minimal bring-up self test: auto-cycles 12 piano notes, no keys/IR needed
    'self_test_ks' = @{
        Top = 'self_test_ks'
        Rtl = @('i2s_tx.v', 'note_table.v', 'karplus_strong.v', 'self_test_ks.v')
        Cst = 'tone_test.cst'
    }
    'self_test_marimba' = @{
        Top = 'self_test_marimba'
        Rtl = @('i2s_tx.v', 'note_table.v', 'piano_engine.v', 'self_test_marimba.v')
        Cst = 'tone_test.cst'
    }
    'self_test_organ' = @{
        Top = 'self_test_organ'
        Rtl = @('i2s_tx.v', 'note_table.v', 'piano_engine.v', 'self_test_organ.v')
        Cst = 'tone_test.cst'
    }
    'self_test_flute' = @{
        Top = 'self_test_flute'
        Rtl = @('i2s_tx.v', 'note_table.v', 'piano_engine.v', 'self_test_flute.v')
        Cst = 'tone_test.cst'
    }
    'self_test_12notes' = @{
        Top = 'self_test_12notes'
        Rtl = @('i2s_tx.v', 'note_table.v', 'piano_engine.v', 'self_test_12notes.v')
        Cst = 'tone_test.cst'
    }
    # Square-wave control test: same 12-note sequence, no piano engine at all
    'self_test_square' = @{
        Top = 'self_test_square'
        Rtl = @('i2s_tx.v', 'note_table.v', 'self_test_square.v')
        Cst = 'tone_test.cst'
    }
    # TTP229 16-key piano module (2-wire serial) - full synth
    'synth_ttp229' = @{
        Top = 'synth_ttp229_top'
        Rtl = @('clk_div.v', 'debounce.v', 'key_scan.v', 'ir_gesture.v', 'i2s_tx.v',
                'note_table.v', 'adsr.v', 'osc_voice.v', 'oscillator_array.v',
                'note_alloc.v', 'mix_tree.v', 'piano_engine.v', 'synth_top.v',
                'ttp229_scan.v', 'uart_stream.v', 'uart_rx.v', 'ui_cmd.v', 'karplus_strong.v', 'ks_array.v', 'latency_meter.v', 'synth_ttp229_top.v')
        Cst = 'synth_ttp229.cst'
    }
    # Same as synth_ttp229 but DAC data stuck at 0 -> silent bench firmware.
    # Touch / latency / UART frames still fully live for web-UI bring-up.
    'synth_ttp229_quiet' = @{
        Top = 'synth_ttp229_quiet_top'
        Rtl = @('clk_div.v', 'debounce.v', 'key_scan.v', 'ir_gesture.v', 'i2s_tx.v',
                'note_table.v', 'adsr.v', 'osc_voice.v', 'oscillator_array.v',
                'note_alloc.v', 'mix_tree.v', 'piano_engine.v', 'synth_top.v',
                'ttp229_scan.v', 'uart_stream.v', 'uart_rx.v', 'ui_cmd.v', 'karplus_strong.v', 'ks_array.v', 'latency_meter.v', 'synth_ttp229_top.v', 'synth_ttp229_quiet_top.v')
        Cst = 'synth_ttp229.cst'
    }
    # TTP229 bit-mapping debug: press a key, LEDs show its bit number
    'ttp229_debug' = @{
        Top = 'ttp229_debug'
        Rtl = @('ttp229_scan.v', 'ttp229_debug.v')
        Cst = 'ttp229_debug.cst'
    }
    'self_test_uart' = @{
        Top = 'self_test_uart'
        Rtl = @('i2s_tx.v', 'note_table.v', 'piano_engine.v', 'uart_stream.v', 'self_test_uart.v')
        Cst = 'synth_uart.cst'
    }
}

$t = $targets[$Target]
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

function ConvertTo-TclPath([string]$p) { return ($p -replace '\\', '/') }

# ---------- generate the Tcl build script ----------
$lines = @()
$lines += "set_device $Device"
$lines += "set_option -top_module $($t.Top)"
$lines += "set_option -output_base_name $Target"
$lines += "set_option -use_sspi_as_gpio 1"

foreach ($f in $t.Rtl) {
    $full = Join-Path $rtlDir $f
    if (-not (Test-Path $full)) { throw "missing rtl file: $full" }
    $lines += "add_file {$(ConvertTo-TclPath $full)}"
}

$cstFull = Join-Path $cstDir $t.Cst
if (-not (Test-Path $cstFull)) { throw "missing constraint file: $cstFull" }
$lines += "add_file {$(ConvertTo-TclPath $cstFull)}"
$lines += "run all"

$tclFile = Join-Path $buildDir "$Target.tcl"
Set-Content -Path $tclFile -Value $lines -Encoding ASCII

Write-Host "=== Tcl build script ===" -ForegroundColor Cyan
$lines | ForEach-Object { Write-Host "    $_" }

# ---------- run synthesis + place & route ----------
Write-Host "=== gw_sh (synthesize + place&route + bitstream) ===" -ForegroundColor Cyan
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $buildDir
try {
    & (Join-Path $GowinHome 'IDE\bin\gw_sh.exe') $tclFile 2>&1 |
        ForEach-Object { Write-Host $_ }
} finally {
    Pop-Location
    $ErrorActionPreference = $saved
}

$fs = Join-Path $buildDir "impl\pnr\$Target.fs"
if (-not (Test-Path $fs)) { throw "bitstream NOT generated: $fs" }

$mb = [math]::Round((Get-Item $fs).Length / 1MB, 2)
Write-Host "=== bitstream OK : $fs  ($mb MB) ===" -ForegroundColor Green

# ---------- optional programming ----------
if ($Program -ne 'none') {
    # operation_index 2 = SRAM Program (volatile)
    # operation_index 9 = exFlash Erase,Program,Verify (persistent)
    $opIdx = if ($Program -eq 'sram') { 2 } else { 9 }

    Write-Host "=== programming : $Program (operation_index=$opIdx) ===" -ForegroundColor Cyan
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & (Join-Path $GowinHome 'Programmer\bin\programmer_cli.exe') `
            --device $DeviceShort --operation_index $opIdx --fsFile $fs 2>&1 |
            ForEach-Object { Write-Host $_ }
    } finally {
        $ErrorActionPreference = $saved
    }
}

Write-Host "=== DONE ===" -ForegroundColor Green
