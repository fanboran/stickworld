# -*- coding: utf-8 -*-
"""写实西幻建筑程序化 PBR 材质库 v3.1（Blender 5.2 / EEVEE）。

key 家族（共 **54** 个；`ORDER` 即注册顺序，`audit()` 打印全部特征尺寸）
---------------------------------------------------------------
* **结构 26**：茅草/瓦/木/抹灰/石砌/砖/铁 + 窗玻璃/暗腔/水/灯 + 地面/草簇/绿植…
* **道具 10**（二轮追加）：染色土布×3 / 柳条 / 陶 / 叶菜 / 根菜 / 鱼 / 面包 / 染缸液面
* **玻璃·魔法 8**（三轮追加 A）：`stained_glass` / `glass_lead` / `glass_clear` /
  `glass_bottle` / `crystal` / `rune_glow` / `bronze` / `patina`
  —— 透光族要开 `_set_glass()`（瑞利折射 + 透射阴影），发光族走 `emit`/`emit_str`。
* **城市地面 10**（三轮追加 B）：`cobble_small/large` / `brick_paving` / `stone_flag` /
  `dirt_packed` / `dirt_mud` / `gravel` / `grass_lawn` / `sand` / `wood_deck`
  —— **一律不挂 `AGE`（近地溅泥）与 `OBJ_VAR`（逐体色变）**，理由见该段注释。

尺度契约（本轮重定标，一切 feature 尺寸都必须走这里的换算）
--------------------------------------------------------
* **1 UV 单位 = 1 格 = 32 世界单位 = 32 px(游戏 1:1) = 0.42 m**。
  （`Builder.__init__(tile=CELL=32)` 与 `box_project_uv` 都是这个口径；
   `box_project_uv` 的"世界单位"在样片里 1 单位 = 1 px，所以 1 UV = 32 px。）
* 换算入口：`uv_m(米)` / `uv_cm(厘米)` / `uv_mm(毫米)`，以及 `to_px(uv)` 回算像素。
* 由此得到的 texel density：游戏 1:1 = **76 px/m**；建筑渲染 2x = 152 px/m。
  出厂门禁：**缩到 25%（19 px/m）仍能说出这是什么材质** —— 所以每族材质除了
  "细读层"（草茎/砖缝/木纹）还必须有"粗读层"（层带、砌块、板缝、垄行）在
  5 cm 以上的尺度成立。

坐标约定
--------
* 图案基于 **UV**；`box_project_uv()` / `Builder.poly()` 做盒式投影：
  **U = 水平轴，V = 竖直/顺坡轴**（水平面取另一水平轴）。
* 投影基于世界坐标 → 相邻构件的纹理自然对齐；材质不是"贴图"，是**世界空间
  程序纹理**（`get_coord` 用 UV，那就是世界坐标 / 32），所以大平面上不会看到
  平铺接缝，但 feature 尺寸必须按米标定。

对外接口（契约，勿破坏）
------------------------
    make(key, **kw) / get(name) / tune(mat, scale=, tint=, wear=)
    mat_<key>(...)            # 12 个原 key 的便捷函数
    audit()                   # 打印 节点数 + 换算后的现实特征尺寸
    reset_cache()             # 场景重建后清内部缓存（避免 StructRNA 失效）
    box_project_uv(obj)

NodeGroup 参数：`Scale`（尺度倍率，>1 = 纹理更大）、`Tint`、`Wear`（0 新 ~ 1 破）。

做旧层与逐体色变（v3.2，见 `AGE` / `OBJ_VAR` 两张表）
-----------------------------------------------------
三道抱怨对应三层，全部走**低频**以守 25% 门禁（<35 cm 的"脏"在 19px/m 下只是噪点）：
1. **做旧层**（`_age_wall`，材质内部，参数在 `AGE`）：近地溅泥/苔 —— 竖面上 V（= 世界 Z
   ／32）0~35cm 渐入、随高度衰减、横向断续（**走 UV 的 V 而不是 Geometry 的世界 Z**：
   世界单位在交付渲染与样片探针里差 32 倍，只有 V 在两处都等于"世界 Z/32"，见 `_v_ground`）；
   垂直雨渍 —— 纵向拉伸噪声，亮度/色相扰动 ≤6%；木质另有**大尺度日照褪色**（朝向不可知
   → 用 1.2~2m 的噪声代替）。水平面（基座顶/墙板顶）用 Normal 门控排除，避免误溅。
2. **逐体色变**（`_obj_var`，Object Info > Random）：每 Object 一个恒定微随机色偏
   （抹灰色相 ±3%、木色明度 ±8%、陶瓦色相 ±6%）——治"全城一个色"（材质实例按名字
   复用，全局只有一个 Tint）。**只给建筑结构材质**（OBJ_VAR 登记在册）；道具系 10 个
   追加 key 不做：道具与墙体各自独立 Object，给了随机就成"一堆不同材质的桶"。
3. **屋面增强**：陶瓦/石板瓦加**第二维逐片随机**（色相摆动 + 破损率）——只用单随机
   时全屋面只在"亮红↔暗红"一条线上抖，读作均匀色带；茅草加大尺度深浅斑驳。

> `Object.random` 由对象名/创建序确定性派生（实测跨进程逐位一致），故逐体色变
> **不破坏**"同种子渲染逐位可复现"。
"""
import bpy
import math

PX_PER_UNIT = 32.0
#: 1 UV 单位（= 1 格 = 32 世界单位 = 32 px）对应的现实长度
M_PER_UV = 0.42


def px(v):
    """像素 → UV（1 UV = 32 px @游戏 1:1）。"""
    return float(v) / PX_PER_UNIT


def uv_m(metres):
    """现实米 → UV。"""
    return float(metres) / M_PER_UV


def uv_cm(centimetres):
    """现实厘米 → UV。"""
    return (float(centimetres) / 100.0) / M_PER_UV


def uv_mm(millimetres):
    """现实毫米 → UV。"""
    return (float(millimetres) / 1000.0) / M_PER_UV


def to_px(uv_units):
    """UV → 游戏 1:1 像素。"""
    return float(uv_units) * PX_PER_UNIT


# ============================================================ 节点构建器
class B:
    """轻量节点图构建器：把"取值/运算/混合"压缩成一行调用。"""

    def __init__(self, tree):
        self.tree = tree
        self.n = tree.nodes
        self.l = tree.links
        self._c = 0

    # ---------- 基础 ----------
    def nd(self, ntype, **props):
        x = self.n.new(ntype)
        self._c += 1
        x.location = ((self._c % 7) * 230.0, -(self._c // 7) * 190.0)
        for k, v in props.items():
            try:
                setattr(x, k, v)
            except Exception:
                pass
        return x

    def _in(self, sock, v):
        if v is None:
            return
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            sock.default_value = v
        elif isinstance(v, (tuple, list)):
            if sock.type == 'RGBA':
                sock.default_value = tuple(v) + (1.0,) if len(v) == 3 else tuple(v)
            elif sock.type == 'VECTOR':
                sock.default_value = tuple(v)[:3]
            else:
                sock.default_value = v
        else:
            self.l.new(v, sock)

    def prop(self, node, name, value):
        try:
            node.inputs[name].default_value = value
        except Exception:
            try:
                setattr(node, name, value)
            except Exception:
                pass
        return node

    # ---------- 数学 ----------
    def op(self, op, a, b=None, c=None, clamp=False):
        x = self.nd('ShaderNodeMath', operation=op, use_clamp=clamp)
        self._in(x.inputs[0], a)
        if b is not None:
            self._in(x.inputs[1], b)
        if c is not None:
            self._in(x.inputs[2], c)
        return x.outputs[0]

    def add(self, a, b):
        return self.op('ADD', a, b)

    def sub(self, a, b):
        return self.op('SUBTRACT', a, b)

    def mul(self, a, b):
        return self.op('MULTIPLY', a, b)

    def div(self, a, b):
        return self.op('DIVIDE', a, b)

    def mn(self, a, b):
        return self.op('MINIMUM', a, b)

    def mx(self, a, b):
        return self.op('MAXIMUM', a, b)

    def absv(self, a):
        return self.op('ABSOLUTE', a)

    def flr(self, a):
        return self.op('FLOOR', a)

    def frc(self, a):
        return self.sub(a, self.flr(a))

    def sine(self, a, mult=1.0, phase=0.0):
        return self.op('SINE', self.add(self.mul(a, mult), phase))

    def pisin(self, a):
        """sin(pi * a)：0→0, 0.5→1, 1→0（块体/草茎截面主力）。"""
        return self.op('SINE', self.mul(a, math.pi))

    def vop(self, op, a, b, c=None):
        x = self.nd('ShaderNodeVectorMath', operation=op)
        self._in(x.inputs[0], a)
        self._in(x.inputs[1], b)
        if c is not None:
            self._in(x.inputs[2], c)
        return x.outputs[0]

    def sep(self, v):
        x = self.nd('ShaderNodeSeparateXYZ')
        self._in(x.inputs[0], v)
        return x.outputs[0], x.outputs[1], x.outputs[2]

    def sep_c(self, c):
        x = self.nd('ShaderNodeSeparateColor', mode='RGB')
        self._in(x.inputs[0], c)
        return x.outputs[0], x.outputs[1], x.outputs[2]

    def vec(self, x, y, z):
        n = self.nd('ShaderNodeCombineXYZ')
        for i, s in enumerate((x, y, z)):
            self._in(n.inputs[i], s)
        return n.outputs[0]

    def mr(self, v, f0, f1, t0, t1, interp='LINEAR', clamp=True):
        n = self.nd('ShaderNodeMapRange', interpolation_type=interp, clamp=clamp)
        self._in(n.inputs[0], v)
        self._in(n.inputs[1], f0)
        self._in(n.inputs[2], f1)
        self._in(n.inputs[3], t0)
        self._in(n.inputs[4], t1)
        return n.outputs[0]

    def ss(self, v, e0, e1):
        """smoothstep：e0→0, e1→1（e0>e1 时反向）。"""
        return self.mr(v, e0, e1, 0.0, 1.0, interp='SMOOTHSTEP')

    def lin(self, v, f0, f1, t0, t1):
        return self.mr(v, f0, f1, t0, t1, interp='LINEAR')

    def step(self, v, e):
        """v > e → 1"""
        return self.op('GREATER_THAN', v, e)

    def lt(self, v, e):
        """v < e → 1"""
        return self.op('LESS_THAN', v, e)

    def gt01(self, v, e):
        return self.op('GREATER_THAN', v, e)

    def pow(self, v, e):
        return self.op('POWER', v, e)

    # ---------- 哈希 / 随机（确定性：全靠 WhiteNoise 对整数格点哈希） ----------
    def h1(self, x, seed=0.0, salt=0.0):
        return self.white(self.vec(x, salt, seed))

    def h2(self, x, y, seed=0.0):
        return self.white(self.vec(x, y, seed))

    # ---------- 混合 ----------
    def mixc(self, fac, a, b, blend='MIX'):
        """颜色混合：fac=0 → a, fac=1 → b（a/b 可为色值或 socket）。"""
        n = self.nd('ShaderNodeMix', data_type='RGBA', blend_type=blend, clamp_factor=True)
        self._in(n.inputs[0], fac)
        self._in(n.inputs[6], a)
        self._in(n.inputs[7], b)
        return n.outputs[2]

    def mixf(self, fac, a, b):
        n = self.nd('ShaderNodeMix', data_type='FLOAT', clamp_factor=True)
        self._in(n.inputs[0], fac)
        self._in(n.inputs[2], a)
        self._in(n.inputs[3], b)
        return n.outputs[0]

    def mul_c(self, c, k):
        """颜色 × 灰度系数（k 可为常数或 socket）。"""
        if not isinstance(k, (int, float)):
            return self.mixc(1.0, c, k, blend='MULTIPLY')
        return self.mixc(1.0, c, (k, k, k), blend='MULTIPLY')

    def shade(self, c, fac, dark=0.55, light=1.0):
        """按 fac(0~1) 把颜色在 [c*dark, c*light] 之间插值——AO/层叠阴影主力。"""
        lo = self.mul_c(c, dark)
        hi = self.mul_c(c, light)
        return self.mixc(fac, lo, hi)

    # ---------- 程序纹理 ----------
    def noise(self, vec, scale=1.0, detail=6.0, rough=0.5, dist=0.0, gain=0.0, dim='3D'):
        n = self.nd('ShaderNodeTexNoise')
        self.prop(n, 'noise_dimensions', dim)
        for k, v in (('detail', detail), ('roughness', rough), ('distortion', dist), ('gain', gain)):
            try:
                setattr(n, k, v)
            except Exception:
                pass
        self._in(n.inputs['Scale'], scale)
        self._in(n.inputs['Vector'], vec)
        return n.outputs[0]

    def voro(self, vec, scale=1.0, feature='F1', randomness=1.0, detail=0.0, rough=0.5):
        n = self.nd('ShaderNodeTexVoronoi', feature=feature, distance='EUCLIDEAN')
        for k, v in (('randomness', randomness), ('detail', detail), ('roughness', rough)):
            try:
                setattr(n, k, v)
            except Exception:
                pass
        self._in(n.inputs['Scale'], scale)
        self._in(n.inputs['Vector'], vec)
        return n.outputs[0], n.outputs[1], n.outputs[2]

    def white(self, vec):
        n = self.nd('ShaderNodeTexWhiteNoise')
        self.prop(n, 'noise_dimensions', '3D')
        self._in(n.inputs[0], vec)
        return n.outputs[0]

    # ---------- 世界坐标 / 逐体随机 ----------
    def pos_z(self):
        """Geometry > Position 的世界 Z（**注意口径**：世界单位 = 场景尺度，

        `buildings.py` 里 1 单位 = 1px@1:1，样片探针里 1 单位 = 1 格，两者差 32 倍；
        任何"现实尺寸"判定都要先想清楚在哪种尺度下——做旧层因此改走 UV 的 V（见 _v_ground）。
        """
        n = self.nd('ShaderNodeNewGeometry')
        _x, _y, z = self.sep(n.outputs['Position'])
        return z

    def nz(self):
        """Geometry > Normal 的 Z 分量（竖面判定用）。"""
        n = self.nd('ShaderNodeNewGeometry')
        _x, _y, z = self.sep(n.outputs['Normal'])
        return z

    def comb(self, r, g, bl):
        """三通道合成颜色（ShaderNodeCombineColor/RGB）——通道级色偏乘子用。"""
        n = self.nd('ShaderNodeCombineColor', mode='RGB')
        for i, s in enumerate((r, g, bl)):
            self._in(n.inputs[i], s)
        return n.outputs[0]

    def obj_rand(self):
        """Object Info > Random：**每对象恒定**的 0~1 随机（跨进程可复现，见 _obj_var）。"""
        n = self.nd('ShaderNodeObjectInfo')
        return n.outputs['Random']

    def wave(self, vec, scale, bands='X', dist=0.0, detail=0.0, phase=0.0):
        n = self.nd('ShaderNodeTexWave', wave_type='BANDS', bands_direction=bands,
                    wave_profile='SIN')
        for k, v in (('distortion', dist), ('detail', detail), ('phase_offset', phase)):
            try:
                setattr(n, k, v)
            except Exception:
                pass
        self._in(n.inputs['Scale'], scale)
        self._in(n.inputs['Vector'], vec)
        return n.outputs[1]          # Factor

    def bump(self, height, strength, distance=0.02, normal=None):
        n = self.nd('ShaderNodeBump')
        self._in(n.inputs[0], strength)
        self._in(n.inputs[1], distance)
        self._in(n.inputs[3], height)
        if normal is not None:
            self._in(n.inputs[4], normal)
        return n.outputs[0]

    def ramp(self, fac, stops):
        n = self.nd('ShaderNodeValToRGB')
        cr = n.color_ramp
        while len(cr.elements) > 1:
            cr.elements.remove(cr.elements[-1])
        cr.elements[0].position = stops[0][0]
        cr.elements[0].color = stops[0][1] if len(stops[0][1]) == 4 else tuple(stops[0][1]) + (1.0,)
        for pos, col in stops[1:]:
            e = cr.elements.new(pos)
            e.color = col if len(col) == 4 else tuple(col) + (1.0,)
        self._in(n.inputs[0], fac)
        return n.outputs[0]


# ------------------------------------------------------------ 通用字段
def _uv(b, gi):
    """取 Scale 归一化后的 UV（u=水平, v=竖直/顺坡）。"""
    tc = b.nd('ShaderNodeTexCoord')
    inv = b.op('DIVIDE', 1.0, gi.outputs['Scale'])
    uv = b.vop('SCALE', tc.outputs['UV'], inv)
    u, v, _ = b.sep(uv)
    return u, v


def _rows(b, v, h):
    """横向分层（木板/草层/原木）。返回 (sv, row, fv, row_rand, row_rand2)。"""
    sv = b.div(v, h)
    row = b.flr(sv)
    fv = b.sub(sv, row)
    return sv, row, fv, b.h1(row, 5.0), b.h1(row, 91.0)


def _cells(b, u, v, cw, ch, stagger=0.5, seed=0.0, jitter=0.0):
    """矩形砌块场（砖/瓦/木瓦）：错缝 + 可选的**缝位抖动**。

    抖动**只做水平方向** —— 砌筑的横缝本来就是水平的（竖缝错落），而且纵向抖动会把
    fv 推出 [0,1]，`min(fv,1-fv)` 变负 → 整条带被误判成灰浆缝，砌块读法直接崩掉
    （第一轮就是踩了这个坑：石墙读成一圈圈横向色带）。
    抖动值取自整数格哈希 → 格内恒定、块间不同，得到"边是直但不规则"的料石感
    （Voronoi 会读成鹅卵石，不能用）。
    """
    sv = b.div(v, ch)
    row = b.flr(sv)
    fv = b.sub(sv, row)
    rrand = b.h1(row, 5.0 + seed)
    su = b.add(b.div(u, cw), b.mul(rrand, stagger))
    col = b.flr(su)
    if jitter:
        jx = b.noise(b.vec(b.mul(col, 3.0), b.mul(row, 3.0), 7.0 + seed), 1.0, 2.0)
        su = b.add(su, b.mul(b.sub(jx, 0.5), jitter))
        col = b.flr(su)
    fu = b.frc(su)
    du = b.mul(b.mn(fu, b.sub(1.0, fu)), cw)
    dv = b.mul(b.mn(fv, b.sub(1.0, fv)), ch)
    d = b.mn(du, dv)
    return dict(sv=sv, row=row, fv=fv, su=su, col=col, fu=fu, d=d, du=du, dv=dv,
                rand=b.h2(col, row, 1.0 + seed),
                rand2=b.h2(col, row, 2.0 + seed),
                rand3=b.h2(col, row, 3.0 + seed))


# ------------------------------------------------------------ 做旧层 / 逐体色变
#
# 这一层治的是创始人三条抱怨：**墙面灰白平淡**（缺"住过人"的时间感）、
# **所有建筑一个色**（材质实例按名字复用 → 全局共享一个 Tint）、
# **屋面像贴纹理平板**（缺斑驳）。三条都必须在 25% 门禁尺寸下仍然成立：
# 所以做旧全部走**低频**（≥35 cm 的带/斑），不做高频脏点。
#
# 分工纪律：
#   * 做旧层 = 材质内部（本表 AGE），同一材质在任何建筑上都成立；
#   * 逐体色变 = Object Info > Random（OBJ_VAR），**只给建筑结构材质**——
#     道具系那 10 个追加 key 不做：道具与墙体是各自独立的 Object，若也给随机，
#     一排木桶会各自偏色（读作"摆了一堆不同材质的桶"）。

#: 做旧层参数（每 key）：
#:   splash 溅泥强度 / mud 暖褐泥色 / moss 苔色 / h 近地渐入高度(m)
#:   rain 垂直雨渍强度 / sun 日照褪色强度 / sun_gray 褪色目标色
AGE = {
    'plaster':     dict(splash=0.58, mud=(0.302, 0.252, 0.184), moss=(0.168, 0.190, 0.092),
                        rain=0.055, h=0.45),
    'stone':       dict(splash=0.56, mud=(0.238, 0.202, 0.152), moss=(0.138, 0.172, 0.076),
                        rain=0.050, h=0.35),
    'white_stone': dict(splash=0.24, mud=(0.372, 0.330, 0.268), moss=(0.204, 0.226, 0.138),
                        rain=0.040, h=0.30),
    'brick':       dict(splash=0.42, mud=(0.246, 0.192, 0.140), moss=(0.140, 0.164, 0.078),
                        rain=0.050, h=0.35),
    'wattle':      dict(splash=0.58, mud=(0.312, 0.280, 0.208), moss=(0.202, 0.262, 0.102),
                        rain=0.050, h=0.45),
    'plank_wall':  dict(splash=0.44, mud=(0.188, 0.148, 0.100), moss=(0.128, 0.148, 0.068),
                        rain=0.060, sun=0.13, sun_gray=(0.660, 0.612, 0.520), h=0.40),
    'timber':      dict(splash=0.34, mud=(0.148, 0.116, 0.080), moss=(0.108, 0.128, 0.060),
                        rain=0.050, sun=0.11, h=0.35),
    'log_wall':    dict(splash=0.46, mud=(0.182, 0.146, 0.100), moss=(0.122, 0.148, 0.068),
                        rain=0.058, sun=0.10, sun_gray=(0.628, 0.570, 0.462), h=0.40),
    'shingle':     dict(rain=0.050, sun=0.16, sun_gray=(0.600, 0.552, 0.470)),
    'slate_roof':  dict(rain=0.040, sun=0.10, sun_gray=(0.500, 0.520, 0.545)),
    'thatch':      dict(sun=0.14, sun_gray=(0.720, 0.620, 0.400)),
    'thatch_old':  dict(sun=0.09, sun_gray=(0.560, 0.520, 0.400)),
    'straw':       dict(sun=0.12, sun_gray=(0.700, 0.600, 0.380)),
    # 金属构件（三轮追加）：铜器多在半人高以上（门环/包角/灯架/落水管），
    # 溅泥带压到 0.30 m 且强度不高；patina 本体已经是"老化产物"，只做日照泛白 + 雨渍。
    'bronze':      dict(splash=0.34, mud=(0.196, 0.155, 0.106), moss=(0.120, 0.152, 0.074),
                        rain=0.050, h=0.30),
    'patina':      dict(rain=0.055, sun=0.10, sun_gray=(0.560, 0.640, 0.600)),
}

#: 逐体色变幅度 (hue, val)：hue = 通道增益偏差（近似小色相旋转），val = 明度 ±。
#: **只登记建筑结构材质**（墙体/屋面/石砌）；道具系 10 key 一律不做。
OBJ_VAR = {
    'plaster':     (0.032, 0.045),      # 抹灰：色相 ±3%（近中性面上色偏会被放大，宁小勿大）
    'stone':       (0.036, 0.060),
    'white_stone': (0.030, 0.050),
    'brick':       (0.032, 0.062),
    'wattle':      (0.028, 0.060),
    'plank_wall':  (0.026, 0.080),      # 木色：明度 ±8%
    'timber':      (0.022, 0.080),
    'log_wall':    (0.026, 0.080),
    'shingle':     (0.024, 0.080),
    'thatch':      (0.040, 0.080),
    'thatch_old':  (0.040, 0.080),
    'straw':       (0.034, 0.070),
    'tile_roof':   (0.060, 0.050),      # 陶瓦：色相 ±6%
    'slate_roof':  (0.034, 0.060),
    # 三轮追加：只给**建筑结构**系（铜构件/铜绿屋面）。玻璃/水晶/符文/地面系一律不做——
    # 玻璃窗格若逐 Object 偏色会让同一面墙的窗子不同色；地砖逐块偏色会在接缝处露硬色阶。
    'bronze':      (0.032, 0.055),
    'patina':      (0.038, 0.070),
}


def _obj_var(b, key):
    """逐体微随机色偏乘子（Object Info > Random，每对象恒定）。

    实现：三通道用 120° 相位的正弦调制（R/G/B 各自 1 + hue·sin(θ + 相位)）
    —— 一次近似的小色相旋转，同时带一点明度抖动；再乘一个独立的 ±val 明度因子
    （由同一个 Random 的分数拍哈希出第二个随机数，省一个节点）。
    `Object.random` 由对象名/创建序确定性派生，**跨进程逐位一致**（已实测）。
    """
    hue, val = OBJ_VAR[key]
    r = b.obj_rand()
    ang = b.mul(b.sub(r, 0.5), 6.2831853)
    sr = b.add(1.0, b.mul(b.sine(ang, 1.0, 0.0), hue))
    sg = b.add(1.0, b.mul(b.sine(ang, 1.0, 2.0943951), hue))
    sb = b.add(1.0, b.mul(b.sine(ang, 1.0, 4.1887902), hue))
    q = b.frc(b.add(b.mul(r, 7.317), 0.371))
    f = b.add(1.0, b.mul(b.sub(q, 0.5), 2.0 * val))
    return b.mul_c(b.comb(sr, sg, sb), f)


def _v_ground(b, v, h_m=0.35):
    """近地权重：V（= 世界 Z/32，竖面上 = 离地高度）0 → 1，h_m 以上 → 0。

    为什么不用 `Geometry > Position` 的**世界 Z**：世界单位在两处口径差 32 倍 ——
    `buildings.py`/交付渲染里 **1 单位 = 1px@1:1**（一层檐高 200 单位 ≈ 2.1m），
    而样片探针（`probe_materials_v2`/`probe_mat3`，`box_project_uv` 直投 UV）
    里 **1 单位 = 1 格 = 32px**（同一面墙只有 5 单位）。同一句"世界 Z 0~0.35m"
    在两个场景里相差 32 倍，材质会在一处几乎看不见、在另一处糊满整面墙（实测踩过）。
    V 在两处都等于"世界 Z / 32"，正是本库唯一的口径基准（1 UV = 1 格 = 0.42m），
    所以做旧层一律走 V → 与场景尺度无关。
    """
    return b.sub(1.0, b.ss(v, 0.0, uv_m(h_m)))


def _vertical(b):
    """竖面权重（0~1）：|N.z| 小 → 1；水平面（地面/基座顶/屋面）→ 0。

    防什么：V 在水平面上是"进深"而不是"高度"（`Builder.poly` 的水平面取 (x,y)），
    所以墙材贴到**水平面**（基座顶檐、墙板顶面）时会被误判成"贴地"而溅满泥。
    """
    return b.sub(1.0, b.ss(b.absv(b.nz()), 0.35, 0.80))


def _mud_palette(b, u, v, mud, moss, seed=271.0):
    """溅泥色：低频斑里"泥色 ↔ 苔色"互串（同一层里既有泥点也有苔痕）。"""
    n = b.noise(b.vec(b.mul(u, 1.7), b.mul(v, 2.8), seed), 1.0, 5.0, 0.5)
    return b.mixc(b.lin(n, 0.30, 0.78, 0.0, 1.0), mud, moss)


def _splash_mask(b, u, v, g):
    """溅泥掩码（0~1）：近地梯度 × 低频断斑 + 底部更密的溅点。

    刻意"断续"：连续的贴地色带会读成"墙脚刷了一道漆"，断续才读作泥水飞溅。
    """
    lo = b.noise(b.vec(b.mul(u, 1.9), b.mul(v, 3.2), 211.0), 1.0, 5.0, 0.55)
    band = b.mul(g, b.lin(lo, 0.28, 0.80, 0.30, 1.0))
    sp = b.noise(b.vec(b.mul(u, 7.5), b.mul(v, 5.5), 223.0), 1.0, 4.0, 0.5)
    speck = b.mul(b.ss(sp, 0.62, 0.80), b.mul(g, 0.85))
    return b.mx(band, speck)


def _rain_mask(b, u, v):
    """垂直雨渍掩码：噪声沿 U 高频、沿 V 低频 → 纵向拉伸的水痕（断续）。"""
    n = b.noise(b.vec(b.mul(u, 8.0), b.mul(v, 0.60), 233.0), 1.0, 5.0, 0.35)
    return b.ss(n, 0.44, 0.82)


def _sun_bleach(b, u, v, col, amt, gray):
    """大尺度日照褪色（1.2~2 m 斑）：朝向不可知 → 只能用大尺度噪声代替。

    只给木质（木墙/木骨/木瓦/茅草）：受光面被晒白、背光面留原色，这层"不匀"
    正是"整片一个色"的解药。
    """
    n = b.noise(b.vec(b.mul(u, 0.30), b.mul(v, 0.23), 241.0), 1.0, 4.0)
    m = b.ss(n, 0.40, 0.74)
    col = b.mixc(b.mul(m, amt), col, gray)
    return b.mul_c(col, b.lin(m, 0.0, 1.0, 1.0, 1.06))


def _age_wall(b, u, v, col, key):
    """墙面/屋面做旧层（plaster/stone/wood 系共用；参数见 AGE 表）。

    顺序：日照褪色（大尺度底色不匀）→ 近地溅泥/苔 → 垂直雨渍（≤6% 扰动）。
    三层都低频克制，保证 25% 门禁下是"读得出材质+有年头"，不是"脏斑"。
    """
    cfg = AGE.get(key)
    if not cfg:
        return col
    if cfg.get('sun'):
        col = _sun_bleach(b, u, v, col, cfg['sun'],
                          cfg.get('sun_gray', (0.620, 0.590, 0.540)))
    if cfg.get('splash'):
        g = b.mul(_v_ground(b, v, cfg.get('h', 0.35)), _vertical(b))
        m = b.mul(_splash_mask(b, u, v, g), cfg['splash'])
        col = b.mixc(m, col, _mud_palette(b, u, v, cfg['mud'], cfg['moss']))
    if cfg.get('rain'):
        m = b.mul(_rain_mask(b, u, v), cfg['rain'])
        # 通道压暗不相等 → 水痕微偏冷（R 压得比 B 多），总扰动 ≤ rain
        col = b.mul_c(col, b.comb(b.sub(1.0, m),
                                  b.sub(1.0, b.mul(m, 0.80)),
                                  b.sub(1.0, b.mul(m, 0.52))))
    return col


def _aged(b, u, v, col, key):
    """做旧层 + 逐体色变（结构材质统一收尾；道具材质只调 `_age_wall` 不调本函数）。"""
    col = _age_wall(b, u, v, col, key)
    if key in OBJ_VAR:
        col = b.mul_c(col, _obj_var(b, key))
    return col


# ============================================================ 茅草
def _b_thatch(b, gi, bsdf, variant='new'):
    """茅草：**沿 V（顺坡）的单根草茎** + 分层的草把 + 层界暗影带。

    这是本轮返工的核心。旧版用"各向异性噪声等值线"做草茎，噪声频率过高
    （茎宽 ≈ 1 cm = 0.75 px）→ 直接糊成"草席/瓦楞板"。

    新版逐字面建模：
      1. 草茎索引：`si = floor((u + 层相位 + 顺坡弯曲) / 茎宽)`，茎宽 2.6 cm；
         逐茎哈希给明度/色温差 → 一根是一根。
      2. 茎截面：`core = sin(pi*fu)^0.5` → 茎心亮、茎缝暗（草秆是圆的）。
      3. 草层：层高 27 cm，**逐层草茎相位错位**（层与层不对齐 → 层界可读）；
         每层草茎下梢参差（±），梢下 = 深层暗影带 → "一撮一撮披下来"。
      4. 梢部发白（枯梢）+ 层间色差 + 旧草的霉斑。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)

    sw = uv_cm(2.8)            # 草茎宽 2.8 cm
    lh = uv_cm(27.0)           # 草层高 27 cm

    # ---- 坡面起伏（很轻，过大就失去"层"的读法）
    wob = b.noise(b.vec(b.mul(u, 1.1), b.mul(v, 0.22), 11.0), 1.0, 3.0)
    vv = b.add(v, b.mul(b.sub(wob, 0.5), b.mul(lh, 0.28)))
    sv = b.div(vv, lh)
    band = b.flr(sv)
    fv = b.sub(sv, band)
    br = b.h1(band, 5.0)
    br2 = b.h1(band, 61.0)

    # ---- 草茎（层相位错位 + 顺坡弯曲 + **茎宽不均** → 不要做成"均匀编织帘"）
    phase = b.mul(br, b.mul(sw, 2.0))
    curv = b.noise(b.vec(b.mul(v, 0.5), b.mul(u, 0.12), 23.0), 1.0, 3.0)
    widen = b.noise(b.vec(b.div(u, b.mul(sw, 3.0)), b.mul(v, 0.25), 61.0), 1.0, 3.0)
    u2 = b.add(b.add(u, phase), b.mul(b.sub(curv, 0.5), b.mul(sw, 1.6)))
    u2 = b.add(u2, b.mul(b.sub(widen, 0.5), b.mul(sw, 1.3)))
    su = b.div(u2, sw)
    si = b.flr(su)
    fu = b.sub(su, si)
    sr = b.h1(si, 7.0)          # 逐茎明度
    sr2 = b.h1(si, 91.0)        # 逐茎色温/干湿
    sr3 = b.h1(si, 131.0)       # 逐茎"干枯/新鲜"
    sr4 = b.noise(b.vec(b.mul(si, 1.7), b.mul(v, 2.2), 157.0), 1.0, 3.0)   # 沿茎渐变
    # 一撮一撮：每 ~9 根草茎共用一个"撮"的明度/色调偏置（同撮的草是一起铺的）
    clump_i = b.flr(b.div(su, 9.0))
    cl = b.h1(clump_i, 311.0)
    cl2 = b.h1(clump_i, 337.0)
    core = b.pow(b.pisin(fu), 0.5)
    seam = b.sub(1.0, core)     # 1 = 茎缝
    # 第二层细茎（1.5cm）叠在上面 → 两个尺度并存，破碎均匀感
    sw2 = uv_cm(1.5)
    su2 = b.div(b.add(u, b.mul(curv, b.mul(sw2, 2.0))), sw2)
    si2 = b.flr(su2)
    fu2 = b.sub(su2, si2)
    core2 = b.pow(b.pisin(fu2), 0.6)
    fine = b.mul(core2, b.mul(b.h1(si2, 173.0), 0.55))

    # ---- 顺茎细部：**必须沿茎（V）缓慢** —— 频率一高就和跨茎方向混成"针织/草席"
    fib = b.noise(b.vec(b.mul(u, 1.4), b.mul(v, 7.0), 5.0), 1.0, 5.0)
    knot = b.noise(b.vec(b.mul(u, 1.2), b.mul(v, 3.2), 13.0), 1.0, 4.0)

    # ---- 本层草梢参差 → 梢下暗影（层界）：窄、软、**沿 U 断断续续**（不断就成竹席横档）
    tipn = b.noise(b.vec(b.mul(u, 11.0), b.mul(band, 7.3), 31.0), 1.0, 3.0)
    tip = b.mr(tipn, 0.34, 0.66, 0.12, 0.40)
    gap = b.sub(1.0, b.ss(fv, b.sub(tip, 0.05), b.add(tip, 0.04)))
    gapbreak = b.lin(b.noise(b.vec(b.mul(u, 1.3), b.mul(band, 2.7), 199.0), 1.0, 4.0),
                     0.30, 0.72, 0.35, 1.0)
    gap = b.mul(gap, gapbreak)
    # ---- 一撮一撮的草把：沿 V 拉长、**低对比**（对比一高就成"编织格"）
    bundle = b.lin(b.noise(b.vec(b.mul(u, 1.3), b.mul(v, 0.35), 43.0), 1.0, 5.0),
                   0.30, 0.70, 0.0, 1.0)

    bright = b.add(b.mul(core, 0.42), b.mul(sr, 0.26))
    bright = b.add(bright, b.mul(sr4, 0.12))
    bright = b.add(bright, b.mul(fib, 0.06))
    bright = b.add(bright, b.mul(bundle, 0.08))
    bright = b.add(bright, b.mul(cl, 0.12))         # 撮内同明度

    if variant == 'old':
        c_dark, c_mid, c_hi = (0.068, 0.044, 0.020), (0.300, 0.205, 0.092), (0.600, 0.490, 0.285)
        c_moss = (0.135, 0.140, 0.062)
    else:
        c_dark, c_mid, c_hi = (0.105, 0.042, 0.008), (0.700, 0.360, 0.085), (1.000, 0.800, 0.400)
        c_moss = (0.165, 0.150, 0.062)

    col = b.ramp(bright, [(0.10, c_dark), (0.44, c_mid), (0.80, c_hi)])
    col = b.mixc(b.mul(sr2, 0.9), b.mul_c(col, 0.80), col)          # 逐茎深浅
    col = b.mixc(b.mul(sr3, 0.5), b.mul_c(col, 0.86), col)          # 少数枯茎
    col = b.mixc(b.mul(cl2, 0.45), b.mul_c(col, 0.88), col)         # 撮间色调差
    col = b.mixc(b.mul(core2, 0.85), b.mul_c(col, 0.78), col)       # 细茎层（暗缝）
    col = b.mul_c(col, b.lin(seam, 0.0, 1.0, 1.02, 0.46))           # 茎缝压暗（硬边界）
    col = b.mixc(gap, b.mul_c(col, 0.50), col)                      # 层界暗影带（软、断续）
    col = b.mixc(b.mul(gap, 0.14), col, b.mul_c(col, 1.22))         # 层界下缘一线受光
    col = b.mixc(b.mul(knot, 0.20), b.mul_c(col, 0.80), col)        # 草节

    # ---- 大尺度斑驳（0.4~0.6 m 的干/湿、新/旧斑块）：屋面"像一块平板"的直接解药。
    #      只走同色系明度 ±20% + 一点湿草的暗黄，绝不引入异物色。
    pat = b.lin(b.noise(b.vec(b.mul(u, 0.85), b.mul(v, 0.50), 251.0), 1.0, 4.0),
                0.28, 0.74, 0.0, 1.0)
    col = b.mul_c(col, b.lin(pat, 0.0, 1.0, 0.80, 1.18))
    wet = b.ss(b.noise(b.vec(b.mul(u, 0.62), b.mul(v, 0.42), 257.0), 1.0, 4.0), 0.54, 0.82)
    col = b.mixc(b.mul(wet, 0.34 if variant == 'old' else 0.16), col, (0.235, 0.192, 0.098))

    # ---- 霉斑（旧草明显；新草只留一点灰，注意别做成"发霉抹布"）
    m1 = b.noise(b.vec(b.mul(u, 2.6), b.mul(v, 2.6), 47.0), 1.0, 5.0, 0.6)
    m2 = b.noise(b.vec(b.mul(u, 9.0), b.mul(v, 9.0), 53.0), 1.0, 4.0)
    mold = b.ss(b.mixf(0.5, m1, m2), 0.54, 0.68)
    amt = wear if variant == 'old' else b.mul(wear, 0.15)
    col = b.mixc(b.mul(mold, amt), col, c_moss)

    h = b.add(b.mul(core, 0.55), b.mul(bundle, 0.30))
    h = b.add(h, b.mul(b.sub(fib, 0.5), 0.12))
    h = b.sub(h, b.mul(seam, 0.50))
    h = b.sub(h, b.mul(gap, 0.60))
    h = b.add(h, b.mul(fine, 0.22))
    rough = b.add(b.lin(bundle, 0.0, 1.0, 0.88, 0.97), b.mul(seam, 0.02))
    # 日照褪色（大尺度斑，取代"朝向"信息）+ 逐体色偏 ±8% 明度
    col = _aged(b, u, v, col, 'thatch' if variant != 'old' else 'thatch_old')

    return dict(color=col, rough=rough,
                normal=b.bump(h, 0.65, uv_cm(1.6)),
                spec=0.10, sheen=0.30, sheen_rough=0.55)


# ============================================================ 散稻草
def _b_straw(b, gi, bsdf):
    """散稻草（草垛/屋顶散落/地面铺草）：**以顺坡（V）为主的草堆** + 零星横躺的散秆。

    上一轮做成"两向等权交叉"→ 直接读成竹席/编织垫。稻草堆是**有主方向**的：
    绝大多数秆顺着堆的坡向躺，少数被踩/被风吹成横的，再加上成堆的低频明暗起伏。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    sw = uv_cm(2.0)             # 散草秆 2 cm

    # 主方向：沿 V 躺的草（横截面在 U）
    sk = b.div(u, sw)
    si = b.flr(sk)
    fu = b.sub(sk, si)
    core = b.pow(b.pisin(fu), 0.5)
    sr = b.h1(si, 23.0)
    sr2 = b.h1(si, 71.0)
    sr3 = b.noise(b.vec(b.mul(si, 1.3), b.mul(v, 1.6), 137.0), 1.0, 3.0)
    # 少数横躺的散秆（约 18% 的秆位）：压在堆面上
    sk2 = b.div(v, b.mul(sw, 1.3))
    si2 = b.flr(sk2)
    fu2 = b.sub(sk2, si2)
    core2 = b.pow(b.pisin(fu2), 0.5)
    gate2 = b.ss(b.h1(si2, 211.0), 0.82, 0.88)
    # 斜躺的散秆（45°）
    d45 = b.div(b.add(u, v), b.mul(sw, 1.7))
    si3 = b.flr(d45)
    fu3 = b.sub(d45, si3)
    core3 = b.pow(b.pisin(fu3), 0.5)
    gate3 = b.ss(b.h1(si3, 233.0), 0.86, 0.92)

    fib = b.noise(b.vec(b.mul(u, 3.0), b.mul(v, 9.0), 29.0), 1.0, 5.0)
    clump = b.noise(b.vec(b.mul(u, 1.2), b.mul(v, 1.2), 13.0), 1.0, 5.0)   # 成堆起伏

    bright = b.add(b.mul(core, 0.42), b.mul(sr, 0.30))
    bright = b.add(bright, b.mul(sr3, 0.16))
    bright = b.add(bright, b.mul(clump, 0.12))
    col = b.ramp(bright, [(0.06, (0.115, 0.052, 0.012)),
                          (0.46, (0.520, 0.300, 0.082)),
                          (0.86, (0.870, 0.680, 0.330))])
    col = b.mixc(sr2, b.mul_c(col, 0.80), col)
    # 横躺/斜躺散秆（亮一点、压在面上）
    overlay = b.mx(b.mul(gate2, core2), b.mul(gate3, b.mul(core3, 0.9)))
    col = b.mixc(overlay, b.mul_c(col, 0.72), b.mul_c(col, 1.10))
    col = b.mixc(b.mul(b.ss(fib, 0.62, 0.86), b.mul(wear, 0.30)), col,
                 (0.235, 0.180, 0.075))
    rough = b.lin(fib, 0.0, 1.0, 0.88, 0.97)
    h = b.add(b.mul(core, 0.80), b.mul(b.sub(fib, 0.5), 0.30))
    h = b.sub(h, b.mul(sr, 0.18))
    h = b.add(h, b.mul(overlay, 0.55))
    h = b.add(h, b.mul(b.sub(clump, 0.5), 0.60))
    col = _aged(b, u, v, col, 'straw')
    return dict(color=col, rough=rough, normal=b.bump(h, 0.85, uv_cm(1.2)),
                spec=0.10, sheen=0.35, sheen_rough=0.6)


# ============================================================ 陶瓦
def _row_light(b, fv, top=0.90, grad_to=0.55, lip=0.06):
    """交叠屋面的**行内受光律**：fv=1 是本排顶端（被上一排压住）→ 硬接触影 + 上排投影渐变；
    fv=0 是本排下缘（露出的板边/瓦口）→ 受光的薄棱。

    这一条是"石板瓦/木瓦/陶瓦读不对"的总病根：旧版只在 fv≈0 做了一道对称的暗缝，
    横纵缝强度一样 → 立刻读成"砌墙"。正确的读法是"上暗下亮、行是主角"。
    """
    contact = b.ss(fv, top - 0.07, top + 0.02)          # 硬接触线
    grad = b.lin(fv, top - grad_to, top, 0.0, 1.0)      # 上排投影（渐变）
    shade = b.mx(contact, grad)
    lip = b.sub(1.0, b.ss(fv, 0.0, lip))                # 下缘薄棱
    return shade, lip


def _b_tile_roof(b, gi, bsdf):
    """陶瓦（筒板瓦）：**横向垄行是主角**（每排瓦口一道硬阴影 + 上一排的投影 +
    本排瓦口的圆棱），同排瓦片之间只有细缝 + 瓦垄剖面。逐片色差 + 苔痕。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    cw, ch = uv_cm(15.0), uv_cm(16.0)       # 瓦 15cm 宽、每排露 16cm
    c = _cells(b, u, v, cw, ch, stagger=0.5, seed=3.0)
    fu, fv, r1, r2, r3 = c['fu'], c['fv'], c['rand'], c['rand2'], c['rand3']

    crown = b.pisin(fu)                     # 瓦垄剖面（片中央起拱）
    shade, lip = _row_light(b, fv, top=0.90, grad_to=0.60, lip=0.07)
    du = b.mul(b.mn(fu, b.sub(1.0, fu)), cw)
    seam_col = b.sub(1.0, b.ss(du, uv_cm(0.5), uv_cm(1.7)))     # 同排细缝（弱）

    base = b.mixc(r1, (0.180, 0.045, 0.022), (0.540, 0.140, 0.044))
    # ---- 逐瓦色差**第二维**：同窑批次也有色相摆动（偏黄 / 偏紫灰），r3 单独驱动
    #      （只用 r1 一个随机 → 全屋面只在"亮红↔暗红"一条线上抖，读作均匀色带）
    base = b.mixc(b.lin(r3, 0.0, 1.0, 0.0, 0.42), base,
                  b.mixc(r1, (0.315, 0.088, 0.028), (0.222, 0.148, 0.132)))
    base = b.mixc(b.lin(r2, 0.82, 0.97, 0.0, 0.72), base, (0.085, 0.030, 0.024))   # 焦瓦
    base = b.mixc(b.lin(r2, 0.0, 0.10, 0.0, 0.40), base, (0.575, 0.272, 0.100))    # 泛白瓦
    # ---- 破损率：极少数瓦片缺角/被替换（暗斑），随 Wear 上升（2~3px@25%，读作颗粒）
    dmg = b.mul(b.ss(r3, 0.90, 0.985), b.lin(wear, 0.0, 1.0, 0.35, 1.0))
    base = b.mixc(dmg, base, (0.128, 0.062, 0.044))
    base = b.shade(base, crown, 0.72, 1.20)                     # 垄脊受光
    base = b.shade(base, lip, 0.94, 1.18)                       # 瓦口亮棱
    col = b.mixc(b.mul(shade, 0.9), b.mul_c(base, 0.26), base)  # 行交叠（主角）
    col = b.mixc(b.mul(seam_col, 0.55), col, b.mul_c(base, 0.50))   # 同排缝（弱）
    # 苔痕/水渍（积在瓦口与缝里）
    moss = b.noise(b.vec(b.mul(u, 4.5), b.mul(v, 4.5), 13.0), 1.0, 5.0, 0.6)
    moss_m = b.mul(b.mul(b.ss(moss, 0.50, 0.70), b.lin(wear, 0.0, 1.0, 0.20, 0.90)),
                   b.mx(shade, b.mul(lip, 0.9)))
    col = b.mixc(moss_m, col, (0.200, 0.225, 0.100))
    grn = b.noise(b.vec(b.mul(u, 16.0), b.mul(v, 16.0), 5.0), 1.0, 4.0)   # 2px 瓦面颗粒
    col = b.mul_c(col, b.lin(grn, 0.25, 0.75, 0.92, 1.07))

    h = b.add(b.mul(crown, 0.85), b.mul(lip, 0.55))
    h = b.add(h, b.mul(shade, 1.05))            # 上一排压在上面 → 行界处一层台阶
    h = b.sub(h, b.mul(seam_col, 0.40))
    h = b.add(h, b.mul(b.sub(grn, 0.5), 0.10))
    col = _aged(b, u, v, col, 'tile_roof')
    return dict(color=col,
                rough=b.add(b.lin(r1, 0.0, 1.0, 0.60, 0.80), b.mul(grn, 0.03)),
                normal=b.bump(h, 0.75, uv_cm(2.4)), spec=0.34)


def _b_slate_roof(b, gi, bsdf):
    """石板瓦：鱼鳞状交叠 —— 每排**上缘压暗 + 上排投影渐变 + 下缘受光薄棱**，
    同排竖缝细、随机、时有时无（一旦等强就成砌墙）。冷灰偏蓝 + 风化水渍。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    cw, ch = uv_cm(26.0), uv_cm(13.0)       # 石板 26cm 宽、每排露 13cm
    c = _cells(b, u, v, cw, ch, stagger=0.5, seed=17.0, jitter=0.10)
    fu, fv, r1, r2, r3 = c['fu'], c['fv'], c['rand'], c['rand2'], c['rand3']

    shade, lip = _row_light(b, fv, top=0.92, grad_to=0.50, lip=0.05)
    du = b.mul(b.mn(fu, b.sub(1.0, fu)), cw)
    seam_col = b.sub(1.0, b.ss(du, uv_cm(0.4), uv_cm(2.0)))
    seam_col = b.mul(seam_col, b.lin(r2, 0.45, 0.72, 0.0, 1.0))    # 竖缝时有时无
    chip = b.mul(b.mr(r2, 0.86, 0.98, 0.0, 1.0),
                 b.mul(b.ss(fv, 0.02, 0.14), b.ss(fu, 0.28, 0.44)))

    base = b.mixc(r1, (0.085, 0.098, 0.120), (0.205, 0.225, 0.258))
    # 逐片色调摆动（第二维随机：一部分石板偏暖褐、一部分偏冷蓝 → 鱼鳞感更碎）
    base = b.mixc(b.lin(r3, 0.0, 1.0, 0.0, 0.40), base,
                  b.mixc(r1, (0.235, 0.222, 0.196), (0.148, 0.170, 0.200)))
    base = b.mixc(b.lin(r2, 0.82, 0.98, 0.0, 0.5), base, (0.058, 0.066, 0.082))
    base = b.mixc(b.lin(r2, 0.0, 0.14, 0.0, 0.35), base, (0.190, 0.172, 0.146))
    base = b.shade(base, lip, 1.0, 1.16)
    col = b.mixc(shade, b.mul_c(base, 0.30), base)
    col = b.mixc(b.mul(seam_col, 0.45), col, b.mul_c(base, 0.34))
    col = b.mixc(chip, col, (0.280, 0.292, 0.310))
    st = b.noise(b.vec(b.mul(u, 4.5), b.mul(v, 1.1), 41.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(st, 0.54, 0.80), b.mul(wear, 0.5)), col, (0.085, 0.095, 0.108))
    moss = b.noise(b.vec(b.mul(u, 3.6), b.mul(v, 3.6), 61.0), 1.0, 5.0, 0.6)
    col = b.mixc(b.mul(b.mul(b.ss(moss, 0.54, 0.74), b.mul(shade, 0.8)),
                       b.mul(wear, 0.6)), col, (0.170, 0.195, 0.100))
    grn = b.noise(b.vec(b.mul(u, 15.0), b.mul(v, 15.0), 9.0), 1.0, 4.0)
    col = b.mul_c(col, b.lin(grn, 0.25, 0.75, 0.93, 1.06))

    h = b.add(b.mul(lip, 0.95), b.mul(b.sub(1.0, shade), -1.05))
    h = b.sub(h, b.mul(seam_col, 0.30))
    h = b.sub(h, b.mul(chip, 0.6))
    h = b.add(h, b.mul(b.sub(grn, 0.5), 0.08))
    col = _aged(b, u, v, col, 'slate_roof')
    return dict(color=col,
                rough=b.add(b.lin(r1, 0.0, 1.0, 0.56, 0.76), b.mul(grn, 0.04)),
                normal=b.bump(h, 0.70, uv_cm(2.2)), spec=0.44)


# ============================================================ 木瓦
def _b_shingle(b, gi, bsdf):
    """木瓦（鱼鳞板）：13 cm 宽、每排露 17 cm，逐片色差 + 顺纹木理 + 行交叠受光。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    cw, ch = uv_cm(16.0), uv_cm(18.0)       # 木瓦 16cm 宽、每排露 18cm
    c = _cells(b, u, v, cw, ch, stagger=0.5, seed=29.0, jitter=0.18)
    fu, fv, r1, r2 = c['fu'], c['fv'], c['rand'], c['rand2']

    shade, lip = _row_light(b, fv, top=0.90, grad_to=0.62, lip=0.05)
    # 竖缝：木瓦是拼铺的，缝很细、且**大部分看不见**（等强就成小方格/编织垫）
    du = b.mul(b.mn(fu, b.sub(1.0, fu)), cw)
    seam_col = b.sub(1.0, b.ss(du, uv_cm(0.25), uv_cm(1.0)))
    seam_col = b.mul(seam_col, b.lin(r2, 0.55, 0.78, 0.0, 1.0))

    # 顺纹木理（木瓦是径向劈的 → 纹路沿着长度方向 = V）
    grain = b.noise(b.vec(b.mul(u, 12.0), b.mul(v, 1.6), 7.0), 1.0, 6.0, 0.55)
    grain2 = b.noise(b.vec(b.mul(u, 26.0), b.mul(v, 0.8), 13.0), 1.0, 4.0)
    g = b.mixf(0.5, grain, grain2)

    base = b.mixc(r1, (0.105, 0.056, 0.028), (0.300, 0.178, 0.086))
    base = b.mixc(b.lin(r2, 0.80, 0.98, 0.0, 0.55), base, (0.082, 0.060, 0.040))
    base = b.mixc(b.lin(r2, 0.0, 0.16, 0.0, 0.40), base, (0.395, 0.245, 0.115))
    base = b.mul_c(base, b.lin(g, 0.25, 0.78, 0.76, 1.16))
    base = b.shade(base, lip, 1.0, 1.22)
    col = b.mixc(shade, b.mul_c(base, 0.24), base)
    col = b.mixc(b.mul(seam_col, 0.30), col, b.mul_c(base, 0.42))
    # 缝里积的苔/腐
    moss = b.noise(b.vec(b.mul(u, 4.5), b.mul(v, 4.5), 63.0), 1.0, 5.0, 0.6)
    col = b.mixc(b.mul(b.mul(b.ss(moss, 0.52, 0.72), b.mul(shade, 0.8)),
                       b.mul(wear, 0.55)), col, (0.145, 0.155, 0.072))
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 2.6), b.mul(v, 2.6), 71.0), 1.0, 5.0),
                            0.55, 0.82), b.mul(wear, 0.35)), col, (0.150, 0.115, 0.075))

    # 逐片批次色差（第三维随机：阴阳面/不同批的木瓦冷暖不同，0.45 以内）
    col = b.mixc(b.lin(c['rand3'], 0.0, 1.0, 0.0, 0.45),
                 col, b.mixc(r1, b.mul_c(col, 1.10), b.mul_c(col, 0.84)))

    h = b.add(b.mul(lip, 0.95), b.mul(shade, 1.10))
    h = b.sub(h, b.mul(seam_col, 0.30))
    h = b.add(h, b.mul(b.sub(g, 0.5), 0.30))
    col = _aged(b, u, v, col, 'shingle')
    return dict(color=col,
                rough=b.add(b.lin(r1, 0.0, 1.0, 0.74, 0.90), b.mul(g, 0.03)),
                normal=b.bump(h, 0.80, uv_cm(2.2)), spec=0.28)


# ============================================================ 木料（横板 / 木骨）
def _wood(b, gi, u, v, board_h, pal, joint_w=None, knot_amt=1.0, camber=0.0,
          cracks=0.0, grain_len=1.0):
    """共用木料层：横板 + 板缝 + 顺板木纹 + 木节 + 板下沿投影。返回 (color, h, rough)。

    * `board_h` 板高按现实换算（木板墙 20 cm → uv_cm(20)）。
    * `grain_len` 木纹沿 U 的拉长倍率（大构件用大值）。
    """
    wear = gi.outputs['Wear']
    jw = joint_w if joint_w is not None else uv_cm(1.2)
    _sv, row, fv, rr1, rr2 = _rows(b, v, board_h)
    dv = b.mul(b.mn(fv, b.sub(1.0, fv)), board_h)
    joint = b.sub(1.0, b.ss(dv, uv_cm(0.15), jw))            # 1 = 板缝里

    # 木纹：沿 U 拉长 + 低频扭曲（年轮感）
    yw = b.noise(b.vec(b.mul(u, 2.0), b.mul(v, 3.0), 7.0), 1.0, 4.0)
    grain = b.noise(b.vec(b.mul(u, 1.2 / max(grain_len, 0.05)),
                          b.add(b.mul(v, 11.0), b.mul(yw, 6.0)), 3.0), 1.0, 7.0, 0.62)
    grain2 = b.noise(b.vec(b.mul(u, 0.5), b.mul(v, 30.0), 13.0), 1.0, 5.0)
    g = b.mixf(0.55, grain, grain2)

    col = b.ramp(g, [(0.22, pal['dark']), (0.52, pal['mid']), (0.80, pal['light'])])
    col = b.mixc(rr1, b.mul_c(col, pal['board_lo']), b.mul_c(col, pal['board_hi']))
    if 'board_hi2' in pal:
        col = b.mixc(b.sub(1.0, b.lin(rr2, 0.42, 0.58, 0.0, 1.0)), col,
                     b.mul_c(col, pal['board_hi2']))

    # 木节：稀疏深色小圆点（Voronoi 距离门控 + 单元门）
    kd, _kc, _kp = b.voro(b.vec(b.mul(u, 2.6), b.mul(v, 2.6), 23.0), scale=1.0, randomness=1.0)
    gate = b.mr(b.h2(b.flr(b.mul(u, 2.6)), b.flr(b.mul(v, 2.6)), 23.0), 0.78, 0.88, 0.0, 1.0)
    knot = b.mul(b.sub(1.0, b.ss(kd, 0.06, 0.22)), b.mul(gate, knot_amt))
    col = b.mixc(knot, col, pal['knot'])

    # 干裂（木骨/老木明显）：顺 U 的细黑线
    crk = None
    if cracks:
        cr = b.noise(b.vec(b.mul(u, 0.5), b.mul(v, 40.0), 51.0), 1.0, 3.0)
        crk = b.mul(b.sub(1.0, b.ss(b.absv(b.sub(cr, 0.5)), 0.0, 0.02)),
                    b.mul(b.sub(1.0, joint), b.mul(cracks, b.lin(wear, 0.15, 0.9, 0.35, 1.0))))
        col = b.mixc(crk, col, (0.055, 0.028, 0.015))

    # 板缝阴影 + 板下沿投影（板顶棱受光）
    edge_shadow = b.lin(fv, 0.0, 0.42, 0.58, 1.02)
    top_hi = b.ss(fv, 0.84, 1.0)
    col = b.mixc(joint, col, (0.055, 0.028, 0.014))
    col = b.shade(col, edge_shadow, 0.60, 1.0)
    col = b.shade(col, top_hi, 1.0, 1.16)

    h = b.sub(1.0, joint)
    h = b.add(h, b.mul(b.sub(0.5, b.absv(b.sub(fv, 0.32))), 0.25))
    h = b.sub(h, b.mul(knot, 0.5))
    if camber:
        h = b.add(h, b.mul(b.pisin(fv), camber))
    h = b.add(h, b.mul(b.sub(g, 0.5), 0.30))
    if crk is not None:
        h = b.sub(h, b.mul(crk, 0.6))
    rough = b.lin(g, 0.0, 1.0, pal['rough'][0], pal['rough'][1])
    return col, h, rough


def _b_plank_wall(b, gi, bsdf):
    """横向木板墙：板高 20 cm，板缝清晰，木纹顺板长，饱和暖棕（绝不发灰白）。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    pal = dict(dark=(0.048, 0.020, 0.008), mid=(0.190, 0.078, 0.030),
               light=(0.360, 0.158, 0.062),
               board_lo=(0.80, 0.80, 0.80), board_hi=(1.12, 1.08, 1.03),
               board_hi2=(1.34, 1.16, 0.98),
               knot=(0.095, 0.042, 0.018), rough=(0.70, 0.86))
    col, h, rough = _wood(b, gi, u, v, uv_cm(20.0), pal, joint_w=uv_cm(1.4),
                          knot_amt=1.0, cracks=0.35, grain_len=1.0)
    dirt = b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 1.1), 71.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(dirt, 0.52, 0.82), b.mul(wear, 0.40)), col, (0.105, 0.052, 0.024))
    col = _aged(b, u, v, col, 'plank_wall')
    return dict(color=col, rough=rough, normal=b.bump(h, 0.80, uv_cm(2.0)), spec=0.33)


def _b_timber(b, gi, bsdf):
    """深色木骨/手斧梁：大尺度斧劈棱面 + 顺梁长纤维 + 纵向干裂。

    木骨构件在游戏尺寸下只有 8~20 px 宽，木纹本身看不清 —— 靠**斧劈棱面**
    （几个大平面各自的明暗差）才能读出"一根方木"。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    pal = dict(dark=(0.034, 0.016, 0.007), mid=(0.130, 0.062, 0.026),
               light=(0.250, 0.132, 0.056),
               board_lo=(0.86, 0.86, 0.86), board_hi=(1.14, 1.10, 1.05),
               board_hi2=(1.22, 1.05, 0.94),
               knot=(0.030, 0.014, 0.007), rough=(0.76, 0.90))
    col, h, rough = _wood(b, gi, u, v, uv_cm(80.0), pal, joint_w=uv_cm(2.0),
                          knot_amt=0.5, camber=0.40, cracks=1.0, grain_len=3.0)
    # 斧劈棱面（11 cm 面，逐面明暗差 → 读得出方木的棱）
    hd, hc, _hp = b.voro(b.vec(b.mul(u, 1.0 / uv_cm(11.0)), b.mul(v, 1.0 / uv_cm(11.0)), 3.0),
                         scale=1.0, randomness=0.85)
    r1, _r2, _r3 = b.sep_c(hc)
    col = b.shade(col, r1, 0.62, 1.44)
    # 斧痕（顺梁的长向浅棱，沿 U 或 V 各一半 → 竖梁横梁都成立）
    ax = b.noise(b.vec(b.mul(u, 1.4), b.mul(v, 0.5), 101.0), 1.0, 3.0)
    ax2 = b.noise(b.vec(b.mul(u, 0.5), b.mul(v, 1.4), 103.0), 1.0, 3.0)
    col = b.mul_c(col, b.lin(b.mixf(0.5, ax, ax2), 0.30, 0.72, 0.84, 1.16))
    h = b.add(h, b.mul(b.sub(r1, 0.5), 0.90))
    _ = hd
    col = _aged(b, u, v, col, 'timber')
    return dict(color=col, rough=rough, normal=b.bump(h, 0.85, uv_cm(2.4)), spec=0.30)


# ============================================================ 抹灰
def _b_plaster(b, gi, bsdf):
    """暖白石灰浆抹灰：**只做明度微差，禁止锈褐色斑**；剥落成"片状露底灰"。

    旧版两宗罪：① 底色偏灰白（0.80,0.75,0.62 在冷环境光下读成脏灰）；
    ② 剥落斑用锈褐 substrate + 随机阈值 → 低 wear 也满墙随机褐点。
    新版：底色暖米白；mottling 走明度不走色相；剥落 = 低频 2 尺度阈值合成的
    连片区域（片状、有边缘棱、有深度），底层是**中性灰浆**（不发褐）。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)

    base = (0.700, 0.645, 0.498)          # 暖米白（略偏黄，别偏灰；G/B 拉开防冷光下发灰）
    # 抹刀痕：低频 + 沿 U 拉长的刀弧（只做明度）
    trowel = b.noise(b.vec(b.mul(u, 0.9), b.mul(v, 2.6), 3.0), 1.0, 4.0, 0.6)
    arc = b.noise(b.vec(b.mul(u, 0.55), b.mul(v, 4.5), 17.0), 1.0, 3.0, 0.75)
    paddle = b.mixf(0.45, trowel, arc)
    col = b.mul_c(base, b.lin(paddle, 0.22, 0.82, 0.842, 1.150))

    # 砂粒（2~3 px，太细在 76 px/m 下看不见）
    grain = b.noise(b.vec(b.mul(u, 13.0), b.mul(v, 13.0), 5.0), 1.0, 3.0, 0.6)
    col = b.mul_c(col, b.lin(grain, 0.22, 0.78, 0.905, 1.095))
    # 抹刀压光的斜向拉丝（灰浆活儿的"光带"）
    trow = b.noise(b.vec(b.mul(u, 1.6), b.mul(v, 7.0), 19.0), 1.0, 4.0, 0.6)
    col = b.mul_c(col, b.lin(trow, 0.30, 0.78, 0.912, 1.105))
    # 灰浆的厚薄斑（5~15cm 的明度起伏：真实石灰墙靠这个"活"起来；也是治"灰白平淡"的主力）
    blob = b.noise(b.vec(b.mul(u, 3.4), b.mul(v, 3.4), 23.0), 1.0, 5.0, 0.55)
    col = b.mul_c(col, b.lin(blob, 0.25, 0.75, 0.888, 1.132))

    # 剥落：片状（低频大斑 + 中频边界参差），露中性灰浆底
    sp1 = b.noise(b.vec(b.mul(u, 0.65), b.mul(v, 0.65), 23.0), 1.0, 5.0, 0.6)
    sp2 = b.noise(b.vec(b.mul(u, 3.0), b.mul(v, 3.0), 29.0), 1.0, 4.0)
    sp = b.mixf(0.25, sp1, sp2)
    thr = b.lin(wear, 0.0, 1.0, 0.735, 0.600)
    mask = b.ss(sp, thr, b.add(thr, 0.045))
    rim = b.mul(b.ss(sp, b.sub(thr, 0.030), thr),
                b.sub(1.0, b.ss(sp, thr, b.add(thr, 0.022))))
    sub_tex = b.noise(b.vec(b.mul(u, 3.4), b.mul(v, 3.4), 41.0), 1.0, 4.0)
    substrate = b.mul_c((0.400, 0.378, 0.345), b.lin(sub_tex, 0.25, 0.75, 0.78, 1.20))
    col = b.mixc(mask, col, substrate)
    col = b.mixc(b.mul(rim, 0.9), col, (0.760, 0.735, 0.665))   # 剥落边缘露白（石灰茬）
    col = b.mul_c(col, b.lin(mask, 0.0, 1.0, 1.0, 0.90))

    # 细裂（竖向拉长，2 px 宽）
    cr = b.noise(b.vec(b.mul(u, 1.8), b.mul(v, 9.0), 37.0), 1.0, 4.0, 0.4)
    crack = b.mul(b.sub(1.0, b.ss(b.absv(b.sub(cr, 0.5)), 0.0, 0.010)),
                  b.mul(b.sub(1.0, mask), b.lin(wear, 0.0, 1.0, 0.20, 0.85)))
    col = b.mixc(crack, col, (0.330, 0.310, 0.280))

    # 泛潮：**只压明度，不换色相**（这是"禁褐斑"的纪律）
    damp = b.noise(b.vec(b.mul(u, 1.6), b.mul(v, 1.6), 53.0), 1.0, 4.0, 0.5)
    col = b.mul_c(col, b.lin(b.mul(b.ss(damp, 0.55, 0.85), b.mul(wear, 0.45)),
                             0.0, 1.0, 1.0, 0.86))

    h = b.add(0.75, b.mul(b.sub(paddle, 0.5), 0.42))
    h = b.add(h, b.mul(b.sub(grain, 0.5), 0.30))
    h = b.sub(h, b.mul(mask, 0.70))
    h = b.add(h, b.mul(rim, 0.30))
    h = b.sub(h, b.mul(crack, 0.35))
    rough = b.lin(paddle, 0.0, 1.0, 0.86, 0.95)
    rough = b.add(rough, b.mul(grain, 0.03))
    # 做旧层：墙脚溅泥/苔（世界 Z 0~35cm，随高度衰减）+ 垂直雨渍 + 逐体色偏 ±4%
    col = _aged(b, u, v, col, 'plaster')
    return dict(color=col, rough=rough, normal=b.bump(h, 0.50, uv_cm(3.0)), spec=0.26)


# ============================================================ 石砌
def _b_masonry(b, gi, cfg):
    """石砌通用：**大块料石 + 深砂浆缝 + 上缘受光/下缘暗的倒角读法**。

    石砌的读法靠三件事：
      1) 矩形料石 + 错缝 + 缝位逐块抖动 → 不规则但边是直的；
      2) 逐块明暗/冷暖差（整数格哈希，可靠、确定性）；
      3) 缝要**深**：缝内 AO + 缝底比石面暗得多 + 上缘一圈受光倒角。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    cw, ch, jw = cfg['cw'], cfg['ch'], cfg['jw']
    c = _cells(b, u, v, cw, ch, stagger=0.5, seed=cfg['seed'], jitter=cfg['jitter'])
    fu, fv, r1, r2, r3, d = c['fu'], c['fv'], c['rand'], c['rand2'], c['rand3'], c['d']

    face = b.ss(d, b.mul(jw, 0.30), jw)                  # 1 = 石面
    seam = b.sub(1.0, face)
    # 倒角：**上缘微弱受光 / 下缘暗**（4 边等强会读成"瓷砖"，过强会读成"条纹纸"）
    top_hi = b.ss(fv, 0.86, 0.99)
    bot_dk = b.sub(1.0, b.ss(fv, 0.05, 0.22))

    mott = b.noise(b.vec(b.mul(u, 5.0), b.mul(v, 5.0), 7.0), 1.0, 6.0, 0.6)
    col = b.mixc(r1, cfg['lo'], cfg['hi'])
    col = b.mixc(b.lin(r2, 0.78, 0.98, 0.0, 0.58), col, b.mul_c(col, 0.66))   # 深石
    col = b.mixc(b.lin(r3, 0.0, 0.38, 0.0, cfg.get('warm_hi', 0.60)), col, cfg['warm'])  # 暖石
    col = b.mixc(b.lin(mott, 0.28, 0.78, 0.0, 0.45), col, b.mul_c(col, 0.78))  # 石面斑驳
    col = b.shade(col, top_hi, 1.0, cfg['top_light'])
    col = b.shade(col, bot_dk, cfg['bot_dark'], 1.0)
    # 砂浆缝（缝底深、缝内 AO）
    mort = b.mixc(b.noise(b.vec(b.mul(u, 12.0), b.mul(v, 12.0), 11.0), 1.0, 4.0),
                  b.mul_c(cfg['mortar'], 0.72), cfg['mortar'])
    col = b.mixc(face, mort, col)
    col = b.mixc(b.mul(seam, 0.85), b.mul_c(col, cfg['ao']), col)
    # 风化脏斑（压明度）
    wea = b.noise(b.vec(b.mul(u, 1.8), b.mul(v, 2.2), 29.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(wea, 0.50, 0.80), b.lin(wear, 0.0, 1.0, 0.12, 0.55)),
                 col, b.mul_c(col, 0.66))
    # 缝内苔藓
    if cfg['moss'] > 0.0:
        moss = b.noise(b.vec(b.mul(u, 4.0), b.mul(v, 4.0), 43.0), 1.0, 5.0, 0.6)
        col = b.mixc(b.mul(b.mul(b.ss(moss, 0.46, 0.68), b.pow(seam, 0.6)),
                           b.mul(wear, cfg['moss'])), col, (0.180, 0.215, 0.100))
    grn = b.noise(b.vec(b.mul(u, 16.0), b.mul(v, 16.0), 3.0), 1.0, 4.0)    # 2px 石面颗粒
    col = b.mul_c(col, b.lin(grn, 0.25, 0.75, 0.95, 1.05))

    h = b.add(b.mul(face, b.lin(r1, 0.0, 1.0, 0.72, 1.0)),
              b.mul(b.sub(mott, 0.5), 0.16))
    h = b.add(h, b.mul(top_hi, 0.22))
    h = b.sub(h, b.mul(bot_dk, 0.16))
    h = b.sub(h, b.mul(seam, 1.30))
    h = b.add(h, b.mul(b.sub(grn, 0.5), 0.10))
    rough = b.add(b.lin(mott, 0.0, 1.0, 0.78, 0.93), b.mul(seam, 0.04))
    # 做旧层：墙脚溅泥/苔 + 垂直雨渍 + 逐体色偏（石砌类的"死灰"靠这一层活起来）
    col = _aged(b, u, v, col, cfg.get('age', 'stone'))
    return dict(color=col, rough=rough, normal=b.bump(h, 0.85, uv_cm(3.2)), spec=0.24)


def _b_stone(b, gi, bsdf):
    """粗料石：块长 45~70 cm、层高 28 cm、缝 2.6 cm（大块 + 深缝 + 上缘受光倒角）。"""
    return _b_masonry(b, gi, dict(
        cw=uv_cm(56.0), ch=uv_cm(28.0), jw=uv_cm(2.6), jitter=0.52, seed=1.0,
        lo=(0.175, 0.167, 0.150), hi=(0.492, 0.470, 0.428),
        warm=(0.432, 0.338, 0.228), mortar=(0.078, 0.073, 0.066),
        top_light=1.16, bot_dark=0.78, ao=0.50, moss=0.55, age='stone', warm_hi=0.68))

def _b_white_stone(b, gi, bsdf):
    """白石细料（线脚/雕饰/首府立面）：块长 30~45 cm、层高 16 cm、缝 1.6 cm，暖奶油色。"""
    return _b_masonry(b, gi, dict(
        cw=uv_cm(38.0), ch=uv_cm(16.0), jw=uv_cm(1.6), jitter=0.30, seed=11.0,
        lo=(0.408, 0.383, 0.330), hi=(0.800, 0.762, 0.668),
        warm=(0.712, 0.612, 0.458), mortar=(0.256, 0.245, 0.220),
        top_light=1.12, bot_dark=0.82, ao=0.66, moss=0.10, age='white_stone'))


# ============================================================ 红砖
def _b_brick(b, gi, bsdf):
    """暖橙红砖：砖 23x8 cm、缝 1.6 cm 错缝，逐块色差（橙红/砖红/土黄/焦黑），
    边缘磕蚀 + 砖面 2~3 px 颗粒，灰浆缝**浅灰**（浅缝才能把红砖衬出来）。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    cw, ch = uv_cm(23.0), uv_cm(8.0)
    c = _cells(b, u, v, cw, ch, stagger=0.5, seed=3.0)
    fu, fv, r1, r2, d = c['fu'], c['fv'], c['rand'], c['rand2'], c['d']

    bricky = b.ss(d, uv_cm(0.25), uv_cm(1.1))
    erode_n = b.noise(b.vec(b.mul(u, 11.0), b.mul(v, 24.0), 1.0), 1.0, 4.0, 0.5)
    edge_prox = b.sub(1.0, b.ss(d, uv_cm(0.3), uv_cm(2.6)))
    erode = b.mul(edge_prox, b.lin(erode_n, 0.38, 0.62, 0.0, 1.0))
    corner = b.mx(b.absv(b.sub(fu, 0.5)), b.absv(b.sub(fv, 0.5)))
    chip_amt = b.mr(r2, b.sub(0.80, b.mul(wear, 0.24)), 0.97, 0.0, 1.0)
    chip = b.mul(chip_amt, b.ss(corner, 0.37, 0.49))
    face = b.mul(bricky, b.sub(1.0, b.mx(b.mul(erode, 0.75), b.mul(chip, 0.9))))

    grain = b.noise(b.vec(b.mul(u, 12.0), b.mul(v, 24.0), 13.0), 1.0, 5.0, 0.6)
    col = b.mixc(r1, (0.272, 0.070, 0.030), (0.622, 0.186, 0.058))
    col = b.mixc(b.lin(r2, 0.66, 0.88, 0.0, 0.55), col, (0.438, 0.208, 0.068))
    col = b.mixc(b.lin(r2, 0.90, 0.97, 0.0, 0.65), col, (0.088, 0.046, 0.034))
    col = b.mul_c(col, b.lin(r1, 0.0, 1.0, 0.74, 1.16))
    col = b.mixc(b.lin(grain, 0.28, 0.75, 0.0, 0.50), col, b.mul_c(col, 0.74))
    # 灰浆缝：浅灰（衬红砖）
    mort = b.mixc(grain, (0.230, 0.216, 0.196), (0.360, 0.342, 0.312))
    col = b.mixc(face, mort, col)
    col = b.shade(col, bricky, 0.55, 1.0)                 # 缝内 AO
    soot = b.noise(b.vec(b.mul(u, 2.4), b.mul(v, 2.4), 19.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(soot, 0.44, 0.78), b.lin(wear, 0.0, 1.0, 0.18, 0.70)),
                 col, (0.110, 0.082, 0.070))
    salt = b.noise(b.vec(b.mul(u, 5.0), b.mul(v, 5.0), 67.0), 1.0, 5.0)
    col = b.mixc(b.mul(b.mul(b.ss(salt, 0.62, 0.82),
                             b.add(b.mul(face, 0.30), b.mul(bricky, 0.20))),
                       b.mul(wear, 0.60)), col, (0.480, 0.455, 0.420))

    h = b.add(b.mul(face, 1.0), b.mul(r1, 0.20))
    h = b.add(h, b.mul(b.sub(grain, 0.5), 0.30))
    h = b.sub(h, b.mul(b.mul(erode, 0.6), 0.5))
    h = b.sub(h, b.mul(chip, 0.4))
    rough = b.add(b.lin(r1, 0.0, 1.0, 0.74, 0.90), b.mul(b.sub(grain, 0.5), 0.08))
    col = _aged(b, u, v, col, 'brick')
    return dict(color=col, rough=rough, normal=b.bump(h, 0.80, uv_cm(2.4)), spec=0.30)


# ============================================================ 锻铁
def _b_iron(b, gi, bsdf):
    """深色锻铁：**近均匀的暗基底 + 低粗糙度 + 锤打棱面（大而柔和）+ 少量氧化斑**。

    旧版读成"水泥砾石"的原因：基底色差过大（逐面 0.72~1.35）+ 高频坑点 +
    粗糙度偏高 → 金属的高光被噪点打散。金属感来自"低粗糙度 + 平滑的大棱面反光"，
    不是来自细节噪点。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    base = (0.078, 0.080, 0.090)          # 深灰蓝锻铁（不是纯黑：纯黑在 2D 立绘里读成"洞"）

    # 锤打棱面：9 cm 一块，逐块一个小角度的面（明度差小、边界柔和）
    fd, fc, _fp = b.voro(b.vec(b.div(u, uv_cm(9.0)), b.div(v, uv_cm(9.0)), 3.0),
                         scale=1.0, randomness=0.85)
    fr, fg, fb = b.sep_c(fc)
    facet = b.lin(fd, 0.05, 0.75, 0.0, 1.0)
    col = b.mixc(b.mul(fr, 0.65), b.mul_c(base, 0.82), b.mul_c(base, 1.34))
    col = b.mixc(b.mul(fg, 0.35), col, b.mul_c(col, 1.14))
    # 锤痕（棱面上的浅凹，2~3 cm）
    mic = b.noise(b.vec(b.mul(u, 26.0), b.mul(v, 26.0), 11.0), 1.0, 4.0, 0.55)
    col = b.mul_c(col, b.lin(mic, 0.25, 0.75, 0.92, 1.12))

    # 氧化：只在缝/边角少量（保持金属主体干净）
    ox = b.noise(b.vec(b.mul(u, 2.2), b.mul(v, 2.6), 23.0), 1.0, 5.0, 0.55)
    ox_m = b.mul(b.ss(ox, 0.58, 0.76), b.lin(wear, 0.0, 1.0, 0.10, 0.75))
    col = b.mixc(ox_m, col, (0.185, 0.082, 0.038))
    met = b.mixf(ox_m, 0.95, 0.35)
    rough = b.mixf(ox_m, b.add(b.lin(facet, 0.0, 1.0, 0.26, 0.40),
                               b.mul(b.sub(mic, 0.5), 0.06)), 0.82)

    h = b.add(b.mul(facet, 0.35), b.mul(fb, 0.05))
    h = b.add(h, b.mul(b.sub(mic, 0.5), 0.22))
    return dict(color=col, rough=rough, metal=met,
                normal=b.bump(h, 0.45, uv_cm(2.0)), spec=0.55)


# ============================================================ 原木墙
def _b_log_wall(b, gi, bsdf):
    """原木横叠墙：圆木径 26 cm —— 长向弧面（缝间压暗 + 中央受光）+ 顺纹 + 节子 + 缝内填泥。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    d = uv_cm(26.0)
    sv, row, fv, rr1, rr2 = _rows(b, v, d)
    prof = b.pow(b.pisin(fv), 0.65)                # 0 缝 / 1 木心（圆木剖面）
    seam = b.sub(1.0, prof)

    # 顺纹（沿 U 的长木纹）+ 节子
    grain = b.noise(b.vec(b.mul(u, 0.9), b.mul(v, 26.0), 7.0), 1.0, 6.0, 0.6)
    grain2 = b.noise(b.vec(b.mul(u, 0.4), b.mul(v, 52.0), 19.0), 1.0, 4.0)
    g = b.mixf(0.5, grain, grain2)
    kd, _kc, _kp = b.voro(b.vec(b.mul(u, 1.4), b.mul(v, 1.4), 31.0), scale=1.0, randomness=1.0)
    gate = b.mr(b.h2(b.flr(b.mul(u, 1.4)), b.flr(b.mul(v, 1.4)), 31.0), 0.80, 0.90, 0.0, 1.0)
    knot = b.mul(b.sub(1.0, b.ss(kd, 0.05, 0.20)), gate)

    col = b.ramp(g, [(0.24, (0.088, 0.036, 0.011)), (0.52, (0.272, 0.120, 0.034)),
                     (0.82, (0.478, 0.240, 0.078))])
    col = b.mixc(rr1, b.mul_c(col, 0.84), b.mul_c(col, 1.12))       # 逐根色差
    col = b.mixc(rr2, col, b.mul_c(col, 0.90))
    col = b.shade(col, prof, 0.55, 1.12)                            # 圆木弧面明暗
    col = b.mixc(knot, col, (0.048, 0.022, 0.009))
    col = b.mixc(b.mul(seam, 0.80), b.mul_c(col, 0.30), col)        # 缝间深阴影
    # 缝内填泥/苔（原木墙的"chinking"）—— 泥色偏暖、覆盖收窄（旧版又宽又偏橄榄绿，
    # 整面墙会被读成"发绿的木板"，而不是"暖棕原木 + 浅色填泥"）
    mud = b.noise(b.vec(b.mul(u, 7.0), b.mul(v, 7.0), 47.0), 1.0, 4.0)
    col = b.mixc(b.mul(seam, 0.62), b.mixc(mud, (0.218, 0.176, 0.118), (0.180, 0.162, 0.090)), col)
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 2.2), b.mul(v, 2.2), 59.0), 1.0, 5.0),
                            0.58, 0.84), b.mul(wear, 0.35)), col, b.mul_c(col, 0.72))

    h = b.add(b.mul(prof, 0.95), b.mul(b.sub(g, 0.5), 0.30))
    h = b.sub(h, b.mul(seam, 1.10))
    h = b.sub(h, b.mul(knot, 0.5))
    rough = b.lin(g, 0.0, 1.0, 0.78, 0.92)
    col = _aged(b, u, v, col, 'log_wall')
    return dict(color=col, rough=rough, normal=b.bump(h, 0.85, uv_cm(4.0)), spec=0.28)


# ============================================================ 编条篱 / 泥笆
def _b_wattle(b, gi, bsdf):
    """编条篱（wattle & daub）：细木条立桩 + 横编条压一挑一 + 泥填缝。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    sw, wh = uv_cm(2.8), uv_cm(9.0)

    ss_ = b.div(u, sw)
    si = b.flr(ss_)
    fu = b.sub(ss_, si)
    stake = b.pow(b.pisin(fu), 0.45)                  # 立桩（竖直细木条）
    ws = b.div(v, wh)
    wi = b.flr(ws)
    fv = b.sub(ws, wi)
    withy = b.pow(b.pisin(fv), 0.5)                   # 横编条
    over = b.step(b.frc(b.mul(b.add(si, wi), 0.5)), 0.5)   # 压一挑一

    srand = b.h1(si, 13.0)
    wrand = b.h1(wi, 29.0)
    g = b.noise(b.vec(b.mul(u, 15.0), b.mul(v, 15.0), 5.0), 1.0, 5.0, 0.5)

    # 泥底（暗、微暖、斑驳）
    daub = b.mixc(b.noise(b.vec(b.mul(u, 2.4), b.mul(v, 2.4), 41.0), 1.0, 5.0, 0.6),
                  (0.128, 0.092, 0.055), (0.225, 0.170, 0.108))
    col = daub
    stake_c = b.mixc(srand, (0.160, 0.105, 0.048), (0.310, 0.205, 0.098))
    withy_c = b.mixc(wrand, (0.225, 0.155, 0.066), (0.390, 0.272, 0.130))
    stake_c = b.mul_c(stake_c, b.lin(g, 0.25, 0.75, 0.80, 1.15))
    withy_c = b.mul_c(withy_c, b.lin(g, 0.25, 0.75, 0.82, 1.18))
    col = b.mixc(stake, col, stake_c)
    col = b.mixc(b.mul(withy, over), col, withy_c)                    # 编条在前
    col = b.mixc(b.mul(withy, b.mul(b.sub(1.0, over), 0.55)), col,
                 b.mul_c(withy_c, 0.55))                              # 编条在后（压暗）

    h = b.add(b.mul(stake, 0.55), b.mul(b.sub(withy, 0.0), 0.0))
    h = b.add(h, b.mul(b.mul(withy, over), 0.75))
    h = b.add(h, b.mul(b.sub(g, 0.5), 0.30))
    rough = b.lin(g, 0.0, 1.0, 0.86, 0.95)
    col = _aged(b, u, v, col, 'wattle')
    return dict(color=col, rough=rough, normal=b.bump(h, 0.85, uv_cm(2.4)), spec=0.18)


# ============================================================ 麻布 / 麻袋
def _weave(b, u, v, cell, pal, over_scale=1.0):
    """平纹织物的"压一挑一"：返回 (col, h)。cell = 织格边长（UV）。"""
    su = b.div(u, cell)
    sv = b.div(v, cell)
    iu = b.flr(su)
    iv = b.flr(sv)
    fu = b.sub(su, iu)
    fv = b.sub(sv, iv)
    warp = b.pow(b.pisin(fu), 0.5)          # 竖线（沿 V 走）
    weft = b.pow(b.pisin(fv), 0.5)          # 横线（沿 U 走）
    over = b.step(b.frc(b.mul(b.add(iu, iv), 0.5)), 0.5)     # 谁在上
    tr = b.h2(iu, iv, 3.0)
    tr2 = b.h2(iu, iv, 19.0)
    slub = b.noise(b.vec(b.mul(u, 9.0), b.mul(v, 9.0), 5.0), 1.0, 5.0, 0.6)
    col = b.mixc(b.mixf(0.5, tr, slub), pal['dark'], pal['mid'])
    col = b.mixc(b.mul(tr2, 0.7), col, pal['hi'])
    top = b.mixf(over, warp, weft)
    col = b.shade(col, top, 0.52, 1.16)
    h = b.mul(top, 1.0)
    h = b.add(h, b.mul(b.sub(slub, 0.5), 0.35))
    return col, h, slub, tr


def _b_canvas(b, gi, bsdf):
    """麻布（棚布/旗帜）：天然亚麻色，织纹 2.4 cm 织格（游戏尺寸下 1.8 px，
    只留"粗布感"；靠**粗节 + 明暗跳变**读出布）。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    pal = dict(dark=(0.255, 0.212, 0.140), mid=(0.545, 0.482, 0.352),
               hi=(0.760, 0.700, 0.545))
    col, h, slub, tr = _weave(b, u, v, uv_cm(2.4), pal)
    dirt = b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 3.2), 31.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(dirt, 0.5, 0.8), b.mul(wear, 0.45)), col, (0.330, 0.278, 0.190))
    col = b.mixc(b.mul(b.sub(1.0, b.pisin(b.frc(b.mul(v, 0.5)))), 0.10), col, b.mul_c(col, 0.86))
    _ = tr
    return dict(color=col, rough=0.94, normal=b.bump(h, 0.95, uv_cm(1.2)),
                spec=0.12, sheen=0.22, sheen_rough=0.55)


def _b_sack(b, gi, bsdf):
    """粗麻布（麻袋）：织格 3.4 cm 的粗黄麻，比 canvas 更粗更黄、脱线起毛。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    pal = dict(dark=(0.175, 0.128, 0.058), mid=(0.430, 0.352, 0.170),
               hi=(0.690, 0.585, 0.320))
    col, h, slub, tr = _weave(b, u, v, uv_cm(3.4), pal)
    fuzzy = b.noise(b.vec(b.mul(u, 30.0), b.mul(v, 30.0), 11.0), 1.0, 4.0)
    col = b.mul_c(col, b.lin(fuzzy, 0.25, 0.75, 0.86, 1.12))          # 起毛
    col = b.mixc(b.mul(b.lin(tr, 0.0, 1.0, 0.62, 1.0), 0.25), col, b.mul_c(col, 0.70))
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 2.2), b.mul(v, 2.2), 71.0), 1.0, 5.0),
                            0.52, 0.82), b.mul(wear, 0.45)), col, (0.185, 0.140, 0.075))
    return dict(color=col, rough=0.96, normal=b.bump(h, 1.0, uv_cm(1.6)),
                spec=0.10, sheen=0.30, sheen_rough=0.6)


# ============================================================ 麻绳
def _b_rope(b, gi, bsdf):
    """麻绳：三股螺旋捻 —— 斜向捻纹 + 股沟 + 纤维毛刺（斜 45° 放，竖绳横绳都成立）。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    pitch = uv_cm(3.6)
    t = b.div(b.add(u, v), pitch)                     # 沿 45° 的螺旋参数
    grp = b.frc(b.div(t, 3.0))                        # 三股分组
    strand = b.pow(b.pisin(grp), 0.5)                 # 股的截面
    fine = b.pisin(b.mul(t, 6.0))                     # 纤维捻线
    fib = b.noise(b.vec(b.mul(u, 40.0), b.mul(v, 40.0), 7.0), 1.0, 4.0)

    col = b.mixc(strand, (0.115, 0.078, 0.036), (0.400, 0.300, 0.150))
    col = b.mixc(b.mul(fine, 0.35), col, b.mul_c(col, 1.20))
    col = b.mul_c(col, b.lin(fib, 0.25, 0.75, 0.84, 1.14))
    col = b.mixc(b.sub(1.0, b.pisin(grp)), b.mul_c(col, 0.42), col)     # 股沟
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 2.0), b.mul(v, 2.0), 23.0), 1.0, 5.0),
                            0.58, 0.84), b.mul(wear, 0.35)), col, (0.245, 0.190, 0.100))
    h = b.add(b.mul(strand, 0.85), b.mul(b.mul(fine, 0.5), 0.30))
    h = b.add(h, b.mul(b.sub(fib, 0.5), 0.40))
    return dict(color=col, rough=0.92, normal=b.bump(h, 0.95, uv_cm(1.4)),
                spec=0.14, sheen=0.25, sheen_rough=0.6)


# ============================================================ 玻璃 / 水 / 暗腔 / 灯
def _b_glass_win(b, gi, bsdf):
    """窗玻璃：深色但有微弱反射（不是纯黑板）。

    深色 + roughness 0.06 → EEVEE 的射线追踪会把天空/环境反射上去，
    于是窗格里有一层冷色微光，"玻璃"才成立；纯黑平板读起来像贴片。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    base = (0.030, 0.038, 0.046)
    mott = b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 3.2), 13.0), 1.0, 5.0, 0.6)
    col = b.mixc(b.lin(mott, 0.30, 0.80, 0.0, 0.55), base, b.mul_c(base, 1.9))
    streak = b.noise(b.vec(b.mul(u, 2.0), b.mul(v, 0.8), 29.0), 1.0, 4.0)   # 斜流痕（脏玻璃）
    col = b.mul_c(col, b.lin(streak, 0.35, 0.75, 0.82, 1.25))
    rough = b.lin(mott, 0.0, 1.0, 0.05, 0.14)
    rough = b.add(rough, b.mul(b.ss(streak, 0.62, 0.88), b.mul(wear, 0.35)))
    return dict(color=col, rough=rough, metal=0.0, spec=0.85)


def _b_water(b, gi, bsdf):
    """水面：深色（墨绿蓝）+ 极低粗糙度 + 微涟漪法线 → 反出天光才像水。"""
    u, v = _uv(b, gi)
    base = (0.012, 0.030, 0.034)
    rip = b.noise(b.vec(b.mul(u, 11.0), b.mul(v, 11.0), 17.0), 1.0, 4.0, 0.4)
    rip2 = b.noise(b.vec(b.mul(u, 5.0), b.mul(v, 21.0), 37.0), 1.0, 4.0, 0.4)
    col = b.mixc(b.lin(b.mixf(0.5, rip, rip2), 0.30, 0.70, 0.0, 0.5), base, (0.030, 0.070, 0.075))
    h = b.add(b.mul(b.sub(rip, 0.5), 0.5), b.mul(b.sub(rip2, 0.5), 0.5))
    return dict(color=col, rough=0.04, metal=0.0,
                normal=b.bump(h, 0.25, uv_cm(2.0)), spec=0.9)


def _b_cavity(b, gi, bsdf):
    """室内暗腔（窗洞/门洞/炉膛内壁）：近全黑，roughness 1.0。**硬需求。**

    代码里 `mat="cavity"` 大量使用；未注册时回退成浅抹灰 → 窗洞/炉膛整体发亮，
    是"窗户像贴片、炉膛没深度"的主因。这里给一层极微弱的低频色差
    （0.02~0.05），让它读作"有纵深的黑"而不是平面黑板。
    """
    u, v = _uv(b, gi)
    n = b.noise(b.vec(b.mul(u, 1.6), b.mul(v, 1.6), 5.0), 1.0, 4.0)
    col = b.mul_c((0.030, 0.030, 0.035), b.lin(n, 0.25, 0.75, 0.75, 1.35))
    return dict(color=col, rough=1.0, metal=0.0, spec=0.0)


def _b_lamp(b, gi, bsdf):
    """灯室/灯笼玻璃：暖色自发光 + 轻微玻璃质感。

    自发光色不能给"接近白"的值：Standard 视图变换下 2.5 强度会直接把 RGB 全推过 1
    → 渲成一块白纸。给**深橙**基色（R 过曝、G 只到 0.9），保证读成"暖黄灯火"。
    """
    u, v = _uv(b, gi)
    n = b.noise(b.vec(b.mul(u, 6.0), b.mul(v, 6.0), 9.0), 1.0, 4.0)
    mott = b.lin(n, 0.25, 0.75, 0.62, 1.06)
    col = b.mul_c((0.560, 0.240, 0.075), mott)
    # 自发光色跟着斑纹走（而不是恒定色值）→ 灯罩上仍有"玻璃/火苗"的层次。
    # 色值必须够深：Standard 视图变换下 emit*strength 一旦 RGB 全部过 1 就是一块白纸。
    emit = b.mul_c((1.00, 0.30, 0.055), b.lin(n, 0.25, 0.75, 0.80, 1.12))
    return dict(color=col, rough=0.16, metal=0.0, spec=0.7,
                emit=emit, emit_str=2.5)


# ============================================================ 地面 / 植被
def _b_ground(b, gi, bsdf):
    """地面：暖米沙色 + 低频色斑 + 稀疏草簇（15 cm）+ 细碎石粒（5 cm）。

    ground 是**巨大平面**且 UV 是世界坐标 / 32，所以材质是"世界空间程序纹理"：
    尺度必须按米标定，否则草簇会密到糊成噪点（这就是回退纯色死白之外最常见的坑）。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    base = (0.680, 0.560, 0.395)                     # 暖沙（略偏黄）
    # 大尺度低频色斑（1~3 m）
    patch = b.noise(b.vec(b.mul(u, 0.45), b.mul(v, 0.45), 3.0), 1.0, 4.0)
    col = b.mul_c(base, b.lin(patch, 0.25, 0.78, 0.82, 1.12))
    patch2 = b.noise(b.vec(b.mul(u, 1.3), b.mul(v, 1.3), 7.0), 1.0, 5.0)
    col = b.mul_c(col, b.lin(patch2, 0.25, 0.78, 0.90, 1.08))
    # 土粒（3~8 cm）
    grain = b.noise(b.vec(b.mul(u, 9.0), b.mul(v, 9.0), 11.0), 1.0, 4.0)
    col = b.mul_c(col, b.lin(grain, 0.2, 0.8, 0.90, 1.09))
    # 细碎石粒：5 cm 格，少数格里有石子
    pd, _pc, _pp = b.voro(b.vec(b.mul(u, 8.4), b.mul(v, 8.4), 9.0), scale=1.0, randomness=0.95)
    pcell = b.h2(b.flr(b.mul(u, 8.4)), b.flr(b.mul(v, 8.4)), 23.0)
    peb = b.mul(b.ss(pcell, 0.74, 0.82), b.sub(1.0, b.ss(pd, 0.30, 0.72)))
    peb_c = b.mixc(b.h1(b.flr(b.mul(u, 8.4)), 31.0), (0.300, 0.285, 0.255), (0.520, 0.500, 0.460))
    col = b.mixc(b.mul(peb, 0.85), col, peb_c)
    # 稀疏草簇：15 cm 簇斑 + 2 cm 草叶
    tuft = b.ss(b.noise(b.vec(b.mul(u, 2.8), b.mul(v, 2.8), 71.0), 1.0, 4.0), 0.50, 0.68)
    tuft2 = b.ss(b.noise(b.vec(b.mul(u, 5.6), b.mul(v, 5.6), 77.0), 1.0, 4.0), 0.48, 0.72)
    tm = b.mul(tuft, b.mixf(0.4, 1.0, tuft2))
    blade = b.noise(b.vec(b.mul(u, 18.0), b.mul(v, 18.0), 83.0), 1.0, 4.0)
    bm = b.mul(b.ss(blade, 0.50, 0.74), b.lin(tm, 0.2, 0.9, 0.0, 1.0))
    grass_c = b.mixc(b.lin(blade, 0.3, 0.8, 0.0, 1.0),
                     (0.052, 0.115, 0.024), (0.165, 0.290, 0.055))
    col = b.mixc(b.mul(bm, 0.95), col, grass_c)
    # 草簇/石粒的接地暗影（让贴地物读得出来）
    col = b.mul_c(col, b.lin(b.mul(tuft, 0.35), 0.0, 1.0, 1.0, 0.90))

    h = b.mul(b.sub(grain, 0.5), 0.28)
    h = b.add(h, b.mul(b.sub(blade, 0.5), b.mul(bm, 0.9)))
    h = b.add(h, b.mul(peb, 0.35))
    rough = b.lin(grain, 0.0, 1.0, 0.92, 0.99)
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 1.1), b.mul(v, 1.1), 91.0), 1.0, 4.0),
                            0.55, 0.85), b.mul(wear, 0.30)), col, b.mul_c(col, 0.80))
    return dict(color=col, rough=rough, normal=b.bump(h, 0.45, uv_cm(2.5)), spec=0.16)


def _b_grass_tuft(b, gi, bsdf):
    """独立草簇（供程序化散布）：整格密生草叶 + 叶梢参差 + 叶缝暗底；带 alpha 裁切。

    坐标按**格内相对高度** `frc(v)` 取，所以贴到 1 格小方片上就是完整一丛，
    贴到大平面上就是逐格重复的草丛（不会因为平面尺寸变了就整片消失）。
    """
    u, v = _uv(b, gi)
    vh = b.frc(v)                         # 格内相对高度 0(根)~1(梢)
    bw = uv_cm(2.2)                       # 草叶位宽 2.2 cm（叶占中间约一半）
    curv = b.mul(b.sub(b.noise(b.vec(b.mul(v, 0.8), b.mul(u, 0.2), 13.0), 1.0, 3.0), 0.5),
                 b.mul(bw, 2.4))
    su = b.div(b.add(u, curv), bw)
    si = b.flr(su)
    fu = b.sub(su, si)
    tall = b.h1(si, 7.0)                  # 逐叶高度
    lean = b.h1(si, 31.0)                 # 逐叶倒伏
    fu2 = b.frc(b.add(fu, b.mul(b.sub(lean, 0.5), b.mul(vh, 0.9))))
    # 叶截面：要真的"窄"（pow 指数太高会整格都算实心 → alpha 裁不出叶缝）
    prof = b.pisin(fu2)
    blade = b.ss(prof, 0.42, 0.95)                  # 0/1 边缘（裁切用）
    blade_c = b.pow(prof, 0.6)                      # 连续明暗（着色用）
    top = b.mr(tall, 0.0, 1.0, 0.42, 0.96)          # 叶梢所在高度
    alive = b.ss(b.sub(top, vh), 0.0, 0.05)         # 超过叶高 → 裁掉
    lvl = b.h1(si, 53.0)
    col = b.mixc(lvl, (0.060, 0.140, 0.028), (0.200, 0.330, 0.078))
    col = b.mul_c(col, b.lin(blade_c, 0.0, 1.0, 0.48, 1.24))
    col = b.mul_c(col, b.lin(vh, 0.0, 0.9, 0.60, 1.18))         # 根暗梢亮
    # 叶缝暗底（alpha 被忽略时也读得出"一丛草"而不是一块绿板）
    col = b.mixc(b.sub(1.0, b.mul(alive, blade)), col, (0.024, 0.042, 0.014))
    alpha = b.mul(alive, blade)
    h = b.mul(blade_c, 0.7)
    return dict(color=col, rough=0.88, alpha=alpha,
                normal=b.bump(h, 0.5, uv_cm(1.0)), spec=0.2)


def _leaves(b, u, v, leaf_sz, pal, vein=True):
    """阔叶簇：Voronoi 叶单元 + 逐叶色差 + 叶脉 + 叶间暗影。返回 (col, h)。"""
    k = 1.0 / leaf_sz
    kd, kc, kp = b.voro(b.vec(b.mul(u, k), b.mul(v, k), 5.0), scale=1.0, randomness=0.9)
    idx = b.h2(b.flr(b.mul(u, k)), b.flr(b.mul(v, k)), 17.0)
    col = b.mixc(idx, pal['lo'], pal['hi'])
    col = b.mixc(b.lin(b.h1(b.flr(b.mul(u, k)), 41.0), 0.72, 0.95, 0.0, 0.6),
                 col, b.mul_c(col, 0.62))
    face = b.sub(1.0, b.ss(kd, 0.30, 0.95))              # 叶面/叶隙
    if vein:
        px_, py_, _pz = b.sep(kp)
        vd = b.absv(b.mul(px_, 2.2))
        vein_m = b.sub(1.0, b.ss(vd, 0.06, 0.22))
        col = b.mixc(b.mul(vein_m, face), col, b.mul_c(col, 0.66))
    col = b.mul_c(col, b.lin(face, 0.0, 1.0, 0.42, 1.10))
    col = b.mul_c(col, b.lin(b.noise(b.vec(b.mul(u, 12.0), b.mul(v, 12.0), 23.0), 1.0, 4.0),
                             0.25, 0.75, 0.86, 1.12))
    h = b.add(b.mul(face, 0.85), b.mul(b.sub(kd, 0.5), 0.3))
    return col, h


def _b_foliage(b, gi, bsdf):
    """阔叶绿植（花槽/陶罐里的丛叶）：叶 7 cm，饱和偏黄的叶绿，粗糙。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    pal = dict(lo=(0.028, 0.075, 0.014), hi=(0.150, 0.320, 0.062))
    col, h = _leaves(b, u, v, uv_cm(7.0), pal)
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 3.2), 61.0), 1.0, 5.0),
                            0.58, 0.84), b.mul(wear, 0.30)), col, (0.180, 0.185, 0.070))  # 枯斑
    return dict(color=col, rough=0.86, normal=b.bump(h, 0.75, uv_cm(3.0)), spec=0.22,
                sheen=0.12, sheen_rough=0.7)


def _b_vine(b, gi, bsdf):
    """攀爬藤（墙根/墙面绿化）：深绿叶片 + 竖向藤蔓茎（比 foliage 更深更冷）。"""
    u, v = _uv(b, gi)
    pal = dict(lo=(0.018, 0.052, 0.014), hi=(0.095, 0.205, 0.048))
    col, h = _leaves(b, u, v, uv_cm(6.0), pal)
    # 竖向藤茎（14 cm 一根，细、暗、连续；沿 V 缓慢蛇行）
    meander = b.noise(b.vec(b.mul(v, 0.6), 3.0, 9.0), 1.0, 3.0)
    stem = b.pisin(b.frc(b.div(b.add(u, b.mul(b.sub(meander, 0.5), 0.14)), uv_cm(14.0))))
    stem = b.pow(stem, 0.4)
    col = b.mixc(stem, col, (0.085, 0.062, 0.030))
    h = b.add(h, b.mul(stem, 0.25))
    col = b.mul_c(col, b.lin(b.noise(b.vec(b.mul(u, 8.0), b.mul(v, 8.0), 33.0), 1.0, 4.0),
                             0.25, 0.75, 0.86, 1.10))
    return dict(color=col, rough=0.88, normal=b.bump(h, 0.8, uv_cm(2.6)), spec=0.20,
                sheen=0.12, sheen_rough=0.7)


# ============================================================ 二轮追加：市集/民生材质
#
# **纯追加**：既有 26 个 key 的任何一行都没动（名字/语义/审计口径保持稳定）。
# 追加的动机来自"道具扩充二轮"（市集摊/鱼摊/菜筐/染缸/面包架…）：这些道具要的颜色
# 在原 26 个 key 里没有对应物 —— 麻布（canvas）是灰白本色、砖（brick）带灰浆缝、
# 麻袋（sack）是粗黄褐 —— 都不能当"染色布 / 陶器 / 蔬果 / 鱼 / 面包"用。

def _cloth_dyed(b, gi, bsdf, lo, mid, hi):
    """染色土布通用层：平纹织 + 手工染斑 + 暴晒褪色 + 垂坠折痕 + 下摆拖脏。

    布色板是"市集摊/挂旗/染坊"最便宜的识别信号：同形不同色的布就能把市集摊、
    鱼摊、染缸一眼分开，比改几何划算得多。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    col, h, slub, _tr = _weave(b, u, v, uv_cm(2.4), dict(dark=lo, mid=mid, hi=hi))
    # **压掉逐格跳变**：`_weave` 的逐格明暗跳变在麻布（米白）上只是"粗布感"，但染成
    # 饱和色后会读成**马赛克瓷砖**（一轮踩过）。染色布整块是一个色，所以先按 mid
    # 拉平 40%，再用低频染斑制造不匀。
    col = b.mixc(0.40, col, mid)
    dye = b.noise(b.vec(b.mul(u, 3.4), b.mul(v, 3.4), 21.0), 1.0, 5.0, 0.55)   # 染得深浅不匀
    col = b.mul_c(col, b.lin(dye, 0.25, 0.78, 0.84, 1.14))
    sun = b.noise(b.vec(b.mul(u, 1.1), b.mul(v, 1.1), 37.0), 1.0, 4.0)         # 晒褪
    col = b.mixc(b.mul(b.ss(sun, 0.52, 0.86), b.mul(wear, 0.42)), col, b.mul_c(col, 1.28))
    fold = b.noise(b.vec(b.mul(u, 1.7), b.mul(v, 0.22), 13.0), 1.0, 4.0)       # 垂坠折痕（顺 V 拉长）
    fold_m = b.sub(1.0, b.ss(b.absv(b.sub(fold, 0.5)), 0.02, 0.15))
    col = b.mul_c(col, b.lin(fold_m, 0.0, 1.0, 0.82, 1.06))
    dirt = b.noise(b.vec(b.mul(u, 2.6), b.mul(v, 2.6), 67.0), 1.0, 5.0, 0.5)   # 下摆拖脏
    col = b.mixc(b.mul(b.ss(dirt, 0.58, 0.86), b.mul(wear, 0.38)), col, (0.230, 0.198, 0.150))
    h = b.add(h, b.mul(fold_m, 0.32))
    return dict(color=col, rough=b.add(0.91, b.mul(slub, 0.04)),
                normal=b.bump(h, 0.65, uv_cm(1.0)), spec=0.12,
                sheen=0.26, sheen_rough=0.58)


def _b_cloth_red(b, gi, bsdf):
    """染布·茜红：中世纪最常见的"贵色"，偏暗砖红（不是现代正红）。

    色板跨度刻意压窄（dark 约为 mid 的 0.55 倍、hi 约 1.6 倍）：宽跨度 + 逐格跳变
    在饱和色上就是"红瓷砖"，窄跨度才读得出"一块染红的布"。
    """
    return _cloth_dyed(b, gi, bsdf,
                       (0.168, 0.032, 0.020), (0.300, 0.056, 0.036),
                       (0.480, 0.118, 0.062))


def _b_cloth_blue(b, gi, bsdf):
    """染布·靛蓝：菘蓝/靛青染，深蓝偏紫，平民最常用的"好颜色"。"""
    return _cloth_dyed(b, gi, bsdf,
                       (0.030, 0.050, 0.098), (0.055, 0.090, 0.175),
                       (0.090, 0.140, 0.255))


def _b_cloth_ochre(b, gi, bsdf):
    """染布·赭黄：洋葱皮/茜草染的暖赭黄，最接近本色麻布的暖调。"""
    return _cloth_dyed(b, gi, bsdf,
                       (0.205, 0.142, 0.058), (0.360, 0.248, 0.100),
                       (0.560, 0.420, 0.205))


def _b_wicker(b, gi, bsdf):
    """柳条编（筐/篓/笼）：横向柳条行 + 竖向立桩压一挑一，暖柳木色。

    与 `wattle` 的分工：那个是**墙用编条篱**（深色、低饱和、带泥底）；筐篓必须亮、
    干净、看得见"一圈一圈的柳条"，否则在游戏尺寸下读成泥巴坨。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    row = uv_cm(2.6)
    sv = b.div(v, row)
    ri = b.flr(sv)
    fv = b.sub(sv, ri)
    rod = b.pow(b.pisin(fv), 0.5)                      # 柳条截面（一根一根）
    rr = b.h1(ri, 7.0)
    rr2 = b.h1(ri, 41.0)
    sw = uv_cm(5.5)
    su = b.div(u, sw)
    ci = b.flr(su)
    fu = b.sub(su, ci)
    stake = b.pow(b.pisin(fu), 0.35)                   # 竖向立桩（压过柳条）
    over = b.step(b.frc(b.mul(b.add(ci, ri), 0.5)), 0.5)
    g = b.noise(b.vec(b.mul(u, 8.0), b.mul(v, 8.0), 5.0), 1.0, 5.0, 0.5)
    col = b.mixc(rr, (0.185, 0.112, 0.044), (0.430, 0.292, 0.132))
    col = b.mixc(b.mul(rr2, 0.60), col, b.mul_c(col, 0.72))
    col = b.mul_c(col, b.lin(g, 0.25, 0.75, 0.84, 1.14))
    col = b.shade(col, rod, 0.55, 1.10)
    stake_c = b.mixc(b.h1(ci, 13.0), (0.230, 0.140, 0.052), (0.500, 0.338, 0.152))
    col = b.mixc(b.mul(stake, over), col, stake_c)
    h = b.add(b.mul(rod, 0.90), b.mul(b.mul(stake, over), 0.50))
    h = b.add(h, b.mul(b.sub(g, 0.5), 0.35))
    _ = wear
    return dict(color=col, rough=b.lin(g, 0.0, 1.0, 0.80, 0.94),
                normal=b.bump(h, 0.95, uv_cm(1.5)), spec=0.22)


def _b_clay(b, gi, bsdf):
    """无釉红陶（陶罐/染缸/奶桶）：暖橙陶土 + 轮制旋纹 + 窑变火色 + 盐霜磨白。

    陶器和石砌/砖砌的区别不在颜色而在"表面的连续曲面"：所以做轮制旋纹（2.2cm
    一道）而不是砌块，粗糙度也略低（好陶是磨光的）。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    rings = b.pisin(b.mul(v, 1.0 / uv_cm(2.2)))                                # 轮制旋纹
    fire = b.noise(b.vec(b.mul(u, 2.2), b.mul(v, 2.2), 11.0), 1.0, 5.0, 0.55)  # 火色深浅
    grain = b.noise(b.vec(b.mul(u, 14.0), b.mul(v, 14.0), 5.0), 1.0, 4.0)
    col = b.mixc(fire, (0.180, 0.070, 0.030), (0.430, 0.185, 0.078))
    col = b.mixc(b.lin(grain, 0.28, 0.76, 0.0, 0.45), col, b.mul_c(col, 0.80))
    col = b.mul_c(col, b.lin(rings, 0.0, 1.0, 0.92, 1.10))
    soot = b.noise(b.vec(b.mul(u, 1.4), b.mul(v, 1.4), 29.0), 1.0, 5.0, 0.6)   # 窑变熏黑
    col = b.mixc(b.mul(b.ss(soot, 0.56, 0.86), b.lin(wear, 0.0, 1.0, 0.16, 0.55)),
                 col, (0.070, 0.040, 0.028))
    salt = b.noise(b.vec(b.mul(u, 9.0), b.mul(v, 9.0), 47.0), 1.0, 4.0)        # 泛碱/磨白
    col = b.mixc(b.mul(b.ss(salt, 0.66, 0.88), b.mul(wear, 0.50)), col, (0.520, 0.480, 0.420))
    h = b.add(b.mul(rings, 0.55), b.mul(b.sub(grain, 0.5), 0.30))
    return dict(color=col, rough=b.lin(fire, 0.0, 1.0, 0.38, 0.60),
                normal=b.bump(h, 0.60, uv_cm(2.0)), spec=0.45)


def _b_produce(b, gi, bsdf):
    """叶菜堆（甘蓝/生菜/香草）：紧凑圆叶细胞 + 叶脉亮线 + 叶缝暗底。

    9cm 的叶单元 —— 比 foliage（7cm 观赏叶）略大、更密、更黄绿，"能吃的一堆"
    和"种着的一丛"在游戏尺寸下就靠密度与色调区分。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    pal = dict(lo=(0.030, 0.082, 0.020), hi=(0.200, 0.365, 0.082))
    col, h = _leaves(b, u, v, uv_cm(9.0), pal)
    n = b.noise(b.vec(b.mul(u, 5.0), b.mul(v, 5.0), 23.0), 1.0, 4.0)
    col = b.mul_c(col, b.lin(n, 0.30, 0.75, 0.88, 1.12))
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 3.0), b.mul(v, 3.0), 55.0), 1.0, 5.0),
                            0.60, 0.86), b.mul(wear, 0.30)), col, (0.230, 0.225, 0.100))  # 蔫叶
    return dict(color=col, rough=0.52, normal=b.bump(h, 0.88, uv_cm(2.4)), spec=0.42,
                sheen=0.10, sheen_rough=0.60)


def _b_produce_root(b, gi, bsdf):
    """根菜堆（胡萝卜/洋葱/芜菁）：顺长轴拉长的细胞 + 橙黄土色 + 泥渍。

    细胞刻意在 V 向拉长 3 倍 —— 根菜是"一根一根躺着的"，等轴细胞会读成土豆或石头。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    ku, kv = 1.0 / uv_cm(30.0), 1.0 / uv_cm(11.0)
    kd, _kc, _kp = b.voro(b.vec(b.mul(u, ku), b.mul(v, kv), 5.0),
                          scale=1.0, randomness=0.90)
    idx = b.h2(b.flr(b.mul(u, ku)), b.flr(b.mul(v, kv)), 17.0)
    col = b.mixc(idx, (0.300, 0.118, 0.020), (0.640, 0.312, 0.058))
    col = b.mixc(b.lin(b.h1(b.flr(b.mul(u, ku)), 41.0), 0.70, 0.94, 0.0, 0.55),
                 col, (0.480, 0.400, 0.150))                                  # 少数土黄/青的
    face = b.sub(1.0, b.ss(kd, 0.32, 0.95))                               # 菜与菜之间的缝
    col = b.mul_c(col, b.lin(face, 0.0, 1.0, 0.40, 1.12))
    mud = b.noise(b.vec(b.mul(u, 6.0), b.mul(v, 6.0), 61.0), 1.0, 5.0, 0.5)   # 带泥
    col = b.mixc(b.mul(b.ss(mud, 0.52, 0.80), b.lin(wear, 0.0, 1.0, 0.30, 0.80)),
                 col, (0.150, 0.105, 0.058))
    grn = b.noise(b.vec(b.mul(u, 20.0), b.mul(v, 20.0), 9.0), 1.0, 4.0)
    col = b.mul_c(col, b.lin(grn, 0.25, 0.75, 0.90, 1.10))
    h = b.add(b.mul(face, 0.85), b.mul(b.sub(kd, 0.5), 0.40))
    return dict(color=col, rough=0.62, normal=b.bump(h, 0.85, uv_cm(2.2)), spec=0.38)


def _b_fish(b, gi, bsdf):
    """鱼皮（鲱/鲭/鳕）：银灰偏蓝 + 细鳞格（2.6x1.8cm）+ 虹彩 + 湿光高光。

    鱼必须**潮**：粗糙度 0.24~0.40 + specular 0.6，缩到游戏尺寸才读得出一条反光的
    鱼；做干的哑光灰条会被读成木棍。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    # 鳞格放大到 4.2x2.6cm：2.6cm 的鳞在游戏尺寸下只有 1.5px，会糊成"褶皱的锡纸"，
    # 而鱼的第一读法就是"一条银亮的长条 + 细鳞"。
    c = _cells(b, u, v, uv_cm(4.2), uv_cm(2.6), stagger=0.5, seed=7.0)
    shade, lip = _row_light(b, c['fv'], top=0.86, grad_to=0.55, lip=0.10)
    base = b.mixc(c['rand'], (0.180, 0.196, 0.222), (0.470, 0.500, 0.540))
    base = b.mixc(b.lin(c['rand2'], 0.72, 0.95, 0.0, 0.50), base, (0.250, 0.300, 0.390))
    col = b.mixc(shade, b.mul_c(base, 0.62), base)
    irid = b.noise(b.vec(b.mul(u, 3.0), b.mul(v, 3.0), 31.0), 1.0, 4.0)          # 虹彩
    col = b.mixc(b.mul(b.ss(irid, 0.55, 0.85), 0.28), col, (0.330, 0.240, 0.400))
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 1.6), b.mul(v, 1.6), 71.0), 1.0, 5.0),
                            0.62, 0.88), b.mul(wear, 0.28)), col, (0.300, 0.280, 0.230))
    h = b.add(b.mul(lip, 0.50), b.mul(shade, 0.70))
    h = b.sub(h, b.mul(b.mul(c['rand'], 0.5), 0.20))
    return dict(color=col, rough=b.lin(c['rand'], 0.0, 1.0, 0.26, 0.40), metal=0.14,
                normal=b.bump(h, 0.50, uv_cm(1.6)), spec=0.60)


def _b_bread(b, gi, bsdf):
    """面包皮：金褐脆壳 + 割包裂痕（露浅色瓤）+ 浮粉 + 焦边。

    割痕（slashes）是面包的第一识别特征 —— 没有它，圆面包在游戏尺寸下就是一个
    褐色球；有了三五道裂口，立刻读作"烤过的面包"。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    crust = b.noise(b.vec(b.mul(u, 4.5), b.mul(v, 4.5), 17.0), 1.0, 6.0, 0.60)
    fine = b.noise(b.vec(b.mul(u, 16.0), b.mul(v, 16.0), 3.0), 1.0, 4.0)
    col = b.mixc(crust, (0.215, 0.082, 0.020), (0.560, 0.288, 0.082))
    col = b.mixc(b.lin(fine, 0.25, 0.78, 0.0, 0.42), col, b.mul_c(col, 0.78))
    sl = b.noise(b.vec(b.mul(u, 0.9), b.mul(v, 26.0), 41.0), 1.0, 3.0)          # 割痕
    slash = b.mul(b.sub(1.0, b.ss(b.absv(b.sub(sl, 0.5)), 0.0, 0.035)),
                  b.mul(b.lin(wear, 0.0, 1.0, 0.35, 1.0),
                        b.lin(crust, 0.35, 0.75, 0.20, 1.0)))
    col = b.mixc(slash, col, (0.690, 0.570, 0.390))                             # 裂口露浅瓤
    fl = b.noise(b.vec(b.mul(u, 6.0), b.mul(v, 6.0), 61.0), 1.0, 4.0)           # 浮粉
    col = b.mixc(b.mul(b.ss(fl, 0.58, 0.86), 0.55), col, (0.800, 0.740, 0.620))
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 3.0), b.mul(v, 3.0), 23.0), 1.0, 5.0),
                            0.66, 0.90), b.mul(wear, 0.40)), col, (0.115, 0.055, 0.020))
    h = b.add(b.mul(b.sub(crust, 0.5), 0.50), b.mul(b.sub(fine, 0.5), 0.25))
    h = b.sub(h, b.mul(slash, 0.60))
    return dict(color=col, rough=b.lin(crust, 0.0, 1.0, 0.62, 0.82),
                normal=b.bump(h, 0.70, uv_cm(1.6)), spec=0.24)


def _b_dye_bath(b, gi, bsdf):
    """染缸液面：深靛近黑 + 极低粗糙度 + 微涡纹 + 浮沫（只在染缸口那一小块用）。"""
    u, v = _uv(b, gi)
    s1 = b.noise(b.vec(b.mul(u, 7.0), b.mul(v, 7.0), 23.0), 1.0, 5.0, 0.70)
    s2 = b.noise(b.vec(b.mul(u, 3.0), b.mul(v, 17.0), 41.0), 1.0, 4.0, 0.60)
    sw = b.mixf(0.5, s1, s2)
    col = b.mixc(sw, (0.010, 0.018, 0.045), (0.048, 0.082, 0.175))
    foam = b.ss(b.noise(b.vec(b.mul(u, 22.0), b.mul(v, 22.0), 7.0), 1.0, 4.0), 0.68, 0.86)
    col = b.mixc(b.mul(foam, 0.45), col, (0.230, 0.290, 0.400))
    h = b.mul(b.sub(sw, 0.5), 0.60)
    return dict(color=col, rough=0.10, metal=0.0, normal=b.bump(h, 0.20, uv_cm(3.0)), spec=0.75)


# ============================================================ 三轮追加 A：玻璃系 / 魔法元素
#
# 这一族的难点是**透光**而不是图案。EEVEE Next 的 Transmission 要成立需要三件事：
#   ① 场景开 raytracing（样片/交付探针已开）；
#   ② 材质开 `use_raytrace_refraction`（由 `_set_glass` 负责，见注册表段）；
#   ③ 物体背后有东西可折（天空/室内暗腔）。
# 只靠 Transmission、背后又没东西时会渲成**死黑**，所以每个玻璃 key 都是双保险：
#   * 彩窗 / 水晶 / 符文 = Transmission **＋ 自发光托底**（宝石色块、晶面、刻痕本身就是发光色）；
#   * 清水玻璃 / 瓶玻璃 = 浅色底 + 极低粗糙 + **假反射斜带/灰雾斑**（把"玻璃"画出来，
#     不赌屏幕空间折射）。这与既有 `glass_win`（深底 + 低粗糙 + 环境反射）同源，
#     区别只是"亮玻璃/背光窗"与"暗窗/黑窗"的取向不同。
#
# 分格纪律：铅条/窗棂 ≥1.5 cm 且必须有实体感（凸起 + 受光滚边 + 暗底），
# 否则在 76 px/m 下铅条会糊成一层灰雾、窗户读作一团色斑。

#: 需要"瑞利折射 + 透射阴影"设置的 key（`_instance` 里调用 `_set_glass`）
GLASS_KEYS = {'stained_glass', 'glass_lead', 'glass_clear', 'glass_bottle', 'crystal'}


def _lead_grid(b, fu, fv, cw, ch, w_uv, soft=1.35):
    """分格铅条/窗棂掩码：到格边距离 < w → 1。返回 (came, d_uv)。

    `d_uv` 同时给"铅条受光滚边"用（滚边 = 铅条中心那一条窄带）。
    """
    du = b.mul(b.mn(fu, b.sub(1.0, fu)), cw)
    dv = b.mul(b.mn(fv, b.sub(1.0, fv)), ch)
    d = b.mn(du, dv)
    return b.sub(1.0, b.ss(d, w_uv, b.mul(w_uv, soft))), d


def _lead_color(b, u, v, seed=43.0):
    """铅条本体色：深铅灰 + 氧化微差（纯黑在 2D 立绘里读成"洞"）。"""
    return b.mixc(b.noise(b.vec(b.mul(u, 42.0), b.mul(v, 42.0), seed), 1.0, 3.0),
                  (0.028, 0.028, 0.034), (0.098, 0.098, 0.110))


def _b_stained_glass(b, gi, bsdf):
    """教堂彩窗：**多色宝石色块 + 铅条分格 + 微透光**。

    读法（从粗到细）：① 每块 18×20 cm 的饱和宝石色块（25% 下 3.4 px，靠**饱和色相**
    而不是亮度跳变读出来）；② 1.8 cm 铅条（深色细网 + 受光滚边，把色块"框"住）；
    ③ 块内"背光"（格心亮、格边暗，像一块透光的玻璃）、气泡、外侧灰泥雨渍。

    **透射只给 0.22**（实测教训）：EEVEE 的屏幕空间折射在"背后没东西"时会把窗格整段
    渲没 —— 透射 0.62 时同一扇窗只有中间几行还看得见，上下变成背景色（读作"窗子破了两块"）。
    彩窗在游戏里的典型看法是"背光发亮的彩色窗格"，所以由**自发光托底 0.85 + 低透射**立住，
    透射只负责"这不是一块不透明的彩色板"。
    """
    u, v = _uv(b, gi)
    cw, ch = uv_cm(18.0), uv_cm(20.0)
    c = _cells(b, u, v, cw, ch, stagger=0.5, seed=5.0, jitter=0.22)
    r1, r2 = c['rand'], c['rand2']
    lw = uv_cm(1.8)
    came, d = _lead_grid(b, c['fu'], c['fv'], cw, ch, lw)

    # ---- 宝石色板：红/蓝/绿/琥珀/紫/青/金/灰白玉（段间留软过渡 = 混色玻璃）
    pane = b.mixc(b.ss(r1, 0.00, 0.13), (0.700, 0.048, 0.038), (0.060, 0.085, 0.600))
    pane = b.mixc(b.ss(r1, 0.13, 0.28), pane, (0.035, 0.380, 0.145))
    pane = b.mixc(b.ss(r1, 0.28, 0.44), pane, (0.880, 0.415, 0.038))
    pane = b.mixc(b.ss(r1, 0.44, 0.58), pane, (0.360, 0.060, 0.560))
    pane = b.mixc(b.ss(r1, 0.58, 0.72), pane, (0.025, 0.340, 0.370))
    pane = b.mixc(b.ss(r1, 0.72, 0.86), pane, (0.860, 0.700, 0.260))
    pane = b.mixc(b.ss(r1, 0.86, 0.94), pane, (0.780, 0.755, 0.670))
    # 块内背光（格心亮、格边暗）+ 逐块深浅 + 吹制玻璃的水波
    # 亮度上限刻意压在 1.15：抬到 1.3 时红/蓝会被推成粉紫（"宝石色"读成"糖果色"）
    pdome = b.pow(b.mul(b.pisin(c['fu']), b.pisin(c['fv'])), 0.35)
    pane = b.mul_c(pane, b.lin(pdome, 0.0, 1.0, 0.62, 1.15))
    pane = b.mul_c(pane, b.lin(r2, 0.0, 1.0, 0.88, 1.12))
    unev = b.noise(b.vec(b.mul(u, 9.0), b.mul(v, 9.0), 31.0), 1.0, 4.0)
    pane = b.mul_c(pane, b.lin(unev, 0.25, 0.78, 0.86, 1.16))
    # 气泡/砂眼：**只往同色更亮里混**（混成白点会把彩窗读成"马赛克瓷砖"）
    bub = b.ss(b.noise(b.vec(b.mul(u, 26.0), b.mul(v, 26.0), 37.0), 1.0, 4.0), 0.74, 0.86)
    pane = b.mixc(b.mul(bub, 0.22), pane, b.mul_c(pane, 1.30))
    # 外侧灰泥/雨渍：只压明度不换色（朝街一面是脏的）
    dirt = b.noise(b.vec(b.mul(u, 3.6), b.mul(v, 1.5), 41.0), 1.0, 5.0, 0.5)
    pane = b.mul_c(pane, b.lin(b.mul(b.ss(dirt, 0.56, 0.82), 0.30), 0.0, 1.0, 1.0, 0.78))

    # ---- 铅条：深铅灰 + 内侧一条受光滚边（读"细网"全靠它）
    lead = _lead_color(b, u, v)
    col = b.mixc(came, pane, lead)
    hi = b.sub(1.0, b.ss(d, b.mul(lw, 0.34), b.mul(lw, 0.78)))
    col = b.mixc(b.mul(hi, 0.42), col, (0.400, 0.425, 0.470))

    h = b.add(b.mul(came, 0.62), b.mul(b.sub(unev, 0.5), 0.20))
    trans = b.mul(b.sub(1.0, came), 0.22)                  # 铅条不透光
    emit = b.mixc(came, b.mul_c(pane, 0.78), (0.008, 0.008, 0.010))
    rough = b.add(b.lin(pdome, 0.0, 1.0, 0.20, 0.09), b.mul(came, 0.30))
    return dict(color=col, rough=rough, metal=b.mul(came, 0.42),
                trans=trans, emit=emit, emit_str=0.75, ior=1.52, spec=0.58,
                normal=b.bump(h, 0.55, uv_cm(1.4)))


def _b_glass_lead(b, gi, bsdf):
    """铅条窗（菱形分格 / 牛眼窗小样）：**淡青绿透光玻璃 + 铅框分格**。

    分格用 45° 旋转坐标 → 菱形 quarry（中世纪 leaded light 的标准做法）。
    玻璃是"吹制圆筒玻璃"：竖向波筋（厚薄不均）+ 气泡 + 浅绿灰污；
    铅条 1.6~2.2 cm，不透光、带受光滚边，把每块玻璃"框"出来。
    """
    u, v = _uv(b, gi)
    s = uv_cm(13.0)
    a = b.add(u, v)
    d_ = b.sub(u, v)
    su, sv = b.div(a, s), b.div(d_, s)
    ci, ri = b.flr(su), b.flr(sv)
    fu, fv = b.sub(su, ci), b.sub(sv, ri)
    r1, r2 = b.h2(ci, ri, 7.0), b.h2(ci, ri, 23.0)
    lw = uv_cm(1.9)                                        # 菱形斜边的垂直宽度 ≈ lw/√2
    came, d = _lead_grid(b, fu, fv, s, s, lw)

    # ---- 淡青绿玻璃：逐块色差 + 竖向波筋（沿 v 拉长的噪声）+ 气泡
    base = b.mixc(r1, (0.300, 0.520, 0.440), (0.640, 0.800, 0.700))
    wav = b.noise(b.vec(b.mul(u, 20.0), b.mul(v, 2.2), 11.0), 1.0, 5.0, 0.55)
    base = b.mixc(b.lin(wav, 0.30, 0.80, 0.0, 0.60), base, b.mul_c(base, 0.60))   # 厚玻璃带偏深
    base = b.mul_c(base, b.lin(r2, 0.0, 1.0, 0.88, 1.12))
    bub = b.ss(b.noise(b.vec(b.mul(u, 26.0), b.mul(v, 26.0), 17.0), 1.0, 4.0), 0.70, 0.82)
    base = b.mixc(b.mul(bub, 0.34), base, (0.840, 0.920, 0.880))
    # 外侧灰泥/雨渍（比彩窗轻：淡青玻璃本来就"雾"）
    dirt = b.noise(b.vec(b.mul(u, 3.0), b.mul(v, 1.4), 29.0), 1.0, 5.0, 0.5)
    base = b.mixc(b.mul(b.ss(dirt, 0.58, 0.86), 0.20), base, (0.075, 0.105, 0.098))

    lead = _lead_color(b, u, v, seed=67.0)
    col = b.mixc(came, base, lead)
    hi = b.sub(1.0, b.ss(d, b.mul(lw, 0.34), b.mul(lw, 0.80)))
    col = b.mixc(b.mul(hi, 0.38), col, (0.385, 0.410, 0.450))

    h = b.add(b.mul(came, 0.58), b.mul(b.sub(wav, 0.5), 0.26))
    trans = b.mul(b.sub(1.0, came), 0.30)      # 同彩窗：低透射 + 自发光托底，避免屏幕空间折射"吃掉"窗格
    emit = b.mixc(came, b.mul_c(base, 0.62), (0.006, 0.010, 0.010))
    rough = b.add(b.lin(wav, 0.0, 1.0, 0.07, 0.16), b.mul(came, 0.26))
    return dict(color=col, rough=rough, metal=b.mul(came, 0.40),
                trans=trans, emit=emit, emit_str=0.45, ior=1.52, spec=0.60,
                normal=b.bump(h, 0.50, uv_cm(1.2)))


def _b_glass_clear(b, gi, bsdf):
    """清水玻璃（门窗小格 / 摆件罩子）：**浅青底 + 极低粗糙 + 假反射斜带 + 灰雾/擦痕**。

    纯透射在"背后没东西"时会渲成死黑，所以这版的读法靠三样**画出来**的东西：
      ① 极浅青绿底（0.86 级，不是纯白 → 边缘/厚处有颜色）；
      ② 一片 30~60 cm 的斜向柔和高光带（室内窗玻璃上那道"反光"）；
      ③ 5~20 cm 的灰雾斑 + 竖向擦痕（脏了才看得见玻璃）。
    透射 0.4~0.95 由灰雾斑调制（脏处散射、透得少）。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    base = (0.760, 0.845, 0.820)
    cloud = b.noise(b.vec(b.mul(u, 5.2), b.mul(v, 5.2), 13.0), 1.0, 5.0, 0.6)
    cm = b.ss(cloud, 0.50, 0.84)
    col = b.mixc(b.mul(cm, 0.45), base, (0.520, 0.580, 0.570))
    # 擦痕（抹布痕：一组一组的斜向细纹）
    wipe = b.noise(b.vec(b.mul(b.add(u, b.mul(v, 0.45)), 22.0), b.mul(v, 1.2), 19.0), 1.0, 4.0)
    wm = b.mul(b.ss(wipe, 0.60, 0.86), b.lin(wear, 0.0, 1.0, 0.35, 1.0))
    col = b.mul_c(col, b.lin(wm, 0.0, 1.0, 1.0, 0.88))
    # 假反射斜带（沿一条斜向取低频噪声 → 一条宽而柔的"天光倒影"；这是玻璃唯一的"存在感"
    # 来源，必须给够：一轮给到 +5% 白在渲染里完全看不见，现在给到 +20~28%）
    dgl = b.add(b.mul(u, 0.36), b.mul(v, 0.94))
    gl = b.noise(b.vec(b.mul(dgl, 0.42), 3.0, 7.0), 1.0, 4.0)
    gm = b.ss(gl, 0.44, 0.74)
    col = b.mixc(b.mul(gm, 0.62), col, (1.200, 1.280, 1.330))
    # 第二道弱反射（斜带错开一段）+ 窗框边缘的暗描边（贴墙的玻璃在框边总是暗一圈）
    gl2 = b.ss(b.noise(b.vec(b.mul(b.sub(dgl, 0.35), 0.55), 5.0, 23.0), 1.0, 4.0), 0.62, 0.86)
    col = b.mixc(b.mul(gl2, 0.28), col, (1.060, 1.100, 1.140))
    # 底部积尘（贴地摆件/低窗格）
    dust = b.mul(b.ss(b.noise(b.vec(b.mul(u, 4.0), b.mul(v, 4.0), 31.0), 1.0, 4.0), 0.55, 0.82),
                 b.mul(_v_ground(b, v, 0.14), 0.55))
    col = b.mixc(dust, col, (0.520, 0.500, 0.440))

    trans = b.mx(b.sub(b.mul(b.sub(1.0, b.mul(cm, 0.40)), 0.92), b.mul(wm, 0.08)), 0.45)
    rough = b.add(b.add(0.030, b.mul(cm, 0.140)), b.mul(wm, 0.045))
    h = b.add(b.mul(b.sub(cloud, 0.5), 0.10), b.mul(b.sub(wipe, 0.5), 0.06))
    return dict(color=col, rough=rough, metal=0.0, trans=trans, ior=1.45, spec=0.62,
                normal=b.bump(h, 0.10, uv_cm(6.0)))


def _b_glass_bottle(b, gi, bsdf):
    """瓶玻璃（绿/橄榄绿厚玻璃）：**模制竖纹 + 气泡 + 厚薄暗带 + 底部水垢**。

    瓶玻璃是"有色且厚"的透光体：色比清水玻璃深得多（0.07~0.30 级），
    竖纹（模具分界/吹制痕迹）2.5 cm 一道，加上水垢/液面痕（≥8 cm，守 25% 门禁）。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    base = b.mixc(b.noise(b.vec(b.mul(u, 1.8), b.mul(v, 1.8), 5.0), 1.0, 4.0),
                  (0.075, 0.165, 0.090), (0.195, 0.365, 0.215))
    # 模制竖纹（沿 v 的细道，2.5 cm 一道）+ 厚玻璃暗带（5~9 cm）
    stria = b.pow(b.pisin(b.frc(b.div(b.add(u, b.mul(b.sub(b.noise(b.vec(b.mul(v, 1.6), 3.0, 9.0), 1.0, 3.0), 0.5), uv_cm(1.5))), uv_cm(2.5)))), 0.6)
    base = b.mul_c(base, b.lin(stria, 0.0, 1.0, 0.80, 1.22))
    thick = b.noise(b.vec(b.mul(u, 7.0), b.mul(v, 1.4), 23.0), 1.0, 4.0)
    base = b.mul_c(base, b.lin(thick, 0.30, 0.80, 0.78, 1.12))
    # 气泡（1~3 cm）
    bub = b.ss(b.noise(b.vec(b.mul(u, 30.0), b.mul(v, 30.0), 37.0), 1.0, 4.0), 0.72, 0.84)
    base = b.mixc(b.mul(bub, 0.40), base, (0.300, 0.480, 0.380))
    # 底部水垢/积尘（哑、发白）
    scum = b.mul(b.ss(b.noise(b.vec(b.mul(u, 5.0), b.mul(v, 5.0), 41.0), 1.0, 4.0), 0.52, 0.82),
                 b.mul(_v_ground(b, v, 0.12), b.lin(wear, 0.0, 1.0, 0.45, 1.0)))
    col = b.mixc(scum, base, (0.300, 0.330, 0.270))

    h = b.add(b.mul(stria, 0.45), b.mul(b.sub(thick, 0.5), 0.30))
    trans = b.lin(thick, 0.30, 0.80, 0.82, 0.58)
    trans = b.mul(trans, b.sub(1.0, b.mul(scum, 0.75)))
    rough = b.add(b.lin(thick, 0.0, 1.0, 0.045, 0.105), b.mul(scum, 0.30))
    emit = b.mul_c(base, 0.30)                     # 弱托底：绝不读成"黑瓶子"
    return dict(color=col, rough=rough, metal=0.0, trans=trans,
                emit=emit, emit_str=0.42, ior=1.52, spec=0.60,
                normal=b.bump(h, 0.30, uv_cm(1.6)))


def _b_crystal(b, gi, bsdf):
    """魔法水晶：**大晶面（12 cm）+ 内部辉光 + 乳白包裹体 + 闪点**。

    上一版的两个坑（实物渲染抓到的）：
      ① 晶面 5.5 cm 太小、色差太大 → 在 30~100 px 的晶体上读成"马赛克帽子 / 巫女帽"，
         不像水晶；自然水晶是一根柱上**只有两三个大面**。
      ② 气泡/近白面把晶体提亮成白斑 → 失去宝石质感。
    这一版：晶面放大到 12 cm（一根晶体上 2~3 个面）、面色差压到 ±18%、去掉近白面；
    "内部发光"由**格心亮 / 格边暗**给出（薄处透、厚边深），另外几何本身是
    六棱柱 + 锥尖（见探针 `shard()`），面与面的明暗转折由实时光照提供。
    """
    u, v = _uv(b, gi)
    cw = ch = uv_cm(12.0)
    c = _cells(b, u, v, cw, ch, stagger=0.5, seed=9.0, jitter=0.35)
    r1, r2, r3 = c['rand'], c['rand2'], c['rand3']
    rx = b.absv(b.sub(b.mul(c['fu'], 2.0), 1.0))
    ry = b.absv(b.sub(b.mul(c['fv'], 2.0), 1.0))
    r = b.pow(b.add(b.pow(rx, 2.2), b.pow(ry, 2.2)), 1.0 / 2.2)
    face = b.sub(1.0, b.ss(r, 0.70, 0.98))
    edge = b.sub(1.0, b.ss(r, 0.86, 1.04))

    # ---- 晶面色：紫水晶/蓝晶为主，少数浅色水晶；差幅压到 ±18%
    col = b.mixc(r1, (0.165, 0.052, 0.350), (0.300, 0.092, 0.485))
    col = b.mixc(b.ss(r2, 0.68, 0.90), col, (0.430, 0.480, 0.720))
    col = b.mixc(b.lin(r3, 0.92, 0.995, 0.0, 0.45), col, (0.620, 0.640, 0.790))
    col = b.mul_c(col, b.lin(r1, 0.0, 1.0, 0.84, 1.18))
    # ---- 乳白包裹体（棉絮，雾）
    mil = b.ss(b.noise(b.vec(b.mul(u, 5.0), b.mul(v, 5.0), 5.0), 1.0, 5.0, 0.55), 0.54, 0.86)
    col = b.mixc(b.mul(mil, 0.30), col, (0.560, 0.590, 0.700))
    # ---- 内部辉光：面心亮、厚边暗（宝石"内发光"的来源）
    glow = b.mixc(b.mul(b.sub(1.0, edge), 0.85), b.mul_c(col, 0.42), b.mul_c(col, 1.30))
    spark = b.ss(b.noise(b.vec(b.mul(u, 30.0), b.mul(v, 30.0), 21.0), 1.0, 3.0), 0.82, 0.92)
    emit = b.mixc(b.mul(spark, 0.88), glow, (1.700, 1.700, 2.000))

    trans = b.mul(b.mixf(edge, 0.85, 0.42), b.lin(mil, 0.0, 1.0, 1.0, 0.55))
    rough = b.add(b.lin(r1, 0.0, 1.0, 0.040, 0.110), b.mul(mil, 0.05))
    # 晶面起伏**克制**：面与面的明暗转折应由几何（六棱柱 + 锥尖）与实时法线给出，
    # 材质里的"格界"做深了会在平面样片上读成"瓷砖 + 灰缝"（一轮的坑）。
    h = b.add(b.mul(face, 0.45), b.mul(edge, 0.15))
    h = b.add(h, b.mul(b.sub(mil, 0.5), 0.18))
    return dict(color=col, rough=rough, metal=0.0, trans=trans,
                emit=emit, emit_str=0.95, ior=1.62, spec=0.62,
                normal=b.bump(h, 0.25, uv_cm(2.0)))


def _b_rune_glow(b, gi, bsdf):
    """符文石刻：**深色花岗岩底 + 凹刻符文（自发光刻痕）**。

    三层结构（守 25% 门禁）：
      ① 30 cm 一道的**雕刻带凹槽**（粗结构，25% 下 5.7 px 读得出"这是一条刻带"）；
      ② 26×30 cm 的**符文格**：一格 = 一条微斜的竖脊 + 2~4 条左右短划（"哪几条出现 /
         多长 / 在什么高度"全部由哈希决定）→ 一笔一划拼出来的字形，不是噪声；
      ③ **刻痕发光 + 外围弱辉**：自发光是唯一能在 1/4 像素下"跳出来"的信息，
         所以除了 2.5 cm 的亮刻痕，还画一层 8~9 cm 的宽软辉（0.30 强度）当"渗光"，
         并用"软辉 − 刻痕"得到刻槽的**倒角肩**（凿刻的受光斜面）。
    行与行**错开半格**：不做错缝时全部竖脊落在同一列上，整面会被读成"条纹 / 电路板"
    （一轮渲染就是这么翻车的）。刻槽本身压暗（凹处不反射环境光），辉光落在槽沿与周围石面上。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    sw, sh = uv_cm(26.0), uv_cm(30.0)
    sv = b.div(v, sh)
    ri = b.flr(sv)
    su = b.add(b.div(u, sw), b.mul(b.frc(b.div(ri, 2.0)), 0.5))     # 错半格
    ci = b.flr(su)
    lu, lv = b.sub(su, ci), b.sub(sv, ri)
    lx = b.lin(lu, 0.20, 0.80, 0.0, 1.0)
    ly = b.lin(lv, 0.22, 0.78, 0.0, 1.0)

    def _bar(d, hw):
        """到某条线的距离 → 笔画掩码（hw 为半宽，格内归一化）。"""
        return b.sub(1.0, b.ss(b.absv(d), 0.0, hw))

    gate = b.ss(b.h2(ci, ri, 3.0), 0.24, 0.32)
    strokes = []
    # 竖脊（可微斜、可左右偏）
    tilt = b.mul(b.sub(b.h2(ci, ri, 11.0), 0.5), 0.26)
    o1 = b.mul(b.sub(b.h2(ci, ri, 13.0), 0.5), 0.20)
    strokes.append((b.sub(lx, b.add(0.5, b.add(o1, b.mul(tilt, b.sub(ly, 0.5))))), 1.0))
    # 四条短划：两条向右、两条向左（高度 / 长度 / 是否出现 全由哈希决定）
    for i, k in enumerate((23.0, 33.0, 43.0, 53.0)):
        y0 = b.add(0.16, b.mul(b.h2(ci, ri, k), 0.66))
        ln = b.add(0.16, b.mul(b.h2(ci, ri, k + 1.0), 0.32))
        on = b.ss(b.h2(ci, ri, k + 2.0), 0.28, 0.38)
        if i % 2 == 0:
            ext = b.mn(b.ss(lx, 0.44, 0.50),
                       b.sub(1.0, b.ss(lx, b.add(0.50, ln), b.add(0.58, ln))))
        else:
            ext = b.mn(b.sub(1.0, b.ss(lx, 0.50, 0.56)),
                       b.ss(lx, b.sub(0.42, ln), b.sub(0.50, ln)))
        strokes.append((b.sub(ly, y0), b.mul(ext, on)))
    core, soft = None, None
    for (d, mask) in strokes:
        c_ = b.mul(_bar(d, 0.058), mask)
        s_ = b.mul(_bar(d, 0.190), mask)
        core = c_ if core is None else b.mx(core, c_)
        soft = s_ if soft is None else b.mx(soft, s_)
    core = b.mul(core, gate)
    soft = b.mul(soft, gate)
    rim = b.mx(b.sub(soft, core), 0.0)               # 刻槽倒角肩（受光斜面）

    # ---- 花岗岩底：暗蓝灰 + 逐格明度 + 凿面棱面 + 石面颗粒（不能压到近黑：
    #      刻痕要"从石头里透出来"，底太黑就变成一块黑板上的霓虹字）
    stone = b.mixc(b.h2(ci, ri, 67.0), (0.078, 0.084, 0.098), (0.148, 0.154, 0.172))
    mott = b.noise(b.vec(b.mul(u, 6.0), b.mul(v, 6.0), 7.0), 1.0, 6.0, 0.6)
    stone = b.mul_c(stone, b.lin(mott, 0.25, 0.78, 0.78, 1.24))
    fd, fc, _fp = b.voro(b.vec(b.div(u, uv_cm(9.0)), b.div(v, uv_cm(9.0)), 3.0),
                         scale=1.0, randomness=0.90)
    fr, _fg, _fb = b.sep_c(fc)
    stone = b.shade(stone, fr, 0.80, 1.24)
    grn = b.noise(b.vec(b.mul(u, 18.0), b.mul(v, 18.0), 13.0), 1.0, 4.0)
    stone = b.mul_c(stone, b.lin(grn, 0.25, 0.75, 0.90, 1.10))
    # ---- 30 cm 一道雕刻带凹槽
    edge = b.mn(lv, b.sub(1.0, lv))
    groove = b.sub(1.0, b.ss(b.mul(edge, sh), uv_cm(0.9), uv_cm(2.4)))
    stone = b.mixc(b.mul(groove, 0.55), stone, b.mul_c(stone, 0.42))

    # ---- 刻痕上色（青为主，少数格为琥珀）+ 倒角肩受光 + 辉光
    glow_c = b.mixc(b.ss(b.h2(ci, ri, 79.0), 0.88, 0.95),
                    (0.400, 0.700, 0.980), (0.980, 0.600, 0.220))
    col = b.mixc(core, stone, (0.030, 0.034, 0.040))          # 刻槽底（未发光时也是暗的）
    col = b.mixc(b.mul(rim, 0.42), col, b.mul_c(stone, 1.85))  # 刻槽倒角肩（凿刻的受光斜面）
    col = b.mixc(b.mul(b.mul(soft, b.sub(1.0, core)), 0.50), col, b.mul_c(glow_c, 0.40))
    emit_amt = b.add(b.mul(core, 0.95),
                     b.mul(b.mul(soft, b.sub(1.0, core)), 0.26))
    emit = b.mul_c(glow_c, emit_amt)

    h = b.mul(b.sub(fr, 0.5), 0.24)
    h = b.add(h, b.mul(b.sub(mott, 0.5), 0.18))
    h = b.sub(h, b.mul(core, 1.00))
    h = b.sub(h, b.mul(b.mul(soft, b.sub(1.0, core)), 0.22))
    h = b.add(h, b.mul(rim, 0.35))
    h = b.sub(h, b.mul(groove, 0.55))
    rough = b.add(b.lin(mott, 0.0, 1.0, 0.72, 0.88), b.mul(core, 0.06))
    _ = wear
    return dict(color=col, rough=rough, metal=0.0, spec=0.22,
                emit=emit, emit_str=0.90, normal=b.bump(h, 0.70, uv_cm(2.2)))


def _b_bronze(b, gi, bsdf):
    """青铜：**暖金铜底 + 锤打棱面 + 凹处铜绿**。

    与 `iron` 的分工：铁是"深灰蓝 + 低粗糙 + 大棱面"（冷、暗、硬），
    铜是"暖橙金 + 略高粗糙 + 铜绿"（暖、亮、氧化）。金属读法同源：靠大而柔和的
    棱面反光而不是细节噪点，所以锤打棱面 7 cm（>5 cm，25% 下 1.3 px 仍是有向的高光）。

    **金属度只给 0.85 而不是 1.0**（实物渲染的教训）：EEVEE 下 metallic=1 的物体
    完全没有漫反射分量，只反射天空/太阳 → 在"只有两盏太阳 + 一个渐变天"的渲染里
    读成**深棕色木框**。留 15% 漫反射，铜才真的是"黄铜"。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    base = (0.470, 0.255, 0.090)
    fd, fc, _fp = b.voro(b.vec(b.div(u, uv_cm(7.0)), b.div(v, uv_cm(7.0)), 3.0),
                         scale=1.0, randomness=0.85)
    fr, fg, _fb = b.sep_c(fc)
    facet = b.lin(fd, 0.05, 0.78, 0.0, 1.0)
    col = b.mixc(b.mul(fr, 0.62), b.mul_c(base, 0.72), b.mul_c(base, 1.44))
    col = b.mixc(b.mul(fg, 0.30), col, b.mul_c(col, 1.12))
    mic = b.noise(b.vec(b.mul(u, 24.0), b.mul(v, 24.0), 11.0), 1.0, 4.0, 0.55)
    col = b.mul_c(col, b.lin(mic, 0.25, 0.75, 0.93, 1.10))
    # ---- 铜绿：凹处/棱角先长（facet 低处），随 Wear 增
    pl = b.noise(b.vec(b.mul(u, 2.6), b.mul(v, 2.6), 23.0), 1.0, 5.0, 0.55)
    pm = b.mul(b.ss(pl, 0.52, 0.78),
               b.mul(b.lin(wear, 0.0, 1.0, 0.30, 0.78),
                     b.lin(facet, 0.0, 1.0, 1.20, 0.55)))
    pat_c = b.mixc(b.noise(b.vec(b.mul(u, 9.0), b.mul(v, 9.0), 29.0), 1.0, 4.0),
                   (0.105, 0.235, 0.195), (0.205, 0.395, 0.320))
    col = b.mixc(pm, col, pat_c)
    col = b.mixc(b.mul(b.ss(b.noise(b.vec(b.mul(u, 1.2), b.mul(v, 1.2), 31.0), 1.0, 4.0),
                            0.60, 0.86), 0.26), col, b.mul_c(col, 0.66))   # 大尺度发暗（烟炱/失光）

    rough = b.mixf(pm, b.add(b.lin(facet, 0.0, 1.0, 0.24, 0.42),
                             b.mul(b.sub(mic, 0.5), 0.05)), 0.80)
    met = b.mixf(pm, 0.85, 0.15)
    h = b.add(b.mul(facet, 0.35), b.mul(b.sub(mic, 0.5), 0.22))
    col = _aged(b, u, v, col, 'bronze')
    return dict(color=col, rough=rough, metal=met, spec=0.55,
                normal=b.bump(h, 0.45, uv_cm(1.8)))


def _b_patina(b, gi, bsdf):
    """铜绿（氧化铜/青铜屋面与构件）：**葱皮状结壳 + 露铜划伤 + 锈水滴痕**。

    色相是"灰青绿"而不是"草绿"（草绿会和藤蔓/苔藓混淆）；结壳是**哑**的
    （粗糙度 0.72~0.90、金属度 0.05）—— 这一点必须区别于铜本体（metal 1.0、rough 0.2），
    否则在游戏尺寸下"铜顶"与"铜绿顶"只是一个色块差别。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    bl = b.noise(b.vec(b.mul(u, 1.6), b.mul(v, 1.6), 5.0), 1.0, 5.0, 0.55)
    crust = b.mixc(bl, (0.068, 0.176, 0.148), (0.268, 0.478, 0.372))
    crust = b.mul_c(crust, b.lin(b.noise(b.vec(b.mul(u, 7.0), b.mul(v, 7.0), 13.0), 1.0, 5.0, 0.6),
                                 0.25, 0.78, 0.88, 1.14))
    flake = b.ss(b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 3.2), 29.0), 1.0, 5.0), 0.50, 0.74)
    crust = b.mixc(b.mul(flake, 0.42), crust, (0.175, 0.330, 0.282))     # 结壳的"葱皮"层次
    # ---- 露铜（划伤/棱角/被摸过）：亮铜色小斑，随 Wear 增
    cop = b.mixc(b.noise(b.vec(b.mul(u, 5.0), b.mul(v, 5.0), 41.0), 1.0, 4.0),
                 (0.190, 0.088, 0.030), (0.420, 0.215, 0.070))
    bare = b.mul(b.ss(b.noise(b.vec(b.mul(u, 4.2), b.mul(v, 4.2), 47.0), 1.0, 5.0, 0.6), 0.62, 0.80),
                 b.lin(wear, 0.0, 1.0, 0.20, 0.85))
    col = b.mixc(bare, crust, cop)
    # ---- 锈水滴痕（竖向条纹：u 高频 / v 低频 → 顺坡下淌的铜绿水）
    drip = b.mul(b.ss(b.noise(b.vec(b.mul(u, 12.0), b.mul(v, 0.9), 53.0), 1.0, 4.0), 0.52, 0.74), 0.30)
    col = b.mixc(drip, col, (0.075, 0.165, 0.135))

    h = b.add(b.mul(b.sub(flake, 0.4), 0.60), b.mul(b.sub(bl, 0.5), 0.30))
    h = b.sub(h, b.mul(bare, 0.30))
    rough = b.mixf(bare, b.lin(bl, 0.0, 1.0, 0.72, 0.90), 0.40)
    met = b.mixf(bare, 0.05, 0.60)
    col = _aged(b, u, v, col, 'patina')
    return dict(color=col, rough=rough, metal=met, spec=0.28,
                normal=b.bump(h, 0.60, uv_cm(2.6)))


# ============================================================ 三轮追加 B：城市地面系
#
# 城市地面（铺装/土路/草地）与墙面的三条差别，决定了这一族的设计：
#   1. **水平面**：`box_project_uv` 在水平面上取 (x, y) 作为 (u, v)，所以 v **不是**高度
#      → 做旧层的 `_v_ground`（近地溅泥）在这一族上毫无意义，一律**不挂 AGE**。
#   2. **逐体色变也不挂**：地面砖块铺装时会切成一块块独立 Object，若给
#      `Object Info > Random`，相邻两块地面会出现"一条硬色阶"（比"全城一个色"更糟）。
#      地砖的"不重复"由**材质内部**的大尺度斑（40~150 cm）承担。
#   3. **可平铺、无接缝**：图案全部是"世界坐标（=UV）的连续函数 + 整数格哈希"，
#      不含任何按对象尺寸定义的锚点 —— 相邻两格地砖在缝上是同一函数取值，天然无缝。
#
# 尺度纪律同全库：细读层照现实尺寸（砾石 2.6 cm、草叶 1.1 cm），
# 但每族都必须有一条 **≥40 cm** 的粗读层（石斑/压实带/湿痕/修剪斑），
# 否则 25% 下 19 px/m 只剩一片灰。


def _setts(b, u, v, cw, ch, stagger=0.5, seed=0.0, jitter=0.25, p=2.4, shrink=0.0):
    """铺装石块场：错缝分格 + 超椭圆圆角（`p` 越大越方）+ 逐块大小不均（shrink）。

    返回 `_cells` 的全部字段 + `r`（格内归一化半径）/`face`/`gap`/`dome`。
    `gap` 的**总宽度 ≈ 2·(1-0.84)·cw/2 ≈ 0.16·cw**（如 9 cm 石块 → 1.4 cm 缝）。
    """
    c = _cells(b, u, v, cw, ch, stagger=stagger, seed=seed, jitter=jitter)
    rx = b.absv(b.sub(b.mul(c['fu'], 2.0), 1.0))
    ry = b.absv(b.sub(b.mul(c['fv'], 2.0), 1.0))
    if shrink:
        s = b.sub(1.0, b.mul(c['rand'], shrink))
        rx = b.div(rx, s)
        ry = b.div(ry, s)
    r = b.pow(b.add(b.pow(rx, p), b.pow(ry, p)), 1.0 / p)
    c['r'] = r
    c['gap'] = b.ss(r, 0.84, 1.00)
    c['face'] = b.sub(1.0, c['gap'])
    c['dome'] = b.sub(1.0, b.ss(r, 0.02, 1.00))          # 面心亮 / 周边暗（圆面受光）
    return c


def _b_sett_paving(b, gi, cfg):
    """铺装地面通用（小石/大石/石板）：**圆面受光 + 深缝填砂 + 顶面磨光 + 湿痕**。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    c = _setts(b, u, v, cfg['cw'], cfg['ch'], cfg.get('stagger', 0.5), cfg['seed'],
               cfg.get('jitter', 0.25), cfg.get('p', 2.4), cfg.get('shrink', 0.10))
    r1, r2, r3 = c['rand'], c['rand2'], c['rand3']

    # ---- 逐块本色：明度 + 冷暖两维摆动（只用一维会读成"同色深浅斑"）
    col = b.mixc(r1, cfg['lo'], cfg['hi'])
    col = b.mixc(b.lin(r2, 0.55, 0.95, 0.0, cfg.get('cool', 0.55)), col, cfg['cool_c'])
    col = b.mixc(b.lin(r3, 0.88, 0.99, 0.0, 0.62), col, b.mul_c(col, cfg.get('dark_mul', 0.52)))
    col = b.mixc(b.lin(r3, 0.0, 0.12, 0.0, 0.45), col, cfg.get('light_c', (0.560, 0.545, 0.505)))
    # 石面颗粒（3~5 cm）
    mott = b.noise(b.vec(b.mul(u, 12.0), b.mul(v, 12.0), 7.0), 1.0, 5.0, 0.6)
    col = b.mul_c(col, b.lin(mott, 0.25, 0.78, 0.88, 1.12))
    # 圆面受光（面心亮 → 小块也有立体感）
    col = b.shade(col, c['dome'], cfg.get('dome_lo', 0.46), cfg.get('dome_hi', 1.16))
    # ---- 缝：砂/湿泥填缝 + AO（缝必须**深**，否则铺装读成"花纹地垫"）
    fill = b.mixc(b.noise(b.vec(b.mul(u, 8.0), b.mul(v, 8.0), 11.0), 1.0, 4.0),
                  cfg['fill_lo'], cfg['fill_hi'])
    col = b.mixc(b.mul(c['gap'], cfg.get('fill_amt', 0.62)), col, b.mul_c(fill, cfg.get('fill_mul', 0.60)))
    ao = b.ss(c['r'], 0.94, 1.06)
    col = b.mul_c(col, b.lin(ao, 0.0, 1.0, 1.0, 0.58))
    # ---- 尘土薄层（20~40 cm 断续）
    dustn = b.noise(b.vec(b.mul(u, 3.0), b.mul(v, 3.0), 23.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(dustn, 0.45, 0.80), cfg.get('dust', 0.40)), col, cfg['dust_c'])
    # ---- 粗读层：40~90 cm 干/湿斑（守 25% 门禁的那一层）
    pat = b.lin(b.noise(b.vec(b.mul(u, 1.0), b.mul(v, 1.0), 31.0), 1.0, 4.0), 0.28, 0.76, 0.0, 1.0)
    col = b.mul_c(col, b.lin(pat, 0.0, 1.0, 0.84, 1.14))
    # ---- 缝里零星地衣/苔（只在缝内，量少；多了整块地发绿）
    if cfg.get('moss', 0.0) > 0.0:
        lich = b.ss(b.noise(b.vec(b.mul(u, 2.2), b.mul(v, 2.2), 37.0), 1.0, 5.0), 0.62, 0.80)
        col = b.mixc(b.mul(b.mul(lich, c['gap']), b.mul(cfg['moss'], b.lin(wear, 0.2, 1.0, 0.6, 1.0))),
                     col, (0.185, 0.205, 0.130))
    # ---- 湿痕（踩过/雨后未干）：压暗 + 降粗糙（石板明显，小石轻）
    wet = b.mul(b.ss(b.noise(b.vec(b.mul(u, 0.9), b.mul(v, 0.9), 41.0), 1.0, 4.0), 0.50, 0.78),
                cfg.get('wet', 0.0))
    col = b.mixc(wet, col, b.mul_c(col, 0.62))

    h = b.add(b.mul(c['dome'], cfg.get('bump', 0.85)), b.mul(b.sub(mott, 0.5), 0.25))
    h = b.sub(h, b.mul(c['gap'], cfg.get('gap_depth', 1.15)))
    rough = b.add(b.lin(c['dome'], 0.0, 1.0, cfg.get('rough_gap', 0.94), cfg.get('rough_top', 0.76)),
                  b.mul(dustn, 0.03))
    rough = b.mixf(wet, rough, b.sub(rough, 0.20))
    return dict(color=col, rough=rough, metal=0.0, spec=cfg.get('spec', 0.20),
                normal=b.bump(h, 0.85, uv_cm(2.6)))


def _b_cobble_small(b, gi, bsdf):
    """小方石铺地（9×10 cm，暖灰）：中世纪城街的主力铺装。

    粗读层 = 40~90 cm 干湿斑 + 缝内砂土；细读层 = 逐块明暗冷暖 + 石面颗粒 + 圆面受光。
    """
    return _b_sett_paving(b, gi, dict(
        cw=uv_cm(9.0), ch=uv_cm(10.0), seed=1.0, jitter=0.26, p=2.4, shrink=0.12,
        lo=(0.150, 0.142, 0.128), hi=(0.410, 0.392, 0.356),
        cool=0.55, cool_c=(0.268, 0.300, 0.332), light_c=(0.565, 0.550, 0.510),
        fill_lo=(0.085, 0.078, 0.066), fill_hi=(0.235, 0.208, 0.172),
        dust=0.42, dust_c=(0.470, 0.430, 0.360), moss=0.45, wet=0.35,
        rough_top=0.74, rough_gap=0.94, spec=0.20))


def _b_cobble_large(b, gi, bsdf):
    """大方石铺地（16×17 cm，青灰）：广场/教堂前庭；石块更大、缝更宽、色差更强。"""
    return _b_sett_paving(b, gi, dict(
        cw=uv_cm(16.0), ch=uv_cm(17.0), seed=13.0, jitter=0.36, p=2.6, shrink=0.16,
        lo=(0.135, 0.140, 0.148), hi=(0.430, 0.440, 0.452),
        cool=0.60, cool_c=(0.235, 0.262, 0.300), light_c=(0.610, 0.610, 0.600),
        fill_lo=(0.070, 0.068, 0.062), fill_hi=(0.215, 0.196, 0.168),
        dust=0.34, dust_c=(0.455, 0.435, 0.390), moss=0.60, wet=0.40,
        dome_lo=0.42, dome_hi=1.20, gap_depth=1.35, fill_mul=0.52,
        rough_top=0.76, rough_gap=0.95, spec=0.22))


def _b_stone_flag(b, gi, bsdf):
    """石板铺地（52×40 cm，青灰偏冷）：石板更大更平，**缝宽且填浅砂**。

    一轮的坑：石板取 0.26~0.58 的浅值 + 缝也浅 → 整块读数变成"一片发白的棉花糖"。
    这一版把石板压到 0.20~0.45（中灰），缝填**浅暖砂**（比石板亮）—— 于是 25% 下的
    识别特征变成"中灰面上的一张浅色缝网"（石板路 vs 小方石/砾石靠这一条分辨）。
    湿痕/干斑对比也是它和 cobble 系的主要区分（石板路"一片湿一片干"很明显）。
    """
    return _b_sett_paving(b, gi, dict(
        cw=uv_cm(52.0), ch=uv_cm(40.0), seed=29.0, stagger=0.18, jitter=0.30,
        p=3.2, shrink=0.06,
        lo=(0.200, 0.208, 0.212), hi=(0.455, 0.462, 0.450),
        cool=0.50, cool_c=(0.238, 0.268, 0.278), light_c=(0.575, 0.565, 0.528),
        fill_lo=(0.330, 0.302, 0.250), fill_hi=(0.560, 0.520, 0.440),
        dust=0.30, dust_c=(0.520, 0.495, 0.430), moss=0.28, wet=0.62,
        dome_lo=0.60, dome_hi=1.12, bump=0.55, gap_depth=1.40,
        fill_amt=0.88, fill_mul=1.10,
        rough_top=0.60, rough_gap=0.88, spec=0.26))


def _b_brick_paving(b, gi, bsdf):
    """砖铺地（平铺 21×10 cm，顺砖错缝）：比墙面砖**闷、磨光、缝细**（抹砂不抹灰）。

    与 `brick`（墙）的分工：墙砖靠灰浆缝和磕蚀读"砌"，地砖靠**顶面磨光**
    （人走车压的地方发亮、糙度降到 0.55）+ 砂缝（暖亮）+ 成片的磨损斑读"铺"。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    cw, ch = uv_cm(21.0), uv_cm(10.0)
    c = _cells(b, u, v, cw, ch, stagger=0.5, seed=13.0, jitter=0.06)
    fu, fv, r1, r2, r3, d = c['fu'], c['fv'], c['rand'], c['rand2'], c['rand3'], c['d']
    jw = uv_cm(0.7)                                   # 缝总宽 ≈ 1.4 cm
    face = b.ss(d, b.mul(jw, 0.5), jw)
    seam = b.sub(1.0, face)

    # ---- 逐砖：闷砖红/棕/土黄/灰褐（比墙砖低饱和），少数深砖与泛白砖
    col = b.mixc(r1, (0.185, 0.072, 0.050), (0.470, 0.185, 0.092))
    col = b.mixc(b.lin(r2, 0.55, 0.88, 0.0, 0.62), col, (0.355, 0.218, 0.138))
    col = b.mixc(b.lin(r3, 0.00, 0.18, 0.0, 0.55), col, (0.130, 0.085, 0.072))
    col = b.mixc(b.lin(r2, 0.90, 0.98, 0.0, 0.55), col, (0.560, 0.470, 0.360))
    col = b.mul_c(col, b.lin(r1, 0.0, 1.0, 0.78, 1.16))
    grain = b.noise(b.vec(b.mul(u, 11.0), b.mul(v, 22.0), 13.0), 1.0, 5.0, 0.6)
    col = b.mixc(b.lin(grain, 0.28, 0.76, 0.0, 0.42), col, b.mul_c(col, 0.80))
    # ---- 顶面磨光（砖面中段被踩亮；粗糙度也降）
    top = b.sub(1.0, b.ss(d, jw, b.mul(ch, 0.42)))
    col = b.shade(col, top, 0.88, 1.18)
    # ---- 砂缝（暖亮，衬出砖）
    sand = b.mixc(b.noise(b.vec(b.mul(u, 14.0), b.mul(v, 14.0), 17.0), 1.0, 4.0),
                  (0.330, 0.300, 0.238), (0.470, 0.432, 0.350))
    col = b.mixc(face, sand, col)
    col = b.mixc(b.mul(seam, 0.90), b.mul_c(col, 0.58), col)
    # ---- 缺砖/塌陷（少数格露下面砂土，随 Wear 增）
    broken = b.mul(b.ss(r2, 0.955, 0.995), b.lin(wear, 0.0, 1.0, 0.25, 1.0))
    col = b.mixc(broken, col, (0.115, 0.095, 0.075))
    # ---- 尘土膜 + 磨损斑（50~90 cm，粗读层）
    dustn = b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 3.2), 23.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(dustn, 0.46, 0.82), 0.36), col, (0.455, 0.415, 0.345))
    worn = b.lin(b.noise(b.vec(b.mul(u, 0.95), b.mul(v, 0.95), 43.0), 1.0, 4.0), 0.30, 0.78, 0.0, 1.0)
    col = b.mul_c(col, b.lin(worn, 0.0, 1.0, 0.88, 1.10))
    wet = b.mul(b.ss(b.noise(b.vec(b.mul(u, 1.1), b.mul(v, 1.1), 47.0), 1.0, 4.0), 0.56, 0.80), 0.35)
    col = b.mixc(wet, col, b.mul_c(col, 0.66))

    h = b.add(b.mul(face, 0.85), b.mul(b.sub(grain, 0.5), 0.28))
    h = b.sub(h, b.mul(seam, 1.20))
    h = b.sub(h, b.mul(broken, 0.90))
    rough = b.add(b.lin(top, 0.0, 1.0, 0.90, 0.58), b.mul(b.sub(grain, 0.5), 0.06))
    rough = b.mixf(wet, rough, b.sub(rough, 0.16))
    return dict(color=col, rough=rough, metal=0.0, spec=0.24,
                normal=b.bump(h, 0.75, uv_cm(2.4)))


def _b_dirt_packed(b, gi, bsdf):
    """夯土 / 压实土场（暖砂褐）：**夯窝 + 踩踏带 + 干裂纹 + 土斑**。

    现实对照：夯土用夯具一下下砸实，留下 8~12 cm 的圆浅窝；人车常走的地方被压出
    "亮带"（20~25 cm）；久旱会出细裂纹。三条都在 5 cm 以上，缩到 25% 仍有信息。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    base = (0.415, 0.338, 0.238)
    # ---- 大尺度土斑（1~3 m 的干湿/含砂差）
    col = b.mul_c(base, b.lin(b.noise(b.vec(b.mul(u, 0.42), b.mul(v, 0.42), 3.0), 1.0, 4.0),
                              0.25, 0.78, 0.80, 1.18))
    col = b.mul_c(col, b.lin(b.noise(b.vec(b.mul(u, 1.25), b.mul(v, 1.25), 7.0), 1.0, 5.0),
                             0.25, 0.78, 0.90, 1.10))
    # ---- 夯窝：10 cm 网格的圆浅窝（Voronoi 距离 → 半球凹陷）
    hd, _hc, _hp = b.voro(b.vec(b.mul(u, 1.0 / uv_cm(10.0)), b.mul(v, 1.0 / uv_cm(10.0)), 9.0),
                          scale=1.0, randomness=0.95)
    dent = b.pow(b.sub(1.0, b.ss(hd, 0.10, 0.72)), 0.7)
    dm = b.ss(b.h2(b.flr(b.mul(u, 1.0 / uv_cm(10.0))), b.flr(b.mul(v, 1.0 / uv_cm(10.0))), 23.0),
              0.55, 0.62)
    dent = b.mul(dent, dm)
    col = b.mixc(dent, col, b.mul_c(col, 0.84))
    # ---- 踩踏带（20~25 cm 宽，沿 u 走向；人走出来的亮带 + 更压实）
    band = b.pisin(b.frc(b.div(b.add(v, b.mul(b.sub(b.noise(b.vec(b.mul(u, 0.5), 3.0, 11.0), 1.0, 3.0), 0.5), uv_cm(9.0))),
                           uv_cm(24.0))))
    band = b.pow(band, 0.7)
    col = b.mul_c(col, b.lin(band, 0.0, 1.0, 0.92, 1.14))
    # ---- 土粒 + 小石子（3~6 cm）
    grain = b.noise(b.vec(b.mul(u, 15.0), b.mul(v, 15.0), 13.0), 1.0, 4.0)
    col = b.mul_c(col, b.lin(grain, 0.22, 0.78, 0.88, 1.10))
    pd, _pc, _pp = b.voro(b.vec(b.mul(u, 1.0 / uv_cm(4.5)), b.mul(v, 1.0 / uv_cm(4.5)), 17.0),
                          scale=1.0, randomness=0.95)
    peb = b.mul(b.ss(b.h2(b.flr(b.mul(u, 1.0 / uv_cm(4.5))), b.flr(b.mul(v, 1.0 / uv_cm(4.5))), 29.0),
                     0.78, 0.85),
                b.sub(1.0, b.ss(pd, 0.28, 0.70)))
    col = b.mixc(b.mul(peb, 0.80), col, b.mixc(b.h2(b.flr(b.mul(u, 1.0 / uv_cm(4.5))),
                                                    b.flr(b.mul(v, 1.0 / uv_cm(4.5))), 31.0),
                                              (0.360, 0.330, 0.290), (0.520, 0.500, 0.460)))
    # ---- 干裂纹（久旱的细网裂，20~40 cm 多边形边）
    cr = b.noise(b.vec(b.mul(u, 2.2), b.mul(v, 2.2), 37.0), 1.0, 5.0, 0.6)
    crack = b.mul(b.sub(1.0, b.ss(b.absv(b.sub(cr, 0.5)), 0.0, 0.012)), b.lin(wear, 0.2, 1.0, 0.35, 0.95))
    col = b.mixc(crack, col, (0.190, 0.150, 0.105))
    soggy = b.mul(b.ss(b.noise(b.vec(b.mul(u, 1.4), b.mul(v, 1.4), 41.0), 1.0, 4.0), 0.58, 0.84), 0.30)
    col = b.mixc(soggy, col, (0.245, 0.185, 0.125))

    h = b.mul(b.sub(grain, 0.5), 0.30)
    h = b.sub(h, b.mul(dent, 0.55))
    h = b.add(h, b.mul(band, 0.18))
    h = b.add(h, b.mul(peb, 0.30))
    h = b.sub(h, b.mul(crack, 0.45))
    rough = b.add(b.lin(grain, 0.0, 1.0, 0.94, 0.99), b.mul(b.sub(band, 0.5), 0.02))
    return dict(color=col, rough=rough, metal=0.0, spec=0.10,
                normal=b.bump(h, 0.55, uv_cm(2.4)))


def _b_dirt_mud(b, gi, bsdf):
    """泥地车辙（深褐湿泥）：**两道车辙 + 辙间脊 + 水洼 + 蹄印 + 草屑**。

    车辙是这一族唯一能在 25% 下成立的粗结构（辙距 88 cm → 25% 下 17 px），
    所以辙的存在感必须做足：辙底压暗 + 湿光（粗糙度 0.10 的水洼）+ 辙缘挤起的泥脊。

    **辙距取 0.88 m（≈2 格，一格 0.42 m）**而不是现实的 1.2 m 车轨宽：本库的图案是
    世界坐标程序纹理、地砖按格铺（1 格 = 0.42 m），辙距收到 2 格才能保证"一块 2×2 格
    的地砖里就有一对完整的车辙" —— 否则 2×2 格上只能看到半条辙，读作"一道脏印"。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    base = (0.108, 0.074, 0.048)
    # ---- 泥面基底：含水量不同的斑（大尺度）+ 泥粒
    col = b.mul_c(base, b.lin(b.noise(b.vec(b.mul(u, 0.55), b.mul(v, 0.55), 3.0), 1.0, 4.0),
                              0.25, 0.78, 0.72, 1.38))
    mud_n = b.noise(b.vec(b.mul(u, 9.0), b.mul(v, 9.0), 13.0), 1.0, 5.0, 0.6)
    col = b.mul_c(col, b.lin(mud_n, 0.22, 0.78, 0.82, 1.18))
    # ---- 车辙：v 向周期 88 cm，两道（0.30 / 0.70），宽 13 cm
    tv = b.frc(b.div(v, uv_m(0.88)))

    def _rut(c0):
        dd = b.sub(tv, c0)
        dd = b.absv(dd)
        dd = b.mn(dd, b.sub(1.0, dd))                       # 环绕（周期边界不接缝）
        return b.sub(1.0, b.ss(b.div(dd, uv_cm(6.5)), 0.0, 1.0))

    rut = b.mx(_rut(0.30), _rut(0.70))
    rut_s = b.ss(rut, 0.35, 0.95)
    col = b.mixc(rut_s, col, b.mul_c(col, 0.46))
    # ---- 水洼（辙底积水）：更暗 + 极低粗糙 + 一点冷色反光
    pw = b.ss(b.noise(b.vec(b.mul(u, 3.4), b.mul(v, 3.4), 19.0), 1.0, 5.0, 0.55), 0.50, 0.76)
    puddle = b.mul(rut_s, pw)
    col = b.mixc(puddle, col, (0.042, 0.052, 0.062))
    # ---- 辙间泥脊（被挤起来的湿泥：亮一点、颗粒粗）
    ridge = b.mul(b.sub(1.0, rut_s),
                  b.ss(b.noise(b.vec(b.mul(u, 2.0), b.mul(v, 2.0), 23.0), 1.0, 4.0), 0.40, 0.70))
    col = b.mixc(ridge, col, (0.255, 0.188, 0.115))
    # ---- 蹄印（12×8 cm 椭圆浅坑，Voronoi 格点门控）
    hp = b.voro(b.vec(b.mul(u, 1.0 / uv_cm(12.0)),
                      b.div(b.add(v, b.mul(u, 0.35)), uv_cm(8.0)), 29.0),
                scale=1.0, randomness=0.9)
    hoof = b.mul(b.sub(1.0, b.ss(hp[0], 0.12, 0.38)),
                 b.ss(b.h2(b.flr(b.mul(u, 1.0 / uv_cm(12.0))),
                           b.flr(b.mul(v, 1.0 / uv_cm(8.0))), 31.0), 0.62, 0.74))
    col = b.mixc(b.mul(hoof, 0.85), col, b.mul_c(col, 0.58))
    # ---- 草屑/麦秸（3~8 cm 的亮黄细条，稀；泥路的"活气"）
    st = b.noise(b.vec(b.mul(b.add(u, b.mul(v, 0.7)), 26.0), b.mul(v, 5.0), 37.0), 1.0, 3.0)
    straw_m = b.ss(st, 0.74, 0.88)
    col = b.mixc(b.mul(straw_m, 0.62), col, (0.520, 0.420, 0.190))
    # ---- 车辙外的干土（被挤到两侧、更干更亮）——把辙"衬"出来
    col = b.mixc(b.mul(b.mul(b.sub(1.0, rut_s), 0.30), b.lin(wear, 0.2, 1.0, 0.5, 1.0)),
                 col, (0.295, 0.235, 0.148))

    h = b.mul(b.sub(mud_n, 0.5), 0.34)
    h = b.sub(h, b.mul(rut_s, 1.25))
    h = b.sub(h, b.mul(hoof, 0.50))
    h = b.add(h, b.mul(ridge, 0.45))
    h = b.sub(h, b.mul(puddle, 0.40))
    rough = b.add(b.lin(mud_n, 0.0, 1.0, 0.82, 0.95), b.mul(b.sub(ridge, 0.5), 0.04))
    rough = b.mixf(rut_s, rough, 0.50)
    rough = b.mixf(puddle, rough, 0.10)
    return dict(color=col, rough=rough, metal=0.0, spec=0.24,
                normal=b.bump(h, 1.0, uv_cm(2.6)))


def _b_gravel(b, gi, bsdf):
    """砾石路面（2~8 cm 碎石）：**双尺度砾石 + 压实亮带 + 粉尘**。

    砾石在第一尺度上必然糊（2.6 cm @25% = 0.5 px），所以粗读层压在
    "7 cm 大砾石 + 45 cm 压实带/摊铺斑"上；颜色给足跳变（青灰/砂黄/石英白/铁锈），
    否则 25% 下会与 `sand`/`stone_flag` 混成一族。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    ks = 1.0 / uv_cm(2.8)
    kd, kc, _kp = b.voro(b.vec(b.mul(u, ks), b.mul(v, ks), 5.0), scale=1.0, randomness=0.95)
    ci = b.flr(b.mul(u, ks))
    ri = b.flr(b.mul(v, ks))
    r1, r2 = b.h2(ci, ri, 7.0), b.h2(ci, ri, 19.0)
    stone = b.mul(b.sub(1.0, b.ss(kd, 0.30, 0.78)), 1.0)          # 砾石球顶
    col = b.mixc(r1, (0.190, 0.180, 0.168), (0.500, 0.480, 0.440))
    col = b.mixc(b.lin(r2, 0.62, 0.90, 0.0, 0.70), col, (0.310, 0.325, 0.355))    # 青灰
    col = b.mixc(b.lin(r2, 0.00, 0.14, 0.0, 0.60), col, (0.620, 0.560, 0.400))    # 砂黄
    col = b.mixc(b.lin(r1, 0.94, 0.99, 0.0, 0.75), col, (0.780, 0.780, 0.760))    # 石英白
    col = b.mixc(b.lin(r1, 0.02, 0.06, 0.0, 0.55), col, (0.300, 0.195, 0.120))    # 铁锈
    col = b.mul_c(col, b.lin(b.sub(kd, 0.35), 0.0, 0.6, 0.62, 1.28))              # 砾石明暗（球顶亮）
    # ---- 第二尺度：7 cm 大砾石（稀疏，25% 下 1.3 px，是"砾石"而非"砂"的记号）
    k2 = 1.0 / uv_cm(7.0)
    d2, c2, _p2 = b.voro(b.vec(b.mul(u, k2), b.mul(v, k2), 23.0), scale=1.0, randomness=0.9)
    i2u, i2v = b.flr(b.mul(u, k2)), b.flr(b.mul(v, k2))
    big = b.mul(b.ss(b.h2(i2u, i2v, 31.0), 0.78, 0.86), b.sub(1.0, b.ss(d2, 0.28, 0.74)))
    c2r, _c2g, _c2b = b.sep_c(c2)
    col = b.mixc(b.mul(big, 0.85),
                 col, b.mixc(b.h2(i2u, i2v, 37.0), (0.280, 0.290, 0.300), (0.560, 0.545, 0.500)))
    # ---- 压实带 / 摊铺斑（45~90 cm，粗读层）+ 粉尘膜
    cmp_ = b.lin(b.noise(b.vec(b.mul(u, 0.62), b.mul(v, 0.62), 41.0), 1.0, 4.0), 0.28, 0.78, 0.0, 1.0)
    col = b.mul_c(col, b.lin(cmp_, 0.0, 1.0, 0.86, 1.16))
    dust = b.mul(b.ss(b.noise(b.vec(b.mul(u, 2.4), b.mul(v, 2.4), 43.0), 1.0, 5.0), 0.44, 0.80), 0.42)
    col = b.mixc(dust, col, (0.520, 0.478, 0.392))
    wet = b.mul(b.ss(b.noise(b.vec(b.mul(u, 1.1), b.mul(v, 1.1), 47.0), 1.0, 4.0), 0.58, 0.82),
                b.lin(wear, 0.0, 1.0, 0.35, 0.75))
    col = b.mixc(wet, col, b.mul_c(col, 0.70))

    h = b.mul(stone, 0.85)
    h = b.add(h, b.mul(big, 0.55))
    h = b.add(h, b.mul(b.sub(cmp_, 0.5), 0.20))
    rough = b.add(b.lin(b.sub(kd, 0.3), 0.0, 0.7, 0.80, 0.96), b.mul(dust, 0.03))
    rough = b.mixf(wet, rough, b.sub(rough, 0.18))
    return dict(color=col, rough=rough, metal=0.0, spec=0.14,
                normal=b.bump(h, 0.95, uv_cm(1.4)))


def _b_grass_lawn(b, gi, bsdf):
    """修剪草坪：**草簇圆面 + 双向细草纹 + 修剪斑 + 稀疏小花**。

    上一版踩的坑（实物渲染抓到）：想做"三向草叶 + 区域主方向"，结果 `pisin(frc(x/bw))`
    式的草叶场在 1.1 cm 位宽下必然连成**长斜条**，整块读成"斜纹布/灯芯绒"。
    结论：76 px/m 下**单根草叶（0.8 px）画不出来**，草坪的读法只能靠
     ① 4.5 cm 的**草簇**（超椭圆分块 + 圆面受光 + 簇缝暗底 → 一撮一撮）；
     ② 1~2 cm 的细草纹（高频噪声阈值斑 + 弱方向性），只当质感不当结构；
     ③ 20~40 cm 的朝向/密度块 + 60~150 cm 的修剪/干湿斑（粗读层，25% 下 14 px）。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    # ---- 草簇：4.5 cm 一格，超椭圆圆面（簇心亮、簇缝暗）
    cw = ch = uv_cm(4.5)
    c = _cells(b, u, v, cw, ch, stagger=0.5, seed=19.0, jitter=0.42)
    rx = b.absv(b.sub(b.mul(c['fu'], 2.0), 1.0))
    ry = b.absv(b.sub(b.mul(c['fv'], 2.0), 1.0))
    r = b.pow(b.add(b.pow(rx, 2.0), b.pow(ry, 2.0)), 0.5)
    dome = b.sub(1.0, b.ss(r, 0.05, 1.05))
    gapn = b.ss(r, 0.80, 1.05)

    # ---- 细草纹：高频阈值斑 + 弱方向性（两向交叉、各自被噪声打碎 → 不连成条）
    warp = b.mul(b.sub(b.noise(b.vec(b.mul(u, 3.0), b.mul(v, 3.0), 9.0), 1.0, 4.0), 0.5),
                 uv_cm(2.0))
    n1 = b.noise(b.vec(b.add(b.mul(u, 9.0), b.mul(v, 24.0)), b.add(b.mul(warp, 6.0), b.mul(v, 6.0)), 13.0),
                 1.0, 4.0, 0.65)
    n2 = b.noise(b.vec(b.add(b.mul(u, 22.0), b.mul(v, 7.0)), b.mul(v, 5.0), 17.0), 1.0, 4.0, 0.65)
    blade = b.ss(b.mixf(0.5, n1, n2), 0.52, 0.72)

    col = b.mixc(c['rand'], (0.048, 0.118, 0.018), (0.135, 0.300, 0.055))
    col = b.mul_c(col, b.lin(dome, 0.0, 1.0, 0.62, 1.18))          # 簇心受光
    col = b.mul_c(col, b.lin(blade, 0.0, 1.0, 0.80, 1.24))         # 草叶（细质感）
    col = b.mixc(b.mul(gapn, 0.75), col, b.mul_c(col, 0.48))       # 簇缝（暗底）
    # ---- 粗读层：60~150 cm 修剪/干湿斑 + 20~40 cm 朝向块
    patch = b.lin(b.noise(b.vec(b.mul(u, 0.55), b.mul(v, 0.55), 23.0), 1.0, 4.0), 0.28, 0.78, 0.0, 1.0)
    col = b.mul_c(col, b.lin(patch, 0.0, 1.0, 0.78, 1.22))
    block = b.lin(b.noise(b.vec(b.mul(u, 2.6), b.mul(v, 2.6), 29.0), 1.0, 4.0), 0.25, 0.75, 0.0, 1.0)
    col = b.mul_c(col, b.lin(block, 0.0, 1.0, 0.88, 1.12))
    # 干黄斑（踩秃/枯草，量小）
    dry = b.mul(b.ss(b.noise(b.vec(b.mul(u, 1.9), b.mul(v, 1.9), 37.0), 1.0, 5.0), 0.64, 0.86),
                b.lin(wear, 0.0, 1.0, 0.30, 0.80))
    col = b.mixc(b.mul(dry, 0.38), col, (0.320, 0.320, 0.095))
    # 小花（3 cm，稀；白/黄两色）
    fl = b.mul(b.ss(b.noise(b.vec(b.mul(u, 26.0), b.mul(v, 26.0), 41.0), 1.0, 3.0), 0.80, 0.90),
               b.ss(b.noise(b.vec(b.mul(u, 2.2), b.mul(v, 2.2), 43.0), 1.0, 4.0), 0.55, 0.75))
    fic = b.mixc(b.h2(b.flr(b.mul(u, 26.0)), b.flr(b.mul(v, 26.0)), 47.0),
                 (0.840, 0.850, 0.800), (0.900, 0.800, 0.300))
    col = b.mixc(b.mul(fl, 0.75), col, fic)

    h = b.add(b.mul(dome, 0.70), b.mul(b.sub(blade, 0.5), 0.40))
    h = b.sub(h, b.mul(gapn, 0.55))
    rough = b.lin(blade, 0.0, 1.0, 0.90, 0.74)
    return dict(color=col, rough=rough, metal=0.0, spec=0.20,
                sheen=0.18, sheen_rough=0.65, normal=b.bump(h, 0.70, uv_cm(1.4)))


def _b_sand(b, gi, bsdf):
    """细砂地（浅暖黄）：**风纹（不对称垄）+ 砂粒 + 湿砂斑 + 零星砾**。

    风纹是砂地的招牌：波长 24 cm、沿 u 走向（顺风向），迎风坡缓、背风坡陡，
    所以用"抬升后的正弦"取不对称剖面（对称正弦会读成"波纹板"）。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    base = (0.790, 0.712, 0.520)
    col = b.mul_c(base, b.lin(b.noise(b.vec(b.mul(u, 0.45), b.mul(v, 0.45), 3.0), 1.0, 4.0),
                              0.25, 0.78, 0.84, 1.14))
    # ---- 风纹：24 cm 波长 + 沿 u 的蜿蜒（v 向相位被低频噪声推动 → 纹路不直）
    #      迎风坡缓、背风坡陡（`pow(pisin, 1.6)` 不对称化）；**纹脊再压一道细亮线**，
    #      否则一片砂在 76 px/m 下只剩明度渐变，读不出"砂丘纹"。
    wander = b.mul(b.sub(b.noise(b.vec(b.mul(u, 0.55), 3.0, 11.0), 1.0, 3.0), 0.5), uv_cm(9.0))
    ph = b.div(b.add(v, wander), uv_cm(24.0))
    rp = b.pow(b.pisin(ph), 1.6)                      # 不对称化：峰窄谷宽
    col = b.mul_c(col, b.lin(rp, 0.0, 1.0, 0.80, 1.20))
    crest = b.sub(1.0, b.ss(b.absv(b.sub(rp, 0.88)), 0.0, 0.09))      # 风纹脊（亮细线）
    trough = b.sub(1.0, b.ss(b.absv(b.sub(rp, 0.10)), 0.0, 0.10))     # 纹谷（暗细线）
    col = b.mixc(b.mul(crest, 0.35), col, (0.960, 0.900, 0.740))
    col = b.mixc(b.mul(trough, 0.30), col, (0.545, 0.480, 0.330))
    # ---- 砂粒（2~4 cm）+ 零星砾石
    grain = b.noise(b.vec(b.mul(u, 19.0), b.mul(v, 19.0), 13.0), 1.0, 4.0)
    col = b.mul_c(col, b.lin(grain, 0.22, 0.78, 0.90, 1.10))
    gd, _gc, _gp = b.voro(b.vec(b.mul(u, 1.0 / uv_cm(4.0)), b.mul(v, 1.0 / uv_cm(4.0)), 17.0),
                          scale=1.0, randomness=0.95)
    gt = b.ss(b.h2(b.flr(b.mul(u, 1.0 / uv_cm(4.0))), b.flr(b.mul(v, 1.0 / uv_cm(4.0))), 23.0),
              0.88, 0.94)
    peb = b.mul(gt, b.sub(1.0, b.ss(gd, 0.24, 0.62)))
    col = b.mixc(b.mul(peb, 0.80), col, (0.420, 0.395, 0.355))
    # ---- 湿砂斑（80~150 cm：压暗 + 略降粗糙）
    wet = b.mul(b.ss(b.noise(b.vec(b.mul(u, 0.75), b.mul(v, 0.75), 29.0), 1.0, 4.0), 0.54, 0.80),
                b.lin(wear, 0.0, 1.0, 0.40, 0.75))
    col = b.mixc(wet, col, (0.430, 0.370, 0.280))
    # ---- 脚印/扰动痕（15~25 cm 的乱斑）
    tr = b.ss(b.noise(b.vec(b.mul(u, 3.6), b.mul(v, 3.6), 37.0), 1.0, 5.0, 0.5), 0.60, 0.82)
    col = b.mul_c(col, b.lin(tr, 0.0, 1.0, 0.94, 1.08))

    h = b.mul(rp, 0.55)
    h = b.add(h, b.mul(crest, 0.30))
    h = b.sub(h, b.mul(trough, 0.35))
    h = b.add(h, b.mul(b.sub(grain, 0.5), 0.24))
    h = b.add(h, b.mul(peb, 0.25))
    h = b.add(h, b.mul(b.sub(tr, 0.5), 0.22))
    rough = b.mixf(wet, b.add(b.lin(grain, 0.0, 1.0, 0.88, 0.97), 0.0), 0.72)
    return dict(color=col, rough=rough, metal=0.0, spec=0.16,
                normal=b.bump(h, 0.60, uv_cm(2.2)))


def _b_wood_deck(b, gi, bsdf):
    """木铺板（14 cm 宽板条，顺 u 铺）：**风化灰木 + 板端接缝 + 钉头 + 缝内污垢**。

    与 `plank_wall`（墙板）的分工：墙板是暖饱和棕、板缝垂直向下（挂在墙上）；
    铺板是水平面、被踩到**发灰发亮**（日照 + 磨损把木油洗掉），所以色板偏灰褐、
    粗糙度更低，并且有"板端接缝"与"钉头"这两个只有地板才有的记号。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    pal = dict(dark=(0.075, 0.055, 0.038), mid=(0.215, 0.170, 0.125),
               light=(0.375, 0.305, 0.230),
               board_lo=(0.82, 0.82, 0.82), board_hi=(1.16, 1.10, 1.02),
               board_hi2=(1.30, 1.18, 1.00),
               knot=(0.075, 0.052, 0.035), rough=(0.62, 0.80))
    col, h, rough = _wood(b, gi, u, v, uv_cm(14.0), pal, joint_w=uv_cm(0.7),
                          knot_amt=0.7, cracks=0.6, grain_len=1.6)
    # ---- 日照褪色（大尺度，木质：1.2~2 m 斑）
    col = _sun_bleach(b, u, v, col, 0.20, (0.545, 0.520, 0.470))
    # ---- 板端接缝（顺砖式错开：每 60 cm 一列，逐排位置不同）
    sv = b.div(v, uv_cm(14.0))
    row = b.flr(sv)
    eu = b.frc(b.add(b.div(u, uv_cm(60.0)), b.h1(row, 7.0)))
    endj = b.sub(1.0, b.ss(b.mn(eu, b.sub(1.0, eu)), 0.0, uv_cm(0.5) / uv_cm(60.0)))
    endj = b.mul(endj, b.sub(1.0, b.mul(b.ss(b.frc(sv), 0.90, 1.0), 0.4)))
    col = b.mixc(b.mul(endj, 0.85), col, (0.052, 0.036, 0.022))
    # ---- 钉头（每排两端各一颗：3 cm 的暗圆点 + 一点高光）
    nu = b.frc(b.add(b.div(u, uv_cm(30.0)), b.mul(b.h1(row, 19.0), 0.5)))
    nd_ = b.sub(1.0, b.ss(b.mn(nu, b.sub(1.0, nu)), 0.0, uv_cm(1.5) / uv_cm(30.0)))
    nail = b.mul(nd_, b.ss(b.frc(sv), 0.42, 0.52))
    col = b.mixc(b.mul(nail, 0.80), col, (0.135, 0.130, 0.125))
    col = b.mixc(b.mul(b.mul(nail, 0.35), b.ss(b.frc(sv), 0.52, 0.58)),
                 col, (0.520, 0.500, 0.462))
    # ---- 缝内污垢/苔（板缝是唯一积脏的地方）
    grime = b.mul(b.ss(b.frc(sv), 0.84, 1.0), b.lin(wear, 0.0, 1.0, 0.35, 0.95))
    col = b.mixc(b.mul(grime, 0.70), col, (0.115, 0.095, 0.068))
    # ---- 磨损亮带（人走的 30~60 cm 带）+ 湿痕
    wd = b.lin(b.noise(b.vec(b.mul(u, 0.75), b.mul(v, 2.2), 41.0), 1.0, 4.0), 0.30, 0.78, 0.0, 1.0)
    col = b.mul_c(col, b.lin(wd, 0.0, 1.0, 0.90, 1.12))
    wet = b.mul(b.ss(b.noise(b.vec(b.mul(u, 1.3), b.mul(v, 1.3), 43.0), 1.0, 4.0), 0.56, 0.80), 0.35)
    col = b.mixc(wet, col, b.mul_c(col, 0.68))

    h = b.add(h, b.mul(endj, -0.35))
    h = b.sub(h, b.mul(b.mul(nail, 0.7), 0.25))
    h = b.sub(h, b.mul(grime, 0.45))
    rough = b.add(rough, b.mul(grime, 0.06))
    rough = b.mixf(wet, rough, b.sub(rough, 0.22))
    rough = b.mixf(wd, rough, b.sub(rough, 0.08))
    return dict(color=col, rough=rough, metal=0.0, spec=0.26,
                normal=b.bump(h, 0.80, uv_cm(2.2)))


# ============================================================ 注册表
_BUILDERS = {
    # ---- 原有 12 个（名字与语义不变）----
    'thatch':       (lambda b, gi, bsdf: _b_thatch(b, gi, bsdf, 'new'), '茅草（新）'),
    'thatch_old':   (lambda b, gi, bsdf: _b_thatch(b, gi, bsdf, 'old'), '茅草（旧/发霉）'),
    'tile_roof':    (_b_tile_roof, '陶瓦（筒板瓦）'),
    'slate_roof':   (_b_slate_roof, '石板瓦'),
    'plank_wall':   (_b_plank_wall, '横向木板墙'),
    'timber':       (_b_timber, '深色木骨梁'),
    'plaster':      (_b_plaster, '暖白抹灰'),
    'stone':        (_b_stone, '粗料石砌'),
    'white_stone':  (_b_white_stone, '白石细料'),
    'brick':        (_b_brick, '暖橙红砖'),
    'iron':         (_b_iron, '深色锻铁'),
    'canvas':       (_b_canvas, '麻布'),
    # ---- 本轮新增（补齐缺口）----
    'cavity':       (_b_cavity, '室内暗腔'),
    'water':        (_b_water, '深色水面'),
    'lamp':         (_b_lamp, '自发光灯玻璃'),
    'straw':        (_b_straw, '散稻草'),
    'rope':         (_b_rope, '麻绳'),
    'sack':         (_b_sack, '粗麻袋布'),
    'glass_win':    (_b_glass_win, '窗玻璃'),
    'wattle':       (_b_wattle, '编条篱/泥笆'),
    'shingle':      (_b_shingle, '木瓦'),
    'log_wall':     (_b_log_wall, '原木横叠墙'),
    'ground':       (_b_ground, '地面（沙土+草簇）'),
    'grass_tuft':   (_b_grass_tuft, '独立草簇（alpha）'),
    'foliage':      (_b_foliage, '阔叶绿植'),
    'vine':         (_b_vine, '攀爬藤'),
    # ---- 二轮追加（道具扩充；既有 26 个 key 未改动）----
    'cloth_red':    (_b_cloth_red, '染布·茜红'),
    'cloth_blue':   (_b_cloth_blue, '染布·靛蓝'),
    'cloth_ochre':  (_b_cloth_ochre, '染布·赭黄'),
    'wicker':       (_b_wicker, '柳条编'),
    'clay':         (_b_clay, '无釉红陶'),
    'produce':      (_b_produce, '叶菜堆'),
    'produce_root': (_b_produce_root, '根菜堆'),
    'fish':         (_b_fish, '鱼皮'),
    'bread':        (_b_bread, '面包皮'),
    'dye_bath':     (_b_dye_bath, '染缸液面'),
    # ---- 三轮追加 A（玻璃系 / 魔法元素；二轮 36 key 未改动）----
    'stained_glass': (_b_stained_glass, '教堂彩窗（宝石色块+铅条）'),
    'glass_lead':   (_b_glass_lead, '铅条窗（菱形分格）'),
    'glass_clear':  (_b_glass_clear, '清水玻璃'),
    'glass_bottle': (_b_glass_bottle, '瓶玻璃（绿/厚）'),
    'crystal':      (_b_crystal, '魔法水晶（半透明+内发光）'),
    'rune_glow':    (_b_rune_glow, '符文石刻（自发光刻痕）'),
    'bronze':       (_b_bronze, '青铜（锤打+铜绿）'),
    'patina':       (_b_patina, '铜绿（结壳+露铜）'),
    # ---- 三轮追加 B（城市地面系；均不挂 AGE/OBJ_VAR，理由见该段注释）----
    'cobble_small': (_b_cobble_small, '小方石铺地 9cm'),
    'cobble_large': (_b_cobble_large, '大方石铺地 16cm'),
    'brick_paving': (_b_brick_paving, '砖铺地 21x10cm'),
    'stone_flag':   (_b_stone_flag, '石板铺地 52x40cm'),
    'dirt_packed':  (_b_dirt_packed, '夯土/压实土'),
    'dirt_mud':     (_b_dirt_mud, '泥地车辙'),
    'gravel':       (_b_gravel, '砾石路面'),
    'grass_lawn':   (_b_grass_lawn, '修剪草坪'),
    'sand':         (_b_sand, '细砂地（风纹）'),
    'wood_deck':    (_b_wood_deck, '木铺板 14cm'),
}

ORDER = ['thatch', 'thatch_old', 'tile_roof', 'slate_roof',
         'plank_wall', 'timber', 'plaster', 'stone',
         'brick', 'iron', 'white_stone', 'canvas',
         'cavity', 'water', 'lamp', 'glass_win',
         'shingle', 'log_wall', 'straw', 'rope',
         'sack', 'wattle', 'ground', 'grass_tuft',
         'foliage', 'vine',
         'cloth_red', 'cloth_blue', 'cloth_ochre', 'wicker', 'clay',
         'produce', 'produce_root', 'fish', 'bread', 'dye_bath',
         'stained_glass', 'glass_lead', 'glass_clear', 'glass_bottle',
         'crystal', 'rune_glow', 'bronze', 'patina',
         'cobble_small', 'cobble_large', 'brick_paving', 'stone_flag',
         'dirt_packed', 'dirt_mud', 'gravel', 'grass_lawn', 'sand', 'wood_deck']

#: 需要 alpha 混合的 key（裁切用贴片）
ALPHA_KEYS = {'grass_tuft'}

#: 每族的"现实特征尺寸"（cm），供 audit() 打印 texel density 对照。
#: 含做旧层的特征（近地溅泥带/雨渍/日照褪色斑）——**必须 ≥35 cm**：25% 下 <7px
#: 的脏点只会把材质糊成"脏"，不增加信息量。
FEATURES = {
    'thatch':      [("草茎宽", 2.8), ("细茎宽", 1.5), ("草层高", 27.0), ("一撮（9 茎）", 25.0),
                    ("大尺度斑驳", 50.0), ("日照褪色斑", 180.0)],
    'thatch_old':  [("草茎宽", 2.8), ("草层高", 27.0), ("霉斑", 25.0),
                    ("大尺度斑驳", 50.0), ("日照褪色斑", 180.0)],
    'tile_roof':   [("瓦宽", 15.0), ("每排露高", 16.0), ("瓦垄拱高", 2.5), ("同排缝", 1.5),
                    ("逐瓦批次色差", 15.0), ("破损瓦", 15.0)],
    'slate_roof':  [("石板宽", 26.0), ("每排露高", 13.0), ("上排投影渐变", 6.5), ("竖缝", 1.4),
                    ("逐片色调", 26.0), ("雨渍", 40.0)],
    'plank_wall':  [("板高", 20.0), ("板缝", 1.4), ("木节", 6.0), ("木纹周期", 11.0),
                    ("近地溅泥带", 40.0), ("雨渍", 55.0), ("日照褪色斑", 140.0)],
    'timber':      [("斧劈棱面", 11.0), ("干裂", 2.0), ("木纹周期", 26.0),
                    ("近地溅泥带", 35.0), ("日照褪色斑", 140.0)],
    'plaster':     [("砂粒", 2.5), ("灰浆厚薄斑", 12.0), ("抹刀弧", 30.0), ("剥落片", 25.0),
                    ("细裂", 2.0), ("近地溅泥带", 45.0), ("雨渍", 55.0)],
    'stone':       [("块长", 56.0), ("层高", 28.0), ("砂浆缝", 2.6), ("倒角带", 4.0),
                    ("近地溅泥带", 35.0), ("雨渍", 55.0)],
    'white_stone': [("块长", 38.0), ("层高", 16.0), ("砂浆缝", 1.6), ("倒角带", 2.6),
                    ("近地溅泥带", 30.0)],
    'brick':       [("砖长", 23.0), ("砖高", 8.0), ("灰浆缝", 1.6), ("砖面颗粒", 2.6),
                    ("近地溅泥带", 35.0), ("雨渍", 55.0)],
    'iron':        [("锤打棱面", 9.0), ("锤痕", 2.6), ("氧化斑", 30.0)],
    'canvas':      [("织格", 2.4), ("粗节", 3.5), ("污渍", 40.0)],
    'cavity':      [("（无特征：近全黑）", 0.0)],
    'water':       [("涟漪", 4.0)],
    'lamp':        [("（自发光，强度 2.5）", 0.0)],
    'glass_win':   [("流痕", 30.0), ("灰斑", 12.0)],
    'shingle':     [("木瓦宽", 16.0), ("每排露高", 18.0), ("上排投影渐变", 8.9), ("竖缝", 1.0),
                    ("逐片色调", 16.0), ("日照褪色斑", 140.0)],
    'log_wall':    [("原木径", 26.0), ("圆木弧面", 26.0), ("缝间填泥", 4.0),
                    ("近地溅泥带", 40.0), ("日照褪色斑", 140.0)],
    'straw':       [("草秆宽", 2.0), ("横躺散秆", 2.6), ("斜躺散秆", 3.4), ("成堆起伏", 35.0),
                    ("日照褪色斑", 180.0)],
    'rope':        [("捻距", 3.6), ("股径", 1.2), ("纤维", 0.5)],
    'sack':        [("织格", 3.4), ("粗细跳变", 6.0)],
    'wattle':      [("立桩宽", 2.8), ("横编条距", 9.0), ("泥底斑", 25.0),
                    ("近地溅泥带", 45.0)],
    'ground':      [("草簇", 15.0), ("碎石粒", 5.0), ("低频色斑", 100.0), ("土粒", 4.0)],
    'grass_tuft':  [("草叶位宽", 2.2), ("草叶净宽", 1.1), ("草叶高(中值)", 30.0)],
    'foliage':     [("叶片", 7.0), ("叶脉", 1.0)],
    'vine':        [("叶片", 6.0), ("藤茎间距", 14.0)],
    # ---- 二轮追加 ----
    'cloth_red':   [("织格", 2.4), ("染斑", 30.0), ("折痕间距", 18.0)],
    'cloth_blue':  [("织格", 2.4), ("染斑", 30.0), ("折痕间距", 18.0)],
    'cloth_ochre': [("织格", 2.4), ("染斑", 30.0), ("折痕间距", 18.0)],
    'wicker':      [("柳条行距", 2.6), ("立桩距", 5.5)],
    'clay':        [("轮制旋纹", 2.2), ("窑变斑", 40.0), ("陶土颗粒", 3.0)],
    'produce':     [("叶单元", 9.0), ("叶脉", 1.2)],
    'produce_root': [("根菜长", 30.0), ("根菜粗", 11.0)],
    'fish':        [("鳞宽", 2.6), ("鳞排高", 1.8), ("虹彩斑", 25.0)],
    'bread':       [("割痕间距", 6.0), ("脆壳斑", 22.0), ("浮粉", 12.0)],
    'dye_bath':    [("涡纹", 14.0), ("浮沫", 4.0)],
    # ---- 三轮追加 A：玻璃系 / 魔法元素（自发光/透射在括号里标出强度）----
    'stained_glass': [("彩色玻璃块", 13.0), ("铅条宽", 1.8), ("块内气泡", 2.0),
                      ("（自发光托底 0.75 / 透射 0.62）", 0.0)],
    'glass_lead':  [("菱形玻璃块", 9.0), ("铅条宽", 1.9), ("波筋", 6.0), ("气泡", 2.0),
                    ("（自发光托底 0.34 / 透射 0.82）", 0.0)],
    'glass_clear': [("灰雾斑", 8.0), ("擦痕道距", 4.0), ("假反射斜带", 45.0), ("底部积尘带", 14.0),
                    ("（透射 0.35~0.94）", 0.0)],
    'glass_bottle': [("模制竖纹", 2.5), ("厚玻璃暗带", 9.0), ("气泡", 2.0), ("底部水垢带", 12.0),
                     ("（透射 0.66~0.88）", 0.0)],
    'crystal':     [("晶面", 5.5), ("乳白包裹体", 8.0), ("闪点", 1.6), ("内部辉光", 5.5),
                    ("（自发光 0.9 / 透射 0.28~0.80）", 0.0)],
    'rune_glow':   [("符文格", 26.0), ("刻痕宽", 2.4), ("辉光晕", 9.0), ("雕刻带凹槽", 30.0),
                    ("（自发光 1.2，刻痕+渗光）", 0.0)],
    'bronze':      [("锤打棱面", 7.0), ("锤痕", 2.0), ("铜绿斑", 30.0)],
    'patina':      [("结壳葱皮", 30.0), ("露铜斑", 12.0), ("滴痕", 8.0)],
    # ---- 三轮追加 B：城市地面系（粗读层 ≥40cm 是过 25% 门禁的那一层）----
    'cobble_small': [("石块", 9.0), ("石缝", 1.4), ("干湿斑（粗读层）", 42.0), ("尘土膜", 33.0)],
    'cobble_large': [("石块", 16.0), ("石缝", 2.6), ("干湿斑（粗读层）", 42.0), ("深石斑", 60.0)],
    'brick_paving': [("砖", 21.0), ("砂缝", 1.4), ("磨损斑（粗读层）", 75.0), ("尘土膜", 33.0)],
    'stone_flag':   [("石板", 52.0), ("砂缝", 4.8), ("湿痕（粗读层）", 90.0), ("石板色差", 52.0)],
    'dirt_packed':  [("夯窝", 10.0), ("踩踏带", 24.0), ("土斑（粗读层）", 130.0), ("小石子", 4.5)],
    'dirt_mud':     [("车辙距", 105.0), ("辙宽", 13.0), ("水洼", 30.0), ("蹄印", 12.0), ("泥脊斑", 50.0)],
    'gravel':       [("砾石", 2.8), ("大砾石", 7.0), ("压实带（粗读层）", 68.0), ("粉尘膜", 42.0)],
    'grass_lawn':   [("草叶宽", 1.1), ("草簇", 3.3), ("主方向块", 33.0),
                     ("修剪/干湿斑（粗读层）", 76.0), ("小花", 3.0)],
    'sand':         [("风纹波长", 24.0), ("砂粒", 2.2), ("湿砂斑（粗读层）", 130.0), ("扰动斑", 28.0)],
    'wood_deck':    [("板宽", 14.0), ("板缝", 1.4), ("板端接缝", 60.0), ("磨损带（粗读层）", 56.0)],
}

_GROUP_CACHE = {}
_INST_CACHE = {}


def _alive(x):
    """Blender 场景重建（read_factory_settings）后旧 ID 会变成失效 StructRNA。"""
    try:
        x.name
        return True
    except Exception:
        return False


def reset_cache():
    """清空内部缓存。**探针/脚本在 `read_factory_settings` 之后必须调用**：
    模块级缓存会留下已被删除的 Material/NodeGroup 引用，取用时抛
    `StructRNA of type Material has been removed`，随后静默回退纯色、纹理整片消失。
    """
    _GROUP_CACHE.clear()
    _INST_CACHE.clear()


def _get_group(key, force=False):
    if not force and key in _GROUP_CACHE:
        ng = _GROUP_CACHE[key]
        if _alive(ng):
            return ng
        _GROUP_CACHE.pop(key, None)
    if key not in _BUILDERS:
        raise KeyError("未知材质: {}（可用: {}）".format(key, ", ".join(ORDER)))
    ng = bpy.data.node_groups.new("nn_" + key, 'ShaderNodeTree')
    for nm, st, dv in (("Scale", 'NodeSocketFloat', 1.0),
                       ("Tint", 'NodeSocketColor', (1.0, 1.0, 1.0, 1.0)),
                       ("Wear", 'NodeSocketFloat', 0.5)):
        s = ng.interface.new_socket(nm, in_out='INPUT', socket_type=st)
        s.default_value = dv
        try:
            if nm == 'Scale':
                s.min_value, s.max_value = 0.05, 8.0
            if nm == 'Wear':
                s.min_value, s.max_value = 0.0, 1.0
        except Exception:
            pass
    ng.interface.new_socket("Shader", in_out='OUTPUT', socket_type='NodeSocketShader')

    b = B(ng)
    gi = b.nd('NodeGroupInput')
    go = b.nd('NodeGroupOutput')
    bsdf = b.nd('ShaderNodeBsdfPrincipled')
    b.l.new(bsdf.outputs['BSDF'], go.inputs['Shader'])
    res = _BUILDERS[key][0](b, gi, bsdf)

    col = b.mul_c(res['color'], gi.outputs['Tint'])
    b.l.new(col, bsdf.inputs['Base Color'])
    for k, name in (('rough', 'Roughness'), ('metal', 'Metallic'), ('normal', 'Normal'),
                    ('spec', 'Specular IOR Level'), ('sheen', 'Sheen Weight'),
                    ('sheen_rough', 'Sheen Roughness'), ('alpha', 'Alpha'),
                    ('emit', 'Emission Color'), ('ior', 'IOR'),
                    ('coat', 'Coat Weight'), ('trans', 'Transmission Weight')):
        if k not in res:
            continue
        v = res[k]
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            bsdf.inputs[name].default_value = v      # 常数直接设默认值
        elif isinstance(v, (tuple, list)):
            sock = bsdf.inputs[name]
            sock.default_value = tuple(v) + (1.0,) if len(v) == 3 else tuple(v)
        else:
            b.l.new(v, bsdf.inputs[name])
    if 'emit_str' in res:
        bsdf.inputs['Emission Strength'].default_value = float(res['emit_str'])
    for k, v in (('IOR', 1.45), ('Coat Weight', 0.0), ('Diffuse Roughness', 0.0),
                 ('Thin Wall', False)):
        try:
            if 'ior' in res and k == 'IOR':
                continue
            bsdf.inputs[k].default_value = v
        except Exception:
            pass
    _GROUP_CACHE[key] = ng
    return ng


def _instance(key, name=None, scale=1.0, tint=(1.0, 1.0, 1.0), wear=0.5):
    ng = _get_group(key)
    m = bpy.data.materials.new(name or ("mat_" + key))
    nt = m.node_tree
    nt.nodes.clear()
    g = nt.nodes.new('ShaderNodeGroup')
    g.node_tree = ng
    g.location = (0, 0)
    o = nt.nodes.new('ShaderNodeOutputMaterial')
    o.location = (320, 0)
    nt.links.new(g.outputs['Shader'], o.inputs['Surface'])
    m["pbr_family"] = key
    if key in ALPHA_KEYS:
        _set_blend(m)
    if key in GLASS_KEYS:
        _set_glass(m)
    tune(m, scale=scale, tint=tint, wear=wear)
    return m


def _set_glass(mat):
    """玻璃材质：开"瑞利透射"与透射阴影。

    EEVEE Next 里 `Transmission Weight` 只有在这个开关打开时才真的走屏幕空间/瑞利折射；
    否则透射体会被当作不透明 → 整块玻璃渲成**死黑**（这一族最常见的翻车）。
    `use_transparent_shadow` 让窗格投影带一点透（不然玻璃投出实心黑块）。
    """
    for attr, val in (('use_raytrace_refraction', True),
                      ('use_transparent_shadow', True)):
        try:
            setattr(mat, attr, val)
        except Exception:
            pass


def _set_blend(mat):
    """裁切材质：让 Alpha 真的生效（4.2+ 用 surface_render_method，老版用 blend_method）。"""
    for attr, val in (('surface_render_method', 'BLENDED'),
                      ('blend_method', 'BLEND'),
                      ('shadow_method', 'HASHED'),
                      ('show_transparent_back', False)):
        try:
            setattr(mat, attr, val)
        except Exception:
            pass


def tune(mat, scale=None, tint=None, wear=None):
    """调整已有材质的 Scale / Tint / Wear（同一 NodeGroup 可被多实例复用）。"""
    for nd in mat.node_tree.nodes:
        if nd.type == 'GROUP' and nd.node_tree and nd.node_tree.name.startswith("nn_"):
            if scale is not None:
                nd.inputs['Scale'].default_value = scale
            if tint is not None:
                t = tuple(tint)
                nd.inputs['Tint'].default_value = t + (1.0,) if len(t) == 3 else t
            if wear is not None:
                nd.inputs['Wear'].default_value = wear
            return mat
    return mat


# ------------------------------------------------------------ 便捷入口
def _mk(key):
    def f(scale=1.0, tint=(1.0, 1.0, 1.0), wear=0.5, name=None):
        return _instance(key, name=name, scale=scale, tint=tint, wear=wear)
    f.__name__ = "mat_" + key
    f.__doc__ = "{} 材质（Scale/Tint/Wear 可调）".format(_BUILDERS[key][1])
    return f


mat_thatch = _mk('thatch')
mat_thatch_old = _mk('thatch_old')
mat_tile_roof = _mk('tile_roof')
mat_slate_roof = _mk('slate_roof')
mat_plank_wall = _mk('plank_wall')
mat_timber = _mk('timber')
mat_plaster = _mk('plaster')
mat_stone = _mk('stone')
mat_white_stone = _mk('white_stone')
mat_brick = _mk('brick')
mat_iron = _mk('iron')
mat_canvas = _mk('canvas')
mat_cavity = _mk('cavity')
mat_water = _mk('water')
mat_lamp = _mk('lamp')
mat_straw = _mk('straw')
mat_rope = _mk('rope')
mat_sack = _mk('sack')
mat_glass_win = _mk('glass_win')
mat_wattle = _mk('wattle')
mat_shingle = _mk('shingle')
mat_log_wall = _mk('log_wall')
mat_ground = _mk('ground')
mat_grass_tuft = _mk('grass_tuft')
mat_foliage = _mk('foliage')
mat_vine = _mk('vine')
mat_cloth_red = _mk('cloth_red')
mat_cloth_blue = _mk('cloth_blue')
mat_cloth_ochre = _mk('cloth_ochre')
mat_wicker = _mk('wicker')
mat_clay = _mk('clay')
mat_produce = _mk('produce')
mat_produce_root = _mk('produce_root')
mat_fish = _mk('fish')
mat_bread = _mk('bread')
mat_dye_bath = _mk('dye_bath')
mat_stained_glass = _mk('stained_glass')
mat_glass_lead = _mk('glass_lead')
mat_glass_clear = _mk('glass_clear')
mat_glass_bottle = _mk('glass_bottle')
mat_crystal = _mk('crystal')
mat_rune_glow = _mk('rune_glow')
mat_bronze = _mk('bronze')
mat_patina = _mk('patina')
mat_cobble_small = _mk('cobble_small')
mat_cobble_large = _mk('cobble_large')
mat_brick_paving = _mk('brick_paving')
mat_stone_flag = _mk('stone_flag')
mat_dirt_packed = _mk('dirt_packed')
mat_dirt_mud = _mk('dirt_mud')
mat_gravel = _mk('gravel')
mat_grass_lawn = _mk('grass_lawn')
mat_sand = _mk('sand')
mat_wood_deck = _mk('wood_deck')


def make(key, **kw):
    """按注册名创建材质（供装配层统一调用）。"""
    if key not in _BUILDERS:
        raise KeyError("未知材质: {}（可用: {}）".format(key, ", ".join(ORDER)))
    return _instance(key, **kw)


#: 建筑/道具装配层的材质名 → 本库注册名
_ALIAS = {
    "plaster_old": "plaster",
    "wood": "plank_wall", "wood_light": "plank_wall", "wood_dark": "timber",
    "wood_door": "plank_wall", "wood_roof": "plank_wall",
    "tile": "tile_roof", "slate": "slate_roof", "stone_dark": "stone",
    "stone_dark": "stone",
    "glass": "glass_win",
    "glass_window": "glass_win",
    "log": "log_wall", "wood_shingle": "shingle",
    "plant": "foliage", "leaf": "foliage",
    # 三轮追加的常用叫法（装配层/地面系可能用短名；不改动任何既有映射）
    "cobble": "cobble_small", "cobble_big": "cobble_large",
    "flagstone": "stone_flag", "flag": "stone_flag",
    "brick_pave": "brick_paving", "paving": "brick_paving",
    "dirt": "dirt_packed", "mud": "dirt_mud", "road_mud": "dirt_mud",
    "lawn": "grass_lawn", "grass_lawn_wild": "ground",
    "deck": "wood_deck", "bronze_aged": "patina",
    "rune": "rune_glow", "gem": "crystal", "window_stained": "stained_glass",
}


def get(name):
    """按装配层的材质名取材质。

    **任意已注册 key 都能直接取到**（buildings.py 的 `_external_material` 在名称
    不在 alias 表时会直接调 `mod.get(name)`），未知名才返回 None（回退纯色）。
    同名材质会被复用（避免 bpy.data 里堆同名副本）。
    """
    key = _ALIAS.get(name, name)
    if key not in _BUILDERS:
        return None
    hit = _INST_CACHE.get(name)
    if hit is not None and _alive(hit):
        return hit
    m = _instance(key, name=name)
    _INST_CACHE[name] = m
    return m


# ============================================================ 几何工具
def box_project_uv(obj, uv_scale=1.0):
    """按世界坐标做盒式投影 UV：主导轴决定平面，U=水平轴，V=竖直轴（水平面取另一水平轴）。

    1 UV 单位 = 1 格 = 32 px；必须**在设置完物体变换（位置/旋转）之后**调用。
    """
    import bmesh
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    uvl = bm.loops.layers.uv.verify()
    mw = obj.matrix_world
    rot = mw.to_3x3()
    for f in bm.faces:
        n = (rot @ f.normal)
        if n.length < 1e-9:
            n = f.normal
        n.normalize()
        ax = max(range(3), key=lambda i: abs(n[i]))
        for lp in f.loops:
            w = mw @ lp.vert.co
            if ax == 2:            # 水平面（地面/屋面）
                uu, vv = w.x, w.y
            elif ax == 1:          # 法线沿 Y（正面墙）
                uu, vv = w.x, w.z
            else:                  # 法线沿 X（侧面墙）
                uu, vv = w.y, w.z
            lp[uvl].uv = (uu * uv_scale, vv * uv_scale)
    bm.to_mesh(me)
    bm.free()
    me.update()
    return obj


def features(key):
    """该材质的现实特征尺寸清单 [(名称, 厘米), ...]（audit / 报告用）。"""
    return list(FEATURES.get(key, []))


def audit(verbose=False):
    """每族的节点数 + 换算后的现实特征尺寸（texel density 自检）。

    返回 [(key, 说明, nodes, features_str), ...]；verbose 时同时打印。
    """
    rows = []
    for k in ORDER:
        ng = _get_group(k)
        feats = []
        for nm, cm_ in FEATURES.get(k, []):
            if cm_ <= 0.0:
                feats.append(nm)
                continue
            feats.append("%s %.1fcm/%.1fpx@1x/%.1fpx@25%%" % (
                nm, cm_, cm_ * 0.01 / M_PER_UV * 32.0, cm_ * 0.01 / M_PER_UV * 8.0))
        ov = OBJ_VAR.get(k)
        if ov:
            feats.append("逐体色变 hue±%.0f%% val±%.0f%%" % (ov[0] * 100.0, ov[1] * 100.0))
        rows.append((k, _BUILDERS[k][1], len(ng.nodes), "；".join(feats)))
    if verbose:
        print("\n=== 材质清单（特征尺寸 = 现实尺寸 / 游戏 1:1 像素 / 25% 像素）===")
        for r in rows:
            print("%-12s %-14s nodes=%-4d %s" % r)
    return rows


if __name__ == "__main__":
    audit(verbose=True)
