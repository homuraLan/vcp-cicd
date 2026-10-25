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
  git fetch -q --depth 1 origin 2>/dev/null || true

  # 本地改动先存起来，避免 pull 冲突。运行时产生的文件（Plugin 下的配置等）不该丢
  if ! git diff --quiet 2>/dev/null; then
    log "存在本地改动，暂存处理"
    git stash push -q -m "auto-deploy-$(date +%s)" -- \
      ':(exclude)docker-compose.override.yml' 2>/dev/null || true
  fi

  if ! git pull --ff-only -q origin 2>/dev/null; then
    log "快进失败，改用重置到远端最新"
    git reset --hard origin/HEAD >/dev/null 2>&1 || rollback
  fi
  log "源码已更新到 $(git rev-parse --short HEAD)"
fi

# ---- 5. 切换镜像并重建 ----
log "写入镜像配置"
cat > docker-compose.override.yml <<EOF
services:
  app:
    image: ${TARGET_IMAGE}
EOF

log "重启服务"
if ! docker compose up -d --remove-orphans; then
  rollback
fi

# ---- 6. 健康检查 ----
if [ -n "$HEALTH_URL" ]; then
  log "等待服务就绪"
  ok=false
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" 2>/dev/null || echo 000)
    # 401/302 也算活着的证据：服务在响应，只是需要认证
    case "$code" in
      200|301|302|307|401|403) ok=true; break ;;
    esac
    sleep 3
  done
  if [ "$ok" != "true" ]; then
    log "健康检查未通过（最后状态码 $code）"
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
