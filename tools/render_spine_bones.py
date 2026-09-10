# -*- coding: utf-8 -*-
"""真实 Spine 骨架的骨骼线渲染器（几何基准用，与贴图无关）。

复用 dump_spine_pose 的求值口径（setup rotation + rotate 增量、世界角链式累加），
把每根骨画成"原点→沿骨 x 轴 length 长度的线段"+关节圆，用于：
- 看 SWL 真实 setup / Stand1 姿态长什么样（几何基准）
- 与本项目 SKELETON_DATA 重建结果并排对比

用法（仓库根）：
    py tools/render_spine_bones.py --pose setup --out out.png
    py tools/render_spine_bones.py --pose anim --anim Swordwrath-Stand1 --time 0 --out out.png
    py tools/render_spine_bones.py --pose anim --anim Swordwrath-Walk --time 0.4 --out walk.png
"""
import argparse
import math
import sys

from PIL import Image, ImageDraw

from dump_spine_pose import (DEFAULT_SKELETON, eval_pose, load_skeleton,
                             preprocess_unwrap)

BG = (70, 70, 70)
BONE = (235, 235, 240)
JOINT = (255, 170, 60)


def draw_bones(bones_data, pose, out, scale, size, flip_y=True):
    """pose: {name: (x, y, angle_deg)}，Spine y-up；画面时翻 y（屏幕 y-down）。"""
    img = Image.new('RGB', size, BG)
    dr = ImageDraw.Draw(img)
    cx, cy = size[0] / 2.0, size[1] / 2.0

    def pt(x, y):
        return (cx + x * scale, cy - (y * scale if flip_y else -y * scale))

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
    print(f'SAVED {out}  (spine世界y范围 {min(ys):.1f}~{max(ys):.1f}, 高度极差 {max(ys)-min(ys):.1f})')


def main() -> int:
    ap = argparse.ArgumentParser(description='Spine 骨架骨骼线渲染器')
    ap.add_argument('--pose', choices=['setup', 'anim'], default='setup')
    ap.add_argument('--anim', default='Swordwrath-Stand1')
    ap.add_argument('--time', type=float, default=0.0)
    ap.add_argument('--skeleton', default=DEFAULT_SKELETON)
    ap.add_argument('--out', default='.tmp_ref_render/spine_bones.png')
    ap.add_argument('--scale', type=float, default=1.6)
    args = ap.parse_args()

    d = load_skeleton(args.skeleton)
    bones = d['bones']
    if args.pose == 'setup':
        pose = {b['name']: (float(b.get('x', 0)), float(b.get('y', 0)),
                            float(b.get('rotation', 0))) for b in bones}
    else:
        pose = eval_pose(bones, preprocess_unwrap(d['animations'][args.anim]), args.time)
    draw_bones(bones, pose, args.out, args.scale, (1100, 1100))
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
