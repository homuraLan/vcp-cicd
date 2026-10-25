# 自托管 runner 搭建教程

在自己机器上跑构建。跟着做大约 40 分钟。

目录：

1. [准备工作](#1-准备工作)
2. [切换分支](#2-切换分支)
3. [注册 runner](#3-注册-runner)
4. [配置变量与密钥](#4-配置变量与密钥)
5. [第一次构建](#5-第一次构建)
6. [局域网分发](#6-局域网分发)
7. [日常维护](#7-日常维护)
8. [故障排查](#8-故障排查)

---

## 1. 准备工作

### 需要的机器

| 角色 | 要求 | 装什么 |
| --- | --- | --- |
| Linux 机 | 常开，2 核 4G 起 | Docker、Git、Python 3 |
| Windows 机（可选） | 要构建桌面端才需要 | Git、Node.js 24 |

一台 Linux 机就够构建服务端和安卓。桌面端要 Windows 机器，没有就用 `main` 分支。

### 需要的工具

| 项目 | 说明 |
| --- | --- |
| GitHub 账号 | 免费账户够用 |
| Git | 推代码 |
| GitHub CLI | 强烈推荐，下面命令都用它 |

安装并登录：

```bash
gh auth login
```

> 用 `gh` 而不是 curl + token。`gh` 会把凭证存进系统钥匙串，之后不用再传 token。

---

## 2. 切换分支

本方案在 `self-hosted` 分支：

```bash
git clone https://github.com/<你>/vcp-cicd.git
cd vcp-cicd
git checkout self-hosted
```

`self-hosted` 分支的 workflow 用 `self-hosted` 标签，任务会派给**你自己的机器**。

---

## 3. 注册 runner

### Linux

在 GitHub 网页上操作：

1. 进入仓库 → **Settings** → **Actions** → **Runners**
2. 点 **New self-hosted runner** → 选 **Linux**
3. 页面上会给出下载和解压命令，照做

然后配置并安装为**用户级**服务：

```bash
# 换成页面给你的 token
./config.sh \
  --url https://github.com/<你>/vcp-cicd \
  --token <REGISTRATION_TOKEN> \
  --name <机器名> \
  --labels self-hosted,linux \
  --work _work

# 装成 systemd 用户服务，不用 root
./svc.sh install
./svc.sh start
```

让服务在未登录时也保持运行：

```bash
loginctl enable-linger $USER
```

> `config.sh --token` 那个 token 只用于注册，一小时后失效，不用保存。

要跑 Android 构建的话，把 runner 用户加进 docker 组：

```bash
sudo usermod -aG docker <你的用户>
```

改完要重新登录才生效。

### Windows

1. 仓库 → **Settings** → **Actions** → **Runners** → **New self-hosted runner** → **Windows**
2. 下载解压，用 PowerShell 执行：

```powershell
.\config.cmd --url https://github.com/<你>/vcp-cicd `
  --token <REGISTRATION_TOKEN> `
  --name <机器名> `
  --labels self-hosted,windows,local `
  --work _work
```

3. 别装成 Windows 服务，改成计划任务，绑当前用户：

```powershell
$action = New-ScheduledTaskAction -Execute "C:\actions-runner\run.cmd" -WorkingDirectory "C:\actions-runner"
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "GitHub Actions Runner" -Action $action -Trigger $trigger
```

> **为什么不用 Windows 服务**：`desktop` job 会用 `local` 标签，只有本机在线才构建。
> 装成服务会以 SYSTEM 身份跑，跟桌面环境隔开，构建 Electron 容易出权限问题。

---

## 4. 配置变量与密钥

### 仓库变量

不进密钥、可以公开的值：

```bash
gh variable set VCP_SERVER_URL --repo <你>/vcp-cicd --body "http://<内网地址>:6005"
gh variable set VCP_APK_URL    --repo <你>/vcp-cicd --body "http://<内网地址>:8090/"
```

| 变量 | 用途 |
| --- | --- |
| `VCP_SERVER_URL` | 编进 App 的默认服务端地址 |
| `VCP_APK_URL` | APK 分发地址，App 自动更新用 |
| `VCP_CI_DIR` | 服务端部署目录（仅自托管需要） |
| `VCP_MOBILE_DIR` | APK 分发目录（仅自托管需要） |
| `VCP_CHAT_DIR` | 桌面端产物目录（仅自托管需要） |
| `VCP_CHAT_SCRIPT` | 打包脚本路径 |

### 签名密钥

APK 必须签名才能覆盖升级。先生成一个：

```bash
keytool -genkeypair -v \
  -keystore release.jks \
  -alias vcpmobile \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass '<口令>' -keypass '<口令>' \
  -dname "CN=VCPMobile, OU=Dev, O=<你的名字>, C=CN"
```

上传到 Secrets：

```bash
base64 -w 0 release.jks > release.jks.b64
gh secret set ANDROID_KEYSTORE_BASE64 --repo <你>/vcp-cicd < release.jks.b64
gh secret set ANDROID_KEY_ALIAS       --repo <你>/vcp-cicd --body "vcpmobile"
gh secret set ANDROID_KEYSTORE_PASSWORD --repo <你>/vcp-cicd --body "<口令>"
gh secret set ANDROID_KEY_PASSWORD      --repo <你>/vcp-cicd --body "<口令>"
```

> **这个 keystore 和口令务必自己备份好。** 丢了就没法给已装的 App 做覆盖升级，用户只能卸载重装。
> 绝对不要提交进仓库。

### Docker Hub（可选）

要自动推镜像的话：

```bash
gh secret set DOCKERHUB_USERNAME --repo <你>/vcp-cicd --body "<Hub 用户名>"
gh secret set DOCKERHUB_TOKEN    --repo <你>/vcp-cicd --body "<Hub access token>"
```

token 在 Docker Hub → Account Settings → Security → New Access Token 生成。

---

## 5. 第一次构建

```bash
gh workflow run vcp-build-release.yml --repo <你>/vcp-cicd
```

只构建某一个：

```bash
gh workflow run vcp-build-release.yml --repo <你>/vcp-cicd -f targets=mobile
```

盯着进度：

```bash
gh run list --repo <你>/vcp-cicd --limit 5
gh run watch --repo <你>/vcp-cicd
```

构建失败看日志：

```bash
gh run view --repo <你>/vcp-cicd --log-failed
```

### 按需构建怎么工作

每次只编译上游真的变了的组件：

```
detect job 查三个上游的最新 commit
      │
      对比 state 分支上记录的 SHA
      │
      ├── 变了 → 构建
      └── 没变 → 跳过
```

第一次运行没有记录，三个全构建。之后就是按需。

想强制重建：

```bash
# 指定目标强制构建
gh workflow run vcp-build-release.yml --repo <你>/vcp-cicd -f targets=backend

# 或者指定具体提交
gh workflow run vcp-build-release.yml --repo <你>/vcp-cicd -f sha=<commit>
```

---

## 6. 局域网分发

产物落在各 runner 的工作目录下：

| 组件 | 位置 |
| --- | --- |
| APK | `$VCP_MOBILE_DIR/out/` |
| 桌面端 | `$VCP_CHAT_DIR/out/` |
| 服务端镜像 | Docker 里，tag 为 `<commit>` |

### APK 分发

用一个静态服务器把 `$VCP_MOBILE_DIR/out/` 暴露出来：

```yaml
# docker-compose.yml
services:
  apk:
    image: nginx:alpine
    ports:
      - "8090:80"
    volumes:
      - /path/to/vcpmobile/out:/usr/share/nginx/html:ro
```

手机访问 `http://<内网地址>:8090/` 就能下载。App 里的自动更新地址指向同一个位置。

### 服务端部署

镜像构建完直接在本地：

```bash
docker compose up -d
```

镜像 tag 用 commit 短 hash，回滚就是换回旧的 tag。

---

## 7. 日常维护

### 检查 runner 状态

```bash
# Linux
systemctl --user status github-runner.service

# 或者直接问 GitHub
gh api repos/<你>/vcp-cicd/actions/runners --jq '.runners[] | "\(.name) \(.status)"'
```

### runner 掉线

```bash
systemctl --user restart github-runner.service
```

`gh` 里显示 `offline` 就是没连上。检查网络、Docker 权限、磁盘空间。

### 定时构建

workflow 里配了每 6 小时检查一次：

```yaml
schedule:
  - cron: '0 */6 * * *'
```

> **GitHub 会在仓库 60 天没活动后自动停用定时任务**，到时候去 Actions 页面点一下 Enable。
> 另外改 workflow 文件会重置定时注册，生效可能要等几个小时。别反复改。

### 清理旧产物

```bash
# 删掉 7 天前的 artifact
gh api repos/<你>/vcp-cicd/actions/artifacts --jq '.artifacts[] | select(.created_at < "日期") | .id' |
  xargs -I{} gh api -X DELETE repos/<你>/vcp-cicd/actions/artifacts/{}
```

---

## 8. 故障排查

### runner 注册失败

```
Cannot configure the runner because it is already configured
```

之前注册过。删掉配置重新来：

```bash
rm -f .runner .credentials .credentials_rsaparams
./config.sh --url ... --token ... --replace
```

### Linux 上操作用户服务报 `Failed to connect to bus`

```bash
systemctl --user status ...
# Failed to connect to bus: No medium found
```

`su` 切过去时没有用户会话。加环境变量：

```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user status ...
```

### job 一直挂着不跑

看 runner 标签是否匹配：

```bash
gh api repos/<你>/vcp-cicd/actions/runners --jq '.runners[] | "\(.name): \(.labels[].name)"'
```

workflow 里 `runs-on: self-hosted, linux`，runner 必须同时有这两个标签。

`desktop` job 带 `local` 标签，Windows 机不在线就一直排队，这是设计如此。

### Linux 上 Docker 报权限错误

```
permission denied while trying to connect to the Docker daemon socket
```

runner 用户没在 docker 组：

```bash
sudo usermod -aG docker <用户>
# 重新登录
```

### Android 构建报 Maven 403

直连 Maven Central 被拒。加镜像：

```bash
mkdir -p ~/.gradle/init.d
cat > ~/.gradle/init.d/init-mirror.gradle <<'EOF'
allprojects {
    repositories {
        maven { url 'https://maven.aliyun.com/repository/public' }
        maven { url 'https://maven.aliyun.com/repository/google' }
        google()
        mavenCentral()
    }
}
EOF
```

### APK 报 `Release signing is incomplete`

Gradle 读不到签名环境变量。宿主模式下必须 export：

```bash
export ANDROID_KEYSTORE_PATH=/绝对路径/release.jks
export ANDROID_KEY_ALIAS=vcpmobile
export ANDROID_KEYSTORE_PASSWORD=<口令>
export ANDROID_KEY_PASSWORD=<口令>
```

注意这个错是在 Rust 编译**之后**才报的，前面全绿别以为没事。

### Electron 构建报 node-pty MSB8040

VS 缺 Spectre 库。改 gyp 绕过：

```powershell
(Get-Content node_modules/node-pty/binding.gyp -Raw) -replace "Spectre", "false" | Set-Content node_modules/node-pty/binding.gyp
```

`deps/winpty/src/winpty.gyp` 也要改。

### 打包报 `Runtime closure policy failed`

`sharp` 的原生二进制没装：

```powershell
npm install --no-save @img/sharp-win32-x64
```

---

<p align="center">
  <sub>上游：<a href="https://github.com/lioensky/VCPToolBox">VCPToolBox</a> · <a href="https://github.com/MRiecy/VCPMobile">VCPMobile</a> · <a href="https://github.com/lioensky/VCPChat">VCPChat</a></sub>
</p>