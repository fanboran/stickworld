# -*- coding: utf-8 -*-
"""旋律串烧 —— 只混"唱旋律的那一层"，回答一个问题：**这些曲子真的是不同的旋律吗**。

为什么单独做这一步：全层样带（`preview.py`）里旋律是"埋在伴奏里"的，验收者要
费劲分辨"换的是旋律还是配器"；而作曲侧最要紧的验收点恰恰是"17 首是 17 条旋律"。
所以这里把每首曲子里**承担旋律的那 1~2 层**（`cues.MELODY_LAYERS_BY_CUE` 声明）
单独混出来、每段**等响度归一**后串成一条——听起来就是"一部旋律集"的目录。

取段位置与全层串烧一致（循环曲从第 3 个 8 小节乐句起 = 情绪打开处），
一次性标点从头放。

    python tools/music/melody_reel.py                      # 全部 17 首
    python tools/music/melody_reel.py --cue night,village   # 只串指定几首
    python tools/music/melody_reel.py --seg 20 --out 某目录
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

from compose import cues as CUES                        # noqa: E402
from musiclib import export as EX                       # noqa: E402
from musiclib import mix as MIX                         # noqa: E402
from preview import encode                              # noqa: E402


def melody_layers(cue_id: str, cue) -> list:
    """该 cue 里唱旋律的层；未声明时退回 tier 0 的地基层。"""
    declared = CUES.MELODY_LAYERS_BY_CUE.get(cue_id)
    if declared:
        missing = [n for n in declared if n not in cue.stems]
        if missing:
            raise KeyError("%s 声明了不存在的旋律层 %s（实际层：%s）"
                           % (cue_id, missing, list(cue.stems)))
        return list(declared)
    tier = EX.cue_tier_map().get(cue_id, {})
    return [n for n, t in tier.items() if t == 0] or [next(iter(cue.stems))]


def take_window(audio, fs: int, start_s: float, dur_s: float,
                fade_s: float = 1.2):
    a = int(start_s * fs)
    b = min(len(audio), a + int(dur_s * fs))
    seg = audio[a:b].copy()
    n = min(int(fade_s * fs), len(seg) // 2)
    if n > 0:
        seg[:n] *= np.linspace(0.0, 1.0, n)[:, None]
        seg[-n:] *= np.linspace(1.0, 0.0, n)[:, None]
    return seg


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="旋律串烧（只混旋律层）")
    ap.add_argument("--out", default=str(REPO / "temp" / "music_preview"),
                    help="输出目录（与 preview.py 相同，便于一起交）")
    ap.add_argument("--cue", default=None, help="逗号分隔，只串指定 cue")
    ap.add_argument("--seg", type=float, default=24.0, help="每首段长（秒）")
    ap.add_argument("--gap", type=float, default=0.9, help="段间留白（秒）")
    ap.add_argument("--name", default="02_旋律串烧（只混旋律层）",
                    help="输出文件名前缀")
    ap.add_argument("--format", default="mp3", choices=["mp3", "ogg"])
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    fs = 48000
    ids = [s.strip() for s in args.cue.split(",") if s.strip()] if args.cue \
        else [cid for cid, _ in CUES.BUILDERS]

    parts, count = [], 0
    for cid in ids:
        cue = CUES.build_one(cid)
        layers = melody_layers(cid, cue)
        stems_dir = HERE / "out" / "stems" / cid
        paths = {n: str(stems_dir / ("%s.wav" % n)) for n in layers}
        missing = [p for p in paths.values() if not Path(p).exists()]
        if missing:
            print("[跳过] %s：缺分轨 %s（先跑 render_all.py）" % (cid, missing),
                  file=sys.stderr)
            continue
        # 等响度归一：这一条样带的用途是"比较旋律"，不该被配器厚薄影响
        audio, _rep = MIX.mix_cue(
            cue, paths,
            overrides=CUES.MIX_OVERRIDES.get(cid, {}),
            balance=CUES.LAYER_BALANCE_BY_CUE.get(cid, {}),
            target_lufs=-15.0, wrap_tail=getattr(cue, "loop", True))
        is_loop = getattr(cue, "loop", True)
        start = cue.seconds(cue.bar(16)) if is_loop else 0.0
        parts.append(take_window(audio, fs, start, args.seg, fade_s=1.2))
        parts.append(np.zeros((int(args.gap * fs), 2), dtype=np.float32))
        count += 1
        print("  %-14s %-10s 旋律层：%s" % (cid, cue.title, "+".join(layers)))

    if not parts:
        print("[错误] 没有可用的分轨；先跑：python tools/music/render_all.py",
              file=sys.stderr)
        return 2
    reel = np.concatenate(parts, axis=0)
    tmp = out_dir / "_tmp_melody_reel.wav"
    MIX.save_mix(reel, str(tmp))
    meta = encode(tmp, out_dir / ("%s.%s" % (args.name, args.format)),
                  args.format)
    tmp.unlink(missing_ok=True)
    print("\n[完成] %s（%d 首 / %.0f 秒 / %.2f MB）"
          % (out_dir / ("%s.%s" % (args.name, args.format)), count,
             len(reel) / fs, meta["mb"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
