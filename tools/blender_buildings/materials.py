# -*- coding: utf-8 -*-
"""写实西幻建筑程序化 PBR 材质库 v3.1（Blender 5.2 / EEVEE）。

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
}

ORDER = ['thatch', 'thatch_old', 'tile_roof', 'slate_roof',
         'plank_wall', 'timber', 'plaster', 'stone',
         'brick', 'iron', 'white_stone', 'canvas',
         'cavity', 'water', 'lamp', 'glass_win',
         'shingle', 'log_wall', 'straw', 'rope',
         'sack', 'wattle', 'ground', 'grass_tuft',
         'foliage', 'vine',
         'cloth_red', 'cloth_blue', 'cloth_ochre', 'wicker', 'clay',
         'produce', 'produce_root', 'fish', 'bread', 'dye_bath']

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
    tune(m, scale=scale, tint=tint, wear=wear)
    return m


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
    "glass": "glass_win",
    "log": "log_wall", "wood_shingle": "shingle",
    "plant": "foliage", "leaf": "foliage",
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
