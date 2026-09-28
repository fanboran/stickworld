"""水陆同源·贴陆后处理 —— 政治几何与水陆真相的单一对齐入口。

背景（docs/项目/世界地图水陆同源重建-方案.md L2 层）：标签场（城块/细化场）与
水陆真相（locked_continent_8192 × 湖光栅 × 河掩膜）是两条 lineage，直接提取轮廓
会出现「几何越海 / 陆地漏盖」两类缝。本模块在**轮廓提取之前**统一做：

  1. 贴陆：海/湖标签归 0（面状水体，城块不进）；
     **河不清标签**（线状水在陆地上，地面归属穿河而过——河流视觉由地形贴图
     层负责，与道路同为后处理叠加语义，色块层不给河留洞）；
  2. 回填：纯陆地内的 0 空洞按 EDT 最近标签回填 + 边界众数自然化
     （EDT 等距边是平直直线，不滤波放大读作方块）。

调用方（L1 export_l1_view_context / P4 的 L2/L3 导出器）约定：
  - labels 与 land/water 同形状同窗口（调用方负责裁窗）；
  - 返回新数组（不就地改），统计 dict 供导出日志与守门断言消费。
"""
import numpy as np
from scipy.ndimage import distance_transform_edt


def snap_labels_to_land(labels, land, water, river=None, preserve=None):
    """标签场贴陆：海/湖归 0 + 纯陆地内 0 空洞按 EDT 最近标签回填（边界众数自然化）。

    preserve（v2 荒地语义，可选）：bool 场，True=设计荒地（无主陆地，保持 0）——
    回填跳过这些像素（城块划分 v3 主张盘封顶留出的无城陆地不是「洞」）。

    水面分两类口径（创始人 2026-09-22 定性）：
      - 海/湖 = 面状水体，城块不进（色块层露真水，湖岸即城块界线）；
      - 河 = **陆地上的线状水**，地面归属穿河而过（河不清标签）——河流视觉由
        地形贴图层负责（与道路同为后处理叠加语义），色块层不给河留洞：清了
        河带标签，城块多边形就在河带露海底色、河带把城块切成两截、描边沿
        河岸画一圈（把河框起来）——全部由此而来。

    Args:
        labels: (H, W) int 标签场（0 = 无地块；可以是多命名空间合成场）
        land:   (H, W) bool 大陆掩膜（locked_continent；True = 陆地）
        water:  (H, W) bool 湖面（贴陆对象；湖光栅，与贴图/湖多边形同代）
        river:  (H, W) bool 河掩膜（None = 不区分；仅供守门统计，不清标签）

    Returns:
        (out, stats)：out = 贴陆后的新 int32 场；
        stats = {"cleared_px": 越水清除, "filled_px": 陆地回填}
    """
    labels = np.asarray(labels)
    sea_or_lake = np.asarray(water, dtype=bool) | ~np.asarray(land, dtype=bool)
    out = labels.astype(np.int32, copy=True)
    cleared = int((out[sea_or_lake] != 0).sum())
    out[sea_or_lake] = 0

    holes = (~sea_or_lake) & (out == 0)
    if preserve is not None:
        holes = holes & ~np.asarray(preserve, dtype=bool)
    filled_mask = np.zeros_like(out, dtype=bool)
    if holes.any() and (out != 0).any():
        # EDT 的 input 非 0 处求到最近 0 处的距离/索引 —— 取反即「洞像素 →
        # 最近有标签像素」，indices 直接给出取值坐标（refine_city_labels 同款）
        _, idx = distance_transform_edt(out == 0, return_indices=True)
        src = out[idx[0], idx[1]]
        take = holes & (src != 0)
        out[take] = src[take]
        filled_mask = take
        filled = int(take.sum())
        # 回填边界自然化：EDT 最近标签的等距边是平直直线/直角，放大后读作
        # 「莫名其妙的方块」——对回填像素做 3×3 众数滤波两轮，边界跟随
        # 周围标签的自然轮廓（只动回填像素，城块间 watershed 原始直线不碰）
        for _ in range(2):
            ys, xs = np.where(filled_mask)
            for y, x in zip(ys.tolist(), xs.tolist()):
                win = out[max(0, y - 1):y + 2, max(0, x - 1):x + 2].ravel()
                win = win[win != 0]
                if win.size:
                    out[y, x] = np.bincount(win).argmax()
    else:
        filled = 0
    return out, {"cleared_px": cleared, "filled_px": filled}


def load_water_masks(output_dir):
    """加载全图水陆三真相（生成期同一次 run 的产物）。

    Returns:
        (land, lake, river)：8192² bool。land = locked_continent；
        lake = 精细湖光栅（refined_lake_mask_8192.npy，bool npy，**已净化**：
        连海组件剔除）；river = fractal_river_mask_8192.png。缺文件抛
        FileNotFoundError（缺输入报错退出，禁止静默回退别的代）。
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


def purge_sea_lakes(lake, land, min_offshore_frac=0.0):
    """湖光栅净化（创始人 2026-09-22 复检发现）：剔除「连海组件」。

    build_lake_raster 的连海判据 = 组件贴图幅边——漏掉「经窄水道与海相连、
    但组件本身不贴图幅边」的海湾小水斑（实测一例 167px 组件 160/169 在海里，
    被三处消费成 base 湖色方块/碎湖多边形/守门 IoU 拉低）。判据补强：
    组件膨胀 4px 的邻域环内海占比 ≥ min_offshore_frac → 判连海，剔除。
    2026-09-23 创始人定「湖不临海」：阈值 0.5 → 0.0（凡邻域触海即剔，
    半开海岸潟湖不再留作湖）。
    """
    from scipy import ndimage as ndi
    out = lake.copy()
    cl, n = ndi.label(out)
    if n == 0:
        return out, 0
    sea = ~land
    n_purged = 0
    for cid in range(1, n + 1):
        comp = cl == cid
        ring = ndi.binary_dilation(comp, iterations=4) & ~comp
        n_ring = int(ring.sum())
        if n_ring and int((ring & sea).sum()) / n_ring > min_offshore_frac:
            out[comp] = False
            n_purged += 1
    return out, n_purged
