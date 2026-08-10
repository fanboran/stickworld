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

文件拆分说明（2026-08-02）：
  本文件仅保留 CLI 子命令分发（main）；
  命令实现拆分为 commands_candidates.py（候选生成）与 commands_map.py（世界地图/crop/pad），
  mask 图像工具在 mask_utils.py。子进程入口固定为本文件，CLI 契约不变。
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import commands_candidates as cand
import commands_map as map_cmds

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
BASE_SEED = 3715991227  # 锁定的大陆模板种子（candidate #2）


def main():
    p = argparse.ArgumentParser(description="世界生成工具")
    sub = p.add_subparsers(dest="cmd", required=True)

    pc = sub.add_parser("candidates", help="批量生成大陆轮廓候选")
    pc.add_argument("--count", type=int, default=10)
    pc.add_argument("--size", type=int, default=1024)
    pc.set_defaults(func=cand.cmd_candidates)

    ptc = sub.add_parser("tectonic-candidates", help="批量生成板块构造地形候选")
    ptc.add_argument("--count", type=int, default=10)
    ptc.add_argument("--size", type=int, default=1024)
    ptc.set_defaults(func=cand.cmd_tectonic_candidates)

    pw = sub.add_parser("world", help="生成完整 L3 世界地图")
    pw.add_argument("--seed", type=int, default=BASE_SEED)
    pw.add_argument("--size", type=int, default=4096)
    pw.set_defaults(func=map_cmds.cmd_world)

    pwp = sub.add_parser("world-from-png", help="从外部 PNG 读大陆掩码，叠加群系/河流")
    pwp.add_argument("--mask", type=str, required=True, help="大陆掩码 PNG 路径")
    pwp.add_argument("--seed", type=int, default=BASE_SEED)
    pwp.add_argument("--size", type=int, default=4096)
    pwp.add_argument("--heightmap", type=str, default=None, help="外部高度场 .npy（Azgaar 模板法）")
    pwp.set_defaults(func=map_cmds.cmd_world_from_png)

    pc = sub.add_parser("crop", help="裁切高度场/mask，去掉周围深蓝海洋")
    pc.add_argument("--heightmap", type=str, required=True, help="输入高度场 .npy")
    pc.add_argument("--mask", type=str, required=True, help="输入 mask PNG（自动找 .npy）")
    pc.add_argument("--out-heightmap", type=str, required=True, help="输出裁切后高度场 .npy")
    pc.add_argument("--out-mask", type=str, required=True, help="输出裁切后 mask PNG（同时存 .npy）")
    pc.add_argument("--out-preview", type=str, default=None, help="输出裁切后预览 PNG")
    pc.add_argument("--pad", type=int, default=20, help="非深蓝极点外 padding 像素")
    pc.set_defaults(func=map_cmds.cmd_crop)

    pu = sub.add_parser("pad-upscale", help="补正方形 + 超分到目标尺寸")
    pu.add_argument("--heightmap", type=str, required=True, help="输入高度场 .npy")
    pu.add_argument("--mask", type=str, required=True, help="输入 mask PNG（自动找 .npy）")
    pu.add_argument("--preview", type=str, default=None, help="输入预览 PNG（可选）")
    pu.add_argument("--out-heightmap", type=str, required=True, help="输出超分高度场 .npy")
    pu.add_argument("--out-mask", type=str, required=True, help="输出超分 mask PNG（同时存 .npy）")
    pu.add_argument("--out-preview", type=str, default=None, help="输出超分预览 PNG")
    pu.add_argument("--size", type=int, default=8192, help="目标尺寸（默认 8192）")
    pu.set_defaults(func=map_cmds.cmd_pad_upscale)

    # 内部子命令（供 subprocess 调用，隔离内存）
    pr = sub.add_parser("_resize", help="[内部] 放大掩码并保存 PNG")
    pr.add_argument("--mask", type=str, required=True)
    pr.add_argument("--size", type=int, required=True)
    pr.add_argument("--seed", type=int, required=True)
    pr.add_argument("--out", type=str, required=True)
    pr.set_defaults(func=map_cmds.cmd_resize)

    pl = sub.add_parser("_landmask", help="[内部] 从种子生成大陆掩码")
    pl.add_argument("--size", type=int, required=True)
    pl.add_argument("--seed", type=int, required=True)
    pl.add_argument("--out", type=str, required=True)
    pl.set_defaults(func=map_cmds.cmd_landmask)

    pw2 = sub.add_parser("_world", help="[内部] 从 mask PNG 生成世界地图")
    pw2.add_argument("--mask", type=str, required=True)
    pw2.add_argument("--size", type=int, required=True)
    pw2.add_argument("--seed", type=int, required=True)
    pw2.add_argument("--heightmap", type=str, default=None, help="外部高度场 .npy")
    pw2.set_defaults(func=map_cmds.cmd_world_internal)

    pt1 = sub.add_parser("_tectonic_one", help="[内部] 生成单张板块构造地形图")
    pt1.add_argument("--size", type=int, required=True)
    pt1.add_argument("--seed", type=int, required=True)
    pt1.add_argument("--out", type=str, required=True)
    pt1.set_defaults(func=cand.cmd_tectonic_one)

    # Azgaar 模板法地形候选
    ptc2 = sub.add_parser("template-candidates", help="批量生成 Azgaar 模板法地形候选")
    ptc2.add_argument("--count", type=int, default=10)
    ptc2.add_argument("--size", type=int, default=1024)
    ptc2.add_argument("--template", type=str, default=None,
                      help="指定模板（continent/volcano/archipelago/mountains/plains），不指定则轮换所有")
    ptc2.set_defaults(func=cand.cmd_template_candidates)

    pt2 = sub.add_parser("_template_one", help="[内部] 生成单张 Azgaar 模板法地形图")
    pt2.add_argument("--size", type=int, required=True)
    pt2.add_argument("--seed", type=int, required=True)
    pt2.add_argument("--template", type=str, required=True)
    pt2.add_argument("--out", type=str, required=True)
    pt2.add_argument("--mask", type=str, default=None, help="外部蒙版 PNG（可选）")
    pt2.add_argument("--save-heightmap", type=str, default=None, help="保存原始高度场 .npy（供 L3 群系/河流管线复用）")
    pt2.set_defaults(func=cand.cmd_template_one)

    # 从外部蒙版 PNG 生成 Azgaar 模板法地形（用锁定的大陆形状）
    ptfp = sub.add_parser("template-from-png", help="从外部 PNG 蒙版生成 Azgaar 模板法地形")
    ptfp.add_argument("--mask", type=str, required=True, help="大陆蒙版 PNG 路径")
    ptfp.add_argument("--size", type=int, default=1024)
    ptfp.add_argument("--seed", type=int, default=BASE_SEED)
    ptfp.add_argument("--template", type=str, default="continent")
    ptfp.add_argument("--out", type=str, default=None)
    ptfp.add_argument("--save-heightmap", type=str, default=None, help="保存原始高度场 .npy")
    ptfp.set_defaults(func=cand.cmd_template_from_png)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
