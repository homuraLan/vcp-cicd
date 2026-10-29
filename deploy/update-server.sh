#!/usr/bin/env bash
# Image code stays in the image; production configuration and data stay on the host.
# See deploy/README.md for path options and rollback behavior.
set -Eeuo pipefail
DEPLOY_DIR="${DEPLOY_DIR:?必须指定 DEPLOY_DIR}"
TARGET_IMAGE="${TARGET_IMAGE:?必须指定 TARGET_IMAGE}"
TARGET_SHA="${TARGET_SHA:-}"
TARGET_TAG="${TARGET_TAG:-}"
HEALTH_URL="${HEALTH_URL:-}"
INTERVAL_H="${INTERVAL_H:-168}"
FORCE="${FORCE:-0}"
HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-40}"
HEALTH_DELAY_SECONDS="${HEALTH_DELAY_SECONDS:-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR TARGET_IMAGE
log() { echo "[$(date '+%F %T')] $*"; }
[[ "$TARGET_IMAGE" =~ ^[[:alnum:]][[:alnum:]_.:/@-]*$ ]] || { echo "镜像引用格式无效"; exit 1; }
cd "$DEPLOY_DIR"
POLICY_STAMP="$DEPLOY_DIR/.last-pull.at"
if [ "$FORCE" != "1" ]; then
  [ "$INTERVAL_H" != "0" ] || { log "自动更新已关闭"; exit 0; }
  if [ -f "$POLICY_STAMP" ]; then
    LAST_AT=$(cat "$POLICY_STAMP")
    if (( $(date -u +%s) - LAST_AT < INTERVAL_H * 3600 )); then
      log "未到更新间隔，本次跳过"
      exit 0
    fi
  fi
fi

# Snapshot the actual running image before pull: an upstream SHA tag can be rebuilt.
mkdir -p .deploy-backup
BACKUP_DIR=$(mktemp -d "$DEPLOY_DIR/.deploy-backup/server-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
HAD_OVERRIDE=false
if [ -f docker-compose.override.yml ]; then
  cp -p docker-compose.override.yml "$BACKUP_DIR/docker-compose.override.yml"
  HAD_OVERRIDE=true
fi
PREV_IMAGE_ID=""
PREV_IMAGE=""
PREV_CONTAINER=$(docker compose ps -q app)
if [ -n "$PREV_CONTAINER" ]; then
  PREV_IMAGE_ID=$(docker inspect --format '{{.Image}}' "$PREV_CONTAINER")
  PREV_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$PREV_CONTAINER")
  ROLLBACK_IMAGE="vcptoolbox-deploy-rollback:$(basename "$BACKUP_DIR")"
  docker image tag "$PREV_IMAGE_ID" "$ROLLBACK_IMAGE"
  printf '%s\n' "$PREV_IMAGE_ID" > "$BACKUP_DIR/image-id"
  printf '%s\n' "$ROLLBACK_IMAGE" > "$BACKUP_DIR/image-reference"
fi
NEXT_OVERRIDE="$BACKUP_DIR/next-override.yml"
python3 "$SCRIPT_DIR/prepare-server-compose.py" "$SCRIPT_DIR/docker-compose.deploy.yml" "$NEXT_OVERRIDE"
docker compose -f docker-compose.yml -f "$NEXT_OVERRIDE" config --quiet
log "拉取镜像 $TARGET_IMAGE"
docker pull "$TARGET_IMAGE"
TARGET_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$TARGET_IMAGE")
if [ "$FORCE" != "1" ] && [ -n "$PREV_IMAGE_ID" ] && [ "$PREV_IMAGE_ID" = "$TARGET_IMAGE_ID" ] \
    && [ "$HAD_OVERRIDE" = true ] && cmp -s "$NEXT_OVERRIDE" docker-compose.override.yml; then
  log "运行镜像与部署配置均未改变，无需重启"
  date -u +%s > "$POLICY_STAMP"
  exit 0
fi
rollback() {
  trap - ERR INT TERM
  set +e
  log "更新失败，恢复旧部署；备份保留于 $BACKUP_DIR"
  if [ "$HAD_OVERRIDE" = true ]; then
    cp -p "$BACKUP_DIR/docker-compose.override.yml" docker-compose.override.yml
  else
    rm -f docker-compose.override.yml
  fi
  if [ -n "$PREV_IMAGE_ID" ]; then
    # Restore mutable tags so a later ordinary compose up also resolves the old image.
    if [[ "$PREV_IMAGE" != *@* && "$PREV_IMAGE" != sha256:* ]]; then
      if ! docker image tag "$PREV_IMAGE_ID" "$PREV_IMAGE"; then
        log "旧镜像标签恢复失败，请使用备份中的 image-reference 手工恢复"
        exit 1
      fi
    fi
    if docker compose up -d --force-recreate --pull never; then
      local restored_container restored_id
      restored_container=$(docker compose ps -q app)
      restored_id=$(docker inspect --format '{{.Image}}' "$restored_container")
      if [ "$restored_id" = "$PREV_IMAGE_ID" ]; then
        log "已恢复旧镜像 $PREV_IMAGE_ID"
      else
        log "回滚镜像核验失败，请检查服务；旧镜像引用保留于备份目录"
      fi
    else
      log "旧服务启动失败，请检查服务；旧镜像引用保留于备份目录"
    fi
  else
    log "此前没有 app 容器，已恢复原配置，请检查首次部署失败原因"
  fi
  exit 1
}
trap rollback ERR INT TERM
# No git reset/clean, native-module deletion, or replacement of production data.
cp "$NEXT_OVERRIDE" docker-compose.override.yml
log "重建服务（旧镜像与配置保留于 $BACKUP_DIR）"
docker compose up -d --force-recreate --pull never
runtime_ready() {
  docker compose exec -T app node - <<'NODE'
const fs = require('fs');
const path = require('path');
const cfg = { ...require('dotenv').parse(fs.readFileSync('/usr/src/app/config.env')), ...process.env };
const mainPort = parseInt(cfg.PORT, 10) || 3000;
const root = path.resolve(cfg.TDB_KNOWLEDGE_ROOT_PATH || '/usr/src/app/knowledge');
const store = path.resolve(cfg.TDB_KNOWLEDGE_STORE_PATH || '/usr/src/app/VectorStoreTDB');
(async () => {
  if (!fs.statSync(root).isDirectory() || !fs.statSync(store).isDirectory()) throw new Error('directory');
  fs.accessSync(root, fs.constants.R_OK);
  fs.accessSync(store, fs.constants.R_OK | fs.constants.W_OK);
  JSON.parse(fs.readFileSync('/usr/src/app/rag_params.json', 'utf8'));
  const statuses = await Promise.all([mainPort, mainPort + 1].map(async port => {
    const response = await fetch(`http://127.0.0.1:${port}/`, {
      redirect: 'manual', signal: AbortSignal.timeout(4000)
    });
    return [200, 301, 302, 307, 308, 401, 403].includes(response.status);
  }));
  if (!statuses.every(Boolean)) throw new Error('listener');
  if (String(cfg.TDB_KNOWLEDGE_ENABLED || 'false').toLowerCase() === 'true') {
    if (!cfg.AdminUsername || !cfg.AdminPassword) throw new Error('admin-auth-required');
    const response = await fetch(`http://127.0.0.1:${mainPort}/admin_api/system-monitor/memory/profile`, {
      headers: { Authorization: 'Basic ' + Buffer.from(`${cfg.AdminUsername}:${cfg.AdminPassword}`).toString('base64') },
      signal: AbortSignal.timeout(4000)
    });
    if (!response.ok) throw new Error('profile');
    const body = await response.json();
    const cold = body.profile?.tdbKnowledge;
    if (!cold?.enabled || !cold.initialized || !cold.metaDb?.open) throw new Error('cold-knowledge');
    if (cfg.TDB_KNOWLEDGE_DIMENSION && Number(cold.dimension) !== Number(cfg.TDB_KNOWLEDGE_DIMENSION)) {
      throw new Error('cold-knowledge-dimension');
    }
  }
})().catch(() => { process.exitCode = 1; });
NODE
}
log "等待主服务、管理服务与知识库挂载就绪"
ok=false
for ((i=1; i<=HEALTH_ATTEMPTS; i++)); do
  if runtime_ready; then
    if [ -z "$HEALTH_URL" ]; then
      ok=true
    else
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" 2>/dev/null || true)
      case "$code" in 200|301|302|307|308|401|403) ok=true ;; esac
    fi
  fi
  [ "$ok" != true ] || break
  sleep "$HEALTH_DELAY_SECONDS"
done
if [ "$ok" != true ]; then
  log "健康检查未通过"
  rollback
fi
trap - ERR INT TERM
if [ -n "$TARGET_SHA" ]; then printf '%s\n' "$TARGET_SHA" > .deployed-sha; fi
if [ -n "$TARGET_TAG" ]; then printf '%s\n' "$TARGET_TAG" > .deployed-tag; fi
date -u +%s > "$POLICY_STAMP"
log "更新完成: $TARGET_IMAGE ($TARGET_IMAGE_ID)"
docker compose ps
