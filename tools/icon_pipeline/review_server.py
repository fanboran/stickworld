# -*- coding: utf-8 -*-
"""图标建模验收工具：本地起 HTTP 服务，浏览器里逐枚标记建模满意/不满意+备注。

用法:
  python review_server.py [端口]      # 默认 8765，打开 http://127.0.0.1:8765
产物:
  <仓库根>/temp/review_result.json —— 逐枚 {name, model_ok, note}，供返工轮读取

只评「建模」（形体/比例/部件连接/辨识度），配色/描边/光影不在反馈范围。
图标清单挂 motifs.py 注册表（旧 7 枚在前），与 accept_sheet 排序一致。"""
import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ICON_DIR = os.path.join(ROOT, "temp", "icons")
RESULT = os.path.join(ROOT, "temp", "review_result.json")

sys.path.insert(0, HERE)
import motifs as M

OLD7 = [("锻造锤", "icon_hammer_v9"), ("爱心", "icon_heart_v9"),
        ("立方体", "test_cube_v9"), ("正球", "test_sphere_v9"),
        ("圆柱", "test_cylinder_v9"), ("圆锥", "test_cone_v9"),
        ("圆环", "test_torus_v9")]
_ALL = [{"name": n, "tag": t} for n, t in OLD7] + \
       [{"name": m["label"], "tag": m["tag"]} for m in M.MOTIFS]

# 既往轮次已标「满意」的不再进待标区（结果档案 temp/review_result_round*.json 全量合并）；
# RECHECK = 已满意但后续轮次重做过、需复验的名字；--all = 关闭过滤全量复
# 审（架构换代轮用：v2 重渲了全部图标，已过枚也须复验）
import glob as _glob
RECHECK = set()
SHOW_ALL = "--all" in sys.argv[1:]

def _prev_ok_names():
    ok = set()
    for fp in sorted(_glob.glob(os.path.join(ROOT, "temp", "review_result_round*.json"))):
        try:
            with open(fp, encoding="utf-8") as f:
                data = json.load(f)
            ok |= {it["name"] for it in data.get("items", []) if it.get("model_ok") is True}
        except Exception:
            pass
    return ok

_PREV_OK = set() if SHOW_ALL else _prev_ok_names()
ICONS = [ic for ic in _ALL if ic["name"] not in _PREV_OK or ic["name"] in RECHECK]
HIDDEN_OK = len(_ALL) - len(ICONS)

PAGE = """<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>图标建模验收 — stick-world</title>
<style>
  :root { --bg:#0e1116; --card:#171b22; --line:#2a3040; --fg:#dde2ea; --dim:#8a93a5;
          --ok:#3f9d5c; --bad:#c4524a; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg);
         font:14px/1.5 "Microsoft YaHei",system-ui,sans-serif; }
  header { position:sticky; top:0; z-index:5; background:var(--bg);
           border-bottom:1px solid var(--line); padding:10px 18px; }
  h1 { font-size:17px; margin:0 0 2px; }
  .hint { color:var(--dim); font-size:12.5px; }
  .hint b { color:#e8c46a; font-weight:600; }
  #bar { display:flex; align-items:center; gap:14px; margin-top:8px; flex-wrap:wrap; }
  #prog { font-size:14px; }
  #prog b { color:#7fc48f; }
  button { cursor:pointer; border-radius:6px; border:1px solid var(--line);
           background:#1e242f; color:var(--fg); padding:6px 14px; font-size:13.5px; }
  button:hover { border-color:#4a5568; }
  #save { background:#2d6a45; border-color:#2d6a45; font-weight:600; }
  #save:hover { background:#357c52; }
  #save.saved { background:#1e242f; border-color:var(--line); font-weight:400; }
  main { display:grid; grid-template-columns:repeat(auto-fill,minmax(168px,1fr));
         gap:12px; padding:16px 18px 60px; }
  .card { background:var(--card); border:1.5px solid var(--line); border-radius:9px;
          padding:10px 10px 8px; display:flex; flex-direction:column; gap:6px; }
  .card.ok   { border-color:var(--ok); }
  .card.bad  { border-color:var(--bad); }
  .imgwrap { width:64px; height:64px; margin:0 auto; cursor:zoom-in;
             background:conic-gradient(#9aa 25%,#778 0 50%,#9aa 0 75%,#778 0) 0 0/16px 16px;
             border-radius:4px; }
  .imgwrap img { width:64px; height:64px; display:block; }
  .nm { text-align:center; font-size:13.5px; }
  .btns { display:flex; gap:6px; }
  .btns button { flex:1; padding:4px 0; font-size:12.5px; }
  .btns .ok.on { background:var(--ok); border-color:var(--ok); color:#fff; }
  .btns .bad.on { background:var(--bad); border-color:var(--bad); color:#fff; }
  textarea { display:none; width:100%; min-height:44px; resize:vertical; font-size:12.5px;
             background:#10131a; color:var(--fg); border:1px solid var(--line);
             border-radius:6px; padding:5px 7px; }
  .card.bad textarea { display:block; }
  #modal { position:fixed; inset:0; background:rgba(0,0,0,.78); display:none;
           align-items:center; justify-content:center; flex-direction:column; gap:14px;
           cursor:zoom-out; z-index:10; }
  #modal img { image-rendering:auto; border-radius:6px;
               background:conic-gradient(#9aa 25%,#778 0 50%,#9aa 0 75%,#778 0) 0 0/32px 32px; }
  #modal .cap { font-size:15px; }
  #toast { position:fixed; bottom:18px; left:50%; transform:translateX(-50%);
           background:#2d6a45; color:#fff; padding:8px 22px; border-radius:8px;
           font-size:14px; opacity:0; transition:opacity .25s; pointer-events:none; }
</style>
</head>
<body>
<header>
  <h1>图标验收 · v2 分档换代审计 <span class="hint">__TOTAL__ 枚全量待标（__HIDDEN__ 枚已过枚本轮一并复验）· 点击图标可放大看 128/256 渲染</span></h1>
  <div class="hint">本轮是 <b>v2 渲染架构换代</b>（着色器分档替换 k-means）——<b>建模和观感都可以反馈</b>：形体/比例/部件连接，以及档位漂移、颜色观感、描边异常。
       点「不满意」可以写备注，也可以 <b>不写</b>——留空的由 AI 直读 64px 原图自查。v1/v2 并排对照页在 temp/compare_v1v2_64_p*.png。</div>
  <div id="bar">
    <span id="prog"></span>
    <button id="next">↓ 下一个未标记</button>
    <button id="save">保存并提交</button>
    <button id="dl">下载 JSON 备份</button>
    <span class="hint" id="savedAt"></span>
  </div>
</header>
<main id="grid"></main>
<div id="modal"><div class="cap" id="mcap"></div><img id="m256" width="256" height="256"><img id="m128" width="128" height="128"></div>
<div id="toast"></div>
<script>
const ICONS = __ICONS__;
const KEY = "icon_review_v4";
const state = {};
ICONS.forEach(ic => state[ic.name] = { model_ok: null, note: "" });

try { Object.assign(state, JSON.parse(localStorage.getItem(KEY) || "{}")); } catch (e) {}
fetch("/api/state").then(r => r.json()).then(j => {
  if (j && j.items && !localStorage.getItem(KEY)) {
    j.items.forEach(it => { if (state[it.name]) state[it.name] = { model_ok: it.model_ok, note: it.note || "" }; });
    render();
  }
}).catch(() => {});

const grid = document.getElementById("grid");
ICONS.forEach(ic => {
  const card = document.createElement("div");
  card.className = "card"; card.dataset.name = ic.name;
  card.innerHTML = `
    <div class="imgwrap" title="点击放大"><img loading="lazy" src="icons/${encodeURIComponent(ic.name)}_64.png"></div>
    <div class="nm">${ic.name}</div>
    <div class="btns">
      <button class="ok">✓ 满意</button><button class="bad">✗ 不满意</button>
    </div>
    <textarea placeholder="可选：问题描述（如"弦又飘了"）；留空=AI 自查"></textarea>`;
  const [bOk, bBad] = card.querySelectorAll("button");
  const ta = card.querySelector("textarea");
  bOk.onclick  = () => { const s = state[ic.name]; s.model_ok = s.model_ok === true  ? null : true;  render(); };
  bBad.onclick = () => { const s = state[ic.name]; s.model_ok = s.model_ok === false ? null : false; render(); };
  ta.oninput = () => { state[ic.name].note = ta.value; persist(); };
  card.querySelector(".imgwrap").onclick = () => openModal(ic.name);
  grid.appendChild(card);
});

function openModal(name) {
  document.getElementById("mcap").textContent = name + "（右 64 源 128 / 左 256，均为原生渲染）";
  const m = document.getElementById("modal");
  document.getElementById("m256").src = `icons/${encodeURIComponent(name)}_256.png`;
  document.getElementById("m128").src = `icons/${encodeURIComponent(name)}_128.png`;
  m.style.display = "flex";
  m.onclick = () => m.style.display = "none";
}

function render() {
  document.querySelectorAll(".card").forEach(card => {
    const s = state[card.dataset.name];
    card.classList.toggle("ok", s.model_ok === true);
    card.classList.toggle("bad", s.model_ok === false);
    card.querySelector(".ok").classList.toggle("on", s.model_ok === true);
    card.querySelector(".bad").classList.toggle("on", s.model_ok === false);
    card.querySelector("textarea").value = s.note;
  });
  const okN = ICONS.filter(i => state[i.name].model_ok === true).length;
  const badN = ICONS.filter(i => state[i.name].model_ok === false).length;
  document.getElementById("prog").innerHTML =
    `已标记 <b>${okN + badN}</b> / ${ICONS.length}（满意 ${okN} · 不满意 ${badN}）`;
  persist();
}

function persist() { localStorage.setItem(KEY, JSON.stringify(state)); }
function payload() {
  return { saved_at: new Date().toISOString(), total: ICONS.length,
           items: ICONS.map(ic => ({ name: ic.name, tag: ic.tag,
                                     model_ok: state[ic.name].model_ok,
                                     note: state[ic.name].note.trim() })) };
}
async function save() {
  try {
    const r = await fetch("/api/save", { method: "POST",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload()) });
    if (!r.ok) throw 0;
    document.getElementById("savedAt").textContent = "已保存到 temp/review_result.json";
  } catch (e) {
    download();
    document.getElementById("savedAt").textContent = "服务不可用，已改为下载 JSON";
  }
  const b = document.getElementById("save");
  b.classList.add("saved"); toast("已保存 ✓");
}
function download() {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([JSON.stringify(payload(), null, 2)], { type: "application/json" }));
  a.download = "review_result.json"; a.click();
}
document.getElementById("save").onclick = save;
document.getElementById("dl").onclick = download;
document.getElementById("next").onclick = () => {
  const c = document.querySelector(".card:not(.ok):not(.bad)");
  if (c) c.scrollIntoView({ behavior: "smooth", block: "center" });
  else toast("全部标记完毕，记得点「保存并提交」");
};
let tT;
function toast(s) { const t = document.getElementById("toast");
  t.textContent = s; t.style.opacity = 1; clearTimeout(tT); tT = setTimeout(() => t.style.opacity = 0, 1800); }
render();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):      # 静默：控制台只留启动行
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        if path in ("/", "/index.html"):
            html = PAGE.replace("__ICONS__", json.dumps(ICONS, ensure_ascii=False)) \
                       .replace("__TOTAL__", str(len(ICONS))) \
                       .replace("__HIDDEN__", str(HIDDEN_OK))
            self._send(200, html.encode("utf-8"), "text/html; charset=utf-8")
        elif path == "/api/state":
            if os.path.exists(RESULT):
                with open(RESULT, "rb") as f:
                    self._send(200, f.read())
            else:
                self._send(200, b"null")
        elif path.startswith("/icons/"):
            fp = os.path.join(ICON_DIR, os.path.basename(path[len("/icons/"):]))
            if os.path.isfile(fp):
                with open(fp, "rb") as f:
                    self._send(200, f.read(), "image/png")
            else:
                self._send(404, b"{}", "application/json")
        else:
            self._send(404, b"{}", "application/json")

    def do_POST(self):
        if self.path != "/api/save":
            self._send(404, b"{}", "application/json")
            return
        n = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(n).decode("utf-8"))
            marked = sum(1 for it in data["items"] if it["model_ok"] is not None)
            data["marked"] = marked
            with open(RESULT, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=1)
            self._send(200, json.dumps({"ok": True, "marked": marked}).encode())
        except Exception as e:
            self._send(400, json.dumps({"ok": False, "err": str(e)}).encode())


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"图标建模验收: http://127.0.0.1:{port}   （{len(ICONS)} 枚，Ctrl+C 退出）")
    sys.stdout.flush()
    srv.serve_forever()
