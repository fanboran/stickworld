# -*- coding: utf-8 -*-
"""生成 tools/music/toolchain_pins.json —— 把音乐渲染工具链钉死。

为什么需要它（本次踩坑）：`setup_toolchain.py` 原先用**匿名** GitHub API 枚举
Salamander 采样仓库的文件树，匿名限额 60 次/小时。额度用尽后安装直接 403：

    HTTPError: 403 Client Error: rate limit exceeded for url:
    https://api.github.com/repos/sfzinstruments/SalamanderGrandPiano/git/trees/master?recursive=1

→ 采样列表拿不到 → 钢琴装不上 → 音乐无法重渲。而且 `SALAMANDER_COMMIT = "master"`
是**浮动引用**，即便装上也未必是当初那套采样（音色会变）。

本脚本用一次**带 token 的** API 调用把"该下哪些文件 + 每个文件的内容指纹（git blob SHA1）"
固化进 `toolchain_pins.json`（入库）。之后 `setup_toolchain.py` 只读这份清单：
①不再需要 API（免疫限额）；②按 commit 下的不可变路径下载；③逐个校验指纹（音色可复现）。

用法：
    GITHUB_TOKEN=... <PY> tools/music/gen_toolchain_pins.py
（也接受 GH_TOKEN；两者都没有时本脚本拒绝运行——匿名调用会污染诊断，见 AGENTS.md）
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import requests

REPO_ROOT = Path(__file__).resolve().parents[2]
MUSIC = Path(__file__).resolve().parent
sys.path.insert(0, str(MUSIC))

from setup_toolchain import (                                    # noqa: E402
    EXTRA_SAMPLE_PREFIXES, SALAMANDER_REPO, SAMPLE_REGIONS,
    SAMPLE_VEL_MAX, SFZ_DATA_FILES, SOURCES, SFIZZ_VER, FLUIDSYNTH_VER,
)
PIN_FILE = MUSIC / "toolchain_pins.json"
SFZ_NAME = "Salamander Grand Piano V3.sfz"
SOUNDFONT_URL = ("https://ftp.osuosl.org/pub/musescore/soundfont/"
                 "MuseScore_General/MuseScore_General.sf3")


def token() -> str:
    t = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not t:
        print("拒绝匿名调用：请设置 GITHUB_TOKEN（见 AGENTS.md「GitHub 查询走 MCP」）",
              file=sys.stderr)
        raise SystemExit(2)
    return t


def fetch_tree(commit: str) -> dict:
    url = "https://api.github.com/repos/%s/git/trees/%s?recursive=1" % (SALAMANDER_REPO, commit)
    r = requests.get(url, headers={"Authorization": "Bearer " + token()}, timeout=60)
    r.raise_for_status()
    return r.json()


def main() -> int:
    # ① 解析 master 当前的 commit（只此一次；之后一律按这个 SHA 走不可变路径）
    head = requests.get("https://api.github.com/repos/%s/commits/master" % SALAMANDER_REPO,
                        headers={"Authorization": "Bearer " + token()}, timeout=60)
    head.raise_for_status()
    commit = head.json()["sha"]
    print("[pins] SalamanderGrandPiano master = %s" % commit)

    tree = fetch_tree(commit)["tree"]
    blobs = {t["path"]: t for t in tree if t["type"] == "blob"}
    print("[pins] 仓库条目 %d（其中 blob %d）" % (len(tree), len(blobs)))

    # ② 选定文件集合——与 setup_toolchain.install_salamander 的筛选口径**逐条一致**
    names = {Path(p).name: p for p in blobs if p.endswith(".flac")}
    want: set[str] = set()
    for name in names:
        if name.startswith(EXTRA_SAMPLE_PREFIXES) and "$" not in name:
            want.add("Samples/" + name)
            continue
        for region in SAMPLE_REGIONS:
            for v in range(1, SAMPLE_VEL_MAX + 1):
                if name == "%sv%d.flac" % (region, v):
                    want.add("Samples/" + name)
    want.add(SFZ_NAME)
    for f in SFZ_DATA_FILES:
        want.add("Data/" + f)

    missing = [p for p in sorted(want) if p not in blobs]
    if missing:
        print("[pins] 这些路径在上游不存在，拒绝生成：%s" % missing[:5], file=sys.stderr)
        return 3

    files = {p: {"size": int(blobs[p]["size"]), "git_sha1": blobs[p]["sha"]}
             for p in sorted(want)}
    total = sum(v["size"] for v in files.values())
    print("[pins] 选定 %d 个文件 / %.1f MB" % (len(files), total / 1e6))

    # ③ SoundFont：下载一次算 sha256（与登记档的 39.9MB 对照）
    #    注意：本机 curl 对 ftp.osuosl.org 解析失败（exit 6），requests 能通——
    #    与"curl 优先"的一般策略相反，故这里直接用 requests。
    sf_dir = REPO_ROOT / "temp" / "music_toolchain" / "downloads"
    sf_dir.mkdir(parents=True, exist_ok=True)
    sf_path = sf_dir / "MuseScore_General.sf3"
    if not sf_path.exists() or sf_path.stat().st_size == 0:
        with requests.get(SOUNDFONT_URL, stream=True, timeout=(20, 300)) as r:
            r.raise_for_status()
            with open(sf_path, "wb") as f:
                for chunk in r.iter_content(1 << 20):
                    f.write(chunk)
    h = hashlib.sha256()
    with open(sf_path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    sf_sha = h.hexdigest()
    print("[pins] SoundFont %d 字节 sha256=%s…" % (sf_path.stat().st_size, sf_sha[:16]))

    pins = {
        "_note": ("音乐渲染工具链的钉版清单：让 setup_toolchain.py 不再依赖 GitHub API 限额、"
                  "并保证每次装到的是同一套采样（音色可复现）。由 tools/music/gen_toolchain_pins.py 生成。"),
        "engines": {k: {"version": v["version"], "url": v["url"], "license": v["license"]}
                    for k, v in SOURCES.items()},
        "salamander": {
            "repo": SALAMANDER_REPO,
            "commit": commit,
            "raw_base": "https://raw.githubusercontent.com/%s/%s" % (SALAMANDER_REPO, commit),
            "file_count": len(files),
            "size_mb": round(total / 1e6, 1),
            "files": files,
        },
        "soundfont": {
            "name": "MuseScore_General.sf3",
            "url": SOUNDFONT_URL,
            "size": sf_path.stat().st_size,
            "sha256": sf_sha,
            "license": "MIT",
            "attribution": ("FluidR3 (Frank Wen) / FluidR3Mono (Michael Cowgill) / "
                            "MuseScore_General 适配 (S. Christian Collins)，MIT"),
            "role": "GM/SoundFont 编制声部（弦乐/竖琴/钟琴/木管/定音鼓等）",
        },
    }
    PIN_FILE.write_text(json.dumps(pins, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("[pins] 已写入 %s（sfizz %s / fluidsynth %s）"
          % (PIN_FILE.relative_to(REPO_ROOT), SFIZZ_VER, FLUIDSYNTH_VER))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
