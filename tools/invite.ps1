# ============================================================================
#  invite.ps1 —— 批量邀请队员为 GitHub 仓库协作者
#  用法：
#      .\invite.ps1                    # 交互式输入（每行一个用户名，空行结束）
#      .\invite.ps1 user1 user2 user3  # 直接传用户名
#
#  前提：已用 gh auth login 登录，且你是仓库 owner
# ============================================================================
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Users
)

$Repo = "M3-Grant/fpga-synth-engine"
$Gh   = "C:\Program Files\GitHub CLI\gh.exe"

if (-not (Test-Path $Gh)) {
    $found = Get-Command gh -ErrorAction SilentlyContinue
    if ($found) { $Gh = $found.Source }
    else { Write-Host "[错误] 找不到 gh.exe，请先安装 GitHub CLI" -ForegroundColor Red; exit 1 }
}

# ---- 没传参数就交互式输入 ----
if (-not $Users -or $Users.Count -eq 0) {
    Write-Host "请输入队员的 GitHub 用户名（每行一个，直接回车结束）：" -ForegroundColor Cyan
    $Users = @()
    while ($true) {
        $u = Read-Host "  用户名"
        if ([string]::IsNullOrWhiteSpace($u)) { break }
        $Users += $u.Trim()
    }
}

if ($Users.Count -eq 0) {
    Write-Host "没有输入任何用户名，退出。" -ForegroundColor Yellow
    exit 0
}

Write-Host "`n仓库: $Repo" -ForegroundColor Cyan
Write-Host "将邀请 $($Users.Count) 人：$($Users -join ', ')`n" -ForegroundColor Cyan

$ok = 0; $fail = 0
foreach ($u in $Users) {
    Write-Host "邀请 $u ... " -NoNewline
    $r = & $Gh api -X PUT "repos/$Repo/collaborators/$u" -f permission=push 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "已发送邀请 ✅" -ForegroundColor Green
        $ok++
    } else {
        Write-Host "失败 ❌" -ForegroundColor Red
        $r | ForEach-Object { Write-Host "    $_" }
        $fail++
    }
}

Write-Host "`n成功 $ok 人，失败 $fail 人" -ForegroundColor Cyan
Write-Host @"

【重要】邀请不是自动生效的：
  队员需要去 GitHub 查收邀请（会收到邮件），或在浏览器打开
  https://github.com/$Repo/invitations
  点 Accept 之后才能真正 push。

【提醒队员】接受邀请后，配置自己的提交身份：
  git config --global user.name "你的名字"
  git config --global user.email "你的GitHub邮箱"
  否则提交记录里全是同一个名字，评委会误判成单人作品。
"@
