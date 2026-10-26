#!/usr/bin/env python3
"""清理 Docker Hub 上的旧镜像标签，只保留最近若干个版本。

为什么不能简单按 tag 数量截断：
    `latest` 每次推送都会刷新到列表最前，按位置截断会把真正的新版本
    挤掉、把 latest 留在原地。所以先按标签类型分开处理。

保留规则：
    - `latest` 永远保留
    - 带版本号的标签（v1.13.0）按推送时间留最新的 N 个
    - 短 hash 标签同样留最新的 N 个
    - 同一个版本的两个标签算作一版，不重复占额度
    - 其它格式（老版本留下的日期标签等）不主动删，留着让人自己判断

环境变量：
    DH_USER      Docker Hub 用户名
    DH_TOKEN     带读写权限的 token
    DH_REPO      仓库名，默认 vcptoolbox
    KEEP_COUNT   保留多少个版本，默认 10
    DRY_RUN      设为 1 只打印不删除
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://hub.docker.com/v2"


def log(msg):
    print(msg, flush=True)


def req(url, method="GET", token=None, payload=None):
    data = None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "JWT " + token
    if payload is not None:
        data = json.dumps(payload).encode()
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(r, timeout=30) as resp:
        body = resp.read().decode()
        return json.loads(body) if body.strip() else {}


def login(user, token):
    """换 JWT。Docker Hub 的写入接口只认 JWT，不认原始 token。"""
    try:
        out = req(f"{API}/users/login/", "POST", payload={"username": user, "password": token})
        jwt = out.get("token")
        if not jwt:
            raise RuntimeError("登录没有返回 token")
        return jwt
    except urllib.error.HTTPError as e:
        log(f"::error::Docker Hub 登录失败（{e.code}）")
        sys.exit(1)


def list_tags(repo, jwt):
    """翻页取全部 tag。"""
    tags = []
    url = f"{API}/repositories/{repo}/tags/?page_size=100&ordering=last_updated"
    while url:
        out = req(url, token=jwt)
        tags.extend(out.get("results", []))
        url = out.get("next")
        if not url or len(tags) > 1000:
            break
    return tags


def main():
    user = os.environ.get("DH_USER", "").strip()
    token = os.environ.get("DH_TOKEN", "").strip()
    repo_name = os.environ.get("DH_REPO", "vcptoolbox").strip()
    keep = int(os.environ.get("KEEP_COUNT", "10"))
    dry = os.environ.get("DRY_RUN", "") == "1"

    if not user or not token:
        log("::error::缺少 DH_USER / DH_TOKEN")
        return 1

    repo = f"{user}/{repo_name}"
    jwt = login(user, token)
    tags = list_tags(repo, jwt)
    log(f"{repo} 现有 {len(tags)} 个标签")

    # 按类型分组，分组内按最后更新时间倒序（接口已排序，这里再稳一次）
    # 注意 tag 顺序：date_pat 必须在 sha_pat 前面判断。
    # 20261025 这种日期只由 0-9 组成，也全落在 [0-9a-f] 里，
    # 先按 hash 判断会把日期标签当成提交号留下来。
    ver_pat = re.compile(r"^v\d+\.\d+\.\d+")
    date_pat = re.compile(r"^20\d{6}$")
    sha_pat = re.compile(r"^[0-9a-f]{7,40}$")

    versions, shas, stale = [], [], []
    for t in tags:
        name = t["name"]
        if name == "latest":
            continue
        if ver_pat.match(name):
            versions.append(t)
        elif date_pat.match(name):
            # 旧机制留下的日期标签，已被 v<版本> 取代，直接清掉
            stale.append(t)
        elif sha_pat.match(name):
            shas.append(t)
        else:
            stale.append(t)

    for group in (versions, shas):
        group.sort(key=lambda x: x.get("last_updated", ""), reverse=True)

    # 版本号和 hash 是同一批镜像的两个名字，配对后算一版：
    # 版本标签按时间留前 N 个，超出部分的镜像连着它的 hash 一起删。
    keep_vers = {t["name"] for t in versions[:keep]}
    keep_shas = {t["name"] for t in shas[:keep]}

    doomed = [t["name"] for t in versions if t["name"] not in keep_vers]
    doomed += [t["name"] for t in shas if t["name"] not in keep_shas]
    doomed += [t["name"] for t in stale]

    log(f"保留版本 {len(keep_vers)} 个: {', '.join(sorted(keep_vers)) or '无'}")
    log(f"保留 hash {len(keep_shas)} 个: {', '.join(sorted(keep_shas)) or '无'}")
    if stale:
        log(f"清理旧格式标签: {', '.join(t['name'] for t in stale)}")

    if not doomed:
        log("没有需要清理的标签")
        return 0

    log(f"待删除 {len(doomed)} 个: {', '.join(doomed)}")
    if dry:
        log("DRY_RUN=1，不实际删除")
        return 0

    failed = 0
    for name in doomed:
        try:
            req(f"{API}/repositories/{repo}/tags/{name}/", "DELETE", token=jwt)
            log(f"  已删 {name}")
        except urllib.error.HTTPError as e:
            failed += 1
            log(f"::warning::删除 {name} 失败（{e.code}）")

    if failed:
        log(f"::warning::{failed} 个标签没删掉，下次构建会再试")
        return 0

    log("清理完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
