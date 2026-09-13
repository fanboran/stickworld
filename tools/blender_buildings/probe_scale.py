# -*- coding: utf-8 -*-
"""probe_scale.py —— **带尺寸标注的比例审计图**（管线 v3 · 米制比例审计）

为什么有这张图
--------------
创始人看单体图后说"比例还是有点奇怪"，但没说是哪一项。本探针的作用是**把比例量出来、
标在图上**，让"奇怪"落到具体项（门高 / 檐高 / 层高 / 屋面 rise / 总剪影高 / 网格宽 /
进深 / 出檐 / 锥顶占比）的实测米数上，并与规范逐项对表。

图上有什么（每栋）
------------------
* **0.5m 刻度尺**（每 0.5m 一道刻度、每 1m 一道贯通虚线 + 米数标签），标尺锚在
  **前墙面平面**（y 最小处的那条落地线）—— 20° 俯视下"同一 z 平面越靠后屏幕越高"，
  故一切高度都按"前立面平面上的世界 Z（米）"读，图注里写明这条约定；
* **火柴人身高标尺**：同尺度 130px 火柴人 + 1.70m 青色标记线；
* 关键尺寸标注线与**实测数值**：门净高 / 檐口高 / 逐层层高 / 屋面 rise / 总高 /
  网格宽 / 出檐（含 %）/ 进深（含"投影为竖直 d·sin20°"的观感偏移）；
* **面板**：该 def 的实际米制尺寸与规范值的偏差（如"檐高 6.8m / 应为 5.2~5.4m ← 超标"），
  超标红 / 偏低橙 / 合规绿；面板同时把同样内容打到 stdout（文本可复跑对表）。

视角与取景口径与 probe_buildings/probe_d3b 一致：正交 + 纯正面（yaw=0）+ 俯角 20°；
本探针额外把每栋的**前墙面平面平移到 y=0**，这样所有标尺共用同一条落地线，横向可比。

跑法（两段式：Blender 出干净渲染 + 元数据，再用带 PIL 的系统 python 叠标注）
------------------------------------------------------------------------
    BLENDER="/f/SteamLibrary/steamapps/common/Blender/blender.exe"
    cd tools/blender_buildings
    "$BLENDER" -b --factory-startup -P probe_scale.py                 # 渲染 + 自动叠标注
    "$BLENDER" -b --factory-startup -P probe_scale.py                 # 同上（SCALE_ACTION 默认 render）
    SCALE_ACTION=audit "$BLENDER" -b --factory-startup -P probe_scale.py   # 只打审计表（不渲染）
    python probe_scale.py                                             # 只叠标注（用已有渲染）
    SCALE_ONLY=mage_tower,stable "$BLENDER" ... -P probe_scale.py     # 只出这些 def
    SCALE_ACTION=audit  ...   # 只打审计表（不渲染）
    SCALE_SKIP_SINGLE=1 ...   # 复用已有单栋裸图（只重渲总图）
    SCALE_SKIP_RENDER=1 ...   # 裸图全复用，只重叠标注（整轮 ~40 秒）

为什么分两段：Blender 自带 python **没有 PIL**（实测），而标注要中文字体/文字排版。
第一段（Blender）产出裸渲染 + `_scale_raw/scale_meta.json`；第二段（系统 python + PIL）
读 json 叠图。第一段结束会自动尝试调用 `python probe_scale.py`，失败会打印手动命令。

产物（stick-world/temp/）
------------------------
    _scale_raw/scale_meta.json          全部实测数据（可直接给别的工具消费）
    _scale_raw/single_<def>_w<N>.png    裸渲染（无标注）
    pbr_scale_sheet.png                 全部 def × 宽度档，**同尺度**分排 + 标注
    pbr_scale_<def>.png                 重点 def 的单栋大图（主宽度档）
    pbr_scale_<def>_w<N>.png            其余宽度档的单栋大图
"""

import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
RAW_DIR = os.path.join(OUT_DIR, "_scale_raw")
META_PATH = os.path.join(RAW_DIR, "scale_meta.json")

# ---------------------------------------------------------------- 世界/相机
CELL = 32.0
STICKMAN_H = 130.0
PX_PER_M = STICKMAN_H / 1.70           # 130px ↔ 1.70m → 76.47 px/m
DOOR_SILL = 8.0
M_PER_CELL = CELL / PX_PER_M           # 0.4185 m
YAW = 0.0
TILT = 20.0
SIN_T = math.sin(math.radians(TILT))
COS_T = math.cos(math.radians(TILT))
ZOOM_SINGLE = 2.0                      # 单栋大图倍率（1 格 = 64px）
ZOOM_SHEET = 1.0                       # 总图倍率（同尺度：所有排共用）
SHEET_COLS = 8
MAT_FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\simhei.ttf", r"C:\Windows\Fonts\Deng.ttf",
    r"C:\Windows\Fonts\simsun.ttc", r"C:\Windows\Fonts\arial.ttf",
]

# ---------------------------------------------------------------- 规范表
# 唯一真相源：交接档 §0.3 硬约束 + 设计文档 §8.7 米制表 + §8.2/§8.3。
# 长度单位一律 **米**（世界 px ÷ 76.47）；本探针只读规范、不写规范。
N_DOOR = (1.94, 2.06)                  # 门净高 2.00m
N_STOREY = (2.60, 2.72)                # 层高 / 单层檐高（墙顶）200~207px
N_STOREY_SMALL = (2.38, 2.72)          # ≤6 格小屋允许 183px=2.4m
N_EAVE1 = N_STOREY
N_EAVE1_SMALL = N_STOREY_SMALL
N_EAVE2 = (5.20, 5.42)                 # 两层檐高 400~413px
N_EAVE3 = (7.80, 8.12)                 # 三层檐高 600~620px
N_RISE_REL = (0.45, 0.62)              # 单层：rise ≈ 檐高 × 0.5
N_RISE_ABS = (1.25, 1.65)
N_EAVE_RATIO = (0.18, 0.23)            # 出檐（每侧）= 建筑宽 × 18~23%
N_PITCH_DEG = (18.0, 58.0)             # 屋面坡度（坡面 = 半进深 + 出檐；茅草偏陡、
N_TOWER_FLOOR = (3.5, 4.5)             # 塔身每层 3.5~4.5m
N_TOWER_BODY_DOORS = 3.0               # 塔身 ≥ 3×门高（≈6m，够两层）
N_TOP_RATIO = 1.00                     # 锥顶/尖顶组 ≤ 塔身（"锥顶不得压过塔身"）
N_DOOR_W_CODE = (0.59, 0.78)           # §8.3 单扇门宽 45~60px
N_DOOR_W_DOC = (0.90, 1.00)            # §8.7 表（与 §8.3 冲突，仅提示）
N_DOOR_MAX_W_SHARE = 0.35              # 门宽 / 圆塔直径 上限（超 = 4 格滥用信号）

#: 重点排查 def（出单栋大图）；值 = 主宽度档
FOCUS = {
    "mage_tower": 6, "alchemy": 8, "library": 12, "barracks": 12,
    "warehouse": 12, "stable": 8, "shelter": 4, "hayloft": 8,
}
#: 塔类 def（走塔身/锥顶专项口径）
TOWER_DEFS = ("mage_tower", "tower", "windmill", "lighthouse")
#: 开敞棚（无门无墙 → 檐高/门层高比口径豁免）
OPEN_DEFS = ("smithy1", "smithy2", "shelter")
#: 通高单层体量（仓库/城门楼：墙面必须容下货门/城门，不按民居檐高口径）
TALL_DEFS = ("warehouse", "gatehouse")
#: 门/层高比只作提示的 def（≤6 格小屋：§8.7 允许 183px=2.4m 层高 → 门占 82%）
RATIO_SOFT_DEFS = ("cottage",)
#: **非居室底层**（马厩/干草棚/仓库/工坊棚）：底层是厩舍/棚下/库房，不按居室 73~75%
#: 口径评"门占层高"，改评"底层 ≥ 门高 + 0.10m（门楣带）"——门能把人放过、门顶不贴楼板。
UTILITY_DEFS = ("stable", "hayloft", "warehouse", "smithy1", "smithy2", "shelter")

V_OK = (72, 200, 104)
V_OVER = (238, 86, 74)
V_UNDER = (242, 170, 62)
V_NONE = (215, 220, 228)
C_DIM = (255, 214, 96)
C_RULER = (150, 200, 255)


def M(px):
    return float(px) / PX_PER_M


def P(meters):
    return float(meters) * PX_PER_M


def _ver(v, lo, hi):
    if lo <= v <= hi:
        return "OK"
    return "↑超标" if v > hi else "↓偏低"


def _vcolor(v):
    return {"OK": V_OK, "↑超标": V_OVER, "↓偏低": V_UNDER}.get(v, V_NONE)


# ================================================================ §1 审计逻辑
# 纯 python（不依赖 bpy/PIL），render 段与 annotate 段共用：render 段用 spec 对象，
# annotate 段用 json 里的 spec 子集。

def _tower_sections(spec):
    return int(spec.get("tower_sections") or 1)


def audit(spec, meas):
    """→ (rows, worst, hard_worst)。

    rows = [(项, 实测文本, 规范文本, 判定)]，判定 ∈ {None,"OK","↑超标","↓偏低"}；
    hard=False 的行只报数不参与"是否超标"的结论（开敞棚/塔类专项/受保护 def）。
    """
    rows = []

    def add(item, actual, target, ver, hard=True):
        rows.append((item, actual, target, ver, hard))

    name = spec.get("def")
    wc = int(spec.get("width_cells") or 0)
    W = float(spec.get("grid_w") or 0.0)
    plinth = float(spec.get("plinth_h") or 0.0)
    eave = float(spec.get("eave_h") or 0.0)
    rise = float(spec.get("rise") or 0.0)
    depth = float(spec.get("depth") or 0.0)
    over = float(spec.get("overhang") or 0.0)
    st = [float(s) for s in (spec.get("storey_h") or [])]
    door = spec.get("door")
    sil = meas.get("sil") or {}
    z_max = float(meas.get("z_max") or 0.0)
    sil_h = float(sil.get("h") or z_max)
    y_span = meas.get("y_span") or depth
    tower = name in TOWER_DEFS
    open_def = name in OPEN_DEFS or door is None
    tall_def = name in TALL_DEFS
    utility = name in UTILITY_DEFS
    small = wc <= 6
    nst = len(st)
    dh = float(door[1]) if door else 0.0
    hard_base = not (tower or tall_def)
    # 层高口径：**从所在层地面（= 勒脚顶）起算**（设计文档 §8.7「两层檐高 = 层高×2」的
    # 同一算法）。勒脚是基座，不计入墙高；地面起的数字一并报出，方便与实拍对读。
    wall1 = eave - plinth if eave > 0 else 0.0

    # ---- 体量
    add("网格宽", "%.2f m（%d 格 = %.2f 现实米）" % (M(W), wc, M(W)), "0.42 m/格",
        None, hard=False)
    add("进深", "%.2f m" % M(depth), "—", None, hard=False)
    if spec.get("eave_exempt") or over <= 0.5:
        add("出檐", "%.2f m（%.1f%%）" % (M(over), over / max(1.0, W) * 100.0),
            "宽×18~23%（本 def 豁免）", None, hard=False)
    else:
        er = over / W
        add("出檐", "%.2f m（%.1f%%）" % (M(over), er * 100.0), "宽×18~23%",
            _ver(er, *N_EAVE_RATIO), hard_base)

    # ---- 门（人 vs 门）
    if door:
        dw, dh = float(door[0]), float(door[1])
        comp = bool(spec.get("composite_door"))
        add("门净高", "%.2f m（%.0fpx%s）" % (M(dh), dh, "*复合门洞" if comp else ""),
            "2.00 m", _ver(M(dh), *N_DOOR), hard_base)
        dwm = M(dw)
        note = ""
        if not comp and dwm < N_DOOR_W_DOC[0] - 0.01:
            note = "；§8.7 表写 0.9~1.0m ← 文档自相矛盾"
        add("门宽", "%.2f m（%.0fpx）%s" % (dwm, dw, note),
            "%.2f~%.2f m（§8.3）" % N_DOOR_W_CODE,
            None if comp else _ver(dwm, *N_DOOR_W_CODE), hard=False)
        if wc <= 4 and M(W) < 2.6:
            add("4 格带门", "%.2f m 宽体量上开 %.2f m 的门" % (M(W), dwm),
                "4 格档只做小物件（§8.2）", "↑超标", hard=False)
        # 门 vs 所在层：门顶是否被楼板/上层墙压住（可见净高 → 人能不能过门）
        if nst and not spec.get("double_storey") and not tower:
            floor_top = plinth + st[0]
            door_top = float(spec.get("door_bottom") or DOOR_SILL) + dh
            if door_top > floor_top + 2.0:
                add("门顶 vs 楼板", "可见净高 %.2f m（门顶越过地面层顶 %.0fpx）"
                    % (M(floor_top - float(spec.get("door_bottom") or DOOR_SILL)),
                       door_top - floor_top),
                    "门顶须在楼板下", "↑超标", hard_base)

    # ---- 檐高（墙顶口径 = 所在层地面起；地面起数字一并报）
    if open_def:
        add("柱高（开敞棚）", "%.2f m" % M(eave), "开敞棚无民居檐高口径",
            None, hard=False)
    elif tower:
        add("檐口高（塔身顶）", "%.2f m（地面起 %.2f m）" % (M(wall1), M(eave)),
            "塔类另核（塔身/锥顶）", None, hard=False)
    elif tall_def:
        add("檐口高（通高体量）", "%.2f m（地面起 %.2f m）" % (M(wall1), M(eave)),
            "仓库/城门：容量决定（不按民居檐高）", None, hard=False)
    else:
        if nst <= 1:
            band = N_EAVE1_SMALL if small else N_EAVE1
            add("檐口高（墙顶）", "%.2f m（地面起 %.2f m 含勒脚 %.2f m）"
                % (M(wall1), M(eave), M(plinth)),
                "%.2f~%.2f m（%s）" % (band[0], band[1],
                                      "6 格小屋可 2.38" if small else "200~207px"),
                _ver(M(wall1), *band), hard_base)
        else:
            band = N_EAVE2 if nst == 2 else N_EAVE3
            lbl = "两层檐高" if nst == 2 else "三层檐高"
            two_real = bool(spec.get("double_storey")) and nst == 2
            if nst == 2 and not two_real:
                lbl = "檐口高（1.5 层）"
            add(lbl, "%.2f m（地面起 %.2f m）" % (M(wall1), M(eave)),
                "%.2f~%.2f m（层高×%d）" % (band[0], band[1], nst),
                _ver(M(wall1), *band) if (two_real or nst >= 3) else None,
                hard_base and two_real and not spec.get("ratio_exempt"))

    # ---- 层高（逐层）+ 门/层高比（设计文档 §8.7 点名的真正病根）
    if st:
        band = N_STOREY_SMALL if small else N_STOREY
        audited = st if (spec.get("double_storey") or nst == 1) else st[:1]
        worst_st = "OK"
        for s in audited:
            v = _ver(M(s), *band)
            if v == "↑超标":
                worst_st = "↑超标"
            elif v == "↓偏低" and worst_st != "↑超标":
                worst_st = "↓偏低"
        txt = " / ".join("%.2f m" % M(s) for s in audited)
        if nst != len(audited):
            txt += "（+%.2f m 阁楼膝墙，不计层）" % M(st[1])
        add("层高", txt, "%.2f~%.2f m（≤6 格 %.2f）"
            % (band[0], band[1], N_STOREY_SMALL[0]),
            worst_st, hard_base and not (open_def or utility))
        if door and not tower and st:
            if utility:
                need = float(spec.get("door_bottom") or DOOR_SILL) + dh + 8.0
                ftop = plinth + st[0]
                add("底层 ≥ 门楣带", "底层 %.2f m（门顶 + %.0fpx）"
                    % (M(st[0]), ftop - need),
                    "≥ 门高 + 0.10 m（非居室底层）",
                    _ver(ftop, need, 1e9), hard_base)
            else:
                share = dh / st[0]
                soft = small or name in RATIO_SOFT_DEFS
                add("门 / 层高", "%.0f%%" % (share * 100.0),
                    "≤76%（现实 74%）" if not small else "≤82%（6 格小屋例外）",
                    _ver(share, 0.0, 0.82 if soft else 0.76), hard_base and not soft)

    # ---- 屋面（硬口径 = 坡度；rise 的绝对值/比值作参考；锥顶塔另核，不走坡屋顶公式）
    # 坡度 = rise ÷ 半跨；跨 = 进深（屋脊沿 X）或面宽（屋脊沿 Y，山墙朝前，如 guildhall）。
    # **出檐不计入跨度**（出檐只是同一坡面往外延，坡角不变）。
    if rise > 0.5 and not tower:
        span = W if spec.get("ridge_axis") == "Y" else depth
        pitch = math.degrees(math.atan(rise / max(1.0, span / 2.0)))
        pv = _ver(pitch, *N_PITCH_DEG)
        add("屋面 rise", "%.2f m（檐高×%.2f，坡 %.0f°）"
            % (M(rise), rise / max(1.0, wall1 or eave), pitch),
            "坡 %.0f~%.0f°（rise ≈ 檐高×%.2f~%.2f、%.2f~%.2f m）"
            % (N_PITCH_DEG + N_RISE_REL + N_RISE_ABS), pv, hard_base)

    # ---- 总高 / 剪影
    add("总高（Z）", "%.2f m（%.0fpx）" % (M(z_max), z_max), "—", None, hard=False)
    add("剪影（投影高）", "%.2f m（%.0fpx）＝总高 %.2f m＋进深投影 %.2f m"
        % (M(sil_h), sil_h, M(z_max), M(y_span * SIN_T)),
        "20° 俯角的固有放大", None, hard=False)
    rband = spec.get("ratio_band") or (0.85, 1.50)
    ratio = sil_h / max(1.0, W)
    add("长宽比", "%.2f（%.2f~%.2f）" % (ratio, rband[0], rband[1]),
        "自带口径" if spec.get("ratio_band") else "§8.2 0.85~1.50",
        None if spec.get("ratio_exempt") else _ver(ratio, *rband),
        hard_base and not spec.get("ratio_exempt"))

    # ---- 塔类专项：塔身每层 / 塔身 vs 门 / 锥顶 vs 塔身
    if tower:
        body = eave - plinth
        ns = _tower_sections(spec)
        mage = (name == "mage_tower")
        if body > 1.0 and ns >= 1:
            per = M(body / ns)
            add("塔身每层", "%.2f m（塔身 %.2f m ÷ %d 段）" % (per, M(body), ns),
                "%.1f~%.1f m/段" % N_TOWER_FLOOR,
                _ver(per, *N_TOWER_FLOOR) if mage else None, mage)
        if door:
            add("塔身 / 门高", "%.2f×（塔身 %.2f m ÷ 门 %.2f m）"
                % (body / dh, M(body), M(dh)),
                "≥%.1f×（≈6m，够两层）" % N_TOWER_BODY_DOORS,
                _ver(body / dh, N_TOWER_BODY_DOORS, 1e9), mage)
        if rise > 0.5:
            add("锥顶组 / 塔身", "%.2f（顶组 %.2f m ÷ 塔身 %.2f m）"
                % (rise / max(1.0, body), M(rise), M(body)),
                "≤%.2f" % N_TOP_RATIO,
                _ver(rise / max(1.0, body), 0.0, N_TOP_RATIO), mage)

    # ---- 汇总
    worst = "OK"
    hard_worst = "OK"
    for (_i, _a, _t, v, hard) in rows:
        if v == "↑超标":
            if hard and hard_worst != "↑超标":
                hard_worst = "↑超标"
            if worst != "↑超标":
                worst = "↑超标"
        elif v == "↓偏低":
            if hard and hard_worst == "OK":
                hard_worst = "↓偏低"
            if worst == "OK":
                worst = "↓偏低"
    return rows, worst, hard_worst


def spec_json(spec):
    """spec → JSON 安全子集（tuple→list；只保留标注/审计用得着的键）。"""
    keys = ("def", "width_cells", "grid_w", "depth", "plinth_h", "wall_h",
            "eave_h", "rise", "total_h", "overhang", "roof_t", "storey_h",
            "door", "door_x", "door_bottom", "double_storey", "composite_door",
            "ratio_band", "ratio_exempt", "eave_exempt", "width_exempt",
            "storey_band", "tower_sections", "material", "bays", "floor_h",
            "open_shed", "open_stall", "jetty", "reason", "tower_h", "spire_h",
            "ridge_axis", "lantern_h")
    out = {}
    for k in keys:
        if k not in spec:
            continue
        v = spec[k]
        if isinstance(v, (tuple, list)):
            out[k] = [float(x) if isinstance(x, (int, float)) else x for x in v]
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            out[k] = float(v)
        else:
            out[k] = v
    return out


def audit_all(B, only=()):
    """对 PROBE_LIST 全部条目跑审计，返回 (entries, 文本表)。"""
    entries = []
    lines = []
    lines.append("%-11s %2s %7s %7s %7s %11s %7s %8s %8s  %s"
                 % ("def", "格", "网格宽", "门净高", "檐口高", "层高", "rise",
                    "总高Z", "剪影高", "判定（硬）"))
    lines.append("-" * 140)
    for (name, wc) in B.PROBE_LIST:
        if only and name not in only:
            continue
        ob, spec = B.ASSEMBLERS[name](wc)
        sil = B.silhouette(ob)
        bb = B.shape_bbox(ob)
        meas = {"sil": sil, "z_max": bb["z"][1], "z_min": bb["z"][0],
                "x_span": bb["x"][1] - bb["x"][0],
                "y_span": bb["y"][1] - bb["y"][0]}
        rows, worst, hard_worst = audit(spec, meas)
        st = spec.get("storey_h") or []
        door = spec.get("door")
        lines.append("%-11s %2d %7.2f %7s %7.2f %11s %7.2f %8.2f %8.2f  %s"
                     % (name, wc, M(spec["grid_w"]),
                        ("%.2f" % M(door[1])) if door else "-",
                        M(spec.get("eave_h") or 0.0),
                        "/".join("%.2f" % M(s) for s in st) if st else "-",
                        M(spec.get("rise") or 0.0),
                        M(bb["z"][1]), M(sil["h"]),
                        {"OK": "PASS", "↑超标": "超标", "↓偏低": "偏低"}[hard_worst]))
        for (item, actual, target, ver, hard) in rows:
            if ver in ("↑超标", "↓偏低") and hard:
                lines.append("      ! %-12s %-30s 应为 %-26s %s"
                             % (item, actual, target, ver))
        entries.append({"name": name, "wc": wc, "spec": spec_json(spec),
                        "meas": meas, "rows": rows, "worst": worst,
                        "hard_worst": hard_worst})
        bpy_remove(B, ob)
    return entries, "\n".join(lines)


def bpy_remove(B, ob):
    import bpy
    me = ob.data
    bpy.data.objects.remove(ob, do_unlink=True)
    try:
        bpy.data.meshes.remove(me)
    except Exception:
        pass


# ================================================================ §2 渲染段
# 世界约定：每栋的**前墙面平面**（y 最小处）平移到 y=0；+Z 向上；正面朝 -Y。
# 于是 "(x, 0, z)" 的点就是"前立面上高 z"的位置，标尺/标注全用这条线。

def _meta_from_shot(info, right, up, cu, cv, y_front, y_back, z_max, x_span,
                    stick_x, res):
    return {"img": [res[0], res[1]], "k": info["k"], "cu": cu, "cv": cv,
            "right": [right[0], right[1], right[2]],
            "up": [up[0], up[1], up[2]], "y_front": y_front, "y_back": y_back,
            "z_max": z_max, "x_span": x_span, "stick_x": stick_x}


def _place(B, bpy, name, wc, cell_x0=None, y_front=0.0):
    """装配一栋 + 前墙面对齐到 y=y_front（可选 x 对齐到 cell_x0）。"""
    ob, spec = B.ASSEMBLERS[name](wc)
    bb = B.shape_bbox(ob)
    ob.location.y += (y_front - bb["y"][0])
    if cell_x0 is not None:
        ob.location.x += (cell_x0 - bb["x"][0])
    bpy.context.view_layer.update()
    bb = B.shape_bbox(ob)
    return ob, spec, bb


def _stick(B, bpy, x, y=7.0):
    sb = B.Builder("stick")
    B.stickman(sb, x=x, y=y)
    return sb.to_object()


def render_phase():
    import bpy
    import buildings as B

    os.makedirs(RAW_DIR, exist_ok=True)
    only = [s for s in os.environ.get("SCALE_ONLY", "").split(",") if s]
    action = os.environ.get("SCALE_ACTION", "render")
    pairs = [(n, w) for (n, w) in B.PROBE_LIST if not only or n in only]

    # ---- 审计表（文本，先打）
    entries, table = audit_all(B, only)
    print("\n=== 比例审计表（米制；1px=1.31cm；高度按前墙面平面上的世界 Z）===")
    print(table)
    if action == "audit":
        print("\nSCALE_AUDIT_DONE")
        return

    by = {(e["name"], e["wc"]): e for e in entries}

    # ---- 场景
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()
    B._MAGIC_KEYS.clear()
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
    for attr, val in (("taa_render_samples", 32), ("use_gtao", True)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass
    w = bpy.data.worlds.new("W")
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background")
    if bg is None:
        bg = w.node_tree.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = (0.62, 0.70, 0.82, 1.0)
    bg.inputs[1].default_value = 0.60

    def sun(nm, energy, rot, ang=3.0, col=(1.0, 0.95, 0.85)):
        d = bpy.data.lights.new(nm, "SUN")
        d.energy = energy
        d.angle = math.radians(ang)
        d.color = col
        o = bpy.data.objects.new(nm, d)
        o.rotation_euler = tuple(math.radians(a) for a in rot)
        sc.collection.objects.link(o)

    sun("key", 3.3, (40, 0, -38))
    sun("fill", 0.15, (55, 0, 128), 20.0, (0.85, 0.90, 1.0))

    camd = bpy.data.cameras.new("cam")
    camd.type = "ORTHO"
    camd.clip_start = 1.0
    camd.clip_end = 60000.0
    cam = bpy.data.objects.new("cam", camd)
    sc.collection.objects.link(cam)
    sc.camera = cam
    camd.sensor_fit = "VERTICAL"

    def make_ground(x0, x1, y0, y1):
        me = bpy.data.meshes.new("g")
        me.from_pydata([(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], [],
                       [(0, 1, 2, 3)])
        me.materials.append(B.material("ground"))
        o = bpy.data.objects.new("ground", me)
        sc.collection.objects.link(o)
        return o

    def shoot(u0, u1, v0, v1, zoom, path, res_max=9000):
        """正交取景：屏幕 u/v 世界区间 → 自动定位相机与分辨率；返回投影参数。"""
        ww, hh = (u1 - u0), (v1 - v0)
        k = min(1.0, res_max / float(max(ww, hh) * zoom))
        rx = max(64, int(round(ww * zoom * k)))
        ry = max(64, int(round(hh * zoom * k)))
        camd.ortho_scale = hh            # sensor_fit=VERTICAL → 竖向着色
        px_per_unit = ry / hh
        right = (math.cos(math.radians(YAW)), math.sin(math.radians(YAW)), 0.0)
        up = (-math.sin(math.radians(YAW)) * SIN_T, math.cos(math.radians(YAW)) * SIN_T,
              COS_T)
        cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
        anchor = (right[0] * cu + up[0] * cv, right[1] * cu + up[1] * cv,
                  right[2] * cu + up[2] * cv)
        fwd = (right[1] * up[2] - right[2] * up[1], right[2] * up[0] - right[0] * up[2],
               right[0] * up[1] - right[1] * up[0])
        cam.location = (anchor[0] + fwd[0] * 20000.0, anchor[1] + fwd[1] * 20000.0,
                        anchor[2] + fwd[2] * 20000.0)
        cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))
        sc.render.resolution_x, sc.render.resolution_y = rx, ry
        sc.render.resolution_percentage = 100
        sc.render.filepath = path
        bpy.ops.render.render(write_still=True)
        bpy.context.view_layer.update()
        return {"k": px_per_unit, "cu": cu, "cv": cv, "res": (rx, ry),
                "u": (u0, u1), "v": (v0, v1)}

    ground = make_ground(-60000.0, 60000.0, -4000.0, 4000.0)

    def frame_single(objs, path, zoom, pad_l=280.0, pad_r=420.0, pad_b=76.0,
                     pad_t=330.0):
        """pad_t 要留出审计面板（右上角，13~15 行）的高度，否则面板会压住建筑顶。"""
        pts = []
        for o in objs:
            pts += B.shape_points(o, skip_ground=False)
        right, up = B.cam_axes(YAW, TILT)
        us = [p.dot(right) for p in pts]
        vs = [p.dot(up) for p in pts]
        u0, u1 = min(us) - pad_l, max(us) + pad_r
        v0, v1 = -pad_b, max(vs) + pad_t
        return shoot(u0, u1, v0, v1, zoom, path)

    # ---------------- 单栋大图
    # SCALE_SKIP_SINGLE=1 → 复用上一次渲染的裸图与 json 里的 singles 元数据，
    # 只重渲总图（改标注/改排框时用，省掉 45 张单栋渲染）。
    singles = {}
    skip_single = os.environ.get("SCALE_SKIP_SINGLE") == "1"
    if skip_single and os.path.exists(META_PATH):
        try:
            with open(META_PATH, "r", encoding="utf-8") as f:
                singles = json.load(f).get("singles") or {}
            print("  [skip] 复用 %d 张单栋裸图 + 元数据" % len(singles))
        except Exception as ex:
            print("  [skip] 复用失败（%s）→ 改为全渲" % ex)
            singles = {}
    if not singles:
        skip_single = False
    if not skip_single:
        for (name, wc) in pairs:
            ob, spec, bb = _place(B, bpy, name, wc, y_front=0.0)
            sx = bb["x"]
            sob = _stick(B, bpy, x=sx[1] + 26.0)
            path = os.path.join(RAW_DIR, "single_%s_w%d.png" % (name, wc))
            info = frame_single([ob, sob], path, ZOOM_SINGLE)
            m = dict(by.get((name, wc)) or {})
            m.update({"name": name, "wc": wc, "spec": m.get("spec") or spec_json(spec),
                      "single": None,
                      "img": list(info["res"]), "k": info["k"], "cu": info["cu"],
                      "cv": info["cv"], "u": list(info["u"]), "v": list(info["v"]),
                      "y_front": 0.0, "y_back": bb["y"][1], "z_max": bb["z"][1],
                      "x_span": sx[1] - sx[0], "x0": sx[0], "x1": sx[1],
                      "stick_x": sx[1] + 26.0})
            singles["%s_w%d" % (name, wc)] = m
            bpy.data.objects.remove(sob, do_unlink=True)
            bpy_remove(B, ob)
            print("  single %-11s w%-2d  %s  res=%s k=%.2f"
                  % (name, wc, os.path.basename(path), info["res"], info["k"]))

    # ---------------- 总图（同尺度分排）
    # 每排 SHEET_COLS 个；单元宽取全局最大实测宽（**排内每格等宽**，横向可比）；
    # 竖直范围**逐排取本排最高**（同 scale 不变 —— 倍率 zoom 相同，只是取景框紧一点，
    # 否则 13.6m 的法师塔会把整表撑高，矮房子只剩 1/3 屏高）。
    widths = []
    for (name, wc) in pairs:
        e = by.get((name, wc))
        widths.append(e["meas"]["x_span"] if e else 0.0)
    cell_w = max(widths) + 150.0
    rows = [pairs[i:i + SHEET_COLS] for i in range(0, len(pairs), SHEET_COLS)]
    sheet = {"rows": [], "zoom": ZOOM_SHEET, "cell_w": cell_w,
             "v_top": 0.0, "cols": SHEET_COLS, "img_w": 0, "img_h": 0}
    # SCALE_SKIP_RENDER=1 → 连总图渲染也复用（只改标注时用：整轮 ~40 秒）
    if os.environ.get("SCALE_SKIP_RENDER") == "1" and os.path.exists(META_PATH):
        with open(META_PATH, "r", encoding="utf-8") as f:
            old = json.load(f)
        if old.get("sheet", {}).get("rows"):
            print("  [skip] 复用总图 %d 排裸图（SCALE_SKIP_RENDER=1）"
                  % len(old["sheet"]["rows"]))
            return _finish(entries, table, singles, old["sheet"])
    for ri, row in enumerate(rows):
        objs = []
        metas = []
        v_top = max((by[(n, w)]["meas"]["z_max"] * COS_T
                     + by[(n, w)]["meas"]["y_span"] * SIN_T) for (n, w) in row
                    if (n, w) in by) + 74.0
        for ci, (name, wc) in enumerate(row):
            x0 = cell_w * ci + 60.0
            ob, spec, bb = _place(B, bpy, name, wc, cell_x0=x0, y_front=0.0)
            sx = bb["x"]
            sob = _stick(B, bpy, x=sx[1] + 26.0)
            objs += [ob, sob]
            metas.append({"name": name, "wc": wc, "spec": spec_json(spec),
                          "x0": sx[0], "x1": sx[1], "y_back": bb["y"][1],
                          "z_max": bb["z"][1], "x_span": sx[1] - sx[0],
                          "stick_x": sx[1] + 26.0,
                          "rows": (by.get((name, wc)) or {}).get("rows") or [],
                          "worst": (by.get((name, wc)) or {}).get("hard_worst", "OK")})
        u0, u1 = -44.0, cell_w * len(row) + 60.0
        path = os.path.join(RAW_DIR, "sheet_row%d.png" % ri)
        info = shoot(u0, u1, -50.0, v_top, ZOOM_SHEET, path)
        right, up = B.cam_axes(YAW, TILT)
        for m in metas:
            m["img"] = list(info["res"])
            m["k"] = info["k"]
            m["cu"] = info["cu"]
            m["cv"] = info["cv"]
            m["y_front"] = 0.0
        sheet["v_top"] = max(sheet["v_top"], v_top)
        sheet["rows"].append({"idx": ri, "img": list(info["res"]), "k": info["k"],
                              "cu": info["cu"], "cv": info["cv"],
                              "u": list(info["u"]), "v": list(info["v"]),
                              "v_top": v_top, "metas": metas})
        print("  sheet row%d  %s  res=%s k=%.2f v_top=%.0f"
              % (ri, path, info["res"], info["k"], v_top))
        for o in objs:
            B_remove_safe(bpy, o)
        bpy.context.view_layer.update()

    return _finish(entries, table, singles, sheet)


def _finish(entries, table, singles, sheet):
    """落 json + 自动叠标注（渲染段与"只改标注"复用路径共用）。"""
    out = {"px_per_m": PX_PER_M, "m_per_cell": M_PER_CELL,
           "tilt": TILT, "yaw": YAW, "zoom_single": ZOOM_SINGLE,
           "focus": FOCUS, "sheet": sheet,
           "singles": singles, "audit": [
               {"name": e["name"], "wc": e["wc"], "rows": e["rows"],
                "worst": e["worst"], "hard_worst": e["hard_worst"]}
               for e in entries],
           "norms": {"door": N_DOOR, "storey": N_STOREY, "eave1": N_EAVE1,
                     "eave2": N_EAVE2, "eave3": N_EAVE3,
                     "rise_rel": N_RISE_REL, "rise_abs": N_RISE_ABS,
                     "eave_ratio": N_EAVE_RATIO, "pitch": N_PITCH_DEG,
                     "tower_floor": N_TOWER_FLOOR, "top_ratio": N_TOP_RATIO}}
    # spec 里可能有 tuple/非 json 值 → 用 default 兜底
    with open(META_PATH, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, default=str, indent=1)
    print("\nMETA -> %s" % META_PATH)
    print(table)

    # ---------------- 自动叠标注
    if os.environ.get("SCALE_ANNOT", "1") != "0":
        py = _find_python()
        if py:
            print("\n[annot] %s %s" % (py, os.path.abspath(__file__)))
            rc = subprocess.call([py, os.path.abspath(__file__)], cwd=HERE)
            print("[annot] rc=%d" % rc)
        else:
            print("\n[annot] 找不到带 PIL 的系统 python；请手动跑："
                  "  python %s    （或 SCALE_ANNOT=0 跳过）"
                  % os.path.abspath(__file__))
    print("\nSCALE_OK")


def B_remove_safe(bpy, ob):
    me = getattr(ob, "data", None)
    bpy.data.objects.remove(ob, do_unlink=True)
    if me is not None:
        try:
            bpy.data.meshes.remove(me)
        except Exception:
            pass


def _find_python():
    import shutil
    for cand in ("python", "python3", "py"):
        p = shutil.which(cand)
        if p:
            try:
                r = subprocess.run([p, "-c", "import PIL"], capture_output=True)
                if r.returncode == 0:
                    return p
            except Exception:
                pass
    return None


# ================================================================ §3 标注段（PIL）

def _screen(m, pt):
    """world point → image px（正交投影线性映射）。"""
    r, u = m["right"], m["up"]
    pu = pt[0] * r[0] + pt[1] * r[1] + pt[2] * r[2]
    pv = pt[0] * u[0] + pt[1] * u[1] + pt[2] * u[2]
    W, H = m["img"]
    return (W / 2.0 + (pu - m["cu"]) * m["k"], H / 2.0 - (pv - m["cv"]) * m["k"])


def _vx(m, z, y=None, x=0.0):
    """前立面平面（或指定 y）上高 z 的屏幕 y。"""
    y = m["y_front"] if y is None else y
    return _screen(m, (x, y, z))[1]


def _ux(m, x, y=None, z=0.0):
    y = m["y_front"] if y is None else y
    return _screen(m, (x, y, z))[0]


def load_font(size, bold=False):
    from PIL import ImageFont
    order = list(MAT_FONT_CANDIDATES)
    if bold:
        order = [r"C:\Windows\Fonts\msyhbd.ttc", r"C:\Windows\Fonts\Dengb.ttf"] + order
    for p in order:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def dash(d, p0, p1, fill, width=1, dl=7, gap=5):
    x0, y0 = p0
    x1, y1 = p1
    L = math.hypot(x1 - x0, y1 - y0)
    if L < 1e-6:
        return
    ux, uy = (x1 - x0) / L, (y1 - y0) / L
    t = 0.0
    while t < L:
        e = min(L, t + dl)
        d.line([x0 + ux * t, y0 + uy * t, x0 + ux * e, y0 + uy * e], fill=fill,
               width=width)
        t = e + gap


def arrow_head(d, tip, frm, fill, size=7):
    tx, ty = tip
    fx, fy = frm
    L = math.hypot(tx - fx, ty - fy) or 1.0
    ux, uy = (tx - fx) / L, (ty - fy) / L
    px, py = -uy, ux
    d.polygon([(tx, ty), (tx - ux * size + px * size * 0.5,
                          ty - uy * size + py * size * 0.5),
               (tx - ux * size - px * size * 0.5, ty - uy * size - py * size * 0.5)],
              fill=fill)


def tag(ov, d, xy, text, font, fill=(255, 255, 255, 255), pad=3,
        bg=(12, 14, 18, 205), anchor="lm", border=None):
    """带底衬的文字（anchor: l/m/r × t/m/b 的第一个字符横、第二个竖）。"""
    x, y = xy
    bb = d.textbbox((0, 0), text, font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    ax = anchor[0]
    ay = anchor[1]
    if ax == "l":
        bx = x
    elif ax == "r":
        bx = x - tw
    else:
        bx = x - tw / 2.0
    if ay == "t":
        by = y
    elif ay == "b":
        by = y - th
    else:
        by = y - th / 2.0
    d.rectangle([bx - pad, by - pad - 1, bx + tw + pad, by + th + pad], fill=bg,
                outline=border)
    d.text((bx - bb[0], by - bb[1]), text, font=font, fill=fill)
    return (bx, by, tw, th)


def vdim(ov, d, m, x_world, z0, z1, label, font, color=C_DIM, side=1,
         y=None, label_dx=0, t=0.5):
    """竖直尺寸线（双箭头）+ 标签；坐标是"前立面平面上的世界 Z"。

    t = 标签落在尺寸线上的比例（相邻标注逐条错开，避免文字互相压）。
    """
    x = _ux(m, x_world, y)
    y0 = _vx(m, z0, y)
    y1 = _vx(m, z1, y)
    d.line([x, y0, x, y1], fill=color, width=2)
    arrow_head(d, (x, y0), (x, y1), color)
    arrow_head(d, (x, y1), (x, y0), color)
    n = max(2, int(abs(y1 - y0) / 26))
    for i in range(1, n):
        yy = y0 + (y1 - y0) * i / n
        d.line([x - 3, yy, x + 3, yy], fill=color, width=1)
    tag(ov, d, (x + label_dx + (6 * side), y0 + (y1 - y0) * t), label, font,
        fill=(20, 20, 20, 255), bg=(255, 214, 96, 235), anchor="lm")
    return x


def hdim(ov, d, m, y_world, x0, x1, label, font, color=C_DIM, dz=0.0,
         label_above=True):
    """水平尺寸线（双箭头）+ 标签；坐标是世界 X（前立面平面上）。"""
    p0 = _screen(m, (x0, m["y_front"], 0.0))
    p1 = _screen(m, (x1, m["y_front"], 0.0))
    yy = p0[1] + dz if abs(p0[1] - p1[1]) < 1e-6 else (p0[1] + p1[1]) / 2.0 + dz
    d.line([p0[0], yy, p1[0], yy], fill=color, width=2)
    arrow_head(d, (p0[0], yy), (p1[0], yy), color)
    arrow_head(d, (p1[0], yy), (p0[0], yy), color)
    tag(ov, d, ((p0[0] + p1[0]) / 2.0, yy - 10 if label_above else yy + 10),
        label, font, fill=(20, 20, 20, 255), bg=(255, 214, 96, 235),
        anchor="mb" if label_above else "mt")


def ruler(ov, d, m, font, x_world, z_max_px, w_px, line_w, fill=C_RULER,
          every_m=0.5, label_every_m=1.0):
    """0.5m 刻度尺 + 每 1m 贯通虚线 + 米数标签（锚在前墙面平面）。

    **单位纪律**：内部一律世界 px（`_vx` 吃 px），只有标签文字换算成米 —— 早先把
    "0.5"（米）直接当 px 喂进去，刻度密成一条实心灰条、顶标还写成 "1040m"。
    """
    x = _ux(m, x_world)
    step = P(every_m)
    lab = P(label_every_m)
    zt = math.floor(M(z_max_px) / every_m) * every_m          # 顶层刻度（米）
    k = 0
    while k * every_m <= zt + 1e-6:
        zpx = k * step
        yy = _vx(m, zpx)
        if k % int(round(label_every_m / every_m)) == 0 and k > 0:
            dash(d, (x, yy), (x + w_px, yy), (150, 165, 185, 110), 1, 9, 7)
            tag(ov, d, (x - 6, yy), "%gm" % round(k * every_m, 1), font,
                fill=C_RULER, bg=(18, 24, 34, 190), anchor="rm")
        else:
            d.line([x, yy, x + 9, yy], fill=fill, width=2)
        k += 1
    d.line([x, _vx(m, 0.0), x, _vx(m, zt * PX_PER_M)], fill=fill, width=2)


def person_line(ov, d, m, font):
    """火柴人 1.70m 标记线（青）。"""
    y = _vx(m, 130.0)
    x0 = _ux(m, m["stick_x"] - 26.0)
    x1 = _ux(m, m["stick_x"] + 26.0)
    d.line([x0, y, x1, y], fill=(90, 235, 255, 235), width=2)
    tag(ov, d, (x1 + 6, y), "人 1.70m", font, fill=(10, 30, 36, 255),
        bg=(90, 235, 255, 235), anchor="lm")


def verdict_badge(ov, d, xy, worst, font):
    txt = {"OK": "比例 PASS", "↑超标": "比例 超标", "↓偏低": "比例 偏低"}[worst]
    tag(ov, d, xy, txt, font, fill=(255, 255, 255, 255), bg=_vcolor(worst) + (235,),
        anchor="lt")


def draw_panel(ov, d, m, entry, title, base_size, avail_px):
    """右上角审计面板：实测米制 + 规范偏差。**自动缩小字号**以适应建筑顶上余量。"""
    rows = entry.get("rows") or []
    lines = [("T", title)]
    lines.append(("S", "实测（米制，1px=1.31cm；高度按前墙面平面世界 Z）"))
    for (item, actual, target, ver, hard) in rows:
        lines.append(("R", item, actual, ver if hard else None))
    lines.append(("S", "规范：门 2.00m｜层高/单层檐高 2.60~2.72m（≤6 格 2.38）｜"
                       "两层檐高 5.20~5.42｜三层 7.80~8.12"))
    lines.append(("S", "规范：屋面 rise ≈ 檐高×0.45~0.62｜出檐 宽×18~23%｜"
                       "塔身每层 3.5~4.5m｜锥顶组 ≤ 塔身"))
    lines.append(("S", "图注：标尺锚在前墙面平面；20° 俯角下同一 z 平面越靠后"
                       "屏幕越高（进深投影 d·sin20°）"))
    fs_sz = max(10, int(base_size))
    while True:
        fs = load_font(fs_sz)
        fb = load_font(fs_sz + 5, bold=True)
        lh = max(12, int(fs_sz * 1.58))
        if lh * len(lines) + 26 <= avail_px or fs_sz <= 10:
            break
        fs_sz -= 1
    pad = 9
    W, _H = m["img"]
    wmax = 0
    for L in lines:
        s = L[1] if L[0] != "R" else "%s %s" % (L[1], L[2])
        bb = d.textbbox((0, 0), s, font=fs if L[0] != "T" else fb)
        wmax = max(wmax, bb[2] - bb[0])
    pw = min(W - 12, wmax + 2 * pad + 130)
    ph = lh * len(lines) + 2 * pad
    x0 = W - pw - 8
    y0 = 8
    d.rectangle([x0, y0, x0 + pw, y0 + ph], fill=(10, 12, 16, 222),
                outline=(90, 100, 115, 255))
    yy = y0 + pad
    for L in lines:
        if L[0] == "T":
            tag(ov, d, (x0 + pad, yy), L[1], fb, fill=(255, 236, 170, 255),
                bg=(0, 0, 0, 0), anchor="lt")
        elif L[0] == "S":
            tag(ov, d, (x0 + pad, yy), L[1], fs, fill=(168, 178, 192, 255),
                bg=(0, 0, 0, 0), anchor="lt")
        else:
            _i, item, actual, ver = L
            fill = _vcolor(ver) if ver in ("OK", "↑超标", "↓偏低") else (222, 228, 235, 255)
            tag(ov, d, (x0 + pad, yy), item, fs, fill=(150, 160, 175, 255),
                bg=(0, 0, 0, 0), anchor="lt")
            tag(ov, d, (x0 + pad + pw * 0.30, yy), actual, fs, fill=fill,
                bg=(0, 0, 0, 0), anchor="lt")
            if ver in ("OK", "↑超标", "↓偏低"):
                tag(ov, d, (x0 + pw - pad, yy), ver, fs, fill=fill,
                    bg=(0, 0, 0, 0), anchor="rt")
        yy += lh
    return y0 + ph


def annotate_single(img_path, out_path, m, entry):
    from PIL import Image, ImageDraw
    m.setdefault("right", [1.0, 0.0, 0.0])
    m.setdefault("up", [0.0, SIN_T, COS_T])
    base = Image.open(img_path).convert("RGBA")
    W, H = base.size
    fs = load_font(max(13, min(22, int(H / 52))))
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    spec = m.get("spec") or {}
    z_max = float(m.get("z_max") or 0.0)
    W0 = float(spec.get("grid_w") or 0.0)
    over = float(spec.get("overhang") or 0.0)
    eave = float(spec.get("eave_h") or 0.0)
    rise = float(spec.get("rise") or 0.0)
    st = [float(s) for s in (spec.get("storey_h") or [])]
    door = spec.get("door")
    plinth = float(spec.get("plinth_h") or 0.0)
    x0, x1 = float(m.get("x0") or -W0 / 2), float(m.get("x1") or W0 / 2)

    # 刻度尺（x0-70）+ 1.70m 标记
    ruler(ov, d, m, fs, x0 - 70.0, z_max, 14, 2)
    person_line(ov, d, m, fs)
    # 进深（投影为竖直；含 20° 俯角的观感偏移量）—— 最左侧
    xd_w = x0 - 150.0
    xd = _ux(m, xd_w)
    d0 = _screen(m, (0.0, m["y_front"], 0.0))
    d1 = _screen(m, (0.0, m["y_back"], 0.0))
    d.line([xd, d0[1], xd, d1[1]], fill=(160, 200, 255), width=2)
    arrow_head(d, (xd, d0[1]), (xd, d1[1]), (160, 200, 255))
    arrow_head(d, (xd, d1[1]), (xd, d0[1]), (160, 200, 255))
    tag(ov, d, (xd - 6, (d0[1] + d1[1]) / 2.0),
        "纵占位 %.2f m／投影 +%.0fpx（含前场构件）"
        % (M(m["y_back"] - m["y_front"]), d0[1] - d1[1]),
        fs, fill=(10, 24, 40, 255), bg=(160, 200, 255, 225), anchor="rm")
    # 网格宽 / 实测宽
    hdim(ov, d, m, 0.0, -W0 / 2, W0 / 2,
         "网格宽 %.2f m（%d 格）" % (M(W0), int(spec.get("width_cells") or 0)),
         fs, dz=30)
    hdim(ov, d, m, 0.0, x0, x1,
         "实测宽 %.2f m（出檐 每侧 %.2f m）" % (M(x1 - x0), M(over)), fs, dz=66)
    # 门
    if door:
        dx = float(spec.get("door_x") or 0.0)
        db = float(spec.get("door_bottom") or DOOR_SILL)
        vdim(ov, d, m, dx + float(door[0]) / 2.0 + 22.0, db, db + float(door[1]),
             "门 %.2f m" % M(door[1]), fs)
    # 檐口 / 逐层 / rise / 总高（右外侧，逐条外移 + 标签沿高度错开）
    xr = x1 + 34.0
    tt = 0.42
    if eave > 0:
        vdim(ov, d, m, xr, 0.0, eave, "檐口 %.2f m" % M(eave), fs, t=tt)
        xr += 62.0
        tt = min(0.92, tt + 0.16)
    zz = plinth
    for i, s in enumerate(st):
        if len(st) > 1:
            vdim(ov, d, m, xr, zz, zz + s, "第%d层 %.2f m" % (i + 1, M(s)), fs, t=tt)
            xr += 62.0
            zz += s
            tt = min(0.92, tt + 0.16)
    if rise > 0.5:
        vdim(ov, d, m, xr, eave, eave + rise, "屋面 rise %.2f m" % M(rise), fs,
             t=min(0.9, tt))
        xr += 62.0
    vdim(ov, d, m, xr, 0.0, z_max, "总高 %.2f m" % M(z_max), fs,
         color=(255, 160, 235), t=0.55)
    title = "%s w%d ｜ 网格宽 %.2f m ｜ %s" % (m["name"], m["wc"], M(W0),
                                              (spec.get("material") or "")[:26])
    draw_panel(ov, d, m, entry, title, max(11, min(20, int(H / 58))),
               _vx(m, z_max) - 12.0)
    out = Image.alpha_composite(base, ov).convert("RGB")
    out.save(out_path)
    return out_path


def annotate_sheet(meta, out_path):
    from PIL import Image, ImageDraw
    rows = meta["sheet"]["rows"]
    imgs = []
    for r in rows:
        im = Image.open(os.path.join(RAW_DIR, "sheet_row%d.png" % r["idx"])).convert("RGBA")
        imgs.append((r, im))
    W = max(im.size[0] for (_r, im) in imgs)
    fs = load_font(15)
    fb = load_font(21, bold=True)
    head_h = 96
    row_h = [im.size[1] + 84 for (_r, im) in imgs]
    H = head_h + sum(row_h)
    sheet = Image.new("RGBA", (W, H), (16, 19, 24, 255))
    d0 = ImageDraw.Draw(sheet)
    title = ("建筑比例审计图 pbr_scale_sheet —— 全部 %d 个 def×宽度档，同尺度（1 格 = %dpx）"
             "｜纯正面 + 俯角 20°" % (sum(len(r["metas"]) for r in rows),
                                      int(32 * meta["zoom_single"] * 0 + 32 * meta["sheet"]["zoom"])))
    d0.text((14, 12), title, font=fb, fill=(255, 236, 170, 255))
    sub = ("米制换算 1px = 1.31cm；火柴人 130px = 1.70m；1 格 = 32px = 0.42m。"
           "标尺锚在**前墙面平面**：每 0.5m 一短刻度、每 1m 一贯通虚线 + 米数。"
           "20° 俯角下同一 z 平面越靠后屏幕越高 —— 故屋面/屋脊在屏幕上会比标尺的同高度更高"
           "（偏移 ≈ 进深×sin20°），这是取景的固有观感放大，不是建模错误。")
    d0.text((14, 42), sub, font=fs, fill=(170, 180, 195, 255))
    sub2 = ("判定色：绿 = 合规 / 红 = 超标 / 橙 = 偏低（只对硬口径着色；塔类/开敞棚另有专项口径）。"
            "各栋大写字母数字为米数标注，蓝字 = 进深投影。")
    d0.text((14, 66), sub2, font=fs, fill=(170, 180, 195, 255))

    yy = head_h
    for (r, im) in imgs:
        ov = Image.new("RGBA", (W, im.size[1] + 84), (0, 0, 0, 0))
        d = ImageDraw.Draw(ov)
        # 1m/0.5m 贯通虚线（用本排投影参数；**米 → 世界 px**）
        mm = {"img": [im.size[0], im.size[1]], "k": r["k"], "cu": r["cu"],
              "cv": r["cv"], "right": [1.0, 0.0, 0.0],
              "up": [0.0, SIN_T, COS_T], "y_front": 0.0}
        ztop_m = math.ceil(M(r.get("v_top") or meta["sheet"]["v_top"]) / 0.5) * 0.5
        k2 = 0
        while k2 * 0.5 <= ztop_m + 1e-6:
            mt = k2 * 0.5
            ypix = _vx(mm, P(mt))
            if 0 <= ypix < im.size[1]:
                major = abs(mt - round(mt)) < 1e-6 and mt > 0
                dash(d, (0, ypix), (im.size[0], ypix),
                     (255, 236, 170, 92) if major else (255, 236, 170, 40),
                     1, 10, 8)
                if major:
                    tag(ov, d, (8, ypix), "%gm" % round(mt), fs,
                        fill=(255, 236, 170, 240), bg=(16, 18, 24, 150), anchor="lm")
            k2 += 1
        # 每栋标签
        for met in r["metas"]:
            m = dict(met)
            m.update({"img": [im.size[0], im.size[1]], "k": r["k"], "cu": r["cu"],
                      "cv": r["cv"], "right": [1.0, 0.0, 0.0],
                      "up": [0.0, SIN_T, COS_T], "y_front": 0.0})
            spec = met["spec"]
            W0 = float(spec.get("grid_w") or 0)
            zmax = float(met["z_max"] or 0)
            ytop = _vx(m, zmax)
            xl = _ux(m, met["x0"])
            xr = _ux(m, met["x1"])
            worst = met.get("worst") or "OK"
            tag(ov, d, (xl, ytop - 46), "%s w%d" % (met["name"], met["wc"]), fs,
                fill=(255, 255, 255, 255), bg=(10, 12, 16, 200), anchor="lt",
                border=_vcolor(worst) + (255,))
            tag(ov, d, (xl, ytop - 26),
                "宽%.2fm 檐%.2fm 总%.2fm" % (M(W0), M(spec.get("eave_h") or 0),
                                            M(zmax)), fs,
                fill=(210, 220, 232, 255), bg=(10, 12, 16, 200), anchor="lt")
            # 檐口 / 总高 细标
            xe = _ux(m, met["x1"] + 12.0)
            d.line([xe, _vx(m, 0.0), xe, _vx(m, float(spec.get("eave_h") or 0))],
                   fill=(255, 214, 96, 190), width=1)
            d.line([xe + 7, _vx(m, 0.0), xe + 7, _vx(m, zmax)],
                   fill=(255, 160, 235, 190), width=1)
            # 火柴人 1.70m 线
            y17 = _vx(m, 130.0)
            d.line([_ux(m, met["stick_x"] - 20.0), y17,
                    _ux(m, met["stick_x"] + 20.0), y17],
                   fill=(90, 235, 255, 200), width=2)
        # 0.5m 刻度尺（每排最左）
        xr0 = 34
        d.line([xr0, _vx(mm, 0.0), xr0, _vx(mm, P(ztop_m))],
               fill=(150, 200, 255, 220), width=2)
        k2 = 0
        while k2 * 0.5 <= ztop_m + 1e-6:
            ypix = _vx(mm, P(k2 * 0.5))
            major = abs(k2 * 0.5 - round(k2 * 0.5)) < 1e-6
            d.line([xr0, ypix, xr0 + (16 if major else 9), ypix],
                   fill=(150, 200, 255, 230), width=2)
            k2 += 1
        rowimg = Image.new("RGBA", (W, im.size[1] + 84), (22, 26, 32, 255))
        rowimg.alpha_composite(im, (0, 42))
        rowimg.alpha_composite(ov, (0, 42))       # 标注与渲染图同坐标系
        sheet.alpha_composite(rowimg, (0, yy))
        d0 = ImageDraw.Draw(sheet)
        d0.text((14, yy + 8), "第 %d 排 / 共 %d 排（同尺度）" % (r["idx"] + 1, len(rows)),
                font=fs, fill=(140, 150, 165, 255))
        yy += im.size[1] + 84
    sheet.convert("RGB").save(out_path)
    return out_path


def annotate_phase():
    import os as _os
    if not _os.path.exists(META_PATH):
        print("!! 缺 %s —— 先跑 Blender 渲染段："
              "blender -b --factory-startup -P probe_scale.py" % META_PATH)
        return 1
    with open(META_PATH, "r", encoding="utf-8") as f:
        meta = json.load(f)
    audit = {"%s_w%d" % (a["name"], a["wc"]): a for a in meta["audit"]}
    outs = []
    for key, m in meta["singles"].items():
        m["right"] = [1.0, 0.0, 0.0]                 # yaw=0 → 屏幕基向（常量）
        m["up"] = [0.0, SIN_T, COS_T]
        name = m["name"]
        if name not in FOCUS and meta["focus"]:
            pass
        ap = os.path.join(OUT_DIR, "pbr_scale_%s.png" % name
                          if FOCUS.get(name) == m["wc"]
                          else "pbr_scale_%s_w%d.png" % (name, m["wc"]))
        raw = os.path.join(RAW_DIR, "single_%s_w%d.png" % (name, m["wc"]))
        if not os.path.exists(raw):
            continue
        annotate_single(raw, ap, m, audit.get(key, {}))
        outs.append(ap)
    sp = annotate_sheet(meta, os.path.join(OUT_DIR, "pbr_scale_sheet.png"))
    outs.append(sp)
    print("\n=== 比例审计图产物 ===")
    for p in outs:
        try:
            from PIL import Image
            im = Image.open(p)
            print("  %-70s %s" % (p, im.size))
        except Exception:
            print("  %s" % p)
    print("ANNOT_OK")
    return 0


# ================================================================ §4 入口

def main():
    try:
        import bpy  # noqa: F401
        in_blender = True
    except Exception:
        in_blender = False
    if in_blender:
        render_phase()
    else:
        sys.exit(annotate_phase())


if __name__ == "__main__":
    main()
