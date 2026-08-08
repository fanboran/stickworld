"""导出 L2 地图包素材 —— 为 13 个地区生成地图系统所需的全套数据。

每地区（output/l2_packs/region_XXX/）：
  - mask_2048.png         地区蒙版（2048 分辨率，与 region_labels 一致）
  - mask_8192.png         地区蒙版（8192 分辨率，与 L3 底图对齐）
  - base_8192.png         L3 地形底图裁切（bbox 扩展，8192 高清）
  - heightmap_8192.npy    高程场裁切（float32，与 base 对齐）
  - heightmap_8192.png    高程可视化（便于人眼检查）
  - info.json             地区定位元数据（bbox/质心/多边形/邻接/类型/面积）

全局（output/l2_packs/）：
  - index_mask_2048.png   边界索引图（每地区唯一 RGB，战略图点击查询用）
  - color_map.json        颜色 -> 地区 label
  - regions_meta.json     全部地区元数据汇总
  - README.md             素材清单与格式说明

用法：
  python tools/worldgen/export_l2_packs.py
"""
import json
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REGIONS_DIR = os.path.join(HERE, "output", "regions")
LOCKED_DIR = os.path.join(HERE, "output", "locked")
OUT_DIR = os.path.join(HERE, "output", "l2_packs")

# 底图与高程的 8192 源
BASE_8192 = os.path.join(LOCKED_DIR, "..", "preview_fractal.png")
HEIGHT_8192 = os.path.join(LOCKED_DIR, "locked_heightmap_8192.npy")

PAD_8192 = 80  # bbox 外扩像素（8192 坐标系）


def unique_colors(n):
    colors = []
    for i in range(n):
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


def heightmap_to_png(h, path, lo=None, hi=None):
    """高程 float32 -> 可视化 PNG（归一化到 0-255，水域=深蓝基调）。"""
    lo = h.min() if lo is None else lo
    hi = h.max() if hi is None else hi
    norm = np.clip((h - lo) / max(hi - lo, 1e-6), 0, 1)
    img = (norm * 255).astype(np.uint8)
    Image.fromarray(img).save(path)


def main():
    print("[1/5] 加载数据...")
    labels = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))  # 2048
    data = json.load(open(os.path.join(REGIONS_DIR, "region_data.json"), encoding="utf-8"))
    regions = data["regions"]
    n = data["n_regions"]
    print("  地区数: %d, labels %s" % (n, labels.shape))

    # 8192 资源（懒加载）
    print("[2/5] 加载 8192 底图 + 高程...")
    base_img = Image.open(BASE_8192).convert("RGB")
    assert base_img.size == (8192, 8192), base_img.size
    height = np.load(HEIGHT_8192, mmap_mode="r")
    print("  底图 %s, 高程 %s" % (base_img.size, height.shape))

    # 2048 labels -> 8192 蒙版（NEAREST 放大），再按 8K 大陆蒙版裁切陆地：
    # 海岸线/大陆轮廓取 8192 级精细边界（locked_continent_8192.png），
    # 地区划分语义保持 2048 定稿（人工调整结果不变）
    labels_8192 = np.array(
        Image.fromarray(labels.astype(np.int32), "I").resize((8192, 8192), Image.NEAREST)
    ).astype(np.int32)
    continent_8192 = np.array(Image.open(os.path.join(LOCKED_DIR, "locked_continent_8192.png")))
    land_8192 = continent_8192[:, :, 0] > 127  # 二值蒙版（0=海洋, 255=陆地）
    labels_8192[~land_8192] = 0  # 按 8K 蒙版裁切 -> 海岸线 8192 级精细

    os.makedirs(OUT_DIR, exist_ok=True)

    print("[3/5] 逐地区导出...")
    meta_list = []
    for r in regions:
        lab = r["label"]
        rid = "region_%03d" % lab
        d = os.path.join(OUT_DIR, rid)
        os.makedirs(d, exist_ok=True)

        m2048 = labels == lab
        m8192 = labels_8192 == lab

        # ---- 蒙版 ----
        Image.fromarray((m2048 * 255).astype(np.uint8)).save(os.path.join(d, "mask_2048.png"))
        Image.fromarray((m8192 * 255).astype(np.uint8)).save(os.path.join(d, "mask_8192_full.png"))

        # ---- 裁切范围（8192 坐标系，外扩） ----
        ys, xs = np.where(m8192)
        y0 = max(0, int(ys.min()) - PAD_8192)
        y1 = min(8191, int(ys.max()) + PAD_8192)
        x0 = max(0, int(xs.min()) - PAD_8192)
        x1 = min(8191, int(xs.max()) + PAD_8192)
        bbox_8192 = {"x0": x0, "y0": y0, "x1": x1, "y1": y1}

        # ---- 底图裁切 ----
        base_crop = base_img.crop((x0, y0, x1 + 1, y1 + 1))
        base_crop.save(os.path.join(d, "base_8192.png"))

        # ---- 蒙版裁切（与 base 对齐，同 bbox） ----
        mask_crop = Image.fromarray((m8192[y0:y1 + 1, x0:x1 + 1] * 255).astype(np.uint8))
        mask_crop.save(os.path.join(d, "mask_8192.png"))

        # ---- 高程裁切 ----
        h_crop = np.array(height[y0:y1 + 1, x0:x1 + 1], dtype=np.float32).copy()
        np.save(os.path.join(d, "heightmap_8192.npy"), h_crop)
        heightmap_to_png(h_crop, os.path.join(d, "heightmap_8192.png"))

        # ---- 信息 ----
        info = {
            "region_id": rid,
            "label": lab,
            "type": r["type"],
            "area_px_2048": r["area_px"],
            "area_ratio": r["area_ratio"],
            "adjacent": r["adjacent"],
            "polygon_2048": r["polygon"],
            "bbox_8192": bbox_8192,
            "files": {
                "mask_2048": rid + "/mask_2048.png",
                "mask_8192_full": rid + "/mask_8192_full.png",
                "mask_8192_crop": rid + "/mask_8192.png",
                "base_8192": rid + "/base_8192.png",
                "heightmap_8192_npy": rid + "/heightmap_8192.npy",
                "heightmap_8192_png": rid + "/heightmap_8192.png",
            },
        }
        with open(os.path.join(d, "info.json"), "w", encoding="utf-8") as f:
            json.dump(info, f, ensure_ascii=False, indent=1)
        meta_list.append(info)
        print("  %s %-10s %5.2f%% bbox8192=(%d,%d)-(%d,%d) 裁切 %dx%d" % (
            rid, r["type"], r["area_ratio"] * 100, x0, y0, x1, y1,
            x1 - x0 + 1, y1 - y0 + 1))

    print("[4/5] 全局索引图 + 元数据...")
    # 索引图（2048，每地区唯一色，战略图点击查询）
    colors = unique_colors(n)
    idx = np.zeros((2048, 2048, 3), dtype=np.uint8)
    idx[labels == 0] = (30, 55, 95)
    color_map = {"ocean": "#1e375f", "labels": {}}
    for i, r in enumerate(regions):
        color = colors[i]
        idx[labels == r["label"]] = color
        color_map["labels"][str(r["label"])] = "#%02x%02x%02x" % color
    Image.fromarray(idx).save(os.path.join(OUT_DIR, "index_mask_2048.png"))
    with open(os.path.join(OUT_DIR, "color_map.json"), "w", encoding="utf-8") as f:
        json.dump(color_map, f, indent=1)

    # 总元数据
    meta = {
        "tool": "export_l2_packs",
        "n_regions": n,
        "source": {
            "labels_2048": "output/regions/region_labels.npy",
            "base_8192": "output/locked/../preview_fractal.png",
            "heightmap_8192": "output/locked/locked_heightmap_8192.npy",
        },
        "pad_8192": PAD_8192,
        "regions": meta_list,
    }
    with open(os.path.join(OUT_DIR, "regions_meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)

    print("[5/5] README...")
    readme = """# L2 地图包素材（13 个地区）

由 `tools/worldgen/export_l2_packs.py` 生成。消费方：L2 地区图（战略图下一级）制作、L2 内部地块（L1）Voronoi 细分、地图系统素材。

## 全局文件

| 文件 | 说明 |
|------|------|
| `index_mask_2048.png` | 边界索引图：每地区唯一 RGB 编码（P 社 provinces.bmp 机制，NEAREST 采样），战略图点击查询用 |
| `color_map.json` | 索引图颜色 -> 地区 label 映射 |
| `regions_meta.json` | 全部地区元数据汇总（类型/面积/邻接/多边形/bbox/文件清单） |

## 每地区目录 `region_XXX/`

| 文件 | 分辨率 | 说明 |
|------|--------|------|
| `mask_2048.png` | 2048² | 地区蒙版（白=该地区），与 `region_labels.npy` 一致 |
| `mask_8192.png` | bbox 裁切 | 地区蒙版裁切（与 base/heightmap 像素对齐） |
| `mask_8192_full.png` | 8192² | 地区蒙版全图（全局坐标系） |
| `base_8192.png` | bbox 裁切 | L3 地形底图裁切（preview_fractal.png），含外扩 80px |
| `heightmap_8192.npy` | bbox 裁切 | 高程场 float32（locked_heightmap_8192.npy 裁切），与 base 像素对齐 |
| `heightmap_8192.png` | bbox 裁切 | 高程可视化（人眼检查） |
| `info.json` | - | 地区定位元数据（bbox_8192/质心可派生/邻接/类型/面积/文件清单） |

## 坐标约定

- 全局坐标系：2048（labels）与 8192（底图/高程）两套，`regions_meta.json` 中 `bbox_8192` 为 8192 坐标系
- 裁切文件（base/heightmap/mask 的 bbox 区域）像素一一对齐，可直接叠加
- 从 2048 -> 8192：坐标 × 4；8192 -> 2048：÷ 4

## 消费流程建议

1. 战略图 L2 缩放：加载 `index_mask_2048.png` + `regions_meta.json` 定位地区
2. 进入某地区：加载 `region_XXX/base_8192.png`（L2 底图）+ `mask_8192.png`（裁剪显示）
3. L2 内部细分 L1 地块：用 `heightmap_8192.npy` 做 Voronoi 细分（同 region_split 的 watershed 流程）
"""
    with open(os.path.join(OUT_DIR, "README.md"), "w", encoding="utf-8") as f:
        f.write(readme)

    print("完成。输出目录: %s" % OUT_DIR)
    print("  总大小: %.1f MB" % (sum(os.path.getsize(os.path.join(dp, fn))
          for dp, _, fns in os.walk(OUT_DIR) for fn in fns) / 1e6))


if __name__ == "__main__":
    main()
