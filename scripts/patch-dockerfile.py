#!/usr/bin/env python3
"""给上游 Dockerfile 补上插件编译、TriviumDB 运行库和原生功能验证。

上游只编译了 rust-vexus-lite，插件里带 Rust 源码的三个（CodeSearcher、
DailyNoteSearcher、PaperReader）靠仓库里放的预编译二进制。预编译不全会导致
插件在运行时找不到可执行文件直接启动失败 —— DailyNoteSearcher 就是只有
aarch64 版本，x86_64 服务器上用不了。

这个脚本在构建前把缺失的部分补进 Dockerfile 的构建阶段，编译结果留在
镜像里，容器和导出的 Linux 二进制包内容一致。

用法：python3 patch-dockerfile.py <Dockerfile 路径>
脚本是幂等的；旧插件编译补丁也会继续补齐新的运行库和验证步骤。
"""

from pathlib import Path
import re
import sys

MARKER = "# >>> plugin-native-build"
SMOKE_MARKER = "# >>> triviumdb-runtime-smoke"
SMOKE_SOURCE = Path(__file__).with_name("smoke-triviumdb.cjs")
SMOKE_NAME = "vcp-ci-smoke-triviumdb.cjs"

SMOKE_BLOCK = f"""# >>> triviumdb-runtime-smoke
# TriviumDB ships a GNU/glibc addon. Alpine's gcompat supplies its runtime ABI.
# Exercise the final runtime image: loading alone does not prove persisted search works.
COPY --from=build /usr/src/app/{SMOKE_NAME} ./{SMOKE_NAME}
RUN node ./{SMOKE_NAME}
# <<< triviumdb-runtime-smoke
"""

BLOCK = """# >>> plugin-native-build
# 插件里的 Rust 子项目需要现场编译。上游只在仓库里放了部分平台的预编译
# 二进制，x86_64-linux 缺好几个，不编译就会在运行时找不到可执行文件。
# 产物按插件 JS 里的命名约定放回插件目录，它按这个名字查找。
#
# 只编译真正用得上的：PaperReader 依赖 bzip2/zstd 等 C 库，编译要额外装一堆
# dev 包，而它的 manifest 是 .block（上游默认禁用），不编。
#
# 注意：RUN 的多行续行里不能夹注释行，否则 Docker 拼接时会断掉，
# for 循环的 do 就配不上。注释只能放在 RUN 外面。
RUN echo ">>> Building plugin native binaries..." && \\
    for spec in \\
      "DailyNoteSearcher/src:DailyNoteSearcher/DailyNoteSearcher-x86_64-unknown-linux-gnu" \\
    ; do \\
      src="${spec%%:*}"; \\
      out="${spec#*:}"; \\
      bin=$(basename "$out" | cut -d- -f1); \\
      if [ ! -f "Plugin/$src/Cargo.toml" ]; then \\
        echo "skip $src (no Cargo.toml)"; \\
        continue; \\
      fi; \\
      echo "--- building $src -> $out"; \\
      ( cd "Plugin/$src" && cargo build --release ) || { echo "!!! failed: $src"; exit 1; }; \\
      if [ ! -f "Plugin/$src/target/release/$bin" ]; then \\
        echo "!!! 编译没有产出 $bin"; \\
        exit 1; \\
      fi; \\
      mkdir -p "$(dirname "Plugin/$out")"; \\
      cp "Plugin/$src/target/release/$bin" "Plugin/$out" || { echo "!!! 复制失败"; exit 1; }; \\
      chmod +x "Plugin/$out"; \\
      test -x "Plugin/$out" || { echo "!!! 产物不可执行"; exit 1; }; \\
      echo "    -> $(wc -c < "Plugin/$out") bytes"; \\
    done && \\
    echo ">>> plugin native build complete." && \\
    ls -la Plugin/DailyNoteSearcher/ | grep x86_64-unknown
# <<< plugin-native-build
"""


def patch_dockerfile(text: str) -> str:
    """Fail closed when the upstream stages change instead of patching the wrong image."""
    text = text.replace("\r\n", "\n")
    stages = re.findall(r"(?m)^FROM\s+([^\n]+)", text)
    if len(stages) != 2 or not all(re.match(r"node:[^\s]*alpine(?:\s|$)", stage) for stage in stages):
        raise ValueError("Expected two Node Alpine stages; review native runtime dependencies")

    # Keep build/runtime ABIs consistent. This also permits an upstream apk block that
    # already contains gcompat without adding a second copy of the package.
    lines = text.splitlines(keepends=True)
    apk_lines = [i for i, line in enumerate(lines) if line.startswith("RUN apk add --no-cache")]
    if len(apk_lines) != 2:
        raise ValueError("Expected one apk dependency block in each stage")
    for index in reversed(apk_lines):
        end = index
        while lines[end].rstrip().endswith("\\"):
            end += 1
            if end >= len(lines):
                raise ValueError("Unterminated apk dependency block")
        block = "".join(lines[index:end + 1])
        if not re.search(r"\bgcompat\b", block):
            if not lines[index].rstrip().endswith("\\"):
                raise ValueError("Expected a multiline apk dependency block")
            lines.insert(index + 1, "  gcompat \\\n")
    text = "".join(lines)

    if MARKER not in text:
        anchor = "\n# 查找所有插件目录下的 requirements.txt"
        if anchor not in text:
            raise ValueError("找不到插件编译插入点，Dockerfile 结构可能变了")
        text = text.replace(anchor, "\n" + BLOCK + anchor, 1)

    if SMOKE_MARKER not in text:
        # Run after production has all native modules, before PM2 starts anything.
        anchor = "COPY --from=build /usr/src/app/AdminPanel-Vue/dist ./AdminPanel-Vue/dist\n"
        if text.count(anchor) != 1:
            raise ValueError("找不到最终运行阶段验证插入点，Dockerfile 结构可能变了")
        text = text.replace(anchor, anchor + "\n" + SMOKE_BLOCK, 1)
    return text


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "Dockerfile")
    raw = path.read_bytes()

    # 统一成 LF 再处理，插入的段落一律用 LF 写出。
    # 上游文件是 CRLF，但 CRLF 会把 \r 留在续行符 \ 后面，Docker 拼出来的
    # RUN 命令里就混进回车，shell 解析会出错（实测量出来的产物对不上）。
    had_crlf = b"\r\n" in raw
    try:
        text = patch_dockerfile(raw.decode("utf-8"))
        smoke = SMOKE_SOURCE.read_bytes()
    except (ValueError, OSError) as exc:
        print(f"::error::{exc}")
        return 1

    # 整个文件写成 LF：Docker 两种都能读，混用反而容易出上面的续行问题
    if had_crlf:
        print("原文件是 CRLF，已转为 LF 以避免续行符失效")
    # The caller patches an upstream checkout, not this CI repository. Stage the
    # probe beside Dockerfile so upstream COPY . . includes the reviewed script.
    path.with_name(SMOKE_NAME).write_bytes(smoke.replace(b"\r\n", b"\n"))
    path.write_bytes(text.encode("utf-8"))
    print("已补齐插件编译、gcompat 运行库和 TriviumDB 持久化检索验证")
    return 0


if __name__ == "__main__":
    sys.exit(main())
