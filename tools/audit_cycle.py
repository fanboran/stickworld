#!/usr/bin/env python3
import re, os
ROOT = os.path.join(os.path.dirname(__file__), "..", "stick-world")

def module_of(path):
    rel = os.path.relpath(path, ROOT).replace("\\", "/")
    m = re.match(r"modules/([^/]+)/", rel)
    return m.group(1) if m else ("core" if rel.startswith("core/") else None)

owner = {}
for dp, _, fs in os.walk(ROOT):
    if ".godot" in dp or "node_modules" in dp:
        continue
    for f in fs:
        if not f.endswith(".gd"):
            continue
        p = os.path.join(dp, f)
        mod = module_of(p)
        if not mod:
            continue
        t = open(p, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"^\s*class_name\s+(\w+)", t, re.M):
            owner[m.group(1)] = mod

def refs_to(t, tgt_mod):
    out = set()
    for cn, ow in owner.items():
        if ow != tgt_mod:
            continue
        if re.search(r"\b" + re.escape(cn) + r"\b", t):
            decl = [l for l in t.splitlines() if re.match(r"^\s*class_name\s+" + re.escape(cn) + r"\b", l)]
            o = t
            for d in decl:
                o = o.replace(d, "")
            if re.search(r"\b" + re.escape(cn) + r"\b", o):
                out.add(cn)
    return out

print("=== combat -> world (edges) ===")
for dp, _, fs in os.walk(os.path.join(ROOT, "modules", "combat")):
    for f in fs:
        if not f.endswith(".gd"):
            continue
        p = os.path.join(dp, f)
        t = open(p, encoding="utf-8", errors="replace").read()
        r = refs_to(t, "world")
        if r:
            print(f"  {os.path.relpath(p, ROOT)} -> {sorted(r)}")

print("=== world -> combat (edges) ===")
for dp, _, fs in os.walk(os.path.join(ROOT, "modules", "world")):
    for f in fs:
        if not f.endswith(".gd"):
            continue
        p = os.path.join(dp, f)
        t = open(p, encoding="utf-8", errors="replace").read()
        r = refs_to(t, "combat")
        if r:
            print(f"  {os.path.relpath(p, ROOT)} -> {sorted(r)}")
