# -*- coding: utf-8 -*-
"""Spine 姿态基准导出器（任务 1a）。

从解包的 Spine 3.8 动画 JSON（external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt）
按固定 fps 采样每个动画，对全部骨骼求值世界位置 (x, y) 与世界角 angle（度），
输出与 Godot 侧 dump 工具完全一致的 JSON 格式，供 compare_pose.py 做翻译保真度对比。

【角度约定（重要，沿用 render_swl_ref.py 的 world()，未做任何翻转）】
- 绝对角 = 骨 setup rotation + 动画 rotate 通道增量（Spine 的 rotate 是增量语义）
- 位置合成用标准旋转矩阵：child = parent_pos + R(parent_angle) * (x, y)，
  即 x' = px + x*cos(a) - y*sin(a)，y' = py + x*sin(a) + y*cos(a)
- 本工具忠实输出数值，绝不翻转符号；符号关系由 compare_pose.py --mode discover 发现
- render_swl_ref.py 里 img.rotate(-ar) 的负号只是 PIL 显示层适配（PIL 逆时针为正），
  与本 dump 无关，dump 里不存在任何取负

【求值口径（与产线假设一致）】
- rotate 曲线**按 curve 字段求值**（linear / stepped / bezier 照产线
  spine_import._eval_keys 同一算法：stepped 保持到段末、bezier 用 Newton 迭代解
  归一化时间参数）。曲线必须参与，否则基准侧把产线的曲线直译当成线性近似，凭空
  造出"残差"（attack 族 39° 假残差即此，2026-10-11 实证）
- 仅 root 骨的 translate 曲线参与世界位置计算（会向子骨传播）；
  其余骨骼的 translate / 全部 scale / ik / slots 通道不参与求值（产线也没译）
- ⚠ 逐骨 translate **不导入产线**：本项目 rig 是重新手写的骨架（rest 偏移自成一套
  参数化，且肢体是建骨时一次成型的静态胶囊、胶囊端点钉在子骨 rest 偏移上），
  运行时改骨 position 只会让胶囊与关节脱开、剪影融成团（2026-10-11 实拍实证）。
  故两侧都只认 root 位移；不要试图把逐骨 translate「补齐」到任一侧
- Spine 3.8 关键帧常省略字段：rotate 键缺 "angle" 按 0，缺 "time" 按 0；
  空键 {} 合法（angle=0）。注意：t=0 时取【第一键的值】（Spine hold-first 语义），
  这与旧 render_swl_ref.py「跳过不带 angle 的键」的取法在首键为空键时会不同——
  本工具按 Spine 正确语义执行
- 输出角度/坐标均保留 3 位小数，单位：度 / Spine 逻辑像素

【skeleton_height 算法】
setup 姿态（无任何动画增量）下，对全部 33 根骨骼求世界 y，
skeleton_height = max(y) - min(y)。
Godot 侧工具必须用同一算法（setup 姿态全骨世界 y 极差），两侧才能互相换算尺度。

用法（在仓库根 F:/VSCode/game-2-aux 下运行）：
    python tools/dump_spine_pose.py --anims Swordwrath-Walk,Swordwrath-Run --fps 15 --out out.json
    python tools/dump_spine_pose.py --all --out all.json
"""

import argparse
import json
import math
import sys

# 默认骨架路径（相对仓库根；文件名带方括号，传参时注意加引号）
DEFAULT_SKELETON = 'external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt'
# 缺省导出的动画集（Swordwrath 基准四件套）
DEFAULT_ANIMS = 'Swordwrath-Stand1,Swordwrath-Walk,Swordwrath-Run,Swordwrath-Attack1'


def load_skeleton(path):
    """加载 Spine 3.8 JSON 骨架文件，返回原始 dict。"""
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def _read_curve(kf):
    """Spine 3.8.99 紧凑曲线格式 → None（线性）/ 'stepped' / (cx1,cy1,cx2,cy2)。

    与产线 spine_import._read_curve 同一读法：curve 为数值 f 时是贝塞尔首控制点
    cx1，其余控制点取伴生字段 c2(cy1，缺省 0)/c3(cx2，缺省 1)/c4(cy2，缺省 1)。
    curve 属于"该键到下一键"的段。
    """
    c = kf.get('curve')
    if c is None:
        return None
    if c == 'stepped':
        return 'stepped'
    if isinstance(c, list):
        return tuple(float(v) for v in c)
    return (float(c), float(kf.get('c2', 0.0)),
            float(kf.get('c3', 1.0)), float(kf.get('c4', 1.0)))


def _bez1(u, c1, c2):
    v = 1.0 - u
    return 3.0 * v * v * u * c1 + 3.0 * v * u * u * c2 + u * u * u


def _bez1d(u, c1, c2):
    v = 1.0 - u
    return 3.0 * v * v * c1 + 6.0 * v * u * (c2 - c1) + 3.0 * u * u * (1.0 - c2)


def _sample_linear(keys, t, field):
    """曲线感知采样单条曲线在 t 处的 field 值（linear / stepped / bezier）。

    与产线 spine_import._eval_keys 同一算法；曲线必须参与求值（见模块 docstring）。
    键缺 time 按 0、缺目标字段按 0（Spine 3.8 省略即缺省值）；
    t 早于首键 / 晚于末键 → hold 端点值。
    """
    if not keys:
        return 0.0
    tv = [(float(k.get('time', 0.0)), float(k.get(field, 0.0)), _read_curve(k)) for k in keys]
    if t <= tv[0][0]:
        return tv[0][1]
    if t >= tv[-1][0]:
        return tv[-1][1]
    for i in range(len(tv) - 1):
        t0, v0, curve = tv[i]
        t1, v1, _ = tv[i + 1]
        if t0 <= t <= t1:
            if t1 <= t0:
                return v1
            dt = t1 - t0
            if curve is None:
                return v0 + (v1 - v0) * ((t - t0) / dt)
            if curve == 'stepped':
                return v0
            target = (t - t0) / dt
            u = target
            for _it in range(8):
                bx = _bez1(u, curve[0], curve[2])
                dx = _bez1d(u, curve[0], curve[2])
                if abs(dx) < 1e-6:
                    break
                u = min(1.0, max(0.0, u - (bx - target) / dx))
            return v0 + (v1 - v0) * _bez1(u, curve[1], curve[3])
    return tv[-1][1]


def anim_duration(anim_data):
    """动画时长 = bones + slots 所有通道最后一个键的最大 time。"""
    mt = 0.0
    for section in ('bones', 'slots'):
        for _name, ch in anim_data.get(section, {}).items():
            for _cname, keys in ch.items():
                if isinstance(keys, list) and keys:
                    mt = max(mt, float(keys[-1].get('time', 0.0)))
    return mt


def unwrap_rotate(keys):
    """对单条 rotate 曲线做"最短角差"解缠绕，与产线 spine_import._unwrap_rotate 同算法。

    Spine 原始角度可含 >360° 螺旋值（如 -325.75 表示 34.25），直接线性插值会绕整圈；
    产线转换时逐键归一到最短角差路径，基准侧必须同款处理，否则两侧插值路径不同
    产生虚假残差。注意用 math.fmod（符号随被除数）对齐 GDScript fmod 语义。
    首键原样保留（与产线一致）。曲线字段原样带过（采样时才解释）。
    """
    out = []
    prev = 0.0
    for k in keys:
        t = float(k.get('time', 0.0))
        a = float(k.get('angle', 0.0))
        if out:
            a = prev + math.fmod(a - prev + 180.0, 360.0) - 180.0
            if abs(a - prev) > 180.0:
                a -= 360.0 if a > prev else -360.0
        rec = dict(k)
        rec['time'] = t
        rec['angle'] = a
        out.append(rec)
        prev = a
    return out


def preprocess_unwrap(anim_data):
    """返回 anim_data 的浅拷贝副本，其中每骨 rotate 曲线已解缠绕。"""
    import copy
    dup = copy.deepcopy(anim_data)
    for _name, ch in dup.get('bones', {}).items():
        if isinstance(ch.get('rotate'), list) and ch['rotate']:
            ch['rotate'] = unwrap_rotate(ch['rotate'])
    return dup


def eval_pose(bones, anim_data, t):
    """对动画 anim_data 在时间 t 求值，返回 {骨名: (x, y, angle_world_deg)}。

    - bones：Spine JSON 的 bones 数组（已保证父骨先于子骨出现，按数组序迭代即可）
    - 世界角 = 链上各骨局部角之和；局部角 = setup rotation + rotate(t)（线性插值增量）。
      与 Godot 侧 dump 的 global_transform.rotation 同语义，可直接对比
    - root 世界位置 = setup(x, y) + translate(t)；该偏移随父子链传播到全部子骨
    - 其余骨骼位置 = 父世界位置 + R(父角) * setup(x, y)（不用动画 translate，产线口径）
    """
    rotate = anim_data.get('bones', {})
    root_ch = rotate.get('root', {})
    root_tx = _sample_linear(root_ch.get('translate', []), t, 'x')
    root_ty = _sample_linear(root_ch.get('translate', []), t, 'y')

    world = {}  # 骨名 -> (x, y, 世界角)
    for b in bones:
        name = b['name']
        parent = b.get('parent')
        # 局部绝对角 = setup rotation + 动画 rotate 增量（约定见模块 docstring，无任何翻转）
        a_local = float(b.get('rotation', 0.0)) + _sample_linear(
            rotate.get(name, {}).get('rotate', []), t, 'angle')
        x = float(b.get('x', 0.0))
        y = float(b.get('y', 0.0))
        if parent is None:
            # root：setup 位置 + 动画 translate 增量
            wx, wy = x + root_tx, y + root_ty
            a_world = a_local
        else:
            px, py, pa = world[parent]
            pr = math.radians(pa)
            wx = px + x * math.cos(pr) - y * math.sin(pr)
            wy = py + x * math.sin(pr) + y * math.cos(pr)
            a_world = pa + a_local
        world[name] = (wx, wy, a_world)
    return world


def skeleton_height(bones):
    """参考总高：setup 姿态下全部骨骼世界 y 的 (max - min)。

    算法说明见模块 docstring；Godot 侧 dump 工具须用同一算法。
    """
    world = eval_pose(bones, {}, 0.0)
    ys = [v[1] for v in world.values()]
    return max(ys) - min(ys)


def count_nonlinear_tracks(anim_data):
    """统计该动画里带非 linear curve 字段的轨道数。

    轨道 = (骨, 通道)。curve 字段为 'stepped' 或 bezier 控制点都算非 linear；
    缺 curve 字段 = linear。求值时它们都被当 linear 处理（产线假设），仅作统计。
    """
    total = 0
    nonlin = 0
    stepped = 0
    bezier = 0
    for _bn, ch in anim_data.get('bones', {}).items():
        for _cname, keys in ch.items():
            if not (isinstance(keys, list) and keys):
                continue
            total += 1
            if any('curve' in k for k in keys):
                nonlin += 1
                if any(k.get('curve') == 'stepped' for k in keys):
                    stepped += 1
                else:
                    bezier += 1
    return total, nonlin, stepped, bezier


def sample_times(duration, fps):
    """在 [0, duration] 上按 fps 均匀采样，返回时刻列表。"""
    n = int(round(duration * fps))
    return [min(i / fps, duration) for i in range(n + 1)]


def dump_anim(bones, anim_data, fps):
    """导出单个动画：返回 {duration, frames}。frames 键为三位小数时刻字符串。"""
    duration = anim_duration(anim_data)
    frames = {}
    for t in sample_times(duration, fps):
        pose = eval_pose(bones, anim_data, t)
        key = f'{t:.3f}'
        frames[key] = {
            name: {'x': round(p[0], 3), 'y': round(p[1], 3), 'angle': round(p[2], 3)}
            for name, p in pose.items()
        }
    return {'duration': round(duration, 4), 'frames': frames}


def main():
    ap = argparse.ArgumentParser(description='Spine 姿态基准导出器（姿态验收链 1a）')
    ap.add_argument('--anims', default=DEFAULT_ANIMS,
                    help=f'逗号分隔的动画名列表（缺省: {DEFAULT_ANIMS}）')
    ap.add_argument('--fps', type=float, default=15.0, help='采样密度（默认 15）')
    ap.add_argument('--out', default='out.json', help='输出 JSON 路径（默认 out.json）')
    ap.add_argument('--all', action='store_true', help='导出全部动画（覆盖 --anims）')
    ap.add_argument('--skeleton', default=DEFAULT_SKELETON,
                    help='Spine 骨架 JSON 路径（文件名带方括号时注意整体加引号）')
    args = ap.parse_args()

    d = load_skeleton(args.skeleton)
    bones = d['bones']
    anims = d['animations']

    names = sorted(anims.keys()) if args.all else [
        s.strip() for s in args.anims.split(',') if s.strip()]
    missing = [n for n in names if n not in anims]
    if missing:
        print('错误：动画不存在:', ', '.join(missing))
        print('可用动画示例:', ', '.join(sorted(anims.keys())[:10]), '...')
        return 2

    height = skeleton_height(bones)
    out = {'source': 'spine', 'skeleton_height': round(height, 3), 'anims': {}}

    print(f'骨架: {args.skeleton}')
    print(f'skeleton_height = {height:.3f}（setup 姿态全骨世界 y 极差，{len(bones)} 根骨）')
    print(f'fps={args.fps}  动画数={len(names)}')

    # 非 linear curve 轨道统计（求值仍按 linear，仅提示产线假设的近似程度）
    tot_all = non_all = 0
    for n in names:
        total, nonlin, stepped, bezier = count_nonlinear_tracks(anims[n])
        tot_all += total
        non_all += nonlin
        print(f'  {n}: 时长={anim_duration(anims[n]):.4f}s 轨道={total} '
              f'非linear curve={nonlin}（stepped={stepped}, bezier={bezier}）')
    print(f'合计: 轨道={tot_all}  非linear={non_all}（{100.0 * non_all / max(1, tot_all):.1f}%）'
          f' —— 这些轨道本工具一律按线性插值求值')

    for n in names:
        out['anims'][n] = dump_anim(bones, preprocess_unwrap(anims[n]), args.fps)
        print(f'  导出 {n}: {len(out["anims"][n]["frames"])} 帧')

    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print(f'已写出 {args.out}（{len(out["anims"])} 个动画）')
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
