# VCPMobile Android 交叉编译环境
#
# 依据上游 .github/toolchain.env 锁定版本：
#   NODE_VERSION=24.14.1
#   PNPM_VERSION=12.6.0
#   JAVA_VERSION=17.0.20+8
#   ANDROID_COMPILE_SDK_VERSION=36
#   ANDROID_BUILD_TOOLS_VERSION=36.0.0
#   NDK_VERSION=29.0.14206865
#
# 基础镜像选 Debian(glibc) 而非 Alpine：Rust 与 Android NDK 工具链依赖 glibc。

FROM eclipse-temurin:17-jdk

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl wget git unzip zip xz-utils file \
        build-essential pkg-config libssl-dev \
        python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---- Node 24 ----
ARG NODE_VERSION=24.14.1
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node -v && npm -v

# ---- pnpm ----
ARG PNPM_VERSION=12.6.0
RUN npm install -g pnpm@${PNPM_VERSION} && pnpm -v

# ---- Rust ----
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal \
    && rustc --version && cargo --version

# ---- Android SDK / NDK ----
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_NDK_HOME=/opt/android-sdk/ndk/29.0.14206865
ENV PATH=${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}

ARG ANDROID_CMDLINE_TOOLS_VERSION=13114758
ARG ANDROID_COMPILE_SDK_VERSION=36
ARG ANDROID_BUILD_TOOLS_VERSION=36.0.0
ARG NDK_VERSION=29.0.14206865

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools \
    && curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
        -o /tmp/cmdline-tools.zip \
    && unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_HOME}/cmdline-tools \
    && mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest \
    && rm /tmp/cmdline-tools.zip

RUN yes | sdkmanager --licenses > /dev/null 2>&1 || true

RUN sdkmanager \
        "platform-tools" \
        "platforms;android-${ANDROID_COMPILE_SDK_VERSION}" \
        "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" \
        "ndk;${NDK_VERSION}" \
    && ls ${ANDROID_HOME}/ndk/

# ---- Rust Android targets ----
RUN rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android

WORKDIR /workspace
CMD ["/bin/bash"]
