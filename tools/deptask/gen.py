#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""任务依赖图工具 v3 —— 纯文本源 → 校验 → 交互式可视化（单文件 HTML，离线可用）。

可读性方案（对标 ComfyUI / Unity Shader Graph，经 litegraph.js 源码核实）：
  1. 布局交给 dagre（mermaid 底层引擎，MIT，已 vendor 至本目录 dagre.min.js 内联进 HTML）：
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
    js = (Path(__file__).parent / "dagre.min.js").read_text(encoding="utf-8")
    return HTML.replace("/*__DAGRE__*/", js).replace("/*__DATA__*/null", json.dumps(data, ensure_ascii=False))


# ─────────────────────── HTML 模板 v3（dagre + 端口贝塞尔） ───────────────────────
HTML = r"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<title>任务依赖图</title>
<style> :root{--bg:#060a11;--bg2:#0b111c;--panel:#0d1522;--panel2:#111a29;--lift:#16233a;
   --line:#1d2a3d;--line2:#26374d;--txt:#dbe4f0;--sub:#7a8ca6;--dim2:#55677f;
   --acc:#38bdf8;--acc2:#a78bfa;--green:#22d3a0;--amber:#fbbf24;--red:#f87171;--pink:#f472b6;
   --mono:ui-monospace,"SF Mono","Cascadia Mono",Consolas,"Liberation Mono",monospace}
 html,body{margin:0;height:100%;overflow:hidden;background:var(--bg);color:var(--txt);
   font:13px/1.5 system-ui,"Segoe UI","Microsoft YaHei",sans-serif}
 /* ── 顶栏（LOGIC-8 topbar：唯一渐变+line2 底线，无阴影） ── */
 #bar{position:fixed;inset:0 0 auto 0;display:flex;flex-direction:column;gap:5px;
   padding:8px 14px;background:linear-gradient(180deg,#0e1725,#0a111c);
   border-bottom:1px solid var(--line2);z-index:20}
 #bar .row{display:flex;align-items:center;gap:8px;min-width:0;flex-wrap:wrap}
 #bar .sep{width:1px;height:15px;background:var(--line2);flex-shrink:0}
 #bar .sub{font-size:10.5px;color:var(--dim2);letter-spacing:2px;white-space:nowrap}
 .logo{font:800 16px/1 var(--mono);letter-spacing:1px;white-space:nowrap;
   background:linear-gradient(92deg,#38bdf8,#a78bfa 55%,#22d3a0);
   -webkit-background-clip:text;background-clip:text;color:transparent}
 #bar .chips{margin-left:auto;display:flex;gap:6px;flex-shrink:0}
 #bar .btn{background:#16233a;color:var(--txt);border:1px solid var(--line2);border-radius:6px;
   padding:5px 11px;font:500 12px/1.2 system-ui,sans-serif;cursor:pointer;white-space:nowrap;
   transition:background .12s,border-color .12s,transform .06s}
 #bar .btn:hover{background:#1e2f4c;border-color:#3a5678}
 #bar .btn:active{transform:translateY(1px)}
 #bar .btn.primary{background:#14405c;border-color:#2a6d94;color:#d8f2ff}
 #bar .btn.primary:hover{background:#1a5375}
 #bar .btn.on{background:#7c2d4a;border-color:#b04a72;color:#ffe4ef}
 #search{background:var(--panel2);border:1px solid var(--line2);border-radius:6px;color:var(--txt);
   padding:4px 10px;font-size:12px;width:170px;outline:none;transition:border-color .12s}
 #search:focus{border-color:var(--acc)}
 #checkChip,#readyChip,#critChip{font:600 11px/1.4 system-ui,sans-serif;padding:4px 10px;border-radius:5px;
   cursor:pointer;background:var(--panel2);border:1px solid var(--line);white-space:nowrap;
   transition:border-color .12s}
 /* ── 图例 / 泳道胶囊 ── */
 #barRow2{overflow-x:auto;scrollbar-width:thin}
 #barRow2::-webkit-scrollbar{height:5px}
 #barRow2::-webkit-scrollbar-thumb{background:#21334b;border-radius:3px}
 #legend{display:flex;gap:9px;font-size:10.5px;color:var(--sub);align-items:center;flex-shrink:0}
 #legend>span{white-space:nowrap;flex-shrink:0}
 .sw{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:4px;vertical-align:-1px}
 #lanes{display:flex;gap:4px;flex-shrink:0}
 .lchip{font-size:11px;padding:3px 9px;border-radius:4px;border:1px solid var(--line);cursor:pointer;
   background:var(--panel2);color:#93a7c0;user-select:none;white-space:nowrap;flex-shrink:0;
   transition:background .12s,border-color .12s}
 .lchip:hover{background:var(--lift);border-color:#3a5678;color:var(--txt)}
 .lchip.off{opacity:.3;text-decoration:line-through}
 .lchip.focus{border-color:var(--acc);color:var(--acc);background:#12304a}
 /* ── 画布工具条（LOGIC-8 view-bar：分组 tiny 按钮密集排列） ── */
 #vbar{position:fixed;display:none;align-items:center;gap:1px;background:var(--line);
   border-bottom:1px solid var(--line2);padding:4px 8px;z-index:16;overflow-x:auto;scrollbar-width:none}
 #vbar .vg{display:flex;gap:1px;align-items:center;flex-shrink:0}
 #vbar .sep{width:1px;height:16px;background:var(--line2);margin:0 7px;flex-shrink:0}
 #vbar .vt{background:var(--panel2);border:1px solid var(--line);color:var(--dim);border-radius:4px;
   padding:3px 8px;font:500 11px/1.2 system-ui,sans-serif;cursor:pointer;white-space:nowrap;flex-shrink:0}
 #vbar .vt:hover{color:var(--txt);border-color:#3a5678}
 #vbar .vt.on{background:#12304a;border-color:var(--acc);color:var(--acc)}
 #vbar .lbl{font-size:9.5px;color:var(--dim2);letter-spacing:.5px;flex-shrink:0}
 /* ── 视图页签（岗位工作台） ── */
 #viewTabs{gap:1px;background:var(--line);flex-wrap:nowrap;overflow-x:auto;scrollbar-width:thin}
 .vtab{font-size:11.5px;padding:5px 12px;border:0;cursor:pointer;background:var(--panel2);
   color:var(--sub);user-select:none;white-space:nowrap;flex-shrink:0}
 .vtab:hover{color:var(--txt)}
 .vtab.on{background:#16273c;color:var(--acc);box-shadow:inset 0 -2px 0 var(--acc)}
 /* ── 详情面板 / 消息 / 帮助 ── */
 #panel{position:fixed;top:92px;right:10px;width:320px;max-height:72vh;overflow:auto;
   background:var(--panel);border:1px solid var(--line2);border-radius:6px;padding:0 0 10px;
   font-size:12.5px;display:none;z-index:20;line-height:1.75}
 #panel h3{margin:0;padding:9px 14px 7px;font-size:13px;font-weight:650;letter-spacing:.3px;
   border-bottom:1px solid var(--line);color:#eaf6ff}
 #panel .tag{display:inline-block;background:var(--panel2);border:1px solid var(--line);border-radius:4px;
   padding:0 7px;margin:2px 4px 2px 0;font-size:11.5px;cursor:pointer;color:#93a7c0}
 #panel .tag:hover{border-color:var(--acc);color:var(--acc)}
 #panel .row{color:var(--sub);margin:6px 14px 0}
 #msgs{position:fixed;bottom:0;left:0;right:0;max-height:34vh;overflow:auto;background:var(--panel);
   border-top:1px solid var(--line2);font-size:12px;padding:8px 14px;display:none;z-index:20;line-height:1.9}
 #msgs .e{color:var(--red)}#msgs .w{color:var(--amber)}
 #help{position:fixed;inset:0;background:#000a;display:none;z-index:40;align-items:center;justify-content:center}
 #help>div{background:var(--panel);border:1px solid var(--line2);border-radius:6px;padding:20px 26px;
   max-width:480px;line-height:2.1;font-size:12.5px}
 #help b{color:var(--acc)}
 /* ── 小地图 / 缩放 ── */
 /* ── 三栏 IDE 布局（LOGIC-8 main 骨架：左岗位栏 / canvas / 右检查器） ── */
 .side{position:fixed;bottom:0;background:var(--panel);display:none;flex-direction:column;
   overflow-y:auto;overflow-x:hidden;z-index:15;scrollbar-width:thin}
 #sideL{left:0;width:248px;border-right:1px solid var(--line2)}
 #sideR{right:0;width:308px;border-left:1px solid var(--line2);padding:0 0 10px}
 .side .pane-head{padding:8px 12px 6px;font-size:11px;font-weight:600;color:var(--acc2);
   letter-spacing:.4px;border-bottom:1px solid var(--line);position:sticky;top:76px;background:var(--panel);z-index:2}
 .side .pane-head .hint{color:var(--dim2);font-size:10px;font-weight:400;margin-left:6px}
 #inspector{padding:0 0 8px}
 #inspector h3{margin:0;padding:9px 14px 7px;font-size:13px;font-weight:650;letter-spacing:.3px;
   border-bottom:1px solid var(--line);color:#eaf6ff}
 #inspector .tag{display:inline-block;background:var(--panel2);border:1px solid var(--line);border-radius:4px;
   padding:0 7px;margin:2px 4px 2px 0;font-size:11.5px;cursor:pointer;color:#93a7c0}
 #inspector .tag:hover{border-color:var(--acc);color:var(--acc)}
 #inspector .row{color:var(--sub);margin:6px 14px 0}
 #inspector .ph{color:var(--dim2);font-size:11px;padding:12px 14px}
 /* 清单行（机器码清单式：左侧 2px 状态条 + 三列 grid + 等宽 id） */
 .lst{display:grid;grid-template-columns:10px minmax(76px,auto) 1fr 18px;gap:6px;align-items:center;
   padding:3px 10px 3px 8px;font-size:11.5px;line-height:1.5;color:#93a7c0;
   border-left:2px solid transparent;cursor:pointer}
 .lst:hover{background:#131e2e;color:var(--txt)}
 .lst.active{background:#16324a;border-left-color:var(--amber);color:#eaf6ff}
 .lst .dot{width:7px;height:7px;border-radius:50%;display:inline-block}
 .lst .lid{font:600 10.5px var(--mono);color:var(--dim2);overflow:hidden;text-overflow:ellipsis}
 .lst .lname{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .lst .lgo{color:var(--dim2);text-align:center}
 .lst .lgo:hover{color:var(--acc)}
 .lst.grp{grid-template-columns:10px 1fr auto;border-bottom:1px solid var(--line)}
 .lst .cnt{font:700 10.5px var(--mono);color:var(--dim2)}
 .gbar{height:6px;background:var(--panel2);border:1px solid var(--line);flex:1}
 .gbar i{display:block;height:100%;background:var(--green)}
 .grow{display:flex;align-items:center;gap:8px;padding:4px 12px;font-size:11.5px}
 .grow .nm{width:130px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;cursor:pointer}
 .grow .nm:hover{color:var(--acc)}
 .grow .pc{font:700 10px var(--mono);color:var(--dim2)}
 .extStrip{margin:8px 12px;padding:8px 10px;background:#0c2a33;border:1px solid #155e75;border-radius:4px;
   font-size:11.5px;line-height:1.6}
 .extStrip b{color:#a5f3fc}
 .extStrip .st{font:700 10.5px var(--mono);color:var(--amber)}
 #mini{position:fixed;left:258px;bottom:12px;border:1px solid var(--line2);background:#0a111ccc;
   z-index:15;cursor:crosshair}
 #zoom{position:fixed;left:258px;bottom:140px;font:600 10px var(--mono);color:var(--dim2);z-index:15;
   background:#0a111ccc;border:1px solid var(--line);padding:3px 8px}
 canvas#cv{display:block;position:fixed;inset:0;cursor:crosshair}
 /* ── canvas 底部渐隐信息条（LOGIC-8 canvas-foot/wave-info 角色） ── */
 #cfoot{position:fixed;left:0;right:0;bottom:0;height:24px;display:flex;align-items:center;gap:16px;
   padding:0 14px;font:11px/1 var(--mono);color:var(--sub);z-index:14;
   background:linear-gradient(180deg,rgba(6,10,17,0),rgba(6,10,17,.94));pointer-events:none}
 #cfoot #cfR{color:#93a7c0}
 /* ── 底部 IDE 面板（dock：运行图/调度日志，可折叠） ── */
 #dock{position:fixed;left:0;right:0;bottom:0;height:38vh;min-height:220px;display:none;flex-direction:column;
   background:var(--panel);border-top:1px solid var(--line2);z-index:18}
 #dock.folded{height:30px}
 #dockBar{display:flex;align-items:center;gap:1px;background:var(--bg2);border-bottom:1px solid var(--line);
   padding:0 8px;height:30px;flex:0 0 auto}
 .dtab{font-size:11.5px;padding:4px 12px;cursor:pointer;background:transparent;border:0;color:var(--dim);white-space:nowrap}
 .dtab:hover{color:var(--txt)}
 .dtab.on{background:#16273c;color:var(--acc);box-shadow:inset 0 -2px 0 var(--acc)}
 #dockInfo{margin-left:auto;font:600 10px var(--mono);color:var(--dim2)}
 #dockFold{cursor:pointer;color:var(--sub);padding:2px 8px;font-size:12px}
 #dockFold:hover{color:var(--acc)}
 #dockBody{flex:1 1 auto;min-height:0;position:relative}
 #dock.folded #dockBody{display:none}
 #gantt{position:absolute;inset:0;width:100%;height:100%;cursor:crosshair}
 #logList{position:absolute;inset:0;overflow-y:auto;padding:4px 0}
 /* ── 相关项浮窗（左下小窗） ── */
 #relwin{position:fixed;left:262px;bottom:44px;width:320px;max-height:62vh;overflow:auto;display:none;
   flex-direction:column;background:var(--panel);border:1px solid var(--line2);border-radius:6px;
   z-index:30;box-shadow:0 8px 24px #000a}
 #relwin .phead{display:flex;align-items:center;gap:8px;padding:8px 12px;font-size:12.5px;color:#eaf6ff;
   border-bottom:1px solid var(--line)}
 #relwin .pbody{overflow:auto}
 /* ── kv 状态格条（LOGIC-8 status-strip：1px 缝网格+等宽数值） ── */
 .strip{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;background:var(--line);
   border-bottom:1px solid var(--line2)}
 #dash .strip{grid-template-columns:repeat(6,1fr);border:1px solid var(--line2);margin:0 auto 14px;max-width:1500px}
 .kv{background:var(--panel2);padding:6px 2px;text-align:center;overflow:hidden}
 .kv span{display:block;font-size:9.5px;color:var(--dim2)}
 .kv b{font:700 13px var(--mono);color:var(--text)}
 .kv b.g{color:var(--green)}.kv b.y{color:var(--amber)}.kv b.c{color:var(--acc)}
 /* ── 底部 IDE 面板（dock：运行图/调度日志，可折叠） ── */
 #dock{position:fixed;left:0;right:0;bottom:0;height:38vh;min-height:220px;display:none;flex-direction:column;
   background:var(--panel);border-top:1px solid var(--line2);z-index:18}
 #dock.folded{height:30px}
 #dockBar{display:flex;align-items:center;gap:1px;background:var(--bg2);border-bottom:1px solid var(--line);
   padding:0 8px;height:30px;flex:0 0 auto}
 .dtab{font-size:11.5px;padding:4px 12px;cursor:pointer;background:transparent;border:0;color:var(--dim);white-space:nowrap}
 .dtab:hover{color:var(--txt)}
 .dtab.on{background:#16273c;color:var(--acc);box-shadow:inset 0 -2px 0 var(--acc)}
 #dockInfo{margin-left:auto;font:600 10px var(--mono);color:var(--dim2)}
 #dockFold{cursor:pointer;color:var(--sub);padding:2px 8px;font-size:12px}
 #dockFold:hover{color:var(--acc)}
 #dockBody{flex:1 1 auto;min-height:0;position:relative}
 #dock.folded #dockBody{display:none}
 #gantt{position:absolute;inset:0;width:100%;height:100%;cursor:crosshair}
 #logList{position:absolute;inset:0;overflow-y:auto;padding:4px 0}
 /* ── 相关项浮窗（左下小窗） ── */
 #relwin{position:fixed;left:262px;bottom:44px;width:320px;max-height:62vh;overflow:auto;display:none;
   flex-direction:column;background:var(--panel);border:1px solid var(--line2);border-radius:6px;
   z-index:30;box-shadow:0 8px 24px #000a}
 #relwin .phead{display:flex;align-items:center;gap:8px;padding:8px 12px;font-size:12.5px;color:#eaf6ff;
   border-bottom:1px solid var(--line)}
 #relwin .pbody{overflow:auto}
 /* ── 检查器上下文行 ── */
 .ctxrow{margin:5px 14px 0;font:600 10.5px var(--mono);color:var(--dim2);letter-spacing:.2px}
 /* ── 右键菜单 / 弹窗（LOGIC-8：直角+1px 线，无阴影） ── */
 #ctx{position:fixed;display:none;background:var(--panel);border:1px solid var(--line2);border-radius:4px;
   padding:5px 0;z-index:50;min-width:170px;font-size:12px;max-height:60vh;overflow:auto}
 #ctx .ch{color:var(--acc2);font-size:10px;padding:4px 14px 2px;letter-spacing:.4px}
 #ctx .ci{padding:5px 14px;cursor:pointer;white-space:nowrap;color:#93a7c0}
 #ctx .ci:hover{background:var(--lift);color:var(--txt)}
 #modal{position:fixed;inset:0;background:#000a;display:none;align-items:center;justify-content:center;z-index:60}
 #modal>div{background:var(--panel);border:1px solid var(--line2);border-radius:6px;padding:18px 22px;
   width:340px;display:flex;flex-direction:column;gap:8px;font-size:12.5px}
 #modal h3{margin:0 0 4px;font-size:13px;font-weight:650;letter-spacing:.3px;color:var(--acc2)}
 #modal label{display:flex;flex-direction:column;gap:3px;color:var(--sub);font-size:11px}
 #modal input,#modal select{background:var(--panel2);border:1px solid var(--line2);border-radius:5px;
   color:var(--txt);padding:5px 8px;font-size:12px;outline:none}
 #modal input:focus,#modal select:focus{border-color:var(--acc)}
 #modal .btns{display:flex;gap:8px;justify-content:flex-end;margin-top:6px}
 #modal .go{background:#14405c;border:1px solid #2a6d94;color:#d8f2ff;border-radius:6px;
   padding:6px 16px;cursor:pointer;font-size:12.5px}
 #modal .no{background:transparent;border:1px solid var(--line2);color:var(--sub);border-radius:6px;
   padding:6px 12px;cursor:pointer;font-size:12.5px}
 /* ── 制作人仪表盘（LOGIC-8 右栏：1px 缝网格/紫罗兰小节标题/kv 状态格） ── */
 #dash{position:fixed;left:0;right:0;bottom:0;display:none;overflow:auto;background:var(--bg);z-index:10;
   padding:clamp(10px,2vw,20px) clamp(10px,3vw,24px) 26px}
 #dash .layout{display:grid;grid-template-columns:minmax(0,2fr) minmax(0,1fr);gap:14px;max-width:1500px;margin:0 auto}
 #dash .col{display:flex;flex-direction:column;gap:14px;min-width:0;align-items:stretch}
 #dash .col>.card:last-child{flex:1;min-height:180px;display:flex;flex-direction:column}
 #dash .col>.card:last-child>div{flex:1;min-height:100px}
 #dash .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(330px,100%),1fr));gap:1px;
   background:var(--line);border:1px solid var(--line2)}
 @media (max-width:1000px){#dash .layout{grid-template-columns:1fr}}
 #dash .card{background:var(--panel);padding:0 0 12px}
 #dash .card h4{margin:0;padding:8px 14px 6px;font-size:11px;font-weight:600;color:var(--acc2);
   letter-spacing:.4px;border-bottom:1px solid var(--line)}
 #dash .card>div,#dash .stats,#dash .gate{margin:0 14px}
 #dash .stats{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;background:var(--line);margin-top:10px}
 #dash .stat{background:var(--panel2);padding:8px 2px;text-align:center}
 #dash .stat b{font:700 13px var(--mono);color:var(--txt);display:block}
 #dash .stat span{font-size:9.5px;color:var(--dim2)}
 .tchip{display:inline-block;background:var(--panel2);border:1px solid var(--line);border-radius:4px;
   padding:2px 8px;margin:2px 3px 2px 0;font-size:11.5px;cursor:pointer;color:#93a7c0;white-space:nowrap;
   transition:background .12s,border-color .12s}
 .tchip:hover{background:var(--lift);border-color:var(--acc);color:var(--acc)}
 .tchip .dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:5px;vertical-align:0}
 #dash .laneHead{font-size:10px;color:var(--acc2);margin:8px 0 3px;letter-spacing:.4px}
 #dash .bar{height:6px;background:var(--panel2);border:1px solid var(--line);flex:1}
 #dash .bar i{display:block;height:100%;background:var(--green)}
 #dash .gate{display:flex;align-items:center;gap:9px;margin:7px 14px;font-size:11.5px;min-width:0}
 #dash .gate .nm{width:min(150px,38vw);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;cursor:pointer;flex-shrink:0}
 #dash .gate .nm:hover{color:var(--acc)}
 #dash .gate .pc{width:52px;text-align:right;color:var(--dim2);font:700 10.5px var(--mono)}
 #dash .warn{font-size:11.5px;color:var(--amber);line-height:1.7;word-break:break-all;margin:4px 14px 0}
 #dash .hint{font-size:10px;color:var(--dim2);margin:6px 14px 0}
 /* ── 全局滚动条 ── */
 ::-webkit-scrollbar{width:9px;height:9px}
 ::-webkit-scrollbar-track{background:#0a111c}
 ::-webkit-scrollbar-thumb{background:#21334b;border-radius:5px}
 ::-webkit-scrollbar-thumb:hover{background:#2d466a}
 @media (max-width:1150px){#bar .sub{display:none}#search{width:130px}}
 @media (max-width:860px){#legend{display:none}#bar .btn{padding:4px 8px;font-size:11.5px}#search{width:110px}
  #sideL{width:200px}#sideR{width:250px}
  #dash .stats{grid-template-columns:repeat(2,1fr)}
  .lst .lname{white-space:normal;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}}
</style></head><body>
<div id="bar"><div class="row"><b class="logo" title="任务依赖图 · 唯一真相源 docs/项目/任务依赖图.txt">任务依赖图</b><span class="sub">DAG 调度台</span>
 <span class="sep"></span>
 <input id="search" placeholder="搜索 id / 名称 / 备注…">
 <span class="sep"></span>
 <button class="btn" onclick="locateActive()" title="定位到进行中/可开工任务区（活跃面）">⌖ 当前面</button>
 <button class="btn" onclick="fitAll()" title="缩放至全图可见">⛶ 全图</button>
 <button class="btn" onclick="relayout()" title="dagre 重新分层布线（交叉最小化；会清除手动布局）">⟲ 重排</button>
 <button class="btn" id="exportBtn" onclick="exportTxt()" title="导出完整源文件（含状态/依赖/布局编辑）→ 覆盖 docs/项目/任务依赖图.txt → 跑 --check 校验">⬇ 导出源</button>
 <button class="btn" onclick="showDivide=!showDivide;this.classList.toggle('on',showDivide);dirty=true" title="完成/未完成分割墙显隐（拖墙=右区整体平移）">✂ 分割墙</button>
 <button class="btn" onclick="document.getElementById('help').style.display='flex'" title="操作说明">? 帮助</button>
 <div class="chips">
  <span id="checkChip" title="校验器结果——错误=环/悬空引用/前置未完成就开工（有错误禁止派活）；警告=状态滞后/冗余依赖/域冲突/无后沿（审计线索）。点击展开明细"></span>
  <span id="readyChip" title="就绪集：前置全部完成、可立即派活的任务数。点击只高亮这些节点（调度视角）"></span>
  <span id="critChip" title="关键路径：未完成子图最长链跳数（加并发只能压非关键路径，关键路径靠拆依赖/拆任务）。点击高亮链上节点"></span>
 </div>
</div>
<div class="row" id="barRow2">
 <span id="legend"></span>
 <span class="sep"></span>
 <span id="lanes" title="单击=聚拢该线居中（再点退出，显隐/布局状态保留） · Alt+单击=显隐该线"></span>
</div>
<div class="row" id="viewTabs">
 <span class="vtab on" data-v="graph">🗺 全图 DAG</span>
 <span class="vtab" data-v="producer" title="派活台：今天派什么 / 什么卡住 / 离里程碑多远">🧭 制作人</span>
 <span class="vtab" data-v="eng" title="代码线工程板：模块开发/重构/技术债">⚙ 程序</span>
 <span class="vtab" data-v="design" title="设计产出板：细化设计/决策项">📐 策划</span>
 <span class="vtab" data-v="art" title="资产板：素材替换/外部采购通道">🎨 美术</span>
 <span class="vtab" data-v="qa" title="质量板：缺陷/待验收/测试链/Demo 收口">🧪 测试</span>
</div>
</div>
<div id="ctx"></div>
<div id="dock">
 <div id="dockBar">
  <span class="dtab on" data-t="gantt">▦ 运行图</span>
  <span class="dtab" data-t="log">≡ 调度日志</span>
  <span id="srcSwitch" style="display:flex;gap:1px;margin-left:8px"></span>
  <span id="dockInfo"></span>
  <span id="dockFold" title="折叠/展开底栏（Tab 键）">▾</span>
 </div>
 <div id="dockBody">
  <canvas id="gantt"></canvas>
  <div id="logList"></div>
 </div>
</div>
<div id="relwin" title="相关项浮窗：点击行定位，⤢ 跳全图"></div>
<div id="modal"><div><h3 id="ntTitle">➕ 新建任务</h3>
 <label>id（英文标识符）<input id="ntId" placeholder="如 tech_rebuild2"></label>
 <label>名称<input id="ntName" placeholder="一句话说清交付物"></label>
 <label>线<select id="ntLane"></select></label>
 <label>状态<select id="ntStatus"></select></label>
 <label>前置（逗号分隔 id，可留空）<input id="ntPrs" placeholder="root"></label>
 <label>域（逗号分隔文件/目录，可留空）<input id="ntDomain" placeholder="modules/xxx"></label>
 <label>关联文档（可留空）<input id="ntDoc" placeholder="docs/设计/系统/xx.md"></label>
 <label>注<input id="ntNote"></label>
 <div class="btns"><button class="no" onclick="closeModal()">取消</button><button class="go" id="ntGo" onclick="submitTaskForm()">创建</button></div>
</div></div>
<div id="dash"></div>
<div id="vbar"></div>
<div id="relwin" title="相关项浮窗：点击行定位，⤢ 跳全图"></div>
<div id="sideL" class="side"></div>
<div id="sideR" class="side"><div id="inspector"><div class="ph">点选任务查看详情（前置/被依赖/关联文档可点跳转）</div></div></div>
<div id="msgs"></div>
<div id="help"><div>
 <b>任务依赖图 · 操作（对标 Shader Graph / ComfyUI）</b><br>
 <b>视图</b>：顶栏第三排页签——全图 DAG / 🧭制作人（派活台）/ ⚙程序 / 📐策划 / 🎨美术 / 🧪测试；URL #view= 可直达<br>
 <b>框选</b>：左键拖空白画虚线框，松开选中框内任务；Shift+点=加选/减选；Esc 清选<br>
 <b>平移</b>：中键拖 / 右键拖 / 空格+左键拖（三通道）；滚轮=缩放；双击空白=适配全图<br>
 <b>移动</b>：拖节点=移动；框选后拖任一选中节点=批量移动（自动遵守分割墙）<br>
 <b>建依赖</b>：从卡片<b>右缘外 9px 热区</b>按下拖到目标卡片松开 = a→b 前置边（会防自环/重复）<br>
 <b>删依赖</b>：点边选中（高亮）后按 Del；或右键边→删除依赖<br>
 <b>右键菜单</b>：选中任务右键=批量改状态（7 态）/✎编辑/✂拆解为子任务/🗑删除/复制 id；空白右键=新建任务<br>
 <b>认领（AI 调度接口）</b>：CLI <span style="font-family:var(--mono)">python tools/deptask/gen.py claim &lt;id&gt; --by &lt;AI名&gt;</span>
 ——认领后卡片 ◉agent 色边框呼吸+工位占用边；done 完成日志入底栏<br>
 <b>✂ 拆解</b>：策划 AI 拆解入口——右键任务→拆解为子任务，表单预填前置=父任务、id 自动编号<br>
 <b>编辑闭环</b>：改状态/连边/新建后节点右上角亮●角标——点「⬇ 导出源」下载完整 txt，
 覆盖 docs/项目/任务依赖图.txt 后跑 <b>python tools/deptask/gen.py --check</b>（有错误禁派活）<br>
 <b>快捷键</b>：N 新建 · F 适配 · T 塔台巡航 · G 泳道带重排 · L 活跃面 · D 底栏折叠 · C 关键路径 · R 就绪集 · 1-6 切视图<br>
 <b>底栏</b>（Tab 键折叠）：▦运行图=泳道带×时间的任务条（火车运行图：滚轮缩放/拖拽平移/点条跳主图，
 运行中条=右缘琥珀光标，描边色=认领 agent）· ≡调度日志=事件流（悬停行联动主图高亮）<br>
 <b>vbar 工具条</b>：布局（▦泳道带/⟲交叉最小）· 状态七态筛选 · ◌微任务/✓完成区显隐 · 数据源（全部/真实/SIM）· 缩放组 · ✈塔台巡航（镜头 3.2s/站轮巡已认领任务）<br>
 <b>调度 chips</b>：✓校验 / 🚦可派（就绪集高亮）/ 🛤关键路径（最长链琥珀蚂蚁线）<br>
 <b>泳道胶囊</b>：单击=聚拢该线（前沿列左/后沿列右，再点退出且坐标不丢）· Alt+单击=显隐<br>
 点节点=详情（前置/被依赖/关联文档可点跳转）· 悬停=高亮上下游依赖链 · 双击节点=居中放大<br>
 右下小地图=点击/拖动跳转 · 拖分割墙=右区整体平移（节点只有变完成才能过墙）<br>
 <span style="color:var(--sub)">布局引擎 dagre（mermaid 同款）+ litegraph 式端口贝塞尔 ·
 源文件一行一记录语法见 任务依赖图.txt 头注释</span>
</div></div>
<canvas id="cv"></canvas>
<canvas id="mini" width="180" height="120"></canvas>
<div id="cfoot"><span id="cfL"></span><span id="cfR" style="margin-left:auto"></span></div>
<script>/*__DAGRE__*/</script>
<script>const DATA=/*__DATA__*/null;</script>
<script>
"use strict";
const cv=document.getElementById("cv"),ctx=cv.getContext("2d");
const mini=document.getElementById("mini"),mctx=mini.getContext("2d");
const STATUS=["完成","待验收","进行中","可开工","阻塞","冻结","放弃"];
const ACTIVE=new Set(["进行中","待验收","完成"]);
const COL={"完成":"#22d3a0","待验收":"#fbbf24","进行中":"#fde047","可开工":"#38bdf8","阻塞":"#64748b","冻结":"#94a3b8","放弃":"#55677f"};
const LANE_COL=["#38bdf8","#a78bfa","#fb923c","#4ade80","#facc15","#f472b6","#22d3ee","#94a3b8"];
const FRAME_PAD=18,FRAME_TOP=34;
let BAR_H=80;  // 顶栏实际高度（resize 动态测量）：画布内容/分隔墙/聚拢标注从这条线以下开始
let dpr=1,VW=0,VH=0,animT=0;
const MONO='ui-monospace,"SF Mono","Cascadia Mono",Consolas,monospace';
const FONT_SM='11px "Segoe UI","Microsoft YaHei",sans-serif';
let nodes=DATA.nodes,edges=DATA.edges,lanes=DATA.lanes;
const manual0=nodes.some(n=>n.x!=null);
nodes.forEach(n=>{n.px=n.x!=null?n.x:0;n.py=n.y!=null?n.y:0;n.lines=[];n.cw=150;n.ch=56;n.inP=[];n.outP=[];});
const byId={};nodes.forEach(n=>byId[n.id]=n);
const prsOf={},blocksOf={};
nodes.forEach(n=>{prsOf[n.id]=[];blocksOf[n.id]=[];});
edges.forEach(e=>{if(prsOf[e.b]){prsOf[e.b].push(e.a);blocksOf[e.a].push(e.b);}});
nodes.forEach(n=>{(n.prs||[]).forEach(p=>{if(prsOf[n.id].indexOf(p)<0)prsOf[n.id].push(p);});});
let view={x:0,y:0,k:1},sel=null,selSet=new Set(),selEdge=null,hover=null,drag=null,hi=null,q="",dirty=true;
let spaceDown=false,editedIds=new Set(),dirtyEdits=false;
let laneVis={};lanes.forEach(l=>laneVis[l]=true);
// ── 簇（封装任务簇）：折叠时成员由虚拟簇节点代替，边聚合重定向 ──
const CLUSTERS=DATA.clusters||[];
const folded={},memberOf={};
CLUSTERS.forEach(c=>{folded[c.id]=!!c.folded;c.members.forEach(m=>memberOf[m]=c.id);});
let VN=[],VE=[],vById={};  // 视图层：当前生效的节点/边（折叠感知）
const ST_ORDER=["进行中","待验收","冻结","阻塞","可开工","完成","放弃"];
function aggStatus(ms){const has={};ms.forEach(m=>has[m.status]=1);
 for(const s of ST_ORDER)if(has[s])return s;return"阻塞";}
function rebuildView(){
 const inFolded=id=>memberOf[id]&&folded[memberOf[id]];
 VN=nodes.filter(n=>!inFolded(n.id));
 CLUSTERS.forEach(c=>{if(!folded[c.id])return;
  const ms=c.members.map(id=>byId[id]).filter(Boolean);
  const cx=ms.reduce((s,m)=>s+m.px+m.cw/2,0)/ms.length;
  const cy=ms.reduce((s,m)=>s+m.py+m.ch/2,0)/ms.length;
  const done=ms.filter(m=>m.status==="完成").length;
  const laneC={};ms.forEach(m=>laneC[m.lane]=(laneC[m.lane]||0)+1);
  const lane=Object.keys(laneC).sort((a,b)=>laneC[b]-laneC[a])[0]||"";
  VN.push({id:"簇:"+c.id,name:c.name,kind:"簇",lane:lane,status:aggStatus(ms),
   px:cx-110,py:cy-32,cw:220,ch:64,lines:[],inP:[],outP:[],isCluster:c,
   prs:c.members.flatMap(id=>prsOf[id]).filter(p=>!c.members.includes(p)),
   note:c.note,_clusterDone:done,_clusterN:ms.length});});
 const seen={};VE=[];vById={};VN.forEach(n=>vById[n.id]=n);
 edges.forEach(e=>{const a=inFolded(e.a)?"簇:"+memberOf[e.a]:e.a;
  const b=inFolded(e.b)?"簇:"+memberOf[e.b]:e.b;
  if(a===b)return;const k=a+"→"+b;if(seen[k])return;seen[k]=1;VE.push({a,b});});
 const vc=VN.filter(n=>n.isCluster);
 vc.forEach(v=>measureOne(v,236));
 // 聚拢模式与完成分割墙互斥：墙的左右强制对齐会拉散聚拢的 core/pre/post 布局
 if(!focusLane&&divideX==null){const done=VN.filter(n=>n.status==="完成");
  if(done.length)divideX=Math.max(...done.map(n=>n.px+n.cw))+34;}
 if(!focusLane)enforceDivide();
 computePorts();}
function measureOne(n,maxW){ // 单节点卡片测量（簇节点用更大宽度）
 n.lines=wrap(n.name,maxW,2);
 let w=0;n.lines.forEach(L=>w=Math.max(w,ctx.measureText(L).width));
 fontSmall();
 const extra=n.isCluster?26:0;
 const pw=ctx.measureText(n.status+(n.exempt?" ·豁免":"")).width+16;
 const idw=ctx.measureText(n.id).width;
 n.cw=Math.max(128,Math.min(n.isCluster?260:202,Math.max(w+22,pw+10,idw+18)));
 n.ch=11+n.lines.length*17+7+18+extra;}
function ancestors(id){const s=new Set(),st=[id];while(st.length){(prsOf[st.pop()]||[]).forEach(p=>{if(!s.has(p)){s.add(p);st.push(p);}});}return s;}
function descendants(id){const s=new Set(),st=[id];while(st.length){(blocksOf[st.pop()]||[]).forEach(b=>{if(!s.has(b)){s.add(b);st.push(b);}});}return s;}
function laneHidden(l){return l&&laneVis[l]===false;}
let viewFilter={};  // 岗位视图过滤（页签切换设置）：lanes=可见线集合 / ids=按任务判定函数
let statusFilter=new Set(),microOn=true,doneOn=true;  // view-bar 筛选态（跨视图保留）
function visNode(n){
 if(laneHidden(n.lane))return false;
 if(viewFilter.lanes&&!viewFilter.lanes.has(n.lane))return false;
 if(viewFilter.ids&&!viewFilter.ids(n))return false;
 if(statusFilter.size&&!statusFilter.has(n.status))return false;
 if(n.tier==="微"&&!microOn)return false;
 if(n.status==="完成"&&!doneOn)return false;
 return true;}
function nodeVisible(n){return visNode(n)&&(!q||n._hit);}
function resize(){dpr=window.devicePixelRatio||1;VW=innerWidth;VH=innerHeight;
 BAR_H=document.getElementById("bar").offsetHeight||80;  // 窄屏换行/媒体查询后顶栏高度跟随实测
 const top=BAR_H+"px";["sideL","sideR","dash"].forEach(id2=>{const el=document.getElementById(id2);
  if(el&&el.style.display!=="none")el.style.top=top;});
 cv.width=VW*dpr;cv.height=VH*dpr;cv.style.width=VW+"px";cv.style.height=VH+"px";dirty=true;}
addEventListener("resize",resize);resize();
function roundRect(c,x,y,w,h,r){c.beginPath();c.moveTo(x+r,y);c.arcTo(x+w,y,x+w,y+h,r);
 c.arcTo(x+w,y+h,x,y+h,r);c.arcTo(x,y+h,x,y,r);c.arcTo(x,y,x+w,y,r);c.closePath();}
function fontCard(){ctx.font='600 12.5px "Segoe UI","Microsoft YaHei",sans-serif';}
function fontSmall(){ctx.font='11px "Segoe UI","Microsoft YaHei",sans-serif';}
function wrap(text,maxW,maxLines){fontCard();const out=[];let cur="";
 for(const ch of text){const t=cur+ch;
  if(ctx.measureText(t).width>maxW&&cur){out.push(cur);cur=ch;
   if(out.length===maxLines-1){let rest=text.slice(text.indexOf(cur));
    while(rest&&ctx.measureText(rest+"…").width>maxW)rest=rest.slice(0,-1);
    out.push(rest+"…");return out;}}
  else cur=t;}
 if(cur)out.push(cur);return out;}
function measureCards(){fontCard();
 nodes.forEach(n=>{n.lines=wrap(n.name,186,2);
  let w=0;n.lines.forEach(L=>w=Math.max(w,ctx.measureText(L).width));
  fontSmall();const pw=ctx.measureText(n.status+(n.exempt?" ·豁免":"")).width+16;
  const idw=ctx.measureText(n.id).width;
  if(n.tier==="微"){ // 微任务：单行矮卡（几轮可完成的挂载项）
   n.lines=wrap(n.name,150,1);
   n.cw=Math.max(96,Math.min(170,w+20));n.ch=26;return;}
  n.cw=Math.max(128,Math.min(202,Math.max(w+22,pw+10,idw+18)));
  n.ch=11+n.lines.length*17+7+18;});}
function dagreLayout(){
 // 分区布局：完成子图与未完成子图各自独立 dagre，墙 = 两区中缝
 // 关键：只排「可见」节点——岗位视图过滤掉的任务不参与分层，否则隐藏节点占位把可见任务撑散
 const vis=VN.filter(n=>visNode(n));
 const D=vis.filter(n=>n.status==="完成"),U=vis.filter(n=>n.status!=="完成");
 layoutSub(D,30);
 const dRight=D.length?Math.max(...D.map(n=>n.px+n.cw)):0;
 layoutSub(U,dRight+110);
 divideX=(D.length?dRight:0)+55;
 computePorts();}
function layoutSub(set,gapLeft){
 if(!set.length)return;
 const g=new dagre.graphlib.Graph({multigraph:true});
 g.setGraph({rankdir:"LR",nodesep:26,ranksep:78,marginx:30,marginy:30});
 g.setDefaultEdgeLabel(()=>({}));
 const ids=new Set(set.map(n=>n.id));
 set.forEach(n=>g.setNode(n.id,{width:n.cw,height:n.ch}));
 VE.forEach(e=>{if(ids.has(e.a)&&ids.has(e.b))g.setEdge(e.a,e.b,{minlen:1,weight:2});});
 dagre.layout(g);
 let minX=1e9;set.forEach(n=>{const gn=g.node(n.id);minX=Math.min(minX,gn.x-n.cw/2);});
 set.forEach(n=>{const gn=g.node(n.id);const nx=gn.x-n.cw/2-minX+gapLeft,ny=gn.y-n.ch/2;
  if(n.isCluster){const dx=nx-n.px,dy=ny-n.py;
   n.px=nx;n.py=ny;
   n.isCluster.members.forEach(id=>{const m=byId[id];m.px+=dx;m.py+=dy;});}
  else{n.px=nx;n.py=ny;}});
}
function computePorts(){
 VN.forEach(n=>{n.inP=[];n.outP=[];});
 VE.forEach(e=>{const a=vById[e.a],b=vById[e.b];if(!a||!b)return;
  a.outP.push({e,y:0});b.inP.push({e,y:0});});
 VN.forEach(n=>{
  const sortIn={},sortOut={};
  VE.forEach(e=>{if(e.b===n.id){const a=vById[e.a];if(a)sortIn[e.a+"|"+e.b]=a.py+a.ch/2;}
   if(e.a===n.id){const b=vById[e.b];if(b)sortOut[e.a+"|"+e.b]=b.py+b.ch/2;}});
  n.inP.sort((p,q)=>(sortIn[p.e.a+"|"+p.e.b]||0)-(sortIn[q.e.a+"|"+q.e.b]||0));
  n.outP.sort((p,q)=>(sortOut[p.e.a+"|"+p.e.b]||0)-(sortOut[q.e.a+"|"+q.e.b]||0));
  n.inP.forEach((p,i)=>p.y=n.py+n.ch*(i+1)/(n.inP.length+1));
  n.outP.forEach((p,i)=>p.y=n.py+n.ch*(i+1)/(n.outP.length+1));});}
function edgeGeom(e){ // litegraph SPLINE_LINK：控制点 = 端口方向 × 0.25×间距
 const a=vById[e.a],b=vById[e.b];
 const pa=a.outP.find(p=>p.e===e),pb=b.inP.find(p=>p.e===e);
 const x1=a.px+a.cw,y1=pa?pa.y:a.py+a.ch/2;
 const x2=b.px,y2=pb?pb.y:b.py+b.ch/2;
 const q=Math.hypot(x2-x1,y2-y1)||1,dx=Math.max(30,q*0.25);
 return{x1,y1,x2,y2,c1x:x1+dx,c1y:y1,c2x:x2-dx,c2y:y2};}
function edgeBad(e){const a=vById[e.a],b=vById[e.b];
 return a&&b&&a.status!=="完成"&&ACTIVE.has(b.status);}
const COLW=240;
function laneBandLayout(){ // 泳道带状布局 v2：行=泳道水平带，列=依赖深度（同带同深度垂直堆叠）——横平竖直
 const vis=VN.filter(n=>visNode(n));
 const visIds=new Set(vis.map(n=>n.id));
 const deps={},depth={},visiting=new Set();
 vis.forEach(n=>deps[n.id]=(n.prs||[]).filter(p=>visIds.has(p)&&p!==n.id));
 function dp(i){if(depth[i]!=null)return depth[i];if(visiting.has(i))return 0;
  visiting.add(i);
  const d=deps[i].length?1+Math.max(...deps[i].map(dp)):0;
  visiting.delete(i);depth[i]=d;return d;}
 vis.forEach(n=>dp(n.id));
 const laneIdx={};lanes.forEach((l,i)=>laneIdx[l]=i);
 const doneVis=vis.filter(n=>n.status==="完成"),undoneVis=vis.filter(n=>n.status!=="完成");
 function place(set,x0){
  const bands={};
  set.forEach(n=>{const li=laneIdx[n.lane]!=null?laneIdx[n.lane]:999;bands[li]=bands[li]||[];bands[li].push(n);});
  let yBase=30;
  Object.keys(bands).map(Number).sort((a,b)=>a-b).forEach(li=>{
   const arr=bands[li].sort((a,b)=>(depth[a.id]-depth[b.id])||(a.id<b.id?-1:1));
     const cols={};                                   // depth 列 → 垂直堆叠队列
   arr.forEach(n=>{(cols[depth[n.id]]=cols[depth[n.id]]||[]).push(n);});
   let bandH=0;
   Object.keys(cols).map(Number).sort((a,b)=>a-b).forEach(d=>{
    cols[d].forEach((n,i)=>{
     n.px=x0+d*COLW;
     n.py=yBase+i*(n.ch+8);
     bandH=Math.max(bandH,(i+1)*(n.ch+8));});});
   yBase+=bandH+24;});
  return yBase;}
 let endY=place(doneVis,30);
 const dMax=doneVis.length?Math.max(...doneVis.map(n=>n.px+n.cw)):0;
 endY=Math.max(endY,place(undoneVis,dMax+110));
 divideX=(doneVis.length?dMax:0)+55;
 computePorts();}
function laneFrames(){
 const fr={};
 VN.forEach(n=>{if(!n.lane||!visNode(n))return;
  const f=fr[n.lane]||(fr[n.lane]={minX:1e9,minY:1e9,maxX:-1e9,maxY:-1e9,n:0});
  f.minX=Math.min(f.minX,n.px);f.minY=Math.min(f.minY,n.py);
  f.maxX=Math.max(f.maxX,n.px+n.cw);f.maxY=Math.max(f.maxY,n.py+n.ch);f.n++;});
 return fr;}
function draw(){
 ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.fillStyle="#080c14";ctx.fillRect(0,0,VW,VH);
 if(view.k*40>=9){ctx.strokeStyle="#101927";ctx.lineWidth=1;ctx.beginPath();
  const x0=Math.floor(-view.x/view.k/40)*40,y0=Math.floor(-view.y/view.k/40)*40,
        x1=(-view.x+VW)/view.k,y1=(-view.y+VH)/view.k;
  for(let x=x0;x<x1;x+=40){const sx=x*view.k+view.x;ctx.moveTo(sx,0);ctx.lineTo(sx,VH);}
  for(let y=y0;y<y1;y+=40){const sy=y*view.k+view.y;ctx.moveTo(0,sy);ctx.lineTo(VW,sy);}
  ctx.stroke();}
 ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);
 // 泳道分组框（LOGIC-8 ACCENT 域色）
 const fr=laneFrames();
 lanes.forEach((ln,i)=>{if(laneVis[ln]===false)return;const f=fr[ln];if(!f)return;
  const c=LANE_COL[i%LANE_COL.length];
  const x=f.minX-FRAME_PAD,y=f.minY-FRAME_PAD-FRAME_TOP+14;
  const w=f.maxX-f.minX+FRAME_PAD*2,h=f.maxY-f.minY+FRAME_PAD*2+FRAME_TOP-14;
  ctx.fillStyle=c+"09";roundRect(ctx,x,y,w,h,3);ctx.fill();
  ctx.strokeStyle=c+"33";ctx.lineWidth=1;ctx.stroke();
  ctx.fillStyle=c;ctx.font="600 10px "+MONO;
  ctx.fillText("[ "+ln+" · "+f.n+" ]",x+12,y+15);
  ctx.font=FONT_SM;});
 CLUSTERS.forEach(c=>{if(folded[c.id])return;
  const ms=c.members.map(id=>byId[id]).filter(Boolean);if(!ms.length)return;
  const x0=Math.min(...ms.map(m=>m.px))-12,y0=Math.min(...ms.map(m=>m.py))-26;
  const x1=Math.max(...ms.map(m=>m.px+m.cw))+12,y1=Math.max(...ms.map(m=>m.py+m.ch))+12;
  const li=lanes.indexOf(ms[0].lane),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  ctx.strokeStyle=lc+"55";ctx.lineWidth=1;ctx.setLineDash([6,4]);
  roundRect(ctx,x0,y0,x1-x0,y1-y0,3);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle=lc+"cc";fontSmall();ctx.textAlign="left";
  ctx.fillText("▣ "+c.name+"（点击收起）",x0+10,y0+14);});
 const anc=hi?ancestors(hi):null,des=hi?descendants(hi):null;
 const cs=(critOnly&&CRIT.length)?new Set(CRIT):null;
 const lit=id=>(!hi&&!cs)||id===hi||(anc&&anc.has(id))||(des&&des.has(id))||(cs&&cs.has(id));
 // 边（端口对端口贝塞尔）
 VE.forEach(e=>{const a=vById[e.a],b=vById[e.b];if(!a||!b||!visNode(a)||!visNode(b))return;
  const on=lit(e.a)&&lit(e.b),bad=edgeBad(e),isSel=selEdge&&selEdge.a===e.a&&selEdge.b===e.b;
  const g=edgeGeom(e);
  const isCrit=cs&&cs.has(e.a)&&cs.has(e.b);
  const sameLane=a.lane&&a.lane===b.lane;
  const li=lanes.indexOf(a.lane),laneC=LANE_COL[(li<0?0:li)%LANE_COL.length];
  let color,w;
  if(isSel||isCrit){color="#fde047";w=2.4;}                       // 选中边/关键路径=亮黄
  else if(bad){color="#f87171";w=2;}                              // 违规=红
  else if(hi===e.b){color="#38bdf8";w=2.2;}                       // 悬停节点的上游入边=天蓝
  else if(hi===e.a){color="#fbbf24";w=2.2;}                       // 悬停节点的下游出边=琥珀
  else if(byId[e.b]&&byId[e.b].claim&&byId[e.b].status!=="完成"){ // 认领任务的前置=agent 色细线（工位占用）
   color=agentColor(byId[e.b].claim)+"99";w=1.3;}
  else if(on){color="#38bdf8dd";w=2;}                             // 链高亮
  else if(sameLane){color=laneC+"88";w=1.5;}                      // 同泳道=领域色
  else{color="#243348";w=1;}                                      // 跨泳道=暗灰细
  ctx.strokeStyle=color;ctx.lineWidth=w;
  if(isCrit){ctx.setLineDash([9,7]);ctx.lineDashOffset=-(animT*0.55)%16;
   ctx.shadowColor="#fde047";ctx.shadowBlur=8;}
  else if(sameLane){ctx.setLineDash([]);}
  let ea=on?1:((hi||cs)?0.12:0.85);
  if(isCrit)ea=1;
  if(focusLane&&vById[e.a]&&vById[e.b]&&vById[e.a]._f==="other"&&vById[e.b]._f==="other")ea*=0.1;
  ctx.globalAlpha=ea;
  ctx.beginPath();ctx.moveTo(g.x1,g.y1);
  ctx.bezierCurveTo(g.c1x,g.c1y,g.c2x,g.c2y,g.x2,g.y2);ctx.stroke();
  if(bad){ctx.setLineDash([6,4]);ctx.beginPath();ctx.moveTo(g.x1,g.y1);
   ctx.bezierCurveTo(g.c1x,g.c1y,g.c2x,g.c2y,g.x2,g.y2);ctx.stroke();ctx.setLineDash([]);}
  // 箭头：沿末端切线方向
  const ang=Math.atan2(g.y2-g.c2y,g.x2-g.c2x);
  ctx.fillStyle=ctx.strokeStyle;ctx.beginPath();
  ctx.moveTo(g.x2+1,g.y2);
  ctx.lineTo(g.x2-8*Math.cos(ang-0.42),g.y2-8*Math.sin(ang-0.42));
  ctx.lineTo(g.x2-8*Math.cos(ang+0.42),g.y2-8*Math.sin(ang+0.42));
  ctx.closePath();ctx.fill();ctx.globalAlpha=1;
  if(isCrit){ctx.setLineDash([]);ctx.shadowBlur=0;}});
 // 节点
 const order=VN.slice().sort((a,b)=>((a.id===hi||a.id===sel)?1:0)-((b.id===hi||b.id===sel)?1:0));
 const vp={x0:-view.x/view.k-60,y0:-view.y/view.k-60,x1:(VW-view.x)/view.k+60,y1:(VH-view.y)/view.k+60};
 order.forEach(n=>{if(!nodeVisible(n))return;
  if(n.px+n.cw<vp.x0||n.px>vp.x1||n.py+n.ch<vp.y0||n.py>vp.y1)return;  // 视口裁剪：大数据流畅关键
  let dim=q?(n._hit?1:0.1):(hi?(n.id===hi||anc.has(n.id)||des.has(n.id)?1:0.16):1);
  if(focusLane&&n._f==="other")dim*=0.13;
  if(readyOnly&&n.status!=="完成"&&READY.indexOf(n.id)<0)dim*=0.08;
  if(cs&&!hi&&!cs.has(n.id))dim*=0.12;
  const x=n.px,y=n.py,w=n.cw,h=n.ch,c=COL[n.status];
  const li=lanes.indexOf(n.lane),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  ctx.globalAlpha=dim;
  const isDone=n.status==="完成";
  ctx.fillStyle=isDone?lc+"1a":"#111a29";roundRect(ctx,x,y,w,h,4);ctx.fill();  // 完成=泳道色淡底（区分领域）
  ctx.strokeStyle=n.id===sel?"#f472b6":(isDone?lc:"#2b3f5a");ctx.lineWidth=n.id===sel?2:(n.tier==="微"?1:1.2);  // 完成=泳道色边框
  if(n.exempt)ctx.setLineDash([4,3]);
  roundRect(ctx,x,y,w,h,4);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle=lc;ctx.fillRect(x+1,y+1,4,h-2);            // 泳道色条
  ctx.fillStyle=c;ctx.fillRect(x+5,y+6,3,h-12);            // 状态色条
  if(n.kind==="里程碑"){ctx.fillStyle=c;ctx.font='11px sans-serif';ctx.fillText("◆",x+14,y+17);}
  if(n.kind==="簇"){ctx.fillStyle=c;ctx.font='11px sans-serif';ctx.fillText("▣",x+14,y+17);
   fontSmall();ctx.fillStyle="#9aa7b4";
   ctx.fillText("已完 "+n._clusterDone+"/"+n._clusterN+" · 点击展开/收起",x+11,y+h-1);}
  ctx.fillStyle="#e6edf3";fontCard();ctx.textAlign="left";
  n.lines.forEach((L,i)=>ctx.fillText(L,x+18+((n.kind==="里程碑"&&i===0)?13:0),y+23+i*17));
  fontSmall();const st=n.claim&&n.status!=="完成"?(n.claim+" · 已认领"):(n.status+(n.exempt?" ·豁免":""));
  const pw=ctx.measureText(st).width+12;
  ctx.fillStyle=c+"1f";roundRect(ctx,x+9,y+h-24,pw,16,3);ctx.fill();
  ctx.fillStyle=c;ctx.fillText(st,x+15,y+h-12);
  if(n.tree){ctx.fillStyle="#6e7a87";ctx.fillText("⌂ "+n.tree,x+9+pw+8,y+h-12);}
  const claimed=n.claim&&n.status!=="完成"&&n.status!=="放弃";
  if(claimed){ // 已认领：agent 色边框+呼吸辉光+角标（机场调度"航班占用"标识）
   const ac=agentColor(n.claim);
   ctx.strokeStyle=ac;ctx.lineWidth=2.2;
   const pulse=0.5+0.5*Math.sin(animT*0.07);
   ctx.shadowColor=ac;ctx.shadowBlur=3+5*pulse;
   roundRect(ctx,x,y,w,h,4);ctx.stroke();ctx.shadowBlur=0;
   ctx.fillStyle=ac;ctx.font="700 9px "+MONO;
   const tag="◉ "+n.claim+claimDurText(n.id);
   ctx.fillText(tag,x+w-10-ctx.measureText(tag).width,y+14);}
  if(n.tier==="微"){ // 微任务单行：点+名称+状态字
   ctx.fillStyle=c;ctx.beginPath();ctx.arc(x+10,y+h/2,3,0,7);ctx.fill();
   ctx.fillStyle="#c9d4e0";fontSmall();ctx.fillText(n.name,x+18,y+16);
   ctx.fillStyle=c;ctx.fillText(n.status,x+w-ctx.measureText(n.status).width-8,y+16);
   ctx.globalAlpha=1;return;}
  if(n.id!==sel&&selSet.has(n.id)){ctx.strokeStyle="#f472b688";roundRect(ctx,x-2,y-2,w+4,h+4,9);ctx.stroke();}
  if(n.id===hover&&n.id!==sel){ctx.strokeStyle="#93c5fd";ctx.lineWidth=1.5;roundRect(ctx,x-3,y-3,w+6,h+6,9);ctx.stroke();}
  if(editedIds.has(n.id)){ctx.fillStyle="#e3b341";ctx.beginPath();ctx.arc(x+w-7,y+7,3.5,0,7);ctx.fill();}
  if((n.prs||[]).indexOf(n.id)>=0){ // 自环=自复验回路：右上 ◌ 弧箭头
   ctx.strokeStyle=c;ctx.lineWidth=1.3;ctx.beginPath();ctx.arc(x+w-15,y+9,4.5,-0.6,4.2);ctx.stroke();
   ctx.fillStyle=c;ctx.beginPath();ctx.moveTo(x+w-9,y+13);ctx.lineTo(x+w-11.5,y+8.5);ctx.lineTo(x+w-6.5,y+9.5);ctx.closePath();ctx.fill();}
  ctx.globalAlpha=1;});
 ctx.textAlign="left";
 // 框选矩形 / 连线预览（屏幕层）
 if(drag&&drag.box){ctx.setTransform(dpr,0,0,dpr,0,0);
  const x=Math.min(drag.sx,drag.cx),y=Math.min(drag.sy,drag.cy),
        w=Math.abs(drag.cx-drag.sx),h=Math.abs(drag.cy-drag.sy);
  ctx.fillStyle="#38bdf81c";ctx.fillRect(x,y,w,h);
  ctx.strokeStyle="#38bdf8";ctx.setLineDash([5,4]);ctx.lineWidth=1;ctx.strokeRect(x,y,w,h);ctx.setLineDash([]);
  ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);}
 if(drag&&drag.link){const a=byId[drag.from];
  if(a){const x1=a.px+a.cw,y1=a.py+a.ch/2,x2=(drag.cx-view.x)/view.k,y2=(drag.cy-view.y)/view.k;
   const q3=Math.hypot(x2-x1,y2-y1)||1,dx=Math.max(30,q3*0.25);
   ctx.strokeStyle="#22d3ee";ctx.lineWidth=2;ctx.setLineDash([6,4]);
   ctx.beginPath();ctx.moveTo(x1,y1);ctx.bezierCurveTo(x1+dx,y1,x2-dx,y2,x2,y2);ctx.stroke();ctx.setLineDash([]);}}
 drawDivide();
 drawFocusLines();
 drawMini();drawZoom();
 dirty=false;}
function drawFocusLines(){if(!focusLane||!focusLines)return;
 ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.font='12px "Segoe UI","Microsoft YaHei",sans-serif';
 const draw=(wx,color,label)=>{const sx=wx*view.k+view.x;
  if(sx<-20||sx>VW+20)return;
  ctx.strokeStyle=color;ctx.lineWidth=2;ctx.setLineDash([8,5]);
  ctx.beginPath();ctx.moveTo(sx,BAR_H);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle=color;ctx.fillText(label,sx+8,BAR_H+16);};
 if(focusLines.pre!=null)draw(focusLines.pre,"#fbbf24","◤ 前沿（外部前置）");
 if(focusLines.post!=null)draw(focusLines.post,"#22d3ee","后继（外部被依赖）◢");
 ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);}
let showDivide=true,divideX=(DATA.divideX!=null?DATA.divideX:null),divideHover=false;
function initDivide(){if(divideX!=null)return;
 const done=VN.filter(n=>n.status==="完成");if(!done.length)return;
 divideX=Math.max(...done.map(n=>n.px+n.cw))+34;}
function enforceDivide(){if(divideX==null)return;
 // 未完成任务若在线左 → 推到线右；完成任务若在线右 → 收回线左；折叠簇成员跟随卡片
 VN.forEach(n=>{const doneSide=n.status==="完成";
  if(doneSide&&n.px+n.cw/2>divideX)n.px=divideX-8-n.cw;
  if(!doneSide&&n.px+n.cw/2<divideX)n.px=divideX+8;});
 VN.forEach(n=>{if(n.isCluster&&n.status==="完成"){
  const target=divideX-8-n.cw,dx=target-n.px;
  if(Math.abs(dx)>0.5){n.px=target;n.isCluster.members.forEach(id=>{const m=byId[id];m.px+=dx;});}}});}
function drawDivide(){if(!showDivide||divideX==null)return;
 const sx=divideX*view.k+view.x;
 ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.fillStyle="#22d3a00d";ctx.fillRect(0,BAR_H,sx,VH-BAR_H);
 ctx.strokeStyle="#22d3a066";ctx.lineWidth=1.5;ctx.setLineDash([10,6]);
 ctx.beginPath();ctx.moveTo(sx,BAR_H);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
 ctx.strokeStyle=divideHover?"#22d3a0":"#22d3a066";ctx.lineWidth=divideHover?2.5:1.5;
 ctx.setLineDash([10,6]);ctx.beginPath();ctx.moveTo(sx,BAR_H);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
 ctx.fillStyle="#22d3a0";fontSmall();ctx.textAlign="left";
 ctx.fillText("✂ 已完成（左）",Math.max(4,sx-110),BAR_H+14);
 ctx.fillStyle="#fbbf24";ctx.fillText("未完成（右）",sx+10,BAR_H+14);
 ctx.fillStyle="#9aa7b4";ctx.font='10px sans-serif';
 ctx.fillText("⟷ 可拖动：右区整体平移·两侧独立",Math.max(4,sx-110),BAR_H+28);
 ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);}
function drawMini(){mctx.setTransform(1,0,0,1,0,0);mctx.clearRect(0,0,180,120);
 const g=graphBBox();if(!g)return;
 const s=Math.min(168/g.w,104/g.h),ox=(180-g.w*s)/2,oy=(120-g.h*s)/2;
 VN.forEach(n=>{if(!visNode(n))return;
  mctx.fillStyle=COL[n.status];
  mctx.fillRect(ox+(n.px-g.minX)*s,oy+(n.py-g.minY)*s,Math.max(2,n.cw*s),Math.max(1.5,n.ch*s));});
 const wx=(-view.x)/view.k,wy=(-view.y)/view.k;
 mctx.strokeStyle="#58a6ff";mctx.lineWidth=1;
 mctx.strokeRect(ox+(wx-g.minX)*s,oy+(wy-g.minY)*s,VW/view.k*s,VH/view.k*s);
 mini._map={s,ox,oy,g};}
function drawZoom(){const cfL=document.getElementById("cfL");if(!cfL)return;
 const vis=VN.filter(n=>visNode(n)).length;
 cfL.textContent="可见 "+vis+"/"+nodes.length+" · "+Math.round(view.k*100)+"%";
 document.getElementById("cfR").textContent="🚦 就绪 "+READY.length+" · 🛤 关键路径 "+Math.max(0,CRIT.length-1)+" 跳";
 document.getElementById("cfoot").style.display=(curView==="producer")?"none":"flex";}
function graphBBox(){const vis=VN.filter(n=>visNode(n)&&(!focusLane||n._f!=="other"));
 if(!vis.length)return null;
 const xs=vis.map(n=>n.px),ys=vis.map(n=>n.py);
 return{minX:Math.min(...xs)-60,minY:Math.min(...ys)-80,
  w:Math.max(...xs.map((v,i)=>v+vis[i].cw))-Math.min(...xs)+120,
  h:Math.max(...ys.map((v,i)=>v+vis[i].ch))-Math.min(...ys)+140};}
function sideW(){const l=document.getElementById("sideL"),r=document.getElementById("sideR");
 return{L:(l&&l.style.display!=="none")?(l.offsetWidth||248):0,R:(r&&r.style.display!=="none")?(r.offsetWidth||308):0};}
let flyRAF=null;
function flyTo(wx,wy,k){ // 特写镜头：缓动飞向目标（侧栏避让后的可视中心）
 const s=sideW();k=k||view.k;
 const tx=s.L+(VW-s.L-s.R)/2-wx*k,ty=Math.max(BAR_H,VH/2-wy*k);
 const f={x:view.x,y:view.y,k:view.k},st=performance.now(),dur=460;
 if(flyRAF)cancelAnimationFrame(flyRAF);
 const step=ts=>{const u=Math.min(1,(ts-st)/dur),e=u<.5?2*u*u:1-Math.pow(-2*u+2,2)/2;
  view.x=f.x+(tx-f.x)*e;view.y=f.y+(ty-f.y)*e;view.k=f.k+(k-f.k)*e;dirty=true;
  if(u<1)flyRAF=requestAnimationFrame(step);};
 flyRAF=requestAnimationFrame(step);}
function centerOn(wx,wy,k){const s=sideW();if(k)view.k=k;
 view.x=s.L+(VW-s.L-s.R)/2-wx*view.k;view.y=Math.max(BAR_H,VH/2-wy*view.k);dirty=true;}
function fitAll(){const g=graphBBox();const s=sideW();
 view.k=Math.min((VW-s.L-s.R-30)/g.w,(VH-BAR_H-40)/g.h,1.2);
 view.x=s.L+(VW-s.L-s.R-g.w*view.k)/2-g.minX*view.k;
 view.y=Math.max(BAR_H,(VH-g.h*view.k)/2)-g.minY*view.k;dirty=true;}
function locateActive(){const act=VN.filter(n=>ACTIVE.has(n.status)||n.status==="可开工");
 const t=act.length?act:VN;
 const xs=t.map(n=>n.px+n.cw/2),ys=t.map(n=>n.py+n.ch/2);
 centerOn((Math.min(...xs)+Math.max(...xs))/2,(Math.min(...ys)+Math.max(...ys))/2,1);}
function relayout(){focusLane=null;focusLines=null;VN.forEach(n=>{if(!n.isCluster){n.x=null;n.y=null;}});
 divideX=null;laneBandLayout();rebuildView();fitAll();dirty=true;}
let focusLane=null,focusLines=null,focusSnapshot=null;  // 快照：进入聚拢前的各节点坐标，退出时恢复（手动布局不丢）
function applyFocus(){
 if(!focusLane){initDivide();rebuildView();locateActive();dirty=true;return;}  // 防呆分支：不走 relayout（会清手动布局）
 const vis=n=>!laneHidden(n.lane);  // 被隐藏的线不参与聚拢布局（显隐与聚拢正交）
 const inS=VN.filter(n=>n.lane===focusLane&&vis(n));
 const inIds=new Set(inS.map(n=>n.id));
 const isPre=n=>VE.some(e=>e.a===n.id&&inIds.has(e.b));
 const isBlk=n=>VE.some(e=>e.b===n.id&&inIds.has(e.a));
 const extP=VN.filter(n=>!n.isCluster&&vis(n)&&!inIds.has(n.id)&&isPre(n)&&!isBlk(n));
 const extB=VN.filter(n=>!n.isCluster&&vis(n)&&!inIds.has(n.id)&&isBlk(n)&&!isPre(n));
 const both=VN.filter(n=>!n.isCluster&&vis(n)&&!inIds.has(n.id)&&isPre(n)&&isBlk(n));
 const others=VN.filter(n=>!n.isCluster&&vis(n)&&n!==null&&!inIds.has(n.id)&&!extP.includes(n)&&!extB.includes(n)&&!both.includes(n));
 const clus=VN.filter(n=>n.isCluster);
 VN.forEach(n=>n._f="other");
 inS.forEach(n=>n._f="core");extP.forEach(n=>n._f="pre");
 extB.forEach(n=>n._f="post");both.forEach(n=>n._f="both");clus.forEach(n=>n._f="other");
 const pRight=extP.length?Math.max(...extP.map(n=>n.px+n.cw)):30;
 layoutSub(extP,30);
 layoutSub(inS,pRight+110);
 layoutSub(both,(inS.length?Math.max(...inS.map(n=>n.px+n.cw)):pRight)+110);
 layoutSub(extB,(both.length?Math.max(...both.map(n=>n.px+n.cw)):inS.length?Math.max(...inS.map(n=>n.px+n.cw)):pRight)+110);
 layoutSub(clus.concat(others),(extB.length?Math.max(...extB.map(n=>n.px+n.cw)):0)+160);
 focusLines=null;
 if(inS.length&&extP.length)focusLines={pre:(Math.max(...extP.map(n=>n.px+n.cw))+Math.min(...inS.map(n=>n.px)))/2};
 if(extB.length)focusLines={...focusLines,post:(Math.max(...inS.map(n=>n.px+n.cw))+Math.min(...extB.map(n=>n.px)))/2};
 computePorts();dirty=true;}
function docHref(p){return "../"+String(p).replace(/^docs\//,"");}
function showPanel(n){const p=document.getElementById("inspector");
 const chip=(id)=>{const t=byId[id];return"<span class='tag' onclick='jump(\""+id+"\")'>"+(t?t.name:id)+" · "+(t?t.status:"?")+"</span>";};
 const inReady=READY.indexOf(n.id),inCrit=CRIT.indexOf(n.id);
 const ctxBits=["前置 "+((n.prs||[]).length),"被依赖 "+(blocksOf[n.id].length)];
 if(inReady>=0)ctxBits.push("🚦 就绪中");
 if(inCrit>0)ctxBits.push("🛤 关键路径第 "+(inCrit+1)+" 跳");
 if(n.kind==="里程碑")ctxBits.push("收口门");
 p.innerHTML="<h3>"+(n.kind==="里程碑"?"◆ ":"")+n.name+"</h3>"
 +"<div class='ctxrow'>"+ctxBits.map(function(x){return "<span"+(x.indexOf("🛤")>=0?" style='color:var(--amber)'":"")+">"+x+"</span>";}).join(" · ")
 +"　<span style='cursor:pointer;color:#79b8ff' title='相关项小窗：前置/被依赖迷你卡' onclick='relPopup(this.dataset.t)' data-t='"+n.id+"'>⧉ 浮窗</span></div>"
 +"<div style='margin:6px 14px 0'><span class='tag' style='cursor:default;color:"+COL[n.status]+"'>"+n.status+"</span>"
 +(n.lane?"<span class='tag' style='cursor:default'>"+n.lane+"</span>":"")
 +(n.tree?"<span class='tag' style='cursor:default'>⌂ "+n.tree+"</span>":"")
 +(n.claim?"<span class='tag' style='cursor:default;color:var(--amber)'>◉ 认领者 "+n.claim+"</span>":"")+"</div>"
 +(selSet.size>1?"<div class='row'>已框选 "+selSet.size+" 个（拖动批量移动 / 右键批量改状态）</div>":"")
 +(n.domain&&n.domain.length?"<div class='row'>文件域："+n.domain.join(", ")+"</div>":"")
 +(n.doc?"<div class='row'>📄 <a style='color:#79b8ff' href='"+docHref(n.doc)+"'>"+n.doc+"</a></div>":"")
 +(n.prs&&n.prs.length?"<div class='row'>前置（点击跳转）：<br>"+n.prs.map(chip).join("")+"</div>":"")
 +(blocksOf[n.id].length?"<div class='row'>被依赖：<br>"+blocksOf[n.id].map(chip).join("")+"</div>":"")
 +(n.note?"<div class='row' style='color:#c3cdd8'>"+n.note+"</div>":"")
 +(n.exempt?"<div class='row' style='color:var(--amber)'>⚠ 豁免派活校验（见注）</div>":"")
 +"<div class='row' style='color:#55677f;font:600 10px var(--mono)'>"+n.id+"</div>";
 if(curView!=="producer")document.getElementById("sideR").style.display="flex";}
function jump(id){const cid=memberOf[id];if(cid&&folded[cid]){folded[cid]=false;rebuildView();}
 const n=byId[id];if(!n)return;sel=id;selSet=new Set([id]);selEdge=null;
 showPanel(n);flyTo(n.px+n.cw/2,n.py+n.ch/2,1.05);}
// ── 交互（对标 Shader Graph / ComfyUI：左键框选，中键/右键/空格+左键平移，端口连线建边） ──
function toWorld(ev){return{x:(ev.clientX-view.x)/view.k,y:(ev.clientY-view.y)/view.k};}
function nodeAt(x,y){for(let i=VN.length-1;i>=0;i--){const n=VN[i];
 if(!nodeVisible(n))continue;
 if(x>=n.px&&x<=n.px+n.cw&&y>=n.py&&y<=n.py+n.ch)return n;}return null;}
function portAt(x,y){for(let i=VN.length-1;i>=0;i--){const n=VN[i];   // 输出热区：右缘外 9px
 if(!nodeVisible(n)||n.isCluster)continue;
 if(x>=n.px+n.cw-1&&x<=n.px+n.cw+9&&y>=n.py&&y<=n.py+n.ch)return n;}return null;}
function bez(t,g){const u=1-t;return{x:u*u*u*g.x1+3*u*u*t*g.c1x+3*u*t*t*g.c2x+t*t*t*g.x2,
 y:u*u*u*g.y1+3*u*u*t*g.c1y+3*u*t*t*g.c2y+t*t*t*g.y2};}
function edgeAt(x,y){let best=null,bd=8;VE.forEach(e=>{const g=edgeGeom(e);
 for(let i=0;i<=16;i++){const q2=bez(i/16,g),d=Math.hypot(q2.x-x,q2.y-y);if(d<bd){bd=d;best=e;}}});
 return best;}
function markEdit(id){editedIds.add(id);dirtyEdits=true;
 const b=document.getElementById("exportBtn");if(b)b.textContent="⬇ 导出源 ●";}
function addEdge(a,b){if(a===b||!byId[b])return false;
 const t=byId[b];
 if(t.prs.indexOf(a)>=0&&edges.some(e=>e.a===a&&e.b===b))return false;  // 已存在=幂等拒绝
 if(t.prs.indexOf(a)<0)t.prs.push(a);
 if(!edges.some(e=>e.a===a&&e.b===b))edges.push({a,b});
 markEdit(a);markEdit(b);return true;}
function delEdge(e){const i=edges.findIndex(x=>x.a===e.a&&x.b===e.b);if(i>=0)edges.splice(i,1);
 const t=byId[e.b];if(t){const j=t.prs.indexOf(e.a);if(j>=0)t.prs.splice(j,1);}
 markEdit(e.a);markEdit(e.b);selEdge=null;rebuildView();dirty=true;}
function setStatusAll(s){if(!selSet.size)return;
 selSet.forEach(id=>{const n=byId[id];if(n)n.status=s;});
 [...selSet].forEach(markEdit);rebuildView();hideCtx();dirty=true;}
function copySelIds(){navigator.clipboard&&navigator.clipboard.writeText([...selSet].join(","));
 hideCtx();}
function hideCtx(){document.getElementById("ctx").style.display="none";}
function showCtx(ev){const c=document.getElementById("ctx");let h="";
 if(selEdge)h+="<div class='ci' onclick='delEdgeSel()'>🗑 删除依赖 "+selEdge.a+" → "+selEdge.b+"</div>";
 const p=toWorld(ev),hit=nodeAt(p.x,p.y);
 const single=(hit&&hit.id)||(selSet.size===1?[...selSet][0]:null);
 if(single&&!selEdge){
  h+="<div class='ch'>"+single+" →</div>"
   +"<div class='ci' onclick=\"setStatusAll('进行中')\">▶ 进行中</div>"
   +"<div class='ci' onclick=\"setStatusAll('待验收')\">🔍 待验收</div>"
   +"<div class='ci' onclick=\"setStatusAll('完成')\">✓ 完成</div>"
   +"<div class='ci' onclick=\"setStatusAll('可开工')\">🚦 可开工</div>"
   +"<div class='ci' onclick=\"setStatusAll('阻塞')\">⏸ 阻塞</div>"
   +"<div class='ci' onclick=\"setStatusAll('冻结')\">❄ 冻结</div>"
   +"<div class='ci' onclick=\"setStatusAll('放弃')\">✕ 放弃</div>"
   +"<div class='ci' onclick=\"doRelease('"+single+"')\">🔓 释放认领</div>"
   +"<div class='ci' onclick='openTaskForm(\""+single+"\")'>✎ 编辑任务…</div>"
   +"<div class='ci' onclick='openTaskForm(null,\""+single+"\")'>✂ 拆解为子任务…</div>"
   +"<div class='ci' onclick='delTask(\""+single+"\")'>🗑 删除任务</div>"
   +"<div class='ci' onclick='copySelIds()'>📋 复制 id</div>";
 }else if(selSet.size>1&&!selEdge){
  h+="<div class='ch'>已选 "+selSet.size+" 个 → 批量状态：</div>";
  ["完成","待验收","进行中","可开工","阻塞","冻结","放弃"].forEach(s=>{
   h+="<div class='ci' onclick=\"setStatusAll('"+s+"')\">"+s+"</div>";});
  h+="<div class='ci' onclick='copySelIds()'>📋 复制所选 id</div>";
 }else if(!selEdge){
  h+="<div class='ci' onclick='openTaskForm()'>➕ 新建任务…</div>"+
     "<div class='ci' onclick='fitAll();hideCtx()'>⛶ 适配全图</div>"+
     "<div class='ci' onclick='relayout();hideCtx()'>⟲ 自动重排</div>";}
 c.innerHTML=h;c.style.display="block";
 c.style.left=Math.min(ev.clientX,innerWidth-190)+"px";
 c.style.top=Math.min(ev.clientY,innerHeight-28*c.querySelectorAll(".ci").length-20)+"px";}
function delEdgeSel(){if(selEdge)delEdge(selEdge);hideCtx();}
document.addEventListener("mousedown",ev=>{if(!ev.target.closest("#ctx"))hideCtx();},true);
cv.oncontextmenu=ev=>ev.preventDefault();
let lastRmb=null;  // 右键按下点：mouseup 会先清 drag，contextmenu 后到——用位移判断是否"右键无拖动"
cv.addEventListener("contextmenu",ev=>{
 if(lastRmb&&Math.hypot(ev.clientX-lastRmb.x,ev.clientY-lastRmb.y)<4)showCtx(ev);
 lastRmb=null;});
cv.onpointerdown=ev=>{if(flyRAF){cancelAnimationFrame(flyRAF);flyRAF=null;}const p=toWorld(ev);
 if(ev.button===1||ev.button===2||(ev.button===0&&spaceDown)){   // 平移三通道
  if(ev.button===2)lastRmb={x:ev.clientX,y:ev.clientY};
  drag={pan:true,sx:ev.clientX,sy:ev.clientY,ox:view.x,oy:view.y,rmb:ev.button===2};}
 else if(ev.button!==0){return;}
 else if(inMini(ev)){drag={mini:true};miniJump(ev);}
 else if(showDivide&&divideX!=null&&Math.abs(ev.clientX-(divideX*view.k+view.x))<7){
  drag={divide:true,sx:ev.clientX,ox:divideX};}
 else{
  const port=portAt(p.x,p.y);                    // 输出端口热区：起连线
  if(port){drag={link:true,from:port.id,sx:ev.clientX,sy:ev.clientY,cx:ev.clientX,cy:ev.clientY};}
  else{
   const e0=(!nodeAt(p.x,p.y))?edgeAt(p.x,p.y):null; // 点边=选中边（Del 删除）
   if(e0){selEdge=e0;sel=null;selSet=new Set();dirty=true;}
   else{
    const n=nodeAt(p.x,p.y);
    if(n){
     if(ev.shiftKey){if(selSet.has(n.id)&&selSet.size>1)selSet.delete(n.id);else selSet.add(n.id);
      sel=n.id;showPanel(n);dirty=true;return;}
     sel=n.id;selEdge=null;if(!selSet.has(n.id))selSet=new Set([n.id]);
     showPanel(n);
     drag={n,dx:p.x-n.px,dy:p.y-n.py,sx:ev.clientX,sy:ev.clientY,moved:false,
      group:[...(n.isCluster?[n]:[...selSet])].filter(m=>m&&m.px!=null)
           .map(m=>({m,dx:p.x-m.px,dy:p.y-m.py}))};
    }else drag={box:true,sx:ev.clientX,sy:ev.clientY,cx:ev.clientX,cy:ev.clientY};
   }}}
 // 指针捕获：拖动中鼠标移出窗口/画布仍持续收到 move/up，杜绝"出界回来抽搐"
 try{cv.setPointerCapture(ev.pointerId);}catch(e2){}
 dirty=true;};
cv.addEventListener("pointermove",ev=>{if(!drag)return;
 if(drag.mini){miniJump(ev);return;}
 if(drag.divide){const dx=(ev.clientX-drag.sx)/view.k;divideX=drag.ox+dx;enforceDivide();dirty=true;return;}
 if(drag.box){drag.cx=ev.clientX;drag.cy=ev.clientY;dirty=true;return;}
 if(drag.link){drag.cx=ev.clientX;drag.cy=ev.clientY;dirty=true;return;}
 if(drag.moved===false&&Math.hypot(ev.clientX-drag.sx,ev.clientY-drag.sy)>4)drag.moved=true;
 if(drag.pan){view.x=drag.ox+ev.clientX-drag.sx;view.y=drag.oy+ev.clientY-drag.sy;}
 else if(drag.group){const p=toWorld(ev);       // 单/批量移动（簇卡片带动成员，各守分割墙）
  drag.group.forEach(g=>{let nx=p.x-g.dx,ny=p.y-g.dy;
   const doneSide=g.m.status==="完成";
   if(showDivide&&divideX!=null&&!g.m.isCluster){
    if(doneSide)nx=Math.min(nx,divideX-8-g.m.cw);else nx=Math.max(nx,divideX+8);}
   const dx=nx-g.m.px,dy=ny-g.m.py;
   g.m.px=nx;g.m.py=ny;
   if(g.m.isCluster){g.m.isCluster.members.forEach(id=>{const m=byId[id];m.px+=dx;m.py+=dy;});}
   else{g.m.x=nx;g.m.y=ny;}});
  computePorts();}  // 端口 y 是缓存值，拖动必须重算，否则贝塞尔垂直方向不跟随
 dirty=true;});
cv.addEventListener("pointerup",ev=>{
 if(drag&&drag.box){
  const x1=Math.min(drag.sx,drag.cx),x2=Math.max(drag.sx,drag.cx),
        y1=Math.min(drag.sy,drag.cy),y2=Math.max(drag.sy,drag.cy);
  if(x2-x1>6||y2-y1>6){
   const a={x:(x1-view.x)/view.k,y:(y1-view.y)/view.k},b={x:(x2-view.x)/view.k,y:(y2-view.y)/view.k};
   const hit=[];VN.forEach(n=>{if(!nodeVisible(n)||n.isCluster)return;
    if(n.px+n.cw>a.x&&n.px<b.x&&n.py+n.ch>a.y&&n.py<b.y)hit.push(n.id);});
   selSet=new Set(hit);sel=hit[0]||null;selEdge=null;
   if(sel)showPanel(byId[sel]);else document.getElementById("inspector").innerHTML="<div class='ph'>框选 "+selSet.size+" 个任务</div>";
  }else{sel=null;selSet=new Set();selEdge=null;hi=null;
   document.getElementById("inspector").innerHTML="<div class='ph'>点选任务查看详情</div>";}
 }else if(drag&&drag.link){
  const p=toWorld(ev),t=nodeAt(p.x,p.y);
  if(t&&t.id!==drag.from&&addEdge(drag.from,t.id)){rebuildView();showPanel(t);}
 }else if(drag&&drag.n&&drag.n.isCluster&&!drag.moved){
  folded[drag.n.isCluster.id]=!folded[drag.n.isCluster.id];rebuildView();}
 try{cv.releasePointerCapture(ev.pointerId);}catch(e2){}
 drag=null;dirty=true;});
cv.onpointerleave=ev=>{if(!drag){hi=null;dirty=true;}};
cv.addEventListener("pointermove",ev=>{if(drag)return;const p=toWorld(ev);
 divideHover=showDivide&&divideX!=null&&Math.abs(ev.clientX-(divideX*view.k+view.x))<7;
 const n=nodeAt(p.x,p.y),po=portAt(p.x,p.y),ed=n?null:edgeAt(p.x,p.y);
 hover=n?n.id:null;hi=n?n.id:null;
 cv.style.cursor=divideHover?"col-resize":(po?"crosshair":(n?"grab":(ed?"pointer":(spaceDown?"grab":"crosshair"))));
 dirty=true;});
cv.onpointerleave=ev2=>{if(!drag&&!sel){hi=null;dirty=true;}};
cv.ondblclick=ev=>{const p=toWorld(ev);const n=nodeAt(p.x,p.y);
 if(n){sel=n.id;selSet=new Set([n.id]);showPanel(n);flyTo(n.px+n.cw/2,n.py+n.ch/2,1.15);}
 else fitAll();};
cv.onwheel=ev=>{ev.preventDefault();const f=ev.deltaY<0?1.13:0.885;const r=toWorld(ev);
 view.k=Math.min(2.5,Math.max(0.2,view.k*f));
 view.x=ev.clientX-r.x*view.k;view.y=ev.clientY-r.y*view.k;dirty=true;};
// ── 新建/编辑任务弹窗（同一表单双模式；编辑时 id 锁定） ──
let editTarget=null;
let planParent=null;
function openTaskForm(editId,parentId){editTarget=editId||null;planParent=parentId||null;
 const m=document.getElementById("modal");m.style.display="flex";
 document.getElementById("ntTitle").textContent=editId?("✎ 编辑任务 · "+editId)
  :(planParent?("✂ 拆解 "+planParent+" → 子任务"):"➕ 新建任务");
 document.getElementById("ntGo").textContent=(editId||planParent)?"创建子任务":"创建";
 document.getElementById("ntGo").textContent=editId?"保存":"创建";
 const idIn=document.getElementById("ntId");
 idIn.value=editId||"";idIn.disabled=!!editId;   // id 是全部引用的锚点，编辑时锁定
 idIn.parentElement.style.display=editId?"none":"flex";
 const n=editId?byId[editId]:null;
 document.getElementById("ntName").value=n?n.name:"";
 const ls=document.getElementById("ntLane");
 ls.innerHTML=lanes.map(l=>"<option"+(n&&n.lane===l?" selected":"")+">"+l+"</option>").join("");
 const st=document.getElementById("ntStatus");
 st.innerHTML=STATUS.map(s=>"<option"+((n?n.status:"可开工")===s?" selected":"")+">"+s+"</option>").join("");
 document.getElementById("ntPrs").value=n?(n.prs||[]).join(","):(planParent||"");
 document.getElementById("ntDomain").value=n?((Array.isArray(n.domain)?n.domain:(n.domain||"").split(",")).filter(Boolean)).join(","):"";
 document.getElementById("ntDoc").value=n?(n.doc||""):"";
 document.getElementById("ntNote").value=n?(n.note||""):"";
 hideCtx();
 if(!editId)document.getElementById("ntName").focus();}
function closeModal(){document.getElementById("modal").style.display="none";editTarget=null;}
function submitTaskForm(){
 const name=document.getElementById("ntName").value.trim();
 const lane=document.getElementById("ntLane").value,status=document.getElementById("ntStatus").value;
 const domain=(document.getElementById("ntDomain").value||"").split(/[,;]/).map(s=>s.trim()).filter(Boolean);
 const doc=document.getElementById("ntDoc").value.trim(),note=document.getElementById("ntNote").value.trim();
 const newPrs=(document.getElementById("ntPrs").value||"").split(",").map(s=>s.trim()).filter(Boolean);
 if(editTarget){const n=byId[editTarget];
  if(!n){closeModal();return;}
  n.name=name||n.name;n.lane=lane;n.status=status;n.domain=domain;n.doc=doc;n.note=note;
  (n.prs||[]).filter(p=>!newPrs.includes(p)).forEach(p=>delEdge({a:p,b:editTarget}));
  newPrs.filter(p=>!(n.prs||[]).includes(p)).forEach(p=>{if(byId[p])addEdge(p,editTarget);
   else alert("前置不存在，已跳过："+p);});
  markEdit(editTarget);measureCards();rebuildView();showPanel(n);buildSide(curView);closeModal();return;}
 let id=document.getElementById("ntId").value.trim();
 if(planParent&&!id){let k=1;while(byId[planParent+"-"+k])k++;id=planParent+"-"+k;
  document.getElementById("ntId").value=id;}
 if(!id){alert("id 必填");return;}
 if(byId[id]){alert("id 已存在："+id);return;}
 const n={id,kind:"任务",name:name||id,lane,status,prs:[],domain,tree:"",note,doc,
  x:null,y:null,px:0,py:0,lines:[],cw:150,ch:56,inP:[],outP:[],_hit:false};
 nodes.push(n);byId[id]=n;prsOf[id]=[];blocksOf[id]=[];
 newPrs.forEach(p=>{if(byId[p])addEdge(p,id);else alert("前置不存在，已跳过："+p);});
 markEdit(id);measureCards();rebuildView();buildSide(curView);closeModal();
 sel=id;selSet=new Set([id]);jump(id);
 if(planParent&&byId[planParent]){  // 父任务自动化：注记"已拆解为"
  const pn=byId[planParent];
  const tag="已拆解为 "+id;
  if(!(pn.note||"").includes(tag))pn.note=(pn.note?pn.note+"；":"")+tag;
  markEdit(planParent);measureCards();rebuildView();}
 closeRel();  // 拆解表单关闭浮窗（若开）
}
function doRelease(id){const n=byId[id];if(!n)return;
 if(n.claim){log_event("release",id,n.claim);}
 n.claim="";markEdit(id);showPanel(n);dirty=true;}
function delTask(id){const n=byId[id];if(!n)return;
 const linked=edges.filter(e=>e.a===id||e.b===id).length;
 if(!confirm("删除任务「"+n.name+"」（"+id+"）及其 "+linked+" 条依赖边？\n此操作导出后生效，源文件覆盖前可反悔。"))return;
 edges=edges.filter(e=>e.a!==id&&e.b!==id);
 CLUSTERS.forEach(c=>{const i=c.members.indexOf(id);if(i>=0)c.members.splice(i,1);});
 nodes.splice(nodes.indexOf(n),1);
 delete byId[id];delete prsOf[id];delete blocksOf[id];
 delete memberOf[id];
 sel=null;selSet=new Set();selEdge=null;hi=null;
 markEdit(id);measureCards();rebuildView();buildSide(curView);
 document.getElementById("inspector").innerHTML="<div class='ph'>已删除 "+id+"</div>";dirty=true;}
function inMini(ev){const r=mini.getBoundingClientRect();
 return ev.clientX>=r.left&&ev.clientX<=r.right&&ev.clientY>=r.top&&ev.clientY<=r.bottom;}
function miniJump(ev){if(!mini._map)return;const{g,s,ox,oy}=mini._map;const r=mini.getBoundingClientRect();
 const wx=(ev.clientX-r.left-ox)/s+g.minX,wy=(ev.clientY-r.top-oy)/s+g.minY;
 view.x=VW/2-wx*view.k;view.y=VH/2-wy*view.k;dirty=true;}
// ── 工具栏 ──
document.getElementById("legend").innerHTML=STATUS.map(s=>"<span><span class='sw' style='background:"+COL[s]+"'></span>"+s+"</span>").join("");
const lanesBox=document.getElementById("lanes");
lanes.forEach((l,i)=>{const c=document.createElement("span");c.className="lchip";
 c.innerHTML='<span class="sw" style="background:'+LANE_COL[i%LANE_COL.length]+'"></span>'+l;
 c.title="单击=聚拢该线居中（再点退出，显隐/布局状态保留） · Alt+单击=显隐该线";
 c.onclick=ev=>{
  if(ev.altKey){laneVis[l]=!laneVis[l];c.classList.toggle("off",!laneVis[l]);dirty=true;return;}
  if(focusLane===l){  // 退出聚拢：恢复进入前坐标与分割墙，不清手动布局
   focusLane=null;c.classList.remove("focus");
   if(focusSnapshot){focusSnapshot.forEach(a=>{a[0].px=a[1];a[0].py=a[2];});focusSnapshot=null;}
   initDivide();rebuildView();fitAll();}
  else{  // 进入聚拢：快照坐标 → 墙互斥 → 分区布局
   lanesBox.querySelectorAll(".lchip.focus").forEach(x=>x.classList.remove("focus"));
   focusLane=l;focusLines=null;c.classList.add("focus");
   focusSnapshot=nodes.map(n=>[n,n.px,n.py]);
   divideX=null;rebuildView();applyFocus();fitAll();}
  dirty=true;};
 lanesBox.appendChild(c);});
const chk=DATA.check||{errors:[],warns:[]};
const chipEl=document.getElementById("checkChip");
chipEl.textContent=chk.errors.length?("✗ "+chk.errors.length+" 错误"+(chk.warns.length?" · "+chk.warns.length+" 警告":""))
 :(chk.warns.length?("⚠ 通过 · "+chk.warns.length+" 警告"):"✓ 校验通过");
chipEl.style.background=chk.errors.length?"#4a1526":(chk.warns.length?"#3a2c0e":"#123a2a");
chipEl.style.color=chk.errors.length?"#ffc9d6":(chk.warns.length?"#ffe08a":"#b8f5da");
chipEl.style.borderColor=chk.errors.length?"#6b2436":(chk.warns.length?"#6b5312":"#1d5340");
chipEl.onclick=toggleMsgs;
// ── 调度视角开关：就绪集高亮 / 关键路径高亮 ──
const READY=DATA.ready||[],CRIT=DATA.crit||[];
let readyOnly=false,critOnly=false;
const rchip=document.getElementById("readyChip");
rchip.textContent="🚦 可派 "+READY.length;
rchip.style.color=READY.length?"#a5f3fc":"#94a3b8";
rchip.style.background=READY.length?"#0c2a33":"#111a29";
const cchip=document.getElementById("critChip");
cchip.textContent="🛤 关键路径 "+Math.max(0,CRIT.length-1)+" 跳";
cchip.style.color=CRIT.length?"#ffe08a":"#94a3b8";
cchip.style.background=CRIT.length?"#3a2c0e":"#111a29";
function refreshChips(){rchip.style.borderColor=readyOnly?"#22d3ee":"#1d2a3d";
 cchip.style.borderColor=critOnly?"#fbbf24":"#1d2a3d";}
rchip.onclick=()=>{readyOnly=!readyOnly;critOnly=false;refreshChips();dirty=true;};
cchip.onclick=()=>{critOnly=!critOnly;readyOnly=false;refreshChips();dirty=true;};
function toggleMsgs(){const m=document.getElementById("msgs");
 if(m.style.display==="block"){m.style.display="none";return;}
 m.innerHTML=(chk.errors.length?chk.errors.map(e=>"<div class='e'>"+e+"</div>").join(""):"<div class='e' style='opacity:.6'>无 ERROR</div>")
 +chk.warns.map(w=>"<div class='w'>"+w+"</div>").join("");
 m.style.display="block";}
document.getElementById("help").onclick=ev=>{if(ev.target.id==="help")ev.currentTarget.style.display="none";};
const searchBox=document.getElementById("search");
searchBox.oninput=()=>{q=searchBox.value.trim();applySearch();dirty=true;};
searchBox.onkeydown=ev=>{if(ev.key==="Enter"){const hit=nodes.find(n=>n._hit);if(hit)jump(hit.id);}
 if(ev.key==="Escape"){searchBox.value="";q="";applySearch();dirty=true;}};
function applySearch(){if(!q){nodes.forEach(n=>n._hit=false);return;}
 const lower=q.toLowerCase();
 nodes.forEach(n=>n._hit=(n.id+" "+n.name+" "+n.note).toLowerCase().includes(lower));}
addEventListener("keydown",ev=>{
 const inField=document.activeElement===searchBox||/^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
 if(ev.code==="Space"&&!inField){spaceDown=true;cv.style.cursor="grab";ev.preventDefault();return;}
 if(ev.key==="Escape"){if(document.getElementById("ctx").style.display==="block"){hideCtx();return;}
  if(document.getElementById("modal").style.display==="flex"){closeModal();return;}
  sel=null;selSet=new Set();selEdge=null;hi=null;
  document.getElementById("inspector").innerHTML="<div class='ph'>点选任务查看详情</div>";dirty=true;return;}
 if(inField)return;
 if((ev.key==="Delete"||ev.key==="Backspace")&&selEdge){delEdge(selEdge);return;}
 // 工业软件快捷键组（大写锁定不敏感）
 const k=ev.key.toLowerCase();
 if(k==="n"){openTaskForm();return;}
 if(k==="f"){fitAll();return;}
 if(k==="t"){toggleTower();return;}
 if(k==="g"){applyLayout(0);return;}
 if(k==="l"){locateActive();return;}
 if(k==="d"){toggleDock();return;}
 if(k==="c"){critOnly=!critOnly;refreshChips();dirty=true;return;}
 if(k==="r"){readyOnly=!readyOnly;critOnly=false;refreshChips();dirty=true;return;}
 const vi=parseInt(ev.key);
 if(vi>=1&&vi<=6){const vs=["graph","producer","eng","design","art","qa"];setView(vs[vi-1]);}});
addEventListener("keyup",ev=>{if(ev.code==="Space"){spaceDown=false;cv.style.cursor="default";dirty=true;}});
// ── 岗位视图体系（同一份 DAG 的不同投影；hash 路由 #view=xxx 可直达/分享） ──
const VIEWS={
 graph:{},
 producer:{},
 eng:{lanes:new Set(["复刻主线","UI线","配置存档","战略图","地图系统","经济循环","玩法系统","工程债","里程碑"])},
 design:{lanes:new Set(["叙事设计","决策","玩法系统","经济循环","里程碑"])},
 art:{ids:n=>/^(asset_|ext_art|fx_|p12_skins)/.test(n.id)||n.lane==="美术"},
 qa:{ids:n=>/^(debt_|test_|ci_|arena_)/.test(n.id)||n.status==="待验收"||/^(demo_|hp_default_zero)/.test(n.id)}
};
let curView=null,viewSnapshot=null;  // 初始 null：启动 setView 必须完整跑一遍 UI 初始化（幂等守卫只拦重复调用）
function setView(v,force){const prev=curView;
 if(!VIEWS[v])v="graph";                       // hash 手输未知视图 → 回退全图
 if(prev===v&&!force)return;                   // 同页签幂等：二次快照会把投影态当原始态
 curView=v;
 if(location.hash!=="#view="+v)location.hash="#view="+v;
 document.querySelectorAll(".vtab").forEach(t=>t.classList.toggle("on",t.dataset.v===v));
 viewFilter=VIEWS[v]||{};
 const dash=document.getElementById("dash"),showDash=v==="producer";
 dash.style.display=showDash?"block":"none";
 ["cv","mini","cfoot"].forEach(id2=>{const el=document.getElementById(id2);if(el)el.style.visibility=showDash?"hidden":"visible";});
 document.getElementById("sideL").style.display=showDash?"none":"flex";
 document.getElementById("sideR").style.display=showDash?"none":"flex";
 const vbel=document.getElementById("vbar");
 vbel.style.display=showDash?"none":"flex";
 if(!showDash){const sw=sideW();vbel.style.top=BAR_H+"px";vbel.style.left=sw.L+"px";vbel.style.right=sw.R+"px";buildVbar();}
 const dkel=document.getElementById("dock");
 dkel.style.display=showDash?"none":"flex";
 if(showDash){dash.style.top=BAR_H+"px";buildDash();return;}
 // 岗位视图 = 布局投影：进入时快照全图坐标 → 对可见子集重新 dagre（隐藏节点不再占位）→ 退出恢复
 // 切视图前清聚拢/关键路径残留：focusLane 的 _f 淡出标记会污染新视图
 focusLane=null;focusLines=null;critOnly=false;refreshChips();
 VN.forEach(n=>{delete n._f;});
 if(prev!==v&&viewSnapshot){viewSnapshot.forEach(a=>{a[0].px=a[1];a[0].py=a[2];});viewSnapshot=null;}
 if(v!=="graph"){viewSnapshot=nodes.map(n=>[n,n.px,n.py]);}
 rebuildView();
 if(v!=="graph"){dagreLayout();rebuildView();fitAll();}
 else{locateActive();}
 buildSide(v);
 dirty=true;}
function jumpTo(id){setView("graph");jump(id);}
function buildVbar(){const v=document.getElementById("vbar");let h="";
 h+="<span class='lbl'>布局</span><span class='vg'>"
  +"<button class='vt on' onclick='applyLayout(0)'>▦ 泳道带</button>"
  +"<button class='vt' onclick='applyLayout(1)'>⟲ 交叉最小</button></span><span class='sep'></span>";
 h+="<span class='lbl'>状态</span><span class='vg'>"
  +STATUS.map(function(st){return "<button class='vt"+(statusFilter.has(st)?" on":"")+"' style='border-left:3px solid "+COL[st]+"' onclick=\"toggleStatus('"+st+"')\">"+st+"</button>";}).join("")
  +"</span><span class='sep'></span>";
 h+="<span class='vg'>"
  +"<button class='vt"+(microOn?" on":"")+"' onclick='microOn=!microOn;refilter()'>◌ 微任务</button>"
  +"<button class='vt"+(doneOn?" on":"")+"' onclick='doneOn=!doneOn;refilter()'>✓ 完成区</button>"
  +"</span><span class='sep'></span>";
 h+="<span class='vg'>"
  +"<button class='vt' onclick='view.k=Math.min(2.5,view.k*1.25);dirty=true'>＋</button>"
  +"<button class='vt' onclick='view.k=Math.max(0.2,view.k/1.25);dirty=true'>－</button>"
  +"<button class='vt' onclick='fitAll()'>⤢ 适配</button>"
  +"<button class='vt' onclick='locateActive()'>⌖ 活跃面</button>"
  +"</span><span class='sep'></span><span class='lbl'>数据源</span><span class='vg' id='srcSwitch2'>"
  +"<button class='vt on' onclick=\"setGanttSource('all')\">全部</button>"
  +"<button class='vt' onclick=\"setGanttSource('real')\">真实</button>"
  +"<button class='vt' onclick=\"setGanttSource('sim')\">SIM</button></span>";
 h+="<span class='vg'><button class='vt"+(towerMode?" on":"")+"' id='towerBtn' onclick='toggleTower()' title='塔台巡航：镜头自动轮巡全部已认领任务（机场调度监控模式）'>✈ 塔台巡航</button></span>";
 v.innerHTML=h;}

// ── 塔台巡航：镜头自动轮巡已认领任务（机场调度监控模式） ──
let towerMode=false,towerRAF=null,towerIdx=0,towerLast=0;
function toggleTower(){towerMode=!towerMode;
 const b=document.getElementById("towerBtn");if(b)b.classList.toggle("on",towerMode);
 if(towerRAF){cancelAnimationFrame(towerRAF);towerRAF=null;}
 if(!towerMode)return;
 const step=ts=>{ // 3.2s/站：flyTo 下一认领任务
  if(!towerMode){towerRAF=null;return;}
  if(ts-towerLast>3200){towerLast=ts;
   const claimed=nodes.filter(n=>n.claim&&n.status!=="完成");
   if(claimed.length){const n=claimed[towerIdx%claimed.length];towerIdx++;
    hi=n.id;sel=n.id;selSet=new Set([n.id]);showPanel(n);relPopup(n.id);
    flyTo(n.px+n.cw/2,n.py+n.ch/2,1.0);}
   else{towerMode=false;const b2=document.getElementById("towerBtn");if(b2)b2.classList.remove("on");}}
  towerRAF=requestAnimationFrame(step);};
 towerLast=0;towerRAF=requestAnimationFrame(step);}
function applyLayout(mode){ // 0=泳道带状 1=dagre 交叉最小化
 if(curView==="graph"){laneBandLayout();}else{dagreLayout();}
 rebuildView();fitAll();dirty=true;}
function toggleStatus(st){statusFilter.has(st)?statusFilter.delete(st):statusFilter.add(st);
 buildVbar();refilter();}
function refilter(){rebuildView();
 if(curView==="graph"){laneBandLayout();}else{dagreLayout();}
 rebuildView();fitAll();dirty=true;}
function sideSelect(id){const n=byId[id];if(!n)return;
 sel=id;selSet=new Set([id]);selEdge=null;hi=id;showPanel(n);
 flyTo(n.px+n.cw/2,n.py+n.ch/2,Math.max(view.k,0.85));  // 特写：相机平移聚焦到该项
 dirty=true;}
// ── 相关项浮窗（左下小窗：中心任务+前置列+被依赖列迷你卡） ──
function relPopup(id){const n=byId[id];if(!n)return;
 const mrow=t=>"<div class='lst' onclick='sideSelect(\""+t.id+"\")'>"
  +"<span class='dot' style='background:"+(COL[t.status]||"#888")+"'></span>"
  +"<span class='lid'>"+t.id+"</span><span class='lname'>"+t.name+"</span>"
  +"<span class='lgo' onclick='event.stopPropagation();jumpTo(\""+t.id+"\")'>⤢</span></div>";
 let h="<div class='phead'><b>"+(n.kind==="里程碑"?"◆ ":"")+esc(n.name)+"</b>"
  +"<span style='margin-left:auto;cursor:pointer;color:var(--dim2)' onclick='closeRel()'>✕</span></div>"
  +"<div class='pbody'>";
 h+="<div class='pane-head' style='position:static'>前置 "+(n.prs||[]).length+"</div>";
 h+=n.prs&&n.prs.length?n.prs.map(p=>byId[p]?mrow(byId[p]):"").join(""):"<div class='ph'>无</div>";
 h+="<div class='pane-head' style='position:static'>被依赖 "+(blocksOf[n.id]||[]).length+"</div>";
 h+=blocksOf[n.id].length?blocksOf[n.id].map(p=>byId[p]?mrow(byId[p]):"").join(""):"<div class='ph'>无</div>";
 h+="</div>";
 const w=document.getElementById("relwin");
 w.innerHTML=h;w.style.display="flex";}
function closeRel(){document.getElementById("relwin").style.display="none";}
function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/"/g,"&quot;").replace(/</g,"&lt;");}
function sideRow(n){return"<div class='lst"+(n.status==="进行中"?" active":"")+"' onclick='sideSelect(\""+n.id+"\")' title=\""+esc(n.name)+"（点击详情，⤢ 跳全图）\">"
 +"<span class='dot' style='background:"+(COL[n.status]||"#888")+"'></span>"
 +"<span class='lid'>"+n.id+"</span><span class='lname'>"+n.name+"</span>"
 +"<span class='lgo' title='跳全图定位' onclick='event.stopPropagation();jumpTo(\""+n.id+"\")'>⤢</span></div>";}
function sideHead(t,hint){return"<div class='pane-head'>"+t+(hint?"<span class='hint'>"+hint+"</span>":"")+"</div>";}
function gateProgress(gid,label){ // 收口门进度内嵌（点击展开成员清单）
 const g=byId[gid];if(!g)return"";
 const ds=blocksOf[gid]||[],done=ds.filter(d=>byId[d]&&byId[d].status==="完成").length;
 const pct=ds.length?Math.round(100*done/ds.length):0;
 let h="<div class='grow' onclick='toggleGate(\""+gid+"\")' title='点击展开/收起成员'>"
  +"<span class='nm' style='color:#eaf6ff'>◆ "+(label||g.name)+"</span>"
  +"<span class='gbar'><i style='width:"+pct+"%'></i></span><span class='pc'>"+done+"/"+ds.length+"</span></div>";
 if(window["_g_"+gid]){
  h+="<div style='max-height:200px;overflow:auto'>";
  ds.forEach(d=>{if(byId[d])h+=sideRow(byId[d]);});
  h+="</div>";}
 return h;}
function toggleGate(gid){window["_g_"+gid]=!window["_g_"+gid];buildSide(curView);}
function buildSide(v){const L=document.getElementById("sideL");let h="";
 const live=n=>n.status!=="完成"&&n.status!=="放弃";
 const active=nodes.filter(n=>n.status==="进行中"||n.status==="待验收");
 const ready=nodes.filter(n=>live(n)&&n.status!=="冻结"
  &&(n.prs||[]).every(p=>p===n.id||(byId[p]&&byId[p].status==="完成")));
 // 顶部 kv 状态条（LOGIC-8 status-strip：六格等宽）
 const nDone=nodes.filter(n=>n.status==="完成").length,
       nAct=nodes.filter(n=>n.status==="进行中"||n.status==="待验收").length,
       nReady=ready.length,
       nBlk=nodes.filter(n=>n.status==="阻塞").length,
       nFrz=nodes.filter(n=>n.status==="冻结").length;
 h+="<div class='strip'>"
  +[["任务",nodes.length,""],["完成",nDone,"g"],["进行",nAct,"c"],["就绪",nReady,"g"],["阻塞",nBlk,"y"],["冻结",nFrz,""]]
   .map(x=>"<div class='kv'><span>"+x[0]+"</span><b class='"+x[2]+"'>"+x[1]+"</b></div>").join("")
  +"</div>";
 if(v==="eng"){
  h+=sideHead("⚙ 进行中 / 待验收","代码线");
  h+=active.filter(n=>n.lane!=="宣发运营").map(sideRow).join("")||"<div class='ph'>无</div>";
  h+=sideHead("🚦 就绪可派","前置全齐");
  h+=ready.filter(n=>n.lane!=="叙事设计"&&n.lane!=="决策"&&n.lane!=="宣发运营").map(sideRow).join("")||"<div class='ph'>无</div>";
  const dom={};active.forEach(n=>(n.domain||[]).forEach(d=>{if(d)dom[d]=n.id;}));
  h+=sideHead("⚡ 文件域占用","并行写必冲突");
  h+=Object.keys(dom).map(d=>"<div class='lst grp' title='进行中任务正占用此域'><span></span><span class='lid' style='overflow:visible'>"+d+"</span><span class='lname' style='text-align:right'>"+dom[d]+"</span><span></span></div>").join("");
 }else if(v==="design"){
  const dec=nodes.filter(n=>/^dec_/.test(n.id)&&live(n));
  h+=sideHead("🏛 等创始人拍板","零代码成本·解锁下游");
  h+=dec.map(n=>sideRow(n)).join("")||"<div class='ph'>无待决策项</div>";
  h+=sideHead("📐 设计产出清单","叙事/玩法/经济设计");
  h+=nodes.filter(n=>n.lane==="叙事设计"&&live(n)).map(sideRow).join("")
   +nodes.filter(n=>n.lane==="玩法系统"&&/^(content_|autonomy_|idle_|god_view)/.test(n.id)&&live(n)).map(sideRow).join("");
 }else if(v==="art"){
  const ext=byId.ext_art;
  h+=sideHead("📡 外部资产通道","采购/自制交付状态");
  h+="<div class='extStrip'><b>ext_art 外部美术资产通道</b><br>状态：<span class='st'>"+ext.status.toUpperCase()+"</span> —— 等待外部交付（手绘贴图/音效采购）。<br>下方 P1~P7 素材替换全部挂此通道：通道不开，资产任务只能做程序侧准备。需求单=待办 PLACEHOLDER 表。</div>";
  h+=sideHead("🎨 素材替换清单","点击行看详情");
  h+=nodes.filter(n=>/^(asset_p|fx_directional|fx_explosion|fx_ground|fx_rain|p12_skins)/.test(n.id)).sort((a,b)=>a.id.localeCompare(b.id)).map(sideRow).join("");
  h+=sideHead("🧰 程序侧配套","材质/粒子管线");
  h+=nodes.filter(n=>/^(texture_gen_regression|weather_env|behavior_)/.test(n.id)||n.id==="p3_thatch").map(sideRow).join("");
 }else if(v==="qa"){
  h+=sideHead("🐞 缺陷清单","观察场验收遗留");
  h+=nodes.filter(n=>/^debt_/.test(n.id)).map(sideRow).join("")||"<div class='ph'>无</div>";
  h+=sideHead("🔍 待验收","需人工/游戏内确认");
  h+=active.filter(n=>n.status==="待验收").map(sideRow).join("")||"<div class='ph'>无</div>";
  h+=sideHead("🧰 测试基建","稳定性/CI");
  h+=nodes.filter(n=>/^(test_stability|ci_enable|texture_gen_regression)/.test(n.id)).map(sideRow).join("");
  h+=sideHead("◆ Demo 收口进度","点击展开成员");
  h+=gateProgress("demo_content","Demo 内容收口")+gateProgress("demo_release","Demo 发布");
 }else{ // graph 全图
  h+=sideHead("🚦 就绪集 top","前置全齐可派活");
  h+=ready.slice(0,14).map(sideRow).join("")||"<div class='ph'>无</div>";
  h+=sideHead("🗂 泳道","任务数");
  const cnt={};nodes.forEach(n=>{if(live(n))cnt[n.lane]=(cnt[n.lane]||0)+1;});
  h+=Object.keys(cnt).map(l=>"<div class='lst grp'><span></span><span class='lname'>"+l+"</span><span class='cnt'>"+cnt[l]+"</span><span></span></div>").join("");
  h+=sideHead("ℹ 操作","常用");
  h+="<div class='ph'>左键拖空白=框选 · 中/右键/空格+拖=平移<br>右缘拖线=建依赖 · 右键=批量/编辑<br>🛤 关键路径=琥珀蚂蚁线 · Alt+点泳道=显隐</div>";
 }
 L.innerHTML=h;L.style.top=BAR_H+"px";
 document.getElementById("sideR").style.top=BAR_H+"px";}
function buildDash(){const P=DATA.producer||{},d=document.getElementById("dash");const LIMIT=6;
 const liveReady=nodes.filter(n=>n.status!=="完成"&&n.status!=="冻结"&&n.status!=="放弃"
  &&(n.prs||[]).every(p=>p===n.id||(byId[p]&&byId[p].status==="完成")));
 const S=Object.assign({},P.stats||{},{ready:liveReady.length});
 const tch=(n,extra)=>"<span class='tchip' onclick='jumpTo(\""+n.id+"\")'>"
  +"<span class='dot' style='background:"+(COL[n.status]||"#888")+"'></span>"+n.name
  +(extra||"")+"</span>";
  let h="<div class='strip'>"
  +[["任务总数",S.nodes,""],["已完成",S.done,"g"],["进行/待验收",S.active,"c"],
    ["就绪可派",S.ready,"g"],["阻塞",S.blocked,"y"],["冻结",S.frozen,""]]
   .map(x=>"<div class='kv'><span>"+x[0]+"</span><b class='"+x[2]+"'>"+x[1]+"</b></div>").join("")
  +"</div><div class='layout'><div class='col' id='dashL'></div><div class='col' id='dashR'></div>";
 const L=[],R=[];
 if((P.combo||[]).length)L.push("<div class='card'><h4>🚦 建议派活组合（域互斥 ≤"+LIMIT+" 线）</h4>"
  +P.combo.map(id=>byId[id]?tch(byId[id]," <span style='color:#6e7a87'>"+byId[id].lane+"</span>"):"").join("")+"</div>");
 if((P.crit||[]).length)L.push("<div class='card'><h4>🛤 关键路径（"+(P.crit.length-1)+" 跳）</h4><div style='line-height:2.1'>"
  +P.crit.map((id,i)=>byId[id]?(i?"<span style='color:#6e7a87'> → </span>":"")+tch(byId[id]):"").join("")+"</div>"
  +"<div class='hint' style='margin:6px 14px 0'>压缩关键路径靠拆依赖/拆任务/外购前置；加并发只能压非关键路径</div></div>");
 const byLane={};liveReady.forEach(n=>{(byLane[n.lane||"（无线）"]=byLane[n.lane||"（无线）"]||[]).push(n);});
 L.push("<div class='card'><h4>📦 就绪集 "+liveReady.length+" 个（点击行在图上定位）</h4><div style='max-height:340px;overflow:auto'>");
 Object.keys(byLane).sort().forEach(ln=>{L.push("<div class='laneHead'>"+ln+" · "+byLane[ln].length+"</div>"
  +byLane[ln].map(n=>tch(n)).join(""));});
 L.push("</div></div>");
 if((P.gates||[]).length)R.push("<div class='card'><h4>◆ 里程碑燃尽</h4>"
  +P.gates.map(g=>"<div class='gate'><span class='nm' onclick='jumpTo(\""+g.id+"\")' title='"+g.id+"'>"+g.name
   +"</span><span class='bar'><i style='width:"+(g.total?Math.round(100*g.done/g.total):0)+"%'></i></span><span class='pc'>"
   +g.done+"/"+g.total+"</span></div>").join("")+"</div>");
 // 👥 AI 负载（真实认领=字段 + 调度日志统计）
 const claimedNow=nodes.filter(n=>n.claim&&n.status!=="完成");
 const byAg={};
 (DATA.simlog&&DATA.simlog.events||[]).forEach(e=>{
  if(!e.agent||e.agent==="unknown")return;
  byAg[e.agent]=byAg[e.agent]||{done:0,claims:0};
  if(e.action==="done")byAg[e.agent].done++;
  if(e.action==="claim")byAg[e.agent].claims++;
 });
 let agCard="<div class='card'><h4>👥 AI 负载（谁在做什么）</h4>";
 agCard+="<div class='laneHead' style='margin:4px 14px 2px'>◉ 认领中（真实认领）</div>";
 agCard+=claimedNow.length?claimedNow.map(n=>tch(n," <span style='color:var(--amber)'>◉ "+n.claim+"</span>")).join(""):"<div class='ph' style='margin:4px 14px'>无认领中任务——用 claim <id> --by <AI名> 认领</div>";
 if(Object.keys(byAg).length){
  agCard+="<div class='laneHead' style='margin:8px 14px 2px'>调度日志统计</div>";
  agCard+=Object.keys(byAg).map(a2=>"<div class='grow'><span class='dot' style='background:"+agentColor(a2)+"'></span><span class='nm'>"+a2+"</span><span style='color:var(--dim2);font:600 10px "+MONO+"'>完成 "+byAg[a2].done+" · 认领 "+byAg[a2].claims+"</span></div>").join("");}
 agCard+="</div>";
 R.push(agCard);
 const ws=(chk.warns||[]).slice(0,12),es=chk.errors||[];
 R.push("<div class='card'><h4>⚠ 审计线索</h4>"
  +(es.length?es.map(e=>"<div class='warn'>"+e+"</div>").join(""):"")
  +(ws.length?ws.map(w=>"<div class='warn'>"+w+"</div>").join(""):"<div class='hint' style='margin:4px 14px'>无警告</div>")+"</div>");
 d.innerHTML=h;
 document.getElementById("dashL").innerHTML=L.join("");
 document.getElementById("dashR").innerHTML=R.join("");}
document.querySelectorAll(".vtab").forEach(t=>{t.onclick=()=>setView(t.dataset.v);});

// ── 底部 IDE 面板（dock）：运行图（火车运行图式）/ 调度日志 ──
const dock=document.getElementById("dock"),gantt=document.getElementById("gantt"),gtx=gantt.getContext("2d");
let dockFolded=false,dockTab="gantt";
document.getElementById("dockFold").onclick=()=>{dockFolded=!dockFolded;
 dock.classList.toggle("folded",dockFolded);
 document.getElementById("dockFold").textContent=dockFolded?"▴":"▾";
 sizeGantt();dirty=true;};
document.querySelectorAll("#srcSwitch").forEach(sw=>{sw.addEventListener("click",ev=>{
 const b=ev.target.closest("[data-src]");if(!b)return;ganttSource=b.dataset.src;
 sw.querySelectorAll("[data-src]").forEach(x=>x.classList.toggle("on",x===b));
 sw._built=false;sizeGantt();drawGantt();});});
document.querySelectorAll(".dtab").forEach(t=>{t.onclick=()=>{
 dockTab=t.dataset.t;
 document.querySelectorAll(".dtab").forEach(x=>x.classList.toggle("on",x.dataset.t===dockTab));
 document.getElementById("gantt").style.display=dockTab==="gantt"?"block":"none";
 document.getElementById("logList").style.display=dockTab==="log"?"block":"none";
 if(dockTab==="log")buildLogList();else{sizeGantt();drawGantt();}
};});
function toggleDock(){dockFolded=!dockFolded;dock.classList.toggle("folded",dockFolded);
 document.getElementById("dockFold").textContent=dockFolded?"▴":"▾";
 sizeGantt();if(dockTab==="log")buildLogList();dirty=true;}
addEventListener("keydown",ev=>{if(ev.key==="Tab"&&!/INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName)){
 ev.preventDefault();toggleDock();}});
function sizeGantt(){const c=gantt;if(!c)return;const r=c.getBoundingClientRect();
 if(r.width<10)return;c.width=r.width*dpr;c.height=r.height*dpr;}
const AGENT_COL=["#38bdf8","#a78bfa","#4ade80","#facc15","#f472b6","#22d3ee","#fb923c","#94a3b8"];
function agentColor(a){let h=0;for(const ch of a)h=(h*31+ch.charCodeAt(0))>>>0;return AGENT_COL[h%AGENT_COL.length];}
function claimDuration(task){ // 认领时长（分钟）：从真实调度日志回放
 const evs=(DATA.simlog&&DATA.simlog.events)||[];
 let t0=null;
 for(let i=evs.length-1;i>=0;i--){const e=evs[i];
  if(e.task===task&&e.action==="claim")t0=e.ts;}
 if(!t0)return null;
 const t=new Date(t0.replace(" ","T"));
 if(isNaN(t))return null;
 return Math.max(0,Math.round((Date.now()-t)/60000))+"min";}
function claimDurText(task){const m=claimDuration(task);return m?(" · "+m):"";}
let ganttSource="all",agentFilter=null;
function simEvents(){const evs=(DATA.simlog&&DATA.simlog.events)||[];
 let out=ganttSource==="all"?evs:evs.filter(e=>(e.src||"real")===ganttSource||ganttSource==="real"&&e.src!=="sim");
 if(agentFilter)out=out.filter(e=>e.agent===agentFilter||out.some(q=>q.agent===agentFilter&&q.task===e.task));
 return out;}
function parseT(ts){const m=/T(\d+)/.exec(ts||"");return m?parseInt(m[1],10):0;}
let ganttJobs={};  // 运行图任务聚合（drawGantt 写入，hover/点击命中复用）
function drawGantt(){const c=gantt;if(!c||c.width<10)return;
 const evs=simEvents();
 gtx.setTransform(dpr,0,0,dpr,0,0);
 const W=c.width/dpr,H=c.height/dpr;
 gtx.fillStyle="#070c14";gtx.fillRect(0,0,W,H);
 if(view.k*40>=9){gtx.strokeStyle="#0e1725";gtx.lineWidth=1;gtx.beginPath();
  for(let x=0;x<W;x+=40){gtx.moveTo(x,0);gtx.lineTo(x,H);}for(let y=0;y<H;y+=40){gtx.moveTo(0,y);gtx.lineTo(W,y);}gtx.stroke();}
 if(!evs.length){gtx.fillStyle="#55677f";gtx.font="12px system-ui";
  gtx.fillText("无调度数据——运行 python tools/deptask/gen.py sim --agents 6 --rounds 60 生成模拟日志",20,H/2);return;}
 // 任务聚合：task → {agent,lane,t0,t1,done}
 const jobs=ganttJobs={};  // 提升为模块级：hover/点击命中复用
 evs.forEach(e=>{const j=jobs[e.task]||(jobs[e.task]={lane:e.note||"",agent:e.agent,t0:1e9,t1:-1,done:false});
  if(e.action==="claim"){j.t0=Math.min(j.t0,parseT(e.ts));j.agent=e.agent;j.lane=e.note||j.lane;}
  if(e.action==="done"){j.t1=Math.min(j.t1,parseT(e.ts));j.done=true;j.agent=e.agent;}});
 const list=Object.keys(jobs).map(id=>Object.assign({id},jobs[id]));
 let tMax=0;list.forEach(j=>{tMax=Math.max(tMax,j.done?j.t1+2:j.t0+6);});
 const padL=8,padT=8,padB=18,rowH=15;
 // 泳道带（复用 lanes 顺序 + 杂项兜底）
 const laneKeys=[];list.forEach(j=>{if(laneKeys.indexOf(j.lane)<0)laneKeys.push(j.lane);});
 lanes.forEach(l=>{if(laneKeys.indexOf(l)<0)laneKeys.push(l);});
 const bandOf={},bandNames=[];let bi=0;
 laneKeys.forEach(l=>{bandOf[l]=bi;bandNames.push(l);bi++;});
 const innerH=H-padT-padB,bandH=Math.min(46,innerH/bandNames.length);
 // x 缩放：滚轮/拖拽平移（存 ganttView）
 if(!ganttView)ganttView={t0:0,t1:tMax};
 const span=ganttView.t1-ganttView.t0||1;
 const X=t=>padL+(t-ganttView.t0)/span*(W-padL-8);
 // 刻度
 gtx.font="600 9px "+MONO;gtx.fillStyle="#55677f";
 const stepT=Math.max(1,Math.round(span/12/5)*5);
 for(let t=Math.ceil(ganttView.t0/stepT)*stepT;t<=ganttView.t1;t+=stepT){
  const x=X(t);gtx.strokeStyle="#101927";gtx.beginPath();gtx.moveTo(x,padT);gtx.lineTo(x,H-padB);gtx.stroke();
  gtx.fillText("T"+String(t).padStart(3,"0"),x+3,H-padB+11);}
 // 泳道带底 + 名称
 bandNames.forEach((l,i)=>{const y=padT+i*bandH;
  if(bi%2===0){gtx.fillStyle="#0b111c";gtx.fillRect(0,y,W,bandH);}
  const li=lanes.indexOf(l),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  gtx.fillStyle=lc+"22";gtx.fillRect(0,y,44,bandH);
  gtx.fillStyle=lc;gtx.font="600 8.5px "+MONO;
  gtx.save();gtx.translate(8,y+bandH/2+3);gtx.fillText(l.length>5?l.slice(0,5):l,0,0);gtx.restore();});
 // 任务条：同带子行贪心
 const rows={};
 const sorted=list.slice().sort((a,b)=>a.t0-b.t0);
 gtx.font="600 8px "+MONO;
 sorted.forEach(j=>{const b=bandOf[j.lane]!=null?bandOf[j.lane]:bandNames.length-1;
  const y0=padT+b*bandH;
  let sub=0;
  while(rows[b+":"+sub]!=null&&rows[b+":"+sub]>j.t0)sub++;
  rows[b+":"+sub]=j.done?j.t1+2:1e9;
  const x0=Math.max(padL,X(j.t0)),x1=j.done?X(j.t1+1):W-4;
  if(x1<0||x0>W)return;
  const y=y0+4+sub*(rowH-3);
  if(y>y0+bandH-4)return;   // 带满溢出跳过（缩放或过滤可看全）
  const li=lanes.indexOf(j.lane),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  const ac=agentColor(j.agent);
  gtx.fillStyle=j.done?lc+"55":ac+"33";
  gtx.fillRect(x0,y,Math.max(3,x1-x0),rowH-6);
  gtx.strokeStyle=j.done?lc:ac;gtx.lineWidth=1;gtx.strokeRect(x0+.5,y+.5,Math.max(3,x1-x0)-1,rowH-7);
  if(!j.done){ // 运行中=右缘琥珀光标条
   gtx.fillStyle="#fde047";gtx.fillRect(x1-2,y,2,rowH-6);}
  if(x1-x0>34){gtx.fillStyle="#c9d4e0";gtx.fillText(j.id,x0+3,y+8);}
  if(ganttHover===j.id||(hi===j.id)){ // 双向联动：主图悬停 ↔ 运行图条高亮
   gtx.strokeStyle="#ffffffcc";gtx.lineWidth=1.5;
   gtx.strokeRect(x0-1.5,y-1.5,Math.max(4,x1-x0)+3,rowH-3);
   if(ganttHover===j.id){ // 悬停浮签：全名+agent+时段
    const tip=j.id+" · "+(j.agent||"?")+" · T"+j.t0+"→"+(j.done?("T"+j.t1):"运行中");
    gtx.font="600 10px "+MONO;
    const tw=gtx.measureText(tip).width+14;
    let tx=Math.min(x1+6,W-tw-4);let ty=y-24;if(ty<padT)ty=y+rowH+2;
    gtx.fillStyle="#0d1522f0";gtx.fillRect(tx,ty,tw,19);
    gtx.strokeStyle="#2b3f5a";gtx.lineWidth=1;gtx.strokeRect(tx+.5,ty+.5,tw-1,18);
    gtx.fillStyle="#eaf6ff";gtx.fillText(tip,tx+7,ty+13);}}});
 // 图例
 gtx.fillStyle="#556777";gtx.font="9px system-ui";
  gtx.fillText("■ 完成  ▌运行中（琥珀光标）  颜色=泳道域 / 描边=认领 agent  ·  滚轮缩放 · 拖拽平移 · 点条跳主图",padL,H-4);
  const sw=document.getElementById("srcSwitch");
  if(sw&&!sw._built){sw._built=true;
   const agents=[];evs.forEach(e=>{if(e.agent&&agents.indexOf(e.agent)<0)agents.push(e.agent);});
   sw.innerHTML="<span class='vt' style='border:0;cursor:default;color:var(--dim2)'>agent:</span>"+agents.map(a2=>"<button class='vt' data-ag='"+a2+"' style='border-left:3px solid "+agentColor(a2)+"' onclick=\"setAgentFilter('"+a2+"')\">"+a2+"</button>").join("")
    +"<button class='vt on' data-ag='' onclick=\"setAgentFilter(null)\">全部</button>";}}
function setAgentFilter(a){agentFilter=a||null;
 document.querySelectorAll("#srcSwitch [data-ag]").forEach(b2=>b2.classList.toggle("on",b2.dataset.ag===agentFilter));
 drawGantt();}
let ganttView=null,gDrag=null;
gantt.addEventListener("wheel",ev=>{ev.preventDefault();
 const evs=simEvents();if(!evs.length)return;
 let tMax=0;evs.forEach(e=>{tMax=Math.max(tMax,parseT(e.ts)+2);});
 if(!ganttView)ganttView={t0:0,t1:tMax};
 const f=ev.deltaY<0?0.8:1.25;
 const anchor=ganttView.t0+(ev.offsetX-8)/(gantt.clientWidth-16)*(ganttView.t1-ganttView.t0);
 let span=(ganttView.t1-ganttView.t0)*f;span=Math.min(tMax*2,Math.max(8,span));
 ganttView.t0=Math.max(0,anchor-(anchor-ganttView.t0)*f);
 ganttView.t1=ganttView.t0+span;drawGantt();},{passive:false});
gantt.addEventListener("pointerdown",ev=>{gDrag={x:ev.clientX,t0:ganttView?ganttView.t0:0,t1:ganttView?ganttView.t1:0};
 try{gantt.setPointerCapture(ev.pointerId);}catch(e2){}});
gantt.addEventListener("pointermove",ev=>{
 if(!gDrag&&ganttView){const rect=gantt.getBoundingClientRect();
  ganttHover=hitGantt(ev.clientX-rect.left,ev.clientY-rect.top);
  if(ganttHover){hi=ganttHover;dirty=true;}   // 双向联动：运行图悬停 → 主图节点高亮
  else if(hi&&selSet.size===0&&!sel){hi=null;dirty=true;}
  return;}
 if(!gDrag||!ganttView)return;
 const span=gDrag.t1-gDrag.t0,d=(ev.clientX-gDrag.x)/(gantt.clientWidth-16)*span;
 let t0=gDrag.t0-d;ganttView={t0:Math.max(0,t0),t1:Math.max(8,t0+span)};
 if(ganttView.t0===0)ganttView.t1=Math.max(ganttView.t1,span);drawGantt();});
gantt.addEventListener("pointerup",()=>{gDrag=null;});
let ganttHover=null;
function hitGantt(x,y){ // 命中检测：{type:"task",id} 或 {type:"band",lane}（空带区域=聚拢该泳道）
 const evs=simEvents();if(!evs.length)return null;
 const span=ganttView.t1-ganttView.t0,W=gantt.clientWidth-16;
 const bandKeys=[];Object.keys(ganttJobs).forEach(id=>{if(bandKeys.indexOf(ganttJobs[id].lane)<0)bandKeys.push(ganttJobs[id].lane);});
 const padT=8,bandH=Math.min(46,(gantt.clientHeight-26)/bandKeys.length);
 const hit=Object.keys(ganttJobs).find(id=>{const j=ganttJobs[id];
  const b=bandKeys.indexOf(j.lane),y0=padT+b*bandH;
  const x0=8+(j.t0-ganttView.t0)/span*W,x1=j.done?8+(j.t1+1-ganttView.t0)/span*W:W+8;
  return y>=y0&&y<=y0+bandH&&x>=x0-4&&x<=x1+4;});
 if(hit)return{type:"task",id:hit};
 const bi=Math.floor((y-padT)/bandH);
 return (bi>=0&&bi<bandKeys.length)?{type:"band",lane:bandKeys[bi]}:null;}
gantt.addEventListener("click",ev=>{ // 点条=跳主图特写；点空带=主图聚拢该泳道
 const rect=gantt.getBoundingClientRect();
 const hit2=hitGantt(ev.clientX-rect.left,ev.clientY-rect.top);
 if(!hit2)return;
 if(hit2.type==="task"){setView("graph");jump(hit2.id);}
 else if(hit2.type==="band"){setView("graph");
  const chip=[].find.call(document.querySelectorAll(".lchip"),x=>x.textContent.indexOf(hit2.lane)>=0);
  if(chip)chip.click();  // 复用泳道胶囊单击=聚拢该线
 }});
gantt.addEventListener("click",ev=>{ // 点条=跳主图特写；点空带=主图聚拢该泳道
 const rect=gantt.getBoundingClientRect();
 const hit=hitGantt(ev.clientX-rect.left,ev.clientY-rect.top);
 if(!hit)return;
 if(hit.type==="task"){setView("graph");jump(hit.id);}
 else if(hit.type==="band"){setView("graph");
  const chip=[].find.call(document.querySelectorAll(".lchip"),x=>x.textContent.indexOf(hit.lane)>=0);
  if(chip)chip.click();  // 复用泳道胶囊单击=聚拢该线
 }});
function buildLogList(){const evs=simEvents().slice().reverse();
 const el=document.getElementById("logList");
 el.innerHTML=evs.map(e=>"<div class='lst' onclick='sideSelect(\""+e.task+"\")' onmouseenter='hi=\""+e.task+"\";dirty=true'>"
  +"<span class='dot' style='background:"+agentColor(e.agent)+"'></span>"
  +"<span class='lid'>"+e.ts+"</span><span class='lname'>"+e.agent+" → "+e.action+" "+e.task+"</span>"
  +"<span class='lgo'>⤢</span></div>").join("")
  ||"<div class='ph'>无调度日志</div>";}
window.addEventListener("resize",()=>{sizeGantt();drawGantt();});
function exportTxt(){ // 编辑闭环：导出完整源文件（状态/依赖/布局/新任务全含）→ 覆盖源 txt → --check
 const bad=[];
 nodes.forEach(n=>{(n.prs||[]).forEach(p=>{
  if(p===n.id)bad.push(n.id+" 自环前置");
  else if(!byId[p])bad.push(n.id+" 前置悬空 "+p);});});
 if(bad.length&&!confirm("发现 "+bad.length+" 处问题（导出后 --check 会报 ERROR）：\n"+bad.slice(0,6).join("\n")+"\n仍要导出吗？"))return;
 let out="# 任务依赖图（看板导出——覆盖 docs/项目/任务依赖图.txt 后运行 python tools/deptask/gen.py --check）\n";
 out+="# 校验: python tools/deptask/gen.py --check   生成: python tools/deptask/gen.py\n";
 out+="线序: "+lanes.join(", ")+"\n";
 if(divideX!=null)out+="分割线: "+Math.round(divideX)+"\n";
 out+="\n";
 CLUSTERS.forEach(c=>{out+="簇 "+c.id+" | 名称="+c.name+" | 成员="+c.members.join(",")
  +(folded[c.id]?" | 折叠=1":"")+(c.note?" | 注="+c.note:"")+"\n";});
 nodes.forEach(n=>{out+=(n.kind==="里程碑"?"里程碑 ":"任务 ")+n.id
  +" | 名称="+n.name+" | 线="+n.lane+" | 状态="+n.status
  +(n.prs&&n.prs.length?" | 前置="+n.prs.join(","):"")
  +(n.domain&&n.domain.length?" | 域="+(Array.isArray(n.domain)?n.domain.join(","):n.domain):"")+(n.tree?" | 树="+n.tree:"")
  +(n.x!=null?" | 位置="+n.px.toFixed(1)+","+n.py.toFixed(1):"")  // 「自动重排」后 x 置 null，不写位置＝保留 dagre 自由态
  +(n.exempt?" | 豁免=1":"")+(n.tier?" | 级="+n.tier:"")+(n.claim?" | 认领="+n.claim:"")
  +(n.doc?" | 文档="+n.doc:"")+(n.note?" | 注="+n.note:"")+"\n";});
 const a=document.createElement("a");
 a.href=URL.createObjectURL(new Blob([out],{type:"text/plain;charset=utf-8"}));
 a.download="任务依赖图.txt";a.click();}
// ── 启动 ──
measureCards();
if(!manual0)divideX=null;
rebuildView();                 // 先建视图集（VN/VE），簇虚拟节点取成员质心
if(manual0){nodes.forEach(n=>{n.px=n.x;n.py=n.y;});rebuildView();}
else dagreLayout();            // 对视图集布局并回写成员坐标
rebuildView();                 // 布局后重建：折叠簇卡片取新质心
locateActive();
setView((location.hash.match(/view=(\w+)/)||[])[1]||"graph",true);   // hash 路由：#view=producer 直达；force=启动强制初始化
addEventListener("hashchange",()=>{const v=(location.hash.match(/view=(\w+)/)||[])[1];if(v&&v!==curView)setView(v);});
let _last=0;
requestAnimationFrame(function loop(ts){if(critOnly||nodes.some(n=>n.claim)){animT++;dirty=true;}  // 蚂蚁线/认领呼吸：仅有关键路径模式或已认领任务时常驻重绘
 if(dirty&&ts-_last>16){draw();_last=ts;}
 requestAnimationFrame(loop);});
</script></body></html>
"""


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
