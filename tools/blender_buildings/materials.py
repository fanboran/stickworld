# -*- coding: utf-8 -*-
"""写实西幻建筑 PBR 材质库（Blender 5.2 / EEVEE）。

坐标约定（与 `建筑生成管线v3-写实PBR.md` §3.1 §5.1 对齐）
--------------------------------------------------------
* 图案基于 **UV**；1 UV 单位 = 1 Blender 单位 = 1 格 = 32px（`PX_PER_UNIT`）。
* UV 必须用 `box_project_uv()` 做盒式投影：**U = 水平轴，V = 竖直/顺坡轴**
  （水平面取另一水平轴）。这样同一材质贴到任意朝向的墙/屋顶上，砖缝永远水平、
  茅草茎永远顺坡、瓦垄永远横贯。投影基于世界坐标 → 相邻构件的纹理自然对齐。
* 每个材质是一个 NodeGroup，对外暴露 3 个可调参数：
    `Scale` 尺度倍率（>1 = 纹理更大，按"格"标定，默认 1.0 = 规范尺寸）
    `Tint`  色调（与基色相乘，用于同族材质的冷暖/深浅变体）
    `Wear`  做旧 0(全新) ~ 1(残破)，控制污渍/苔藓/缺角/霉斑的强度
* 用法：
    import materials as M
    m = M.mat_thatch(scale=1.0, tint=(1.0,0.95,0.85), wear=0.35)
    M.box_project_uv(obj)          # 几何 UV 投影
    M.tune(m, wear=0.8)            # 事后调参

材质规格（1 格 = 32px）
----------------------
    brick       砖 20x10px, 缝 1.5px
    stone       石块 ~30x18px, 灰浆缝 1.5px
    white_stone 白石饰块 ~16x10px, 细缝 1px
    plank_wall  横板高 20px, 板间色差 + 木纹 29x3px + 木节 3px
    timber      深色木骨: 同族木纹, 手斧棱面, 纵向干裂
    thatch      草层高 16px, 草茎 ~1.8px 宽 / 9px 长, 束宽 4~8px
    tile_roof   瓦 11x10px, 垄高 ~2px, 逐片色差
    slate_roof  石板瓦 13x11px, 错缝, 冷灰 + 风化
    plaster     抹灰: 抹刀痕 + 颗粒 + 剥落斑(露底灰) + 细裂
    iron        铸铁: 麻点(1.6px) + 锤痕 + 锈斑
    canvas      麻布: 经纬织纹 1.2px + 粗节
"""
import bpy

PX_PER_UNIT = 32.0


def px(v):
    """像素 → Blender 单位（1 单位 = 1 格 = 32px）。"""
    return float(v) / PX_PER_UNIT


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
    def op(self, op, a, b=None, clamp=False):
        x = self.nd('ShaderNodeMath', operation=op, use_clamp=clamp)
        self._in(x.inputs[0], a)
        if b is not None:
            self._in(x.inputs[1], b)
        return x.outputs[0]

    def add(self, a, b):
        return self.op('ADD', a, b)

    def sub(self, a, b):
        return self.op('SUBTRACT', a, b)

    def mul(self, a, b):
        return self.op('MULTIPLY', a, b)

    def div(self, a, b):
        return self.op('DIVIDE', a, b)

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

    def pow(self, v, e):
        return self.op('POWER', v, e)

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
        """颜色 × 灰度系数（k 可为常数或 socket→用 shade）。"""
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


# ------------------------------------------------------------ 通用小工具
def _uv(b, gi):
    """取 Scale 归一化后的 UV（返回值 u=水平, v=竖直/顺坡）。"""
    tc = b.nd('ShaderNodeTexCoord')
    inv = b.op('DIVIDE', 1.0, gi.outputs['Scale'])
    uv = b.vop('SCALE', tc.outputs['UV'], inv)
    u, v, _ = b.sep(uv)
    return u, v


def _rows(b, v, h):
    """横向分层（木板/草层）：返回 (sv, row, fv, row_rand, row_rand2)。"""
    sv = b.div(v, h)
    row = b.op('FLOOR', sv)
    fv = b.op('SUBTRACT', sv, row)
    return sv, row, fv, b.white(b.vec(row, 5.0, 2.0)), b.white(b.vec(row, 91.0, 7.0))


def _cells(b, u, v, cw, ch, stagger=0.5, seed=0.0):
    """矩形砌块网格（砖/瓦）：返回 dict(单元格内相对坐标/序号/随机值/到缝距离)。"""
    sv = b.div(v, ch)
    row = b.op('FLOOR', sv)
    rrand = b.white(b.vec(row, 5.0 + seed, 2.0))
    su = b.div(u, cw)
    if stagger:
        su = b.add(su, b.mul(rrand, stagger))
    col = b.op('FLOOR', su)
    fu = b.sub(su, col)
    fv = b.sub(sv, row)
    du = b.mul(b.op('MINIMUM', fu, b.sub(1.0, fu)), cw)
    dv = b.mul(b.op('MINIMUM', fv, b.sub(1.0, fv)), ch)
    d = b.op('MINIMUM', du, dv)
    return dict(sv=sv, row=row, fv=fv, su=su, col=col, fu=fu, d=d,
                rand=b.white(b.vec(col, row, seed)),
                rand2=b.white(b.vec(col, row, seed + 37.0)),
                cell=b.vec(col, row, seed))


# ============================================================ 材质实现
def _b_thatch(b, gi, bsdf, variant='new'):
    """茅草：顺坡草茎 + 层叠起檐 + 束状起伏 + 霉斑。

    草茎做法（关键）：取**各向异性噪声的等值线**做草茎分界 ——
        line = 1 - smoothstep(|noise - 0.5|, 0, w)
    噪声沿 U 密集(1.6px)、沿 V 极长(约 24px)，其 0.5 等值线就是一条条细、硬、
    天然弯曲的竖线，正是草茎之间的暗缝；两层（细/中）+ 长条随机叠加即可。
    直接用平滑噪声当亮度只会得到"刷痕/抹布"，不是茅草。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)

    # ---- 层界：轻微起伏（扰动过大会失去"层"的读法）
    w1 = b.noise(b.vec(b.mul(u, 0.9), b.mul(v, 0.30), 5.0), 1.0, 3.0)
    w2 = b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 0.9), 9.0), 1.0, 3.0)
    vv = b.add(v, b.mul(b.sub(b.mixf(0.5, w1, w2), 0.5), 0.38))
    sv = b.div(vv, 0.50)                                    # 层高 0.50u = 16px
    course = b.op('FLOOR', sv)
    fv = b.sub(sv, course)
    crow = b.white(b.vec(course, 5.0, 2.0))                 # 每层色差
    cthk = b.white(b.vec(course, 61.0, 9.0))

    # ---- 草茎等值线：细茎(1.5px) + 中茎(3px)
    n1 = b.noise(b.vec(b.mul(u, 21.0), b.mul(v, 1.35), 1.0), 1.0, 5.0, 0.5)
    n2 = b.noise(b.vec(b.mul(u, 9.5), b.mul(v, 0.9), 7.0), 1.0, 5.0, 0.5)
    wk = b.lin(cthk, 0.0, 1.0, 0.040, 0.070)                # 层间缝宽随机
    line1 = b.sub(1.0, b.ss(b.op('ABSOLUTE', b.sub(n1, 0.5)), 0.0, wk))
    line2 = b.sub(1.0, b.ss(b.op('ABSOLUTE', b.sub(n2, 0.5)), 0.0, b.mul(wk, 1.5)))
    stem = b.op('MAXIMUM', line1, b.mul(line2, 0.85))       # 茎缝（1=缝）
    # 茎内明暗（沿茎方向的起伏 + 逐茎随机）
    strand = b.white(b.vec(b.op('FLOOR', b.mul(u, 21.0)),
                           b.op('FLOOR', b.mul(v, 0.8)), 17.0))
    inner = b.mixf(0.45, b.lin(n2, 0.2, 0.8, 0.0, 1.0), strand)

    # ---- 层顶：上一层压住（窄而硬的下缘阴影）+ 层檐参差
    lap = b.sub(1.0, b.ss(fv, 0.0, b.lin(cthk, 0.0, 1.0, 0.055, 0.15)))
    tip = b.noise(b.vec(b.mul(u, 15.0), b.mul(vv, 3.0), 23.0), 1.0, 4.0)
    stem = b.mixf(b.mul(b.sub(1.0, lap), b.lin(tip, 0.35, 0.72, 0.35, 1.0)), stem,
                  b.sub(stem, 0.25))
    bundle = b.lin(b.noise(b.vec(b.mul(u, 2.4), b.mul(v, 1.5), 31.0), 1.0, 5.0),
                   0.25, 0.75, 0.0, 1.0)

    if variant == 'old':
        c_dark, c_mid, c_hi = (0.145, 0.115, 0.062), (0.400, 0.320, 0.170), (0.640, 0.545, 0.330)
        c_moss = (0.195, 0.205, 0.130)
    else:
        c_dark, c_mid, c_hi = (0.300, 0.165, 0.045), (0.890, 0.605, 0.205), (1.000, 0.870, 0.450)
        c_moss = (0.285, 0.255, 0.125)

    col = b.ramp(b.mixf(0.35, inner, bundle),
                 [(0.10, c_dark), (0.45, c_mid), (0.85, c_hi)])
    col = b.mixc(stem, b.mul_c(col, 0.62), col)             # 茎缝压暗
    col = b.mixc(lap, b.shade(col, 0.0, 0.74, 1.0), col)    # 层檐阴影
    col = b.mixc(crow, b.mul_c(col, 0.90), col)             # 层色差

    # ---- 霉斑 / 发灰（边界不规则）
    m1 = b.noise(b.vec(b.mul(u, 2.6), b.mul(v, 2.6), 43.0), 1.0, 5.0, 0.6)
    m2 = b.noise(b.vec(b.mul(u, 8.0), b.mul(v, 8.0), 47.0), 1.0, 4.0)
    mold_mask = b.ss(b.mixf(0.5, m1, m2), 0.52, 0.66)
    amt = wear if variant == 'old' else b.mul(wear, 0.22)
    col = b.mixc(b.mul(mold_mask, amt), col, c_moss)

    h = b.add(b.mul(b.sub(1.0, lap), 0.55), b.mul(lap, 0.30))
    h = b.sub(h, b.mul(stem, 0.55))
    h = b.add(h, b.mul(bundle, 0.40))
    h = b.add(h, b.mul(b.sub(tip, 0.5), 0.20))
    rough = b.lin(bundle, 0.0, 1.0, 0.90, 0.97)

    return dict(color=col,
                rough=rough,
                normal=b.bump(h, 0.55, 0.035),
                spec=0.12, sheen=0.25, sheen_rough=0.6)


def _b_tile_roof(b, gi, bsdf):
    """陶瓦（筒板瓦）：横垄 + 逐片色差 + 瓦口出檐阴影 + 瓦缝苔痕。

    关键：**缝必须各向异性** —— 横向（每排瓦口）一道硬而深的阴影，纵向（同排瓦片之间）
    只有极细的暗线。四边等强会读成"编织垫/马赛克"。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    cw, chh = px(11), px(10)
    c = _cells(b, u, v, cw, chh, stagger=0.5)
    fu, fv, r1, r2 = c['fu'], c['fv'], c['rand'], c['rand2']

    crown = b.op('SINE', b.mul(fu, 3.14159265))              # 垄脊（片中央最高）
    # 横向：瓦口（本排下缘）—— 硬深阴影 + 上一排的投影
    seam_row = b.sub(1.0, b.ss(fv, 0.0, 0.085))
    lap = b.ss(fv, 0.02, 0.40)                               # 0=瓦口, 1=瓦面
    # 纵向：同排瓦片间的细缝（弱）
    du = b.mul(b.op('MINIMUM', fu, b.sub(1.0, fu)), cw)
    seam_col = b.sub(1.0, b.ss(du, 0.004, 0.016))

    # 逐片色差：深陶红族 + 少量焦黑/泛白（烧成差异）
    base = b.mixc(r1, (0.245, 0.062, 0.036), (0.495, 0.160, 0.066))
    base = b.mixc(b.lin(r2, 0.78, 0.95, 0.0, 0.75), base, (0.16, 0.055, 0.035))   # 焦瓦
    base = b.mixc(b.lin(r2, 0.0, 0.13, 0.0, 0.5), base, (0.60, 0.34, 0.16))       # 泛白瓦
    base = b.shade(base, crown, 0.80, 1.12)                  # 垄脊受光
    base = b.shade(base, lap, 0.62, 1.04)                    # 瓦口一段压暗（层叠）
    col = b.mixc(b.op('MAXIMUM', seam_col, b.mul(seam_row, 0.85)), base,
                 b.mul_c(base, 0.22))                        # 缝（横重纵轻）
    # 苔痕 / 水渍（积在瓦口与同排缝里）
    moss = b.noise(b.vec(b.mul(u, 4.5), b.mul(v, 4.5), 13.0), 1.0, 5.0, 0.6)
    moss_m = b.mul(b.mul(b.ss(moss, 0.48, 0.68), b.lin(wear, 0.0, 1.0, 0.25, 0.95)),
                   b.op('MAXIMUM', b.mul(seam_row, 0.9), b.mul(b.sub(1.0, lap), 0.5)))
    col = b.mixc(moss_m, col, (0.24, 0.26, 0.13))
    streak = b.noise(b.vec(b.mul(u, 6.5), b.mul(v, 1.0), 31.0), 1.0, 4.0)
    col = b.mixc(b.mul(b.ss(streak, 0.58, 0.82), b.mul(wear, 0.5)), col, (0.14, 0.10, 0.085))
    # 瓦面颗粒（2~3px，不做过细则不可见）
    grn = b.noise(b.vec(b.mul(u, 14.0), b.mul(v, 14.0), 5.0), 1.0, 4.0)
    col = b.mul_c(col, b.lin(grn, 0.25, 0.75, 0.93, 1.06))

    h = b.add(b.mul(crown, 0.60), b.mul(lap, 0.70))
    h = b.sub(h, b.mul(seam_row, 0.9))
    h = b.sub(h, b.mul(seam_col, 0.5))
    h = b.add(h, b.mul(b.sub(grn, 0.5), 0.10))

    return dict(color=col,
                rough=b.add(b.lin(r1, 0.0, 1.0, 0.66, 0.84), b.mul(grn, 0.03)),
                normal=b.bump(h, 0.60, 0.055),
                spec=0.32)


def _b_slate_roof(b, gi, bsdf):
    """石板瓦：错缝平铺、片状硬边、冷灰、风化水渍（横重纵轻，同 tile 纪律）。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    cw, chh = px(15), px(11)
    c = _cells(b, u, v, cw, chh, stagger=0.5, seed=17.0)
    fu, fv, r1, r2 = c['fu'], c['fv'], c['rand'], c['rand2']

    seam_row = b.sub(1.0, b.ss(fv, 0.0, 0.075))              # 本排石板下缘（硬边 + 投影）
    lap = b.ss(fv, 0.03, 0.45)
    du = b.mul(b.op('MINIMUM', fu, b.sub(1.0, fu)), cw)
    seam_col = b.sub(1.0, b.ss(du, 0.004, 0.020))
    # 部分石板下缘被磕掉
    chip_amt = b.mr(r2, 0.88, 0.99, 0.0, 1.0)
    chip = b.mul(chip_amt, b.mul(b.ss(b.sub(1.0, fv), 0.72, 0.94), b.ss(fu, 0.30, 0.46)))

    # 冷灰石板：逐片明暗差（同矿区石板本就有色差）
    base = b.mixc(r1, (0.140, 0.158, 0.190), (0.245, 0.265, 0.302))
    base = b.mixc(b.lin(r2, 0.86, 0.99, 0.0, 0.45), base, (0.105, 0.115, 0.135))  # 深青
    base = b.mixc(b.lin(r2, 0.0, 0.10, 0.0, 0.30), base, (0.240, 0.243, 0.230))   # 略泛褐
    base = b.shade(base, lap, 0.68, 1.05)
    col = b.mixc(b.op('MAXIMUM', b.mul(seam_col, 0.42), seam_row), base,
                 b.mul_c(base, 0.20))
    col = b.mixc(chip, col, (0.300, 0.310, 0.330))           # 磕口露新茬
    # 风化水渍（竖向拉长）+ 缝内苔藓
    st = b.noise(b.vec(b.mul(u, 5.5), b.mul(v, 1.2), 41.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(st, 0.52, 0.78), b.mul(wear, 0.5)), col, (0.115, 0.125, 0.135))
    moss = b.noise(b.vec(b.mul(u, 3.6), b.mul(v, 3.6), 61.0), 1.0, 5.0, 0.6)
    col = b.mixc(b.mul(b.mul(b.ss(moss, 0.52, 0.72), b.mul(seam_row, 0.8)),
                       b.mul(wear, 0.65)), col, (0.21, 0.235, 0.12))
    grn = b.noise(b.vec(b.mul(u, 13.0), b.mul(v, 13.0), 9.0), 1.0, 4.0)
    col = b.mul_c(col, b.lin(grn, 0.25, 0.75, 0.94, 1.05))

    h = b.add(b.mul(lap, 0.85), b.mul(b.sub(1.0, seam_row), -0.9))
    h = b.sub(h, b.mul(seam_col, 0.3))
    h = b.sub(h, b.mul(chip, 0.6))
    h = b.add(h, b.mul(b.sub(grn, 0.5), 0.08))

    return dict(color=col,
                rough=b.add(b.lin(r1, 0.0, 1.0, 0.60, 0.78), b.mul(grn, 0.04)),
                normal=b.bump(h, 0.55, 0.055),
                spec=0.42)


def _wood(b, gi, u, v, board_h, pal, joint_w=0.035, knot_amt=1.0, camber=0.0,
          cracks=0.0, ring=1.0):
    """共用木料层：横向板 + 板间色差 + 木纹 + 木节 + 板缝阴影。返回 (color, height, rough)。"""
    wear = gi.outputs['Wear']
    _sv, row, fv, rr1, rr2 = _rows(b, v, board_h)
    dv = b.mul(b.op('MINIMUM', fv, b.sub(1.0, fv)), board_h)
    joint = b.sub(1.0, b.ss(dv, 0.004, joint_w))            # 1 = 板缝里

    # 木纹：沿 U 拉长的噪声 + 低频扭曲（年轮感）
    yw = b.noise(b.vec(b.mul(u, 2.0), b.mul(v, 3.0), 7.0), 1.0, 4.0)
    grain = b.noise(b.vec(b.mul(u, 1.2), b.add(b.mul(v, 11.0), b.mul(yw, 6.0)), 3.0), 1.0, 7.0, 0.62)
    grain2 = b.noise(b.vec(b.mul(u, 0.5), b.mul(v, 26.0), 13.0), 1.0, 5.0)
    g = b.mixf(0.55, grain, grain2)
    if ring:
        g = b.pow(g, b.lin(ring, 0.5, 1.5, 1.35, 0.75))

    col = b.ramp(g, [(0.22, pal['dark']), (0.52, pal['mid']), (0.80, pal['light'])])
    col = b.mixc(rr1, b.mul_c(col, pal['board_lo']), b.mul_c(col, pal['board_hi']))  # 板间色差
    if 'board_hi2' in pal:
        col = b.mixc(b.sub(1.0, b.lin(rr2, 0.42, 0.58, 0.0, 1.0)), col,
                     b.mul_c(col, pal['board_hi2']))                                  # 少数板更红/更亮

    # 木节：稀疏的深色小圆点（Voronoi 距离门控 + 单元随机门）
    kd, _kc, kp = b.voro(b.vec(b.mul(u, 2.6), b.mul(v, 2.6), 23.0), scale=1.0, randomness=1.0)
    gate = b.mr(b.white(b.vec(b.op('FLOOR', b.mul(u, 2.6)), b.op('FLOOR', b.mul(v, 2.6)), 23.0)),
                0.78, 0.88, 0.0, 1.0)
    knot = b.mul(b.sub(1.0, b.ss(kd, 0.06, 0.22)), b.mul(gate, knot_amt))
    col = b.mixc(knot, col, pal['knot'])

    # 干裂（木骨/老木明显）：顺 U 的细黑线
    if cracks:
        cr = b.noise(b.vec(b.mul(u, 0.5), b.mul(v, 40.0), 51.0), 1.0, 3.0)
        crk = b.mul(b.sub(1.0, b.ss(b.op('ABSOLUTE', b.sub(cr, 0.5)), 0.0, 0.02)),
                    b.mul(b.sub(1.0, joint), b.mul(cracks, b.lin(wear, 0.2, 0.9, 0.4, 1.0))))
        col = b.mixc(crk, col, (0.06, 0.03, 0.02))

    # 板缝阴影 + 板下沿出檐阴影（板顶棱受光）
    edge_shadow = b.lin(fv, 0.0, 0.46, 0.60, 1.02)
    top_hi = b.ss(fv, 0.86, 1.0)
    col = b.mixc(joint, col, (0.075, 0.038, 0.018))
    col = b.shade(col, edge_shadow, 0.62, 1.0)
    col = b.shade(col, top_hi, 1.0, 1.14)

    h = b.sub(1.0, joint)
    h = b.add(h, b.mul(b.sub(0.5, b.op('ABSOLUTE', b.sub(fv, 0.35))), 0.25))
    h = b.sub(h, b.mul(knot, 0.5))
    if camber:
        h = b.add(h, b.mul(b.op('SINE', b.mul(fv, 3.14159)), camber))
    h = b.add(h, b.mul(b.sub(g, 0.5), 0.30))
    if cracks:
        h = b.sub(h, b.mul(crk, 0.6))
    rough = b.lin(g, 0.0, 1.0, pal['rough'][0], pal['rough'][1])
    return col, h, rough


def _b_plank_wall(b, gi, bsdf):
    """横向木板墙：板高 20px，板缝 1px，板间色差 + 木纹 + 木节。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    pal = dict(dark=(0.205, 0.112, 0.052), mid=(0.390, 0.225, 0.105),
               light=(0.585, 0.375, 0.185),
               board_lo=(0.84, 0.84, 0.84), board_hi=(1.09, 1.06, 1.03),
               board_hi2=(1.22, 1.12, 1.02),
               knot=(0.105, 0.048, 0.022), rough=(0.72, 0.86))
    col, h, rough = _wood(b, gi, u, v, px(20), pal, joint_w=px(1.1), knot_amt=1.0,
                          camber=0.0, cracks=0.35, ring=1.0)
    # 雨水污渍（下沿更深）
    dirt = b.noise(b.vec(b.mul(u, 3.5), b.mul(v, 1.2), 71.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(dirt, 0.5, 0.8), b.mul(wear, 0.45)), col, (0.155, 0.095, 0.05))
    return dict(color=col, rough=rough, normal=b.bump(h, 0.70, 0.045), spec=0.35)


def _b_timber(b, gi, bsdf):
    """深色木骨梁：手斧棱面 + 深色 + 纵向干裂（配抹灰）。"""
    u, v = _uv(b, gi)
    pal = dict(dark=(0.165, 0.082, 0.034), mid=(0.300, 0.168, 0.075),
               light=(0.430, 0.258, 0.122),
               board_lo=(0.88, 0.88, 0.88), board_hi=(1.12, 1.08, 1.04),
               knot=(0.045, 0.022, 0.010), rough=(0.78, 0.90))
    col, h, rough = _wood(b, gi, u, v, px(60), pal, joint_w=px(2.0), knot_amt=0.6,
                          camber=0.45, cracks=1.0, ring=0.5)
    # 斧痕：横向的浅棱面
    ax = b.noise(b.vec(b.mul(u, 0.7), b.mul(v, 1.1), 101.0), 1.0, 2.0)
    col = b.shade(col, b.lin(ax, 0.3, 0.7, 0.0, 1.0), 0.86, 1.14)
    h = b.add(h, b.mul(b.sub(ax, 0.5), 0.55))
    return dict(color=col, rough=rough, normal=b.bump(h, 0.60, 0.045), spec=0.3)


def _b_plaster(b, gi, bsdf):
    """抹灰墙：抹刀痕（拉长弧纹）+ 2px 砂粒 + 剥落斑（露砖红底）+ 细裂。

    颗粒尺度必须 ≥2px 才在 32px/格下可见（此前用 scale 170 → 0.19px，等于没做）。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)

    base = (0.80, 0.75, 0.62)                                  # 米白抹灰
    # 抹刀痕：低频 + 沿 U 拉长的刀弧
    trowel = b.noise(b.vec(b.mul(u, 0.9), b.mul(v, 2.6), 3.0), 1.0, 4.0, 0.6)
    arc = b.noise(b.vec(b.mul(u, 0.55), b.mul(v, 4.5), 17.0), 1.0, 3.0, 0.75)
    paddle = b.mixf(0.45, trowel, arc)
    col = b.mul_c(base, b.lin(paddle, 0.22, 0.82, 0.845, 1.115))

    # 砂粒（2.3px）
    grain = b.noise(b.vec(b.mul(u, 14.0), b.mul(v, 14.0), 5.0), 1.0, 3.0, 0.6)
    col = b.mul_c(col, b.lin(grain, 0.22, 0.78, 0.92, 1.07))

    # 剥落斑：大块、边界参差、露砖红底灰；斑内自身有色差
    spall = b.noise(b.vec(b.mul(u, 0.75), b.mul(v, 0.75), 23.0), 1.0, 5.0, 0.65)
    spall2 = b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 3.2), 29.0), 1.0, 4.0)
    sp = b.mixf(0.22, spall, spall2)
    thr = b.lin(wear, 0.0, 1.0, 0.665, 0.590)
    mask = b.ss(sp, thr, b.add(thr, 0.035))
    rim = b.mul(b.ss(sp, b.sub(thr, 0.025), thr),
                b.sub(1.0, b.ss(sp, thr, b.add(thr, 0.02))))
    sub_tex = b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 3.2), 41.0), 1.0, 4.0)        # 底层灰浆斑
    substrate = b.mul_c((0.300, 0.170, 0.110), b.lin(sub_tex, 0.25, 0.75, 0.80, 1.18))
    col = b.mixc(mask, col, substrate)
    col = b.mixc(b.mul(rim, 0.85), col, (0.94, 0.91, 0.82))    # 剥落边缘露白
    col = b.mul_c(col, b.lin(mask, 0.0, 1.0, 1.0, 0.92))

    # 细裂（竖向拉长，2px 宽）
    cr = b.noise(b.vec(b.mul(u, 1.8), b.mul(v, 9.0), 37.0), 1.0, 4.0, 0.4)
    crack = b.mul(b.sub(1.0, b.ss(b.op('ABSOLUTE', b.sub(cr, 0.5)), 0.0, 0.010)),
                  b.mul(b.sub(1.0, mask), b.lin(wear, 0.0, 1.0, 0.25, 0.85)))
    col = b.mixc(crack, col, (0.30, 0.25, 0.19))

    # 泛潮 / 脏（低频斑，不依赖绝对坐标）
    damp = b.noise(b.vec(b.mul(u, 1.8), b.mul(v, 1.8), 53.0), 1.0, 4.0, 0.5)
    col = b.mixc(b.mul(b.ss(damp, 0.55, 0.85), b.mul(wear, 0.35)), col, (0.52, 0.47, 0.37))

    h = b.add(0.75, b.mul(b.sub(paddle, 0.5), 0.42))
    h = b.add(h, b.mul(b.sub(grain, 0.5), 0.30))
    h = b.sub(h, b.mul(mask, 0.65))
    h = b.add(h, b.mul(rim, 0.30))
    h = b.sub(h, b.mul(crack, 0.35))

    rough = b.lin(paddle, 0.0, 1.0, 0.85, 0.94)
    rough = b.add(rough, b.mul(grain, 0.04))
    return dict(color=col, rough=rough, normal=b.bump(h, 0.45, 0.030), spec=0.28)


def _b_stone(b, gi, bsdf, light=False):
    """石砌：**错缝矩形石块 + 缝位抖动**（不用 Voronoi 细胞 —— 那会读成"龟裂/鹅卵石"）。

    石砌的读法靠三件事：
      1) 矩形料石 + 错缝(半块) + 缝位被逐格噪声抖动 → 不规则但边是直的；
      2) 逐块明暗/冷暖差（整数格索引哈希，可靠）；
      3) 灰浆缝窄而深 + 石块棱边一圈受光倒角 + 缝内苔藓。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)

    if light:      # 白石饰（线脚/雕饰用，细料石）
        cw, chh, jw, jitter = px(16), px(10), px(0.9), 0.20
        c_lo, c_hi, c_warm = (0.475, 0.462, 0.432), (0.795, 0.772, 0.705), (0.735, 0.698, 0.618)
        c_mortar = (0.360, 0.348, 0.325)
        moss_amt = 0.10
    else:          # 石砌（深）：粗料石
        cw, chh, jw, jitter = px(30), px(18), px(1.4), 0.32
        c_lo, c_hi, c_warm = (0.175, 0.170, 0.163), (0.545, 0.525, 0.478), (0.487, 0.428, 0.352)
        c_mortar = (0.165, 0.160, 0.150)
        moss_amt = 0.85

    sv = b.div(v, chh)
    row = b.op('FLOOR', sv)
    fv0 = b.sub(sv, row)
    rrand = b.white(b.vec(row, 5.0, 2.0))
    su = b.add(b.div(u, cw), b.mul(rrand, 0.5))               # 错缝
    col = b.op('FLOOR', su)
    fu0 = b.sub(su, col)
    # 缝位抖动（每格一个值：整数格索引 → 噪声格点，格内恒定）
    jx = b.noise(b.vec(b.mul(col, 6.0), b.mul(row, 6.0), 3.0), 1.0, 2.0)
    jy = b.noise(b.vec(b.mul(col, 6.0), b.mul(row, 6.0), 11.0), 1.0, 2.0)
    fu = b.add(fu0, b.mul(b.sub(jx, 0.5), jitter))
    fv = b.add(fv0, b.mul(b.sub(jy, 0.5), b.mul(jitter, 0.5)))
    du = b.mul(b.op('MINIMUM', fu, b.sub(1.0, fu)), cw)
    dv = b.mul(b.op('MINIMUM', fv, b.sub(1.0, fv)), chh)
    d = b.op('MINIMUM', du, dv)                                # 到缝的距离（单位）

    r1 = b.white(b.vec(col, row, 1.0))
    r2 = b.white(b.vec(col, row, 2.0))
    r3 = b.white(b.vec(col, row, 3.0))
    face = b.ss(d, b.mul(jw, 0.35), jw)
    seam = b.sub(1.0, face)
    chamfer = b.mul(b.ss(d, jw, b.mul(jw, 1.7)),
                    b.sub(1.0, b.ss(d, b.mul(jw, 1.7), b.mul(jw, 3.4))))

    # 石面色：逐块明暗/冷暖 + 块内斑驳
    mott = b.noise(b.vec(b.mul(u, 8.0), b.mul(v, 8.0), 7.0), 1.0, 6.0, 0.6)
    col_c = b.mixc(r1, c_lo, c_hi)
    col_c = b.mixc(b.lin(r2, 0.78, 0.98, 0.0, 0.62), col_c, b.mul_c(col_c, 0.60))
    col_c = b.mixc(b.lin(r3, 0.0, 0.24, 0.0, 0.55), col_c, c_warm)
    col_c = b.mixc(b.lin(mott, 0.28, 0.78, 0.0, 0.5), col_c, b.mul_c(col_c, 0.74))
    col_c = b.shade(col_c, chamfer, 1.0, 1.26)
    # 灰浆缝
    mort = b.mixc(b.noise(b.vec(b.mul(u, 13.0), b.mul(v, 13.0), 11.0), 1.0, 4.0),
                  b.mul_c(c_mortar, 0.70), c_mortar)
    col_c = b.mixc(face, mort, col_c)
    # 风化脏斑
    wea = b.noise(b.vec(b.mul(u, 1.8), b.mul(v, 2.2), 29.0), 1.0, 5.0, 0.5)
    col_c = b.mixc(b.mul(b.ss(wea, 0.50, 0.80), b.lin(wear, 0.0, 1.0, 0.15, 0.62)), col_c,
                   b.mul_c(col_c, 0.58))
    # 缝内苔藓
    moss = b.noise(b.vec(b.mul(u, 4.0), b.mul(v, 4.0), 43.0), 1.0, 5.0, 0.6)
    col_c = b.mixc(b.mul(b.mul(b.ss(moss, 0.46, 0.68), b.pow(seam, 0.6)),
                         b.mul(wear, moss_amt)), col_c, (0.205, 0.245, 0.120))
    grn = b.noise(b.vec(b.mul(u, 15.0), b.mul(v, 15.0), 3.0), 1.0, 4.0)
    col_c = b.mul_c(col_c, b.lin(grn, 0.25, 0.75, 0.94, 1.06))

    # 高度：逐块高低 + 石面平台 + 深缝 + 棱边倒角
    h = b.add(b.mul(face, b.lin(b.mixf(0.5, r1, r3), 0.0, 1.0, 0.72, 1.0)),
              b.mul(b.sub(mott, 0.5), 0.16))
    h = b.add(h, b.mul(chamfer, 0.28))
    h = b.sub(h, b.mul(seam, 1.15))
    h = b.add(h, b.mul(b.sub(grn, 0.5), 0.10))

    rough = b.add(b.lin(mott, 0.0, 1.0, 0.76, 0.92), b.mul(seam, 0.05))
    return dict(color=col_c, rough=rough, normal=b.bump(h, 0.70, 0.04), spec=0.25)


def _b_brick(b, gi, bsdf):
    """做旧红砖：20x10px 砖 + ~1.3px 深缝 + 逐块色差 + 边缘磕蚀 + 烟熏。

    要点：缝要窄而深（比砖暗很多，靠 AO 拉出凹凸），砖面要有 2~3px 的可见颗粒，
    砖块轮廓被噪点啃出缺口 —— 否则读成"矢量色块贴图"。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    cw, chh = px(20), px(10)
    c = _cells(b, u, v, cw, chh, stagger=0.5, seed=3.0)
    fu, fv, r1, r2, d = c['fu'], c['fv'], c['rand'], c['rand2'], c['d']

    # ---- 砖面轮廓：缝内 1.2px 起步 + 噪点啃边 + 缺角
    bricky = b.ss(d, px(0.3), px(1.2))
    erode_n = b.noise(b.vec(b.mul(u, 11.0), b.mul(v, 22.0), 1.0), 1.0, 4.0, 0.5)
    edge_prox = b.sub(1.0, b.ss(d, px(0.4), px(3.2)))
    erode = b.mul(edge_prox, b.lin(erode_n, 0.38, 0.62, 0.0, 1.0))
    corner = b.op('MAXIMUM', b.op('ABSOLUTE', b.sub(fu, 0.5)), b.op('ABSOLUTE', b.sub(fv, 0.5)))
    chip_amt = b.mr(r2, b.sub(0.78, b.mul(wear, 0.26)), 0.97, 0.0, 1.0)
    chip = b.mul(chip_amt, b.ss(corner, 0.36, 0.49))
    face = b.mul(bricky, b.sub(1.0, b.op('MAXIMUM', b.mul(erode, 0.75), b.mul(chip, 0.95))))

    # ---- 砖面色：4 路（深红/亮红/土黄/焦黑）+ 宽明暗跨度 + 2.5px 颗粒
    grain = b.noise(b.vec(b.mul(u, 13.0), b.mul(v, 26.0), 13.0), 1.0, 5.0, 0.6)
    col = b.mixc(r1, (0.30, 0.085, 0.045), (0.58, 0.18, 0.070))
    col = b.mixc(b.lin(r2, 0.70, 0.90, 0.0, 0.55), col, (0.42, 0.20, 0.075))
    col = b.mixc(b.lin(r2, 0.90, 0.97, 0.0, 0.7), col, (0.115, 0.06, 0.048))
    col = b.mul_c(col, b.lin(r1, 0.0, 1.0, 0.70, 1.18))
    col = b.mixc(b.lin(grain, 0.28, 0.75, 0.0, 0.55), col, b.mul_c(col, 0.70))
    # ---- 灰浆缝（窄、深、灰）
    mort = b.mixc(grain, (0.145, 0.135, 0.125), (0.30, 0.285, 0.265))
    col = b.mixc(face, mort, col)
    col = b.shade(col, bricky, 0.50, 1.0)                     # 缝内 AO（拉凹凸）
    # ---- 烟熏 / 泛白盐霜
    soot = b.noise(b.vec(b.mul(u, 2.4), b.mul(v, 2.4), 19.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(soot, 0.42, 0.78), b.lin(wear, 0.0, 1.0, 0.2, 0.8)), col,
                 (0.135, 0.10, 0.085))
    salt = b.noise(b.vec(b.mul(u, 5.0), b.mul(v, 5.0), 67.0), 1.0, 5.0)
    col = b.mixc(b.mul(b.mul(b.ss(salt, 0.62, 0.82),
                             b.add(b.mul(face, 0.30), b.mul(bricky, 0.20))),
                       b.mul(wear, 0.65)),
                 col, (0.60, 0.58, 0.54))

    h = b.add(b.mul(face, 1.0), b.mul(r1, 0.20))
    h = b.add(h, b.mul(b.sub(grain, 0.5), 0.30))
    h = b.sub(h, b.mul(b.mul(erode, 0.6), 0.5))
    h = b.sub(h, b.mul(chip, 0.4))
    rough = b.add(b.lin(r1, 0.0, 1.0, 0.72, 0.88), b.mul(b.sub(grain, 0.5), 0.08))
    return dict(color=col, rough=rough, normal=b.bump(h, 0.70, 0.035), spec=0.30)


def _b_iron(b, gi, bsdf):
    """铸铁：锤打棱面（逐面高低）+ 麻点气孔 + 锈斑（金属 0.9）。"""
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)

    base = (0.090, 0.090, 0.100)
    # 铸造麻点（~3px 凹坑）
    pd, _pc, _pp = b.voro(b.vec(b.mul(u, 6.0), b.mul(v, 6.0), 7.0), scale=1.0, randomness=1.0)
    pit = b.sub(1.0, b.ss(pd, 0.22, 0.60))
    # 锤打棱面（~10px 平面，逐面不同朝向/高度 → 形体才读得出来）
    hd, hc, _hp = b.voro(b.vec(b.mul(u, 2.1), b.mul(v, 2.1), 3.0), scale=1.0, randomness=0.9)
    r1, r2, _r3 = b.sep_c(hc)
    hammer = b.lin(hd, 0.10, 0.80, 0.0, 1.0)
    # 表面微观粗糙
    mic = b.noise(b.vec(b.mul(u, 12.0), b.mul(v, 12.0), 11.0), 1.0, 5.0, 0.65)

    col = b.mixc(pit, b.mul_c(base, 1.15), b.mul_c(base, 2.0))
    col = b.shade(col, b.mul(r1, 1.0), 0.72, 1.35)             # 逐面亮度（棱面反光差）
    col = b.mul_c(col, b.lin(mic, 0.25, 0.75, 0.88, 1.14))
    # 锈斑
    rust = b.noise(b.vec(b.mul(u, 2.6), b.mul(v, 3.0), 23.0), 1.0, 5.0, 0.55)
    rust_m = b.mul(b.ss(rust, 0.48, 0.70), b.lin(wear, 0.0, 1.0, 0.25, 1.0))
    col = b.mixc(rust_m, col, (0.265, 0.115, 0.050))
    met = b.mixf(rust_m, 0.97, 0.20)
    rough = b.mixf(rust_m, b.add(b.lin(mic, 0.0, 1.0, 0.26, 0.46), b.mul(b.sub(1.0, pit), 0.12)), 0.88)
    h = b.add(b.mul(b.sub(1.0, pit), -0.55), b.mul(r2, 0.35))
    h = b.add(h, b.mul(b.sub(mic, 0.5), 0.35))
    h = b.sub(h, b.mul(b.mul(b.sub(1.0, hammer), 0.4), 0.6))
    return dict(color=col, rough=rough, metal=met, normal=b.bump(h, 0.65, 0.045), spec=0.5)


def _b_canvas(b, gi, bsdf):
    """麻布（棚布/麻袋）：经纬织纹（2.4px）+ 粗节 + 污渍。

    注意 Wave 的 Scale 是"每单位几个波段"，不是周期长度：周期 2.4px → Scale = 32/2.4 ≈ 13.3。
    """
    wear = gi.outputs['Wear']
    u, v = _uv(b, gi)
    wscale = PX_PER_UNIT / 3.2                                # 3.2px 一个织纹周期（规范 2~4px）
    warp = b.wave(b.vec(u, v, 0.0), scale=wscale, bands='Y')
    weft = b.wave(b.vec(u, v, 0.0), scale=wscale, bands='X')
    weave = b.mul(warp, weft)
    weave = b.lin(weave, 0.06, 0.46, 0.0, 1.0)
    slub = b.noise(b.vec(b.mul(u, 12.0), b.mul(v, 12.0), 5.0), 1.0, 5.0, 0.6)
    thread = b.white(b.vec(b.op('FLOOR', b.mul(u, 16.0)), b.op('FLOOR', b.mul(v, 16.0)), 3.0))

    col = b.ramp(b.mixf(0.35, weave, thread),
                 [(0.10, (0.375, 0.320, 0.225)), (0.50, (0.640, 0.580, 0.440)),
                  (0.90, (0.850, 0.795, 0.650))])
    col = b.mixc(slub, col, b.mul_c(col, 0.72))
    dirt = b.noise(b.vec(b.mul(u, 3.2), b.mul(v, 3.2), 31.0), 1.0, 5.0, 0.5)
    col = b.mixc(b.mul(b.ss(dirt, 0.5, 0.8), b.mul(wear, 0.45)), col, (0.38, 0.325, 0.235))
    h = b.add(b.mul(weave, 0.65), b.mul(b.sub(slub, 0.5), 0.30))
    return dict(color=col, rough=0.95, normal=b.bump(h, 0.80, 0.060), spec=0.12, sheen=0.2)


# ============================================================ 注册表
_BUILDERS = {
    'thatch':       (lambda b, gi, bsdf: _b_thatch(b, gi, bsdf, 'new'), '茅草（新）'),
    'thatch_old':   (lambda b, gi, bsdf: _b_thatch(b, gi, bsdf, 'old'), '茅草（旧/发霉）'),
    'tile_roof':    (_b_tile_roof, '陶瓦（筒板瓦）'),
    'slate_roof':   (_b_slate_roof, '石板瓦'),
    'plank_wall':   (_b_plank_wall, '横向木板墙'),
    'timber':       (_b_timber, '深色木骨梁'),
    'plaster':      (_b_plaster, '抹灰墙'),
    'stone':        (_b_stone, '石砌（深）'),
    'white_stone':  (lambda b, gi, bsdf: _b_stone(b, gi, bsdf, True), '白石饰（细块）'),
    'brick':        (_b_brick, '做旧红砖'),
    'iron':         (_b_iron, '铸铁'),
    'canvas':       (_b_canvas, '麻布'),
}
ORDER = ['thatch', 'thatch_old', 'tile_roof', 'slate_roof',
         'plank_wall', 'timber', 'plaster', 'stone',
         'brick', 'iron', 'white_stone', 'canvas']

_GROUP_CACHE = {}


def _get_group(key, force=False):
    if key in _GROUP_CACHE and not force:
        return _GROUP_CACHE[key]
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
                    ('sheen_rough', 'Sheen Roughness')):
        if k not in res:
            continue
        v = res[k]
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            bsdf.inputs[name].default_value = v      # 常数直接设默认值
        else:
            b.l.new(v, bsdf.inputs[name])
    for k, v in (('IOR', 1.45), ('Coat Weight', 0.0), ('Diffuse Roughness', 0.0),
                 ('Thin Wall', False)):
        try:
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
    tune(m, scale=scale, tint=tint, wear=wear)
    return m


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


def make(key, **kw):
    """按注册名创建材质（供装配层统一调用）。"""
    if key not in _BUILDERS:
        raise KeyError("未知材质: {}（可用: {}）".format(key, ", ".join(ORDER)))
    return _instance(key, **kw)


#: 建筑装配层（buildings.py）的材质名 → 本库注册名
_ALIAS = {
    "plaster_old": "plaster",
    "wood": "plank_wall", "wood_light": "plank_wall", "wood_dark": "timber",
    "tile": "tile_roof", "slate": "slate_roof", "stone_dark": "stone",
}


def get(name):
    """按建筑装配层的材质名取材质；未知名返回 None（便于装配层回退纯色 PBR）。"""
    key = _ALIAS.get(name, name)
    if key not in _BUILDERS:
        return None
    return _instance(key, name=name)


# ============================================================ 几何工具
def box_project_uv(obj, uv_scale=1.0):
    """按世界坐标做盒式投影 UV：主导轴决定平面，U=水平轴，V=竖直轴（水平面取另一水平轴）。

    1 UV 单位 = 1 Blender 单位 = 1 格 = 32px，与材质库尺度规范一致。
    必须在设置完物体变换（位置/旋转）之后调用。
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


def audit():
    """打印材质清单与各自节点数（自检/报告用）。"""
    rows = []
    for k in ORDER:
        ng = _get_group(k)
        rows.append((k, _BUILDERS[k][1], len(ng.nodes), len(ng.interface.items_tree) - 1))
    return rows


if __name__ == "__main__":
    for r in audit():
        print("{:12s} {:14s} nodes={:3d} inputs={}".format(*r))
