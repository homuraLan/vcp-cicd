#!/usr/bin/env python3
"""给上游 Dockerfile 补上插件原生二进制编译。

上游只编译了 rust-vexus-lite，插件里带 Rust 源码的三个（CodeSearcher、
DailyNoteSearcher、PaperReader）靠仓库里放的预编译二进制。预编译不全会导致
插件在运行时找不到可执行文件直接启动失败 —— DailyNoteSearcher 就是只有
aarch64 版本，x86_64 服务器上用不了。

这个脚本在构建前把缺失的部分补进 Dockerfile 的构建阶段，编译结果留在
镜像里，容器和导出的 Linux 二进制包内容一致。

用法：python3 patch-dockerfile.py <Dockerfile 路径>
脚本是幂等的，已经打过就跳过。
"""

import re
import sys

MARKER = "# >>> plugin-native-build"

BLOCK = """# >>> plugin-native-build
# 插件里的 Rust 子项目需要现场编译。上游只在仓库里放了部分平台的预编译
# 二进制，x86_64-linux 缺好几个，不编译就会在运行时找不到可执行文件。
# 产物按插件 JS 里的命名约定放回插件目录，它按这个名字查找。
#
# 只编译真正用得上的：PaperReader 依赖 bzip2/zstd 等 C 库，编译要额外装一堆
# dev 包，而它的 manifest 是 .block（上游默认禁用），不编。
RUN echo ">>> Building plugin native binaries..." && \\
    for spec in \\
      "DailyNoteSearcher/src:DailyNoteSearcher/DailyNoteSearcher-x86_64-unknown-linux-gnu" \\
    ; do \\
      src="${spec%%:*}"; \\
      out="${spec#*:}"; \\
      if [ ! -f "Plugin/$src/Cargo.toml" ]; then \\
        echo "skip $src (no Cargo.toml)"; \\
        continue; \\
      fi; \\
      echo "--- building $src -> $out"; \\
      ( cd "Plugin/$src" && cargo build --release ) || { echo "!!! failed: $src"; exit 1; }; \\
      mkdir -p "$(dirname "Plugin/$out")"; \\
      cp "Plugin/$src/target/release/$(basename "$out")" "Plugin/$out" 2>/dev/null || \\
        cp "Plugin/$src/target/release/$(basename "$src")" "Plugin/$out"; \\
      chmod +x "Plugin/$out"; \\
      echo "    -> $(stat -c %s "Plugin/$out") bytes"; \\
    done && \\
    echo ">>> plugin native build complete."
# <<< plugin-native-build
"""


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "Dockerfile"
    with open(path, "rb") as fh:
        raw = fh.read()

    # 保留原文件的换行风格（上游是 CRLF）
    crlf = b"\r\n" in raw
    text = raw.decode("utf-8").replace("\r\n", "\n")

    if MARKER in text:
        print("已打过补丁，跳过")
        return 0

    # 插在 AdminPanel-Vue 构建之后、插件依赖安装之前
    anchor = "\n# 查找所有插件目录下的 requirements.txt"
    if anchor not in text:
        print(f"::error::找不到插入点，Dockerfile 结构可能变了")
        return 1

    text = text.replace(anchor, "\n" + BLOCK + anchor, 1)

    out = text.replace("\n", "\r\n") if crlf else text
    with open(path, "wb") as fh:
        fh.write(out.encode("utf-8"))

    print("已补入插件编译段")
    return 0


if __name__ == "__main__":
    sys.exit(main())
