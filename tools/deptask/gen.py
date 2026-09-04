#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""任务依赖图工具 v3 —— 纯文本源 → 校验 → 交互式可视化（单文件 HTML，离线可用）。

可读性方案（对标 ComfyUI / Unity Shader Graph，经 litegraph.js 源码核实）：
  1. 布局交给 dagre（mermaid 底层引擎，MIT，已 vendor 至 web/vendor/dagre.min.js 内联进 HTML）：
     层式 rank + barycenter 交叉最小化 + 坐标对齐——手搓最长路径分层缺交叉最小化是 v1/v2 混乱的根因。
  2. 边端口对端口：输入挂卡片左缘、输出挂右缘（按对端 y 排序均匀分布），从不连"卡片中心"。
  3. 贝塞尔控制点 = 端口方向 × 0.25×间距（litegraph renderLink SPLINE_LINK 的 G=.25*q 公式），
     输出向右出、输入从左入——水平切线约束让所有边同向流动。
  4. 泳道不再用刚性列，改为 ComfyUI 式分组框（lane 色底框 + 标签）。
  5. 高分屏 devicePixelRatio 渲染、卡片自适应宽度+两行换行、默认 100% 缩放锚定活跃区。

源文件语法（一行一记录，# 开头为注释，全角竖线 | 分隔字段）：

    线序: 主线, UI线, ...                  # 泳道（分组框）顺序
    任务 <id> | 名称=... | 线=... | 状态=... | [前置=a,b] | [域=...] | [树=...] | [位置=x,y] | [豁免=1] | [文档=...] | [级=微] | [注=...]
    （级=微：几轮可完成的随手挂载项，画布矮卡、豁免无后沿/阻塞无因审计；
      前置含自身=自复验回路（审计/复验类任务），合法且不算未完成前置）
    里程碑 <id> | ...                      # 同任务，卡片带 ◆
    <a> -> <b>                             # a 是 b 的前置：a 完成前 b 不得开工

状态：完成 / 待验收 / 进行中 / 可开工 / 阻塞 / 冻结 / 放弃
状态语义（调度模型）：
  可开工  = 前置已全部完成、协调者可立即派活（由 DAG 派生，不是手填愿望）
  阻塞    = 前置未齐（阻塞无因 = ERROR；前置齐却标阻塞 = W 状态滞后）
             外部依赖（美术资产/创始人窗口等）建显式门节点承载，不用"阻塞"空挂
  冻结    = 有意延后（冻结令/占位），前置可有可无但须注说明
  域=     文件域 token，供并行冲突检测——同域互斥是**调度约束**不是依赖，
             先后由协调者派活时裁决，不得写成 前置=

校验规则（--check 退出码 1 = 有 ERROR）：
  E 悬空引用 / 环 / 重复 id
  E 派活违规   可开工/进行中/待验收/完成 的任务存在未完成前置且无 豁免=1（派活闸门）
  W 状态滞后   状态=阻塞 但前置已全部完成（应改 可开工，或补真实前置/挂外部门）
  W 冗余前置   前置可经其它前置传递到达（图保持最小，假深度会误导读图与调度）
  W 域冲突     两个 进行中 任务声明了相同 域 token（合并冲突热点）
  W 未知泳道   线= 不在 线序 里
  W 无后沿     未完成且无消费方（launch 后代=终局交付，豁免）

调度报告（每次运行输出，铁路调度模型）：
  就绪集        前置全齐、可立即派活的任务（按线分组）
  建议派活组合  就绪集内按关键路径优先 + 域互斥贪心选出的并行组合（≤ 并行线上限）
  波次          未完成子图拓扑分层（波 n = 最少还要等 n 道串行工序）
  关键路径      最长链（加并发只能压非关键路径，关键路径要靠拆依赖/拆任务）

布局：源里没有任何 位置= 时，页面用 dagre 自动布局；「⬇ 导出源」把当前坐标连同
状态/依赖编辑写进导出的源文件（覆盖源 txt 即冻结为手动布局）；页面「自动重排」可清掉回 dagre。
位置=x,y 单位为世界像素。

用法：
  python tools/deptask/gen.py                 # 校验 + 调度报告 + 生成 docs/项目/任务依赖图.html
  python tools/deptask/gen.py --check         # 只校验 + 调度报告（不生成）
  python tools/deptask/gen.py --lanes 8       # 建议派活组合的并行线上限（默认 6）
"""
import argparse
import json
import re
import sys
from pathlib import Path

STATUSES = ["完成", "待验收", "进行中", "可开工", "阻塞", "冻结", "放弃"]
ACTIVE = {"进行中", "待验收", "完成"}
FIELDS = {"名称", "线", "状态", "前置", "域", "树", "位置", "豁免", "注", "文档", "级", "认领"}


def parse(src: str):
    nodes, edges, lane_order, errors, clusters = {}, [], [], [], []
    for ln, raw in enumerate(src.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("线序:"):
            lane_order = [x.strip() for x in line[3:].split(",") if x.strip()]
            continue
        if line.startswith("分割线:"):
            try:
                globals()["_divide_hint"] = float(line[4:].strip())
            except ValueError:
                pass
            continue
        m = re.match(r"^(\S+)\s*->\s*(\S+)$", line)
        if m:
            edges.append({"a": m.group(1), "b": m.group(2), "line": ln})
            continue
        m = re.match(r"^(任务|里程碑|簇)\s+(\S+)\s*(?:\|(.*))?$", line)
        if not m:
            errors.append(("E", ln, f"无法解析的行: {line[:60]}"))
            continue
        kind, nid, rest = m.group(1), m.group(2), m.group(3) or ""
        if kind == "簇":
            cl = {"id": nid, "kind": kind, "name": nid, "members": [], "note": "",
                  "folded": False, "line": ln}
            for kv in (rest or "").split("|"):
                if "=" not in kv:
                    errors.append(("E", ln, f"簇 {nid}: 字段缺 '=': {kv.strip()}"))
                    continue
                k, v = kv.split("=", 1)
                k, v = k.strip(), v.strip()
                if k == "名称":
                    cl["name"] = v
                elif k == "成员":
                    cl["members"] = [x.strip() for x in v.split(",") if x.strip()]
                elif k == "折叠":
                    cl["folded"] = v in ("1", "true", "是")
                elif k == "注":
                    cl["note"] = v
                else:
                    errors.append(("W", ln, f"簇 {nid}: 未知字段 {k}（可用: 名称/成员/折叠/注）"))
            if not cl["members"]:
                errors.append(("E", ln, f"簇 {nid}: 没有成员"))
            clusters.append(cl)
            continue
        node = {"id": nid, "kind": kind, "name": nid, "lane": "", "status": "可开工",
                "prs": [], "domain": [], "tree": "", "note": "", "pos": None,
                "exempt": False, "doc": "", "tier": "", "claim": "", "line": ln}
        for kv in rest.split("|"):
            if "=" not in kv:
                errors.append(("E", ln, f"{nid}: 字段缺 '=': {kv.strip()}"))
                continue
            k, v = kv.split("=", 1)
            k, v = k.strip(), v.strip()
            if k == "名称":
                node["name"] = v
            elif k == "线":
                node["lane"] = v
            elif k == "状态":
                if v not in STATUSES:
                    errors.append(("E", ln, f"{nid}: 未知状态 {v}"))
                node["status"] = v
            elif k == "前置":
                node["prs"] = [x.strip() for x in v.split(",") if x.strip()]
            elif k == "域":
                node["domain"] = [x.strip() for x in re.split(r"[,;]", v) if x.strip()]
            elif k == "树":
                node["tree"] = v
            elif k == "位置":
                try:
                    x, y = v.split(",")
                    node["pos"] = [float(x), float(y)]
                except ValueError:
                    errors.append(("E", ln, f"{nid}: 位置格式应为 x,y"))
            elif k == "豁免":
                node["exempt"] = v in ("1", "true", "是")
            elif k == "注":
                node["note"] = v
            elif k == "文档":
                node["doc"] = v
            elif k == "级":
                node["tier"] = v
            elif k == "认领":
                node["claim"] = v
            else:
                errors.append(("W", ln, f"{nid}: 未知字段 {k}（可用: {'/'.join(sorted(FIELDS))}）"))
        if nid in nodes:
            errors.append(("E", ln, f"重复 id: {nid}"))
        else:
            nodes[nid] = node
    return nodes, edges, lane_order, errors, clusters, globals().get("_divide_hint")


def _closure(start_sets, nodes):
    """从若干起点沿前置方向求传递闭包（全部祖先）。"""
    seen, st = set(), list(start_sets)
    while st:
        q = st.pop()
        if q in seen or q not in nodes:
            continue
        seen.add(q)
        st.extend(nodes[q]["prs"])
    return seen


def redundant_edges(nodes):
    """传递约简：前置 a→b 若可经 b 的其它前置传递到达，则 a→b 冗余。"""
    red = set()
    for nid, n in nodes.items():
        ps = [p for p in n["prs"] if p in nodes and p != nid]  # 自环不参与冗余判定
        if len(ps) < 2:
            continue
        anc = {p: _closure(nodes[p]["prs"], nodes) for p in ps}
        for a in ps:
            if any(a in anc[p2] for p2 in ps if p2 != a):
                red.add((a, nid))
    return red


def descendants_of(nid, nodes):
    """沿"被依赖"方向求全部后代（依赖 nid 的任务，传递）。"""
    succ = {}
    for n in nodes.values():
        for p in n["prs"]:
            succ.setdefault(p, []).append(n["id"])
    seen, st = set(), [nid]
    while st:
        for b in succ.get(st.pop(), []):
            if b not in seen:
                seen.add(b)
                st.append(b)
    return seen


def wave_levels(nodes):
    """未完成子图拓扑分层：波 0 = 前置全齐（就绪）；波 n = 最少还要等 n 道串行工序。
    Kahn 拓扑排序 O(V+E)——环内节点 indeg 永不归零，自然落波 0（环由 validate 报 ERROR）。"""
    from collections import deque
    done = {i for i, n in nodes.items() if n["status"] == "完成"}
    pend = {i for i, n in nodes.items() if n["status"] not in ("完成", "放弃")}
    indeg = {}
    children = {}
    for i in pend:
        ps = [q for q in nodes[i]["prs"] if q in pend]
        indeg[i] = len(ps)
        for q in ps:
            children.setdefault(q, []).append(i)
    level = {}
    dq = deque(i for i in pend if indeg[i] == 0)
    for i in dq:
        level[i] = 0
    while dq:
        x = dq.popleft()
        for c in children.get(x, []):
            indeg[c] -= 1
            if level.get(c, -1) < level[x] + 1:
                level[c] = level[x] + 1
            if indeg[c] == 0:
                dq.append(c)
    for i in pend:
        level.setdefault(i, 0)  # 环残留
    return {i: level[i] for i in pend}


def critical_path(nodes):
    """未完成子图最长链（按边数），返回 [端, …, 起点]（起点在前）。
    visited 防护：环（自环/互环）会让链回走打转——遇已访问节点即停（环由 validate 报 ERROR）。"""
    lv = wave_levels(nodes)
    if not lv:
        return []
    done = {i for i, n in nodes.items() if n["status"] == "完成"}
    tail = max(lv, key=lambda i: lv[i])
    chain, cur, visited = [], tail, set()
    while lv.get(cur, 0) > 0 and cur not in visited:
        visited.add(cur)
        chain.append(cur)
        unmet = [p for p in nodes[cur]["prs"] if p in nodes and p not in done]
        if not unmet:
            break
        cur = max(unmet, key=lambda p: lv.get(p, 0))
    chain.append(cur)
    return list(reversed(chain))


def ready_set(nodes):
    """就绪集：未完成、未冻结、未放弃、前置全齐——协调者可立即派活的全集。"""
    done = {i for i, n in nodes.items() if n["status"] == "完成"}
    out = []
    for i, n in nodes.items():
        if n["status"] in ("完成", "冻结", "放弃"):
            continue
        if all(p in done for p in n["prs"] if p != n["id"]):
            out.append(i)
    return out


def dispatch_suggestion(nodes, ready, crit, limit=6):
    """建议派活组合：关键路径优先 + 域互斥贪心（空域视作全域冲突，保守不并行）。"""
    crit_set = set(crit)
    order = sorted(ready, key=lambda i: (i not in crit_set, -len(descendants_of(i, nodes))))
    picked, used = [], set()
    for i in order:
        dom = set(nodes[i]["domain"])
        if not dom:
            continue  # 无域声明=范围不明，保守不进组合（可派，但需协调者先补域）
        if dom & used:
            continue
        used |= dom
        picked.append(i)
        if len(picked) >= limit:
            break
    return picked


def schedule_report(nodes, limit=6):
    """铁路调度报告：就绪集 / 状态滞后 / 波次 / 关键路径 / 建议派活组合。"""
    done = {i for i, n in nodes.items() if n["status"] == "完成"}
    ready = ready_set(nodes)
    crit = critical_path(nodes)
    lines = ["—— 调度报告 ——"]

    by_lane = {}
    for i in ready:
        by_lane.setdefault(nodes[i]["lane"] or "（无线）", []).append(i)
    lines.append(f"就绪集 {len(ready)} 个（前置全齐，可立即派活；按线分组）：")
    for lane in sorted(by_lane, key=lambda l: -len(by_lane[l])):
        ids = sorted(by_lane[lane])
        lines.append(f"  [{lane}] {len(ids)}: {' '.join(ids)}")

    stale = [i for i in ready if nodes[i]["status"] == "阻塞" and not nodes[i]["exempt"]]
    if stale:
        lines.append(f"状态滞后 {len(stale)} 个（前置齐但标阻塞，见 W——改 可开工 或补真实前置）")

    lv = wave_levels(nodes)
    waves = {}
    for i, l in lv.items():
        waves.setdefault(l, []).append(i)
    if waves:
        ws = " · ".join(f"波{k}={len(waves[k])}" for k in sorted(waves))
        lines.append(f"波次（未完成子图，波 n=最少还要等 n 道串行工序）：{ws}")
    if crit:
        lines.append(f"关键路径（{len(crit) - 1} 跳）：{' → '.join(crit)}")

    picked = dispatch_suggestion(nodes, ready, crit, limit)
    if picked:
        desc = "，".join(f"{i}（{nodes[i]['lane']}）" for i in picked)
        lines.append(f"建议派活组合（关键路径优先+域互斥，≤{limit} 并行线）：{desc}")
    return "\n".join(lines), ready, crit


def validate(nodes, edges, lane_order, clusters):
    errs, warns = [], []
    ids = set(nodes)
    for e in edges:
        for end in (e["a"], e["b"]):
            if end not in ids:
                errs.append(f"E 行{e['line']}: 悬空引用 {end}")
    for n in nodes.values():
        for p in n["prs"]:
            if p not in ids:
                errs.append(f"E 行{n['line']}: {n['id']} 前置 {p} 未定义")
        if n["lane"] and lane_order and n["lane"] not in lane_order:
            warns.append(f"W 行{n['line']}: {n['id']} 泳道 {n['lane']} 不在 线序")

    adj = {i: [p for p in nodes[i]["prs"] if p in nodes and p != i] for i in nodes}  # 自环=自复验
    color = {i: 0 for i in adj}
    reported = set()
    for start in adj:
        if color[start]:
            continue
        stack = [(start, iter(adj[start]))]
        color[start] = 1
        while stack:
            node_id, it = stack[-1]
            nxt = None
            for child in it:
                if color[child] == 1:
                    if child not in reported:
                        reported.add(child)
                        errs.append("E: 前置链成环，涉及 " + child
                                    + "（环上任务的前置/被依赖无法收敛，须拆环）")
                    continue
                if color[child] == 0:
                    nxt = child
                    break
            if nxt is None:
                color[node_id] = 2
                stack.pop()
            else:
                color[nxt] = 1
                stack.append((nxt, iter(adj[nxt])))

    done = {i for i in nodes if nodes[i]["status"] == "完成"}
    for n in nodes.values():
        if (n["status"] in ACTIVE or n["status"] == "可开工") and not n["exempt"]:
            unmet = [p for p in n["prs"] if p != n["id"] and p not in done]  # 自环不算未完成前置
            if unmet:
                errs.append(f"E 行{n['line']}: {n['id']} 状态={n['status']} 但前置未完成: {','.join(unmet)}"
                            f"（确需并行先行则加 豁免=1 并在 注 里写理由）")

    # 状态滞后：前置已全部完成却标"阻塞"——阻塞 专指前置未齐，
    # "没排期/外部依赖"不是阻塞的理由（外部依赖建门节点，排期由协调者在就绪集内裁量）。
    for n in nodes.values():
        if n["status"] == "阻塞" and not n["exempt"] and n["prs"] and \
                all(p in done for p in n["prs"]):
            warns.append(f"W 行{n['line']}: {n['id']} 状态滞后——前置已全部完成却标阻塞；"
                         f"改 可开工（排期先后由协调者裁量）或补真实前置/挂外部门节点")

    # 冗余前置：a→b 可经 b 的其它前置传递到达——图必须保持最小，
    # 假深度会让人误以为串行更长、并发更少。
    for a, b in sorted(redundant_edges(nodes)):
        warns.append(f"W: 前置 {a} -> {b} 冗余（可经其它前置传递到达），删除以保持最小依赖")

    # 阻塞无因：标阻塞/冻结却没有任何前置——依赖图必须能解释"为什么现在不能做"。
    # 源头任务一律 前置=root（root 是唯一无前置节点，完成态）。
    for n in nodes.values():
        if n["tier"] == "微":
            continue  # 微任务：随手挂载项，豁免阻塞无因审计
        if n["status"] in ("阻塞", "冻结") and not n["prs"] and n["id"] != "root":
            errs.append(f"E 行{n['line']}: {n['id']} 阻塞无因——状态={n['status']} 但没有任何前置，"
                        f"须补真实前置或前置到 root（表示仅因优先级未排期）")

    # 簇校验：成员存在 / 重复归属 / id 冲突 / 规模上限
    # 粒度规范：任务=单一可验收交付物（1 次派活）；名称=具体内容（编号/批次入 注=）；
    # 簇=语义功能团（成员 ≤ 8，超出必须拆分成多个簇）
    member_owner = {}
    for c in clusters:
        if c["id"] in nodes:
            errs.append(f"E 行{c['line']}: 簇 id {c['id']} 与任务节点冲突")
        if len(c["members"]) > 8:
            errs.append(f"E 行{c['line']}: 簇 {c['id']} 成员 {len(c['members'])} 个超过上限 8——按语义边界拆分成多个簇")
        for m in c["members"]:
            if m not in nodes:
                errs.append(f"E 行{c['line']}: 簇 {c['id']} 成员 {m} 未定义")
            elif m in member_owner:
                errs.append(f"E 行{c['line']}: 成员 {m} 同时属于簇 {member_owner[m]} 与 {c['id']}")
            else:
                member_owner[m] = c["id"]

    # 无后沿叶子：未完成且没有任何被依赖——逐个确认产出消费方；
    # 琐碎修复类（改一行文档/单条清理）不该独立存在，应合并进有后沿的任务或降级为附属步骤。
    # 例外：launch 的后代是终局交付（发布后的产出即终点），天然无后沿。
    terminal = descendants_of("launch", nodes) if "launch" in nodes else set()
    dependents = set()
    for e in edges:
        dependents.add(e["a"])  # a=被依赖的前置提供者；叶子=从不作为 a 的节点
    for n in nodes.values():
        if n["tier"] == "微":
            continue  # 微任务豁免无后沿审计
        if n["status"] not in ("完成", "放弃") and n["id"] not in dependents \
                and n["id"] not in terminal:
            warns.append(f"W 行{n['line']}: {n['id']} 无后沿（产出无消费方）——确认它服务于什么目标；"
                         f"琐碎修复应合并进有后沿的任务或移出规划图")

    seen = {}
    for n in nodes.values():
        if n["status"] == "进行中":
            for d in n["domain"]:
                if d in seen and seen[d] != n["id"]:
                    warns.append(f"W: 域 {d} 同时被进行中任务 {seen[d]} 与 {n['id']} 声明（合并冲突热点）")
                seen[d] = n["id"]
    return errs, warns


def producer_data(nodes, ready, crit, limit=6):
    """制作人视图聚合数据：统计 / 派活组合 / 里程碑进度（收口门燃尽）。"""
    combo = dispatch_suggestion(nodes, ready, crit, limit)
    gates = []
    for n in nodes.values():
        if n["kind"] != "里程碑":
            continue
        ds = [d for d in descendants_of(n["id"], nodes) if nodes[d]["status"] != "放弃"]
        done = sum(1 for d in ds if nodes[d]["status"] == "完成")
        gates.append({"id": n["id"], "name": n["name"], "done": done, "total": len(ds)})
    gates.sort(key=lambda g: (g["done"] >= g["total"], -(g["total"] - g["done"])))
    stats = {
        "nodes": len(nodes),
        "done": sum(1 for n in nodes.values() if n["status"] == "完成"),
        "active": sum(1 for n in nodes.values() if n["status"] in ("进行中", "待验收")),
        "ready": len(ready),
        "blocked": sum(1 for n in nodes.values() if n["status"] == "阻塞"),
        "frozen": sum(1 for n in nodes.values() if n["status"] == "冻结"),
    }
    ready_list = [{"id": i, "name": nodes[i]["name"], "lane": nodes[i]["lane"]} for i in sorted(ready)]
    return {"ready": ready_list, "combo": combo, "crit": crit, "gates": gates, "stats": stats}


def load_simlog(root):
    """调度日志注入：真实 docs/项目/调度日志.jsonl 与 .temp/sim_log.jsonl 模拟数据合并（带 src 标记）。"""
    import json
    evs = []
    for rel, tag in (("docs/项目/调度日志.jsonl", "real"), (".temp/sim_log.jsonl", "sim")):
        f = root / rel
        if not f.exists():
            continue
        for ln in f.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if not ln:
                continue
            try:
                rec = json.loads(ln)
                rec["src"] = tag
                evs.append(rec)
            except ValueError:
                pass
    return {"source": "+".join(sorted({e.get("src", "?") for e in evs})) or "", "events": evs[-800:]}


# ───────────────────── HTML 组装（源码 = web/ 多文件前端工程，构建时拼装为单文件产物） ─────────────────────
# 源码结构：web/index.html（骨架+占位符）· web/css/board.css · web/js/*.js（按 APP_JS 顺序拼装）· web/vendor/dagre.min.js
# 铁律：改 JS 后对每个文件跑 node --check；再运行本脚本重新生成单文件 HTML（产物 URL 不变，http/file:// 均可直开）
WEB_DIR = Path(__file__).parent / "web"
APP_JS = ["core.js", "layout.js", "render.js", "camera.js", "interact.js",
          "tasks.js", "views.js", "dock.js", "boot.js"]


def gen_html(nodes, edges, lane_order, errors, warns, clusters, divide_hint, ready=None, crit=None, producer=None, root=None) -> str:
    data = {
        "lanes": lane_order,
        "nodes": [{"id": n["id"], "name": n["name"], "kind": n["kind"], "lane": n["lane"],
                   "status": n["status"], "prs": n["prs"], "domain": n["domain"],
                   "tree": n["tree"], "note": n["note"], "exempt": n["exempt"], "doc": n["doc"], "tier": n["tier"], "claim": n["claim"],
                   "x": n["pos"][0] if n["pos"] else None,
                   "y": n["pos"][1] if n["pos"] else None} for n in nodes.values()],
        "edges": [{"a": e["a"], "b": e["b"]} for e in edges],
        "check": {"errors": errors, "warns": warns},
        "divideX": divide_hint,
        "ready": sorted(ready or []),
        "crit": crit or [],
        "producer": producer or {},
        "simlog": load_simlog(root),
        "clusters": [{"id": c["id"], "name": c["name"], "members": c["members"],
                    "note": c["note"], "folded": c["folded"]} for c in clusters],
    }
    html = (WEB_DIR / "index.html").read_text(encoding="utf-8")
    css = (WEB_DIR / "css" / "board.css").read_text(encoding="utf-8")
    js = (WEB_DIR / "vendor" / "dagre.min.js").read_text(encoding="utf-8")
    app = "".join((WEB_DIR / "js" / f).read_text(encoding="utf-8") for f in APP_JS)
    return (html.replace("/*__CSS__*/", css)
                .replace("/*__DAGRE__*/", js)
                .replace("/*__DATA__*/null", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
                .replace("/*__APP__*/", app))


# ───────────── AI 调度 CLI：claim / release / done / sim（执行 AI 的自发认领接口） ─────────────
LOG_PATH = Path(__file__).resolve().parents[2] / "docs" / "项目" / "调度日志.jsonl"


def log_event(action, task, agent, extra=""):
    import json, datetime
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    rec = {"ts": datetime.datetime.now().isoformat(timespec="seconds"),
           "agent": agent, "action": action, "task": task}
    if extra:
        rec["note"] = extra
    with LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def set_field_in_txt(src_path, nid, field, value):
    """就地替换任务行内字段（其它行字节不动）。value=None 删除该字段。
    实现：按 " | " 切分为字段数组后定点替换/删除/追加——无正则边界问题。"""
    text = src_path.read_text(encoding="utf-8")
    out = []
    hit = False
    prefix_task = "任务 " + nid + " "
    prefix_ms = "里程碑 " + nid + " "
    for ln in text.split("\n"):
        if ln.startswith(prefix_task) or ln.startswith(prefix_ms):
            hit = True
            parts = ln.split(" | ")
            if value is None:
                parts = [q for q in parts if not q.startswith(field + "=")]
            else:
                tgt = field + "=" + value
                for i, q in enumerate(parts):
                    if q.startswith(field + "="):
                        parts[i] = tgt
                        break
                else:
                    parts.append(tgt)
            ln = " | ".join(parts)
        out.append(ln)
    if not hit:
        return False
    src_path.write_text("\n".join(out) + "\n", encoding="utf-8")
    return True


def cmd_claim(src_path, nid, agent):
    nodes, edges, lane_order, perr, clusters, _ = parse(src_path.read_text(encoding="utf-8"))
    if nid not in nodes:
        print("E: 任务不存在: " + nid)
        return 1
    n = nodes[nid]
    if n["status"] in ("完成", "放弃"):
        print("E: 任务已" + n["status"] + ": " + nid)
        return 1
    if n["claim"]:
        print("E: 已被认领: " + nid + " → " + n["claim"])
        return 1
    unmet = [q for q in n["prs"] if q != nid and nodes.get(q, {"status": ""})["status"] != "完成"]
    if unmet:
        print("E: 前置未完成，禁止认领: " + nid + " ← " + ",".join(unmet))
        return 1
    if not set_field_in_txt(src_path, nid, "认领", agent):
        print("E: 写回失败")
        return 1
    log_event("claim", nid, agent, n["lane"])
    print("✓ " + agent + " 认领 " + nid + "（" + n["name"] + "）")
    return 0


def cmd_release(src_path, nid, agent=""):
    nodes, edges, lane_order, perr, clusters, _ = parse(src_path.read_text(encoding="utf-8"))
    if nid not in nodes:
        print("E: 任务不存在: " + nid)
        return 1
    cur = nodes[nid]["claim"]
    if not cur:
        print("E: 未被认领: " + nid)
        return 1
    if agent and cur != agent:
        print("E: 认领者是 " + cur + "，不是 " + agent)
        return 1
    set_field_in_txt(src_path, nid, "认领", None)
    log_event("release", nid, cur)
    print("✓ 释放 " + nid + "（原认领 " + cur + "）")
    return 0


def cmd_done(src_path, nid, agent):
    nodes, edges, lane_order, perr, clusters, _ = parse(src_path.read_text(encoding="utf-8"))
    if nid not in nodes:
        print("E: 任务不存在: " + nid)
        return 1
    set_field_in_txt(src_path, nid, "状态", "完成")
    set_field_in_txt(src_path, nid, "认领", None)
    log_event("done", nid, agent, nodes[nid]["lane"])
    print("✓ " + nid + " 完成（" + agent + "）")
    return 0


def cmd_sim(src_path, agents_n, rounds, seed=7):
    """多 AI 调度模拟：按就绪集认领→执行→完成，写模拟日志（供运行图/压力测试）。"""
    import random, json, datetime
    rng = random.Random(seed)
    nodes, edges, lane_order, perr, clusters, _ = parse(src_path.read_text(encoding="utf-8"))
    AGENTS = ["exec-%02d" % i for i in range(1, agents_n + 1)]
    speed = {a: rng.uniform(0.6, 1.6) for a in AGENTS}
    spec = {a: rng.choice(["复刻主线", "工程债", "UI线", "战略图", "地图系统", "玩法系统", "叙事设计", "决策"]) for a in AGENTS}
    t = 0
    claims = {}  # task → (agent, claim_t)
    log = []
    out = Path(".temp/sim_log.jsonl")
    out.parent.mkdir(parents=True, exist_ok=True)
    done_count = 0
    for t in range(rounds):
        # 认领：每个空闲 agent 从就绪集挑任务（专长线优先，否则关键路径优先近似=被依赖数最多）
        for a in AGENTS:
            if any(v[0] == a for v in claims.values()):
                continue
            cand = []
            for nid, n in nodes.items():
                if n["status"] != "可开工" or nid in claims or nid in done_count if False else nid in claims:
                    continue
            for nid, n in nodes.items():
                if n["status"] != "可开工" or nid in claims:
                    continue
                if any(q in claims for q in n["prs"]):
                    continue
                all_done = all((q not in nodes) or nodes[q]["status"] == "完成" for q in n["prs"])
                if not all_done:
                    continue
                w = 3 if n["lane"] == spec[a] else 1
                cand.append((rng.random() < 0.9, w, nid))
            pool = [c[2] for c in cand if c[0]]
            if pool:
                pick = max(pool, key=lambda nid: (nodes[nid]["lane"] == spec[a], sum(1 for n2 in nodes.values() if nid in n2["prs"]), -len(nid)))
                claims[pick] = (a, t)
                log.append({"ts": "T%03d" % t, "agent": a, "action": "claim", "task": pick, "note": nodes[pick]["lane"]})
        # 完成：按速度概率完成
        for nid in list(claims):
            a, t0 = claims[nid]
            dur = max(1, int(round(2 / speed[a])))
            if t - t0 >= dur and rng.random() < 0.5:
                nodes[nid]["status"] = "完成"
                nodes[nid]["claim"] = ""
                log.append({"ts": "T%03d" % t, "agent": a, "action": "done", "task": nid, "note": nodes[nid]["lane"]})
                done_count += 1
                del claims[nid]
    with out.open("w", encoding="utf-8") as f:
        for rec in log:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print("sim 完成：%d agents × %d 轮 → %d 事件，完成 %d 任务 → %s" % (agents_n, rounds, len(log), done_count, out))
    return 0


def main():
    # 子命令分发：claim/release/done/sim（AI 调度接口），无子命令=默认校验+生成
    argv = sys.argv[1:]
    if argv and argv[0] in ("claim", "release", "done", "sim"):
        cmd = argv[0]
        rest = argv[1:]
        root0 = Path(__file__).resolve().parents[2]
        src0 = root0 / "docs" / "项目" / "任务依赖图.txt"
        if cmd == "claim":
            if not rest:
                print("用法: claim <id> --by <AI名>")
                return 1
            nid = rest[0]
            by = "unknown"
            if "--by" in rest:
                by = rest[rest.index("--by") + 1]
            return cmd_claim(src0, nid, by)
        if cmd == "release":
            if not rest:
                print("用法: release <id> [原认领者]")
                return 1
            return cmd_release(src0, rest[0], rest[1] if len(rest) > 1 else "")
        if cmd == "done":
            if not rest:
                print("用法: done <id> --by <AI名>")
                return 1
            by = rest[rest.index("--by") + 1] if "--by" in rest else "unknown"
            return cmd_done(src0, rest[0], by)
        if cmd == "sim":
            agents_n, rounds = 6, 40
            if "--agents" in rest:
                agents_n = int(rest[rest.index("--agents") + 1])
            if "--rounds" in rest:
                rounds = int(rest[rest.index("--rounds") + 1])
            return cmd_sim(src0, agents_n, rounds)
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--src", default="docs/项目/任务依赖图.txt")
    ap.add_argument("-o", "--out", default="docs/项目/任务依赖图.html")
    ap.add_argument("--check", action="store_true", help="只校验+调度报告不生成")
    ap.add_argument("--lanes", type=int, default=6, help="建议派活组合的并行线上限（默认 6）")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[2]
    src = root / args.src
    if not src.exists():
        print(f"源文件不存在: {src}")
        return 1
    nodes, edges, lane_order, perr, clusters, divide_hint = parse(src.read_text(encoding="utf-8"))
    # 前置= 字段是依赖的唯一真相源；-> 行仅兼容旧文件。合并去重后统一为 edges。
    for e in list(edges):
        if e["a"] in nodes and e["b"] in nodes and e["a"] not in nodes[e["b"]]["prs"]:
            nodes[e["b"]]["prs"].append(e["a"])
    edge_set = {(e["a"], e["b"]) for e in edges if e["a"] in nodes and e["b"] in nodes}
    for n in nodes.values():
        for p in n["prs"]:
            if p in nodes and (p, n["id"]) not in edge_set:
                edge_set.add((p, n["id"]))
    edges = [{"a": a, "b": b, "line": 0} for a, b in sorted(edge_set)]
    errors, warns = validate(nodes, edges, lane_order, clusters)
    errors = [f"{lvl} 行{ln}: {msg}" for lvl, ln, msg in perr if lvl == "E"] + errors
    warns += [f"{lvl} 行{ln}: {msg}" for lvl, ln, msg in perr if lvl == "W"]
    for w in warns:
        print(w)
    for e in errors:
        print(e)
    print(f"—— {len(nodes)} 节点 / {len(edges)} 边 / {len(clusters)} 簇，{len(errors)} 错误 / {len(warns)} 警告")
    report, ready, crit = schedule_report(nodes, args.lanes)
    print(report)
    if errors:
        return 1
    if args.check:
        return 0
    out = root / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    prod = producer_data(nodes, ready, crit, args.lanes)
    out.write_text(gen_html(nodes, edges, lane_order, errors, warns, clusters, divide_hint, ready, crit, prod, root),
                   encoding="utf-8")
    print(f"已生成 {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
