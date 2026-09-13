# -*- coding: utf-8 -*-
"""音色体检 —— 八度带能量分布 + 频谱斜率 + 有源帧谱质心。

为什么单独做一个工具：混音配方里的每一条增益都应该**由测量决定**，而不是
凭"钢琴偏亮/弦乐偏厚"这类成见去填。本工具给出可比对的基线数值，改完配方
再跑一次就能看出动的是哪一段、动了多少。

    python tools/music/tone_check.py                       # 检查全部母带
    python tools/music/tone_check.py --stems interior      # 检查某首的分轨
    python tools/music/tone_check.py --raw C4v10.flac      # 检查单个采样文件

判读参考（钢琴独奏、轻柔力度下的自然分布，实测标定见音乐质检规范）：
    40-100Hz   <10%     隆隆/房间感
    100-250Hz  10-25%   低音区基频
    250-500Hz  20-40%   中低音区基频
    500-1k     15-30%   中音区基频 + 前几个泛音
    1-2k       5-15%    泛音，"清晰度"
    2-4k       2-8%     泛音，"存在感"（刺耳的高风险区，但完全缺失=发闷）
    4-8k       0.5-3%   锤击/空气感
    8-16k      0.1-1%   空气感
斜率 -6 ~ -9 dB/oct 是常见原声钢琴；比 -9 更陡说明偏闷，比 -6 更平说明偏亮。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal as sg

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

OUT = HERE / "out"
MASTER = OUT / "master"
DELIVER = REPO / "stick-world" / "assets" / "audio" / "bgm"
TOOLCHAIN = Path("temp/music_toolchain")

EDGES = [(40, 100), (100, 250), (250, 500), (500, 1000), (1000, 2000),
         (2000, 4000), (4000, 8000), (8000, 16000)]


def _label(lo: int, hi: int) -> str:
    if lo >= 1000:
        return "%dk-%dk" % (lo // 1000, hi // 1000)
    if hi >= 1000:
        return "%d-%dk" % (lo, hi // 1000)
    return "%d-%d" % (lo, hi)


def report(path: Path, label: str = "") -> dict:
    x, sr = sf.read(str(path), always_2d=True, dtype="float64")
    m = x.mean(axis=1)
    f, P = sg.welch(m, fs=sr, nperseg=8192)
    tot = float(P[(f >= 40) & (f <= 16000)].sum()) + 1e-20
    res = {"file": str(path), "label": label or path.stem,
           "peak": float(np.max(np.abs(m))), "sr": sr,
           "duration_s": round(len(m) / sr, 2)}
    for lo, hi in EDGES:
        sel = (f >= lo) & (f < hi)
        res[_label(lo, hi)] = round(100.0 * float(P[sel].sum()) / tot, 2)
    band = (f >= 200) & (f <= 8000) & (P > 0)
    res["slope_db_oct"] = round(float(np.polyfit(np.log2(f[band]),
                                                 10 * np.log10(P[band]), 1)[0]), 2)

    # 有源帧谱质心（排除近静音帧，否则静音帧的数值噪声会拉低统计）
    f2, _t, Z = sg.stft(m, fs=sr, nperseg=2048, noverlap=1536)
    mag = np.abs(Z) ** 2
    e = mag.sum(axis=0)
    act = e > (e.max() * 1e-6)
    if act.any():
        cent = (f2[:, None] * mag).sum(axis=0) / (e + 1e-20)
        res["centroid_p50_hz"] = int(np.percentile(cent[act], 50))
        res["centroid_p95_hz"] = int(np.percentile(cent[act], 95))
        res["active_frames_pct"] = round(100.0 * float(act.mean()), 1)
    return res


def print_table(rows: list) -> None:
    keys = [_label(lo, hi) for lo, hi in EDGES]
    head = "%-26s%7s" % ("文件", "峰值") + "".join("%9s" % k for k in keys) \
        + "%9s%9s%9s" % ("斜率", "质心50", "质心95")
    print(head)
    print("-" * len(head))
    for r in rows:
        line = "%-26s%7.3f" % (r["label"][:26], r["peak"])
        line += "".join("%9.2f" % r.get(k, 0.0) for k in keys)
        line += "%9.2f%9d%9d" % (r.get("slope_db_oct", 0.0),
                                 r.get("centroid_p50_hz", 0),
                                 r.get("centroid_p95_hz", 0))
        print(line)


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="音色体检")
    ap.add_argument("--stems", metavar="CUE", help="检查某首曲子的分轨")
    ap.add_argument("--raw", metavar="FILE", help="检查单个音频文件")
    ap.add_argument("--delivered", action="store_true", help="检查交付的 OGG")
    args = ap.parse_args()

    rows = []
    if args.raw:
        p = Path(args.raw)
        if not p.exists():
            p = TOOLCHAIN / "sfz" / "SalamanderGrandPiano" / "Samples" / args.raw
        if not p.exists():
            print("找不到文件：%s" % args.raw, file=sys.stderr)
            return 2
        rows = [report(p)]
    elif args.stems:
        d = OUT / "stems" / args.stems
        if not d.exists():
            print("找不到分轨目录：%s" % d, file=sys.stderr)
            return 2
        rows = [report(p, "%s/%s" % (args.stems, p.stem))
                for p in sorted(d.glob("*.wav"))]
    else:
        src = DELIVER if args.delivered else MASTER
        files = sorted(src.glob("*.ogg")) if args.delivered else sorted(src.glob("*.wav"))
        if args.delivered:
            files = sorted(src.glob("*/*.ogg"))
        for p in files:
            rows.append(report(p, str(p.relative_to(src)).replace("\\", "/")))
    if not rows:
        print("没有可测的音频。", file=sys.stderr)
        return 2
    print_table(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
