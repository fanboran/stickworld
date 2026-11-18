# -*- coding: utf-8 -*-
"""SWL Spine 骨架 FK 参照图生成器 —— 战场观感重构 S1 验收链。

对指定动画逐时刻做正向运动学，把 Spine 骨架画成火柴人线图（y-up→屏幕
y-down 翻转），作为 Godot 侧 anim_gallery 复渲帧的逐帧姿势真值参照。
动作数据单一真相源（2026-10-09 创始人裁决）的验收侧配套。

用法（python = Python312，PIL 依赖）：
  python tools/baking/spine_pose_ref.py [动画名 ...]   # 缺省抽验集
输出：temp/spine_pose_ref/<动画>_<i>.png + 汇总网格 all_ref.png
"""
import json
import math
import os
import sys

SPINE_FILE = r"F:/VSCode/stickworld/external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt"
OUT_DIR = os.path.join("temp", "spine_pose_ref")
SCALE = 0.55          # Spine 单位 → 像素
LINE_W = 5
# 参照骨架只画核心肢体链（与本项目 SPINE_TO_MY 映射同集）
DRAW_BONES = {
    "bone": None, "minertorso1": "bone", "bone2": "minertorso1", "bone3": "bone2",
    "minerhead1": "bone3",
    "minerarm1": "bone3", "minerarm2": "minerarm1",
    "minerarm3": "bone3", "minerarm4": "minerarm3",
    "minerleg2": "bone", "minerleg1": "minerleg2", "minerfoot1": "minerleg1",
    "minerleg4": "bone", "minerleg3": "minerleg4", "minerfoot2": "minerleg3",
    "pickaxe1": "minerarm4", "Arrow1": "minerarm2",
}
SEEKS = [0.25, 0.55, 0.85]   # 与 anim_gallery.gd 抽帧位置一致
DEFAULT_SET = ["walk", "run", "attack", "attack_bow", "attack_bow_reload",
               "run_bow", "dead", "idle_bow", "attack_spear"]
ANIM_MAP = {   # 与 spine_import.gd ANIM_MAP 同名对（抽验子集）
    "walk": "Swordwrath-Walk", "run": "Swordwrath-Run",
    "attack": "Swordwrath-Attack1", "attack_bow": "Archidon-Draw",
    "attack_bow_reload": "Archidon-Reload", "run_bow": "Archidon-Run",
    "dead": "Death1", "idle_bow": "Archidon-Stand1",
    "attack_spear": "Spearton-Attack1",
}


def load():
    with open(SPINE_FILE, encoding="utf-8") as f:
        return json.load(f)


def timeline(anim, bone, kind="rotate"):
    """骨架 JSON 时间线 → {t: value}（线性插值采样用有序键表）。"""
    b = anim.get("bones", {}).get(bone, {})
    return b.get(kind, [])


def sample(keys, t, default):
    """曲线感知采样：None=linear / stepped=保持 / [cx1,cy1,cx2,cy2]=bezier
    （与 spine_import 的 _eval_keys 同数学，互为独立复算）。"""
    if not keys:
        return default, False
    times = [float(k.get("time", 0.0)) for k in keys]

    def angle_of(k):
        return float(k.get("angle", 0.0))

    if t <= times[0]:
        return angle_of(keys[0]), True
    for i in range(len(keys) - 1):
        if times[i] <= t <= times[i + 1]:
            span = times[i + 1] - times[i]
            if span <= 0:
                return angle_of(keys[i]), True
            r = (t - times[i]) / span
            curve = _expand_curve(keys[i])
            if curve is None:
                a0, a1 = angle_of(keys[i]), angle_of(keys[i + 1])
                return a0 + (a1 - a0) * r, True
            if curve == "stepped":
                return angle_of(keys[i]), True
            cx1, cy1, cx2, cy2 = curve
            u0 = r
            u = u0
            for _ in range(8):
                bx = _bez1(u, cx1, cx2)
                dx = _bezd(u, cx1, cx2)
                if abs(dx) < 1e-6:
                    break
                u -= (bx - u0) / dx
                u = max(0.0, min(1.0, u))
            a0, a1 = angle_of(keys[i]), angle_of(keys[i + 1])
            return a0 + (a1 - a0) * _bez1(u, cy1, cy2), True
    return angle_of(keys[-1]), True


def _expand_curve(k):
    """紧凑曲线 → None(线性) | "stepped" | [cx1, cy1, cx2, cy2]。
    3.8.99 格式（ReadCurve 反汇编定案）：数值 f=bezier cx1，伴生 c2/c3/c4
    缺省 0/1/1。"""
    if "curve" not in k:
        return None
    c = k["curve"]
    if c == "stepped":
        return "stepped"
    return [float(c), float(k.get("c2", 0.0)), float(k.get("c3", 1.0)), float(k.get("c4", 1.0))]


def _bez1(u, c1, c2):
    v = 1.0 - u
    return 3.0 * v * v * u * c1 + 3.0 * v * u * u * c2 + u * u * u


def _bezd(u, c1, c2):
    v = 1.0 - u
    return 3.0 * v * v * c1 + 6.0 * v * u * (c2 - c1) + 3.0 * u * u * (1.0 - c2)


def anim_length(anim):
    mx = 0.0
    for ts in anim.get("bones", {}).values():
        for kind in ("rotate", "translate"):
            for k in ts.get(kind, []):
                mx = max(mx, float(k.get("time", 0.0)))
    return mx


def fk(data, anim, t):
    """t 时刻全骨世界变换（Spine y-up）。rotate 时间线值 = 绝对局部角。"""
    bones = {b["name"]: b for b in data["bones"]}
    out = {}

    def world(name):
        if name in out:
            return out[name]
        b = bones[name]
        parent = b.get("parent")
        if parent is None or parent not in bones:
            px, py, pa = 0.0, 0.0, 0.0
        else:
            _, (px, py), pa = world(parent)
        # 局部：setup + 动画绝对值覆盖（未列骨保持 setup）
        ang, _ = sample(timeline(anim, name), t, float(b.get("rotation", 0.0)))
        x = float(b.get("x", 0.0))
        y = float(b.get("y", 0.0))
        tk = timeline(anim, name, "translate")
        if tk:
            # translate 值 = 相对 setup 的偏移
            dx = dy = 0.0
            for k in tk:
                kt = float(k.get("time", 0.0))
                if kt <= t:
                    dx = float(k.get("x", 0.0))
                    dy = float(k.get("y", 0.0))
            x += dx
            y += dy
        c, s = math.cos(math.radians(pa)), math.sin(math.radians(pa))
        wx = px + x * c - y * s
        wy = py + x * s + y * c
        wa = pa + ang
        out[name] = (name, (wx, wy), wa)
        return out[name]

    for n in bones:
        world(n)
    return out


def render(anim_name, spine_name, data, seek):
    anim = data["animations"][spine_name]
    length = anim_length(anim)
    t = length * seek
    pose = fk(data, anim, t)
    from PIL import Image, ImageDraw
    W, H = 360, 420
    img = Image.new("RGB", (W, H), (250, 248, 244))
    d = ImageDraw.Draw(img)
    ox, oy = W * 0.42, H * 0.78   # root 原点（y-up→屏幕 y-down）
    bones = {b["name"]: b for b in data["bones"]}

    def to_screen(x, y):
        return (ox + x * SCALE, oy - y * SCALE)

    # root translate（起伏）
    rx, ry = 0.0, 0.0
    tk = timeline(anim, "root", "translate")
    if tk:
        for k in tk:
            if float(k.get("time", 0.0)) <= t:
                rx = float(k.get("x", 0.0))
                ry = float(k.get("y", 0.0))
    # 躯干链根 = bone（其 setup 位置 + root 位移）
    for child, parent in DRAW_BONES.items():
        if parent is None:
            continue
        _, (cx, cy), _ = pose[child]
        _, (px, py), _ = pose[parent]
        a = to_screen(px + rx, py + ry)
        b = to_screen(cx + rx, cy + ry)
        col = (60, 60, 70)
        wid = LINE_W
        if child in ("pickaxe1", "Arrow1"):
            col, wid = (150, 100, 40), LINE_W - 2   # 武器/箭通道骨
        d.line([a, b], fill=col, width=wid)
        d.ellipse([b[0] - 4, b[1] - 4, b[0] + 4, b[1] + 4], fill=col)
    # 头：骨原点向上偏置（附件式，近似 HEAD_ORBIT 语义）
    if "minerhead1" in pose:
        _, (hx, hy), ha = pose["minerhead1"]
        hd = 38.0   # Spine 长度 32.4 的近似头径
        cx = hx + math.cos(math.radians(ha + 90.0)) * hd
        cy = hy + math.sin(math.radians(ha + 90.0)) * hd
        c = to_screen(cx + rx, cy + ry)
        r = 20
        d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r],
                  outline=(60, 60, 70), width=LINE_W)
    d.text((10, 8), "%s @t=%.2f/%.2f (seek %.2f)" % (anim_name, t, length, seek),
           fill=(30, 30, 40))
    return img


def main():
    names = sys.argv[1:] or DEFAULT_SET
    data = load()
    os.makedirs(OUT_DIR, exist_ok=True)
    from PIL import Image
    cells = []
    for n in names:
        sp = ANIM_MAP.get(n)
        if sp is None or sp not in data["animations"]:
            print("skip %s（无映射或缺源）" % n)
            continue
        for i, seek in enumerate(SEEKS):
            img = render(n, sp, data, seek)
            p = os.path.join(OUT_DIR, "%s_%d.png" % (n, i))
            img.save(p)
            cells.append((n, i, img))
            print("OK", p)
    if not cells:
        print("无产出")
        return
    cols = len(SEEKS)
    rows = (len(cells) + cols - 1) // cols
    CW, CH = 360, 420
    grid = Image.new("RGB", (cols * CW, rows * CH), (255, 255, 255))
    for idx, (n, i, img) in enumerate(cells):
        grid.paste(img, ((i % cols) * CW, (idx // cols) * CH))
    out = os.path.join(OUT_DIR, "all_ref.png")
    grid.save(out)
    print("汇总网格:", os.path.abspath(out))


if __name__ == "__main__":
    main()
