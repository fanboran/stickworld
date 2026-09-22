"""水陆同源·贴陆后处理 —— 政治几何与水陆真相的单一对齐入口。

背景（docs/项目/世界地图水陆同源重建-方案.md L2 层）：标签场（城块/细化场）与
水陆真相（locked_continent_8192 × 湖光栅 × 河掩膜）是两条 lineage，直接提取轮廓
会出现「几何越海 / 陆地漏盖」两类缝。本模块在**轮廓提取之前**统一做两步：

  1. 贴陆：水面（海 ∪ 湖 ∪ 河）标签一律归 0 —— 水面不进地块，地块边界贴水线；
  2. 回填：纯陆地（陆地 ∧ ¬水面）内的 0 空洞按 EDT 最近标签回填 —— 消除
     城块生长留下的内缩毛边，保证「陆地减几何 = 0」。

湖/河水面保持 0 不回填：湖由湖泊多边形（同一湖光栅提取）覆盖、河由矢量折线
（同一河掩膜提取）覆盖，水面下的地块边界反而会穿出水面对观感有害。

调用方（L1 export_l1_view_context / P4 的 L2/L3 导出器）约定：
  - labels 与 land/water 同形状同窗口（调用方负责裁窗）；
  - 返回新数组（不就地改），统计 dict 供导出日志与守门断言消费。
"""
import numpy as np
from scipy.ndimage import distance_transform_edt


def snap_labels_to_land(labels, land, water):
    """标签场贴陆：水面归 0 + 纯陆地内 0 空洞按 EDT 最近标签回填。

    Args:
        labels: (H, W) int 标签场（0 = 无地块；可以是多命名空间合成场）
        land:   (H, W) bool 大陆掩膜（locked_continent；True = 陆地）
        water:  (H, W) bool 内陆水面（湖光栅 | 河掩膜；海由 ¬land 补齐）

    Returns:
        (out, stats)：out = 贴陆后的新 int32 场；
        stats = {"cleared_px": 越水清除, "filled_px": 陆地回填}
    """
    labels = np.asarray(labels)
    water_all = np.asarray(water, dtype=bool) | ~np.asarray(land, dtype=bool)
    out = labels.astype(np.int32, copy=True)
    cleared = int((out[water_all] != 0).sum())
    out[water_all] = 0

    holes = (~water_all) & (out == 0)
    filled = 0
    if holes.any() and (out != 0).any():
        # EDT 的 input 非 0 处求到最近 0 处的距离/索引 —— 取反即「洞像素 →
        # 最近有标签像素」，indices 直接给出取值坐标（refine_city_labels 同款）
        _, idx = distance_transform_edt(out == 0, return_indices=True)
        src = out[idx[0], idx[1]]
        take = holes & (src != 0)
        filled = int(take.sum())
        out[take] = src[take]
    return out, {"cleared_px": cleared, "filled_px": filled}


def load_water_masks(output_dir):
    """加载全图水陆三真相（生成期同一次 run 的产物）。

    Returns:
        (land, lake, river)：8192² bool。land = locked_continent；
        lake = 精细湖光栅（refined_lake_mask_8192.npy，bool npy）；
        river = fractal_river_mask_8192.png。缺文件抛 FileNotFoundError
        （缺输入报错退出，禁止静默回退别的代）。
    """
    import os
    from PIL import Image

    def _must(path):
        if not os.path.exists(path):
            raise FileNotFoundError(
                "水陆真相缺输入：%s 不存在（湖光栅由 refine 后的湖面真值产出，"
                "禁止回退旧代——见 水陆同源重建-方案.md L4）" % path)
        return path

    land = np.array(Image.open(_must(os.path.join(
        output_dir, "locked", "locked_continent_8192.png"))).convert("L")) > 127
    lake = np.load(_must(os.path.join(
        output_dir, "refined_lake_mask_8192.npy"))).astype(bool)
    river = np.array(Image.open(_must(os.path.join(
        output_dir, "fractal_river_mask_8192.png"))).convert("L")) > 127
    return land, lake, river
