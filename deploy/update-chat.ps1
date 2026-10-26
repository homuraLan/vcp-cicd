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
#   -Tag          目标发布标签，如 v2026.10.25-13
#   -DeployDir    安装目录（默认取仓库变量）
#   -Repo         仓库全名
#   -IntervalHours 本机多久拉一次，0 表示不自动拉（默认 168 = 一周）
#   -Force        忽略间隔，立刻拉

param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$DeployDir = "",
    [string]$Repo = "homuraLan/vcp-cicd",
    [int]$IntervalHours = 168,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Log($msg) {
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
}

# 分片并行下载。
#
# 为什么要自己写：GitHub 对单条连接有明显限速，实测单流只有 0.5 MB/s 左右，
# 四百多兆的安装包要下十六分钟。开八条连接并行能到 4 MB/s 以上，
# 同样的文件两分钟以内就完了。gh 的 download 子命令不会自己并行。
#
# 关键点：
#   - 先 HEAD 拿长度，再按 Range 切块，每块独立请求
#   - 每块失败重试几次，避免一个连接抖动就整包重来
#   - 下完必须核对总长度，短了就是没下全，直接报错
function Get-FileParallel {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [int]$Parts = 8,
        [int]$Retries = 3
    )

    # token 只发给 api.github.com。
    # 浏览器直链会跳到 release-assets.githubusercontent.com，那边不认 GitHub token，
    # 带上 Authorization 反而直接 401。
    $needAuth = $Uri -match '^https://api\.github\.com/'
    $authVal = if ($needAuth -and $env:GH_TOKEN) { "Bearer $($env:GH_TOKEN)" } else { $null }

    $head = [System.Net.HttpWebRequest]::Create($Uri)
    $head.Method = "HEAD"
    $head.Timeout = 30000
    $head.AllowAutoRedirect = $true
    $head.UserAgent = "vcp-deploy"
    if ($authVal) { $head.Headers.Add("Authorization", $authVal) }
    $hr = $head.GetResponse()
    $size = [int64]$hr.ContentLength
    $ranges = $hr.Headers["Accept-Ranges"]
    $hr.Close()

    if ($size -le 0) { throw "拿不到文件大小" }
    $mb = [math]::Round($size / 1MB, 1)

    # 服务器不支持分片就只能老实用单流
    if ($ranges -ne "bytes" -or $size -lt 8MB) {
        Log "服务器不支持分片，改用单流下载（$mb MB）"
        $single = [System.Net.HttpWebRequest]::Create($Uri)
        $single.Timeout = 60000
        $single.UserAgent = "vcp-deploy"
        if ($authVal) { $single.Headers.Add("Authorization", $authVal) }
        $sr = $single.GetResponse()
        $sr.GetResponseStream().CopyTo([System.IO.File]::Create($OutFile))
        $sr.Close()
        return
    }

    Log "分片下载 $mb MB，$Parts 路并行"

    $chunk = [int64][math]::Ceiling($size / $Parts)
    $tasks = @()
    for ($i = 0; $i -lt $Parts; $i++) {
        $from = $i * $chunk
        $to = [math]::Min($from + $chunk - 1, $size - 1)
        if ($from -ge $size) { break }
        $slice = Join-Path ([System.IO.Path]::GetDirectoryName($OutFile)) ("part{0}.tmp" -f $i)

        $tasks += Start-Job -ScriptBlock {
            param($u, $a, $b, $dest, $tries, $tok)
            $err = $null
            for ($k = 1; $k -le $tries; $k++) {
                try {
                    $req = [System.Net.HttpWebRequest]::Create($u)
                    $req.Timeout = 60000
                    $req.ReadWriteTimeout = 60000
                    $req.UserAgent = "vcp-deploy"
                    $req.AddRange($a, $b)
                    if ($tok) { $req.Headers.Add("Authorization", "Bearer $tok") }
                    $resp = $req.GetResponse()
                    $in = $resp.GetResponseStream()
                    $out = [System.IO.File]::Create($dest)
                    $buf = New-Object byte[] 131072
                    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $n)
                    }
                    $out.Close(); $in.Close(); $resp.Close()
                    $want = $b - $a + 1
                    $got = (Get-Item $dest).Length
                    if ($got -ne $want) { throw "分片长度不对: 期望 $want 实际 $got" }
                    return "ok"
                } catch {
                    $err = $_.Exception.Message
                    Start-Sleep -Seconds 2
                }
            }
            return "fail: $err"
        } -ArgumentList $Uri, $from, $to, $slice, $Retries, $(if ($authVal) { $env:GH_TOKEN } else { "" })
    }

    $null = $tasks | Wait-Job
    $results = $tasks | Receive-Job
    $tasks | Remove-Job -Force

    $bad = $results | Where-Object { $_ -ne "ok" }
    if ($bad) { throw "分片下载失败: $($bad -join '; ')" }

    # 按顺序拼回一个文件
    $out = [System.IO.File]::Create($OutFile)
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        $slice = Join-Path ([System.IO.Path]::GetDirectoryName($OutFile)) ("part{0}.tmp" -f $i)
        $bytes = [System.IO.File]::ReadAllBytes($slice)
        $out.Write($bytes, 0, $bytes.Length)
        Remove-Item $slice -Force
    }
    $out.Close()

    $finalSize = (Get-Item $OutFile).Length
    if ($finalSize -ne $size) {
        throw "拼接后大小不对: 期望 $size 实际 $finalSize"
    }
}

if (-not $DeployDir) {
    $DeployDir = $env:VCP_CHAT_DIR
    if (-not $DeployDir) {
        Log "未指定部署目录，跳过"
        exit 0
    }
}

# ---- 0. 到间隔了没有 ----
# 上游照常编译，这里管的是本机多久去拉一次。
$pullStamp = Join-Path $DeployDir ".last-pull.at"
if (-not $Force -and $IntervalHours -gt 0 -and (Test-Path $pullStamp)) {
    $lastRaw = (Get-Content $pullStamp -Raw).Trim()
    $lastAt = 0
    if ([int64]::TryParse($lastRaw, [ref]$lastAt) -and $lastAt -gt 0) {
        $gap = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) - $lastAt
        $limit = [int64]$IntervalHours * 3600
        if ($gap -lt $limit) {
            Log ("距上次拉取 {0}s，未到 {1}s（间隔 {2}h），本次跳过" -f $gap, $limit, $IntervalHours)
            exit 0
        }
    }
}

# ---- 1. 幂等检查 ----
$stampFile = Join-Path $DeployDir ".deployed-tag"
if (Test-Path $stampFile) {
    $current = (Get-Content $stampFile -Raw).Trim()
    if ($current -eq $Tag) {
        Log "已部署 $Tag，无需更新"
        # 版本没变也刷新时间戳，免得每隔一次定时就跑一遍检查
        try {
            [System.IO.File]::WriteAllText($pullStamp, [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
        } catch { }
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

# GitHub 对单连接限速，gh 的 download 只能单流，四百多兆要下十几分钟。
# 这里改成拿 asset 直链，自己分片并行下载。
try {
    # 用 release view 拿资产地址。
    # 不用 gh api + jq：那段 jq 里要嵌双引号和变量，在 5.1 里转义极易出错，
    # 一旦 gh 输出的是错误对象，取出来的是 ErrorRecord，.Trim() 直接崩。
    $raw = & gh release view $Tag --repo $Repo --json assets 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "查询发布失败" }
    $rel = $raw | ConvertFrom-Json
    $asset = @($rel.assets) | Where-Object { $_.name -eq $target } | Select-Object -First 1
    if (-not $asset) { throw "没有找到资产 $target" }

    $file = Join-Path $tmp $target
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # 公开仓库用 asset.url 直接下，浏览器地址，不需要额外换跳转。
    # 私有仓库那个地址要鉴权，退回 apiUrl 换一次 Location。
    #
    # 坑：AllowAutoRedirect=false 时 302 会让 GetResponse 直接抛 WebException，
    # 响应对象在异常里、不在返回值里。只在成功分支读 Location 会永远读到空，
    # 于是整段并行下载静默退回单流 —— 看着没报错，其实没生效。
    $realUri = $null
    if ($asset.url) { $realUri = [string]$asset.url }
    if (-not $realUri -or $asset.apiUrl) {
        $probe = [System.Net.HttpWebRequest]::Create([string]$asset.apiUrl)
        $probe.Method = "GET"
        $probe.AllowAutoRedirect = $false
        $probe.UserAgent = "vcp-deploy"
        $probe.Headers.Add("Authorization", "Bearer $($env:GH_TOKEN)")
        $probe.Accept = "application/octet-stream"
        try {
            $resp = $probe.GetResponse()
            $code = [int]$resp.StatusCode
            if ($code -ge 300 -and $code -lt 400) { $realUri = $resp.Headers["Location"] }
            $resp.Close()
        } catch [System.Net.WebException] {
            $er = $_.Exception.Response
            if ($er) {
                $code = [int]$er.StatusCode
                if ($code -ge 300 -and $code -lt 400) { $realUri = $er.Headers["Location"] }
            }
        }
    }
    if (-not $realUri) { throw "拿不到文件直链" }

    Get-FileParallel -Uri $realUri -OutFile $file -Parts 8
    $sw.Stop()
    $mb = [math]::Round((Get-Item $file).Length / 1MB, 1)
    $rate = [math]::Round($mb / [math]::Max($sw.Elapsed.TotalSeconds, 0.001), 2)
    Log "已下载 $mb MB，用时 $([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒（$rate MB/s）"
} catch {
    Log "并行下载失败（$($_.Exception.Message)），退回单流"
    & gh release download $Tag --repo $Repo --pattern $target --dir $tmp
    if ($LASTEXITCODE -ne 0) {
        Log "下载失败"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    $file = Join-Path $tmp $target
    Log "已下载 $([math]::Round((Get-Item $file).Length / 1MB, 1)) MB"
}

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
    # 状态文件不是程序的一部分，别卷进备份再回滚回去
    $existing = Get-ChildItem $DeployDir -Exclude ".backup", ".deployed-tag", ".last-pull.at" -ErrorAction SilentlyContinue
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

    # 5.1 的 Set-Content -Encoding utf8 会写 BOM，下次读出来带 \ufeff 就比不相等了
    [System.IO.File]::WriteAllText($stampFile, $Tag, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($pullStamp, [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
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
