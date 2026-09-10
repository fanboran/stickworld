# -*- coding: utf-8 -*-
"""批次 C 数值链对账：Spine 真值（Godot 域）× Godot 逐骨世界位姿 RMS 验收。

输入两侧 dump JSON（tools/dump_spine_pose.py v2 与
stick-world/tools/baking/dump_rig_pose.gd，同域同构：Godot 域世界位姿、
Spine 原名 56 骨、帧键 3 位小数时刻），逐动画逐帧逐骨对比：

- 位置误差 = hypot(dx, dy)（世界像素）
- 角度误差 = wrap_to_180(a_spine - a_godot)（度）
- 判定口径（方案 §5.3 提案阈值）：**每动画每骨 RMS** ≤ 阈值（默认 0.5px / 0.5°）；
  max 同时报告不判定（定位尖峰用）

用法（仓库根）：
    python tools/verify_pose_rms.py --spine spine.json --godot godot.json
    python tools/verify_pose_rms.py --spine s.json --godot g.json --report report.json
全部通过退出码 0，否则 1（可接 CI）。
"""

import argparse
import json
import math
import sys


def load_dump(path):
    with open(path, encoding='utf-8') as f:
        d = json.load(f)
    for k in ('source', 'skeleton_height', 'anims'):
        if k not in d:
            raise SystemExit(f'错误: {path} 缺少字段 "{k}"，不是合法的 dump JSON')
    return d


def wrap180(a):
    return (a + 180.0) % 360.0 - 180.0


def frame_keys(frames):
    """帧键 → round3 数值键映射（浮点字符串两侧一致，round 仅防御）。"""
    return {round(float(k), 3): k for k in frames}


def main():
    ap = argparse.ArgumentParser(description='批次 C 逐动画逐骨位姿 RMS 对账')
    ap.add_argument('--spine', required=True, help='Spine 侧 dump JSON（dump_spine_pose.py v2）')
    ap.add_argument('--godot', required=True, help='Godot 侧 dump JSON（dump_rig_pose.gd）')
    ap.add_argument('--tol-pos', type=float, default=0.5, help='位置 RMS 阈值（px，默认 0.5）')
    ap.add_argument('--tol-angle', type=float, default=0.5, help='角度 RMS 阈值（度，默认 0.5）')
    ap.add_argument('--report', default='', help='汇总 JSON 输出路径（可选）')
    ap.add_argument('--top', type=int, default=15, help='明细输出条数（默认 15）')
    args = ap.parse_args()

    spine = load_dump(args.spine)
    godot = load_dump(args.godot)
    print(f'spine: {args.spine} (source={spine["source"]}, height={spine["skeleton_height"]})')
    print(f'godot: {args.godot} (source={godot["source"]}, height={godot["skeleton_height"]})')
    dh = abs(spine['skeleton_height'] - godot['skeleton_height'])
    print(f'骨架高差: {dh:.3f}px  阈值: pos_rms≤{args.tol_pos}px, angle_rms≤{args.tol_angle}°\n')
    if dh > 1.0:
        print('警告: 两侧 skeleton_height 差 >1px，先查两侧口径是否同域同锚')

    sa, ga = spine['anims'], godot['anims']
    only_s = sorted(set(sa) - set(ga))
    only_g = sorted(set(ga) - set(sa))
    if only_s:
        print(f'仅 spine 侧（跳过 {len(only_s)}）: {", ".join(only_s[:6])}...')
    if only_g:
        print(f'仅 godot 侧（跳过 {len(only_g)}）: {", ".join(only_g[:6])}...')
    common = sorted(set(sa) & set(ga))
    if not common:
        print('错误: 无共同动画')
        return 2

    # 全局累计与明细收集
    fails = []          # (动画, 骨, pos_rms, pos_max, ang_rms, ang_max)
    worst_frames = []   # (err_kind, 动画, 骨, t, err)
    total_pos2 = total_ang2 = total_n = 0
    all_ok = True

    for an in common:
        fs, fg = sa[an]['frames'], ga[an]['frames']
        ks, kg = frame_keys(fs), frame_keys(fg)
        ts = sorted(set(ks) & set(kg))
        if not ts:
            print(f'{an}  错误: 无共同帧  [FAIL]')
            all_ok = False
            continue
        miss_s, miss_g = len(ks) - len(ts), len(kg) - len(ts)

        acc = {}  # 骨 -> [Σpos², pos_max, Σang², ang_max]
        for t in ts:
            row_s, row_g = fs[ks[t]], fg[kg[t]]
            common_bones = set(row_s) & set(row_g)
            for bone in common_bones:
                a, b = row_s[bone], row_g[bone]
                dx, dy = a['x'] - b['x'], a['y'] - b['y']
                pe = math.hypot(dx, dy)
                ae = abs(wrap180(a['angle'] - b['angle']))
                st = acc.setdefault(bone, [0.0, 0.0, 0.0, 0.0])
                st[0] += pe * pe
                st[1] = max(st[1], pe)
                st[2] += ae * ae
                st[3] = max(st[3], ae)
                total_pos2 += pe * pe
                total_ang2 += ae * ae
                total_n += 1
                if pe > args.tol_pos * 3:
                    worst_frames.append(('pos', an, bone, t, pe))
                if ae > args.tol_angle * 3:
                    worst_frames.append(('angle', an, bone, t, ae))

        # 逐骨 RMS 判定
        bad = []
        anim_pos2 = anim_ang2 = 0.0
        for bone, (sp2, pmax, sa2, amax) in acc.items():
            n = len(ts)
            prms = math.sqrt(sp2 / n)
            arms = math.sqrt(sa2 / n)
            anim_pos2 += sp2
            anim_ang2 += sa2
            if prms > args.tol_pos or arms > args.tol_angle:
                bad.append((bone, prms, pmax, arms, amax))
        anim_n = len(ts) * len(acc)
        gprms = math.sqrt(anim_pos2 / anim_n) if anim_n else 0.0
        garms = math.sqrt(anim_ang2 / anim_n) if anim_n else 0.0
        ok = not bad
        all_ok = all_ok and ok
        flag = 'PASS' if ok else f'FAIL({len(bad)} 骨)'
        note = ''
        if miss_s or miss_g:
            note = f'  帧未对齐 spine-{miss_s}/godot-{miss_g}'
        print(f'{an:<28} 帧{len(ts):>3} 全骨rms p={gprms:.4f}px a={garms:.4f}°  {flag}{note}')
        for bone, prms, pmax, arms, amax in sorted(bad, key=lambda x: -max(x[1], x[3])):
            fails.append((an, bone, prms, pmax, arms, amax))
            print(f'    {bone:<22} pos_rms={prms:.4f} max={pmax:.4f}px   '
                  f'ang_rms={arms:.4f} max={amax:.4f}°')

    print()
    grms = math.sqrt(total_pos2 / total_n) if total_n else 0.0
    garms = math.sqrt(total_ang2 / total_n) if total_n else 0.0
    print(f'全局: {total_n} 骨·帧样本  pos_rms={grms:.5f}px  angle_rms={garms:.5f}°')

    if worst_frames:
        print(f'\n超 3× 阈值的尖峰帧（top {args.top}）:')
        rank = {'pos': 0, 'angle': 1}
        worst_frames.sort(key=lambda w: (-w[4], rank[w[0]]))
        for kind, an, bone, t, err in worst_frames[:args.top]:
            unit = 'px' if kind == 'pos' else '°'
            print(f'  [{kind}] {an} t={t:.3f} {bone}  err={err:.4f}{unit}')

    if fails:
        print(f'\n超阈骨×动画 {len(fails)} 项（判定口径 = 逐动画逐骨 RMS）：')
        fails.sort(key=lambda f: -max(f[2], f[4]))
        for an, bone, prms, pmax, arms, amax in fails[:args.top]:
            print(f'  {an} / {bone}: pos_rms={prms:.4f}px ang_rms={arms:.4f}°')
    print('\n总结: ' + ('全部 PASS' if all_ok else '存在 FAIL'))
    verdict = all_ok

    if args.report:
        rep = {
            'tol_pos': args.tol_pos, 'tol_angle': args.tol_angle,
            'samples': total_n,
            'global_pos_rms': grms, 'global_angle_rms': garms,
            'pass': verdict,
            'fails': [
                {'anim': an, 'bone': bone, 'pos_rms': prms, 'pos_max': pmax,
                 'angle_rms': arms, 'angle_max': amax}
                for an, bone, prms, pmax, arms, amax in fails
            ],
        }
        with open(args.report, 'w', encoding='utf-8') as f:
            json.dump(rep, f, ensure_ascii=False, indent=1)
        print(f'汇总已写出 {args.report}')
    return 0 if verdict else 1


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
