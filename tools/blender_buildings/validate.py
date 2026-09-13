# -*- coding: utf-8 -*-
"""validate.py —— 建筑生成管线 v3 自动校验（纯几何 + 数据，**不渲染任何图**）

做什么
------
把"靠人眼/agent 自评"的几条出厂门禁变成可复跑的自动检查（交接档 §三.5），覆盖六项：

  1. def↔装配器覆盖表   city_layout.DEFS(24) × probe_city_scene.DEF_MAP/PROP_LOTS，逐 def
                        打印映射与缺口（缺哪个列哪个，不许静默跳过）。道具型 lot
                        （well/market_stall）走 PROP_LOTS 聚簇：校验配方道具名已注册
                        且实测占位不撑出地块
  2. 地块合规           4 档 tier × 各 3 seed 跑 plan_city：同排 lots x 区间不重叠 /
                        w_px ≤ 该 def 映射的最大装配宽 / 每 lot 至少一个「尺寸放得下」
                        的装配宽度档
  3. 装配适配           DEF_MAP 里每个映射按布局器声明的宽度档实际调一次装配器：
                        实测网格宽 ≤ 对应 lot 宽（pick_width 语义）+ check_spec 基线
                        比对（house16 / townhouse12 / townhouse16 为已知基线，
                        出现新 FAIL 逐条列出）
  4. 窗规格 lint        WINDOW_SPEC 全档位：窗台 69 档一致 / 窗高 92~100 /
                        同立面窗型 ≤2 的约束字段（分立面常量组）存在且成立
  5. 纹素密度纪律       materials.py 全部 UV 标定入口引用 M_PER_UV=0.42，
                        源码级排查硬编码的其它「米/UV」比例常量
  6. 道具挂载回归       props.DRESS 每套配方在默认宽度各跑一次 pack_sides/dress：
                        无异常、无负宽度、道具数 ≥1、配方内道具名都已注册

跑法::

    blender -b --factory-startup -P tools/blender_buildings/validate.py

可选环境变量::

    VALIDATE_ONLY=1,3        只跑指定检查项（用于自检退出码语义 / 局部复现）
    VALIDATE_SEEDS=611036,1,777   覆盖「地块合规」用的 seed 列表
    VALIDATE_PROPS_W=384     覆盖「道具挂载回归」的默认立面宽度（单位）

退出码::

    0 = 全部检查 PASS（已知基线 FAIL 不计）
    1 = 有 FAIL，逐条已打印

设计取舍（诚实清单，写在文件里方便复核）
----------------------------------------
* **不 import probe_city_scene**：该文件在模块级直接 `main()`（一 import 就会全量渲
  染）。DEF_MAP 改由 `ast` 解析源码取字面量，行为零副作用。
* `pick_width` 在此**镜像**了 probe_city_scene.pick_width 的三行语义（同样是不执行
  该探针的代价），语义差异会直接反映在检查 3 的违反清单里。
* 检查 2「每 lot 至少一个可用宽度档」取**装配级**口径：映射装配器的宽度档里必须存在
  一档 ≤ 该 lot 宽（否则装配体会撑出自己的地块）。布局级口径（DEFS 声明宽度非空）恒
  真，不作判定。
* 检查 3 的「新 FAIL」以 probe_buildings.PROBE_LIST 的实测基线为口径；DEF_MAP 会调到
  一些 PROBE_LIST 未覆盖的宽度档（如 barn16 / smithy1 w6），它们一旦 FAIL 即列为新
  FAIL——这是本工具要暴露的真实缺口，不是误报。
* 检查 4「同立面窗型 ≤2」在无分立面元数据的前提下只能校验：分立面常量组
  （WIN_FRONT/SIDE/GABLE + WIN_LOW/UP/TOP）存在、取值在 WINDOW_SPEC 内、每组窗型
  ≤2；装配器函数体内部的**实际**取用档数只做源码扫描并列报，不作判定。
* 检查 5 是源码级文本/AST 检查，不做像素级 texel density 实测（那需要渲染）。
* 检查 6 只跑 pack_sides/dress 的排布与建模路径，`GAME_SCALE` 生效但**不渲染**，
  因此"缩到游戏尺寸是否可辨"仍需 25% 样片人眼验收（交接档 §二 已知落差）。
"""

import ast
import contextlib
import io
import os
import re
import sys
import time
import traceback

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B          # noqa: E402
import city_layout as CL       # noqa: E402
import materials as MAT        # noqa: E402
import props as P              # noqa: E402

CELL = 32.0
TIERS = ("hamlet", "village", "town", "city")
PROBE_SRC = os.path.join(HERE, "probe_city_scene.py")
MAT_SRC_PATH = os.path.join(HERE, "materials.py")

#: probe_buildings.PROBE_LIST 实测基线里已知的 check_spec FAIL（交接任务给定）
KNOWN_SPEC_FAIL = {("house", 16), ("townhouse", 12), ("townhouse", 16)}

#: 布局器 def 宽度档在装配器里的支撑表：装配器名 → buildings 的参数表属性名
ASM_TIER_ATTR = {
    "house": "HOUSE_TIERS", "townhouse": "TOWNHOUSE_TIERS", "barn": "BARN_TIERS",
    "smithy1": "SMITHY1_TIERS", "rowhouse": "ROWHOUSE_TIERS",
    "windmill": "WINDMILL_TIERS", "cathedral": "CATHEDRAL_TIERS",
    "tower": "TOWER_TIERS", "gatehouse": "GATEHOUSE_TIERS",
    "lighthouse": "LIGHTHOUSE_TIERS",
    # 批次 D3a（9 个民用装配器）
    "cottage": "COTTAGE_TIERS", "tavern": "TAVERN_TIERS", "bakery": "BAKERY_TIERS",
    "shop": "SHOP_TIERS", "guildhall": "GUILDHALL_TIERS",
    "hayloft": "HAYLOFT_TIERS", "smithy2": "SMITHY2_TIERS",
    "smithy3": "SMITHY3_TIERS", "smithy4": "SMITHY4_TIERS",
}

#: 窗规格标准（交接档 §0.3 / 任务书）
WIN_SILL_STD = 69.0
#: 窗台例外：临街一层 1.00m（street）/ 阁楼矮窗（garret，相对楼层地面）
WIN_SILL_EXCEPT = {"street": 76.0, "garret": 14.0}
WIN_H_BAND = (92.0, 100.0)
WIN_H_EXCEPT = {"garret": 30.0, "vent": 48.0, "squint": 52.0, "peephole": 34.0,
                "belfry": 112.0}
#: 固定宽的非居室开口：不参与居室窗高带判定
WIN_FIXED = ("vent", "squint", "peephole", "belfry")
#: 分立面窗型常量组（同一立面一组；每组窗型 ≤2）
WIN_FACADE_GROUPS = {
    "正面(单层)": ("WIN_FRONT",), "侧墙": ("WIN_SIDE",), "山墙": ("WIN_GABLE",),
    "二/三层立面": ("WIN_LOW", "WIN_UP", "WIN_TOP"),
}
WIN_FACADE_FIELDS = ("WIN_FRONT", "WIN_SIDE", "WIN_GABLE", "WIN_LOW", "WIN_UP", "WIN_TOP")
#: 任务给定的「同立面窗型 ≤2」上限
WIN_PER_FACADE_MAX = 2

M_PER_UV_EXPECT = 0.42
PROPS_DEFAULT_W = float(os.environ.get("VALIDATE_PROPS_W", "384"))

DEFAULT_SEEDS = (611036, 1, 777)


# ══════════════════════════════════════════════════════════════════════════
# 通用
# ══════════════════════════════════════════════════════════════════════════
def wipe_meshes():
    """删掉场景里的网格对象（不 read_factory_settings —— 见交接档 §六 材质坑）。"""
    for ob in list(bpy.data.objects):
        if ob.type == "MESH":
            bpy.data.objects.remove(ob, do_unlink=True)


def pick_width(want, allowed):
    """镜像 probe_city_scene.pick_width：挑不大于 want 的最大支持档，否则退最小档。"""
    smaller = [w for w in allowed if w <= want]
    return max(smaller) if smaller else min(allowed)


def asm_tiers(asm):
    """装配器支持的宽度档（取自 buildings 的参数表；取不到返回 None）。"""
    tbl = getattr(B, ASM_TIER_ATTR.get(asm, ""), None)
    return sorted(tbl.keys()) if isinstance(tbl, dict) else None


def load_def_map():
    """用 ast 解析 probe_city_scene.py 里的 DEF_MAP 字面量（不执行该模块）。"""
    src = open(PROBE_SRC, encoding="utf-8").read()
    tree = ast.parse(src)
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "DEF_MAP" for t in node.targets):
            return ast.literal_eval(node.value)
    raise RuntimeError("probe_city_scene.py 里找不到 DEF_MAP 字面量")


def load_prop_lots():
    """同样用 ast 取 PROP_LOTS 字面量（道具型 lot：well / market_stall）。"""
    src = open(PROBE_SRC, encoding="utf-8").read()
    tree = ast.parse(src)
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "PROP_LOTS" for t in node.targets):
            return ast.literal_eval(node.value)
    return {}


def prop_footprint(recipe, pw):
    """按 PROP_LOTS 配方**实测**聚簇占地跨度（镜像探针的 build_prop_lot，不 import 探针）。

    返回 (实际摆出的件数, x 跨度)。道具函数里没注册的名字由调用方先查表拦下。
    """
    b = B.Builder("propval_foot")
    n = 0
    for (pname, xf, yoff, kw) in recipe:
        fn = P.TABLE.get(pname)
        if fn is None:
            continue
        p = dict(kw)
        for k in ("r", "h", "w", "d", "s"):
            if k in p:
                p[k] = p[k] * P.GAME_SCALE
        x = xf * pw
        try:
            fn(b, x=x, y=yoff, z=0.0, seed=7, **p)
        except TypeError:
            fn(b, x=x, y=yoff, z=0.0, **p)
        n += 1
    ob = b.to_object()
    mx = B.measure(ob)
    wipe_meshes()
    return n, mx["x"][1] - mx["x"][0]


class Result(object):
    def __init__(self, idx, name):
        self.idx, self.name = idx, name
        self.fails, self.notes = [], []
        self.count = 0
        self.secs = 0.0

    def fail(self, msg):
        self.fails.append(msg)

    def note(self, msg):
        self.notes.append(msg)

    @property
    def ok(self):
        return not self.fails


def parse_only():
    raw = os.environ.get("VALIDATE_ONLY", "").strip()
    if not raw:
        return None
    out = set()
    for part in raw.split(","):
        part = part.strip()
        if part.isdigit():
            out.add(int(part))
    return out or None


def parse_seeds():
    raw = os.environ.get("VALIDATE_SEEDS", "").strip()
    if not raw:
        return list(DEFAULT_SEEDS)
    return [int(x) for x in raw.split(",") if x.strip()]


# ══════════════════════════════════════════════════════════════════════════
# 检查 1：def ↔ 装配器覆盖表
# ══════════════════════════════════════════════════════════════════════════
def check_coverage(def_map, prop_map):
    res = Result(1, "def↔装配器覆盖")
    print("\n[1] def ↔ 装配器覆盖表（city_layout.DEFS × probe_city_scene.DEF_MAP/PROP_LOTS）")
    head = "%-14s %-10s %-8s %-14s %-16s %s" % (
        "def", "中文", "声明宽度", "装配器映射", "该装配器宽度档", "判定")
    print(head)
    print("-" * 108)
    gaps = 0
    for defn in sorted(CL.DEFS):
        d = CL.DEFS[defn]
        decl = list(d["widths"])
        m = def_map.get(defn)
        if m is None and defn in prop_map:
            recipe = prop_map[defn]
            bad = [n for (n, _x, _y, _k) in recipe if n not in P.TABLE]
            if not recipe:
                res.fail("道具型 lot %s（%s）：PROP_LOTS 配方为空" % (defn, d["cn"]))
                gaps += 1
                status = "缺口：配方为空"
            elif bad:
                res.fail("道具型 lot %s（%s）：配方含未注册道具 %s（渲染会静默丢弃）"
                         % (defn, d["cn"], bad))
                gaps += 1
                status = "缺口：未注册道具 %s" % bad
            else:
                spans = []
                for w in decl:
                    n, sp = prop_footprint(recipe, w * CELL)
                    spans.append("%d格:%.0fpx" % (w, sp))
                    if sp > w * CELL + 1.0:
                        res.fail("道具型 lot %s 在 %d 格地块（%.0fpx）上实测占位 %.0fpx →"
                                 " 撑出地块 %.0fpx" % (defn, w, w * CELL, sp, sp - w * CELL))
                        gaps += 1
                status = "OK（道具型 lot：%d 件 / 占位 %s）" % (len(recipe), ",".join(spans))
            print("%-14s %-10s %-8s %-14s %-16s %s"
                  % (defn, d["cn"], decl, "—(道具)", "—", status))
            continue
        if m is None:
            status = "缺口：无装配器映射"
            gaps += 1
            res.fail("缺口 %s（%s）：DEF_MAP 无映射，plan 里的该 lot 会被整条跳过"
                     % (defn, d["cn"]))
            print("%-14s %-10s %-8s %-14s %-16s %s"
                  % (defn, d["cn"], decl, "—", "—", status))
            continue
        asm, allowed = m
        allowed = sorted(allowed)
        tiers = asm_tiers(asm)
        problems = []
        if asm not in B.ASSEMBLERS:
            problems.append("装配器 %s 不存在" % asm)
        if tiers is None:
            problems.append("装配器 %s 无宽度档表" % asm)
        else:
            unknown = [w for w in allowed if w not in tiers]
            if unknown:
                problems.append("映射宽度档 %s 不在 %s 支持表 %s 内"
                                % (unknown, asm, tiers))
        inter = [w for w in decl if w in allowed]
        if not inter:
            problems.append("声明宽度 %s 与映射宽度档 %s 无交集（该 def 永远装配不出）"
                            % (decl, allowed))
        if problems:
            gaps += 1
            for p in problems:
                res.fail("缺口 %s（%s）：%s" % (defn, d["cn"], p))
            status = "缺口：" + "；".join(problems)
        else:
            status = "OK（可用档 %s）" % inter
        print("%-14s %-10s %-8s %-14s %-16s %s"
              % (defn, d["cn"], decl, "%s%s" % (asm, "" if asm in B.ASSEMBLERS else "?"),
                 allowed, status))
    stray = sorted((set(def_map) | set(prop_map)) - set(CL.DEFS))
    if stray:
        res.fail("DEF_MAP/PROP_LOTS 多余的键（不在 DEFS 里）：%s" % stray)
    res.count = len(CL.DEFS)
    res.note("DEFS %d 种 / DEF_MAP %d 键 / PROP_LOTS %d 键 / 缺口 %d 种；跳过种（无映射）=%s"
             % (len(CL.DEFS), len(def_map), len(prop_map), gaps,
                [k for k in sorted(CL.DEFS)
                 if k not in def_map and k not in prop_map]))
    return res


# ══════════════════════════════════════════════════════════════════════════
# 检查 2：地块合规
# ══════════════════════════════════════════════════════════════════════════
def check_lots(def_map, seeds):
    res = Result(2, "地块合规")
    print("\n[2] 地块合规（plan_city 4 档 × %d seed=%s）" % (len(seeds), seeds))
    print("%-8s %-8s %6s %8s %8s %8s %s"
          % ("tier", "seed", "lots", "同排重叠", "超最大宽", "无可用档", "判定"))
    print("-" * 84)
    # 缺口按「类型」聚合：{(def,wc,need): [(tier,seed), ...]}
    nofit_agg, overmax_agg, overlap_agg = {}, {}, {}
    called = 0
    for tier in TIERS:
        for seed in seeds:
            try:
                plan = CL.plan_city(tier, seed)
            except Exception as exc:
                res.fail("%s/%d：plan_city 抛 %s: %s（无法验证该组合，不作静默跳过）"
                         % (tier, seed, type(exc).__name__, exc))
                print("%-8s %-8d %6s %8s %8s %8s FAIL(plan 抛异常)"
                      % (tier, seed, "-", "-", "-", "-"))
                continue
            called += 1
            lots = plan["lots"]
            res.count += len(lots)
            # 2a 同排 x 区间重叠
            by_row = {}
            for l in lots:
                by_row.setdefault(l["row"], []).append(l)
            overlaps = []
            for row, ls in by_row.items():
                ls = sorted(ls, key=lambda x: x["x_cells"][0])
                for a, b in zip(ls, ls[1:]):
                    if a["x_cells"][1] > b["x_cells"][0]:
                        overlaps.append((row, a["def"], a["x_cells"], b["def"],
                                         b["x_cells"]))
            for (row, da, xa, db, xb) in overlaps:
                overlap_agg.setdefault((row, da, tuple(xa), db, tuple(xb)), 0)
                overlap_agg[(row, da, tuple(xa), db, tuple(xb))] += 1
            # 2b 超最大装配宽 / 2c 每 lot 至少一个可用宽度档
            overmax, nofit = [], []
            for l in lots:
                m = def_map.get(l["def"])
                if m is None:
                    continue
                asm, allowed = m
                allowed = sorted(allowed)
                if l["w_px"] > max(allowed) * CELL:
                    overmax.append((l["def"], l["w_cells"], max(allowed)))
                if pick_width(l["w_cells"], allowed) > l["w_cells"]:
                    nofit.append((l["def"], l["w_cells"],
                                  pick_width(l["w_cells"], allowed)))
            for (defn, wc, mx) in overmax:
                overmax_agg.setdefault((defn, wc, mx), []).append((tier, seed))
            for (defn, wc, need) in nofit:
                nofit_agg.setdefault((defn, wc, need), []).append((tier, seed))
            verdict = "PASS" if not (overlaps or overmax or nofit) else \
                "FAIL(o%d/x%d/f%d)" % (len(overlaps), len(overmax), len(nofit))
            print("%-8s %-8d %6d %8d %8d %8d %s"
                  % (tier, seed, len(lots), len(overlaps), len(overmax),
                     len(nofit), verdict))
    # 聚合打印（避免 12 个 seed × 同一缺口刷屏）
    for (row, da, xa, db, xb), n in sorted(overlap_agg.items(), key=str):
        res.fail("lot 重叠 row%d %s%s 与 %s%s（%d 个组合）"
                 % (row, da, list(xa), db, list(xb), n))
    for (defn, wc, mx), combos in sorted(overmax_agg.items()):
        res.fail("%s lot %d 格(=%.0fpx) 超映射最大装配宽 %d 格（%s）"
                 % (defn, wc, wc * CELL, mx, ",".join("%s/%d" % c for c in combos)))
    for (defn, wc, need), combos in sorted(nofit_agg.items()):
        seen = list(dict.fromkeys(combos))
        res.fail("%s lot %d 格 无可用装配宽度档（最小可装配 %d 格 → 撑出地块 %d 格；"
                 "出现于 %s）"
                 % (defn, wc, need, need - wc,
                    ",".join("%s/%d" % c for c in seen)))
    print("聚合缺口：同排重叠 %d 类 / 超最大装配宽 %d 类 / 无可用装配档 %d 类"
          % (len(overlap_agg), len(overmax_agg), len(nofit_agg)))
    res.note("plan_city 成功 %d/%d 组合；同排重叠为布局器既有保证（本项 0 即口径成立）；"
             "「无可用装配档」是 DEF_MAP 桥接缺口（同见 [1]/[3]）"
             % (called, len(TIERS) * len(seeds)))
    return res


# ══════════════════════════════════════════════════════════════════════════
# 检查 3：装配适配（实际调装配器）
# ══════════════════════════════════════════════════════════════════════════
def check_assembly(def_map):
    res = Result(3, "装配适配")
    print("\n[3] 装配适配（DEF_MAP 每个映射声明的全部宽度档各实际调一次装配器）")
    # pairs：(asm, w) 来自 DEF_MAP 各映射的 allowed 宽度档（装配支持面全覆盖）
    # route：(asm, w) -> [(def, 该 def 声明的 lot 宽)]，即 pick_width 真正会路由到它的来源
    pairs, route = {}, {}
    for defn, (asm, allowed) in sorted(def_map.items()):
        if defn not in CL.DEFS or asm not in B.ASSEMBLERS:
            continue
        for w in sorted(allowed):
            pairs.setdefault((asm, w), [])
        for lot_w in CL.DEFS[defn]["widths"]:
            cw = pick_width(lot_w, sorted(allowed))
            route.setdefault((asm, cw), []).append((defn, lot_w))
    print("%-11s %-4s %-8s %-8s %-8s %-9s %s"
          % ("装配器", "格", "网格宽", "剪影总高", "出檐%", "spec", "pick_width 路由来源"))
    print("-" * 108)
    new_fails, fit_violations, baseline_hits = [], [], []
    asm_warns = {}          # 去重后的装配器自带 [warn]（不刷屏，汇总一次）
    for (asm, w) in sorted(pairs):
        abuf = io.StringIO()
        try:
            with contextlib.redirect_stdout(abuf):
                ob, spec = B.ASSEMBLERS[asm](w)
        except Exception as exc:
            res.fail("装配 %s(%d) 抛 %s: %s" % (asm, w, type(exc).__name__, exc))
            print("%-11s %-4d %s" % (asm, w, "FAIL(装配抛 %s)" % type(exc).__name__))
            continue
        for line in abuf.getvalue().splitlines():
            line = line.strip()
            if line.startswith("[warn]") and line not in asm_warns:
                asm_warns[line] = "%s(%d)" % (asm, w)
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rep = B.check_spec(spec, ob)
        except Exception as exc:
            res.fail("check_spec %s(%d) 抛 %s: %s" % (asm, w, type(exc).__name__, exc))
            wipe_meshes()
            continue
        grid_w = float(spec["grid_w"])
        srcs = route.get((asm, w), [])
        # 3a：实测网格宽 ≤ 该档实际服务的 lot 宽（逐来源判定，避免取最小值误报）
        for (defn, lot_w) in sorted(srcs):
            if grid_w > lot_w * CELL:
                fit_violations.append((asm, w, grid_w, defn, lot_w))
        # 3b：check_spec 基线比对
        bad = [k for k in ("ratio_ok", "grid_band_ok", "eave_ok", "door_ok",
                           "door_size_ok", "min_width_ok", "storey_ok")
               if not rep[k]]
        if not rep["pass"]:
            if (asm, w) in KNOWN_SPEC_FAIL:
                baseline_hits.append((asm, w, bad))
                tag = "FAIL(基线)"
            else:
                new_fails.append((asm, w, bad, rep))
                tag = "FAIL(新)"
                res.fail("新 check_spec FAIL：%s(%d) → %s（剪影比 %.2f 带 %s）"
                         % (asm, w, bad, rep["ratio"], rep["ratio_band"]))
        else:
            tag = "PASS"
        wipe_meshes()
        res.count += 1
        src_txt = ("; ".join("%s@%d" % (d, lw) for (d, lw) in srcs)
                   if srcs else "—（超出各 def 声明宽度，仅支持面覆盖）")
        print("%-11s %-4d %-8.0f %-8.0f %-8s %-9s %s"
              % (asm, w, grid_w, rep["sil_h"], "%.1f%%" % (rep["eave_ratio"] * 100.0),
                 tag, src_txt))
    for (asm, w, grid_w, defn, lot_w) in fit_violations:
        res.fail("装配宽超 lot：%s→%s(%d) 实测网格宽 %.0f > 该 lot 宽 %.0f（差 %d 格）"
                 % (defn, asm, w, grid_w, lot_w * CELL, w - lot_w))
    res.note("装配对=%d / 基线 FAIL=%s / 新 FAIL=%d / 宽度超 lot=%d"
             % (len(pairs), [(a, w) for (a, w, _b) in baseline_hits],
                len(new_fails), len(fit_violations)))
    if baseline_hits:
        print("  基线 FAIL（已知，不计）：%s" % [(a, w, b) for (a, w, b) in baseline_hits])
    if asm_warns:
        print("  装配器自带 [warn]（去重后 %d 类，不参与判定）：" % len(asm_warns))
        for line, where in asm_warns.items():
            print("    %s  ← 首次出现于 %s" % (line, where))
        res.note("装配器 [warn] %d 类（见上，属装配器内部告警，check_spec 未判 FAIL）"
                 % len(asm_warns))
    return res


# ══════════════════════════════════════════════════════════════════════════
# 检查 4：窗规格 lint
# ══════════════════════════════════════════════════════════════════════════
def check_window_spec():
    res = Result(4, "窗规格 lint")
    spec = B.WINDOW_SPEC
    print("\n[4] 窗规格 lint（WINDOW_SPEC %d 档）" % len(spec))
    res.count = len(spec)
    # 4a 字段齐备
    for kind, d in sorted(spec.items()):
        miss = [f for f in ("sill", "h", "muntins") if f not in d]
        if "frac" not in d and "w" not in d:
            miss.append("frac|w")
        if miss:
            res.fail("窗档 %s 缺约束字段：%s" % (kind, miss))
    # 4b 窗台一致 / 4c 窗高带
    resident = [k for k, d in spec.items() if "frac" in d] + ["lancet"]
    print("  居室窗档（frac + lancet）：%s" % resident)
    for kind in resident:
        d = spec[kind]
        exp = WIN_SILL_EXCEPT.get(kind, WIN_SILL_STD)
        if abs(d["sill"] - exp) > 1e-6:
            res.fail("窗台口径不一致：%s sill=%.0f（应为 %.0f 或已登记例外 %s）"
                     % (kind, d["sill"], exp, sorted(WIN_SILL_EXCEPT)))
        if kind not in WIN_H_EXCEPT and not (WIN_H_BAND[0] <= d["h"] <= WIN_H_BAND[1]):
            res.fail("窗高越界：%s h=%.0f（规范 %.0f~%.0f）"
                     % (kind, d["h"], WIN_H_BAND[0], WIN_H_BAND[1]))
    print("  窗台：标准 %.0f；例外 %s；实测 %s"
          % (WIN_SILL_STD,
             {k: v for k, v in WIN_SILL_EXCEPT.items()},
             {k: spec[k]["sill"] for k in resident}))
    print("  窗高：带 %.0f~%.0f；实测 %s；豁免 %s"
          % (WIN_H_BAND[0], WIN_H_BAND[1],
             {k: spec[k]["h"] for k in resident}, sorted(WIN_H_EXCEPT)))
    # 4d 同立面窗型 ≤2 的约束字段（分立面常量组）
    for fld in WIN_FACADE_FIELDS:
        if not hasattr(B, fld):
            res.fail("分立面窗型约束常量缺失：buildings.%s" % fld)
            continue
        kind = getattr(B, fld)
        if kind not in spec:
            res.fail("%s=%r 不在 WINDOW_SPEC 内" % (fld, kind))
    for gname, flds in WIN_FACADE_GROUPS.items():
        kinds = []
        for fld in flds:
            if hasattr(B, fld):
                kinds.append(getattr(B, fld))
        uniq = sorted(set(kinds))
        if len(uniq) > WIN_PER_FACADE_MAX:
            res.fail("分立面「%s」窗型 %d 种 > %d：%s"
                     % (gname, len(uniq), WIN_PER_FACADE_MAX, uniq))
        print("  分立面「%s」：常量 %s → 窗型 %s（%d/%d）"
              % (gname, list(flds), uniq, len(uniq), WIN_PER_FACADE_MAX))
    # 4e 装配器源码扫描（信息性）：各 assemble_* 引用的窗型常量
    src = open(os.path.join(HERE, "buildings.py"), encoding="utf-8").read()
    tree = ast.parse(src)
    const_names = {k: getattr(B, k) for k in WIN_FACADE_FIELDS if hasattr(B, k)}
    scanned = 0
    for node in tree.body:
        if not (isinstance(node, ast.FunctionDef) and node.name.startswith("assemble_")):
            continue
        seg = ast.get_source_segment(src, node) or ""
        used = sorted({const_names[n] for n in set(re.findall(r"\bWIN_[A-Z_]+\b", seg))
                       if n in const_names})
        if used:
            scanned += 1
            print("  源码窗型取用 %-14s → %s" % (node.name, used))
    res.note("档位=%d；居室档=%d；分立面组=%d；源码扫描装配器=%d"
             % (len(spec), len(resident), len(WIN_FACADE_GROUPS), scanned))
    return res


# ══════════════════════════════════════════════════════════════════════════
# 检查 5：纹素密度纪律（源码级）
# ══════════════════════════════════════════════════════════════════════════
def check_texel_density():
    res = Result(5, "纹素密度纪律")
    print("\n[5] 纹素密度纪律（materials.py 源码级）")
    src = open(MAT_SRC_PATH, encoding="utf-8").read()
    tree = ast.parse(src)
    # 5a M_PER_UV 字面量
    literal = None
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "M_PER_UV" for t in node.targets):
            try:
                literal = float(ast.literal_eval(node.value))
            except Exception:
                literal = None
    if literal is None:
        res.fail("materials.py 里找不到 M_PER_UV 的常量赋值")
    elif abs(literal - M_PER_UV_EXPECT) > 1e-9:
        res.fail("M_PER_UV=%.6f ≠ 规范 %.2f" % (literal, M_PER_UV_EXPECT))
    print("  M_PER_UV 字面量 = %s（规范 %.2f）" % (literal, M_PER_UV_EXPECT))
    # 5b 每个 UV 标定入口必须引用 M_PER_UV（不得硬编码比例）
    entries = ("uv_m", "uv_cm", "uv_mm")
    for fn_name in entries:
        fn = next((n for n in tree.body
                   if isinstance(n, ast.FunctionDef) and n.name == fn_name), None)
        if fn is None:
            res.fail("UV 标定入口缺失：%s()" % fn_name)
            continue
        seg = ast.get_source_segment(src, fn) or ""
        if "M_PER_UV" not in seg:
            res.fail("%s() 未引用 M_PER_UV（疑似硬编码米/UV 比例）：%s"
                     % (fn_name, seg.strip().splitlines()[-1].strip()))
        else:
            print("  %s() → 引用 M_PER_UV ✔" % fn_name)
    # 5c 源码里不许再出现其它「米/UV」比例常量
    bad = []
    for m in re.finditer(r"/\s*(0\.4[0-9]+)", src):
        line = src[:m.start()].count("\n") + 1
        bad.append("第 %d 行 除法分母 %s（疑似硬编码 m/UV）" % (line, m.group(1)))
    for m in re.finditer(r"\b0\.0131[0-9]*\b", src):
        line = src[:m.start()].count("\n") + 1
        bad.append("第 %d 行 出现 0.0131x（cm/UV 的另一种写法）" % line)
    # 模块级常量：名字像「x_PER_UV / UV_PER_x」的比例常量必须等于 M_PER_UV
    for node in tree.body:
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Constant):
            continue
        if not isinstance(node.value.value, (int, float)):
            continue
        for t in node.targets:
            if not isinstance(t, ast.Name):
                continue
            nm = t.id.upper()
            if ("PER_UV" in nm or "UV_PER" in nm) and abs(
                    float(node.value.value) - M_PER_UV_EXPECT) > 1e-9:
                bad.append("第 %d 行 常量 %s=%.6f ≠ %.2f"
                           % (node.lineno, t.id, float(node.value.value),
                              M_PER_UV_EXPECT))
    for b in bad:
        res.fail("硬编码比例常量：" + b)
    refs = [src[:m.start()].count("\n") + 1 for m in re.finditer(r"\bM_PER_UV\b", src)]
    print("  M_PER_UV 引用行 = %s；疑似其它比例常量 = %d 处" % (refs, len(bad)))
    res.count = len(entries) + 1
    res.note("uv_* 入口 %d 个；M_PER_UV 引用 %d 处；违规常量 %d 处"
             % (len(entries), len(refs), len(bad)))
    return res


# ══════════════════════════════════════════════════════════════════════════
# 检查 6：道具挂载回归
# ══════════════════════════════════════════════════════════════════════════
def check_props():
    res = Result(6, "道具挂载回归")
    print("\n[6] 道具挂载回归（DRESS %d 套配方 @ 默认宽 %.0f = %.0f 格，不渲染）"
          % (len(P.DRESS), PROPS_DEFAULT_W, PROPS_DEFAULT_W / CELL))
    print("%-12s %6s %8s %8s %8s %s"
          % ("配方", "道具数", "pack", "dress", "最小/最大占位宽", "判定"))
    print("-" * 84)
    for kind in sorted(P.DRESS):
        items = P.DRESS[kind]
        res.count += 1
        unknown = [n for (n, _s, _kw) in items if n not in P.TABLE]
        if unknown:
            res.fail("配方 %s 含未注册道具名（dress 会静默丢弃）：%s" % (kind, unknown))
        if not items:
            res.fail("配方 %s 为空（道具数 <1）" % kind)
            continue
        try:
            plan = P.pack_sides(PROPS_DEFAULT_W, items, 0.0, 50.0)
        except Exception as exc:
            res.fail("pack_sides(%s) 抛 %s: %s" % (kind, type(exc).__name__, exc))
            print("%-12s %6s %8s" % (kind, "-", "FAIL(异常)"))
            continue
        b = B.Builder("propsval_%s" % kind)
        try:
            placed = P.dress(b, kind, PROPS_DEFAULT_W, 0.0, seed=7,
                             door_x=0.0, door_w=50.0)
        except Exception as exc:
            res.fail("dress(%s) 抛 %s: %s" % (kind, type(exc).__name__, exc))
            wipe_meshes()
            print("%-12s %6s %8d %8s" % (kind, "-", len(plan), "FAIL(异常)"))
            continue
        width = []
        for (name, cx, side, kw) in plan:
            w = float(P.WIDTH.get(name, 40.0)) * P.GAME_SCALE
            if name in P.SPAN:
                w = abs(kw.get("x1", 0.0) - kw.get("x0", 0.0)) * P.GAME_SCALE + 20.0
            width.append(w)
            if w <= 0.0:
                res.fail("配方 %s 道具 %s 占位宽非正：%.2f" % (kind, name, w))
        wipe_meshes()
        n = len(placed)
        if n < 1:
            res.fail("配方 %s 在默认宽 %.0f 下道具数 0（<1）" % (kind, PROPS_DEFAULT_W))
        verdict = "PASS" if (n >= 1 and not unknown) else "FAIL"
        print("%-12s %6d %8d %8d %8.0f/%-8.0f %s"
              % (kind, len(items), len(plan), n,
                 (min(width) if width else 0.0), (max(width) if width else 0.0),
                 verdict))
    res.note("配方=%d；默认宽 %.0f；全部 ≥1 件为 PASS 口径"
             % (len(P.DRESS), PROPS_DEFAULT_W))
    return res


# ══════════════════════════════════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════════════════════════════════
def main():
    t0 = time.time()
    only = parse_only()
    seeds = parse_seeds()
    print("=" * 108)
    print("建筑管线 v3 自动校验 validate.py（无渲染）  "
          "检查项=%s  seeds=%s  blender=%s"
          % (sorted(only) if only else "1-6", seeds, bpy.app.version_string))
    print("=" * 108)
    # 一张场景只 read_factory_settings 一次（交接档 §六 材质缓存坑）
    bpy.ops.wm.read_factory_settings(use_empty=True)
    try:
        B._CACHE.clear()
    except Exception:
        pass
    try:
        MAT.reset_cache()
    except Exception:
        pass

    results = []
    try:
        def_map = load_def_map()
        prop_map = load_prop_lots()
    except Exception as exc:
        print("!! DEF_MAP/PROP_LOTS 解析失败：%s" % exc)
        print(traceback.format_exc())
        return 1

    runners = [
        (1, lambda: check_coverage(def_map, prop_map)),
        (2, lambda: check_lots(def_map, seeds)),
        (3, lambda: check_assembly(def_map)),
        (4, lambda: check_window_spec()),
        (5, lambda: check_texel_density()),
        (6, lambda: check_props()),
    ]
    for idx, fn in runners:
        if only and idx not in only:
            continue
        ts = time.time()
        try:
            res = fn()
        except Exception as exc:
            res = Result(idx, "检查 %d" % idx)
            res.fail("检查自身崩溃：%s: %s" % (type(exc).__name__, exc))
            print(traceback.format_exc())
        res.secs = time.time() - ts
        results.append(res)

    total = time.time() - t0
    print("\n" + "=" * 108)
    print("汇总表")
    print("%-6s %-16s %-6s %-10s %s" % ("检查项", "名称", "结果", "明细数", "耗时"))
    print("-" * 108)
    n_fail = 0
    for r in results:
        if not r.ok:
            n_fail += 1
        print("%-6d %-16s %-6s %-10d %.1fs"
              % (r.idx, r.name, "PASS" if r.ok else "FAIL", r.count, r.secs))
    print("-" * 108)
    for r in results:
        if not r.ok:
            for f in r.fails:
                print("  FAIL[%d] %s" % (r.idx, f))
        for nt in r.notes:
            print("  note[%d] %s" % (r.idx, nt))
    print("-" * 108)
    print("总计：%d 项检查，FAIL %d 项，用时 %.1fs（预算 ≤90s）  → 退出码 %d"
          % (len(results), n_fail, total, 1 if n_fail else 0))
    print("=" * 108)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
