# -*- coding: utf-8 -*-
"""props.py —— 建筑道具层（管线 v3 · 写实 PBR）

为什么单独一层
--------------
创始人参考图 `assets/_raw/建筑/smithy.png` 里，道具（带铁箍木桶、铁砧、火炉橙色
火光、长凳、木墩、煤桶）贡献了约 1/3 的画面信息量。建筑本体再准，光秃秃一小块
立面在游戏里也读作"空"。本模块把道具做成可复用积木，由装配器/探针统一挂载。

约定（与 buildings.py 的公共 API 对齐，**不修改 buildings.py**）
--------------
* **正面 = -Y**（与 `window(face_dir=-1.0)`、`door()` 一致）。道具一律摆在建筑前墙
  面之外：`y = front_y - depth/2`，`front_y` 取 `buildings.measure(ob)["y"][0]`。
* z 向上，地面 z=0；`box_bottom` 的 xy 是水平中心。
* 确定性：所有随机走 `random.Random(seed)`；同一 seed 逐顶点同结果。
* 材质名沿用 buildings 的材质表（见 `buildings.SPEC_COLOR` / `MATERIAL_ALIAS`）。
  深腔用 `glass`（近黑、非金属），发热用 `fire` / `ember`（自发光）。

跑法：装配器里 `import props as P; P.dress(b, "smithy", W, front_y, seed=...)`。
"""

import math
import random

import buildings as B

CELL = B.CELL


# ---------------------------------------------------------------- 工具

def _ring(b, center, radius, height, mat, segments=14, axis="Z", taper=1.0):
    b.cylinder(center, radius, height, mat, segments=segments, axis=axis, taper=taper)


def _strip(b, mat, pts, outward=None):
    """一条折线带（薄板贴面），pts 为世界坐标列表。"""
    if len(pts) >= 3:
        b.poly(list(pts), mat, outward=outward)


def _arc_pts(cx, cz, y, r, a0, a1, steps=10):
    """XZ 平面上的圆弧点列（用于炉口/桶口拱形）。"""
    out = []
    for i in range(steps + 1):
        t = float(i) / steps
        a = a0 + (a1 - a0) * t
        out.append((cx + r * math.cos(a), y, cz + r * math.sin(a)))
    return out


# ================================================================ 容器类

def barrel(b, x=0.0, y=0.0, z=0.0, r=15.0, h=42.0, mat="wood", band_mat="iron",
           staves=16, bands=3, belly=1.10, lying=False, open_top=False, water=False):
    """木桶（腰鼓形桶身 + 铁箍）。

    腰鼓形靠"下锥 + 上锥"两段拼出，比直筒一眼更像桶；`lying=True` 侧躺（桶口朝
    观察者 -Y），`water=True` 桶口加水面（淬火桶/水桶）。
    """
    if lying:
        cy, cz = y, z + r * belly
        mid = h * 0.5
        _ring(b, (x, cy - mid / 2.0, cz), r, mid, mat, staves, "Y", taper=belly)
        _ring(b, (x, cy + mid / 2.0, cz), r * belly, mid, mat, staves, "Y", taper=1.0 / belly)
        for i in range(bands):
            t = (i + 0.5) / bands
            _ring(b, (x, cy - h * 0.5 + t * h, cz), r * (belly if 0.25 < t < 0.75 else 1.02),
                  3.4, band_mat, staves, "Y")
        if water:
            b.cylinder((x, cy - h * 0.5 - 1.0, cz), r * 0.9, 1.2, "glass", staves, "Y")
        else:
            _ring(b, (x, cy - h * 0.5 - 1.0, cz), r * 0.9, 2.6, "wood_dark", staves, "Y")
        return
    mid = h * 0.46
    _ring(b, (x, y, z + mid / 2.0), r, mid, mat, staves, "Z", taper=belly)
    _ring(b, (x, y, z + mid + (h - mid) / 2.0), r * belly, h - mid, mat, staves, "Z",
          taper=1.0 / belly)
    for i in range(bands):
        t = 0.5 / bands + (1.0 - 1.0 / bands) * (float(i) / max(1, bands - 1)) if bands > 1 else 0.5
        _ring(b, (x, y, z + h * t), r * (belly if 0.30 < t < 0.70 else 1.03), 3.2,
              band_mat, staves)
    if open_top:
        if water:
            b.cylinder((x, y, z + h - 1.5), r * belly * 0.92, 1.4, "glass", staves)
    else:
        _ring(b, (x, y, z + h - 1.5), r * belly * 0.9, 3.0, "wood_dark", staves)


def bucket(b, x=0.0, y=0.0, z=0.0, r=10.0, h=22.0, mat="wood", band_mat="iron",
           handle=True):
    """提桶（上宽下窄 + 一道铁箍 + 提梁）。"""
    _ring(b, (x, y, z + h / 2.0), r * 0.86, h, mat, 12, "Z", taper=1.18)
    _ring(b, (x, y, z + h * 0.86), r * 1.02, 2.6, band_mat, 12)
    if handle:
        for sx in (-1.0, 1.0):
            b.box_bottom((3.0, 3.0, 12.0), (x + sx * r * 0.95, y), z + h - 1.0, band_mat)


def trough(b, x=0.0, y=0.0, z=0.0, w=76.0, d=26.0, h=24.0, mat="wood"):
    """水槽（四壁 + 水面）。"""
    t = 6.0
    b.box_bottom((w, t, h), (x, y - d / 2.0 + t / 2.0), z, mat)
    b.box_bottom((w, t, h), (x, y + d / 2.0 - t / 2.0), z, mat)
    b.box_bottom((t, d - 2 * t, h), (x - w / 2.0 + t / 2.0, y), z, mat)
    b.box_bottom((t, d - 2 * t, h), (x + w / 2.0 - t / 2.0, y), z, mat)
    b.box_bottom((w - 2 * t, d - 2 * t, 2.0), (x, y), z + h * 0.62, "glass")


def sack(b, x=0.0, y=0.0, z=0.0, r=13.0, h=30.0, mat="canvas", ear=True):
    """麻袋（下鼓上收 + 扎口）。"""
    _ring(b, (x, y, z + h * 0.35), r, h * 0.7, mat, 12, "Z", taper=0.62)
    b.cylinder((x, y, z + h * 0.72), r * 0.42, h * 0.26, mat, 10, "Z", taper=0.75)
    if ear:
        b.box_bottom((7.0, 5.0, 9.0), (x - 3.0, y), z + h * 0.9, mat)
        b.box_bottom((7.0, 5.0, 7.0), (x + 4.0, y), z + h * 0.88, mat)


def crate(b, x=0.0, y=0.0, z=0.0, s=28.0, h=24.0, mat="wood", batten="wood_dark"):
    """货箱（板面 + 四角压条）。"""
    b.box_bottom((s, s * 0.78, h), (x, y), z, mat)
    e = 3.5
    for sx in (-1.0, 1.0):
        b.box_bottom((e, s * 0.78 + 1.0, h + 1.0), (x + sx * (s / 2.0 - e / 2.0), y), z, batten)
    b.box_bottom((s + 1.0, s * 0.78 + 1.0, e), (x, y), z + h - e, batten)
    b.box_bottom((s + 1.0, s * 0.78 + 1.0, e), (x, y), z + 2.0, batten)


def chest(b, x=0.0, y=0.0, z=0.0, w=48.0, d=30.0, h=32.0, mat="wood", iron="iron"):
    """铁件木柜（箱体 + 铁带 + 锁扣）。"""
    b.box_bottom((w, d, h), (x, y), z, mat)
    b.box_bottom((w, d + 1.0, h * 0.30), (x, y), z + h * 0.70, mat)
    for sx in (-0.42, 0.42):
        b.box_bottom((7.0, d + 2.0, h + 1.0), (x + sx * w, y), z, iron)
    b.box_bottom((12.0, 6.0, 12.0), (x, y - d / 2.0 - 2.0), z + h * 0.36, iron)


def log_pile(b, x=0.0, y=0.0, z=0.0, rows=2, per_row=5, r=8.0, seed=0):
    """柴垛：木料沿 X 横堆，**端面朝观察者**（-Y）——游戏尺寸下也一眼读作柴火。"""
    rng = random.Random(seed)
    span = per_row * (r * 2.0 + 2.0)
    y0 = y
    for row in range(rows):
        for i in range(per_row):
            lx = x - span / 2.0 + (i + 0.5) * (span / per_row)
            lz = z + r + row * (r * 1.85)
            ln = 34.0 + rng.uniform(-3.0, 3.0)
            yy = y0 + rng.uniform(-1.5, 1.5)
            _ring(b, (lx, yy, lz), r * rng.uniform(0.85, 1.05), ln, "wood_light", 10, "Y")
            _ring(b, (lx, yy - ln / 2.0 - 0.6, lz), r * 0.72, 1.6, "wood_dark", 10, "Y")
    for i in range(2):                                   # 立柱挡柴
        b.box_bottom((7.0, 7.0, z + rows * r * 1.85 + 10.0 - z), 
                     (x + (i * 2 - 1) * (span / 2.0 + 5.0), y), z, "timber")


def plank_pile(b, x=0.0, y=0.0, z=0.0, w=64.0, n=7, t=3.2, seed=0):
    """晾/存木板：层叠薄板，端面参差。"""
    rng = random.Random(seed)
    for i in range(n):
        zz = z + t * (i + 0.5)
        b.box_bottom((w + rng.uniform(-5.0, 5.0), 22.0, t),
                     (x + rng.uniform(-2.5, 2.5), y), zz, "wood_light")
    for sx in (-1.0, 1.0):
        b.box_bottom((6.0, 24.0, n * t + 2.0), (x + sx * (w / 2.0 - 4.0), y), z, "timber")


def coal_pile(b, x=0.0, y=0.0, z=0.0, w=44.0, h=18.0, seed=0):
    """煤/矿石堆：低矮堆体 + 碎块。

    必须用**深色**（`iron` 的金属基底接近黑）——`stone_dark` 是给墙面石灰岩用的
    浅灰，堆出来读成"一小堆雪"。
    """
    rng = random.Random(seed)
    _ring(b, (x, y, z + h * 0.30), w * 0.42, h * 0.60, "iron", 12, "Z", taper=0.35)
    for i in range(9):
        b.box_bottom((7.5, 7.5, 6.5),
                     (x + rng.uniform(-1.0, 1.0) * w * 0.36,
                      y + rng.uniform(-1.0, 1.0) * w * 0.26), z,
                     "iron" if i % 3 else "stone_dark",
                     rot=(rng.uniform(-0.2, 0.2), rng.uniform(-0.2, 0.2),
                          rng.uniform(0.0, 3.0)))


def haystack(b, x=0.0, y=0.0, z=0.0, r=26.0, h=44.0, mat="thatch", pole=True,
             tufts=7, seed=0):
    """草垛：**低矮圆顶锥**（不是尖锥）+ 散落草梢 + 中柱。

    尖锥在游戏尺寸下会被读成"金色小帐篷"；草垛的正确轮廓是矮胖圆顶 —— 底径大、
    顶部收得快但带圆弧，所以用"下段缓锥 + 上段急锥"两节拼。
    """
    rng = random.Random(seed)
    _ring(b, (x, y, z + h * 0.22), r, h * 0.44, mat, 16, "Z", taper=0.78)
    _ring(b, (x, y, z + h * 0.66), r * 0.78, h * 0.44, mat, 16, "Z", taper=0.42)
    _ring(b, (x, y, z + h * 0.90), r * 0.33, h * 0.20, mat, 14, "Z", taper=0.30)
    for i in range(tufts):                                    # 散落草梢（破掉完美曲面）
        th = rng.uniform(0.0, math.pi * 2.0)
        rr = rng.uniform(0.55, 1.0)
        hz = rng.uniform(0.05, 0.55)
        b.box((6.0, 6.0, 14.0),
              (x + math.cos(th) * r * rr, y + math.sin(th) * r * rr, z + h * hz),
              "straw", rot=(rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5), th))
    if pole:
        b.box_bottom((8.0, 8.0, h * 0.55), (x, y), z + h * 0.45, "timber")


# ================================================================ 铁匠/工坊

def anvil(b, x=0.0, y=0.0, z=0.0, mat="iron", stump=True, stump_h=36.0):
    """铁砧（砧角 + 砧尾 + 可选木墩），总高约 62。"""
    base = z + stump_h if stump else z
    if stump:
        _ring(b, (x, y, z + stump_h / 2.0), 17.0, stump_h, "wood_dark", 14)
        _ring(b, (x, y, z + 3.0), 18.5, 6.0, "timber", 14)
    b.box_bottom((36.0, 21.0, 6.0), (x, y), base, mat)                  # 砧座
    b.box_bottom((17.0, 14.0, 13.0), (x, y), base + 6.0, mat)           # 腰
    b.box_bottom((46.0, 20.0, 9.0), (x, y), base + 19.0, mat)           # 砧面
    b.cylinder((x + 30.0, y, base + 23.5), 6.0, 20.0, mat, 10, "X", taper=0.30)  # 砧角
    b.box_bottom((14.0, 17.0, 6.0), (x - 29.0, y), base + 19.0, mat)    # 砧尾
    return {"top": base + 28.0}


def tongs(b, x=0.0, y=0.0, z=0.0, mat="iron"):
    """火钳（两根交叉细杆 + 钳口）。"""
    for sx in (-1.0, 1.0):
        b.box(  # 手柄段
            (5.0, 4.0, 34.0), (x + sx * 5.0, y, z + 17.0), mat,
            rot=(0.0, sx * math.radians(9.0), 0.0))
        b.box_bottom((4.0, 3.0, 22.0), (x + sx * 8.0, y), z + 30.0, mat,
                     rot=(0.0, -sx * math.radians(11.0), 0.0))


def tools_rack(b, x=0.0, y=0.0, z=0.0, w=54.0, mat="timber"):
    """挂墙工具架（横梁 + 挂钩 + 锤与钳），装在立面上。"""
    b.box_bottom((w, 6.0, 7.0), (x, y), z, mat)
    for i in range(3):
        hx = x - w / 2.0 + (i + 0.5) * (w / 3.0)
        b.box_bottom((4.0, 5.0, 9.0), (hx, y - 4.0), z - 9.0, "iron")
    b.box_bottom((9.0, 7.0, 16.0), (x - w / 4.0, y - 7.0), z - 30.0, "iron")     # 锤头
    b.box_bottom((4.0, 4.0, 22.0), (x - w / 4.0, y - 7.0), z - 52.0, "wood")     # 锤柄
    b.box_bottom((13.0, 5.0, 9.0), (x + w / 4.0, y - 7.0), z - 22.0, "iron")     # 钳


def grindstone(b, x=0.0, y=0.0, z=0.0, r=24.0, mat="stone_dark"):
    """磨石（立轮 + 木架 + 摇柄）。"""
    for sx in (-1.0, 1.0):
        b.box_bottom((8.0, 26.0, 34.0), (x + sx * 9.0, y), z, "timber")
    _ring(b, (x, y, z + 34.0 + r * 0.55), r, 13.0, mat, 16, "X")
    b.cylinder((x + 8.0, y, z + 34.0 + r * 0.55), 2.4, 22.0, "iron", 8, "X")
    b.cylinder((x + 20.0, y, z + 34.0 + r * 0.55), 3.0, 16.0, "wood", 8, "X")
    b.box_bottom((26.0, 18.0, 6.0), (x, y), z + 28.0, "timber")


def quench_barrel(b, x=0.0, y=0.0, z=0.0):
    """淬火桶（桶 + 水面 + 插着的铁件）。"""
    barrel(b, x, y, z, r=14.0, h=40.0, open_top=True, water=True)
    b.box((4.0, 4.0, 40.0), (x + 5.0, y, z + 38.0), "iron",
          rot=(0.0, math.radians(18.0), 0.0))
    b.box((4.0, 4.0, 34.0), (x - 6.0, y + 2.0, z + 36.0), "iron",
          rot=(0.0, math.radians(-13.0), 0.0))


# ================================================================ 家具

def bench(b, x=0.0, y=0.0, z=0.0, w=64.0, d=28.0, h=34.0, mat="wood",
          back=False, legs=4):
    """长凳/工作台（带可选靠背）。"""
    b.box_bottom((w, d, 6.0), (x, y), z + h - 6.0, mat)
    if legs == 4:
        for sx in (-1.0, 1.0):
            for sy in (-1.0, 1.0):
                b.box_bottom((7.0, 7.0, h - 6.0),
                             (x + sx * (w / 2.0 - 7.0), y + sy * (d / 2.0 - 7.0)), z, mat)
    else:
        for sx in (-1.0, 1.0):
            b.box_bottom((9.0, d - 4.0, h - 6.0), (x + sx * (w / 2.0 - 8.0), y), z, mat)
    if back:
        for sx in (-1.0, 1.0):
            b.box_bottom((7.0, 7.0, 30.0), (x + sx * (w / 2.0 - 7.0), y + d / 2.0 - 5.0),
                         z + h - 6.0, mat)
        b.box_bottom((w, 6.0, 9.0), (x, y + d / 2.0 - 5.0), z + h + 20.0, mat)


def stool(b, x=0.0, y=0.0, z=0.0, r=13.0, h=28.0, mat="wood", legs=3):
    """圆凳/三脚凳。"""
    _ring(b, (x, y, z + h - 4.0), r, 7.0, mat, 12)
    for i in range(legs):
        th = 2.0 * math.pi * i / legs + 0.4
        b.box_bottom((6.0, 6.0, h - 7.0),
                     (x + math.cos(th) * r * 0.58, y + math.sin(th) * r * 0.58), z, mat)


def table(b, x=0.0, y=0.0, z=0.0, w=62.0, d=34.0, h=44.0, mat="wood"):
    """桌面（板缝 + 四腿 + 横撑）。"""
    b.box_bottom((w, d, 6.0), (x, y), z + h - 6.0, mat)
    b.box_bottom((w, d * 0.9, 4.0), (x, y), z + h - 11.0, mat)
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            b.box_bottom((7.0, 7.0, h - 10.0),
                         (x + sx * (w / 2.0 - 7.0), y + sy * (d / 2.0 - 7.0)), z, mat)
    for sy in (-1.0, 1.0):
        b.box_bottom((w - 14.0, 5.0, 5.0), (x, y + sy * (d / 2.0 - 7.0)), z + h * 0.36, mat)


def signboard(b, x=0.0, y=0.0, z=0.0, w=54.0, h=40.0, mat="wood_dark",
              strap="iron", swing=0.0):
    """悬挂招牌（铁支架 + 吊链 + 木板），挂在立面外。"""
    arm = w * 0.62
    b.box_bottom((7.0, 7.0, 34.0), (x, y), z + h + 6.0, strap)          # 立杆
    b.box((arm, 7.0, 7.0), (x, y - arm / 2.0, z + h + 34.0), strap)     # 横臂
    b.box((w, h, 6.0), (x, y - arm * 0.82, z + h * 0.5), mat, rot=(0.0, math.radians(swing), 0.0))
    for sx in (-1.0, 1.0):
        b.box_bottom((4.0, 4.0, 12.0),
                     (x + sx * (w / 2.0 - 6.0), y - arm * 0.82), z + h - 4.0, strap)
    b.box_bottom((w + 5.0, 7.0, 5.0), (x, y - arm * 0.82), z + h - 4.0, mat)   # 上压条
    b.box_bottom((w + 5.0, 7.0, 5.0), (x, y - arm * 0.82), z, mat)             # 下压条


def lantern(b, x=0.0, y=0.0, z=0.0, s=17.0, h=26.0, bracket=True, lit=True,
            glass="glass"):
    """灯笼/风灯（铁框 + 玻璃四面 + 顶盖 + 暖光核心）。"""
    if bracket:
        b.box_bottom((6.0, 6.0, h + 18.0), (x, y), z + h * 0.35, "iron")
        b.box((14.0, 6.0, 6.0), (x, y - 7.0, z + h + 12.0), "iron")
        b.box_bottom((3.0, 3.0, 9.0), (x, y - 12.0), z + h + 3.0, "iron")
    bz = z + h * 0.35
    b.box_bottom((s, s, 4.0), (x, y, ), bz - 4.0, "iron")                     # 底
    b.box_bottom((s * 0.8, s * 0.8, h), (x, y), bz, glass)                    # 玻璃体
    for sx in (-1.0, 1.0):                                                   # 四角框
        b.box_bottom((3.0, 3.0, h), (x + sx * s * 0.42, y - s * 0.42), bz, "iron")
        b.box_bottom((s + 1.0, 3.0, 3.0), (x, y - sx * s * 0.42), bz + h * 0.5, "iron")
    b.box_bottom((s * 1.05, s * 1.05, 7.0), (x, y), bz + h, "iron")           # 顶盖
    if lit:
        b.box_bottom((s * 0.42, s * 0.42, h * 0.5), (x, y), bz + h * 0.22, "fire")


def pot(b, x=0.0, y=0.0, z=0.0, r=11.0, h=20.0, mat="stone_dark", plant=True,
        seed=0, foliage="foliage"):
    """陶罐/花盆：直口厚唇 + 两只小耳；`plant=True` 加一丛阔叶绿植。

    刻意不做成"锥形"——锥体在游戏尺寸下会被读成尖顶小帐篷（我踩过）。罐身用
    直筒 + 外翻厚唇，轮廓才有"罐"的读法。
    """
    rng = random.Random(seed)
    _ring(b, (x, y, z + h * 0.44), r * 0.86, h * 0.88, mat, 14, "Z", taper=1.02)
    _ring(b, (x, y, z + h * 0.88), r * 0.90, h * 0.12, mat, 14, "Z", taper=1.22)  # 口沿外翻
    for sx in (-1.0, 1.0):                                                       # 双耳
        b.box_bottom((4.0, 5.0, 9.0), (x + sx * r * 0.92, y), z + h * 0.68, mat)
    if plant:
        b.cylinder((x, y, z + h * 0.92), r * 0.82, 4.0, "cavity", 12)            # 盆土暗面
        for i in range(6):
            th = rng.uniform(0.0, math.pi * 2.0)
            rr = rng.uniform(0.0, r * 0.5)
            b.box((7.0, 7.0, 13.0),
                  (x + math.cos(th) * rr, y + math.sin(th) * rr, z + h + 9.0),
                  foliage, rot=(rng.uniform(-0.35, 0.35), rng.uniform(-0.35, 0.35), 0.0))


def planter(b, x=0.0, y=0.0, z=0.0, w=44.0, d=18.0, h=20.0, mat="wood",
            seed=0, foliage="foliage"):
    """长条花槽（窗台/墙根用）：木槽 + 一排阔叶。"""
    t = 5.0
    b.box_bottom((w, d, h), (x, y), z, mat)
    b.box_bottom((w, d * 0.86, h * 0.18), (x, y), z + h * 0.8, "cavity")   # 土面
    rng = random.Random(seed)
    n = max(2, int(w / 14.0))
    for i in range(n):
        px = x - w / 2.0 + (i + 0.5) * (w / n)
        for k in range(3):
            b.box((9.0, 9.0, 16.0),
                  (px + rng.uniform(-4.0, 4.0), y + rng.uniform(-3.0, 3.0),
                   z + h + 9.0), foliage,
                  rot=(rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), 0.0))


def ladder(b, x=0.0, y=0.0, z=0.0, h=110.0, w=22.0, mat="wood", lean=9.0):
    """木梯（两根边梁 + 横档），靠墙斜立。"""
    r = math.radians(lean)
    for sx in (-1.0, 1.0):
        b.box((5.0, 5.0, h), (x + sx * w / 2.0, y + math.sin(r) * h * 0.5, z + math.cos(r) * h / 2.0),
              mat, rot=(r, 0.0, 0.0))
    for i in range(int(h / 18.0)):
        zz = z + math.cos(r) * (12.0 + i * 18.0)
        yy = y + math.sin(r) * (12.0 + i * 18.0)
        b.box((w + 3.0, 4.0, 4.0), (x, yy, zz), mat)


# ================================================================ 运输/围挡

def cart(b, x=0.0, y=0.0, z=0.0, w=96.0, d=44.0, mat="wood", iron="iron",
         loaded=0, seed=0):
    """两轮木板车（辐条车轮 + 车厢 + 辕杆 + 载货）。

    车轮是"车"的辨认特征，必须做够大：轮径 60（≈0.79m，符合农用板车），并且
    **带轮辋 + 六根辐条**，否则缩到游戏尺寸只剩一个圆饼，会被读成"地上的圆木片"。
    """
    wr = 30.0
    hub = z + wr
    for sy in (-1.0, 1.0):
        wy = y + sy * (d * 0.54)
        _ring(b, (x - w * 0.20, wy, hub), wr * 0.86, 9.0, "wood_dark", 18, "Y")   # 轮板
        _ring(b, (x - w * 0.20, wy, hub), wr, 4.5, iron, 18, "Y")                 # 轮辋
        for k in range(6):                                                        # 辐条
            a = math.pi * k / 3.0
            b.box((wr * 0.70, 4.0, 5.0),
                  (x - w * 0.20 + math.cos(a) * wr * 0.46, wy,
                   hub + math.sin(a) * wr * 0.46), mat, rot=(0.0, a, 0.0))
        _ring(b, (x - w * 0.20, wy, hub), 7.0, 12.0, "iron", 10, "Y")             # 轮毂
    b.box_bottom((w, d, 9.0), (x, y), z + wr - 4.0, mat)                          # 车厢底
    for sx in (-1.0, 1.0):                                                        # 侧板
        b.box_bottom((9.0, d, 26.0), (x + sx * (w / 2.0 - 4.5), y), z + wr + 5.0, mat)
    b.box_bottom((w, 9.0, 26.0), (x, y + d / 2.0 - 4.5), z + wr + 5.0, mat)       # 后板
    b.box_bottom((w, 9.0, 16.0), (x, y - d / 2.0 + 4.5), z + wr + 5.0, mat)       # 前板（矮）
    for sx in (-1.0, 1.0):                                                        # 辕杆
        b.box((w * 0.52, 7.0, 7.0), (x + (w / 2.0 + w * 0.24), y + sx * d * 0.30,
                                     z + wr + 1.0), mat)
    b.box_bottom((11.0, d * 0.64, 10.0), (x + w / 2.0 + w * 0.48, y), z + wr, mat)  # 横把手
    rng = random.Random(seed)
    if loaded:
        n = max(1, loaded)
        for i in range(n):
            px = x - w * 0.32 + (i * (w * 0.64 / (n - 1)) if n > 1 else 0.0)
            if i % 2 == 0:
                crate(b, px, y + rng.uniform(-3.0, 3.0), z + wr + 5.0, s=27.0, h=23.0)
            else:
                sack(b, px, y + rng.uniform(-3.0, 3.0), z + wr + 5.0, r=12.0, h=26.0)


def wheelbarrow(b, x=0.0, y=0.0, z=0.0, mat="wood"):
    """独轮小推车。"""
    _ring(b, (x + 26.0, y, z + 15.0), 15.0, 6.0, mat, 14, "Y")
    b.box_bottom((50.0, 30.0, 7.0), (x, y), z + 20.0, mat)
    for sx in (-1.0, 1.0):
        b.box_bottom((6.0, 30.0, 15.0), (x + sx * 25.0, y), z + 6.0, mat)
    b.box_bottom((48.0, 6.0, 15.0), (x, y + 12.0), z + 6.0, mat)
    for sx in (-1.0, 1.0):
        b.box((44.0, 5.0, 5.0), (x - 38.0, y + sx * 9.0, z + 26.0), mat)
    b.box_bottom((16.0, 16.0, 5.0), (x + 46.0, y), z + 40.0, mat)


def fence(b, x0, x1, y=0.0, z=0.0, h=54.0, posts=None, mat="wood",
          wattle=False, seed=0, x=0.0):
    """栅栏：默认横杆式（立柱 + 两道横杆），`wattle=True` 编条篱（铁匠铺/田园感）。

    x 为整段平移量（挂载调度用统一站位），x0/x1 是相对跨度。
    """
    x0 = x0 + x
    x1 = x1 + x
    span = abs(x1 - x0)
    if posts is None:
        posts = max(2, int(round(span / 46.0)) + 1)
    rng = random.Random(seed)
    xs = [x0 + (x1 - x0) * (float(i) / (posts - 1)) for i in range(posts)]
    for px in xs:
        b.box_bottom((8.0, 8.0, h + 4.0), (px, y), z, mat)
    if wattle:
        n = int(span / 11.0)
        for i in range(n):
            wx = x0 + (x1 - x0) * ((i + 0.5) / n)
            b.box((span / n + 3.0, 6.0, 5.0), (wx, y, z + h * (0.28 + 0.44 * (i % 2))), mat,
                  rot=(0.0, rng.uniform(-0.10, 0.10), 0.0))
    else:
        for t in (0.45, 0.82):
            b.box((span, 6.0, 7.0), ((x0 + x1) / 2.0, y, z + h * t), mat)
    return {"span": span}


def banner(b, x=0.0, y=0.0, z=0.0, w=26.0, h=54.0, mat="tile", pole=True):
    """垂幡（染色布面 + 上下压条 + 可选挑杆）。

    布面用**染色**（`tile` 是暗砖红、`brick` 是暖橙红）而不是 `canvas` —— 麻布本色
    是灰白，挂出来读成"灰床单"。旗帜是中世纪街景最省钱的"有人味"信号。
    """
    if pole:
        b.box_bottom((6.0, 6.0, h + 22.0), (x, y), z - 12.0, "wood_dark")
        b.box((w + 10.0, 6.0, 6.0), (x, y - w * 0.35 + 3.0, z + h + 6.0), "wood_dark")
    b.box((w, 4.0, h), (x, y, z + h * 0.5), mat)
    b.box((w * 0.55, 2.5, h * 0.72), (x, y - 2.5, z + h * 0.54), "brick")   # 中条徽记
    b.box_bottom((w + 4.0, 6.0, 5.0), (x, y), z + h - 2.0, "iron")
    b.box_bottom((w + 4.0, 6.0, 5.0), (x, y), z, "iron")


def clothesline(b, x0, x1, y=0.0, z=100.0, items=3, seed=0, x=0.0):
    """晾衣绳（两端绑墙 + 挂布）；x 为整段平移量，x0/x1 是相对跨度。

    挂布用**染色布**（tile/brick/canvas 三种交错）——一律麻布本色会读成一片灰床单。
    """
    x0 = x0 + x
    x1 = x1 + x
    b.box((abs(x1 - x0), 2.5, 2.5), ((x0 + x1) / 2.0, y, z), "wood_dark")
    rng = random.Random(seed)
    cloths = ("canvas", "tile", "brick", "plaster_old")
    for i in range(items):
        px = x0 + (x1 - x0) * ((i + 1.0) / (items + 1.0))
        w = rng.uniform(20.0, 34.0)
        hh = rng.uniform(28.0, 48.0)
        b.box((w, 3.0, hh), (px, y, z - hh / 2.0), cloths[i % len(cloths)])


def well(b, x=0.0, y=0.0, z=0.0, r=26.0, mat="stone_dark", roof=True):
    """水井（石圈 + 双柱 + 顶棚 + 吊绳吊桶）。"""
    _ring(b, (x, y, z + 16.0), r, 32.0, mat, 16, "Z")
    _ring(b, (x, y, z + 31.0), r * 0.86, 4.0, "glass", 16)              # 井口暗
    for sx in (-1.0, 1.0):
        b.box_bottom((8.0, 8.0, 76.0), (x + sx * r * 0.82, y), z + 32.0, "timber")
    if roof:
        b.box((r * 2.3, r * 1.9, 7.0), (x, y, z + 112.0), "wood_dark")
        _ring(b, (x, y, z + 124.0), r * 1.02, 18.0, "thatch", 12, "Z", taper=0.1)
    b.cylinder((x, y, z + 100.0), 2.2, 22.0, "wood_dark", 8, "Z")
    bucket(b, x, y, z + 74.0, r=8.0, h=16.0)


def grind_post(b, x=0.0, y=0.0, z=0.0, mat="wood"):
    """拴马桩/系物桩。"""
    b.box_bottom((11.0, 11.0, 84.0), (x, y), z, mat)
    b.box_bottom((15.0, 15.0, 8.0), (x, y), z + 76.0, mat)
    b.box((26.0, 5.0, 5.0), (x, y, z + 70.0), "iron")


def hay_fork(b, x=0.0, y=0.0, z=0.0):
    """干草叉（柄 + 三齿）斜靠墙。"""
    b.box((4.5, 4.5, 82.0), (x, y, z + 41.0), "wood", rot=(math.radians(-12.0), 0.0, 0.0))
    for i in range(3):
        b.box((3.0, 3.0, 22.0), (x + (i - 1) * 6.0, y + 5.0, z + 88.0), "iron",
              rot=(math.radians(-12.0), 0.0, 0.0))


# ================================================================ 立面挂载

def flower_box(b, x=0.0, y=0.0, z=0.0, w=40.0, mat="wood", seed=0):
    """窗台花箱（挂在窗下沿）。"""
    b.box_bottom((w, 15.0, 14.0), (x, y), z, mat)
    b.box_bottom((w - 4.0, 12.0, 3.0), (x, y), z + 11.0, "thatch_old")
    rng = random.Random(seed)
    for i in range(int(w / 9.0)):
        px = x - w / 2.0 + (i + 0.5) * (w / max(1, int(w / 9.0)))
        b.box((5.0, 5.0, 11.0), (px, y + rng.uniform(-2.0, 2.0), z + 15.0), "thatch",
              rot=(rng.uniform(-0.25, 0.25), rng.uniform(-0.25, 0.25), 0.0))


def rope_coil(b, x=0.0, y=0.0, z=0.0, r=12.0, mat="canvas"):
    """成盘缆绳。"""
    for k in range(3):
        _ring(b, (x, y, z + 5.0 + k * 5.0), r - k * 0.9, 4.5, mat, 14)


def mooring_post(b, x=0.0, y=0.0, z=0.0):
    """码头系缆桩（铁环 + 木桩）。"""
    b.box_bottom((14.0, 14.0, 46.0), (x, y), z, "timber")
    b.box_bottom((18.0, 18.0, 7.0), (x, y), z + 40.0, "wood_dark")
    _ring(b, (x, y, z + 33.0), 10.0, 4.0, "iron", 12, "X")


# ================================================================ 二轮：市集/民生道具
#
# 尺寸纪律（与既有 34 件一致）
# ------------------------------
# * 一律按**现实尺寸**建模（1 世界单位 ≈ 1.31cm，1 格 = 32 单位 = 0.42m），
#   挂载时由 `GAME_SCALE` 统一放大到"游戏尺寸可辨"。
# * 只有 r/h/w/d/s 能当主尺寸参数 —— `dress()` 的缩放**只认这五个键**；其余内部
#   尺寸必须从主尺寸派生（`fx = w * 0.42` 之类），否则放大后比例会走形。
# * 复合道具内部调用的子道具（筐、桶、箱）也要按同一比例派生尺寸，否则会出现
#   "放大的摊子上摆着没放大的菜筐"。

def _euler_to(dx, dy, dz):
    """把"局部 +Z 指向 d"的欧拉角解出来（XYZ 序，rz=0）—— 斜腿/斜撑/辕杆用。"""
    ln = math.sqrt(dx * dx + dy * dy + dz * dz) or 1.0
    dx, dy, dz = dx / ln, dy / ln, dz / ln
    rx = math.asin(max(-1.0, min(1.0, -dy)))
    cx = math.cos(rx)
    if abs(cx) < 1e-6:
        return (rx, 0.0, 0.0)
    return (rx, math.atan2(dx / cx, dz / cx), 0.0)


def _strut(b, p0, p1, size, mat, thick=None):
    """两点之间的一根方料（斜腿/斜撑/吊臂/辕杆）—— 免得手算欧拉角。

    `buildings.Builder.box` 只吃轴对齐或欧拉旋转的盒子，斜构件一律靠这个包一层。
    """
    dx, dy, dz = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
    ln = math.sqrt(dx * dx + dy * dy + dz * dz)
    if ln < 1e-6:
        return
    b.box((size, size if thick is None else thick, ln),
          ((p0[0] + p1[0]) / 2.0, (p0[1] + p1[1]) / 2.0, (p0[2] + p1[2]) / 2.0),
          mat, rot=_euler_to(dx, dy, dz))


def _open_vat(b, x=0.0, y=0.0, z=0.0, r=26.0, h=26.0, mat="wood", seg=16, t=None,
              water=None, band=None, inner="cavity"):
    """**开口**圆盆/圆缸：一圈切向壁板 + 内腔底 + 可选液面 + 可选铁箍。

    为什么不能用 `cylinder`：Builder 的柱体**两头都封盖**，顶盖会把内腔与液面全盖住，
    "敞口容器"就死了。所以壁板必须由 seg 块切向薄板拼（微俯视下能看见的恰好是
    "壁顶一圈 + 内腔暗面 + 液面"这三层）。`trough()` 用四块方板是因为它是方的。
    """
    t = t if t is not None else max(3.0, r * 0.16)
    chord = 2.0 * math.pi * (r - t * 0.5) / seg + 1.6
    for i in range(seg):
        a = 2.0 * math.pi * (i + 0.5) / seg
        cx = x + math.cos(a) * (r - t * 0.5)
        cy = y + math.sin(a) * (r - t * 0.5)
        b.box((t, chord, h), (cx, cy, z + h * 0.5), mat, rot=(0.0, 0.0, a))
    b.cylinder((x, y, z + t * 0.6), r - t, t, inner, seg, "Z")          # 内腔底（暗）
    if water is not None:
        b.cylinder((x, y, z + h - 1.0), r - t * 1.25, 2.0, water, seg)  # 液面
    else:
        b.cylinder((x, y, z + h - 1.6), r - t * 1.15, 1.6, inner, seg)
    if band is not None:
        _ring(b, (x, y, z + h * band), r + 0.6, 3.4, "iron", seg)
    return {"r": r, "h": h}


def _cloth_over_rim(b, x, y, z, r, h, cloth, rng, width=None):
    """一块布搭在缸/盆沿上（缸口一段 + 外垂到地 + 内搭一段）——"有人在干活"的信号。"""
    w = width if width else r * 1.5
    y0 = y - r * 0.55
    b.box((w, r * 0.95, 4.0), (x, y0, z + h + 1.5), cloth)                     # 搭在缸口
    b.box((w, 4.5, h * 1.28), (x, y0 - r * 0.52, z + h * 0.64), cloth,
          rot=(math.radians(-8.0), 0.0, 0.0))                                  # 外垂到地
    b.box((w * 0.78, 4.0, h * 0.46), (x, y0 + r * 0.38, z + h * 0.80), cloth,
          rot=(math.radians(14.0), 0.0, 0.0))                                  # 内搭一段
    b.box((w * 1.02, 3.0, 5.0), (x, y0, z + h - 1.0), cloth if rng.random() < 0.5
          else "cloth_ochre")                                                  # 缸口垂下的褶


def _hen(b, x=0.0, y=0.0, z=0.0, s=1.0, mat="canvas"):
    """母鸡（卵形身 + 竖颈 + 头 + 红冠 + 上翘尾）：3~4 只在笼边走动，"有人养"的信号。

    游戏尺寸下只有 ~30px，所以**不做腿**（细腿会读成"小桌子"）；比例必须是
    "**长 > 高**的卵形身"（第一轮做成半径≈半长的球体，缩下去读成一朵白花）。
    体色用暖白/暖褐的织物材质（`canvas` / `cloth_ochre`）——在这个尺度它们就是
    "一块暖色羽毛"；不要用 `plaster_old`（冷灰会读成石头）。
    """
    _ring(b, (x, y, z + 8.5 * s), 7.6 * s, 26.0 * s, mat, 10, "X", taper=0.62)   # 身
    b.box_bottom((16.0 * s, 13.0 * s, 4.0 * s), (x - 1.0 * s, y), z, mat)        # 腹底（落地）
    b.box((6.0 * s, 6.0 * s, 11.0 * s), (x + 10.0 * s, y, z + 15.0 * s), mat,
          rot=(0.0, math.radians(-16.0), 0.0))                                   # 颈
    b.cylinder((x + 13.0 * s, y, z + 21.0 * s), 5.0 * s, 9.0 * s, mat, 8, "X")   # 头
    b.box_bottom((3.6 * s, 3.6 * s, 4.0 * s), (x + 13.0 * s, y), z + 24.0 * s,
                 "cloth_red")                                                    # 冠
    b.box((3.0 * s, 2.8 * s, 3.0 * s), (x + 18.0 * s, y, z + 19.5 * s), "produce_root",
          rot=(0.0, math.radians(12.0), 0.0))                                    # 喙
    b.box((11.0 * s, 2.6 * s, 6.0 * s), (x - 14.0 * s, y, z + 15.0 * s), mat,
          rot=(0.0, math.radians(-38.0), 0.0))                                   # 翘尾


def _fish(b, x=0.0, y=0.0, z=0.0, ln=34.0, r=7.0, mat="fish", seed=0):
    """一条鱼（头朝 -X）：两节纺锤身 + 浅色腹线 + 背/胸/尾鳍 + 两眼（湿光靠材质）。

    鱼在游戏尺寸下是一条 ~50px 的横条，读法全靠三件事：**纺锤轮廓 + 浅腹（与深色
    背一撞）+ 鳍的碎边**；三者缺一就会被读成"一坨灰纸"。
    """
    cz = z + r * 0.98
    _ring(b, (x + ln * 0.26, y, cz), r, ln * 0.48, mat, 10, "X", taper=0.34)     # 后段（收尾）
    _ring(b, (x - ln * 0.25, y, cz), r * 0.86, ln * 0.50, mat, 10, "X", taper=0.78)  # 前段（头）
    b.box((ln * 0.66, r * 1.15, r * 0.26), (x - ln * 0.05, y, cz - r * 0.80), "canvas")
    b.box((ln * 0.30, 2.0, r * 0.72), (x - ln * 0.02, y, cz + r * 0.94), mat,
          rot=(0.0, math.radians(-16.0), 0.0))                                   # 背鳍
    for sz in (1.0, -1.0):
        b.box((ln * 0.20, 2.0, r * 0.92), (x + ln * 0.55, y, cz + sz * r * 0.60), mat,
              rot=(0.0, math.radians(38.0 * sz), 0.0))                           # 尾鳍
    b.box((ln * 0.16, 2.5, r * 0.55), (x - ln * 0.14, y, cz - r * 0.40), mat,
          rot=(0.0, math.radians(22.0), 0.0))                                    # 胸鳍
    for sy in (-1.0, 1.0):
        b.cylinder((x - ln * 0.40, y + sy * r * 0.78, cz + r * 0.26), r * 0.20, 2.0,
                   "iron", 8, "Y")                                               # 眼
    _ = seed


def _jug(b, x=0.0, y=0.0, z=0.0, r=17.0, h=30.0, mat="clay"):
    """双耳细颈瓶（酒/油/水）：鼓腹 + 收肩 + 细颈 + 外翻口 + 双耳。"""
    _ring(b, (x, y, z + h * 0.30), r * 0.90, h * 0.60, mat, 14, "Z", taper=1.08)
    _ring(b, (x, y, z + h * 0.68), r * 0.98, h * 0.24, mat, 14, "Z", taper=0.64)
    b.cylinder((x, y, z + h * 0.86), r * 0.46, h * 0.22, mat, 12)
    _ring(b, (x, y, z + h * 0.98), r * 0.60, h * 0.07, mat, 12)
    for sx in (-1.0, 1.0):
        b.box_bottom((5.0, 4.0, h * 0.34), (x + sx * r * 0.84, y), z + h * 0.50, mat)


def _basket_load(b, x, y, z_top, r, mat, seed, n=7, k=None):
    """筐面堆货（叶菜/根菜/鱼）：在筐口之上堆一坨，破掉"空筐"的读法。"""
    rng = random.Random(seed)
    k = k if k else r * 0.52
    for i in range(n):
        th = rng.uniform(0.0, math.pi * 2.0)
        rad = rng.uniform(0.0, r * 0.46)
        b.box((k, k, k * 0.72),
              (x + math.cos(th) * rad, y + math.sin(th) * rad,
               z_top + k * 0.32 + rng.uniform(0.0, k * 0.26)),
              mat, rot=(rng.uniform(-0.35, 0.35), rng.uniform(-0.35, 0.35), th))


def basket(b, x=0.0, y=0.0, z=0.0, r=19.0, h=19.0, mat="wicker", rim="wood_light",
           handle=False, bottom=True):
    """柳条筐：敞口微外翻 + 口沿加固圈 + 可选提梁。"""
    _ring(b, (x, y, z + h * 0.47), r * 0.80, h * 0.94, mat, 14, "Z", taper=1.22)
    _ring(b, (x, y, z + h * 0.93), r * 1.04, h * 0.16, rim, 14)
    if bottom:
        b.cylinder((x, y, z + 2.0), r * 0.76, 3.0, rim, 12)
    if handle:
        for sx in (-1.0, 1.0):
            b.box((4.5, 5.0, h * 0.70), (x + sx * r * 0.88, y, z + h * 0.80), mat)
        b.box((r * 1.76, 5.0, 5.0), (x, y, z + h * 1.14), mat)


def produce_baskets(b, x=0.0, y=0.0, z=0.0, r=19.0, h=19.0, seed=0):
    """菜筐堆：两只落地筐 + 一只叠在上面，筐面堆叶菜/根菜。"""
    basket(b, x - r * 1.05, y, z, r=r, h=h)
    _basket_load(b, x - r * 1.05, y, z + h * 0.88, r, "produce", seed + 1)
    basket(b, x + r * 1.05, y - 2.0, z, r=r * 0.95, h=h * 0.95)
    _basket_load(b, x + r * 1.05, y - 2.0, z + h * 0.90, r * 0.95, "produce_root", seed + 2)
    basket(b, x - r * 1.05, y + 1.0, z + h, r=r * 0.86, h=h * 0.84, handle=True)
    _basket_load(b, x - r * 1.05, y + 1.0, z + h + h * 0.80, r * 0.86, "produce",
                 seed + 3, n=5)


def market_stall(b, x=0.0, y=0.0, z=0.0, w=170.0, d=88.0, h=165.0, mat="timber",
                 cloth="cloth_ochre", goods=True, seed=0):
    """市集摊：四柱 + 前柜台（布围裙 + 台面货）+ 前低后高的斜布篷 + 前缘布幔 + 摊下堆货。

    正面 = -Y。三条经验值（都是"从正面看会不会穿帮"倒推的，不要随手改）：
      ① **篷前缘必须高过台面货在屏幕上的顶**：相机俯角 20°，篷前缘（在 y 更靠前处）
         下垂的布幔会遮住它身后的台面货 —— 所以前柱取 `h*0.88`、布幔只挂 14 左右，
         台面货高度压到 `h*0.20` 以内，屏幕上前者才始终在后者上方。
      ② **布篷要压得住柜台**：后柱 h、前柱 h*0.88，前后落差 20~25 单位，
         在 20° 俯角下算下来正好能看见布面（再平就压成一条线）。
      ③ **台前不做整片木板墙**：一块落地木墙会把摊子读成"棚屋"；改成布围裙
         （垂到台面下 ~55%）+ 露出的台腿与摊下堆货，"摊"的读法才成立。
    """
    rng = random.Random(seed)
    fx = w / 170.0                      # dress() 只缩放主尺寸，内部小件按此比例跟随
    pw = 9.0 * fx
    x0, x1 = x - w / 2.0 + pw * 0.6, x + w / 2.0 - pw * 0.6
    yb, yf = y + d / 2.0 - pw * 0.6, y - d / 2.0 + pw * 0.6
    pf = h * 0.88                                                               # 前柱高
    for px in (x0, x1):
        for (py, ph) in ((yb, h), (yf, pf)):
            b.box_bottom((pw, pw, ph), (px, py), z, mat)
    b.box((w + 6.0 * fx, 7.0 * fx, 7.0 * fx), (x, yb, z + h - 12.0 * fx), mat)     # 后梁
    b.box((w + 6.0 * fx, 6.0 * fx, 6.0 * fx), (x, yf, z + pf - 9.0 * fx), mat)     # 前梁
    for px in (x0, x1):                                                            # 侧向斜撑
        _strut(b, (px, yb, z + h - 12.0 * fx), (px, yf, z + pf - 9.0 * fx),
               6.0 * fx, mat)
    # 布篷（前低后高）+ 前后压条 + 前缘布幔
    cz_top = z + h - 6.0 * fx
    cz_bot = z + pf - 4.0 * fx
    y_a, y_b = yb, yf - 18.0 * fx
    rx = math.atan2(cz_top - cz_bot, y_a - y_b)
    ln = math.hypot(y_a - y_b, cz_top - cz_bot)
    b.box((w + 16.0 * fx, ln, 3.0 * fx), (x, (y_a + y_b) / 2.0, (cz_top + cz_bot) / 2.0),
          cloth, rot=(rx, 0.0, 0.0))
    b.box((w + 17.0 * fx, 5.0 * fx, 5.0 * fx), (x, y_a, cz_top + 2.0 * fx), mat)
    b.box((w + 17.0 * fx, 4.0 * fx, 4.0 * fx), (x, y_b, cz_bot - 1.0 * fx), mat)
    nf = max(3, int(w / 42.0))
    for i in range(nf):
        fw = (w + 14.0 * fx) / nf - 5.0 * fx
        fxp = x - (w + 14.0 * fx) / 2.0 + (i + 0.5) * ((w + 14.0 * fx) / nf)
        fh = (14.0 + rng.uniform(-3.0, 4.0)) * fx
        b.box((fw, 3.0 * fx, fh), (fxp, y_b - 0.5 * fx, cz_bot - fh * 0.5 - 2.0 * fx), cloth)
    # 柜台（台面 + 布围裙 + 台腿）
    ct_h = h * 0.42
    ct_w = w - 12.0 * fx
    ct_d = d * 0.62
    cy = y - d * 0.10
    b.box_bottom((ct_w, ct_d, 8.0 * fx), (x, cy), z + ct_h, mat)
    b.box_bottom((ct_w + 4.0 * fx, 5.0 * fx, 5.0 * fx), (x, cy - ct_d / 2.0 + 2.0 * fx),
                 z + ct_h + 8.0 * fx, mat)                                      # 台沿
    b.box((ct_w, 3.5 * fx, ct_h * 0.55), (x, cy - ct_d / 2.0 - 2.0 * fx,
                                          z + ct_h - ct_h * 0.28), cloth)       # 布围裙
    b.box_bottom((ct_w - 10.0 * fx, ct_d * 0.78, 4.0 * fx), (x, cy), z + ct_h * 0.42, "wood")
    for sx in (-1.0, 1.0):
        b.box_bottom((7.0 * fx, ct_d, ct_h), (x + sx * (ct_w / 2.0 - 6.0 * fx), cy),
                     z + 2.0 * fx, mat)
    # 台面货（高度压在 h*0.20 以内，否则会在屏幕上顶到前缘布幔）
    if goods:
        top = z + ct_h + 8.0 * fx
        if w >= 140.0:
            basket(b, x - ct_w * 0.30, cy, top, r=16.0 * fx, h=14.0 * fx)
            _basket_load(b, x - ct_w * 0.30, cy, top + 12.0 * fx, 15.0 * fx, "produce",
                         seed + 5, n=6, k=8.0 * fx)
            crate(b, x + ct_w * 0.06, cy + 2.0 * fx, top, s=28.0 * fx, h=22.0 * fx)
            _basket_load(b, x + ct_w * 0.06, cy + 2.0 * fx, top + 20.0 * fx, 17.0 * fx,
                         "produce_root", seed + 6, n=6, k=8.0 * fx)
            basket(b, x + ct_w * 0.36, cy, top, r=14.0 * fx, h=13.0 * fx)
            _basket_load(b, x + ct_w * 0.36, cy, top + 11.0 * fx, 13.0 * fx, "bread",
                         seed + 7, n=5, k=9.0 * fx)
        else:
            basket(b, x - ct_w * 0.24, cy, top, r=16.0 * fx, h=14.0 * fx)
            _basket_load(b, x - ct_w * 0.24, cy, top + 12.0 * fx, 15.0 * fx, "produce",
                         seed + 5, n=6, k=8.0 * fx)
            crate(b, x + ct_w * 0.26, cy + 2.0 * fx, top, s=26.0 * fx, h=20.0 * fx)
    sack(b, x - ct_w * 0.34, cy + 6.0 * fx, z, r=11.0 * fx, h=26.0 * fx)
    barrel(b, x + ct_w * 0.36, cy + 4.0 * fx, z, r=12.0 * fx, h=34.0 * fx, bands=2)


def market_table(b, x=0.0, y=0.0, z=0.0, w=120.0, d=60.0, h=62.0, mat="wood",
                 cloth="cloth_blue", goods="produce", seed=0):
    """市集案桌（搁凳 + 台板 + 桌裙 + 台面货）：可单摆，也可摆在摊篷下。

    `goods`：`produce` 菜果 / `cheese` 奶酪（圆形酪轮 + 案板 + 刀）。
    """
    rng = random.Random(seed)
    fw = w / 120.0
    b.box_bottom((w, d, 7.0 * fw), (x, y), z + h, mat)
    b.box_bottom((w - 6.0 * fw, d - 6.0 * fw, 4.0 * fw), (x, y), z + h - 9.0 * fw, mat)
    for sx in (-1.0, 1.0):
        b.box_bottom((9.0 * fw, d - 8.0 * fw, h - 4.0 * fw),
                     (x + sx * (w / 2.0 - 10.0 * fw), y), z + 2.0 * fw, "timber")
        b.box_bottom((7.0 * fw, 6.0 * fw, 30.0 * fw),
                     (x + sx * (w / 2.0 - 10.0 * fw), y - d / 2.0 + 4.0 * fw), z, "timber")
    b.box_bottom((w - 26.0 * fw, 5.0 * fw, 5.0 * fw), (x, y), z + h * 0.40, "timber")
    b.box((w + 5.0 * fw, 4.0 * fw, 30.0 * fw), (x, y - d / 2.0 - 1.0 * fw, z + h - 22.0 * fw),
          cloth)                                                            # 桌裙
    top = z + h + 7.0 * fw
    if goods == "cheese":
        for (dx, rr, hh) in ((-w * 0.30, 17.0, 9.0), (-w * 0.10, 15.0, 8.0), (w * 0.14, 13.0, 8.0)):
            _ring(b, (x + dx * fw, y, top + rr * 0.9 * fw), rr * 0.9 * fw, hh * fw,
                  "bread", 14, "Y")
        b.box_bottom((w * 0.30, 12.0 * fw, 5.0 * fw), (x + w * 0.33, y - 2.0 * fw), top,
                     "wood_light")
        b.box((24.0 * fw, 3.0 * fw, 13.0 * fw), (x + w * 0.33, y - 10.0 * fw,
                                                top + 11.0 * fw), "iron")     # 酪刀
    else:
        basket(b, x - w * 0.30, y, top, r=16.0 * fw, h=15.0 * fw)
        _basket_load(b, x - w * 0.30, y, top + 13.0 * fw, 16.0 * fw, "produce", seed + 1, n=6)
        basket(b, x + w * 0.30, y, top, r=15.0 * fw, h=14.0 * fw)
        _basket_load(b, x + w * 0.30, y, top + 12.0 * fw, 15.0 * fw, "produce_root",
                     seed + 2, n=6)
        _jug(b, x + w * 0.06, y + 6.0 * fw, top, r=12.0 * fw, h=22.0 * fw)
        for i in range(2):
            b.box((10.0 * fw, 10.0 * fw, 9.0 * fw),
                  (x - w * 0.08 + i * 12.0 * fw, y - 10.0 * fw, top + 4.0 * fw),
                  "bread", rot=(rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), 0.0))


def awning(b, x=0.0, y=0.0, z=0.0, w=140.0, cloth="cloth_red",
           arms="iron", valance=4):
    """纯布篷（挂立面）：墙面横梁 + 两根斜撑杆 + 斜布面 + 前缘不等长布幔。

    y = 墙面（贴面件由 `dress()` 给 `front_y - 4`）。布面向 -Y 伸出 `w*0.42`，
    靠墙侧高、外缘低 —— 微俯视下能看见布面，不会被压成一条线（§8.1）。

    布幔**必须同色**：两色交替会被读成"一块块方盒"而不是垂布（一轮踩过）。
    布幔之间留缝、长度不一、上缘压一道深色条，"垂布"的读法才立得住。
    """
    proj = w * 0.42
    drop = w * 0.20
    z_top = z + drop
    y0, y1 = y, y - proj
    b.box((w, 7.0, 7.0), (x, y - 3.0, z_top), "timber")                        # 墙面横梁
    for sx in (-1.0, 1.0):                                                     # 斜撑杆
        _strut(b, (x + sx * (w / 2.0 - 6.0), y0 - 2.0, z_top),
               (x + sx * (w / 2.0 - 6.0), y1 + 4.0, z + 2.0), 5.5, arms)
    rx = math.atan2(drop, y0 - y1)
    ln = math.hypot(y0 - y1, drop)
    b.box((w + 12.0, ln, 3.0), (x, (y0 + y1) / 2.0, (z_top + z) / 2.0), cloth,
          rot=(rx, 0.0, 0.0))
    b.box((w + 13.0, 5.0, 5.0), (x, y0 - 2.0, z_top + 2.0), "timber")          # 靠墙压条
    b.box((w + 13.0, 4.0, 4.0), (x, y1 + 2.0, z), "timber")                    # 外缘压条
    n = max(2, int(valance))
    for i in range(n):
        fw = (w + 10.0) / n - w * 0.035
        fxp = x - (w + 10.0) / 2.0 + (i + 0.5) * ((w + 10.0) / n)
        fh = w * 0.14 * (1.0 + 0.26 * ((i % 2) * 2 - 1))
        b.box((fw, 3.0, fh), (fxp, y1 + 1.5, z - fh * 0.5 - 1.0), cloth)
        b.box((fw + 1.5, 4.0, 4.0), (fxp, y1 + 2.5, z - 2.0), "timber")         # 幔上压条


def hanging_sign(b, x=0.0, y=0.0, z=0.0, w=48.0, h=38.0, arm=None, mat="wood_dark",
                 iron="iron", board_mat="cloth_red", emblem=True, swing=0.0):
    """铁艺挂招牌（贴面）：墙面铁座 + 挑臂 + 卷草 + 吊环 + 木牌（可带彩绘牌面）。

    与 `signboard`（旧）的分工：那个是"铁支架 + 木牌"的通用款；这个专做**铁艺挑臂
    挂招牌**（锻铁卷草 + 双吊环 + 彩绘牌面），市集/店铺立面用它才有中世纪街味。
    """
    arm = arm if arm else w * 1.25
    b.box_bottom((10.0, 6.0, h * 1.30), (x, y - 2.0), z - 4.0, iron)           # 墙面竖座
    for k in range(3):
        b.box_bottom((14.0, 9.0, 5.0), (x, y - 3.0), z - 2.0 + k * (h * 0.55), iron)
    _strut(b, (x, y - 3.0, z + h * 1.05), (x, y - arm, z + h * 0.86), 6.0, iron)  # 挑臂（略上翘）
    b.box((6.0, 6.0, 15.0), (x, y - arm * 0.93, z + h * 0.86), iron)
    _ring(b, (x, y - arm * 0.60, z + h * 0.76), 7.5, 4.5, iron, 10, "Y")        # 卷草
    _strut(b, (x, y - arm * 0.66, z + h * 0.80), (x, y - arm * 0.30, z + h * 0.28),
           4.5, iron)                                                           # 斜拉杆
    for sx in (-1.0, 1.0):                                                      # 吊环
        b.box_bottom((3.4, 3.4, 10.0), (x + sx * (w * 0.30), y - arm * 0.86),
                     z + h * 0.60, iron)
    b.box((w, 4.0, h), (x, y - arm * 0.96, z + h * 0.06), mat,
          rot=(0.0, math.radians(swing), 0.0))
    b.box((w + 5.0, 6.0, 4.5), (x, y - arm * 0.96, z + h * 0.52), iron)
    b.box((w + 5.0, 6.0, 4.5), (x, y - arm * 0.96, z - h * 0.44), iron)
    if emblem:
        b.box((w * 0.56, 3.0, h * 0.56), (x, y - arm * 0.96 - 3.6, z + h * 0.04), board_mat)


def standing_board(b, x=0.0, y=0.0, z=0.0, w=44.0, h=66.0, mat="wood",
                   panel="white_stone"):
    """A 字招牌：两块斜立板 + 顶部铁铰 + 白色板面（摊前/店门口的招揽牌）。"""
    for sy in (-1.0, 1.0):
        for sx in (-1.0, 1.0):
            _strut(b, (x + sx * w * 0.44, y + sy * 3.0, z + 2.0),
                   (x + sx * w * 0.10, y + sy * 12.0, z + h), 4.5, mat)
        b.box((w * 0.94, 5.0, h * 0.86), (x, y + sy * 9.0, z + h * 0.48), mat,
              rot=(math.radians(9.0 * sy), 0.0, 0.0))
    b.box((w * 0.74, 3.0, h * 0.56), (x, y - 11.5, z + h * 0.55), panel,
          rot=(math.radians(-9.0), 0.0, 0.0))
    b.box((w * 0.9, 6.0, 6.0), (x, y, z + h - 2.0), "iron")


def fish_table(b, x=0.0, y=0.0, z=0.0, w=110.0, d=52.0, h=60.0, mat="wood", seed=0):
    """鱼摊案板：厚案板 + 三条约 0.45m 的鱼 + 鱼刀 + 台下鱼篓与提桶。"""
    fw = w / 110.0
    b.box_bottom((w, d, 9.0 * fw), (x, y), z + h, "wood_light")               # 厚案板
    b.box_bottom((w + 8.0 * fw, 6.0 * fw, 6.0 * fw), (x, y - d / 2.0 + 3.0 * fw),
                 z + h + 9.0 * fw, "wood")
    for sx in (-1.0, 1.0):
        b.box_bottom((10.0 * fw, d - 10.0 * fw, h - 6.0 * fw),
                     (x + sx * (w / 2.0 - 12.0 * fw), y), z, "timber")
    b.box_bottom((w - 20.0 * fw, d - 16.0 * fw, 5.0 * fw), (x, y), z + h * 0.52, "timber")
    basket(b, x - w * 0.30, y, z + h * 0.52 + 5.0 * fw, r=15.0 * fw, h=14.0 * fw)
    _basket_load(b, x - w * 0.30, y, z + h * 0.52 + 19.0 * fw, 15.0 * fw, "fish", seed + 1, n=5)
    bucket(b, x + w * 0.33, y + 2.0 * fw, z + h * 0.52 + 5.0 * fw,
           r=9.0 * fw, h=18.0 * fw)
    top = z + h + 9.0 * fw
    for i in range(3):
        _fish(b, x - w * 0.30 + i * (w * 0.30), y - 9.0 * fw + i * 7.0 * fw, top,
              ln=w * 0.40, r=w * 0.082, seed=seed + i)
    b.box((30.0 * fw, 3.0 * fw, 15.0 * fw), (x + w * 0.44, y + 12.0 * fw, top + 14.0 * fw),
          "iron")                                                              # 鱼刀
    b.box_bottom((26.0 * fw, 16.0 * fw, 8.0 * fw), (x - w * 0.46, y + 9.0 * fw),
                 top, "white_stone")                                           # 盐箱


def pottery_row(b, x=0.0, y=0.0, z=0.0, n=5, r=17.0, h=30.0, mat="clay", seed=0):
    """陶器摊：一列大小不一的陶罐/双耳瓶 + 一只侧倒（破掉"一排站桩"的读法）。"""
    rng = random.Random(seed)
    span = r * 2.4 * n
    for i in range(n):
        px = x - span / 2.0 + (i + 0.5) * (span / n)
        rr = r * rng.uniform(0.72, 1.10)
        hh = h * rng.uniform(0.70, 1.15)
        py = y + rng.uniform(-2.0, 2.0)
        if i % 3 == 1:
            _jug(b, px, py, z, r=rr, h=hh, mat=mat)
        else:
            pot(b, px, py, z, r=rr, h=hh, mat=mat, plant=False)
    _ring(b, (x + span * 0.5 + r * 0.95, y, z + r * 0.92), r * 0.90, h * 0.72,
          mat, 12, "Y", taper=0.92)                                             # 侧倒的一只


def wash_tub(b, x=0.0, y=0.0, z=0.0, r=30.0, h=26.0, mat="wood", cloth="cloth_blue",
             cloth2="cloth_red", board=True, bucket_side=True, seed=0):
    """洗衣盆：木箍大盆 + 盆内水面 + 搭在盆沿的湿布 + 斜靠的搓衣板 + 提桶。"""
    rng = random.Random(seed)
    _open_vat(b, x, y, z, r, h, mat, seg=18, t=r * 0.16, water="water", band=0.55)
    _cloth_over_rim(b, x + r * 0.55, y - r * 0.30, z, r * 0.92, h, cloth, rng,
                    width=r * 0.85)
    if board:
        # 搓衣板**靠在盆外侧**（底在身前地面、上端搭在盆沿）：塞进盆里会被盆壁整个
        # 挡住（微俯视下"看不见"就等于没做）。
        bw, bh = r * 1.15, h * 2.1
        bx = x - r * 0.40
        p0 = (bx, y - r * 1.32, z + 2.0)
        p1 = (bx, y - r * 0.46, z + h * 1.95)
        _strut(b, p0, p1, bw, "wood_light", thick=3.6)
        for i in range(4):
            t = 0.18 + i * 0.21
            px = bx
            py = p0[1] + (p1[1] - p0[1]) * t - 2.6
            pz = p0[2] + (p1[2] - p0[2]) * t
            b.box((bw * 0.86, 2.4, 2.6), (px, py, pz), "wood_light",
                  rot=_euler_to(0.0, p1[1] - p0[1], p1[2] - p0[2]))
    if bucket_side:
        bucket(b, x + r * 1.32, y + r * 0.30, z, r=r * 0.32, h=h * 0.76)
        b.box((6.0, 5.0, 10.0), (x + r * 1.05, y + r * 0.20, z + h * 0.9), cloth2,
              rot=(math.radians(-12.0), 0.0, math.radians(20.0)))
    _ = rng


def dye_pots(b, x=0.0, y=0.0, z=0.0, n=3, r=21.0, h=32.0, mat="clay", seed=0):
    """染缸组：数口陶缸（深靛液面）+ 缸沿搭着的染色布 + 靠着的搅棍。"""
    rng = random.Random(seed)
    gap = r * 2.5
    for i in range(n):
        px = x - (n - 1) * gap / 2.0 + i * gap
        py = y + rng.uniform(-3.0, 3.0)
        rv = r * rng.uniform(0.88, 1.08)
        hv = h * rng.uniform(0.86, 1.06)
        _open_vat(b, px, py, z, rv, hv, mat, seg=16, t=rv * 0.20, water="dye_bath",
                  band=0.60)
        if i % 2 == 0:
            _cloth_over_rim(b, px + rv * 0.30, py - rv * 0.35, z, rv * 0.9, hv,
                            "cloth_blue" if i == 0 else "cloth_red", rng,
                            width=rv * 0.9)
        else:
            b.box((5.0, 5.0, hv * 1.95), (px - rv * 0.80, py - rv * 0.25, z + hv * 0.95),
                  "wood", rot=(0.0, math.radians(-20.0), 0.0))                   # 搅棍
            b.box((rv * 0.55, 4.0, hv * 0.80), (px - rv * 1.40, py - rv * 0.30, z + hv * 0.72),
                  "cloth_blue", rot=(0.0, math.radians(-9.0), 0.0))             # 绞布挂杆


def sack_stack(b, x=0.0, y=0.0, z=0.0, r=13.0, h=30.0, seed=0, patch=True):
    """麻袋堆：底层三袋 + 中层两袋 + 顶一袋（逐层错位、层间下沉 20% 才像压着堆）。"""
    rng = random.Random(seed)
    rows = ((0, (-1.0, 0.0, 1.0)), (1, (-0.5, 0.5)), (2, (0.0,)))
    for (lv, offs) in rows:
        lz = z + lv * h * 0.80
        for k in offs:
            px = x + k * r * 1.85 + rng.uniform(-1.5, 1.5)
            py = y + rng.uniform(-3.0, 3.0)
            sack(b, px, py, lz, r=r, h=h * (1.0 - 0.06 * lv), mat="sack", ear=(lv > 1))
            if patch and rng.random() < 0.55:
                b.box((r * 0.9, 3.0, r * 0.7), (px, py - r * 0.95, lz + h * 0.40),
                      "cloth_ochre" if rng.random() < 0.5 else "cloth_red")


def barrel_stand(b, x=0.0, y=0.0, z=0.0, w=104.0, r=13.0, bl=34.0, h=44.0,
                 mat="timber", tap=True):
    """双层酒桶架：四腿木架，下层两只横躺落地、上层两只落在横档上（带龙头）。"""
    lg = max(6.0, w * 0.085)
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            b.box_bottom((lg, lg, h + 6.0), (x + sx * (w / 2.0 - lg * 0.6),
                                            y + sy * (bl * 0.62)), z, mat)
    for sy in (-1.0, 1.0):
        b.box((w, 7.0, 7.0), (x, y + sy * (bl * 0.62), z + h), mat)             # 上层横档
        _strut(b, (x + w / 2.0 - lg * 0.6, y + sy * (bl * 0.62), z + h),
               (x + w / 2.0 - lg * 0.6, y + sy * (bl * 0.62), z), lg * 0.7, mat)
    for sx in (-1.0, 1.0):                                                      # 侧向斜撑
        _strut(b, (x - sx * (w / 2.0 - lg * 0.6), y - bl * 0.62, z + h),
               (x - sx * (w / 2.0 - lg * 0.6), y + bl * 0.62, z + h), lg * 0.7, mat)
    for sx in (-1.0, 1.0):
        barrel(b, x + sx * (w * 0.25), y, z, r=r, h=bl, lying=True)             # 下层
        barrel(b, x + sx * (w * 0.25), y, z + h + 3.5, r=r * 0.94, h=bl * 0.94,
               lying=True)                                                      # 上层
    if tap:
        b.cylinder((x - w * 0.25, y - bl * 0.5 - 3.0, z + h + r * 0.9), 3.0, 10.0,
                   "iron", 8, "Y")
        b.box_bottom((9.0, 6.0, 7.0), (x - w * 0.25, y - bl * 0.5 - 9.0),
                     z + h + r * 0.6, "iron")


def bread_tray(b, x=0.0, y=0.0, z=0.0, w=60.0, h=76.0, d=34.0, mat="wood",
               loaves=5, seed=0):
    """面包架：三层（微前倾）托盘 + 圆面包/长棍 + 盖布角 + 立柱与顶梁。"""
    rng = random.Random(seed)
    fw = w / 60.0
    for sx in (-1.0, 1.0):
        b.box_bottom((7.0 * fw, 7.0 * fw, h), (x + sx * (w / 2.0 - 5.0 * fw), y),
                     z, "timber")
    b.box((w + 6.0 * fw, 5.0 * fw, 5.0 * fw), (x, y, z + h), "timber")
    tilt = math.radians(-7.0)
    for i in range(3):
        sz = z + 12.0 * fw + i * (h * 0.30)
        b.box((w, d, 5.0 * fw), (x, y, sz), mat, rot=(tilt, 0.0, 0.0))
        b.box((w + 3.0 * fw, 4.0 * fw, 5.0 * fw), (x, y - d / 2.0, sz + 3.0 * fw), "timber")
        nn = max(2, loaves // 2)
        for k in range(nn):
            px = x - w * 0.34 + (k + 0.5) * (w * 0.68 / nn)
            rr = w * 0.10 * rng.uniform(0.80, 1.15)
            if i == 1:
                b.box((w * 0.30, rr * 1.5, rr * 0.95), (px, y, sz + 3.0 * fw + rr * 0.5),
                      "bread", rot=(0.0, 0.0, rng.uniform(-0.25, 0.25)))
            else:
                _ring(b, (px, y, sz + 3.0 * fw + rr * 0.52), rr * 0.92, rr * 0.92,
                      "bread", 12, "Y")
    b.box((w * 0.5, d * 0.9, 4.0 * fw), (x + w * 0.22, y, z + 12.0 * fw + h * 0.60 + 6.0 * fw),
          "canvas")                                                             # 盖布


def herb_rack(b, x=0.0, y=0.0, z=0.0, w=64.0, n=6, seed=0, mat="timber"):
    """墙面草药晾架（贴面）：横杆 + 两只托架 + 一束束倒挂的香草/蒜辫。"""
    rng = random.Random(seed)
    b.box((w, 7.0, 7.0), (x, y, z), mat)                                        # 横杆
    for sx in (-1.0, 1.0):                                                      # 托架
        b.box_bottom((6.0, 6.0, 16.0), (x + sx * (w / 2.0 - 8.0), y + 3.0), z - 13.0, mat)
        b.box((22.0, 6.0, 6.0), (x + sx * (w / 2.0 - 14.0), y + 6.0, z - 4.0), mat)
    for i in range(n):
        px = x - w * 0.42 + (i + 0.5) * (w * 0.84 / n)
        ln = w * rng.uniform(0.36, 0.56)
        mm = "foliage" if i % 2 == 0 else "straw"
        _ring(b, (px, y - 2.0, z - 5.0 - ln * 0.5), ln * 0.09, ln, mm, 10, "Z", taper=1.32)
        b.box((7.0, 5.0, 5.0), (px, y - 2.0, z - 6.0), "rope")
        if i % 3 == 2:
            b.box((5.0, 5.0, 9.0), (px + 4.0, y - 2.0, z - 12.0 - ln), "produce_root")


def lantern_post(b, x=0.0, y=0.0, z=0.0, h=196.0, arm=None, mat="timber", lit=True,
                 s=None):
    """立柱灯笼：石座 + 木柱 + 铁箍/挂环 + 挑臂 + 灯笼（自发光）+ 斜撑。

    灯笼复用既有 `lantern()`（`belt/materials` 的 `lamp` 自发光玻璃），所以夜里
    亮的是同一套材质，不会出现"柱子上的灯和门口灯不是一个色"。
    """
    arm = arm if arm else h * 0.16
    s = s if s else h * 0.098
    k = s / 19.0                                    # 内部小件的等比系数（s=19 为标称值）
    b.box_bottom((26.0 * k, 26.0 * k, 12.0 * k), (x, y), z, "stone_dark")
    b.box_bottom((12.0 * k, 12.0 * k, h), (x, y), z + 10.0 * k, mat)
    b.box_bottom((16.0 * k, 16.0 * k, 8.0 * k), (x, y), z + h * 0.35, "iron")
    _ring(b, (x, y, z + h * 0.62), 8.0 * k, 5.0 * k, "iron", 12, "X")
    b.box((arm, 7.0 * k, 7.0 * k), (x, y - arm * 0.5, z + h - 5.0 * k), "iron")   # 挑臂
    _strut(b, (x, y - 3.0 * k, z + h - 26.0 * k),
           (x, y - arm + 5.0 * k, z + h - 8.0 * k), 5.0 * k, "iron")              # 斜撑
    b.box_bottom((5.0 * k, 5.0 * k, 12.0 * k), (x, y - arm + 4.0 * k), z + h - 20.0 * k,
                 "iron")
    lantern(b, x, y - arm + 4.0 * k, z + h - 32.0 * k, s=s, h=s * 1.5,
            bracket=False, lit=lit)


def chicken_coop(b, x=0.0, y=0.0, z=0.0, w=92.0, d=60.0, h=56.0, mat="wood",
                 roof_mat="wood_shingle", hens=3, seed=0):
    """鸡笼：木板笼身 + 单坡顶 + 出入洞（朝前）+ 带横档的踏板坡道 + 散养母鸡。"""
    rng = random.Random(seed)
    fw = w / 92.0
    b.box_bottom((w, d, h), (x, y), z, mat)                                     # 笼身
    b.box_bottom((w * 0.30, 4.0 * fw, h * 0.40), (x - w * 0.16, y - d / 2.0 - 1.0 * fw),
                 z + 2.0 * fw, "cavity")                                        # 出入洞
    b.box((w * 0.34, 5.0 * fw, h * 0.40), (x - w * 0.16, y - d / 2.0 - 3.0 * fw, z + h * 0.22),
          "timber")                                                             # 洞框
    b.box((w + 12.0 * fw, d + 16.0 * fw, 6.0 * fw), (x, y, z + h + 5.0 * fw), roof_mat,
          rot=(math.radians(-7.0), 0.0, 0.0))                                   # 单坡顶
    rl = h * 0.95                                                               # 坡道
    ry = y - d / 2.0 - rl * 0.44
    rz = z + h * 0.21
    ang = math.radians(-58.0)          # 绕 X 转 → 盒子**长边必须是局部 Z**（局部 Y 是坡长会埋进地里）
    b.box((w * 0.30, 4.0 * fw, rl), (x - w * 0.16, ry, rz), "wood_light", rot=(ang, 0.0, 0.0))
    for i in range(4):                                                          # 坡道横档
        s = -rl * 0.34 + i * rl * 0.24
        b.box((w * 0.30 + 3.0 * fw, 3.0 * fw, 3.0 * fw),
              (x - w * 0.16, ry + s * 0.848, rz + s * 0.530), "wood_light", rot=(ang, 0.0, 0.0))
    hs = fw * 1.5
    # 站位全部落在笼身**前方**（oy ≤ -0.6 → y - d*0.6，笼身前沿在 -0.5）：站进笼子
    # 里就是穿模；同时避开 x -0.31w..-0.01w 那段坡道。
    spots = ((-0.62, -0.66), (0.16, -0.92), (0.46, -1.10), (-0.30, -1.18))
    for i in range(max(0, min(hens, len(spots)))):
        (ox, oy) = spots[i]
        _hen(b, x + w * ox, y + d * oy, z, s=hs,
             mat="canvas" if i % 2 == 0 else "cloth_ochre")
    _ = rng


def cart_loaded(b, x=0.0, y=0.0, z=0.0, w=110.0, d=52.0, seed=0, sacks=2, barrels=1,
                hay=True):
    """载货板车：复用 `cart` 的辐条轮组/车厢/辕杆，再压上箱 + 袋 + 卧桶 + 草捆。"""
    cart(b, x=x, y=y, z=z, w=w, d=d, loaded=0)
    fw = w / 110.0
    top = z + 30.0 + 5.0
    crate(b, x - w * 0.22, y + 2.0 * fw, top, s=w * 0.24, h=w * 0.20)
    crate(b, x - w * 0.22, y + 2.0 * fw, top + w * 0.20, s=w * 0.20, h=w * 0.17)
    for i in range(sacks):
        sack(b, x + w * 0.14 + i * w * 0.15, y - 6.0 * fw + i * 5.0 * fw, top,
             r=w * 0.10, h=w * 0.24)
    if barrels:
        barrel(b, x + w * 0.30, y + 3.0 * fw, top, r=w * 0.10, h=w * 0.27, lying=True)
    if hay:
        hay_bale(b, x + w * 0.03, y + 4.0 * fw, top + w * 0.20, w=w * 0.42,
                 d=26.0 * fw, h=22.0 * fw, mat="thatch", seed=seed)
    basket(b, x - w * 0.52, y + d * 0.48, top - 12.0 * fw, r=12.0 * fw, h=12.0 * fw,
           handle=True)


def stone_pile(b, x=0.0, y=0.0, z=0.0, w=88.0, h=40.0, seed=0, cut=True):
    """石料堆：底层一坨深色碎石 + 上面两块**浅色**方整料石 + 撬棍。

    对比是刻意的：碎石用 `stone_dark`、料石用 `stone`。全用浅石在沙土地上会糊成
    一坨"沙堆"，深浅一撞才读得出"石料 + 待砌的料石"。
    """
    rng = random.Random(seed)
    # 底床做成**低平的碎石床**而不是圆锥：圆锥在 20° 俯视下侧面全在暗部，会读成
    # "一顶深色小帐篷"（草垛也踩过同一个坑）。
    _ring(b, (x, y, z + h * 0.09), w * 0.44, h * 0.20, "stone_dark", 12, "Z", taper=0.90)
    for i in range(11):
        a = rng.uniform(0.0, math.pi * 2.0)
        rad = rng.uniform(0.0, w * 0.40)
        s = w * rng.uniform(0.09, 0.17)
        b.box((s, s * 0.82, s * 0.62),
              (x + math.cos(a) * rad, y + math.sin(a) * rad * 0.62,
               z + h * 0.16 + rng.uniform(0.0, h * 0.16)),
              "stone_dark" if i % 3 else "stone",
              rot=(rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), rng.uniform(0.0, 3.0)))
    if cut:
        b.box_bottom((w * 0.42, w * 0.24, h * 0.30), (x - w * 0.10, y), z + h * 0.20, "stone")
        b.box_bottom((w * 0.30, w * 0.20, h * 0.24), (x + w * 0.06, y + w * 0.05),
                     z + h * 0.50, "stone")
        b.box((6.0, 6.0, h * 0.48), (x + w * 0.34, y - w * 0.12, z + h * 0.42), "timber",
              rot=(0.0, math.radians(16.0), 0.0))


def firewood_basket(b, x=0.0, y=0.0, z=0.0, r=20.0, h=22.0, seed=0, lean=2):
    """柴篓：柳条筐 + 竖插的劈柴（端面朝上）+ 斜靠的两根长柴。"""
    rng = random.Random(seed)
    basket(b, x, y, z, r=r, h=h)
    for i in range(7):
        th = rng.uniform(0.0, math.pi * 2.0)
        rad = rng.uniform(0.0, r * 0.62)
        ln = h * rng.uniform(1.5, 2.1)
        lx, ly = x + math.cos(th) * rad, y + math.sin(th) * rad
        b.cylinder((lx, ly, z + ln / 2.0), r * 0.17, ln, "wood_light", 8, "Z",
                   taper=rng.uniform(0.86, 1.0))
        b.cylinder((lx, ly, z + ln - 0.8), r * 0.16, 1.8, "wood_dark", 8, "Z")
    for i in range(lean):
        b.box((6.0, 6.0, h * 1.6), (x + (i * 2 - 1) * r * 0.85, y + r * 0.45, z + h * 0.72),
              "wood", rot=(math.radians(-14.0), 0.0, math.radians((i * 2 - 1) * 10.0)))


def milk_churn(b, x=0.0, y=0.0, z=0.0, r=12.0, h=54.0, mat="iron", lid=True, handle=True):
    """奶桶（束颈高桶）：下宽上收 + 束颈 + 盖 + 双耳 + 底圈。"""
    _ring(b, (x, y, z + h * 0.40), r * 0.92, h * 0.80, mat, 14, "Z", taper=0.74)
    _ring(b, (x, y, z + h * 0.84), r * 0.70, h * 0.10, mat, 14)
    b.cylinder((x, y, z + h * 0.94), r * 0.76, h * 0.08, mat, 14)
    _ring(b, (x, y, z + 2.0), r * 1.02, 4.0, mat, 14)
    if lid:
        b.cylinder((x, y, z + h * 0.99), r * 0.80, 3.0, mat, 14)
        b.box_bottom((5.0, 5.0, 5.0), (x, y), z + h * 1.02, mat)
    if handle:
        for sx in (-1.0, 1.0):
            b.box_bottom((3.0, 4.0, 12.0), (x + sx * r * 0.82, y), z + h * 0.66, mat)


def crate_stack(b, x=0.0, y=0.0, z=0.0, s=30.0, h=26.0, n=3, seed=0, plank=True):
    """货箱堆：三层箱（逐层错位微转）+ 顶上一块散板 + 脚边一捆绳。"""
    rng = random.Random(seed)
    for i in range(n):
        crate(b, x + rng.uniform(-3.0, 3.0), y + rng.uniform(-3.0, 3.0),
              z + i * (h + 1.0), s=s * (1.0 - 0.05 * i), h=h * (1.0 - 0.05 * i))
    if plank:
        b.box((s * 1.5, s * 0.7, 3.0), (x - s * 0.05, y + s * 0.1, z + n * (h + 1.0) + 1.5),
              "wood_light", rot=(0.0, 0.0, math.radians(rng.uniform(-8.0, 8.0))))
        rope_coil(b, x + s * 0.95, y - s * 0.9, z, r=s * 0.42)


def water_butt(b, x=0.0, y=0.0, z=0.0, r=16.0, h=54.0, lid=True, tap=True, bucket2=True):
    """接雨水的立桶：高桶（开口 + 水面）+ 半边板盖 + 铁龙头 + 接水桶。"""
    barrel(b, x, y, z, r=r, h=h, bands=3, mat="wood", open_top=True, water=True)
    if lid:
        for sx in (-1.0, 1.0):
            b.box_bottom((r * 1.3, 5.0, 5.0), (x + sx * r * 0.66, y), z + h - 1.0,
                         "wood_dark")
    if tap:
        b.cylinder((x, y - r * 1.06, z + h * 0.36), 3.2, 12.0, "iron", 8, "Y")
        _ring(b, (x, y - r * 1.06 - 6.0, z + h * 0.30), 4.0, 9.0, "iron", 8, "X")
    if bucket2:
        bucket(b, x + r * 0.55, y - r * 1.55, z, r=r * 0.52, h=h * 0.30)


def hay_bale(b, x=0.0, y=0.0, z=0.0, w=76.0, d=42.0, h=34.0, mat="thatch", seed=0,
             fork=False):
    """草捆（方捆）：两道绳 + 参差的草梢端面（破掉"方盒"的读法）。"""
    rng = random.Random(seed)
    fw = w / 76.0
    b.box_bottom((w, d, h), (x, y), z, mat)
    for i in range(2):
        _ring(b, (x + (i * 2 - 1) * w * 0.26, y, z + h * 0.5), h * 0.56, 3.0 * fw,
              "rope", 12, "X")
    for i in range(8):
        b.box((7.0 * fw, 5.0 * fw, 5.0 * fw),
              (x + w * 0.5 + rng.uniform(-1.0, 1.0),
               y + rng.uniform(-d * 0.4, d * 0.4), z + rng.uniform(3.0, h - 3.0)),
              "straw", rot=(rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6), 0.0))
    if fork:
        hay_fork(b, x + w * 0.42, y + d * 0.30, z)


def stew_pot(b, x=0.0, y=0.0, z=0.0, r=22.0, h=26.0, mat="iron", fire=True, ladle=True):
    """吊锅灶：三脚铁架 + 挂链 + 吊锅（能看见汤面）+ 灶膛余烬（自发光）+ 长柄勺。"""
    top = z + h * 3.0
    for i in range(3):
        a = 2.0 * math.pi * i / 3.0 + math.pi / 2.0
        _strut(b, (x + math.cos(a) * r * 1.05, y + math.sin(a) * r * 1.05, z),
               (x, y, top), r * 0.30, "iron")
    _ring(b, (x, y, top + 4.0), r * 0.22, 8.0, "iron", 10)
    b.box_bottom((r * 0.16, r * 0.16, 14.0), (x, y), top - 8.0, "iron")        # 挂链
    _open_vat(b, x, y, top - 34.0, r, h, mat, seg=16, t=r * 0.15, water="water")
    for sx in (-1.0, 1.0):
        b.box_bottom((r * 0.30, 4.0, 5.0), (x + sx * r * 0.66, y), top - 30.0, "iron")
    _ring(b, (x, y, z + 5.0), r * 0.85, 11.0, "stone_dark", 12)                # 灶圈
    if fire:
        for i in range(5):
            a = math.pi * 2.0 * i / 5.0
            b.box((9.0, 9.0, 7.0),
                  (x + math.cos(a) * r * 0.36, y + math.sin(a) * r * 0.36, z + 9.0),
                  "ember", rot=(0.0, 0.0, a))
        b.box_bottom((r * 0.68, r * 0.68, 8.0), (x, y), z + 8.0, "fire")
    if ladle:
        _strut(b, (x + r * 1.45, y - r * 0.45, z), (x + r * 0.45, y - r * 0.22, top - 26.0),
               4.5, "wood")
        b.cylinder((x + r * 0.50, y - r * 0.22, top - 30.0), r * 0.26, 8.0, "iron", 10)


def broom_bundle(b, x=0.0, y=0.0, z=0.0, h=118.0, n=2, seed=0):
    """靠墙的扫帚/柴捆（贴面）：柄上端抵墙，草梢在下端散开成帚。"""
    rng = random.Random(seed)
    for i in range(n):
        px = x + (i - (n - 1) / 2.0) * h * 0.14
        _strut(b, (px, y - h * 0.22, z), (px, y - 4.0, z + h), h * 0.042, "wood_light")
        for k in range(5):
            th = -0.5 + k * 0.25
            _strut(b, (px + math.sin(th) * h * 0.04, y - h * 0.20, z + h * 0.22),
                   (px + math.sin(th) * h * 0.10,
                    y - h * 0.26 - rng.uniform(0.0, h * 0.04), z + 2.0),
                   h * 0.034, "straw")
        _ring(b, (px, y - h * 0.21, z + h * 0.19), h * 0.058, h * 0.05, "rope", 10, "X")


def flower_bucket(b, x=0.0, y=0.0, z=0.0, r=10.0, h=21.0, n=9, seed=0, bucket2=True):
    """花桶：木提桶里插一把剪下的花（红/蓝花头 + 绿叶茎），旁边再来一只空桶。"""
    rng = random.Random(seed)
    bucket(b, x, y, z, r=r, h=h)
    for i in range(n):
        th = rng.uniform(0.0, math.pi * 2.0)
        rad = rng.uniform(0.0, r * 0.60)
        ln = h * rng.uniform(1.05, 1.65)
        sx, sy = x + math.cos(th) * rad, y + math.sin(th) * rad
        b.box((2.6, 2.6, ln), (sx, sy, z + h + ln * 0.5 - 3.0), "foliage",
              rot=(rng.uniform(-0.22, 0.22), rng.uniform(-0.22, 0.22), 0.0))
        b.box((6.5, 6.5, 6.0),
              (sx + rng.uniform(-2.0, 2.0), sy + rng.uniform(-2.0, 2.0), z + h + ln - 2.0),
              "cloth_red" if i % 2 == 0 else "cloth_blue",
              rot=(rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), rng.uniform(0.0, 3.0)))
    if bucket2:
        bucket(b, x + r * 2.6, y + 3.0, z, r=r * 0.86, h=h * 0.86)


# ================================================================ 挂载调度

#: 游戏内 1:1 可辨的默认放大系数。道具按"现实尺寸"建模（桶高 0.55m、铁砧全高 1.2m），
#: 但本游戏 1px ≈ 1.31cm、屏幕上一栋房才 200~410px 高 —— 现实尺寸的道具缩到游戏
#: 尺寸就只剩十几个像素，读不出是什么。§9.2 的出厂门禁要求"游戏尺寸可辨"，所以
#: 挂载时统一放大到 1.45 倍（现实尺寸仍记录在各自 docstring 里，便于反算）。
GAME_SCALE = 1.45

#: 每种建筑类型的前场配方：(道具名, 侧别, kwargs)。侧别 -1 = 门左侧、+1 = 门右侧；
#: 列表**从前到后即优先级**，宽度不够或没位置时从尾部丢弃。
#: 之所以按"门左右两侧向外铺"而不是按全宽均分：门是立面的视觉锚点，道具必须
#: 对称铺开且**绝不压门**（§8.3 门口可读），贪心两侧排布天然满足这两条。
DRESS = {
    "house": [
        ("barrel", -1, dict(r=15.0, h=42.0, bands=3)),
        ("log_pile", 1, dict(rows=2, per_row=4)),
        ("bench", -1, dict(w=52.0, h=32.0)),
        ("haystack", 1, dict(r=20.0, h=38.0)),
        ("ladder", -1, dict(h=96.0)),
        ("pot", 1, dict(r=10.0, h=16.0)),
        # ---- 二轮追加（一律挂在尾部：宽不够时从尾部丢，既有排布不动）----
        ("firewood_basket", 1, dict(r=20.0, h=22.0)),
        ("basket", -1, dict(r=17.0, h=17.0)),
        ("milk_churn", -1, dict(r=11.0, h=50.0)),
    ],
    "townhouse": [
        ("signboard", -1, dict(w=48.0, h=36.0, swing=2.5)),
        ("crate", 1, dict(s=28.0, h=24.0)),
        ("lantern", 1, dict(s=15.0, h=24.0)),
        ("sack", -1, dict(r=12.0, h=28.0)),
        ("pot", -1, dict(r=9.0, h=15.0)),
        ("clothesline", 1, dict(x0=-30.0, x1=30.0, z=120.0, items=2)),
        # ---- 二轮追加（尾部低优先级）----
        ("flower_bucket", 1, dict(r=10.0, h=20.0)),
        ("basket", -1, dict(r=17.0, h=17.0)),
        ("hanging_sign", -1, dict(w=42.0, h=32.0, z=178.0)),
    ],
    "barn": [
        ("cart", 1, dict(w=92.0, loaded=3)),
        ("haystack", -1, dict(r=24.0, h=44.0)),
        ("trough", 1, dict(w=70.0, h=22.0)),
        ("hay_fork", -1, {}),
        ("log_pile", -1, dict(rows=2, per_row=5)),
        ("fence", 1, dict(x0=-30.0, x1=30.0, wattle=True)),
        # ---- 二轮追加 ----
        ("hay_bale", 1, dict(w=76.0, h=34.0)),
        ("chicken_coop", -1, dict(w=88.0, h=52.0)),
        ("basket", 1, dict(r=17.0, h=17.0)),
    ],
    "smithy": [
        ("anvil", -1, {}),
        ("quench_barrel", 1, {}),
        ("barrel", -1, dict(r=15.0, h=42.0, bands=3)),
        ("log_pile", 1, dict(rows=2, per_row=4)),
        ("tools_rack", -1, dict(w=48.0)),
        ("grindstone", 1, dict(r=22.0)),
        ("stool", -1, {}),
        ("coal_pile", 1, dict(w=40.0, h=16.0)),
        # ---- 二轮追加 ----
        ("stone_pile", -1, dict(w=84.0, h=38.0)),
        ("barrel_stand", 1, dict(w=100.0)),
        ("broom_bundle", -1, dict(h=104.0)),
    ],
    "windmill": [
        ("cart", 1, dict(w=96.0, loaded=4)),
        ("sack", -1, dict(r=13.0, h=30.0)),
        ("grindstone", 1, dict(r=24.0)),
        ("sack", -1, dict(r=11.0, h=26.0)),
        ("fence", -1, dict(x0=-30.0, x1=30.0)),
        # ---- 二轮追加 ----
        ("sack_stack", 1, dict(r=12.0, h=28.0)),
        ("basket", -1, dict(r=16.0, h=16.0)),
    ],
    "cathedral": [
        ("lantern", -1, dict(s=19.0, h=30.0)),
        ("lantern", 1, dict(s=19.0, h=30.0)),
        ("flower_box", -1, dict(w=44.0)),
        ("flower_box", 1, dict(w=44.0)),
        ("bench", 1, dict(w=56.0, h=32.0, back=True)),
        # ---- 二轮追加（教堂门前是市集的老传统）----
        ("lantern_post", -1, dict(h=190.0)),
        ("market_table", 1, dict(w=110.0, goods="produce")),
    ],
    "tower": [
        ("barrel", -1, dict(r=14.0, h=40.0)),
        ("crate", 1, dict(s=26.0, h=22.0)),
        ("banner", 1, dict(w=24.0, h=50.0)),
    ],
    "gatehouse": [
        ("banner", -1, dict(w=24.0, h=52.0)),
        ("lantern", -1, dict(s=17.0, h=26.0)),
        ("barrel", 1, dict(r=14.0, h=40.0)),
        ("crate", 1, dict(s=24.0, h=20.0)),
        ("market_table", 1, dict(w=104.0, goods="cheese")),
        ("sack_stack", -1, dict(r=12.0, h=28.0)),
    ],
    "lighthouse": [
        ("rope_coil", -1, dict(r=13.0)),
        ("mooring_post", -1, {}),
        ("crate", 1, dict(s=28.0, h=24.0)),
        ("barrel", 1, dict(r=14.0, h=40.0)),
        ("water_butt", -1, dict(r=15.0, h=52.0)),
        ("firewood_basket", 1, dict(r=18.0, h=20.0)),
    ],
    # ---- 二轮新增配方：店铺 / 市集 -------------------------------------------
    #: 店铺立面：布篷 + 挂招牌 + 台案 + 筐货 + 面包架。
    #: 顺序说明：townhouse 的门偏在**左起第一开间**（door_x ≈ -218，左侧只剩极窄一条
    #: 墙面），所以大件先占**右侧**的连续墙面，小件再走左。篷布 w=120 是"外缘恰好压在
    #: 窗楣之上、靠墙缘又不超过一层檐口（207）、左右也不压门框"的尺寸，别随手放大。
    "shop": [
        ("awning", 1, dict(w=120.0, z=168.0)),
        ("hanging_sign", 1, dict(w=46.0, h=36.0, z=182.0)),
        ("market_table", 1, dict(w=118.0, goods="cheese")),
        ("flower_bucket", -1, dict(r=10.0, h=20.0)),
        ("bread_tray", -1, dict(w=56.0, h=72.0)),
        ("produce_baskets", -1, dict(r=18.0, h=18.0)),
        ("sack_stack", 1, dict(r=12.0, h=28.0)),
        ("basket", 1, dict(r=17.0, h=17.0)),
    ],
    #: 市集立面（广场边一排摊）：摊篷领衔，后面才是桶架/菜筐/陶器/袋堆/箱堆
    "market": [
        ("market_stall", 1, dict(w=170.0, d=88.0, h=165.0, cloth="cloth_ochre")),
        ("barrel_stand", -1, dict(w=104.0)),
        ("produce_baskets", 1, dict(r=18.0, h=18.0)),
        ("pottery_row", -1, dict(n=5, r=17.0, h=30.0)),
        ("sack_stack", 1, dict(r=13.0, h=30.0)),
        ("crate_stack", -1, dict(s=30.0, h=26.0)),
    ],
}

#: 道具落地占位宽（建模尺寸，未乘 GAME_SCALE）——排布用，宁可略宽也不要重叠。
WIDTH = {
    "barrel": 42.0, "bucket": 28.0, "trough": 82.0, "sack": 32.0, "crate": 42.0,
    "chest": 56.0, "log_pile": 100.0, "plank_pile": 74.0, "coal_pile": 50.0,
    "haystack": 56.0, "anvil": 74.0, "tongs": 30.0, "tools_rack": 60.0,
    "grindstone": 58.0, "quench_barrel": 44.0, "bench": 72.0, "stool": 34.0,
    "table": 70.0, "signboard": 64.0, "lantern": 40.0, "pot": 34.0,
    "ladder": 40.0, "cart": 136.0, "wheelbarrow": 120.0, "fence": 88.0,
    "well": 68.0, "banner": 36.0, "clothesline": 84.0, "hay_fork": 28.0,
    "grind_post": 30.0, "rope_coil": 32.0, "mooring_post": 30.0,
    "flower_box": 54.0,
    # ---- 二轮：市集/民生 ----
    "market_stall": 206.0, "market_table": 128.0, "awning": 152.0,
    "hanging_sign": 64.0, "standing_board": 54.0, "basket": 44.0,
    "produce_baskets": 88.0, "fish_table": 120.0, "pottery_row": 102.0,
    "wash_tub": 100.0, "sack_stack": 68.0, "barrel_stand": 116.0,
    "bread_tray": 66.0, "dye_pots": 138.0, "herb_rack": 70.0,
    "lantern_post": 52.0, "chicken_coop": 104.0, "cart_loaded": 152.0,
    "stone_pile": 96.0, "firewood_basket": 46.0, "milk_churn": 30.0,
    "crate_stack": 44.0, "water_butt": 40.0, "hay_bale": 84.0, "stew_pot": 62.0,
    "broom_bundle": 40.0, "flower_bucket": 44.0,
}

#: 道具名 -> 函数（供配方表与外部直接调用）
TABLE = {
    "barrel": barrel, "bucket": bucket, "trough": trough, "sack": sack,
    "crate": crate, "chest": chest, "log_pile": log_pile, "plank_pile": plank_pile,
    "coal_pile": coal_pile, "haystack": haystack, "anvil": anvil, "tongs": tongs,
    "tools_rack": tools_rack, "grindstone": grindstone, "quench_barrel": quench_barrel,
    "bench": bench, "stool": stool, "table": table, "signboard": signboard,
    "lantern": lantern, "pot": pot, "planter": planter, "ladder": ladder, "cart": cart,
    "wheelbarrow": wheelbarrow, "fence": fence, "banner": banner,
    "clothesline": clothesline, "well": well, "grind_post": grind_post,
    "hay_fork": hay_fork, "flower_box": flower_box, "rope_coil": rope_coil,
    "mooring_post": mooring_post,
    # ---- 二轮：市集/民生 ----
    "basket": basket, "produce_baskets": produce_baskets, "market_stall": market_stall,
    "market_table": market_table, "awning": awning, "hanging_sign": hanging_sign,
    "standing_board": standing_board, "fish_table": fish_table,
    "pottery_row": pottery_row, "wash_tub": wash_tub, "dye_pots": dye_pots,
    "sack_stack": sack_stack, "barrel_stand": barrel_stand, "bread_tray": bread_tray,
    "herb_rack": herb_rack, "lantern_post": lantern_post,
    "chicken_coop": chicken_coop, "cart_loaded": cart_loaded, "stone_pile": stone_pile,
    "firewood_basket": firewood_basket, "milk_churn": milk_churn,
    "crate_stack": crate_stack, "water_butt": water_butt, "hay_bale": hay_bale,
    "stew_pot": stew_pot, "broom_bundle": broom_bundle, "flower_bucket": flower_bucket,
}

#: 贴面件（挂墙，不做进深外移）
FLUSH = ("tools_rack", "signboard", "flower_box", "clothesline",
         "awning", "hanging_sign", "herb_rack", "broom_bundle")
#: 按跨度摆放的件（用 x0/x1 相对跨度 + 统一平移量）
SPAN = ("fence", "clothesline")
#: 各自的前后进深（决定 y 外移多少）。**口径**：这里给的是"外移量 × 2"，而
#: `dress()` 的 `y = front_y - DEPTH*0.5` 是**不乘 GAME_SCALE** 的，所以新道具按
#: "现实进深 × 1.45 × 1.15" 给值 —— 宁可多推出去一点，也不让放大的道具插进墙里。
DEPTH = {"log_pile": 22.0, "plank_pile": 22.0, "cart": 46.0, "wheelbarrow": 40.0,
         "well": 40.0, "trough": 26.0, "haystack": 44.0, "bench": 28.0,
         "table": 34.0, "fence": 8.0, "grindstone": 26.0, "ladder": 14.0,
         "hay_fork": 12.0, "coal_pile": 34.0,
         # ---- 二轮 ----
         "market_stall": 164.0, "market_table": 92.0, "standing_board": 46.0,
         "basket": 62.0, "produce_baskets": 70.0, "fish_table": 86.0,
         "pottery_row": 70.0, "wash_tub": 96.0, "sack_stack": 64.0,
         "barrel_stand": 70.0, "bread_tray": 56.0, "dye_pots": 72.0,
         "lantern_post": 50.0, "chicken_coop": 196.0, "cart_loaded": 86.0,
         "stone_pile": 92.0, "firewood_basket": 66.0, "milk_churn": 42.0,
         "crate_stack": 54.0, "water_butt": 62.0, "hay_bale": 68.0,
         "stew_pot": 74.0, "flower_bucket": 48.0}


def pack_sides(W, items, door_x, door_w, gap=14.0, spill=0.30, clear=10.0,
               scale=GAME_SCALE):
    """把道具从门口向左右两侧铺开，返回 [(name, x)]；放不下的从尾部丢弃。

    保证：① 任何道具不与门洞重叠（左右游标从门边 clear 处起步）；
    ② 同侧道具之间留 gap；③ 允许溢出立面两端 spill×W，视觉上更像"堆在屋前"。
    """
    lo = -W / 2.0 - W * spill
    hi = W / 2.0 + W * spill
    cur = {"L": door_x - door_w / 2.0 - clear, "R": door_x + door_w / 2.0 + clear}
    out = []
    for (name, side, kw) in items:
        w = WIDTH.get(name, 40.0) * scale
        if name in SPAN:                       # 跨度件：按自身跨度算占位
            w = abs(kw.get("x1", 0.0) - kw.get("x0", 0.0)) * scale + 20.0
        key = "L" if side < 0 else "R"
        if key == "L":
            cx = cur["L"] - w / 2.0
            if cx - w / 2.0 < lo:
                continue
            cur["L"] = cx - w / 2.0 - gap
        else:
            cx = cur["R"] + w / 2.0
            if cx + w / 2.0 > hi:
                continue
            cur["R"] = cx + w / 2.0 + gap
        out.append((name, cx, side, kw))
    return out


def dress(b, kind, W, front_y, seed=0, door_x=0.0, door_w=50.0, y_jitter=4.0,
          scale=GAME_SCALE, max_items=None):
    """给一个立面挂上该类型的全部道具。

    参数
    ----
    b        : `buildings.Builder`（与建筑同一个 builder，同对象同材质槽）
    kind     : DRESS 的键（house/townhouse/barn/smithy/windmill/cathedral/...）
    W        : 建筑网格宽（格 × 32）
    front_y  : 建筑前墙面 y（= measure(ob)["y"][0]）；道具摆在它 -Y 侧之外
    seed     : 确定性种子（建议与建筑的 seed 派生同源）
    返回     : 挂载清单 (道具名, x, y)，供自检打印

    y 取值规则：贴面件（工具架/招牌/花箱/晾衣绳）贴墙 `front_y - 4`；其余按道具
    自身进深外移，再加 0~y_jitter 的抖动 —— 一排道具不在同一 y 才读得出"摆在地上"
    而不是"贴在墙上"。
    """
    recipe = DRESS.get(kind)
    if not recipe:
        return []
    rng = random.Random(seed * 977 + 13)
    items = recipe if max_items is None else recipe[:max_items]
    plan = pack_sides(W, items, door_x, door_w, scale=scale)
    placed = []
    for (pname, x, side, kw) in plan:
        fn = TABLE.get(pname)
        if fn is None:
            continue
        p = dict(kw)
        zz = p.pop("z", 0.0)          # 挂墙件可自带 z 偏移（如晾衣绳挂高）
        if pname in FLUSH:
            y = front_y - 4.0
        else:
            y = front_y - DEPTH.get(pname, 30.0) * 0.5 - rng.uniform(0.0, y_jitter)
        if scale != 1.0:
            for k in ("r", "h", "w", "d", "s"):
                if k in p:
                    p[k] = p[k] * scale
        p["seed"] = int(rng.randrange(1 << 30))
        try:
            fn(b, x=x, y=y, z=zz, **p)
        except TypeError:
            p.pop("seed", None)
            fn(b, x=x, y=y, z=zz, **p)
        placed.append((pname, round(x, 1), round(y, 1)))
    return placed
