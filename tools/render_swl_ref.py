import json, io, sys, math
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
from PIL import Image, ImageDraw

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
anim = d['animations']['Swordwrath-Stand1']
for bn, tls in anim.get('bones', {}).items():
    rot = tls.get('rotate')
    if not rot:
        continue
    ks = [k for k in rot if 'angle' in k]
    if ks:
        P[bn] = min(ks, key=lambda k: k.get('time', 0))['angle']

def world(bn):
    b = bones[bn]
    p = b.get('parent')
    # Spine: 动画 rotate 是相对 setup rotation 的增量 → 绝对角 = setup + 动画
    a = b.get('rotation', 0.0) + P.get(bn, 0.0)
    if p is None:
        return (float(b.get('x', 0)), float(b.get('y', 0)), float(a))
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

for pin, chin, thick in [('bone', 'minertorso1', 23), ('minertorso1', 'minerhead1', 42),
                         ('root', 'minerleg1', 23), ('minerleg1', 'minerleg2', 23), ('minerleg2', 'minerfoot1', 23),
                         ('root', 'minerleg3', 23), ('minerleg3', 'minerleg4', 23), ('minerleg4', 'minerfoot2', 23),
                         ('bone3', 'minerarm3', 23), ('minerarm3', 'minerarm4', 23),
                         ('bone3', 'minerarm1', 23), ('minerarm1', 'minerarm2', 23)]:
    seg(pin, chin, thick, (235, 235, 240, 255))

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

draw_att('weapon', 'Swordbasic')
draw_att('Arrow1', 'classic-spearton-shield-0')

# 调试：打印部分关键点
print('DBG pickaxe1 world:', world('pickaxe1'))
print('DBG Arrow1 world:', world('Arrow1'))
print('DBG regions has Swordbasic:', 'Swordbasic' in regions)
print('DBG skin weapon atts:', list(d['skins'][0]['attachments']['weapon'].keys())[:8])

canvas.convert('RGB').save('stick-world/tools/baking/ref_swl_pose.png')
print('SAVED', W, H)
