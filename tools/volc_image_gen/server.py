"""
火山引擎豆包文生图 - 本地代理服务

起一个本地 HTTP 服务, 接收文生图请求, 转发到火山引擎 Ark API,
自动下载生成的图片到 stick-world/assets/_raw/ 目录, 返回本地文件路径。

用法:
    # 1. 配置 API Key (二选一)
    #    a) 环境变量:  set ARK_API_KEY=xxxxxxxx
    #    b) 或在本脚本同目录创建 .env 文件, 内容: ARK_API_KEY=xxxxxxxx

    # 2. 启动服务
    python tools/volc_image_gen/server.py
    python tools/volc_image_gen/server.py --port 9000

    # 3. 调用 (任一 shell)
    curl -X POST http://localhost:8787/generate -H "Content-Type: application/json" -d "{\"prompt\":\"一只柴犬\"}"
    curl -X POST http://localhost:8787/generate -H "Content-Type: application/json" -d "{\"prompt\":\"像素风勇者\",\"size\":\"2K\",\"output_name\":\"hero\"}"

接口:
    POST /generate
        body: {
            "prompt":      str   必填, 提示词
            "model":       str   可选, 默认 doubao-seedream-5-0-pro-260628
            "size":        str   可选, 默认 "2K"
            "image":       str   可选, 参考图 (URL 或 base64 data:image/...;base64,...)
            "output_name": str   可选, 输出文件名(不含扩展名), 默认用时间戳
        }
        resp: { "ok":true, "file":"_raw/xxx.png", "path":"绝对路径", "url":"火山URL", "elapsed":3.2 }

    GET /health
        resp: { "ok":true, "api_key_loaded":true }

依赖: 仅 Python 标准库 (推荐 pip install certifi 启用 SSL 证书验证)
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sqlite3
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ---- Windows 控制台中文编码修复 -------------------------------------------
# Windows 终端默认 GBK, Python 按 UTF-8 输出中文会乱码, 这里强制 UTF-8
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

# ---- 配置 -----------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = SCRIPT_DIR.parent.parent / "stick-world" / "assets" / "_raw"
HISTORY_DIR = OUTPUT_DIR / "history"
HISTORY_DB = HISTORY_DIR / "history.db"
ENV_FILE = SCRIPT_DIR / ".env"

ARK_API_URL = "https://ark.cn-beijing.volces.com/api/v3/images/generations"
DEFAULT_MODEL = "doubao-seedream-5-0-lite-260128"
DEFAULT_SIZE = "4K"
DEFAULT_WATERMARK = False
DEFAULT_PORT = 8787
API_TIMEOUT = 180  # 调用 Ark API 超时(秒)
DOWNLOAD_TIMEOUT = 60  # 下载图片超时(秒)

# Windows 环境常缺 CA 根证书, 跳过 SSL 验证
# SSL: 优先 certifi, 否则跳过验证
try:
    import certifi as _certifi_mod
    _certifi_ca = _certifi_mod.where()
    SSL_CTX = ssl.create_default_context(cafile=_certifi_ca)
    print(f"[CFG] SSL: certifi OK ({_certifi_ca})", flush=True)
except ImportError:
    SSL_CTX = ssl._create_unverified_context()
    print("[CFG] SSL: certifi 未安装, 跳过证书验证, 建议: pip install certifi", flush=True)

# 启动时由 main() 填充
API_KEY: str | None = None


# ---- 工具函数 -------------------------------------------------------------

def log(msg: str) -> None:
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def load_api_key() -> str | None:
    """优先环境变量 ARK_API_KEY, 其次同目录 .env 文件"""
    key = os.environ.get("ARK_API_KEY")
    if key and key.strip():
        return key.strip()
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() == "ARK_API_KEY":
                v = v.strip().strip('"').strip("'")
                if v:
                    return v
    return None


def call_volc_api(payload: dict, api_key: str) -> dict:
    """调用火山引擎 Ark 文生图 API, 返回解析后的 JSON 字典"""
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        ARK_API_URL,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=API_TIMEOUT, context=SSL_CTX) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Ark API HTTP {e.code}: {err_body}") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"Ark API 网络错误: {e.reason}") from None


def download_image(url: str, dest: Path) -> None:
    """下载图片到本地"""
    req = urllib.request.Request(url, headers={"User-Agent": "volc-image-gen/1.0"})
    with urllib.request.urlopen(req, timeout=DOWNLOAD_TIMEOUT, context=SSL_CTX) as resp:
        dest.write_bytes(resp.read())


def safe_filename(name: str) -> str:
    """清理文件名中的非法字符"""
    for ch in '<>:"/\\|?*':
        name = name.replace(ch, "_")
    name = name.strip().strip(".")
    return name or "image"


# ---- 历史记录 -------------------------------------------------------------

def init_history_db():
    """启动时确保历史目录和表存在"""
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(HISTORY_DB)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            created TEXT NOT NULL,
            prompt TEXT NOT NULL,
            model TEXT,
            size TEXT,
            ref_count INTEGER DEFAULT 0,
            out_path TEXT,
            volc_url TEXT,
            elapsed REAL,
            folder TEXT,
            output_name TEXT
        )
    """)
    conn.commit()
    conn.close()


def save_history(ts, created, prompt, model, size, ref_count, out_path, volc_url, elapsed, folder, output_name=None):
    conn = sqlite3.connect(HISTORY_DB)
    conn.execute(
        "INSERT INTO records (ts, created, prompt, model, size, ref_count, out_path, volc_url, elapsed, folder, output_name) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (ts, created, prompt, model, size, ref_count, str(out_path), volc_url, elapsed, str(folder), output_name),
    )
    conn.commit()
    conn.close()


def decode_data_url(data_url) -> bytes | None:
    """解码 data:image/xxx;base64,... 返回二进制; 非 data URL 返回 None"""
    if not isinstance(data_url, str) or not data_url.startswith("data:"):
        return None
    try:
        _, b64 = data_url.split(",", 1)
        return base64.b64decode(b64)
    except Exception:
        return None


# ---- 核心逻辑 -------------------------------------------------------------

def handle_generate(body: dict, api_key: str) -> dict:
    prompt = body.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return {"ok": False, "error": "字段 prompt 必填且为非空字符串"}

    payload = {
        "model": body.get("model", DEFAULT_MODEL),
        "prompt": prompt,
        "response_format": "url",
        "size": body.get("size", DEFAULT_SIZE),
        "stream": False,
        "watermark": False,
    }

    image = body.get("image")
    if image:
        payload["image"] = image if isinstance(image, list) else [image]

    t0 = time.time()
    log(f"请求生成: model={payload['model']} size={payload['size']}")
    log(f"  prompt: {prompt[:80]}{'...' if len(prompt) > 80 else ''}")

    result = call_volc_api(payload, api_key)

    images = result.get("data", [])
    if not images:
        return {"ok": False, "error": "Ark API 未返回图片数据", "raw": result}

    image_url = images[0].get("url")
    if not image_url:
        return {"ok": False, "error": "Ark API 返回数据中无 url 字段", "raw": result}

    # 时间戳作为本次记录的目录名
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    folder = HISTORY_DIR / ts
    folder.mkdir(parents=True, exist_ok=True)

    # 下载生成图到子目录
    out_path = folder / "out.png"
    download_image(image_url, out_path)

    # 保存参考图副本 (base64 解码落盘; URL 仅 meta 记录)
    ref_list = image if isinstance(image, list) else ([image] if image else [])
    ref_count = 0
    for i, ref in enumerate(ref_list, 1):
        data = decode_data_url(ref)
        if data:
            (folder / f"ref_{i}.png").write_bytes(data)
            ref_count += 1

    # 写 meta.json (含完整参数, 断网也能追溯)
    created = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    meta = {
        "ts": ts,
        "created": created,
        "prompt": prompt,
        "model": payload["model"],
        "size": payload["size"],
        "volc_url": image_url,
        "ref_count": ref_count,
        "ref_sources": ref_list,
        "output_name": body.get("output_name"),
    }
    (folder / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    # 插入 SQLite 索引
    elapsed = round(time.time() - t0, 2)
    save_history(
        ts=ts, created=created, prompt=prompt, model=payload["model"],
        size=payload["size"], ref_count=ref_count, out_path=out_path,
        volc_url=image_url, elapsed=elapsed, folder=folder,
        output_name=body.get("output_name"),
    )
    log(f"生成完成: {ts}/out.png ({elapsed}s, 参考图{ref_count}张)")

    return {
        "ok": True,
        "file": f"_raw/history/{ts}/out.png",
        "name": ts,
        "created": created,
        "path": str(out_path),
        "url": image_url,
        "preview": f"/img?name={ts}",
        "elapsed": elapsed,
    }


# ---- HTTP 服务 ------------------------------------------------------------

INDEX_HTML = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>豆包文生图 · 本地代理</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Microsoft YaHei", "Segoe UI", sans-serif; background: #ffffff; color: #1a1a1a; line-height: 1.5; overflow: hidden; }
  .topbar { padding: 10px 18px; border-bottom: 1px solid #eee; display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .topbar h1 { font-size: 15px; font-weight: 600; margin-right: 4px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #ccc; display: inline-block; }
  .dot.on { background: #34a853; }
  .dot.off { background: #ea4335; }
  .app { display: flex; height: calc(100vh - 41px); }
  .left { width: 46%; display: flex; flex-direction: column; border-right: 1px solid #eee; }
  .right { flex: 1; overflow-y: auto; padding: 18px; background: #fafafa; }
  .history { flex: 1; overflow-y: auto; padding: 8px; }
  .hist-item { padding: 10px 12px; border-radius: 6px; cursor: pointer; margin-bottom: 4px; border: 1px solid transparent; }
  .hist-item:hover { background: #f5f8ff; }
  .hist-item.active { background: #eef4ff; border-color: #cfe0ff; }
  .hist-meta { font-size: 11px; color: #888; margin-bottom: 3px; display: flex; gap: 6px; flex-wrap: wrap; }
  .hist-tag { background: #f0f0f0; padding: 1px 6px; border-radius: 3px; }
  .hist-prompt { font-size: 13px; color: #333; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .composer { border-top: 1px solid #eee; padding: 12px; background: #fff; }
  .field { margin-bottom: 10px; }
  label { display: block; font-size: 11px; color: #666; margin-bottom: 4px; }
  textarea, input[type=text], select { width: 100%; padding: 7px 10px; border: 1px solid #ddd; border-radius: 5px; font-size: 13px; font-family: inherit; background: #fff; color: #1a1a1a; }
  textarea { min-height: 56px; resize: vertical; }
  textarea:focus, input:focus, select:focus { outline: none; border-color: #4a90d9; }
  .row { display: flex; gap: 10px; }
  .row .field { flex: 1; }
  button { background: #1a1a1a; color: #fff; border: none; padding: 8px 22px; border-radius: 5px; font-size: 13px; cursor: pointer; font-family: inherit; }
  button:disabled { background: #999; cursor: not-allowed; }
  .ref-thumbs { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 6px; }
  .ref-thumbs img { width: 56px; height: 56px; object-fit: cover; border-radius: 4px; border: 1px solid #eee; }
  .detail-empty { color: #aaa; text-align: center; padding: 60px 20px; font-size: 13px; }
  .detail-section { margin-bottom: 18px; }
  .detail-section h3 { font-size: 13px; color: #555; margin-bottom: 8px; font-weight: 600; }
  .detail-section img.main { max-width: 100%; border-radius: 6px; display: block; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
  .detail-refs { display: flex; gap: 8px; flex-wrap: wrap; }
  .detail-refs img { width: 100px; height: 100px; object-fit: cover; border-radius: 4px; border: 1px solid #eee; cursor: pointer; }
  .detail-info { font-size: 12px; color: #555; background: #fff; padding: 10px 12px; border-radius: 6px; border: 1px solid #eee; }
  .detail-info code { font-family: ui-monospace, Consolas, monospace; background: #f5f5f5; padding: 6px; border-radius: 3px; display: block; white-space: pre-wrap; margin-top: 4px; }
  .toast { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%); background: #1a1a1a; color: #fff; padding: 8px 18px; border-radius: 6px; font-size: 13px; display: none; z-index: 99; }
  .toast.err { background: #c33; }
</style>
</head>
<body>
<div class="topbar">
  <h1>豆包文生图</h1>
  <span id="dot" class="dot"></span>
  <span id="status">检查状态中...</span>
  <span style="color:#bbb;">· 本地代理</span>
</div>
<div class="app">
  <div class="left">
    <div class="history" id="history"><div class="detail-empty">加载历史中...</div></div>
    <div class="composer">
      <div class="field">
        <label>提示词 prompt</label>
        <textarea id="prompt" placeholder="描述你想生成的图片，例如：像素风勇者立绘，正面，持剑，纯色背景"></textarea>
      </div>
      <div class="row">
        <div class="field">
          <label>模型</label>
          <select id="model">
            <option value="doubao-seedream-5-0-lite-260128" selected>5.0 Lite</option>
            <option value="doubao-seedream-5-0-pro-260628">5.0 Pro</option>
          </select>
        </div>
        <div class="field">
          <label>尺寸</label>
          <select id="size">
            <option value="4K" selected>4K (4096x4096)</option>
            <option value="3K">3K (3072x3072)</option>
            <option value="2K">2K (2048x2048)</option>
            <option value="4096x4096">4096x4096</option>
            <option value="5504x3040">5504x3040 (16:9)</option>
            <option value="3040x5504">3040x5504 (9:16)</option>
            <option value="3072x3072">3072x3072</option>
            <option value="2048x2048">2048x2048</option>
            <option value="__custom__">自定义...</option>
          </select>
          <input type="text" id="size_custom" placeholder="宽x高" style="display:none; margin-top:4px;">
        </div>
      </div>
      <div class="field">
        <label>参考图 (可选, 多选)</label>
        <input type="file" id="ref_image" accept="image/png,image/jpeg,image/webp" multiple onchange="previewRef()">
        <div id="ref_previews" class="ref-thumbs"></div>
      </div>
      <button id="btn" onclick="generate()">生成</button>
    </div>
  </div>
  <div class="right" id="detail">
    <div class="detail-empty">点击左侧历史记录查看图片，或生成新图后自动展示</div>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
  fetch('/health').then(r => r.json()).then(j => {
    const dot = document.getElementById('dot');
    const st = document.getElementById('status');
    if (j.api_key_loaded) { dot.className = 'dot on'; st.textContent = 'API Key 已加载'; }
    else { dot.className = 'dot off'; st.textContent = '未配置 ARK_API_KEY'; }
  });

  let refImages = [];
  function previewRef() {
    const files = [...document.getElementById('ref_image').files];
    refImages = [];
    const c = document.getElementById('ref_previews');
    c.innerHTML = '';
    files.forEach(f => {
      const reader = new FileReader();
      reader.onload = () => {
        refImages.push(reader.result);
        const img = document.createElement('img');
        img.src = reader.result;
        img.title = f.name;
        c.appendChild(img);
      };
      reader.readAsDataURL(f);
    });
  }

  const sizeSelect = document.getElementById('size');
  const sizeInput = document.getElementById('size_custom');
  sizeSelect.addEventListener('change', function() {
    sizeInput.style.display = this.value === '__custom__' ? 'block' : 'none';
  });

  function toast(msg, isErr) {
    const t = document.getElementById('toast');
    t.textContent = msg;
    t.className = 'toast' + (isErr ? ' err' : '');
    t.style.display = 'block';
    setTimeout(() => { t.style.display = 'none'; }, 2500);
  }

  function escapeHtml(s) {
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  async function loadHistory(selectTs) {
    const r = await fetch('/history');
    const j = await r.json();
    const box = document.getElementById('history');
    if (!j.items || !j.items.length) {
      box.innerHTML = '<div class="detail-empty">还没有历史记录，先生成一张吧</div>';
      return;
    }
    box.innerHTML = '';
    j.items.forEach(it => {
      const div = document.createElement('div');
      div.className = 'hist-item' + (it.ts === selectTs ? ' active' : '');
      const modelName = it.model.indexOf('lite') >= 0 ? 'Lite' : 'Pro';
      const time = (it.created || '').slice(11);
      div.innerHTML = '<div class="hist-meta"><span>' + time + '</span>' +
        '<span class="hist-tag">' + modelName + '</span>' +
        '<span class="hist-tag">' + it.size + '</span>' +
        (it.ref_count ? '<span class="hist-tag">参考' + it.ref_count + '</span>' : '') +
        '<span class="hist-tag">' + it.elapsed + 's</span></div>' +
        '<div class="hist-prompt"></div>';
      div.querySelector('.hist-prompt').textContent = it.prompt;
      div.onclick = () => {
        document.querySelectorAll('.hist-item').forEach(el => el.classList.remove('active'));
        div.classList.add('active');
        showDetail(it);
      };
      box.appendChild(div);
    });
  }

  function showDetail(it) {
    const d = document.getElementById('detail');
    const modelName = it.model.indexOf('lite') >= 0 ? '5.0 Lite' : '5.0 Pro';
    let html = '<div class="detail-section"><h3>生成结果</h3>' +
      '<img class="main" src="/img?name=' + it.ts + '" alt="生成结果"></div>';
    if (it.ref_count) {
      html += '<div class="detail-section"><h3>参考图 (' + it.ref_count + ')</h3><div class="detail-refs">';
      for (let i = 1; i <= it.ref_count; i++) {
        html += '<img src="/img?name=' + it.ts + '&ref=' + i + '" alt="参考图' + i + '">';
      }
      html += '</div></div>';
    }
    html += '<div class="detail-section"><h3>详情</h3><div class="detail-info">' +
      '<div>时间: ' + escapeHtml(it.created) + '</div>' +
      '<div>模型: ' + modelName + ' · 尺寸: ' + escapeHtml(it.size) + '</div>' +
      '<div>耗时: ' + it.elapsed + 's</div>' +
      '<div style="margin-top:6px;">提示词:<code>' + escapeHtml(it.prompt) + '</code></div>' +
      '</div></div>';
    d.innerHTML = html;
  }

  async function generate() {
    const prompt = document.getElementById('prompt').value.trim();
    if (!prompt) { toast('请输入提示词', true); return; }
    const refCount = refImages.length;
    const body = {
      prompt,
      model: document.getElementById('model').value,
      size: sizeSelect.value === '__custom__' ? sizeInput.value : sizeSelect.value,
    };
    if (refImages.length) body.image = refImages;
    const btn = document.getElementById('btn');
    btn.disabled = true; btn.textContent = '生成中...';
    toast('正在请求火山引擎...');
    try {
      const r = await fetch('/generate', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) });
      const j = await r.json();
      if (j.ok) {
        toast('生成成功 · ' + j.elapsed + 's');
        document.getElementById('prompt').value = '';
        refImages = [];
        document.getElementById('ref_image').value = '';
        document.getElementById('ref_previews').innerHTML = '';
        await loadHistory(j.name);
        showDetail({ ts: j.name, created: j.created || '', prompt: prompt, model: body.model, size: body.size, ref_count: refCount, elapsed: j.elapsed });
      } else {
        toast(j.error || '生成失败', true);
      }
    } catch (e) {
      toast('请求失败: ' + e.message, true);
    } finally {
      btn.disabled = false; btn.textContent = '生成';
    }
  }

  loadHistory();
</script>
</body>
</html>'''


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            html = INDEX_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
        elif path == "/health":
            self._json(200, {"ok": True, "api_key_loaded": API_KEY is not None})
        elif path == "/history":
            self._serve_history()
        elif path == "/img":
            self._serve_image()
        else:
            self._json(404, {"ok": False, "error": f"未知路径: {self.path}"})

    def _serve_history(self):
        """返回历史记录列表, 按时间倒序"""
        conn = sqlite3.connect(HISTORY_DB)
        rows = conn.execute(
            "SELECT ts, created, prompt, model, size, ref_count, elapsed, output_name "
            "FROM records ORDER BY id DESC LIMIT 200"
        ).fetchall()
        conn.close()
        items = [{
            "ts": r[0], "created": r[1], "prompt": r[2],
            "model": r[3], "size": r[4], "ref_count": r[5],
            "elapsed": r[6], "output_name": r[7],
        } for r in rows]
        self._json(200, {"ok": True, "items": items})

    def _serve_image(self):
        """读取本地图片返回. ?name=ts 返回生成图; ?name=ts&ref=N 返回第N张参考图"""
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        name = qs.get("name", [""])[0].strip()
        if not name:
            self._json(400, {"ok": False, "error": "缺少 name 参数"})
            return
        safe = safe_filename(name)  # 已把 /\ 等替换为 _, 防路径穿越
        ref = qs.get("ref", [""])[0].strip()
        if ref:
            candidate = HISTORY_DIR / safe / f"ref_{safe_filename(ref)}.png"
        else:
            candidate = HISTORY_DIR / safe / "out.png"
            if not candidate.exists():
                candidate = OUTPUT_DIR / safe  # 回退: 旧版本直接放 _raw 根的图
        ext = candidate.suffix.lower()
        if not candidate.exists() or ext not in (".png", ".jpg", ".jpeg", ".webp"):
            self._json(404, {"ok": False, "error": f"图片不存在: {safe}"})
            return
        data = candidate.read_bytes()
        ctype = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}[ext]
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/generate":
            self._json(404, {"ok": False, "error": f"未知路径: {self.path}"})
            return
        if API_KEY is None:
            self._json(500, {"ok": False, "error": "未配置 ARK_API_KEY, 无法调用"})
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError as e:
            self._json(400, {"ok": False, "error": f"JSON 解析失败: {e}"})
            return
        if not isinstance(body, dict):
            self._json(400, {"ok": False, "error": "请求体必须是 JSON 对象"})
            return

        try:
            result = handle_generate(body, API_KEY)
            code = 200 if result.get("ok") else 400
            self._json(code, result)
        except Exception as e:
            log(f"处理异常: {e}")
            self._json(500, {"ok": False, "error": str(e)})

    def _json(self, code: int, payload: dict):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # 用自定义 log() 替代默认日志
        pass


# ---- 入口 -----------------------------------------------------------------

def main():
    global API_KEY
    parser = argparse.ArgumentParser(description="火山引擎豆包文生图本地代理服务")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"监听端口, 默认 {DEFAULT_PORT}")
    args = parser.parse_args()

    API_KEY = load_api_key()
    if API_KEY is None:
        log("[WARN] 未检测到 ARK_API_KEY")
        log(f"  请设置环境变量 ARK_API_KEY, 或在 {ENV_FILE} 写入 ARK_API_KEY=xxx")
        log("  服务仍会启动, 但 /generate 调用将返回错误")
    else:
        log(f"[OK] API Key 已加载 (前4位: {API_KEY[:4]}...)")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    init_history_db()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    log(f"服务已启动: http://127.0.0.1:{args.port}")
    log(f"输出目录: {OUTPUT_DIR}")
    log(f"历史记录: {HISTORY_DIR} (history.db)")
    log("接口: POST /generate  |  GET /health")
    log("Ctrl+C 退出")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("正在关闭...")
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
