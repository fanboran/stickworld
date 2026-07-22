"""
程序化材质迭代脚本（通用引擎）。

归档 → 生成贴图 → 多维度对比。

用法：
    python iterate.py                          # 默认 thatch 材质
    python iterate.py --material stone_wall    # 切换材质
    python iterate.py --material thatch --stats
    python iterate.py --compare-only           # 仅对比（跳过生成）
    python iterate.py --pair a.png b.png       # A/B 对比
    python iterate.py --open                   # 打开结果文件

扩展新材质：在 MATERIALS 字典中添加一条即可。
"""
import subprocess
import sys
import os
import time
import argparse

# === 路径配置 ===
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
PROJECT_ROOT = os.path.normpath(os.path.join(BUILDING_GEN, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")

GODOT_EXE = r"F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"
PYTHON_EXE = r"C:\Users\fanbo\AppData\Local\Programs\Python\Python312\python.exe"

# ══════════════════════════ 材质注册表 ══════════════════════════
# 扩展新材质只需在此追加一条。texture_type: "structured"（植物/植被）或 "seamless"（砖墙/无缝纹理）

MATERIALS = {
    "thatch": {
        "description": "茅草屋顶",
        "output": os.path.join(REF_DIR, "preview_thatch.png"),
        "reference": os.path.join(REF_DIR, "thatch_ref.png"),
        "regions": 3,
        "texture_type": "structured",
    },
    # === 预留扩展位 ===
    # "stone_wall": {
    #     "description": "石墙",
    #     "output": os.path.join(REF_DIR, "preview_stone_wall.png"),
    #     "reference": os.path.join(REF_DIR, "stone_wall_ref.png"),
    #     "regions": 4,
    #     "texture_type": "seamless",
    # },
    # "wood_plank": {
    #     "description": "木板墙",
    #     "output": os.path.join(REF_DIR, "preview_wood_plank.png"),
    #     "reference": os.path.join(REF_DIR, "wood_plank_ref.png"),
    #     "regions": 3,
    #     "texture_type": "seamless",
    # },
    # "crenellation": {
    #     "description": "城垛屋顶",
    #     "output": os.path.join(REF_DIR, "preview_crenellation.png"),
    #     "reference": os.path.join(REF_DIR, "crenellation_ref.png"),
    #     "regions": 3,
    #     "texture_type": "structured",
    # },
}


def banner(text: str):
    print(f"\n{'='*60}")
    print(f"  {text}")
    print(f"{'='*60}")


def get_config(material: str) -> dict:
    if material not in MATERIALS:
        print(f"[ERROR] 未知材质: {material}")
        print(f"  可用: {', '.join(MATERIALS.keys())}")
        sys.exit(1)
    return MATERIALS[material]


def step_archive(config: dict):
    banner(f"归档旧 preview ({config['description']})")
    out = config["output"]
    if not os.path.isfile(out):
        print("  无旧文件，跳过归档")
        return
    script = os.path.join(SCRIPT_DIR, "archive_preview.py")
    subprocess.run([PYTHON_EXE, script, os.path.basename(out)], check=True)


def step_dump_texture(config: dict, material: str):
    banner(f"生成贴图 ({config['description']})")

    import json as _json
    cfg_path = os.path.join(SCRIPT_DIR, "_material_config.json")
    with open(cfg_path, "w", encoding="utf-8") as f:
        _json.dump({"material": material}, f)

    cmd = [
        GODOT_EXE,
        "--headless",
        "--path", PROJECT_ROOT,
        "--script", "res://modules/building_gen/tools/dmp.gd",
    ]
    t0 = time.time()
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    elapsed = time.time() - t0

    try:
        os.remove(cfg_path)
    except OSError:
        pass

    if result.returncode != 0:
        print(f"[ERROR] Godot 生成贴图失败 ({elapsed:.1f}s)")
        print("STDOUT:", result.stdout)
        print("STDERR:", result.stderr[-500:] if result.stderr else "")
        sys.exit(1)
    out = config["output"]
    if os.path.isfile(out):
        sz = os.path.getsize(out)
        print(f"[OK] {os.path.basename(out)} ({sz} bytes, {elapsed:.1f}s)")
    else:
        print(f"[ERROR] 贴图文件未生成: {out}")
        sys.exit(1)


def step_stats(config: dict):
    banner(f"多维度对比 ({config['description']})")
    sys.path.insert(0, SCRIPT_DIR)
    try:
        from compare import run_compare, print_results
        results = run_compare(config["output"], config["reference"], config.get("regions", 3))
        print_results(results)
    except ImportError as e:
        print(f"[SKIP] 导入 compare 失败: {e}")
    except FileNotFoundError as e:
        print(f"[SKIP] {e}")


def step_pair(config: dict, gen_a: str, gen_b: str):
    banner(f"A/B 对比 ({config['description']})")
    sys.path.insert(0, SCRIPT_DIR)
    try:
        from compare import run_pair_compare, print_pair_results
        pair = run_pair_compare(gen_a, gen_b, config["reference"], config.get("regions", 3))
        print_pair_results(pair)
    except ImportError as e:
        print(f"[SKIP] {e}")
    except FileNotFoundError as e:
        print(f"[SKIP] {e}")


def open_results(config: dict):
    out = config["output"]
    if os.path.isfile(out):
        os.startfile(out)


def main():
    parser = argparse.ArgumentParser(description="程序化材质迭代（通用引擎）")
    parser.add_argument("--material", default="thatch", help="材质名（thatch/stone_wall/wood_plank/crenellation）")
    parser.add_argument("--stats", action="store_true", help="生成后运行多维度对比")
    parser.add_argument("--compare-only", action="store_true", help="跳过生成和归档，仅运行对比")
    parser.add_argument("--open", action="store_true", help="完成后打开结果文件")
    parser.add_argument("--pair", nargs=2, metavar=("GEN_A", "GEN_B"),
                        help="A/B对比两份生成图")
    parser.add_argument("--list", action="store_true", help="列出所有可用材质")
    args = parser.parse_args()

    if args.list:
        print("可用材质:")
        for name, cfg in MATERIALS.items():
            print(f"  {name:<20s} {cfg['description']}  ({cfg['texture_type']})")
        return

    config = get_config(args.material)

    # --compare-only：跳过生成流程
    if args.compare_only:
        step_stats(config)
        return

    # --pair：A/B 对比
    if args.pair:
        step_pair(config, args.pair[0], args.pair[1])
        return

    # 正常迭代流程
    t_start = time.time()
    step_archive(config)
    step_dump_texture(config, args.material)
    if args.stats:
        step_stats(config)

    elapsed = time.time() - t_start
    banner("完成")
    print(f"  材质:    {config['description']} ({args.material})")
    print(f"  总耗时:  {elapsed:.1f}s")
    print(f"  参考图:  {config['reference']}")
    print(f"  生成图:  {config['output']}")

    if args.open:
        open_results(config)


if __name__ == "__main__":
    main()
