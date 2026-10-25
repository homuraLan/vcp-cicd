# VCP 自托管 runner 构建方案

<p align="center">
  <img src="https://img.shields.io/badge/self--hosted-runner-6e7681?style=flat-square" alt="self-hosted">
  <img src="https://img.shields.io/badge/build-local%20machine-blue?style=flat-square" alt="local build">
  <img src="https://img.shields.io/badge/branch-self--hosted-orange?style=flat-square" alt="branch">
</p>

在自己机器上编译三端，产物直接落地，不经过公网。

> **默认用 `main` 分支。** 那里是托管方案，编译在 GitHub 服务器上跑，不需要你的机器常开。
> 这个分支适合：Actions 额度不够、内网隔离环境、或者就是想自己掌控构建过程。

## 什么时候该用这个分支

| 情况 | 建议 |
| :--- | :--- |
| 普通使用 | 用 `main`，别折腾 |
| Actions 额度耗尽 | 切这个分支 |
| 服务端在内网，产物不能出网 | 切这个分支 |
| 想完全掌控构建环境 | 切这个分支 |
| 没有常开的机器 | **别用**，用 `main` |

## 这个方案要求什么

- **一台常开的机器**（NAS / 小主机 / 台式机都行）
- 该机器上装好 **Docker**（Android 交叉编译需要）
- 一个 GitHub 账号，能创建仓库级 runner

不需要公网 IP，不需要端口映射。runner 是**主动外连**拉任务的。

## 架构

```
GitHub Actions（只做调度）
      │
      ├── NAS / Linux 机 ──► 服务端镜像构建部署
      │                   └─► Android APK 交叉编译
      │
      └── Windows 机 ─────► Electron 客户端打包
```

runner 标签决定任务落到哪台机器：

| Job | 标签 | 落在 |
| :--- | :--- | :--- |
| `backend` | `self-hosted, linux` | Linux 机 |
| `mobile` | `self-hosted, linux` | Linux 机 |
| `desktop` | `self-hosted, local, windows` | Windows 机 |

`desktop` 带 `local` 标签，所以 Windows 机不在线时它只会**排队等待**，不会误派到别处 —— 这就是「本机上线才更新」的实现方式。

## 开始

完整步骤见 **[TUTORIAL.md](TUTORIAL.md)**，包括：

1. 注册 runner（Linux 用户级 / Windows 计划任务）
2. 配置工作目录与凭证
3. 触发构建
4. 局域网分发
5. 故障排查

专项文档：

- [CI-CD.md](CI-CD.md) — 流水线设计、部署记录、踩坑总结
- [CLIENTS.md](CLIENTS.md) — 三端各自的构建细节

## runner 的运行方式

以**普通用户**身份运行，不注册系统服务，不需要 root。

**Linux** —— systemd 用户实例：

```bash
systemctl --user enable --now github-runner.service
loginctl enable-linger <user>       # 未登录也保持运行
```

> `su - <user> -c "systemctl --user ..."` 会报
> `Failed to connect to bus: No medium found`，需要补 `XDG_RUNTIME_DIR=/run/user/<uid>`。

**Windows** —— 计划任务（`AtLogOn`），在登录会话里跑。

> 任务绑定交互登录会话，注销或重启后需要重新登录一次才会自动起来。

## 关于「用户级 runner」

GitHub 的**用户级 runner**（一个 runner 服务该用户名下所有仓库）需要付费计划，
Free 账户只能创建仓库级或组织级 runner。

本方案用的是 **仓库级 + 用户态运行**：

- **仓库级** —— 注册在某个仓库下，只接该仓库的任务
- **用户态** —— 以普通用户身份运行，不是 root、不是系统服务

两者不是一回事，网上经常混着说。

## 切回托管方案

```bash
git checkout main
```

## 本地实参

`LOCAL-NOTES.md` 记录真实的内网地址、路径、口令，已加入 `.gitignore`，**不会进入仓库**。
自己需要时新建一份即可。

---

<p align="center">
  <sub>上游：<a href="https://github.com/lioensky/VCPToolBox">VCPToolBox</a> · <a href="https://github.com/MRiecy/VCPMobile">VCPMobile</a> · <a href="https://github.com/lioensky/VCPChat">VCPChat</a></sub>
</p>