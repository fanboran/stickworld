#!/usr/bin/env python3
"""模块README登记审计（doc-lint）：登记覆盖率 + 引用有效性 + 生成方式标注。

用法:
  python tools/audit_docs.py                 # 全量审计
  python tools/audit_docs.py --map <模块名>   # 生成该模块的文件地图骨架（贴进README后补一句话职责）

检查两件事：
  1. stick-world/modules/*/ 是否有 README.md（缺 = 待登记清单，信息性）。
  2. 已有 README 里引用的文件路径是否真实存在（防登记腐烂；失效引用 = 硬错误，退出码 1）。

路径解析约定（按序尝试）：res:// 前缀剥掉映射到 stick-world/；stick-world|docs|tools
开头按仓库根解析；其余相对模块根解析。只把「含 / 且以已知扩展名结尾」的 token 当路径。

--map 模式只打印到 stdout，不改任何文件；提取 class_name / extends，api.gd 单列。
"""
import re
import os
import sys
import argparse

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
MODULES = os.path.join(ROOT, "stick-world", "modules")
PATH_EXT = (".gd", ".tscn", ".tres", ".py", ".json", ".sh", ".cfg", ".gdns", ".md", ".png", ".import")

TOKEN = re.compile(r"[\w\-./\\]+")
CLASS_NAME = re.compile(r"^\s*class_name\s+(\w+)", re.M)
EXTENDS = re.compile(r"^\s*extends\s+([\w\"]+)")


def norm(token: str) -> str:
    t = token.replace("\\", "/").strip().strip("`*()[]<>，。；")
    while t.startswith("./"):
        t = t[2:]
    return t


def is_path_token(token: str) -> bool:
    t = norm(token)
    return ("/" in t and t.lower().endswith(PATH_EXT)
            and "://" not in t and not t.startswith("http"))


def resolve(t: str, module_dir: str):
    cands = []
    if os.path.isabs(t):
        cands.append(t)
        i = t.find("/game-2/")
        if i != -1:
            cands.append(os.path.join(ROOT, t[i + len("/game-2/"):]))
    if t.lower().startswith("res://"):
        cands.append(os.path.join(ROOT, "stick-world", t[6:]))
    for marker in ("stick-world/", "docs/", "tools/"):
        if marker in t:
            cands.append(os.path.join(ROOT, t[t.index(marker):]))
    cands.append(os.path.join(ROOT, "stick-world", t))
    cands.append(os.path.join(ROOT, t))
    cands.append(os.path.join(module_dir, t))
    for c in cands:
        if os.path.isfile(c) or os.path.isdir(c):
            return c
    return None


def audit():
    broken, have, missing = [], [], []
    for name in sorted(os.listdir(MODULES)):
        mdir = os.path.join(MODULES, name)
        if not os.path.isdir(mdir):
            continue
        readme = os.path.join(mdir, "README.md")
        gd_count = sum(1 for dp, _, fs in os.walk(mdir) for f in fs if f.endswith(".gd"))
        if not os.path.isfile(readme):
            missing.append((name, gd_count))
            continue
        with open(readme, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
        have.append((name, len(lines), gd_count))
        for i, line in enumerate(lines, 1):
            for tok in TOKEN.findall(line):
                if not is_path_token(tok):
                    continue
                if resolve(norm(tok), mdir) is None:
                    broken.append((f"modules/{name}/README.md:{i}", tok.strip()))

    print("== 模块README覆盖率 ==")
    total = len(have) + len(missing)
    print(f"已有 {len(have)}/{total}：")
    for n, ln, gc in have:
        print(f"  {n:<14} {ln:>4}行  gd×{gc}")
    if missing:
        print(f"缺 README（待登记，按代码量降序）：")
        for n, gc in sorted(missing, key=lambda x: -x[1]):
            print(f"  {n:<14} gd×{gc}")

    print("\n== 引用有效性 ==")
    if broken:
        print(f"失效引用 {len(broken)} 处：")
        for where, tok in broken:
            print(f"  {where}  →  {tok}")
    else:
        print("全部引用可达。")

    print(f"\n结论：{'FAIL（存在失效引用，退出码1）' if broken else 'PASS（缺README为待登记项，不算失败）'}")
    return 1 if broken else 0


def file_map(module: str):
    mdir = os.path.join(MODULES, module)
    if not os.path.isdir(mdir):
        print(f"模块不存在：{module}（可选：{', '.join(sorted(os.listdir(MODULES)))}）")
        return 1
    rows = []
    for dp, _, fs in os.walk(mdir):
        for f in sorted(fs):
            if not f.endswith(".gd"):
                continue
            p = os.path.relpath(os.path.join(dp, f), mdir).replace("\\", "/")
            src = open(os.path.join(dp, f), encoding="utf-8", errors="replace").read()
            cn = CLASS_NAME.search(src)
            ex = EXTENDS.search(src)
            tag = "（对外契约）" if f == "api.gd" else ""
            rows.append((p, cn.group(1) if cn else "", ex.group(1) if ex else "", tag))
    print(f"## 文件地图（脚本提取自代码实态，职责列待补一句话）\n")
    print(f"| 文件 | class_name | extends | 职责 |")
    print(f"|---|---|---|---|")
    for p, cn, ex, tag in sorted(rows):
        print(f"| `{p}` | {cn} | {ex} | {tag} |")
    print(f"\n共 {len(rows)} 个脚本。补完职责列后粘入 modules/{module}/README.md。")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", metavar="模块名")
    args = ap.parse_args()
    sys.exit(file_map(args.map) if args.map else audit())
