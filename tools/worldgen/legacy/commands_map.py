"""世界地图生成命令 —— 从 generate.py 拆分。

职责：L3 世界地图生成（world / world-from-png）、crop / pad-upscale、
内部子命令（_resize / _landmask / _world）。
子进程仍通过 generate.py 入口调用（保持 CLI 契约不变）。
"""
import gc
import os
import subprocess
import sys

import numpy as np
from PIL import Image

from landmask import generate_landmask, land_ratio
from world_map import generate_world_map, render_png, biome_stats, BIOME_NAMES
from terrain_template import (
    render_heightmap as render_template_heightmap,
    heightmap_stats as template_heightmap_stats,
)
from mask_utils import (
    load_mask_png,
    save_mask_png,
    resize_mask,
    pad_square_float,
    pad_square_uint8,
)

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
BASE_SEED = 3715991227  # 锁定的大陆模板种子（candidate #2）
# 子进程入口：保持 generate.py 为 CLI 唯一入口（子命令契约不变）
ENTRY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generate.py")


def cmd_world(args):
    """生成完整 L3 世界地图（子进程隔离，避免沙箱因长时间无输出杀进程）。

    步骤 1：_landmask 子进程生成大陆掩码（保存 .npy + PNG）
    步骤 2：_world 子进程从 .npy 加载掩码，生成群系/河流，渲染 PNG
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    seed = args.seed
    size = args.size
    locked_path = os.path.join(OUTPUT_DIR, "locked_continent.png")

    print(f"生成 L3 世界地图 (seed={seed}, {size}x{size})...")
    print("[步骤 1/2] 生成大陆掩码（子进程隔离）...")
    subprocess.run(
        [sys.executable, ENTRY, "_landmask",
         "--size", str(size), "--seed", str(seed), "--out", locked_path],
        check=True,
    )

    print("[步骤 2/2] 生成群系/河流（子进程隔离）...")
    subprocess.run(
        [sys.executable, ENTRY, "_world",
         "--mask", locked_path, "--size", str(size), "--seed", str(seed)],
        check=True,
    )


def cmd_world_from_png(args):
    """从外部 PNG 读大陆掩码，放大到目标尺寸，叠加群系/河流。

    用 subprocess 隔离 resize 和 world_map 两步，避免 PIL LANCZOS 的 C 层
    临时内存不归还 OS 导致后续 numpy 操作 OOM。
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    mask_path_in = args.mask
    size = args.size
    seed = args.seed
    locked_path = os.path.join(OUTPUT_DIR, "locked_continent.png")

    # 步骤 1：resize mask（子进程，隔离 PIL 内存）
    mask = load_mask_png(mask_path_in)
    print(f"原始尺寸: {mask.shape[1]}x{mask.shape[0]}, 陆地 {land_ratio(mask)*100:.1f}%")
    if mask.shape[0] != size or mask.shape[1] != size:
        print(f"放大到 {size}x{size}（子进程隔离）...")
        subprocess.run(
            [sys.executable, ENTRY, "_resize",
             "--mask", mask_path_in, "--size", str(size), "--seed", str(seed),
             "--out", locked_path],
            check=True,
        )
    else:
        # 尺寸一致，直接复制（同时保存 .npy 供 _cmd_world 直读）
        save_mask_png(mask, locked_path)
        np.save(locked_path + ".npy", mask)
    del mask
    gc.collect()

    # 步骤 2：从 resized mask 生成世界地图（新进程的内存完全干净）
    print(f"生成群系/河流 (seed={seed})...")
    cmd = [sys.executable, ENTRY, "_world",
           "--mask", locked_path, "--size", str(size), "--seed", str(seed)]
    if getattr(args, "heightmap", None):
        cmd += ["--heightmap", args.heightmap]
    subprocess.run(cmd, check=True)


def cmd_resize(args):
    """[内部] 放大掩码 + 噪声扰动边缘，保存 .npy + PNG。"""
    mask = load_mask_png(args.mask)
    mask = resize_mask(mask, args.size, args.seed)
    np.save(args.out + ".npy", mask)       # 供 _cmd_world 用 numpy 直读
    save_mask_png(mask, args.out)          # 供人查看
    print(f"  resize 完成: {args.out}, 陆地 {land_ratio(mask)*100:.1f}%")


def cmd_landmask(args):
    """[内部] 从种子直接生成大陆掩码，保存 .npy + PNG。"""
    print(f"  生成大陆掩码 (seed={args.seed}, {args.size}x{args.size})...", flush=True)
    mask = generate_landmask(args.size, args.seed)
    np.save(args.out + ".npy", mask)       # 供 _cmd_world 用 numpy 直读
    save_mask_png(mask, args.out)          # 供人查看
    print(f"  landmask 完成: {args.out}, 陆地 {land_ratio(mask)*100:.1f}%")


def cmd_world_internal(args):
    """[内部] 从 mask .npy 生成世界地图（不经 PIL，内存最干净）。"""
    npy_path = args.mask + ".npy"
    if os.path.exists(npy_path):
        mask = np.load(npy_path)
    else:
        mask = load_mask_png(args.mask)
    print(f"  mask: {mask.shape[1]}x{mask.shape[0]}, 陆地 {land_ratio(mask)*100:.1f}%")
    gc.collect()

    # 可选：加载外部高度场
    heightmap = None
    if getattr(args, "heightmap", None):
        heightmap = np.load(args.heightmap)
        print(f"  heightmap: {heightmap.shape[1]}x{heightmap.shape[0]}, 值域 {heightmap.min():.1f}-{heightmap.max():.1f}")
        # 如果高度场尺寸和 mask 不一致，缩放到匹配 size
        if heightmap.shape[0] != args.size or heightmap.shape[1] != args.size:
            print(f"  缩放高度场 {heightmap.shape[1]}x{heightmap.shape[0]} -> {args.size}x{args.size}...")
            img = Image.fromarray(heightmap.astype(np.float32), "F")
            img = img.resize((args.size, args.size), Image.BILINEAR)
            heightmap = np.array(img, dtype=np.float32)
            del img
            gc.collect()
        gc.collect()

    wm = generate_world_map(args.size, args.seed, mask, heightmap=heightmap)

    locked_path = os.path.join(OUTPUT_DIR, "locked_continent.png")
    save_mask_png(wm.landmask, locked_path)

    world_path = os.path.join(OUTPUT_DIR, "world_map_l3.png")
    render_png(wm, world_path)
    print(f"  世界地图 -> {world_path}")

    print("--- 生物群落占比 ---")
    stats = biome_stats(wm)
    for b in range(len(BIOME_NAMES)):
        print(f"  {BIOME_NAMES[b]:<6s} {stats[b]*100:.1f}%")
    river_count = int((wm.river_flow > 0.01).sum())
    print(f"河流格子数: {river_count}")


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
        mask = load_mask_png(args.mask)
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
    save_mask_png(mask_crop, args.out_mask)
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
    h_pad = pad_square_float(h, np.float32(0.0))
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
        mask = load_mask_png(args.mask)
    print(f"  mask: {mask.shape[1]}x{mask.shape[0]} -> {target}x{target}", flush=True)
    mask_pad = pad_square_uint8(mask, 0)
    img = Image.fromarray(mask_pad * 255, "L").resize((target, target), Image.NEAREST)
    mask_up = (np.array(img) > 127).astype(np.uint8)
    del img, mask_pad
    np.save(args.out_mask + ".npy", mask_up)
    save_mask_png(mask_up, args.out_mask)
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
