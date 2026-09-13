# -*- coding: utf-8 -*-
"""管线自检 —— 用合成信号验证 DSP / 混响 / 混音 / 响度 / 导出各环节。

为什么需要：这条管线里大量环节（IR 合成、K 加权、循环折回、限制器）在
"看起来没报错"的情况下也可能悄悄做错事。本脚本用**已知答案的输入**去验证
输出，把"能跑通"和"算得对"分开。

已经靠它抓到的真实缺陷（记在此处，避免日后重犯）：
  1. 积分响度按声道**求平均**而非求和 → 立体声少算 3 LU；
  2. 混响 IR 长度按衰减最快的频段算 → 低频尾巴被截断（可闻的硬切）；
  3. 混响各频段等方差噪声 → 频谱是白的，混响发"嘶"、发刺；
  4. 低频单声道化用"低通后相减重建" → 相位不匹配、残留约 45% 侧信号；
  5. 接缝指标用局部窗口 RMS 归一化 → 遇到自然衰减到静音的结尾会退化。

    python tools/music/selftest.py
退出码 0 = 全部通过。
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from musiclib import dsp, export, loudness, mix, reverb      # noqa: E402

SR = 48000
FAILS: list = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print("[%s] %-44s %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILS.append(name)


def tone(freq: float, dur: float, amp: float = 0.5, sr: int = SR) -> np.ndarray:
    t = np.arange(int(sr * dur)) / sr
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float64)


def stereo(x: np.ndarray, corr: float = 1.0, seed: int = 0) -> np.ndarray:
    if corr >= 1.0:
        return np.repeat(x[:, None], 2, axis=1)
    rng = np.random.default_rng(seed)
    other = rng.standard_normal(len(x)) * np.std(x) * math.sqrt(1 - corr ** 2)
    return np.stack([x, corr * x + other], axis=1)


def side_of(sig: np.ndarray) -> float:
    _, sd = dsp.mid_side(sig)
    return float(np.sqrt(np.mean(sd ** 2)))


# ─────────────────────────── 1. 响度 ────────────────────────────────

def test_loudness() -> None:
    v = loudness.verify_k_weighting(SR)
    check("BS.1770 K 加权系数（48000Hz 对表）", v["ok"],
          "max_abs_diff=%.2e" % v["max_abs_diff"])

    # 不依赖外部参考的硬性不变量
    mono = tone(1000.0, 4.0, 0.1414)[:, None]
    l1 = loudness.integrated_lufs(mono, SR)
    l2 = loudness.integrated_lufs(np.repeat(mono, 2, axis=1), SR)
    check("双声道同信号 = 单声道 +3 LU", abs((l2 - l1) - 3.0) < 0.15,
          "%.2f vs %.2f" % (l2, l1))
    l3 = loudness.integrated_lufs(mono * 2.0, SR)
    check("幅度翻倍 = +6 LU", abs((l3 - l1) - 6.0) < 0.15,
          "%.2f vs %.2f" % (l3, l1))

    # 与独立实现交叉验证（pyloudnorm 是 BS.1770 的成熟实现）
    try:
        import pyloudnorm as pyln
        n = SR * 6
        t = np.arange(n) / SR
        prog = np.zeros((n, 2))
        for f, a in ((220.0, 0.4), (440.0, 0.3), (1760.0, 0.15)):
            prog += a * np.sin(2 * np.pi * f * t)[:, None]
        prog *= 0.3
        mine = loudness.integrated_lufs(prog, SR)
        ref = pyln.Meter(SR).integrated_loudness(prog)
        check("立体声 LUFS 与 pyloudnorm 一致（±0.3 LU）", abs(mine - ref) < 0.3,
              "本实现 %.3f / pyloudnorm %.3f" % (mine, ref))
        m1 = loudness.integrated_lufs(np.ascontiguousarray(prog[:, :1]), SR)
        r1 = pyln.Meter(SR).integrated_loudness(np.ascontiguousarray(prog[:, :1]))
        check("单声道 LUFS 与 pyloudnorm 一致（±0.3 LU）", abs(m1 - r1) < 0.3,
              "本实现 %.3f / pyloudnorm %.3f" % (m1, r1))
    except ImportError:
        print("[SKIP] 未安装 pyloudnorm，跳过交叉验证")

    # 真峰值：已知答案的过冲案例。
    # 相位偏移 22.5° 时采样点恰好避开波峰 → 采样峰值 -0.69dB，真峰值应 ≈0dB
    t = np.arange(SR) / SR
    tricky = np.sin(2 * np.pi * (SR / 8.0) * t + np.pi / 8.0)
    sp = loudness.sample_peak_dbfs(tricky)
    tp = loudness.true_peak_dbfs(stereo(tricky), SR)
    check("真峰值抓到采样间过冲（TP≈0，SP≈-0.69dB）",
          abs(tp) < 0.2 and abs(sp + 0.687) < 0.15, "TP=%.2f SP=%.2f dB" % (tp, sp))

    sq = np.sign(tone(997.0, 1.0, 0.9))
    check("方波真峰值 ≥ 采样峰值",
          loudness.true_peak_dbfs(stereo(sq), SR) >= loudness.sample_peak_dbfs(sq) - 0.05,
          "TP=%.2f SP=%.2f dB" % (loudness.true_peak_dbfs(stereo(sq), SR),
                                  loudness.sample_peak_dbfs(sq)))
    check("静音积分响度 = -inf",
          not np.isfinite(loudness.integrated_lufs(np.zeros((SR, 2)), SR)))


# ─────────────────────────── 2. DSP ─────────────────────────────────

def test_dsp() -> None:
    x = tone(100.0, 1.0, 0.5)
    y = dsp.highpass(x, SR, 1000.0, order=4)
    check("高通抑制被滤频段 (>26dB)",
          20 * math.log10(np.sqrt(np.mean(y ** 2)) / np.sqrt(np.mean(x ** 2))) < -26.0)

    # 搁架：拐点 2000Hz、测 8000Hz（离过渡区两个八度，应接近标称增益）
    for target in (-6.0, 3.0):
        x = tone(8000.0, 1.0, 0.5)
        y = dsp.shelf(x, SR, 2000.0, target, kind="high")
        g = 20 * math.log10(np.sqrt(np.mean(y ** 2)) / np.sqrt(np.mean(x ** 2)))
        check("高频搁架 %+0.0fdB 生效（测 8kHz）" % target,
              abs(g - target) < 1.2, "%.2f dB" % g)
    x = tone(120.0, 1.0, 0.5)
    y = dsp.shelf(x, SR, 2000.0, -6.0, kind="high")
    check("高频搁架不影响低频",
          abs(20 * math.log10(np.sqrt(np.mean(y ** 2)) / np.sqrt(np.mean(x ** 2)))) < 1.0)

    loud = tone(220.0, 2.0, 0.9)
    comp = dsp.compressor(loud, SR, threshold_db=-24.0, ratio=4.0)
    gr = 20 * math.log10(np.sqrt(np.mean(comp[len(comp) // 2:] ** 2))
                         / np.sqrt(np.mean(loud[len(loud) // 2:] ** 2)))
    check("压缩器产生负增益 (>3dB)", gr < -3.0, "%.2f dB" % gr)

    lim = dsp.limiter(stereo(tone(110.0, 1.0, 3.0)), SR, ceiling_db=-1.0)
    check("限制器不越 ceiling", loudness.sample_peak_dbfs(lim) <= -0.9,
          "%.2f dB" % loudness.sample_peak_dbfs(lim))

    # M/S 展宽：**分开测**低频与中频。
    # 测试信号用"左右增益不同的纯音"而不是"纯音+去相关噪声"：后者会往
    # 侧信号里灌进宽带噪声，而低频单声道化只作用于交叉点以下，
    # 于是总侧能量被 180Hz 以上的噪声主导，测出来像是"没做单声道化"。
    low_pair = np.stack([tone(80.0, 1.0, 0.4), tone(80.0, 1.0, 0.4) * 0.4], axis=1)
    mid_pair = np.stack([tone(900.0, 1.0, 0.4), tone(900.0, 1.0, 0.4) * 0.4], axis=1)
    wb = dsp.widen(low_pair, 1.6, bass_mono_hz=180.0, fs=SR)
    wm = dsp.widen(mid_pair, 1.6, bass_mono_hz=180.0, fs=SR)
    check("展宽后低频(80Hz)侧信号被折掉（降 >20x）",
          side_of(wb) < side_of(low_pair) / 20.0,
          "%.6f -> %.6f" % (side_of(low_pair), side_of(wb)))
    check("展宽后中频(900Hz)侧信号被放大（>1.4x）",
          side_of(wm) > side_of(mid_pair) * 1.4,
          "%.6f -> %.6f" % (side_of(mid_pair), side_of(wm)))


# ─────────────────────────── 3. 混响 ────────────────────────────────

def _spectral_slope_db_per_oct(f, P, lo=200.0, hi=8000.0) -> float:
    """在倍频程坐标下拟合功率谱斜率（dB/oct）。粉噪 ≈ -3，白噪 ≈ 0。"""
    m = (f >= lo) & (f <= hi) & (P > 0)
    if m.sum() < 8:
        return 0.0
    return float(np.polyfit(np.log2(f[m]), 10 * np.log10(P[m]), 1)[0])


def test_reverb() -> None:
    from scipy import signal as sg
    ir = reverb.make_ir(SR, rt60=2.0, pre_delay_ms=25, seed=1, style="hall")
    check("IR 长度覆盖最慢频段（≥ RT60）", len(ir) / SR >= 2.0,
          "%.2fs" % (len(ir) / SR))
    early = float(np.sum(ir[:SR // 20] ** 2))
    late = float(np.sum(ir[-SR // 20:] ** 2))
    check("IR 尾部能量已衰减", late < early * 1e-3,
          "early=%.3e late=%.3e" % (early, late))
    check("IR 尾部无硬切（末 50ms 能量占比 <1%）",
          reverb.tail_energy(ir, SR, 50.0) < 0.01,
          "%.6f" % reverb.tail_energy(ir, SR, 50.0))
    pre = int(0.02 * SR)
    check("IR 存在预延迟（前 20ms 近静音）",
          float(np.max(np.abs(ir[:pre]))) < 0.05 * float(np.max(np.abs(ir))))

    lo = dsp.lowpass(ir, SR, 400.0)
    hi = dsp.highpass(ir, SR, 4000.0)
    tail = slice(int(1.5 * SR), int(1.9 * SR))
    check("低频衰减慢于高频（自然房间特征）",
          float(np.sum(lo[tail] ** 2)) > float(np.sum(hi[tail] ** 2)) * 1.5,
          "%.3e vs %.3e" % (np.sum(lo[tail] ** 2), np.sum(hi[tail] ** 2)))

    f, P = sg.welch(ir[:, 0], fs=SR, nperseg=8192)
    slope = _spectral_slope_db_per_oct(f, P)
    check("IR 频谱接近粉噪（-6 ~ -1 dB/oct，避免发嘶）", -6.0 < slope < -1.0,
          "%.2f dB/oct" % slope)

    dry = stereo(tone(660.0, 1.0, 0.5), corr=0.3, seed=2)
    wet = reverb.convolve_reverb(dry, ir, SR, mix=0.5)
    check("卷积混响输出等长且无 NaN",
          wet.shape == dry.shape and np.all(np.isfinite(wet)))
    imp = np.zeros((SR, 2))
    imp[100] = 1.0
    check("混响给脉冲加出尾巴",
          float(np.sum(reverb.convolve_reverb(imp, ir, SR, mix=1.0)[SR // 2:] ** 2)) > 1e-6)


# ─────────────────────────── 4. 循环折回 ────────────────────────────

def test_loop_wrap() -> None:
    n = SR * 4
    x = np.zeros((n + SR, 2))
    x[SR:SR + 1000] = 0.8
    x[n + 200:n + 300] = 0.25
    y = mix.wrap_loop_tail(x, SR, 0, n)
    check("折回后长度 = 循环体长度", len(y) == n, "%d" % len(y))
    base = x[:n].copy()
    check("折回区 = 原内容 + 尾巴（相加而非覆盖）",
          abs(y[205, 0] - (base[205, 0] + 0.25)) < 1e-6,
          "y[205]=%.4f, base=%.4f" % (y[205, 0], base[205, 0]))
    check("折回区之外不受影响",
          abs(y[500, 0] - base[500, 0]) < 1e-9 and abs(y[1000, 0] - base[1000, 0]) < 1e-9)

    # 接缝指标必须用"拼接处的一阶差分"判读，而不是"两窗相减"
    # 正例：220Hz 正弦在 1 秒里正好走整数个周期 → 末尾与开头严丝合缝
    t = np.arange(SR) / SR
    good_sig = 0.5 * np.sin(2 * np.pi * 220.0 * t)
    good = loudness.loop_seam_report(good_sig, 0, SR, fs=SR)
    check("整数周期正弦：接缝听不出来（click ≤ 12dB）",
          good.get("ok") is True and good["jump_rms_db"] <= 12.0,
          "click=%.1f dB, flux=%.2f"
          % (good.get("jump_rms_db", 0), good.get("seam_flux_ratio", 0)))

    # 反例：220.25Hz —— 末尾停在 +0.5、开头从 0 起，拼接处有孤立大跳变
    bad_sig = 0.5 * np.sin(2 * np.pi * 220.25 * t)
    bad = loudness.loop_seam_report(bad_sig, 0, SR, fs=SR)
    check("相位错位能被抓出（click 比正例高 >15dB）",
          bad.get("ok") is True and bad["jump_rms_db"] > good["jump_rms_db"] + 15.0,
          "错位 %.1f dB vs 连续 %.1f dB"
          % (bad.get("jump_rms_db", 0), good.get("jump_rms_db", 0)))

    # 尾部硬切（结尾电平骤断）应被 tail_decay_db 反映出来
    # 注意循环点设在数组末尾，这样"循环末尾 20ms"才是那 200 点的静音
    # 静音段取 1000 点（约 21ms）：刚好让"末尾 20ms"整段落在静音里，
    # 而"前 20ms"仍以正弦为主 —— 这样比值才有意义
    cut = np.concatenate([0.5 * np.sin(2 * np.pi * 220.0 * t)[:SR - 1000],
                          np.zeros(1000)])
    rep_cut = loudness.loop_seam_report(cut, 0, SR, fs=SR)
    check("尾部硬切能被 tail_decay 反映",
          rep_cut.get("ok") is True and rep_cut["tail_decay_db"] < -20.0,
          "末 20ms 电平变化 %.1f dB" % rep_cut.get("tail_decay_db", 0))


# ─────────────────────────── 5. 混音 / 导出 ─────────────────────────

def test_mix_and_export(tmp: Path) -> None:
    from musiclib import score as S
    from musiclib.render import write_wav

    rng = np.random.default_rng(3)
    n = SR * 3
    fake = {"piano": rng.standard_normal((n, 2)) * 0.02,
            "strings": rng.standard_normal((n, 2)) * 0.01}
    paths = {}
    for k, v in fake.items():
        p = tmp / ("selftest_%s.wav" % k)
        write_wav(str(p), v.astype(np.float32), SR, subtype="PCM_24")
        paths[k] = str(p)

    cue = S.Cue(cue_id="selftest", title="自检", bpm=72, bars=8,
                loop_start_bar=0.0, loop_end_bar=8)
    cue.stem("piano")
    cue.stem("strings")
    audio, rep = mix.mix_cue(cue, paths,
                             overrides={"piano": {"rev_style": "room"}},
                             target_lufs=-17.0)
    check("混音输出为立体声且有限",
          audio.ndim == 2 and np.all(np.isfinite(audio)), "%s" % (audio.shape,))
    check("混音达到目标响度 (±1.5 LU)", abs(rep["integrated_lufs"] + 17.0) < 1.5,
          "%.2f LUFS" % rep["integrated_lufs"])
    check("真峰值不越 -1.0 dBTP", rep["true_peak_dbtp"] <= -0.9,
          "%.2f dBTP" % rep["true_peak_dbtp"])
    check("无削波样点", rep["clipped_samples"] == 0)
    check("DC 偏置极小", abs(rep["dc_offset"]) < 1e-3, "%.2e" % rep["dc_offset"])
    check("报告含刺耳度与单声道指标",
          "harshness_score" in rep and "mono_correlation" in rep,
          "刺耳度 %.3f / 声道相关 %.3f"
          % (rep.get("harshness_score", -1), rep.get("mono_correlation", 0)))
    check("报告含循环接缝指标", "seam_jump_rms_db" in rep,
          "%.1f dB" % rep.get("seam_jump_rms_db", 0))

    master = tmp / "selftest_master.wav"
    mix.save_mix(audio, str(master))
    check("母带 WAV 落盘", master.exists(), "%.2f MB" % (master.stat().st_size / 1e6))

    try:
        meta = export.ogg_encode(str(master), str(tmp / "selftest.ogg"), quality=6)
        import soundfile as sf
        info = sf.info(str(tmp / "selftest.ogg"))
        check("OGG 编码成功且规格正确",
              meta["bytes"] > 0 and info.samplerate == SR and info.channels == 2,
              "%.2f MB / %.0f kbps / %d Hz %dch"
              % (meta["bytes"] / 1e6, meta["kbps"], info.samplerate, info.channels))
    except Exception as e:  # noqa: BLE001
        check("OGG 编码成功且规格正确", False, str(e)[:100])

    man = export.build_manifest([{**rep, "loop": True, "bar_beats": 4,
                                  "stems": ["piano", "strings"],
                                  "loop_beats": 32}])
    ent = man["cues"]["selftest"]
    check("引擎清单结构正确",
          ent["beat_count"] == 32 and len(ent["layers"]) == 2
          and ent["layers"][0]["tier"] == 0,
          "layers=%s" % [(l["name"], l["tier"]) for l in ent["layers"]])


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    tmp = HERE / "out" / "selftest"
    tmp.mkdir(parents=True, exist_ok=True)
    print("── 1. 响度 / K 加权 ─────────────────────────────")
    test_loudness()
    print("\n── 2. DSP 原语 ──────────────────────────────────")
    test_dsp()
    print("\n── 3. 程序化混响 ────────────────────────────────")
    test_reverb()
    print("\n── 4. 循环尾巴折回 ──────────────────────────────")
    test_loop_wrap()
    print("\n── 5. 混音 / 母带 / 导出 ────────────────────────")
    test_mix_and_export(tmp)

    print("\n" + "=" * 56)
    if FAILS:
        print("失败 %d 项：%s" % (len(FAILS), "；".join(FAILS)))
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
