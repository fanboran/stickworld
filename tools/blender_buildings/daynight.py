# -*- coding: utf-8 -*-
"""daynight.py —— 昼夜分层光照 / 发光层分离（管线 v3 · 写实 PBR）

定位
====
本文件是**光照与交付分层的实现层**（不是探针）：`probe_daynight.py` 把街景搭好之后
调用它出「白天 / 夜晚 / 纯发光层 / 分层说明图」。装配器（buildings.py）、材质库
（materials.py）、道具层（props.py）都由别人维护，本文件**只读调用**，不修改。

创始人问题的答案：两层 + 一次调色
=================================
问："游戏昼夜光效怎么处理？夜晚建筑和场景发光？" 答：

    夜  =  albedo × tint_night  +  glow × strength

- **albedo**：白天光照下的建筑（一次烘焙，交付基线；引擎不参与）
- **tint_night**：冷蓝调 + 压暗（引擎一行 multiply，随黄昏插值）
- **glow**：**只含自发光物**的加法层（灯笼 / 炉火 / 彩窗 / 符文 / 水晶 + 光晕）
  引擎 additive 叠上去、再挂 bloom，就是"灯真的亮着"的夜景

设计要点（三条，都是踩坑换来的）
================================
1. **发光件从网格里"找"，不硬编码坐标**：扫描网格多边形，把材质在节点树里
   `Emission Strength > 阈值` 的面按**连通性分簇** —— 一簇 = 一盏灯笼 / 一处炉火 /
   一扇彩窗。装配器以后挪了灯的坐标，本模块不用改一行。簇的质心 + 尺寸就是
   点光源与光晕贴片的锚点。
   ⇒ 判定**不靠材质名**（`fire`/`ember` 走 buildings 的纯色回退，材质名是
   `flat_fire`；`glass` 经 alias 落到 `glass_win` 却仍叫 `glass`）——靠节点真值。
2. **点光源放在簇的"前方"(-Y)，不是质心**：灯 / 炉火 / 水晶都嵌在灯具或墙体内，
   光源放质心会被灯具自身几何挡住（光洒不出来，夜里只有灯"亮"、墙面"黑"）。
   沿 -Y 外推到灯具前脸之外，光才真的落在墙面与地面上。阴影保持开启
   （关阴影会穿墙漏光到邻栋，读作"整条街一起发光"）。
3. **纯发光层 = 对象级材质替换 + 黑世界 + 灭灯**：非发光材质槽在 **OBJECT 级**
   换成纯黑无光材质（不动 mesh 数据，可无损还原）；世界背景压到全黑、方向光与
   点光源全关。于是整张图只剩自发光 + 光晕贴片 —— 正是引擎 additive 要的那层。
   材质按"节点是否发光"分流，所以分离是**干净**的（`_dn_glow_nohalo.png` 是不带
   光晕的控制图，用来实测"非发光物有没有漏进来"）。

引擎侧合成建议（本文件实测出来的数值）
======================================
- `tint_night = (0.11, 0.14, 0.26)`：≈ 环境光压到白天的 10~12% 且偏冷蓝
  （与本题夜晚渲染的环境档同源；想更黑把三通道同时乘 0.8，别只压 G）
- `glow_strength = 1.0`：发光层本来就是按 1:1 加法设计的；再叠 bloom
  （建议阈值 0.75 起、半径屏幕 2~4%）——阈值低于 0.5 会把夜空整片糊成灰雾
- 昼夜切换：albedo 只烘焙一次；`tint_night` 随昼夜插值（黎明/黄昏走中性暖灰，
  别直接冷蓝↔白，会有一秒"蓝闪"）；glow 只在夜间淡入（白天必须淡到 0，
  否则白天灯笼也在发光 —— 见 §"白天基线"注意事项）
"""

import math

import bpy
import numpy as np
from mathutils import Vector

#: 判"发光"的 Emission Strength 下限。低于此只当普通材质（避免把 Emission Strength
#: 被节点连线、常数默认 0 的材质误判成发光）。
EMIT_MIN = 0.05

#: 发光「族」参数表：发射点光源的瓦数（0 = 不投点光，只进 glow 层）、光晕缩放。
#: 瓦数按"1 格 = 32 单位 = 0.42 m、单层檐高 ≈ 205 单位"的场景尺度标定：
#: 一盏 20 W 的点光放在墙前 40 单位（0.52 m）处，墙面（抹灰 albedo ≈0.7）能读到
#: 约 0.5 的辐亮度 —— 白天 key 3.5 下抹灰约 0.78，所以夜里能"看得出被灯照到"
#: 但远不到过曝。**改这几个数是调夜景观感的第一旋钮。**
#: 判定族的规则见 `_family()`；不在表里的新发光材质走 `_FAMILY_DEFAULT`（有一盏
#: 小灯，避免"新加的自发光夜里不照亮"）。
FAMILY = {
    # 族         点光瓦数  光晕系数  备注
    "lamp":         (20.0, 0.95),   # 灯笼/灯室玻璃（materials._b_lamp，暖橙 emit 2.5）
    "fire":         (46.0, 1.15),   # 炉膛火（buildings 纯色回退 + EMISSIVE 4.0）
    "ember":        (12.0, 0.50),   # 炉口炭层（EMISSIVE 1.4，和 forge 的火合并成一盏）
    "crystal":      (24.0, 0.75),   # 魔法水晶（冷蓝白 emit 0.95）
    "rune_glow":    (10.0, 0.30),   # 符文刻痕（青/琥珀 emit 0.90；刻带细长，光晕给弱）
    # 彩窗/铅条窗/药瓶：emit 0.42~0.75，是"透光/微光"，**不投点光源** ——
    # 一扇窗在物理上不向街面投光斑；且教堂窗数量大，逐扇挂灯会瞬间打爆灯数上限。
    "stained_glass": (0.0, 0.55),
    "glass_lead":    (0.0, 0.35),
    "glass_bottle":  (0.0, 0.30),
    # 「点亮的窗」（light_some_windows 造的 lamp 实例，名字见 _FAMILY_ALIAS）：
    # 瓦数远小于灯笼 —— 窗后是一支蜡烛，不是一盏街灯；但它亮了就该在墙上留一层暖光。
    "window_lit":   (8.0, 0.70),
}
_FAMILY_DEFAULT = (9.0, 0.55)

#: 材质名 → 族名的手工改名（只用于本模块造出来的材质；装配层材质名直通）。
_FAMILY_ALIAS = {"dn_window_lit": "window_lit"}

#: 点光源瓦数换算 **1 场景单位 = 1 m** 的大坑（必须懂，否则灯全废）：
#: Blender 的物理单位里 1 场景单位 = 1 米，而本管线 1 格 = 32 单位 = 0.42 m
#: ⇒ 整条街在 Blender 眼里是**几十米到上百米宽**。点光的辐照度 = P/(4πd²)，
#: 距离按"米"计，所以 100 单位 = 100 m：一盏物理上合理的 20 W 灯泡放到 100 m 外
#: 只剩 1.2e-4 W/m²，比月光（0.16）弱三个数量级 —— 出图就是"灯亮着但墙是黑的"。
#: 下面的表按"摄影棚瓦数"给（20~46），再乘本系数换算到场景尺度：
#: 8e3 ⇒ 一盏 lamp 在 115 单位（1.5 m）处给 ≈1.0 W/m² 的辐照度，约为主光 3.5 的
#: 1/4、夜晚环境（≈0.2）的 5 倍 —— 墙上/地面能读出一圈明确的暖光，但不过曝。
#: **这是调夜景观感的第一旋钮**（环境变量 DN_LIGHT_GAIN 再乘一层）。
WATT_SCALE = 8.0e3

#: 点光源的灯色（线性 RGB，Blender 用法同引擎）。暖橙 ≈ 2400K，冷蓝 ≈ 月色补光。
WARM = (1.00, 0.46, 0.16)
COOL = (0.42, 0.64, 1.00)

#: 夜晚环境：天空渐变 + 强度。与白天同口径（0.55 × 平均色 ≈ 0.37 辐亮度），
#: 这里 0.13 × 平均色 ≈ 0.036 → **≈ 白天的 10%**（落在"8~12%"要求内），
#: 且 B/R ≈ 2.7（冷蓝月光感）。注意：像素口径的夜/昼比会明显高于 9%
#: （白天基线大片过曝、像素被截到 1.0），汇报里两个口径都给。
NIGHT_SKY_TOP = (0.07, 0.11, 0.32, 1.0)
NIGHT_SKY_BOTTOM = (0.24, 0.27, 0.40, 1.0)
NIGHT_SKY_STRENGTH = 0.13

#: 夜晚方向光：主光（月光）压到 0.14 并改冷白；补光 0.04 / 0.03 全冷。
#: 白天是 key 3.5 暖 + fill 0.22 + bounce 0.30（见 probe_daynight 的 day 档）。
NIGHT_SUNS = (
    # name    energy  rot(deg)        soft(deg) color
    ("key",    0.14, (42.0, 0.0, -34.0), 6.0, (0.55, 0.68, 1.00)),
    ("fill",   0.04, (58.0, 0.0, 126.0), 22.0, (0.50, 0.62, 1.00)),
    ("bounce", 0.03, (-28.0, 0.0, 6.0), 45.0, (0.46, 0.56, 1.00)),
)

#: 引擎侧合成建议值（本文件里的分层图就用这两条算，见 montage()）。
NIGHT_TINT = (0.11, 0.14, 0.26)
GLOW_STRENGTH = 1.0

#: 灯光/光晕的二次调参（探针可用环境变量覆盖，方便出图对比）
LIGHT_GAIN = 1.5
HALO_NIGHT = 0.55     # 夜图上光晕调弱：真实渲染里靠引擎 bloom 补，贴片只给"起辉"
HALO_GLOW = 1.00      # glow 层是给引擎加法用的，光晕按设计值足额给


def reset():
    """清本模块的缓存。探针在 `read_factory_settings` 之后必须调一次（与
    buildings._CACHE / materials.reset_cache 同规）——否则拿到的是已删除的
    Material 引用。"""
    _HALO_NODES.clear()
    _HALO_MUL.clear()


# ============================================================ 发光件识别

def _bsdf_of(mat):
    """取材质的 Principled BSDF。materials.py 的材质是 Group→Output 的壳，
    真正的 BSDF **在 node group 内部**（Emission Strength 是 group 里的常数）。"""
    if mat is None or not getattr(mat, "use_nodes", False):
        return None
    nt = mat.node_tree
    b = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if b is not None:
        return b
    g = next((n for n in nt.nodes if n.type == "GROUP" and n.node_tree), None)
    if g is not None:
        return next((n for n in g.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    return None


def material_emission(mat):
    """材质的自发光 (strength, color|None)。

    **按节点真值判定，不按材质名**：`fire`/`ember` 走 buildings 的纯色回退，
    材质名其实是 `flat_fire`；`glass` 经 alias 落到 glass_win 却仍叫 `glass`。
    只看名字会漏判或误判，所以这里读 Emission Strength；颜色被节点连线（materials.py
    的灯色是算出来的）时返回 None，由调用方按族给代表色。
    """
    b = _bsdf_of(mat)
    if b is None:
        return 0.0, None
    try:
        strength = float(b.inputs["Emission Strength"].default_value)
    except Exception:
        return 0.0, None
    col = None
    sock = b.inputs.get("Emission Color")
    if sock is not None and not sock.is_linked:
        try:
            v = sock.default_value
            col = (float(v[0]), float(v[1]), float(v[2]))
        except Exception:
            col = None
    return strength, col


def is_emissive(mat):
    return material_emission(mat)[0] > EMIT_MIN


def emissive_names(objs):
    """本次场景里实际出现的发光材质名集合（白名单，供汇报与实际分流用）。"""
    out = set()
    for ob in objs:
        if ob.type != "MESH":
            continue
        for m in ob.data.materials:
            if is_emissive(m):
                out.add(m.name)
    return out


def _family(name):
    """材质名 → 族名（去掉 buildings 纯色回退的 `flat_` 前缀）。

    `flat_fire` → `fire`；其余同名直通；未知名返回原名（拿不到表就落默认参数）。
    """
    n = name[5:] if name.startswith("flat_") else name
    return _FAMILY_ALIAS.get(n, n)


def _face_components(me, faces):
    """同一材质的面的**连通分量**（按共享顶点做洪水填充）。

    注意：本管线的 Builder 逐面建 mesh、**相邻面之间不共享顶点**（实测：一个铁匠
    炉的 6 个面是 6 个独立分量），所以这个函数只对"顶点确实共享"的构件有效。
    真正的分簇走 `_spatial_groups()`（按空间单链），本函数保留给需要真邻接的场合。
    """
    v2f = {}
    for pi in faces:
        for v in me.polygons[pi].vertices:
            v2f.setdefault(v, []).append(pi)
    seen = set()
    comps = []
    for start in faces:
        if start in seen:
            continue
        stack, comp, seen = [start], [], seen | {start}
        while stack:
            f = stack.pop()
            comp.append(f)
            for v in me.polygons[f].vertices:
                for g in v2f[v]:
                    if g not in seen:
                        seen.add(g)
                        stack.append(g)
        comps.append(comp)
    return comps


def _spatial_groups(items, link):
    """按距离 < link 的**单链（single-linkage）连通分量**分簇；网格加速。

    items = [(pos(Vector), payload), ...] → 返回 [[item_index, ...], ...]。

    为什么用单链而不是"到质心距离"：符文环、一圈悬浮水晶这类构件沿周长是**链状**
    的，到质心距离会把一个环拆成一堆碎簇（碎簇 = 一堆强弱不一的小点光，把塔身
    打成一团斑）。单链沿几何连成整体，才读得出"这是环带在发光"。
    """
    if not items:
        return []
    cell = float(link)
    grid = {}
    for i, (p, _pl) in enumerate(items):
        key = (int(math.floor(p.x / cell)), int(math.floor(p.y / cell)),
               int(math.floor(p.z / cell)))
        grid.setdefault(key, []).append(i)
    parent = list(range(len(items)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for key, ids in grid.items():
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    nb = grid.get((key[0] + dx, key[1] + dy, key[2] + dz))
                    if not nb:
                        continue
                    for i in ids:
                        for j in nb:
                            if j <= i:
                                continue
                            if (items[i][0] - items[j][0]).length < link:
                                ra, rb = find(i), find(j)
                                if ra != rb:
                                    parent[max(ra, rb)] = min(ra, rb)
    groups = {}
    for i in range(len(items)):
        groups.setdefault(find(i), []).append(i)
    return [groups[k] for k in sorted(groups)]


def _world_face(me, mw, pi):
    """面的世界空间顶点、面积、法线（**面积/尺寸一律用世界坐标算**：用
    `polygon.area` 是局部量，遇到带缩放/旋转的对象会与视觉尺寸对不上）。"""
    p = me.polygons[pi]
    vs = [mw @ me.vertices[v].co for v in p.vertices]
    area = 0.0
    for k in range(1, len(vs) - 1):
        area += (vs[k] - vs[0]).cross(vs[k + 1] - vs[0]).length * 0.5
    n = (mw.to_3x3() @ p.normal)
    if n.length > 1e-9:
        n.normalize()
    c = sum(vs, Vector((0.0, 0.0, 0.0))) / len(vs)
    return vs, area, n, c


def _cluster_from_faces(me, mw, face_ids, mat, strength, color):
    pts, area, front_n, front_y = [], 0.0, Vector((0.0, -1.0, 0.0)), None
    faces = []            # 每面 (中心, 三向尺寸)：光晕要按"面"再分簇，见 add_halos
    for pi in face_ids:
        vs, a, n, c = _world_face(me, mw, pi)
        pts += vs
        area += a
        ex = (max(v.x for v in vs) - min(v.x for v in vs),
              max(v.y for v in vs) - min(v.y for v in vs),
              max(v.z for v in vs) - min(v.z for v in vs))
        faces.append((c, ex))
        if front_y is None or c.y < front_y:
            front_y, front_n = c.y, n
    xs = [p.x for p in pts]
    ys = [p.y for p in pts]
    zs = [p.z for p in pts]
    size = (max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs))
    pos = Vector((sum(xs) / len(xs), sum(ys) / len(ys), sum(zs) / len(zs)))
    return dict(mat=mat, family=_family(mat.name), strength=strength, color=color,
                pos=pos, size=size, area=area, normal=front_n, n_faces=len(face_ids),
                faces=faces)


def collect_emissive(objs, link=95.0):
    """扫描场景 → 自发光簇列表（同一材质按空间单链分簇）。

    距离阈值 95 单位（≈1.25 m）：足够让"炉膛火 + 炉口炭层""环带被拆成 20 个面"
    这类构件连成一体，又不会把相邻两盏灯笼（间距 160+ 单位）粘成一盏。
    """
    out = []
    for ob in objs:
        if ob.type != "MESH":
            continue
        me = ob.data
        mw = ob.matrix_world
        by_mat = {}
        for p in me.polygons:
            if p.material_index >= len(me.materials):
                continue
            m = me.materials[p.material_index]
            st, col = material_emission(m)
            if m is None or st <= EMIT_MIN:
                continue
            by_mat.setdefault(p.material_index, (m, st, col, []))[3].append(p.index)
        for (m, st, col, faces) in by_mat.values():
            items = []
            for pi in faces:
                _vs, _a, _n, c = _world_face(me, mw, pi)
                items.append((c, pi))
            for group in _spatial_groups(items, link):
                out.append(_cluster_from_faces(
                    me, mw, [items[i][1] for i in group], m, st, col))
    out.sort(key=lambda c: -c["strength"] * c["area"])
    return out


# ============================================================ 灯光

def _sun(sc, name, energy, rot, soft=3.0, color=(1.0, 0.95, 0.85)):
    d = bpy.data.lights.new(name, "SUN")
    d.energy = energy
    d.angle = math.radians(soft)
    d.color = color
    ob = bpy.data.objects.new(name, d)
    ob.rotation_euler = tuple(math.radians(a) for a in rot)
    sc.collection.objects.link(ob)
    return ob


def set_suns(sc, spec):
    """重建方向光组：先删掉已有的 SUN（光照切换必须整组换，别只改强度 —— 漏一盏
    白天的主光就会让"夜晚"还是亮的）。spec = [(name, energy, rot, soft, color)]。"""
    for ob in [o for o in bpy.data.objects if o.type == "LIGHT"
               and o.data.type == "SUN"]:
        bpy.data.objects.remove(ob, do_unlink=True)
    out = [_sun(sc, *s) for s in spec]
    bpy.context.view_layer.update()
    return out


def _lights_off():
    """记录并关闭所有 LIGHT 对象（glow 层用：只留自发光，不许场景灯参与）。"""
    saved = []
    for ob in [o for o in bpy.data.objects if o.type == "LIGHT"]:
        saved.append((ob, ob.hide_render))
        ob.hide_render = True
    return saved


def restore_lights(saved):
    for ob, hr in saved:
        ob.hide_render = hr


def set_sky(sc, name, top, bottom, strength):
    """天空渐变世界（白天/夜晚各一份；**一次场景只 read_factory_settings 一次**，
    世界对象留着复用，别来回重建 —— 踩坑记录 §六）。

    渐变用 Map Range 把"视向 Z"重映射到 0~1 **再**进 ColorRamp：ColorRamp 对
    Fac < 0 会钳到第 0 档，直接拿 Z 当 Fac 的话地平线以下全是一个死色，
    天空会渲成一块平的灰板（第一版就是这样）。(-0.3, 0.5) 覆盖 20° 俯角下
    整幅画面的视向范围，天顶/地平线才拉得开。
    """
    w = bpy.data.worlds.get(name)
    if w is None:
        w = bpy.data.worlds.new(name)
    sc.world = w
    w.use_nodes = True
    nt = w.node_tree
    if not w.get("dn_built"):
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputWorld")
        bg = nt.nodes.new("ShaderNodeBackground")
        bg.name = "dn_bg"
        tc = nt.nodes.new("ShaderNodeTexCoord")
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        mr = nt.nodes.new("ShaderNodeMapRange")
        mr.inputs["From Min"].default_value = -0.30
        mr.inputs["From Max"].default_value = 0.50
        ramp = nt.nodes.new("ShaderNodeValToRGB")
        ramp.name = "dn_ramp"
        nt.links.new(tc.outputs["Generated"], sep.inputs["Vector"])
        nt.links.new(sep.outputs["Z"], mr.inputs["Value"])
        nt.links.new(mr.outputs["Result"], ramp.inputs["Fac"])
        nt.links.new(ramp.outputs["Color"], bg.inputs[0])
        nt.links.new(bg.outputs["Background"], out.inputs["Surface"])
        w["dn_built"] = True
    bg = nt.nodes["dn_bg"]
    ramp = nt.nodes["dn_ramp"]
    bg.inputs[1].default_value = strength
    ramp.color_ramp.elements[0].color = bottom
    ramp.color_ramp.elements[1].color = top
    return w


def add_point_lights(clusters, cam, gain=1.0, max_lights=22, push_scale=0.5):
    """给"会投射真实光照"的发光簇挂点光源。

    位置 = 簇质心 + 前方偏移（见模块头 §2）；瓦数 = 族表 × 尺寸系数 × gain × WATT_SCALE
    （WATT_SCALE 的理由见其定义处 —— 不乘它灯就是"亮着但照不亮"）。
    尺寸系数按簇的最大边长相对 60 单位（≈0.8 m）开方缩放并夹到 0.6~2.4 ——
    炉膛火比灯笼大得多，不缩放的话同一张图里炉火会把墙打过曝。
    返回 (灯对象列表, 明细列表)。
    """
    made, rows = [], []
    cand = []
    for c in clusters:
        light_w, halo = FAMILY.get(c["family"], _FAMILY_DEFAULT)
        if light_w <= 0.0:
            continue
        d = max(c["size"]) if any(c["size"]) else 0.0
        scale = max(0.6, min(2.4, math.sqrt(max(d, 1.0) / 60.0)))
        cand.append((light_w * scale * gain * WATT_SCALE, c, halo))
    cand.sort(key=lambda t: -t[0])
    cam_fwd = cam.matrix_world.to_quaternion() @ Vector((0.0, 0.0, -1.0))
    for energy, c, _halo in cand[:max_lights]:
        # 前方外推量按簇的**进深**（Y 向尺寸）给，夹到 60 单位：环带/整排玻璃的 Y 尺寸
        # 可能很大，不夹会把光源推到街上、变成"半空一盏灯"。
        push = min(c["size"][1], 60.0) * push_scale + 12.0
        pos = c["pos"] + Vector((0.0, -max(14.0, push), 0.0))
        # 朝相机再挪一点：灯具的框（铁框/玻璃）在正交视角下会挡住灯前脸，
        # 前推一个灯具厚度让光"从灯里出来"。
        pos = pos - cam_fwd * 10.0
        lw, halo = FAMILY.get(c["family"], _FAMILY_DEFAULT)
        color = c["color"] or (WARM if c["family"] in ("lamp", "fire", "ember")
                               else COOL)
        d = bpy.data.lights.new("dn_" + c["family"], "POINT")
        d.energy = energy
        d.color = color
        d.use_shadow = True
        try:
            d.shadow_soft_size = max(3.0, min(14.0, c["size"][2] * 0.5))
        except Exception:
            pass
        for attr in ("shadow_buffer_bias", "specular_factor"):
            if hasattr(d, attr):
                try:
                    setattr(d, attr, 0.02 if attr == "shadow_buffer_bias" else 1.0)
                except Exception:
                    pass
        ob = bpy.data.objects.new("dn_" + c["family"], d)
        ob.location = tuple(pos)
        bpy.context.scene.collection.objects.link(ob)
        made.append(ob)
        rows.append(dict(family=c["family"], mat=c["mat"].name,
                         energy=round(energy, 1),
                         pos=tuple(round(v, 1) for v in pos),
                         size=tuple(round(v, 1) for v in c["size"]),
                         faces=c["n_faces"]))
    bpy.context.view_layer.update()
    return made, rows


# ============================================================ 光晕贴片

def _halo_material(color, strength, name="dn_halo"):
    """径向衰减的加法光晕材质（Principled：Emission 给核心、Alpha 给衰减）。

    为什么不用 Emission + MixShader：Principled 一个节点就能同时给
    Emission Color/Strength 和 Alpha，少一层链路、少一类坑。
    Generated 坐标 0..1 → 距中心 0.5 的距离 → pow 衰减 → 核心亮、边缘透明。
    """
    m = bpy.data.materials.get(name)
    if m is None:
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
        nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
        tc = nt.nodes.new("ShaderNodeTexCoord")
        vm = nt.nodes.new("ShaderNodeVectorMath")
        vm.operation = "DISTANCE"
        vm.inputs[1].default_value = (0.5, 0.5, 0.5)
        nt.links.new(tc.outputs["Generated"], vm.inputs[0])
        mul = nt.nodes.new("ShaderNodeMath")
        mul.operation = "MULTIPLY"
        mul.inputs[1].default_value = 2.0                    # 0..0.707 → 0..1.41
        nt.links.new(vm.outputs["Value"], mul.inputs[0])
        cl = nt.nodes.new("ShaderNodeClamp")
        nt.links.new(mul.outputs[0], cl.inputs[0])
        inv = nt.nodes.new("ShaderNodeMath")
        inv.operation = "SUBTRACT"
        inv.inputs[0].default_value = 1.0
        nt.links.new(cl.outputs[0], inv.inputs[1])            # 1 - d
        pw = nt.nodes.new("ShaderNodeMath")
        pw.operation = "POWER"
        pw.inputs[1].default_value = 2.4                     # 柔和衰减（越小越"糊"）
        nt.links.new(inv.outputs[0], pw.inputs[0])
        bsdf.inputs["Base Color"].default_value = (0.0, 0.0, 0.0, 1.0)
        bsdf.inputs["Roughness"].default_value = 1.0
        try:
            bsdf.inputs["Specular IOR Level"].default_value = 0.0
        except Exception:
            pass
        nt.links.new(pw.outputs[0], bsdf.inputs["Alpha"])
        _HALO_NODES[name] = (bsdf, pw.outputs[0])
    bsdf, fac = _HALO_NODES[name]
    bsdf.inputs["Emission Color"].default_value = (color[0], color[1], color[2], 1.0)
    m["dn_halo_base"] = float(strength)          # 存基准强度，供 set_halo_mult 缩放
    smul = _halo_strength_node(name)
    smul.inputs[1].default_value = float(strength)
    if not smul.outputs[0].is_linked:
        m.node_tree.links.new(smul.outputs[0], bsdf.inputs["Emission Strength"])
    _set_alpha_blend(m)
    return m


_HALO_NODES = {}
_HALO_MUL = {}


def _halo_strength_node(name):
    """在 halo 材质里挂一个 "衰减 × 强度" 的乘法节点（复用，不重复建）。"""
    if name in _HALO_MUL:
        return _HALO_MUL[name]
    m = bpy.data.materials[name]
    nt = m.node_tree
    _bsdf, fac = _HALO_NODES[name]
    mul = nt.nodes.new("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    nt.links.new(fac, mul.inputs[0])
    _HALO_MUL[name] = mul
    return mul


def set_halo_mult(mult):
    """把所有光晕材质的强度重设为 基准 × mult。

    夜图上光晕调弱（真实渲染的辉光应由引擎 bloom 出，贴片只给"起辉"，否则会糊）；
    glow 层里光晕足额给（它就是给引擎加法用的那一层）。"""
    for m in list(bpy.data.materials):
        if not m.name.startswith("dn_halo_"):
            continue
        mul = _HALO_MUL.get(m.name)
        if mul is None:
            continue
        try:
            mul.inputs[1].default_value = float(m["dn_halo_base"]) * mult
        except Exception:
            pass


def _set_alpha_blend(m):
    for attr, val in (("blend_method", "BLEND"),
                      ("surface_render_method", "BLENDED"),
                      ("show_transparent_back", False),
                      ("use_backface_culling", False),
                      ("use_transparent_shadow", False)):
        try:
            setattr(m, attr, val)
        except Exception:
            pass


def add_halos(clusters, cam, mult=1.0, sub_link=62.0, max_per_cluster=6,
              min_size=30.0, max_size=280.0):
    """给每个发光簇加**朝向相机**的光晕贴片（billboard），簇内再按面分簇。

    为什么要"簇内再分簇"：点光源用 95 单位的单链，会把一整面立面的所有彩窗并成
    一个簇（对点光没问题，一盏代表即可）；但光晕只有一片、又落在立面正中，就会
    糊在**中间的石头墙**上，窗子自己反而没有光晕。这里按 62 单位把簇内的面再分一次，
    **每片窗/每颗水晶/每段刻带各得一片光晕**，位置才落在发光物自己身上。

    尺寸 = 2.6 × max(次大边长, 22 单位) × 族系数，夹到 30~280：次大边代表"这个
    发光物有多宽"，下限 22 保证小灯笼（12 单位）也有足够溢出的光晕（不然只有一点
    几何轮廓，没有"起辉"）。上限 280 防大彩窗糊成一片。
    朝向 = 直接套相机欧拉角（平面法线 +Z 经该旋转后正对相机；正交视角下永远正对）。
    """
    made = []
    for i, c in enumerate(clusters):
        _light_w, halo = FAMILY.get(c["family"], _FAMILY_DEFAULT)
        color = c["color"] or (WARM if c["family"] in ("lamp", "fire", "ember",
                                                       "window_lit") else COOL)
        strength = min(2.6, 0.30 + 0.85 * c["strength"])
        m = _halo_material(color, strength, name="dn_halo_" + c["family"])
        fas = c.get("faces") or []
        if fas:
            groups = _spatial_groups([(f[0], k) for k, f in enumerate(fas)], sub_link)
        else:
            groups = [[0]]
        if len(groups) > max_per_cluster:                 # 细长构件别铺满一屏
            groups = groups[:max_per_cluster]
        cam_fwd = cam.matrix_world.to_quaternion() @ Vector((0.0, 0.0, -1.0))
        for gi, group in enumerate(groups):
            cs, exs = [], []
            for k in group:
                f = fas[k] if fas else (c["pos"], (0.0, 0.0, 0.0))
                cs.append(f[0])
                exs.append(f[1])
            lo = [min(cs[j][a] - exs[j][a] * 0.5 for j in range(len(cs)))
                  for a in range(3)]
            hi = [max(cs[j][a] + exs[j][a] * 0.5 for j in range(len(cs)))
                  for a in range(3)]
            dims = sorted(hi[a] - lo[a] for a in range(3))
            size = 2.6 * max(dims[1], 22.0) * halo
            size = max(min_size, min(max_size, size))
            ctr = Vector([(lo[a] + hi[a]) * 0.5 for a in range(3)])
            me = bpy.data.meshes.new("dn_halo_%d_%d" % (i, gi))
            s = size * 0.5
            me.from_pydata([(-s, -s, 0.0), (s, -s, 0.0), (s, s, 0.0), (-s, s, 0.0)],
                           [], [(0, 1, 2, 3)])
            me.materials.append(m)
            ob = bpy.data.objects.new("dn_halo_%d_%d" % (i, gi), me)
            ob.location = tuple(ctr - cam_fwd * 26.0)
            ob.rotation_euler = cam.rotation_euler
            bpy.context.scene.collection.objects.link(ob)
            made.append(ob)
    set_halo_mult(mult)
    bpy.context.view_layer.update()
    return made


# ============================================================ 窗户点灯

def light_some_windows(objs, mat_lamp, prob=0.45, seed=7, kind="glass",
                       min_z=115.0, link=70.0):
    """把一部分**普通窗玻璃**改成自发光（房间亮着灯）。

    这就是"引擎里怎么只让部分窗户亮"在管线侧的对应物：普通窗玻璃用 `glass`
    （= materials 的 glass_win，**不发光**），要亮的窗换成一个 `lamp` 的实例
    （暖橙自发光）。这里按空间单链把玻璃面分成"一扇窗"，再用确定性 RNG 抽
    prob 比例，把命中窗的 `material_index` 指向新加的发光材质槽。

    **两个门槛**（实测坑）：
    - `min_z=115`：灯笼的玻璃盒也叫 `glass`，但灯笼挂在墙脚（z≈20~60 单位）。
      按"窗台以上"过滤，否则会把灯笼玻璃也当窗户点灯，值也重复。
    - `link=70`：同一立面两扇窗的中心距约 110+ 单位，70 的单链不会把它们粘成
      "一扇巨窗"；而一扇窗自身的多个玻璃面/分格（间距 < 40）会被并成一扇。

    返回 (点亮的窗数, 总窗数)。
    """
    rng = np.random.default_rng(seed)
    lit = total = 0
    for ob in objs:
        if ob.type != "MESH" or ob.data is None:
            continue
        me = ob.data
        mw = ob.matrix_world
        slots = [i for i, m in enumerate(me.materials) if m and m.name == kind]
        if not slots:
            continue
        items = []
        for p in me.polygons:
            if p.material_index not in slots:
                continue
            _vs, _a, _n, c = _world_face(me, mw, p.index)
            if c.z < min_z:
                continue
            items.append((c, p.index))
        total += len(_spatial_groups(items, link))
        if me.materials.get(mat_lamp.name) is None:
            me.materials.append(mat_lamp)
        idx = len(me.materials) - 1
        for group in _spatial_groups(items, link):
            if rng.random() >= prob:
                continue
            for gi in group:
                me.polygons[items[gi][1]].material_index = idx
            lit += 1
    bpy.context.view_layer.update()
    return lit, total


# ============================================================ glow 层

def _black_material():
    """纯黑无光材质（glow 层的底）。用 Principled 把 diffuse/spec/emission 全归零，
    这样即使有灯没关干净也不会被照亮 —— 比"把 base color 刷黑"更保险。"""
    m = bpy.data.materials.get("dn_black")
    if m is not None:
        return m
    m = bpy.data.materials.new("dn_black")
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (0.0, 0.0, 0.0, 1.0)
    b.inputs["Roughness"].default_value = 1.0
    b.inputs["Metallic"].default_value = 0.0
    b.inputs["Emission Strength"].default_value = 0.0
    for k, v in (("Specular IOR Level", 0.0), ("Sheen Weight", 0.0),
                 ("Coat Weight", 0.0), ("Transmission Weight", 0.0)):
        try:
            b.inputs[k].default_value = v
        except Exception:
            pass
    m.diffuse_color = (0.0, 0.0, 0.0, 1.0)
    return m


def blacken_non_emissive(objs):
    """非发光材质槽 → 纯黑（**OBJECT 级**替换：动的是对象的槽链接，不动 mesh 数据，
    也不影响其它对象共用同一 mesh 的情况）。返回可无损还原的存档。"""
    black = _black_material()
    saved = []
    kept = 0
    for ob in objs:
        if ob.type != "MESH" or ob.data is None:
            continue
        for i, slot in enumerate(ob.material_slots):
            m = slot.material
            if is_emissive(m):
                kept += 1
                continue
            saved.append((ob, i, slot.link, m))
            slot.link = "OBJECT"
            slot.material = black
    bpy.context.view_layer.update()
    return saved, kept


def restore_slots(saved):
    for ob, i, link, m in saved:
        try:
            ob.material_slots[i].material = m
            ob.material_slots[i].link = link
        except Exception:
            pass


def audit_glow_source(objs):
    """glow 层的**来源审计**：统计槽位里有多少是发光材质、分别是什么。

    这是"分离是否干净"的第一半证据（第二半 = 控制图的像素实测，见 probe）。
    """
    rows = {}
    blackened = 0
    for ob in objs:
        if ob.type != "MESH" or ob.data is None:
            continue
        for slot in ob.material_slots:
            m = slot.material
            if is_emissive(m):
                st, col = material_emission(m)
                rows.setdefault(m.name, {"slots": 0, "strength": round(st, 2),
                                         "family": _family(m.name)})
                rows[m.name]["slots"] += 1
            else:
                blackened += 1
    return rows, blackened


# ============================================================ 取景

def make_camera(sc, tilt):
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 200000.0
    ob = bpy.data.objects.new("cam", d)
    sc.collection.objects.link(ob)
    sc.camera = ob
    ob["dn_tilt"] = tilt
    return ob


def frame(cam, objs, zoom=1.0, pad=60.0, pad_top=40.0, pad_bottom=None,
          yaw=0.0, tilt=20.0, res_max=14000):
    """正交取景：把 objs 的包围点投到相机平面，按 zoom 定分辨率。

    与 probe_city_scene 同口径（纯正面 + 20° 俯角），只是把参数显式化 ——
    四张图必须用**同一套取景**，否则分层图四格大小不一，创始人看不出是同一张。

    `pad_bottom` 单列：地面铺到画面下缘时用 0（否则下缘会露出背景色的一条"白带"，
    20° 俯角下地面是斜的，留白会读作"没铺完"）。None = 与 pad 同值。
    返回 (anchor, right, up, 分辨率)。
    """
    import buildings as B
    pts = []
    for ob in objs:
        pts += B.shape_points(ob, skip_ground=False)
    right, up = B.cam_axes(yaw, tilt)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    pb = pad if pad_bottom is None else pad_bottom
    u0, u1 = min(us) - pad, max(us) + pad
    v0, v1 = min(vs) - pb, max(vs) + pad_top
    w, h = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = pts[0]
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * 14000.0)
    cam.rotation_euler = (math.radians(90.0 - tilt), 0.0, math.radians(yaw))
    k = min(1.0, res_max / float(max(w, h) * zoom))
    rx = max(64, int(round(w * zoom * k)))
    ry = max(64, int(round(h * zoom * k)))
    cam.data.ortho_scale = max(w, h)
    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    sc.render.resolution_percentage = 100
    bpy.context.view_layer.update()
    return dict(anchor=Vector(anchor), right=right, up=up, res=(rx, ry))


def render(path):
    sc = bpy.context.scene
    sc.render.filepath = path
    sc.render.image_settings.file_format = "PNG"
    bpy.ops.render.render(write_still=True)
    print("   -> %s  %dx%d" % (path.split("/")[-1], sc.render.resolution_x,
                              sc.render.resolution_y))
    return path


# ============================================================ 分层说明图（montage）

def srgb_to_linear(a):
    """sRGB 编码值 → 场景线性值（**读回渲染图后必须先做这一步**，理由见 `_load_rgba`）。"""
    x = np.clip(a, 0.0, 1.0)
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4).astype(
        np.float32)


def _load_rgba(path):
    """读 PNG 为 **linear** float RGBA 数组 (h, w, 4)，并记下尺寸。

    坑（实测）：`Image.pixels` 对 8-bit PNG **不做 sRGB→linear 解码**，返回的是
    文件里那套 sRGB 编码值（验证：日间天空 sRGB 0.669 = linear 0.4077 的编码）。
    而引擎做 `albedo × tint` 是在**线性空间**里乘的 —— 不先解码就量 tint，量到的
    是"编码空间的比值"，直接当乘法系数用会把夜晚压得偏亮、冷色也偏得不对。
    所以这里统一解码；写回用 Non-Color 的 float 图（见 `_rgba_image`），
    保证"读 → 算 → 写 → 渲染"整条链路只做一次 sRGB 编/解码。

    像素是**自下而上**排的，全程保持同一顺序，缩放/相加不受影响。
    """
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    buf = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    bpy.data.images.remove(img)
    a = buf.reshape(h, w, 4)
    a[..., :3] = srgb_to_linear(a[..., :3])
    return a, (w, h)


def _rgba_image(name, arr, w, h):
    """把 linear 数组写成**Non-Color** 生成的图像：Non-Color 保证不再做一次
    sRGB→linear 解码（我们给的就是 linear），渲染时 Standard 只做一次
    linear→sRGB 编码 —— 与源 PNG 的 sRGB→linear 解码正好互逆，四格颜色不失真。"""
    img = bpy.data.images.new(name, width=w, height=h, alpha=False,
                              float_buffer=True)
    img.colorspace_settings.name = "Non-Color"
    img.pixels.foreach_set(np.ascontiguousarray(arr, dtype=np.float32).reshape(-1))
    return img


def _text_obj(body, font, size, loc, name="dn_txt"):
    cu = bpy.data.curves.new(name, type="FONT")
    cu.body = body
    cu.font = font
    cu.size = size
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    ob = bpy.data.objects.new(name, cu)
    ob.location = tuple(loc)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def _text_width(body, size):
    """估文字宽度：CJK 全角 ≈ 1.0 em，ASCII ≈ 0.55 em（够用来撑不满格 / 换行）。"""
    n = 0.0
    for ch in body:
        n += 1.0 if ord(ch) > 0x2E80 else 0.55
    return n * size


def montage(tiles, out_path, title="", font_path=r"C:\Windows\Fonts\msyh.ttc",
            cols=2, tile_w=1000.0, res_x=2560, bg=0.045):
    """四格分层说明图（每格 = 一张渲染图 + 标注）。

    为什么在 Blender 里拼而不是 PIL：Blender 的 Python 没有 PIL（实测），
    而且中文标注要 CJK 字体 —— 直接用 Blender 的文字对象 + 自发光平面最省事，
    也保证四格与源图同一套色彩链路（Standard 视图变换，来回互逆）。

    tiles = [(source, label), ...]，按左上→右下的顺序。source 可以是
    ① PNG 路径（渲染产物）或 ② `(linear float RGBA 数组, w, h)` ——
    后者用来显示**在内存里合成的** tile（tint / tint+glow），走同一条
    Non-Color → Emission → Standard 路径，不做 8-bit 中转（暗部会出带）。
    """
    bpy.ops.wm.read_factory_settings(use_empty=True)
    # buildings 的材质缓存必须作废，否则拿到已删除的 Material（踩坑 §六）
    import buildings as B
    B._CACHE.clear()
    reset()

    sc = bpy.context.scene
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        try:
            sc.render.engine = eng
            break
        except Exception:
            continue
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    sc.render.film_transparent = False
    sc.render.image_settings.file_format = "PNG"
    # 中性深灰底（不是纯黑：纯黑下"哪一格有内容"反而读不出来）
    w = bpy.data.worlds.new("dn_montage_world")
    sc.world = w
    w.use_nodes = True
    bgn = w.node_tree.nodes.get("Background")
    bgn.inputs[0].default_value = (bg, bg, bg, 1.0)
    bgn.inputs[1].default_value = 1.0

    font = bpy.data.fonts.load(font_path)
    txt_mat = bpy.data.materials.new("dn_txt_mat")
    txt_mat.use_nodes = True
    tb = next(n for n in txt_mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    tb.inputs["Base Color"].default_value = (0.0, 0.0, 0.0, 1.0)
    tb.inputs["Emission Color"].default_value = (1.0, 0.95, 0.86, 1.0)
    tb.inputs["Emission Strength"].default_value = 1.0

    rows = int(math.ceil(len(tiles) / float(cols)))
    label_h = 54.0
    gap = 34.0
    imgs = []
    aspect = None
    for (src, label) in tiles:
        if isinstance(src, str):
            arr, (iw, ih) = _load_rgba(src)
        else:
            arr, iw, ih = src[0], int(src[1]), int(src[2])
            arr = np.asarray(arr, dtype=np.float32)
            if arr.ndim == 3 and arr.shape[2] == 3:        # 内存合成的 tile 只有 RGB
                arr = np.dstack([arr, np.ones(arr.shape[:2], np.float32)])
            arr = arr.reshape(ih, iw, 4)
        imgs.append((arr, iw, ih, label))
        if aspect is None:
            aspect = ih / float(iw)
    tile_h = tile_w * aspect
    cell_w, cell_h = tile_w, tile_h + label_h
    total_w = cols * cell_w + (cols + 1) * gap
    total_h = rows * cell_h + (rows + 1) * gap + (58.0 if title else 0.0)

    for i, (arr, iw, ih, label) in enumerate(imgs):
        r, c = divmod(i, cols)
        cx = -total_w / 2.0 + gap + cell_w / 2.0 + c * (cell_w + gap)
        cy = total_h / 2.0 - (58.0 if title else 0.0) - gap - cell_h / 2.0 \
            - r * (cell_h + gap)
        img = _rgba_image("dn_tile_%d" % i, arr, iw, ih)
        m = bpy.data.materials.new("dn_tile_mat_%d" % i)
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        em = nt.nodes.new("ShaderNodeEmission")
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = img
        tex.interpolation = "Cubic"
        nt.links.new(tex.outputs["Color"], em.inputs["Color"])
        em.inputs["Strength"].default_value = 1.0
        nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
        plane = bpy.data.meshes.new("dn_plane_%d" % i)
        hw, hh = tile_w / 2.0, tile_h / 2.0
        y0 = cy - cell_h / 2.0 + label_h
        plane.from_pydata([(cx - hw, y0, 0.0), (cx + hw, y0, 0.0),
                           (cx + hw, y0 + tile_h, 0.0), (cx - hw, y0 + tile_h, 0.0)],
                          [], [(0, 1, 2, 3)])
        # **必须给 UV**：Image Texture 的 Vector 不接线时用活动 UV 层；没有 UV 层
        # 就退化成"整片取图像同一个像素"（第一版四格全是一样的天空色，就是这么来的）。
        uvl = plane.uv_layers.new()
        for k, uv in enumerate(((0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0))):
            uvl.data[k].uv = uv
        plane.materials.append(m)
        ob = bpy.data.objects.new("dn_plane_%d" % i, plane)
        sc.collection.objects.link(ob)
        size = 0.80 * label_h
        while _text_width(label, size) > cell_w * 0.96 and size > 10.0:
            size -= 1.0
        t = _text_obj(label, font, size, (cx, y0 - label_h * 0.52, 1.0))
        t.data.materials.append(txt_mat)

    if title:
        size = 44.0
        while _text_width(title, size) > total_w * 0.94 and size > 14.0:
            size -= 1.0
        t = _text_obj(title, font, size,
                      (0.0, total_h / 2.0 - 30.0, 1.0), name="dn_title")
        t.data.materials.append(txt_mat)

    cam_d = bpy.data.cameras.new("montage_cam")
    cam_d.type = "ORTHO"
    cam_d.ortho_scale = total_w
    cam = bpy.data.objects.new("montage_cam", cam_d)
    cam.location = (0.0, 0.0, 500.0)
    cam.rotation_euler = (0.0, 0.0, 0.0)
    sc.collection.objects.link(cam)
    sc.camera = cam

    sc.render.resolution_x = res_x
    sc.render.resolution_y = max(64, int(round(res_x * total_h / total_w)))
    sc.render.filepath = out_path
    bpy.ops.render.render(write_still=True)
    print("   -> %s  %dx%d" % (out_path.split("/")[-1], sc.render.resolution_x,
                              sc.render.resolution_y))
    return out_path
