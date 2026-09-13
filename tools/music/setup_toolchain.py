# -*- coding: utf-8 -*-
"""音乐管线工具链安装 —— 幂等拉取渲染引擎与采样音源。

产出（全部落在仓库 `temp/music_toolchain/`，gitignored；可用环境变量
`MUSIC_TOOLCHAIN_DIR` 覆盖）：

    temp/music_toolchain/
      bin/fluidsynth/fluidsynth.exe        GM 音源渲染（弦乐/木管/竖琴/钟琴…）
      bin/sfizz/sfizz_render.exe           SFZ 渲染（钢琴，Salamander Grand Piano V3）
      sfz/SalamanderGrandPiano/…           钢琴 SFZ 定义（自包含，已按需裁剪）
      MANIFEST.json                        来源 / 版本 / 许可 / 校验清单

为什么要两个渲染器：Salamander 是 SFZ 采样库（sfizz 渲染），其余编制用
General MIDI SoundFont（fluidsynth 渲染）。两者都在**离线**阶段出 WAV 分轨，
游戏运行时只消费最终 OGG/WAV，不带任何合成器。

用法：
    python tools/music/setup_toolchain.py               # 全部拉齐
    python tools/music/setup_toolchain.py --skip-samples  # 只装渲染器
    python tools/music/setup_toolchain.py --verify        # 只校验已有文件
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
SALAMANDER_COMMIT = "master"

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


def _raw_url(repo: str, path: str) -> str:
    from urllib.parse import quote
    return "https://raw.githubusercontent.com/%s/%s/%s" % (
        repo, SALAMANDER_COMMIT, quote(path))


def _tree(repo: str) -> list:
    url = "https://api.github.com/repos/%s/git/trees/%s?recursive=1" % (repo, SALAMANDER_COMMIT)
    r = requests.get(url, timeout=60)
    r.raise_for_status()
    return r.json()["tree"]


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
        # sfizz 的 exe 在 bin/Release 子目录，统一拍平一层便于调用
        for exe in bin_dir.rglob("*.exe"):
            flat = bin_dir / exe.name
            if exe.parent != bin_dir and not flat.exists():
                flat.write_bytes(exe.read_bytes())
        marker.write_text(src["version"], encoding="utf-8")
        print("[toolchain] %-11s 安装完成 (%s)" % (key, src["version"]))
        manifest.setdefault("engines", {})[key] = {
            "version": src["version"], "url": src["url"], "license": src["license"],
            "role": src["role"], "sha256": _sha256(zpath),
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

    # 2) 采样子集
    tree = _tree(SALAMANDER_REPO)
    entries = {Path(t["path"]).name: t for t in tree
               if t["path"].endswith(".flac")}
    want_names = set()
    for name in entries:
        if name.startswith(EXTRA_SAMPLE_PREFIXES) and "$" not in name:
            want_names.add(name)
            continue
        for region in SAMPLE_REGIONS:
            for v in range(1, SAMPLE_VEL_MAX + 1):
                if name == "%sv%d.flac" % (region, v):
                    want_names.add(name)
    wanted = sorted("Samples/" + n for n in want_names)

    todo = [p for p in wanted if not (out / p).exists()]
    total_mb = sum(entries[Path(p).name]["size"] for p in todo) / 1e6
    print("[toolchain] 采样：需要 %d 个文件 / 待下载 %d 个 / 约 %.0f MB"
          % (len(wanted), len(todo), total_mb))

    done = 0
    errors = []

    def fetch(rel: str) -> None:
        _download(_raw_url(SALAMANDER_REPO, rel), out / rel)

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

    # 3) 生成裁剪版 SFZ（自包含：只引用已下载的采样）
    gen_trimmed_sfz(out)
    manifest["sample_library"] = {
        "name": "Salamander Grand Piano V3",
        "author": SALAMANDER_AUTHOR,
        "license": SALAMANDER_LICENSE,
        "repo": "https://github.com/%s" % SALAMANDER_REPO,
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

    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print("[toolchain] 清单写入 %s" % manifest_path)
    return verify(root)


if __name__ == "__main__":
    raise SystemExit(main())
