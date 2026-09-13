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
_WIDTHS = {"house": 12, "townhouse": 12, "smithy1": 8, "tavern": 12,
           "bakery": 12, "shop": 12, "cathedral": 16}


def defs():
    return dict(_WIDTHS)


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


def _shell(b, L, storey_split=False, ceiling=False):
    """后墙（可上下分段）+ 地板 + 踢脚 + 可选二层楼板。

    **不做天花/顶梁**：屋顶在前层（前视里正好盖在檐口以上），后层再压一块天花只会
    在"只看后层"时糊成一片黑，且在最终合成里被屋顶完全遮住 —— 纯浪费。
    """
    W, D, wt, plinth = L["W"], L["D"], L["wt"], L["plinth"]
    h, yb, yf = L["back_h"], L["yb"], L["yf"]
    xh, depth, yc = L["xh"], L["depth"], L["yc"]
    if L.get("open_front"):
        B.wall_panel(b, W, h, wt, L["wall_low"], 0.0, D / 2.0 - wt / 2.0, plinth)
    elif storey_split and L["wall_up"] != L["wall_low"]:
        st = L["storey"]
        B.wall_panel(b, W, st, wt, L["wall_low"], 0.0, D / 2.0 - wt / 2.0, plinth)
        B.wall_panel(b, W, h - st, wt, L["wall_up"], 0.0, D / 2.0 - wt / 2.0,
                     plinth + st)
    else:
        B.wall_panel(b, W, h, wt, L["wall_low"], 0.0, D / 2.0 - wt / 2.0, plinth)
    # 地板 + 踢脚
    b.box_bottom((xh * 2.0, depth, 4.0), (0.0, yc), plinth - 4.0, L["floor"])
    b.box_bottom((xh * 2.0, 3.0, 10.0), (0.0, yb - 1.5), plinth, "wood_dark")
    for sx in (-1.0, 1.0):
        b.box_bottom((3.0, depth, 10.0), (sx * (xh - 1.5), yc), plinth, "wood_dark")
    # 二层楼板（上下真的分成两层，必须留）
    if L["storey"]:
        b.box_bottom((xh * 2.0, depth, 7.0), (0.0, yc), L["mid"] - 7.0, "timber")
        b.box_bottom((xh * 2.0, depth, 9.0), (0.0, yc), L["mid"], "wood_deck")
        b.box_bottom((xh * 2.0, 9.0, 12.0), (0.0, yc), L["mid"] - 19.0, "timber")


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
            b.box_bottom((5.0, 5.0, 8.0), (ax, y), z + 8.0 + h + 37.0, "fire")


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
    """大教堂：长椅列 / 祭坛 / 烛台 / 彩窗内透光（后殿三窗 + 玫瑰窗）。"""
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    # 后殿彩窗：后墙开真洞 + 嵌 stained_glass + 洞外发光板（"室外天光透进来"）。
    # 洞口必须**完整落在墙高以内**（越顶的洞会连墙一起切掉，发光板就从墙上方露出来）。
    apse = ((-132.0, 150.0, 74.0, 168.0), (0.0, 264.0, 140.0, 140.0),
            (132.0, 150.0, 74.0, 168.0))
    holes = [(ax, aw, az0, az0 + ah) for (ax, az0, aw, ah) in apse]
    B.wall_panel(b, L["W"], L["back_h"], L["wt"], L["wall_low"], 0.0,
                 L["D"] / 2.0 - L["wt"] / 2.0, pl, openings=holes)
    for (ax, az0, aw, ah) in apse:
        if ax == 0.0:
            B.rose_window(b, ax, yb - 1.0, az0 + ah / 2.0, min(aw, ah) / 2.0,
                          glass="stained_glass", tracery="white_stone", spokes=12)
            b.box_bottom((aw + 10.0, 6.0, ah + 28.0), (ax, L["D"] / 2.0 - 3.0),
                         az0 - 14.0, "lamp")
        else:
            B.lancet_window(b, ax, yb - 1.0, az0, aw, ah, head=46.0, profile="point",
                            glass="stained_glass", ring="white_stone", sill=True)
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
    for sx in (-1.0, 1.0):
        for i in range(4):
            cy = yf + 44.0 + i * 40.0
            b.box_bottom((34.0, 34.0, 16.0), (sx * 158.0, cy), pl, "stone_dark")
            b.cylinder((sx * 158.0, cy, pl + 16.0 + L["back_h"] * 0.46),
                       14.0, L["back_h"] * 0.92, "stone", 12)
            b.box_bottom((42.0, 42.0, 14.0), (sx * 158.0, cy),
                         pl + 16.0 + L["back_h"] * 0.92, "white_stone")
    # 中央通道红毯 + 长椅列（面向后殿）
    _rug(b, 0.0, yc + 8.0, pl + 0.6, 96.0, depth - 36.0, "cloth_red")
    for row in range(6):
        ry = yf + 62.0 + row * 56.0
        for sx in (-1.0, 1.0):
            _pew(b, x=sx * 88.0, y=ry, z=pl, w=116.0)
    # 祭坛（后殿台阶 + 圣坛 + 器物）
    b.box_bottom((214.0, 64.0, 14.0), (0.0, yb - 44.0), pl, "white_stone")
    b.box_bottom((180.0, 52.0, 14.0), (0.0, yb - 40.0), pl + 14.0, "white_stone")
    b.box_bottom((144.0, 38.0, 62.0), (0.0, yb - 36.0), pl + 28.0, "white_stone")
    b.box_bottom((152.0, 12.0, 10.0), (0.0, yb - 36.0), pl + 90.0, "stone_dark")
    _prop(P.book_stack, b, x=-28.0, y=yb - 36.0, z=pl + 90.0, w=34.0, h=28.0, n=4)
    _prop(P.censer, b, x=32.0, y=yb - 32.0, z=pl + 90.0, h=32.0, r=12.0, lit=True)
    for sx in (-1.0, 1.0):
        _candelabra(b, sx * 90.0, yb - 32.0, pl + 28.0, h=86.0, candles=5)
    # 圣水盆 + 讲道坛（近入口）
    b.cylinder((xh - 62.0, yf + 40.0, pl + 26.0), 26.0, 52.0, "white_stone", 16,
               taper=0.72)
    b.cylinder((xh - 62.0, yf + 40.0, pl + 55.0), 24.0, 8.0, "stone_dark", 16)
    b.box_bottom((62.0, 44.0, 86.0), (-xh + 58.0, yf + 44.0), pl, "wood")
    # 垂幡
    for sx in (-1.0, 1.0):
        for i in range(2):
            bx = sx * 158.0
            by = yf + 64.0 + i * 82.0
            _hang_cloth(b, bx, by, L["ceil"] - 60.0, 34.0, 96.0,
                        "cloth_red" if i == 0 else "cloth_blue", rope=60.0)


_INTERIORS = {
    "house": _house, "townhouse": _townhouse, "smithy1": _smithy,
    "tavern": _tavern, "bakery": _bakery, "shop": _shop, "cathedral": _cathedral,
}


def build_back(def_name, wc=None):
    """后层（Interior 层）：后墙 + 地板 + 天花 + 家具。返回 (obj, L)。"""
    wc = wc or _WIDTHS[def_name]
    L = layout(def_name, wc)
    b = B.Builder("int_%s_back_w%d" % (def_name, wc))
    _INTERIORS[def_name](b, L)
    ob = b.to_object()
    ob.name = "int_%s_back" % def_name
    return ob, L


def lights(def_name, L):
    """暖色室内光（1~2 个点光）：[{loc, energy, color, radius}, ...]。

    双层建筑两层各一盏（合计 2 盏）；单层 2 盏（一盏主光 + 一盏炉火侧光）；
    教堂给祭坛与中殿各一盏。刻意压低能量 —— 室内是壁炉/烛火照亮的暖暗，
    不是室外日光的亮度（硬约束：别把室内打亮到像室外）。
    """
    pl, yb, yf, xh = L["plinth"], L["yb"], L["yf"], L["xh"]
    if def_name == "cathedral":
        return [dict(loc=(0.0, yb - 56.0, pl + 200.0), energy=900000.0,
                     color=(1.0, 0.68, 0.36), radius=120.0),
                dict(loc=(0.0, yf + 86.0, pl + 156.0), energy=520000.0,
                     color=(1.0, 0.72, 0.44), radius=100.0)]
    if def_name == "smithy1":
        return [dict(loc=(-xh + 70.0, yf + 18.0, pl + 96.0), energy=260000.0,
                     color=(1.0, 0.50, 0.22), radius=64.0),
                dict(loc=(xh - 70.0, yf + 60.0, pl + L["back_h"] * 0.56),
                     energy=170000.0, color=(1.0, 0.70, 0.42), radius=74.0)]
    if L["storey"]:
        z2 = L["mid"]
        return [dict(loc=(-10.0, yf + 50.0, pl + L["back_h"] * 0.40), energy=320000.0,
                     color=(1.0, 0.64, 0.34), radius=90.0),
                dict(loc=(0.0, yf + 50.0, z2 + L["back_h"] * 0.38), energy=190000.0,
                     color=(1.0, 0.72, 0.44), radius=78.0)]
    return [dict(loc=(-xh * 0.20, yf + min(58.0, L["depth"] * 0.44),
                      pl + L["back_h"] * 0.56), energy=270000.0,
                 color=(1.0, 0.66, 0.36), radius=80.0),
            dict(loc=(xh * 0.52, yb - 52.0, pl + L["back_h"] * 0.55), energy=120000.0,
                 color=(1.0, 0.56, 0.26), radius=60.0)]


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
    """前层（Exterior + WallFront）：复用装配器成品 → 切后半天 → 换真透明窗玻璃。"""
    wc = wc or _WIDTHS[def_name]
    ob, spec = B.ASSEMBLERS[def_name](wc)
    crop_back_half(ob, y_cut=0.0, z_cut=spec["eave_h"])
    if def_name != "cathedral":
        swap_window_glass(ob, thin_glass())
    ob.name = "int_%s_front" % def_name
    return ob, spec
