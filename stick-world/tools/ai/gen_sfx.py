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


def _save(path, data):
    data = np.clip(data, -0.95, 0.95)
    pcm = (data * 32767).astype(np.int16)
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm.tobytes())
    print("[sfx]", os.path.basename(path), "%.2fs" % (len(data) / SR))


def _chirp(f0, f1, dur, vol, fm_depth=0.05, fm_rate=30.0, bright=0.4, seed=0):
    """单音节鸟啾：指数频率轨迹（真鸟滑音多为指数型）+ 喉部 FM 颤动
    + 一次泛音（鸣管谐波）+ 呼吸气声，钟形音节包络。"""
    n = int(SR * dur)
    t = np.arange(n) / SR
    freq = f0 * (f1 / f0) ** (t / dur)
    vib = 1.0 + fm_depth * np.sin(2 * np.pi * fm_rate * t)
    phase = 2 * np.pi * np.cumsum(freq * vib) / SR
    tone = np.sin(phase) + bright * 0.35 * np.sin(2 * phase)
    rng = np.random.default_rng(seed)
    k = max(1, int(SR / 6000))  # 6kHz 低通气声
    breath = np.convolve(rng.normal(0, 1, n), np.ones(k) / k, mode="same") * 0.22
    env = np.sin(np.pi * t / dur) ** 1.5
    return (tone * 0.8 + breath) * env * vol


def _phrase(syls, gap=0.06):
    """音节序列拼装：[(f0, f1, dur, vol, kwargs...), ...] 交替静默"""
    parts = []
    for s in syls:
        parts.append(_chirp(*s[:4], **(s[4] if len(s) > 4 else {})))
        parts.append(np.zeros(int(SR * gap)))
    return np.concatenate(parts)


def _rain_loop(dur, vol):
    """分层雨声无缝循环（FFT 域滤波天然周期化，重跑零 seam）：
    远雨垫(brown) + 沙沙(pink 带通) + 细雨嘶(高通) + 稀疏大雨滴瞬态
    + 慢强度起伏（周期取循环整数分频保无缝）。"""
    n = int(SR * dur)
    freqs = np.fft.rfftfreq(n, 1 / SR)
    rng = np.random.default_rng(11)

    def _shaped_noise(resp):
        """白噪 → rfft 乘频响 → irfft：循环卷积，结果首尾无缝"""
        white = rng.normal(0, 1, n)
        return np.fft.irfft(np.fft.rfft(white) * resp, n)

    def _band(lo, hi, tilt):
        resp = np.zeros_like(freqs)
        m = (freqs >= lo) & (freqs <= hi)
        resp[m] = (freqs[m] / hi) ** tilt
        return resp

    bed = _shaped_noise(_band(20, 400, -1.5))       # 远雨垫（brown 质感轰鸣）
    hiss = _shaped_noise(_band(200, 2400, -0.6))    # 密雨沙沙（pink 带通）
    fine = _shaped_noise(_band(2500, 9000, 0.3))    # 细雨嘶（轻高频）
    # 稀疏大雨滴："啪嗒"瞬态（2-8ms 噪声脉冲 ×30ms 指数衰减），避开首尾 0.15s
    drops = np.zeros(n)
    for _ in range(int(dur * 7)):
        pos = rng.integers(int(0.15 * SR), n - int(0.15 * SR))
        m = rng.integers(int(0.002 * SR), int(0.008 * SR))
        drop = rng.normal(0, 1, m) * np.exp(-np.arange(m) / (0.03 * SR))
        drops[pos:pos + m] += drop * rng.uniform(0.5, 1.0)
    k = max(1, int(SR / 3000))
    drops = np.convolve(drops, np.ones(k) / k, mode="same")
    # 慢呼吸起伏：每循环 2 个周期（整数分频保无缝）
    lfo = 1.0 + 0.15 * np.sin(2 * np.pi * 2 * np.arange(n) / n)
    out = (0.55 * bed / (np.max(np.abs(bed)) + 1e-6)
           + 1.0 * hiss / (np.max(np.abs(hiss)) + 1e-6)
           + 0.30 * fine / (np.max(np.abs(fine)) + 1e-6)
           + 0.55 * drops / (np.max(np.abs(drops)) + 1e-6)) * lfo
    return out / (np.max(np.abs(out)) + 1e-6) * vol


def gen_all(out_dir):
    """本脚本只合成仍由程序生成的音效；下列事件已换成 Terraria 提取件
    （tools/ai/extract_terraria_sfx.py，见 docs/项目/素材替换清单.md），
    此处不再生成，避免重跑覆盖：
      ui_click / ui_confirm / game_started / build_complete / harvest_hit_{a,b,c}
      / harvest_wood / harvest_gain / quest_done / ui_hover / unit_hurt / game_saved
      / battle_started / battle_ended_win / battle_ended_lose
    """
    os.makedirs(out_dir, exist_ok=True)
    # 天空生命感：远处鸟啁啾三变体（音节拟真：指数滑音+FM 颤音+气声）
    # a=柳莺式上行音节×3；b=雀式单音节快速颤音；c=斑鸠式低频双音"咕-咕"
    _save(os.path.join(out_dir, "bird_chirp_a.wav"),
          _phrase([(2600, 3300, 0.09, 0.15, {"fm_rate": 24.0}),
                   (2700, 3400, 0.09, 0.14, {"fm_rate": 24.0}),
                   (2800, 3500, 0.11, 0.13, {"fm_rate": 24.0})], gap=0.11))
    _save(os.path.join(out_dir, "bird_chirp_b.wav"),
          _phrase([(3400, 2800, 0.28, 0.15, {"fm_depth": 0.10, "fm_rate": 34.0}),
                   (3500, 2900, 0.22, 0.12, {"fm_depth": 0.10, "fm_rate": 34.0})],
                  gap=0.14))
    _save(os.path.join(out_dir, "bird_chirp_c.wav"),
          _phrase([(900, 640, 0.20, 0.16, {"fm_rate": 14.0, "bright": 0.2}),
                   (860, 600, 0.26, 0.13, {"fm_rate": 14.0, "bright": 0.2})],
                  gap=0.16))
    # 天气层：雨声 4s 无缝循环（分层雨声：垫/沙沙/细雨/雨滴瞬态）
    _save(os.path.join(out_dir, "rain_loop.wav"), _rain_loop(4.0, 0.38))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/audio/sfx"
    gen_all(out)
