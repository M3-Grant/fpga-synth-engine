# ============================================================================
#  setup.ps1 —— 队员首次配置（一键搞定）
#  用法：右键"使用 PowerShell 运行"，或在 PowerShell 里执行：
#        .\setup.ps1
# ============================================================================

$RepoUrl = "https://github.com/M3-Grant/fpga-synth-engine.git"
$CloneDir = "D:\fpga-synth-engine"

Write-Host @"
========================================================
  FPGA 合成器项目 —— 队员环境配置
  仓库：$RepoUrl
========================================================

"@ -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. Git
Write-Host "[1/5] 检查 Git ..." -ForegroundColor Yellow
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Host "  ✗ 没装 Git" -ForegroundColor Red
    Write-Host "    请先下载安装：https://git-scm.com/download/win"
    Write-Host "    装完重新运行本脚本。"
    Read-Host "`n按回车退出"
    exit 1
}
Write-Host "  ✓ $(git --version)" -ForegroundColor Green

# ------------------------------------------------------------ 2. 提交身份
Write-Host "`n[2/5] 配置你的提交身份" -ForegroundColor Yellow
$curName  = git config --global user.name 2>$null
$curEmail = git config --global user.email 2>$null

if ($curName -and $curEmail) {
    Write-Host "  当前身份：$curName <$curEmail>" -ForegroundColor Gray
    $keep = Read-Host "  沿用这个身份吗？(Y/n)"
    if ($keep -ne "n" -and $keep -ne "N") {
        Write-Host "  ✓ 保持原有身份" -ForegroundColor Green
    } else {
        $curName = $null
    }
}

if (-not $curName) {
    Write-Host "  ⚠ 必须用你自己的名字，不要用别人的，否则提交记录会混淆" -ForegroundColor Yellow
    $n = Read-Host "  你的名字（如：张某某）"
    $e = Read-Host "  你的 GitHub 邮箱"
    if ([string]::IsNullOrWhiteSpace($n) -or [string]::IsNullOrWhiteSpace($e)) {
        Write-Host "  ✗ 名字和邮箱都不能为空" -ForegroundColor Red
        Read-Host "`n按回车退出"; exit 1
    }
    git config --global user.name $n
    git config --global user.email $e
    Write-Host "  ✓ 已设置：$n <$e>" -ForegroundColor Green
}

# ------------------------------------------------------------- 3. 克隆
Write-Host "`n[3/5] 获取仓库代码" -ForegroundColor Yellow
if (Test-Path (Join-Path $CloneDir ".git")) {
    Write-Host "  目录已存在，改为拉取最新代码 ..." -ForegroundColor Gray
    Push-Location $CloneDir
    git pull 2>&1 | ForEach-Object { Write-Host "    $_" }
    Pop-Location
} elseif (Test-Path $CloneDir) {
    Write-Host "  ✗ $CloneDir 已存在但不是 Git 仓库" -ForegroundColor Red
    Write-Host "    请手动处理该目录后重试，或改 CloneDir 变量。"
    Read-Host "`n按回车退出"; exit 1
} else {
    Write-Host "  克隆到 $CloneDir ..." -ForegroundColor Gray
    git clone $RepoUrl $CloneDir 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ✗ 克隆失败。检查网络，或确认你已接受仓库邀请。" -ForegroundColor Red
        Read-Host "`n按回车退出"; exit 1
    }
}
Write-Host "  ✓ 代码已就位：$CloneDir" -ForegroundColor Green

# ------------------------------------------------------- 4. 工具链检查
Write-Host "`n[4/5] 检查仿真工具（iverilog）" -ForegroundColor Yellow
$iv = Get-Command iverilog -ErrorAction SilentlyContinue
if ($iv) {
    Write-Host "  ✓ $(iverilog -V 2>&1 | Select-Object -First 1)" -ForegroundColor Green
} else {
    foreach ($p in @("D:\Tools\iverilog\bin\iverilog.exe","C:\iverilog\bin\iverilog.exe")) {
        if (Test-Path $p) { Write-Host "  ✓ 找到：$p" -ForegroundColor Green; $iv = $p; break }
    }
}
if (-not $iv) {
    Write-Host "  ⚠ 没装 iverilog（跑仿真才需要，可以先不管）" -ForegroundColor Yellow
    Write-Host "    下载：http://bleyer.org/icarus/"
}

# ------------------------------------------------------------ 5. 完成
Write-Host @"

[5/5] 配置完成！
========================================================
  仓库位置：$CloneDir

  接下来：
    1. cd $CloneDir
    2. 阅读 CONTRIBUTING.md（协作规范，必读）
    3. 阅读 00-先看我.md（项目现状）
    4. 试跑仿真：cd code; .\run_sim_all.bat

  ⚠ 三条纪律：
    · 每次开工前先 git pull
    · 提交前先 git status 确认没把 *.vcd/*.out 加进去
    · .v 文件保存为 UTF-8 无 BOM（带 BOM 会导致编译失败）
========================================================
"@ -ForegroundColor Cyan

Read-Host "`n按回车退出"
