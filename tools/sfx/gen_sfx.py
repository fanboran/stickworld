# -*- coding: utf-8 -*-
"""音效生成 —— 按 `sfxlib/design.py` 的配方一键生成全部交付件。

    <PY> tools/sfx/gen_sfx.py                 # 全部（32 件）
    <PY> tools/sfx/gen_sfx.py --only ui_hover,harvest_hit_a
    <PY> tools/sfx/gen_sfx.py --list          # 只列配方，不生成
    <PY> tools/sfx/gen_sfx.py --verify        # 重新生成一遍并与落盘文件比对 sha256

**幂等**：每个变体的随机种子由 `design.seed_of(文件名, 变体号)`（CRC32）决定，
与进程、时间、文件系统无关；交付件固定 48kHz / 立体声 / PCM_16。因此
"同参数 → 同字节"。`--verify` 就是把这条承诺变成可执行的检查。

产物：
  stick-world/assets/audio/sfx/<name>.wav   交付件（游戏加载的资产）
  tools/sfx/out/gen_report.json             生成与母带过程的记录（供 qa_sfx 引用）

`--verify` 与 `qa_sfx.py --check` 一起进 CI。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

import soundfile as sf                                   # noqa: E402
from sfxlib import design as D                           # noqa: E402
from sfxlib import post                                   # noqa: E402

SR = 48000
DELIVER = REPO / "stick-world" / "assets" / "audio" / "sfx"
OUT = HERE / "out"
REPORT = OUT / "gen_report.json"


def render(name: str, recipe: D.Recipe, index: int) -> tuple:
    """渲染一件（含母带链）。返回 (stereo float64, measure dict, info dict)。"""
    seed = D.seed_of(name, index)
    raw = recipe.build(SR, seed)
    audio, info = post.master(
        raw, SR,
        target_lufs=D.target_lufs(name),
        ceiling_dbtp=recipe.tp,
        tone_ops=recipe.tone,
        rev=recipe.rev,
        width=recipe.width,
        seed=seed,
        soft_clip=recipe.clip,
        max_s=recipe.max_s,
    )
    rep = post.measure(audio, SR, name,
                       lufs_target=D.target_lufs(name),
                       dur_range_ms=recipe.dur_ms)
    rep.update({
        "event": recipe.event,
        "category": recipe.category,
        "node": recipe.node,
        "seed": seed,
        "variant_index": index,
        "variants_in_event": len(recipe.files),
        "band_center_hz": recipe.band_center,
        "key_relation": recipe.key,
        "overlap": recipe.overlap,
        "sha256": hashlib.sha256(
            np.ascontiguousarray(audio.astype(np.float32)).tobytes()).hexdigest(),
    })
    rep.update(info)
    return audio, rep, info


def write_wav(path: Path, audio: np.ndarray, fs: int = SR) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), audio.astype(np.float32), fs, subtype="PCM_16")
    return path.stat().st_size


def select(only) -> list:
    if not only:
        return list(D.RECIPES)
    want = set()
    for chunk in only:
        want.update(s.strip() for s in chunk.split(",") if s.strip())
    out, unknown = [], []
    for name in sorted(want):
        try:
            out.append(D.by_file(name))
        except KeyError:
            unknown.append(name)
    if unknown:
        raise SystemExit("[错误] 配方里没有这些名字: %s\n（可先跑 --list 看全部名字）"
                         % ", ".join(unknown))
    return out


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="音效生成")
    ap.add_argument("--only", action="append", default=None,
                    help="只生成指定文件（逗号分隔可多个）")
    ap.add_argument("--out", default=str(DELIVER), help="输出目录")
    ap.add_argument("--list", action="store_true", help="只列配方")
    ap.add_argument("--verify", action="store_true",
                    help="重新渲染并与已落盘文件比对（幂等自检）")
    args = ap.parse_args()

    if args.list:
        print("%-22s %-12s %-28s %8s %7s  %s"
              % ("文件", "类别", "事件", "L_evt", "时长ms", "这是什么声音"))
        print("-" * 132)
        for r in D.RECIPES:
            for i, f in enumerate(r.files):
                print("%-22s %-12s %-28s %8.1f %7s  %s"
                      % (f, r.category, r.event, D.layer_of(r.category),
                         "—", r.what if i == 0 else ""))
        print("\n共 %d 件（%d 个事件）" % (len(D.all_files()), len(D.groups())))
        return 0

    out_dir = Path(args.out)
    wanted = select(args.only)
    jobs = [(f, r, i) for r in wanted for i, f in enumerate(r.files)]

    if args.verify:
        return _verify(jobs, out_dir)

    t0 = time.time()
    reports = []
    print("%-22s %-10s %7s %8s %8s %7s %6s %6s  %s"
          % ("文件", "类别", "时长ms", "L_evt", "目标", "dBTP", "峰均",
             "2-5kms", "交付"))
    print("-" * 118)
    for name, recipe, idx in jobs:
        audio, rep, info = render(name, recipe, idx)
        nbytes = write_wav(out_dir / ("%s.wav" % name), audio)
        rep["file"] = "stick-world/assets/audio/sfx/%s.wav" % name
        rep["bytes"] = nbytes
        reports.append(rep)
        flag = ""
        if abs(rep["lufs_error"]) > 0.5:
            flag += " ⚠响度偏%d" % round(rep["lufs_error"])
        if rep["duration_ms"] < recipe.dur_ms[0] or rep["duration_ms"] > recipe.dur_ms[1]:
            flag += " ⚠时长%.0fms越界" % rep["duration_ms"]
        print("%-22s %-10s %7.0f %8.2f %8.1f %7.2f %6.1f %6.0f  %5.0fKB%s"
              % (name, recipe.category, rep["duration_ms"], rep["event_lufs"],
                 D.target_lufs(name), rep["true_peak_dbtp"],
                 rep["crest_factor_db"], rep["band2_5k_busy_ms"],
                 nbytes / 1024.0, flag))

    OUT.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(
        {"sample_rate": SR, "count": len(reports), "reports": reports},
        ensure_ascii=False, indent=2), encoding="utf-8")
    print("-" * 118)
    print("共 %d 件 / %.1f 秒 / 报告 %s"
          % (len(reports), time.time() - t0,
             REPORT.relative_to(REPO).as_posix()))
    return 0


def _verify(jobs, out_dir: Path) -> int:
    """幂等自检：重渲染 → **按交付路径重新编码** → 与落盘文件逐字节比对。

    为什么是"重新编码后比字节"，而不是"读回来换算成 int16 再比"：
    libsndfile 的 float→PCM_16 满刻度用 **32768**（写：round(x·32768) 再夹到
    [-32768, 32767]；读：v/32768）。而 `round(disk·32767)` 与 `round(audio·32767)`
    的换算是两套口径，凡 |样点| 偏大的样点都会差 1 个 LSB —— 早期这样比对时
    34 件里约一半样点报"不同"，**那是换算口径不一致，不是渲染不确定**（同进程
    重渲染逐样点 max|diff| = 0）。直接比编码字节绕开换算口径，也比它更严格：
    RIFF 头、块对齐、量化结果全在比较范围内。
    """
    import io
    fails = []
    for name, recipe, idx in jobs:
        p = out_dir / ("%s.wav" % name)
        if not p.exists():
            fails.append("%s: 文件不存在" % name)
            continue
        audio, _rep, _info = render(name, recipe, idx)
        buf = io.BytesIO()
        sf.write(buf, audio.astype(np.float32), SR, format="WAV", subtype="PCM_16")
        fresh = buf.getvalue()
        disk = p.read_bytes()
        if fresh != disk:
            n = min(len(fresh), len(disk))
            diff = int(sum(1 for a, b in zip(fresh[:n], disk[:n]) if a != b))
            fails.append("%s: 字节不同（%d/%d 字节；长度 %d vs %d）"
                         % (name, diff, n, len(fresh), len(disk)))
    if fails:
        print("幂等检查失败 %d 项：" % len(fails))
        for f in fails:
            print("  - %s" % f)
        return 1
    print("幂等检查通过：%d 件全部与落盘文件逐字节一致（同 seed 同结果）。"
          % len(jobs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
