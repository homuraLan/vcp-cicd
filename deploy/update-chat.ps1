# VCPChat 桌面端自动更新
#
# 由 GitHub Actions 在构建完成后调用，也可以由 runner 定时轮询触发。
#
# 设计要点：
#   - 幂等：目标版本已部署就跳过
#   - 可回滚：失败时恢复到旧版本目录
#   - 从 Release 下载，不依赖 Actions 的临时产物
#   - 静默安装，装完能检测到新版本
#
# 参数：
#   -Tag        目标发布标签，如 v2026.10.25-13
#   -DeployDir  安装目录（默认取仓库变量）
#   -Repo       仓库全名

param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$DeployDir = "",
    [string]$Repo = "homuraLan/vcp-cicd"
)

$ErrorActionPreference = "Stop"

function Log($msg) {
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
}

if (-not $DeployDir) {
    $DeployDir = $env:VCP_CHAT_DIR
    if (-not $DeployDir) {
        Log "未指定部署目录，跳过"
        exit 0
    }
}

# ---- 1. 幂等检查 ----
$stampFile = Join-Path $DeployDir ".deployed-tag"
if (Test-Path $stampFile) {
    $current = (Get-Content $stampFile -Raw).Trim()
    if ($current -eq $Tag) {
        Log "已部署 $Tag，无需更新"
        exit 0
    }
    Log "当前版本: $current"
}
Log "目标版本: $Tag"

# ---- 2. 查询该发布下的安装包 ----
Log "查询发布资产"
$assets = & gh release view $Tag --repo $Repo --json assets --jq '.assets[].name' 2>&1
if ($LASTEXITCODE -ne 0) {
    # 把 gh 的真实输出打出来，别静默失败
    Log "查询发布失败: $($assets -join ' ')"
    exit 1
}
# 混进来的告警行不算资产名
$assets = @($assets | Where-Object { $_ -match '\S' -and $_ -notmatch '^(warning|gh:)' })

# 优先安装版，没有就退回免安装版
$setup = $assets | Where-Object { $_ -like "*Setup*.exe" } | Select-Object -First 1
$portable = $assets | Where-Object { $_ -like "*Portable*.zip" } | Select-Object -First 1

if (-not $setup -and -not $portable) {
    Log "该发布没有桌面端成品，跳过"
    exit 0
}

New-Item -ItemType Directory -Force -Path $DeployDir | Out-Null
$tmp = Join-Path $env:TEMP "vcpchat-update-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# ---- 3. 下载并校验 ----
$target = if ($setup) { $setup } else { $portable }
Log "下载 $target"
& gh release download $Tag --repo $Repo --pattern $target --dir $tmp
if ($LASTEXITCODE -ne 0) {
    Log "下载失败"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$file = Join-Path $tmp $target
$sizeMB = [math]::Round((Get-Item $file).Length / 1MB, 1)
Log "已下载 $sizeMB MB"

# 有校验值就核对
$sumName = "$target.sha256"
& gh release download $Tag --repo $Repo --pattern $sumName --dir $tmp 2>$null
if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $tmp $sumName))) {
    $expected = ((Get-Content (Join-Path $tmp $sumName) -Raw) -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) {
        Log "校验失败: 期望 $expected 实际 $actual"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Log "校验通过"
}

# ---- 4. 备份旧版本，准备回滚 ----
$backup = Join-Path $DeployDir ".backup"
if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
if (Test-Path $DeployDir) {
    $existing = Get-ChildItem $DeployDir -Exclude ".backup", ".deployed-tag" -ErrorAction SilentlyContinue
    if ($existing) {
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        foreach ($item in $existing) {
            Copy-Item $item.FullName -Destination $backup -Recurse -Force -ErrorAction SilentlyContinue
        }
        Log "已备份旧版本"
    }
}

# ---- 5. 安装 ----
try {
    if ($setup) {
        Log "静默安装"
        $proc = Start-Process -FilePath $file -ArgumentList "/S" -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "安装程序返回 $($proc.ExitCode)" }
        Log "安装完成"
    }
    else {
        Log "解压免安装版"
        if (-not (Test-Path $DeployDir)) { New-Item -ItemType Directory -Force -Path $DeployDir | Out-Null }
        Expand-Archive -Path $file -DestinationPath $DeployDir -Force
        Log "解压完成"
    }

    Set-Content -Path $stampFile -Value $Tag -NoNewline -Encoding utf8
    Log "更新完成: $Tag"
}
catch {
    Log "更新失败: $_"
    if (Test-Path $backup) {
        Log "回滚"
        Get-ChildItem $backup -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName -Destination $DeployDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    exit 1
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $backup) { Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue }
}
