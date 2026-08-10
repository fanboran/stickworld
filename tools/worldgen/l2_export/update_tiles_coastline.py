"""按 8K 蒙版裁切当前 tiles（保留人工合并状态），重建 json 多边形元数据。

背景：export_l2_packs 更新后 mask_8192.png 海岸线为 8192 级精细；
当前 tiles_8192.npy 是人工调整后的定稿分块，不能重跑算法。
做法：tiles 按新 mask 裁切（海洋外清 0，海岸线 8K），内部划分不变；
用共享网格提取重建 tiles.json（polygons/holes/color/centroid）。

用法：
  python tools/worldgen/l2_export/update_tiles_coastline.py [region_XXX ...]
"""
import json
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L2_DIR = os.path.join(HERE, "output", "l2_packs")
OCEAN_COLOR = (30, 55, 95)


def unique_colors():
    colors = []
    for i in range(80):
        h = (i * 0.618033988749895) % 1.0
        s = 0.65 + 0.2 * ((i * 7) % 3) / 2.0
        l = 0.45 + 0.25 * ((i * 11) % 3) / 2.0
        c = (1 - abs(2 * l - 1)) * s
        x = c * (1 - abs((h * 6) % 2 - 1))
        m = l - c / 2
        if h < 1 / 6: r, g, b = c, x, 0
        elif h < 2 / 6: r, g, b = x, c, 0
        elif h < 3 / 6: r, g, b = 0, c, x
        elif h < 4 / 6: r, g, b = 0, x, c
        elif h < 5 / 6: r, g, b = x, 0, c
        else: r, g, b = c, 0, x
        colors.append((int((r + m) * 255), int((g + m) * 255), int((b + m) * 255)))
    return colors


def main():
    rids = sys.argv[1:] or sorted(d for d in os.listdir(L2_DIR) if d.startswith("region_"))
    colors = unique_colors()
    for rid in rids:
        rdir = os.path.join(L2_DIR, rid)
        info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
        old_b = info.get("bbox_8192_old", None)
        # 旧 bbox 从旧 info 备份？export_l2_packs 已覆盖 info.json —— 从旧 tiles 无法得知旧 bbox。
        # 方案：旧 tiles 存了 bbox 到 json 备份（tiles.json 无 bbox）。
        # 直接读旧 bbox：export_l2_packs 覆盖前 info.json 有 bbox_8192；
        # 这里用"当前 tiles 尺寸回溯"不可靠，改用旧 info.json 备份文件（若存在）。
        # 简化：本脚本假设调用前 export_l2_packs 尚未覆盖 —— 用 git 恢复？不。
        # 最稳：从旧 tiles_8192.npy 的 bbox 记录文件读取（update 前由调用方备份）。
        bbox_bak = os.path.join(rdir, "bbox_8192_old.json")
        if not os.path.exists(bbox_bak):
            print("  %s: 缺少旧 bbox 备份，跳过（先备份旧 info.json）" % rid)
            continue
        old_b = json.load(open(bbox_bak, encoding="utf-8"))
        ox0, oy0, ox1, oy1 = old_b["x0"], old_b["y0"], old_b["x1"], old_b["y1"]

        # 旧 tiles 贴回 8192 全图
        seg_old = np.load(os.path.join(rdir, "tiles_8192.npy"))
        full = np.zeros((8192, 8192), dtype=np.int32)
        full[oy0:oy1 + 1, ox0:ox1 + 1] = seg_old
        # 按新 8K 蒙版裁切海岸线（内部划分不变）
        mask_full = np.array(Image.open(os.path.join(rdir, "mask_8192_full.png"))) > 0
        full[~mask_full] = 0

        # 按新 bbox 裁切保存
        b = info["bbox_8192"]
        x0, y0, x1, y1 = b["x0"], b["y0"], b["x1"], b["y1"]
        seg = full[y0:y1 + 1, x0:x1 + 1]
        mask = mask_full[y0:y1 + 1, x0:x1 + 1]

        # 共享网格提取重建元数据
        import mesh_extract
        mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(seg.astype(np.int32)))
        total = int(mask.sum())
        tiles = []
        for lab, mv in mesh.items():
            m = seg == lab
            ys, xs = np.where(m)
            if ys.size == 0:
                continue
            tiles.append({
                "label": lab,
                "color": list(colors[(lab - 1) % len(colors)]),
                "area_px": int(m.sum()),
                "area_ratio": float(m.sum() / total),
                "centroid": [float(ys.mean()), float(xs.mean())],
                "polygon": mv["outer"][0] if mv["outer"] else [],
                "polygons": mv["outer"],
                "holes": mv["holes"],
            })
        tiles.sort(key=lambda t: -t["area_ratio"])
        tiles_data = {"region_id": rid, "label": info["label"],
                      "n_tiles": len(tiles), "tiles": tiles}
        with open(os.path.join(rdir, "tiles.json"), "w", encoding="utf-8") as f:
            json.dump(tiles_data, f, ensure_ascii=False, indent=1)
        np.save(os.path.join(rdir, "tiles_8192.npy"), seg)
        print("  %s: %d 地块，海岸线已按 8K 蒙版裁切（新 bbox %dx%d）" % (rid, len(tiles), x1 - x0 + 1, y1 - y0 + 1))
    print("完成。")


if __name__ == "__main__":
    main()
