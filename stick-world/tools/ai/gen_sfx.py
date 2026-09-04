# -*- coding: utf-8 -*-
"""程序化音效合成 —— numpy 直接合成 WAV（零音频资产依赖）。

覆盖 AudioManager.SFX_EVENTS 约定的全部事件 + Demo 新增（采集/获得/目标完成）。
设计原则：短（0.05-0.6s）、软包络（5ms attack + 指数衰减）、轻失谐去"电脑感"。
用法：python gen_sfx.py [输出目录 assets/audio/sfx]
"""
import os
import sys
import wave

import numpy as np

SR = 44100


def _env(n, attack=0.005, decay=None):
    """attack 线性 + 指数衰减包络"""
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-4), 0, 1)
    d = np.exp(-t / (decay if decay else n / SR / 4.0))
    return a * d


def _tone(freq, dur, vol=0.5, detune=0.004, decay=None):
    n = int(SR * dur)
    t = np.arange(n) / SR
    w = (np.sin(2 * np.pi * freq * (1 + detune) * t)
         + 0.35 * np.sin(2 * np.pi * freq * (1 - detune) * t)
         + 0.12 * np.sin(2 * np.pi * freq * 2.01 * t))
    return w * _env(n, decay=decay) * vol


def _noise(dur, vol=0.4, lp=None):
    n = int(SR * dur)
    w = np.random.default_rng(7).normal(0, 1, n)
    if lp:  # 简易低通：滑动平均
        k = max(1, int(SR / lp))
        w = np.convolve(w, np.ones(k) / k, mode="same")
    return w * _env(n, attack=0.001) * vol


def _seq(notes, note_dur=0.09, gap=0.01, vol=0.5):
    """音符序列 (freq, dur_mult)"""
    parts = []
    for f, m in notes:
        parts.append(_tone(f, note_dur * m, vol=vol))
        parts.append(np.zeros(int(SR * gap)))
    return np.concatenate(parts)


def _mix(*parts):
    """长度不齐的多轨混合：零填充到最长后相加"""
    n = max(len(p) for p in parts)
    out = np.zeros(n)
    for p in parts:
        out[:len(p)] += p
    return out


def _save(path, data):
    data = np.clip(data, -0.95, 0.95)
    pcm = (data * 32767).astype(np.int16)
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm.tobytes())
    print("[sfx]", os.path.basename(path), "%.2fs" % (len(data) / SR))


C5, E5, G5, C6 = 523.25, 659.25, 783.99, 1046.5
A4, B4, D5, F5, A5 = 440.0, 493.88, 587.33, 698.46, 880.0


def _sweep(f0, f1, dur, vol=0.3):
    """线性频率扫掠单音（鸟啁啾用）"""
    n = int(SR * dur)
    t = np.arange(n) / SR
    freq = np.linspace(f0, f1, n)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    return np.sin(phase) * _env(n, attack=0.004, decay=dur / 2.5) * vol


def gen_all(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    _save(os.path.join(out_dir, "ui_click.wav"), _mix(_noise(0.045, 0.35), _tone(1150, 0.05, 0.3)))
    _save(os.path.join(out_dir, "ui_confirm.wav"), _seq([(A4, 1), (C6, 1)], 0.09))
    _save(os.path.join(out_dir, "game_started.wav"), _seq([(C5, 1), (E5, 1), (G5, 1.6)], 0.11))
    _save(os.path.join(out_dir, "game_saved.wav"), _seq([(G5, 1), (C6, 1)], 0.1))
    _save(os.path.join(out_dir, "build_complete.wav"),
          _mix(_tone(130.8, 0.35, 0.55, decay=0.12), _noise(0.25, 0.18, lp=900)))
    _save(os.path.join(out_dir, "battle_started.wav"),
          _mix(_tone(82.4, 0.5, 0.6, decay=0.18), _seq([(D5, 1)], 0.12, vol=0.3)))
    _save(os.path.join(out_dir, "battle_ended_win.wav"),
          _seq([(C5, 1), (E5, 1), (G5, 1), (C6, 2.2)], 0.12, gap=0.02))
    _save(os.path.join(out_dir, "battle_ended_lose.wav"),
          _seq([(F5, 1), (D5, 1), (B4, 1), (392.0, 2.2)], 0.13, gap=0.03, vol=0.45))
    # Demo 新增事件
    _save(os.path.join(out_dir, "harvest_hit.wav"),
          _mix(_noise(0.05, 0.5, lp=2500), _tone(196, 0.09, 0.4, decay=0.03)))
    _save(os.path.join(out_dir, "harvest_gain.wav"), _tone(1318.5, 0.16, 0.35, decay=0.05))
    _save(os.path.join(out_dir, "quest_done.wav"), _seq([(A5, 1), (1174.7, 1.8)], 0.1, gap=0.015))
    _save(os.path.join(out_dir, "ui_hover.wav"), _tone(880, 0.04, 0.16, decay=0.015))
    # 天空生命感：远处鸟啁啾三变体（音量压低做距离感，与飞鸟生成配对播放）
    _save(os.path.join(out_dir, "bird_chirp_a.wav"),
          _mix(_sweep(2300, 3100, 0.09, 0.16),
               np.concatenate([np.zeros(int(SR * 0.10)), _sweep(2500, 3400, 0.11, 0.14)])))
    _b_parts = [np.concatenate([np.zeros(int(SR * 0.07 * i)), _sweep(f0, f1, 0.07, 0.13)])
                for i, (f0, f1) in enumerate([(3400, 2600), (3200, 2500), (3600, 2700)])]
    _save(os.path.join(out_dir, "bird_chirp_b.wav"), _mix(*_b_parts))
    _t_n = int(SR * 0.22)
    _trem = 1.0 + 0.25 * np.sin(2 * np.pi * 38 * np.arange(_t_n) / SR)
    _save(os.path.join(out_dir, "bird_chirp_c.wav"), _sweep(2800, 2200, 0.22, 0.15) * _trem)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/audio/sfx"
    gen_all(out)
