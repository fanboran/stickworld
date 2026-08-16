#!/usr/bin/env python3
"""跨模块依赖静态分析：class_name 引用 + preload/load 路径 → 模块依赖图。
用法: python tools/audit_deps.py
"""
import re, os, sys
from collections import defaultdict

ROOT = os.path.join(os.path.dirname(__file__), "..", "stick-world")
MODULES = os.path.join(ROOT, "modules")

def module_of(path: str):
    rel = os.path.relpath(path, ROOT).replace("\\", "/")
    m = re.match(r"modules/([^/]+)/", rel)
    return m.group(1) if m else ("core" if rel.startswith("core/") else "other")

# 1. 收集每个模块声明的 class_name
class_name_owner = {}   # class_name -> module
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
        try:
            txt = open(p, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        for m in re.finditer(r"^\s*class_name\s+(\w+)", txt, re.M):
            class_name_owner[m.group(1)] = mod

# 2. 扫描每个文件，找 preload/load + class_name 引用
file_deps = {}   # path -> set(module)
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
        txt = open(p, encoding="utf-8", errors="replace").read()
        deps = set()
        # preload("res://modules/xxx/...")
        for m in re.finditer(r'preload\(["\']res://modules/([^/]+)/', txt):
            deps.add(m.group(1))
        for m in re.finditer(r'load\(["\']res://modules/([^/]+)/', txt):
            deps.add(m.group(1))
        # class_name 引用（去掉自身声明行）
        for cn, owner in class_name_owner.items():
            if owner == mod:
                continue
            # 匹配词边界，排除声明行
            if re.search(r"\b" + re.escape(cn) + r"\b", txt):
                # 声明行剔除
                decl_lines = [l for l in txt.splitlines() if re.match(r"^\s*class_name\s+" + re.escape(cn) + r"\b", l)]
                other = txt
                for dl in decl_lines:
                    other = other.replace(dl, "")
                if re.search(r"\b" + re.escape(cn) + r"\b", other):
                    deps.add(owner)
        if mod != "core" and "core" in deps:
            deps.remove("core")  # core 是基础设施，不计入环
        file_deps[p] = (mod, deps)

# 3. 聚合模块图 + 找环
mod_deps = defaultdict(set)
mod_files = defaultdict(list)
for p, (mod, deps) in file_deps.items():
    mod_files[mod].append(os.path.basename(p))
    mod_deps[mod] |= deps

print("=== 模块依赖图（直接依赖）===")
for mod in sorted(mod_deps):
    deps = sorted(mod_deps[mod])
    print(f"{mod:18s} -> {', '.join(deps) if deps else '(无)'}")

# 找环
def find_cycle():
    visited = set(); stack = []
    def dfs(n):
        if n in stack:
            return stack[stack.index(n):] + [n]
        if n in visited:
            return None
        visited.add(n); stack.append(n)
        for m in mod_deps.get(n, ()):
            r = dfs(m)
            if r: return r
        stack.pop()
        return None
    for n in mod_deps:
        r = dfs(n)
        if r: return r
    return None
c = find_cycle()
print("\n=== 依赖环 ===")
print(" -> ".join(c) if c else "未发现环")

# 4. 违反"只走 api.gd"的引用：跨模块 preload 非 api 路径
print("\n=== 跨模块 preload 到内部文件（非 api.gd）===")
viol = 0
for p, (mod, deps) in sorted(file_deps.items()):
    txt = open(p, encoding="utf-8", errors="replace").read()
    for m in re.finditer(r'preload\(["\']res://modules/([^/]+)/([^"\']+)["\']', txt):
        tgt_mod, tgt_path = m.group(1), m.group(2)
        if tgt_mod == mod:
            continue
        if not tgt_path.startswith("api.gd"):
            print(f"  {os.path.relpath(p, ROOT)}: preload -> modules/{tgt_mod}/{tgt_path}")
            viol += 1
print(f"共 {viol} 处")
