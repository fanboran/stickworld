# -*- coding: utf-8 -*-
"""probe_city_scene.py —— 城市街景成图（管线 v3 · 写实 PBR）

做什么
------
把 `city_layout.plan_city()` 求解出的**确定性城市平面**真正搭出来渲染：临街建筑按
平面里的 x / 行深 / 分区摆放，各自挂上 `props.dress()` 的道具，背后立起城墙，前面
铺出主街 —— 也就是创始人要的"一个中世纪欧洲城市"的临街全景。

与 `city_layout.py` 的关系
--------------------------
布局器只出**数据**（plan dict）和平面图；本文件是它的**消费端**（前端渲染）。
只读 plan，不改布局器。

**已知落差（重要）**：布局器的 DEFS 表有 36 种建筑（29 + 行政阶梯 5：council_hall/
town_hall/city_hall/governor_palace/imperial_palace + belfry/mint），其中行政批次
已交付 6 个装配器（city_hall 待立项，过渡期映射 guildhall[16]，见 DEF_MAP TODO），
`buildings.ASSEMBLERS` 有 32 种。`DEF_MAP` 把暂缺的种类**映射**到最接近的装配器
（如 plaster_house→house、church/chapel→cathedral）；`well` / `market_stall` 本质是
道具，不能硬套建筑，走 `PROP_LOTS` 的**道具聚簇**（直接摆 `props.TABLE` 的件）。
布局器与装配器的宽度口径由 `city_layout.DEFS.widths` 的"可装配下限"保证对齐
（`validate.py` 检查 2/3 会实测这一条）。布局器 J3 投放的特殊建筑（mage_tower/
library/barracks/warehouse/alchemy）由 `DEF_MAP` 直接路由，无需另行处理。

跑法::
    blender -b --factory-startup -P probe_city_scene.py
    CITY_TIERS=village,town blender -b --factory-startup -P probe_city_scene.py

产物（stick-world/temp/）::
    pbr_city_<tier>.png       1 px/单位 = **游戏内真实大小**的临街全景
    pbr_city_<tier>_2x.png    2x 局部（看材质与道具细节）
    pbr_city_<tier>.json      本次成图用到的摆放清单（自检/复现用）
"""

import json
import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B          # noqa: E402
import city_layout as CL       # noqa: E402
import props as P              # noqa: E402

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
YAW = 0.0
TILT = 20.0          # main() 里可由 CITY_TILT 覆盖（总览图用更深俯角读出行深）
#: 行深拉伸：布局器的"行"之间只差建筑进深（5~6 格 ≈ 160~190 单位），在 20° 俯角下
#: 折算到屏幕垂直只有 ~55~65 单位，后一行会被前一行整个盖住。这里给每深一行额外
#: 后推 ROW_STRETCH，把行距在画面上拉开到可读——这是 2.5D 街景的常规美术手段
#: （"行距拉伸"），只改渲染摆放，不改布局数据。
ROW_STRETCH = 190.0
CELL = 32.0

#: 布局器 def → (装配器, 该装配器支持且**尽量不小于平面格宽**的宽度档)
#: 宽度档取自 buildings.py 的各 *_TIERS 表；挑最小的"够宽"档，不够就取最大档。
#: 布局器的 DEFS.widths 已按"可装配下限"裁过（见 city_layout.py 表头注释），
#: 所以每个 def 声明的每一档都能被这里路由到 ≤ 自身的装配宽度（不撑出地块）。
DEF_MAP = {
    "cottage":       ("cottage", [6, 8]),
    "house":         ("house", [8, 12, 16]),
    "plaster_house": ("house", [8, 12, 16]),
    "bakery":        ("bakery", [8, 12]),
    "shop":          ("shop", [8, 12]),
    "tavern":        ("tavern", [12, 16]),
    "townhouse":     ("townhouse", [12, 16]),
    "guildhall":     ("guildhall", [12, 16]),
    "hayloft":       ("hayloft", [8, 12]),
    "barn":          ("barn", [8, 12, 16]),
    # stable / shelter：D3b 起独立装配器（不再兜底 barn，消"深色木板墙读作黑盒子"）
    "stable":        ("stable", [8, 12]),
    "shelter":       ("shelter", [4, 6, 8]),
    # 第三轮魔法 / 公共 / 军政 / 物流线（city_layout.DEFS 已入表，宽度档与装配器
    # *_TIERS 一一对齐；J3 特殊建筑投放按 SPECIAL_DEFS 的区带权重落到院坝空段）
    "mage_tower":    ("mage_tower", [4, 6, 8]),
    "alchemy":       ("alchemy", [8, 12]),
    "library":       ("library", [12, 16]),
    "barracks":      ("barracks", [12, 16]),
    "warehouse":     ("warehouse", [12, 16]),
    "smithy1":       ("smithy1", [6, 8]),
    "smithy2":       ("smithy2", [8]),
    "smithy3":       ("smithy3", [8, 12]),
    "smithy4":       ("smithy4", [12]),
    "church":        ("cathedral", [12, 16]),
    # 小礼拜堂：村档核心 landmark（塔顶要压过全村）。8 格 = cathedral 的小教堂档，
    # 不另起装配器 —— 与教会语言同源（石砌 + 玫瑰窗 + 单钟楼尖顶），只是中殿压到一层半。
    "chapel":        ("cathedral", [8]),
    "tower":         ("tower", [4, 6]),
    "gatehouse":     ("gatehouse", [6, 8, 12]),
    "lighthouse":    ("lighthouse", [4, 6]),
    "windmill":      ("windmill", [4, 6, 8]),
    # ── 行政建筑阶梯（聚落等级与建筑分级.md §二，AI 提案/待定） ─────────
    # 行政批次已交付 4 装配器（council_hall/town_hall/governor_palace/
    # imperial_palace），映射到实名装配器；city_hall 暂无装配器（待 city_hall
    # 装配器立项后替换），过渡期按任务书 §二 由 guildhall[16] 兼。
    "council_hall":   ("council_hall", [8]),
    "town_hall":      ("town_hall", [12, 16]),
    "city_hall":      ("guildhall", [16]),      # TODO: 待 city_hall 装配器立项后替换
    "governor_palace": ("governor_palace", [16]),
    "imperial_palace": ("imperial_palace", [16]),
    # 天际线点缀/首府公共建筑（SPECIAL_DEFS 投放；装配器同批交付）
    "belfry":         ("belfry", [4, 6]),
    "mint":           ("mint", [12, 16]),
    # 批 2（驿站族/赌场族/科研族/花店，装配器同批交付实名）
    "waystation":     ("waystation", [6, 8]),
    "inn_post":       ("inn_post", [12, 16]),
    "coach_house":    ("coach_house", [12, 16]),
    "gambling_den":   ("gambling_den", [8, 12]),
    "grand_casino":   ("grand_casino", [16]),
    "academy":        ("academy", [12, 16]),
    "observatory":    ("observatory", [8]),
    "flower_shop":    ("flower_shop", [8, 12]),
}

#: 「道具型 lot」：这些 def 本身就是道具（§0.3「小物件例外」），既没有装配器，
#: 也不该硬套一个建筑装配器 —— 直接按聚簇配方把 `props.TABLE` 里的件摆在自己的
#: 地块上（不新增装配器、不改 props.py）。条目 = (道具名, 占地块宽比例, 前后偏移,
#: kwargs)；前后偏移 0 = 地块前进线，负值 = 更靠前（与 `dress()` 的门口前场同向）。
#: 尺寸统一乘 `P.GAME_SCALE`（与 `dress()` 同口径：不放大在游戏尺寸下读不出）。
#: **字典一律写字面量**：validate.py 用 ast.literal_eval 读这张表（不能是 dict(...) 调用）。
PROP_LOTS = {
    # 井：石井 + 井台边的盘绳 + 接水桶（村中心/院坝的固定组合）
    "well": [
        ("well",        0.00, -30.0, {"r": 26.0, "roof": True}),
        ("rope_coil",  -0.25, -14.0, {"r": 12.0}),
        ("water_butt",  0.16, -18.0, {"r": 16.0, "h": 54.0, "lid": True, "tap": True}),
    ],
    # 市集摊：摊篷 + **篷下的案桌**（market_table 允许摆在摊篷下，不横向叠占） +
    # 摊前两侧的筐货（摆在摊篷**之前**，不挤进摊位立柱与柜台之间）
    "market_stall": [
        ("market_stall",    0.00,  -26.0, {"w": 158.0, "d": 88.0, "h": 165.0,
                                          "cloth": "cloth_ochre"}),
        ("market_table",    0.00,  -50.0, {"w": 120.0, "d": 60.0, "goods": "produce"}),
        ("basket",         -0.30, -104.0, {"r": 15.0, "h": 16.0}),
        ("produce_baskets", 0.28, -110.0, {"r": 16.0, "h": 17.0}),
    ],
}

#: 装配器 → 道具配方键
DRESS_OF = {"smithy1": "smithy", "smithy2": "smithy", "smithy3": "smithy",
            "smithy4": "smithy", "rowhouse": "townhouse", "cottage": "house",
            "tavern": "townhouse", "bakery": "market", "shop": "shop",
            "guildhall": "cathedral", "hayloft": "barn"}

#: 布局器 def → 道具配方键（功能区决定前场道具）
#: 配方一律取自 `props.DRESS` 的既有键（**不新增、不改 props.py**）：
#: tavern→townhouse（含 hanging_sign）、shop→shop（布篷 + 铁艺招牌 + 面包架）、
#: bakery→market（市集摊 + 桶架 + 菜筐，面包房门口摆摊的老传统）、
#: guildhall→cathedral（门口灯柱 + 长凳 + 摊桌的市政/行会前场）。
#: 第三轮：mage_tower→alchemy（水晶簇 / 符文碑 / 水晶球，法师塔的魔法件）、
#: library→library（卷轴架 / 书堆 / 星盘 / 墨水瓶）、barracks→gatehouse（兵器架 /
#: 箭靶 / 盾牌 / 军旗，军政语言同源）、warehouse→market（货箱堆 / 麻袋堆 / 桶架；
#: props 既有配方里没有"推车 + 货箱"合一的套，推车在 barn 配方里、货箱在 market
#: 配方里，取货箱堆为仓储主读）、stable/hayloft/shelter→barn（料槽 / 草垛 / 车）。
DRESS_BY_DEF = {
    "smithy1": "smithy", "smithy2": "smithy", "smithy3": "smithy", "smithy4": "smithy",
    "tavern": "townhouse", "townhouse": "townhouse", "guildhall": "cathedral",
    "shop": "shop", "bakery": "market", "plaster_house": "townhouse",
    "barn": "barn", "stable": "barn", "hayloft": "barn", "shelter": "barn",
    "cottage": "house", "house": "house",
    "church": "cathedral", "chapel": "cathedral",
    "tower": "tower", "gatehouse": "gatehouse", "lighthouse": "lighthouse",
    "windmill": "windmill",
    # 第三轮新 def（配方一律取自 props.DRESS 既有键，不新增/不改 props.py）
    "mage_tower": "alchemy", "alchemy": "alchemy", "library": "library",
    "barracks": "gatehouse", "warehouse": "market",
    # 行政阶梯（装配器同批交付；市政/行政前场与 guildhall 同配方 = cathedral 键）
    "council_hall": "house", "town_hall": "cathedral", "city_hall": "cathedral",
    "governor_palace": "cathedral", "imperial_palace": "cathedral",
    "belfry": "tower", "mint": "smithy",
    # 批 2（配方取 props.DRESS 既有键；inn_post→townhouse 取挂招牌灯笼同源，
    # academy/observatory→library 取书堆星盘学术件，grand_casino→cathedral 取
    # 柱廊灯柱长凳门面前场）
    "waystation": "barn", "inn_post": "townhouse", "coach_house": "barn",
    "gambling_den": "shop", "grand_casino": "cathedral", "academy": "library",
    "observatory": "library", "flower_shop": "shop",
}

#: 挂墙件基准 y 需要显式覆盖的 def：**圆塔**（mage_tower）的包围盒最外沿是悬浮
#: 水晶伸出的位置（-1.4R），拿它当"前墙面"会把道具摆到塔身外一圈空气里。
#: 圆塔的真实前墙面 = 塔身切点 -D/2（= -R）。observatory 同为收分圆塔。
WALL_Y_DEPTH2 = {"mage_tower", "observatory"}


# ---------------------------------------------------------------- 场景

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()
    _MAT.clear()          # 自建材质也要作废（否则拿到已删除的 Material 引用）


def wipe():
    for ob in list(bpy.data.objects):
        if ob.type == "MESH":
            bpy.data.objects.remove(ob, do_unlink=True)


def setup_world():
    sc = bpy.context.scene
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        try:
            sc.render.engine = eng
            break
        except Exception:
            continue
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    for attr, val in (("taa_render_samples", 64), ("use_gtao", True)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass

    def sky(name, top, bottom, strength):
        w = bpy.data.worlds.new(name)
        sc.world = w
        w.use_nodes = True
        nt = w.node_tree
        bg = nt.nodes.get("Background") or nt.nodes.new("ShaderNodeBackground")
        bg.inputs[1].default_value = strength
        tc = nt.nodes.new("ShaderNodeTexCoord")
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        ramp = nt.nodes.new("ShaderNodeValToRGB")
        ramp.color_ramp.elements[0].color = bottom          # 地平线：暖白
        ramp.color_ramp.elements[1].color = top             # 天顶：冷蓝
        nt.links.new(tc.outputs["Generated"], sep.inputs["Vector"])
        nt.links.new(sep.outputs["Z"], ramp.inputs["Fac"])
        nt.links.new(ramp.outputs["Color"], bg.inputs[0])
        return w

    sky("W", (0.42, 0.56, 0.80, 1.0), (0.74, 0.76, 0.74, 1.0), 0.55)

    def sun(name, energy, rot, angle=3.0, color=(1.0, 0.95, 0.85)):
        d = bpy.data.lights.new(name, "SUN")
        d.energy = energy
        d.angle = math.radians(angle)
        d.color = color
        ob = bpy.data.objects.new(name, d)
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
        sc.collection.objects.link(ob)
        return ob

    sun("key", 3.5, (42, 0, -34), 2.5, (1.0, 0.93, 0.80))
    sun("fill", 0.22, (58, 0, 126), 20.0, (0.80, 0.87, 1.0))
    sun("bounce", 0.30, (-28, 0, 6), 45.0, (0.95, 0.80, 0.62))
    return sc


_MAT = {}


def _mat(name, maker):
    """自建材质缓存。**不能用 dict.setdefault(name, maker())**——默认参数会先求值，
    于是每次调用都新建一个材质（既浪费又会漏进 bpy.data）。"""
    if name not in _MAT:
        _MAT[name] = maker()
    return _MAT[name]


def ground_material():
    m = bpy.data.materials.new("city_ground")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.96
    bsdf.inputs["Base Color"].default_value = (0.58, 0.49, 0.33, 1.0)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (0.02, 0.02, 0.02)
    nz = nt.nodes.new("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 6.0
    nz.inputs["Detail"].default_value = 6.0
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.34
    ramp.color_ramp.elements[0].color = (0.42, 0.34, 0.22, 1.0)
    ramp.color_ramp.elements[1].position = 0.76
    ramp.color_ramp.elements[1].color = (0.70, 0.60, 0.41, 1.0)
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.30
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], nz.inputs["Vector"])
    nt.links.new(nz.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(nz.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def road_material():
    """街道铺装：湿冷石板的读法（比暖沙地面暗、偏冷），把主街从地面里"切"出来。"""
    m = bpy.data.materials.new("city_road")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.88
    bsdf.inputs["Base Color"].default_value = (0.32, 0.31, 0.29, 1.0)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    vn = nt.nodes.new("ShaderNodeTexVoronoi")
    vn.inputs["Scale"].default_value = 26.0
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.20, 0.195, 0.185, 1.0)
    ramp.color_ramp.elements[1].color = (0.44, 0.43, 0.40, 1.0)
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.35
    nt.links.new(tc.outputs["Object"], vn.inputs["Vector"])
    nt.links.new(vn.outputs["Distance"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(vn.outputs["Distance"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def quad(name, x0, x1, y0, y1, z, material):
    me = bpy.data.meshes.new(name + "_mesh")
    me.from_pydata([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], [], [(0, 1, 2, 3)])
    me.materials.append(material)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def city_wall(b, x0, x1, y, h, mat="stone_dark", thick=28.0, merlon=30.0):
    """城墙：墙身 + 垛口 + 墙基放脚（背后高墙是"围城"的读法来源）。"""
    B.wall_block(b, x1 - x0, h, thick, mat, x=(x0 + x1) / 2.0, y=y, z=0.0)
    b.box_bottom((x1 - x0 + 10.0, thick + 12.0, 22.0), ((x0 + x1) / 2.0, y), 0.0,
                 "stone_dark")
    B.crenellation(b, x1 - x0, thick, h, mat, x=(x0 + x1) / 2.0, y=y,
                   merlon=merlon, gap=20.0, h=30.0)


def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 60000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def place_camera(cam, anchor, dist=12000.0):
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * dist)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))


def shoot(cam, objs, zoom, path, pad=40.0, pad_top=30.0, res_max=14000):
    pts = []
    for ob in objs:
        pts += B.shape_points(ob, skip_ground=False)
    right, up = B.cam_axes(YAW, TILT)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = min(us) - pad, max(us) + pad
    v0, v1 = min(vs) - pad, max(vs) + pad_top
    w, h = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = pts[0]
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))
    place_camera(cam, anchor)
    k = min(1.0, res_max / float(max(w, h) * zoom))
    rx = max(64, int(round(w * zoom * k)))
    ry = max(64, int(round(h * zoom * k)))
    cam.data.ortho_scale = max(w, h)
    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    sc.render.resolution_percentage = 100
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("-> %s  %dx%d  (%.2f px/unit)" % (os.path.basename(path), rx, ry, zoom * k))
    return {"path": path, "res": (rx, ry)}


# ---------------------------------------------------------------- 成图

def pick_width(want, allowed):
    """挑**不大于**平面格宽的最大支持档（避免建筑撑出自己的地块、和邻居横向叠上）；
    都太大就退回最小档。"""
    smaller = [w for w in allowed if w <= want]
    return max(smaller) if smaller else min(allowed)


def build_prop_lot(defn, lot, seed=0):
    """道具型 lot（well / market_stall）：把 `PROP_LOTS` 的聚簇配方摆在本地原点附近。

    坐标约定与建筑一致：返回对象的 (0,0,0) 就是**地块前进线中点**，调用方按
    "世界 y = -baseline_y + 行距拉伸"平移即可；配方里的 y 偏移为负 = 更靠前。
    """
    pw = float(lot["w_cells"]) * CELL
    b = B.Builder("proplot_%d_%s" % (lot["index"], defn))
    placed = []
    for (pname, xf, yoff, kw) in PROP_LOTS[defn]:
        fn = P.TABLE.get(pname)
        if fn is None:
            print("!! 道具型 lot %s 的配方含未注册道具 %s" % (defn, pname))
            continue
        p = {k: v for k, v in kw.items()}
        for k in ("r", "h", "w", "d", "s"):
            if k in p:
                p[k] = p[k] * P.GAME_SCALE          # 与 dress() 同口径
        x = xf * pw
        try:
            fn(b, x=x, y=yoff, z=0.0, seed=int(seed), **p)
        except TypeError:
            fn(b, x=x, y=yoff, z=0.0, **p)
        placed.append((pname, round(x, 1), yoff))
    return b.to_object(), placed


def build_city(tier, seed=611036, rows=(0,), report=None):
    """按 plan 摆放临街建筑（rows 指定参与渲染的行深档）。

    **坐标换算（踩过坑，务必看懂）**：布局器的 `baseline_y` 越大表示越靠**前**（南），
    而本管线的世界坐标里 **-Y = 正前方**（相机在 -Y 侧向 +Y 看，且俯角 20° 朝下，
    所以 y 越大在画面上越高、越远）。两者方向相反，故 世界 y = **-baseline_y**。
    第一版直接把 baseline_y 当世界 y 用，结果**城墙跑到建筑前面**、把整条街的下半截
    全糊住了。

    另外建筑在各自装配器里是**以原点为中心**（进深向 ±Y 各半）建模的，而 `baseline_y`
    指的是"前墙面落地线"，所以摆放时要按实测把**前墙面**对齐到 -baseline_y，不能
    直接放原点。
    """
    plan = CL.plan_city(tier, seed)
    objs = []
    placed = []
    skipped = []
    ys = []
    for lot in sorted(plan["lots"], key=lambda l: (l["row"], l["x_px"])):
        if lot["row"] not in rows:
            continue
        cx = lot["x_px"] + lot["w_px"] / 2.0
        # ---- 道具型 lot（well / market_stall）：不走装配器，摆一组道具
        if lot["def"] in PROP_LOTS:
            ob, _placed = build_prop_lot(
                lot["def"], lot, seed=lot["index"] * 37 + (seed % 1000))
            dy = -float(lot["baseline_y"]) + lot["row"] * ROW_STRETCH
            ob.location = (cx, dy, 0.0)
            bpy.context.view_layer.update()
            objs.append(ob)
            mx = B.measure(ob)
            ys.append((mx["y"][0], mx["y"][1], lot))
            placed.append({"index": lot["index"], "def": lot["def"],
                           "zone": lot["zone"], "row": lot["row"], "asm": "@props",
                           "cells": int(lot["w_cells"]), "x": round(cx, 1),
                           "y": round(dy, 1)})
            continue
        m = DEF_MAP.get(lot["def"])
        if m is None:
            skipped.append(lot["def"])
            continue
        asm, allowed = m
        wc = pick_width(int(lot["w_cells"]), allowed)
        try:
            ob, spec = B.ASSEMBLERS[asm](wc)
        except Exception as exc:
            print("!! %s(%s->%d) 装配失败：%s" % (lot["def"], asm, wc, exc))
            skipped.append(lot["def"])
            continue
        front_local = B.measure(ob)["y"][0]
        # 道具层：以本地前墙面为基准挂载，再与建筑一起平移（保证道具贴在同一面墙上）
        pob = None
        kind = DRESS_BY_DEF.get(lot["def"])
        if kind:
            pb = B.Builder("props_%d" % lot["index"])
            d = spec.get("door")
            # 圆塔（mage_tower）：前墙面取塔身切点 -D/2，不取含水悬浮水晶的包围盒外沿
            wall_y = (-spec["depth"] / 2.0
                      if lot["def"] in WALL_Y_DEPTH2 else None)
            P.dress(pb, kind, spec["grid_w"], front_local,
                    seed=lot["index"] * 37 + (seed % 1000),
                    door_x=spec.get("door_x", 0.0), door_w=(d[0] if d else 0.0),
                    wall_y=wall_y)
            pob = pb.to_object()
        dy = -float(lot["baseline_y"]) - front_local + lot["row"] * ROW_STRETCH
        ob.location = (cx, dy, 0.0)
        if pob is not None:
            pob.location = (cx, dy, 0.0)
        bpy.context.view_layer.update()
        objs.append(ob)
        if pob is not None:
            objs.append(pob)
        mx = B.measure(ob)
        ys.append((mx["y"][0], mx["y"][1], lot))
        placed.append({"index": lot["index"], "def": lot["def"], "zone": lot["zone"],
                       "row": lot["row"], "asm": asm, "cells": wc,
                       "x": round(cx, 1), "y": round(dy, 1)})
    # 城墙：立在所有建筑**背后**（世界 y 更大 = 更远），height 取平面档的墙高。
    # 跨度按**实际用到的建筑横向范围**取，不要按平面全宽——平面留有大量余量带，
    # 按全宽拉墙会把画面撑成"一堵空墙 + 中间一小撮房子"。
    wh = plan["params"]["wall_h_px"]
    wall_y = None
    if wh:
        wall_y = max(b for (_a, b, _l) in ys) + 160.0
        bx0 = min(B.measure(o)["x"][0] for o in objs)
        bx1 = max(B.measure(o)["x"][1] for o in objs)
        wb = B.Builder("city_wall")
        # 墙体材质按档：tier 1 石 / tier 2 深色石 / tier 3 砖（capital 520 /
        # metropolis 640，任务书 §一；既有档判定不变 → 旧图零漂移）
        wall_mat = ("brick" if plan["wall_tier"] >= 3
                    else "stone_dark" if plan["wall_tier"] >= 2 else "stone")
        city_wall(wb, bx0 - 340.0, bx1 + 340.0, wall_y, wh, wall_mat)
        wob = wb.to_object()
        objs.append(wob)
        placed.append({"index": -1, "def": "city_wall", "zone": "wall", "row": -1,
                       "asm": "-", "cells": 0, "x": 0.0, "y": round(wall_y, 1)})
    if report is not None:
        report["placed"] = placed
        report["skipped_defs"] = sorted(set(skipped))
        report["plan_specials"] = plan.get("specials", [])
        report["plan_admin_slots"] = plan.get("admin_slots", [])
        report["plan_checks"] = plan.get("checks", {})
        report["tier"] = tier
        report["seed"] = seed
        report["width_px"] = plan["width_px"]
        report["rows"] = list(rows)
    # 地面 + 主街铺装（主街在临街建筑**前方**，即世界 y 更小的一侧）
    front = min(a for (a, _b, _l) in ys)
    back = max(b for (_a, b, _l) in ys)
    x0 = min(B.measure(o)["x"][0] for o in objs) - 600.0
    x1 = max(B.measure(o)["x"][1] for o in objs) + 600.0
    quad("ground", x0, x1, front - 900.0, back + 900.0, -1.0,
         _mat("g", ground_material))
    quad("road", x0, x1, front - 6.0 * CELL, front + 2.0, 0.6,
         _mat("r", road_material))
    return plan, objs


def main():
    global TILT, ROW_STRETCH
    os.makedirs(OUT_DIR, exist_ok=True)
    TILT = float(os.environ.get("CITY_TILT", "20"))
    ROW_STRETCH = float(os.environ.get("CITY_ROW_STRETCH", str(ROW_STRETCH)))
    tiers = os.environ.get("CITY_TIERS", "village,town").split(",")
    rows = tuple(int(v) for v in os.environ.get("CITY_ROWS", "0").split(",") if v != "")
    tag = os.environ.get("CITY_TAG", "")
    for tier in tiers:
        tier = tier.strip()
        if not tier:
            continue
        clear()
        setup_world()
        cam = make_camera()
        report = {}
        plan, objs = build_city(tier, seed=611036, rows=rows, report=report)
        print("[%s] 临街面 %d 栋（行深 %s，俯角 %.0f°，行距拉伸 %.0f）；跳过的种类：%s"
              % (tier, len(report["placed"]) - 1, rows, TILT, ROW_STRETCH,
                 ",".join(report["skipped_defs"]) or "无"))
        shoot(cam, objs, 1.0, os.path.join(OUT_DIR, "pbr_city_%s%s.png" % (tier, tag)),
              pad=60.0, pad_top=40.0)
        shoot(cam, objs, 2.0, os.path.join(OUT_DIR, "pbr_city_%s%s_2x.png" % (tier, tag)),
              pad=60.0, pad_top=40.0)
        with open(os.path.join(OUT_DIR, "pbr_city_%s%s.json" % (tier, tag)), "w",
                  encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=1)
    print("\nCITY_SCENE_OK")


main()
