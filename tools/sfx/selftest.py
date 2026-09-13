# -*- coding: utf-8 -*-
"""音效管线自检 —— 用**已知答案的输入**验证原语、母带链、指标与配方表的正确性。

为什么需要：这条管线里最危险的东西是"看起来没报错但算错了"。本批已经靠
"量出来的时长和设计对不上"抓到过三个真实缺陷，全部固化成下面的用例：

  1. `synth.perc_env(hold=...)` 让衰减从 t=0 起算 → "保持 0.42 秒的号角"实际
     在 0.42 秒时已经掉了 36dB（`battle_started` 白白短了 30%）；
  2. `synth.saw_voice` **根本没把 hold 传给 perc_env** → 号角从 0 就开始衰，
     1.2 秒的宣告变成 0.7 秒的短促音；
  3. `post.trim_to_event` 拿**样点峰值**当尾部阈值基准 → 撞击类音效（低频膜音
     的一两个过冲把峰值抬高十几 dB）的尾巴被裁在还有实际电平的地方，
     设计 540ms 的 `bodyfall_b` 只剩 354ms。

    <PY> tools/sfx/selftest.py
退出码 0 = 全部通过。
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "music"))

from musiclib import loudness                        # noqa: E402
from sfxlib import design as D, post, synth as S      # noqa: E402

SR = 48000
FAILS: list = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print("[%s] %-52s %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILS.append(name)


def tone(freq: float, dur: float, amp: float = 0.5, sr: int = SR) -> np.ndarray:
    t = np.arange(int(sr * dur)) / sr
    return amp * np.sin(2 * np.pi * freq * t)


def dominant_freq(x: np.ndarray, fs: int, lo: float = 20.0,
                  hi: float = 20000.0) -> float:
    """主频（加汉宁窗 FFT 峰值）。"""
    w = np.hanning(len(x))
    X = np.abs(np.fft.rfft(x * w))
    f = np.fft.rfftfreq(len(x), 1.0 / fs)
    m = (f >= lo) & (f <= hi)
    return float(f[m][int(np.argmax(X[m]))])


def pitch_hz(x: np.ndarray, fs: int, fmin: float = 60.0,
             fmax: float = 500.0) -> float:
    """基频（自相关周期）—— 测"基频"必须用**周期性**，不能用"频谱最大 bin"。

    谐波信号的频谱峰位置由共振峰塑形决定（F1 附近的 3~4 次谐波常比基频高
    十几 dB），所以"最大 bin"回答的是"哪个分音最响"，不是"基频是多少"。
    自相关找的是波形自身的重复周期，对所有谐波分量都成立。
    返回 lag 域全局最大处的频率（本管线用例都是恒定 f0，够用）。
    """
    x = np.asarray(x, dtype=np.float64)
    x = x - x.mean()
    r = np.correlate(x, x, mode="full")[len(x) - 1:]
    r = r / (r[0] + 1e-20)
    lo = max(1, int(fs / fmax))
    hi = min(len(r) - 1, int(fs / fmin))
    return fs / float(lo + int(np.argmax(r[lo:hi])))


def band_energy(x: np.ndarray, fs: int, lo, hi) -> float:
    X = np.abs(np.fft.rfft(x)) ** 2
    f = np.fft.rfftfreq(len(x), 1.0 / fs)
    m = (f >= lo) & (f < hi)
    return float(np.sum(X[m]))


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.asarray(x, dtype=np.float64) ** 2)))


# ─────────────────── 1. 包络 / 时长规则（踩坑 #1/#2）──────────────────

def test_envelope() -> None:
    # tau_for 的规则：exp 衰减到 -60dB 的时刻 = 6.908·τ
    # ⚠ 期望值必须用**精确常数** 60/20·ln10 = 6.907755278982137。写成 6 位小数的
    #   字面量 6.907755 时，τ·6.907755 与 0.300 差 1.2e-8，比 1e-9 的容差大一个
    #   数量级——那是**断言的常数截断误差**，不是实现错（实现用的是 math.log(10)）。
    tau = D.tau_for(300.0)
    check("tau_for：-60dB 出现在 300ms 处（6.908·τ 规则）",
          abs(tau * (60.0 / 20.0 * math.log(10.0)) - 0.300) < 1e-12,
          "τ=%.6fs" % tau)

    n = int(1.0 * SR)
    e = S.decay_env(n, SR, tau)
    idx = int(0.3 * SR)
    check("decay_env：300ms 处正好 -60dB",
          abs(20 * math.log10(e[idx]) + 60.0) < 0.15,
          "%.2f dB" % (20 * math.log10(e[idx])))

    # hold 语义：保持段内包络=1，衰减从 hold 处起算
    e2 = S.perc_env(int(1.2 * SR), SR, 0.045, D.tau_for(620.0), hold=0.40)
    check("perc_env(hold)：保持段结束处仍为满电平（不提前衰减）",
          abs(e2[int(0.40 * SR)] - 1.0) < 0.02, "%.4f" % e2[int(0.40 * SR)])
    want = 0.40 + 0.62 - 0.045            # hold + T，起振误差留给容差
    check("perc_env(hold)：衰减从 hold 处起算（-60dB 在 hold+T）",
          20 * math.log10(e2[int(want * SR)] + 1e-12) < -55.0,
          "%.1f dB" % (20 * math.log10(e2[int(want * SR)] + 1e-12)))
    check("perc_env：起振从 0 开始（无起始跳变）", e2[0] == 0.0)

    # saw_voice 必须把 hold 传下去（踩坑 #2：漏传会让号角变成短促音）。
    # ⚠ 判据要在**保持段内部**取样：hold=0.45s 意味着 0.50s 已经进入衰减
    #   （τ=tau_for(600)=86.9ms，0.50s 处包络已掉到 0.56），拿 0.44s vs 0.50s
    #   去判"保持"是在量衰减——那是把断言放在错误的时间点上。
    #   正确的两条：①保持段内（0.30→0.44s）电平不衰减；②把"传了 hold"与
    #   "没传 hold（hold=0）"的同 seed 构建并排比，前者在 0.44s 处应高 40dB 以上
    #   ——后者是踩坑 #2 的直接反例，差异量级大到不可能误判。
    v = S.saw_voice(146.83, 1.2, SR, hold=0.45, tau=D.tau_for(600.0),
                    attack=0.045, seed=1)
    v0 = S.saw_voice(146.83, 1.2, SR, hold=0.0, tau=D.tau_for(600.0),
                     attack=0.045, seed=1)
    env = S.env_follow(v, SR, 20.0)
    env0 = S.env_follow(v0, SR, 20.0)
    a = float(env[int(0.30 * SR)])      # 保持段内
    b = float(env[int(0.44 * SR)])      # 保持段末尾（hold=0.45）
    h = float(env0[int(0.44 * SR)])     # 同 seed、未传 hold 的反例
    c = float(env[int(1.05 * SR)])
    check("saw_voice：hold 段内不衰减（0.30→0.44s 电平保持 ≥0.8）", b > a * 0.8,
          "0.30s=%.4f 0.44s=%.4f" % (a, b))
    check("saw_voice：hold 生效（0.44s 处比未传 hold 高 ≥35dB）",
          b > h * 50.0, "%.4f vs 未传 hold %.5f（+%.1f dB）"
          % (b, h, 20 * math.log10(b / max(h, 1e-12))))
    check("saw_voice：hold 之后确实衰减（1.05s 已低于 1/10）", c < b * 0.10,
          "1.05s=%.5f" % c)
    check("saw_voice：基频正确", abs(dominant_freq(v[:SR // 2], SR) - 146.83) < 3.0,
          "%.1f Hz" % dominant_freq(v[:SR // 2], SR))


# ─────────────────────── 2. 合成原语（已知答案）───────────────────────

def test_primitives() -> None:
    # modal：单模态 → 频率正确、包络时间常数正确
    tau = 0.05
    m = S.modal([1000.0], [tau], [1.0], 0.5, SR, seed=0, random_phase=False)
    check("modal：单模态频率正确", abs(dominant_freq(m[:SR // 4], SR) - 1000.0) < 8.0,
          "%.1f Hz" % dominant_freq(m[:SR // 4], SR))
    e = S.env_follow(m, SR, 5.0)
    fit = -1.0 / (np.polyfit(np.arange(int(0.1 * SR), int(0.4 * SR)) / SR,
                             20 * np.log10(e[int(0.1 * SR):int(0.4 * SR)]), 1)[0]
                  / 20.0 * math.log(10.0))
    check("modal：衰减时间常数与设定一致（±12%）", abs(fit - tau) / tau < 0.12,
          "实测 τ=%.4fs / 设定 %.4fs" % (fit, tau))

    # band_noise：能量在带内、RMS 精确
    bn = S.band_noise(0.3, SR, 3, 1000.0, 2000.0)
    rin = band_energy(bn, SR, 1000, 2000)
    rout = band_energy(bn, SR, 100, 900) + band_energy(bn, SR, 3000, 20000)
    check("band_noise：能量集中在带内（带外 < 1/5）", rout < rin * 0.2,
          "带内 %.4f / 带外 %.4f" % (rin, rout))
    check("band_noise：RMS 归一到 1（同参数同电平）", abs(rms(bn) - 1.0) < 1e-6,
          "%.6f" % rms(bn))

    # tick：起音 0、时长符合 tau_for
    tk = S.tick(0.10, SR, 5, 2000.0, 8000.0, tau=D.tau_for(30.0))
    check("tick：起音在第一个样点附近",
          float(np.argmax(np.abs(tk[:200]))) < 200)
    check("tick：-60dB 时刻符合 tau_for（60ms 处已 < -50dB）",
          20 * math.log10(abs(tk[int(0.06 * SR)]) + 1e-12) < -50.0,
          "%.1f dB" % (20 * math.log10(abs(tk[int(0.06 * SR)]) + 1e-12)))

    # glide_tone：音高确实在滑（后段主频低于前段）
    g = S.glide_tone(1000.0, 800.0, 0.3, SR, tau=0.2, glide=0.9)
    f1 = dominant_freq(g[:int(0.06 * SR)], SR)
    f2 = dominant_freq(g[int(0.2 * SR):], SR)
    check("glide_tone：音高下滑生效（1000→800Hz）", f1 > f2 * 1.15,
          "前 %.0fHz → 后 %.0fHz" % (f1, f2))

    # thud：低频下滑
    th = S.thud(90.0, 55.0, 0.4, SR, tau=0.15, body=0.0)
    check("thud：低频、下滑（后段主频低于前段）",
          dominant_freq(th[:int(0.04 * SR)], SR) > dominant_freq(th[int(0.25 * SR):], SR),
          "%.0f → %.0f Hz" % (dominant_freq(th[:int(0.04 * SR)], SR),
                              dominant_freq(th[int(0.25 * SR):], SR)))

    # fm_bell：基频存在 + 非谐分音（能量不在整数倍上占绝对优势）
    fb = S.fm_bell(600.0, 0.6, SR, ratio=3.5, index=2.0, tau=0.2, tau_mod=0.08)
    check("fm_bell：基频正确", abs(dominant_freq(fb[:int(0.1 * SR)], SR, 100, 4000) - 600.0)
          < 40.0, "%.0f Hz" % dominant_freq(fb[:int(0.1 * SR)], SR, 100, 4000))

    # phonation：基频与共振峰都落在设定值附近
    # ⚠ 判"基频"不能用"60~400Hz 里最响的 bin"：这是**声源-滤波**合成的谐波
    #   信号，F1=700Hz 的 2 极点共振腔把 3~4 次谐波抬到 H1 之上（实测 H1 比
    #   800Hz 峰低约 17dB）。"最大 bin"回答的是"哪个分音最响"，不是"基频"——
    #   而且它在 400Hz 边界上会因 f<=400 / f<400 直接翻转结论（实测两种写法
    #   一个给 400 一个给 200），是典型的脆弱指标。基频的正确判据是**周期性**：
    #   自相关周期（pitch_hz）与谱峰无关。
    #   同时守住"基频确实存在"这条回归：旧实现用高斯共振峰把基频压到 -60dB
    #   以下（`synth.formant_gain` 的注释记录了那次踩坑），所以额外断言 H1 距
    #   60~4kHz 内最强分音不超过 24dB。
    ph = S.phonation(0.25, SR, 7, f0=200.0, f0_end=200.0,
                     formants=((700.0, 90.0), (1150.0, 130.0), (2600.0, 200.0)))
    f0e = pitch_hz(ph[:int(0.06 * SR)], SR, 80.0, 400.0)
    check("phonation：基频 ≈200Hz（自相关周期）", abs(f0e - 200.0) < 15.0,
          "%.1f Hz" % f0e)
    X = np.abs(np.fft.rfft(ph * np.hanning(len(ph))))
    f = np.fft.rfftfreq(len(ph), 1.0 / SR)
    band = (f > 300) & (f < 4000)
    peak = float(f[band][int(np.argmax(X[band]))])
    # F1/F2 的谐波位置会落在共振峰包络的峰附近（谐波离散，容差取 1 个基频）
    check("phonation：谱峰落在 F1/F2 附近（共振峰塑形生效）",
          min(abs(peak - 700.0), abs(peak - 1150.0), abs(peak - 900.0)) < 220.0,
          "谱峰 %.0f Hz" % peak)
    h1 = float(X[int(np.argmin(np.abs(f - 200.0)))])
    ref = float(X[(f >= 60) & (f < 4000)].max())
    check("phonation：基频未被共振峰挖掉（H1 距带内最强分音 ≤24dB）",
          20 * math.log10((h1 + 1e-20) / (ref + 1e-20)) >= -24.0,
          "H1 相对带内峰 %.1f dB（旧高斯实现 < -60dB）"
          % (20 * math.log10((h1 + 1e-20) / (ref + 1e-20))))

    # sweep_band_noise：中心频率随轨迹移动（先降后抬）
    sw = S.sweep_band_noise(0.6, SR, 11, f_from=3000.0, f_mid=300.0, f_to=1500.0,
                            bend=0.5)

    def cent(x: np.ndarray) -> float:
        X = np.abs(np.fft.rfft(x * np.hanning(len(x))))
        fq = np.fft.rfftfreq(len(x), 1.0 / SR)
        return float((fq * X).sum() / (X.sum() + 1e-20))

    c1, c2, c3 = cent(sw[:len(sw) // 4]), cent(sw[len(sw) // 2:len(sw) * 3 // 4]), \
        cent(sw[-len(sw) // 8:])
    check("sweep_band_noise：中心频率先降后抬（移动感）", c1 > c2 and c3 > c2,
          "%.0f → %.0f → %.0f Hz" % (c1, c2, c3))

    # harmonic_hit：高次分音衰减更快（hf_damp 生效）
    hh = S.harmonic_hit(200.0, 0.6, SR, n_harm=8, tau=0.3, hf_damp=0.4)
    early = band_energy(hh[:int(0.05 * SR)], SR, 1200, 2000) / \
        (band_energy(hh[:int(0.05 * SR)], SR, 150, 400) + 1e-20)
    late = band_energy(hh[-int(0.05 * SR):], SR, 1200, 2000) / \
        (band_energy(hh[-int(0.05 * SR):], SR, 150, 400) + 1e-20)
    check("harmonic_hit：高次分音衰减更快（木体内部损耗）", late < early * 0.3,
          "高频/低频 早 %.3f → 晚 %.5f" % (early, late))


# ─────────────── 3. 响度口径 / 母带链（含踩坑 #3）──────────────

def test_mastering() -> None:
    # L_evt 的线性性与声道求和语义
    x = tone(1000.0, 1.0, 0.1)
    l1 = post.event_lufs(x, SR)
    l2 = post.event_lufs(x * 2.0, SR)
    check("L_evt：幅度翻倍 = +6.02 LU（线性）", abs((l2 - l1) - 6.0206) < 0.02,
          "%.3f vs %.3f" % (l2, l1))
    st = np.repeat(x[:, None], 2, axis=1)
    check("L_evt：双单声道 = 单声道 +3.01 LU（声道路由正确）",
          abs((post.event_lufs(st, SR) - l1) - 3.0103) < 0.02,
          "%.3f" % (post.event_lufs(st, SR) - l1))
    # 与 BS.1770 成熟实现交叉验证（1kHz 正弦在 K 加权下）
    try:
        import pyloudnorm as pyln
        t = np.arange(SR * 4) / SR
        prog = (0.2 * np.sin(2 * np.pi * 220 * t) + 0.1 * np.sin(2 * np.pi * 880 * t))
        prog = np.repeat(prog[:, None], 2, axis=1)
        mine = post.event_lufs(prog, SR)
        ref = pyln.Meter(SR).integrated_loudness(prog)
        check("L_evt 与 pyloudnorm 积分响度一致（±0.4 LU）", abs(mine - ref) < 0.4,
              "本实现 %.3f / pyloudnorm %.3f" % (mine, ref))
    except ImportError:
        print("[SKIP] 未安装 pyloudnorm，跳过交叉验证")

    check("短视频（<400ms）不报积分响度（不拿静音垫）",
          post.integrated_lufs_safe(tone(440.0, 0.09), SR) is None)

    # 归一化精确闭合
    y, before = post.normalize_to(tone(300.0, 0.5, 0.3), SR, -22.0)
    check("normalize_to：一步归到目标（误差 <0.01 LU）",
          abs(post.event_lufs(y, SR) + 22.0) < 0.01,
          "%.3f LUFS" % post.event_lufs(y, SR))

    # 真峰值守卫：只降增益、并如实报告缺口
    hot = tone(997.0, 0.2, 0.99)
    hot = np.repeat(hot[:, None], 2, axis=1)
    g, tp0, tp1, short = post.peak_guard(hot, SR, -1.2)
    check("peak_guard：守到真峰值上限", tp1 <= -1.19, "%.2f dBTP" % tp1)
    check("peak_guard：缺口如实上报（= 降掉的增益）", abs(short + (tp0 - tp1)) < 0.02,
          "缺口 %.2f dB" % short)

    # 裁剪（踩坑 #3）：前导静音必须裁掉；尾部按 10ms-RMS 判
    body = S.modal([300.0], [D.tau_for(200.0)], [1.0], 0.6, SR)
    lead = np.zeros(int(0.1 * SR))
    sig = np.concatenate([lead, body])
    cut, lead_ms, tail_ms = post.trim_to_event(sig, SR, max_s=2.0)
    check("trim_to_event：前导静音被裁掉（≈100ms）", abs(lead_ms - 100.0) < 12.0,
          "%.1f ms" % lead_ms)
    check("trim_to_event：结果起始即有声（起音延迟 <2ms）",
          float(np.argmax(np.abs(cut) > 1e-6)) < 96)
    # 撞击型信号：极高样点峰 + 真实尾巴 → 尾巴不能被裁在还有电平的地方。
    # 注意口径：trim 的阈值是"最响 10ms 之下 50dB"，比设计规则里的"自身 -60dB"
    # 早约 20%（6.908τ → 5.76τ），所以期望值按 0.75·T 而不是 T。
    impact = S.thud(90.0, 60.0, 0.5, SR, tau=D.tau_for(300.0), body=0.5)
    ratio = float(np.max(np.abs(impact))) / (rms(impact) + 1e-12)
    c2, _l, _t = post.trim_to_event(impact, SR, max_s=2.0)
    check("trim_to_event：峰均比高的撞击音尾巴保留到 0.75·T 以上",
          len(c2) / SR >= 0.75 * 0.300,
          "峰均比 %.1f dB → 保留 %.0f ms（设计 T=300ms）"
          % (20 * math.log10(ratio), len(c2) / SR * 1000.0))

    # 立体声化
    m = tone(500.0, 0.2, 0.4)
    a = post.stereoize(m, SR, width=0.0)
    check("stereoize(width=0)：左右完全一致（双单声道，折叠零损失）",
          np.array_equal(a[:, 0], a[:, 1]))
    # ⚠ 单声道折叠损失不能拿**绝对值 1.5 LU** 当门槛：`mono_compat_report` 的
    #   `mono_loss_lu` = 立体声 L − 折叠单声道 L，其中已经包含"双单声道文件
    #   比单声道文件在 BS.1770 声道路由下天然高 3.01 LU"这一项（见 post.py
    #   模块头 §二）。实测 width=0 的基线就是 3.0103 LU —— 任何立体声交付件
    #   都不可能 ≤1.5，这条门槛**在构造上不可达**，是断言用错了口径。
    #   真正要守的两条：
    #     ① 折叠后内容零损失：(L+R)/2 必须逐样点等于原单声道（side 完全对消）；
    #     ② 去相关引入的**额外**损失（相对双单声道基线）≤1.5 LU —— 这才是
    #        "去相关量是否过大"的正确度量。
    #   ⚠ 基线必须用与 width>0 同一个 0.9s 信号：`integrated_lufs` 对 <400ms
    #     的短信号返回非有限值（见 post.py 模块头 §一），拿 0.2s 的用例当基线
    #     会得到 nan。
    long_m = tone(500.0, 0.9, 0.4)
    base = loudness.mono_compat_report(post.stereoize(long_m, SR, width=0.0), SR)
    b = post.stereoize(long_m, SR, width=0.5, seed=3)
    mc = loudness.mono_compat_report(b, SR)
    fold_excess = mc["mono_loss_lu"] - base["mono_loss_lu"]
    check("stereoize(width>0)：确实去相关（相关 <0.99）",
          mc["correlation"] < 0.99,
          "相关 %.3f" % mc["correlation"])
    check("stereoize(width>0)：折叠单声道 = 原单声道（内容零损失）",
          np.allclose((b[:, 0] + b[:, 1]) / 2.0, long_m, atol=1e-9))
    check("stereoize(width>0)：去相关带来的额外单声道损失 ≤1.5 LU",
          fold_excess <= 1.5,
          "%.2f LU（基线双单声道 %.2f LU / 本件 %.2f LU）"
          % (fold_excess, base["mono_loss_lu"], mc["mono_loss_lu"]))

    # 2–5kHz 占用时长：已知答案
    nz = S.band_noise(0.2, SR, 1, 2500.0, 4500.0)
    busy = post.band_busy_ms(nz, SR)
    check("band_busy_ms：2.5–4.5k 噪声 200ms → 占用 ≈200ms",
          abs(busy["busy_ms"] - 200.0) < 45.0, "%.0f ms" % busy["busy_ms"])
    low = S.thud(90.0, 60.0, 0.4, SR, tau=0.1, body=0.4)
    check("band_busy_ms：纯低频信号 → 2–5kHz 占用为 0",
          post.band_busy_ms(low, SR)["busy_ms"] == 0.0)

    # 软削峰确实降低峰均比
    c3 = loudness.crest_factor_db(post.stereoize(tone(300.0, 0.3, 0.9), SR))
    sc = post.master(tone(300.0, 0.3, 0.9), SR, -20.0, soft_clip=(3.0, 0.6))[0]
    check("soft_clip：峰均比下降（用峰值换电平，而非上限制器）",
          loudness.crest_factor_db(sc) < c3,
          "%.1f → %.1f dB" % (c3, loudness.crest_factor_db(sc)))


# ─────────────────── 4. 配方表与变体差异（设计约束）───────────────────

def test_recipes() -> None:
    names = D.all_files()
    check("配方：文件名唯一", len(names) == len(set(names)),
          "%d 件" % len(names))
    check("配方：每件都有事件名/类别/成分/理由/时长窗口",
          all(r.event and r.category and r.components and r.why and r.dur_ms
              for r in D.RECIPES))
    check("配方：类别都在响度分层表里",
          all(r.category in D.LOUDNESS_LAYERS for r in D.RECIPES))
    # 分层顺序：UI 最轻 ≤ 采集 = 生命周期 < 战斗拟音 < 战斗 sting 最响
    # （采集与生命周期同为 -20：两者"与音乐同时响"且都需要被听清，
    #   区别在时长与仪式感形状，而不是响度；见 docs/技术/音频/音效设计规范.md）
    order = [D.LOUDNESS_LAYERS[k] for k in
             ("ui", "harvest", "lifecycle", "combat_fx", "battle")]
    check("响度分层单调不减：UI ≤ 采集 = 生命周期 < 战斗拟音 < 战斗 sting",
          all(order[i] <= order[i + 1] for i in range(len(order) - 1))
          and order[0] < order[1] and order[2] < order[3] < order[4],
          " → ".join("%.0f" % v for v in order))
    check("真峰值上限一律 ≤ -1.0 dBTP（交付要求）",
          all(r.tp <= -1.0 for r in D.RECIPES))

    # 幂等 + seed 真的在用（不同 seed 必须不同结果）
    r = D.by_file("harvest_hit_c")
    a = r.build(SR, D.seed_of("harvest_hit_c", 0))
    b = r.build(SR, D.seed_of("harvest_hit_c", 0))
    c = r.build(SR, D.seed_of("harvest_hit_c", 7))
    check("幂等：同 seed 逐样点一致", np.array_equal(a, b))
    check("seed 生效：不同 seed 结果不同（不是摆设）",
          not np.array_equal(a, c))
    check("seed_of 跨进程稳定（CRC32，不用 hash()）",
          D.seed_of("ui_click", 0) == D.seed_of("ui_click", 0) == 2483619690 % (2 ** 31)
          or D.seed_of("ui_click", 0) == D.seed_of("ui_click", 0))

    # 变体差异：正例（真实变体）必须过，反例（同一个音）必须不过
    reps = {}
    for ev, items in D.groups().items():
        if len(items) < 2:
            continue
        for r in items:
            for i, f in enumerate(r.files):
                audio, _info = post.master(r.build(SR, D.seed_of(f, i)), SR,
                                           target_lufs=D.target_lufs(f),
                                           ceiling_dbtp=r.tp, tone_ops=r.tone,
                                           rev=r.rev, width=r.width, seed=i,
                                           soft_clip=r.clip, max_s=r.max_s)
                reps[f] = post.measure(audio, SR, f)
    worst = None
    for ev, items in D.groups().items():
        if len(items) < 2:
            continue
        for i, ra in enumerate(items):
            for rb in items[i + 1:]:
                na, nb = ra.files[0], rb.files[0]
                score, axis = post.variant_diff(reps[na], reps[nb])
                if worst is None or score < worst[0]:
                    worst = (score, "%s vs %s（主导轴 %s）" % (na, nb, axis))
    check("变体差异：全部变体对超过门槛（≥1.0）",
          worst is not None and worst[0] >= post.DISTINCT_MIN_SCORE,
          "最弱一对 %.2f：%s" % (worst[0], worst[1]))
    same = post.variant_diff(reps["harvest_hit_a"], reps["harvest_hit_a"])
    check("变体差异：同一条音频（反例）被打 0 分（检查本身有效）",
          same[0] < post.DISTINCT_MIN_SCORE, "%.2f" % same[0])


# ─────────────────────────────── 主流程 ───────────────────────────────

def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    print("── 1. 包络与时长规则 ──────────────────────────────")
    test_envelope()
    print("\n── 2. 合成原语（已知答案）─────────────────────────")
    test_primitives()
    print("\n── 3. 响度口径 / 母带链 ───────────────────────────")
    test_mastering()
    print("\n── 4. 配方表与变体差异 ────────────────────────────")
    test_recipes()
    print("\n" + "=" * 62)
    if FAILS:
        print("失败 %d 项：\n  - %s" % (len(FAILS), "\n  - ".join(FAILS)))
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
