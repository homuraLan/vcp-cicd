# VCP CI/CD 流水线

**当前方案：GitHub Actions + self-hosted runner（官方 CI/CD，纯出站，无需公网入站）。**

---

## 为什么是这个方案

三个硬约束决定了架构：

1. **上游 `lioensky/VCPToolBox` 是第三方仓库**，我没有它的写权限，无法在上游加 webhook。
2. **NAS 没有公网入站**（无固定公网 IP，无法做端口映射）。
3. **不接受用定时器代替事件驱动的构建**。

前两条排除了「GitHub webhook → NAS」这条路（那需要公网入口）。
**self-hosted runner 正好绕过**：runner 在 NAS 上运行，主动向外连 GitHub 拉任务，**不需要任何入站端口**。

## 架构

```
GitHub (<owner>/vcp-cicd, 私有)
   │  ① schedule (*/10) 检测上游 main 的 SHA
   │  ② workflow_dispatch 手动触发（可指定任意 SHA / 强制重建）
   ▼
self-hosted runner (装在 runner 工作目录)
   │  runner 主动出站连接，GitHub 通过长连接下发任务 —— 无入站
   ▼
workflow: 比对 state.json 里的 SHA
   │  相同 → 直接结束（不构建）
   ▼  不同
$VCP_CI_DIR/build.sh <sha>
   ├─ 从本地仓库同步源码到 vcp-ci/src
   ├─ 自动补回上游漏提交的 ToolConfigs/jev_tool_call_exp.json
   ├─ 给 Dockerfile 补 TVStxt/ToolConfigs/config 的 COPY
   ├─ docker build -t vcptoolbox:vcp-ci-<sha8>（已存在则跳过）
   ├─ docker compose up -d app
   ├─ 健康检查 6005/v1/models（200/401 = 主服务已活）
   └─ post-deploy.sh 强校验 → 失败自动回滚
```

**关键**：GitHub 侧只负责「发现上游有新提交」这一件事，实际构建完全在 NAS 本地执行。
runner 空闲时 CPU 为 0%，构建只在 SHA 真的变化时发生一次。

## 仓库与 runner

三端（服务端 / 移动端 / 桌面端）的构建细节见 [CLIENTS.md](CLIENTS.md)。

| 项 | 值 |
| --- | --- |
| 仓库 | `<owner>/vcp-cicd`（公开，见下方说明） |
| Workflow | `.github/workflows/vcp-deploy.yml` |
| 检测频率 | `cron: '*/5 * * * *'`（每 5 分钟，GitHub 支持的最小粒度） |
| Runner 1 | `linux` 型 — 标签 `self-hosted, linux` |
| Runner 2 | `windows` 型 — 标签 `self-hosted, local, windows` |
| Runner 目录 | 由各机器自行决定，不写死在 workflow 里 |
| 服务名 | `actions.runner.<owner>-<repo>.<runner>.service` |
| 执行用户 | root（需 `RUNNER_ALLOW_RUNASROOT=1`） |

### 三个 job 如何分派

| job | `runs-on` | 跑什么 |
| --- | --- | --- |
| `backend` | `self-hosted, linux` | VCPToolBox Docker 镜像与部署 |
| `mobile` | `self-hosted, linux` | VCPMobile APK 交叉编译 |
| `desktop` | `self-hosted, local, Windows` | VCPChat Electron 安装包 |

`desktop` 只带 `local` 标签，所以本机不在线时它只会排队，不会误派到 NAS —— 这就是「本机上线才更新本机软件」的实现。

### runner 常用操作

```bash
systemctl status actions.runner.<owner>-<repo>.<runner>.service
journalctl -u actions.runner.<owner>-<repo>.<runner>.service -f   # 看接单与执行
systemctl restart actions.runner.<owner>-<repo>.<runner>.service
```

### 手动触发一次部署

```bash
curl -X POST -H "Authorization: Bearer <PAT>" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/<owner>/vcp-cicd/actions/workflows/vcp-deploy.yml/dispatches \
  -d '{"ref":"main","inputs":{"sha":"<可选SHA>","force":false,"targets":"all"}}'
```

`targets` 可选 `all` / `backend` / `mobile` / `desktop`，用来只重建某一端。

或在网页 Actions → VCP Build & Deploy → Run workflow。

### 本机 runner（Windows）

装成计划任务，登录即启动：

```powershell
Get-ScheduledTask -TaskName "VCP Actions Runner"          # 查看状态
Get-ScheduledTaskInfo -TaskName "VCP Actions Runner"       # 上次运行结果
Start-ScheduledTask -TaskName "VCP Actions Runner"         # 手动拉起
Get-Process -Name Runner.Listener                          # 确认进程
```

`LastTaskResult 267009`（`0x00041301`）表示「正在运行」，是正常值。

> 该任务绑定交互登录会话，**注销或重启后需要重新登录一次才会自动起来**。
> 之前尝试装成 Windows 服务失败（`RunnerService.exe` 需要 UAC 提权），所以用了计划任务。
> runner 离线期间的 `desktop` job 会一直排队，不会丢。

## ⚠️ 必须知道的限制

### 1. 上游变更检测靠 schedule，不是 push 即时触发

GitHub **不提供**「第三方仓库 push 时通知我的仓库」的机制。fork 也一样——上游 push 不会触发 fork 的 workflow。

所以在「无入站 + 无上游权限」的前提下，发现上游更新只能靠定期比对 SHA。
这是**变更检测**，不是构建轮询：SHA 没变就什么都不做（实测 16 秒结束，构建步骤自动跳过）。

### 2. 新建仓库的 schedule 首次注册很慢，且「改一次 cron 就重排一次队」

**这是本项目踩过最坑的一条，务必先读。**

现象：仓库建好后，`workflow_dispatch` 立刻可用，但 `schedule` 迟迟不触发。实测连续 81 分钟、跨八个 `*/10` 班次全部落空。

排查过程中试过的手段**全部无效**，而且**每一个都在延长问题**：
- 把 cron 改成 `* * * * *`（每分钟）→ 不触发
- 把私有仓库改成公开 → 不触发
- 删除 workflow 文件再重建（强迫 GitHub 刷新索引，`updated_at` 确实变了）→ 仍不触发

**根因**：GitHub 的定时调度注册是异步的、有较长延迟（官方文档也承认高峰期可达数十分钟）。而**每次修改 workflow 文件（尤其改 cron）都会重置这个注册过程**。来回改动等于把排队一次次清零，永远等不到第一次调度。

**正确做法**：
1. cron 定好后**就别再动它**；
2. 静置等待，首次注册可能需要一段不短的时间（本例约数小时后，`event: schedule` 的记录出现，随后按 5 分钟稳定运行）；
3. 用 `GET /repos/<owner>/<repo>/actions/runs` 里是否出现 `event: schedule` 来判断是否已生效，**不要靠反复改配置去试探**。

期间想立刻部署，直接用 `workflow_dispatch` 手动触发，不影响 schedule 的排队。

### 3. 仓库 60 天无活动会禁用 scheduled workflow

GitHub 的规则：仓库 60 天没有活动，定时 workflow 会被自动停用。

**症状**：上游更新了但一直不部署。
**处置**：去 Actions 页面点一次 Enable，或手动 Run workflow 一次即可恢复。
**彻底避免**：偶尔往 `vcp-cicd` 仓库提交一次（比如更新本文档）。

## 如果将来有了公网入口

`vcp-ci` 目录下保留了完整的入站 webhook 方案（`webhook.js` / `worker.sh` / `nginx.conf`），随时可以切回：

```bash
systemctl enable --now vcp-ci-webhook vcp-ci-worker
```

然后在上游（或 fork）配置 webhook 指向 `http://<公网>:9101/hook`。
届时可以把 workflow 的 `schedule` 去掉，只留 `workflow_dispatch`。

> 注意：`vcp-ci-proxy`（nginx）**必须一直保持运行**，它除了 9101 还承载 **7999 端口的 embedding 路径适配**（把 NewAPI 的 `/v1/embeddings` 转成 infinity 的 `/embeddings`）。停掉它会导致 VCP 的向量化全部失败。

## 目录

| 路径 | 说明 |
| --- | --- |
| runner 工作目录 | GitHub Actions runner |
| `vcp-ci/build.sh` | 构建 + 部署 + 回滚（核心） |
| `vcp-ci/post-deploy.sh` | 部署后强校验 |
| `vcp-ci/state.json` | 当前部署版本（workflow 据此判断是否构建） |
| `vcp-ci/logs/build-<sha8>.log` | 每次构建的完整日志 |
| `vcp-ci/src/` | 流水线专用源码树 |
| `vcp-ci/nginx/` | 独立 nginx（9101 入站 + 7999 embedding 适配） |
| `vcp-ci/webhook.js` `worker.sh` | 入站方案（当前停用，保留备用） |

## 端口

| 端口 | 服务 | 状态 |
| --- | --- | --- |
| 6005 | VCPToolBox 主服务 | 运行 |
| 6006 | 管理面板 | 运行 |
| 9000 | NewAPI 网关 | 运行 |
| 7997 | infinity-embed（bge-m3, 1024 维） | 运行 |
| 7999 | nginx embedding 路径适配 | **运行（必需）** |
| 9100 | 入站 webhook | 已停用 |
| 9101 | 入站 webhook 入口 | 停用 |

## 部署踩过的坑（重建时会复发，已固化进流水线）

### 1. Rust 原生模块 ABI 不匹配

`NativeKnowledgeRuntime ABI unavailable` → 主服务启动即崩。

**根因**：compose 把宿主目录 `.:/usr/src/app` 整挂载，宿主 git 仓库里**预编译的旧 `.node`** 覆盖了镜像内现编的产物。

**解决**：compose 用命名卷 `vcp_vexus:/usr/src/app/rust-vexus-lite` 遮住该目录。

### 2. 上游 Dockerfile 的 COPY 清单不全

`COPY --from=build` 漏了 `TVStxt`、`ToolConfigs`、`config`，只 `mkdir` 了空目录。原本靠全目录挂载掩盖，一旦不挂载就崩。

**解决**：`build.sh` 自动给 Dockerfile 补三条 `COPY`，保证镜像自包含。

### 3. 上游漏提交 `ToolConfigs/jev_tool_call_exp.json`

`server.js` 硬依赖该文件（无降级），缺失直接崩溃。该文件在 git 历史 `deb9d15` 中存在。

**解决**：`build.sh` 检测缺失时从 `deb9d15` 自动恢复。

### 4. 健康检查误报

原来用 `6006/AdminPanel` 判断，但管理面板是**独立进程**，主服务崩了它照样响应。

**解决**：改探 `6005/v1/models`（`200`/`401` 才算主服务活），再加 `post-deploy.sh` 三重校验。

### 5. infinity-embed OOM

bge-m3 批量加载峰值 8.35G，而容器 `memory: 8G` 上限 → 被 cgroup 连续 OOM kill。

**解决**：``infinity-embed` 的 compose 文件` 中 `memory: 8G → 16G`，`--batch-size 16 → 8`。

### 6. 向量维度必须匹配

`VECTORDB_DIMENSION` 必须等于 embedding 模型输出维度。bge-m3 = **1024**（不是默认的 3072）。
改维度后必须清空 `VectorStore` 重建，否则新旧向量不兼容。

### 7. fnOS 的 nginx 不可 systemd 管理

`systemctl reload nginx` → `nginx.service is not active`；`nginx -s reload` → `invalid PID number ""`。

**解决**：用**独立 nginx 实例**（`vcp-ci-proxy.service`，自带 config/pid/log），不碰 fnOS 自带的四个 nginx master。

### 8. 构建缓存复用

首次全量构建 27 分钟，Docker 缓存命中后 **约 3 分钟**。

## 已知无害告警（不影响核心功能，不用处理）

容器日志里会持续出现这几条，都是可选组件缺失，上游自身有降级：

| 告警 | 原因 | 影响 |
| --- | --- | --- |
| `TriviumDB 原生绑定加载失败 … ld-linux-x86-64.so.2` | `triviumdb` 只提供 glibc（gnu）版本，而镜像是 musl 的 alpine | 冷知识库禁用，其余正常 |
| `DailyNoteSearcher executable … was not found` | 该插件需要本地 Cargo 编译，上游未提供二进制 | 日记搜索插件不可用 |
| `WeatherReporter … YOUR_QWEATHER_KEY` | `config.env` 里是占位符，没配天气 API key | 天气插件不可用，删掉该插件或填 key 即可 |

要彻底消除 TriviumDB 告警，只能把基础镜像从 `node:20-alpine` 换成 `node:20-slim`（glibc），但会导致整个 Dockerfile 的 apk 层重写，代价远大于收益，**不建议动**。

## 性能与验证记录

| 项 | 值 |
| --- | --- |
| 上游版本 | `c603f13692b212db371223ff6d91fb71b0b3b39e` |
| 部署镜像 | `vcptoolbox:vcp-ci-c603f136` |
| 手动触发（完整构建） | 192 秒 |
| 定时触发（完整构建） | 391 秒（`event: schedule`，全流程自动） |
| 重复触发（SHA 未变） | 16 秒，`构建并部署` 步骤自动 skipped |
| runner 空闲 CPU | 0.0% |
| 容器稳定 | `RestartCount=0`，主服务 6005 返回 401（鉴权正常） |
| 镜像精简 | 保留「当前版 + 上一版」，debug 期的重复 tag 已清理 |

**已实测通过的完整链路**：GitHub 定时调度 → runner 接单 → 检测到上游新提交 → 构建 → 部署 → 健康检查 → 状态落盘，全程无人干预。
