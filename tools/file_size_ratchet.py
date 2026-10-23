#!/usr/bin/env python3
"""生产代码文件行数棘轮：core/ + modules/ 下 .gd 物理行数只减不增。

用法: python tools/file_size_ratchet.py [--regen]

扫描域：stick-world/core/**/*.gd + stick-world/modules/**/*.gd（生产口径，
天然不含 tests/tools/addons）。退出码即红线：

  R1 新文件硬顶：物理行数 ≥400 且不在 SIZE_BASELINE → exit 1
     （拆子域助手，或入册 SIZE_BASELINE 并带理由）
  R2 在册只减不增：物理行数 > 基线登记值 → exit 1
     （拆子域助手，注释随码迁移；基线不许上调）

观察段（打印不 fail）：
  I1 超线文件 物理行/净代码行 并排——净代码行 = 去空行+注释后的行数，
     防「删注释凑行数」可见化（删注释物理行不降，净行会露馅）。
  I2 最长函数 Top10——按缩进回退估算函数体（缩进 ≤ 函数定义行即结束），
     只报代码行 >120 的，纯观察不设硬线。
  I3 基线收缩提示：文件现值低于登记值时列出「可收缩至 X」（已 <400 可除名），
     对齐 audit_deps 的债务收缩提示；已删除文件提示除名。

基线维护：`--regen` 打印当前全量字典（≥400 行文件 → 行数，按路径排序），
可直接粘贴替换脚本头部 SIZE_BASELINE。棘轮语义与 audit_deps.py 的
KNOWN_CYCLES 等基线一致：登记当前在册债务，只降不升，修复后回填收缩。

阈值依据：
  400 = 实测中位数 158（2026-10-23 全量 401 个生产 .gd）的 2.5 倍，与行数
  审计现役口径一致；低于它的文件不加管束，避免正常小改动被误报。
  不设全仓总行数基线：总行数随功能增长自然上涨，「加功能」不是症状，
  棘轮只该盯「单文件失控增长」这一个症状（拆分滞后）。
  不设函数长度硬线：缩进回退估算有误差（连续缩进块/嵌套结构），做红线会
  制造假阳性；先经 I2 观察段曝光，确有规律性垃圾再考虑升格。
"""
import os, re, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(SCRIPT_DIR, "..", "stick-world")
SCAN_DIRS = ("core", "modules")   # 生产口径：只扫 core/ + modules/
SIZE_LIMIT = 400                  # 新文件硬顶（依据见头注释）
FUNC_OBS_LIMIT = 120              # 函数长度观察线（只曝光不 fail）

# ── 棘轮基线（在册超线债务，只降不升；拆分后回填收缩，不许上调）─────────────
# 路径相对 stick-world/（正斜杠）→ 当前物理行数。2026-10-23 首次采集。
SIZE_BASELINE = {
    # 注：formation_system / hd2d_world / organization_manager 三条按 HEAD 已提交值
    # 登记（工作树有其进行中的未提交拆分，现值更低——提交后跑 --regen 回填收缩）。
    "core/autoload/save_manager.gd": 573,
    "core/autoload/world_state.gd": 455,
    "core/services/audio_manager.gd": 901,
    "core/services/music_director.gd": 947,
    "modules/building_gen/buildings/building_exterior.gd": 783,
    "modules/building_gen/buildings/interior_props.gd": 724,
    "modules/building_gen/scripts/building.gd": 485,
    "modules/combat/scripts/battle/battle_instance.gd": 634,
    "modules/combat/scripts/battle/battle_sim.gd": 532,
    "modules/combat/scripts/battle/team_ai.gd": 633,
    "modules/combat/scripts/battle/utility_scorer.gd": 540,
    "modules/combat/scripts/command/selection_system.gd": 440,
    "modules/construction/scripts/construction_manager.gd": 914,
    "modules/construction/scripts/construction_project.gd": 466,
    "modules/construction/ui/build_menu.gd": 570,
    "modules/debug_gui/scripts/ai_viz_snapshot.gd": 464,
    "modules/debug_gui/scripts/ai_viz_window.gd": 467,
    "modules/debug_gui/scripts/debug_drawers.gd": 578,
    "modules/debug_gui/scripts/debug_tools_panel.gd": 442,
    "modules/formation/scripts/battle_line.gd": 403,
    "modules/formation/scripts/formation_system.gd": 1594,
    "modules/formation/scripts/squad_phase_plan.gd": 506,
    "modules/formation/ui/formation_panel.gd": 424,
    "modules/formation/ui/squad_card.gd": 633,
    "modules/fx/scripts/crystal_sparkles.gd": 519,
    "modules/hd2d/scripts/char_rig_3d.gd": 790,
    "modules/hd2d/scripts/hd2d_world.gd": 945,
    "modules/hd2d/scripts/placer/hd2d_street_placer.gd": 523,
    "modules/organization/api.gd": 421,
    "modules/organization/scripts/organization_manager.gd": 734,
    "modules/organization/ui/command_chain_board.gd": 682,
    "modules/organization/ui/command_chain_view.gd": 559,
    "modules/organization/ui/org_panel.gd": 552,
    "modules/organization/ui/strategic_overview_panel.gd": 789,
    "modules/stick_rig/scripts/crowd_renderer.gd": 579,
    "modules/stick_rig/scripts/crowd_renderer_buckets.gd": 460,
    "modules/stick_rig/scripts/health_bar_indicator.gd": 568,
    "modules/stick_rig/scripts/stickman_anims.gd": 566,
    "modules/stick_rig/scripts/stickman_batch_rig.gd": 712,
    "modules/stick_rig/scripts/stickman_rig.gd": 949,
    "modules/stick_rig/scripts/stickman_skeleton.gd": 430,
    "modules/tactics/scripts/capture/squad_intent_planner.gd": 576,
    "modules/texture_gen/scripts/debug/capture_in_game.gd": 426,
    "modules/ui_global/scripts/menus/main_menu.gd": 546,
    "modules/ui_global/scripts/menus/soundtrack_player.gd": 532,
    "modules/ui_global/scripts/panels/settings_menu_panel.gd": 516,
    "modules/ui_global/scripts/sketch/sketch_cloud.gd": 453,
    "modules/units/scripts/ai/ai_controller.gd": 816,
    "modules/units/scripts/ai/behavior_attack.gd": 902,
    "modules/units/scripts/ai/behavior_move.gd": 490,
    "modules/units/scripts/entity/entity_motion.gd": 404,
    "modules/units/scripts/entity/interaction_controller.gd": 462,
    "modules/units/scripts/entity/visual_controller.gd": 503,
    "modules/units/scripts/entity/weapon_mount.gd": 930,
    "modules/units/scripts/stickman_entity.gd": 1332,
    "modules/units/scripts/weapons/arrow_projectile.gd": 454,
    "modules/world/scripts/camera/camera_rig.gd": 673,
    "modules/world/scripts/game_root.gd": 786,
    "modules/world/scripts/map/hd2d_map_base.gd": 951,
    "modules/world/scripts/setup/save_handler.gd": 515,
    "modules/world/scripts/setup/system_setup.gd": 474,
    "modules/world/scripts/setup/system_setup_strategic_map.gd": 402,
    "modules/world_map/api.gd": 628,
    "modules/world_map/data/l2_world_data.gd": 412,
    "modules/world_map/scripts/l2_map_renderer.gd": 473,
    "modules/world_map/scripts/l3_map_renderer.gd": 877,
    "modules/world_map/scripts/map_label_layer.gd": 471,
    "modules/world_map/scripts/map_renderer.gd": 772,
    "modules/world_map/scripts/map_renderer_geo.gd": 433,
    "modules/world_map/scripts/strategic_map_controller.gd": 745,
}


def strip_comments(code: str, keep_strings: bool = False) -> str:
    """去掉 # 行注释。keep_strings=False 时字符串内容一并剔除，
    keep_strings=True 时保留字符串（算净代码行/函数体行数用——字符串字面量
    也是代码）。跨行三引号全程跟踪。与 audit_deps.py 同源。"""
    out, in_str, i, n = [], None, 0, len(code)
    while i < n:
        c = code[i]
        if in_str:
            triple = in_str.startswith('"""') or in_str.startswith("'''")
            if triple:
                if code[i:i + 3] == in_str:
                    in_str = None
                    if keep_strings:
                        out.append(code[i:i + 3])
                    i += 3
                    continue
                if keep_strings:
                    out.append(c)
                i += 1
                continue
            if c == "\\":
                if keep_strings:
                    out.append(code[i:i + 2])
                i += 2
                continue
            if c == in_str:
                in_str = None
            if keep_strings:
                out.append(c)
            i += 1
            continue
        if code[i:i + 3] in ('"""', "'''"):
            in_str = code[i:i + 3]
            if keep_strings:
                out.append(code[i:i + 3])
            i += 3
            continue
        if c in ('"', "'"):
            in_str = c
            if keep_strings:
                out.append(c)
            i += 1
            continue
        if c == "#":
            while i < n and code[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def read(path: str) -> str:
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except Exception:
        return ""


def indent_of(line: str) -> int:
    """缩进宽度（tab 按 4 算），用于函数体缩进回退判定。"""
    expanded = line.expandtabs(4)
    return len(expanded) - len(expanded.lstrip())


def scan_files():
    """收集扫描域内全部 .gd → [(rel_path, 绝对路径)]，rel 正斜杠有序稳定。"""
    files = []
    for sub in SCAN_DIRS:
        base = os.path.join(ROOT, sub)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, files_ in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in (".godot", "node_modules")]
            for f in files_:
                if not f.endswith(".gd"):
                    continue
                p = os.path.join(dirpath, f)
                rel = os.path.relpath(p, ROOT).replace("\\", "/")
                files.append((rel, p))
    files.sort()
    return files


def longest_functions(rel: str, raw: str):
    """缩进回退估算每个函数的代码行数：从 func 定义行起，到首个缩进
    ≤ 定义行缩进的非空行（不含）为止，计非空行数（注释已剥离）。
    返回 [(代码行数, '路径:行号 func名()')]。"""
    lines = strip_comments(raw, keep_strings=True).split("\n")
    funcs = []   # (name, line_idx, indent)
    for i, l in enumerate(lines):
        m = re.match(r"^(\s*)(?:static\s+)?func\s+(\w+)\s*\(", l)
        if m:
            funcs.append((m.group(2), i, indent_of(l)))
    out = []
    for idx, (name, start, ind) in enumerate(funcs):
        end = len(lines)
        for j in range(start + 1, len(lines)):
            if lines[j].strip() and indent_of(lines[j]) <= ind:
                end = j
                break
        body = sum(1 for l in lines[start:end] if l.strip())
        out.append((body, f"{rel}:{start + 1} {name}()"))
    return out


# ── --regen：打印当前全量基线字典（可直接粘贴替换 SIZE_BASELINE）────────────
if "--regen" in sys.argv[1:]:
    rows = []
    for rel, p in scan_files():
        n = len(read(p).splitlines())
        if n >= SIZE_LIMIT:
            rows.append(f'    "{rel}": {n},')
    print("SIZE_BASELINE = {")
    print("\n".join(rows))
    print("}")
    print(f"// 共 {len(rows)} 条（≥{SIZE_LIMIT} 行），按路径排序", file=sys.stderr)
    sys.exit(0)

# ── 1. 采集：物理行 / 净代码行 ──────────────────────────────────────────────
physical = {}   # rel -> 物理行数
net_code = {}   # rel -> 净代码行数（去空行+注释）
long_funcs = [] # (代码行数, 位置描述) 全域收集，观察段取 Top10
for rel, p in scan_files():
    raw = read(p)
    physical[rel] = len(raw.splitlines())
    stripped = strip_comments(raw, keep_strings=True)
    net_code[rel] = sum(1 for l in stripped.split("\n") if l.strip())
    long_funcs.extend(longest_functions(rel, raw))

# ── 2. I1 超线文件并排展示（物理行 / 净代码行）─────────────────────────────
over = sorted(
    (rel for rel in physical if physical[rel] >= SIZE_LIMIT),
    key=lambda r: -physical[r])
print(f"=== 超线文件（≥{SIZE_LIMIT} 行，物理行/净代码行）===")
if not over:
    print("  无")
for rel in over:
    print(f"  {physical[rel]:5d} / {net_code[rel]:5d}  {rel}")
print(f"共 {len(over)} 个")

# ── 3. I2 最长函数 Top10（纯观察）───────────────────────────────────────────
obs = [x for x in long_funcs if x[0] > FUNC_OBS_LIMIT]
obs.sort(key=lambda x: -x[0])
print(f"\n=== 最长函数 Top10（缩进回退估算，代码行 >{FUNC_OBS_LIMIT}，仅观察）===")
if not obs:
    print("  无")
for n, loc in obs[:10]:
    print(f"  {n:4d} 行  {loc}")

# ── 4. 棘轮红线：R1 新文件硬顶 / R2 在册只减不增 ───────────────────────────
failures = []
for rel in over:
    if rel not in SIZE_BASELINE:
        failures.append(
            f"新文件 {rel} 达 {physical[rel]} 行（≥{SIZE_LIMIT}）未入册"
            "——拆子域助手，或入册 SIZE_BASELINE 带理由（在册后只许降不许升）")
for rel, base in sorted(SIZE_BASELINE.items()):
    if rel not in physical:
        continue   # 已删除：走下方除名提示，不算违规
    if physical[rel] > base:
        failures.append(
            f"{rel} {physical[rel]} 行超基线 {base}（+{physical[rel] - base}）"
            "——拆子域助手，注释随码迁移；基线不许上调")
print("\n=== 棘轮红线 ===")
if failures:
    for msg in failures:
        print(f"  [FAIL] {msg}")
    sys.exit(1)
print("  [PASS] 无未入册新超线文件，在册文件均未超基线")

# ── 5. I3 基线收缩提示（债务只降不升的另一半：降了要回填）───────────────────
shrink = [(rel, base, physical[rel]) for rel, base in sorted(SIZE_BASELINE.items())
          if rel in physical and physical[rel] < base]
missing = [rel for rel in sorted(SIZE_BASELINE) if rel not in physical]
if shrink or missing:
    print("  [提示] 债务低于基线，可收缩脚本头部的 SIZE_BASELINE：")
    for rel, base, cur in shrink:
        note = "（已低于 400，可直接除名）" if cur < SIZE_LIMIT else ""
        print(f"    {rel} 现值 {cur} < 登记 {base}，可收缩至 {cur}{note}")
    for rel in missing:
        print(f"    {rel} 已删除，可除名")
sys.exit(0)
