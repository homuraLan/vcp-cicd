# 自托管 runner 方案（备用）

> **这是备用分支。** 默认使用 `main` 分支的托管方案——编译在 GitHub 服务器上完成，不需要你自己的机器常开。
> 只有当 GitHub Actions 不可用（额度耗尽、网络受限、需要完全内网）时，才用这个分支。

## 与 main 的区别

| | `main`（托管） | `self-hosted`（本分支） |
| --- | --- | --- |
| 编译位置 | GitHub 托管 runner | 你自己的机器 |
| 需要机器常开 | 否 | 是 |
| Actions 额度 | 消耗 | 不消耗 |
| 内网隔离 | 产物走公网 | 全程内网 |
| 产物分发 | Release + 局域网同步 | 直接落在本地目录 |
| 适用 | 大多数人 | 额度紧张 / 内网环境 |

## 方案概要

两台自托管 runner：

```
GitHub Actions（只负责调度）
      │
      ├── NAS（linux 标签）  → 服务端 Docker 构建部署 + APK 交叉编译
      └── 本机（local 标签） → Windows 客户端打包
```

`desktop` job 只带 `local` 标签，所以本机不在线时它只会排队，不会误派到 NAS —— 这就是「本机上线才更新」的实现。

## runner 的用户态运行

runner 以**普通用户**身份运行，不注册为系统服务，不需要 root。

### Linux

```bash
# 注册
./config.sh --url https://github.com/<owner>/<repo> --token <TOKEN> \
  --name <runner-name> --labels self-hosted,linux --unattended

# 用户服务：~/.config/systemd/user/github-runner.service
systemctl --user enable --now github-runner.service
systemctl --user status github-runner.service

# 允许未登录时也保持运行
loginctl enable-linger <user>
```

> `su - <user> -c "systemctl --user ..."` 会报 `Failed to connect to bus: No medium found`，
> 需要补上 `XDG_RUNTIME_DIR=/run/user/<uid>`。

用 Docker 构建时需要把用户加入 docker 组：

```bash
usermod -aG docker <user>
```

### Windows

用计划任务（`AtLogOn`）达到同样效果：在登录会话里跑，不碰系统服务。

```powershell
Get-ScheduledTask -TaskName "VCP Actions Runner"     # 查看状态
Start-ScheduledTask -TaskName "VCP Actions Runner"   # 手动拉起
Get-Process -Name Runner.Listener                    # 确认进程
```

> 任务绑定交互登录会话，注销或重启后需要重新登录一次才会自动起来。

## 关于「用户级 runner」

GitHub 的**用户级 runner**（一个 runner 服务该用户名下所有仓库）需要付费计划。
Free 账户只支持仓库级 / 组织级 runner。

本分支用的是**仓库级 + 用户态运行**，两者不是一回事：
- 仓库级：注册在某个仓库下，只接该仓库的任务
- 用户态：以普通用户身份运行，不是 root、不是系统服务

## 文档

- [CI-CD.md](CI-CD.md) — 流水线设计、runner 配置、部署记录
- [CLIENTS.md](CLIENTS.md) — 三端各自的构建细节与踩坑
- `LOCAL-NOTES.md` — 本机实参（内网地址、路径、口令），**不入库**

## 切回托管方案

```bash
git checkout main
```

`main` 分支的文档见其 README。
