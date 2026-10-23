#!/usr/bin/env python3
"""跨模块依赖静态分析：class_name 引用 + 资源路径字符串 → 模块依赖图。

用法: python tools/audit_deps.py

输出四段：模块依赖图（静态边 + 运行时注入边以"(注入)"标注）/ 全部依赖环 /
跨模块越界引用（非 api.gd，分 preload 与裸字符串两类）/ 运行时注入边扫描
（信息段，不入红线）。退出码即红线：新环或越界超基线 → exit 1。

判定规则（2026-08-31 修正，此前版本结论不可用）：
  1. 匹配 class_name 前先剥离注释与字符串，否则注释里提一句就算一条依赖边。
     实例：input_dispatcher.gd 注释「Building 不再直调 dispatcher」曾让
     player_control → building_gen 成为假边，进而报出不存在的环。
  2. 匹配 preload/路径字符串时保留字符串内容（路径本身就写在字符串里），只去注释。
  3. 邻接表用有序结构聚合，依赖图与环的顺序稳定可复现。
  4. 枚举全部简单环并规范化去重，不再「找到第一个就返回」。
  5. （2026-09-19）任何 "res://modules/<mod>/…" 字符串都建边，不限于 preload(
     调用——change_scene_to_file / load / DirAccess 等运行时路径同样构成依赖
     （盲区实例：ui_global 载入屏硬编码 game_root.tscn 直切 L3 组合根）。
     跨模块的裸字符串路径（非 api.gd）进越界清单，行内 audit-exempt 标记豁免。

已知豁免：装配器（system_setup.gd）需按具体类型做依赖注入，其跨模块 preload
属设计使然，单独统计不混入越界违规清单。

棘轮红线（AR-6）：KNOWN_CYCLES / PRELOAD_VIOL_BASELINE / STRING_VIOL_BASELINE /
ASSEMBLER_PRELOAD_BASELINE 登记当前在册债务，只降不升——新环或超基线即 exit 1；
低于基线时提示收缩基线，防止「零依赖环」验收标准与工具输出长期脱节。
"""
import re, os, sys
from collections import defaultdict

ROOT = os.path.join(os.path.dirname(__file__), "..", "stick-world")
MODULES = os.path.join(ROOT, "modules")

# 装配器白名单：composition root 必须知道具体类型才能装配
ASSEMBLER = {"modules/world/scripts/setup/system_setup.gd"}

# ── 棘轮基线（在册债务，只降不升；修复后应回填收缩）─────────────────────────
# 二元环以字典序小者开头登记，与输出规范化一致
KNOWN_CYCLES = {
    ("organization", "world"),
    ("town_life", "units"),
    ("world", "world_map"),
}
PRELOAD_VIOL_BASELINE = 0   # 在册越界 preload（AR-1 已清偿归零：hd2d 场景/云牌改经
                            # Hd2dAPI/UIAPI 契约，demo_quest 随演示目标链根除）
STRING_VIOL_BASELINE = 0    # 裸字符串跨模块越界（AR-1 已清偿归零：dev_scene_escape
                            # 路径常量迁 UIAPI）
# 装配器深路径 preload 红线（AR-6）：composition root（system_setup.gd）豁免的
# 跨模块 preload 总数只降不升——模块自装配下沉（AR-1）应让它持续收缩，
# 新增装配需求走对应模块 setup.gd，不在装配器堆深路径 preload
ASSEMBLER_PRELOAD_BASELINE = 37

# 运行时注入型跨模块边（2026-10-23 审计 P2-3）：目标 API 以 Node 弱类型经装配器/
# 上游 set 进来，静态扫描（preload/路径/class_name）完全不可见，须在此登记。
# 与 modules/README.md §2 边表同步登记；依赖图输出中以"(注入)"标注。
# 只作显性化展示，不入环检测/红线——注入对的目标多为零出向基础层（resources 等），
# 展示层先观察一轮，是否升格红线待定。
RUNTIME_EDGES = {
    # organization → construction：RecruitManager 持 ConstructionApi 取空闲村民/
    #   征用退工（recruit_manager.gd _construction_api.unregister_worker /
    #   get_available_workers；注入 system_setup_core_systems._setup_recruit_system
    #   mgr.setup 首参）
    ("organization", "construction"),
    # organization → resources：RecruitManager 持 ResourcesApi 查/扣招兵资源
    #   （recruit_manager.gd _resources_api.get_stock/consume；注入同上
    #   mgr.setup 次参）
    ("organization", "resources"),
    # construction → resources：ConstructionManager/BuildingCosts（P0-9 成本扣减
    #   /清场回收）/BuildMenu 持 ResourcesApi 调 get_stock/consume/produce
    #   （注入 system_setup_core_systems set_resources_api 链）
    ("construction", "resources"),
    # units → resources：实体注入链（spawn 时 set_resources_api → 实体）→
    #   interaction_controller 采集入库 / BehaviorHarvest 劳作入账 /
    #   ResourcesStorageBackend 村仓账本适配（注入 game_root_map_flow /
    #   save_handler / initial_content）
    ("units", "resources"),
    # units → organization：实体持 OrganizationApi（stickman_entity
    #   set/get_organization_api；注入 game_root_map_flow 玩家 spawn 处）
    ("units", "organization"),
    # formation → organization：FormationSystem.setup(org_api) 读组织快照/
    #   补位回写（"由 GameRoot 装配时注入"，system_setup_core_systems.
    #   _setup_formation_system）
    ("formation", "organization"),
    # tactics → organization：TacticalOrders.setup 第三参 org_api（组织代理：
    #   build_dispatch_plan/get_organization；注入 _setup_tactical_system）
    ("tactics", "organization"),
    # ui_global → resources：ResourceBar 持 ResourcesApi 渲染顶栏资源条
    #   （GlobalHUD.attach_resources 注入，_setup_core_systems HUD 段）
    ("ui_global", "resources"),
}

# 模块目录名集合（注入边扫描器的词→模块解析表；只认整名，org/res 等缩写不认
# ——避免望文生义的误报，出现新别名时再显式扩表）
MODULE_DIRS = {d for d in os.listdir(MODULES)
               if os.path.isdir(os.path.join(MODULES, d))}


def module_of(path: str):
    rel = os.path.relpath(path, ROOT).replace("\\", "/")
    m = re.match(r"modules/([^/]+)/", rel)
    return m.group(1) if m else ("core" if rel.startswith("core/") else "other")


def strip_comments(code: str, keep_strings: bool = False) -> str:
    """去掉 # 行注释。keep_strings=False 时字符串内容一并剔除（用于匹配类名），
    keep_strings=True 时保留字符串（用于匹配 preload 路径）。跨行三引号全程跟踪。"""
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


# 1. 收集每个模块声明的 class_name
class_name_owner = {}   # class_name -> (module, rel_path)
for dirpath, _, files in os.walk(ROOT):
    if ".godot" in dirpath or "node_modules" in dirpath:
        continue
    for f in files:
        if not f.endswith(".gd"):
            continue
        p = os.path.join(dirpath, f)
        mod = module_of(p)
        if mod == "other":
            continue
        code = strip_comments(read(p))
        for m in re.finditer(r"^\s*class_name\s+(\w+)", code, re.M):
            class_name_owner[m.group(1)] = (mod, os.path.relpath(p, ROOT).replace("\\", "/"))

# 2. 扫描每个文件，找 preload/load + 路径字符串 + class_name 引用
file_deps = {}          # rel_path -> (module, set(module))
preload_viol = []       # (rel_path, line, target)
string_viol = []        # 裸字符串路径越界（非 preload 形式）
preload_exempt = []     # 行内 audit-exempt 标记豁免的（rel_path, line, target）
assembler_preloads = 0
runtime_hits = defaultdict(set)  # (src_mod, tgt_mod) -> {rel_path} 注入模式命中
for dirpath, _, files in os.walk(ROOT):
    if ".godot" in dirpath or "node_modules" in dirpath:
        continue
    for f in files:
        if not f.endswith(".gd"):
            continue
        p = os.path.join(dirpath, f)
        rel = os.path.relpath(p, ROOT).replace("\\", "/")
        mod = module_of(p)
        if mod == "other":
            continue
        raw = read(p)
        code_no_str = strip_comments(raw)                 # 匹配类名
        code_keep_str = strip_comments(raw, True)         # 匹配路径字符串

        deps = set()
        # core/ 下不论子目录（autoload/entities/services）一律归为 core 基础设施；
        # res://core/ 字符串统一按 core 计（含 preload/load 与裸字符串）
        for m in re.finditer(r'["\']res://modules/([^/"\']+)/', code_keep_str):
            deps.add(m.group(1))
        if re.search(r'["\']res://core/', code_keep_str):
            deps.add("core")

        for cn, (owner_mod, owner_rel) in class_name_owner.items():
            if owner_mod == mod:
                continue
            body = "\n".join(
                l for l in code_no_str.split("\n")
                if not re.match(r"^\s*class_name\s+" + re.escape(cn) + r"\b", l))
            if re.search(r"\b" + re.escape(cn) + r"\b", body):
                deps.add(owner_mod)

        deps.discard("core")    # core 是基础设施，不计入环
        deps.discard(mod)       # 模块内部自引用不计入跨模块图
        file_deps[rel] = (mod, deps)

        # 运行时注入边模式扫描：var _<模块名>_api 字段 / func set_<模块名>_api
        # 注入方法（弱类型 Node 注入是本项目跨模块运行时耦合的惯例载体）。
        # 只扫声明不扫赋值——GDScript 静态类型下赋值不产生声明之外的目标对；
        # 词必须恰好是模块目录名（org/res 等缩写不认，见 MODULE_DIRS 注释）。
        # 命中且模块对既不在 RUNTIME_EDGES、也不是静态边 → 疑似未登记注入边，
        # 信息段提示不入红线：先观察一轮噪声水平，再决定是否升格棘轮。
        for m in re.finditer(r"^\s*var\s+_([a-z_]+?)_api\s*:", code_no_str, re.M):
            if m.group(1) in MODULE_DIRS and m.group(1) != mod:
                runtime_hits[(mod, m.group(1))].add(rel)
        for m in re.finditer(r"^\s*func\s+set_([a-z_]+?)_api\s*\(", code_no_str, re.M):
            if m.group(1) in MODULE_DIRS and m.group(1) != mod:
                runtime_hits[(mod, m.group(1))].add(rel)

        # 越界引用（装配器单独统计；行内 audit-exempt 标记显式豁免）。
        # preload 形式与裸字符串形式分开报：前者是编译期耦合，更重。
        def _exempt_or_violate(kind_list, rel, raw, code_keep_str, start, tgt):
            tgt_mod, tgt_path = tgt
            line = code_keep_str[:start].count("\n") + 1
            # 标记写在注释里，而 code_keep_str 已剥注释——须回原文找（含前 2 行）
            raw_lines = raw.split("\n")
            ctx = "\n".join(raw_lines[max(0, line - 3):line])
            if rel in ASSEMBLER:
                return "assembler"
            if "audit-exempt" in ctx:
                return "exempt"
            kind_list.append((rel, line, f"modules/{tgt_mod}/{tgt_path}"))
            return "viol"

        preload_spans = []
        for m in re.finditer(r'preload\(\s*(["\'])res://modules/([^/]+)/([^"\']*)["\']', code_keep_str):
            preload_spans.append((m.start(), m.end()))
            tgt_mod, tgt_path = m.group(2), m.group(3)
            if tgt_mod == mod or tgt_path.startswith("api.gd"):
                continue
            res = _exempt_or_violate(preload_viol, rel, raw, code_keep_str, m.start(), (tgt_mod, tgt_path))
            if res == "assembler":
                assembler_preloads += 1
            elif res == "exempt":
                preload_exempt.append((rel, code_keep_str[:m.start()].count("\n") + 1,
                                       f"modules/{tgt_mod}/{tgt_path}"))
        for m in re.finditer(r'["\']res://modules/([^/]+)/([^"\']*)["\']', code_keep_str):
            if any(s <= m.start() < e for s, e in preload_spans):
                continue  # 已按 preload 形式报告
            tgt_mod, tgt_path = m.group(1), m.group(2)
            if tgt_mod == mod or tgt_path.startswith("api.gd"):
                continue
            _exempt_or_violate(string_viol, rel, raw, code_keep_str, m.start(), (tgt_mod, tgt_path))

# 3. 聚合模块图（有序）；运行时注入边并入展示——静态图里没有的目标补在尾部
# 带"(注入)"标注（已在静态图的注入对不重复标注，静态边信息更全）
mod_deps = defaultdict(set)
for rel, (mod, deps) in file_deps.items():
    mod_deps[mod] |= deps
graph = {m: sorted(d) for m, d in mod_deps.items()}
runtime_only = defaultdict(list)   # 模块 -> [静态图没有的注入目标]
for src, tgt in sorted(RUNTIME_EDGES):
    if tgt not in graph.get(src, ()):
        runtime_only[src].append(tgt)

print("=== 模块依赖图（直接依赖；带(注入)尾注的为运行时注入边，静态扫描不可见）===")
for mod in sorted(graph):
    cols = list(graph[mod]) + [f"{t}(注入)" for t in runtime_only.get(mod, ())]
    print(f"{mod:18s} -> {', '.join(cols) if cols else '(无)'}")

# 4. 枚举全部简单环（规范化为最小元素开头后去重，保证输出稳定）
cycles = set()


def dfs(start, node, path, seen):
    for nxt in graph.get(node, ()):
        if nxt == start:
            cyc = list(path)
            k = cyc.index(min(cyc))
            cycles.add(tuple(cyc[k:] + cyc[:k]))
        elif nxt not in seen and nxt > start:
            dfs(start, nxt, path + [nxt], seen | {nxt})


for s in sorted(graph):
    dfs(s, s, [s], {s})

cycles = sorted(cycles, key=lambda c: (len(c), c))
print(f"\n=== 依赖环（共 {len(cycles)} 个）===")
if not cycles:
    print("  未发现环")
else:
    # 二元环是根因：修掉它们，由其组合出的长环会一并消失
    base = [c for c in cycles if len(c) == 2]
    tri = [c for c in cycles if len(c) == 3]
    longer = [c for c in cycles if len(c) > 3]
    print(f"  二元环 {len(base)} 个（根因，优先修这些）:")
    for c in base:
        known = "（在册）" if tuple(c) in KNOWN_CYCLES else "  ⚠ 新增环！"
        print(f"    {c[0]} <-> {c[1]} {known}")
    if tri:
        print(f"  三元环 {len(tri)} 个:")
        for c in tri:
            print(f"    {' -> '.join(c)} -> {c[0]}")
    if longer:
        print(f"  更长环 {len(longer)} 个（由上述基础环组合而成，不单列）")

# 5. 越界引用（preload + 裸字符串）
print("\n=== 跨模块 preload 到内部文件（非 api.gd）===")
for rel, line, tgt in sorted(preload_viol):
    print(f"  {rel}:{line}: preload -> {tgt}")
print(f"共 {len(preload_viol)} 处"
      + (f"（另有装配器 {', '.join(sorted(ASSEMBLER))} 的 {assembler_preloads} 处已豁免："
         f"composition root 需按具体类型注入）" if assembler_preloads else ""))
print("\n=== 跨模块裸字符串路径到内部文件（非 api.gd）===")
for rel, line, tgt in sorted(string_viol):
    print(f"  {rel}:{line}: string -> {tgt}")
print(f"共 {len(string_viol)} 处")
if preload_exempt:
    print("\n=== 显式豁免（行内 audit-exempt 标记）===")
    for rel, line, tgt in sorted(preload_exempt):
        print(f"  {rel}:{line}: preload -> {tgt}")
    print(f"共 {len(preload_exempt)} 处")

# 5.5 运行时注入边扫描（信息段，不入红线）：登记在册的注入对罗列一遍供人读，
# 扫描器命中但未登记的列"疑似未登记注入边"。入红线的门槛（观察一轮后定）：
# 注入登记靠人手维护，先看扫描器是否稳定零误报，再决定是否棘轮化。
print("\n=== 运行时注入边（静态不可见，RUNTIME_EDGES 登记）===")
for src, tgt in sorted(RUNTIME_EDGES):
    print(f"  {src} -> {tgt} (注入)")
unregistered = {pair: files for pair, files in runtime_hits.items()
                if pair not in RUNTIME_EDGES and pair[1] not in graph.get(pair[0], ())}
if unregistered:
    print("  疑似未登记注入边（确认后登记进 RUNTIME_EDGES / modules/README.md 边表）:")
    for (src, tgt), files in sorted(unregistered.items()):
        for f in sorted(files):
            print(f"    {src} -> {tgt}: {f}")
    print(f"  共 {len(unregistered)} 对未登记")
else:
    print("  扫描器未发现未登记注入边")

# 6. 棘轮红线：在册债务只降不升（AR-6 方向）
failures = []
new_cycles = [c for c in cycles if tuple(c) not in KNOWN_CYCLES]
if new_cycles:
    failures.append(f"新增依赖环 {len(new_cycles)} 个：{[' <-> '.join(c) for c in new_cycles]}")
if len(preload_viol) > PRELOAD_VIOL_BASELINE:
    failures.append(f"越界 preload {len(preload_viol)} 处超基线 {PRELOAD_VIOL_BASELINE}")
if len(string_viol) > STRING_VIOL_BASELINE:
    failures.append(f"裸字符串越界 {len(string_viol)} 处超基线 {STRING_VIOL_BASELINE}")
if assembler_preloads > ASSEMBLER_PRELOAD_BASELINE:
    failures.append(f"装配器深路径 preload {assembler_preloads} 处超基线 {ASSEMBLER_PRELOAD_BASELINE}"
                    "（AR-1：新增装配走模块 setup.gd，装配器只编排）")
print("\n=== 棘轮红线 ===")
if failures:
    for msg in failures:
        print(f"  [FAIL] {msg}")
    sys.exit(1)
print("  [PASS] 无新增环、越界未超基线")
cycle_set = {tuple(c) for c in cycles}
fixed_cycles = [c for c in KNOWN_CYCLES if c not in cycle_set]
if len(preload_viol) < PRELOAD_VIOL_BASELINE or len(string_viol) < STRING_VIOL_BASELINE \
        or assembler_preloads < ASSEMBLER_PRELOAD_BASELINE or fixed_cycles:
    print(f"  [提示] 债务低于基线（环 {len(cycles)} / preload {len(preload_viol)}/{PRELOAD_VIOL_BASELINE}"
          f" / 字符串 {len(string_viol)}/{STRING_VIOL_BASELINE}"
          f" / 装配器 {assembler_preloads}/{ASSEMBLER_PRELOAD_BASELINE}"
          + (f" / 已消环 {['<->'.join(c) for c in fixed_cycles]}" if fixed_cycles else "")
          + "），可收缩脚本头部的棘轮基线")
sys.exit(0)
