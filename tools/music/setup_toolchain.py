# -*- coding: utf-8 -*-
"""音乐管线工具链安装 —— 幂等拉取渲染引擎与采样音源。

产出（全部落在仓库 `temp/music_toolchain/`，gitignored；可用环境变量
`MUSIC_TOOLCHAIN_DIR` 覆盖）：

    temp/music_toolchain/
      bin/fluidsynth/fluidsynth.exe        GM 音源渲染（弦乐/木管/竖琴/钟琴…）
      bin/sfizz/sfizz_render.exe           SFZ 渲染（钢琴，Salamander Grand Piano V3）
      sfz/SalamanderGrandPiano/…           钢琴 SFZ 定义（自包含，已按需裁剪）
      soundfonts/MuseScore_General.sf3     GM SoundFont（编制声部的音源）
      MANIFEST.json                        来源 / 版本 / 许可 / 校验清单

**可复现性**：采样与 SoundFont 都按入库的 `tools/music/toolchain_pins.json` 下载，
并逐文件校验内容指纹（采样 = git blob sha1；SoundFont = sha256）。因此"同一 commit 的
代码 → 同一套音源 → 同一首曲子"。两处曾经让管线装不上的坑，现在都有兜底：

  - 采样原先靠**匿名** GitHub API 枚举文件树（限额 60/h），额度用尽即 403 → 改用清单；
  - SoundFont 原先**没有任何脚本会下载**（手工放置）→ 现在按 URL + sha256 自动装。

为什么要两个渲染器：Salamander 是 SFZ 采样库（sfizz 渲染），其余编制用
General MIDI SoundFont（fluidsynth 渲染）。两者都在**离线**阶段出 WAV 分轨，
游戏运行时只消费最终 OGG/WAV，不带任何合成器。

用法：
    python tools/music/setup_toolchain.py               # 全部拉齐
    python tools/music/setup_toolchain.py --skip-samples  # 只装渲染器
    python tools/music/setup_toolchain.py --verify        # 只校验已有文件（含指纹）
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

try:
    import requests
except ImportError:  # pragma: no cover
    print("需要 requests：pip install requests", file=sys.stderr)
    raise

REPO_ROOT = Path(__file__).resolve().parents[2]

# ─────────────────────────────── 来源清单 ────────────────────────────────

FLUIDSYNTH_VER = "2.3.4"
SFIZZ_VER = "1.2.3"
# 采样库 commit：**钉死**（原为 "master"，浮动引用 → 上游一动音色就变）。
# 真正生效的 commit 以 `tools/music/toolchain_pins.json` 为准（下面 _sample_plan 读它）；
# 这里的常量只是"清单缺失时回退到 API"的兜底值。
SALAMANDER_COMMIT = "3382bf9496bba2486f5ab0de55a264d1dfc38404"
## 钉版清单（入库）：采样文件列表 + commit + SoundFont 的 sha256。
## 为什么必须有它：原先靠匿名 GitHub API 枚举采样树，匿名限额 60/h，额度用尽即 403
## → 采样下不了 → 音乐无法重渲。清单化后①不依赖 API；②按 commit 不可变路径下载；
## ③逐文件校验 blob 指纹，保证"每次装到的是同一套采样"。
PIN_FILE = Path(__file__).with_name("toolchain_pins.json")
# GM SoundFont（MuseScore_General.sf3，MIT）——编制声部的音源，体积 39.9MB。
# 官方 osuosl 镜像；本机 curl 对该域解析失败（exit 6），下载走 requests 兜底。
SOUNDFONT_URL = ("https://ftp.osuosl.org/pub/musescore/soundfont/"
                 "MuseScore_General/MuseScore_General.sf3")

SOURCES = {
    "fluidsynth": {
        "url": ("https://github.com/FluidSynth/fluidsynth/releases/download/"
                "v%s/fluidsynth-%s-win10-x64.zip" % (FLUIDSYNTH_VER, FLUIDSYNTH_VER)),
        "version": FLUIDSYNTH_VER,
        "license": "LGPL-2.1-or-later",
        "role": "GM/SoundFont 渲染引擎（弦乐/木管/竖琴/钟琴等编制声部）",
    },
    "sfizz": {
        "url": ("https://github.com/sfztools/sfizz/releases/download/%s/"
                "sfizz-%s-win64.zip" % (SFIZZ_VER, SFIZZ_VER)),
        "version": SFIZZ_VER,
        "license": "BSD-2-Clause (sfizz) / 采样另计",
        "role": "SFZ 采样库渲染引擎（钢琴）",
    },
}

# Salamander Grand Piano V3 —— Yamaha C5，48kHz/24bit，16 力度层。
# 作者 Alexander Holm，许可 CC-BY 3.0（署名要求见 docs/技术/音频/音乐资产登记与来源.md）。
SALAMANDER_REPO = "sfzinstruments/SalamanderGrandPiano"
SALAMANDER_LICENSE = "CC-BY-3.0"
SALAMANDER_AUTHOR = "Alexander Holm"

# 采样裁剪：只取实际用到的音区与力度上限，控制下载量与磁盘占用。
#   音区 = SFZ region 的 pitch_keycenter 列表，覆盖 MIDI 33(A1) ~ 93(A6)
#   力度 = v1..v14（1~112）；v15/v16 是 ff/fff 力度，本项目音乐不需要，
#          且高力度采样偏亮偏硬，与"柔和"基调相悖。
SAMPLE_REGIONS = ["A1", "C2", "D#2", "F#2", "A2", "C3", "D#3", "F#3", "A3",
                  "C4", "D#4", "F#4", "A4", "C5", "D#5", "F#5", "A5", "C6",
                  "D#6", "F#6", "A6"]
SAMPLE_VEL_MAX = 14
# 力度层边界，与上游 Data/notes.txt 的 `<group> lovel=.. hivel=..` 逐行一致
VEL_BOUNDS = [(1, 26), (27, 34), (35, 36), (37, 43), (44, 46), (47, 50),
              (51, 56), (57, 64), (65, 72), (73, 80), (81, 88), (89, 96),
              (97, 104), (105, 112), (113, 120), (121, 127)]
# 非音符采样：制音器释放(rel{midi}.flac) / 琴弦共鸣(harm*) / 踏板机械噪声(pedal*)
# 体积小（~15MB）但决定"像不像真钢琴"，全部保留
EXTRA_SAMPLE_PREFIXES = ("rel", "harm", "pedal")

SFZ_DATA_FILES = ["notes.txt", "region.txt", "tune_nat.txt", "tune_ret.txt",
                  "hammer.txt", "pedal.txt", "str_res.txt"] + \
                 ["vel_%02d.txt" % i for i in range(1, 17)]


# ─────────────────────────────── 工具 ────────────────────────────────

def toolchain_dir() -> Path:
    env = os.environ.get("MUSIC_TOOLCHAIN_DIR")
    return Path(env) if env else REPO_ROOT / "temp" / "music_toolchain"


def _download(url: str, dest: Path, retries: int = 4) -> Path:
    """下载并原子落盘（.part → 改名），已存在则跳过。

    **优先走 curl**：本机实测 Python 的 requests/urllib 在部分 GitHub 主机上
    会长时间挂起（github.com 直连超时、raw.githubusercontent.com 偶发卡死），
    而 curl 两个都能通。故 curl 做主通道、requests 做兜底，避免整条管线
    卡在"看起来在下载、其实没动静"的状态上。
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    tmp = dest.with_suffix(dest.suffix + ".part")
    last = None

    def _try_curl() -> bool:
        if tmp.exists():
            tmp.unlink()
        subprocess.run(["curl", "-sL", "--fail", "--retry", "3",
                        "--connect-timeout", "30", "--max-time", "600",
                        "-o", str(tmp), url], check=True, timeout=660)
        return tmp.exists() and tmp.stat().st_size > 0

    def _try_requests() -> bool:
        with requests.get(url, stream=True, timeout=(20, 120)) as r:
            r.raise_for_status()
            with open(tmp, "wb") as f:
                for chunk in r.iter_content(1 << 16):
                    f.write(chunk)
        return tmp.exists() and tmp.stat().st_size > 0

    for _attempt in range(retries):
        for fn in (_try_curl, _try_requests):
            try:
                if fn():
                    tmp.replace(dest)
                    return dest
                last = RuntimeError("%s 产出为空" % fn.__name__)
            except Exception as e:  # noqa: BLE001
                last = e
    raise RuntimeError("下载失败 %s: %s" % (url, last))


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _raw_url(repo: str, path: str, commit: str = "") -> str:
    from urllib.parse import quote
    return "https://raw.githubusercontent.com/%s/%s/%s" % (
        repo, commit or SALAMANDER_COMMIT, quote(path))


def _git_blob_sha1(path: Path) -> str:
    """文件的 git blob 哈希（`sha1("blob <len>\\0" + 内容)`）——钉版清单里存的就是它，
    与 GitHub tree API 的 `sha` 字段同口径，可逐文件校验内容。"""
    h = hashlib.sha1()
    h.update(b"blob %d\0" % path.stat().st_size)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _github_headers() -> dict:
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    return {"Authorization": "Bearer " + tok} if tok else {}


def _sample_plan() -> tuple:
    """返回 `({相对路径: {"size": int, "git_sha1": str}}, commit, 来源说明)`。

    **优先读入库的钉版清单** `tools/music/toolchain_pins.json`：不调用 GitHub API
    （匿名限额 60 次/小时，曾因此 403 让整条音乐管线装不上），且 commit 固定 →
    采样与当初渲染交付件时同源同版本，**音色可复现**。
    清单缺失时回退到 API 枚举：带 GITHUB_TOKEN 走认证，否则会撞限额（会明确告警）。
    """
    if PIN_FILE.exists():
        pins = json.loads(PIN_FILE.read_text(encoding="utf-8"))
        sal = pins.get("salamander", {})
        files = sal.get("files") or {}
        if files:
            return files, sal.get("commit", SALAMANDER_COMMIT), \
                "%s（commit %s）" % (PIN_FILE.name, str(sal.get("commit"))[:12])

    print("[toolchain] ⚠ 未找到 %s，回退到 GitHub API 枚举（匿名限额 60/h，可能 403；"
          "建议从仓库取回该文件）" % PIN_FILE.name)
    commit = SALAMANDER_COMMIT
    url = "https://api.github.com/repos/%s/git/trees/%s?recursive=1" % (SALAMANDER_REPO, commit)
    r = requests.get(url, headers=_github_headers(), timeout=60)
    if r.status_code == 403:
        raise RuntimeError(
            "GitHub API 403（限额/无认证）。要么设置 GITHUB_TOKEN，要么从仓库取回 %s"
            % PIN_FILE.name)
    r.raise_for_status()
    tree = r.json()["tree"]
    files = {t["path"]: {"size": int(t["size"]), "git_sha1": t["sha"]}
             for t in tree if t["type"] == "blob" and t["path"].endswith(".flac")}
    return files, commit, "API 枚举（浮动，未钉版）"


# ─────────────────────────────── 阶段 ────────────────────────────────

def install_engines(root: Path, manifest: dict) -> None:
    for key in ("fluidsynth", "sfizz"):
        src = SOURCES[key]
        bin_dir = root / "bin" / key
        marker = bin_dir / (".installed-%s" % src["version"])
        if marker.exists():
            print("[toolchain] %-11s 已就位 (%s)" % (key, src["version"]))
            continue
        zpath = _download(src["url"], root / "downloads" / ("%s-%s.zip" % (key, src["version"])))
        bin_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zpath) as z:
            z.extractall(bin_dir)
        # sfizz 的 exe 在 bin/Release 子目录，统一拍平一层便于调用。
        # **DLL 必须一起拍平**：只复制 exe 会得到一个"找不到 DLL"的副本
        # （报 3221225781 / bash 127），而 render._exe 的 DLL 打分逻辑只是绕开它，
        # 手工调用照样踩坑——所以这里直接把 DLL 也放到拍平后的 exe 旁边。
        for exe in bin_dir.rglob("*.exe"):
            flat = bin_dir / exe.name
            if exe.parent != bin_dir and not flat.exists():
                flat.write_bytes(exe.read_bytes())
                for dll in exe.parent.glob("*.dll"):
                    (bin_dir / dll.name).write_bytes(dll.read_bytes())
        marker.write_text(src["version"], encoding="utf-8")
        print("[toolchain] %-11s 安装完成 (%s)" % (key, src["version"]))
        manifest.setdefault("engines", {})[key] = {
            "version": src["version"], "url": src["url"], "license": src["license"],
            "role": src["role"], "sha256": _sha256(zpath),
        }


def install_soundfont(root: Path, manifest: dict) -> None:
    """拉取 GM SoundFont（MuseScore_General.sf3，MIT）到工具链的 soundfonts/。

    **这是原先最容易"复现不出来"的一环**：编制声部（弦乐/竖琴/钟琴/木管/定音鼓）
    全部靠它，但早先它只写在登记档里、**没有任何脚本会下载它**，render_all 只会在缺它时
    报"需要一份 GM SoundFont…"然后退出。现在按钉版清单里的 URL + sha256 自动装。
    """
    pins = json.loads(PIN_FILE.read_text(encoding="utf-8")) if PIN_FILE.exists() else {}
    sf = pins.get("soundfont", {})
    url = sf.get("url", SOUNDFONT_URL)
    name = sf.get("name", "MuseScore_General.sf3")
    dst = root / "soundfonts" / name
    # 标记文件**不能带 .sf2/.sf3 扩展名**：render.soundfont() 是按 `*.sf3` glob 取音源的，
    # 带扩展名的标记会被当成音源传给 fluidsynth（后果是**静默渲染出空轨**，曾因此
    # 让弦乐层变成 1kbps 的空 ogg）。
    marker = root / "soundfonts" / (".installed-" + Path(name).stem)
    if dst.exists() and dst.stat().st_size > 0:
        print("[toolchain] soundfont 已就位 (%s)" % name)
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        # _download 的 curl 优先在本域会失败（DNS），其 requests 兜底能通
        _download(url, dst, retries=3)
        print("[toolchain] soundfont 下载完成 (%s / %.1f MB)"
              % (name, dst.stat().st_size / 1e6))

    got = _sha256(dst)
    want = sf.get("sha256")
    if want and got != want:
        raise RuntimeError(
            "SoundFont 内容与钉版清单不一致（音色会变）：\n"
            "       期望 sha256 %s\n       实测        %s\n"
            "       若不是有意的版本变更，删掉 %s 重下"
            % (want, got, dst))
    size = int(dst.stat().st_size)
    if sf.get("size") and size != int(sf["size"]):
        print("[toolchain] ⚠ SoundFont 体积 %d 与清单 %s 不同（哈希已过，仅提示）"
              % (size, sf["size"]))

    # 署名义乌（MIT 要求保留致谢；发布 credits 直接用这份）
    (root / "soundfonts" / "README.txt").write_text(
        "%s\n\n来源：%s\n体积：%d 字节\nsha256：%s\n许可：%s\n署名义务：%s\n"
        % (name, url, size, got, sf.get("license", "MIT"),
           sf.get("attribution", "")), encoding="utf-8")
    marker.write_text(got, encoding="utf-8")
    manifest["soundfont"] = {
        "name": name, "url": url, "size": size, "sha256": got,
        "license": sf.get("license", "MIT"),
        "attribution": sf.get("attribution", ""),
        "role": sf.get("role", "GM 编制声部"),
    }


def engine_exe(root: Path, key: str) -> Path:
    names = {"fluidsynth": "fluidsynth.exe", "sfizz": "sfizz_render.exe"}
    return root / "bin" / key / names[key]


def install_salamander(root: Path, manifest: dict, workers: int = 8) -> None:
    """拉取 Salamander Grand Piano V3 的 SFZ 定义与**裁剪后的**采样子集。"""
    out = root / "sfz" / "SalamanderGrandPiano"
    samples = out / "Samples"
    data = out / "Data"
    out.mkdir(parents=True, exist_ok=True)
    data.mkdir(parents=True, exist_ok=True)
    samples.mkdir(parents=True, exist_ok=True)

    # 1) SFZ 定义 + Data 表（体积小，串行即可）
    for name in ["Salamander Grand Piano V3.sfz"]:
        dst = out / name
        if not dst.exists():
            _download(_raw_url(SALAMANDER_REPO, name), dst)
    for name in SFZ_DATA_FILES:
        dst = data / name
        if not dst.exists():
            _download(_raw_url(SALAMANDER_REPO, "Data/" + name), dst)
    print("[toolchain] SFZ 定义与 Data 表就位 (%d 个)" % (len(SFZ_DATA_FILES) + 1))

    # 2) 采样子集 —— 按**钉版清单**下（不再依赖 GitHub API 限额），逐文件校验内容指纹
    plan, commit, plan_src = _sample_plan()
    wanted = sorted(p for p in plan if p.startswith("Samples/"))
    todo = [p for p in wanted if not (out / p).exists()]
    total_mb = sum(int(plan[p]["size"]) for p in todo) / 1e6
    print("[toolchain] 采样来源：%s" % plan_src)
    print("[toolchain] 采样：需要 %d 个文件 / 待下载 %d 个 / 约 %.0f MB"
          % (len(wanted), len(todo), total_mb))

    done = 0
    errors = []
    bad_hash = []

    def fetch(rel: str) -> None:
        _download(_raw_url(SALAMANDER_REPO, rel, commit), out / rel)
        # 内容指纹（git blob sha1）：钉版清单在册的必须一致——这是"同一次渲染"的保证
        want = plan.get(rel, {}).get("git_sha1")
        if want and _git_blob_sha1(out / rel) != want:
            bad_hash.append(rel)

    if todo:
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = {ex.submit(fetch, p): p for p in todo}
            for fut in as_completed(futs):
                rel = futs[fut]
                try:
                    fut.result()
                except Exception as e:  # noqa: BLE001
                    errors.append((rel, str(e)))
                done += 1
                if done % 25 == 0 or done == len(todo):
                    print("            %d/%d" % (done, len(todo)))

    if errors:
        raise RuntimeError("有 %d 个采样下载失败，重跑本脚本续传：%s"
                           % (len(errors), errors[:3]))
    if bad_hash:
        raise RuntimeError(
            "有 %d 个采样内容与钉版清单不一致（音色会变）：%s\n"
            "       若不是有意的版本变更，请删掉这些文件重下；"
            "若确实要换版本，重跑 temp/gen_toolchain_pins.py 更新清单"
            % (len(bad_hash), bad_hash[:3]))

    # 3) 生成裁剪版 SFZ（自包含：只引用已下载的采样）
    gen_trimmed_sfz(out)
    manifest["sample_library"] = {
        "name": "Salamander Grand Piano V3",
        "author": SALAMANDER_AUTHOR,
        "license": SALAMANDER_LICENSE,
        "repo": "https://github.com/%s" % SALAMANDER_REPO,
        "commit": commit,
        "pinned_by": plan_src,
        "engine": "sfizz %s" % SFIZZ_VER,
        "regions": SAMPLE_REGIONS,
        "velocity_layers": "v1..v%d" % SAMPLE_VEL_MAX,
        "file_count": len(wanted),
        "size_mb": round(sum((out / p).stat().st_size for p in wanted) / 1e6, 1),
    }
    print("[toolchain] 钢琴采样就位：%d 文件 / %.0f MB"
          % (len(wanted), manifest["sample_library"]["size_mb"]))


def gen_trimmed_sfz(out: Path) -> None:
    """生成裁剪版 SFZ：**保留原始结构与全部细节层**，只裁剪 region 表。

    原始 SFZ 的细节层（琴弦共鸣 str_res / 制音器释放 rel / 踏板噪声 pedal）
    由 Data/ 下的独立表定义并通过 CC 门控，体积小（~15MB）且是"这台钢琴听起来
    像真钢琴"的重要来源，因此**整份保留**。

    唯一会出问题的是 region 表：裁剪采样后，原始 region.txt 会引用不存在的
    采样文件，sfizz 对缺失采样是**静默丢音**（某个音突然没有了，很难查）。
    所以这里生成一份只含已下载音区的 `region_trim.txt`，并让 `notes_trim.txt`
    指向它；`vel_NN.txt` 原样复用（未被引用的宏定义无害）。
    """
    data = out / "Data"

    kept, dropped = [], 0
    for line in (data / "region.txt").read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped.startswith("<region>"):
            kept.append(line.rstrip())
            continue
        tpl = ""
        for tok in stripped[len("<region>"):].split():
            if tok.startswith("sample="):
                tpl = tok.split("=", 1)[1]
        note = tpl.split("$VEL")[0]
        if note in SAMPLE_REGIONS:
            kept.append(line.rstrip())
        else:
            dropped += 1
    (data / "region_trim.txt").write_text("\n".join(kept) + "\n", encoding="utf-8")

    notes = []
    for v in range(1, 17):
        lo, hi = VEL_BOUNDS[v - 1]
        notes.append('<group> #include "Data/vel_%02d.txt" lovel=%d hivel=%d '
                     '#include "Data/region_trim.txt"' % (v, lo, hi))
    (data / "notes_trim.txt").write_text("\n".join(notes) + "\n", encoding="utf-8")

    src = (out / "Salamander Grand Piano V3.sfz").read_text(encoding="utf-8")
    header = (
        "// Salamander Grand Piano V3 (Yamaha C5) —— 裁剪版。\n"
        "// 由 tools/music/setup_toolchain.py 生成，请勿手工编辑。\n"
        "// 音区：%s（覆盖 MIDI 33~93）；力度层：v1..v%d（1~112）。\n"
        "// 许可 CC-BY 3.0，作者 %s；署名登记见 docs/技术/音频/音乐资产登记与来源.md。\n"
        % (" ".join(SAMPLE_REGIONS), SAMPLE_VEL_MAX, SALAMANDER_AUTHOR)
    )
    body = src.replace('"Data/notes.txt"', '"Data/notes_trim.txt"')
    (out / "piano.sfz").write_text(header + body, encoding="utf-8")
    print("[toolchain] 生成裁剪版 piano.sfz：保留 %d 个 region、裁掉 %d 个（音区外）"
          % (len([l for l in kept if l.strip().startswith("<region>")]), dropped))


# ─────────────────────────────── 校验 ────────────────────────────────

def verify(root: Path) -> int:
    ok = True
    for key in ("fluidsynth", "sfizz"):
        exe = engine_exe(root, key)
        status = "OK" if exe.exists() else "缺失"
        if not exe.exists():
            ok = False
        print("[verify] %-11s %-40s %s" % (key, exe.relative_to(root), status))
    piano = root / "sfz" / "SalamanderGrandPiano"
    sfz = piano / "piano.sfz"
    n_samples = len(list((piano / "Samples").glob("*.flac"))) if piano.exists() else 0
    print("[verify] %-11s %-40s %s" % ("piano sfz", "sfz/SalamanderGrandPiano/piano.sfz",
                                       "OK" if sfz.exists() else "缺失"))
    print("[verify] %-11s %-40s %d 个采样" % ("piano 采样", "Samples/*.flac", n_samples))
    if not sfz.exists() or n_samples < 100:
        ok = False
    # 钉版校验：采样指纹 + SoundFont 哈希（这两项决定"音色是否与当初一致"）
    if PIN_FILE.exists():
        pins = json.loads(PIN_FILE.read_text(encoding="utf-8"))
        plan = pins.get("salamander", {}).get("files", {})
        sample_plan = {p: v for p, v in plan.items() if p.startswith("Samples/")}
        bad = []
        for rel, meta in sample_plan.items():
            f = piano / rel
            if not f.exists():
                bad.append(rel + "（缺）")
            elif meta.get("git_sha1") and _git_blob_sha1(f) != meta["git_sha1"]:
                bad.append(rel + "（指纹不符）")
        print("[verify] %-11s %-40s %s" % ("采样指纹", "vs toolchain_pins.json",
                                           "全部一致" if not bad else "%d 项异常" % len(bad)))
        if bad:
            ok = False
            for b in bad[:5]:
                print("           - %s" % b)
        sf = pins.get("soundfont", {})
        sf_path = root / "soundfonts" / sf.get("name", "MuseScore_General.sf3")
        if not sf_path.exists():
            print("[verify] %-11s %-40s %s" % ("soundfont", sf.get("name", ""), "缺失"))
            ok = False
        else:
            hit = (not sf.get("sha256")) or (_sha256(sf_path) == sf["sha256"])
            print("[verify] %-11s %-40s %s" % ("soundfont", sf_path.name,
                                               "OK（sha256 一致）" if hit else "内容与清单不符"))
            ok = ok and hit
    return 0 if ok else 1


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="音乐管线工具链安装")
    ap.add_argument("--skip-samples", action="store_true", help="只装渲染引擎")
    ap.add_argument("--verify", action="store_true", help="只校验已有文件")
    ap.add_argument("--workers", type=int, default=8, help="采样并发下载数")
    args = ap.parse_args()

    root = toolchain_dir()
    root.mkdir(parents=True, exist_ok=True)
    print("[toolchain] 目录：%s" % root)

    if args.verify:
        return verify(root)

    manifest_path = root / "MANIFEST.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {}
    manifest["toolchain_dir"] = str(root.relative_to(REPO_ROOT)) if root.is_relative_to(REPO_ROOT) else str(root)

    install_engines(root, manifest)
    if not args.skip_samples:
        install_salamander(root, manifest, workers=args.workers)
        install_soundfont(root, manifest)

    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print("[toolchain] 清单写入 %s" % manifest_path)
    return verify(root)


if __name__ == "__main__":
    raise SystemExit(main())
