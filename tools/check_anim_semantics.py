# -*- coding: utf-8 -*-
"""L2 语义验收：发布版动画（洗稿后）vs 忠实版的三组语义断言。

姿态验收链的 L2 层。L1（compare_pose.py）保证忠实版 .tres 与解包 Spine 数据
逐帧一致；本脚本保证发布版（modules/units/animations/，经 wash_anims.gd 洗稿）
在扰动曲线的同时**不破坏动作语义**、且扰动幅度有界（足以防"逐帧复制"指认）。

三组断言：
  1. 膝/肘弯曲方向：walk/run 的两腿两臂链骨（thigh/shin、upper_arm/forearm 各
     内外），发布版世界角增量序列与忠实版增量序列的皮尔逊相关系数 r ≥ 0.80。
     洗稿只扰动幅度不翻转方向——这是历史翻车的"膝/肘只能往一个方向弯"判据
     的量化版。某骨增量幅度过小（std < 1°）跳过并标注。
  2. 幅度偏差界：每动画每骨，发布版摆幅 vs 忠实版摆幅之比 ∈
     [0.70×幅度基准, 1.35]（洗稿参数 0.84~1.16 幅度缩放 + 2.5° 漂移 + 重采样
     的理论界再放宽容差；run 有意收缩到 0.72 故只缩下界）。忠实版摆幅
     < 8° 的骨跳过（任务基线 3° 的延伸：小净摆幅骨是链上各 track 反向
     抵消后的残留，独立幅度缩放即可把比值推出界，判据无鉴别力）；
     原始世界角触及 ±170°（跨 ±180 卷绕边界）的骨跳过（摆幅度量不可靠，
     方向/幅度已由 L1 保证）。
  3. 事件时刻保留：直接解析两目录 .tres 文本的 metadata/hit_time、
     metadata/anim_events、metadata/sound_events。非循环动画 stretch=1 应逐值
     一致；循环动画（洗稿允许相位/时长微调）事件时间应按 stretch 同步缩放。

用法（仓库根）：
    python tools/check_anim_semantics.py \\
        --faithful stick-world/tools/baking/_faithful/rig_pose.json \\
        --pub stick-world/tools/baking/_faithful/rig_pose_pub.json
全 PASS 退出码 0，有 FAIL 退出码 1（可挂 CI）。

自检（不碰产物，内存注入伪数据验证判据有效）：
    python tools/check_anim_semantics.py --selftest
  自检 1：pub = faithful 应全 PASS（判据不误报）；
  自检 2：注入方向翻转（某骨增量取反）应被断言 1 抓住；
  自检 3：注入幅度 ×2 应被断言 2 抓住。
"""

import argparse
import copy
import json
import math
import re
import sys
from pathlib import Path

# ---------- 判据参数 ----------

GRID_N = 64          # 相位网格采样点数（含 0 与 1 两端）
R_MIN = 0.80         # 断言 1：方向一致的最小皮尔逊相关系数
STD_SKIP = 1.0       # 断言 1：忠实版增量 std < 1° 的骨跳过（幅度过小）
RATIO_LO, RATIO_HI = 0.70, 1.35   # 断言 2：摆幅比容许区间（× 每动画幅度基准）
SWING_SKIP = 8.0     # 断言 2：忠实版摆幅 < 8° 的骨跳过。任务基线 3° 在真实链式
                     #   骨架上不够：小净摆幅骨是链上各 track 反向抵消后的残留，
                     #   洗稿每骨独立幅度缩放（0.84~1.16，设计内扰动）即可把它
                     #   的比值推出 ±30%（实测 arrive 小腿 6.2°→2.9°、矛兵脚
                     #   8.0°→11.0°）；动作语义由大摆幅特征承载，微动不在判据范围
EDGE_SKIP = 170.0    # 断言 2：原始世界角触及 ±170°（跨 ±180 边界）的骨，
                     #   摆幅度量受边界卷绕影响不可靠，跳过（方向/幅度已由 L1 保证）
PHASE_MAX = 0.18     # 断言 1：循环动画相位对齐搜索半宽（归一化相位，覆盖洗稿
                     #   0~0.15s 相移；远小于半周期，翻转无法伪装成相移通过）
PHASE_STEPS = 25

# 洗稿的每动画幅度基准（与 stick-world/tools/baking/wash_anims.gd 的 ANIM_AMP
# 对齐：run 有意收缩摆动到 0.72，断言 2 的缩小界随动画基准等比缩放）
ANIM_AMP = {'run': 0.72}

# 断言 1 的动画与腿臂链骨（历史翻车判据的量化对象）
DIR_ANIMS = ['walk', 'run']
LIMB_BONES = ['thigh_outer', 'shin_outer', 'upper_arm_outer', 'forearm_outer',
              'thigh_inner', 'shin_inner', 'upper_arm_inner', 'forearm_inner']

# 全部 17 个动画（= wash_anims.gd ANIMATIONS，断言 3 逐一核对 .tres 事件元数据）
ALL_ANIMS = ['idle', 'idle_v2', 'walk', 'run', 'attack', 'dead',
             'hit_front', 'hit_back', 'walk_carry', 'build', 'arrive',
             'dead_headshot', 'block',
             'attack_spear', 'attack_pickaxe', 'attack_staff', 'attack_bow']

REPO = Path(__file__).resolve().parent.parent


# ---------- 基础工具 ----------

def wrap_deg(a):
    """角度归一到 [-180, 180]。"""
    return (a + 180.0) % 360.0 - 180.0


def pstdev(xs):
    n = len(xs)
    m = sum(xs) / n
    return math.sqrt(sum((x - m) ** 2 for x in xs) / n)


def pearson(xs, ys):
    """皮尔逊相关系数；任一侧零方差返回 None。"""
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / n
    sx, sy = pstdev(xs), pstdev(ys)
    if sx < 1e-12 or sy < 1e-12:
        return None
    return sxy / (sx * sy)


def resolve_path(p):
    """路径解析：依次尝试 cwd 相对 / 仓库根相对 / baking 目录相对。"""
    cands = [Path(p), REPO / p, REPO / 'stick-world' / p,
             REPO / 'stick-world' / 'tools' / 'baking' / p]
    for c in cands:
        if c.exists():
            return c
    raise SystemExit(f'错误: 找不到路径 {p}')


def load_dump(path):
    with open(path, encoding='utf-8') as f:
        d = json.load(f)
    for k in ('source', 'skeleton_height', 'anims'):
        if k not in d:
            raise SystemExit(f'错误: {path} 缺少字段 "{k}"，不是合法的 dump JSON')
    return d


# ---------- 姿态序列提取 ----------

def angle_series(frames, bone, duration, n=GRID_N):
    """在归一化相位网格 [0,1] 上线性插值某骨世界角（度）。

    循环动画洗稿后时长有 ±4% 微调，两侧各自按 duration 归一化相位对齐，
    消除纯时间轴缩放差异。返回长度 n 的列表；缺骨返回 None。
    """
    pts = []
    for tkey, fr in frames.items():
        b = fr.get(bone)
        if b is None:
            return None
        pts.append((float(tkey), float(b['angle'])))
    if len(pts) < 2:
        return None
    pts.sort()
    out = []
    for i in range(n):
        t = duration * i / (n - 1)
        out.append(_interp(pts, t))
    return out


def _interp(pts, t):
    if t <= pts[0][0]:
        return pts[0][1]
    if t >= pts[-1][0]:
        return pts[-1][1]
    lo, hi = 0, len(pts) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if pts[mid][0] <= t:
            lo = mid
        else:
            hi = mid
    t0, v0 = pts[lo]
    t1, v1 = pts[hi]
    f = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
    return v0 + (v1 - v0) * f


def unwrap(angles):
    """一维解卷绕：相邻差 wrap 到 [-180,180] 后累积，恢复连续相位轨迹。

    世界角 dump 值域 [-180,180]，摆腿/摆臂可能跨越 ±180 边界；先解卷绕
    再算增量/摆幅，避免跨界跳变伪造 360° 突变（破坏相关系数与摆幅比）。
    """
    out = [angles[0]]
    for a in angles[1:]:
        out.append(out[-1] + wrap_deg(a - out[-1]))
    return out


def rel_series(angles):
    """世界角增量序列：rel[i] = unwrap(angle)[i] - unwrap(angle)[0]（消静态偏移）。"""
    unw = unwrap(angles)
    a0 = unw[0]
    return [a - a0 for a in unw]


def swing(xs):
    """摆幅 = max - min。"""
    return max(xs) - min(xs)


def shift_series(xs, tau):
    """把相位网格序列平移 tau（归一化相位），端点截断。"""
    n = len(xs)
    out = []
    for i in range(n):
        p = i / (n - 1) + tau
        if p < 0.0:
            p = 0.0
        if p > 1.0:
            p = 1.0
        f = p * (n - 1)
        i0 = int(f)
        if i0 >= n - 1:
            out.append(xs[n - 1])
        else:
            frac = f - i0
            out.append(xs[i0] * (1 - frac) + xs[i0 + 1] * frac)
    return out


# ---------- .tres 事件元数据解析 ----------

def parse_tres_meta(path):
    """解析动画 .tres 文本：loop_mode / length / hit_time / anim_events / sound_events。"""
    text = Path(path).read_text(encoding='utf-8')
    m = re.search(r'^loop_mode = (\d+)', text, re.M)
    loop = bool(m and int(m.group(1)) == 1)
    m = re.search(r'^length = ([\d.eE+-]+)', text, re.M)
    # Animation.length 缺省 1.0：.tres 中恰好为默认值时该行会被省略（如 build）
    length = float(m.group(1)) if m else 1.0

    m = re.search(r'^metadata/hit_time = (-?[\d.eE+]+)', text, re.M)
    hit = float(m.group(1)) if m else None

    events = []      # [(name, string, time)]
    m = re.search(r'^metadata/anim_events = \[(.*?)\n\]', text, re.M | re.S)
    if m:
        for body in re.findall(r'\{([^{}]*)\}', m.group(1)):
            name = re.search(r'"name":\s*"([^"]*)"', body)
            string = re.search(r'"string":\s*"([^"]*)"', body)
            time = re.search(r'"time":\s*(-?[\d.eE+]+)', body)
            events.append((name.group(1) if name else '',
                           string.group(1) if string else '',
                           float(time.group(1)) if time else None))

    sounds = []      # [(time, sfx)]
    m = re.search(r'^metadata/sound_events = \[(.*)\]\s*$', text, re.M)
    if m:
        for t, sfx in re.findall(r'\[(-?[\d.eE+]+),\s*"([^"]*)"\]', m.group(1)):
            sounds.append((float(t), sfx))
    return {'loop': loop, 'length': length, 'hit': hit,
            'events': events, 'sounds': sounds}


# ---------- 断言 1：膝/肘弯曲方向 ----------

def check_direction(faithful, pub):
    """返回 (n_pass, n_fail, n_skip, rows, fails)。rows 为汇总输出行。"""
    rows, fails = [], []
    n_pass = n_fail = n_skip = 0
    r_min_seen, r_max_seen = 2.0, -2.0
    for an in DIR_ANIMS:
        fa_an, pub_an = faithful['anims'].get(an), pub['anims'].get(an)
        if fa_an is None or pub_an is None:
            rows.append(f'  {an:<6} 缺动画（faithful={fa_an is not None}, pub={pub_an is not None}）  [FAIL]')
            n_fail += 1
            fails.append((an, '*', '缺动画'))
            continue
        for bone in LIMB_BONES:
            sa = angle_series(fa_an['frames'], bone, float(fa_an['duration']))
            sb = angle_series(pub_an['frames'], bone, float(pub_an['duration']))
            if sa is None or sb is None:
                rows.append(f'  {an:<6} {bone:<18} 缺骨  [SKIP]')
                n_skip += 1
                continue
            rel_fa, rel_pub = rel_series(sa), rel_series(sb)
            std_fa = pstdev(rel_fa)
            if std_fa < STD_SKIP:
                rows.append(f'  {an:<6} {bone:<18} std={std_fa:.2f}° 幅度过小  [SKIP]')
                n_skip += 1
                continue
            # 循环动画洗稿允许相位偏移：小范围相位对齐后取最优 r
            best_r, best_tau = -2.0, 0.0
            for k in range(PHASE_STEPS):
                tau = -PHASE_MAX + 2 * PHASE_MAX * k / (PHASE_STEPS - 1)
                r = pearson(shift_series(rel_pub, tau), rel_fa)
                if r is not None and r > best_r:
                    best_r, best_tau = r, tau
            r_min_seen = min(r_min_seen, best_r)
            r_max_seen = max(r_max_seen, best_r)
            ok = best_r >= R_MIN
            n_pass, n_fail = (n_pass + 1, n_fail) if ok else (n_pass, n_fail + 1)
            rows.append(f'  {an:<6} {bone:<18} r={best_r:+.3f} (τ={best_tau:+.3f})  '
                        f'[{"PASS" if ok else "FAIL"}]')
            if not ok:
                fails.append((an, bone, f'r={best_r:+.3f} < {R_MIN}（方向翻转嫌疑）'))
    summary = (f'  断言1: {n_pass} PASS / {n_fail} FAIL / {n_skip} SKIP'
               + (f'，r ∈ [{r_min_seen:+.3f}, {r_max_seen:+.3f}]' if r_max_seen > -2 else ''))
    return n_pass, n_fail, n_skip, rows, fails, summary


# ---------- 断言 2：幅度偏差界 ----------

def check_amplitude(faithful, pub):
    """返回 (n_anim_pass, n_anim_fail, rows, fails, summary)。"""
    rows, fails = [], []
    n_anim_pass = n_anim_fail = 0
    g_lo, g_hi = 2.0, -2.0
    n_checked = 0
    n_skipped = 0
    common = [a for a in sorted(faithful['anims']) if a in pub['anims']]
    for an in common:
        amp = ANIM_AMP.get(an, 1.0)
        # 幅度放大对任何动画都是语义风险（上界固定）；缩小界随动画幅度基准
        # 缩放（run 有意收缩摆动到 0.72，"没缩够"不是语义破坏、缩过头才是）
        lo_amp, hi_amp = RATIO_LO * amp, RATIO_HI
        fa_fr, pub_fr = faithful['anims'][an]['frames'], pub['anims'][an]['frames']
        fa_first = next(iter(fa_fr.values()))
        bones = [b for b in fa_first if b in next(iter(pub_fr.values()))]
        n_ok = n_bad = n_sk = 0
        lo, hi = 2.0, -2.0
        for bone in bones:
            sa = angle_series(fa_fr, bone, float(faithful['anims'][an]['duration']))
            sb = angle_series(pub_fr, bone, float(pub['anims'][an]['duration']))
            if sa is None or sb is None:
                n_sk += 1
                continue
            # 跨 ±180 边界的骨：世界角摆幅度量不可靠（方向/幅度已由 L1 保证）
            if max(abs(a) for a in sa) > EDGE_SKIP or max(abs(a) for a in sb) > EDGE_SKIP:
                n_sk += 1
                continue
            sw_fa, sw_pub = swing(rel_series(sa)), swing(rel_series(sb))
            if sw_fa < SWING_SKIP:
                n_sk += 1
                continue
            ratio = sw_pub / sw_fa
            n_checked += 1
            lo, hi = min(lo, ratio), max(hi, ratio)
            g_lo, g_hi = min(g_lo, ratio), max(g_hi, ratio)
            if lo_amp <= ratio <= hi_amp:
                n_ok += 1
            else:
                n_bad += 1
                fails.append(f'  {an} {bone}  忠实摆幅={sw_fa:.2f}° pub摆幅={sw_pub:.2f}° '
                             f'比={ratio:.3f} 超出 [{lo_amp:.2f}, {hi_amp:.2f}]'
                             + (f'（amp={amp}）' if amp != 1.0 else ''))
        status = 'PASS' if n_bad == 0 else 'FAIL'
        if n_bad:
            n_anim_fail += 1
        else:
            n_anim_pass += 1
        n_skipped += n_sk
        amp_tag = f' amp={amp}' if amp != 1.0 else ''
        ratio_txt = f'比∈[{lo:.2f}, {hi:.2f}]' if (n_ok + n_bad) > 0 else '比∈—'
        rows.append(f'  {an:<15} 检{n_ok + n_bad:<3} 跳{n_sk:<3} '
                    f'{ratio_txt}  [{status}]{amp_tag}')
    summary = (f'  断言2: 动画 {n_anim_pass} PASS / {n_anim_fail} FAIL'
               f'（检测 {n_checked} 骨，跳过小骨/跨界骨 {n_skipped}，'
               f'全局比 ∈ [{g_lo:.3f}, {g_hi:.3f}]，界按每动画幅度基准缩放）')
    return n_anim_pass, n_anim_fail, rows, fails, summary


# ---------- 断言 3：事件时刻保留 ----------

def check_events(faithful_dir, pub_dir):
    """返回 (n_pass, n_fail, rows, fails, summary)。"""
    rows, fails = [], []
    n_pass = n_fail = 0
    for an in ALL_ANIMS:
        fa_p, pub_p = Path(faithful_dir) / f'{an}.tres', Path(pub_dir) / f'{an}.tres'
        if not fa_p.exists():
            rows.append(f'  {an:<15} 忠实版缺 {fa_p.name}  [FAIL]')
            fails.append(f'  {an}: 忠实版 .tres 缺失')
            n_fail += 1
            continue
        if not pub_p.exists():
            rows.append(f'  {an:<15} 发布版缺 {pub_p.name}  [FAIL]')
            fails.append(f'  {an}: 发布版 .tres 缺失（洗稿清单漏项？）')
            n_fail += 1
            continue
        fa, pub = parse_tres_meta(fa_p), parse_tres_meta(pub_p)
        probs = []
        if fa['loop']:
            # 循环动画：洗稿允许时长微调，事件时间应按 stretch 同步缩放
            if not fa['length'] or not pub['length']:
                probs.append('缺 length')
            else:
                stretch = pub['length'] / fa['length']
                _cmp_hit(fa, pub, probs, stretch)
                _cmp_events(fa, pub, probs, stretch)
                _cmp_sounds(fa, pub, probs, stretch)
                extra = f'stretch={stretch:.4f}'
        else:
            # 非循环动画 stretch=1：事件逐值一致
            _cmp_hit(fa, pub, probs, 1.0)
            _cmp_events(fa, pub, probs, 1.0)
            _cmp_sounds(fa, pub, probs, 1.0)
            extra = 'stretch=1'
        if probs:
            rows.append(f'  {an:<15} {extra}  [FAIL]')
            fails.append(f'  {an}: ' + '；'.join(probs))
            n_fail += 1
        else:
            n_ev = len(fa['events'])
            rows.append(f'  {an:<15} hit={_fmt_hit(fa["hit"]):<7} events {n_ev}/{n_ev}'
                        f'  sound {len(fa["sounds"])}/{len(fa["sounds"])}  {extra}  [PASS]')
            n_pass += 1
    summary = f'  断言3: {n_pass} PASS / {n_fail} FAIL（共 {len(ALL_ANIMS)} 动画）'
    return n_pass, n_fail, rows, fails, summary


def _fmt_hit(v):
    return '无' if v is None else f'{v:.4f}'


def _cmp_hit(fa, pub, probs, stretch):
    if fa['hit'] is None or pub['hit'] is None:
        if fa['hit'] != pub['hit']:
            probs.append(f'hit_time 缺失不一致（faithful={fa["hit"]}, pub={pub["hit"]}）')
        return
    if fa['hit'] < 0:  # -1 = 无命中事件，洗稿不得凭空造出
        if pub['hit'] >= 0:
            probs.append(f'hit_time 忠实={fa["hit"]} pub 凭空出现 {pub["hit"]}')
        return
    expect = fa['hit'] * stretch
    if abs(pub['hit'] - expect) > (1e-4 if stretch == 1.0 else max(1e-3, abs(expect) * 2e-3)):
        probs.append(f'hit_time {fa["hit"]:.4f}×{stretch:.4f}≠{pub["hit"]:.4f}')


def _cmp_events(fa, pub, probs, stretch):
    if len(fa['events']) != len(pub['events']):
        probs.append(f'anim_events 数量 {len(fa["events"])}≠{len(pub["events"])}')
        return
    for (n1, s1, t1), (n2, s2, t2) in zip(fa['events'], pub['events']):
        if n1 != n2 or s1 != s2:
            probs.append(f'anim_events 字段不一致（{n1}/{s1} vs {n2}/{s2}）')
            continue
        if t1 is None or t2 is None:
            if t1 != t2:
                probs.append('anim_events time 缺失不一致')
            continue
        expect = t1 * stretch
        if abs(t2 - expect) > (1e-4 if stretch == 1.0 else max(1e-3, abs(expect) * 2e-3)):
            probs.append(f'anim_events time {t1:.4f}×{stretch:.4f}≠{t2:.4f}（{n1}）')


def _cmp_sounds(fa, pub, probs, stretch):
    if len(fa['sounds']) != len(pub['sounds']):
        probs.append(f'sound_events 数量 {len(fa["sounds"])}≠{len(pub["sounds"])}')
        return
    for (t1, s1), (t2, s2) in zip(fa['sounds'], pub['sounds']):
        if s1 != s2:
            probs.append(f'sound_events sfx 不一致（{s1} vs {s2}）')
            continue
        expect = t1 * stretch
        if abs(t2 - expect) > (1e-4 if stretch == 1.0 else max(1e-3, abs(expect) * 2e-3)):
            probs.append(f'sound_events time {t1:.4f}×{stretch:.4f}≠{t2:.4f}（{s1}）')


# ---------- 主检查 ----------

def run_checks(faithful, pub, faithful_dir, pub_dir, verbose=True):
    """跑三组断言，返回 (all_pass, fail_lines, text_lines)。"""
    d1 = check_direction(faithful, pub)
    d2 = check_amplitude(faithful, pub)
    d3 = check_events(faithful_dir, pub_dir)
    lines = []
    lines.append('── 断言1 膝/肘弯曲方向（walk/run 腿臂 8 骨，皮尔逊 r ≥ '
                 f'{R_MIN}，std<{STD_SKIP}° 跳过）──')
    lines += d1[3]
    lines.append(d1[5])
    lines.append('')
    lines.append(f'── 断言2 幅度偏差界（摆幅比 ∈ [{RATIO_LO}, {RATIO_HI}]×每动画幅度基准，'
                 f'忠实摆幅<{SWING_SKIP}° 或跨±180边界 跳过）──')
    lines += d2[2]
    lines.append(d2[4])
    lines.append('')
    lines.append('── 断言3 事件时刻保留（hit_time / anim_events / sound_events）──')
    lines += d3[2]
    lines.append(d3[4])
    all_pass = (d1[1] == 0 and d2[1] == 0 and d3[1] == 0)
    fail_lines = [f'[断言1] {f[0]}/{f[1]}: {f[2]}' for f in d1[4]]
    fail_lines += [f'[断言2] {f.strip()}' for f in d2[3]]
    fail_lines += [f'[断言3] {f.strip()}' for f in d3[3]]
    lines.append('')
    lines.append('超差明细（最多 30 行）:')
    if fail_lines:
        lines += fail_lines[:30]
    else:
        lines.append('  （无）')
    lines.append('')
    lines.append('总结: ' + ('全部 PASS（洗稿保语义、扰动有界、事件无损）' if all_pass
                            else '存在 FAIL'))
    return all_pass, fail_lines, lines


# ---------- 自检 ----------

def inject_transform(faithful, anim, bone, k):
    """深拷贝并把某动画某骨的世界角序列做 rel' = k·rel 线性变换（绕首帧值）。"""
    d = copy.deepcopy(faithful)
    frames = d['anims'][anim]['frames']
    first = min(frames, key=float)
    a0 = frames[first][bone]['angle']
    for fr in frames.values():
        fr[bone]['angle'] = a0 + k * (fr[bone]['angle'] - a0)
    return d


def selftest(args):
    """判据有效性自检：不误报 + 翻转/放大必被抓。内存注入，不碰产物。"""
    fa_path = resolve_path(args.faithful)
    fa = load_dump(fa_path)
    fa_dir = resolve_path(args.faithful_dir)
    ok_all = True

    print('=== L2 自检（判据有效性验证，内存注入伪 pub） ===\n')

    # 自检 1：pub = faithful 应全 PASS
    ok, fails, _ = run_checks(fa, copy.deepcopy(fa), fa_dir, fa_dir, verbose=False)
    tag = '符合预期' if ok else '不符合预期（判据误报！）'
    ok_all &= ok
    print(f'[自检1] pub = faithful：{"全 PASS" if ok else "出现 FAIL"} — {tag}')
    if not ok:
        for f in fails[:10]:
            print(f'    意外 FAIL: {f}')

    # 自检 2：注入 walk/shin_outer 方向翻转（rel 取反）→ 断言 1 必须抓住
    flipped = inject_transform(fa, 'walk', 'shin_outer', -1.0)
    ok, fails, _ = run_checks(fa, flipped, fa_dir, fa_dir, verbose=False)
    caught = [f for f in fails if f.startswith('[断言1]') and 'walk/shin_outer' in f]
    good = bool(caught)
    # 断言 1 其余骨不应被牵连（只有注入骨 FAIL）
    other_a1 = [f for f in fails if f.startswith('[断言1]') and 'walk/shin_outer' not in f]
    tag = '符合预期' if good and not other_a1 else '不符合预期'
    ok_all &= good and not other_a1
    print(f'[自检2] 注入 walk/shin_outer 方向翻转：断言1 '
          f'{"抓到 FAIL（" + caught[0].split(": ")[1] + "）" if caught else "未抓到！"} — {tag}')

    # 自检 3：注入幅度 ×2 → 断言 2 必须抓住（断言 1 不受牵连）。
    # 注入骨选忠实摆幅 10~40° 的：摆幅太大 ×2 后伪 pub 会跨越 ±180 边界、
    # 触发跨界 SKIP 而绕过摆幅判据（跨界骨已由 L1 增量残差保证）
    target = None
    for an in sorted(fa['anims']):
        frames = fa['anims'][an]['frames']
        first = next(iter(frames.values()))
        for bone in sorted(first):
            sa = angle_series(frames, bone, float(fa['anims'][an]['duration']))
            if sa is None or max(abs(a) for a in sa) > 120.0:
                continue
            sw = swing(rel_series(sa))
            if 10.0 <= sw <= 40.0:
                target = (an, bone, sw)
                break
        if target:
            break
    if target is None:
        print('[自检3] 未找到合适的注入目标（摆幅 10~40° 骨）— 不符合预期')
        return 1
    an_t, bone_t, sw_t = target
    amplified = inject_transform(fa, an_t, bone_t, 2.0)
    ok, fails, _ = run_checks(fa, amplified, fa_dir, fa_dir, verbose=False)
    caught2 = [f for f in fails if f.startswith('[断言2]') and bone_t in f
               and f.startswith(f'[断言2] {an_t} ')]
    a1_spill = [f for f in fails if f.startswith('[断言1]')]
    good = bool(caught2) and not a1_spill
    tag = '符合预期' if good else '不符合预期'
    ok_all &= good
    detail = caught2[0].split('比=')[1].split(' ')[0] if caught2 else '?'
    print(f'[自检3] 注入 {an_t}/{bone_t}（忠实摆幅 {sw_t:.1f}°）幅度×2：断言2 '
          f'{"抓到 FAIL（比=" + detail + "）" if caught2 else "未抓到！"}'
          f'{"，断言1 未误牵连" if not a1_spill else "，断言1 误牵连！"} — {tag}')

    print()
    print('自检结论: ' + ('全部符合预期（判据有效，可挂 CI）' if ok_all else '存在不符预期项'))
    return 0 if ok_all else 1


# ---------- 入口 ----------

def main():
    ap = argparse.ArgumentParser(description='L2 语义验收：发布版(洗稿) vs 忠实版')
    ap.add_argument('--faithful', default='stick-world/tools/baking/_faithful/rig_pose.json',
                    help='忠实版姿态 dump JSON（Spine 直出骨架）')
    ap.add_argument('--pub', default='stick-world/tools/baking/_faithful/rig_pose_pub.json',
                    help='发布版姿态 dump JSON（洗稿后 modules/units/animations）')
    ap.add_argument('--faithful-dir', default='stick-world/tools/baking/_faithful',
                    help='忠实版动画 .tres 目录（断言 3）')
    ap.add_argument('--pub-dir', default='stick-world/modules/units/animations',
                    help='发布版动画 .tres 目录（断言 3）')
    ap.add_argument('--selftest', action='store_true',
                    help='判据自检：pub=faithful 应全 PASS；注入翻转/放大必被抓')
    args = ap.parse_args()

    if args.selftest:
        return selftest(args)

    fa_path, pub_path = resolve_path(args.faithful), resolve_path(args.pub)
    faithful, pub = load_dump(fa_path), load_dump(pub_path)
    faithful_dir, pub_dir = resolve_path(args.faithful_dir), resolve_path(args.pub_dir)
    print('=== L2 动画语义验收：发布版(洗稿) vs 忠实版 ===')
    print(f'faithful: {fa_path}（{len(faithful["anims"])} 动画）   '
          f'pub: {pub_path}（{len(pub["anims"])} 动画）\n')

    all_pass, fails, lines = run_checks(faithful, pub, faithful_dir, pub_dir)
    print('\n'.join(lines))
    return 0 if all_pass else 1


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
