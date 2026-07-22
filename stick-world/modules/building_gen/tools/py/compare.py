"""
材质多维度对比脚本。

SSIM（结构相似度）+ 水平分区统计 + 颜色直方图相关性 + 边缘密度。

用法：
    python compare.py                              # 默认对比 preview_thatch vs thatch_ref
    python compare.py --gen a.png --ref b.png      # 自定义文件
    python compare.py --regions 5                  # 水平分区数（默认3）
    python compare.py --json                       # JSON格式输出
    python compare.py --pair a.png b.png --ref r.png  # A/B对比：两份生成图 vs 同参考
"""
import os
import sys
import argparse
import json

import cv2
import numpy as np

# === 路径默认值 ===
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")
DEFAULT_GEN = os.path.join(REF_DIR, "preview_thatch.png")
DEFAULT_REF = os.path.join(REF_DIR, "thatch_ref.png")


def load_rgba(path: str):
    """以 RGBA 方式读取图片；若无 alpha 通道则补全 255。"""
    img = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if img is None:
        raise FileNotFoundError(f"无法读取: {path}")
    if len(img.shape) == 2:
        img = cv2.cvtColor(img, cv2.COLOR_GRAY2BGRA)
    elif img.shape[2] == 3:
        img = cv2.cvtColor(img, cv2.COLOR_BGR2BGRA)
    return img


def mask_from_alpha(img_bgra: np.ndarray) -> np.ndarray:
    """返回 alpha>0 的布尔掩码；无 alpha 时全 True。"""
    if img_bgra.shape[2] >= 4:
        return img_bgra[:, :, 3] > 0
    return np.ones(img_bgra.shape[:2], dtype=bool)


def bgr_mean_masked(img_bgra: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """仅计算 mask 内像素的 BGR 均值。"""
    bgr = img_bgra[:, :, :3]
    if mask.any():
        return bgr[mask].mean(axis=0)
    return bgr.mean(axis=(0, 1))


def load_and_align(gen_path: str, ref_path: str):
    """加载生成图和参考图，统一尺寸。返回 (gen_bgra, ref_bgra) uint8。"""
    ref = load_rgba(ref_path)
    gen = load_rgba(gen_path)
    if gen.shape[:2] != ref.shape[:2]:
        gen = cv2.resize(gen, (ref.shape[1], ref.shape[0]))
    return gen, ref


# ─── SSIM ────────────────────────────────────────────────────────────

def compute_ssim(img1: np.ndarray, img2: np.ndarray, mask1: np.ndarray = None, mask2: np.ndarray = None) -> float:
    """
    手动实现 SSIM（结构相似度），仅在两张图掩码重叠区域计算。
    SSIM(x,y) = [l(x,y)]·[c(x,y)]·[s(x,y)]
    C1=(0.01L)², C2=(0.03L)², L=255，11×11 高斯窗口。
    返回 (-1, 1]，越接近1越相似。
    """
    C1 = (0.01 * 255) ** 2
    C2 = (0.03 * 255) ** 2

    img1 = img1.astype(np.float64)
    img2 = img2.astype(np.float64)

    kernel = cv2.getGaussianKernel(11, 1.5)
    window = kernel @ kernel.T

    mu1 = cv2.filter2D(img1, -1, window, borderType=cv2.BORDER_REFLECT)
    mu2 = cv2.filter2D(img2, -1, window, borderType=cv2.BORDER_REFLECT)

    mu1_sq = mu1 ** 2
    mu2_sq = mu2 ** 2
    mu1_mu2 = mu1 * mu2

    sigma1_sq = cv2.filter2D(img1 ** 2, -1, window, borderType=cv2.BORDER_REFLECT) - mu1_sq
    sigma2_sq = cv2.filter2D(img2 ** 2, -1, window, borderType=cv2.BORDER_REFLECT) - mu2_sq
    sigma12   = cv2.filter2D(img1 * img2, -1, window, borderType=cv2.BORDER_REFLECT) - mu1_mu2

    ssim_map = ((2 * mu1_mu2 + C1) * (2 * sigma12 + C2)) / \
               ((mu1_sq + mu2_sq + C1) * (sigma1_sq + sigma2_sq + C2))

    if mask1 is not None and mask2 is not None:
        overlap = mask1.astype(np.uint8) & mask2.astype(np.uint8)
        if overlap.sum() > 0:
            return float(ssim_map[overlap > 0].mean())
    return float(ssim_map.mean())


# ─── 简单指标 ────────────────────────────────────────────────────────

def compute_mse(img1: np.ndarray, img2: np.ndarray, mask1: np.ndarray = None, mask2: np.ndarray = None) -> float:
    """仅在两张图掩码重叠区域计算 MSE。"""
    diff = (img1.astype(np.float64) - img2.astype(np.float64)) ** 2
    if mask1 is not None and mask2 is not None:
        overlap = mask1.astype(np.uint8) & mask2.astype(np.uint8)
        if overlap.sum() > 0:
            return float(diff[overlap > 0].mean())
    return float(diff.mean())


def edge_density(img: np.ndarray, mask: np.ndarray = None) -> float:
    """计算边缘密度；若提供 mask 则只统计 mask 内像素。"""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 50, 150)
    if mask is not None:
        denom = float(mask.sum())
        if denom > 0:
            return float(edges[mask].sum() / (denom * 255))
    return float(edges.sum() / (gray.size * 255))


# ─── 垂直亮度剖面（结构化纹理专用）──────────────────────────────────

def vertical_luminance_profile(gen: np.ndarray, ref: np.ndarray,
                                gen_mask: np.ndarray = None, ref_mask: np.ndarray = None) -> dict:
    """
    逐行计算 alpha>0 像素的平均亮度，比较生成图和参考图的垂直光照分布。
    适用于"水平tileable、垂直结构化"的纹理（如茅草、植被）。
    """
    g_gray = cv2.cvtColor(gen, cv2.COLOR_BGR2GRAY).astype(np.float64)
    r_gray = cv2.cvtColor(ref, cv2.COLOR_BGR2GRAY).astype(np.float64)

    def masked_row_mean(gray: np.ndarray, mask: np.ndarray):
        rows = []
        for y in range(gray.shape[0]):
            row_mask = mask[y, :] if mask is not None else np.ones(gray.shape[1], dtype=bool)
            vals = gray[y, row_mask]
            rows.append(float(vals.mean()) if vals.size > 0 else 0.0)
        return np.array(rows)

    gen_rows = masked_row_mean(g_gray, gen_mask)
    ref_rows = masked_row_mean(r_gray, ref_mask)

    # 只取两行都有有效像素的行
    valid = (gen_rows > 0) & (ref_rows > 0)
    if valid.sum() < 2:
        return {"profile_mse": 0.0, "profile_corr": 0.0}

    gen_rows_v = gen_rows[valid]
    ref_rows_v = ref_rows[valid]

    profile_mse = float(((gen_rows_v - ref_rows_v) ** 2).mean())

    gen_centered = gen_rows_v - gen_rows_v.mean()
    ref_centered = ref_rows_v - ref_rows_v.mean()
    denom = np.sqrt((gen_centered ** 2).sum() * (ref_centered ** 2).sum())
    if denom > 1e-10:
        profile_corr = float((gen_centered * ref_centered).sum() / denom)
    else:
        profile_corr = 0.0

    return {
        "profile_mse": profile_mse,
        "profile_corr": profile_corr,
    }


# ─── 颜色直方图 ──────────────────────────────────────────────────────

def color_histogram_compare(gen: np.ndarray, ref: np.ndarray,
                             gen_mask: np.ndarray = None, ref_mask: np.ndarray = None) -> dict:
    """BGR 三通道直方图相关性（仅统计 alpha>0 区域）。"""
    scores = []
    for ch in range(3):
        g_ch = gen[:, :, ch]
        r_ch = ref[:, :, ch]
        hg = cv2.calcHist([g_ch], [0], gen_mask.astype(np.uint8) if gen_mask is not None else None, [64], [0, 256])
        hr = cv2.calcHist([r_ch], [0], ref_mask.astype(np.uint8) if ref_mask is not None else None, [64], [0, 256])
        cv2.normalize(hg, hg)
        cv2.normalize(hr, hr)
        scores.append(float(cv2.compareHist(hg, hr, cv2.HISTCMP_CORREL)))
    return {
        "b": scores[0],
        "g": scores[1],
        "r": scores[2],
        "avg": float(np.mean(scores)),
    }


# ─── 水平分区统计 ────────────────────────────────────────────────────

def regional_stats(gen: np.ndarray, gen_mask: np.ndarray, ref: np.ndarray, ref_mask: np.ndarray, num_regions: int = 3) -> list:
    """
    将图像水平等分为 num_regions 个区域，逐区域计算 MSE、SSIM、颜色均值（仅 alpha>0）。
    """
    h, w = gen.shape[:2]
    region_h = h // num_regions
    results = []

    for i in range(num_regions):
        y0 = i * region_h
        y1 = (i + 1) * region_h if i < num_regions - 1 else h

        g_region = gen[y0:y1, :, :]
        r_region = ref[y0:y1, :, :]
        g_mask_r = gen_mask[y0:y1, :]
        r_mask_r = ref_mask[y0:y1, :]

        g_gray = cv2.cvtColor(g_region, cv2.COLOR_BGR2GRAY)
        r_gray = cv2.cvtColor(r_region, cv2.COLOR_BGR2GRAY)

        mse  = compute_mse(g_region, r_region, g_mask_r, r_mask_r)
        ssim = compute_ssim(g_gray, r_gray, g_mask_r, r_mask_r)

        gen_mean = bgr_mean_masked(g_region, g_mask_r)
        ref_mean = bgr_mean_masked(r_region, r_mask_r)

        results.append({
            "region": i + 1,
            "y_range": [y0, y1],
            "mse": mse,
            "ssim": ssim,
            "gen_bgr_mean": gen_mean.tolist(),
            "ref_bgr_mean": ref_mean.tolist(),
        })

    return results


# ─── 核心对比函数 ────────────────────────────────────────────────────

def run_compare(gen_path: str, ref_path: str, num_regions: int = 3) -> dict:
    """执行完整对比，返回 dict。"""
    gen, ref = load_and_align(gen_path, ref_path)

    gen_mask = mask_from_alpha(gen)
    ref_mask = mask_from_alpha(ref)

    g_gray = cv2.cvtColor(gen, cv2.COLOR_BGR2GRAY)
    r_gray = cv2.cvtColor(ref, cv2.COLOR_BGR2GRAY)

    overlap = gen_mask.astype(np.uint8) & ref_mask.astype(np.uint8)

    return {
        "gen_path": gen_path,
        "ref_path": ref_path,
        "ssim":    compute_ssim(g_gray, r_gray, gen_mask, ref_mask),
        "mse":     compute_mse(gen, ref, gen_mask, ref_mask),
        "edge_gen": edge_density(gen, gen_mask),
        "edge_ref": edge_density(ref, ref_mask),
        "bgr_gen": bgr_mean_masked(gen, gen_mask).tolist(),
        "bgr_ref": bgr_mean_masked(ref, ref_mask).tolist(),
        "histogram_corr": color_histogram_compare(gen, ref, gen_mask, ref_mask),
        "vertical_profile": vertical_luminance_profile(gen, ref, gen_mask, ref_mask),
        "regions": regional_stats(gen, gen_mask, ref, ref_mask, num_regions),
        "overlap_ratio": float(overlap.sum() / max(gen_mask.sum(), ref_mask.sum(), 1)),
    }


# ─── A/B 对比 ─────────────────────────────────────────────────────────

def run_pair_compare(gen_a_path: str, gen_b_path: str, ref_path: str, num_regions: int = 3) -> dict:
    """对比两份生成图，输出各自的指标和优劣判断。"""
    a = run_compare(gen_a_path, ref_path, num_regions)
    b = run_compare(gen_b_path, ref_path, num_regions)

    # 判断维度：MSE、垂直剖面相关系数、边缘密度偏差、直方图（SSIM 对结构化纹理不适用）
    a_win = 0
    b_win = 0

    if a["mse"] < b["mse"]:     a_win += 1
    else:                       b_win += 1

    if a["vertical_profile"]["profile_corr"] > b["vertical_profile"]["profile_corr"]:
        a_win += 1
    else:
        b_win += 1

    a_edge_dev = abs(a["edge_gen"] - a["edge_ref"])
    b_edge_dev = abs(b["edge_gen"] - b["edge_ref"])
    if a_edge_dev < b_edge_dev: a_win += 1
    else:                        b_win += 1

    if a["histogram_corr"]["avg"] > b["histogram_corr"]["avg"]:
        a_win += 1
    else:
        b_win += 1

    return {
        "A": a,
        "B": b,
        "A_wins": a_win,
        "B_wins": b_win,
    }


# ─── 输出 ─────────────────────────────────────────────────────────────

def print_results(results: dict, label: str = ""):
    prefix = f" [{label}]" if label else ""
    gen_name = os.path.basename(results["gen_path"])

    print(f"\n{'─'*50}")
    print(f"  {gen_name}{prefix} vs 参考图")
    print(f"{'─'*50}")

    print(f"  MSE: {results['mse']:.1f}   边缘密度: 参考={results['edge_ref']:.4f}  生成={results['edge_gen']:.4f}")
    print(f"  SSIM: {results['ssim']:.4f}  (注：结构化纹理适用性有限，参考垂直剖面)")

    rb = results["bgr_ref"]
    gb = results["bgr_gen"]
    print(f"  BGR 参考:  [{rb[0]:.1f}, {rb[1]:.1f}, {rb[2]:.1f}]")
    print(f"  BGR 生成:  [{gb[0]:.1f}, {gb[1]:.1f}, {gb[2]:.1f}]")
    print(f"  BGR 偏差:  [{rb[0]-gb[0]:+.1f}, {rb[1]-gb[1]:+.1f}, {rb[2]-gb[2]:+.1f}]")

    h = results["histogram_corr"]
    print(f"  直方图相关: B={h['b']:.3f} G={h['g']:.3f} R={h['r']:.3f}  avg={h['avg']:.3f}")

    vp = results["vertical_profile"]
    print(f"  垂直剖面:   MSE={vp['profile_mse']:.1f}  相关={vp['profile_corr']:.4f}")
    print(f"  重叠比例:   {results.get('overlap_ratio', 0.0):.3f}")

    regions = results["regions"]
    print(f"\n  水平 {len(regions)} 分区统计:")
    print(f"  {'#':<4s} {'Y范围':<10s} {'MSE':>8s} {'SSIM':>8s}  {'生成BGR均值':<24s}  {'参考BGR均值':<24s}")
    print("  " + "─" * 95)
    for r in regions:
        gs = f"B={r['gen_bgr_mean'][0]:.0f} G={r['gen_bgr_mean'][1]:.0f} R={r['gen_bgr_mean'][2]:.0f}"
        rs = f"B={r['ref_bgr_mean'][0]:.0f} G={r['ref_bgr_mean'][1]:.0f} R={r['ref_bgr_mean'][2]:.0f}"
        yr = f"{r['y_range'][0]}-{r['y_range'][1]}"
        print(f"  {r['region']:<4d} {yr:<10s} {r['mse']:>8.0f} {r['ssim']:>8.4f}  {gs:<24s}  {rs:<24s}")


def print_pair_results(pair: dict):
    """打印 A/B 对比结果。"""
    print_results(pair["A"], label="A")
    print_results(pair["B"], label="B")

    print(f"\n{'═'*50}")
    print(f"  综合评分: A 胜 {pair['A_wins']}/4 项  |  B 胜 {pair['B_wins']}/4 项")
    winner = "A" if pair["A_wins"] > pair["B_wins"] else ("B" if pair["B_wins"] > pair["A_wins"] else "平局")
    print(f"  胜出: {winner}")
    print(f"{'═'*50}")


# ─── 入口 ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="程序化材质多维度对比")
    parser.add_argument("--gen",  default=DEFAULT_GEN, help="生成图路径")
    parser.add_argument("--ref",  default=DEFAULT_REF, help="参考图路径")
    parser.add_argument("--regions", type=int, default=3, help="水平分区数")
    parser.add_argument("--json", action="store_true", help="JSON输出")
    parser.add_argument("--pair", nargs=2, metavar=("GEN_A", "GEN_B"),
                        help="A/B对比：两份生成图 vs 同一参考")
    args = parser.parse_args()

    try:
        if args.pair:
            pair = run_pair_compare(args.pair[0], args.pair[1], args.ref, args.regions)
            if args.json:
                print(json.dumps(pair, indent=2, ensure_ascii=False, default=str))
            else:
                print_pair_results(pair)
        else:
            results = run_compare(args.gen, args.ref, args.regions)
            if args.json:
                print(json.dumps(results, indent=2, ensure_ascii=False, default=str))
            else:
                print_results(results)
    except FileNotFoundError as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
