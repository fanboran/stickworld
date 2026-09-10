# -*- coding: utf-8 -*-
"""真实 Spine 骨架的骨骼线渲染器（几何基准用，与贴图无关）。

复用 dump_spine_pose v2 的求值口径（Godot 域世界位姿：RigRoot 锚点 + 全通道
精确曲线），把每根骨画成"原点→沿骨 x 轴 length 长度的线段"+关节圆，用于：
- 看 SWL 真实 setup / 任意动画任意时刻的骨架姿态（几何基准）
- 与游戏内渲染截图并排对比（批次 B/D 验收链）

输出域 = Godot 域（y-down，与游戏内一致），与 relax 场景截图可直接目测对齐。

用法（仓库根）：
    py tools/render_spine_bones.py --pose setup --out out.png
    py tools/render_spine_bones.py --pose anim --anim Swordwrath-Stand1 --time 0 --out out.png
    py tools/render_spine_bones.py --pose anim --anim Swordwrath-Walk --time 0.4 --out walk.png
"""
import argparse
import math
import os
import sys

from PIL import Image, ImageDraw

from dump_spine_pose import (DEFAULT_SKELETON, anim_duration, build_tracks,
                             compose_world, eval_channels, load_skeleton,
                             resolve_skeleton, topo_order)

BG = (70, 70, 70)
BONE = (235, 235, 240)
JOINT = (255, 170, 60)


def draw_bones(bones_data, pose, out, scale, size):
    """pose: {name: (x, y, angle_deg)}，Godot 域 y-down；屏幕直接同向画。"""
    img = Image.new('RGB', size, BG)
    dr = ImageDraw.Draw(img)
    cx, cy = size[0] / 2.0, size[1] / 2.0

    def pt(x, y):
        return (cx + x * scale, cy + y * scale)

    # Spine JSON 原始骨长字段 = length（导入器表 BONES 才是 len）
    lengths = {b['name']: float(b.get('length', 0) or 0) for b in bones_data}
    for name, (x, y, a) in pose.items():
        ln = lengths.get(name, 0.0)
        p0 = pt(x, y)
        dr.ellipse([p0[0] - 3, p0[1] - 3, p0[0] + 3, p0[1] + 3], fill=JOINT)
        if ln <= 0:
            continue
        r = math.radians(a)
        p1 = pt(x + math.cos(r) * ln, y + math.sin(r) * ln)
        dr.line([p0, p1], fill=BONE, width=4)
    img.save(out)
    ys = [p[1] for p in pose.values()]
    print(f'SAVED {out}  (Godot域y范围 {min(ys):.1f}~{max(ys):.1f}, 高度极差 {max(ys)-min(ys):.1f})')


def main() -> int:
    ap = argparse.ArgumentParser(description='Spine 骨架骨骼线渲染器（Godot 域）')
    ap.add_argument('--pose', choices=['setup', 'anim'], default='setup')
    ap.add_argument('--anim', default='Swordwrath-Stand1')
    ap.add_argument('--time', type=float, default=0.0)
    ap.add_argument('--skeleton', default=DEFAULT_SKELETON)
    ap.add_argument('--out', default='.tmp_ref_render/spine_bones.png')
    ap.add_argument('--scale', type=float, default=1.6)
    args = ap.parse_args()

    path = resolve_skeleton(args.skeleton)
    d = load_skeleton(path)
    bones = d['bones']
    bones_by_name = {b['name']: b for b in bones}
    order = topo_order(bones)
    if args.pose == 'setup':
        channels = eval_channels({}, order, bones_by_name, 0.0)
    else:
        tracks = build_tracks(d['animations'][args.anim], bones_by_name)
        channels = eval_channels(tracks, order, bones_by_name, args.time)
    pose = compose_world(channels, order, bones_by_name)
    draw_bones(bones, pose, args.out, args.scale, (1100, 1100))
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
