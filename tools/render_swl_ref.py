import json, io, sys, math, argparse
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
from PIL import Image, ImageDraw
# 复用姿态验收链 1a 的时间插值求值（与 dump_spine_pose.py 口径完全一致）
from dump_spine_pose import _sample_linear

# ---- 参数化（任务 1c）：无参数运行保持原默认行为（Stand1 t=0 full 输出） ----
ap = argparse.ArgumentParser(description='PIL 单姿势参考渲染器（可用 --time 取任意时刻姿态）')
ap.add_argument('--anim', default='Swordwrath-Stand1', help='动画名（默认 Swordwrath-Stand1）')
ap.add_argument('--time', type=float, default=0.0,
                help='采样时刻秒（默认 0；rotate/translate 线性插值，替代旧的「首关键帧」取值）')
ap.add_argument('--out', default='stick-world/tools/baking/ref_swl_pose.png', help='输出 PNG 路径')
ap.add_argument('--focus', choices=['sword', 'hand', 'full'], default='full',
                help='sword=只画剑附件与手骨聚焦渲染; hand=手骨链+武器; full=全身(原行为)')
args = ap.parse_args()

d = json.load(open('external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt', encoding='utf-8'))
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
atlas_img = Image.open('external/decompiled/legacy/spine_raw/textures/universal.png').convert('RGBA')

P = {}
anim = d['animations'][args.anim]
# 旧取法是「带 angle 的键中取 time 最小者」（首关键帧口径，且会跳过空键 {}）；
# 现改为在 --time 处对 rotate 曲线线性插值（Spine hold-first 语义，首键缺 angle 按 0）。
# 对 Stand1 t=0 两种口径数值一致（该动画无「首键为空键」的轨道，已验证）。
for bn, tls in anim.get('bones', {}).items():
    rot = tls.get('rotate')
    if not rot:
        continue
    P[bn] = _sample_linear(rot, args.time, 'angle')
# root 的 translate 增量同样按时间插值，叠加进 root 世界位置（与 dump 口径一致）
_root_tr = anim.get('bones', {}).get('root', {}).get('translate', [])
ROOT_TX = _sample_linear(_root_tr, args.time, 'x')
ROOT_TY = _sample_linear(_root_tr, args.time, 'y')

def world(bn):
    b = bones[bn]
    p = b.get('parent')
    # Spine: 动画 rotate 是相对 setup rotation 的增量 → 绝对角 = setup + 动画
    a = b.get('rotation', 0.0) + P.get(bn, 0.0)
    if p is None:
        # root：setup 位置 + 动画 translate 增量（与 dump_spine_pose 口径一致；t=0 且无增量时不变）
        return (float(b.get('x', 0)) + ROOT_TX, float(b.get('y', 0)) + ROOT_TY, float(a))
    px, py, pa = world(p)
    pr = math.radians(pa)
    x, y = float(b.get('x', 0)), float(b.get('y', 0))
    return (px + x*math.cos(pr) - y*math.sin(pr),
            py + x*math.sin(pr) + y*math.cos(pr), float(a))

skin = None
for sk in d['skins']:
    if sk['name'] == 'default':
        skin = sk

S = 2.5
W, H = 1200, 900
canvas = Image.new('RGBA', (W, H), (70, 70, 70, 255))
CX, CY = 300, 150

def seg(pin, chin, thick, color):
    x1, y1, _ = world(pin)
    x2, y2, _ = world(chin)
    dr = ImageDraw.Draw(canvas)
    dr.line([(CX+x1*S, CY+y1*S), (CX+x2*S, CY+y2*S)], fill=color, width=int(thick*S))
    dr.ellipse([CX+x2*S-thick*S/2, CY+y2*S-thick*S/2, CX+x2*S+thick*S/2, CY+y2*S+thick*S/2], fill=color)

SEGMENTS = [('bone', 'minertorso1', 23), ('minertorso1', 'minerhead1', 42),
            ('root', 'minerleg1', 23), ('minerleg1', 'minerleg2', 23), ('minerleg2', 'minerfoot1', 23),
            ('root', 'minerleg3', 23), ('minerleg3', 'minerleg4', 23), ('minerleg4', 'minerfoot2', 23),
            ('bone3', 'minerarm3', 23), ('minerarm3', 'minerarm4', 23),
            ('bone3', 'minerarm1', 23), ('minerarm1', 'minerarm2', 23)]
ARM_SEGS = [s for s in SEGMENTS if s[0] in ('bone3', 'minerarm3', 'minerarm1')]

if args.focus == 'full':
    for pin, chin, thick in SEGMENTS:
        seg(pin, chin, thick, (235, 235, 240, 255))
else:
    # sword/hand 聚焦：只画手臂链（剑的持握链路）
    for pin, chin, thick in ARM_SEGS:
        seg(pin, chin, thick, (235, 235, 240, 255))
    if args.focus == 'hand':
        # hand：额外把手骨 pickaxe1（weapon 槽挂载骨）画成短线+圆点标记
        wx, wy, wr = world('pickaxe1')
        dr = ImageDraw.Draw(canvas)
        x2, y2 = wx + 18 * math.cos(math.radians(wr)), wy + 18 * math.sin(math.radians(wr))
        dr.line([(CX+wx*S, CY+wy*S), (CX+x2*S, CY+y2*S)], fill=(255, 200, 80, 255), width=int(10*S))
        dr.ellipse([CX+wx*S-12, CY+wy*S-12, CX+wx*S+12, CY+wy*S+12], fill=(255, 160, 40, 255))
        print('FOCUS hand bone pickaxe1 world=', (round(wx, 2), round(wy, 2), round(wr, 2)))

def draw_att(slot, name):
    if skin is None:
        return
    atts = skin['attachments'].get(slot, None)
    if atts is None or name not in atts:
        print('NO ATT', slot, name)
        return
    a = atts[name]
    slot_obj = None
    for sl in d['slots']:
        if sl['name'] == slot:
            slot_obj = sl
            break
    slot_bone = slot_obj['bone'] if slot_obj else None
    if slot_bone is None or slot_bone not in bones:
        print('NO BONE', slot, slot_bone)
        return
    wx, wy, wr = world(slot_bone)
    rname = name if name in regions else None
    if rname is None:
        print('no region for', slot, name)
        return
    x0, y0, rw, rh = regions[rname]
    img = atlas_img.crop((x0, y0, x0+rw, y0+rh))
    aw, ah = a.get('width') or img.width, a.get('height') or img.height
    sx, sy = a.get('scaleX', 1), a.get('scaleY', 1)
    dw, dh = max(1, int(aw*sx*S)), max(1, int(ah*sy*S))
    img2 = img.resize((dw, dh), Image.LANCZOS)
    ar = wr + a.get('rotation', 0)
    rt = img2.rotate(-ar, resample=Image.BICUBIC, expand=True)
    ox, oy = a.get('x', 0), a.get('y', 0)
    cxx = wx + ox*math.cos(math.radians(wr)) - oy*math.sin(math.radians(wr))
    cyy = wy + ox*math.sin(math.radians(wr)) + oy*math.cos(math.radians(wr))
    dest = (int(CX + cxx*S - rt.width/2), int(CY + cyy*S - rt.height/2))
    canvas.alpha_composite(rt, dest)
    print('PASTE', slot, name, 'dest=', dest, 'size=', rt.size)
    # 采样中心像素
    px = canvas.getpixel((dest[0]+rt.width//2, min(dest[1]+rt.height//2, canvas.height-1)))
    print('CENTER PIXEL', px)
    print('DREW', slot, name, 'world=(', round(wx,1), round(wy,1), ') ar=', round(ar,1), 'disp=', dw, 'x', dh)

# full：画武器 + 盾两个附件；sword/hand 聚焦：只画武器剑
draw_att('weapon', 'Swordbasic')
if args.focus == 'full':
    draw_att('Arrow1', 'classic-spearton-shield-0')

# 调试：打印部分关键点
print('DBG pickaxe1 world:', world('pickaxe1'))
print('DBG Arrow1 world:', world('Arrow1'))
print('DBG regions has Swordbasic:', 'Swordbasic' in regions)
print('DBG skin weapon atts:', list(d['skins'][0]['attachments']['weapon'].keys())[:8])

canvas.convert('RGB').save(args.out)
print('SAVED', W, H, '->', args.out, f'(anim={args.anim} t={args.time} focus={args.focus})')
