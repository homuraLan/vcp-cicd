#!/usr/bin/env bash
# VCPMobile APK 交叉编译 + 配置注入
#
# 配置注入方式：仅改 Rust 侧默认值（settings_manager.rs 的 vcp_server_url 等），
# 不触碰任何业务逻辑。首次启动即带好服务地址，用户仍可在设置里改。

set -euo pipefail

# 工作目录由调用方提供，脚本本身不假设任何具体路径
WORK=${WORK:?请设置 WORK 环境变量指向构建工作目录}
SRC=$WORK/src
OUT=$WORK/out
LOG_DIR=$WORK/logs
IMAGE=${IMAGE:-vcpmobile-android:latest}

# ---- 注入的配置 ----
# 服务地址必须由调用方提供：这是部署环境相关的值，不写死在代码里
VCP_SERVER_URL=${VCP_SERVER_URL:?请设置 VCP_SERVER_URL 为被测服务端的地址}
VCP_API_KEY=${VCP_API_KEY:-}
ADMIN_USER=${ADMIN_USER:-}
ADMIN_PASS=${ADMIN_PASS:-}

# 分发地址仅用于输出提示，可选
DOWNLOAD_URL=${DOWNLOAD_URL:-}

# ---- 签名配置（必须由调用方提供，绝不设默认值）----
KEY_ALIAS=${KEY_ALIAS:?请设置 KEY_ALIAS 为签名密钥别名}
KEY_PASS=${KEY_PASS:?请设置 KEY_PASS 为签名密钥口令}

mkdir -p "$OUT" "$LOG_DIR"

SHA=$(git -C "$SRC" rev-parse HEAD)
SHORT=${SHA:0:8}
STAMP=$(date '+%Y%m%d-%H%M%S')
LOG=$LOG_DIR/build-$SHORT.log

exec > >(tee -a "$LOG") 2>&1
echo "[$(date '+%F %T')] === APK BUILD START $SHA"

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

# ---- 版本号：附加构建标识，避免与上游版本混淆 ----
VERSION_CODE_OFFSET=${VERSION_CODE_OFFSET:-0}
python3 - "$SRC" "$VERSION_CODE_OFFSET" <<'PY'
import json, sys
src, off = sys.argv[1], int(sys.argv[2])
p = src + '/src-tauri/tauri.conf.json'
d = json.load(open(p, encoding='utf-8'))
b = d.setdefault('bundle', {}).setdefault('android', {})
base = b.get('versionCode', 1)
b['versionCode'] = base + off
print(f"versionCode: {base} -> {b['versionCode']}")
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY

# ---- 构建 ----
echo "[$(date '+%F %T')] 开始容器内构建"
mkdir -p "$WORK/gradle-home" "$WORK/.cargo-registry"
cp -f "$WORK/gradle-init/init-mirror.gradle" "$WORK/gradle-home/" 2>/dev/null || true

docker run --rm \
  -v "$SRC":/workspace \
  -v "$OUT":/out \
  -v "$WORK/gradle-home":/root/.gradle \
  -v "$WORK/.cargo-registry":/usr/local/cargo/registry \
  -v "$WORK/keys":/keys:ro \
  -e TARGET_SHA="$SHA" \
  -e ANDROID_KEYSTORE_PATH=/keys/vcpmobile.jks \
  -e ANDROID_KEY_ALIAS="${KEY_ALIAS}" \
  -e ANDROID_KEYSTORE_PASSWORD="${KEY_PASS}" \
  -e ANDROID_KEY_PASSWORD="${KEY_PASS}" \
  -w /workspace \
  "$IMAGE" bash -c '
    set -euo pipefail
    export CARGO_NET_GIT_FETCH_WITH_CLI=true

    # Gradle 使用国内镜像（解决 Maven 403/缓慢）
    GRADLE_INIT=""
    if [ -f /root/.gradle/init-mirror.gradle ]; then
      mkdir -p /root/.gradle/init.d
      cp /root/.gradle/init-mirror.gradle /root/.gradle/init.d/
      GRADLE_INIT="--init-script /root/.gradle/init.d/init-mirror.gradle"
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

    echo "--- 编译 APK (aarch64)"
    pnpm tauri android build --apk --target aarch64

    echo "--- 收集产物"
    found=$(find src-tauri/gen/android/app/build/outputs/apk -name "*.apk" -type f | sort)
    echo "$found"
    for f in $found; do
      cp "$f" /out/
    done
    ls -lh /out/
  '

echo "[$(date '+%F %T')] === APK BUILD OK $SHORT"

# ---- 发布到 NAS 下载目录 ----
VER=$(python3 -c "import json;print(json.load(open('$SRC/src-tauri/tauri.conf.json'))['version'])")
VCODE=$(python3 -c "import json;print(json.load(open('$SRC/src-tauri/tauri.conf.json'))['bundle']['android']['versionCode'])")

# 固定文件名：App 用固定 URL 拉取，避免版本号变化导致地址失效
rm -f "$OUT/VCPMobile-latest.apk"
set -- "$OUT"/*.apk
if [ -f "$1" ]; then
  cp -f "$1" "$OUT/VCPMobile-latest.apk"
  # 只保留带版本号的那份和 latest 软链副本，清理旧版本
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

# workflow 用的状态文件
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

# 下载页（模板放 template/，每次发布复制过去）
if [ -f "$WORK/template/index.html" ]; then
  cp -f "$WORK/template/index.html" "$OUT/index.html"
fi

# fnOS 下目录常出现 d--------- 权限，nginx 读不到，统一修正
chmod -R u+rwX,go+rX "$OUT" 2>/dev/null || true
echo "[$(date '+%F %T')] 权限已修正${DOWNLOAD_URL:+，可通过 $DOWNLOAD_URL 下载}"
