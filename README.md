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

| 文件 | 说明 |
| :--- | :--- |
| `VCPMobile-v<版本>-<hash>.apk` | 安卓安装包，传到手机点击安装 |
| `VCPMobile-latest.apk` | 同上，固定名，适合收藏下载链接 |
| `VCPChat-Setup-<版本>-<hash>.exe` | Windows 安装包，双击运行 |
| `VCPChat-Portable-<版本>-<hash>.zip` | Windows 免安装版，解压即用 |
| `vcptoolbox-<日期>-<hash>.tar.gz` | 服务端镜像归档，离线部署用 |
| `SHA256SUMS.txt` | 校验清单 |

文件名里的 `<hash>` 是上游提交的短 SHA，能直接对上源码版本。

> 也可以直接拉取服务端镜像：
> ```bash
> docker pull homuralan/vcptoolbox:latest      # 最新
> docker pull homuralan/vcptoolbox:<hash>      # 固定到某个提交
> ```

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

```bash
docker pull homuralan/vcptoolbox:latest
```

需要配置文件才能启动。参考上游 [VCPToolBox](https://github.com/lioensky/VCPToolBox) 的部署说明。

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
      ├── VCPToolBox 有新提交？ → 只构建服务端镜像
      ├── VCPMobile  有新提交？ → 只构建 APK
      └── VCPChat    有新提交？ → 只构建 Windows 客户端
```

没变化就跳过，不浪费构建时间。上一次成功的提交记在 `state` 分支上，
用 SHA 比对，不依赖版本号或 tag。

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

上游有新提交时自动构建，检查间隔 6 小时。Releases 里的版本号带日期和运行号。

</details>

<details>
<summary><b>为什么这次 Release 只有安卓包</b></summary>

因为这次只有 VCPMobile 上游更新了。按需构建，只编译有变化的组件。

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
