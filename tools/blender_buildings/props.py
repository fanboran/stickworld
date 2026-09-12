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
    ],
    "townhouse": [
        ("signboard", -1, dict(w=48.0, h=36.0, swing=2.5)),
        ("crate", 1, dict(s=28.0, h=24.0)),
        ("lantern", 1, dict(s=15.0, h=24.0)),
        ("sack", -1, dict(r=12.0, h=28.0)),
        ("pot", -1, dict(r=9.0, h=15.0)),
        ("clothesline", 1, dict(x0=-30.0, x1=30.0, z=120.0, items=2)),
    ],
    "barn": [
        ("cart", 1, dict(w=92.0, loaded=3)),
        ("haystack", -1, dict(r=24.0, h=44.0)),
        ("trough", 1, dict(w=70.0, h=22.0)),
        ("hay_fork", -1, {}),
        ("log_pile", -1, dict(rows=2, per_row=5)),
        ("fence", 1, dict(x0=-30.0, x1=30.0, wattle=True)),
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
    ],
    "windmill": [
        ("cart", 1, dict(w=96.0, loaded=4)),
        ("sack", -1, dict(r=13.0, h=30.0)),
        ("grindstone", 1, dict(r=24.0)),
        ("sack", -1, dict(r=11.0, h=26.0)),
        ("fence", -1, dict(x0=-30.0, x1=30.0)),
    ],
    "cathedral": [
        ("lantern", -1, dict(s=19.0, h=30.0)),
        ("lantern", 1, dict(s=19.0, h=30.0)),
        ("flower_box", -1, dict(w=44.0)),
        ("flower_box", 1, dict(w=44.0)),
        ("bench", 1, dict(w=56.0, h=32.0, back=True)),
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
    ],
    "lighthouse": [
        ("rope_coil", -1, dict(r=13.0)),
        ("mooring_post", -1, {}),
        ("crate", 1, dict(s=28.0, h=24.0)),
        ("barrel", 1, dict(r=14.0, h=40.0)),
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
}

#: 贴面件（挂墙，不做进深外移）
FLUSH = ("tools_rack", "signboard", "flower_box", "clothesline")
#: 按跨度摆放的件（用 x0/x1 相对跨度 + 统一平移量）
SPAN = ("fence", "clothesline")
#: 各自的前后进深（决定 y 外移多少）
DEPTH = {"log_pile": 22.0, "plank_pile": 22.0, "cart": 46.0, "wheelbarrow": 40.0,
         "well": 40.0, "trough": 26.0, "haystack": 44.0, "bench": 28.0,
         "table": 34.0, "fence": 8.0, "grindstone": 26.0, "ladder": 14.0,
         "hay_fork": 12.0, "coal_pile": 34.0}


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
