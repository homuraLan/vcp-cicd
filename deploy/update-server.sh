#!/usr/bin/env bash
# VCPToolBox 服务端自动更新
#
# 由 GitHub Actions 在构建完成后调用，也可以由 runner 定时轮询触发。
# 两种入口都走这个脚本，保证行为一致。
#
# 设计要点：
#   - 幂等：目标版本已在跑就直接退出，不会重启服务
#   - 可回滚：所有改动前先备份 override 与源码提交号
#   - 保数据：只更新代码，不碰 config.env 和 VectorStore 卷
#   - 健康检查：起不来自动回滚到旧镜像
#
# 环境变量：
#   DEPLOY_DIR     部署目录（必填）
#   TARGET_IMAGE   目标镜像，如 homuralan/vcptoolbox:add5dbb5（必填）
#   TARGET_SHA     目标上游提交（可选，用于记录）
#   HEALTH_URL     健康检查地址（可选）

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:?必须指定 DEPLOY_DIR}"
TARGET_IMAGE="${TARGET_IMAGE:?必须指定 TARGET_IMAGE}"
TARGET_SHA="${TARGET_SHA:-}"
HEALTH_URL="${HEALTH_URL:-}"

log() { echo "[$(date '+%F %T')] $*"; }

cd "$DEPLOY_DIR" || { echo "部署目录不存在: $DEPLOY_DIR"; exit 1; }

OVER_BACKUP="$DEPLOY_DIR/.override.backup"
PREV_IMAGE=""

# ---- 1. 已经在跑目标版本就不用动 ----
if [ -f docker-compose.override.yml ]; then
  PREV_IMAGE=$(grep -E '^\s+image:' docker-compose.override.yml | head -1 | awk '{print $2}')
fi

if [ "$PREV_IMAGE" = "$TARGET_IMAGE" ]; then
  log "已在运行 $TARGET_IMAGE，无需更新"
  exit 0
fi

log "当前镜像: ${PREV_IMAGE:-<未设置>}"
log "目标镜像: $TARGET_IMAGE"

# ---- 2. 拉取新镜像 ----
log "拉取镜像"
if ! docker pull "$TARGET_IMAGE"; then
  echo "镜像拉取失败，保留当前版本不动"
  exit 1
fi

# ---- 3. 备份当前状态，便于回滚 ----
if [ -f docker-compose.override.yml ]; then
  cp docker-compose.override.yml "$OVER_BACKUP"
  log "已备份 override 配置"
fi

PREV_COMMIT=""
if [ -d .git ]; then
  PREV_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
fi

rollback() {
  log "!!! 更新失败，开始回滚"
  if [ -n "$PREV_IMAGE" ] && [ -f "$OVER_BACKUP" ]; then
    cp "$OVER_BACKUP" docker-compose.override.yml
    docker compose up -d --remove-orphans || true
    log "已回滚到 ${PREV_IMAGE}"
  fi
  if [ -n "$PREV_COMMIT" ] && [ -d .git ]; then
    git reset --hard "$PREV_COMMIT" >/dev/null 2>&1 || true
    log "已回滚源码到 ${PREV_COMMIT:0:8}"
  fi
  exit 1
}

# ---- 4. 更新源码 ----
# 宿主机源码整目录挂载进容器，会覆盖镜像里的代码，所以必须同步更新
if [ -d .git ]; then
  log "更新源码"

  # 部署目录一般属于 root，而 runner 用别的账户跑，git 会因为
  # 「dubious ownership」拒绝操作。这个目录是我们自己指定的，加白名单。
  # 只在当前命令生效，不改 runner 的全局 git 配置。
  git -c safe.directory="$PWD" status >/dev/null 2>&1 || true
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=safe.directory
  export GIT_CONFIG_VALUE_0="$PWD"

  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
  [ "$BRANCH" = "HEAD" ] && BRANCH=main

  # 上游会 force push 改写历史，--ff-only 必然失败，所以直接对齐远端。
  # 注意别写成 `git fetch ... | tail`：管道会让 $? 变成 tail 的退出码，
  # 永远看不到 fetch 真失败。
  FETCH_LOG=$(mktemp)
  if ! git fetch --depth 1 origin "$BRANCH" >"$FETCH_LOG" 2>&1; then
    tail -3 "$FETCH_LOG"
    rm -f "$FETCH_LOG"
    log "拉取失败，保留当前源码"
    exit 1
  fi
  rm -f "$FETCH_LOG"

  # reset 会覆盖本地对跟踪文件的修改。先留一份，出问题能找回来
  if ! git diff --quiet 2>/dev/null; then
    CHANGED=$(git diff --name-only 2>/dev/null | tr '\n' ' ')
    log "本地修改过的跟踪文件: $CHANGED"
    mkdir -p .deploy-backup
    for f in $CHANGED; do
      [ -f "$f" ] && cp "$f" ".deploy-backup/$(echo "$f" | tr '/' '_').$(date +%s)" 2>/dev/null || true
    done
    log "已备份到 .deploy-backup"
  fi

  if ! git reset --hard "origin/$BRANCH" >/dev/null 2>&1; then
    log "重置失败（可能是浅克隆缺对象），尝试补全后重试"
    git fetch --unshallow origin "$BRANCH" >/dev/null 2>&1 || true
    if ! git reset --hard "origin/$BRANCH" >/dev/null 2>&1; then
      rollback
    fi
  fi

  log "源码已更新到 $(git rev-parse --short HEAD)（$(git log -1 --format=%s | cut -c1-50)）"

  # rust-vexus-lite 的原生模块跟 Node 版本强绑定，必须用镜像里编好的那份。
  # 宿主目录里的预编译产物会遮住镜像的（见下面 volumes 说明），所以清掉。
  if [ -d rust-vexus-lite ]; then
    NODES=$(ls rust-vexus-lite/*.node 2>/dev/null | wc -l)
    if [ "$NODES" -gt 0 ]; then
      mkdir -p .node-backup
      cp -a rust-vexus-lite/*.node .node-backup/ 2>/dev/null || true
      rm -f rust-vexus-lite/*.node
      log "已清理 $NODES 个宿主原生模块，改用镜像内的版本"
    fi
  fi
fi

# ---- 5. 切换镜像并重建 ----
# 上游的 docker-compose.yml 是给本地开发用的，有三个挂载会毁掉镜像里的产物：
#   .:/usr/src/app             宿主源码覆盖镜像代码
#   /usr/src/app/pydeps        匿名卷遮住镜像里装好的 python 依赖
#   /usr/src/app/node_modules  匿名卷遮住镜像里的 node_modules
# 所以这里用 !override 整段替换挂载，只留配置和数据。
log "写入部署配置"
cat > docker-compose.override.yml <<EOF
services:
  app:
    image: ${TARGET_IMAGE}
    volumes: !override
      - ./config.env:/usr/src/app/config.env
      - ./TVStxt:/usr/src/app/TVStxt
      - ./ToolConfigs:/usr/src/app/ToolConfigs
      - ./Plugin/UserAuth:/usr/src/app/Plugin/UserAuth
      - vcp_vectorstore:/usr/src/app/VectorStore
      - ./dailynote:/usr/src/app/dailynote
      - ./Plugin/VCPLog/log:/usr/src/app/Plugin/VCPLog/log
EOF

log "重启服务"
if ! docker compose up -d --force-recreate --remove-orphans; then
  rollback
fi

# ---- 6. 健康检查 ----
# 6005 是主服务，对裸 GET 不回状态码；6006 会返回 302，更适合探活。
# 任何一个端口有响应就算起来了。
if [ -n "$HEALTH_URL" ]; then
  # 主服务对裸 GET 可能不回状态码，所以额外探测 6006
  HOSTPORT=$(echo "$HEALTH_URL" | sed -E 's#^https?://([^/]+).*#\1#')
  HOST=$(echo "$HOSTPORT" | sed -E 's#:[0-9]+$##')
  ALT_URL="http://${HOST}:6006/"

  log "等待服务就绪（$HEALTH_URL）"
  # 先给容器几秒起来，省得第一轮全是连接拒绝
  sleep 5
  ok=false
  code=""
  for i in $(seq 1 40); do
    for u in "$HEALTH_URL" "$ALT_URL"; do
      # 容器刚起时连接会被拒（curl 退出码 7），set -e 下必须兜住，
      # 否则整个脚本在这里直接死掉，看不出是「还没起来」还是「起不来」
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" 2>/dev/null || true)
      case "$code" in
        200|301|302|307|401|403) ok=true; break 2 ;;
      esac
    done
    sleep 3
  done
  if [ "$ok" != "true" ]; then
    log "健康检查未通过（最后状态码 ${code:-无响应}）"
    rollback
  fi
  log "健康检查通过（$code）"
fi

rm -f "$OVER_BACKUP"
log "更新完成: $TARGET_IMAGE"
if [ -n "$TARGET_SHA" ]; then
  echo "$TARGET_SHA" > .deployed-sha
  log "记录提交: ${TARGET_SHA:0:8}"
fi

docker compose ps
