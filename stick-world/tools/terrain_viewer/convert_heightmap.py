"""将高度图、蒙版转换为 Godot 直接可读的 PNG（线性，不归一化）。

用法:
  python tools/terrain_viewer/convert_heightmap.py [--size 8192]

高度图存储：原始值 -0.1~1.0 线性映射到 16-bit 0~65535
着色器内恢复：h_raw = sample * 1.1 - 0.1
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image


def load_mask(path: str, target_size: int) -> np.ndarray:
	img = Image.open(path).convert("L")
	arr = np.array(img)
	binary = np.where(arr > 128, 255, 0).astype(np.uint8)
	if arr.shape[0] != target_size:
		img = Image.fromarray(binary)
		img = img.resize((target_size, target_size), Image.NEAREST)
		return np.array(img, dtype=np.uint8)
	return binary


def main():
	parser = argparse.ArgumentParser(description="转换高度图+蒙版为 Godot 可读 PNG（线性）")
	parser.add_argument("--size", type=int, default=8192, help="目标分辨率")
	args = parser.parse_args()

	script_dir = os.path.dirname(os.path.abspath(__file__))
	repo_root = os.path.normpath(os.path.join(script_dir, "..", "..", ".."))
	wg = os.path.join(repo_root, "tools", "worldgen", "output")
	out = os.path.join(script_dir, "output")
	os.makedirs(out, exist_ok=True)
	size = args.size

	# ── 贴图们（原样不归一化）────────────────────────────────
	maps = {
		"landmask": os.path.join(wg, "locked", "locked_continent_8192.png"),
		"rivers":   os.path.join(wg, "fractal_river_mask_8192.png"),
		"lakes":    os.path.join(wg, "fractal_lake_mask_8192.png"),
	}
	for name, path in maps.items():
		if not os.path.exists(path):
			print(f"跳过 {name}（未找到 {path}）")
			continue
		arr = load_mask(path, size)
		Image.fromarray(arr).save(os.path.join(out, f"{name}_{size}.png"))
		print(f"{name} -> {name}_{size}.png")

	# ── 高度图：线性映射到 16-bit ──────────────────────────
	hm_path = os.path.join(wg, "fractal_heightmap_8192.npy")
	if not os.path.exists(hm_path):
		print(f"错误: 找不到高度图 {hm_path}")
		sys.exit(1)

	print("加载高度图...")
	h = np.load(hm_path)
	if h.shape[0] != size:
		img = Image.fromarray(h.astype(np.float32), mode="F")
		img = img.resize((size, size), Image.LANCZOS)
		h = np.array(img, dtype=np.float32)

	# 线性映射：原始 -0.1 -> 0, 1.0 -> 65535
	h_clamped = np.clip(h, -0.1, 1.0)
	h_16bit = ((h_clamped + 0.1) / 1.1 * 65535).astype(np.uint16)
	Image.fromarray(h_16bit).save(os.path.join(out, f"heightmap_{size}.png"))
	print(f"高度图 -> heightmap_{size}.png  (线性, 原始范围 [{h.min():.3f}, {h.max():.3f}])")
	print("完成。")


if __name__ == "__main__":
	main()