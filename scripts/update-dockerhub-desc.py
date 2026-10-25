#!/usr/bin/env python3
"""更新 Docker Hub 仓库说明（简介 + 详细描述）。"""
import json
import os
import sys
import urllib.request

user = os.environ["DH_USER"]
token = os.environ["DH_TOKEN"]
upstream_sha = os.environ.get("UPSTREAM_SHA", "")[:8]

README = f"""# VCPToolBox

Automatically built from [lioensky/VCPToolBox](https://github.com/lioensky/VCPToolBox).

Unofficial rebuild. For documentation and support, refer to the upstream repository.

## Pull

```bash
docker pull {user}/vcptoolbox:latest
```

## Tags

| Tag | Meaning |
| --- | --- |
| `latest` | most recent successful build |
| `<commit>` | pinned to a specific upstream commit |

## Latest build

- upstream commit: `{upstream_sha}`
- built by GitHub Actions
"""


def main():
    # 登录拿 JWT
    login = urllib.request.Request(
        "https://hub.docker.com/v2/users/login",
        data=json.dumps({"username": user, "password": token}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(login, timeout=30) as r:
        jwt = json.load(r)["token"]

    patch = urllib.request.Request(
        f"https://hub.docker.com/v2/repositories/{user}/vcptoolbox/",
        data=json.dumps(
            {
                "full_description": README,
                "description": "VCPToolBox 自动构建镜像",
            }
        ).encode(),
        headers={
            "Authorization": f"Bearer {jwt}",
            "Content-Type": "application/json",
        },
        method="PATCH",
    )
    with urllib.request.urlopen(patch, timeout=30) as r:
        print(f"说明更新成功: HTTP {r.status}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # 说明更新失败不应让整个构建失败
        print(f"说明更新失败（不影响构建）: {e}", file=sys.stderr)
