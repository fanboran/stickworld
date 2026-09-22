"""老 L1 省份政治面侧表导出 —— 69 个老 L1 块的「主导政权 + 全局质心」小表。

用途（战略图 L1 视图的邻省上下文层）：
  - 邻省色块按**各自主导政权色**上色（暗一阶）而不是现在的平灰；
  - 左右箭头按**全局质心**判方位，切到相邻老 L1 省份（不看被 context 裁过的局部多边形，
    避免方位被裁切偏心带歪）。

数据来源（全部为已烘产物，不再依赖 worldgen 中间态 npy）：
  - l3_l1.json            69 块 polygons（[y,x] 序）/centroid([x,y])/area_px/group
  - l3_political_id_8192.png   8192 政权 ID mask（像素值 = lut_index，与 PoliticalLut 同源）
  - political_data.json   states[sid].lut_index / name / color

主导政权 = 块内（去保留码 0/253/254/255）出现像素最多的 lut_index；同票取面积无关，
按 code 升序稳定取最小（可复现）。

输出：config/strategic_map/l1_province_politics.json
  {"meta": {...}, "provinces": {"69": {"state_id","name","lut_index","color",
                                       "centroid":[x,y],"area_px","region"}}}

用法：
  python tools/worldgen/l1/export_province_politics.py
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))

L1_PATH = os.path.join(GAME_DIR, "l3_l1.json")
MASK_PATH = os.path.join(GAME_DIR, "l3_political_id_8192.png")
PDATA_PATH = os.path.join(GAME_DIR, "political_data.json")
OUT_PATH = os.path.join(GAME_DIR, "l1_province_politics.json")

# mask 保留码（与 political_lut.gd 同源）
CODE_FREE_CITY = 253
CODE_LAKE = 254
CODE_NEIGHBOR = 255
RESERVED = (0, CODE_FREE_CITY, CODE_LAKE, CODE_NEIGHBOR)


def dump_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))


def dominant_code(mask, rings, holes):
    """块内政权码众数。rings/holes: [[y,x],...] 点列（8192 级）。"""
    xs = [p[1] for r in rings for p in r]
    ys = [p[0] for r in rings for p in r]
    x0, x1 = int(min(xs)), int(max(xs)) + 1
    y0, y1 = int(min(ys)), int(max(ys)) + 1
    w, h = x1 - x0, y1 - y0
    if w <= 0 or h <= 0:
        return 0
    st = Image.new("1", (w, h), 0)
    d = ImageDraw.Draw(st)
    for r in rings:
        d.polygon([(p[1] - x0, p[0] - y0) for p in r], fill=1)
    for hl in holes:
        d.polygon([(p[1] - x0, p[0] - y0) for p in hl], fill=0)
    sel = np.asarray(st, dtype=bool)
    codes = mask[y0:y1, x0:x1][sel]
    if codes.size == 0:
        return 0
    vals, counts = np.unique(codes, return_counts=True)
    order = np.lexsort((vals, -counts))          # 先按票数降序，同票按 code 升序
    for v in vals[order]:
        if int(v) not in RESERVED:
            return int(v)
    return 0


def main():
    with open(L1_PATH, encoding="utf-8") as f:
        l1 = json.load(f)
    with open(PDATA_PATH, encoding="utf-8") as f:
        pdata = json.load(f)
    mask = np.asarray(Image.open(MASK_PATH).convert("L"))

    # lut_index -> 政权信息（保留码不在 states 内）
    by_index = {}
    for sid, info in pdata["states"].items():
        idx = int(info.get("lut_index", 0))
        if 0 < idx < 256:
            by_index[idx] = (sid, info)

    provinces = {}
    n_reserved = 0
    for t in l1["tiles"]:
        label = int(t["label"])
        code = dominant_code(mask, t.get("polygons", []), t.get("holes", []))
        if code in by_index:
            sid, info = by_index[code]
            name = str(info.get("name", ""))
            color = [int(v) for v in info.get("color", [110, 110, 110])]
        else:
            sid, name, color = "", "", [110, 110, 110]
            n_reserved += 1
        provinces[str(label)] = {
            "state_id": sid,
            "name": name,
            "lut_index": code,
            "color": color,
            "centroid": [round(float(v), 2) for v in t.get("centroid", [0.0, 0.0])],
            "area_px": int(t.get("area_px", 0)),
            "region": int(t.get("group", 0)),
        }

    dump_json(OUT_PATH, {
        "meta": {
            "source": "l3_l1.json 多边形 × l3_political_id_8192.png 众数采样"
                      "（tools/worldgen/l1/export_province_politics.py）",
            "size": int(l1.get("size", 8192)),
            "n_provinces": len(provinces),
            "note": "静态世界生成快照：用于战略图 L1 邻省上下文上色与方位判定，"
                    "不随运行时占领变化（领土归属真值在 WorldState.territories）",
        },
        "provinces": provinces,
    })

    print("已写 %s：%d 省（无主导政权 %d）" % (OUT_PATH, len(provinces), n_reserved))
    for lab in ("18", "67", "68", "69", "1", "5"):
        p = provinces.get(lab)
        if p:
            print("  #%s  %-12s %s  centroid=%s" % (
                lab, p["name"] or "(自由城邦)", p["color"], p["centroid"]))


if __name__ == "__main__":
    sys.exit(main())
