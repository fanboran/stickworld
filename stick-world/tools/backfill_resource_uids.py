#!/usr/bin/env python3
"""场景/资源 UID 补齐工具（backfill_resource_uids.py）

扫 res:// 根下全部 .tscn/.tres（排除 addons/godot-sqlite 第三方与 config/strategic_map
submodule），对头部无 uid 的文件在第一行 header 标签内插入 ResourceUID 官方铸造的
uid:// 文本；已有 uid 的文件零改动；除插入的 uid 外文件字节零变动。

uid 铸造不走 python 复刻编码（引擎 id_to_text 非纯 base62，存在内部偏移），
一律经 godot --headless 调 tools/backfill_resource_uids_mint.gd 用
ResourceUID.create_id() 官方途径生成，python 侧只做全仓文本查重兜底。

用法:
  python tools/backfill_resource_uids.py --check                # 现状报告（缺失/重复/悬空），零写入
  python tools/backfill_resource_uids.py --apply [--godot X]    # 铸 uid 并插入头部
  python tools/backfill_resource_uids.py --verify [--godot X]   # 自验收: 文本校验 + 引擎侧缓存校验
      # --apply 后须先跑 godot --headless --import 重建 uid_cache.bin 再 --verify

退出码: 0=通过, 1=存在缺失/重复/悬空/错误。--check/--verify 可入 CI。
"""
from __future__ import annotations

import argparse
import collections
import os
import re
import subprocess
import sys
from pathlib import Path

# 绝不触碰的目录（相对 res:// 根，posix 风格）
EXCLUDE_DIRS = ("addons/godot-sqlite", "config/strategic_map")
# 引擎默认 uid 文本格式: uid:// + [0-9A-Za-z]+（id_to_text 双射，查重按原文比对）
UID_RE = re.compile(rb'uid="(uid://[0-9A-Za-z]+)"')
BODY_UID_RE = re.compile(rb'"(uid://[0-9A-Za-z]+)"')
FORMAT_RE = re.compile(rb"format=(\d+)")
DEFAULT_GODOT = r"F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"


class Report:
    """收集问题，退出码 1 当且仅当有任一条目。"""

    def __init__(self) -> None:
        self.missing: list[str] = []      # 头部缺 uid 的 .tscn/.tres
        self.dups: list[str] = []         # 定义处重复（header/sidecar/import 之间）
        self.dangling: list[str] = []     # 使用处 uid 解析不到任何定义
        self.skipped: list[str] = []      # 头部异常而跳过（非 gd_scene/gd_resource、format!=3 等）

    def ok(self) -> bool:
        return not (self.missing or self.dups or self.dangling or self.skipped)


def excluded(rel: str) -> bool:
    parts = rel.replace("\\", "/").split("/")
    rel_posix = "/".join(parts)
    if any(rel_posix == d or rel_posix.startswith(d + "/") for d in EXCLUDE_DIRS):
        return True
    return any(p.startswith(".") for p in parts)


def scan_files(root: Path, suffixes: tuple[str, ...]) -> list[Path]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        dirnames[:] = [d for d in dirnames if not excluded(os.path.join(rel_dir, d) if rel_dir != "." else d)]
        for fn in filenames:
            if fn.endswith(suffixes):
                out.append(Path(dirpath) / fn)
    return sorted(out)


def first_line(path: Path) -> tuple[bytes, bytes]:
    """返回 (首行不含换行, 其余字节)。二进制读，保证除插入外字节零变动。"""
    data = path.read_bytes()
    idx = data.find(b"\n")
    if idx < 0:
        return data, b""
    return data[:idx], data[idx:]


def parse_header(line: bytes) -> tuple[str | None, str | None]:
    """解析 header 行 -> (uid 文本或 None, 错误说明或 None)。"""
    if not (line.startswith(b"[gd_scene") or line.startswith(b"[gd_resource")):
        return None, "头部不是 [gd_scene/[gd_resource"
    close = line.rfind(b"]")
    if close < 0:
        return None, "首行无 ']'（跨行 header，需人工确认）"
    fm = FORMAT_RE.search(line[:close])
    if fm and fm.group(1) != b"3":
        return None, f"format={fm.group(1).decode()}（非 format=3，不插入 uid）"
    m = UID_RE.search(line[:close])
    if m:
        return m.group(1).decode("ascii"), None
    if b"uid=" in line[:close]:
        return None, "头部已有 uid= 但非 uid:// 文本格式"
    return None, None


def insert_uid(line: bytes, uid: str) -> bytes:
    """在 header 的 ']' 前插入 uid 属性；']' 前若有空白则插在空白之前，保持原有空白不动。"""
    close = line.rindex(b"]")
    i = close
    while i > 0 and line[i - 1 : i] in (b" ", b"\t"):
        i -= 1
    ins = f' uid="{uid}"'.encode("ascii")
    return line[:i] + ins + line[i:]


def collect(root: Path) -> tuple[Report, dict[str, set[str]], dict[str, str], list[Path], dict[str, set[str]]]:
    """全仓收集。返回 (报告, uid->资源路径集合, 使用处 uid->引用文件, 待补文件列表, 资源->已声明uid集合)。

    定义处归属语义：*.uid 侧车与 *.import 声明的 uid 归属其同路径兄弟资源
    （F.uid / F.import -> F），因为引擎对同一资源同时给头部与侧车登记同一 uid
    是合法状态（本仓 Godot 4.7.1 UID 重生成即如此）。故：
      - 重复 = 同一 uid 被 2+ 个不同资源声明
      - 冲突 = 同一资源声明了 2+ 个不同 uid（头部与侧车不一致）
    使用处 = .tscn/.tres 正文内引用的 uid 字符串（不含各自头部），必须能解析到定义处。
    被排除目录（第三方/submodule）只读收集、绝不写入，新铸 uid 也不得与其相撞。
    """
    rep = Report()
    decl: dict[str, set[str]] = {}
    res_uids: dict[str, set[str]] = {}
    uses: dict[str, str] = {}

    def declare(uid: str, res_rel: str) -> None:
        decl.setdefault(uid, set()).add(res_rel)
        res_uids.setdefault(res_rel, set()).add(uid)

    for p in sorted(root.rglob("*.uid")):
        if excluded(str(p.relative_to(root))):
            continue
        text = p.read_text(encoding="utf-8", errors="replace").splitlines()
        if text and (m := re.fullmatch(r"uid://[0-9A-Za-z]+", text[0].strip())):
            declare(m.group(0), str(p.relative_to(root))[: -len(".uid")])

    for p in sorted(root.rglob("*.import")):
        if excluded(str(p.relative_to(root))):
            continue
        for m in UID_RE.finditer(p.read_bytes()):
            declare(m.group(1).decode("ascii"), str(p.relative_to(root))[: -len(".import")])

    targets = scan_files(root, (".tscn", ".tres"))
    for p in targets:
        rel = str(p.relative_to(root))
        line, rest = first_line(p)
        uid, err = parse_header(line)
        if err:
            # 头部异常（format!=3 / 非 gd_ 开头 / uid= 形态异常）一律零改动并显式报告
            rep.skipped.append(f"{rel}: {err}")
            continue
        if uid:
            declare(uid, rel)
        else:
            rep.missing.append(rel)
        # 使用处只扫正文（rest）：头部自身 uid 不算引用，让悬空/被引用计数保持真实语义
        for m in BODY_UID_RE.finditer(rest):
            uses.setdefault(m.group(1).decode("ascii"), rel)

    for u in sorted(decl):
        if len(decl[u]) > 1:
            rep.dups.append(f"{u}: 被多个资源声明 {sorted(decl[u])}")
    for r in sorted(res_uids):
        if len(res_uids[r]) > 1:
            rep.dups.append(f"{r}: 声明了多个 uid {sorted(res_uids[r])}")
    for u, src in sorted(uses.items()):
        if u not in decl:
            rep.dangling.append(f"{u} 被 {src} 引用，但全仓无定义（头部/侧车/import 均未登记）")

    missing_set = set(rep.missing)
    targets_missing = [p for p in targets if str(p.relative_to(root)) in missing_set]
    return rep, decl, uses, targets_missing, res_uids


def mint(root: Path, godot: str, count: int, taken: set[str]) -> list[str]:
    """调引擎官方 ResourceUID.create_id() 铸 count 个不与 taken 撞车的 uid 文本。"""
    script = root / "tools" / "backfill_resource_uids_mint.gd"
    out: list[str] = []
    batch = count
    while len(out) < count:
        need = batch + 16
        proc = subprocess.run(
            [godot, "--headless", "--path", str(root), "--script",
             "res://tools/backfill_resource_uids_mint.gd", "--", f"--count={need}"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
        got = [ln.strip() for ln in proc.stdout.splitlines()
               if re.fullmatch(r"uid://[0-9A-Za-z]+", ln.strip())]
        if len(got) < need:
            print(proc.stdout[-2000:], proc.stderr[-2000:], file=sys.stderr)
            raise RuntimeError(f"铸造不足: 请求数={need} 实得={len(got)}（godot 退出码 {proc.returncode}）")
        for u in got:
            if u not in taken:
                out.append(u)
                taken.add(u)
        if len(out) < count:
            batch = count - len(out)  # 极小概率撞车，按缺口重铸
    return out[:count]


def apply(root: Path, godot: str) -> int:
    rep, decl, _uses, targets, res_uids = collect(root)
    for line in rep.skipped:
        print(f"[skip] {line}")
    if not targets:
        print(f"APPLY: 无需补齐（缺失=0 重复={len(rep.dups)} 悬空={len(rep.dangling)}）")
        return 0 if rep.ok() else 1
    # 头部补齐的 uid 来源优先级：
    #   1. 侧车/import 已为该资源声明的 uid -> 原样采纳（引擎此前已分配，保持引用连续性）
    #   2. 无任何声明 -> 引擎官方 ResourceUID.create_id() 全新铸造
    #   3. 声明了多个 uid 的 -> 跳过报错，人工裁决
    plan: list[tuple[Path, str]] = []
    need_mint: list[Path] = []
    for p in targets:
        rel = str(p.relative_to(root))
        claimed = res_uids.get(rel, set())
        if len(claimed) == 1:
            plan.append((p, next(iter(claimed))))
            print(f"[=] {rel} -> {plan[-1][1]}（采纳侧车/import 既有声明）")
        elif len(claimed) > 1:
            rep.skipped.append(f"{rel}: 头部缺 uid 且侧车/import 声明了多个 uid {sorted(claimed)}，需人工裁决")
        else:
            need_mint.append(p)
    minted = iter(mint(root, godot, len(need_mint), set(decl)))
    plan.extend((p, next(minted)) for p in need_mint)
    for i, (p, uid) in enumerate(plan, 1):
        line, rest = first_line(p)
        new_line = insert_uid(line, uid)
        p.write_bytes(new_line + rest)  # 首行外字节原样回写
        if i <= 5 or i == len(plan):
            print(f"[+] {p.relative_to(root)} -> {uid}")
    print(f"APPLY: 补齐 {len(plan)} 个文件（采纳既有 {len(plan) - len(need_mint)} + 新铸 {len(need_mint)}）")
    rep2, decl2, _u2, targets2, _r2 = collect(root)
    if targets2 or not rep2.ok():
        print(f"复检未通过: 仍缺 {len(targets2)}, 重复 {len(rep2.dups)}, 悬空 {len(rep2.dangling)}, 跳过 {len(rep2.skipped)}", file=sys.stderr)
        for line in rep2.skipped:
            print(f"[skip] {line}", file=sys.stderr)
        return 1
    print(f"复检通过: 全仓定义 uid {len(decl2)} 个，缺失=0 重复=0 悬空=0")
    print("下一步: godot --headless --import 重建 uid_cache.bin，再跑 --verify。")
    return 0


def verify(root: Path, godot: str) -> int:
    rep, _decl, _uses, targets, _res_uids = collect(root)
    for line in rep.skipped:
        print(f"[skip] {line}")
    tscn = sum(1 for p in scan_files(root, (".tscn",)) )
    tres = sum(1 for p in scan_files(root, (".tres",)) )
    print(f"VERIFY(python): tscn={tscn} tres={tres} 缺失={len(rep.missing)} 重复={len(rep.dups)} 悬空={len(rep.dangling)}")
    for line in rep.missing:
        print(f"[缺] {line}")
    for line in rep.dups + rep.dangling:
        print(f"[!] {line}")
    if targets:
        return 1
    print("VERIFY(godot): 调 verify_resource_uids.gd 校验 uid_cache 一致性与 ext_resource 解析…")
    proc = subprocess.run(
        [godot, "--headless", "--path", str(root), "--script", "res://tools/verify_resource_uids.gd"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
    tail = (proc.stdout + proc.stderr).strip().splitlines()
    for ln in tail[-40:]:
        print(f"  {ln}")
    if proc.returncode != 0:
        print("VERIFY(godot): 失败（退出码 %d）" % proc.returncode)
        return 1
    print("VERIFY: 全部通过（缺失=0 重复=0 悬空=0 缓存一致）")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="场景/资源 UID 补齐与自验收")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent),
                    help="res:// 根（默认 stick-world/，即本脚本上级目录）")
    ap.add_argument("--godot", default=os.environ.get("GODOT_BIN", DEFAULT_GODOT), help="godot 可执行路径")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="只报告，不写入")
    mode.add_argument("--apply", action="store_true", help="补齐缺失 uid")
    mode.add_argument("--verify", action="store_true", help="补齐后自验收（文本+引擎缓存）")
    args = ap.parse_args()
    root = Path(args.root).resolve()

    if args.check:
        rep, _decl, _uses, _targets, _res_uids = collect(root)
        for line in rep.skipped:
            print(f"[skip] {line}")
        print(f"CHECK: tscn={sum(1 for p in scan_files(root, ('.tscn',)))} "
              f"tres={sum(1 for p in scan_files(root, ('.tres',)))} "
              f"缺失={len(rep.missing)} 重复={len(rep.dups)} 悬空={len(rep.dangling)} "
              f"定义uid总数={len(_decl)} 被引用uid数={len(_uses)}")
        for rel in rep.missing:
            print(f"[缺] {rel}")
        for line in rep.dups + rep.dangling:
            print(f"[!] {line}")
        return 0 if rep.ok() else 1
    if args.apply:
        return apply(root, args.godot)
    return verify(root, args.godot)


if __name__ == "__main__":
    sys.exit(main())
