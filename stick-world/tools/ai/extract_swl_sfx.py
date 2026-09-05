# -*- coding: utf-8 -*-
"""Stick War: Legacy (Unity APK) 音效提取落位器 —— AudioClip → WAV 选件入册。

用途：为私有演示版提取参考音效（已在 docs/项目/素材替换清单.md 登记，
公开/上架前替换为无版权资产）。UnityPy 导出的 WAV 采样率/声道保持原样
（SWL 原始件混有 8k/22k/44.1k/48k，Godot 混音器自动重采样，无格式假设）；
gain_db 仅做响度匹配（unit_hurt 组对齐 Terraria 旧件基线 -22.2 dBFS RMS，
纯增益不削波），其余原样保真。

来源：SWL v2021.1.11（archive.org 存档 stick-war-legacy-v-2021.1.11），
解包 assets/bin/Data 后经 UnityPy.extract_audioclip_samples 全量导出
（原始件名见提取日志 audio_index.txt）。选件依据：
- 战斗生命周期 = SWL 战役关卡的起/胜/负三件套（同族音乐 sting）；
- 动作音 = SWL 原动画 Sound 事件同名素材（对应本项目动画
  metadata/anim_events 的取值，接线见 weapon_mount.gd SFX_PATHS）。

用法：python extract_swl_sfx.py <audio_raw 目录>
"""
import os
import shutil
import sys
import wave

import numpy as np

# 源件名（UnityPy 全量导出产物）→ (项目资产名, 增益dB)
SELECTION = {
    # 战斗开始（SWL 开战号角）/ 胜利 / 失败（关卡胜/负 sting，与开战号角同族）
    "StartLevel-Horns.wav.wav": ("battle_started.wav", 0.0),
    "LevelWin.wav.wav":         ("battle_ended_win.wav", 0.0),
    "LevelLose.wav.wav":        ("battle_ended_lose.wav", 0.0),
    # 受击痛叫 pain5~7 三变体（pain4 长达 2.3s 不适合高频受击，弃用）；
    # 增益对齐 Terraria Player_Hit_0 基线（-25.7/-28.2/-31.3 → ≈-22 dBFS RMS）
    "2122_pain5.wav.wav": ("unit_hurt_a.wav", 3.5),
    "2124_pain6.wav.wav": ("unit_hurt_b.wav", 6.0),
    "2126_pain7.wav.wav": ("unit_hurt_c.wav", 9.0),
    # 动画 Sound 事件素材（与 SWL 原事件名一一对应）
    "Swoosh_1.wav.wav":                  ("swoosh_a.wav", 0.0),
    "Swoosh_2.wav.wav":                  ("swoosh_b.wav", 0.0),
    "Swoosh_3.wav.wav":                  ("swoosh_c.wav", 0.0),
    "Swoosh_4.wav.wav":                  ("swoosh_d.wav", 0.0),
    "headbutt1.wav.wav":                 ("headbutt.wav", 0.0),
    "MagikillBlast_1.wav.wav":           ("magikill_blast_a.wav", 0.0),
    "MagikillBlast_2.wav.wav":           ("magikill_blast_b.wav", 0.0),
    "Thump_THUD_Smooth_01_mono.wav.wav": ("thump_a.wav", 0.0),
    "Thump_THUD_Smooth_02_mono.wav.wav": ("thump_b.wav", 0.0),
    "fall_1.wav.wav":                    ("bodyfall_a.wav", 0.0),  # = body-fall_1（同物异名）
    "fall_2.wav.wav":                    ("bodyfall_b.wav", 0.0),
    "fall_3.wav.wav":                    ("bodyfall_c.wav", 0.0),
    "clang_1.wav.wav":                   ("clang_a.wav", 0.0),
    "clang_2.wav.wav":                   ("clang_b.wav", 0.0),
}

OUT_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "..", "assets", "audio", "sfx"))


def _apply_gain(src: str, dst: str, gain_db: float) -> None:
    """PCM16 WAV 原格式增益（wave+numpy，不重采样不变声道）。"""
    with wave.open(src, "rb") as r:
        params = r.getparams()
        raw = r.readframes(params.nframes)
    data = np.frombuffer(raw, dtype=np.int16).astype(np.float64)
    data *= 10.0 ** (gain_db / 20.0)
    np.clip(data, -32768, 32767, out=data)
    with wave.open(dst, "wb") as w:
        w.setparams(params)
        w.writeframes(data.astype(np.int16).tobytes())


def main(argv: list) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    src_dir = argv[1]
    ok = 0
    for src, (dst, gain_db) in SELECTION.items():
        src_path = os.path.join(src_dir, src)
        if not os.path.isfile(src_path):
            print(f"缺失源件: {src}")
            continue
        dst_path = os.path.join(OUT_DIR, dst)
        if gain_db:
            _apply_gain(src_path, dst_path, gain_db)
        else:
            shutil.copyfile(src_path, dst_path)
        print(f"{dst}\t<- {src}\t({os.path.getsize(dst_path)} B, gain={gain_db:+.1f}dB)")
        ok += 1
    print(f"落位 {ok}/{len(SELECTION)}")
    return 0 if ok == len(SELECTION) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
