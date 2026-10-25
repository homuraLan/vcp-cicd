# 把本机 GitHub Actions runner 装成 Windows 服务
#
# 背景：
#   原来用计划任务跑 run.cmd，里面的 Runner.Listener.exe 是前台进程，
#   所以一直挂着一个黑窗口。
#
#   注意 RunnerService.exe 不能带 create 参数调用 —— 它任何参数都不认，
#   一调就进服务主机模式空转，报「必须首先安装 Windows 服务」。
#   runner 2.338 的正确做法是 config.cmd 加 --runasservice，
#   安装器会注册服务并生成 .service 文件。
#
# 用法：管理员 PowerShell 里执行
#   powershell -ExecutionPolicy Bypass -File D:\code\vcp-deploy\deploy\install-runner-service.ps1
#
# token 会自动用 gh 取，取不到会提示你手动粘贴。

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$RunnerDir = "E:\actions-runner"
$RepoUrl   = "https://github.com/homuraLan/vcp-cicd"
$TaskName  = "VCP Actions Runner"

function Log($msg) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" }

Write-Host "==== 把 runner 装成 Windows 服务 ====" -ForegroundColor Cyan
Write-Host ""

# ---- 1. 停掉旧的计划任务和残留进程 ----
Log "清理计划任务"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Log "已删除计划任务: $TaskName"
}
else {
    Log "没有计划任务，跳过"
}

Log "停止残留进程"
$procs = Get-Process Runner.Listener, Runner.Worker, RunnerService -ErrorAction SilentlyContinue
if ($procs) {
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Log "已停止 $($procs.Count) 个进程"
}

# ---- 2. 取 registration token ----
Log "获取 registration token"
$token = ""
try {
    $token = (& gh api -X POST "repos/homuraLan/vcp-cicd/actions/runners/registration-token" --jq ".token" 2>$null)
}
catch {
    $token = ""
}

if (-not $token) {
    Write-Host "自动获取失败（gh 可能没登录）" -ForegroundColor Yellow
    Write-Host "打开这个页面，复制命令里 --token 后面那串：" -ForegroundColor Yellow
    Write-Host "  $RepoUrl/settings/actions/runners/new" -ForegroundColor White
    $token = Read-Host "粘贴 token"
}
if (-not $token) {
    Write-Host "没有 token，退出" -ForegroundColor Red
    exit 1
}
Log "token 已就绪"

# ---- 3. 用服务模式重新配置 ----
# 已注册的必须先进移除，否则 config 会报 already configured
if (Test-Path (Join-Path $RunnerDir ".runner")) {
    Log "检测到已注册，先移除（_work 目录会保留）"
    Push-Location $RunnerDir
    & ".\config.cmd" remove --token $token 2>&1 | Out-Host
    Pop-Location
    Start-Sleep -Seconds 2
}

Log "以服务模式注册"
Push-Location $RunnerDir
& ".\config.cmd" --url $RepoUrl --token $token --name $env:COMPUTERNAME --labels "self-hosted,windows,local" --work _work --runasservice --unattended 2>&1 | Out-Host
$configOk = $LASTEXITCODE -eq 0
Pop-Location

if (-not $configOk) {
    Write-Host ""
    Write-Host "config.cmd 返回 $LASTEXITCODE" -ForegroundColor Red
    Write-Host "如果提示 already configured，先手动移除：" -ForegroundColor Yellow
    Write-Host "  cd $RunnerDir" -ForegroundColor White
    Write-Host "  .\config.cmd remove --token <token>" -ForegroundColor White
    exit 1
}

# ---- 4. 验证服务 ----
Start-Sleep -Seconds 5
$svc = Get-CimInstance Win32_Service | Where-Object { $_.PathName -like "*actions-runner*" } | Select-Object -First 1

Write-Host ""
if (-not $svc) {
    Write-Host "服务没注册上。看日志：" -ForegroundColor Red
    Write-Host "  Get-ChildItem $RunnerDir\_diag | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Tail 40"
    exit 1
}

Write-Host "==== 服务状态 ====" -ForegroundColor Cyan
$svc | Format-List Name, State, StartMode, StartName | Out-String | Write-Host

if ($svc.State -ne "Running") {
    Log "启动服务"
    Start-Service -Name $svc.Name
    Start-Sleep -Seconds 8
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'"
    $svc | Format-List Name, State | Out-String | Write-Host
}

if ($svc.StartMode -ne "Auto") {
    Set-Service -Name $svc.Name -StartupType Automatic
    Log "已设为开机自启"
}

# ---- 5. 等 GitHub 显示 online ----
Log "等待 runner 连上 GitHub"
$online = $false
for ($i = 1; $i -le 15; $i++) {
    Start-Sleep -Seconds 5
    $st = & gh api repos/homuraLan/vcp-cicd/actions/runners --jq '.runners[] | "\(.name) \(.status)"' 2>$null
    if ($st -match "online") { $online = $true; Write-Host $st }
}

Write-Host ""
if ($online) {
    Write-Host "完成。runner 已作为服务运行，没有黑窗口，开机自启，不用登录。" -ForegroundColor Green
}
else {
    Write-Host "服务在跑，但 GitHub 还没显示 online，等一分钟查：" -ForegroundColor Yellow
    Write-Host "  gh api repos/homuraLan/vcp-cicd/actions/runners" -ForegroundColor White
}
