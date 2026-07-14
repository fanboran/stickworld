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
import json
import os
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
ENV_FILE = SCRIPT_DIR / ".env"

ARK_API_URL = "https://ark.cn-beijing.volces.com/api/v3/images/generations"
DEFAULT_MODEL = "doubao-seedream-5-0-pro-260628"
DEFAULT_SIZE = "2K"
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
        payload["image"] = [image]

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

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    output_name = body.get("output_name")
    if output_name:
        base = safe_filename(str(output_name))
        dest = OUTPUT_DIR / f"{base}.png"
        if dest.exists():
            ts = datetime.now().strftime("%H%M%S")
            dest = OUTPUT_DIR / f"{base}_{ts}.png"
    else:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        dest = OUTPUT_DIR / f"{ts}.png"

    download_image(image_url, dest)
    elapsed = round(time.time() - t0, 2)
    log(f"生成完成: {dest.name} ({elapsed}s)")

    return {
        "ok": True,
        "file": f"_raw/{dest.name}",
        "name": dest.name,
        "path": str(dest),
        "url": image_url,
        "preview": f"/img?name={dest.name}",
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
  body { font-family: -apple-system, BlinkMacSystemFont, "Microsoft YaHei", "Segoe UI", sans-serif; background: #ffffff; color: #1a1a1a; padding: 28px 24px; line-height: 1.6; }
  .wrap { max-width: 760px; margin: 0 auto; }
  h1 { font-size: 19px; font-weight: 600; }
  .sub { color: #888; font-size: 12px; margin: 4px 0 22px; display: flex; align-items: center; gap: 6px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #ccc; display: inline-block; }
  .dot.on { background: #34a853; }
  .dot.off { background: #ea4335; }
  .field { margin-bottom: 14px; }
  label { display: block; font-size: 12px; color: #555; margin-bottom: 5px; }
  textarea, input[type=text], select { width: 100%; padding: 9px 11px; border: 1px solid #ddd; border-radius: 6px; font-size: 14px; font-family: inherit; background: #fff; color: #1a1a1a; }
  textarea { min-height: 88px; resize: vertical; }
  textarea:focus, input:focus, select:focus { outline: none; border-color: #4a90d9; }
  .row { display: flex; gap: 12px; }
  .row .field { flex: 1; }
  .check { display: flex; align-items: center; gap: 8px; }
  .check label { margin: 0; }
  button { background: #1a1a1a; color: #fff; border: none; padding: 9px 26px; border-radius: 6px; font-size: 14px; cursor: pointer; font-family: inherit; }
  button:disabled { background: #999; cursor: not-allowed; }
  .result { margin-top: 22px; }
  .result .card { border: 1px solid #eee; border-radius: 6px; padding: 14px; }
  .result.error .card { border-color: #f0c0c0; background: #fdf6f6; color: #c33; }
  .result img { max-width: 100%; border-radius: 6px; display: block; margin-top: 10px; }
  .meta { font-size: 12px; color: #888; margin-top: 10px; word-break: break-all; }
  .path { font-family: ui-monospace, Consolas, monospace; background: #f5f5f5; padding: 2px 6px; border-radius: 3px; font-size: 12px; }
  .placeholder { color: #aaa; font-size: 13px; padding: 24px; text-align: center; border: 1px dashed #eee; border-radius: 6px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>豆包文生图</h1>
  <div class="sub"><span id="dot" class="dot"></span><span id="status">检查状态中...</span> · 本地代理</div>

  <div class="field">
    <label>提示词 prompt</label>
    <textarea id="prompt" placeholder="描述你想生成的图片，例如：像素风勇者立绘，正面，持剑，纯色背景"></textarea>
  </div>
  <div class="row">
    <div class="field">
      <label>尺寸 size</label>
      <select id="size">
        <option value="2K">2K</option>
        <option value="1K">1K</option>
        <option value="3K">3K</option>
        <option value="4K">4K</option>
      </select>
    </div>
    <div class="field">
      <label>输出文件名 (可选)</label>
      <input type="text" id="output_name" placeholder="留空则用时间戳">
    </div>
  </div>
  <div class="field">
    <label>参考图 image (可选)</label>
    <input type="file" id="ref_image" accept="image/png,image/jpeg,image/webp" onchange="previewRef()">
    <img id="ref_preview" style="max-width:160px; display:none; margin-top:6px; border-radius:4px;">
    <div id="ref_info" style="font-size:11px; color:#888; margin-top:4px; display:none;"></div>
  </div>
  <button id="btn" onclick="generate()">生成</button>

  <div id="result" class="result">
    <div class="placeholder">结果会显示在这里</div>
  </div>
</div>
<script>
  fetch('/health').then(r => r.json()).then(j => {
    const dot = document.getElementById('dot');
    const st = document.getElementById('status');
    if (j.api_key_loaded) { dot.className = 'dot on'; st.textContent = 'API Key 已加载'; }
    else { dot.className = 'dot off'; st.textContent = '未配置 ARK_API_KEY'; }
  }).catch(() => {
    document.getElementById('dot').className = 'dot off';
    document.getElementById('status').textContent = '服务异常';
  });

  let refBase64 = '';
  function previewRef() {
    const file = document.getElementById('ref_image').files[0];
    if (!file) return;
    document.getElementById('ref_info').style.display = 'block';
    document.getElementById('ref_info').textContent = file.name + ' (' + (file.size/1024).toFixed(1) + 'KB)';
    const reader = new FileReader();
    reader.onload = () => {
      refBase64 = reader.result;
      const preview = document.getElementById('ref_preview');
      preview.src = refBase64;
      preview.style.display = 'block';
    };
    reader.readAsDataURL(file);
  }

  async function generate() {
    const prompt = document.getElementById('prompt').value.trim();
    if (!prompt) { showResult('请输入提示词', true); return; }
    const body = {
      prompt,
      size: document.getElementById('size').value,
    };
    if (refBase64) body.image = refBase64;
    const name = document.getElementById('output_name').value.trim();
    if (name) body.output_name = name;

    const btn = document.getElementById('btn');
    btn.disabled = true; btn.textContent = '生成中...';
    showResult('正在请求火山引擎, 请稍候...', false, true);
    try {
      const r = await fetch('/generate', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) });
      const j = await r.json();
      if (j.ok) {
        showResult(
          '<div>生成成功 · 耗时 ' + j.elapsed + 's</div>' +
          '<img src="' + j.preview + '" alt="生成结果">' +
          '<div class="meta">本地文件: <span class="path">' + j.path + '</span><br>文件名: ' + j.name + '</div>',
          false
        );
      } else {
        showResult(j.error || '生成失败', true);
      }
    } catch (e) {
      showResult('请求失败: ' + e.message, true);
    } finally {
      btn.disabled = false; btn.textContent = '生成';
    }
  }
  function showResult(html, isErr, isInfo) {
    const el = document.getElementById('result');
    el.className = 'result' + (isErr ? ' error' : '');
    el.innerHTML = isInfo ? '<div class="placeholder">' + html + '</div>' : '<div class="card">' + html + '</div>';
  }
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
        elif path == "/img":
            self._serve_image()
        else:
            self._json(404, {"ok": False, "error": f"未知路径: {self.path}"})

    def _serve_image(self):
        """从 output/ 读取本地图片返回, 用于网页预览"""
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        name = qs.get("name", [""])[0].strip()
        if not name:
            self._json(400, {"ok": False, "error": "缺少 name 参数"})
            return
        safe = safe_filename(name)  # 已把 /\ 等替换为 _, 防路径穿越
        img = OUTPUT_DIR / safe
        ext = img.suffix.lower()
        if not img.exists() or ext not in (".png", ".jpg", ".jpeg", ".webp"):
            self._json(404, {"ok": False, "error": f"图片不存在: {safe}"})
            return
        data = img.read_bytes()
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
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    log(f"服务已启动: http://127.0.0.1:{args.port}")
    log(f"输出目录: {OUTPUT_DIR}")
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
