# 详细配置教程

从零开始把 VCP 三端构建搬到 GitHub Actions，并把成品分发到局域网。跟着做大约 30 分钟。

目录：

1. [准备工作](#1-准备工作)
2. [改造仓库](#2-改造仓库)
3. [配置变量与密钥](#3-配置变量与密钥)
4. [第一次构建](#4-第一次构建)
5. [局域网分发](#5-局域网分发)
6. [客户端自动更新](#6-客户端自动更新)
7. [服务端部署](#7-服务端部署)
8. [日常维护](#8-日常维护)
9. [故障排查](#9-故障排查)

---

## 1. 准备工作

### 需要的账号和工具

| 项目 | 说明 |
| --- | --- |
| GitHub 账号 | 免费账户就够 |
| Git | 用于推送代码 |
| GitHub CLI（可选但强烈推荐） | 命令行操作 Actions，比点网页快很多 |

安装 `gh` 并登录：

```bash
# Windows
winget install GitHub.cli
# macOS
brew install gh
# Linux
sudo apt install gh

# 登录（浏览器授权）
gh auth login
```

确认登录成功：

```bash
gh auth status
```

### 关于构建额度

| 仓库类型 | 额度 |
| --- | --- |
| 公开仓库 | Actions 不限时长，免费 |
| 私有仓库 | 每月 2000 分钟，Windows 按 2 倍计费 |

三个项目的完整构建大约消耗：
- 服务端：10～25 分钟（靠缓存，首次更久）
- 移动端 APK：15～30 分钟（首次），之后命中缓存约 10 分钟
- 桌面端：20～40 分钟（首次，要下载 Electron）

如果仓库设为公开，这些都不计费。**建议用公开仓库。**

---

## 2. 改造仓库

### 创建仓库

```bash
# 在 GitHub 上建一个空仓库，名字随意，这里用 vcp-build
gh repo create vcp-build --public --description "VCP 三端自动构建"
```

### 准备 workflow

仓库里必须有一个 `.github/workflows/` 目录（**注意 workflows 前面的点，少写会完全不生效**），放构建流水线。

目录结构：

```
.github/workflows/vcp-build-release.yml     ← 核心流水线
vcpmobile/build-apk.sh                      ← APK 构建脚本
```

推送：

```bash
git clone https://github.com/<你>/vcp-build.git
cd vcp-build
# 复制文件进去
git add .
git commit -m "init"
git push
```

推送后打开 **Actions** 标签页，应该能看到 `VCP Build & Release`。

> 看不到工作流？确认路径是 `.github/workflows/`，不是 `github/workflows/`。

---

## 3. 配置变量与密钥

进入 **Settings → Secrets and variables → Actions**。

### Variables（仓库变量，不加密）

这些不是秘密，只是配置项：

| 变量名 | 必填 | 说明 | 示例 |
| --- | --- | --- | --- |
| `VCP_SERVER_URL` | 是 | 编进 App 的服务端地址 | `http://192.168.2.100:6005` |
| `VCP_APK_URL` | 否 | 局域网下载页，仅用于提示 | `http://192.168.2.100:8090/` |

用命令行设置：

```bash
gh variable set VCP_SERVER_URL --repo <你>/vcp-build --body "http://192.168.2.100:6005"
gh variable set VCP_APK_URL    --repo <你>/vcp-build --body "http://192.168.2.100:8090/"
```

> `VCP_SERVER_URL` 会写进 APK 的 Rust 默认配置。用户装完 App 打开就能用，不用手动填地址。

### Secrets（密钥，加密）

只有 APK 签名需要。**不配也能构建**，但产出是未签名 APK，装不上。

#### 生成签名密钥

```bash
keytool -genkeypair -v \
  -keystore release.jks \
  -alias vcp \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=VCP, OU=Dev, O=Personal, L=Local, ST=Local, C=CN"
```

会提示输入口令，记下来。

> **极其重要**：这个 `.jks` 文件丢了，已装的 App 就永远无法覆盖升级，只能让用户卸载重装。
> 生成后立刻备份到两个不同的地方（U 盘 + 网盘，或者密码管理器）。

#### 转 Base64

```bash
# Linux / macOS
base64 -w 0 release.jks > release.jks.b64

# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("release.jks")) | Set-Content release.jks.b64 -NoNewline

# Git Bash
certutil -encode release.jks release.jks.b64   # 会带首尾标记，需要手动删掉
```

#### 上传四个 Secret

```bash
gh secret set ANDROID_KEYSTORE_BASE64 --repo <你>/vcp-build < release.jks.b64
gh secret set ANDROID_KEY_ALIAS --repo <你>/vcp-build --body "vcp"
gh secret set ANDROID_KEYSTORE_PASSWORD --repo <你>/vcp-build --body "你的口令"
gh secret set ANDROID_KEY_PASSWORD --repo <你>/vcp-build --body "你的口令"
```

或者网页上逐个添加。确认：

```bash
gh secret list --repo <你>/vcp-build
```

#### 上传完删掉本地文件

```bash
shred -u release.jks release.jks.b64   # Linux
# Windows
Remove-Item release.jks,release.jks.b64
```

**但要先确保备份好了。**

---

## 4. 第一次构建

### 手动触发

```bash
gh workflow run vcp-build-release.yml --repo <你>/vcp-build
```

指定只构建某一端：

```bash
gh workflow run vcp-build-release.yml --repo <你>/vcp-build -f targets=mobile
gh workflow run vcp-build-release.yml --repo <你>/vcp-build -f targets=desktop
gh workflow run vcp-build-release.yml --repo <你>/vcp-build -f targets=backend
```

### 观察进度

```bash
# 实时跟踪
gh run watch --repo <你>/vcp-build

# 看列表
gh run list --repo <你>/vcp-build

# 只看失败的日志
gh run view --repo <你>/vcp-build --log-failed
```

网页也可以：Actions → 点进运行 → 点开 job 看实时日志。

### 拿到产物

构建成功后进入仓库 **Releases** 页面，最新一条里附带了所有文件：

| 文件 | 内容 |
| --- | --- |
| `VCPMobile-latest.apk` | Android 安装包 |
| `VCP聊天客户端 Setup x.y.z.exe` | Windows 安装包 |
| `vcptoolbox-xxxxxxxx.tar.gz` | 服务端镜像（docker save 格式） |
| `SHA256SUMS.txt` | 全部文件的校验和 |
| `manifest.json` | APK 版本信息 |

命令行下载：

```bash
gh release download --repo <你>/vcp-build --dir ./dist
```

---

## 5. 局域网分发

公网 Release 页面能下载，但局域网更快，而且离线也能用。

### 方案：NAS 定时同步 + 静态服务

#### 5.1 建目录

```bash
# 举例，路径随你
mkdir -p /srv/vcp/{apk,chat}
```

#### 5.2 同步脚本

新建 `/srv/vcp/sync.sh`：

```bash
#!/usr/bin/env bash
# 把最新 Release 产物同步到局域网目录
set -euo pipefail

REPO="<你>/vcp-build"
APK_DIR=/srv/vcp/apk
CHAT_DIR=/srv/vcp/chat

# 拉取最新 Release 的 APK 和安装包
gh release download --repo "$REPO" --pattern '*.apk' --dir "$APK_DIR" --clobber
gh release download --repo "$REPO" --pattern 'manifest.json' --dir "$APK_DIR" --clobber
gh release download --repo "$REPO" --pattern '*.exe' --dir "$CHAT_DIR" --clobber

chmod -R a+rX "$APK_DIR" "$CHAT_DIR"
echo "同步完成: $(date '+%F %T')"
```

赋予执行权限并测试：

```bash
chmod +x /srv/vcp/sync.sh
/srv/vcp/sync.sh
ls -lh /srv/vcp/apk
```

> NAS 上需要先装 `gh` 并登录一次（`gh auth login`），用只读权限的 token 就够。

#### 5.3 定时执行

```bash
# crontab -e，每 30 分钟同步一次
*/30 * * * * /srv/vcp/sync.sh >> /var/log/vcp-sync.log 2>&1
```

或者用 systemd timer。

#### 5.4 起一个静态服务

nginx 配置示例：

```nginx
server {
    listen 8090;
    server_name _;
    root /srv/vcp/apk;

    charset utf-8;

    # APK 不缓存，保证拿到最新版
    location ~* \.apk$ {
        add_header Cache-Control "no-store";
        types { }
        default_type application/vnd.android.package-archive;
    }

    # 版本清单也不缓存
    location = /manifest.json {
        add_header Cache-Control "no-store";
        default_type application/json;
    }

    location /health {
        return 200 "ok\n";
        default_type text/plain;
    }
}
```

重载 nginx 后测试：

```bash
curl -I http://127.0.0.1:8090/VCPMobile-latest.apk
curl http://127.0.0.1:8090/manifest.json
```

#### 5.5 手机访问

手机连同一个 WiFi，浏览器打开：

```
http://<NAS的IP>:8090/
```

会看到下载页，点按钮直接装。

---

## 6. 客户端自动更新

### Android

App 内置的更新检查会读取 `manifest.json`，比对 `versionCode`。只要有新版就提示。

流程：

1. 上游有新提交 → Actions 构建出新 APK
2. Release 更新 → NAS 同步脚本拉到本地
3. 用户打开 App → 读到新 `manifest.json` → 提示更新
4. 点击下载 → 从局域网服务器拉 APK → 系统安装

**前提**：新旧 APK 必须同一个签名。所以签名密钥配好后不要再换。

### Windows

VCPChat 是 Electron 应用，更新方式是下载新安装包覆盖安装。安装包通过同一个局域网服务分发。

---

## 7. 服务端部署

Release 里的 `vcptoolbox-xxxxxxxx.tar.gz` 是镜像归档。

### 在 NAS 上导入并运行

```bash
# 下载
gh release download --repo <你>/vcp-build --pattern 'vcptoolbox-*.tar.gz' --dir /tmp

# 导入镜像
gunzip -c /tmp/vcptoolbox-*.tar.gz | docker load

# 看导入的镜像名
docker images | grep vcptoolbox

# 用 compose 起服务
cd /path/to/compose
docker compose -f docker-compose.prod.yml up -d
```

### 或者直接构建（不用 Actions 产物）

如果服务端就在 NAS 上跑，本地构建更快：

```bash
git clone https://github.com/lioensky/VCPToolBox.git
cd VCPToolBox
docker build -t vcptoolbox:local .
```

健康检查：

```bash
curl -I http://127.0.0.1:6005/v1/models     # 401 表示服务正常，需要鉴权
```

---

## 8. 日常维护

### 定时构建

流水线默认每 6 小时检查一次上游。要改频率改 `vcp-build-release.yml` 里的 cron：

```yaml
on:
  schedule:
    - cron: '0 */6 * * *'    # 每 6 小时（UTC）
```

常用值：

| cron | 含义 |
| --- | --- |
| `0 */6 * * *` | 每 6 小时 |
| `0 0 * * *` | 每天零点 |
| `0 2 * * 1` | 每周一凌晨 2 点 |
| `*/30 * * * *` | 每 30 分钟 |

> **改完 cron 之后别再反复改 workflow 文件**。GitHub 的定时注册是异步的，
> 每次改文件都会把注册队列清零重来，可能几个小时才生效。
> 期间要构建就手动 `gh workflow run`。

### 防止定时任务被暂停

公开仓库 60 天没有提交时，GitHub 会自动暂停定时工作流。

恢复方法：Actions 页面点 **Enable**，或者随便提交一次。

### 清理旧 Release

Release 会越积越多。定期删掉旧的：

```bash
# 列出所有 tag
gh release list --repo <你>/vcp-build

# 删除某个
gh release delete <tag> --repo <你>/vcp-build --yes

# 删除对应 tag
git push --delete origin <tag>
```

### 轮换签名密钥（一般不需要）

只有密钥泄露才需要。换密钥意味着所有用户必须卸载重装，慎用。

---

## 9. 故障排查

### workflow 不出现 / 无法触发

**症状**：`gh workflow run` 报 404 或 `Workflow does not have 'workflow_dispatch' trigger`。

**原因**：文件不在 `.github/workflows/` 下。写成了 `github/workflows/`（少了点）。

**处理**：

```bash
ls -la .github/workflows/
gh api repos/<你>/vcp-build/actions/workflows --jq '.workflows[].path'
```

### 移动端：`未配置仓库变量 VCP_SERVER_URL`

变量没建。见[第 3 节](#3-配置变量与密钥)。

### 移动端：`Release signing is incomplete`

四个 Secret 没配全，或者 `ANDROID_KEY_ALIAS` 和生成时用的 `-alias` 不一致。

检查：

```bash
gh secret list --repo <你>/vcp-build
```

### 桌面端：`Could not find any Visual Studio installation`

托管 Windows 镜像已经切换到 Visual Studio 2026，而依赖自带的 `node-gyp` 太旧，识别不了新版本号。

流水线里已经用 `npm install -g node-gyp@latest` 处理了。如果上游改了依赖结构导致又失败，手动确认这一步还在。

### 桌面端：`MSB8040 需要缓解了 Spectre 漏洞的库`

`node-pty` 的 gyp 配置强制要求 Spectre 库。流水线会自动改两个 `*.gyp` 文件关掉这个检查。

如果失败，检查上游是否重命名了这些文件：

```
node_modules/node-pty/binding.gyp
node_modules/node-pty/deps/winpty/src/winpty.gyp
```

### 桌面端：`Runtime closure policy failed`

`npm ci --omit=optional` 跳过了 `sharp` 的平台二进制，打包时的完整性校验失败。

流水线已自动补装 `@img/sharp-win32-x64`。

### APK 装不上 / 提示"应用未安装"

**签名不一致**。已装的旧版是别的证书签的。

处理：卸载旧版再装。之后只要不换密钥就不会再发生。

查看当前 APK 的签名：

```bash
apksigner verify --print-certs VCPMobile-latest.apk
```

### 构建很慢

首次构建最慢，需要下载 Rust crates、Gradle 发行包、Electron 二进制。之后会被缓存。

想进一步加速：
- 确认 Rust 缓存和 Gradle 缓存在工作流里没被跳过
- 服务端如果不需要 Actions 构建，直接在 NAS 上 `docker build` 更快

### 额度不够用

把仓库改成公开，Actions 完全免费。

```bash
gh repo edit <你>/vcp-build --visibility public
```

---

## 附：本地编译（备用）

GitHub Actions 不可用时，可以退回本地编译。完整的自托管方案在 `self-hosted` 分支。

简要步骤：

```bash
# APK（需要 Docker 或完整 Android 工具链）
WORK=/path/to/work BUILD_MODE=host \
VCP_SERVER_URL=http://192.168.2.100:6005 \
KEY_ALIAS=vcp KEY_PASS=口令 KEYSTORE_PATH=/path/release.jks \
bash vcpmobile/build-apk.sh
```

Windows 客户端：

```powershell
$env:VCP_CHAT_DIR = "D:\vcpchat"
.\vcpchat\build-chat.ps1
```
