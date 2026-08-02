"""候选生成命令 —— 从 generate.py 拆分。

职责：大陆候选 / 板块构造候选 / Azgaar 模板法候选的批量生成。
子进程仍通过 generate.py 入口调用（保持 CLI 契约不变）。
"""
import gc
import os
import subprocess
import sys

import numpy as np
from PIL import Image

from landmask import generate_landmask, land_ratio
from tectonic import generate_tectonic_heightmap, render_heightmap, heightmap_stats
from terrain_template import (
    generate_template_heightmap,
    render_heightmap as render_template_heightmap,
    heightmap_stats as template_heightmap_stats,
    TEMPLATES as TERRAIN_TEMPLATES,
)
from mask_utils import derive_seed, load_mask_png, save_mask_png

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
BASE_SEED = 3715991227  # 锁定的大陆模板种子（candidate #2）
# 子进程入口：保持 generate.py 为 CLI 唯一入口（子命令契约不变）
ENTRY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generate.py")


def cmd_candidates(args):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    count = args.count
    size = args.size
    print(f"生成 {count} 个大陆候选 ({size}x{size})...")
    for i in range(count):
        seed = derive_seed(BASE_SEED, i)
        mask = generate_landmask(size, seed)
        path = os.path.join(OUTPUT_DIR, f"candidate_{i+1:02d}.png")
        save_mask_png(mask, path)
        print(f"  #{i+1:2d}  seed={seed}  陆地 {land_ratio(mask)*100:.0f}%  -> {path}")
    print("完成。")


def cmd_tectonic_candidates(args):
    """生成 N 张板块构造地形候选图（大陆轮廓 + 板块地形 + 高度分级渲染）。

    每张图用不同种子，大陆形状和板块配置都不同。
    用子进程隔离每张图，避免沙箱杀进程。
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    count = args.count
    size = args.size
    print(f"生成 {count} 张板块构造地形候选 ({size}x{size})...")
    for i in range(count):
        seed = derive_seed(BASE_SEED, i)
        out_path = os.path.join(OUTPUT_DIR, f"tectonic_{i+1:02d}.png")
        print(f"  [{i+1}/{count}] seed={seed}", flush=True)
        subprocess.run(
            [sys.executable, ENTRY, "_tectonic_one",
             "--size", str(size), "--seed", str(seed), "--out", out_path],
            check=True,
        )
    print("完成。")


def cmd_tectonic_one(args):
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
        seed = derive_seed(BASE_SEED, i)
        tpl = templates[i]
        out_path = os.path.join(OUTPUT_DIR, f"template_{i+1:02d}_{tpl}.png")
        print(f"  [{i+1}/{count}] seed={seed} template={tpl}", flush=True)
        subprocess.run(
            [sys.executable, ENTRY, "_template_one",
             "--size", str(size), "--seed", str(seed),
             "--template", tpl, "--out", out_path],
            check=True,
        )
    print("完成。")


def cmd_template_one(args):
    """[内部] 生成单张 Azgaar 模板法地形图。"""
    size = args.size
    seed = args.seed
    tpl = args.template
    if getattr(args, "mask", None):
        print(f"  加载外部蒙版: {args.mask}...", flush=True)
        mask = load_mask_png(args.mask)
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


def cmd_template_from_png(args):
    """从外部 PNG 蒙版生成 Azgaar 模板法地形（用锁定的大陆形状）。

    用 subprocess 隔离，避免 PIL LANCZOS 的 C 层内存不归还。
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    mask_path = args.mask
    size = args.size
    seed = args.seed
    tpl = args.template
    out_path = args.out or os.path.join(OUTPUT_DIR, f"template_from_png_{tpl}.png")

    print(f"从外部蒙版生成 Azgaar 模板法地形 (template={tpl}, {size}x{size})...")
    cmd = [sys.executable, ENTRY, "_template_one",
           "--size", str(size), "--seed", str(seed),
           "--template", tpl, "--out", out_path,
           "--mask", mask_path]
    save_h = getattr(args, "save_heightmap", None)
    if save_h:
        cmd += ["--save-heightmap", save_h]
    subprocess.run(cmd, check=True)
