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
    任务 <id> | 名称=... | 线=... | 状态=... | [前置=a,b] | [域=...] | [树=...] | [位置=x,y] | [豁免=1] | [注=...]
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

布局：源里没有任何 位置= 时，页面用 dagre 自动布局；「保存布局」把当前坐标写进源文件
（冻结为手动布局）；页面「自动重排」可清掉回 dagre。位置=x,y 单位为世界像素。

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
FIELDS = {"名称", "线", "状态", "前置", "域", "树", "位置", "豁免", "注", "文档"}


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
                "exempt": False, "doc": "", "line": ln}
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
        ps = [p for p in n["prs"] if p in nodes]
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
    """未完成子图拓扑分层：波 0 = 前置全齐（就绪）；波 n = 最少还要等 n 道串行工序。"""
    done = {i for i, n in nodes.items() if n["status"] == "完成"}
    pend = {i for i, n in nodes.items() if n["status"] not in ("完成", "放弃")}
    level = {}

    def lv(i):
        if i in level:
            return level[i]
        unmet = [p for p in nodes[i]["prs"] if p in nodes and p not in done]
        level[i] = 0 if not unmet else 1 + max(lv(p) for p in unmet if p in pend)
        return level[i]

    for i in pend:
        lv(i)
    return {i: level[i] for i in pend}


def critical_path(nodes):
    """未完成子图最长链（按边数），返回 [端, …, 起点]（起点在前）。"""
    lv = wave_levels(nodes)
    if not lv:
        return []
    done = {i for i, n in nodes.items() if n["status"] == "完成"}
    tail = max(lv, key=lambda i: lv[i])
    chain, cur = [], tail
    while lv.get(cur, 0) > 0:
        chain.append(cur)
        unmet = [p for p in nodes[cur]["prs"] if p in nodes and p not in done]
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
        if all(p in done for p in n["prs"]):
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

    adj = {i: nodes[i]["prs"] for i in nodes if i in nodes}
    color = {i: 0 for i in adj}
    for start in adj:
        if color[start]:
            continue
        stack = [(start, iter(adj[start]))]
        color[start] = 1
        while stack:
            node_it = stack[-1]
            nxt = None
            for child in node_it[1]:
                if child not in adj:
                    continue
                if color[child] == 1:
                    errs.append("E: 前置链成环，涉及 " + child)
                    stack = []
                    break
                if color[child] == 0:
                    nxt = child
                    break
            if nxt is None:
                color[node_it[0]] = 2
                stack.pop()
            else:
                color[nxt] = 1
                stack.append((nxt, iter(adj[nxt])))

    done = {i for i in nodes if nodes[i]["status"] == "完成"}
    for n in nodes.values():
        if (n["status"] in ACTIVE or n["status"] == "可开工") and not n["exempt"]:
            unmet = [p for p in n["prs"] if p not in done]
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


def gen_html(nodes, edges, lane_order, errors, warns, clusters, divide_hint, ready=None, crit=None, producer=None) -> str:
    data = {
        "lanes": lane_order,
        "nodes": [{"id": n["id"], "name": n["name"], "kind": n["kind"], "lane": n["lane"],
                   "status": n["status"], "prs": n["prs"], "domain": ",".join(n["domain"]),
                   "tree": n["tree"], "note": n["note"], "exempt": n["exempt"], "doc": n["doc"],
                   "x": n["pos"][0] if n["pos"] else None,
                   "y": n["pos"][1] if n["pos"] else None} for n in nodes.values()],
        "edges": [{"a": e["a"], "b": e["b"]} for e in edges],
        "check": {"errors": errors, "warns": warns},
        "divideX": divide_hint,
        "ready": sorted(ready or []),
        "crit": crit or [],
        "producer": producer or {},
        "clusters": [{"id": c["id"], "name": c["name"], "members": c["members"],
                    "note": c["note"], "folded": c["folded"]} for c in clusters],
    }
    js = (Path(__file__).parent / "dagre.min.js").read_text(encoding="utf-8")
    return HTML.replace("/*__DAGRE__*/", js).replace("/*__DATA__*/null", json.dumps(data, ensure_ascii=False))


# ─────────────────────── HTML 模板 v3（dagre + 端口贝塞尔） ───────────────────────
HTML = r"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<title>任务依赖图</title>
<style>
 :root{--bg:#0f1216;--panel:#161b22;--panel2:#1c222b;--line:#2a313a;--txt:#e6edf3;--sub:#9aa7b4;--acc:#58a6ff}
 html,body{margin:0;height:100%;overflow:hidden;background:var(--bg);color:var(--txt);
   font-family:"Segoe UI","Microsoft YaHei",system-ui,sans-serif;font-size:13px}
 #bar{position:fixed;inset:0 0 auto 0;display:flex;flex-direction:column;gap:6px;
   padding:8px 14px;background:linear-gradient(180deg,#1a212b,#141920);
   border-bottom:1px solid var(--line);box-shadow:0 4px 16px #0007;z-index:20}
 #bar .row{display:flex;align-items:center;gap:8px;min-width:0;flex-wrap:wrap}
 #bar .sep{width:1px;height:16px;background:var(--line);flex-shrink:0}
 #bar .sub{font-size:10.5px;color:var(--sub);letter-spacing:2px;white-space:nowrap;margin-top:1px}
 #bar b{font-size:14.5px;letter-spacing:1px;white-space:nowrap;display:flex;align-items:center;gap:7px}
 #bar b::before{content:"";width:10px;height:10px;border-radius:3px;flex-shrink:0;
   background:linear-gradient(135deg,#58a6ff,#bc8cff);box-shadow:0 0 8px #58a6ff66}
 #bar .chips{margin-left:auto;display:flex;gap:6px;flex-shrink:0}
 #bar .btn{background:transparent;border:1px solid var(--line);border-radius:7px;color:#c9d4e0;
   padding:4px 10px;cursor:pointer;font-size:12px;white-space:nowrap;transition:all .15s}
 #bar .btn:hover{background:#232b36;border-color:#3d4754;color:var(--txt)}
 #bar .btn:active{transform:translateY(1px)}
 #bar .btn.primary{background:#58a6ff1a;border-color:#58a6ff44;color:#79b8ff}
 #bar .btn.primary:hover{background:#58a6ff2e;border-color:#58a6ff77}
 #search{background:#0d1117;border:1px solid var(--line);border-radius:16px;color:var(--txt);
   padding:4px 12px;font-size:12px;width:170px;outline:none;transition:all .15s}
 #search:focus{border-color:var(--acc);box-shadow:0 0 0 2px #58a6ff22;width:200px}
 #barRow2{overflow-x:auto;scrollbar-width:thin}
 #barRow2::-webkit-scrollbar{height:5px}
 #barRow2::-webkit-scrollbar-thumb{background:#2a313a;border-radius:3px}
 #legend{display:flex;gap:9px;font-size:10.5px;color:var(--sub);align-items:center;flex-shrink:0}
 #legend>span{white-space:nowrap;flex-shrink:0}
 .sw{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:4px;vertical-align:-1px}
 #lanes{display:flex;gap:5px;flex-shrink:0}
 .lchip{font-size:11px;padding:2px 9px;border-radius:20px;border:1px solid #ffffff10;cursor:pointer;
   background:#1c222b;color:#c9d4e0;user-select:none;white-space:nowrap;flex-shrink:0;transition:all .15s}
 .lchip:hover{background:#242c37;border-color:#3d4754}
 .lchip.focus{border-color:var(--acc);color:var(--acc);background:#58a6ff1a}
 .lchip.off{opacity:.35;text-decoration:line-through}
 #checkChip,#readyChip,#critChip{font-size:11px;padding:3px 10px;border-radius:20px;cursor:pointer;
   background:#0d1117;border:1px solid var(--line);white-space:nowrap;transition:border-color .15s}
 #panel{position:fixed;top:92px;right:10px;width:320px;max-height:72vh;overflow:auto;
   background:#161b22f5;border:1px solid var(--line);border-radius:10px;padding:12px 14px;
   font-size:12.5px;display:none;z-index:20;line-height:1.75;box-shadow:0 8px 30px #0009}
 #panel h3{margin:0 0 4px;font-size:14.5px}
 #panel .tag{display:inline-block;background:var(--panel2);border:1px solid var(--line);border-radius:5px;
   padding:0 7px;margin:2px 4px 2px 0;font-size:11.5px;cursor:pointer}
 #panel .tag:hover{border-color:var(--acc);color:var(--acc)}
 #panel .row{color:var(--sub);margin-top:6px}
 #msgs{position:fixed;bottom:0;left:0;right:0;max-height:34vh;overflow:auto;background:#161b22f5;
   border-top:1px solid var(--line);font-size:12px;padding:8px 14px;display:none;z-index:20;line-height:1.9}
 #msgs .e{color:#f85149}#msgs .w{color:#d29922}
 #help{position:fixed;inset:0;background:#0009;display:none;z-index:40;align-items:center;justify-content:center}
 #help>div{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:20px 26px;
   max-width:460px;line-height:2.1;font-size:13px}
 #help b{color:var(--acc)}
 #mini{position:fixed;right:12px;bottom:12px;border:1px solid var(--line);border-radius:8px;
   background:#161b22cc;z-index:15;cursor:crosshair}
 #zoom{position:fixed;left:12px;bottom:12px;font-size:11px;color:var(--sub);z-index:15;
   background:#161b22cc;border:1px solid var(--line);border-radius:6px;padding:3px 8px}
 canvas#cv{display:block;position:fixed;inset:0}
 /* ── 视图页签（岗位工作台） ── */
 #viewTabs{gap:4px}
 .vtab{font-size:11.5px;padding:2px 11px;border-radius:16px;border:1px solid #ffffff10;cursor:pointer;
   background:#161b22;color:#9aa7b4;user-select:none;white-space:nowrap;flex-shrink:0;transition:all .15s}
 .vtab:hover{color:var(--txt);border-color:#3d4754}
 .vtab.on{background:#58a6ff1f;border-color:#58a6ff66;color:#79b8ff;font-weight:600}
 /* ── 右键菜单 / 弹窗 ── */
 #ctx{position:fixed;display:none;background:#1c222bf2;border:1px solid #3d4754;border-radius:9px;
   padding:5px 0;z-index:50;min-width:170px;box-shadow:0 10px 30px #000a;font-size:12px;max-height:60vh;overflow:auto}
 #ctx .ch{color:var(--sub);font-size:10.5px;padding:4px 14px 2px;letter-spacing:1px}
 #ctx .ci{padding:5px 14px;cursor:pointer;white-space:nowrap}
 #ctx .ci:hover{background:#58a6ff22}
 #modal{position:fixed;inset:0;background:#000a;display:none;align-items:center;justify-content:center;z-index:60}
 #modal>div{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px 22px;
   width:340px;display:flex;flex-direction:column;gap:8px;font-size:12.5px}
 #modal h3{margin:0 0 4px;font-size:14.5px}
 #modal label{display:flex;flex-direction:column;gap:3px;color:var(--sub)}
 #modal input,#modal select{background:#0d1117;border:1px solid var(--line);border-radius:6px;color:var(--txt);
   padding:5px 8px;font-size:12px;outline:none}
 #modal input:focus,#modal select:focus{border-color:var(--acc)}
 #modal .btns{display:flex;gap:8px;justify-content:flex-end;margin-top:6px}
 #modal .go{background:#58a6ff22;border:1px solid #58a6ff55;color:#79b8ff;border-radius:7px;
   padding:6px 16px;cursor:pointer;font-size:12.5px}
 #modal .no{background:transparent;border:1px solid var(--line);color:var(--sub);border-radius:7px;
   padding:6px 12px;cursor:pointer;font-size:12.5px}
 /* ── 制作人仪表盘 ── */
 #dash{position:fixed;left:0;right:0;bottom:0;display:none;overflow:auto;background:var(--bg);z-index:10;
   padding:16px 18px 26px}
 #dash .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(330px,1fr));gap:14px;max-width:1500px}
 #dash .card{background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:13px 15px}
 #dash .card h4{margin:0 0 9px;font-size:13px;color:var(--acc);letter-spacing:.5px}
 #dash .stats{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
 #dash .stat{background:#0d1117;border:1px solid var(--line);border-radius:8px;padding:8px 10px;text-align:center}
 #dash .stat b{font-size:20px;display:block}
 #dash .stat span{font-size:10.5px;color:var(--sub)}
 .tchip{display:inline-block;background:#1c222b;border:1px solid #ffffff12;border-radius:6px;padding:2px 8px;
   margin:2px 3px 2px 0;font-size:11.5px;cursor:pointer;color:#c9d4e0;white-space:nowrap;transition:all .12s}
 .tchip:hover{border-color:var(--acc);color:var(--acc)}
 .tchip .dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:5px;vertical-align:0}
 #dash .laneHead{font-size:11px;color:var(--sub);margin:7px 0 2px;letter-spacing:1px}
 #dash .bar{height:7px;background:#0d1117;border:1px solid #2a313a;border-radius:4px;overflow:hidden;flex:1}
 #dash .bar i{display:block;height:100%;background:linear-gradient(90deg,#2dd4bf,#3fb950)}
 #dash .gate{display:flex;align-items:center;gap:9px;margin:6px 0;font-size:11.5px}
 #dash .gate .nm{width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;cursor:pointer}
 #dash .gate .nm:hover{color:var(--acc)}
 #dash .gate .pc{width:46px;text-align:right;color:var(--sub);font-size:10.5px}
 #dash .warn{font-size:11.5px;color:#d29922;line-height:1.7;word-break:break-all}
 #dash .hint{font-size:10.5px;color:#6e7a87;margin-top:6px}
 @media (max-width:1150px){#bar .sub{display:none}#search{width:130px}}
 @media (max-width:860px){#legend{display:none}#bar .btn{padding:4px 7px;font-size:11.5px}#search{width:110px}}
</style></head><body>
<div id="bar"><div class="row"><b title="任务依赖图 · 唯一真相源 docs/项目/任务依赖图.txt">任务依赖图</b><span class="sub">DAG 调度台</span>
 <span class="sep"></span>
 <input id="search" placeholder="搜索 id / 名称 / 备注…">
 <span class="sep"></span>
 <button class="btn" onclick="locateActive()" title="定位到进行中/可开工任务区（活跃面）">⌖ 当前面</button>
 <button class="btn" onclick="fitAll()" title="缩放至全图可见">⛶ 全图</button>
 <button class="btn" onclick="relayout()" title="dagre 重新分层布线（交叉最小化；会清除手动布局）">⟲ 重排</button>
 <button class="btn" id="exportBtn" onclick="exportTxt()" title="导出完整源文件（含状态/依赖/布局编辑）→ 覆盖 docs/项目/任务依赖图.txt → 跑 --check 校验">⬇ 导出源</button>
 <button class="btn" onclick="showDivide=!showDivide;dirty=true" title="完成/未完成分割墙显隐（拖墙=右区整体平移）">✂ 分割墙</button>
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
<div id="modal"><div><h3>➕ 新建任务</h3>
 <label>id（英文标识符）<input id="ntId" placeholder="如 tech_rebuild2"></label>
 <label>名称<input id="ntName" placeholder="一句话说清交付物"></label>
 <label>线<select id="ntLane"></select></label>
 <label>状态<select id="ntStatus"></select></label>
 <label>前置（逗号分隔 id，可留空）<input id="ntPrs" placeholder="root"></label>
 <label>域（逗号分隔文件/目录，可留空）<input id="ntDomain" placeholder="modules/xxx"></label>
 <label>关联文档（可留空）<input id="ntDoc" placeholder="docs/设计/系统/xx.md"></label>
 <label>注<input id="ntNote"></label>
 <div class="btns"><button class="no" onclick="closeModal()">取消</button><button class="go" onclick="submitNewTask()">创建</button></div>
</div></div>
<div id="dash"></div>
<div id="panel"></div>
<div id="msgs"></div>
<div id="help"><div>
 <b>任务依赖图 · 操作（对标 Shader Graph / ComfyUI）</b><br>
 <b>视图</b>：顶栏第三排页签——全图 DAG / 🧭制作人（派活台）/ ⚙程序 / 📐策划 / 🎨美术 / 🧪测试；URL #view= 可直达<br>
 <b>框选</b>：左键拖空白画虚线框，松开选中框内任务；Shift+点=加选/减选；Esc 清选<br>
 <b>平移</b>：中键拖 / 右键拖 / 空格+左键拖（三通道）；滚轮=缩放；双击空白=适配全图<br>
 <b>移动</b>：拖节点=移动；框选后拖任一选中节点=批量移动（自动遵守分割墙）<br>
 <b>建依赖</b>：从卡片<b>右缘外 9px 热区</b>按下拖到目标卡片松开 = a→b 前置边（会防自环/重复）<br>
 <b>删依赖</b>：点边选中（高亮）后按 Del；或右键边→删除依赖<br>
 <b>右键菜单</b>：选中任务右键=批量改状态（7 态）/复制 id；空白右键=新建任务/全图/重排<br>
 <b>编辑闭环</b>：改状态/连边/新建后节点右上角亮●角标——点「⬇ 导出源」下载完整 txt，
 覆盖 docs/项目/任务依赖图.txt 后跑 <b>python tools/deptask/gen.py --check</b>（有错误禁派活）<br>
 <b>调度 chips</b>：✓校验 / 🚦可派（就绪集高亮）/ 🛤关键路径（最长链高亮）<br>
 <b>泳道胶囊</b>：单击=聚拢该线（前沿列左/后沿列右，再点退出且坐标不丢）· Alt+单击=显隐<br>
 点节点=详情（前置/被依赖/关联文档可点跳转）· 悬停=高亮上下游依赖链 · 双击节点=居中放大<br>
 右下小地图=点击/拖动跳转 · 拖分割墙=右区整体平移（节点只有变完成才能过墙）<br>
 <span style="color:var(--sub)">布局引擎 dagre（mermaid 同款）+ litegraph 式端口贝塞尔 ·
 源文件一行一记录语法见 任务依赖图.txt 头注释</span>
</div></div>
<canvas id="cv"></canvas>
<canvas id="mini" width="180" height="120"></canvas>
<div id="zoom"></div>
<script>/*__DAGRE__*/</script>
<script>const DATA=/*__DATA__*/null;</script>
<script>
"use strict";
const cv=document.getElementById("cv"),ctx=cv.getContext("2d");
const mini=document.getElementById("mini"),mctx=mini.getContext("2d");
const STATUS=["完成","待验收","进行中","可开工","阻塞","冻结","放弃"];
const ACTIVE=new Set(["进行中","待验收","完成"]);
const COL={"完成":"#3fb950","待验收":"#58a6ff","进行中":"#4c8dff","可开工":"#2dd4bf","阻塞":"#d29922","冻结":"#8b949e","放弃":"#6e7681"};
const LANE_COL=["#58a6ff","#bc8cff","#39c5cf","#e3b341","#ff7b72","#7ee787","#f778ba","#79c0ff"];
const FRAME_PAD=18,FRAME_TOP=34;
let BAR_H=80;  // 顶栏实际高度（resize 动态测量）：画布内容/分隔墙/聚拢标注从这条线以下开始
let dpr=1,VW=0,VH=0;
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
function visNode(n){return !laneHidden(n.lane)&&(!viewFilter.lanes||viewFilter.lanes.has(n.lane))&&(!viewFilter.ids||viewFilter.ids(n));}
function nodeVisible(n){return visNode(n)&&(!q||n._hit);}
function resize(){dpr=window.devicePixelRatio||1;VW=innerWidth;VH=innerHeight;
 BAR_H=document.getElementById("bar").offsetHeight||80;  // 窄屏换行/媒体查询后顶栏高度跟随实测
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
  n.cw=Math.max(128,Math.min(202,Math.max(w+22,pw+10,idw+18)));
  n.ch=11+n.lines.length*17+7+18;});}
function dagreLayout(){
 // 分区布局：完成子图与未完成子图各自独立 dagre，墙 = 两区中缝（自动重排与分隔墙的配合点）
 const D=VN.filter(n=>n.status==="完成"),U=VN.filter(n=>n.status!=="完成");
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
function laneFrames(){
 const fr={};
 VN.forEach(n=>{if(!n.lane||!visNode(n))return;
  const f=fr[n.lane]||(fr[n.lane]={minX:1e9,minY:1e9,maxX:-1e9,maxY:-1e9,n:0});
  f.minX=Math.min(f.minX,n.px);f.minY=Math.min(f.minY,n.py);
  f.maxX=Math.max(f.maxX,n.px+n.cw);f.maxY=Math.max(f.maxY,n.py+n.ch);f.n++;});
 return fr;}
function draw(){
 ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.fillStyle="#0f1216";ctx.fillRect(0,0,VW,VH);
 ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);
 // 泳道分组框（ComfyUI 式）
 const fr=laneFrames();
 lanes.forEach((ln,i)=>{if(laneVis[ln]===false)return;const f=fr[ln];if(!f)return;
  const c=LANE_COL[i%LANE_COL.length];
  const x=f.minX-FRAME_PAD,y=f.minY-FRAME_PAD-FRAME_TOP+14;
  const w=f.maxX-f.minX+FRAME_PAD*2,h=f.maxY-f.minY+FRAME_PAD*2+FRAME_TOP-14;
  ctx.fillStyle=c+"0a";roundRect(ctx,x,y,w,h,14);ctx.fill();
  ctx.strokeStyle=c+"2e";ctx.lineWidth=1.2;ctx.stroke();
  ctx.fillStyle=c+"cc";fontSmall();
  ctx.fillText("◤ "+ln+" · "+f.n,x+12,y+15);});
 CLUSTERS.forEach(c=>{if(folded[c.id])return;
  const ms=c.members.map(id=>byId[id]).filter(Boolean);if(!ms.length)return;
  const x0=Math.min(...ms.map(m=>m.px))-12,y0=Math.min(...ms.map(m=>m.py))-26;
  const x1=Math.max(...ms.map(m=>m.px+m.cw))+12,y1=Math.max(...ms.map(m=>m.py+m.ch))+12;
  const li=lanes.indexOf(ms[0].lane),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  ctx.strokeStyle=lc+"55";ctx.lineWidth=1.2;ctx.setLineDash([7,5]);
  roundRect(ctx,x0,y0,x1-x0,y1-y0,12);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle=lc+"cc";fontSmall();ctx.textAlign="left";
  ctx.fillText("▣ "+c.name+"（点击收起）",x0+10,y0+14);});
 const anc=hi?ancestors(hi):null,des=hi?descendants(hi):null;
 const cs=(critOnly&&CRIT.length)?new Set(CRIT):null;
 const lit=id=>(!hi&&!cs)||id===hi||(anc&&anc.has(id))||(des&&des.has(id))||(cs&&cs.has(id));
 // 边（端口对端口贝塞尔）
 VE.forEach(e=>{const a=vById[e.a],b=vById[e.b];if(!a||!b||!visNode(a)||!visNode(b))return;
  const on=lit(e.a)&&lit(e.b),bad=edgeBad(e),isSel=selEdge&&selEdge.a===e.a&&selEdge.b===e.b;
  const g=edgeGeom(e);
  ctx.strokeStyle=isSel?"#ffd35c":(bad?"#f85149":(on?"#58a6ffdd":"#3d4a5c"));
  ctx.lineWidth=isSel?3:((on||bad)?2:1.2);
  let ea=on?1:((hi||cs)?0.12:0.85);
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
  ctx.closePath();ctx.fill();ctx.globalAlpha=1;});
 // 节点
 const order=VN.slice().sort((a,b)=>((a.id===hi||a.id===sel)?1:0)-((b.id===hi||b.id===sel)?1:0));
 order.forEach(n=>{if(!nodeVisible(n))return;
  let dim=q?(n._hit?1:0.1):(hi?(n.id===hi||anc.has(n.id)||des.has(n.id)?1:0.16):1);
  if(focusLane&&n._f==="other")dim*=0.13;
  if(readyOnly&&n.status!=="完成"&&READY.indexOf(n.id)<0)dim*=0.08;
  if(cs&&!hi&&!cs.has(n.id))dim*=0.12;
  const x=n.px,y=n.py,w=n.cw,h=n.ch,c=COL[n.status];
  const li=lanes.indexOf(n.lane),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  ctx.globalAlpha=dim;
  const isDone=n.status==="完成";
  ctx.shadowColor="#00000077";ctx.shadowBlur=12;ctx.shadowOffsetY=3;
  ctx.fillStyle=isDone?lc+"16":"#171c23";roundRect(ctx,x,y,w,h,10);ctx.fill();  // 完成=泳道色淡底（区分领域）
  ctx.shadowColor="transparent";ctx.shadowBlur=0;ctx.shadowOffsetY=0;
  ctx.strokeStyle=n.id===sel?"#8ec2ff":(isDone?lc:c);ctx.lineWidth=n.id===sel?2:1.2;  // 完成=泳道色边框
  if(n.exempt)ctx.setLineDash([5,3]);
  roundRect(ctx,x,y,w,h,10);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle=lc;ctx.fillRect(x+1,y+1,4,h-2);            // 泳道色条
  ctx.fillStyle=c;ctx.fillRect(x+5,y+6,3,h-12);            // 状态色条
  if(n.kind==="里程碑"){ctx.fillStyle=c;ctx.font='11px sans-serif';ctx.fillText("◆",x+14,y+17);}
  if(n.kind==="簇"){ctx.fillStyle=c;ctx.font='11px sans-serif';ctx.fillText("▣",x+14,y+17);
   fontSmall();ctx.fillStyle="#9aa7b4";
   ctx.fillText("已完 "+n._clusterDone+"/"+n._clusterN+" · 点击展开/收起",x+11,y+h-1);}
  ctx.fillStyle="#e6edf3";fontCard();ctx.textAlign="left";
  n.lines.forEach((L,i)=>ctx.fillText(L,x+18+((n.kind==="里程碑"&&i===0)?13:0),y+23+i*17));
  fontSmall();const st=n.status+(n.exempt?" ·豁免":"");
  const pw=ctx.measureText(st).width+12;
  ctx.fillStyle=c+"26";roundRect(ctx,x+9,y+h-24,pw,16,8);ctx.fill();
  ctx.fillStyle=c;ctx.fillText(st,x+15,y+h-12);
  if(n.tree){ctx.fillStyle="#6e7a87";ctx.fillText("⌂ "+n.tree,x+9+pw+8,y+h-12);}
  if(n.id!==sel&&selSet.has(n.id)){ctx.strokeStyle="#58a6ff88";roundRect(ctx,x-2,y-2,w+4,h+4,11);ctx.stroke();}
  if(n.id===sel||n.id===hover){ctx.strokeStyle="#ffffff38";roundRect(ctx,x-3,y-3,w+6,h+6,12);ctx.stroke();}
  if(editedIds.has(n.id)){ctx.fillStyle="#e3b341";ctx.beginPath();ctx.arc(x+w-7,y+7,3.5,0,7);ctx.fill();}
  ctx.globalAlpha=1;});
 ctx.textAlign="left";
 // 框选矩形 / 连线预览（屏幕层）
 if(drag&&drag.box){ctx.setTransform(dpr,0,0,dpr,0,0);
  const x=Math.min(drag.sx,drag.cx),y=Math.min(drag.sy,drag.cy),
        w=Math.abs(drag.cx-drag.sx),h=Math.abs(drag.cy-drag.sy);
  ctx.fillStyle="#58a6ff1c";ctx.fillRect(x,y,w,h);
  ctx.strokeStyle="#58a6ff";ctx.setLineDash([5,4]);ctx.lineWidth=1;ctx.strokeRect(x,y,w,h);ctx.setLineDash([]);
  ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);}
 if(drag&&drag.link){const a=byId[drag.from];
  if(a){const x1=a.px+a.cw,y1=a.py+a.ch/2,x2=(drag.cx-view.x)/view.k,y2=(drag.cy-view.y)/view.k;
   const q3=Math.hypot(x2-x1,y2-y1)||1,dx=Math.max(30,q3*0.25);
   ctx.strokeStyle="#2dd4bf";ctx.lineWidth=2;ctx.setLineDash([6,4]);
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
 if(focusLines.pre!=null)draw(focusLines.pre,"#d29922","◤ 前沿（外部前置）");
 if(focusLines.post!=null)draw(focusLines.post,"#2dd4bf","后继（外部被依赖）◢");
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
 ctx.fillStyle="#3fb9500a";ctx.fillRect(0,BAR_H,sx,VH-BAR_H);
 ctx.strokeStyle="#3fb95066";ctx.lineWidth=1.5;ctx.setLineDash([10,6]);
 ctx.beginPath();ctx.moveTo(sx,BAR_H);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
 ctx.strokeStyle=divideHover?"#3fb950":"#3fb95066";ctx.lineWidth=divideHover?2.5:1.5;
 ctx.setLineDash([10,6]);ctx.beginPath();ctx.moveTo(sx,BAR_H);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
 ctx.fillStyle="#3fb950";fontSmall();ctx.textAlign="left";
 ctx.fillText("✂ 已完成（左）",Math.max(4,sx-110),BAR_H+14);
 ctx.fillStyle="#d29922";ctx.fillText("未完成（右）",sx+10,BAR_H+14);
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
function drawZoom(){document.getElementById("zoom").textContent=Math.round(view.k*100)+"%";}
function graphBBox(){const vis=VN.filter(n=>!focusLane||n._f!=="other");
 if(!vis.length)return null;
 const xs=vis.map(n=>n.px),ys=vis.map(n=>n.py);
 return{minX:Math.min(...xs)-60,minY:Math.min(...ys)-80,
  w:Math.max(...xs.map((v,i)=>v+vis[i].cw))-Math.min(...xs)+120,
  h:Math.max(...ys.map((v,i)=>v+vis[i].ch))-Math.min(...ys)+140};}
function centerOn(wx,wy,k){if(k)view.k=k;
 view.x=VW/2-wx*view.k;view.y=Math.max(BAR_H,VH/2-wy*view.k);dirty=true;}
function fitAll(){const g=graphBBox();
 view.k=Math.min((VW-30)/g.w,(VH-100)/g.h,1.2);
 view.x=(VW-g.w*view.k)/2-g.minX*view.k;
 view.y=Math.max(BAR_H,(VH-g.h*view.k)/2)-g.minY*view.k;dirty=true;}
function locateActive(){const act=VN.filter(n=>ACTIVE.has(n.status)||n.status==="可开工");
 const t=act.length?act:VN;
 const xs=t.map(n=>n.px+n.cw/2),ys=t.map(n=>n.py+n.ch/2);
 centerOn((Math.min(...xs)+Math.max(...xs))/2,(Math.min(...ys)+Math.max(...ys))/2,1);}
function relayout(){focusLane=null;focusLines=null;VN.forEach(n=>{if(!n.isCluster){n.x=null;n.y=null;}});
 divideX=null;dagreLayout();rebuildView();locateActive();dirty=true;}
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
function showPanel(n){const p=document.getElementById("panel");
 const chip=(id)=>{const t=byId[id];return"<span class='tag' onclick='jump(\""+id+"\")'>"+(t?t.name:id)+" · "+(t?t.status:"?")+"</span>";};
 p.innerHTML="<h3>"+(n.kind==="里程碑"?"◆ ":"")+n.name+"</h3>"
 +"<div><span class='tag' style='cursor:default;color:"+COL[n.status]+"'>"+n.status+"</span>"
 +(n.lane?"<span class='tag' style='cursor:default'>"+n.lane+"</span>":"")
 +(n.tree?"<span class='tag' style='cursor:default'>⌂ "+n.tree+"</span>":"")+"</div>"
 +(selSet.size>1?"<div class='row'>已框选 "+selSet.size+" 个（拖动批量移动 / 右键批量改状态）</div>":"")
 +(n.domain?"<div class='row'>文件域："+n.domain+"</div>":"")
 +(n.doc?"<div class='row'>📄 <a style='color:#79b8ff' href='"+docHref(n.doc)+"'>"+n.doc+"</a></div>":"")
 +(n.prs&&n.prs.length?"<div class='row'>前置（点击跳转）：<br>"+n.prs.map(chip).join("")+"</div>":"")
 +(blocksOf[n.id].length?"<div class='row'>被依赖：<br>"+blocksOf[n.id].map(chip).join("")+"</div>":"")
 +(n.note?"<div class='row' style='color:#c3cdd8'>"+n.note+"</div>":"")
 +(n.exempt?"<div class='row' style='color:#d29922'>⚠ 豁免派活校验（见注）</div>":"")
 +"<div class='row' style='color:#555'>"+n.id+"</div>";
 p.style.display="block";}
function jump(id){const cid=memberOf[id];if(cid&&folded[cid]){folded[cid]=false;rebuildView();}
 const n=byId[id];if(!n)return;sel=id;selSet=new Set([id]);selEdge=null;
 centerOn(n.px+n.cw/2,n.py+n.ch/2,1.1);showPanel(n);}
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
 if(selSet.size>1||((hit||selSet.size===1)&&!selEdge)){
  const ids=[...selSet];
  h+="<div class='ch'>"+(ids.length>1?"已选 "+ids.length+" 个任务 → 批量状态：":(ids[0]||hit.id)+" → 状态：")+"</div>";
  STATUS.forEach(s=>{h+="<div class='ci' onclick=\"setStatusAll('"+s+"')\">"+s+"</div>";});
  h+="<div class='ci' onclick='copySelIds()'>📋 复制所选 id</div>";
 }else if(!selEdge){
  h+="<div class='ci' onclick='openNewTask()'>➕ 新建任务…</div>"+
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
cv.onmousedown=ev=>{const p=toWorld(ev);
 if(ev.button===1||ev.button===2||(ev.button===0&&spaceDown)){   // 平移三通道
  if(ev.button===2)lastRmb={x:ev.clientX,y:ev.clientY};
  drag={pan:true,sx:ev.clientX,sy:ev.clientY,ox:view.x,oy:view.y,rmb:ev.button===2};return;}
 if(ev.button!==0)return;
 if(inMini(ev)){drag={mini:true};miniJump(ev);return;}
 if(showDivide&&divideX!=null&&Math.abs(ev.clientX-(divideX*view.k+view.x))<7){
  drag={divide:true,sx:ev.clientX,ox:divideX};return;}
 const port=portAt(p.x,p.y);                    // 输出端口热区：起连线
 if(port){drag={link:true,from:port.id,sx:ev.clientX,sy:ev.clientY,cx:ev.clientX,cy:ev.clientY};return;}
 const e=(!nodeAt(p.x,p.y))?edgeAt(p.x,p.y):null; // 点边=选中边（Del 删除）
 if(e){selEdge=e;sel=null;selSet=new Set();dirty=true;return;}
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
 dirty=true;};
addEventListener("mousemove",ev=>{if(!drag)return;
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
addEventListener("mouseup",ev=>{
 if(drag&&drag.box){
  const x1=Math.min(drag.sx,drag.cx),x2=Math.max(drag.sx,drag.cx),
        y1=Math.min(drag.sy,drag.cy),y2=Math.max(drag.sy,drag.cy);
  if(x2-x1>6||y2-y1>6){
   const a={x:(x1-view.x)/view.k,y:(y1-view.y)/view.k},b={x:(x2-view.x)/view.k,y:(y2-view.y)/view.k};
   const hit=[];VN.forEach(n=>{if(!nodeVisible(n)||n.isCluster)return;
    if(n.px+n.cw>a.x&&n.px<b.x&&n.py+n.ch>a.y&&n.py<b.y)hit.push(n.id);});
   selSet=new Set(hit);sel=hit[0]||null;selEdge=null;
   if(sel)showPanel(byId[sel]);else document.getElementById("panel").style.display="none";
  }else{sel=null;selSet=new Set();selEdge=null;hi=null;
   document.getElementById("panel").style.display="none";}
 }else if(drag&&drag.link){
  const p=toWorld(ev),t=nodeAt(p.x,p.y);
  if(t&&t.id!==drag.from&&addEdge(drag.from,t.id)){rebuildView();showPanel(t);}
 }else if(drag&&drag.n&&drag.n.isCluster&&!drag.moved){
  folded[drag.n.isCluster.id]=!folded[drag.n.isCluster.id];rebuildView();}
 drag=null;dirty=true;});
cv.onmousemove=ev=>{if(drag)return;const p=toWorld(ev);
 divideHover=showDivide&&divideX!=null&&Math.abs(ev.clientX-(divideX*view.k+view.x))<7;
 const n=nodeAt(p.x,p.y),po=portAt(p.x,p.y),ed=n?null:edgeAt(p.x,p.y);
 hover=n?n.id:null;hi=n?n.id:null;
 cv.style.cursor=divideHover?"col-resize":(po?"crosshair":(n?"grab":(ed?"pointer":(spaceDown?"grab":"crosshair"))));
 dirty=true;};
cv.onmouseleave=()=>{if(!sel){hi=null;dirty=true;}};
cv.ondblclick=ev=>{const p=toWorld(ev);const n=nodeAt(p.x,p.y);
 if(n){sel=n.id;selSet=new Set([n.id]);centerOn(n.px+n.cw/2,n.py+n.ch/2,1.15);showPanel(n);}
 else fitAll();};
cv.onwheel=ev=>{ev.preventDefault();const f=ev.deltaY<0?1.13:0.885;const r=toWorld(ev);
 view.k=Math.min(2.5,Math.max(0.2,view.k*f));
 view.x=ev.clientX-r.x*view.k;view.y=ev.clientY-r.y*view.k;dirty=true;};
// ── 新建任务弹窗 ──
function openNewTask(){const m=document.getElementById("modal");m.style.display="flex";
 const ls=document.getElementById("ntLane");
 ls.innerHTML=lanes.map(l=>"<option>"+l+"</option>").join("");
 const st=document.getElementById("ntStatus");
 st.innerHTML=STATUS.map(s=>"<option"+(s==="可开工"?" selected":"")+">"+s+"</option>").join("");
 document.getElementById("ntId").focus();}
function closeModal(){document.getElementById("modal").style.display="none";}
function submitNewTask(){const id=document.getElementById("ntId").value.trim();
 if(!id){alert("id 必填");return;}
 if(byId[id]){alert("id 已存在："+id);return;}
 const n={id,kind:"任务",name:document.getElementById("ntName").value.trim()||id,
  lane:document.getElementById("ntLane").value,status:document.getElementById("ntStatus").value,
  prs:[],domain:(document.getElementById("ntDomain").value||"").split(/[,;]/).map(s=>s.trim()).filter(Boolean),
  tree:"",note:document.getElementById("ntNote").value.trim(),
  doc:document.getElementById("ntDoc").value.trim(),x:null,y:null,px:0,py:0,
  lines:[],cw:150,ch:56,inP:[],outP:[],_hit:false};
 nodes.push(n);byId[n.id]=n;prsOf[n.id]=[];blocksOf[n.id]=[];
 (document.getElementById("ntPrs").value||"").split(",").map(s=>s.trim()).filter(Boolean)
  .forEach(p=>addEdge(p,id));
 markEdit(id);measureCards();rebuildView();closeModal();
 sel=id;selSet=new Set([id]);jump(id);}
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
chipEl.style.background=chk.errors.length?"#f8514933":(chk.warns.length?"#d2992233":"#3fb95033");
chipEl.style.color=chk.errors.length?"#f85149":(chk.warns.length?"#d29922":"#3fb950");
chipEl.onclick=toggleMsgs;
// ── 调度视角开关：就绪集高亮 / 关键路径高亮 ──
const READY=DATA.ready||[],CRIT=DATA.crit||[];
let readyOnly=false,critOnly=false;
const rchip=document.getElementById("readyChip");
rchip.textContent="🚦 可派 "+READY.length;
rchip.style.color=READY.length?"#2dd4bf":"#8b949e";
rchip.style.background=READY.length?"#2dd4bf14":"#8b949e0d";
const cchip=document.getElementById("critChip");
cchip.textContent="🛤 关键路径 "+Math.max(0,CRIT.length-1)+" 跳";
cchip.style.color=CRIT.length?"#e3b341":"#8b949e";
cchip.style.background=CRIT.length?"#e3b34114":"#8b949e0d";
function refreshChips(){rchip.style.borderColor=readyOnly?"#2dd4bf":"#2a313a";
 cchip.style.borderColor=critOnly?"#e3b341":"#2a313a";}
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
  document.getElementById("panel").style.display="none";dirty=true;return;}
 if(inField)return;
 if((ev.key==="Delete"||ev.key==="Backspace")&&selEdge){delEdge(selEdge);}});
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
let curView="graph";
function setView(v){curView=v;
 if(location.hash!=="#view="+v)location.hash="#view="+v;
 document.querySelectorAll(".vtab").forEach(t=>t.classList.toggle("on",t.dataset.v===v));
 viewFilter=VIEWS[v]||{};
 const dash=document.getElementById("dash"),showDash=v==="producer";
 dash.style.display=showDash?"block":"none";
 ["cv","mini","zoom"].forEach(id2=>{document.getElementById(id2).style.visibility=showDash?"hidden":"visible";});
 if(showDash){dash.style.top=BAR_H+"px";buildDash();return;}
 rebuildView();fitAll();dirty=true;}
function jumpTo(id){setView("graph");jump(id);}
function buildDash(){const P=DATA.producer||{},S=P.stats||{},d=document.getElementById("dash");
 const liveReady=nodes.filter(n=>n.status!=="完成"&&n.status!=="冻结"&&n.status!=="放弃"
  &&(n.prs||[]).every(p=>byId[p]&&byId[p].status==="完成"));
 const tch=(n,extra)=>"<span class='tchip' onclick='jumpTo(\""+n.id+"\")'>"
  +"<span class='dot' style='background:"+(COL[n.status]||"#888")+"'></span>"+n.name
  +(extra||"")+"</span>";
 let h="<div class='grid'>";
 h+="<div class='card' style='grid-column:1/-1'><h4>📊 项目快照</h4><div class='stats'>"
  +[["任务总数",S.nodes,""],["已完成",S.done,"#3fb950"],["进行/待验收",S.active,"#4c8dff"],
    ["就绪可派",liveReady.length,"#2dd4bf"],["阻塞(前置未齐)",S.blocked,"#d29922"],["冻结(有意延后)",S.frozen,"#8b949e"]]
   .map(x=>"<div class='stat'><b style='color:"+x[2]+"'>"+x[1]+"</b><span>"+x[0]+"</span></div>").join("")
  +"</div><div class='hint'>就绪集为实时计算；改状态/连边后本页即时生效（其余卡片重新生成后更新）</div></div>";
 if((P.combo||[]).length)h+="<div class='card'><h4>🚦 建议派活组合（域互斥 ≤6 线）</h4>"
  +P.combo.map(id=>byId[id]?tch(byId[id]," <span style='color:#6e7a87'>"+byId[id].lane+"</span>"):"").join("")+"</div>";
 if((P.crit||[]).length)h+="<div class='card'><h4>🛤 关键路径（"+(P.crit.length-1)+" 跳）</h4><div style='line-height:2.1'>"
  +P.crit.map((id,i)=>byId[id]?(i?"<span style='color:#6e7a87'> → </span>":"")+tch(byId[id]):"").join("")+"</div>"
  +"<div class='hint'>压缩关键路径靠拆依赖/拆任务/外购前置；加并发只能压非关键路径</div></div>";
 const byLane={};liveReady.forEach(n=>{(byLane[n.lane||"（无线）"]=byLane[n.lane||"（无线）"]||[]).push(n);});
 h+="<div class='card'><h4>📦 就绪集 "+liveReady.length+" 个（点击跳全图定位）</h4><div style='max-height:340px;overflow:auto'>";
 Object.keys(byLane).sort().forEach(ln=>{h+="<div class='laneHead'>"+ln+" · "+byLane[ln].length+"</div>"
  +byLane[ln].map(n=>tch(n)).join("");});
 h+="</div></div>";
 if((P.gates||[]).length)h+="<div class='card'><h4>◆ 里程碑燃尽</h4>"
  +P.gates.map(g=>"<div class='gate'><span class='nm' onclick='jumpTo(\""+g.id+"\")' title='"+g.id+"'>"+g.name
   +"</span><span class='bar'><i style='width:"+(g.total?Math.round(100*g.done/g.total):0)+"%'></i></span><span class='pc'>"
   +g.done+"/"+g.total+"</span></div>").join("")+"</div>";
 const ws=(chk.warns||[]).slice(0,12),es=chk.errors||[];
 h+="<div class='card'><h4>⚠ 审计线索</h4>"
  +(es.length?es.map(e=>"<div class='warn'>"+e+"</div>").join(""):"")
  +(ws.length?ws.map(w=>"<div class='warn'>"+w+"</div>").join(""):"<div class='hint'>无警告</div>")+"</div>";
 h+="</div>";d.innerHTML=h;}
document.querySelectorAll(".vtab").forEach(t=>{t.onclick=()=>setView(t.dataset.v);});
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
  +(n.domain?" | 域="+n.domain:"")+(n.tree?" | 树="+n.tree:"")
  +(n.x!=null?" | 位置="+n.px.toFixed(1)+","+n.py.toFixed(1):"")  // 「自动重排」后 x 置 null，不写位置＝保留 dagre 自由态
  +(n.exempt?" | 豁免=1":"")+(n.doc?" | 文档="+n.doc:"")+(n.note?" | 注="+n.note:"")+"\n";});
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
setView((location.hash.match(/view=(\w+)/)||[])[1]||"graph");   // hash 路由：#view=producer 直达
addEventListener("hashchange",()=>{const v=(location.hash.match(/view=(\w+)/)||[])[1];if(v&&v!==curView)setView(v);});
let _last=0;
requestAnimationFrame(function loop(ts){if(dirty&&ts-_last>16){draw();_last=ts;}
 requestAnimationFrame(loop);});
</script></body></html>
"""


def main():
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
    out.write_text(gen_html(nodes, edges, lane_order, errors, warns, clusters, divide_hint, ready, crit, prod),
                   encoding="utf-8")
    print(f"已生成 {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
