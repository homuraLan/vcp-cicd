# VCP 全家桶 · 自动构建分发

<p align="center">
  <img src="https://img.shields.io/badge/VCPToolBox-Docker-2496ED?style=flat-square&logo=docker&logoColor=white" alt="VCPToolBox">
  <img src="https://img.shields.io/badge/VCPMobile-Android-3DDC84?style=flat-square&logo=android&logoColor=white" alt="VCPMobile">
  <img src="https://img.shields.io/badge/VCPChat-Windows-0078D4?style=flat-square&logo=windows&logoColor=white" alt="VCPChat">
</p>

<p align="center">
  <img src="https://img.shields.io/github/actions/workflow/status/homuraLan/vcp-cicd/vcp-build-release.yml?style=flat-square&label=build" alt="build status">
  <img src="https://img.shields.io/github/v/release/homuraLan/vcp-cicd?style=flat-square&label=release" alt="release">
  <img src="https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20Docker-informational?style=flat-square" alt="platform">
</p>

---

跟踪三个上游项目的更新，自动编译成可直接使用的成品。**不用自己配环境，下载就能用。**

| 组件 | 是什么 | 平台 |
| :--- | :--- | :--- |
| ![Docker](https://img.shields.io/badge/-VCPToolBox-2496ED?style=flat-square&logo=docker&logoColor=white) | AI 工具调用服务端 | Docker |
| ![Android](https://img.shields.io/badge/-VCPMobile-3DDC84?style=flat-square&logo=android&logoColor=white) | 手机客户端 | Android 8.0+ |
| ![Windows](https://img.shields.io/badge/-VCPChat-0078D4?style=flat-square&logo=windows&logoColor=white) | 桌面客户端 | Windows 10/11 |

## 下载

<p align="center">
  <a href="../../releases/latest">
    <img src="https://img.shields.io/badge/⬇%20下载最新版-Releases-2ea44f?style=for-the-badge" alt="Download">
  </a>
</p>

进入 [**Releases**](../../releases/latest) 页面，按需下载：

| 文件 | 平台 | 说明 |
| :--- | :--- | :--- |
| `VCPMobile-v<版本>-<hash>.apk` | Android | 安装包，传到手机点击安装 |
| `VCPMobile-latest.apk` | Android | 同上，固定名，适合收藏链接 |
| `VCPChat-Setup-<版本>-<hash>.exe` | Windows | 安装包，双击运行 |
| `VCPChat-Portable-<版本>-<hash>.zip` | Windows | 免安装版，解压即用 |
| `vcptoolbox-<版本>-<hash>-linux-amd64.tar.gz` | Linux | 服务端二进制，解压即跑 |

文件名里的 `<hash>` 是上游提交的短 SHA，能直接对上源码版本。
桌面端的 `<版本>` 是上游提交日期，如 `VCPChat-Setup-2026.10.25-74d4a491.exe`。

每个文件都配了同名的 `.sha256`，另有一份汇总的 `SHA256SUMS`：

```bash
sha256sum -c SHA256SUMS
```

Release 里只放成品和校验值，没有别的东西。

### 服务端也有免安装的二进制包

除了 Docker 镜像，服务端同样提供二进制的 tar 包，**不装 Docker 也能直接跑**。

```bash
tar -xzf vcptoolbox-<版本>-<hash>-linux-amd64.tar.gz
cd app
node main.js
```

依赖已全部内置（`node_modules`、`pydeps`、编好的原生模块、插件里用 Rust 写的
子程序），不用 `npm install`，也不用装编译器。

包里的 `BUILD-INFO.txt` 写明提交、构建时间和运行环境。

> 这个包按 Alpine/musl 构建。如果系统是 glibc（常见发行版都是），
> 用容器镜像更省事：
> ```bash
> docker pull homuralan/vcptoolbox:latest         # 最新
> docker pull homuralan/vcptoolbox:v1.13.0        # 固定到某个上游版本
> docker pull homuralan/vcptoolbox:<hash>         # 固定到某次上游提交
> ```
>
> 三个标签指向同一个镜像，按用途挑：`latest` 日常用，`v<版本>` 跟着上游版本走，
> `<hash>` 精确到提交，回滚时用它最稳。

## 各端说明

### VCPMobile · 安卓

- 要求 **Android 8.0** 及以上
- 首次启动已内置服务地址，无需手动配置
- 支持覆盖升级，新版本直接安装即可

### VCPChat · Windows

- 支持 Windows 10 / 11（64 位）
- 安装后首次启动需在设置里填入服务端地址
- 新版本直接装，会自动覆盖

### VCPToolBox · 服务端

<a href="https://hub.docker.com/r/homuralan/vcptoolbox"><img src="https://img.shields.io/docker/pulls/homuralan/vcptoolbox?style=flat-square&logo=docker&logoColor=white" alt="docker pulls"></a>

```bash
docker pull homuralan/vcptoolbox:latest
```

| Tag | 说明 |
| :--- | :--- |
| `latest` | 最近一次成功构建 |
| `v1.13.0` 这样的版本号 | 对应上游版本，跟 Release 标签对得上 |
| `dd4f7032` 这样的短 hash | 精确对应某个上游提交，回滚用 |

每次构建完会自动清理旧标签，只保留最新 10 个版本（`latest` 除外）。
想回滚到更早的版本，用 Release 里留着的 tar 包。

需要配置文件才能启动。参考上游 [VCPToolBox](https://github.com/lioensky/VCPToolBox) 的部署说明。
镜像说明会随每次构建自动更新到 Docker Hub 页面。

## 更新方式

客户端会自动检测新版本：

- **安卓**：打开 App 时检查，有新版会弹提示
- **Windows**：下载新安装包覆盖安装

也可以在 Settings 里手动点检查更新。

## 构建规则

**只有上游真的更新了才会重新编译。** 三个上游各自独立判断：

```
每 6 小时检查一次
      │
      ├── VCPToolBox 有新提交？ → 只构建服务端（镜像 + Linux 二进制）
      ├── VCPMobile  有新提交？ → 只构建 APK
      └── VCPChat    有新提交？ → 只构建 Windows 客户端
```

没变化就跳过，不浪费构建时间。上一次成功的提交记在 `state` 分支上，
用 SHA 比对，不依赖版本号或 tag。

所以某次 Release 里只有一两个文件是**正常现象** —— 说明其它组件这轮没变。
没变的组件，摘要里会分别给出它自己最近一次真正构建出来的那版链接。

## 常见问题

<details>
<summary><b>安装 APK 提示「应用未安装」</b></summary>

签名不一致。如果你装过其他来源的同名 App，需要先卸载再装这个。

</details>

<details>
<summary><b>App 打开连不上服务</b></summary>

内置地址是局域网地址。确认手机和服务端在同一个网络，或者在 App 设置里改成正确的地址。

</details>

<details>
<summary><b>多久更新一次</b></summary>

分两层看，两层互不影响：

**上游构建** —— 有新提交就编译，每 6 小时查一次上游。这一层不设频率限制，
上游动了就构建，保证 Release 里永远是最新代码。

**本机拉取** —— 已部署的机器多久去取一次新版本，默认一周一次，每一端单独设：

| 仓库变量 | 管什么 | 默认 |
| :--- | :--- | :--- |
| `VCP_SERVER_INTERVAL_H` | 服务端多久拉一次 | `168`（小时 = 一周） |
| `VCP_CHAT_INTERVAL_H` | 桌面端多久拉一次 | `168`（小时 = 一周） |

移动端没有这一项：APK 只是放在局域网下载页上，手机上什么时候装由你决定，
不存在「自动拉取」这一步。

改法（小时数）：

```bash
gh variable set VCP_SERVER_INTERVAL_H --repo homuraLan/vcp-cicd --body "24"     # 一天
gh variable set VCP_CHAT_INTERVAL_H --repo homuraLan/vcp-cicd --body "72"       # 三天
```

填 `0` 表示该端不自动拉，只能手动触发。手动触发 `VCP 部署对齐` workflow
会忽略间隔立刻对齐一次，升级完想马上验证时用这个。

版本号沿用上游仓库的最新 tag：服务端是 `v1.13.0` 这种，移动端是 `v1.1.6`。

桌面端例外：VCPChat 上游没有版本 tag，`package.json` 里写死的 `1.0.0` 从来不更新，
所以用它最新提交的日期当版本号，如 `v2026.10.25`。

一版里同时更新了多个组件时，标签会带上各自版本，如 `v1.13.0.1.1.6.2026.10.25`。

</details>

<details>
<summary><b>Linux 二进制包里能直接跑吗</b></summary>

能。里面是完整的应用目录（源码 + node_modules + pydeps + 插件依赖 + 编译好的
原生模块），面向 `node:20-alpine` 的 musl 运行环境。

插件里用 Rust 写的子项目（DailyNoteSearcher 等）在构建时一并编译，
上游仓库只放了部分平台的预编译文件，缺的那个由 CI 补上。

</details>

<details>
<summary><b>为什么这次 Release 只有安卓包</b></summary>

因为这次只有 VCPMobile 上游更新了。按需构建，只编译有变化的组件。

没变的组件，摘要里会给出它**自己最近一次真正构建出来**的那版链接 ——
不会指到一版没有该组件产物的发布上。

</details>

<details>
<summary><b>Linux 二进制跑不起来 / 报 glibc 错误</b></summary>

这个包按 Alpine（musl）构建，和上游 Dockerfile 保持一致。glibc 系统（Debian、Ubuntu、
CentOS 等）上可能缺库或加载不了原生模块。

在 glibc 系统上请用容器镜像：

```bash
docker pull homuralan/vcptoolbox:latest
```

也可以装 `gcompat` 后在 musl 环境里跑。

</details>

<details>
<summary><b>这些包安全吗</b></summary>

代码全部来自上面三个上游仓库，这里只做编译和打包，不改动业务逻辑。构建过程在 GitHub Actions 上进行，流水线文件公开可查。

唯一改动：把服务地址作为默认值编进 App，省去首次配置。

</details>

---

<p align="center">
  <sub>非官方构建 · 上游：<a href="https://github.com/lioensky/VCPToolBox">VCPToolBox</a> · <a href="https://github.com/MRiecy/VCPMobile">VCPMobile</a> · <a href="https://github.com/lioensky/VCPChat">VCPChat</a></sub>
</p>
