# -*- coding: utf-8 -*-
"""S1 端到端保真校验：.tres BEZIER 轨采样值 vs Spine 原数据独立求值。
用法：godot --headless --path . --script res://tools/baking/dump_bezier_samples.gd 生成 temp/bezier_samples.tsv，再 python tools/baking/verify_bezier_import.py。"""
import json
import math

SPINE = r"F:/VSCode/stickworld/external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt"
TSV = "temp/bezier_samples.tsv"
AM = {'attack': 'Swordwrath-Attack1', 'walk': 'Swordwrath-Walk',
      'attack_bow': 'Archidon-Draw', 'run': 'Swordwrath-Run', 'dead': 'Death1',
      'hit_front': 'Hit-Mid-Front-Small-1', 'idle_spear': 'Spearton-Stand1',
      'attack_spear': 'Spearton-Attack1', 'block_attack_3': 'Spearton-Block-Attack3',
      'attack_2': 'Swordwrath-Attack2', 'attack_spear_throw': 'Spearton-Throw',
      'run_spear': 'Spearton-Run', 'attack_bow_reload': 'Archidon-Reload'}
M = {'bone3': 7, 'minerhead1': 10, 'minerarm1': 18, 'minerarm2': 1, 'minerarm3': 19,
     'minerarm4': 14, 'minerleg2': 16, 'minerleg1': 3, 'minerfoot1': 4, 'minerleg4': 17,
     'minerleg3': 11, 'minerfoot2': 12, 'bone': 21, 'minertorso1': 6, 'bone2': 22,
     'pickaxe1': 23, 'Arrow1': 24}
NAMES = {0: 'hip', 1: 'forearm_outer', 2: 'hand_outer', 3: 'shin_outer', 4: 'foot_outer',
         5: 'toe_outer', 6: 'lower_torso', 7: 'upper_torso', 9: 'neck', 10: 'head',
         11: 'shin_inner', 12: 'foot_inner', 13: 'toe_inner', 14: 'forearm_inner',
         15: 'hand_inner', 16: 'thigh_outer', 17: 'thigh_inner', 18: 'upper_arm_outer',
         19: 'upper_arm_inner', 21: 'spine_root', 22: 'chest_mid', 23: 'weapon_hand',
         24: 'shield_hand'}
PAR = {0: -1, 21: 0, 16: 21, 3: 16, 4: 3, 5: 4, 17: 21, 11: 17, 12: 11, 13: 12,
       6: 21, 22: 6, 7: 22, 18: 7, 1: 18, 2: 1, 24: 2, 19: 7, 14: 19, 15: 14,
       23: 15, 9: 7, 10: 9}


def path_of(b):
    parts = []
    while b >= 0:
        parts.insert(0, NAMES[b])
        b = PAR[b]
    return '/'.join(parts)


def bez1(u, c1, c2):
    v = 1.0 - u
    return 3.0 * v * v * u * c1 + 3.0 * v * u * u * c2 + u * u * u


def bezd(u, c1, c2):
    v = 1.0 - u
    return 3.0 * v * v * c1 + 6.0 * v * u * (c2 - c1) + 3.0 * u * u * (1.0 - c2)


def expand_curve(k):
    if "curve" not in k:
        return None
    c = k["curve"]
    if c == "stepped":
        return "stepped"
    return [float(c), float(k.get("c2", 0.0)), float(k.get("c3", 1.0)), float(k.get("c4", 1.0))]


def main():
    spine = json.load(open(SPINE, encoding='utf-8'))
    anims = spine['animations']
    bonelist = {b['name']: b for b in spine['bones']}
    ref = {n: float(bonelist[n].get('rotation', 0.0)) for n in M}
    for bn, ts in anims['Swordwrath-Stand1'].get('bones', {}).items():
        r = ts.get('rotate', [])
        if bn in M and r:
            ref[bn] = float(r[0].get('angle', 0.0))

    def keys_of(sp, bn):
        bd = anims[sp].get('bones', {}).get(bn)
        rot = bd.get('rotate', []) if bd else []
        if not rot:
            return None  # 垫轨：期望常量 0
        out, prev = [], 0.0
        for k in rot:
            t = float(k.get('time', 0))
            a = float(k.get('angle', 0))
            if out:
                a = prev + math.fmod(a - prev + 180.0, 360.0) - 180.0
                if abs(a - prev) > 180.0:
                    a -= 360.0 if a > prev else -360.0
            out.append((t, a, expand_curve(k)))
            prev = a
        vals = [(t, ref[bn] - a, c) for t, a, c in out]
        sh = -round(vals[0][1] / 360.0) * 360.0
        return [(t, a + sh, c) for t, a, c in vals]

    def eval_at(keys, t):
        n = len(keys)
        if t <= keys[0][0]:
            return keys[0][1]
        if t >= keys[n - 1][0]:
            return keys[n - 1][1]
        i = 0
        while i + 1 < n and keys[i + 1][0] <= t:
            i += 1
        t0, v0, c = keys[i]
        t1, v1, _ = keys[i + 1]
        dt, dv = t1 - t0, v1 - v0
        if c is None:
            return v0 + dv * ((t - t0) / dt)
        if c == 'stepped':
            return v0
        u0 = (t - t0) / dt
        u = u0
        for _ in range(8):
            bx, dx = bez1(u, c[0], c[2]), bezd(u, c[0], c[2])
            if abs(dx) < 1e-6:
                break
            u -= (bx - u0) / dx
            u = max(0.0, min(1.0, u))
        return v0 + dv * bez1(u, c[1], c[3])

    rev = {path_of(bid): bn for bn, bid in M.items()}
    bad = tot = 0
    worst, worstinfo = 0.0, None
    for line in open(TSV, encoding='utf-8'):
        parts = line.rstrip('\n').split('\t')
        if len(parts) != 4:
            continue
        gd, p, t, v = parts[0], parts[1], float(parts[2]), float(parts[3])
        bn = rev.get(p[:-len(':rotation')])
        if bn is None:
            continue
        keys = keys_of(AM[gd], bn)
        exp = 0.0 if keys is None else math.radians(eval_at(keys, t))
        tot += 1
        d = abs(exp - v)
        if d > worst:
            worst, worstinfo = d, (gd, p, round(t, 3))
        if d > 1e-4:
            bad += 1
    print('样本 %d，超差(>1e-4 rad) %d，最大偏差 %.2e @ %s' % (tot, bad, worst, worstinfo))
    print('=== 端到端曲线保真通过 ===' if bad == 0 else '=== 有超差 ===')


if __name__ == '__main__':
    main()
