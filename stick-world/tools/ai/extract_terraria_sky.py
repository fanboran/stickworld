# -*- coding: utf-8 -*-
"""Terraria 天空贴图提取器 —— Content/Images 的 XNB（LZX 压缩）→ PNG。

产物（assets/sky/，已登记 docs/项目/素材替换清单.md，正式版前替换为无版权资产）：
  bg_mountain_far.png   ← Background_7.xnb   地表远山（视差 0.15，DrawSurfaceBG_BackMountainsStep1）
  bg_mountain_near.png  ← Background_8.xnb   地表近山（视差 0.2，Step2）
  bg_trees_far.png      ← Background_9.xnb   森林树线远（视差 0.4，DrawSurfaceBG_Forest 层1）
  bg_trees_mid.png      ← Background_10.xnb  森林树线中（视差 0.43，层2）
  bg_trees_near.png     ← Background_11.xnb  森林树线近（视差 0.49，层3）
  cloud_a..d.png        ← Cloud_0..3.xnb     云四变体（Cloud.cs type = rand.Next(4)）

森林组编号依据：WorldGen.SetForestBGSet 默认 style（mountainSet 7/8 + treeSet 9/10/11）。

管线：node xnb_lzx_extract.js（LZX 解压复用 external XnbCli 的纯 JS 解码器，
     依赖 XNBCLI_DIR 指向其 clone，默认 F:/tmp/XnbCli，github.com/LeonBlade/XnbCli）
     → 原始 RGBA（XNB Color 为预乘 alpha）→ 本脚本除回 alpha 转直通 PNG。

用法：python extract_terraria_sky.py [Terraria Images 目录] [输出目录 assets/sky]
"""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
XNBCLI_DIR = os.environ.get("XNBCLI_DIR", "F:/tmp/XnbCli")

## 提取清单：输出名 → XNB 文件名（不带扩展）
TEXTURES = {
    "bg_mountain_far": "Background_7",
    "bg_mountain_near": "Background_8",
    "bg_trees_far": "Background_9",
    "bg_trees_mid": "Background_10",
    "bg_trees_near": "Background_11",
    "cloud_a": "Cloud_0",
    "cloud_b": "Cloud_1",
    "cloud_c": "Cloud_2",
    "cloud_d": "Cloud_3",
}


def extract_raw(xnb_path: str) -> tuple:
    """调 node 提取器：返回 (meta dict, bytes)。"""
    with tempfile.TemporaryDirectory() as td:
        bin_path = os.path.join(td, "payload.bin")
        proc = subprocess.run(
            ["node", os.path.join(TOOLS_DIR, "xnb_lzx_extract.js"), xnb_path, bin_path],
            capture_output=True, text=True, cwd=TOOLS_DIR, shell=sys.platform == "win32",
        )
        # node 输出混有 LZX 日志行，JSON 元数据在最后一行
        lines = [ln for ln in proc.stdout.strip().splitlines() if ln.strip().startswith("{")]
        if not lines or proc.returncode != 0:
            raise RuntimeError("提取失败 %s:\n%s\n%s" % (xnb_path, proc.stdout, proc.stderr))
        meta = json.loads(lines[-1])
        with open(bin_path, "rb") as f:
            return meta, f.read()


def to_png(meta: dict, raw: bytes, out_path: str) -> None:
    """原始 RGBA（预乘 alpha）→ 直通 alpha PNG。

    反预乘除法在低 alpha 区放大 8bit 舍入噪声（×255/a，a<32 时 ×8+），
    渲染成"一排排横灰线"；alpha 下限 96 封顶放大倍率 ≤2.66——
    低 alpha 边缘略偏暗（与 Terraria 云灰蓝边观感一致），换取零噪声条带。
    顶部垫 2 行全透明：背景层 sprite 开 texture_repeat 且 region 高=贴图高，
    顶边线性采样会垂直回绕"吃"到底部不透明行，形成层顶 1px 灰缝。"""
    w, h = meta["width"], meta["height"]
    assert meta["format"] == 0, "仅支持 SurfaceFormat.Color（RGBA），实际 format=%s" % meta["format"]
    px = np.frombuffer(raw, dtype=np.uint8, count=w * h * 4).reshape(h, w, 4).astype(np.float32)
    a = px[..., 3:4]
    safe_a = np.maximum(a, 96.0)
    rgb = np.minimum(px[..., :3] * (255.0 / safe_a), 255.0)
    out = np.dstack([rgb, a])
    pad = np.zeros((2, w, 4), dtype=np.float32)
    out = np.vstack([pad, out])
    Image.fromarray(out.astype(np.uint8), "RGBA").save(out_path)


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else r"E:/Windows_steam/steamapps/common/Terraria/Content/Images"
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(TOOLS_DIR, "..", "..", "assets", "sky")
    out = os.path.abspath(out)
    os.makedirs(out, exist_ok=True)
    if not os.path.isdir(XNBCLI_DIR):
        raise SystemExit("XnbCli 未找到：%s（git clone https://github.com/LeonBlade/XnbCli 后设 XNBCLI_DIR）" % XNBCLI_DIR)
    for out_name, xnb_name in TEXTURES.items():
        meta, raw = extract_raw(os.path.join(src, xnb_name + ".xnb"))
        dst = os.path.join(out, out_name + ".png")
        to_png(meta, raw, dst)
        print("[terraria-sky] %s.xnb → %s (%dx%d)" % (xnb_name, dst, meta["width"], meta["height"]))
