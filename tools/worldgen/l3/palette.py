"""政权调色板（观感返工第三批 C23：80 国色板重设计）。

设计取向（美术优先，保留「相邻国可区分」的功能底线）：
  - 在 **OKLCH 感知均匀空间** 里取「等色相环 × 明度档」网格：
    色相环 16 等分（22.5°）承载「同族/异族」直觉，明度 6 档（ΔL≈0.06）承载
    「同族深浅变体」——所有候选**同彩度区间（低饱和）**，因此整图色调协调，
    不会出现「某几国特别艳、其余发灰」的拼贴感（旧 CONTENT_PALETTE 派生色的问题）。
  - 彩色数量多于政权数（16×6=96 > 80），留给贪心图着色挑选余地；
  - 分配用**OKLab ΔE** 判相邻可区分（比 HSL 色相差更贴近人眼）：
    相邻国 ΔE ≥ min_delta_e（默认 0.105 ≈ 5 个 JND），不满足即计罚。

本模块被两个工具共用，保证「重跑生成器」与「只重排颜色」结果一致：
  - state_expand_lite.py（全量重跑政权）
  - state_recolor.py（只按现有领土邻接重排颜色，不动领土/命名）
"""

import math

# OKLab <-> sRGB（Björn Ottosson 的参考矩阵，线性 sRGB 空间）
_M1 = (
    (0.4122214708, 0.5363325363, 0.0514459929),
    (0.2119034982, 0.6806995451, 0.1073969566),
    (0.0883024619, 0.2817188376, 0.6299787005),
)


def _gamma(u: float) -> float:
    """线性 sRGB → 显示 sRGB（BT.709 传输曲线）"""
    u = min(max(u, 0.0), 1.0)
    if u <= 0.0031308:
        return 12.92 * u
    return 1.055 * (u ** (1.0 / 2.4)) - 0.055


def oklch_to_oklab(lightness: float, chroma: float, hue_deg: float):
    """(L, C, h) → (L, a, b)"""
    h = math.radians(hue_deg)
    return lightness, chroma * math.cos(h), chroma * math.sin(h)


def oklab_to_rgb(lightness: float, a: float, b: float):
    """(L, a, b) → 0..255 的 (r, g, b) 整数元组"""
    l_ = lightness + 0.3963377774 * a + 0.2158037573 * b
    m_ = lightness - 0.1055613458 * a - 0.0638541728 * b
    s_ = lightness - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return (int(round(_gamma(r) * 255.0)),
            int(round(_gamma(g) * 255.0)),
            int(round(_gamma(bb) * 255.0)))


def delta_e(lab_a, lab_b) -> float:
    """OKLab 欧氏距离（≈ 感知色差，0.02 约 1 个 JND）"""
    return math.sqrt(sum((lab_a[i] - lab_b[i]) ** 2 for i in range(3)))


def build_candidates(spec: dict):
    """按参数表 colors 段生成候选色列表。

    spec = {"hue_count": 16, "hue_offset_deg": 11.25,
            "tiers": [{"l": 0.815, "c": 0.038}, ...]}
    返回项：{hue, tier, L, C, lab, rgb}
    """
    n_hue = int(spec.get("hue_count", 16))
    offset = float(spec.get("hue_offset_deg", 0.0))
    tiers = spec.get("tiers", [])
    out = []
    for ti, tier in enumerate(tiers):
        lightness = float(tier["l"])
        chroma = float(tier["c"])
        for hi in range(n_hue):
            hue = (offset + 360.0 * hi / n_hue) % 360.0
            lab = oklch_to_oklab(lightness, chroma, hue)
            out.append({
                "hue": hi, "tier": ti, "L": lightness, "C": chroma,
                "lab": lab, "rgb": oklab_to_rgb(*lab),
            })
    return out


def label_adjacency(tiles, label_to_sid):
    """城块共享边 → 政权邻接表（与 GDScript MapSketch.edge_key 同口径 0.25px 量化）。

    tiles = [{"label": int, "polygons": [[[y, x], ...], ...]}]；
    返回 {sid: set(sid)}（无归属/未知 label 忽略）。
    """
    by_edge = {}
    for t in tiles:
        lb = int(t.get("label", 0))
        if lb <= 0:
            continue
        for poly in t.get("polygons", []):
            n = len(poly)
            if n < 3:
                continue
            pts = [(int(round(float(p[0]) * 4)), int(round(float(p[1]) * 4)))
                   for p in poly]
            for i in range(n):
                a, b = pts[i], pts[(i + 1) % n]
                key = (a, b) if a <= b else (b, a)
                got = by_edge.get(key)
                if got is None:
                    by_edge[key] = {lb}
                else:
                    got.add(lb)
    neighbors = {}
    for label_set in by_edge.values():
        if len(label_set) < 2:
            continue
        sids = {label_to_sid.get(lb) for lb in label_set}
        sids.discard(None)
        if len(sids) < 2:
            continue
        for sid in sids:
            neighbors.setdefault(sid, set()).update(sids - {sid})
    return neighbors


def assign_from_tiles(candidates, tiles, label_to_sid, sizes, min_delta_e):
    """按城块邻接一次性给全部政权配色（生成器与 recolor 工具共用，结果逐位一致）。

    sizes = {sid: 城数}，决定分配次序（大国先占色，与小国可选余地更大的直觉一致；
    次序 tie-break 用 state_id 字典序 → 两端确定性一致）。
    """
    neighbors = label_adjacency(tiles, label_to_sid)
    order = sorted(sizes.keys(), key=lambda s: (-sizes.get(s, 0), s))
    return assign_colors(candidates, order, neighbors, min_delta_e)


def _coprime_stride(n: int) -> int:
    """与 n 互质的最大整数（< n/2）——用作轮转步长，让连续取值跨越整个环"""
    for s in range(max(n // 2, 1), 1, -1):
        if math.gcd(s, n) == 1:
            return s
    return 1


def assign_colors(candidates, order, neighbors, min_delta_e):
    """贪心分配：按 order（大国优先）逐国取色。

    选色键 = (违反量, 该明度档已用次数, 该候选已用次数, 轮转次序) 字典序取最小：
      1. **违反量**（硬约束优先）= Σ_相邻已分配国 max(0, min_delta_e − ΔE)² ——
         只要存在「不与任何已分配邻居撞色」的候选，就一定要用它；
      2. **明度档已用次数**——防止大国把最亮的档全占掉（否则整图偏白/偏灰，
         各档均匀铺开才是协调观感）；
      3. **候选已用次数**——同一颜色尽量不复用（候选多于政权数）；
      4. 轮转次序 (hue, tier) 随分配步数同相旋转——同色相/同明度不扎堆。
    """
    n_hue = (max(c["hue"] for c in candidates) + 1) if candidates else 1
    n_tier = (max(c["tier"] for c in candidates) + 1) if candidates else 1
    # 轮转步长取「与环长互质的最大数」：相邻两次分配跨半个色轮跳，
    # 避免「大国依次拿到相邻色相」拼出渐变带（feedback2 E 的绿渐变梯教训）
    h_stride = _coprime_stride(n_hue)
    t_stride = _coprime_stride(n_tier)
    assigned = {}
    use_count = {}
    tier_use = {}
    step = 0
    for sid in order:
        nbr_items = [assigned[s] for s in neighbors.get(sid, ()) if s in assigned]
        rot = [
            ((c["hue"] + step * h_stride) % n_hue,
             (c["tier"] + step * t_stride) % n_tier, pi)
            for pi, c in enumerate(candidates)
        ]
        rot.sort(key=lambda r: (r[0], r[1], r[2]))
        rot_rank = {r[2]: i for i, r in enumerate(rot)}
        step += 1
        best_pi, best_key = None, None
        for pi, p in enumerate(candidates):
            viol = 0.0
            for q in nbr_items:
                de = delta_e(p["lab"], q["lab"])
                if de < min_delta_e:
                    viol += (min_delta_e - de) ** 2
            key = (viol, tier_use.get(p["tier"], 0), use_count.get(pi, 0), rot_rank[pi])
            if best_key is None or key < best_key:
                best_pi, best_key = pi, key
        assigned[sid] = candidates[best_pi]
        use_count[best_pi] = use_count.get(best_pi, 0) + 1
        tier_use[candidates[best_pi]["tier"]] = \
            tier_use.get(candidates[best_pi]["tier"], 0) + 1
    conflicts = []
    for sid, nbrs in neighbors.items():
        for nb in nbrs:
            if nb not in assigned or sid >= nb:
                continue
            if delta_e(assigned[sid]["lab"], assigned[nb]["lab"]) < min_delta_e:
                conflicts.append((sid, nb))
    return assigned, conflicts