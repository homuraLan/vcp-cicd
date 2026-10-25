#!/usr/bin/env bash
# VCPMobile APK 交叉编译 + 配置注入
#
# 配置注入方式：仅改 Rust 侧默认值（settings_manager.rs 的 vcp_server_url 等），
# 不触碰任何业务逻辑。首次启动即带好服务地址，用户仍可在设置里改。
#
# 两种构建模式：
#   BUILD_MODE=docker    在容器内构建（本地/自托管 runner）
#   BUILD_MODE=host      直接在宿主环境构建（GitHub 托管 runner，工具链已预装）
#
# 签名是可选的：不提供签名时产出未签名 APK，仅用于验证构建。
# 正式分发必须签名，否则无法覆盖安装旧版本。

set -euo pipefail

WORK=${WORK:?请设置 WORK 环境变量指向工作目录（存放产物与缓存）}
BUILD_MODE=${BUILD_MODE:-docker}
# 源码目录默认在工作目录下的 src/，也允许单独指定（例如 CI 里源码检出在别处）
SRC=${SRC_DIR:-$WORK/src}
OUT=$WORK/out
LOG_DIR=$WORK/logs
IMAGE=${IMAGE:-vcpmobile-android:latest}

# ---- 注入的配置 ----
VCP_SERVER_URL=${VCP_SERVER_URL:?请设置 VCP_SERVER_URL 为服务端地址}
VCP_API_KEY=${VCP_API_KEY:-}
ADMIN_USER=${ADMIN_USER:-}
ADMIN_PASS=${ADMIN_PASS:-}

DOWNLOAD_URL=${DOWNLOAD_URL:-}
VERSION_CODE_OFFSET=${VERSION_CODE_OFFSET:-0}

# ---- 签名配置（可选）----
KEY_ALIAS=${KEY_ALIAS:-}
KEY_PASS=${KEY_PASS:-}
# keystore 文件路径；为空表示不签名
KEYSTORE_PATH=${KEYSTORE_PATH:-}

mkdir -p "$OUT" "$LOG_DIR"

SHA=$(git -C "$SRC" rev-parse HEAD)
SHORT=${SHA:0:8}

exec > >(tee -a "$LOG_DIR/build-$SHORT.log") 2>&1
echo "[$(date '+%F %T')] === APK BUILD START $SHA (mode=$BUILD_MODE)"

# ---- 注入配置（幂等：先还原再替换）----
SETTINGS=$SRC/src-tauri/src/vcp_modules/infra/settings_manager.rs
git -C "$SRC" checkout -- "$SETTINGS" 2>/dev/null || true

python3 - "$SETTINGS" "$VCP_SERVER_URL" "$VCP_API_KEY" "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import re, sys
path, url, key, user, pw = sys.argv[1:6]
s = open(path, encoding='utf-8').read()

def sub(field, value):
    global s
    if not value:
        return
    pat = re.compile(r'(\b' + field + r':\s*)"[^"]*"')
    if pat.search(s):
        s = pat.sub(lambda m: m.group(1) + '"' + value.replace('"', '\\"') + '"', s, count=1)
        print(f"inject {field} = {value}")
    else:
        print(f"WARN field not found: {field}")

sub('vcp_server_url', url)
sub('vcp_api_key', key)
sub('admin_username', user)
sub('admin_password', pw)
open(path, 'w', encoding='utf-8').write(s)
PY

echo "[$(date '+%F %T')] 配置注入完成"

# ---- 版本号偏移 ----
python3 - "$SRC" "$VERSION_CODE_OFFSET" <<'PY'
import json, sys
src, off = sys.argv[1], int(sys.argv[2])
if off:
    p = src + '/src-tauri/tauri.conf.json'
    d = json.load(open(p, encoding='utf-8'))
    b = d.setdefault('bundle', {}).setdefault('android', {})
    base = b.get('versionCode', 1)
    b['versionCode'] = base + off
    json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(f"versionCode: {base} -> {b['versionCode']}")
PY

# ---- 构建 ----
if [ "$BUILD_MODE" = "docker" ]; then
  echo "[$(date '+%F %T')] 容器内构建"
  mkdir -p "$WORK/gradle-home" "$WORK/.cargo-registry"
  cp -f "$WORK/gradle-init/init-mirror.gradle" "$WORK/gradle-home/" 2>/dev/null || true

  KEYSTORE_ARGS=()
  KEY_ENV=()
  if [ -n "$KEYSTORE_PATH" ] && [ -f "$KEYSTORE_PATH" ]; then
    KEYSTORE_ARGS=(-v "$(dirname "$KEYSTORE_PATH")":/keys:ro)
    KEY_ENV=(-e ANDROID_KEYSTORE_PATH=/keys/$(basename "$KEYSTORE_PATH")
             -e ANDROID_KEY_ALIAS="$KEY_ALIAS"
             -e ANDROID_KEYSTORE_PASSWORD="$KEY_PASS"
             -e ANDROID_KEY_PASSWORD="$KEY_PASS")
  fi

  docker run --rm \
    -v "$SRC":/workspace \
    -v "$OUT":/out \
    -v "$WORK/gradle-home":/root/.gradle \
    -v "$WORK/.cargo-registry":/usr/local/cargo/registry \
    "${KEYSTORE_ARGS[@]}" \
    -e TARGET_SHA="$SHA" \
    "${KEY_ENV[@]}" \
    -w /workspace \
    "$IMAGE" bash -c '
      set -euo pipefail
      export CARGO_NET_GIT_FETCH_WITH_CLI=true

      if [ -f /root/.gradle/init-mirror.gradle ]; then
        mkdir -p /root/.gradle/init.d
        cp /root/.gradle/init-mirror.gradle /root/.gradle/init.d/
        echo "--- 已加载 Maven 镜像"
      fi

      echo "--- 依赖安装"
      if [ -f pnpm-lock.yaml ]; then
        pnpm install --frozen-lockfile --prefer-offline
      else
        pnpm install --prefer-offline
      fi

      echo "--- tauri android init"
      if [ ! -d src-tauri/gen/android ]; then
        pnpm tauri android init --ci
      fi

      echo "--- android settings"
      pnpm ci:prepare-android-settings || true

      echo "--- 编译 APK"
      pnpm tauri android build --apk --target aarch64

      found=$(find src-tauri/gen/android/app/build/outputs/apk -name "*.apk" -type f | sort)
      echo "$found"
      for f in $found; do cp "$f" /out/; done
      ls -lh /out/
    '

else
  echo "[$(date '+%F %T')] 宿主环境构建"
  cd "$SRC"
  export CARGO_NET_GIT_FETCH_WITH_CLI=true

  echo "--- 依赖安装"
  if [ -f pnpm-lock.yaml ]; then
    pnpm install --frozen-lockfile
  else
    pnpm install
  fi

  echo "--- tauri android init"
  if [ ! -d src-tauri/gen/android ]; then
    pnpm tauri android init --ci
  fi

  echo "--- android settings"
  pnpm ci:prepare-android-settings || true

  # 托管 runner 的 gradlew 可能没有执行位
  chmod +x src-tauri/gen/android/gradlew 2>/dev/null || true

  echo "--- 编译 APK"
  pnpm tauri android build --apk --target aarch64

  found=$(find src-tauri/gen/android/app/build/outputs/apk -name "*.apk" -type f | sort)
  echo "$found"
  for f in $found; do cp "$f" "$OUT/"; done
  ls -lh "$OUT/"
fi

echo "[$(date '+%F %T')] === APK BUILD OK $SHORT"

# ---- 规范化产物 ----
VER=$(python3 -c "import json;print(json.load(open('$SRC/src-tauri/tauri.conf.json'))['version'])")
VCODE=$(python3 -c "import json;print(json.load(open('$SRC/src-tauri/tauri.conf.json'))['bundle']['android']['versionCode'])")

# 固定文件名：App 用固定 URL 拉取，避免版本号变化导致地址失效
rm -f "$OUT/VCPMobile-latest.apk"
set -- "$OUT"/*.apk
if [ -f "$1" ]; then
  cp -f "$1" "$OUT/VCPMobile-latest.apk"
  find "$OUT" -maxdepth 1 -name "*.apk" ! -name "VCPMobile-latest.apk" -delete 2>/dev/null || true
fi

APK_SIZE=$(stat -c %s "$OUT/VCPMobile-latest.apk" 2>/dev/null || echo 0)
APK_SHA=$(sha256sum "$OUT/VCPMobile-latest.apk" 2>/dev/null | cut -d" " -f1 || echo "")

cat > "$OUT/manifest.json" <<EOF
{
  "version": "$VER",
  "versionCode": $VCODE,
  "sha": "$SHA",
  "apk": "VCPMobile-latest.apk",
  "size": $APK_SIZE,
  "apk_sha256": "$APK_SHA",
  "server": "$VCP_SERVER_URL",
  "built_at": "$(date -Iseconds)"
}
EOF

cat > "$WORK/state.json" <<EOF
{
  "sha": "$SHA",
  "version": "$VER",
  "versionCode": $VCODE,
  "apk": "VCPMobile-latest.apk",
  "built_at": "$(date -Iseconds)"
}
EOF

echo "[$(date '+%F %T')] manifest 与 state 已写入"
echo "[$(date '+%F %T')] APK: $VER (code $VCODE), $(numfmt --to=iec $APK_SIZE 2>/dev/null || echo $APK_SIZE)"

if [ -f "$WORK/template/index.html" ]; then
  cp -f "$WORK/template/index.html" "$OUT/index.html"
fi

chmod -R u+rwX,go+rX "$OUT" 2>/dev/null || true
echo "[$(date '+%F %T')] 完成${DOWNLOAD_URL:+，可通过 $DOWNLOAD_URL 下载}"
