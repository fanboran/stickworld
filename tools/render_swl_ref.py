import json, io, sys, math, argparse
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
from PIL import Image, ImageDraw
# 复用姿态验收链 1a 的时间插值求值（与 dump_spine_pose.py 口径完全一致）
from dump_spine_pose import _sample_linear, eval_pose, preprocess_unwrap, load_skeleton, DEFAULT_SKELETON

# ---- 参数化（任务 1c）：无参数运行保持原默认行为（Stand1 t=0 full 输出） ----
ap = argparse.ArgumentParser(description='PIL 单姿势参考渲染器（可用 --time 取任意时刻姿态）')
ap.add_argument('--anim', default='Swordwrath-Stand1', help='动画名（默认 Swordwrath-Stand1）')
ap.add_argument('--time', type=float, default=0.0,
                help='采样时刻秒（默认 0；rotate/translate 线性插值，替代旧的「首关键帧」取值）')
ap.add_argument('--out', default='stick-world/tools/baking/ref_swl_pose.png', help='输出 PNG 路径')
ap.add_argument('--focus', choices=['sword', 'hand', 'full'], default='full',
                help='sword=只画 weapon 槽附件与手骨聚焦渲染; hand=手骨链+武器; full=全身(原行为)')
args = ap.parse_args()

d = load_skeleton(DEFAULT_SKELETON)
bones = {b['name']: b for b in d['bones']}
atlas = open('external/decompiled/legacy/spine_raw/核心单位骨架/[universal.atlas].txt', encoding='utf-8').read()
lines = atlas.split('\n')
regions = {}
for i, l in enumerate(lines):
    name = l.strip()
    if name and ':' not in name and i+3 < len(lines):
        try:
            xy = lines[i+2].split(':')[1].split(',')
            sz = lines[i+3].split(':')[1].split(',')
            regions[name] = (int(xy[0]), int(xy[1]), int(sz[0]), int(sz[1]))
        except Exception:
            pass
atlas_img = Image.open('external/decompiled/legacy/textures/universal.png' if False else 'external/decompiled/legacy/spine_raw/textures/universal.png').convert('RGBA')

# 动画姿态：复用 dump_spine_pose.eval_pose（世界角=链上累加，忠实口径）。
# 【历史教训】旧版本文件自带 world() 把「局部角」当世界角返回（pickaxe1 返回 84.97，
# 真世界角 42.68），导致附件朝向错 ~43°、旧武器 tscn 推导链被"循环验证"。
# 现统一走 dump 口径：绝对角 = setup rotation + 动画增量，世界角 = 父世界角 + 局部角。
anim_data = preprocess_unwrap(d['animations'][args.anim])
pose = eval_pose(d['bones'], anim_data, args.time)

def world(bn):
    x, y, a = pose[bn]
    return (x, y, a)

sk_name = args.anim.split('-')[0]
skins = {s['name']: s for s in d['skins']}
skin = skins.get(sk_name, skins['default'])
print('skin =', skin['name'])

# ---- 先收集绘制元素（世界坐标，Spine y-up），再统一取景绘制 ----
# 元素: ('seg', p1, p2, thick, color) | ('att', img, center, angle_screen, dw, dh, slot, name)
#       | ('dot', center, r, color)
elements = []

SEGMENTS = [('bone', 'minertorso1', 23), ('minertorso1', 'minerhead1', 42),
            ('root', 'minerleg1', 23), ('minerleg1', 'minerleg2', 23), ('minerleg2', 'minerfoot1', 23),
            ('root', 'minerleg3', 23), ('minerleg3', 'minerleg4', 23), ('minerleg4', 'minerfoot2', 23),
            ('bone3', 'minerarm3', 23), ('minerarm3', 'minerarm4', 23),
            ('bone3', 'minerarm1', 23), ('minerarm1', 'minerarm2', 23)]
ARM_SEGS = [s for s in SEGMENTS if s[0] in ('bone3', 'minerarm3', 'minerarm1')]

def slot_attachment(slot):
    """兵种 skin 的槽附件（带 path 间接），无覆盖时回退 default 的约定附件。
    返回 (region_name, att_dict) 或 None。"""
    atts = skin['attachments'].get(slot) or {}
    for _k, a in atts.items():
        # region 间接：解包 JSON 用 "name" 字段（非标准 "path"），两者都支持
        name = a.get('path') or a.get('name') or _k
        return (name, a)
    # 兵种 skin 未覆盖：weapon 槽约定附件是 Bow_Full1（游戏运行时为弓手手动设置）；
    # Arrow1 槽 default 附件为 Arrowskn（箭袋，Archidon 兵种 skin 已覆盖）。
    fallback = {'weapon': 'Bow_Full1', 'Arrow1': 'Arrowskn'}.get(slot)
    if fallback and fallback in (skins['default']['attachments'].get(slot) or {}):
        return (fallback, skins['default']['attachments'][slot][fallback])
    return None

def add_attachment(slot):
    got = slot_attachment(slot)
    if got is None:
        print('NO ATT', slot)
        return
    rname, a = got
    if rname not in regions:
        print('no region for', slot, rname)
        return
    slot_obj = next((sl for sl in d['slots'] if sl['name'] == slot), None)
    slot_bone = slot_obj['bone'] if slot_obj else None
    if slot_bone is None or slot_bone not in bones:
        print('NO BONE', slot, slot_bone)
        return
    wx, wy, wr = world(slot_bone)
    x0, y0, rw, rh = regions[rname]
    img = atlas_img.crop((x0, y0, x0+rw, y0+rh))
    if 'uvs' in a:
        # mesh 附件：纹理经顶点仿射贴到骨局部系（拟合 uv·region → vertices），
        # 残差 ~20/370 Spine 单位（网格微变形，仿射近似对验收足够）。
        import numpy as np
        W_, H_ = img.size
        src = np.array(a['uvs'], float).reshape(-1, 2) * np.array([W_, H_])
        dst = np.array(a['vertices'], float).reshape(-1, 2)
        Amat = np.hstack([src, np.ones((len(src), 1))])
        coef, *_ = np.linalg.lstsq(Amat, dst, rcond=None)
        A2, t2 = coef[:2].T, coef[2]
        err = float(np.abs(Amat @ coef - dst).max())
        elements.append(('mesh', img, (wx, wy), wr, A2, t2, slot, rname))
        elements.append(('dot', (wx, wy), 14, (255, 160, 40, 255)))
        print('ATT %s MESH region=%s 拟合残差max=%.1f boneWorld=%.2f' % (slot, rname, err, wr))
        return
    aw, ah = a.get('width') or img.width, a.get('height') or img.height
    sx, sy = a.get('scaleX', 1), a.get('scaleY', 1)
    dw, dh = max(1, int(aw*sx)), max(1, int(ah*sy))
    ar = wr + a.get('rotation', 0)   # 附件世界角（Spine y-up CCW）
    ox, oy = a.get('x', 0), a.get('y', 0)
    c = (wx + ox*math.cos(math.radians(wr)) - oy*math.sin(math.radians(wr)),
         wy + ox*math.sin(math.radians(wr)) + oy*math.cos(math.radians(wr)))
    elements.append(('att', img, c, ar, dw, dh, slot, rname))
    # 手骨原点标记（握点应落在附件上此处）
    elements.append(('dot', (wx, wy), 14, (255, 160, 40, 255)))
    print('ATT %s region=%s wh=%sx%s s=%s rot=%s xy=%s boneWorld=%.2f attWorld=%.2f' % (
        slot, rname, aw, ah, sx, a.get('rotation', 0), (ox, oy), wr, ar))

if args.focus == 'full':
    for pin, chin, thick in SEGMENTS:
        elements.append(('seg', world(pin)[:2], world(chin)[:2], thick, (235, 235, 240, 255)))
else:
    for pin, chin, thick in ARM_SEGS:
        elements.append(('seg', world(pin)[:2], world(chin)[:2], thick, (235, 235, 240, 255)))
    if args.focus == 'hand':
        wx, wy, wr = world('pickaxe1')
        elements.append(('dot', (wx, wy), 16, (255, 160, 40, 255)))
        print('FOCUS hand bone pickaxe1 world=', (round(wx, 2), round(wy, 2), round(wr, 2)))

add_attachment('weapon')
if args.focus == 'full':
    add_attachment('Arrow1')

# ---- 取景与绘制（屏幕 y-down：screen = (CX + x*S, CY - y*S)） ----
W, H = 1100, 1100
MARGIN = 60
def _mesh_world_pts(e):
    """mesh 元素四角的世界坐标（Spine y-up）。e = ('mesh', img, bone, wr, A2, t2, ...)"""
    import numpy as np
    _tag, img, bone, wr, A2, t2 = e[0], e[1], e[2], e[3], e[4], e[5]
    w_, h_ = img.size
    rot = np.array([[math.cos(math.radians(wr)), -math.sin(math.radians(wr))],
                    [math.sin(math.radians(wr)), math.cos(math.radians(wr))]])
    return [tuple(rot @ (A2 @ np.array([u, v]) + t2) + np.array(bone))
            for u, v in ((0, 0), (w_, 0), (0, h_), (w_, h_))]

xs, ys = [], []
for e in elements:
    if e[0] == 'seg':
        xs += [e[1][0], e[2][0]]; ys += [e[1][1], e[2][1]]
    elif e[0] == 'att':
        r = max(e[4], e[5]) / 2 * 1.42   # 旋转外接
        xs += [e[2][0]-r, e[2][0]+r]; ys += [e[2][1]-r, e[2][1]+r]
    elif e[0] == 'mesh':
        for p in _mesh_world_pts(e):
            xs += [p[0]]; ys += [p[1]]
    elif e[0] == 'dot':
        xs += [e[1][0]-20, e[1][0]+20]; ys += [e[1][1]-20, e[1][1]+20]
bx0, bx1, by0, by1 = min(xs), max(xs), min(ys), max(ys)
S = min((W-2*MARGIN)/max(bx1-bx0, 1), (H-2*MARGIN)/max(by1-by0, 1))
CX = MARGIN + (W-2*MARGIN - (bx1-bx0)*S)/2 - bx0*S
CY = MARGIN + (H-2*MARGIN - (by1-by0)*S)/2 + by1*S

def W2S(p):
    return (CX + p[0]*S, CY - p[1]*S)

canvas = Image.new('RGBA', (W, H), (70, 70, 70, 255))
dr = ImageDraw.Draw(canvas)
# 先画肢体，再画附件（SWL 槽序武器在上），手部标记最后
for e in [e for e in elements if e[0] == 'seg']:
    _, p1, p2, thick, color = e
    dr.line([W2S(p1), W2S(p2)], fill=color, width=max(1, int(thick*S)))
for e in [e for e in elements if e[0] == 'att']:
    _, img, c, ar, dw, dh, slot, rname = e
    img2 = img.resize((max(1, int(dw*S)), max(1, int(dh*S))), Image.LANCZOS)
    # 屏幕坐标系 y 翻转后，Spine 世界角 ar（y-up CCW）在画布上等效 PIL rotate(ar)（CCW 为正）
    rt = img2.rotate(ar, resample=Image.BICUBIC, expand=True)
    dest = (int(W2S(c)[0] - rt.width/2), int(W2S(c)[1] - rt.height/2))
    canvas.alpha_composite(rt, dest)
    print('PASTE %s region=%s attWorld=%.2f° disp=%.0fx%.0f center_screen=(%d,%d)' % (
        slot, rname, ar, dw*S, dh*S, dest[0]+rt.width//2, dest[1]+rt.height//2))
for e in [e for e in elements if e[0] == 'mesh']:
    _tag, img, bone, wr, A2, t2, slot, rname = e
    import numpy as np
    # screen = W2S(bone + R(wr)·(A2·texel + t2)) = M·texel + v；PIL 需要逆映射系数
    rot = np.array([[math.cos(math.radians(wr)), -math.sin(math.radians(wr))],
                    [math.sin(math.radians(wr)), math.cos(math.radians(wr))]])
    M = S * np.array([[1, 0], [0, -1]]) @ rot @ A2
    v = np.array(W2S(tuple(rot @ t2 + np.array(bone))))
    Minv = np.linalg.inv(M)
    cfs = Minv @ (-v)
    rt = img.transform((W, H), Image.AFFINE,
                       (Minv[0, 0], Minv[0, 1], cfs[0], Minv[1, 0], Minv[1, 1], cfs[1]),
                       resample=Image.BICUBIC)
    canvas.alpha_composite(rt, (0, 0))
    print('PASTE %s MESH region=%s 骨世界角=%.2f°' % (slot, rname, wr))
for e in [e for e in elements if e[0] == 'dot']:
    _, c, r, color = e
    sp = W2S(c)
    dr.ellipse([sp[0]-r, sp[1]-r, sp[0]+r, sp[1]+r], fill=color)

canvas.convert('RGB').save(args.out)
print('SAVED %dx%d -> %s (anim=%s t=%s focus=%s skin=%s S=%.2f)' % (
    W, H, args.out, args.anim, args.time, args.focus, skin['name'], S))
