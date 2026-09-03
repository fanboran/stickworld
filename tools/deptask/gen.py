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

校验规则（--check 退出码 1 = 有 ERROR）：
  E 悬空引用 / 环 / 重复 id
  E 派活违规   可开工/进行中/待验收/完成 的任务存在未完成前置且无 豁免=1（派活闸门）
  W 域冲突     两个 进行中 任务声明了相同 域 token（合并冲突热点）
  W 未知泳道   线= 不在 线序 里

布局：源里没有任何 位置= 时，页面用 dagre 自动布局；「保存布局」把当前坐标写进源文件
（冻结为手动布局）；页面「自动重排」可清掉回 dagre。位置=x,y 单位为世界像素。

用法：
  python tools/deptask/gen.py                 # 生成 docs/项目/任务依赖图.html
  python tools/deptask/gen.py --check         # 只校验
"""
import argparse
import json
import re
import sys
from pathlib import Path

STATUSES = ["完成", "待验收", "进行中", "可开工", "阻塞", "冻结", "放弃"]
ACTIVE = {"进行中", "待验收", "完成"}
FIELDS = {"名称", "线", "状态", "前置", "域", "树", "位置", "豁免", "注"}


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
                "exempt": False, "line": ln}
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
            else:
                errors.append(("W", ln, f"{nid}: 未知字段 {k}（可用: {'/'.join(sorted(FIELDS))}）"))
        if nid in nodes:
            errors.append(("E", ln, f"重复 id: {nid}"))
        else:
            nodes[nid] = node
    return nodes, edges, lane_order, errors, clusters, globals().get("_divide_hint")


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
    # 琐碎修复类（改一行文档/单条清理）不该独立存在，应合并进有后沿的任务或降级为附属步骤
    dependents = set()
    for e in edges:
        dependents.add(e["a"])  # a=被依赖的前置提供者；叶子=从不作为 a 的节点
    for n in nodes.values():
        if n["status"] not in ("完成", "放弃") and n["id"] not in dependents:
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


def gen_html(nodes, edges, lane_order, errors, warns, clusters, divide_hint) -> str:
    data = {
        "lanes": lane_order,
        "nodes": [{"id": n["id"], "name": n["name"], "kind": n["kind"], "lane": n["lane"],
                   "status": n["status"], "prs": n["prs"], "domain": ",".join(n["domain"]),
                   "tree": n["tree"], "note": n["note"], "exempt": n["exempt"],
                   "x": n["pos"][0] if n["pos"] else None,
                   "y": n["pos"][1] if n["pos"] else None} for n in nodes.values()],
        "edges": [{"a": e["a"], "b": e["b"]} for e in edges],
        "check": {"errors": errors, "warns": warns},
        "divideX": divide_hint,
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
 #bar{position:fixed;inset:0 0 auto 0;height:46px;display:flex;align-items:center;gap:8px;
   padding:0 12px;background:#161b22ee;backdrop-filter:blur(8px);border-bottom:1px solid var(--line);z-index:20}
 #bar b{font-size:14px;letter-spacing:.5px;white-space:nowrap}
 #bar .btn{background:var(--panel2);border:1px solid var(--line);border-radius:6px;color:var(--txt);
   padding:5px 11px;cursor:pointer;font-size:12px;white-space:nowrap}
 #bar .btn:hover{background:#242c37;border-color:#3d4754}
 #search{background:#0d1117;border:1px solid var(--line);border-radius:6px;color:var(--txt);
   padding:5px 10px;font-size:12px;width:160px;outline:none}
 #search:focus{border-color:var(--acc)}
 #legend{display:flex;gap:7px;font-size:11px;align-items:center;flex-wrap:wrap}
 .sw{width:9px;height:9px;border-radius:2px;display:inline-block;margin-right:3px;vertical-align:-1px}
 #lanes{display:flex;gap:5px;flex-wrap:wrap}
 .lchip{font-size:11px;padding:3px 9px;border-radius:10px;border:1px solid var(--line);cursor:pointer;
   background:var(--panel2);user-select:none;white-space:nowrap}
 .lchip.off{opacity:.35;text-decoration:line-through}
 #checkChip{font-size:11px;padding:3px 9px;border-radius:10px;cursor:pointer}
 #panel{position:fixed;top:56px;right:10px;width:320px;max-height:72vh;overflow:auto;
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
</style></head><body>
<div id="bar"><b>任务依赖图</b>
 <input id="search" placeholder="搜索 id / 名称 / 备注…">
 <button class="btn" onclick="locateActive()">定位当前</button>
 <button class="btn" onclick="fitAll()">适配全图</button>
 <button class="btn" onclick="relayout()">自动重排</button>
 <button class="btn" onclick="saveTxt()">保存布局</button>
 <button class="btn" onclick="showDivide=!showDivide;dirty=true">完成分割线</button>
 <button class="btn" onclick="toggleMsgs()">校验结果</button>
 <button class="btn" onclick="document.getElementById('help').style.display='flex'">帮助</button>
 <span id="checkChip"></span>
 <span id="legend"></span>
 <span id="lanes"></span>
</div>
<div id="panel"></div>
<div id="msgs"></div>
<div id="help"><div>
 <b>任务依赖图 · 操作</b><br>
 拖节点 = 移动 · 拖空白 = 平移 · 滚轮 = 缩放<br>
 点节点 = 详情（前置/被依赖可点击跳转）<br>
 悬停 = 高亮上下游依赖链（上游 = 要先完成的）<br>
 双击节点 = 居中放大 · 双击空白 = 适配全图<br>
 搜索框回车 = 跳到第一个匹配 · Esc = 清除<br>
 右下小地图 = 点击/拖动跳转 · 泳道胶囊 = 显隐该线<br>
 <b>▣ 封装簇</b> = 点击折叠卡片展开成员，点虚线框标签收起；拖动簇=整体平移<br>
 <b>◎ 聚拢</b> = 双击泳道胶囊：该线居中，前沿（外部前置）列左、后沿（外部被依赖）列右，无关淡出；再双击退出<br>
 <b>✂ 分隔墙</b> = 左完成右未完成；拖墙=右区整体平移；节点拖动被墙挡住，只有状态变完成才移到左侧<br>
 <b>自动重排</b> = dagre 重新分层布线（交叉最小化）<br>
 <b>保存布局</b> = 把当前位置写回源文件（下次打开即手动布局）<br>
 <span style="color:var(--sub)">红边 = 前置未完成却已开工（违规）· 虚线框 = 豁免校验 ·
 布局引擎 dagre（mermaid 同款）+ litegraph 式端口贝塞尔</span>
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
let dpr=1,VW=0,VH=0;
let nodes=DATA.nodes,edges=DATA.edges,lanes=DATA.lanes;
const manual0=nodes.some(n=>n.x!=null);
nodes.forEach(n=>{n.px=n.x!=null?n.x:0;n.py=n.y!=null?n.y:0;n.lines=[];n.cw=150;n.ch=56;n.inP=[];n.outP=[];});
const byId={};nodes.forEach(n=>byId[n.id]=n);
const prsOf={},blocksOf={};
nodes.forEach(n=>{prsOf[n.id]=[];blocksOf[n.id]=[];});
edges.forEach(e=>{if(prsOf[e.b]){prsOf[e.b].push(e.a);blocksOf[e.a].push(e.b);}});
nodes.forEach(n=>{(n.prs||[]).forEach(p=>{if(prsOf[n.id].indexOf(p)<0)prsOf[n.id].push(p);});});
let view={x:0,y:0,k:1},sel=null,hover=null,drag=null,hi=null,q="",dirty=true;
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
 if(divideX==null){const done=VN.filter(n=>n.status==="完成");
  if(done.length)divideX=Math.max(...done.map(n=>n.px+n.cw))+34;}
 enforceDivide();
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
function nodeVisible(n){return !laneHidden(n.lane)&&(!q||n._hit);}
function resize(){dpr=window.devicePixelRatio||1;VW=innerWidth;VH=innerHeight;
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
 VN.forEach(n=>{if(!n.lane)return;
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
 const lit=id=>!hi||id===hi||(anc&&anc.has(id))||(des&&des.has(id));
 // 边（端口对端口贝塞尔）
 VE.forEach(e=>{const a=vById[e.a],b=vById[e.b];if(!a||!b||laneHidden(a.lane)||laneHidden(b.lane))return;
  const on=lit(e.a)&&lit(e.b),bad=edgeBad(e);
  const g=edgeGeom(e);
  ctx.strokeStyle=bad?"#f85149":(on?"#58a6ffdd":"#3d4a5c");
  ctx.lineWidth=(on||bad)?2:1.2;
  let ea=on?1:(hi?0.12:0.85);
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
  if(n.id===sel||n.id===hover){ctx.strokeStyle="#ffffff38";roundRect(ctx,x-3,y-3,w+6,h+6,12);ctx.stroke();}
  ctx.globalAlpha=1;});
 ctx.textAlign="left";
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
  ctx.beginPath();ctx.moveTo(sx,46);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle=color;ctx.fillText(label,sx+8,64);};
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
 ctx.fillStyle="#3fb9500a";ctx.fillRect(0,46,sx,VH-46);
 ctx.strokeStyle="#3fb95066";ctx.lineWidth=1.5;ctx.setLineDash([10,6]);
 ctx.beginPath();ctx.moveTo(sx,46);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
 ctx.strokeStyle=divideHover?"#3fb950":"#3fb95066";ctx.lineWidth=divideHover?2.5:1.5;
 ctx.setLineDash([10,6]);ctx.beginPath();ctx.moveTo(sx,46);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
 ctx.fillStyle="#3fb950";fontSmall();ctx.textAlign="left";
 ctx.fillText("✂ 已完成（左）",Math.max(4,sx-110),60);
 ctx.fillStyle="#d29922";ctx.fillText("未完成（右）",sx+10,60);
 ctx.fillStyle="#9aa7b4";ctx.font='10px sans-serif';
 ctx.fillText("⟷ 可拖动：右区整体平移·两侧独立",Math.max(4,sx-110),74);
 ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);}
function drawMini(){mctx.setTransform(1,0,0,1,0,0);mctx.clearRect(0,0,180,120);
 const g=graphBBox();if(!g)return;
 const s=Math.min(168/g.w,104/g.h),ox=(180-g.w*s)/2,oy=(120-g.h*s)/2;
 VN.forEach(n=>{if(laneHidden(n.lane))return;
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
 view.x=VW/2-wx*view.k;view.y=Math.max(46,VH/2-wy*view.k);dirty=true;}
function fitAll(){const g=graphBBox();
 view.k=Math.min((VW-30)/g.w,(VH-100)/g.h,1.2);
 view.x=(VW-g.w*view.k)/2-g.minX*view.k;
 view.y=Math.max(46,(VH-g.h*view.k)/2)-g.minY*view.k;dirty=true;}
function locateActive(){const act=VN.filter(n=>ACTIVE.has(n.status)||n.status==="可开工");
 const t=act.length?act:VN;
 const xs=t.map(n=>n.px+n.cw/2),ys=t.map(n=>n.py+n.ch/2);
 centerOn((Math.min(...xs)+Math.max(...xs))/2,(Math.min(...ys)+Math.max(...ys))/2,1);}
function relayout(){focusLane=null;focusLines=null;VN.forEach(n=>{if(!n.isCluster){n.x=null;n.y=null;}});
 divideX=null;dagreLayout();rebuildView();locateActive();dirty=true;}
let focusLane=null,focusLines=null;
function applyFocus(){
 if(!focusLane){divideX=null;dagreLayout();rebuildView();locateActive();dirty=true;return;}
 const inS=VN.filter(n=>n.lane===focusLane);
 const inIds=new Set(inS.map(n=>n.id));
 const isPre=n=>VE.some(e=>e.a===n.id&&inIds.has(e.b));
 const isBlk=n=>VE.some(e=>e.b===n.id&&inIds.has(e.a));
 const extP=VN.filter(n=>!n.isCluster&&!inIds.has(n.id)&&isPre(n)&&!isBlk(n));
 const extB=VN.filter(n=>!n.isCluster&&!inIds.has(n.id)&&isBlk(n)&&!isPre(n));
 const both=VN.filter(n=>!n.isCluster&&!inIds.has(n.id)&&isPre(n)&&isBlk(n));
 const others=VN.filter(n=>!n.isCluster&&n!==null&&!inIds.has(n.id)&&!extP.includes(n)&&!extB.includes(n)&&!both.includes(n));
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
function showPanel(n){const p=document.getElementById("panel");
 const chip=(id)=>{const t=byId[id];return"<span class='tag' onclick='jump(\""+id+"\")'>"+(t?t.name:id)+" · "+(t?t.status:"?")+"</span>";};
 p.innerHTML="<h3>"+(n.kind==="里程碑"?"◆ ":"")+n.name+"</h3>"
 +"<div><span class='tag' style='cursor:default;color:"+COL[n.status]+"'>"+n.status+"</span>"
 +(n.lane?"<span class='tag' style='cursor:default'>"+n.lane+"</span>":"")
 +(n.tree?"<span class='tag' style='cursor:default'>⌂ "+n.tree+"</span>":"")+"</div>"
 +(n.domain?"<div class='row'>文件域："+n.domain+"</div>":"")
 +(n.prs&&n.prs.length?"<div class='row'>前置（点击跳转）：<br>"+n.prs.map(chip).join("")+"</div>":"")
 +(blocksOf[n.id].length?"<div class='row'>被依赖：<br>"+blocksOf[n.id].map(chip).join("")+"</div>":"")
 +(n.note?"<div class='row' style='color:#c3cdd8'>"+n.note+"</div>":"")
 +(n.exempt?"<div class='row' style='color:#d29922'>⚠ 豁免派活校验（见注）</div>":"")
 +"<div class='row' style='color:#555'>"+n.id+"</div>";
 p.style.display="block";}
function jump(id){const cid=memberOf[id];if(cid&&folded[cid]){folded[cid]=false;rebuildView();}
 const n=byId[id];if(!n)return;sel=id;centerOn(n.px+n.cw/2,n.py+n.ch/2,1.1);showPanel(n);}
// ── 交互 ──
function toWorld(ev){return{x:(ev.clientX-view.x)/view.k,y:(ev.clientY-view.y)/view.k};}
function nodeAt(x,y){for(let i=VN.length-1;i>=0;i--){const n=VN[i];
 if(!nodeVisible(n))continue;
 if(x>=n.px&&x<=n.px+n.cw&&y>=n.py&&y<=n.py+n.ch)return n;}return null;}
cv.onmousedown=ev=>{const p=toWorld(ev);
 if(showDivide&&divideX!=null&&Math.abs(ev.clientX-(divideX*view.k+view.x))<7){
  drag={divide:true,sx:ev.clientX,ox:divideX};return;}
 const n=nodeAt(p.x,p.y);
 if(ev.button===0&&n){drag={n,dx:p.x-n.px,dy:p.y-n.py,sx:ev.clientX,sy:ev.clientY,moved:false};sel=n.id;showPanel(n);}
 else if(inMini(ev)){drag={mini:true};miniJump(ev);}
 else{drag={pan:true,sx:ev.clientX,sy:ev.clientY,ox:view.x,oy:view.y,moved:true};
  if(ev.button===0){sel=null;hi=null;document.getElementById("panel").style.display="none";}}
 dirty=true;};
addEventListener("mousemove",ev=>{if(!drag)return;
 if(drag.mini){miniJump(ev);return;}
 if(drag.divide){const dx=(ev.clientX-drag.sx)/view.k;divideX=drag.ox+dx;enforceDivide();dirty=true;return;}
 if(drag.moved===false&&Math.hypot(ev.clientX-drag.sx,ev.clientY-drag.sy)>4)drag.moved=true;
 if(drag.pan){view.x=drag.ox+ev.clientX-drag.sx;view.y=drag.oy+ev.clientY-drag.sy;}
 else{const p=toWorld(ev);let nx=p.x-drag.dx,ny=p.y-drag.dy;
  const doneSide=drag.n.status==="完成";
  if(showDivide&&divideX!=null&&!drag.n.isCluster){
   if(doneSide)nx=Math.min(nx,divideX-8-drag.n.cw);else nx=Math.max(nx,divideX+8);}
  const dx=nx-drag.n.px,dy=ny-drag.n.py;
  drag.n.px=nx;drag.n.py=ny;
  if(drag.n.isCluster){drag.n.isCluster.members.forEach(id=>{const m=byId[id];m.px+=dx;m.py+=dy;});}
  else{drag.n.x=drag.n.px;drag.n.y=drag.n.py;}  // 标记手动位置：保存布局时写「位置=」
  computePorts();}  // 端口 y 是缓存值，拖动必须重算，否则贝塞尔垂直方向不跟随
 dirty=true;});
addEventListener("mouseup",ev=>{
 if(drag&&drag.n&&drag.n.isCluster&&!drag.moved){folded[drag.n.isCluster.id]=!folded[drag.n.isCluster.id];rebuildView();}
 drag=null;dirty=true;});
cv.onmousemove=ev=>{if(drag)return;const p=toWorld(ev);
 divideHover=showDivide&&divideX!=null&&Math.abs(ev.clientX-(divideX*view.k+view.x))<7;
 const n=nodeAt(p.x,p.y);
 hover=n?n.id:null;hi=n?n.id:null;
 cv.style.cursor=divideHover?"col-resize":(n?"grab":"default");dirty=true;};
cv.onmouseleave=()=>{if(!sel){hi=null;dirty=true;}};
cv.ondblclick=ev=>{const p=toWorld(ev);const n=nodeAt(p.x,p.y);
 if(n){sel=n.id;centerOn(n.px+n.cw/2,n.py+n.ch/2,1.15);showPanel(n);}
 else fitAll();};
cv.onwheel=ev=>{ev.preventDefault();const f=ev.deltaY<0?1.13:0.885;const r=toWorld(ev);
 view.k=Math.min(2.5,Math.max(0.2,view.k*f));
 view.x=ev.clientX-r.x*view.k;view.y=ev.clientY-r.y*view.k;dirty=true;};
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
 c.onclick=()=>{laneVis[l]=!laneVis[l];c.classList.toggle("off",!laneVis[l]);dirty=true;};
 c.title="单击=显隐该线 · 双击=聚拢到画面中央（观察前后沿边界）";
 c.ondblclick=ev=>{ev.preventDefault();focusLane=(focusLane===l)?null:l;focusLines=null;
  Object.keys(laneVis).forEach(k=>laneVis[k]=true);
  lanesBox.querySelectorAll(".lchip").forEach(x=>x.classList.remove("off"));
  if(focusLane){rebuildView();applyFocus();fitAll();}else{rebuildView();relayout();}
  dirty=true;};
 lanesBox.appendChild(c);});
const chk=DATA.check||{errors:[],warns:[]};
const chipEl=document.getElementById("checkChip");
chipEl.textContent="✓ "+chk.errors.length+"E / "+chk.warns.length+"W";
chipEl.style.background=chk.errors.length?"#f8514933":"#3fb95033";
chipEl.style.color=chk.errors.length?"#f85149":"#3fb950";
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
addEventListener("keydown",ev=>{if(ev.key==="Escape"&&document.activeElement!==searchBox){
 sel=null;hi=null;document.getElementById("panel").style.display="none";dirty=true;}});
function saveTxt(){let out="# 任务依赖图（可视化工具导出，可直接覆盖源文件）\n";
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
  +(n.x!=null?" | 位置="+n.px.toFixed(1)+","+n.py.toFixed(1):"")  // 「自动重排」后 x 置 null，保存时不写位置＝保留 dagre 自由态
  +(n.exempt?" | 豁免=1":"")+(n.note?" | 注="+n.note:"")+"\n";});
 const a=document.createElement("a");
 a.href=URL.createObjectURL(new Blob([out],{type:"text/plain"}));
 a.download="任务依赖图.txt";a.click();}
// ── 启动 ──
measureCards();
if(!manual0)divideX=null;
rebuildView();                 // 先建视图集（VN/VE），簇虚拟节点取成员质心
if(manual0){nodes.forEach(n=>{n.px=n.x;n.py=n.y;});rebuildView();}
else dagreLayout();            // 对视图集布局并回写成员坐标
rebuildView();                 // 布局后重建：折叠簇卡片取新质心
locateActive();
let _last=0;
requestAnimationFrame(function loop(ts){if(dirty&&ts-_last>16){draw();_last=ts;}
 requestAnimationFrame(loop);});
</script></body></html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--src", default="docs/项目/任务依赖图.txt")
    ap.add_argument("-o", "--out", default="docs/项目/任务依赖图.html")
    ap.add_argument("--check", action="store_true", help="只校验不生成")
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
    if errors:
        return 1
    if args.check:
        return 0
    out = root / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(gen_html(nodes, edges, lane_order, errors, warns, clusters, divide_hint), encoding="utf-8")
    print(f"已生成 {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
