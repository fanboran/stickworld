#!/usr/bin/env python3
"""自对弈 Benchmark 并行编排器 —— 每场一个无头 Godot 进程，纯后台计算多核并行。

并行与剥视觉口径（创始人 2026-09-30 定）：并行模拟、剔除一切视觉、只装需要的
代码——Godot 侧由 char_sprite_3d 的 headless 豁免（不装配 billboard 视觉链）+
--headless 无 GPU + battle_sim 批模拟内核共同保证；本脚本负责进程级并行与汇总。

用法（Git Bash / PowerShell 均可）:
  python run_parallel.py --battles 8 \
      --brain-a res://tests/dev/benchmark_brains/my_v2.gd \
      [--brain-b res://tests/dev/benchmark_brains/incumbent.gd] \
      [--jobs 6] [--timeout 600]

规则：半数场次挑战者在攻方(左)、半数在守方(右)消除占位偏差；
胜负 = 有效战力先归零方负（超时按剩余战力判，差≤10%平）；
稳定战胜线 65%，过线挑战者接替卫冕者。
"""
import argparse
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

DEFAULT_GODOT = r"F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
DEFAULT_PROJECT = r"F:\VSCode\game-2\.temp\观察场AI\stick-world"
WIN_LINE = 0.65


def run_one(i: int, total: int, a: argparse.Namespace) -> dict:
    side = i % 2  # 0=挑战者在攻方(左)，1=在守方(右)
    out = a.results / f"battle_{i:02d}_of_{total:02d}.json"
    cmd = [
        a.godot, "--headless", "--path", a.project,
        "res://tests/dev/diag_arena_benchmark_shots.tscn", "--",
        f"--index={i}", f"--side={side}",
        f"--brain-a={a.brain_a or ''}", f"--brain-b={a.brain_b or ''}",
        f"--out={out.as_posix()}",
    ]
    try:
        subprocess.run(cmd, capture_output=True, text=True, timeout=a.timeout)
    except subprocess.TimeoutExpired:
        return {"winner": "timeout", "a_side": side, "duration_s": a.timeout,
                "str_a": 0, "str_b": 0}
    if out.exists():
        try:
            return json.loads(out.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    return {"winner": "error", "a_side": side, "duration_s": 0.0, "str_a": 0, "str_b": 0}


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    p = argparse.ArgumentParser(description="自对弈 Benchmark 并行编排器")
    p.add_argument("--battles", type=int, default=8, help="总场次（自动对半换边）")
    p.add_argument("--brain-a", default="", help="挑战者脚本 res:// 路径（空=内嵌默认AI自检）")
    p.add_argument("--brain-b", default="", help="卫冕者脚本 res:// 路径（空=内嵌默认AI）")
    p.add_argument("--godot", default=DEFAULT_GODOT)
    p.add_argument("--project", default=DEFAULT_PROJECT)
    p.add_argument("--jobs", type=int, default=0, help="并行进程数（默认=CPU核数）")
    p.add_argument("--timeout", type=int, default=600, help="单场超时秒")
    p.add_argument("--results", default="", help="JSON 结果目录（默认 stick-world/temp/bench_results）")
    a = p.parse_args()

    results_dir = Path(a.results) if a.results else Path(a.project) / "temp" / "bench_results"
    results_dir.mkdir(parents=True, exist_ok=True)
    a.results = results_dir
    jobs = a.jobs or __import__("os").cpu_count() or 4

    label_a = Path(a.brain_a).stem if a.brain_a else "内嵌默认AI"
    label_b = Path(a.brain_b).stem if a.brain_b else "内嵌默认AI"
    print(f"[Bench] === {label_a} vs {label_b}：{a.battles} 场换边轮换，{jobs} 进程并行 ===")

    results = []
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = {pool.submit(run_one, i, a.battles, a): i for i in range(a.battles)}
        for fut in as_completed(futs):
            r = fut.result()
            results.append(r)
            side = "攻方" if r["a_side"] == 0 else "守方"
            print(f"[Bench] 第{r.get('index', futs[fut])}场 A在{side}：{r['winner']} 胜"
                  f"（{r['duration_s']:.0f}s，战力 {r['str_a']}:{r['str_b']}）")

    wins_a = sum(1 for r in results if r["winner"] == "A")
    wins_b = sum(1 for r in results if r["winner"] == "B")
    draws = sum(1 for r in results if r["winner"] == "draw")
    bad = sum(1 for r in results if r["winner"] in ("error", "timeout"))
    total = len(results)
    print(f"[Bench] === 总分：挑战者A {wins_a} 胜 / 卫冕者B {wins_b} 胜 / 平 {draws}"
          f" / 无效 {bad}（共 {total} 场）===")

    # 左右占位偏置体检（创始人要求：占位不得影响胜率）
    for side, tag in ((0, "攻方(左)"), (1, "守方(右)")):
        games = [r for r in results if r["a_side"] == side and r["winner"] != "draw"]
        if games:
            rate = sum(1 for r in games if r["winner"] == "A") / len(games)
            print(f"[Bench] A在{tag}时胜率 {rate * 100:.0f}%（{len(games)} 场分胜负）")

    if not a.brain_a:
        print("[Bench] 基线自检模式：胜差应接近各半，偏离大 = 左右占位或先手不平衡")
        return 0
    if bad:
        print("[Bench] 存在无效场次，结果不可信，先修再判")
        return 1
    rate = wins_a / max(total, 1)
    ok = rate >= WIN_LINE
    print(f"[Bench] 挑战者胜率 {rate * 100:.0f}%，稳定战胜线 {WIN_LINE * 100:.0f}% → "
          f"{'✅ 迭代通过，接替卫冕者（登记进 benchmark_brains/README.md 卫冕者表）' if ok else '❌ 迭代不通过，继续调'}")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
