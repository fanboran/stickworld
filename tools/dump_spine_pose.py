# -*- coding: utf-8 -*-
"""Spine 姿态基准导出器 v2（批次 C 数值链真值侧）。

从解包的 Spine 3.8 骨架 JSON（external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt）
按固定 fps 采样每个动画，对全部骨骼求值 **Godot 域**的世界位姿 (x, y, angle°)，
与 Godot 侧 `stick-world/tools/baking/dump_rig_pose.gd` 的输出同域同构，
供 verify_pose_rms.py 做逐动画逐骨 RMS 对账（方案 §5.3 数值链）。

【求值口径 = 逐字复刻 spine_importer.py 写入 .tres 的数学】
- rotate：解缠绕（最短角差路径）后，轨道值 = -(setup_rot + delta) 转弧度；
  bezier/stepped/linear 三种段精确求值（bezier 在 Spine 归一化控制点域解
  x(u)=α 得 y(u)，与 Godot 域 handle 换算数学等价，残差浮点噪声级）
- translate：x = setup_x + tx、y = -(setup_y + ty)；root 骨丢弃 tx（防漂移，
  同导入器默认 --root-tx drop 口径），只保留 y
- scale：值 = setup_s * 倍率
- 曲线字段：Spine 4.x 字段风格（curve=x1、c2=y1、c3=x2、c4=y2，缺省 0/1）

【Godot 域世界合成】
- 虚拟根 `RigRoot`：position=(4, 183.02)（= SpineRenderData.RIG_ANCHOR）、
  rot=0、scale=1，全部 56 骨挂其下——与 StickmanSkeleton.build_from_scratch
  同构（锚点把髋骨 bone 对到 rig 原点）。
- 每骨局部变换 = T(position) · R(rotation) · S(scale)（Godot Node2D 语义），
  global = parent_global · local；RigRoot 本身不进输出。
- 输出 angle = rad_to_deg(atan2(x_axis.y, x_axis.x))——Godot
  Transform2D.get_rotation() 在 basis=R·S、sx>0 时的精确值。
- skeleton_height = setup 姿态全骨全局 y 极差（Godot 域，含 RigRoot 平移），
  与 Godot 侧 _measure_height 同口径。

用法（在仓库根或 worktree 根运行；真相源不在时自动回退主 checkout）：
    python tools/dump_spine_pose.py --anims Swordwrath-Walk,Swordwrath-Run --fps 15 --out out.json
    python tools/dump_spine_pose.py --all --fps 15 --out all.json
"""

import argparse
import json
import math
import os
import sys

# 默认骨架路径（相对仓库根；文件名带方括号，传参时注意加引号）
DEFAULT_SKELETON = 'external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt'

# RigRoot 锚点（Godot 局部系 y-down），= spine_render_data.gd 的 RIG_ANCHOR。
# 两处必须同步修改：改锚点不改这里，对账残差会整体平移髋部。
RIG_ANCHOR = (4.0, 183.02)

# bezier 求值二分次数：60 次 → 区间宽 2^-60，远超 f64 精度需求
_BEZIER_BISECT = 60


def load_skeleton(path):
    """加载 Spine 3.8 JSON 骨架文件，返回原始 dict。"""
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def resolve_skeleton(path_arg):
    """真相源路径解析：worktree 里没有 external/ 时回退主 checkout（同导入器）。"""
    if os.path.isabs(path_arg):
        return path_arg
    roots = [os.getcwd(), os.path.abspath(os.path.join(os.getcwd(), '..', '..'))]
    for root in roots:
        cand = os.path.join(root, path_arg)
        if os.path.exists(cand):
            return cand
    raise FileNotFoundError('真相源不存在（当前目录与主 checkout 都试过）: %s' % path_arg)


# ============================================================
#  曲线段解析与求值（与 spine_importer.seg_curve / bezier_points 同口径）
# ============================================================

def seg_curve(key):
    """键的出段曲线：'stepped' | 'linear' | (x1, y1, x2, y2) 归一化控制点。"""
    cv = key.get('curve')
    if cv == 'stepped':
        return 'stepped'
    if cv is None:
        return 'linear'
    if isinstance(cv, (int, float)):
        return (float(cv), float(key.get('c2', 0.0)),
                float(key.get('c3', 1.0)), float(key.get('c4', 1.0)))
    if isinstance(cv, list):  # 兼容标准 4 数组写法（本数据未出现，防御）
        return tuple(float(x) for x in (cv + [0, 0, 1, 1])[:4])
    raise ValueError('未知 curve 字段: %r' % (cv,))


def unwrap_rotate(keys):
    """rotate 键序列解缠绕（最短角差路径），首键原样保留（同导入器）。"""
    out = []
    prev = 0.0
    for k in keys:
        t = float(k.get('time', 0.0))
        a = float(k.get('angle', 0.0))
        if out:
            a = prev + math.fmod(a - prev + 180.0, 360.0) - 180.0
            if abs(a - prev) > 180.0:
                a -= 360.0 if a > prev else -360.0
        out.append((t, a))
        prev = a
    return out


def timeline_keys(keys, value_of):
    """键序列规整：[(time, value, seg)]，按时间排序、同时间取后键（Spine 语义）。"""
    rows = [(float(k.get('time', 0.0)), value_of(k), seg_curve(k)) for k in keys]
    rows.sort(key=lambda r: r[0])
    out = []
    for r in rows:
        if out and out[-1][0] == r[0]:
            out[-1] = r
        else:
            out.append(r)
    return out


def _bezier_y(x1, y1, x2, y2, alpha):
    """Spine 归一化 bezier 段求值：解 x(u)=alpha 得 y(u)（二分，段内单调时精确）。

    x(u) = 3(1-u)²u·x1 + 3(1-u)u²·x2 + u³，y 同理。控制点 x 乱序/越界时
    二分给确定值（Godot 引擎同为数值求解，此类键共 28 个已登记容许）。
    """
    if alpha <= 0.0:
        return 0.0
    if alpha >= 1.0:
        return 1.0
    lo, hi = 0.0, 1.0
    for _ in range(_BEZIER_BISECT):
        u = (lo + hi) * 0.5
        v = 1.0 - u
        xu = 3.0 * v * v * u * x1 + 3.0 * v * u * u * x2 + u * u * u
        if xu < alpha:
            lo = u
        else:
            hi = u
    u = (lo + hi) * 0.5
    v = 1.0 - u
    return 3.0 * v * v * u * y1 + 3.0 * v * u * u * y2 + u * u * u


def eval_track(rows, t):
    """单条规整轨道在时刻 t 的值（Godot 域值已换算进 rows）。"""
    if t <= rows[0][0]:
        return rows[0][1]
    if t >= rows[-1][0]:
        return rows[-1][1]
    for i in range(len(rows) - 1):
        t0, v0, seg = rows[i]
        t1, v1, _ = rows[i + 1]
        if t0 <= t <= t1:
            if t1 <= t0:
                return v1
            if seg == 'stepped':
                return v0
            alpha = (t - t0) / (t1 - t0)
            if seg == 'linear':
                return v0 + (v1 - v0) * alpha
            x1, y1, x2, y2 = seg
            return v0 + (v1 - v0) * _bezier_y(x1, y1, x2, y2, alpha)
    return rows[-1][1]


# ============================================================
#  动画 → Godot 域逐骨通道轨道
# ============================================================

def build_tracks(anim_data, bones_by_name):
    """动画 → {骨名: {'rot': rows|None, 'px': rows|None, 'py': rows|None,
    'sx': rows|None, 'sy': rows|None}}。

    轨道值已换算到 Godot 域（弧度 / Godot 像素 / 倍率），无轨道 = None
    （求值端回退 setup 值）。root 骨丢弃 translate x（同导入器 drop 口径）。
    """
    tracks = {}
    for bone_name, chans in anim_data.get('bones', {}).items():
        setup = bones_by_name.get(bone_name)
        if setup is None:
            raise ValueError('动画引用未知骨骼 %s' % bone_name)
        setup_rot = float(setup.get('rotation', 0.0))
        setup_x = float(setup.get('x', 0.0))
        setup_y = float(setup.get('y', 0.0))
        setup_sx = float(setup.get('scaleX', 1.0))
        setup_sy = float(setup.get('scaleY', 1.0))

        tr = {'rot': None, 'px': None, 'py': None, 'sx': None, 'sy': None}
        for ch_name, raw_keys in chans.items():
            if not (isinstance(raw_keys, list) and raw_keys):
                continue
            if ch_name == 'rotate':
                unwrapped = unwrap_rotate(raw_keys)
                tr['rot'] = [(t, -math.radians(setup_rot + a), seg_curve(k))
                             for (t, a), k in zip(unwrapped, raw_keys)]
            elif ch_name == 'translate':
                if bone_name == 'root':
                    tr['py'] = timeline_keys(
                        [{'time': k.get('time', 0.0), 'y': k.get('y', 0.0),
                          'curve': k.get('curve'), 'c2': k.get('c2'),
                          'c3': k.get('c3'), 'c4': k.get('c4')} for k in raw_keys],
                        lambda k: -(setup_y + float(k.get('y', 0.0))))
                else:
                    tr['px'] = timeline_keys(raw_keys, lambda k: setup_x + float(k.get('x', 0.0)))
                    tr['py'] = timeline_keys(raw_keys, lambda k: -(setup_y + float(k.get('y', 0.0))))
            elif ch_name == 'scale':
                tr['sx'] = timeline_keys(raw_keys, lambda k: setup_sx * float(k.get('x', 1.0)))
                tr['sy'] = timeline_keys(raw_keys, lambda k: setup_sy * float(k.get('y', 1.0)))
            # shear：Godot 无 shear，已弃用登记（不影响位姿对账口径）——同导入器
        tracks[bone_name] = tr
    return tracks


def _max_time(node, mt):
    """递归扫最大 time（同导入器 anim_duration，含 deform/drawOrder 段）。"""
    if isinstance(node, list):
        for it in node:
            mt = _max_time(it, mt)
    elif isinstance(node, dict):
        if 'time' in node:
            mt = max(mt, float(node['time']))
        for v in node.values():
            mt = _max_time(v, mt)
    return mt


def anim_duration(anim_data):
    sections = {k: anim_data[k] for k in ('bones', 'slots', 'deform', 'drawOrder')
                if k in anim_data}
    return _max_time(sections, 0.0)


# ============================================================
#  Godot 域世界合成
# ============================================================

def topo_order(bones):
    """父骨先于子骨的迭代序（Spine JSON 保证数组序即拓扑序，防御性再排）。

    bones: Spine JSON 的 bones 数组（或任意可按 name 迭代的骨 dict 集合）。
    """
    by_name = {b['name']: b for b in bones}
    order, seen = [], set()

    def visit(name):
        if name in seen:
            return
        seen.add(name)
        p = by_name[name].get('parent')
        if p and p in by_name:
            visit(p)
        order.append(name)

    for b in bones:
        visit(b['name'])
    return order


def eval_channels(tracks, order, bones_by_name, t):
    """时刻 t 全骨通道值（Godot 域）：{骨: (x, y, rot_rad, sx, sy)}。"""
    out = {}
    for name in order:
        tr = tracks.get(name)
        d = bones_by_name[name]
        if tr is None:
            out[name] = (float(d.get('x', 0.0)), -float(d.get('y', 0.0)),
                         -math.radians(float(d.get('rotation', 0.0))),
                         float(d.get('scaleX', 1.0)), float(d.get('scaleY', 1.0)))
        else:
            rot = tr['rot'][0][1] if tr['rot'] is None else eval_track(tr['rot'], t)
            if tr['px'] is None:
                px = float(d.get('x', 0.0))
                py = -float(d.get('y', 0.0)) if tr['py'] is None else eval_track(tr['py'], t)
            else:
                px = eval_track(tr['px'], t)
                py = eval_track(tr['py'], t)
            sx = eval_track(tr['sx'], t) if tr['sx'] is not None else float(d.get('scaleX', 1.0))
            sy = eval_track(tr['sy'], t) if tr['sy'] is not None else float(d.get('scaleY', 1.0))
            out[name] = (px, py, rot, sx, sy)
    return out


def compose_world(channels, order, bones_by_name):
    """Godot 域仿射合成（T·R·S），返回 {骨: (gx, gy, angle_deg)}；RigRoot 不输出。

    每骨世界变换 = 父骨世界变换 · 本骨局部变换（拓扑序保证父先算完；
    无父/父不在表中的骨直接挂虚拟根 RigRoot）。basis 用列主序 6 元组存储。
    """
    # basis 列主序 [a c / b d]：columns[0]=(a,b) x_axis、columns[1]=(c,d) y_axis
    IDENTITY = (1.0, 0.0, 0.0, 1.0)
    xf = {}  # 骨名 -> (a, b, c, d, tx, ty)
    xf[''] = IDENTITY + RIG_ANCHOR  # 虚拟根：identity basis + RIG_ANCHOR 平移
    for name in order:
        parent = str(bones_by_name[name].get('parent', ''))
        pa, pb_, pc, pd, ptx, pty = xf[parent] if parent in xf else xf['']
        lx, ly, rot, sx, sy = channels[name]
        c, s = math.cos(rot), math.sin(rot)
        # 本骨局部 basis = R·S：columns[0]=(sx·cos, sx·sin)、columns[1]=(-sy·sin, sy·cos)
        la, lb_, lc, ld = c * sx, s * sx, -s * sy, c * sy
        ga = pa * la + pc * lb_
        gb = pb_ * la + pd * lb_
        gc = pa * lc + pc * ld
        gd = pb_ * lc + pd * ld
        gx = pa * lx + pc * ly + ptx
        gy = pb_ * lx + pd * ly + pty
        xf[name] = (ga, gb, gc, gd, gx, gy)
    out = {}
    for name in order:
        ga, gb, gc, gd, gx, gy = xf[name]
        # Godot get_rotation()：basis=R·S 且 sx>0 时 = atan2(x_axis.y, x_axis.x)；
        # det<0（负 scale 镜像）时 Godot 把 x 轴翻负再提取
        if ga * gd - gb * gc < 0.0:
            angle = math.degrees(math.atan2(-gb, -ga))
        else:
            angle = math.degrees(math.atan2(gb, ga))
        out[name] = (gx, gy, angle)
    return out


def skeleton_height(bones_by_name, order):
    """setup 姿态全骨全局 y 极差（Godot 域，含 RigRoot 平移）。"""
    channels = eval_channels({}, order, bones_by_name, 0.0)
    world = compose_world(channels, order, bones_by_name)
    ys = [v[1] for v in world.values()]
    return max(ys) - min(ys)


# ============================================================
#  采样导出
# ============================================================

def sample_times(duration, fps):
    """在 [0, duration] 上按 fps 均匀采样（n = round 半升，同 GDScript roundi）。"""
    n = int(duration * fps + 0.5)
    return [min(i / fps, duration) for i in range(n + 1)]


def dump_anim(bones_by_name, order, tracks, duration, fps):
    frames = {}
    for t in sample_times(duration, fps):
        channels = eval_channels(tracks, order, bones_by_name, t)
        world = compose_world(channels, order, bones_by_name)
        key = '%.3f' % t
        frames[key] = {
            name: {'x': round(p[0], 3), 'y': round(p[1], 3), 'angle': round(p[2], 3)}
            for name, p in world.items()
        }
    return {'duration': round(duration, 4), 'frames': frames}


def main():
    ap = argparse.ArgumentParser(description='Spine 姿态基准导出器 v2（Godot 域，批次 C 数值链）')
    ap.add_argument('--anims', default='Swordwrath-Stand1',
                    help='逗号分隔的动画名列表')
    ap.add_argument('--fps', type=float, default=15.0, help='采样密度（默认 15）')
    ap.add_argument('--out', default='out.json', help='输出 JSON 路径')
    ap.add_argument('--all', action='store_true', help='导出全部动画（覆盖 --anims）')
    ap.add_argument('--skeleton', default=DEFAULT_SKELETON,
                    help='Spine 骨架 JSON 路径（相对路径自动回退主 checkout）')
    args = ap.parse_args()

    path = resolve_skeleton(args.skeleton)
    d = load_skeleton(path)
    bones = d['bones']
    anims = d['animations']
    bones_by_name = {b['name']: b for b in bones}
    order = topo_order(bones)

    names = sorted(anims.keys()) if args.all else [
        s.strip() for s in args.anims.split(',') if s.strip()]
    missing = [n for n in names if n not in anims]
    if missing:
        print('错误：动画不存在:', ', '.join(missing))
        return 2

    height = skeleton_height(bones_by_name, order)
    out = {'source': 'spine-godot-domain', 'skeleton_height': round(height, 3), 'anims': {}}

    print(f'骨架: {path}')
    print(f'skeleton_height = {height:.3f}（Godot 域 setup 全骨 y 极差，{len(bones)} 根骨）')
    print(f'fps={args.fps}  动画数={len(names)}')

    for n in names:
        anim = anims[n]
        tracks = build_tracks(anim, bones_by_name)
        duration = anim_duration(anim)
        out['anims'][n] = dump_anim(bones_by_name, order, tracks, duration, args.fps)
        print(f'  导出 {n}: duration={duration:.4f}s, {len(out["anims"][n]["frames"])} 帧')

    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print(f'已写出 {args.out}（{len(out["anims"])} 个动画）')
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
