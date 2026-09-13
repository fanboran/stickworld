# -*- coding: utf-8 -*-
"""interiors.py —— 建筑内景层（back）+ 前/后两层交付（管线 v3 · 写实 PBR）

这份文件干两件事
----------------
1. **内景库**：为 house / townhouse / smithy1 / tavern / bakery / shop / cathedral
   各建一套室内陈设（后墙 + 地板 + 天花梁 + 家具 + 暖色点光），供游戏的
   `Interior` 层使用。
2. **前/后两层交付**：把一栋建筑拆成"后层（内景）"与"前层（前墙 + 屋顶 + 门窗框）"
   两张带 alpha 的 PNG，对接既有机制
   `docs/技术/架构/场景与战斗/地图与场景图.md` §5.2「小型建筑 - 墙面透明化」：
   玩家进交互区 → `WallFront.modulate.a = 0.3` + `Interior.visible = true`。
   这一机制能成立，是因为**前层 PNG 的窗玻璃像素是真透明的**（alpha 会被 0.3 加权），
   后层 PNG 直接叠在它后面。

坐标与尺规（与 buildings.py / props.py 完全一致）
-------------------------------------------------
* 正面 = **-Y**；世界 z 向上、地面 z = 0；建筑本体以原点为中心、进深向 ±Y 各半。
* 1 格 = 32 单位 = 0.42m；门高 153、单层檐高 205~210（交接档 §0.3）。
* 内景定尺**全部从 `buildings.py` 的 tier 表读取**，本文件不复制任何尺寸数字 ——
  宽度/层高口径改动时内景自动跟随。
* 家具复用 `props.py` 的积木，按 `GAME_SCALE`（1.45）放大到游戏内可辨尺寸。

前/后切分怎么做的
-----------------
前层不是手搓立面，而是**直接复用 `buildings.ASSEMBLERS[def]` 的成品**，再用
`crop_back_half()` 沿 y=0 把"檐口以下的后半栋"（后墙/后半侧墙/地板/室内器物）切掉，
只留**前墙 + 门窗 + 屋顶 + 山墙 + 烟囱 + 老虎窗**（前视 yaw=0 下侧墙与山墙端面本就
投影成线，所以前层 = 正面可见的全部外皮，既喂 `Exterior` 也喂 `WallFront`）。
切完把窗玻璃换成 `thin_glass()`（真透明），教堂除外（保留彩窗）。

**本批不改 materials.py**：现有 `glass_clear` 是"纯透射"材质，实测在
`film_transparent` 下渲染 alpha = 255（不透明），分层合成时窗格会把内景整块挡住。
`thin_glass()` 是本文件内的临时替身（Alpha 混合），只用于本批出图；
materials.py 的最小改动清单见交接报告。
"""

import math

import bpy

import buildings as B
import props as P

CELL = B.CELL
GAME = P.GAME_SCALE          # 1.45，与道具层同源

#: 内景临时真透明窗玻璃的材质名（见文件头说明）
THIN_GLASS = "glass_clear_thin"

#: 前层里"清水窗玻璃"的槽位名（buildings.material("glass") → 槽名就是 "glass"）
_CLEAR_GLASS_SLOTS = ("glass", "glass_win")


# ================================================================ §1 真透明窗玻璃

def thin_glass(alpha=0.07):
    """本批临时的"真透明"窗玻璃：Principled Alpha 混合，每面 alpha≈0.07。

    `window()` 里窗玻璃是一块**有厚度的盒**（前后两个面），两面各 alpha=a 叠加后
    净 alpha ≈ 1-(1-a)² ≈ 0.135 → 合成时约 86% 透到后面的内景，玻璃只留一层淡青
    薄纱（给到 0.12 时净 0.23，实拍窗格发奶白、内景糊掉，故压到 0.07）。
    观感刻意贴近 `materials.glass_clear`（浅青底 + 低粗糙 + 一点镜面），
    只把"透射"换成"alpha 混合"，这样它才进 alpha 通道、能被 `WallFront` 的 0.3 加权。
    """
    m = bpy.data.materials.get(THIN_GLASS)
    if m is None:
        m = bpy.data.materials.new(THIN_GLASS)
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
        bsdf.inputs["Base Color"].default_value = (0.46, 0.53, 0.53, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.05
        try:
            bsdf.inputs["Specular IOR Level"].default_value = 0.55
        except Exception:
            pass
        try:
            bsdf.inputs["IOR"].default_value = 1.45
        except Exception:
            pass
        nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
        for attr, val in (("surface_render_method", "BLENDED"),
                          ("blend_method", "BLEND"),
                          ("use_transparent_shadow", True),
                          ("show_transparent_back", True)):
            try:
                setattr(m, attr, val)
            except Exception:
                pass
    for nd in m.node_tree.nodes:
        if nd.type == "BSDF_PRINCIPLED":
            nd.inputs["Alpha"].default_value = float(alpha)
    m.diffuse_color = (0.46, 0.53, 0.53, float(alpha))
    B._CACHE[THIN_GLASS] = m          # 让 buildings.material() 能取到（只读调用）
    return m


# ================================================================ §2 内景定尺

#: 交付清单 def → 宽度档。房子/店铺类取 **12 格档**：8 格档内净深只 ~1.5m，
#: 摆不下"床 + 桌 + 炉"三件（真去 8 格档会互相穿模），12 格档内净深 ~2.2m 才立得住。
#: 小体量 def（cottage/shelter/stable 小档）**只有 8 格及以下档**，走"紧凑内景"
#: （更少家具、贴墙摆、进深只够一条通道），见各 builder 注释与 `COMPACT` 集合。
_WIDTHS = {
    # —— 首轮已具备的 7 套
    "house": 12, "townhouse": 12, "smithy1": 8, "tavern": 12,
    "bakery": 12, "shop": 12, "cathedral": 16,
    # —— 扩展轮新增 19 个装配器 def
    "barn": 12, "cottage": 8, "stable": 12, "shelter": 6, "hayloft": 12,
    "guildhall": 12, "smithy2": 8, "smithy3": 12, "smithy4": 12,
    "barracks": 12, "warehouse": 12, "alchemy": 12, "library": 12,
    "rowhouse": 12, "windmill": 6, "tower": 6, "gatehouse": 8,
    "mage_tower": 6, "lighthouse": 6,
    # —— 3 个**别名 def**（无独立装配器，front 走 DEF_MAP 的目标装配器）
    "plaster_house": 12, "church": 12, "chapel": 8,
}

#: 别名 def → 前层实际使用的 (装配器名, 宽度档)。与 `probe_city_scene.DEF_MAP` 同源，
#: 保证"前层 PNG = 该 def 在城市里真正被渲成的装配器"，后层内景与它严格对齐。
_FRONT_ALIAS = {
    "plaster_house": ("house", 12),      # DEF_MAP: plaster_house → house
    "church": ("cathedral", 12),         # DEF_MAP: church → cathedral
    "chapel": ("cathedral", 8),          # DEF_MAP: chapel → cathedral 小教堂档
}

#: 圆塔类 def（后壁是"半圆内表面"而非平板，走 `_round_shell`）
ROUND_DEFS = {"windmill", "mage_tower", "lighthouse"}

#: 「紧凑内景」def：8 格及以下 / 净进深浅，家具只够贴墙一排 + 一条通道
COMPACT = {"cottage", "shelter", "gatehouse", "stable"}


def defs():
    return dict(_WIDTHS)


def front_def(def_name, wc=None):
    """前层实际使用的 (装配器名, 宽度档)：别名解引用，其余同名同档。"""
    if def_name in _FRONT_ALIAS:
        return _FRONT_ALIAS[def_name]
    return (def_name, wc or _WIDTHS[def_name])


def layout(def_name, wc=None):
    """内景净尺寸：全部从 buildings 的 tier 表读，本文件不复制数字。"""
    wc = wc or _WIDTHS[def_name]
    if def_name == "house":
        t = B.HOUSE_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["wall"], eave=t["plinth"] + t["wall"],
                 floor="wood_deck", wall_low="plaster", wall_up="plaster")
    elif def_name == "townhouse":
        t = B.TOWNHOUSE_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=t["storey"], back_h=t["storey"] * 2.0,
                 eave=t["plinth"] + t["storey"] * 2.0,
                 floor="wood_deck", wall_low="plaster_old", wall_up="plaster_old")
    elif def_name == "smithy1":
        t = B.SMITHY1_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=0.0, wt=14.0, storey=None,
                 back_h=t["post_h"], eave=t["post_h"], open_front=True,
                 floor="dirt_packed", wall_low="wood_light", wall_up="wood_light")
    elif def_name == "tavern":
        t = B.TAVERN_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=t["storey"], back_h=t["storey"] * 2.0,
                 eave=t["plinth"] + t["storey"] * 2.0,
                 floor="stone_flag", wall_low="stone", wall_up="plaster_old")
    elif def_name == "bakery":
        t = B.BAKERY_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["wall"], eave=t["plinth"] + t["wall"],
                 floor="stone_flag", wall_low="brick", wall_up="brick")
    elif def_name == "shop":
        t = B.SHOP_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["storey"], eave=t["plinth"] + t["storey"],
                 floor="wood_deck", wall_low="wood", wall_up="wood")
    elif def_name == "cathedral":
        t = B.CATHEDRAL_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["nave_h"], eave=t["plinth"] + t["nave_h"],
                 floor="stone_flag", wall_low="stone", wall_up="stone")
    # ---------------------------------------------------------- 别名 def
    elif def_name == "plaster_house":
        # 前层走 house 装配器（DEF_MAP），后层与它同尺；家具与 house 同源、墙材换抹灰。
        t = B.HOUSE_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["wall"], eave=t["plinth"] + t["wall"],
                 floor="wood_deck", wall_low="plaster", wall_up="plaster")
    elif def_name in ("church", "chapel"):
        t = B.CATHEDRAL_TIERS[wc]            # chapel 只有 8 格档（= 小教堂档）
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["nave_h"], eave=t["plinth"] + t["nave_h"],
                 floor="stone_flag", wall_low="stone", wall_up="stone",
                 small=(def_name == "chapel"))
    # ---------------------------------------------------------- 农业线
    elif def_name == "barn":
        t = B.BARN_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["wall"], eave=t["plinth"] + t["wall"],
                 floor="wood_deck", wall_low="plaster_old",
                 wall_up="plaster_old")
    elif def_name == "cottage":
        t = B.COTTAGE_TIERS[wc]              # 只有 6/8 档 → 紧凑内景
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["wall"], eave=t["plinth"] + t["wall"],
                 floor="wood_deck", wall_low="plaster", wall_up="plaster")
    elif def_name == "stable":
        t = B.STABLE_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["low"], eave=t["plinth"] + t["low"],
                 floor="dirt_packed", wall_low="stone", wall_up="wood_light")
    elif def_name == "shelter":
        t = B.SHELTER_TIERS[wc]              # 三面开敞，只有四角柱
        L = dict(W=wc * CELL, D=t["D"], plinth=0.0, wt=float(t["post"]),
                 storey=None, back_h=t["post_h"], eave=t["post_h"],
                 open_front=True, floor="dirt_packed",
                 wall_low="wood_light", wall_up="wood_light")
    elif def_name == "hayloft":
        t = B.HAYLOFT_TIERS[wc]              # 石砌底层 + 开敞草棚上层
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=t["low"], back_h=t["low"] + t["up"],
                 eave=t["plinth"] + t["low"] + t["up"],
                 floor="stone_flag", wall_low="stone", wall_up="wood_light")
    # ---------------------------------------------------------- 公共 / 军事 / 物流
    elif def_name == "guildhall":
        t = B.GUILDHALL_TIERS[wc]
        st = t["storey"]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=st, back_h=st * 2.0, eave=t["plinth"] + st * 2.0,
                 floor="stone_flag", wall_low="stone", wall_up="plaster_old")
    elif def_name == "barracks":
        t = B.BARRACKS_TIERS[wc]
        st = t["storey"]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=st, back_h=st * 2.0, eave=t["plinth"] + st * 2.0,
                 floor="stone_flag", wall_low="stone", wall_up="plaster_old")
    elif def_name == "warehouse":
        t = B.WAREHOUSE_TIERS[wc]            # 高勒脚单层通高货仓
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["wall"], eave=t["plinth"] + t["wall"],
                 floor="stone_flag", wall_low="brick", wall_up="brick")
    elif def_name == "library":
        t = B.LIBRARY_TIERS[wc]
        st = t["storey"]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=st, back_h=st * 2.0, eave=t["plinth"] + st * 2.0,
                 floor="stone_flag", wall_low="stone", wall_up="stone")
    elif def_name == "rowhouse":
        t = B.ROWHOUSE_TIERS[wc]
        sts = list(t["storeys"])
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=sts[0], storeys=sts, back_h=sum(sts),
                 eave=t["plinth"] + sum(sts),
                 floor="stone_flag", wall_low="brick", wall_up="plaster_old",
                 wall_mid="plaster_old")
    # ---------------------------------------------------------- 工坊线
    elif def_name == "smithy2":
        t = B.SMITHY2_TIERS[wc]              # 半封闭大铁匠铺（双炉）
        L = dict(W=wc * CELL, D=t["D"], plinth=0.0, wt=float(t["post"]),
                 storey=None, back_h=t["post_h"], eave=t["post_h"],
                 floor="dirt_packed", wall_low="wood_light", wall_up="wood_light")
    elif def_name == "smithy3":
        t = B.SMITHY3_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["wall"], eave=t["plinth"] + t["wall"],
                 floor="stone_flag", wall_low="stone", wall_up="stone")
    elif def_name == "smithy4":
        t = B.SMITHY4_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["wall"], eave=t["plinth"] + t["wall"],
                 floor="stone_flag", wall_low="brick", wall_up="brick")
    elif def_name == "alchemy":
        t = B.ALCHEMY_TIERS[wc]
        L = dict(W=wc * CELL, D=t["D"], plinth=t["plinth"], wt=t["wt"],
                 storey=None, back_h=t["wall"], eave=t["plinth"] + t["wall"],
                 floor="stone_flag", wall_low="brick", wall_up="brick")
    # ---------------------------------------------------------- 塔类（圆塔 / 方形退台）
    elif def_name == "windmill":
        t = B.WINDMILL_TIERS[wc]
        L = dict(W=t["R"] * 2.0, D=t["R"] * 2.0, plinth=t["plinth"], wt=12.0,
                 storey=t["tower_h"] * 0.5, back_h=t["tower_h"],
                 eave=t["plinth"] + t["tower_h"], round=True, R=t["R"],
                 taper=t["taper"], floor="wood_deck",
                 wall_low="stone", wall_up="stone")
    elif def_name == "mage_tower":
        t = B.MAGE_TOWER_TIERS[wc]
        sec = max(1, int(t["sec"]))
        L = dict(W=t["R"] * 2.0, D=t["R"] * 2.0, plinth=t["plinth"], wt=12.0,
                 storey=t["tower_h"] / sec, back_h=t["tower_h"],
                 eave=t["plinth"] + t["tower_h"], round=True, R=t["R"],
                 taper=t["taper"], floor="stone_flag",
                 wall_low="stone", wall_up="stone")
    elif def_name == "lighthouse":
        t = B.LIGHTHOUSE_TIERS[wc]
        L = dict(W=t["R"] * 2.0, D=t["R"] * 2.0, plinth=t["plinth"], wt=12.0,
                 storey=t["tower_h"] * 0.55, back_h=t["tower_h"],
                 eave=t["plinth"] + t["tower_h"], round=True, R=t["R"],
                 taper=t["taper"], floor="stone_flag",
                 wall_low="white_stone", wall_up="white_stone")
    elif def_name == "tower":
        t = B.TOWER_TIERS[wc]
        W = wc * CELL
        L = dict(W=W, D=t["D"], plinth=t["plinth"], wt=16.0,
                 storey=t["body_h"] / 3.0, storeys=[t["body_h"] / 3.0] * 3,
                 back_h=t["body_h"],
                 eave=t["plinth"] + t["body_h"], stepped=True,
                 step_w=(W, W - 9.0, W - 18.0), floor="stone_flag",
                 wall_low="stone", wall_up="stone")
    elif def_name == "gatehouse":
        t = B.GATEHOUSE_TIERS[wc]            # 内景 = **门洞通道**（净宽 = 拱洞宽）
        rect_h = {6: 134.0, 8: 136.0, 12: 132.0}[wc]
        clear = rect_h + t["gate_w"] * 0.5
        L = dict(W=t["gate_w"], D=t["D"], plinth=t["plinth"], wt=10.0,
                 storey=None, back_h=clear, eave=t["plinth"] + clear,
                 floor="cobble_small", wall_low="stone", wall_up="stone",
                 gate_clear=clear)
    else:
        raise KeyError("无内景定义: %s" % def_name)

    L["def"] = def_name
    L["wc"] = wc
    L["xh"] = L["W"] / 2.0 - L["wt"]
    L["yb"] = L["D"] / 2.0 - L["wt"]
    L["yf"] = -(L["D"] / 2.0) + L["wt"]
    if L.get("open_front"):                     # 开放棚：前方无墙，地板推到檐柱跟前
        L["yf"] = -(L["D"] / 2.0) + 10.0
        L["xh"] = L["W"] / 2.0 - 7.0
    L["yc"] = (L["yb"] + L["yf"]) / 2.0
    L["depth"] = L["yb"] - L["yf"]
    L["ceil"] = L["plinth"] + L["back_h"]
    L["mid"] = (L["plinth"] + L["storey"]) if L["storey"] else None
    # 多层楼板标高列表（单层 = [plinth]；两层 = [plinth, mid]；三层 = [plinth, m1, m2]）
    if L.get("storeys"):
        zs, acc = [L["plinth"]], L["plinth"]
        for st in L["storeys"][:-1]:
            acc += st
            zs.append(acc)
        L["mids"] = zs
    elif L["storey"]:
        L["mids"] = [L["plinth"], L["plinth"] + L["storey"]]
    else:
        L["mids"] = [L["plinth"]]
    return L


# ================================================================ §3 通用构件

#: 家具尺寸：props 的积木统一按 GAME_SCALE 放大（与道具层同源）
def _prop(fn, b, scale=GAME, seed=17, **kw):
    """调 props.py 的积木：尺寸键按 GAME_SCALE 放大，x/y/z 保持绝对布局坐标。

    注意：放大系数参数名必须叫 `scale`（不能叫 `s`）—— props 的多数积木用 `s`
    作**尺寸**关键字，两者同名会把 `s=28` 当成倍数，几何直接飞到天上。
    """
    kw = dict(kw)
    for k in ("r", "h", "w", "d", "s"):
        v = kw.get(k)
        if isinstance(v, (int, float)):
            kw[k] = float(v) * scale
    kw.setdefault("seed", seed)
    try:
        return fn(b, **kw)
    except TypeError:
        kw.pop("seed", None)
        return fn(b, **kw)


def _shell(b, L, storey_split=False, ceiling=False, openings=()):
    """后墙（可上下分段）+ 地板 + 踢脚 + 可选二层楼板。

    **不做天花/顶梁**：屋顶在前层（前视里正好盖在檐口以上），后层再压一块天花只会
    在"只看后层"时糊成一片黑，且在最终合成里被屋顶完全遮住 —— 纯浪费。
    `openings` = 后墙真洞（通风窗/阁楼口），洞后必须自己压一块 `cavity` 挡板，
    否则会直接透到透明的世界背景（合成时读作"墙上破了个洞看到天空"）。
    """
    W, D, wt, plinth = L["W"], L["D"], L["wt"], L["plinth"]
    h, yb, yf = L["back_h"], L["yb"], L["yf"]
    xh, depth, yc = L["xh"], L["depth"], L["yc"]
    if L.get("wall_segments"):                  # 只封部分高度（草棚/畚棚）
        zz = plinth
        for seg_h, seg_mat in L["wall_segments"]:
            B.wall_panel(b, W, seg_h, wt, seg_mat, 0.0, D / 2.0 - wt / 2.0, zz)
            zz += seg_h
    elif L.get("open_front"):
        B.wall_panel(b, W, h, wt, L["wall_low"], 0.0, D / 2.0 - wt / 2.0, plinth)
    elif storey_split and L["wall_up"] != L["wall_low"]:
        st = L["storey"]
        B.wall_panel(b, W, st, wt, L["wall_low"], 0.0, D / 2.0 - wt / 2.0, plinth)
        B.wall_panel(b, W, h - st, wt, L["wall_up"], 0.0, D / 2.0 - wt / 2.0,
                     plinth + st)
    else:
        B.wall_panel(b, W, h, wt, L["wall_low"], 0.0, D / 2.0 - wt / 2.0, plinth,
                     openings=openings)
    # 地板 + 踢脚
    b.box_bottom((xh * 2.0, depth, 4.0), (0.0, yc), plinth - 4.0, L["floor"])
    b.box_bottom((xh * 2.0, 3.0, 10.0), (0.0, yb - 1.5), plinth, "wood_dark")
    for sx in (-1.0, 1.0):
        b.box_bottom((3.0, depth, 10.0), (sx * (xh - 1.5), yc), plinth, "wood_dark")
    # 楼板（每个上层标高一块：上下真的分成几层，必须留）
    upper = [zz for zz in L.get("mids", []) if zz > plinth + 1.0]
    for k, zz in enumerate(upper):
        b.box_bottom((xh * 2.0, depth, 7.0), (0.0, yc), zz - 7.0, "timber")
        b.box_bottom((xh * 2.0, depth, 9.0), (0.0, yc), zz, "wood_deck")
        b.box_bottom((xh * 2.0, 9.0, 12.0), (0.0, yc), zz - 19.0, "timber")


def _bed(b, x, y, z, ln=150.0, w=78.0, head=1.0, mat="wood_light",
         cloth="cloth_blue"):
    """床（床长沿 X；尺寸单位 = 世界单位，调用方自行决定是否已放大）。"""
    b.box_bottom((ln, w, 7.0), (x, y), z + 30.0, mat)
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            b.box_bottom((8.0, 8.0, 30.0),
                         (x + sx * (ln / 2.0 - 6.0), y + sy * (w / 2.0 - 6.0)),
                         z, "wood_dark")
    b.box_bottom((ln - 6.0, w - 10.0, 12.0), (x, y), z + 37.0, "canvas")
    b.box_bottom((ln - 4.0, w * 0.56, 9.0), (x - head * ln * 0.16, y), z + 46.0, cloth)
    b.box_bottom((ln * 0.20, w - 16.0, 8.0), (x + head * ln * 0.37, y), z + 48.0,
                 "canvas")
    b.box_bottom((6.0, w + 4.0, 36.0), (x + head * (ln / 2.0 + 2.0), y), z + 30.0, mat)


def _hearth(b, x, y_wall, z, w=70.0, h=200.0, mat="stone_dark", fire=True):
    """壁炉（贴后墙、炉口朝 -Y）。w/h = 世界单位，调用方按层高给。"""
    dw = 22.0
    yc = y_wall - dw / 2.0
    for sx in (-1.0, 1.0):
        b.box_bottom((18.0, dw, h), (x + sx * (w / 2.0 + 9.0), yc), z, mat)
    b.box_bottom((w + 36.0, dw, 18.0), (x, yc), z + h, mat)
    b.box_bottom((w + 14.0, dw + 10.0, 9.0), (x, yc - 5.0), z, "stone")
    b.box_bottom((w, 6.0, h - 6.0), (x, y_wall - 5.0), z + 6.0, "cavity")
    b.box_bottom((w + 46.0, 24.0, 11.0), (x, y_wall - 20.0), z + h + 18.0, "wood")
    if fire:
        b.box_bottom((w - 18.0, 12.0, 30.0), (x, y_wall - 17.0), z + 8.0, "fire")
        b.box_bottom((w - 26.0, 16.0, 8.0), (x, y_wall - 19.0), z + 6.0, "ember")
        for sx in (-1.0, 1.0):
            b.box((13.0, 13.0, 44.0), (x + sx * 15.0, y_wall - 17.0, z + 26.0),
                  "wood_dark", rot=(0.0, 0.0, sx * 0.5))
    return {"mantle": z + h + 29.0}


def _pew(b, x, y, z, w=118.0, mat="wood"):
    """教堂长椅（座 + 靠背 + 两端侧板 + 跪凳），面向 +Y（祭坛方向）。"""
    b.box_bottom((w, 34.0, 7.0), (x, y), z + 41.0, mat)
    b.box_bottom((w, 8.0, 46.0), (x, y - 15.0), z + 47.0, mat)
    for sx in (-1.0, 1.0):
        b.box_bottom((9.0, 44.0, 44.0), (x + sx * (w / 2.0 - 5.0), y - 8.0),
                     z, "wood_dark")
    b.box_bottom((w - 20.0, 13.0, 9.0), (x, y + 24.0), z + 6.0, "wood_dark")


def _shelf(b, x, y_wall, z, w, levels=3, d=22.0, dh=62.0, mat="wood"):
    """贴后墙的层板架（层板朝 -Y 伸出）。返回每层台面高度，供摆件用。"""
    b.box_bottom((10.0, d, levels * dh + 10.0), (x - w / 2.0 + 5.0, y_wall - d / 2.0),
                 z, "wood_dark")
    b.box_bottom((10.0, d, levels * dh + 10.0), (x + w / 2.0 - 5.0, y_wall - d / 2.0),
                 z, "wood_dark")
    out = []
    for i in range(levels):
        zz = z + 8.0 + i * dh
        b.box_bottom((w, d, 7.0), (x, y_wall - d / 2.0), zz, mat)
        out.append(zz + 7.0)
    return out


def _counter(b, x, y, z, w, d=30.0, h=58.0, mat="wood", panel="wood_dark"):
    """柜台/吧台：台面板 + 前挡板 + 两侧端板。"""
    b.box_bottom((w, d, 8.0), (x, y), z + h - 8.0, mat)
    b.box_bottom((w, 7.0, h - 8.0), (x, y - d / 2.0 + 3.5), z, panel)
    for sx in (-1.0, 1.0):
        b.box_bottom((8.0, d - 6.0, h - 8.0), (x + sx * (w / 2.0 - 4.0), y), z, panel)


def _hang_lantern(b, x, y, z_ceil, drop=40.0, s=22.0):
    """吊灯（铁链 + 灯体 + 暖光核心）。仅用于确有屋顶/天花的地方。"""
    b.box_bottom((4.0, 4.0, drop), (x, y), z_ceil - drop, "iron")
    _prop(P.lantern, b, x=x, y=y, z=z_ceil - drop - 30.0, s=s, h=30.0,
          bracket=False, lit=True, glass="glass")


def _wall_lantern(b, x, y_wall, z, s=20.0):
    """壁灯（铁托架 + 灯体）：挂后墙、朝 -Y 伸进屋里，不依赖天花。"""
    _prop(P.lantern, b, x=x, y=y_wall - 5.0, z=z, s=s, h=26.0, bracket=True,
          lit=True, glass="glass")


def _rug(b, x, y, z, w, d, mat="cloth_ochre"):
    b.box_bottom((w, d, 2.0), (x, y), z, mat)


def _hang_cloth(b, x, y, z_top, w, h, mat, rope=24.0):
    b.box_bottom((6.0, 6.0, rope), (x, y), z_top - rope, "rope")
    b.box_bottom((w, 6.0, h), (x, y), z_top - rope - h, mat)


def _candelabra(b, x, y, z, h=96.0, candles=5, lit=True):
    """立式烛台：铁座 + 立柱 + 横臂 + 蜡烛（火苗自发光）。"""
    b.cylinder((x, y, z + 5.0), 16.0, 10.0, "iron", 12)
    b.cylinder((x, y, z + 8.0 + h / 2.0), 4.5, h, "iron", 10)
    b.box_bottom((52.0, 8.0, 7.0), (x, y), z + 8.0 + h - 7.0, "iron")
    for i in range(candles):
        ax = x - 26.0 + i * (52.0 / (candles - 1))
        b.box_bottom((6.0, 6.0, 8.0), (ax, y), z + 8.0 + h, "iron")
        b.cylinder((ax, y, z + 8.0 + h + 17.0), 3.4, 20.0, "canvas", 8)
        if lit:
            _flame(b, ax, y, z + 8.0 + h + 37.0)


def _flame(b, x, y, z, s=1.0):
    """火苗：`fire` 外焰 + `lamp` 自发光芯。

    `fire`/`ember` 两个材质名**尚未注册进 materials.py**（§3.3 发光物总表已记），
    当前落回退色、无自发光；单靠它内景的"暖点"读不出来。这里叠一颗 `lamp`
    （EMISSIVE 2.5）当芯 —— 不动 materials.py，也把炉火/烛火真正点亮。
    """
    b.box_bottom((5.0 * s, 5.0 * s, 9.0 * s), (x, y), z, "fire")
    b.box_bottom((3.4 * s, 3.4 * s, 6.0 * s), (x, y), z + 1.5 * s, "lamp")


def _brazier(b, x, y, z, r=22.0, h=30.0, legs=True):
    """火盆：三足铁盆 + 炭 + 火芯（军营/大厅/塔楼的暖点）。"""
    if legs:
        for k in range(3):
            th = 2.0 * math.pi * k / 3.0 + 0.5
            b.box_bottom((6.0, 6.0, 26.0),
                         (x + math.cos(th) * r * 0.62, y + math.sin(th) * r * 0.62),
                         z, "iron")
    b.cylinder((x, y, z + 26.0 + h * 0.5), r, h, "iron", 14, taper=1.24)
    b.cylinder((x, y, z + 26.0 + h - 3.0), r * 0.84, 8.0, "iron", 14)
    b.box_bottom((r * 1.10, r * 1.10, 10.0), (x, y), z + 26.0 + h - 6.0, "stone_dark")
    for k in range(3):
        th = 2.0 * math.pi * k / 3.0 + 1.1
        _flame(b, x + math.cos(th) * r * 0.34, y + math.sin(th) * r * 0.34,
               z + 26.0 + h - 4.0, s=1.5)
    return z + 26.0 + h


def _stall(b, x0, x1, y_wall, z, h=96.0, rails=(0.42, 0.78), mat="wood"):
    """马厩隔栏：立柱 + 两道横栏（沿后墙把厩舍分成几格）。"""
    for xx in (x0, x1):
        b.box_bottom((11.0, 11.0, h), (xx, y_wall - 26.0), z, mat)
    for f in rails:
        b.box_bottom((abs(x1 - x0) + 11.0, 8.0, 9.0),
                     ((x0 + x1) / 2.0, y_wall - 26.0), z + h * f, mat)
    for k in range(1, 3):                        # 竖档
        b.box_bottom((8.0, 8.0, h * 0.86),
                     (x0 + (x1 - x0) * k / 3.0, y_wall - 26.0), z, mat)


def _stairs(b, x, y, z0, z1, w=52.0, mat="wood", steps=8):
    """直跑木梯（塔楼/风车/街屋的层间通道）：逐级踏面 + 两根斜梁。

    梁要**细**：正面视角下一根 150 长的斜梁会读成"一块长斜板压在楼层上"，抢掉家具的
    注意力（塔楼首版就是这个问题）。踏面进深也压到 22，读作梯子而不是坡道。
    """
    dh = (z1 - z0) / float(steps)
    run = w / float(steps)
    for i in range(steps):
        b.box_bottom((run * 1.26, 22.0, 6.0), (x + w / 2.0 - run * (i + 0.5), y),
                     z0 + dh * (i + 1) - 6.0, mat)
    ln = math.hypot(w, z1 - z0)
    ang = math.atan2(z1 - z0, w)
    for sy in (-1.0, 1.0):
        b.box((ln, 4.5, 6.0), (x, y + sy * 11.0, (z0 + z1) / 2.0), "timber",
              rot=(0.0, -ang, 0.0))


def _hoist(b, x, y, z_rail, drop=70.0, w=150.0):
    """仓库吊臂/滑轨：横梁 + 滑车 + 吊索 + 悬空货箱。"""
    b.box_bottom((w, 12.0, 13.0), (x, y), z_rail, "timber")
    for sx in (-1.0, 1.0):
        b.box_bottom((13.0, 13.0, 16.0), (x + sx * (w / 2.0 - 7.0), y), z_rail - 16.0,
                     "iron")
    hx = x + w * 0.22
    b.box_bottom((20.0, 20.0, 12.0), (hx, y), z_rail - 12.0, "iron")
    b.box_bottom((4.0, 4.0, drop), (hx, y), z_rail - 12.0 - drop, "rope")
    _prop(P.crate, b, x=hx, y=y, z=z_rail - 12.0 - drop - 20.0, s=26.0, h=22.0)
    b.box_bottom((6.0, 6.0, 26.0), (hx, y), z_rail - 12.0 - drop - 20.0, "rope")


def _scale_beam(b, x, y, z, w=76.0, h=96.0):
    """货称/天平：立柱 + 横梁 + 两端吊盘（仓库/市集称重用）。"""
    b.box_bottom((16.0, 16.0, 8.0), (x, y), z, "iron")
    b.box_bottom((9.0, 9.0, h), (x, y), z + 8.0, "iron")
    b.box_bottom((w, 8.0, 8.0), (x, y), z + 8.0 + h - 8.0, "bronze")
    for sx in (-1.0, 1.0):
        b.box_bottom((3.0, 3.0, 34.0), (x + sx * (w / 2.0 - 6.0), y),
                     z + 8.0 + h - 42.0, "iron")
        b.cylinder((x + sx * (w / 2.0 - 6.0), y, z + 8.0 + h - 52.0), 17.0, 7.0,
                   "bronze", 12)
    return z + 8.0 + h


def _millstone(b, x, y, z, r=34.0):
    """磨盘：下盘（座） + 上盘（转） + 中轴 + 木推杆。"""
    b.cylinder((x, y, z + 7.0), r * 1.12, 14.0, "stone", 20)
    b.cylinder((x, y, z + 14.0 + 12.0), r, 24.0, "white_stone", 20)
    b.cylinder((x, y, z + 40.0), 5.0, 30.0, "iron", 10)
    b.box_bottom((r * 1.5, 11.0, 11.0), (x + r * 0.75, y - r * 1.3), z + 40.0,
                 "timber")
    return z + 52.0


def _lens(b, x, y, z, r=30.0, h=54.0):
    """灯塔灯室透镜 / 法师塔水晶灯：玻璃罩 + 火芯 + 上下铁箍。"""
    b.cylinder((x, y, z), r * 1.16, 9.0, "iron", 16)
    b.cylinder((x, y, z + 9.0 + h / 2.0), r, h, "glass_lead", 16)
    _flame(b, x, y, z + 9.0 + h * 0.32, s=4.0)
    b.box_bottom((r * 1.3, r * 1.3, h * 0.30), (x, y), z + 9.0 + h * 0.18, "lamp")
    b.cylinder((x, y, z + 9.0 + h), r * 1.16, 8.0, "iron", 16)
    return z + 9.0 + h + 8.0


def _wall_bunk(b, x, z, y_wall, w=72.0, d=44.0, tiers=2, lo=52.0, gap=76.0,
               cloth="cloth_ochre"):
    """靠墙上下铺：木框 + 草垫 + 枕（兵营/塔楼哨兵床）。"""
    out = []
    for k in range(tiers):
        zz = z + lo + k * gap
        b.box_bottom((w, d, 7.0), (x, y_wall - d / 2.0 - 6.0), zz, "wood")
        for sx in (-1.0, 1.0):
            for sy in (-1.0, 1.0):
                b.box_bottom((8.0, 8.0, lo + k * gap),
                             (x + sx * (w / 2.0 - 6.0),
                              y_wall - 6.0 - d / 2.0 + sy * (d / 2.0 - 6.0)),
                             z, "wood_dark")
        b.box_bottom((w - 8.0, d - 12.0, 10.0), (x, y_wall - d / 2.0 - 6.0),
                     zz + 7.0, "straw")
        b.box_bottom((w * 0.24, d - 20.0, 8.0), (x - w * 0.3, y_wall - d / 2.0 - 6.0),
                     zz + 17.0, cloth)
        out.append(zz)
    return out


def _round_shell(b, L, seg=20):
    """圆塔内景的"后壁 + 圆地板 + 楼层圆板"。

    **只画 y>0 的背面半圈**（近相机那半边不画，否则会把室内糊住）；法线朝**塔心**
    （用 `-mid` 方向），这样室内点光才能把内表面打亮。半径按 tier 的 taper 逐段收，
    与前层塔身的收分严格一致（顶段半径 = R×taper），不会从塔身里戳出来。
    """
    R, taper, h, plinth = L["R"], L["taper"], L["back_h"], L["plinth"]
    wt = L["wt"]
    nseg = 3
    for k in range(nseg):
        z0 = plinth + h * k / float(nseg)
        z1 = plinth + h * (k + 1) / float(nseg)
        r0 = (R - wt) * (1.0 - (k / float(nseg)) * (1.0 - taper))
        r1 = (R - wt) * (1.0 - ((k + 1) / float(nseg)) * (1.0 - taper))
        ring0 = [(math.cos(math.pi * i / seg) * r0,
                  math.sin(math.pi * i / seg) * r0, z0) for i in range(seg + 1)]
        ring1 = [(math.cos(math.pi * i / seg) * r1,
                  math.sin(math.pi * i / seg) * r1, z1) for i in range(seg + 1)]
        for i in range(seg):
            p = [ring0[i], ring0[i + 1], ring1[i + 1], ring1[i]]
            mid = tuple(sum(c[c_i] for c in p) / 4.0 for c_i in range(3))
            b.poly(p, L["wall_low"], outward=(-mid[0], -mid[1], 0.0))
        if k:
            b.cylinder((0.0, 0.0, z0 - 6.0), r0 * 0.99, 12.0, "stone", seg)
    # 地板 + 踢脚（圆）
    for k, zz in enumerate(L.get("mids", [plinth])):
        r = (R - wt) * (1.0 - (k / 3.0) * (1.0 - taper))
        b.cylinder((0.0, 0.0, zz - 4.0), r, 4.0, L["floor"], seg)
        if k:
            b.cylinder((0.0, 0.0, zz - 7.0), r, 7.0, "timber", seg)
            b.cylinder((0.0, 0.0, zz), r, 8.0, "wood_deck", seg)
    b.cylinder((0.0, 0.0, plinth + h - 6.0), (R - wt) * taper, 8.0,
               L["wall_up"], seg)


def _tower_shell(b, L):
    """方形退台塔（瞭望塔）的内景壳：三段收分后墙 + 各层楼板。"""
    plinth, plinth_h = L["plinth"], L["plinth"]
    h = L["back_h"]
    seg_h = h / 3.0
    widths = L["step_w"]
    yb = L["yb"]
    for k in range(3):
        B.wall_panel(b, widths[k], seg_h, 18.0, L["wall_low"], 0.0,
                     yb + 2.0 * k - 9.0, plinth_h + seg_h * k)
    b.box_bottom((widths[0] * 0.94, L["depth"], 4.0), (0.0, L["yc"]),
                 plinth_h - 4.0, L["floor"])
    for zz in [z for z in L["mids"] if z > plinth_h + 1.0]:
        b.box_bottom((widths[0] * 0.94, L["depth"] - 6.0, 8.0), (0.0, L["yc"]),
                     zz - 8.0, "wood_deck")
        b.box_bottom((widths[0] * 0.94, 10.0, 13.0), (0.0, L["yc"]), zz - 21.0, "timber")


# ================================================================ §4 各 def 内景

def _house(b, L):
    """民居：床 / 桌 / 凳 / 壁炉 / 挂物。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L)
    # 左半：床贴后墙（床长沿 X），床尾留出通道
    _bed(b, x=-72.0, y=yb - 46.0, z=pl, ln=148.0, w=76.0, head=1.0,
         cloth="cloth_blue")
    # 右半：壁炉 + 台面器物
    hx = xh - 66.0
    hm = _hearth(b, hx, yb, pl, w=64.0, h=126.0)
    _prop(P.pot, b, x=hx - 26.0, y=yb - 26.0, z=hm["mantle"], r=9.0, h=16.0,
          mat="clay")
    _prop(P.pot, b, x=hx + 18.0, y=yb - 26.0, z=hm["mantle"], r=8.0, h=14.0,
          mat="stone_dark")
    # 前中：桌 + 两条凳（凳在桌子两端，不占进深）
    tx, ty = -56.0, yf + 44.0
    _prop(P.table, b, x=tx, y=ty, z=pl, w=62.0, d=32.0, h=46.0)
    _prop(P.stool, b, x=tx - 78.0, y=ty, z=pl, r=12.0, h=29.0)
    _prop(P.stool, b, x=tx + 74.0, y=ty, z=pl, r=12.0, h=29.0)
    _prop(P.pot, b, x=tx + 8.0, y=ty, z=pl + 46.0 * GAME, r=8.0, h=13.0, mat="clay")
    _rug(b, tx, ty, pl + 0.6, 150.0, 84.0)
    # 后墙层板（床的上方，不碰床面；层板顶不得越过墙顶 —— 越了会在墙上方戳出黑柱）
    sh = _shelf(b, x=-56.0, y_wall=yb, z=pl + 100.0, w=92.0, levels=2, d=19.0,
                dh=44.0)
    for px, pr, ph, mt in ((-0.28, 9.0, 17.0, "clay"), (0.02, 7.5, 14.0, "stone_dark"),
                           (0.26, 10.0, 19.0, "clay")):
        _prop(P.pot, b, x=-56.0 + px * 92.0, y=yb - 12.0, z=sh[0], r=pr, h=ph, mat=mt)
    # 挂物：吊杆 + 三块布 + 干草药
    b.box_bottom((132.0, 6.0, 6.0), (36.0, yf + 22.0), L["ceil"] - 14.0, "timber")
    for i, m in enumerate(("cloth_red", "cloth_blue", "cloth_ochre")):
        _hang_cloth(b, 36.0 - 44.0 + i * 44.0, yf + 22.0, L["ceil"] - 14.0, 30.0, 58.0,
                    m, rope=0.0)
    _prop(P.herb_rack, b, x=8.0, y=yb, z=pl + 168.0, w=58.0, n=6, mat="timber")
    # 地面零碎
    _prop(P.chest, b, x=88.0, y=yf + 44.0, z=pl, w=46.0, d=30.0, h=32.0)
    _prop(P.firewood_basket, b, x=hx - 74.0, y=yb - 34.0, z=pl, r=19.0, h=22.0)
    _prop(P.barrel, b, x=xh - 24.0, y=yf + 26.0, z=pl, r=15.0, h=42.0)
    _prop(P.bucket, b, x=xh - 24.0, y=yf + 62.0, z=pl, r=10.0, h=22.0)
    _prop(P.sack, b, x=xh - 66.0, y=yf + 26.0, z=pl, r=13.0, h=30.0)
    _wall_lantern(b, x=-24.0, y_wall=yb, z=pl + 150.0, s=20.0)


def _townhouse(b, L):
    """街屋：一层起居（壁炉/桌/架）+ 二层卧房（床/箱/烛）。"""
    pl, yb, yf, xh, mid = L["plinth"], L["yb"], L["yf"], L["xh"], L["mid"]
    _shell(b, L, storey_split=True)
    # ---- 一层
    hx = xh - 62.0
    hm = _hearth(b, hx, yb, pl, w=70.0, h=150.0)
    _prop(P.stew_pot, b, x=hx, y=yb - 26.0, z=pl + 8.0, r=22.0, h=28.0, fire=True)
    _prop(P.pot, b, x=hx + 40.0, y=yb - 26.0, z=hm["mantle"], r=9.0, h=16.0,
          mat="clay")
    tx, ty = -66.0, yf + 50.0
    _prop(P.table, b, x=tx, y=ty, z=pl, w=68.0, d=34.0, h=48.0)
    _prop(P.bench, b, x=tx, y=ty + 44.0, z=pl, w=74.0, d=26.0, h=34.0)
    _prop(P.stool, b, x=tx - 84.0, y=ty, z=pl, r=12.0, h=30.0)
    _prop(P.stool, b, x=tx + 80.0, y=ty, z=pl, r=12.0, h=30.0)
    _prop(P.pot, b, x=tx + 6.0, y=ty, z=pl + 48.0 * GAME, r=8.0, h=13.0, mat="clay")
    _rug(b, tx, ty, pl + 0.6, 150.0, 78.0)
    sh = _shelf(b, x=-xh + 66.0, y_wall=yb, z=pl + 54.0, w=104.0, levels=3, d=21.0,
                dh=40.0)
    for zz, items in ((sh[0], ((-0.30, 9.0, 17.0), (0.02, 8.0, 15.0))),
                      (sh[1], ((0.26, 8.5, 16.0),)),
                      (sh[2], ((-0.12, 10.0, 19.0), (0.24, 8.0, 14.0)))):
        for px, pr, ph in items:
            _prop(P.pot, b, x=-xh + 66.0 + px * 104.0, y=yb - 12.0, z=zz, r=pr,
                  h=ph, mat="clay")
    _prop(P.barrel, b, x=-xh + 26.0, y=yf + 26.0, z=pl, r=15.0, h=44.0)
    _prop(P.water_butt, b, x=-xh + 84.0, y=yf + 26.0, z=pl, r=16.0, h=54.0)
    _prop(P.chest, b, x=xh - 26.0, y=yf + 26.0, z=pl, w=48.0, d=30.0, h=34.0)
    _wall_lantern(b, x=-40.0, y_wall=yb, z=pl + 154.0, s=20.0)
    # ---- 二层
    z2 = mid
    _bed(b, x=-xh + 96.0, y=yb - 46.0, z=z2, ln=152.0, w=78.0, head=-1.0)
    _prop(P.chest, b, x=-xh + 26.0, y=yb - 30.0, z=z2, w=48.0, d=30.0, h=32.0)
    sh2 = _shelf(b, x=xh - 76.0, y_wall=yb, z=z2 + 80.0, w=92.0, levels=2, d=19.0,
                 dh=44.0)
    _prop(P.book_stack, b, x=xh - 102.0, y=yb - 12.0, z=sh2[1], w=32.0, h=28.0, n=5)
    _prop(P.pot, b, x=xh - 48.0, y=yb - 12.0, z=sh2[0], r=9.0, h=16.0, mat="clay")
    _prop(P.stool, b, x=xh - 60.0, y=yf + 54.0, z=z2, r=12.0, h=28.0)
    _prop(P.crate_stack, b, x=xh - 26.0, y=yf + 28.0, z=z2, s=28.0, h=24.0, n=3)
    _rug(b, -50.0, yf + 62.0, z2 + 0.6, 170.0, 96.0)
    _wall_lantern(b, x=-34.0, y_wall=yb, z=z2 + 150.0, s=18.0)


def _smithy(b, L):
    """铁匠铺：火炉 / 铁砧 / 淬火桶 / 工具架 —— 师傅的工作位。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L, ceiling=False)
    # 火炉（贴后墙左段，炉口朝前）
    fx = -xh + 70.0
    B.forge(b, fx, yb - 54.0, pl, w=68.0, d=54.0, body_h=74.0,
            flue_h=max(24.0, L["ceil"] - 196.0))
    # 铁砧（炉前偏左，正对炉口 = 师傅工作位）
    _prop(P.anvil, b, x=fx + 16.0, y=yf + 42.0, z=pl, stump=True, stump_h=40.0)
    _prop(P.tongs, b, x=fx - 12.0, y=yf + 38.0, z=pl + 62.0)
    # 淬火桶（砧右）
    _prop(P.quench_barrel, b, x=fx + 78.0, y=yf + 42.0, z=pl)
    # 工具架（后墙，炉右）
    _prop(P.tools_rack, b, x=fx + 130.0, y=yb - 8.0, z=pl + 168.0, w=74.0)
    # 工作台（右后）+ 磨石 + 煤 + 柴 + 家什
    _prop(P.bench, b, x=xh - 60.0, y=yb - 44.0, z=pl, w=84.0, d=32.0, h=48.0)
    _prop(P.grindstone, b, x=xh - 44.0, y=yf + 44.0, z=pl, r=24.0)
    _prop(P.coal_pile, b, x=fx + 24.0, y=yf + 20.0, z=pl, w=42.0, h=18.0)
    _prop(P.log_pile, b, x=xh - 96.0, y=yf + 42.0, z=pl, rows=2, per_row=4, r=8.0)
    _prop(P.barrel, b, x=-xh + 20.0, y=yf + 44.0, z=pl, r=15.0, h=42.0, open_top=True)
    _prop(P.bucket, b, x=-xh + 20.0, y=yf + 80.0, z=pl, r=10.0, h=22.0)
    _prop(P.milk_churn, b, x=-xh + 24.0, y=yb - 28.0, z=pl, r=12.0, h=54.0)
    _prop(P.sack, b, x=-xh + 58.0, y=yb - 26.0, z=pl, r=13.0, h=30.0)
    _wall_lantern(b, x=xh - 96.0, y_wall=yb, z=pl + 150.0, s=20.0)


def _tavern(b, L):
    """酒馆：吧台 / 酒桶 / 桌凳（一层公共间）+ 二层杂物与床铺。"""
    pl, yb, yf, xh, mid = L["plinth"], L["yb"], L["yf"], L["xh"], L["mid"]
    _shell(b, L, storey_split=True)
    # ---- 一层：吧台（后墙右段）
    bx = xh - 112.0
    _counter(b, bx, yb - 58.0, pl, w=170.0, d=32.0, h=58.0)
    sh = _shelf(b, x=bx + 34.0, y_wall=yb, z=pl + 30.0, w=150.0, levels=3, d=22.0,
                dh=46.0)
    for zz in sh:
        _prop(P.pottery_row, b, x=bx + 34.0, y=yb - 12.0, z=zz, n=5, r=9.0, h=17.0)
    _prop(P.basket, b, x=bx - 36.0, y=yb - 12.0, z=sh[0], r=17.0, h=17.0)
    _prop(P.barrel_stand, b, x=bx + 96.0, y=yb - 30.0, z=pl, w=100.0, r=13.0, bl=34.0,
          h=44.0)
    _prop(P.barrel, b, x=bx - 62.0, y=yb - 30.0, z=pl, r=15.0, h=42.0, lying=True)
    _prop(P.barrel, b, x=bx - 62.0, y=yb - 30.0, z=pl + 46.0, r=14.0, h=38.0,
          lying=True)
    # 壁炉（后墙左段）+ 炖锅
    hm = _hearth(b, -xh + 74.0, yb, pl, w=76.0, h=150.0)
    _prop(P.stew_pot, b, x=-xh + 74.0, y=yb - 30.0, z=pl + 8.0, r=24.0, h=30.0)
    _prop(P.pot, b, x=-xh + 112.0, y=yb - 26.0, z=hm["mantle"], r=9.0, h=16.0,
          mat="clay")
    # 桌凳 ×2（前场左右）
    for tx, ty, rug in ((-xh + 62.0, yf + 48.0, "cloth_red"),
                        (xh - 62.0, yf + 48.0, "cloth_blue")):
        _prop(P.table, b, x=tx, y=ty, z=pl, w=64.0, d=34.0, h=46.0)
        _prop(P.stool, b, x=tx - 78.0, y=ty, z=pl, r=12.0, h=29.0)
        _prop(P.stool, b, x=tx + 74.0, y=ty, z=pl, r=12.0, h=29.0)
        _prop(P.stool, b, x=tx - 8.0, y=ty + 44.0, z=pl, r=12.0, h=29.0)
        _prop(P.bucket, b, x=tx + 6.0, y=ty, z=pl + 46.0 * GAME, r=6.0, h=12.0)
        _rug(b, tx, ty, pl + 0.6, 132.0, 82.0, rug)
    _prop(P.chest, b, x=-xh + 26.0, y=yf + 26.0, z=pl, w=48.0, d=30.0, h=34.0)
    _prop(P.barrel, b, x=-xh + 84.0, y=yf + 26.0, z=pl, r=15.0, h=42.0)
    _prop(P.barrel, b, x=-xh + 84.0, y=yf + 26.0, z=pl + 46.0, r=14.0, h=38.0)
    _wall_lantern(b, x=-xh + 140.0, y_wall=yb, z=pl + 152.0, s=20.0)
    # ---- 二层：两铺床 + 杂物
    z2 = mid
    _bed(b, x=-xh + 96.0, y=yb - 46.0, z=z2, ln=150.0, w=76.0, head=-1.0,
         cloth="cloth_red")
    _bed(b, x=xh - 96.0, y=yb - 46.0, z=z2, ln=150.0, w=76.0, head=1.0,
         cloth="cloth_ochre")
    _prop(P.crate_stack, b, x=0.0, y=yb - 34.0, z=z2, s=28.0, h=24.0, n=3)
    _prop(P.barrel, b, x=0.0, y=yf + 32.0, z=z2, r=15.0, h=42.0)
    _prop(P.sack_stack, b, x=-xh + 26.0, y=yf + 30.0, z=z2, r=13.0, h=30.0)
    _prop(P.stool, b, x=xh - 60.0, y=yf + 46.0, z=z2, r=12.0, h=28.0)
    _wall_lantern(b, x=-34.0, y_wall=yb, z=z2 + 148.0, s=18.0)


def _bakery(b, L):
    """面包房：烤炉 / 面包架 / 面粉桶。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L, ceiling=False)
    # 砖砌烤炉（后墙左段，炉口朝前）
    ox = -xh + 62.0
    oh = 112.0
    b.box_bottom((132.0, 70.0, 26.0), (ox, yb - 36.0), pl, "stone_dark")
    b.box_bottom((104.0, 64.0, oh), (ox, yb - 34.0), pl + 26.0, "brick")
    b.box_bottom((56.0, 8.0, 44.0), (ox, yb - 65.0), pl + 34.0, "cavity")
    b.box_bottom((48.0, 14.0, 30.0), (ox, yb - 58.0), pl + 38.0, "fire")
    b.box_bottom((52.0, 16.0, 8.0), (ox, yb - 58.0), pl + 34.0, "ember")
    for k, (kw, kd, kh) in enumerate(((104.0, 64.0, 18.0), (78.0, 52.0, 16.0),
                                      (52.0, 38.0, 14.0))):
        b.box_bottom((kw, kd, kh), (ox, yb - 34.0), pl + 26.0 + oh + k * 15.0, "brick")
    b.cylinder((ox, yb - 34.0, L["ceil"] - 36.0), 11.0, 72.0, "brick", 12)
    # 面包架（烤炉右侧后墙）
    sh = _shelf(b, x=xh - 74.0, y_wall=yb, z=pl + 52.0, w=112.0, levels=3, d=25.0,
                dh=42.0)
    for zz in sh:
        _prop(P.bread_tray, b, x=xh - 74.0, y=yb - 15.0, z=zz, w=60.0, h=28.0, d=20.0)
    _prop(P.basket, b, x=xh - 26.0, y=yb - 12.0, z=sh[2], r=16.0, h=16.0)
    # 工作长桌（前中）+ 盆 + 面包
    tx, ty = -xh + 100.0, yf + 46.0
    _prop(P.table, b, x=tx, y=ty, z=pl, w=92.0, d=40.0, h=48.0)
    _prop(P.wash_tub, b, x=tx - 36.0, y=ty, z=pl + 48.0 * GAME, r=16.0, h=16.0)
    _prop(P.basket, b, x=tx + 40.0, y=ty, z=pl + 48.0 * GAME, r=16.0, h=16.0)
    b.box_bottom((30.0, 20.0, 11.0), (tx + 8.0, ty), pl + 48.0 * GAME + 10.0, "bread")
    B.baker_peel(b, tx - 78.0, yb - 22.0, pl + 100.0, ln=104.0)
    # 面粉桶 + 麻袋堆
    _prop(P.barrel, b, x=xh - 30.0, y=yf + 28.0, z=pl, r=16.0, h=46.0, open_top=True)
    _prop(P.sack_stack, b, x=xh - 92.0, y=yf + 30.0, z=pl, r=14.0, h=32.0)
    _prop(P.sack, b, x=-xh + 24.0, y=yf + 26.0, z=pl, r=13.0, h=30.0)
    _prop(P.milk_churn, b, x=-xh + 24.0, y=yb - 26.0, z=pl, r=12.0, h=54.0)
    _hang_lantern(b, x=xh - 140.0, y=yf + 44.0, z_ceil=L["ceil"], drop=30.0, s=20.0)


def _shop(b, L):
    """杂货铺：货架 / 柜台 / 挂货。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L)
    # 后墙货架（三段；层板顶不得越过墙顶，否则在墙上方戳出黑柱）
    for sx, sw, seed in ((-xh + 62.0, 92.0, 1), (6.0, 92.0, 2), (xh - 62.0, 96.0, 3)):
        sh = _shelf(b, x=sx, y_wall=yb, z=pl + 18.0, w=sw, levels=3, d=23.0, dh=48.0)
        for j, zz in enumerate(sh):
            if j % 2 == 0:
                _prop(P.produce_baskets, b, x=sx - sw * 0.20, y=yb - 13.0, z=zz,
                      r=15.0, h=15.0, seed=seed * 7 + j)
            else:
                _prop(P.pottery_row, b, x=sx + sw * 0.04, y=yb - 12.0, z=zz, n=4,
                      r=9.0, h=17.0, seed=seed * 11 + j)
        _prop(P.crate, b, x=sx + sw * 0.28, y=yb - 13.0, z=sh[2], s=24.0, h=20.0)
    # 柜台（前中，横向）
    _counter(b, x=-30.0, y=yf + 46.0, z=pl, w=196.0, d=32.0, h=58.0)
    _prop(P.basket, b, x=-104.0, y=yf + 46.0, z=pl + 58.0, r=16.0, h=16.0)
    _prop(P.pottery_row, b, x=-8.0, y=yf + 46.0, z=pl + 58.0, n=3, r=8.0, h=15.0)
    b.box_bottom((32.0, 22.0, 26.0), (54.0, yf + 46.0), pl + 58.0, "wood")
    # 吊挂货：梁下布匹 + 篮子（吊杆压在墙顶线下，不悬空）
    zt = L["ceil"] - 12.0
    b.box_bottom((300.0, 6.0, 6.0), (0.0, yf + 78.0), zt, "timber")
    for i, m in enumerate(("cloth_red", "cloth_blue", "cloth_ochre")):
        _hang_cloth(b, -xh + 74.0 + i * 36.0, yf + 78.0, zt, 30.0, 72.0, m, rope=0.0)
    for i in range(3):
        bx = xh - 60.0 + i * 46.0
        _hang_cloth(b, bx, yf + 78.0, zt, 28.0, 40.0, "rope", rope=0.0)
        _prop(P.basket, b, x=bx, y=yf + 78.0, z=zt - 40.0 - 21.8, r=14.0, h=15.0)
    # 地面货箱 + 麻袋 + 桶 + 钱箱
    _prop(P.crate_stack, b, x=xh - 36.0, y=yf + 26.0, z=pl, s=28.0, h=26.0, n=3)
    _prop(P.sack_stack, b, x=-xh + 34.0, y=yf + 26.0, z=pl, r=14.0, h=32.0)
    _prop(P.barrel, b, x=xh - 100.0, y=yf + 26.0, z=pl, r=15.0, h=42.0, open_top=True)
    _prop(P.chest, b, x=-xh + 24.0, y=yb - 26.0, z=pl, w=50.0, d=32.0, h=34.0)
    _prop(P.barrel, b, x=xh - 140.0, y=yb - 28.0, z=pl, r=14.0, h=40.0)
    _wall_lantern(b, x=-xh + 150.0, y_wall=yb, z=pl + 158.0, s=20.0)
    _wall_lantern(b, x=xh - 60.0, y_wall=yb, z=pl + 158.0, s=20.0)


def _cathedral(b, L):
    """大教堂 / 教堂 / 小礼拜堂：长椅列 / 祭坛 / 烛台 / 彩窗内透光。

    **按宽度参数化**（church=12 格、chapel=8 格复用同一套语言）：柱列 / 彩窗 /
    长椅位置的 x 全部由 `xh` 推导，不再写死 ±158/±132（写死的话 8/12 格档家具
    会直接穿墙）。`small=True`（chapel）走"单彩窗 + 长椅 ×4"的简化档。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    small = bool(L.get("small"))
    nave = L["back_h"]
    col_x = xh * 0.74
    aisle_x = xh * 0.42
    # 后殿彩窗：后墙开真洞 + 嵌 stained_glass + 洞外发光板（"室外天光透进来"）。
    # 洞口必须**完整落在墙高以内**（越顶的洞会连墙一起切掉，发光板就从墙上方露出来）。
    if small:
        apse = ((0.0, nave * 0.42, nave * 0.20, nave * 0.34),)   # 单彩窗（居中尖拱）
    else:
        apse = ((-xh * 0.62, nave * 0.36, nave * 0.20, nave * 0.42),
                (0.0, nave * 0.68, xh * 0.72, nave * 0.34),
                (xh * 0.62, nave * 0.36, nave * 0.20, nave * 0.42))
    holes = [(ax, aw, az0, az0 + ah) for (ax, az0, aw, ah) in apse]
    B.wall_panel(b, L["W"], nave, L["wt"], L["wall_low"], 0.0,
                 L["D"] / 2.0 - L["wt"] / 2.0, pl, openings=holes)
    for (ax, az0, aw, ah) in apse:
        if ax == 0.0 and aw > ah * 0.8:            # 圆形玫瑰窗（近正方的大窗）
            B.rose_window(b, ax, yb - 1.0, az0 + ah / 2.0, min(aw, ah) / 2.0,
                          glass="stained_glass", tracery="white_stone", spokes=12)
            b.box_bottom((aw + 10.0, 6.0, ah + 28.0), (ax, L["D"] / 2.0 - 3.0),
                         az0 - 14.0, "lamp")
        else:
            B.lancet_window(b, ax, yb - 1.0, az0, aw, ah, head=min(46.0, aw * 0.62),
                            profile="point", glass="stained_glass",
                            ring="white_stone", sill=True)
            b.box_bottom((aw + 10.0, 6.0, ah + 30.0), (ax, L["D"] / 2.0 - 3.0),
                         az0 - 15.0, "lamp")
    # 地板 / 踢脚 / 天花
    x2, depth, yc = xh * 2.0, L["depth"], L["yc"]
    b.box_bottom((x2, depth, 4.0), (0.0, yc), pl - 4.0, L["floor"])
    b.box_bottom((x2, 4.0, 14.0), (0.0, yb - 2.0), pl, "stone_dark")
    b.box_bottom((x2, depth, 6.0), (0.0, yc), L["ceil"], "stone")
    for i in range(6):
        bx = -xh + (i + 0.5) * (x2 / 6.0)
        b.box_bottom((16.0, depth, 18.0), (bx, yc), L["ceil"] - 22.0, "stone")
    # 两列石柱（中殿纵深；侧墙在前视里投影成线，柱列是唯一的纵深线索）
    ncol = 3 if small else 4
    for sx in (-1.0, 1.0):
        for i in range(ncol):
            cy = yf + 44.0 + i * (depth * 0.26)
            b.box_bottom((34.0, 34.0, 16.0), (sx * col_x, cy), pl, "stone_dark")
            b.cylinder((sx * col_x, cy, pl + 16.0 + nave * 0.43),
                       14.0, nave * 0.86, "stone", 12)
            b.box_bottom((42.0, 42.0, 14.0), (sx * col_x, cy),
                         pl + 16.0 + nave * 0.86, "white_stone")
    # 中央通道红毯 + 长椅列（面向后殿）
    _rug(b, 0.0, yc + 8.0, pl + 0.6, xh * 0.56, depth - 36.0, "cloth_red")
    # 长椅只放**两排**：中殿净深只有 ~2.6~4m（D 表值），6 排会一路压过祭坛并冲出后墙
    # （旧代码 yf+62+row*56 在 w12/w16 档就会越界）。祭坛贴后墙退到长椅之后。
    rows = 2
    for row in range(rows):
        ry = yf + 44.0 + row * 54.0
        for sx in (-1.0, 1.0):
            _pew(b, x=sx * aisle_x, y=ry, z=pl, w=xh * 0.52)
    # 祭坛（后殿台阶 + 圣坛 + 器物）
    aw = xh * (0.62 if small else 0.92)
    ay = yb - 26.0
    b.box_bottom((aw * 1.18, 46.0, 14.0), (0.0, ay), pl, "white_stone")
    b.box_bottom((aw, 38.0, 14.0), (0.0, ay + 2.0), pl + 14.0, "white_stone")
    b.box_bottom((aw * 0.80, 28.0, 62.0), (0.0, ay + 6.0), pl + 28.0, "white_stone")
    b.box_bottom((aw * 0.85, 12.0, 10.0), (0.0, ay + 6.0), pl + 90.0, "stone_dark")
    _prop(P.book_stack, b, x=-aw * 0.16, y=ay + 6.0, z=pl + 90.0, w=34.0, h=28.0,
          n=4)
    _prop(P.censer, b, x=aw * 0.18, y=ay + 8.0, z=pl + 90.0, h=32.0, r=12.0,
          lit=True)
    for sx in (-1.0, 1.0):
        _candelabra(b, sx * aw * 0.50, ay + 14.0, pl + 28.0, h=86.0, candles=5)
    if not small:
        # 圣水盆 + 讲道坛（近入口）
        b.cylinder((xh - 62.0, yf + 40.0, pl + 26.0), 26.0, 52.0, "white_stone", 16,
                   taper=0.72)
        b.cylinder((xh - 62.0, yf + 40.0, pl + 55.0), 24.0, 8.0, "stone_dark", 16)
        b.box_bottom((62.0, 44.0, 86.0), (-xh + 58.0, yf + 44.0), pl, "wood")
    else:
        _prop(P.font, b, x=xh * 0.72, y=yf + 42.0, z=pl, r=16.0, h=50.0)
    # 垂幡
    for sx in (-1.0, 1.0):
        for i in range(2 if not small else 1):
            _hang_cloth(b, sx * col_x, yf + 64.0 + i * (depth * 0.42),
                        L["ceil"] - 60.0, 34.0, 96.0,
                        "cloth_red" if i == 0 else "cloth_blue", rope=60.0)


# ================================================================ §4b 扩展轮内景
#: 覆盖矩阵里"待做的 22 项"：19 个装配器 def + 3 个别名 def（plaster_house /
#: church / chapel）。每套 = 后墙 + 地板 + 该 def 功能语义的家具设备 + 暖色点光。
#: 小体量 def（cottage / shelter / stable / gatehouse）走"紧凑内景"：家具贴墙一排、
#: 中间只留一条通道，并在函数注释里如实记该档进深够不够用。

# ---------------------------------------------------------------- 农业线

def _barn(b, L):
    """谷仓：干草垛 / 谷袋 / 农具 / 料槽 / 板车 + 后墙通风窗对位。

    进深 12 格档净 ~156px(2.0m)：够"后墙料槽 + 前场板车"两排，但**不够**再插一排货架
    —— 谷仓本来就是空腔体量，靠草垛/谷袋的体积感撑，不靠家具密度。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    depth = L["depth"]
    # 后墙高处两个通风窗真洞（谷仓的透气特征）+ 洞后 cavity 挡板 + 百叶
    vents = ((-xh * 0.60, 44.0, pl + L["back_h"] * 0.70, pl + L["back_h"] * 0.70 + 40.0),
             (xh * 0.60, 44.0, pl + L["back_h"] * 0.70, pl + L["back_h"] * 0.70 + 40.0))
    _shell(b, L, openings=[(vx, vw, vz0, vz1) for (vx, vw, vz0, vz1) in vents])
    for (vx, vw, vz0, vz1) in vents:
        b.box_bottom((vw + 8.0, 6.0, vz1 - vz0 + 8.0), (vx, yb + 1.0), vz0 - 4.0,
                     "cavity")
        for k in range(4):
            b.box_bottom((vw, 6.0, 6.0), (vx, yb - 2.0),
                         vz0 + 6.0 + k * (vz1 - vz0 - 12.0) / 3.0, "wood_dark")
    # 白灰内壁 + 木骨（谷仓内壁刷白灰是常见的；纯木板内壁会让整栋读成一坨褐色）
    for fx in (-xh * 0.86, -xh * 0.32, xh * 0.32, xh * 0.86):
        b.box_bottom((18.0, 14.0, L["back_h"] - 26.0), (fx, yb - 8.0), pl, "timber")
    b.box_bottom((xh * 2.0, 16.0, 20.0), (0.0, yb - 8.0), pl + L["back_h"] - 30.0,
                 "timber")
    b.box_bottom((xh * 2.0, 14.0, 14.0), (0.0, yb - 8.0), pl + L["back_h"] * 0.50,
                 "timber")
    # 后墙料槽（横向长槽）+ 谷袋堆
    _prop(P.trough, b, x=-xh * 0.30, y=yb - 30.0, z=pl, w=118.0, d=30.0, h=26.0)
    _prop(P.sack_stack, b, x=xh * 0.74, y=yb - 30.0, z=pl, r=14.0, h=32.0)
    _prop(P.sack, b, x=xh * 0.30, y=yb - 22.0, z=pl, r=12.0, h=28.0)
    # 干草垛（左后）+ 干草捆（右前）
    _prop(P.haystack, b, x=-xh * 0.72, y=yb - 52.0, z=pl, r=28.0, h=50.0, pole=True)
    _prop(P.hay_bale, b, x=xh * 0.52, y=yf + 44.0, z=pl, w=70.0, d=40.0, h=32.0)
    _prop(P.hay_bale, b, x=xh * 0.52, y=yf + 44.0, z=pl + 32.0, w=64.0, d=36.0,
          h=28.0)
    # 上层草棚板（谷仓的 hayloft）：后半进深一块楼板 + 板上干草
    loft_z = pl + L["back_h"] * 0.58
    lw = xh * 2.0 * 0.86
    b.box_bottom((lw, depth * 0.42, 9.0), (0.0, yb - depth * 0.24), loft_z, "wood")
    b.box_bottom((lw, 9.0, 13.0), (0.0, yb - depth * 0.46), loft_z - 13.0, "timber")
    _prop(P.haystack, b, x=-xh * 0.38, y=yb - depth * 0.24, z=loft_z + 9.0, r=22.0,
          h=36.0, pole=False)
    _prop(P.plank_pile, b, x=xh * 0.42, y=yb - depth * 0.24, z=loft_z + 9.0, w=62.0,
          n=6)
    _prop(P.ladder, b, x=xh * 0.86, y=yf + 30.0, z=pl, h=110.0, w=22.0, lean=7.0)
    # 农具 + 板车 + 桶 + 柴
    _prop(P.hay_fork, b, x=-xh + 20.0, y=yb - 20.0, z=pl + 96.0, seed=3)
    _prop(P.broom_bundle, b, x=-xh + 44.0, y=yb - 20.0, z=pl + 96.0, h=90.0, n=2)
    _prop(P.cart, b, x=-xh * 0.34, y=yf + 46.0, z=pl, w=96.0, d=44.0)
    _prop(P.barrel, b, x=-xh + 24.0, y=yf + 24.0, z=pl, r=15.0, h=44.0, open_top=True)
    _prop(P.bucket, b, x=-xh + 24.0, y=yf + 62.0, z=pl, r=10.0, h=22.0)
    _prop(P.wheelbarrow, b, x=xh * 0.20, y=yf + 30.0, z=pl)
    _wall_lantern(b, x=xh * 0.10, y_wall=yb, z=pl + L["back_h"] * 0.62, s=20.0)


def _cottage(b, L):
    """茅草农舍（紧凑内景）：床贴后墙 / 小壁炉 / 桌贴前墙 / 柴堆 / 陶罐 / 晾晒架。

    **进深够不够：不够。** 8 格档净进深 = 152−2×18 = 116px ≈ 1.5m，床（深 64）与
    桌（深 28）各贴一侧墙后中间只剩 ~6px 通行缝，家具几乎相碰。结论：cottage 摆得下
    "床 + 桌 + 炉 + 柴"，但**需 12 格档才有舒展的合格内景**（cottage 无 12 格档，
    故只能按 8 格出图，观感偏挤 —— 见报告）。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L)
    # 床贴后墙左段（独占左半的进深），其余家具一律排到"床沿以外的前场"
    _bed(b, x=-xh + 58.0, y=yb - 32.0, z=pl, ln=112.0, w=58.0, head=-1.0,
         cloth="cloth_ochre")
    hm = _hearth(b, xh - 54.0, yb, pl, w=52.0, h=112.0)
    _prop(P.pot, b, x=xh - 54.0, y=yb - 24.0, z=pl + 8.0, r=11.0, h=18.0, mat="clay")
    _prop(P.pot, b, x=xh - 24.0, y=yb - 24.0, z=hm["mantle"], r=8.0, h=14.0,
          mat="stone_dark")
    # 后墙板架放"床与炉之间"的上方（离床面 ≥ 40px，不穿床）
    sh = _shelf(b, x=-6.0, y_wall=yb, z=pl + 96.0, w=66.0, levels=2, d=18.0, dh=40.0)
    _prop(P.pot, b, x=-6.0, y=yb - 11.0, z=sh[0], r=8.0, h=15.0, mat="clay")
    _prop(P.pot, b, x=-28.0, y=yb - 11.0, z=sh[1], r=7.0, h=13.0, mat="stone_dark")
    # 桌 + 两凳（前场右侧：床/柴堆之外的唯一空位）
    _prop(P.table, b, x=xh * 0.36, y=yf + 34.0, z=pl, w=52.0, d=26.0, h=42.0)
    _prop(P.stool, b, x=xh * 0.36 - 48.0, y=yf + 34.0, z=pl, r=11.0, h=27.0)
    _prop(P.stool, b, x=xh * 0.36 + 46.0, y=yf + 34.0, z=pl, r=11.0, h=27.0)
    _rug(b, xh * 0.36, yf + 34.0, pl + 0.6, 100.0, 56.0, "cloth_red")
    # 柴堆 + 柴筐（前场左侧，与床沿留 6px 以上间隙）
    _prop(P.log_pile, b, x=-xh * 0.60, y=yf + 30.0, z=pl, rows=2, per_row=3, r=7.0)
    _prop(P.firewood_basket, b, x=-xh * 0.24, y=yf + 46.0, z=pl, r=17.0, h=20.0)
    _prop(P.bucket, b, x=xh * 0.86, y=yf + 30.0, z=pl, r=9.0, h=20.0)
    _prop(P.herb_rack, b, x=-2.0, y=yb, z=pl + 152.0, w=44.0, n=5, mat="timber")
    _wall_lantern(b, x=-xh * 0.34, y_wall=yb, z=pl + 124.0, s=18.0)


def _stable(b, L):
    """马厩（紧凑内景，单层厩舍）：三格隔栏 + 草料槽 + 水槽 + 马鞍架 + 干草 + 拴马桩。

    净高 = tier 的 `low`（只到厩舍地面层顶），家具高度一律压到 ≤ 110px，鞍架/工具架
    只能挂在后墙中腰。进深 12 格档净 ~156px 够"隔栏 + 一条清粪通道"，**摆不下**
    工作台类家具（如实记录在报告里）。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L)
    h = L["back_h"]
    # 三格隔栏（贴后墙）
    for k in range(3):
        x0 = -xh + 8.0 + k * (xh * 2.0 - 16.0) / 3.0
        x1 = -xh + 8.0 + (k + 1) * (xh * 2.0 - 16.0) / 3.0
        _stall(b, x0, x1, yb, pl, h=min(104.0, h - 24.0),
               rails=(0.44, 0.80))
    # 每格的草料槽 + 干草
    for k in range(3):
        cx = -xh + 8.0 + (k + 0.5) * (xh * 2.0 - 16.0) / 3.0
        _prop(P.trough, b, x=cx, y=yb - 62.0, z=pl, w=54.0, d=24.0, h=22.0)
        _prop(P.hay_bale, b, x=cx, y=yb - 16.0, z=pl, w=40.0, d=24.0, h=22.0)
    # 水槽（右前）+ 桶
    _prop(P.trough, b, x=xh * 0.60, y=yf + 34.0, z=pl, w=76.0, d=28.0, h=26.0)
    _prop(P.bucket, b, x=xh * 0.24, y=yf + 30.0, z=pl, r=10.0, h=22.0)
    # 马鞍架（后墙中腰：整件 104 高装不下，改挂墙横杆 + 鞍）
    b.box_bottom((xh * 1.28, 10.0, 10.0), (0.0, yb - 12.0), pl + 82.0, "timber")
    for sx in (-0.44, 0.14):
        b.box_bottom((26.0, 20.0, 14.0), (sx * xh, yb - 22.0), pl + 82.0, "leather")
        b.box_bottom((16.0, 8.0, 22.0), (sx * xh, yb - 22.0), pl + 60.0, "leather")
    _prop(P.tools_rack, b, x=-xh * 0.62, y=yb - 8.0, z=pl + 52.0, w=50.0)
    _prop(P.hay_fork, b, x=xh * 0.86, y=yb - 18.0, z=pl + 40.0, seed=7)
    _prop(P.sack_stack, b, x=-xh + 26.0, y=yf + 28.0, z=pl, r=13.0, h=30.0)
    _prop(P.barrel, b, x=-xh + 74.0, y=yf + 26.0, z=pl, r=14.0, h=40.0, open_top=True)
    # 拴马桩（棚下前缘）+ 草绳
    b.box_bottom((13.0, 13.0, 96.0), (xh - 40.0, yf + 12.0), pl, "wood_dark")
    _prop(P.rope_coil, b, x=xh - 40.0, y=yf + 12.0, z=pl + 96.0, r=10.0)
    _wall_lantern(b, x=-xh * 0.18, y_wall=yb, z=pl + 108.0, s=17.0)


def _shelter(b, L):
    """柱撑草棚（紧凑内景，三面开敞）：柴堆 / 板车 / 草垛 / 水桶 / 坐凳。

    **进深够不够：够但只能摆"辎重堆"。** 6 格档净进深 ~1.5m、净高 ~170px；无墙可挂靠
    → 所有家具自立（工具不上墙、灯吊在檐檩下），且**件数必须少**：5~6 件已是上限，
    再多就互相压成一片（本批只留柴/车/草/桶/凳，其余撤掉）。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    # 三面开敞：后壁只封下半（与装配器"只封背面下半"一致），上半透空
    L["wall_segments"] = [(L["back_h"] * 0.56, L["wall_low"])]
    _shell(b, L)
    # 檐檩 + 吊灯（无天花，灯吊在檩条下）
    b.box_bottom((xh * 2.0 + 18.0, 13.0, 13.0), (0.0, yf + 14.0), L["ceil"] - 15.0,
                 "timber")
    _prop(P.lantern, b, x=xh * 0.46, y=yf + 14.0, z=L["ceil"] - 56.0, s=18.0, h=26.0,
          bracket=False, lit=True, glass="glass")
    _prop(P.log_pile, b, x=-xh * 0.56, y=yb - 34.0, z=pl, rows=2, per_row=3, r=7.0)
    _prop(P.cart, b, x=-xh * 0.06, y=yf + 46.0, z=pl, w=84.0, d=40.0)
    _prop(P.hay_bale, b, x=xh * 0.44, y=yb - 30.0, z=pl, w=52.0, d=30.0, h=26.0)
    _prop(P.barrel, b, x=xh * 0.66, y=yf + 32.0, z=pl, r=14.0, h=40.0, open_top=True)
    _prop(P.stool, b, x=xh * 0.22, y=yf + 22.0, z=pl, r=12.0, h=28.0)
    _prop(P.bucket, b, x=-xh * 0.80, y=yf + 24.0, z=pl, r=9.0, h=20.0)


def _hayloft(b, L):
    """草棚顶民居：一层农舍起居（床/桌/小炉/草垛）+ 二层开敞干草棚（草垛/草叉/板材）。

    两层：底层 net=low 够住人；上层 net=up 只够放干草与矮农具（人站不直，本来就是
    货棚层）。总净深 12 格档 ~160px，家具排得开。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    mid = L["mid"]
    _shell(b, L, storey_split=True)
    # ---- 一层：农舍起居
    _bed(b, x=-xh + 78.0, y=yb - 38.0, z=pl, ln=134.0, w=66.0, head=-1.0,
         cloth="cloth_blue")
    hm = _hearth(b, xh - 54.0, yb, pl, w=54.0, h=110.0)
    _prop(P.stew_pot, b, x=xh - 54.0, y=yb - 26.0, z=pl + 8.0, r=16.0, h=22.0,
          fire=True)
    _prop(P.pot, b, x=xh - 22.0, y=yb - 24.0, z=hm["mantle"], r=8.5, h=15.0,
          mat="clay")
    _prop(P.table, b, x=-xh * 0.14, y=yf + 48.0, z=pl, w=58.0, d=30.0, h=44.0)
    _prop(P.bench, b, x=-xh * 0.14, y=yf + 76.0, z=pl, w=66.0, d=24.0, h=32.0)
    _prop(P.stool, b, x=-xh * 0.14 - 62.0, y=yf + 48.0, z=pl, r=11.0, h=27.0)
    _rug(b, -xh * 0.14, yf + 48.0, pl + 0.6, 122.0, 74.0)
    sh = _shelf(b, x=-xh + 62.0, y_wall=yb, z=pl + 92.0, w=86.0, levels=2, d=18.0,
                dh=40.0)
    _prop(P.pot, b, x=-xh + 62.0, y=yb - 11.0, z=sh[0], r=8.5, h=15.0, mat="clay")
    _prop(P.pot, b, x=-xh + 34.0, y=yb - 11.0, z=sh[1], r=8.0, h=14.0, mat="stone_dark")
    _prop(P.firewood_basket, b, x=xh - 26.0, y=yf + 28.0, z=pl, r=18.0, h=20.0)
    _prop(P.hay_bale, b, x=-xh + 24.0, y=yf + 28.0, z=pl, w=46.0, d=28.0, h=24.0)
    _prop(P.tools_rack, b, x=xh * 0.66, y=yb - 8.0, z=pl + 40.0, w=50.0)
    _prop(P.barrel, b, x=xh - 32.0, y=yb - 28.0, z=pl, r=13.0, h=38.0)
    _wall_lantern(b, x=-xh * 0.12, y_wall=yb, z=pl + 120.0, s=18.0)
    # ---- 二层：开敞干草棚
    lz = mid
    _prop(P.haystack, b, x=-xh * 0.50, y=yb - 44.0, z=lz, r=25.0, h=44.0, pole=False)
    _prop(P.hay_bale, b, x=-xh * 0.10, y=yb - 38.0, z=lz, w=52.0, d=30.0, h=28.0)
    _prop(P.hay_fork, b, x=xh * 0.54, y=yb - 16.0, z=lz, seed=5)
    _prop(P.hay_fork, b, x=xh * 0.70, y=yb - 16.0, z=lz, seed=9)
    _prop(P.plank_pile, b, x=xh * 0.30, y=yf + 34.0, z=lz, w=56.0, n=5)
    _prop(P.ladder, b, x=xh * 0.84, y=yf + 20.0, z=pl, h=104.0, w=22.0, lean=6.0)
    _prop(P.lantern, b, x=-xh * 0.28, y=0.0, z=lz + 54.0, s=17.0, h=24.0,
          bracket=False, lit=True, glass="glass")


def _smithy_common(b, L, twin=False, bellows=False, display=False):
    """smithy1 的"四件套"（火炉 + 铁砧 + 淬火桶 + 工具架）—— smithy2/3/4 共用底板。

    差异只在炉的座数（twin）、风箱（bellows）、展示架（display）与墙材/烟囱对位。
    摆位纪律：炉占后墙两角（|x| ≈ xh−70），砧/淬火桶排在**炉前**，工作台给中/后场，
    矮件（煤/柴/桶）贴地散开 —— 否则 12 格档也会糊成一坨棕色。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    ceil = L["ceil"]
    fx_list = [-xh + 70.0] if not twin else [-xh + 68.0, xh - 68.0]
    for k, fx in enumerate(fx_list):
        B.forge(b, fx, yb - 54.0, pl, w=66.0, d=52.0, body_h=74.0,
                flue_h=max(24.0, ceil - 196.0))
        ax = fx + (16.0 if not k else -16.0)
        _prop(P.anvil, b, x=ax, y=yf + 42.0, z=pl, stump=True, stump_h=40.0)
        _prop(P.tongs, b, x=ax - 26.0, y=yf + 40.0, z=pl + 62.0)
        qx = fx + 74.0 if not k else fx - 44.0
        _prop(P.quench_barrel, b, x=qx, y=yf + 48.0, z=pl)
        _prop(P.coal_pile, b, x=fx + (22.0 if not k else -22.0), y=yf + 18.0, z=pl,
              w=40.0, h=18.0)
    # 工具架（后墙偏左中）：`tools_rack` 的 z 是**横杆高度**，工具从 z 往下挂
    _prop(P.tools_rack, b, x=-xh * 0.16, y=yb - 8.0,
          z=pl + min(158.0, ceil - 44.0), w=68.0)
    # 工作台：双炉放**中后窄台**（两支炉之间只有 x∈(−44,44) 可用），单炉靠右后
    if twin:
        _prop(P.bench, b, x=0.0, y=yb - 16.0, z=pl, w=70.0, d=24.0, h=44.0)
    else:
        _prop(P.bench, b, x=xh * 0.58, y=yb - 36.0, z=pl, w=76.0, d=30.0, h=46.0)
    _prop(P.grindstone, b, x=xh * 0.42, y=yf + 44.0, z=pl, r=24.0)
    _prop(P.log_pile, b, x=-xh * 0.46, y=yf + 26.0, z=pl, rows=2, per_row=3, r=8.0)
    _prop(P.barrel, b, x=-xh + 20.0, y=yf + 50.0, z=pl, r=15.0, h=42.0, open_top=True)
    _prop(P.bucket, b, x=-xh + 20.0, y=yf + 86.0, z=pl, r=10.0, h=22.0)
    _prop(P.milk_churn, b, x=-xh + 26.0, y=yb - 24.0, z=pl, r=12.0, h=54.0)
    _prop(P.sack, b, x=-xh + 60.0, y=yb - 14.0, z=pl, r=13.0, h=30.0)
    if bellows:
        bx = xh * 0.02 if twin else xh * 0.26
        b.box_bottom((52.0, 36.0, 34.0), (bx, yb - 48.0), pl + 30.0, "leather")
        b.box_bottom((62.0, 13.0, 12.0), (bx, yb - 30.0), pl + 52.0, "wood")
    if display and not twin:
        sh = _shelf(b, x=xh * 0.62, y_wall=yb, z=pl + 92.0, w=84.0, levels=2, d=20.0,
                    dh=42.0)
        for zz in sh:
            _prop(P.pottery_row, b, x=xh * 0.62, y=yb - 11.0, z=zz, n=4, r=9.0, h=17.0)
    _wall_lantern(b, x=-xh * 0.34, y_wall=yb, z=pl + min(150.0, ceil - 46.0), s=20.0)


def _smithy2(b, L):
    """大铁匠铺（半封闭，双炉）：两座火炉 + 双铁砧 + 淬火桶 ×2 + 工具架 + 风箱 + 右侧半封闭木屋。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L)
    _smithy_common(b, L, twin=True, bellows=True)
    # 半封闭木屋隔墙（最右一跨，与装配器"右侧木板墙 + 真门"对位；不压右炉）
    ix = xh - 26.0
    b.box_bottom((46.0, L["depth"] * 0.78, L["back_h"] - 46.0),
                 (ix, yb - L["depth"] * 0.39), pl, "wood_light")
    b.box_bottom((46.0, 12.0, 12.0), (ix, yb - L["depth"] * 0.78), pl, "timber")
    _prop(P.crate_stack, b, x=ix, y=yf + 30.0, z=pl, s=24.0, h=22.0, n=2)
    _prop(P.plank_pile, b, x=xh * 0.34, y=yb - 24.0, z=pl, w=58.0, n=4)


def _smithy3(b, L):
    """铁匠工坊（石砌室内化）：同一套四件 + 中后落地石烟囱对位 + 晾铁架 + 大水槽。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L)
    _smithy_common(b, L, bellows=True, display=True)
    # 落地石烟囱（对位装配器山墙端烟囱）：放**后墙正中**，不与炉/展示架争位
    b.box_bottom((42.0, 50.0, L["back_h"]), (0.0, yb - 26.0), pl, "stone_dark")
    b.box_bottom((56.0, 64.0, 16.0), (0.0, yb - 26.0), pl, "stone")
    # 晾铁架（铁艺横杆 + 挂件）+ 大水槽
    B.iron_rack(b, min(92.0, xh * 0.7), x=-xh * 0.52, y_wall=yb,
                z=pl + min(118.0, L["ceil"] - 90.0), pieces=4, hook=True)
    b.box_bottom((82.0, 32.0, 30.0), (xh * 0.24, yf + 34.0), pl, "wood_dark")
    b.box_bottom((70.0, 24.0, 6.0), (xh * 0.24, yf + 34.0), pl + 30.0, "glass_lead")
    _prop(P.barrel, b, x=xh * 0.60, y=yb - 30.0, z=pl, r=14.0, h=40.0, open_top=True)


def _smithy4(b, L):
    """锻造车间（大跨度砖厂 + 前凸水轮房）：大炉 + 双砧 + 水轮传动 + 淬火槽 + 成品展架。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L)
    _smithy_common(b, L, twin=True, bellows=True)
    # 水轮房的"内侧"：竖传动轴 + 大齿轮（轮面在前层，室内看到的是轴与齿）
    wx = -xh + 62.0
    b.cylinder((wx, yf + 34.0, pl + 92.0), 15.0, 180.0, "timber", 14)
    b.cylinder((wx, yf + 34.0, pl + 72.0), 34.0, 18.0, "iron", 18)
    for k in range(8):
        th = 2.0 * math.pi * k / 8.0
        b.box_bottom((15.0, 12.0, 12.0),
                     (wx + math.cos(th) * 30.0, yf + 34.0 + math.sin(th) * 30.0),
                     pl + 56.0, "timber")
    # 引水槽（前凸水轮房的地沟盖上石板）
    b.box_bottom((xh * 0.9, 26.0, 20.0), (-xh * 0.44, yf + 54.0), pl, "stone")
    _prop(P.water_butt, b, x=-xh * 0.20, y=yf + 40.0, z=pl, r=18.0, h=56.0, lid=False,
          tap=False, bucket2=False)
    _prop(P.stone_pile, b, x=xh * 0.30, y=yf + 26.0, z=pl, w=70.0, h=34.0, seed=4)
    _prop(P.wheel_pile, b, x=xh * 0.62, y=yb - 30.0, z=pl, w=52.0, h=54.0, n=2)


def _alchemy(b, L):
    """炼金工坊：坩埚炉 + 蒸馏器 + 药瓶架 + 草药晾架 + 玻璃箱 + 大烟囱对位。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    ceil = L["ceil"]
    _shell(b, L)
    # 坩埚炉（贴后墙左段）+ 砖砌烟道（对位装配器三根砖烟囱）
    cx = -xh + 68.0
    b.box_bottom((72.0, 60.0, 66.0), (cx, yb - 32.0), pl, "brick")
    b.box_bottom((58.0, 20.0, 32.0), (cx, yb - 62.0), pl + 34.0, "cavity")
    _flame(b, cx, yb - 66.0, pl + 36.0, s=2.6)
    b.box_bottom((76.0, 12.0, 12.0), (cx, yb - 62.0), pl + 26.0, "stone_dark")
    b.box_bottom((58.0, 58.0, max(20.0, ceil - 130.0)), (cx, yb - 34.0), pl + 66.0,
                 "brick")
    _prop(P.cauldron, b, x=cx + 4.0, y=yb - 62.0, z=pl + 64.0, r=20.0, h=24.0,
          brew="glow_water", fire=False, ladle=False)
    # 药瓶架（后墙右段）：z 与层距受墙顶约束（层板顶不得越 back_h）
    sh = _shelf(b, x=xh - 74.0, y_wall=yb, z=pl + 46.0, w=118.0, levels=3, d=24.0,
                dh=40.0)
    _prop(P.potion_bottles, b, x=xh - 40.0, y=yb - 14.0, z=sh[1], w=46.0, h=48.0, n=5,
          seed=3)
    _prop(P.potion_bottles, b, x=xh - 40.0, y=yb - 14.0, z=sh[0], w=44.0, h=44.0, n=4,
          seed=5)
    _prop(P.hourglass, b, x=xh - 96.0, y=yb - 14.0, z=sh[2], h=32.0, frame="bronze",
          sand=True)
    # 蒸馏器：放**落地工作台**上（放层板会让整件越过墙顶）
    _prop(P.table, b, x=xh - 52.0, y=yf + 40.0, z=pl, w=74.0, d=34.0, h=46.0)
    _prop(P.alembic, b, x=xh - 52.0, y=yf + 40.0, z=pl + 46.0 * GAME, h=68.0,
          heat=True, seed=2)
    _prop(P.glass_crate, b, x=xh - 26.0, y=yb - 26.0, z=pl, s=36.0, h=36.0, n=5,
          seed=7)
    _prop(P.table, b, x=-xh * 0.12, y=yf + 46.0, z=pl, w=76.0, d=36.0, h=46.0)
    _prop(P.inkwell_quill, b, x=-xh * 0.12 + 30.0, y=yf + 46.0,
          z=pl + 46.0 * GAME, w=36.0, n=2, seed=4)
    _prop(P.potion_bottles, b, x=-xh * 0.12 - 26.0, y=yf + 46.0,
          z=pl + 46.0 * GAME, w=38.0, h=40.0, n=3, seed=9)
    # 草药晾架（吊在梁下；herb_rack 的 z 是横杆高度，草药往下挂）
    _prop(P.herb_rack, b, x=xh * 0.24, y=yb - 22.0, z=pl + 148.0, w=62.0, n=7,
          mat="timber")
    _prop(P.dye_pots, b, x=0.0, y=yb - 22.0, z=pl, n=3, r=20.0, h=30.0, seed=6)
    _prop(P.crystal_cluster, b, x=-xh + 50.0, y=yf + 30.0, z=pl, w=46.0, h=48.0, n=4,
          seed=8)
    _prop(P.basket, b, x=-xh + 86.0, y=yf + 30.0, z=pl, r=16.0, h=16.0)
    _wall_lantern(b, x=-xh * 0.60, y_wall=yb, z=pl + min(156.0, ceil - 44.0), s=20.0)


def _guildhall(b, L):
    """行会馆（两层）：一层长桌 ×2 + 长凳 + 公告板 + 账簿台 + 地毯 + 火盆；
    二层书架成排 + 徽记挂毯 + 火盆 + 匣柜。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    mid = L["mid"]
    _shell(b, L, storey_split=True)
    # ---- 一层：大厅
    for k, (tx, rug) in enumerate(((-xh * 0.44, "cloth_red"),
                                   (xh * 0.44, "cloth_blue"))):
        ty = yf + 56.0
        _prop(P.table, b, x=tx, y=ty, z=pl, w=96.0, d=36.0, h=48.0)
        _prop(P.bench, b, x=tx, y=ty - 34.0, z=pl, w=100.0, d=24.0, h=34.0)
        _prop(P.bench, b, x=tx, y=ty + 34.0, z=pl, w=100.0, d=24.0, h=34.0)
        _prop(P.stool, b, x=tx + 62.0, y=ty, z=pl, r=12.0, h=29.0)
        _rug(b, tx, ty, pl + 0.6, 142.0, 108.0, rug)
    b.box_bottom((xh * 0.96, 62.0, 14.0), (0.0, yb - 44.0), pl, "stone")
    _prop(P.table, b, x=0.0, y=yb - 44.0, z=pl + 14.0, w=104.0, d=34.0, h=48.0)
    for sx in (-1.0, 1.0):
        _prop(P.stool, b, x=sx * 54.0, y=yb - 44.0, z=pl + 14.0, r=12.0, h=29.0)
    _prop(P.standing_board, b, x=-xh * 0.74, y=yb - 36.0, z=pl, w=44.0, h=62.0,
          mat="wood")
    _counter(b, xh * 0.60, y=yf + 44.0, z=pl, w=88.0, d=32.0, h=58.0)
    _prop(P.book_stack, b, x=xh * 0.60, y=yf + 44.0, z=pl + 58.0, w=40.0, h=32.0,
          n=5)
    _prop(P.inkwell_quill, b, x=xh * 0.60 + 30.0, y=yf + 44.0, z=pl + 58.0, w=34.0,
          n=2, seed=6)
    _brazier(b, -xh * 0.86, yf + 30.0, pl, r=18.0, h=26.0)
    _brazier(b, xh * 0.86, yf + 30.0, pl, r=18.0, h=26.0)
    sh = _shelf(b, x=-xh * 0.58, y_wall=yb, z=pl + 46.0, w=96.0, levels=3, d=22.0,
                dh=44.0)
    for zz in sh:
        _prop(P.pottery_row, b, x=-xh * 0.58, y=yb - 12.0, z=zz, n=4, r=9.0, h=17.0)
    _prop(P.banner, b, x=xh * 0.30, y=yb - 4.0, z=mid - 16.0, w=28.0, h=78.0,
          mat="cloth_red", pole=False)
    _prop(P.chest, b, x=xh - 40.0, y=yf + 28.0, z=pl, w=46.0, d=30.0, h=32.0)
    _wall_lantern(b, x=-xh * 0.28, y_wall=yb, z=pl + 156.0, s=20.0)
    # ---- 二层：议事/档案
    z2 = mid
    for k in range(3):
        sx = -xh * 0.60 + k * xh * 0.60
        sh2 = _shelf(b, x=sx, y_wall=yb, z=z2 + 24.0, w=76.0, levels=3, d=22.0,
                     dh=44.0)
        _prop(P.book_stack, b, x=sx - 16.0, y=yb - 12.0, z=sh2[0], w=38.0, h=30.0,
              n=5, seed=k * 3 + 1)
        _prop(P.book_stack, b, x=sx + 18.0, y=yb - 12.0, z=sh2[1], w=36.0, h=28.0,
              n=4, seed=k * 5 + 2)
    _prop(P.table, b, x=-xh * 0.20, y=yf + 48.0, z=z2, w=74.0, d=34.0, h=46.0)
    _prop(P.stool, b, x=-xh * 0.20 - 60.0, y=yf + 48.0, z=z2, r=12.0, h=28.0)
    _prop(P.stool, b, x=-xh * 0.20 + 58.0, y=yf + 48.0, z=z2, r=12.0, h=28.0)
    _candelabra(b, xh * 0.54, yf + 46.0, z2, h=78.0, candles=5)
    _prop(P.shield_plaque, b, x=xh * 0.74, y=yb - 4.0, z=z2 + 88.0, w=38.0, h=44.0,
          mat="wood_light", boss="iron", seed=4)
    _prop(P.chest, b, x=xh - 40.0, y=yf + 28.0, z=z2, w=46.0, d=30.0, h=32.0)
    _rug(b, -xh * 0.20, yf + 48.0, z2 + 0.6, 142.0, 90.0, "cloth_ochre")
    _wall_lantern(b, x=-xh * 0.32, y_wall=yb, z=z2 + 150.0, s=18.0)


def _barracks(b, L):
    """兵营（两层）：一层兵器架 + 草人靶 + 箭靶 + 火盆 + 长凳 + 货箱 + 盾墙；
    二层上下铺成排 + 兵器架 + 军旗 + 火盆。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    mid = L["mid"]
    _shell(b, L, storey_split=True)
    # ---- 一层：训练 / 装备
    for sx in (-1.0, 1.0):
        _prop(P.weapon_rack, b, x=sx * xh * 0.70, y=yb - 12.0, z=pl, w=62.0,
              h=74.0, seed=1 if sx < 0 else 2)
    _prop(P.training_dummy, b, x=-xh * 0.40, y=yf + 46.0, z=pl, h=112.0, shield=True,
          seed=3)
    _prop(P.archery_target, b, x=xh * 0.40, y=yf + 44.0, z=pl, h=90.0, arrows=3,
          seed=4)
    _brazier(b, 0.0, yf + 30.0, pl, r=18.0, h=26.0)
    _prop(P.bench, b, x=-xh * 0.10, y=yf + 50.0, z=pl, w=84.0, d=26.0, h=34.0)
    _prop(P.bench, b, x=-xh * 0.10, y=yf + 80.0, z=pl, w=84.0, d=26.0, h=34.0)
    _prop(P.crate_stack, b, x=xh * 0.84, y=yf + 28.0, z=pl, s=26.0, h=22.0, n=3)
    _prop(P.barrel, b, x=-xh * 0.88, y=yf + 28.0, z=pl, r=15.0, h=42.0, open_top=True)
    for sx in (-0.52, -0.20, 0.12, 0.44):
        _prop(P.shield_plaque, b, x=sx * xh, y=yb - 4.0, z=pl + 116.0, w=38.0, h=44.0,
              mat="wood_light", boss="iron", seed=int(abs(sx) * 20) + 3)
    _prop(P.standing_board, b, x=xh * 0.44, y=yb - 36.0, z=pl, w=44.0, h=62.0,
          mat="wood")
    _wall_lantern(b, x=-xh * 0.14, y_wall=yb, z=pl + 158.0, s=20.0)
    # ---- 二层：宿营（三组上下铺 + 兵器 + 火盆）
    z2 = mid
    for k in range(3):
        x = -xh * 0.60 + k * xh * 0.60
        _wall_bunk(b, x, z2, yb, w=72.0, d=40.0, tiers=2, lo=46.0, gap=62.0,
                   cloth=("cloth_blue", "cloth_ochre", "cloth_red")[k])
    _prop(P.chest, b, x=xh * 0.60, y=yf + 28.0, z=z2, w=44.0, d=28.0, h=30.0)
    _prop(P.weapon_rack, b, x=xh * 0.62, y=yb - 12.0, z=z2, w=56.0, h=68.0, seed=5)
    _brazier(b, 0.0, yf + 32.0, z2, r=17.0, h=24.0)
    _prop(P.banner, b, x=-xh * 0.90, y=yb - 4.0, z=z2 + 148.0, w=28.0, h=78.0,
          mat="cloth_red", pole=False)
    _prop(P.crate_stack, b, x=-xh * 0.82, y=yf + 28.0, z=z2, s=24.0, h=20.0, n=2)
    _wall_lantern(b, x=xh * 0.12, y_wall=yb, z=z2 + 148.0, s=18.0)


def _warehouse(b, L):
    """仓库：货架成排 + 麻袋堆 + 货箱 + 吊臂滑轨 + 货称 + 挂灯。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    ceil = L["ceil"]
    _shell(b, L)
    # 后墙重货架 ×3（每层都塞货箱/麻袋；层板顶不得越墙顶）
    for sx in (-xh * 0.62, 0.0, xh * 0.62):
        sh = _shelf(b, x=sx, y_wall=yb, z=pl + 16.0, w=72.0, levels=4, d=26.0,
                    dh=42.0)
        for j, zz in enumerate(sh):
            if j % 2 == 0:
                _prop(P.crate, b, x=sx - 18.0, y=yb - 14.0, z=zz, s=24.0, h=20.0)
                _prop(P.sack, b, x=sx + 20.0, y=yb - 14.0, z=zz, r=11.0, h=24.0)
            else:
                _prop(P.barrel, b, x=sx + 18.0, y=yb - 14.0, z=zz, r=12.0, h=32.0)
                _prop(P.crate, b, x=sx - 22.0, y=yb - 14.0, z=zz, s=20.0, h=17.0)
    _hoist(b, 0.0, yf + 48.0, ceil - 24.0, drop=64.0, w=min(xh * 1.6, 200.0))
    b.box_bottom((xh * 0.64, 58.0, 12.0), (xh * 0.62, yf + 30.0), pl, "stone")
    _prop(P.crate_stack, b, x=xh * 0.62, y=yf + 30.0, z=pl + 12.0, s=26.0, h=22.0,
          n=3)
    _prop(P.sack_stack, b, x=xh * 0.26, y=yf + 34.0, z=pl, r=13.0, h=30.0)
    _scale_beam(b, -xh * 0.36, yf + 42.0, pl, w=68.0, h=82.0)
    _prop(P.barrel_stand, b, x=-xh * 0.64, y=yf + 28.0, z=pl, w=72.0, r=12.0,
          bl=32.0, h=42.0)
    _prop(P.rope_coil, b, x=-xh + 24.0, y=yb - 24.0, z=pl, r=11.0)
    _prop(P.plank_pile, b, x=-xh + 56.0, y=yf + 24.0, z=pl, w=52.0, n=4)
    _wall_lantern(b, x=-xh * 0.30, y_wall=yb, z=pl + L["back_h"] * 0.68, s=20.0)
    _hang_lantern(b, x=xh * 0.28, y=yf + 44.0, z_ceil=ceil, drop=26.0, s=20.0)


def _library(b, L):
    """图书馆（两层书库）：书墙成排 + 阅览桌 + 梯子 + 卷轴柜 + 烛台。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    mid = L["mid"]
    _shell(b, L, storey_split=True)
    # ---- 一层：书墙 ×3 + 阅览桌 ×2
    for sx in (-xh * 0.62, 0.0, xh * 0.62):
        sh = _shelf(b, x=sx, y_wall=yb, z=pl + 18.0, w=78.0, levels=4, d=24.0,
                    dh=44.0)
        for j, zz in enumerate(sh):
            _prop(P.book_stack, b, x=sx - 14.0, y=yb - 12.0, z=zz, w=38.0, h=30.0,
                  n=5, seed=j + int(abs(sx)) % 7)
            _prop(P.book_stack, b, x=sx + 20.0, y=yb - 12.0, z=zz, w=32.0, h=26.0,
                  n=4, seed=j * 3 + 2)
    for tx in (-xh * 0.40, xh * 0.40):
        ty = yf + 48.0
        _prop(P.table, b, x=tx, y=ty, z=pl, w=74.0, d=34.0, h=46.0)
        _prop(P.stool, b, x=tx - 58.0, y=ty, z=pl, r=12.0, h=29.0)
        _prop(P.stool, b, x=tx + 56.0, y=ty, z=pl, r=12.0, h=29.0)
        _prop(P.book_stack, b, x=tx, y=ty, z=pl + 46.0 * GAME, w=36.0, h=28.0, n=5,
              seed=int(abs(tx)) % 9 + 1)
        _prop(P.candle_glass, b, x=tx + 28.0, y=ty, z=pl + 46.0 * GAME, h=40.0,
              lit=True, seed=3)
        _rug(b, tx, ty, pl + 0.6, 122.0, 80.0, "cloth_ochre")
    _prop(P.ladder, b, x=xh * 0.88, y=yf + 20.0, z=pl, h=110.0, w=22.0, lean=6.0)
    _prop(P.scroll_rack, b, x=-xh + 66.0, y=yb - 30.0, z=pl, w=56.0, h=86.0, seed=4)
    _prop(P.candle_rack, b, x=xh * 0.74, y=yb - 34.0, z=pl, w=48.0, h=70.0, tiers=3,
          seed=2)
    _wall_lantern(b, x=-xh * 0.18, y_wall=yb, z=pl + 158.0, s=20.0)
    # ---- 二层：书墙 + 卷轴柜 + 阅览
    z2 = mid
    for sx in (-xh * 0.62, 0.0, xh * 0.62):
        sh2 = _shelf(b, x=sx, y_wall=yb, z=z2 + 18.0, w=78.0, levels=4, d=24.0,
                     dh=42.0)
        for j, zz in enumerate(sh2):
            _prop(P.book_stack, b, x=sx - 16.0, y=yb - 12.0, z=zz, w=38.0, h=30.0,
                  n=5, seed=j * 5 + 3)
            _prop(P.book_stack, b, x=sx + 18.0, y=yb - 12.0, z=zz, w=32.0, h=26.0,
                  n=4, seed=j * 7 + 5)
    _prop(P.scroll_rack, b, x=-xh * 0.30, y=yf + 32.0, z=z2, w=56.0, h=84.0, seed=6)
    _prop(P.table, b, x=xh * 0.42, y=yf + 48.0, z=z2, w=70.0, d=34.0, h=46.0)
    _prop(P.stool, b, x=xh * 0.42 - 56.0, y=yf + 48.0, z=z2, r=12.0, h=28.0)
    _prop(P.inkwell_quill, b, x=xh * 0.42, y=yf + 48.0, z=z2 + 46.0 * GAME, w=36.0,
          n=3, seed=8)
    _candelabra(b, -xh * 0.64, yf + 48.0, z2, h=76.0, candles=5)
    _prop(P.ladder, b, x=-xh * 0.88, y=yf + 20.0, z=z2, h=104.0, w=22.0, lean=-6.0)
    _rug(b, xh * 0.42, yf + 48.0, z2 + 0.6, 126.0, 84.0)
    _wall_lantern(b, x=xh * 0.22, y_wall=yb, z=z2 + 154.0, s=18.0)


def _plaster_house(b, L):
    """抹灰街屋（别名 def，前层走 house 装配器）：民居底子 + 抹灰墙 + 街屋味：
    临街货架角 + 陶器 + 晾衣杆 + 壁炉 + 床桌。

    口径说明：`probe_city_scene.DEF_MAP` 把 plaster_house 路由到 **house 装配器**
    （单层），故内景按 house 的单层尺出图，家具与 house 同源、只换墙材与临街货架角。
    §3.1 表写"剖视 2 层"与此冲突（属布局器 TALL_DEFS 的旧口径），**以装配器为准**。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    _shell(b, L)
    _bed(b, x=-xh * 0.62, y=yb - 46.0, z=pl, ln=140.0, w=72.0, head=1.0,
         cloth="cloth_red")
    hx = xh - 62.0
    hm = _hearth(b, hx, yb, pl, w=58.0, h=118.0)
    _prop(P.pot, b, x=hx - 24.0, y=yb - 26.0, z=hm["mantle"], r=9.0, h=16.0,
          mat="clay")
    _prop(P.stew_pot, b, x=hx, y=yb - 26.0, z=pl + 8.0, r=17.0, h=24.0, fire=True)
    tx, ty = -xh * 0.18, yf + 46.0
    _prop(P.table, b, x=tx, y=ty, z=pl, w=64.0, d=34.0, h=46.0)
    _prop(P.bench, b, x=tx, y=ty + 42.0, z=pl, w=70.0, d=26.0, h=34.0)
    _prop(P.stool, b, x=tx - 76.0, y=ty, z=pl, r=12.0, h=29.0)
    _rug(b, tx, ty, pl + 0.6, 138.0, 80.0)
    # 临街货架角（抹灰街屋的"前店"）：矮货架 + 陶器 + 货筐
    sh = _shelf(b, x=-xh + 58.0, y_wall=yb, z=pl + 72.0, w=88.0, levels=3, d=22.0,
                dh=40.0)
    for j, zz in enumerate(sh):
        if j % 2:
            _prop(P.pottery_row, b, x=-xh + 58.0, y=yb - 12.0, z=zz, n=4, r=9.0, h=17.0,
                  seed=j + 2)
        else:
            _prop(P.produce_baskets, b, x=-xh + 58.0, y=yb - 12.0, z=zz, r=15.0,
                  h=15.0, seed=j + 4)
    _prop(P.barrel, b, x=-xh + 22.0, y=yf + 26.0, z=pl, r=14.0, h=40.0, open_top=True)
    _prop(P.crate_stack, b, x=xh - 30.0, y=yf + 26.0, z=pl, s=26.0, h=24.0, n=2)
    _prop(P.clothesline, b, x0=-xh * 0.4, x1=xh * 0.4, y=yf + 18.0, z=pl + 150.0,
          items=3, seed=5)
    _prop(P.herb_rack, b, x=6.0, y=yb, z=pl + 158.0, w=52.0, n=6, mat="timber")
    _wall_lantern(b, x=xh * 0.20, y_wall=yb, z=pl + 152.0, s=19.0)


# ---------------------------------------------------------------- 塔类（圆塔 / 方形退台 / 城门楼）

def _windmill(b, L):
    """风车磨坊（圆塔剖视，两层）：一层存货筛粉 / 二层磨盘 + 传动轴 + 料斗。

    只画 y>0 的背面半圈（`_round_shell`），半径按 tier 的 taper 收分，与前层塔身同
    锥度。**圆塔家具必须收在内切带里**（|x|、y ≤ 0.6×(R−wt)），否则两侧会戳出弧壁。
    """
    pl, R, wt = L["plinth"], L["R"], L["wt"]
    ri = R - wt
    bd = ri * 0.60
    mid = L["mid"]
    _round_shell(b, L)
    # ---- 一层：存货 / 筛粉
    _prop(P.sack_stack, b, x=-bd * 0.62, y=bd * 0.42, z=pl, r=13.0, h=28.0, seed=2)
    _prop(P.sack_stack, b, x=bd * 0.10, y=bd * 0.46, z=pl, r=13.0, h=28.0, seed=5)
    _prop(P.sack, b, x=-bd * 0.10, y=bd * 0.60, z=pl, r=12.0, h=27.0)
    _prop(P.barrel, b, x=bd * 0.78, y=bd * 0.10, z=pl, r=14.0, h=42.0, open_top=True)
    _prop(P.basket, b, x=-bd * 0.86, y=bd * 0.02, z=pl, r=16.0, h=16.0)
    _prop(P.produce_baskets, b, x=bd * 0.72, y=bd * 0.52, z=pl, r=15.0, h=15.0,
          seed=3)
    _prop(P.water_butt, b, x=-bd * 1.02, y=bd * 0.62, z=pl, r=15.0, h=50.0, lid=True,
          tap=True, bucket2=False)
    _prop(P.ladder, b, x=bd * 0.92, y=-bd * 0.72, z=pl, h=86.0, w=22.0, lean=8.0)
    _prop(P.broom_bundle, b, x=-bd * 0.40, y=bd * 0.06, z=pl, h=92.0, n=2)
    _prop(P.glass_lantern, b, x=0.0, y=bd * 0.88, z=pl + 148.0, h=38.0, lit=True,
          seed=2)
    # ---- 二层：磨盘 + 传动轴 + 料斗
    z2 = mid
    _millstone(b, x=-bd * 0.46, y=bd * 0.46, z=z2, r=min(28.0, bd * 0.62))
    b.cylinder((0.0, bd * 0.56, z2 + 58.0), 10.0, 130.0, "timber", 12)
    b.cylinder((0.0, bd * 0.56, z2 + 112.0), 24.0, 15.0, "iron", 16)
    for k in range(6):
        th = 2.0 * math.pi * k / 6.0
        b.box_bottom((12.0, 10.0, 10.0),
                     (math.cos(th) * 20.0, bd * 0.56 + math.sin(th) * 20.0),
                     z2 + 114.0, "timber")
    b.cylinder((-bd * 0.46, bd * 0.46, z2 + 92.0), 26.0, 52.0, "wood", 14, taper=0.34)
    b.box_bottom((24.0, 24.0, 12.0), (-bd * 0.46, bd * 0.46), z2 + 84.0, "wood_dark")
    _prop(P.sack_stack, b, x=bd * 0.62, y=bd * 0.50, z=z2, r=13.0, h=28.0, seed=6)
    _prop(P.rope_coil, b, x=bd * 0.96, y=bd * 0.60, z=z2, r=10.0)


def _mage_tower(b, L):
    """法师塔（圆塔剖视，两层）：一层符文法阵 + 炼药台 + 书堆；二层水晶簇 + 星盘 + 书架 + 符文柱。

    圆塔家具一律收在内切带 |x|、y ≤ 0.6×(R−wt)（弧壁在两侧很浅，越界就戳出去）。
    """
    pl, R, wt = L["plinth"], L["R"], L["wt"]
    ri = R - wt
    bd = ri * 0.60
    mid = L["mid"]
    _round_shell(b, L)
    # ---- 一层：法阵 + 炼药 + 书堆
    _prop(P.summon_circle, b, x=0.0, y=bd * 0.10, z=pl + 0.8, r=min(30.0, bd * 0.66),
          lit=True, shards=4, seed=3)
    _prop(P.cauldron, b, x=-bd * 0.78, y=bd * 0.62, z=pl, r=16.0, h=24.0,
          brew="glow_water", fire=True, ladle=True, seed=2)
    _prop(P.alembic, b, x=bd * 0.72, y=bd * 0.66, z=pl, h=78.0, heat=True, seed=5)
    _prop(P.book_stack, b, x=-bd * 0.80, y=bd * 0.06, z=pl, w=24.0, h=26.0, n=5,
          seed=2)
    _prop(P.book_stack, b, x=bd * 0.84, y=bd * 0.06, z=pl, w=24.0, h=26.0, n=4,
          seed=4)
    _prop(P.rune_stone, b, x=-bd * 0.70, y=bd * 0.86, z=pl, h=104.0, w=30.0, seed=6)
    _prop(P.glass_crate, b, x=bd * 0.56, y=bd * 0.86, z=pl, s=30.0, h=32.0, n=4,
          seed=7)
    _prop(P.candle_glass, b, x=0.0, y=bd * 0.98, z=pl + 10.0, h=40.0, lit=True, seed=2)
    # ---- 二层：水晶 + 星盘 + 书堆 + 法杖
    z2 = mid
    _prop(P.crystal_cluster, b, x=-bd * 0.62, y=bd * 0.62, z=z2, w=44.0, h=54.0, n=5,
          seed=8)
    _prop(P.magic_spring, b, x=bd * 0.52, y=bd * 0.70, z=z2, r=22.0, h=46.0, seed=9)
    _prop(P.astrolabe, b, x=0.0, y=bd * 0.30, z=z2, r=22.0, stand=True, seed=3)
    _prop(P.staff_rack, b, x=-bd * 0.66, y=bd * 0.10, z=z2, w=44.0, h=82.0, n=3,
          seed=4)
    for j in range(2):
        _prop(P.book_stack, b, x=-bd * 0.20 + j * 34.0, y=bd * 0.92, z=z2,
              w=26.0, h=28.0, n=4, seed=j + 2)
    _prop(P.scroll_rack, b, x=bd * 0.62, y=bd * 0.16, z=z2, w=40.0, h=78.0, seed=5)
    _prop(P.hourglass, b, x=bd * 0.92, y=-bd * 0.20, z=z2 + 42.0, h=34.0,
          frame="bronze", sand=True)
    _prop(P.crystal_orb, b, x=bd * 0.92, y=-bd * 0.20, z=z2, r=14.0, stand=True,
          seed=6)


def _lighthouse(b, L):
    """灯塔（圆塔剖视，两层）：一层起居/储油（床 + 木桶 + 箱）；二层灯室（透镜 + 油桶 + 梯）。

    圆塔家具收在内切带内（同 mage_tower）。
    """
    pl, R, wt = L["plinth"], L["R"], L["wt"]
    ri = R - wt
    bd = ri * 0.60
    mid = L["mid"]
    _round_shell(b, L)
    # ---- 一层：起居 + 储油
    _bed(b, x=-bd * 0.50, y=bd * 0.62, z=pl, ln=88.0, w=50.0, head=1.0,
         cloth="cloth_blue")
    _prop(P.barrel, b, x=bd * 0.74, y=bd * 0.66, z=pl, r=14.0, h=42.0, open_top=True)
    _prop(P.barrel, b, x=bd * 0.94, y=bd * 0.24, z=pl, r=13.0, h=38.0)
    _prop(P.chest, b, x=-bd * 0.90, y=bd * 0.14, z=pl, w=40.0, d=26.0, h=28.0)
    _prop(P.sack_stack, b, x=-bd * 0.30, y=bd * 0.96, z=pl, r=12.0, h=26.0)
    _prop(P.trough, b, x=bd * 0.10, y=bd * 0.10, z=pl, w=48.0, d=22.0, h=20.0)
    _prop(P.rope_coil, b, x=-bd * 0.96, y=bd * 0.72, z=pl, r=10.0)
    _prop(P.ladder, b, x=bd * 0.96, y=-bd * 0.90, z=pl, h=98.0, w=22.0, lean=8.0)
    _prop(P.glass_lantern, b, x=0.0, y=bd * 1.06, z=pl + 112.0, h=38.0, lit=True,
          seed=3)
    # ---- 二层：灯室 / 储油
    z2 = mid
    _lens(b, x=0.0, y=bd * 0.34, z=z2 + 10.0, r=min(24.0, bd * 0.50), h=48.0)
    _prop(P.barrel, b, x=-bd * 0.84, y=bd * 0.66, z=z2, r=14.0, h=42.0, open_top=True)
    _prop(P.barrel, b, x=-bd * 0.92, y=bd * 0.20, z=z2, r=13.0, h=38.0)
    _prop(P.milk_churn, b, x=bd * 0.80, y=bd * 0.68, z=z2, r=12.0, h=48.0, mat="iron")
    _prop(P.broom_bundle, b, x=bd * 0.94, y=-bd * 0.86, z=z2, h=70.0, n=2)
    _prop(P.rope_coil, b, x=bd * 0.30, y=bd * 0.94, z=z2, r=10.0)
    _prop(P.hourglass, b, x=-bd * 0.60, y=bd * 0.94, z=z2 + 38.0, h=32.0,
          frame="bronze", sand=True)


def _tower(b, L):
    """瞭望塔（方形退台剖视，三层）：一层守卫（兵器架 + 火盆 + 箭束）；二层哨兵床铺；
    三层火盆 + 箭垛 + 沙袋。退台后墙按 tier 三段收分。"""
    pl = L["plinth"]
    mids = L["mids"]
    _tower_shell(b, L)
    yb = L["yb"]
    xh0 = L["step_w"][0] / 2.0 - 18.0
    # ---- 一层：守卫
    _prop(P.weapon_rack, b, x=-xh0 * 0.58, y=yb - 12.0, z=pl, w=58.0, h=72.0, seed=1)
    _prop(P.bench, b, x=xh0 * 0.52, y=yb - 36.0, z=pl, w=68.0, d=26.0, h=34.0)
    _brazier(b, 0.0, yb - 66.0, pl, r=17.0, h=24.0)
    _prop(P.barrel, b, x=xh0 * 0.70, y=-yb * 0.34, z=pl, r=14.0, h=40.0,
          open_top=True)
    _prop(P.bucket, b, x=-xh0 * 0.72, y=-yb * 0.34, z=pl, r=10.0, h=22.0)
    b.box_bottom((44.0, 22.0, 24.0), (xh0 * 0.06, yb - 30.0), pl, "wood")
    for k in range(4):
        b.cylinder((-16.0 + k * 11.0, yb - 30.0, pl + 50.0), 3.0, 50.0, "wood_light", 6)
    _prop(P.shield_plaque, b, x=-xh0 * 0.86, y=yb - 4.0, z=pl + 106.0, w=34.0, h=40.0,
          mat="wood_light", boss="iron", seed=3)
    _stairs(b, x=xh0 * 0.24, y=-yb * 0.46, z0=pl, z1=mids[1], w=48.0, steps=8)
    # ---- 二层：哨兵铺
    _wall_bunk(b, -xh0 * 0.36, mids[1], yb, w=58.0, d=38.0, tiers=2, lo=42.0,
               gap=56.0, cloth="cloth_ochre")
    _brazier(b, xh0 * 0.44, y=yb - 58.0, z=mids[1], r=15.0, h=22.0)
    b.box_bottom((40.0, 22.0, 22.0), (xh0 * 0.62, yb - 30.0), mids[1], "wood")
    for k in range(4):
        b.cylinder((xh0 * 0.62 - 15.0 + k * 10.0, yb - 30.0, mids[1] + 46.0), 3.0,
                   46.0, "wood_light", 6)
    _stairs(b, x=-xh0 * 0.24, y=-yb * 0.46, z0=mids[1], z1=mids[2], w=46.0, steps=7)
    # ---- 三层：箭垛 / 火盆 / 沙袋
    _brazier(b, 0.0, yb - 54.0, mids[2], r=16.0, h=24.0)
    for k in range(3):
        b.box_bottom((44.0, 28.0, 24.0), (-xh0 * 0.52 + k * 38.0, -yb * 0.40),
                     mids[2], "canvas")
    b.box_bottom((40.0, 22.0, 22.0), (xh0 * 0.62, yb - 30.0), mids[2], "wood")
    for k in range(3):
        b.cylinder((xh0 * 0.62 - 12.0 + k * 12.0, yb - 30.0, mids[2] + 46.0), 3.0,
                   46.0, "wood_light", 6)
    _prop(P.rope_coil, b, x=-xh0 * 0.76, y=yb - 42.0, z=mids[2], r=10.0)
    _wall_lantern(b, x=xh0 * 0.20, y_wall=yb, z=pl + 62.0, s=17.0)


def _gatehouse(b, L):
    """城门楼（紧凑内景 = **门洞通道**）：闸门 + 守卫桌 + 武器架 + 火盆 + 沙袋 + 火把。

    净宽 = 拱洞宽（约 1.4~1.8m）、净深 = 通道进深、净高 = 拱洞净高。**这是一条通道
    不是房间**：家具表宽一律压到 ≤ 60px 并贴东西两壁，中间留通行带 —— 该 def 不适用
    12 格档房间标准（如实记录在报告）。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    ceil = L["ceil"]
    _shell(b, L)
    # 洞顶石券（后口内表面）+ 后口半掩木门
    b.box_bottom((xh * 2.0 + 20.0, 26.0, 22.0), (0.0, yb - 14.0), ceil - 22.0, "stone")
    b.box_bottom((xh * 1.5, 16.0, int(ceil - pl - 30.0)), (0.0, yb - 10.0), pl + 4.0,
                 "wood_dark")
    # 闸门（半落铁栅，压在门洞前缘）
    for k in range(5):
        px = -xh * 0.66 + k * (xh * 1.32 / 4.0)
        b.box_bottom((8.0, 8.0, ceil * 0.42), (px, yf + 18.0), pl + ceil * 0.52,
                     "iron")
    b.box_bottom((xh * 1.44, 9.0, 9.0), (0.0, yf + 18.0), pl + ceil * 0.94, "iron")
    # 守卫桌（贴西壁的窄件）+ 凳 + 账本
    _prop(P.table, b, x=-xh + 22.0, y=yf + 46.0, z=pl, w=26.0, d=28.0, h=44.0)
    _prop(P.stool, b, x=-xh + 24.0, y=yf + 80.0, z=pl, r=10.0, h=27.0)
    _prop(P.inkwell_quill, b, x=-xh + 22.0, y=yf + 46.0, z=pl + 44.0 * GAME, w=18.0,
          n=1, seed=2)
    _prop(P.glass_lantern, b, x=-xh + 22.0, y=yf + 46.0,
          z=pl + 44.0 * GAME + 8.0, h=30.0, lit=True, seed=4)
    # 武器架（贴东壁）+ 沙袋 + 火盆
    _prop(P.weapon_rack, b, x=xh - 20.0, y=yb - 36.0, z=pl, w=26.0, h=66.0, seed=5)
    for k in range(3):
        b.box_bottom((40.0, 24.0, 20.0), (xh - 22.0, yf + 26.0 + k * 28.0), pl,
                     "canvas")
    _brazier(b, 0.0, yb - 42.0, pl, r=14.0, h=20.0, legs=False)
    _prop(P.rope_coil, b, x=-xh + 14.0, y=yb - 36.0, z=pl, r=9.0)
    _prop(P.bucket, b, x=-xh + 16.0, y=yb - 62.0, z=pl, r=9.0, h=20.0)
    for sx in (-1.0, 1.0):
        _prop(P.lantern, b, x=sx * (xh - 4.0), y=yf + 30.0, z=pl + ceil * 0.66,
              s=16.0, h=24.0, bracket=True, lit=True, glass="glass")
    _prop(P.shield_plaque, b, x=0.0, y=yb - 4.0, z=pl + ceil * 0.64, w=32.0, h=38.0,
          mat="wood_light", boss="iron", seed=7)


def _rowhouse(b, L):
    """联排三层（三层剖面）：底层商铺（柜台 + 货架）/ 二层起居（炉 + 桌 + 水缸）/
    三层卧房（床 ×2 + 箱 + 书架）。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    mids = L["mids"]
    storeys = L["storeys"]
    L["wall_segments"] = [(storeys[0], L["wall_low"]),
                          (storeys[1], L["wall_up"]),
                          (storeys[2], L["wall_mid"])]
    _shell(b, L)
    # ---- 一层：商铺
    for sx in (-xh * 0.62, 0.0, xh * 0.62):
        sh = _shelf(b, x=sx, y_wall=yb, z=pl + 16.0, w=72.0, levels=3, d=22.0,
                    dh=44.0)
        for j, zz in enumerate(sh):
            if j % 2 == 0:
                _prop(P.produce_baskets, b, x=sx - 14.0, y=yb - 12.0, z=zz, r=15.0,
                      h=15.0, seed=j + int(abs(sx)) % 5)
            else:
                _prop(P.pottery_row, b, x=sx + 10.0, y=yb - 12.0, z=zz, n=4, r=9.0,
                      h=17.0, seed=j * 3 + 1)
        _prop(P.crate, b, x=sx + 22.0, y=yb - 12.0, z=sh[2], s=22.0, h=18.0)
    _counter(b, x=-xh * 0.05, y=yf + 46.0, z=pl, w=150.0, d=32.0, h=58.0)
    _prop(P.basket, b, x=-xh * 0.58, y=yf + 46.0, z=pl + 58.0, r=16.0, h=16.0)
    _prop(P.pottery_row, b, x=xh * 0.26, y=yf + 46.0, z=pl + 58.0, n=3, r=8.0, h=15.0)
    b.box_bottom((28.0, 20.0, 24.0), (xh * 0.54, yf + 46.0), pl + 58.0, "wood")
    _prop(P.chest, b, x=-xh + 26.0, y=yb - 26.0, z=pl, w=44.0, d=28.0, h=32.0)
    _hang_lantern(b, x=0.0, y=yf + 76.0, z_ceil=pl + storeys[0], drop=26.0, s=19.0)
    # ---- 二层：起居
    z2 = mids[1]
    hm = _hearth(b, xh - 56.0, yb, z2, w=54.0, h=116.0)
    _prop(P.stew_pot, b, x=xh - 56.0, y=yb - 26.0, z=z2 + 8.0, r=16.0, h=22.0,
          fire=True)
    _prop(P.pot, b, x=xh - 24.0, y=yb - 24.0, z=hm["mantle"], r=8.5, h=15.0,
          mat="clay")
    _prop(P.table, b, x=-xh * 0.28, y=yf + 48.0, z=z2, w=62.0, d=32.0, h=46.0)
    _prop(P.bench, b, x=-xh * 0.28, y=yf + 76.0, z=z2, w=68.0, d=24.0, h=34.0)
    _prop(P.stool, b, x=-xh * 0.28 - 72.0, y=yf + 48.0, z=z2, r=12.0, h=29.0)
    _prop(P.water_butt, b, x=-xh + 32.0, y=yf + 28.0, z=z2, r=16.0, h=52.0, lid=True,
          tap=False, bucket2=False)
    sh2 = _shelf(b, x=-xh * 0.62, y_wall=yb, z=z2 + 46.0, w=72.0, levels=2,
                 d=20.0, dh=42.0)
    for zz in sh2:
        _prop(P.pot, b, x=-xh * 0.62, y=yb - 11.0, z=zz, r=8.5, h=15.0, mat="clay")
    _rug(b, -xh * 0.28, yf + 48.0, z2 + 0.6, 130.0, 80.0, "cloth_red")
    _wall_lantern(b, x=xh * 0.18, y_wall=yb, z=z2 + 126.0, s=18.0)
    # ---- 三层：卧房
    z3 = mids[2]
    _bed(b, x=-xh + 80.0, y=yb - 38.0, z=z3, ln=124.0, w=64.0, head=-1.0,
         cloth="cloth_blue")
    _bed(b, x=xh - 80.0, y=yb - 38.0, z=z3, ln=124.0, w=64.0, head=1.0,
         cloth="cloth_ochre")
    _prop(P.chest, b, x=-xh + 40.0, y=yf + 28.0, z=z3, w=44.0, d=28.0, h=32.0)
    _prop(P.chest, b, x=xh - 42.0, y=yf + 28.0, z=z3, w=44.0, d=28.0, h=32.0)
    sh3 = _shelf(b, x=0.0, y_wall=yb, z=z3 + 54.0, w=88.0, levels=2, d=20.0,
                 dh=42.0)
    _prop(P.book_stack, b, x=-12.0, y=yb - 11.0, z=sh3[1], w=32.0, h=26.0, n=4)
    _prop(P.pot, b, x=20.0, y=yb - 11.0, z=sh3[0], r=8.0, h=14.0, mat="clay")
    _prop(P.stool, b, x=0.0, y=yf + 52.0, z=z3, r=12.0, h=28.0)
    _rug(b, 0.0, yf + 54.0, z3 + 0.6, 140.0, 84.0, "cloth_ochre")
    _wall_lantern(b, x=-xh * 0.28, y_wall=yb, z=z3 + 124.0, s=18.0)


_INTERIORS = {
    # —— 首轮 7 套
    "house": _house, "townhouse": _townhouse, "smithy1": _smithy,
    "tavern": _tavern, "bakery": _bakery, "shop": _shop, "cathedral": _cathedral,
    # —— 扩展轮 19 套
    "barn": _barn, "cottage": _cottage, "stable": _stable, "shelter": _shelter,
    "hayloft": _hayloft, "guildhall": _guildhall, "smithy2": _smithy2,
    "smithy3": _smithy3, "smithy4": _smithy4, "barracks": _barracks,
    "warehouse": _warehouse, "alchemy": _alchemy, "library": _library,
    "rowhouse": _rowhouse, "windmill": _windmill, "tower": _tower,
    "gatehouse": _gatehouse, "mage_tower": _mage_tower, "lighthouse": _lighthouse,
    # —— 别名 3 套（复用同源内景）
    "plaster_house": _plaster_house, "church": _cathedral, "chapel": _cathedral,
}





def clip_to_walls(ob, half_w, eps=0.5):
    """把后层几何按**外墙外皮**夹紧：删掉 x 越出 `±(half_w + eps)` 的面。

    内景是"室内内容"，任何像素都不该越出外墙外皮。但 `_prop` 统一乘了 `GAME_SCALE`
    （1.45），贴墙的宽件（木桶架/箱/麻袋）会被放大到戳出墙外 5~36px（旧资产
    townhouse/tavern/shop 实测 9.6/36.5/33.1px，本批新增的 stable/shelter/rowhouse 也有）
    —— 出图后在合成里会读成"房子边上飘着一只木桶"。这里统一夹紧到外墙外皮
    （`±W/2`，**不能取 W/2 以内，否则会把后墙本身切掉**）：切掉的部分落在墙体厚度
    内或墙外，前层墙壁会把切口盖住，观感无损。
    返回被删的面数（探针打印出来，便于发现"越界越得离谱"的摆位）。
    """
    import bmesh
    lim = half_w + eps
    me = ob.data
    bm = bmesh.new()
    bm.from_mesh(me)
    kill = [f for f in bm.faces if any(abs(v.co.x) > lim for v in f.verts)]
    if kill:
        bmesh.ops.delete(bm, geom=kill, context="FACES")
        bm.to_mesh(me)
        me.update()
    bm.free()
    return len(kill)


def build_back(def_name, wc=None):
    """后层（Interior 层）：后墙 + 地板 + 楼板 + 家具 + 暖光锚点。返回 (obj, L)。

    出口统一做一次 `clip_to_walls`（按外墙夹紧）；夹紧面数写进 `L["clipped"]`。
    """
    wc = wc or _WIDTHS[def_name]
    L = layout(def_name, wc)
    b = B.Builder("int_%s_back_w%d" % (def_name, wc))
    _INTERIORS[def_name](b, L)
    ob = b.to_object()
    ob.name = "int_%s_back" % def_name
    L["clipped"] = clip_to_walls(ob, L["W"] / 2.0)
    return ob, L


def lights(def_name, L):
    """暖色室内点光（1~2 盏／层）：[{loc, energy, color, radius}, ...]。

    刻意压低能量 —— 室内是壁炉/烛火照亮的暖暗，不是室外日光的亮度
    （硬约束：别把室内打亮到像室外）。多层建筑逐层一盏（`L["mids"]`），
    单层建筑给一盏主光 + 一盏角落/炉火侧光；通道型（gatehouse）压小半径。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    depth = L["depth"]
    top = pl + L["back_h"]
    if def_name in ("cathedral", "church", "chapel"):
        bright = 1100000.0 if def_name == "cathedral" else 900000.0
        return [dict(loc=(0.0, yb - 56.0, pl + L["back_h"] * 0.52), energy=bright,
                     color=(1.0, 0.68, 0.36), radius=120.0),
                dict(loc=(0.0, yf + 86.0, pl + L["back_h"] * 0.40),
                     energy=bright * 0.58, color=(1.0, 0.72, 0.44), radius=100.0)]
    if def_name in ("smithy1", "smithy2", "smithy3", "smithy4", "alchemy",
                    "bakery"):
        return [dict(loc=(-xh * 0.50, yf + 18.0, pl + 96.0), energy=270000.0,
                     color=(1.0, 0.50, 0.22), radius=66.0),
                dict(loc=(xh * 0.42, yb - 52.0, pl + L["back_h"] * 0.55),
                     energy=170000.0, color=(1.0, 0.70, 0.42), radius=76.0)]
    if def_name in ("townhouse", "tavern"):
        z2 = L["mid"]
        return [dict(loc=(-10.0, yf + 50.0, pl + L["back_h"] * 0.40),
                     energy=320000.0, color=(1.0, 0.64, 0.34), radius=90.0),
                dict(loc=(0.0, yf + 50.0, z2 + L["back_h"] * 0.38), energy=190000.0,
                     color=(1.0, 0.72, 0.44), radius=78.0)]
    if def_name == "gatehouse":                 # 通道型：半径压小，别把石壁打成白
        return [dict(loc=(0.0, yf + 58.0, pl + L["back_h"] * 0.58), energy=300000.0,
                     color=(1.0, 0.60, 0.30), radius=62.0),
                dict(loc=(0.0, yf + 20.0, pl + L["back_h"] * 0.92), energy=160000.0,
                     color=(1.0, 0.66, 0.36), radius=46.0)]
    if def_name == "shelter":                   # 三面开敞：檐下一盏 + 贴地一盏
        return [dict(loc=(xh * 0.26, yf + 14.0, top - 54.0), energy=260000.0,
                     color=(1.0, 0.64, 0.34), radius=70.0),
                dict(loc=(-xh * 0.44, yb - 40.0, pl + L["back_h"] * 0.34),
                     energy=150000.0, color=(1.0, 0.58, 0.28), radius=66.0)]
    mids = list(L.get("mids") or [pl])
    n = len(mids)
    # 圆塔是小房间（半径 ~70）：同样能量在更小空间里才够亮，补 1.6× 并收半径
    gain = 1.6 if L.get("round") else 1.0
    rad = 78.0 if L.get("round") else 104.0
    out = []
    for i, z in enumerate(mids):
        z_top = top if i == n - 1 else mids[i + 1]
        room = max(60.0, z_top - z)
        out.append(dict(loc=(-xh * 0.34, yf + min(64.0, depth * 0.40), z + room * 0.56),
                        energy=gain * 340000.0 / (1.0 + 0.30 * (n - 1)),
                        color=(1.0, 0.64, 0.34), radius=rad))
    if n == 1:                                  # 单层：第二盏补另一端/炉火侧
        out.append(dict(loc=(xh * 0.44, yb - 46.0, pl + L["back_h"] * 0.52),
                        energy=210000.0, color=(1.0, 0.58, 0.28), radius=92.0))
    return out


# ================================================================ §5 前层（前墙+屋顶）

def crop_back_half(ob, y_cut=0.0, z_cut=None, drop_shadow=True):
    """把建筑切成"只看正面"的前层：删掉**檐口以下、y>y_cut 的后半栋**。

    保留：前墙（含门窗真洞）、门/窗框与玻璃、屋顶整片、山墙、烟囱、老虎窗、悬挑。
    删除：后墙、后半侧墙与地板、室内器物、接地阴影踏板（`shadow_*` 材质）。
    前视 yaw=0 下侧墙/山墙端面本就投影成线，所以剩下的就是"正面可见的全部外皮"。
    """
    import bmesh
    me = ob.data
    bm = bmesh.new()
    bm.from_mesh(me)
    kill = []
    for f in bm.faces:
        mi = f.material_index
        nm = me.materials[mi].name if (mi < len(me.materials) and me.materials[mi]) else ""
        if drop_shadow and "shadow_" in nm:
            kill.append(f)
            continue
        c = f.calc_center_median()
        if c.y > y_cut and (z_cut is None or c.z < z_cut):
            kill.append(f)
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bm.to_mesh(me)
    bm.free()
    me.update()
    return ob


def swap_window_glass(ob, mat, slots=_CLEAR_GLASS_SLOTS):
    """把前层的清水窗玻璃换成真透明材质（彩窗 / 彩铅玻璃不动）。"""
    me = ob.data
    n = 0
    for i, m in enumerate(me.materials):
        if m is not None and m.name in slots:
            me.materials[i] = mat
            n += 1
    return n


def build_front(def_name, wc=None):
    """前层（Exterior + WallFront）：复用装配器成品 → 切后半天 → 换真透明窗玻璃。

    别名 def（plaster_house / church / chapel）没有自己的装配器，按 `_FRONT_ALIAS`
    （与 `probe_city_scene.DEF_MAP` 同源）解引用到实际装配器，**保证"前层 PNG =
    该 def 在城市里真正被渲成的装配器"**，后层内景才与它严格对齐。
    """
    wc = wc or _WIDTHS[def_name]
    asm, asm_wc = front_def(def_name, wc)
    ob, spec = B.ASSEMBLERS[asm](asm_wc)
    crop_back_half(ob, y_cut=0.0, z_cut=spec["eave_h"])
    if def_name not in ("cathedral", "church", "chapel"):
        swap_window_glass(ob, thin_glass())
    ob.name = "int_%s_front" % def_name
    return ob, spec
