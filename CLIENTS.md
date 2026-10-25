# VCP 三端构建与分发

VCPToolBox 服务端、VCPMobile 移动端、VCPChat 桌面端的自动构建与分发链路。

两套 self-hosted runner，全程出站连接，不需要任何入站端口或公网 IP。

| 组件 | 仓库 | 构建机器 | 产物 |
| --- | --- | --- | --- |
| 服务端 | [lioensky/VCPToolBox](https://github.com/lioensky/VCPToolBox) | NAS（Linux） | Docker 镜像，直接部署 |
| 移动端 | [MRiecy/VCPMobile](https://github.com/MRiecy/VCPMobile) | NAS（Linux 容器交叉编译） | Android APK，局域网分发 |
| 桌面端 | [lioensky/VCPChat](https://github.com/lioensky/VCPChat) | 本机（Windows） | Electron 安装包 |

## 为什么桌面端必须在本机构建

VCPChat 是 Electron 应用，`electron-builder` 打包时要：

- 下载 **win32** 版 Electron 二进制
- 针对当前平台重建 `better-sqlite3`、`node-pty`、`sharp`、`sherpa-onnx-node` 等原生模块

这两步都无法在 Linux 上可靠地交叉完成。所以桌面端交给 Windows 本机的 runner。

移动端不同：Tauri + Rust 是真正的交叉编译，上游自己就在 `ubuntu-22.04` 上出 APK，所以 NAS 上用容器编译即可。

## Runner

| 名称 | 系统 | 标签 | 用途 |
| --- | --- | --- | --- |
| `linux` 型 | Linux | `self-hosted, linux` | 服务端 + 移动端 |
| `windows` 型 | Windows | `self-hosted, local, windows` | 桌面端 |

本机 runner 装成计划任务（`VCP Actions Runner`），登录即启动。它不在线时，`desktop` job 会一直排队，不会误派到 NAS —— 这就是「本机上线才更新」的实现方式。

## 触发方式

`schedule: cron '*/5 * * * *'`，每 5 分钟比对一次上游 `main` 的 SHA。三个 job 各自和本地 `state.json` 比对，SHA 没变就立即跳过（约 16 秒）。

也可以 `workflow_dispatch` 手动触发，支持：

- `sha`：指定提交
- `force`：强制重建
- `targets`：`all` / `backend` / `mobile` / `desktop`

> **改动 workflow 文件会重置 GitHub 的 schedule 注册队列**，重新排队可能要几十分钟到几小时。改完就不要再动，需要立即生效时用 `workflow_dispatch`。

## 移动端：配置注入

APK 首次启动就要能连上服务端，不想让用户手填地址。

注入方式是改 Rust 侧默认值，**不改任何业务逻辑**：

```
src-tauri/src/vcp_modules/infra/settings_manager.rs
-  vcp_server_url: "".to_string(),
+  vcp_server_url: "<服务端地址>".to_string(),
```

只影响默认值，用户在设置界面仍然可以随时改。每次构建前 `git checkout` 还原，再重新注入，保证幂等。

`versionCode` 会加偏移量（`VERSION_CODE_OFFSET`），确保每次构建都能覆盖安装。

改动总量：2 个文件 6 行。

## 移动端：构建

`$VCP_MOBILE_DIR/build-apk.sh`，在 `vcpmobile-android` 镜像里跑。

镜像基于 `eclipse-temurin:17-jdk`，锁定了上游 `.github/toolchain.env` 的版本：

```
NODE_VERSION=24.14.1
PNPM_VERSION=12.6.0
JAVA_VERSION=17
ANDROID_COMPILE_SDK_VERSION=36
ANDROID_BUILD_TOOLS_VERSION=36.0.0
NDK_VERSION=29.0.14206865
```

流程：`pnpm install` → `tauri android init` → `tauri android build --apk --target aarch64`。

### 两个必须处理的坑

**Maven 403。** 国内直连 `repo.maven.apache.org` 会返回 403，Gradle 拉不到 Kotlin 插件。用 `init-mirror.gradle` 通过 Gradle init script 注入阿里云镜像，不改上游文件。

**Gradle 发行包下载慢。** 官方 `services.gradle.org` 太慢。从阿里云镜像下好 132MB 的 `gradle-8.14.3-bin.zip`，校验 SHA256 后放进 `gradle-home/wrapper/dists/`，后续构建直接复用。

### 签名

`Release signing is incomplete` 会在 Rust 编译、前端构建都通过之后才报出来，容易误以为是编译失败。

签名密钥放在 `$VCP_MOBILE_DIR/keys/vcpmobile.jks`（权限 600，不进 git），通过环境变量传给 Gradle：

```
ANDROID_KEYSTORE_PATH / ANDROID_KEY_ALIAS
ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_PASSWORD
```

## 移动端：分发

独立 nginx 实例，服务 `vcp-apk-dist.service`，监听 **8090**。

```
<分发地址>/                       下载页（手机浏览器直接用）
<分发地址>/manifest.json          版本清单
<分发地址>/VCPMobile-latest.apk
```

`VCPMobile-latest.apk` 是固定文件名，App 端不需要跟着版本号改地址。`manifest.json` 里带 `version`、`versionCode`、`sha256`，App 用它判断要不要更新。

用独立 nginx 实例而不是 fnOS 自带的：fnOS 的 nginx 不受 systemd 管理，改配置容易影响到其他服务。

## 桌面端：构建

`build-chat.ps1`（路径通过 `VCP_CHAT_SCRIPT` 变量注入），由本机 runner 调用。

流程：`git fetch` 目标 SHA → `npm ci --omit=optional` → 修正原生模块编译配置 → `npm run build`（Rust 运行时）→ `npm run dist`（electron-builder）→ 产物收进 `$VCP_CHAT_DIR/out`。

当前 SHA 记录在 `$VCP_CHAT_DIR/state.json`，和上游一致时直接退出。

## 目录

各目录的实际位置由仓库变量指定，以下用变量名表示。

服务端机器（`VCP_CI_DIR`）：

```
$VCP_CI_DIR/          服务端构建脚本与状态
```

移动端（`VCP_MOBILE_DIR`）：

```
$VCP_MOBILE_DIR/
  ├── src/             VCPMobile 源码
  ├── out/             APK + manifest + 下载页
  ├── keys/            签名密钥（600，不进 git）
  ├── gradle-home/     Gradle 缓存（含预置发行包）
  ├── gradle-init/     Maven 镜像 init script
  ├── template/        下载页模板
  └── logs/
```

桌面端（`VCP_CHAT_DIR` / `VCP_CHAT_SCRIPT`）：

```
$VCP_CHAT_DIR/
  ├── src/             VCPChat 源码
  ├── out/             安装包
  ├── state.json
  └── logs/
$VCP_CHAT_SCRIPT       构建脚本
```

## 仓库变量

workflow 不写死任何路径或地址，全部从这里读：

| 变量 | 含义 |
| --- | --- |
| `VCP_CI_DIR` | 服务端 CI 工作目录 |
| `VCP_MOBILE_DIR` | 移动端工作目录 |
| `VCP_CHAT_DIR` | 桌面端工作目录 |
| `VCP_CHAT_SCRIPT` | 桌面端构建脚本路径 |
| `VCP_APK_URL` | 移动端分发地址 |

在仓库 Settings → Secrets and variables → Actions → Variables 里配置。

## 排错

**构建卡住不动。** Gradle 下载或 Maven 解析会长时间无输出，看 `docker stats` 的 CPU：接近 0 说明在等网络，不是死锁。

**APK 下载页 403。** fnOS 下新建目录常是 `d---------`，`chmod -R u+rwX,go+rX` 即可。脚本每次构建后会自动修。

**本机 runner 没接单。** 检查计划任务状态 `Get-ScheduledTask -TaskName "VCP Actions Runner"`，以及 GitHub 上 runner 是否 online。runner 离线期间的 job 会排队等待。

**schedule 不触发。** 先看 `GET /repos/<owner>/vcp-cicd/actions/runs` 里有没有 `event: schedule`。如果刚改过 workflow 文件，需要等注册队列；仓库 60 天无活动也会被自动禁用。
