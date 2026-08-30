# -*- coding: utf-8 -*-
"""姿态对比报告器（任务 1b）。

输入 dump_spine_pose.py（或 Godot 侧同格式 dump 工具）产出的两个姿态 JSON，
按硬编码骨骼映射表逐动画逐帧对比，构成「Spine 原始动画数据 vs Godot 骨架动画」
的姿态验收链。本工具不预设任何符号约定——两侧坐标/角度关系由 discover 模式
用数据拟合自动发现（历史上两次因预设符号约定翻车，故约定必须由数据定论）。

用法：
    python tools/compare_pose.py --spine spine.json --godot godot.json --mode diff
    python tools/compare_pose.py --spine spine.json --godot godot.json --mode discover
diff 模式全 PASS 退出码 0，有 FAIL 退出码 1（可接 CI）。
"""

import argparse
import json
import math
import sys

# 骨骼映射表：Spine 原名 → Godot 骨名（两侧骨名对齐，硬编码）
# root→hip 仅对比位置，不对比角度
BONE_MAP = {
    'bone3': 'upper_torso',
    'minerhead1': 'head',
    'minerarm1': 'upper_arm_outer',
    'minerarm2': 'forearm_outer',
    'minerarm3': 'upper_arm_inner',
    'minerarm4': 'forearm_inner',
    'minerleg2': 'thigh_outer',
    'minerleg1': 'shin_outer',
    'minerfoot1': 'foot_outer',
    'minerleg4': 'thigh_inner',
    'minerleg3': 'shin_inner',
    'minerfoot2': 'foot_inner',
    'bone': 'spine_root',
    'minertorso1': 'lower_torso',
    'bone2': 'chest_mid',
    'pickaxe1': 'weapon_hand',
    'Arrow1': 'shield_hand',
    'root': 'hip',  # 仅位置
}

# 动画名映射（真相源 = stick-world/tools/baking/spine_import.gd 的 ANIM_MAP）。
# spine 动画名 → godot 动画名。Miner-Attack1 同源两个用途（attack_pickaxe/build），
# 只映射 attack_pickaxe，build 跳过（曲线相同，重复对比无意义）。
ANIM_MAP = {
    'Swordwrath-Stand1': 'idle',
    'Swordwrath-Stand2': 'idle_v2',
    'Swordwrath-Walk': 'walk',
    'Swordwrath-Run': 'run',
    'Swordwrath-Attack1': 'attack',
    'Swordwrath-Block': 'block',
    'Spearton-Attack1': 'attack_spear',
    'Miner-Attack1': 'attack_pickaxe',
    'Magikill-Spell1': 'attack_staff',
    'Archidon-Draw': 'attack_bow',
    'Death1': 'dead',
    'Death-Headshot': 'dead_headshot',
    'Hit-Mid-Front-Small-1': 'hit_front',
    'Hit-Mid-Back-Small-1': 'hit_back',
    'Miner-Walk': 'walk_carry',
    'Cheering': 'arrive',
}


# 已知故意修正豁免（镜像产线 spine_import.KEYFRAME_FIXES）：
# walk/run 的手臂轨道被手工重写（消除 idle→walk 切换"伸手卡顿"：原始起步
# 前臂 29° vs idle 0.6°，瞬间抬手）。因这两动画手臂关键帧少（6 键），
# FIXES 实际覆盖整条轨道 = 手臂曲线整体手工值，非原始数据（视觉已认可）。
# 豁免=整条轨道（True）；链下子骨（weapon/shield_hand）随之同偏，一并豁免。
KNOWN_FIXES = {
    'walk': {'forearm_outer': True, 'forearm_inner': True,
             'upper_arm_outer': True, 'upper_arm_inner': True,
             'weapon_hand': True, 'shield_hand': True},
    'run': {'upper_arm_inner': True, 'forearm_inner': True, 'weapon_hand': True},
}


def map_spine_anims(spine):
    """把 spine 侧动画键经 ANIM_MAP 翻译成 godot 名（未在映射表内的动画跳过）。"""
    out = {}
    for name, data in spine['anims'].items():
        gn = ANIM_MAP.get(name)
        if gn is not None:
            out[gn] = data
    return out


def load_dump(path):
    """加载 dump JSON 并做格式校验。"""
    with open(path, encoding='utf-8') as f:
        d = json.load(f)
    for k in ('source', 'skeleton_height', 'anims'):
        if k not in d:
            raise SystemExit(f'错误: {path} 缺少字段 "{k}"，不是合法的 dump JSON')
    return d


def angle_diff(a, b):
    """角度差归一到 [-180, 180]。"""
    return (a - b + 180.0) % 360.0 - 180.0


def bone_of(frame, spine_name, godot_name):
    """从帧数据里取骨骼姿态：优先用映射后的 godot 骨名，查不到回退 Spine 原名。

    回退使得「spine JSON vs spine JSON」自比对也能工作（两侧同名），
    真实场景下 godot dump 用映射名，不受影响。
    """
    return frame.get(godot_name, frame.get(spine_name))


def common_frames(fa, fb):
    """两侧共同帧键（按 round3 数值归一后求交集，返回排序时刻列表与键映射）。"""
    ka = {round(float(k), 3): k for k in fa}
    kb = {round(float(k), 3): k for k in fb}
    ts = sorted(set(ka) & set(kb))
    return ts, ka, kb


def lin_fit(xs, ys):
    """最小二乘一次拟合 ys ≈ s*xs + b，返回 (s, b)。"""
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    s = sxy / sxx if sxx > 1e-12 else 1.0
    b = my - s * mx
    return s, b


def residuals(xs, ys, s, b):
    """给定 s/b 的残差统计：返回 (mean_abs, rms, max)。"""
    rs = [y - (s * x + b) for x, y in zip(xs, ys)]
    mean_abs = sum(abs(r) for r in rs) / len(rs)
    rms = math.sqrt(sum(r * r for r in rs) / len(rs))
    return mean_abs, rms, max(abs(r) for r in rs)


def fit_fixed(xs, ys, sign):
    """固定符号拟合 g = sign*a + b，b 取最小二乘（=mean(g - sign*a)）。"""
    b = sum(y - sign * x for x, y in zip(xs, ys)) / len(xs)
    return sign, b


def mode_diff(spine, godot, tol_angle, tol_pos):
    """diff 模式：每动画每骨的角度增量轨迹对比。

    两侧骨架零位不同（Godot 零位=直立、Spine 零位=setup 姿势），世界角绝对值差一个
    每骨常数（W_godot ≈ b(骨) - W_spine，负号模型，discover 模式可验证）。该常数是
    结构性骨架差异、不是翻译误差——动作保真度的正确判据是**增量**：
    负号模型下两侧增量互为相反数，残差 = |wrap((g(t)-g(0)) + (a(t)-a(0)))|。
    静态偏移全部消除后，剩余残差 = 真实翻译误差（未映射骨缺口 / unwrap 分歧 /
    KEYFRAME_FIXES 手工修正）。位置对比同理：相对 t=0 的位移增量。
    """
    scale = godot['skeleton_height'] / spine['skeleton_height'] \
        if spine['skeleton_height'] else 1.0
    print(f'尺度换算: spine 高 {spine["skeleton_height"]} → godot 高 '
          f'{godot["skeleton_height"]}，位置 ×{scale:.6f}')
    print(f'容差: 角度增量残差 {tol_angle}°  位置增量 {tol_pos} 逻辑px(godot)')

    sanims = map_spine_anims(spine)
    common_anims = [a for a in sanims if a in godot['anims']]
    only_g = [a for a in godot['anims'] if a not in sanims]
    if only_g:
        print(f'警告: 仅 godot 侧有的动画(跳过): {", ".join(only_g[:8])}...')
    if not common_anims:
        print('错误: 两侧没有共同动画（检查 ANIM_MAP）')
        return 2

    angle_pairs = [(s, g) for s, g in BONE_MAP.items() if s != 'root']

    all_pass = True
    detail_lines = []
    bone_worst = {}  # 骨对 -> max 增量残差
    for an in common_anims:
        fa, fb = sanims[an]['frames'], godot['anims'][an]['frames']
        ts, ka, kb = common_frames(fa, fb)
        if not ts:
            print(f'{an}  错误: 无共同帧  [FAIL]')
            all_pass = False
            continue

        # 每动画首帧基准（角度增量 + 位置增量共用 t=0 基准）
        sa0, ga0 = fa[ka[ts[0]]], fb[kb[ts[0]]]
        pos0 = None
        n_total = 0
        n_bad = 0
        n_fix = 0
        err_sum = 0.0
        err_max = 0.0
        pos_bad = 0
        pos_max = 0.0
        for t in ts:
            sa, ga = fa[ka[t]], fb[kb[t]]
            p_root = bone_of(sa, 'root', 'hip')
            p_hip = bone_of(ga, 'root', 'hip')
            if p_root is not None and p_hip is not None:
                disp_a = (p_root['x'] * scale, p_root['y'] * scale)
                disp_g = (p_hip['x'], p_hip['y'])
                if pos0 is None:
                    pos0 = (disp_g[0] - disp_a[0], disp_g[1] - disp_a[1])
                dx = disp_g[0] - pos0[0] - disp_a[0]
                dy = disp_g[1] - pos0[1] - disp_a[1]
                dist = math.hypot(dx, dy)
                pos_max = max(pos_max, dist)
                if dist > tol_pos:
                    pos_bad += 1
                    if len(detail_lines) < 30:
                        detail_lines.append(
                            f'  {an} t={t:.3f} root↔hip 位移增量差 dx={dx:.2f} dy={dy:.2f} '
                            f'距离={dist:.3f}px')
            for sb, gb in angle_pairs:
                pa_ = bone_of(sa, sb, gb)
                pb_ = bone_of(ga, sb, gb)
                pa0_ = bone_of(sa0, sb, gb)
                pb0_ = bone_of(ga0, sb, gb)
                if pa_ is None or pb_ is None or pa0_ is None or pb0_ is None:
                    continue
                err = abs(angle_diff_sign(pb_['angle'] - pb0_['angle'],
                                          pa_['angle'] - pa0_['angle'], 0.0))
                known = bool(KNOWN_FIXES.get(an, {}).get(gb, False))
                if not known:
                    n_total += 1
                    err_sum += err
                    err_max = max(err_max, err)
                    bone_worst[(sb, gb)] = max(bone_worst.get((sb, gb), 0.0), err)
                if err > tol_angle and not known:
                    n_bad += 1
                    if len(detail_lines) < 30:
                        detail_lines.append(
                            f'  {an} t={t:.3f} {sb}↔{gb}  '
                            f'spine增量={pa_["angle"] - pa0_["angle"]:+.3f}° '
                            f'godot增量={pb_["angle"] - pb0_["angle"]:+.3f}°  '
                            f'残差={err:.3f}°')
                elif known and err > tol_angle:
                    n_fix += 1

        mean_err = err_sum / n_total if n_total else 0.0
        ok = (n_bad == 0 and pos_bad == 0)
        all_pass = all_pass and ok
        print(f'{an:<15} max={err_max:6.2f}°  mean={mean_err:5.2f}°  '
              f'超差 {n_bad}/{n_total}'
              + (f'  [位移超差 {pos_bad}(max {pos_max:.1f}px)]' if pos_bad else '')
              + (f'  [已知修正帧 {n_fix}]' if n_fix else '')
              + ('  [PASS]' if ok else '  [FAIL]'))

    print()
    print('每骨最差增量残差（定位缺口骨，0 = 转换精确）:')
    for (sb, gb), worst in sorted(bone_worst.items(), key=lambda kv: -kv[1]):
        print(f'  {sb:<14}↔ {gb:<18} max残差={worst:7.2f}°')

    print()
    print('超差明细（最多 30 行）:')
    if detail_lines:
        print(chr(10).join(detail_lines))
    else:
        print('  （无）')
    print()
    print('总结: ' + ('全部 PASS' if all_pass else '存在 FAIL'))
    return 0 if all_pass else 1


def angle_diff_sign(g, a, b):
    """负号模型残差：g - (b - a)，归一到 [-180, 180]。"""
    return (g + a - b + 180.0) % 360.0 - 180.0


def mode_discover(spine, godot):
    """discover 模式：对两侧共同首帧(t=0)做符号关系拟合，不预设约定。

    对每骨对收集 (a_spine, a_godot) 样本，比较两种符号假设：
      H+: g = +a + b   H-: g = -a + b   （s 固定 ±1，b 最小二乘）
    同时做自由拟合 g = s*a + b 报告 s（理想约定一致时 s≈+1）。
    注意：自由拟合 g=s*(-a)+b 与 g=s*a+b 数学上恒等（s 取反），残差无区分力，
    故「哪种符号关系残差最小」用固定 s=±1 的拟合判定。
    """
    pairs = [(s, g) for s, g in BONE_MAP.items() if s != 'root']
    sanims = map_spine_anims(spine)
    common_anims = [a for a in sanims if a in godot['anims']]

    samples = []  # (动画, spine骨, godot骨, a_spine, a_godot)
    for an in common_anims:
        fa = sanims[an]['frames']
        fb = godot['anims'][an]['frames']
        ts, ka, kb = common_frames(fa, fb)
        if not ts or ka.get(0.0) is None or kb.get(0.0) is None:
            continue
        sa, ga = fa[ka[0.0]], fb[kb[0.0]]
        for sb, gb in pairs:
            pa_ = bone_of(sa, sb, gb)
            pb_ = bone_of(ga, sb, gb)
            if pa_ is not None and pb_ is not None:
                samples.append((an, sb, gb, pa_['angle'], pb_['angle']))
    if not samples:
        print('错误: 两侧没有共同动画的首帧(t=0)样本')
        return 2

    print(f'discover 模式：共同动画 {len(common_anims)} 个，首帧骨对样本 '
          f'{len(samples)} 个（映射表 {len(pairs)} 对）\n')

    a_all = [s[3] for s in samples]
    g_all = [s[4] for s in samples]

    # 自由拟合（参考量）：理想情况 s≈+1, b≈0
    s_free, b_free = lin_fit(a_all, g_all)
    free_stat = residuals(a_all, g_all, s_free, b_free)

    # 固定符号拟合（判据）
    s_p, b_p = fit_fixed(a_all, g_all, +1.0)
    s_m, b_m = fit_fixed(a_all, g_all, -1.0)
    stat_p = residuals(a_all, g_all, s_p, b_p)
    stat_m = residuals(a_all, g_all, s_m, b_m)

    print('自由拟合 g = s·a_spine + b :  '
          f's={s_free:+.4f}  b={b_free:+.4f}  '
          f'mean|r|={free_stat[0]:.4f}°  rms={free_stat[1]:.4f}°')
    print(f'假设 H+ (g = +a+b):  mean|r|={stat_p[0]:.4f}°  rms={stat_p[1]:.4f}°')
    print(f'假设 H- (g = -a+b):  mean|r|={stat_m[0]:.4f}°  rms={stat_m[1]:.4f}°')

    if stat_p[1] <= stat_m[1]:
        win_sign, win_b, win_stat = +1.0, b_p, stat_p
        verdict = '取正号（g = +a_spine + b，两侧角度约定一致，未翻转）'
    else:
        win_sign, win_b, win_stat = -1.0, b_m, stat_m
        verdict = '取负号（g = -a_spine + b，godot 侧角度相对 spine 整体翻转）'

    print(f'\n结论: 全局残差最小 → {verdict}')
    print(f'全局: b={win_b:+.4f}°  mean|r|={win_stat[0]:.4f}°  '
          f'rms={win_stat[1]:.4f}°  max|r|={win_stat[2]:.4f}°')

    # 每骨 b 偏移（胜出符号下 b_i = mean(g_i - sign·a_i)）
    print('\n每骨 b 偏移量（度，胜出符号下）:')
    by_bone = {}
    for an, sb, gb, av, gv in samples:
        by_bone.setdefault((sb, gb), []).append(gv - win_sign * av)
    for (sb, gb), bs in sorted(by_bone.items()):
        bi = sum(bs) / len(bs)
        print(f'  {sb:<14}→ {gb:<18} b={bi:+8.3f}°  (n={len(bs)})')

    if abs(win_stat[1]) < 1e-6 and abs(s_free - 1.0) < 1e-6 and abs(win_b) < 1e-6:
        print('\n自比对成立: 正号、残差≈0、s≈1、b≈0')
    return 0


def main():
    ap = argparse.ArgumentParser(description='姿态对比报告器（姿态验收链 1b）')
    ap.add_argument('--spine', required=True, help='Spine 侧 dump JSON')
    ap.add_argument('--godot', required=True, help='Godot 侧 dump JSON')
    ap.add_argument('--tol-angle', type=float, default=1.0, help='角度容差（度，默认 1.0）')
    ap.add_argument('--tol-pos', type=float, default=1.0, help='位置容差（godot 逻辑px，默认 1.0）')
    ap.add_argument('--mode', choices=['diff', 'discover'], default='diff',
                    help='diff=逐帧验收 discover=符号关系拟合定论')
    args = ap.parse_args()

    spine = load_dump(args.spine)
    godot = load_dump(args.godot)
    print(f'spine: {args.spine} (source={spine["source"]})   '
          f'godot: {args.godot} (source={godot["source"]})   模式: {args.mode}\n')

    if args.mode == 'discover':
        return mode_discover(spine, godot)
    return mode_diff(spine, godot, args.tol_angle, args.tol_pos)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
