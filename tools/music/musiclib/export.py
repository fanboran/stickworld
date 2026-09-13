# -*- coding: utf-8 -*-
"""交付导出 —— 母带 WAV → 游戏用的 OGG + 清单 JSON。

编码用 imageio-ffmpeg 自带的 ffmpeg（`-c:a libvorbis`），而不是 soundfile：
libsndfile 的 Vorbis 编码器不暴露质量参数，默认码率偏低（约 130kbps），
对这种以钢琴独奏为主体、大量弱奏细节的音乐不够用。ffmpeg 可以开到 q=6
（约 190kbps），在体积与音质之间取得可接受的平衡。

**OGG 的循环信息不进文件**：Godot 的 AudioStreamOggVorbis 把循环点放在
`loop_offset` / `beat_count` / `bpm` 上，且不读取内嵌元数据。所以循环信息
统一写进 `music_manifest.json`，由代码在加载时赋值——单一真相源，
避免"文件里的信息"和"代码里的信息"两处不一致。
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path


def ffmpeg_exe() -> str:
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


def ogg_encode(wav_path: str, ogg_path: str, quality: int = 6,
               sr: int = 48000, channels: int = 2) -> dict:
    """WAV → OGG Vorbis。quality 0~10（本项目用 6，约 190kbps）。"""
    out = Path(ogg_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [ffmpeg_exe(), "-y", "-loglevel", "error", "-i", str(wav_path),
           "-c:a", "libvorbis", "-q:a", str(quality),
           "-ar", str(sr), "-ac", str(channels), str(out)]
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode != 0 or not out.exists():
        raise RuntimeError("OGG 编码失败：%s\n%s" % (proc.returncode, proc.stderr[-2000:]))
    return {"ogg": str(out), "bytes": out.stat().st_size,
            "kbps": round(out.stat().st_size * 8 / 1000.0
                          / max(0.001, _duration(wav_path)), 1)}


def _duration(wav_path: str) -> float:
    import soundfile as sf
    return sf.info(wav_path).duration


def cue_tier_map() -> dict:
    """每个 cue 各层所属的强度档位（tier）。

    引擎据此做纵向混音：tier 0 常驻，tier 越高越"热闹"，按游戏状态逐层淡入。
    这张表是"哪一层在什么强度出现"的唯一真相源，作曲与引擎都读它。
    """
    return {
        "menu_title":  {"piano": 0, "strings": 1},
        "field_day":   {"piano": 0, "strings": 1, "harp": 2, "bells": 2},
        "field_night": {"piano": 0, "strings": 1, "bells": 2},
        "village":     {"piano": 0, "guitar": 1, "marimba": 2, "winds": 2},
        "interior":    {"piano": 0},
        "strategic":   {"pad": 0, "vibraphone": 1, "piano": 1, "bells": 2},
        "battle":      {"piano": 0, "strings": 1, "perc": 1, "winds": 2},
        "sting_victory": {"mix": 0},
        "sting_defeat":  {"mix": 0},
    }


# 交付给引擎的每层默认音量：**一律 unity（0dB）**。
#
# 为什么是 0 而不是"各层给个 -3/-5dB"：分层文件在渲染阶段就已经带着**配平后的
# 音量**（相对钢琴的目标偏移由 mix.py 的 LAYER_BALANCE_DB 自动配平并烘焙进文件）。
# 若清单再叠一次固定偏移，运行时听到的混音就**不等于**混音阶段验收过的母带——
# 实测那样会让铃类层比设计值再低 6~7dB、把人声部压没。
# 平衡的唯一真相源是渲染/混音阶段；`db` 字段保留为**运行时可选的微调**，默认 0。
TIER_DEFAULT_DB = {}

def build_manifest(reports: list) -> dict:
    """把各 cue 的混音报告汇总成引擎消费的清单。"""
    tiers = cue_tier_map()
    cues = {}
    for rep in reports:
        cid = rep["cue_id"]
        loop = rep.get("loop", True)
        entry = {
            "title": rep["title"],
            "bpm": rep["bpm"],
            "bar_beats": rep.get("bar_beats", 4),
            "bars": rep["bars"],
            "beat_count": int(round(rep["loop_beats"])) if loop else 0,
            "loop": loop,
            "loop_offset": 0.0,
            "key": rep["key"],
            "duration_s": rep["duration_s"],
            "loudness_lufs": rep["integrated_lufs"],
            "layers": [],
        }
        tier_map = tiers.get(cid, {})
        for stem in rep["stems"]:
            entry["layers"].append({
                "name": stem,
                "file": "%s/%s.ogg" % (cid, stem),
                "tier": tier_map.get(stem, 0),
                # 交付分层已含全部增益（含总线标量），运行时按 unity 叠加即可。
                # 平衡的唯一真相源是渲染/混音阶段；此字段保留为运行时可选的微调。
                "db": 0.0,
            })
        entry["layers"].sort(key=lambda l: (l["tier"], l["name"]))
        cues[cid] = entry
    return {"version": 1, "cue_count": len(cues), "cues": cues}


def write_manifest(manifest: dict, path: str) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(manifest, ensure_ascii=False, indent=2),
                 encoding="utf-8")
