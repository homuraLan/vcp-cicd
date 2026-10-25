# VCP 三端自动构建与分发

把 [VCPToolBox](https://github.com/lioensky/VCPToolBox)、[VCPMobile](https://github.com/MRiecy/VCPMobile)、[VCPChat](https://github.com/lioensky/VCPChat) 三个上游项目的编译全部交给 GitHub Actions 托管 runner 完成，产物自动打包成 Release，再同步到局域网供日常更新。

**你不需要一台 24 小时开机的电脑，也不需要本地 runner。** 编译在 GitHub 的服务器上跑，跑完自动发布。

---

## 它做什么

```
上游仓库有新提交
      │
      ▼
GitHub Actions（托管 runner，免费额度内）
      ├── ubuntu-latest   → VCPToolBox 镜像 + VCPMobile APK
      └── windows-latest  → VCPChat 安装包
      │
      ▼
自动创建 Release，附带全部成品
      │
      ▼
你的 NAS 定时拉取 → 局域网下载页
      │
      ▼
手机 / PC 从局域网安装更新
```

## 快速开始

### 1. 确认仓库变量

进入仓库 **Settings → Secrets and variables → Actions → Variables**，确认这四项：

| 变量 | 说明 | 示例 |
| --- | --- | --- |
| `VCP_SERVER_URL` | App 首次启动时内置的服务端地址 | `http://192.168.2.100:6005` |
| `VCP_APK_URL` | 局域网 APK 下载页地址（仅用于提示文案） | `http://192.168.2.100:8090/` |

改完立即生效，不需要重新提交代码。

### 2. 手动构建一次

```bash
gh workflow run vcp-build-release.yml --repo <你的用户名>/vcp-cicd
```

或者网页 **Actions → VCP Build & Release → Run workflow**。

只构建某一端：

```bash
gh workflow run vcp-build-release.yml -f targets=mobile      # 只构建 APK
gh workflow run vcp-build-release.yml -f targets=desktop     # 只构建 Windows 客户端
gh workflow run vcp-build-release.yml -f targets=backend     # 只构建服务端
```

### 3. 下载产物

构建完成后自动出现在 **Releases** 页面，所有关节都有附件：

| 文件 | 用途 |
| --- | --- |
| `VCPMobile-latest.apk` | Android 装机 |
| `VCP聊天客户端 Setup x.y.z.exe` | Windows 安装包 |
| `vcptoolbox-xxxxxxxx.tar.gz` | 服务端镜像归档 |
| `SHA256SUMS.txt` | 校验清单 |

## 配置签名（正式分发必做）

不配置签名也能构建，但产出的是**未签名 APK**，装不上或无法覆盖旧版本。配置一次即可长期使用。

### 生成密钥

```bash
keytool -genkeypair -v \
  -keystore release.jks \
  -alias vcp \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=VCP, OU=Dev, O=Personal, L=Local, ST=Local, C=CN"
```

> **这个文件丢掉后，已安装的 App 就永远无法覆盖升级了**，请立刻备份到至少两个地方。

### 转成 Base64 并上传

Linux / macOS：

```bash
base64 -w 0 release.jks > release.jks.b64
```

Windows PowerShell：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("release.jks")) | Set-Content release.jks.b64 -NoNewline
```

进入 **Settings → Secrets and variables → Actions → Secrets**，新建四个 Secret：

| Secret 名 | 值 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `release.jks.b64` 的完整内容 |
| `ANDROID_KEY_ALIAS` | 生成时的 `-alias`，例如 `vcp` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 口令 |
| `ANDROID_KEY_PASSWORD` | 密钥口令（通常同上） |

## 局域网分发

Release 在公网，手机和 PC 平时从局域网拿更新更快。NAS 上配一个定时同步：

```bash
# 拉取最新 Release 产物
gh release download --repo <用户名>/vcp-cicd --pattern '*.apk' --dir /srv/vcpmobile/out --clobber
gh release download --repo <用户名>/vcp-cicd --pattern '*.exe' --dir /srv/vcpchat/out --clobber
```

配合一个静态文件服务（nginx 等）即可提供下载页。移动端内置的检查逻辑会读取同目录下的 `manifest.json` 判断版本。

完整的分发配置见 **[TUTORIAL.md](TUTORIAL.md)**。

## 触发方式

| 方式 | 时机 | 说明 |
| --- | --- | --- |
| `schedule` | 每 6 小时 | 检测上游是否有新提交 |
| `workflow_dispatch` | 手动 | 可指定单端、指定提交 |

> 仓库 60 天没有活动时，GitHub 会自动暂停定时工作流。进入 Actions 页面点一下 **Enable** 即可恢复，或者随便提交一次代码。

## 目录

```
.github/workflows/
  vcp-build-release.yml   托管构建流水线（三端 + 发布）
android/
  Dockerfile              可选的本地构建镜像
vcpmobile/
  build-apk.sh            APK 构建脚本（支持容器 / 宿主两种模式）
  index.html              局域网下载页
  nginx-apk.conf          下载服务配置
  init-mirror.gradle      Maven 镜像
vcpchat/
  build-chat.ps1          本地构建脚本（备用方案）
docker-compose.prod.yml   服务端运行配置
TUTORIAL.md               详细步骤教程
```

## 分支说明

| 分支 | 方案 |
| --- | --- |
| `main` | **托管 runner**，推荐。本文档描述的就是它。 |
| `self-hosted` | 自托管 runner 方案，在自己的机器上编译。需要一台常开的机器，适合内网环境或不想消耗 GitHub 额度的情况。 |

## 常见问题

**构建失败提示未配置 `VCP_SERVER_URL`**
仓库变量没建。见「快速开始」第 1 步。

**Windows 打包报 `MSB8040`**
`node-pty` 强制要求 Spectre 缓解库。workflow 里已经自动改 gyp 配置文件关掉这个检查，如果仍失败，检查上游是否改了构建脚本结构。

**打包报 `Runtime closure policy failed`**
`npm ci --omit=optional` 跳过了 `sharp` 的平台二进制。workflow 已自动补装 `@img/sharp-win32-x64`。

**APK 安装时提示应用未安装**
签名不一致。旧版本如果是别的证书签的，需要先卸载再装；确保 Secret 配置的是同一个 keystore。

**构建时间太长**
首次构建最慢（要下载 Rust 依赖、Gradle 发行包、Electron 二进制）。之后的构建会命中缓存，快很多。

## 注意

- 免费账户的 Actions 额度：公开仓库不计费，私有仓库每月 2000 分钟。Windows runner 按 2 倍计费。
- 构建产物默认保留 7 天，Release 附件长期保留。
- 服务端镜像归档较大，如果只想要镜像，可以直接在 NAS 上 `docker build`，不必走 Actions。
