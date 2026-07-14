"""世界生成 CLI 工具（开发期，Python）。

用法：
  python tools/worldgen/generate.py candidates [--count 10] [--size 1024]
      批量生成大陆轮廓候选 PNG（供抽卡挑选）。

  python tools/worldgen/generate.py world [--seed N] [--size 4096]
      在指定种子的大陆上生成完整 L3 世界地图（高程/群系/河流），
      输出 locked_continent.png + world_map_l3.png。

  python tools/worldgen/generate.py world-from-png --mask <path> [--seed N] [--size 4096]
      从外部 PNG 读取大陆掩码（如回收站找回的锁定模板），
      放大到目标尺寸后叠加群系/河流，输出 world_map_l3.png。

输出目录：tools/worldgen/output/
"""
import argparse
import gc
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from PIL import Image

from landmask import generate_landmask, land_ratio
from noise_util import make_grid, _sample
from world_map import generate_world_map, render_png, biome_stats, BIOME_NAMES
from tectonic import generate_tectonic_heightmap, render_heightmap, heightmap_stats
from terrain_template import (
    generate_template_heightmap,
    render_heightmap as render_template_heightmap,
    heightmap_stats as template_heightmap_stats,
    TEMPLATES as TERRAIN_TEMPLATES,
)

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
BASE_SEED = 3715991227  # 锁定的大陆模板种子（candidate #2）


def cmd_candidates(args):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    count = args.count
    size = args.size
    print(f"生成 {count} 个大陆候选 ({size}x{size})...")
    for i in range(count):
        seed = _derive_seed(BASE_SEED, i)
        mask = generate_landmask(size, seed)
        path = os.path.join(OUTPUT_DIR, f"candidate_{i+1:02d}.png")
        _save_mask_png(mask, path)
        print(f"  #{i+1:2d}  seed={seed}  陆地 {land_ratio(mask)*100:.0f}%  -> {path}")
    print("完成。")


def cmd_tectonic_candidates(args):
    """生成 N 张板块构造地形候选图（大陆轮廓 + 板块地形 + 高度分级渲染）。

    每张图用不同种子，大陆形状和板块配置都不同。
    用子进程隔离每张图，避免沙箱杀进程。
    """
    import subprocess

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    count = args.count
    size = args.size
    print(f"生成 {count} 张板块构造地形候选 ({size}x{size})...")
    for i in range(count):
        seed = _derive_seed(BASE_SEED, i)
        out_path = os.path.join(OUTPUT_DIR, f"tectonic_{i+1:02d}.png")
        print(f"  [{i+1}/{count}] seed={seed}", flush=True)
        subprocess.run(
            [sys.executable, __file__, "_tectonic_one",
             "--size", str(size), "--seed", str(seed), "--out", out_path],
            check=True,
        )
    print("完成。")


def _cmd_tectonic_one(args):
    """[内部] 生成单张板块构造地形图。"""
    size = args.size
    seed = args.seed
    print(f"  生成大陆掩码 (seed={seed})...", flush=True)
    mask = generate_landmask(size, seed)
    print(f"  陆地 {land_ratio(mask)*100:.1f}%", flush=True)

    print(f"  板块构造地形...", flush=True)
    heightmap = generate_tectonic_heightmap(size, seed, mask)

    print(f"  渲染...", flush=True)
    render_heightmap(heightmap, mask, args.out)

    stats = heightmap_stats(heightmap, mask)
    print(f"  -> {args.out}", flush=True)
    print("  --- 地形占比 ---", flush=True)
    for k, v in stats.items():
        print(f"    {k:<4s} {v*100:.1f}%", flush=True)


def cmd_template_candidates(args):
    """生成 N 张 Azgaar 模板法地形候选图（大陆轮廓 + 模板地形 + 高度分级渲染）。

    每张图用不同模板或不同种子，供用户挑选。
    用子进程隔离每张图，避免沙箱杀进程。
    """
    import subprocess

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    count = args.count
    size = args.size
    template = args.template
    # 模板列表：如果用户指定了 --template，只用那个；否则轮换所有模板
    if template:
        templates = [template] * count
    else:
        all_templates = list(TERRAIN_TEMPLATES.keys())
        templates = [all_templates[i % len(all_templates)] for i in range(count)]

    print(f"生成 {count} 张模板法地形候选 ({size}x{size})...")
    for i in range(count):
        seed = _derive_seed(BASE_SEED, i)
        tpl = templates[i]
        out_path = os.path.join(OUTPUT_DIR, f"template_{i+1:02d}_{tpl}.png")
        print(f"  [{i+1}/{count}] seed={seed} template={tpl}", flush=True)
        subprocess.run(
            [sys.executable, __file__, "_template_one",
             "--size", str(size), "--seed", str(seed),
             "--template", tpl, "--out", out_path],
            check=True,
        )
    print("完成。")


def _cmd_template_one(args):
    """[内部] 生成单张 Azgaar 模板法地形图。"""
    size = args.size
    seed = args.seed
    tpl = args.template
    if getattr(args, "mask", None):
        print(f"  加载外部蒙版: {args.mask}...", flush=True)
        mask = _load_mask_png(args.mask)
        if mask.shape[0] != size or mask.shape[1] != size:
            print(f"  缩放蒙版 {mask.shape[1]}x{mask.shape[0]} -> {size}x{size}...", flush=True)
            img = Image.fromarray(mask * 255, "L").resize((size, size), Image.LANCZOS)
            mask = (np.array(img) > 127).astype(np.uint8)
            del img
            gc.collect()
    else:
        print(f"  生成大陆掩码 (seed={seed})...", flush=True)
        mask = generate_landmask(size, seed)
    print(f"  陆地 {land_ratio(mask)*100:.1f}%", flush=True)

    print(f"  模板法地形 (template={tpl})...", flush=True)
    heightmap = generate_template_heightmap(size, seed, mask, tpl)

    # 可选：保存原始高度场 .npy（供 L3 群系/河流管线复用）
    if getattr(args, "save_heightmap", None):
        np.save(args.save_heightmap, heightmap)
        print(f"  高度场 -> {args.save_heightmap}", flush=True)

    print(f"  渲染...", flush=True)
    render_template_heightmap(heightmap, mask, args.out)

    stats, land_stats = template_heightmap_stats(heightmap, mask)
    print(f"  -> {args.out}", flush=True)
    print("  --- 地形占比（全部）---", flush=True)
    for k, v in stats.items():
        print(f"    {k:<14s} {v*100:.1f}%", flush=True)
    print("  --- 地形占比（陆地上）---", flush=True)
    for k, v in land_stats.items():
        print(f"    {k:<14s} {v*100:.1f}%", flush=True)


def _cmd_template_from_png(args):
    """从外部 PNG 蒙版生成 Azgaar 模板法地形（用锁定的大陆形状）。

    用 subprocess 隔离，避免 PIL LANCZOS 的 C 层内存不归还。
    """
    import subprocess

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    mask_path = args.mask
    size = args.size
    seed = args.seed
    tpl = args.template
    out_path = args.out or os.path.join(OUTPUT_DIR, f"template_from_png_{tpl}.png")

    print(f"从外部蒙版生成 Azgaar 模板法地形 (template={tpl}, {size}x{size})...")
    cmd = [sys.executable, __file__, "_template_one",
           "--size", str(size), "--seed", str(seed),
           "--template", tpl, "--out", out_path,
           "--mask", mask_path]
    save_h = getattr(args, "save_heightmap", None)
    if save_h:
        cmd += ["--save-heightmap", save_h]
    subprocess.run(cmd, check=True)


def cmd_world(args):
    """生成完整 L3 世界地图（子进程隔离，避免沙箱因长时间无输出杀进程）。

    步骤 1：_landmask 子进程生成大陆掩码（保存 .npy + PNG）
    步骤 2：_world 子进程从 .npy 加载掩码，生成群系/河流，渲染 PNG
    """
    import subprocess

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    seed = args.seed
    size = args.size
    locked_path = os.path.join(OUTPUT_DIR, "locked_continent.png")

    print(f"生成 L3 世界地图 (seed={seed}, {size}x{size})...")
    print("[步骤 1/2] 生成大陆掩码（子进程隔离）...")
    subprocess.run(
        [sys.executable, __file__, "_landmask",
         "--size", str(size), "--seed", str(seed), "--out", locked_path],
        check=True,
    )

    print("[步骤 2/2] 生成群系/河流（子进程隔离）...")
    subprocess.run(
        [sys.executable, __file__, "_world",
         "--mask", locked_path, "--size", str(size), "--seed", str(seed)],
        check=True,
    )


def cmd_world_from_png(args):
    """从外部 PNG 读大陆掩码，放大到目标尺寸，叠加群系/河流。

    用 subprocess 隔离 resize 和 world_map 两步，避免 PIL LANCZOS 的 C 层
    临时内存不归还 OS 导致后续 numpy 操作 OOM。
    """
    import subprocess

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    mask_path_in = args.mask
    size = args.size
    seed = args.seed
    locked_path = os.path.join(OUTPUT_DIR, "locked_continent.png")

    # 步骤 1：resize mask（子进程，隔离 PIL 内存）
    mask = _load_mask_png(mask_path_in)
    print(f"原始尺寸: {mask.shape[1]}x{mask.shape[0]}, 陆地 {land_ratio(mask)*100:.1f}%")
    if mask.shape[0] != size or mask.shape[1] != size:
        print(f"放大到 {size}x{size}（子进程隔离）...")
        subprocess.run(
            [sys.executable, __file__, "_resize",
             "--mask", mask_path_in, "--size", str(size), "--seed", str(seed),
             "--out", locked_path],
            check=True,
        )
    else:
        # 尺寸一致，直接复制
        _save_mask_png(mask, locked_path)
    del mask
    gc.collect()

    # 步骤 2：从 resized mask 生成世界地图（新进程的内存完全干净）
    print(f"生成群系/河流 (seed={seed})...")
    subprocess.run(
        [sys.executable, __file__, "_world",
         "--mask", locked_path, "--size", str(size), "--seed", str(seed)],
        check=True,
    )


def _load_mask_png(path: str) -> np.ndarray:
    """从 PNG 读取大陆掩码，返回 uint8 (H,W)，1=陆 0=洋。"""
    img = Image.open(path).convert("L")
    arr = np.array(img, dtype=np.uint8)
    return (arr > 127).astype(np.uint8)


def _bilinear_sample_u8(arr: np.ndarray, SX: np.ndarray, SY: np.ndarray) -> np.ndarray:
    """在分数坐标处对 uint8 2D 数组做双线性采样，返回 float32（值域 0-255）。

    逐个从 uint8 数组取值并转 float32，避免全局 float32 数组。
    """
    h, w = arr.shape
    SX = np.clip(SX, np.float32(0.0), np.float32(w - 1.001)).astype(np.float32, copy=False)
    SY = np.clip(SY, np.float32(0.0), np.float32(h - 1.001)).astype(np.float32, copy=False)
    x0 = np.floor(SX).astype(np.int32)
    y0 = np.floor(SY).astype(np.int32)
    fx = (SX - x0).astype(np.float32, copy=False)
    fy = (SY - y0).astype(np.float32, copy=False)
    del SX, SY
    _3 = np.float32(3.0)
    _2 = np.float32(2.0)
    u = fx * fx * (_3 - _2 * fx)
    v = fy * fy * (_3 - _2 * fy)
    del fx, fy
    v00 = arr[y0, x0].astype(np.float32)
    v10 = arr[y0, x0 + 1].astype(np.float32)
    a = v00 + (v10 - v00) * u
    del v00, v10
    v01 = arr[y0 + 1, x0].astype(np.float32)
    v11 = arr[y0 + 1, x0 + 1].astype(np.float32)
    b = v01 + (v11 - v01) * u
    del v01, v11
    return a + (b - a) * v


def _resize_mask(mask: np.ndarray, size: int, seed: int = 0) -> np.ndarray:
    """放大掩码 + 多倍频域扭曲边缘。

    用 LANCZOS 放大到连续值，然后对采样坐标做多倍频域扭曲
    （fBm 偏移），再二值化。域扭曲产生有机的海岸线（海湾、半岛、
    碎岛），比加性噪声更自然——它扭曲边界几何而非简单移动阈值。

    连续场存为 uint8（16MB @ 4096）而非 float32（64MB），
    采样时按 slab 转 float32，峰值内存恒定。

    3 层噪声：
      低频(24格)：大海湾/半岛
      中频(80格)：海岸曲折
      高频(256格)：精细锯齿
    """
    img = Image.fromarray(mask * 255, "L")
    img = img.resize((size, size), Image.LANCZOS)
    cont = np.array(img)  # uint8, 16MB
    del img
    gc.collect()

    result = np.zeros((size, size), dtype=np.uint8)
    slab_h = 64
    # 域扭曲幅度：约图像宽度的 1%，产生明显但不破坏大陆形状的边缘扭曲
    warp_amp = np.float32(size * 0.01)
    _2 = np.float32(2.0)
    _1 = np.float32(1.0)
    _thresh = np.float32(127.5)
    _size = np.float32(size)

    # 预生成 3 层噪声网格（x/y 各一组，避免坐标偏移被裁剪）
    g1x = make_grid(24, 24, seed + 1001)
    g1y = make_grid(24, 24, seed + 1002)
    g2x = make_grid(80, 80, seed + 2002)
    g2y = make_grid(80, 80, seed + 2003)
    g3x = make_grid(256, 256, seed + 3003)
    g3y = make_grid(256, 256, seed + 3004)

    n_slabs = (size + slab_h - 1) // slab_h
    _24 = np.float32(24)
    _80 = np.float32(80)
    _256 = np.float32(256)
    _04 = np.float32(0.4)
    _015 = np.float32(0.15)
    for i, y0 in enumerate(range(0, size, slab_h)):
        y1 = min(y0 + slab_h, size)
        xs = np.arange(size, dtype=np.float32)
        ys = np.arange(y0, y1, dtype=np.float32)
        PX, PY = np.meshgrid(xs, ys)
        fx = PX / _size
        fy = PY / _size

        # 3 层域扭曲
        wx1 = (_sample(g1x, fx * _24, fy * _24) * _2 - _1) * warp_amp
        wy1 = (_sample(g1y, fx * _24, fy * _24) * _2 - _1) * warp_amp
        wx2 = (_sample(g2x, fx * _80, fy * _80) * _2 - _1) * warp_amp * _04
        wy2 = (_sample(g2y, fx * _80, fy * _80) * _2 - _1) * warp_amp * _04
        wx3 = (_sample(g3x, fx * _256, fy * _256) * _2 - _1) * warp_amp * _015
        wy3 = (_sample(g3y, fx * _256, fy * _256) * _2 - _1) * warp_amp * _015
        wx = wx1 + wx2 + wx3
        wy = wy1 + wy2 + wy3
        del wx1, wy1, wx2, wy2, wx3, wy3, fx, fy

        # 在扭曲坐标处采样连续场
        SX = np.clip(PX + wx, np.float32(0.0), np.float32(size - 1.001))
        SY = np.clip(PY + wy, np.float32(0.0), np.float32(size - 1.001))
        del PX, PY, wx, wy
        sampled = _bilinear_sample_u8(cont, SX, SY)
        del SX, SY

        result[y0:y1] = (sampled > _thresh).astype(np.uint8)
        del sampled
        gc.collect()
        if i % 2 == 0:
            print(f"  resize {i}/{n_slabs} (y={y0})", flush=True)

    del cont, g1x, g1y, g2x, g2y, g3x, g3y
    gc.collect()
    return result


def _derive_seed(base: int, index: int) -> int:
    """派生子种子（确定性）。"""
    h = (base * 1000003 + index * 9176 + 12345) & 0x7FFFFFFF
    return h


def _save_mask_png(mask: np.ndarray, path: str) -> None:
    img = Image.fromarray(mask * 255, "L")
    img.save(path)


def _cmd_resize(args):
    """[内部] 放大掩码 + 噪声扰动边缘，保存 .npy + PNG。"""
    mask = _load_mask_png(args.mask)
    mask = _resize_mask(mask, args.size, args.seed)
    np.save(args.out + ".npy", mask)       # 供 _cmd_world 用 numpy 直读
    _save_mask_png(mask, args.out)          # 供人查看
    print(f"  resize 完成: {args.out}, 陆地 {land_ratio(mask)*100:.1f}%")


def cmd_crop(args):
    """裁切高度场和 mask，去掉周围深蓝海洋。

    找 4 方向（上/下/左/右）的非深蓝极点（高度 >= deep_ocean 阈值上限），
    往外 padding 像素裁切。
    """
    # 加载高度场
    h = np.load(args.heightmap)
    print(f"  加载高度场: {h.shape}, 值域 {h.min():.1f}-{h.max():.1f}", flush=True)

    # 加载 mask（优先 .npy，否则 PNG）
    mask_npy = args.mask + ".npy"
    if os.path.exists(mask_npy):
        mask = np.load(mask_npy)
    else:
        mask = _load_mask_png(args.mask)
    print(f"  加载 mask: {mask.shape}, 陆地 {land_ratio(mask)*100:.1f}%", flush=True)

    size = h.shape[0]
    assert mask.shape == h.shape, f"形状不匹配: h={h.shape} mask={mask.shape}"

    # 找非深蓝边界（高度 >= deep_ocean 阈值上限 8.0）
    # deep_ocean: (-1e9, 8.0)，所以非深蓝 = h >= 8.0
    not_deep = h >= np.float32(8.0)
    rows = np.where(not_deep.any(axis=1))[0]
    cols = np.where(not_deep.any(axis=0))[0]
    top, bottom = int(rows[0]), int(rows[-1])
    left, right = int(cols[0]), int(cols[-1])
    print(f"  非深蓝边界: top={top} bottom={bottom} left={left} right={right}", flush=True)

    # 往外 padding
    pad = args.pad
    top = max(0, top - pad)
    left = max(0, left - pad)
    bottom = min(size, bottom + pad)
    right = min(size, right + pad)
    print(f"  裁切后: top={top} bottom={bottom} left={left} right={right} (pad={pad})", flush=True)

    # 裁切
    h_crop = h[top:bottom, left:right].copy()
    mask_crop = mask[top:bottom, left:right].copy()
    print(f"  裁切后尺寸: {h_crop.shape[1]}x{h_crop.shape[0]}, 陆地 {land_ratio(mask_crop)*100:.1f}%", flush=True)

    # 保存
    np.save(args.out_heightmap, h_crop)
    np.save(args.out_mask + ".npy", mask_crop)
    _save_mask_png(mask_crop, args.out_mask)
    print(f"  高度场 -> {args.out_heightmap}", flush=True)
    print(f"  mask -> {args.out_mask} (+ .npy)", flush=True)

    # 渲染预览
    if args.out_preview:
        render_template_heightmap(h_crop, mask_crop, args.out_preview)
        print(f"  预览 -> {args.out_preview}", flush=True)
        stats, land_stats = template_heightmap_stats(h_crop, mask_crop)
        print("  --- 地形占比（陆地上）---", flush=True)
        for k, v in land_stats.items():
            print(f"    {k:<14s} {v*100:.1f}%", flush=True)


def cmd_pad_upscale(args):
    """把高度场/mask/预览补成正方形后超分到目标尺寸。

    pad 策略：居中 pad 到 max(h,w) × max(h,w)，pad 值：
      - 高度场: 0（深海）
      - mask: 0（海洋）
      - 预览 PNG: 深蓝色 (35, 70, 130)
    超分方法：
      - 高度场 .npy: 双线性插值（连续值）
      - mask: 最近邻 + 阈值化（保持二值）
      - 预览 PNG: LANCZOS（视觉质量）
    """
    target = args.size

    # --- 高度场 ---
    h = np.load(args.heightmap)
    print(f"  高度场: {h.shape[1]}x{h.shape[0]} -> {target}x{target}", flush=True)
    h_pad = _pad_square_float(h, np.float32(0.0))
    img = Image.fromarray(h_pad.astype(np.float32), "F").resize((target, target), Image.BILINEAR)
    h_up = np.array(img, dtype=np.float32)
    del img, h_pad
    np.save(args.out_heightmap, h_up)
    print(f"  -> {args.out_heightmap}", flush=True)

    # --- mask ---
    mask_npy = args.mask + ".npy"
    if os.path.exists(mask_npy):
        mask = np.load(mask_npy)
    else:
        mask = _load_mask_png(args.mask)
    print(f"  mask: {mask.shape[1]}x{mask.shape[0]} -> {target}x{target}", flush=True)
    mask_pad = _pad_square_uint8(mask, 0)
    img = Image.fromarray(mask_pad * 255, "L").resize((target, target), Image.NEAREST)
    mask_up = (np.array(img) > 127).astype(np.uint8)
    del img, mask_pad
    np.save(args.out_mask + ".npy", mask_up)
    _save_mask_png(mask_up, args.out_mask)
    print(f"  -> {args.out_mask} (+ .npy), 陆地 {land_ratio(mask_up)*100:.1f}%", flush=True)

    # --- 预览 PNG ---
    if args.out_preview:
        preview = Image.open(args.preview).convert("RGB")
        print(f"  预览: {preview.size[0]}x{preview.size[1]} -> {target}x{target}", flush=True)
        # pad 预览到正方形
        w, hh = preview.size
        m = max(w, hh)
        padded = Image.new("RGB", (m, m), (35, 70, 130))
        padded.paste(preview, ((m - w) // 2, (m - hh) // 2))
        preview_up = padded.resize((target, target), Image.LANCZOS)
        preview_up.save(args.out_preview)
        print(f"  -> {args.out_preview}", flush=True)

    # 高度场占比统计
    stats, land_stats = template_heightmap_stats(h_up, mask_up)
    print("  --- 地形占比（陆地上）---", flush=True)
    for k, v in land_stats.items():
        print(f"    {k:<14s} {v*100:.1f}%", flush=True)


def _pad_square_float(arr: np.ndarray, fill: np.float32) -> np.ndarray:
    """居中 pad float32 2D 数组到正方形。"""
    h, w = arr.shape
    m = max(h, w)
    pad_top = (m - h) // 2
    pad_bottom = m - h - pad_top
    pad_left = (m - w) // 2
    pad_right = m - w - pad_left
    return np.pad(arr, ((pad_top, pad_bottom), (pad_left, pad_right)),
                  mode="constant", constant_values=fill)


def _pad_square_uint8(arr: np.ndarray, fill: int) -> np.ndarray:
    """居中 pad uint8 2D 数组到正方形。"""
    h, w = arr.shape
    m = max(h, w)
    pad_top = (m - h) // 2
    pad_bottom = m - h - pad_top
    pad_left = (m - w) // 2
    pad_right = m - w - pad_left
    return np.pad(arr, ((pad_top, pad_bottom), (pad_left, pad_right)),
                  mode="constant", constant_values=fill)


def _cmd_landmask(args):
    """[内部] 从种子直接生成大陆掩码，保存 .npy + PNG。"""
    print(f"  生成大陆掩码 (seed={args.seed}, {args.size}x{args.size})...", flush=True)
    mask = generate_landmask(args.size, args.seed)
    np.save(args.out + ".npy", mask)       # 供 _cmd_world 用 numpy 直读
    _save_mask_png(mask, args.out)          # 供人查看
    print(f"  landmask 完成: {args.out}, 陆地 {land_ratio(mask)*100:.1f}%")


def _cmd_world(args):
    """[内部] 从 mask .npy 生成世界地图（不经 PIL，内存最干净）。"""
    npy_path = args.mask + ".npy"
    if os.path.exists(npy_path):
        mask = np.load(npy_path)
    else:
        mask = _load_mask_png(args.mask)
    print(f"  mask: {mask.shape[1]}x{mask.shape[0]}, 陆地 {land_ratio(mask)*100:.1f}%")
    gc.collect()
    wm = generate_world_map(args.size, args.seed, mask)

    locked_path = os.path.join(OUTPUT_DIR, "locked_continent.png")
    _save_mask_png(wm.landmask, locked_path)

    world_path = os.path.join(OUTPUT_DIR, "world_map_l3.png")
    render_png(wm, world_path)
    print(f"  世界地图 -> {world_path}")

    print("--- 生物群落占比 ---")
    stats = biome_stats(wm)
    for b in range(len(BIOME_NAMES)):
        print(f"  {BIOME_NAMES[b]:<6s} {stats[b]*100:.1f}%")
    river_count = int(wm.is_river.sum())
    print(f"河流格子数: {river_count}")


def main():
    p = argparse.ArgumentParser(description="世界生成工具")
    sub = p.add_subparsers(dest="cmd", required=True)

    pc = sub.add_parser("candidates", help="批量生成大陆轮廓候选")
    pc.add_argument("--count", type=int, default=10)
    pc.add_argument("--size", type=int, default=1024)
    pc.set_defaults(func=cmd_candidates)

    ptc = sub.add_parser("tectonic-candidates", help="批量生成板块构造地形候选")
    ptc.add_argument("--count", type=int, default=10)
    ptc.add_argument("--size", type=int, default=1024)
    ptc.set_defaults(func=cmd_tectonic_candidates)

    pw = sub.add_parser("world", help="生成完整 L3 世界地图")
    pw.add_argument("--seed", type=int, default=BASE_SEED)
    pw.add_argument("--size", type=int, default=4096)
    pw.set_defaults(func=cmd_world)

    pwp = sub.add_parser("world-from-png", help="从外部 PNG 读大陆掩码，叠加群系/河流")
    pwp.add_argument("--mask", type=str, required=True, help="大陆掩码 PNG 路径")
    pwp.add_argument("--seed", type=int, default=BASE_SEED)
    pwp.add_argument("--size", type=int, default=4096)
    pwp.set_defaults(func=cmd_world_from_png)

    pc = sub.add_parser("crop", help="裁切高度场/mask，去掉周围深蓝海洋")
    pc.add_argument("--heightmap", type=str, required=True, help="输入高度场 .npy")
    pc.add_argument("--mask", type=str, required=True, help="输入 mask PNG（自动找 .npy）")
    pc.add_argument("--out-heightmap", type=str, required=True, help="输出裁切后高度场 .npy")
    pc.add_argument("--out-mask", type=str, required=True, help="输出裁切后 mask PNG（同时存 .npy）")
    pc.add_argument("--out-preview", type=str, default=None, help="输出裁切后预览 PNG")
    pc.add_argument("--pad", type=int, default=20, help="非深蓝极点外 padding 像素")
    pc.set_defaults(func=cmd_crop)

    pu = sub.add_parser("pad-upscale", help="补正方形 + 超分到目标尺寸")
    pu.add_argument("--heightmap", type=str, required=True, help="输入高度场 .npy")
    pu.add_argument("--mask", type=str, required=True, help="输入 mask PNG（自动找 .npy）")
    pu.add_argument("--preview", type=str, default=None, help="输入预览 PNG（可选）")
    pu.add_argument("--out-heightmap", type=str, required=True, help="输出超分高度场 .npy")
    pu.add_argument("--out-mask", type=str, required=True, help="输出超分 mask PNG（同时存 .npy）")
    pu.add_argument("--out-preview", type=str, default=None, help="输出超分预览 PNG")
    pu.add_argument("--size", type=int, default=8192, help="目标尺寸（默认 8192）")
    pu.set_defaults(func=cmd_pad_upscale)

    # 内部子命令（供 subprocess 调用，隔离内存）
    pr = sub.add_parser("_resize", help="[内部] 放大掩码并保存 PNG")
    pr.add_argument("--mask", type=str, required=True)
    pr.add_argument("--size", type=int, required=True)
    pr.add_argument("--seed", type=int, required=True)
    pr.add_argument("--out", type=str, required=True)
    pr.set_defaults(func=_cmd_resize)

    pl = sub.add_parser("_landmask", help="[内部] 从种子生成大陆掩码")
    pl.add_argument("--size", type=int, required=True)
    pl.add_argument("--seed", type=int, required=True)
    pl.add_argument("--out", type=str, required=True)
    pl.set_defaults(func=_cmd_landmask)

    pw2 = sub.add_parser("_world", help="[内部] 从 mask PNG 生成世界地图")
    pw2.add_argument("--mask", type=str, required=True)
    pw2.add_argument("--size", type=int, required=True)
    pw2.add_argument("--seed", type=int, required=True)
    pw2.set_defaults(func=_cmd_world)

    pt1 = sub.add_parser("_tectonic_one", help="[内部] 生成单张板块构造地形图")
    pt1.add_argument("--size", type=int, required=True)
    pt1.add_argument("--seed", type=int, required=True)
    pt1.add_argument("--out", type=str, required=True)
    pt1.set_defaults(func=_cmd_tectonic_one)

    # Azgaar 模板法地形候选
    ptc2 = sub.add_parser("template-candidates", help="批量生成 Azgaar 模板法地形候选")
    ptc2.add_argument("--count", type=int, default=10)
    ptc2.add_argument("--size", type=int, default=1024)
    ptc2.add_argument("--template", type=str, default=None,
                      help="指定模板（continent/volcano/archipelago/mountains/plains），不指定则轮换所有")
    ptc2.set_defaults(func=cmd_template_candidates)

    pt2 = sub.add_parser("_template_one", help="[内部] 生成单张 Azgaar 模板法地形图")
    pt2.add_argument("--size", type=int, required=True)
    pt2.add_argument("--seed", type=int, required=True)
    pt2.add_argument("--template", type=str, required=True)
    pt2.add_argument("--out", type=str, required=True)
    pt2.add_argument("--mask", type=str, default=None, help="外部蒙版 PNG（可选）")
    pt2.add_argument("--save-heightmap", type=str, default=None, help="保存原始高度场 .npy（供 L3 群系/河流管线复用）")
    pt2.set_defaults(func=_cmd_template_one)

    # 从外部蒙版 PNG 生成 Azgaar 模板法地形（用锁定的大陆形状）
    ptfp = sub.add_parser("template-from-png", help="从外部 PNG 蒙版生成 Azgaar 模板法地形")
    ptfp.add_argument("--mask", type=str, required=True, help="大陆蒙版 PNG 路径")
    ptfp.add_argument("--size", type=int, default=1024)
    ptfp.add_argument("--seed", type=int, default=BASE_SEED)
    ptfp.add_argument("--template", type=str, default="continent")
    ptfp.add_argument("--out", type=str, default=None)
    ptfp.add_argument("--save-heightmap", type=str, default=None, help="保存原始高度场 .npy")
    ptfp.set_defaults(func=_cmd_template_from_png)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
