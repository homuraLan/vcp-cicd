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

# 程序直接装在 DeployDir 根上（E:\vcpchat\VCP聊天客户端.exe），不再多套一层 app。
#
# 代价是 DeployDir 里同时住着安装产物和部署元数据，所以下面凡是「清空安装目录」
# 的地方都必须显式跳过 $Preserved —— 否则会把 .deployed-tag / .last-pull.at
# 一起删掉，下次运行就以为从没部署过。
$InstallDir = $DeployDir

# 平铺安装时绝对不能删的条目。
#
# AppData 是用户数据（settings.json / 聊天记录 / 数据库），安装包本身不含它，
# 但它和安装产物同处一个目录，漏掉就会被当成旧版本残留清掉 —— 实测丢了整份配置。
# 其余是部署状态、回滚备份和构建工作目录。
$Preserved = @('.deployed-tag', '.last-pull.at', '.backup', 'AppData', 'src', 'out', 'logs', 'ci')

function Test-Preserved([string]$leaf) {
    return $Preserved -contains $leaf
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
#
# 下载 sha256 失败不能让整段校验静默跳过 —— 那样「校验通过」和
# 「根本没校验」看起来完全一样。缺文件就直接报错。
$sumName = "$target.sha256"
& gh release download $Tag --repo $Repo --pattern $sumName --dir $tmp 2>$null
if (-not (Test-Path (Join-Path $tmp $sumName))) {
    Log "下载校验文件 $sumName 失败"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
$expected = ((Get-Content (Join-Path $tmp $sumName) -Raw) -split '\s+')[0].ToLower()
$actual = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
if ($expected -ne $actual) {
    Log "校验失败: 期望 $expected 实际 $actual"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Log "校验通过"

# ---- 4. 备份旧版本，准备回滚 ----
# ★ 备份必须放在安装目录【外面】。
#
# 以前放 <DeployDir>\.backup，和安装目录同一棵树：
#   - NSIS 安装器会清空整个目标目录，备份跟着一起没
#   - finally 里无论如何都会把它删掉（见文件末尾）
# 结果 catch 里的「回滚」永远是空的，等于没有回滚。
# 改放到 DeployDir 的同级目录，和 vcpchat-data 并列，安装器碰不到。
$backupRoot = Join-Path (Split-Path $DeployDir -Parent) "vcpchat-deploy-backup"
$backup = $backupRoot
if (Test-Path $backup) { Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $InstallDir) {
    $existing = Get-ChildItem $InstallDir -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-Preserved $_.Name) }
    if ($existing) {
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        foreach ($item in $existing) {
            Copy-Item $item.FullName -Destination $backup -Recurse -Force -ErrorAction SilentlyContinue
        }
        Log "已备份旧版本到 $backup（$($existing.Count) 项）"
    }
}

# ---- 5. 安装 ----
$installOk = $false
try {
    if ($setup) {
        # 装之前先把旧版本清干净。
        #
        # 为什么要手动做：NSIS 卸载程序处理不了 electron 的编译残留。
        # 实测卸载后还留着 better-sqlite3 / electron-edge-js / node-pty 的
        # MSBuild 中间目录（.tlog / .obj / src 多层嵌套），
        # 下次安装就会弹 "Failed to uninstall old application files" 并以退出码 2 失败。
        # 先跑一次卸载器，再把剩下的目录整个删掉，安装才不会卡在这一步。
        $uninst = Get-ChildItem $InstallDir -Filter "Uninstall*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($uninst) {
            Log "清理旧版本"
            try {
                Start-Process -FilePath $uninst.FullName -ArgumentList "/S", "/currentuser" -Wait -PassThru -ErrorAction Stop | Out-Null
            } catch {
                Log "卸载器执行异常（继续）：$($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2
        }
        # 兜底清理：只删安装产物，保留部署元数据。
        #
        # 这里以前是 Remove-Item $InstallDir -Recurse —— 那时 InstallDir 是
        # DeployDir\app，整删安全。现在 InstallDir 就是 DeployDir 本身，
        # 整删会把 .deployed-tag / .last-pull.at / .backup 一起干掉，
        # 所以改成逐项删除并跳过 $Preserved。
        if (Test-Path $InstallDir) {
            Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-Preserved $_.Name) } |
                ForEach-Object {
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
        }
        Start-Sleep -Seconds 1

        Log "静默安装到 $InstallDir"
        # NSIS 的 /D 必须放最后、不加引号，否则会被当成参数的一部分。
        # 不指定的话装到当前身份的 %LOCALAPPDATA%\Programs\vcp-chat-desktop，
        # 服务账户和交互用户的路径不一样，等于同一台机器装出两份。
        $proc = Start-Process -FilePath $file -ArgumentList "/S", "/D=$InstallDir" -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "安装程序返回 $($proc.ExitCode)" }

        # 安装器返回 0 不代表文件真的换成了新的。
        # 实测：客户端正在运行时，exe 和 app.asar 被占用，覆盖失败，
        # 但 .pak 之类没被占用的文件照样更新了，安装器仍然返回 0。
        # 结果 tag 被写成新版本，实际主程序还是旧的，下次幂等检查直接跳过，
        # 永远修不回来。
        #
        # 不能用文件修改时间判断：安装包里的时间戳来自打包时刻，
        # 可能本来就很旧，会造成误报。改用哈希比对安装前后的实际内容。
        $exePath = Join-Path $InstallDir "VCP聊天客户端.exe"
        $asarPath = Join-Path $InstallDir "resources\app.asar"
        $before = @{}
        foreach ($f in @($exePath, $asarPath)) {
            if (Test-Path $f) { $before[$f] = (Get-FileHash $f -Algorithm SHA256).Hash }
        }
        if ($before.Count -gt 0) {
            $unchanged = @()
            foreach ($f in $before.Keys) {
                $now = (Get-FileHash $f -Algorithm SHA256).Hash
                if ($now -eq $before[$f]) { $unchanged += (Split-Path $f -Leaf) }
            }
            if ($unchanged.Count -eq $before.Count) {
                throw "安装后文件内容没有任何变化（多半是客户端还在运行占着文件）：$($unchanged -join ', ')。请退出客户端后重试。"
            }
            if ($unchanged.Count -gt 0) {
                Log "警告: 这些文件未被更新（可能仍被占用）：$($unchanged -join ', ')"
            }
        }
        Log "安装完成"
    }
    else {
        Log "解压免安装版到 $InstallDir"
        if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
        Expand-Archive -Path $file -DestinationPath $InstallDir -Force
        Log "解压完成"
    }

    # ---- 5.5. 建快捷方式 ----
    #
    # ★ 数据目录必须放在安装目录【外面】。
    #
    # 平铺后安装目录就是 DeployDir，而 NSIS 安装器写入时会清空目标目录 ——
    # 实测：脚本白名单已经保住了 .deployed-tag / .last-pull.at，
    # 但 E:\vcpchat\AppData 照样被安装器删了。白名单只管得住脚本自己的
    # Remove-Item，管不住安装器，所以「把 AppData 加进白名单」这条路走不通。
    #
    # 数据路径早先也试过放安装目录里（app\AppData），一样每次更新都丢 ——
    # 因为它在安装器的作用范围之内。唯一可靠的做法是移出去。
    #
    # 客户端 main.js 原生支持：VCPCHAT_APP_DATA_DIR 有这个值就用它，
    # 不用 exe 同级的 AppData。所以这里主动设上，而不是像以前那样清掉。
    $dataRoot = Join-Path (Split-Path $DeployDir -Parent) "vcpchat-data"
    if (-not (Test-Path $dataRoot)) {
        New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
        Log "已创建数据目录 $dataRoot"
    }

    # 旧数据在 <InstallDir>\AppData，第一次升级时搬过去
    $legacyData = Join-Path $InstallDir "AppData"
    if (Test-Path $legacyData) {
        $items = Get-ChildItem $legacyData -Force -ErrorAction SilentlyContinue
        if ($items) {
            Log "迁移旧数据 $legacyData -> $dataRoot"
            foreach ($it in $items) {
                $dest = Join-Path $dataRoot $it.Name
                # 目标已存在就不覆盖，避免把新数据盖回旧的
                if (-not (Test-Path $dest)) {
                    Copy-Item $it.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # 用户级环境变量：从资源管理器/开始菜单启动都能读到
    $prevData = [Environment]::GetEnvironmentVariable("VCPCHAT_APP_DATA_DIR", "User")
    if ($prevData -ne $dataRoot) {
        [Environment]::SetEnvironmentVariable("VCPCHAT_APP_DATA_DIR", $dataRoot, "User")
        Log "已设置 VCPCHAT_APP_DATA_DIR = $dataRoot"
    }

    $appExe = Get-ChildItem $InstallDir -Filter "*.exe" -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notmatch "^Uninstall" } |
              Sort-Object Length -Descending | Select-Object -First 1

    if ($appExe) {
        $lnkDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
        New-Item -ItemType Directory -Force -Path $lnkDir | Out-Null
        $lnkPath = Join-Path $lnkDir "VCP聊天客户端.lnk"

        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($lnkPath)
        $lnk.TargetPath = $appExe.FullName
        $lnk.WorkingDirectory = $InstallDir
        $lnk.Description = "VCP 聊天客户端"
        $lnk.Save()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws)
        Log "快捷方式已创建"
    }
    else {
        Log "警告: 安装目录里没找到主程序，跳过快捷方式"
    }

    # 5.1 的 Set-Content -Encoding utf8 会写 BOM，下次读出来带 \ufeff 就比不相等了
    [System.IO.File]::WriteAllText($stampFile, $Tag, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($pullStamp, [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
    $installOk = $true
    Log "更新完成: $Tag"
}
catch {
    Log "更新失败: $_"
    if (Test-Path $backup) {
        Log "回滚"
        Get-ChildItem $backup -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName -Destination $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    exit 1
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    # 只有装成功了才清理备份。
    # 失败时留着，方便事后把文件拿回来 —— 以前无条件删，
    # 回滚完备份就没了，真正出事时没有任何退路。
    if ($installOk -and (Test-Path $backup)) {
        Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif (Test-Path $backup) {
        Log "安装未成功，保留备份于 $backup"
    }
}
