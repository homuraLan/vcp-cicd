#!/usr/bin/env python3
"""更新 Docker Hub 仓库说明（简介 + 详细描述）。

凭证从环境变量取：
    DH_USER           Docker Hub 用户名
    DH_TOKEN          带读写权限的 token
    UPSTREAM_SHA      本次构建对应的上游提交
    UPSTREAM_VERSION  上游版本号（可空，如 v1.13.0）
    RELEASE_TAG       对应的 GitHub Release 标签（可空）
    REPO              构建仓库的 owner/name，默认 homuraLan/vcp-cicd
任何失败都只打警告，不让整个构建挂掉——说明是附属产物，不该拖累镜像。
"""
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://hub.docker.com/v2"

user = os.environ.get("DH_USER", "").strip()
token = os.environ.get("DH_TOKEN", "").strip()
upstream_sha = os.environ.get("UPSTREAM_SHA", "")[:8]
upstream_ver = os.environ.get("UPSTREAM_VERSION", "").strip()
release_tag = os.environ.get("RELEASE_TAG", "").strip()
repo = os.environ.get("REPO", "homuraLan/vcp-cicd").strip()

IMAGE = f"{user}/vcptoolbox"
REPO_URL = f"https://github.com/{repo}"

DESC = "VCPToolBox 自动构建镜像 · 来自 GitHub Actions"

README = f"""# VCPToolBox

> 本镜像由 [**{repo}**]({REPO_URL}) 自动构建发布，不是官方镜像。

上游项目：[lioensky/VCPToolBox](https://github.com/lioensky/VCPToolBox)。
源码来自上游，这里只做编译和打包，不改动业务逻辑。
使用文档请看上游仓库；构建流水线、变更记录和已知问题在我们的仓库里。

## 为什么会有这个镜像

上游只提供源码，自己编译要配 Node、Python、Rust 和一堆原生依赖。
这个镜像把这些都做完了：上游一有提交就自动重新编译，推到这里和 GitHub Release。

**你不需要自己在本地构建。**

## 拉取

```bash
docker pull {IMAGE}:latest
```

## 标签说明

| 标签 | 含义 |
| :--- | :--- |
| `latest` | 最近一次成功构建 |
| `v1.13.0` 这样的版本号 | 对应上游版本，跟 Release 标签一致 |
| `dd4f7032` 这样的短 hash | 精确对应某次上游提交，回滚用 |

三个标签指向同一个镜像。日常用 `latest`，要固定版本用版本号，
出问题回滚用短 hash —— 那个永远不会被覆盖。

> 旧标签会自动清理：每次构建后只保留最近 10 个版本，`latest` 永久保留。
> 更早的版本请到 GitHub Release 下载对应的 tar 包。

## 构建信息

- 上游提交：`{upstream_sha}`{f"（{upstream_ver}）" if upstream_ver else ""}
- {f"对应发布：[{release_tag}]({REPO_URL}/releases/tag/{release_tag})" if release_tag else "构建由 GitHub Actions 完成"}
- 构建环境：Alpine / musl，与上游 Dockerfile 保持一致

## 也提供免安装的二进制包

不想装 Docker 的话，GitHub Release 里有同样内容的 tar 包，
依赖全部内置，解压就能跑：

```bash
tar -xzf vcptoolbox-<版本>-<hash>-linux-amd64.tar.gz
cd app
node main.js
```

见 [{repo} Releases]({REPO_URL}/releases)。

## 需要什么配置

镜像本身不含配置。要正常启动需要按上游文档准备 `config.toml` 等文件并挂载进去，
参考上游 [VCPToolBox 部署说明](https://github.com/lioensky/VCPToolBox)。

## 相关仓库

- 构建与发布：[{repo}]({REPO_URL})
- 上游源码：[lioensky/VCPToolBox](https://github.com/lioensky/VCPToolBox)
"""


def req(url, method="GET", jwt=None, payload=None):
    data = None
    headers = {"Content-Type": "application/json"}
    if jwt:
        headers["Authorization"] = f"Bearer {jwt}"
    if payload is not None:
        data = json.dumps(payload).encode()
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(r, timeout=30) as resp:
        body = resp.read().decode()
        return json.loads(body) if body.strip() else {}


def main():
    if not user or not token:
        print("未配置 DH_USER / DH_TOKEN，跳过说明更新", file=sys.stderr)
        return 0

    # 登录换 JWT。Docker Hub 的写接口只认 JWT，不认原始 token。
    login = urllib.request.Request(
        f"{API}/users/login/",
        data=json.dumps({"username": user, "password": token}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(login, timeout=30) as r:
        jwt = json.load(r)["token"]

    out = req(
        f"{API}/repositories/{IMAGE}/",
        "PATCH",
        jwt=jwt,
        payload={"full_description": README, "description": DESC},
    )
    print(f"说明更新成功: {out.get('name', IMAGE)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as e:
        # 说明更新失败不该让整个构建失败
        print(f"说明更新失败（不影响构建）: HTTP {e.code}", file=sys.stderr)
    except Exception as e:
        print(f"说明更新失败（不影响构建）: {e}", file=sys.stderr)
