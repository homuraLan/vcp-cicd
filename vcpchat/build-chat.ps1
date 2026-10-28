# VCPChat Windows 构建脚本
#
# 在 Windows 本机（self-hosted runner）执行。
# Electron 打包必须在目标平台上进行：electron-builder 会下载 win32 Electron 二进制，
# 并针对当前平台重建 better-sqlite3 / node-pty / sharp 等原生模块，跨平台交叉打包不可靠。

param(
    [string]$Sha = "",
    [string]$Work = "",
    [string]$Version = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# 工作目录：优先用参数，其次环境变量 VCP_CHAT_DIR
if (-not $Work) { $Work = $env:VCP_CHAT_DIR }
if (-not $Work) { throw "请通过 -Work 参数或 VCP_CHAT_DIR 环境变量指定工作目录" }

$Src       = Join-Path $Work "src"
$Out       = Join-Path $Work "out"
$StateFile = Join-Path $Work "state.json"
$LogDir    = Join-Path $Work "logs"
$Upstream  = "https://github.com/lioensky/VCPChat.git"

New-Item -ItemType Directory -Force -Path $Work, $Out, $LogDir | Out-Null

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Log   = Join-Path $LogDir "build-$Stamp.log"

function Log($msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $Log -Value $line -Encoding UTF8
}

# ---- 确定目标版本 ----
if ($Sha) {
    $Target = $Sha
} else {
    $Target = (& git ls-remote $Upstream refs/heads/main | ForEach-Object { ($_ -split "`t")[0] })
}
if (-not $Target) { throw "无法获取上游 SHA" }
$Short = $Target.Substring(0, 8)

Log "=== VCPChat 构建开始 $Short"

# ---- 比对当前版本 ----
$Current = ""
if (Test-Path $StateFile) {
    try { $Current = (Get-Content $StateFile -Raw | ConvertFrom-Json).sha } catch {}
}
if ($Current -eq $Target -and -not $Force) {
    Log "已是最新版本 $Short，跳过构建"
    exit 0
}
Log "当前: $(if($Current){$Current.Substring(0,8)}else{'<无>'}) -> 目标: $Short"

# ---- 准备源码 ----
if (-not (Test-Path (Join-Path $Src ".git"))) {
    Log "首次克隆上游仓库（约 585MB，请耐心等待）"
    if (Test-Path $Src) { Remove-Item -Recurse -Force $Src }
    & git clone --filter=blob:none $Upstream $Src
    if ($LASTEXITCODE -ne 0) { throw "克隆失败" }
}

Push-Location $Src
try {
    Log "拉取目标提交"
    & git fetch --depth 1 origin $Target
    & git checkout -f $Target
    if ($LASTEXITCODE -ne 0) { throw "检出 $Target 失败" }

    # ---- 安装依赖 ----
    Log "安装依赖（含原生模块编译，耗时较长）"
    & npm ci --omit=optional 2>&1 | Tee-Object -FilePath $Log -Append
    if ($LASTEXITCODE -ne 0) {
        Log "npm ci 失败，回退到 npm install"
        & npm install 2>&1 | Tee-Object -FilePath $Log -Append
    }

    # ---- 修正 node-pty 的 Spectre 要求 ----
    # node-pty 及其内嵌 winpty 的 gyp 都强制 'SpectreMitigation': 'Spectre'，
    # 需要 VS 的 Spectre 缓解库（Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre）。
    # 该组件未安装时 electron-builder 的 rebuild 会以 MSB8040 失败。
    # 这里改为 'false' 跳过检查——只影响编译选项，不改任何业务代码；
    # 每次安装依赖后都重新应用，保证幂等。
    $gypFiles = @(
        (Join-Path $Src "node_modules\node-pty\binding.gyp"),
        (Join-Path $Src "node_modules\node-pty\deps\winpty\src\winpty.gyp")
    )
    foreach ($gypPath in $gypFiles) {
        if (-not (Test-Path $gypPath)) { continue }
        $gypText = Get-Content $gypPath -Raw
        if ($gypText -match "'SpectreMitigation':\s*'Spectre'") {
            $gypText = $gypText -replace "'SpectreMitigation':\s*'Spectre'", "'SpectreMitigation': 'false'"
            [System.IO.File]::WriteAllText($gypPath, $gypText, (New-Object System.Text.UTF8Encoding($false)))
            Log "已关闭 Spectre 检查: $(Split-Path $gypPath -Leaf)"
        }
    }

    # ---- 补装 sharp 的平台二进制 ----
    # npm ci --omit=optional 会跳过 sharp 的 @img/sharp-win32-x64 平台包，
    # 而 package.json 的 electron-builder hooks（afterPack）会做 runtime closure 校验，
    # 缺二进制时以 "native binary missing" 失败。这里显式补上。
    if (Test-Path (Join-Path $Src "node_modules\sharp")) {
        $imgWin = Join-Path $Src "node_modules\@img\sharp-win32-x64"
        if (-not (Test-Path $imgWin)) {
            Log "补装 sharp 的 win32-x64 二进制"
            & npm install --no-save @img/sharp-win32-x64 2>&1 | Tee-Object -FilePath $Log -Append
        }
    }

    # ---- 修正 Rust 助手配置路径 ----
    # 上游 modules/ipc/assistantHandlers.js 用 __dirname 向上两级推导配置目录：
    #     path.join(__dirname, '..', '..', 'AppData', 'rust-assistant-config.json')
    # 源码目录下 __dirname 是 <app>\modules\ipc，向上两级正好是 <app>，正确；
    # 但打包进 app.asar 后 __dirname 是 <app>\resources\app.asar\modules\ipc，
    # 向上两级落在 app.asar 这个【文件】上，fs.ensureDir() 试图在文件底下建目录，
    # 内核返回 ENOTDIR。表现是设置里保存 Rust 助手配置必然失败，填什么都一样。
    #
    # 改为向上四级：<app>\resources\app.asar\modules\ipc -> <app>
    # 与开发环境语义一致，配置落回 <app>\AppData\，和 settings.json 同目录。
    $ahPath = Join-Path $Src "modules\ipc\assistantHandlers.js"
    if (-not (Test-Path $ahPath)) {
        throw "未找到 modules\ipc\assistantHandlers.js，上游目录结构可能已变更"
    }
    $ahText = [System.IO.File]::ReadAllText($ahPath)
    $ahOld = "path.join(__dirname, '..', '..', 'AppData', 'rust-assistant-config.json')"
    $ahNew = "path.join(__dirname, '../../../../AppData', 'rust-assistant-config.json')"
    if ($ahText.Contains($ahNew)) {
        Log "Rust 助手配置路径已是修正版，跳过"
    } elseif ($ahText.Contains($ahOld)) {
        $ahText = $ahText.Replace($ahOld, $ahNew)
        [System.IO.File]::WriteAllText($ahPath, $ahText, (New-Object System.Text.UTF8Encoding($false)))
        Log "已修正 Rust 助手配置路径（ENOTDIR）：__dirname 向上 2 级 -> 4 级"
    } else {
        # 上游改写过这段就必须显式失败，别静默放过带 bug 的包
        throw "assistantHandlers.js 中未找到预期的 getRustAssistantConfigPath 实现，请检查上游是否已变更"
    }

    # ---- 构建 Rust 运行时 ----
    Log "构建 Rust 运行时组件"
    & npm run build 2>&1 | Tee-Object -FilePath $Log -Append
    if ($LASTEXITCODE -ne 0) { throw "Rust 运行时构建失败" }

    # ---- 写入版本号 ----
    # 上游 package.json 的 version 恒为 1.0.0，从不更新。
    # 不改的话安装后注册表里的「程序和功能」会一直显示 1.0.0，
    # 装完看不出是哪个版本，也就没法判断更新到底有没有生效。
    if ($Version) {
        $ver = $Version.TrimStart("v")
        # electron-builder 要求 x.y.z 三段式，日期版本要补成 2026.10.26.0 这种
        if ($ver -match '^\d{4}\.\d{2}\.\d{2}$') { $ver = "$ver.0" }

        $pkgPath = Join-Path $Src "package.json"
        $raw = Get-Content $pkgPath -Raw -Encoding utf8
        # 只替换顶层 version 那一行，别用 ConvertTo-Json 整个重写 ——
        # 那会把上游的字段顺序和格式全打乱，之后 diff 全是噪声。
        $newRaw = [regex]::Replace($raw, '("version"\s*:\s*")[^"]*(")', "`${1}$ver`${2}", 1)
        if ($newRaw -eq $raw) { throw "package.json 里没有找到 version 字段" }
        # 上游文件可能带 BOM，按无 BOM 写回避免 JSON.parse 报错
        [System.IO.File]::WriteAllText($pkgPath, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
        Log "版本号写入 $ver"
    }

    # ---- 打包 Electron ----
    Log "electron-builder 打包"
    & npm run dist 2>&1 | Tee-Object -FilePath $Log -Append
    if ($LASTEXITCODE -ne 0) { throw "electron-builder 打包失败" }

    # ---- 收集产物 ----
    $distDir = Join-Path $Src "dist"
    if (-not (Test-Path $distDir)) { throw "未找到 dist 目录" }

    $artifacts = Get-ChildItem $distDir -Include *.exe,*.msi,*.7z,*.zip -Recurse -File |
                 Where-Object { $_.Length -gt 1MB }
    if (-not $artifacts) { throw "dist 目录下没有找到安装包产物" }

    Log "收集到 $($artifacts.Count) 个产物"
    foreach ($a in $artifacts) {
        Copy-Item $a.FullName -Destination $Out -Force
        Log "  $($a.Name) ($([math]::Round($a.Length/1MB,1)) MB)"
    }

} finally {
    Pop-Location
}

# ---- 写状态 ----
$pkg = Get-Content (Join-Path $Src "package.json") -Raw | ConvertFrom-Json
$state = [ordered]@{
    sha        = $Target
    version    = $pkg.version
    built_at   = (Get-Date).ToString("o")
    artifacts  = (Get-ChildItem $Out -File | Select-Object -ExpandProperty Name)
}
$state | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding UTF8

Log "=== VCPChat 构建完成 $Short"
