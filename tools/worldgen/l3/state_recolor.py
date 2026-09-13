"""政权配色重排（观感返工第三批 C23：80 国色板重设计，只改颜色不动领土）。

与 state_expand_lite.py 共用 `palette.py` 的候选色生成与贪心分配（含城块共享边
邻接提取）——两端结果逐位一致，因此：
  - 只调色不重跑领土：跑本工具（秒级，只改 color 字段 + 刷 bin）
  - 全量重跑政权：state_expand_lite.py 内部走同一函数

产物（就地 patch，保留其余字段）：
  - config/strategic_map/l3_city.json          states[sid].color（政治图运行时 LUT 真相源）
  - config/strategic_map/political_data.json   states[sid].color + meta.color_source
  - config/strategic_map/l2_packs/*/l2_world.json  states[sid].color（L2 政权表同源）
  - config/strategic_map/l1_world.json         states[].color（出生 8 城邦，L1 政治图/图例）
  - output/<preview>.png                       2048 预览（ID mask 新 LUT 上色，验收用）

改完必须刷 bin + import（同仓库约定）：
  godot --headless --path stick-world --script res://tools/l_world_bake.gd
  godot --headless --path stick-world --import

用法：
  python state_recolor.py [--dry-run] [--no-preview]
"""

import argparse
import glob
import json
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import palette  # noqa: E402  （同目录模块，脚本方式运行时 sys.path 首项即 HERE）

OUTPUT_DIR = os.path.join(os.path.dirname(HERE), "output")
GAME_CFG = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(HERE, "state_params.json")

# ID mask 保留码与运行时 PoliticalLut 同源
OCEAN_RGB = (30, 55, 95)
CODE_FREE, CODE_LAKE, CODE_NEIGHBOR = 253, 254, 255
FREE_RGB = (110, 110, 110)
LAKE_RGB = (72, 116, 158)
NEIGHBOR_RGB = (115, 115, 115)


def sid_of_label(label):
    return "settlement_city_%03d" % int(label)


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def dump_json(path, data):
    # 与生成端同格式（indent=1 / 不转义中文）——纯 color 字段 diff
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="只算不写")
    ap.add_argument("--no-preview", action="store_true", help="不输出预览大图")
    args = ap.parse_args()

    params = load_json(PARAMS_PATH)
    spec = params["colors"]
    min_de = float(spec.get("min_delta_e", 0.105))

    city_path = os.path.join(GAME_CFG, "l3_city.json")
    pdata_path = os.path.join(GAME_CFG, "political_data.json")
    city_json = load_json(city_path)
    pdata = load_json(pdata_path)
    states = city_json["states"]

    label_to_sid = {int(k.split("_")[-1]): v
                    for k, v in pdata["city_owners"].items()}
    sizes = {sid: int(states[sid].get("n_cities", 0)) for sid in states}
    candidates = palette.build_candidates(spec)
    print("候选色 %d（%d 色相 × %d 明度档），政权 %d" % (
        len(candidates), int(spec["hue_count"]), len(spec["tiers"]), len(states)))

    assigned, conflicts = palette.assign_from_tiles(
        candidates, city_json["tiles"], label_to_sid, sizes, min_de)
    colors = {sid: tuple(assigned[sid]["rgb"]) for sid in assigned}

    # 指标：相邻对最小色差（功能底线 = 相邻国可区分）
    nbrs = palette.label_adjacency(city_json["tiles"], label_to_sid)
    des = []
    for sid, ns in nbrs.items():
        for nb in ns:
            if sid < nb and sid in assigned and nb in assigned:
                des.append(palette.delta_e(assigned[sid]["lab"], assigned[nb]["lab"]))
    if des:
        print("相邻国 ΔE：min=%.3f p05=%.3f median=%.3f（阈值 %.3f）= 冲突 %d 对" % (
            min(des), float(np.percentile(des, 5)), float(np.median(des)),
            min_de, len(conflicts)))
    used_cand = {(assigned[s]["hue"], assigned[s]["tier"]) for s in assigned}
    print("用色 %d / 候选 %d（复用 %d）" % (
        len(used_cand), len(candidates), len(assigned) - len(used_cand)))
    if conflicts:
        print("  [warn] 未达阈值的相邻对（前 10）：%s" % conflicts[:10])

    # 采样打印（大国在前）
    for sid in sorted(states, key=lambda s: (-sizes.get(s, 0), s))[:6]:
        c = assigned[sid]
        print("  %-22s 城%3d  hue%-3d L%.2f → RGB%s" % (
            sid, sizes[sid], c["hue"], c["L"], colors[sid]))

    if args.dry_run:
        print("--dry-run：不写文件")
        return

    # ---- 回写：l3_city.json / political_data.json ----
    for sid, rgb in colors.items():
        states[sid]["color"] = list(rgb)
        if sid in pdata["states"]:
            pdata["states"][sid]["color"] = list(rgb)
    pdata["meta"]["color_source"] = (
        "OKLCH 感知均匀色轮派生（观感返工第三批 C23：%d 色相 × %d 明度档等彩度候选，"
        "贪心图着色保证相邻国 OKLab ΔE ≥ %.3f，工具 state_recolor.py / palette.py）"
        % (int(spec["hue_count"]), len(spec["tiers"]), min_de))
    pdata["meta"]["color_palette_version"] = "v3-oklch-%dx%d" % (
        int(spec["hue_count"]), len(spec["tiers"]))
    dump_json(city_path, city_json)
    dump_json(pdata_path, pdata)

    # ---- 回写：L2 全量 pack ----
    n_pack = 0
    for pack_dir in sorted(glob.glob(os.path.join(GAME_CFG, "l2_packs", "*"))):
        p = os.path.join(pack_dir, "l2_world.json")
        if not os.path.isfile(p):
            continue
        d = load_json(p)
        st = d.get("states")
        if not isinstance(st, dict):
            continue
        touched = False
        for sid in st:
            if sid in colors:
                st[sid]["color"] = list(colors[sid])
                touched = True
        if touched:
            dump_json(p, d)
            n_pack += 1
    print("已回写 L2 pack %d 份" % n_pack)

    # ---- 回写：出生 L1（8 城邦，按 state_id 对齐）----
    l1_path = os.path.join(GAME_CFG, "l1_world.json")
    l1 = load_json(l1_path)
    n_l1 = 0
    for st in l1.get("states", []):
        sid = st.get("state_id", "")
        if sid in colors:
            st["color"] = list(colors[sid])
            n_l1 += 1
    dump_json(l1_path, l1)
    print("已回写出生 L1 城邦色 %d 条" % n_l1)

    # ---- 预览大图（ID mask × 新 LUT，2048）----
    if not args.no_preview:
        mask_path = os.path.join(GAME_CFG, "l3_political_id_8192.png")
        mask = Image.open(mask_path).convert("L")
        lut = np.zeros((256, 3), dtype=np.uint8)
        lut[0] = OCEAN_RGB
        lut[CODE_FREE] = FREE_RGB
        lut[CODE_LAKE] = LAKE_RGB
        lut[CODE_NEIGHBOR] = NEIGHBOR_RGB
        for sid, rgb in colors.items():
            idx = int(states[sid].get("lut_index", 0))
            if 0 < idx < 256:
                lut[idx] = rgb
        arr = np.asarray(mask)
        rgb = lut[arr]
        out = Image.fromarray(rgb).resize((2048, 2048), Image.NEAREST)
        prev = os.path.join(OUTPUT_DIR, "palette_v3_preview_2048.png")
        out.save(prev)
        print("预览 → %s" % prev)


if __name__ == "__main__":
    main()
