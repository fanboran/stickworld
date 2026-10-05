#!/usr/bin/env python3
"""RL 训练进度监控 —— 滑动均值判定"练成没"（稳定战胜线 0.65）。
零介入：只读 CSV，不碰训练进程。用法：python rl_monitor.py [窗口数]"""
import csv
import json
import os
import sys

RL_DIR = os.path.expandvars(r"%APPDATA%\Godot\app_userdata\火柴人帝国模拟\rl")
WIN_LINE = 0.65

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def main() -> int:
    window = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    eval_csv = os.path.join(RL_DIR, "eval_log_cpp.csv")
    train_csv = os.path.join(RL_DIR, "train_log_cpp.csv")
    if not os.path.exists(eval_csv):
        print("eval_log_cpp.csv 不存在")
        return 1
    rows = list(csv.DictReader(open(eval_csv, encoding="utf-8")))
    if not rows:
        print("评估曲线为空")
        return 1
    iters = [int(r[list(rows[0].keys())[0]]) for r in rows]
    rates = [float(r[list(rows[0].keys())[3]]) for r in rows]
    print(f"评估点总数 {len(rows)}，最新 iter={iters[-1]}")
    # 滑动均值序列（窗口=window 个评估点）
    tail = rates[-window:]
    mean = sum(tail) / len(tail)
    print(f"近 {len(tail)} 次评估均值 = {mean:.3f}（区间 {min(tail):.2f}~{max(tail):.2f}）")
    # 全程分段趋势（四等分）
    seg = max(len(rates) // 4, 1)
    for i in range(4):
        chunk = rates[i * seg:(i + 1) * seg] if i < 3 else rates[3 * seg:]
        if chunk:
            print(f"  四分位{i+1}（iter≈{iters[i*seg]}~）均值 {sum(chunk)/len(chunk):.3f}")
    verdict = "✅ 过稳定战胜线" if mean >= WIN_LINE else "未过线（继续训/继续调）"
    print(f"判定：{verdict}（线 {WIN_LINE}）")
    if os.path.exists(train_csv):
        with open(train_csv, encoding="utf-8") as f:
            last = f.readlines()[-1].split(",")
        print(f"训练最新 iter={last[0]} 熵H={last[6]} 温度T={last[7]}", flush=True)
    # 状态导出（给调度器/面板消费）
    state = {"latest_iter": iters[-1], "window": window, "mean_rate": round(mean, 4),
             "pass_line": bool(mean >= WIN_LINE)}
    out = os.path.join(RL_DIR, "monitor_state.json")
    json.dump(state, open(out, "w", encoding="utf-8"))
    print(f"状态已写 {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
