"""population_score 补齐（总体设计 §5.7 / C3，纯数据项）

对既有 config JSON 就地补充 population_score 字段（确定性纯函数，不改几何）：
  - l1_world.json 8 城邦：level 已知，按同级别内面积分位映射到级别分数带
  - l3_city.json 1040 城：无级别，按 2048 归一面积分位派生级别（p85+ → T3，
    p55+ → T2，其余 T1），再同级别内按面积分位映射分数带

分数带（对齐 §5.7 blob 的 T1-T5 base 半径梯度）：
  T1 0.15~0.35 / T2 0.35~0.55 / T3 0.55~0.80 / T4 0.80~0.95 / T5 0.95~1.0

每局 ±15% 扰动在运行时装配侧做（SettlementRef.jitter_population_score，
出生聚落免疫），本工具只写基准值。
"""

import json
import os

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))),
                          "stick-world", "config", "strategic_map")

LEVEL_BANDS = {
    1: (0.15, 0.35),
    2: (0.35, 0.55),
    3: (0.55, 0.80),
    4: (0.80, 0.95),
    5: (0.95, 1.0),
}


def band_score(level: int, percentile: float) -> float:
    lo, hi = LEVEL_BANDS[level]
    return round(lo + (hi - lo) * percentile, 4)


def percentile_in_level(items: list, level_key: str, area_key: str) -> dict:
    """同级别内按面积升序的分位（0~1）。同级 1 个元素 → 0.5。返回 id → 分位。"""
    groups: dict = {}
    for it in items:
        groups.setdefault(it[level_key], []).append(it)
    out = {}
    for _, members in groups.items():
        members.sort(key=lambda x: x[area_key])
        n = len(members)
        for rank, m in enumerate(members):
            out[m["key"]] = 0.5 if n == 1 else rank / (n - 1)
    return out


def main():
    # --- l1_world.json：8 城邦（level 已知，area_px 已是 2048 归一） ---
    p1 = os.path.join(CONFIG_DIR, "l1_world.json")
    d1 = json.load(open(p1, encoding="utf-8"))
    items = []
    for t in d1["tiles"]:
        s = t.get("settlement")
        if not s:
            continue
        items.append({"key": s["settlement_id"], "level": int(s.get("level", 1)), "area": float(t["area_px"])})
    pct = percentile_in_level(items, "level", "area")
    for t in d1["tiles"]:
        s = t.get("settlement")
        if not s:
            continue
        s["population_score"] = band_score(int(s.get("level", 1)), pct[s["settlement_id"]])
    json.dump(d1, open(p1, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"l1_world.json: {len(items)} 聚落 population_score 已写入")

    # --- l3_city.json：1040 城（无级别 → 面积分位派生 T1/T2/T3） ---
    p2 = os.path.join(CONFIG_DIR, "l3_city.json")
    d2 = json.load(open(p2, encoding="utf-8"))
    areas = sorted(t["area_px"] / 16.0 for t in d2["tiles"])  # 8192 → 2048 归一
    def q(p):
        return areas[min(len(areas) - 1, int(p * len(areas)))]
    t2_cut, t3_cut = q(0.55), q(0.85)
    items = []
    for t in d2["tiles"]:
        a2048 = t["area_px"] / 16.0
        level = 3 if a2048 >= t3_cut else (2 if a2048 >= t2_cut else 1)
        t["level"] = level
        items.append({"key": t["label"], "level": level, "area": a2048})
    pct2 = percentile_in_level(items, "level", "area")
    for t in d2["tiles"]:
        t["population_score"] = band_score(t["level"], pct2[t["label"]])
    json.dump(d2, open(p2, "w", encoding="utf-8"), ensure_ascii=False)
    n = {lv: sum(1 for it in items if it["level"] == lv) for lv in (1, 2, 3)}
    print(f"l3_city.json: {len(items)} 城（T1 {n[1]} / T2 {n[2]} / T3 {n[3]}，面积分位裁 p55={t2_cut:.0f} p85={t3_cut:.0f}@2048）")


if __name__ == "__main__":
    main()
