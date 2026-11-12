#!/usr/bin/env python3
"""BArch Drop: files from the iPhone to this desktop over the LAN (barch-drop.service, `barch drop`).

The iPhone sends through a Shortcut in its share sheet ("Send to BArch": Get Contents of URL, POST,
form field `file`) or through the page this serves at http://<desktop>:<port>/ (Safari, any size).
Files land in ~/Downloads/iPhone (never overwritten: name-2.ext), a text or link goes to the
clipboard; either way one notification per batch, with Open and Show in folder.

    POST /upload   Authorization: Bearer <token>
                   multipart/form-data: any number of file parts (`file`) and `text` fields,
                   or a raw body with the name in X-Filename (or ?name=)
    GET  /         the upload page (the token comes in the URL fragment, kept in localStorage)
    GET  /ping     {"ok": true}

Config: ~/.config/barch/drop.json (mode 600, made on first run): token, port, dir, allow (networks
that may connect, checked here on top of the firewall rule). What arrived: state.json in
~/.local/state/barch/drop/.

    drop.py serve | status [--json] | setup | open
"""

import hmac
import ipaddress
import json
import mimetypes
import os
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlsplit

HOME = os.path.expanduser("~")
CONFIG = os.path.join(HOME, ".config/barch/drop.json")
STATE_DIR = os.path.join(HOME, ".local/state/barch/drop")
STATE = os.path.join(STATE_DIR, "state.json")
THEME = os.path.join(HOME, ".local/state/quickshell/theme.json")
BARCH = os.path.join(HOME, ".local/bin/barch")
DEFAULTS = {"port": 8350, "dir": "~/Downloads/iPhone", "allow": ["100.100.0.0/24", "127.0.0.0/8"]}
CHUNK = 1 << 20
TEXT_MAX = 1 << 20
BATCH_S = 2.5  # files closer than this to each other are one notification


# ---------------------------------------------------------------- config and state

def load_config(create=True):
    try:
        with open(CONFIG) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        if not create:
            return None
        cfg = {}
    changed = "token" not in cfg
    cfg.setdefault("token", secrets.token_urlsafe(24))
    for k, v in DEFAULTS.items():
        cfg.setdefault(k, v)
    if changed:
        os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
        fd = os.open(CONFIG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
    return cfg


def dest_dir(cfg):
    return os.path.expanduser(cfg["dir"])


def read_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"received": []}


def record(entries):
    st = read_state()
    st["received"] = (entries + st.get("received", []))[:50]
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=1)
    os.replace(tmp, STATE)


def lan_address():
    """The address the iPhone reaches: the source address of the default route."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("100.100.0.1", 9))
        addr = s.getsockname()[0]
        s.close()
        return addr
    except OSError:
        return "127.0.0.1"


# ---------------------------------------------------------------- file names

def safe_name(name, content_type=""):
    name = unicodedata.normalize("NFC", os.path.basename((name or "").replace("\\", "/")))
    name = re.sub(r"[\x00-\x1f/]", "", name).strip().lstrip(".")
    if not name:
        ext = mimetypes.guess_extension((content_type or "").split(";")[0].strip()) or ".bin"
        name = time.strftime("iPhone-%Y%m%d-%H%M%S") + ext
    return name[:200]


def unique_path(directory, name):
    stem, ext = os.path.splitext(name)
    path, n = os.path.join(directory, name), 2
    while os.path.exists(path):
        path = os.path.join(directory, f"{stem}-{n}{ext}")
        n += 1
    return path


# ---------------------------------------------------------------- request body

class BodyReader:
    """read(n) over a request body, Content-Length or chunked."""

    def __init__(self, rfile, headers):
        self.rfile = rfile
        self.chunked = "chunked" in headers.get("Transfer-Encoding", "").lower()
        self.left = int(headers.get("Content-Length") or 0) if not self.chunked else 0
        self.done = False

    def read(self, n=CHUNK):
        if self.done:
            return b""
        if not self.chunked:
            if self.left <= 0:
                self.done = True
                return b""
            data = self.rfile.read(min(n, self.left))
            if not data:
                raise ConnectionError("body ended early")
            self.left -= len(data)
            return data
        if self.left == 0:
            size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                    pass
                self.done = True
                return b""
            self.left = size
        data = self.rfile.read(min(n, self.left))
        if not data:
            raise ConnectionError("body ended early")
        self.left -= len(data)
        if self.left == 0:
            self.rfile.readline()
        return data


def parse_disposition(value):
    params = {}
    for m in re.finditer(r';\s*([\w*]+)\s*=\s*("((?:[^"\\]|\\.)*)"|[^;]*)', value):
        key, raw, quoted = m.group(1).lower(), m.group(2), m.group(3)
        params[key] = quoted.replace('\\"', '"') if quoted is not None else raw.strip()
    if "filename*" in params:
        enc, _, rest = params["filename*"].partition("''")
        params["filename"] = unquote(rest, encoding=enc or "utf-8", errors="replace")
    return params


def multipart(body, boundary, on_file, on_text):
    """Stream a multipart body: on_file(name, ctype) returns a sink with write/close/abort,
    on_text(field, value) gets small fields."""
    delim = b"\r\n--" + boundary
    buf, eof = b"\r\n", False

    def more():
        nonlocal buf, eof
        data = body.read()
        if not data:
            eof = True
        buf += data

    while True:                                      # find the next part
        i = buf.find(delim)
        while i < 0:
            if eof:
                return
            buf = buf[-len(delim):]
            more()
            i = buf.find(delim)
        buf = buf[i + len(delim):]
        while len(buf) < 2 and not eof:
            more()
        if buf.startswith(b"--"):
            return
        while b"\r\n\r\n" not in buf:                # its headers
            if eof or len(buf) > 65536:
                raise ValueError("bad multipart headers")
            more()
        head, buf = buf.split(b"\r\n\r\n", 1)
        headers = {}
        for line in head.decode("utf-8", "replace").split("\r\n"):
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        disp = parse_disposition(headers.get("content-disposition", ""))
        if "filename" in disp:
            sink = on_file(disp["filename"], headers.get("content-type", ""))
        else:
            sink = TextSink(disp.get("name", ""), on_text)
        try:                                         # its content, up to the next delimiter
            while True:
                i = buf.find(delim)
                if i >= 0:
                    sink.write(buf[:i])
                    buf = buf[i:]
                    break
                keep = len(delim) - 1
                if len(buf) > keep:
                    sink.write(buf[:-keep])
                    buf = buf[-keep:]
                if eof:
                    raise ValueError("multipart body ended inside a part")
                more()
        except BaseException:
            sink.abort()
            raise
        sink.close()


class TextSink:
    def __init__(self, field, on_text):
        self.field, self.on_text, self.data = field, on_text, bytearray()

    def write(self, b):
        if len(self.data) + len(b) > TEXT_MAX:
            raise ValueError("text field too large")
        self.data += b

    def close(self):
        self.on_text(self.field, self.data.decode("utf-8", "replace"))

    def abort(self):
        pass


class FileSink:
    def __init__(self, directory, name, content_type, saved):
        os.makedirs(directory, exist_ok=True)
        self.directory, self.saved = directory, saved
        self.name = safe_name(name, content_type)
        self.part = os.path.join(directory, f".{self.name}.{secrets.token_hex(4)}.part")
        self.f = open(self.part, "wb")
        self.size = 0

    def write(self, b):
        self.f.write(b)
        self.size += len(b)

    def close(self):
        self.f.close()
        path = unique_path(self.directory, self.name)
        os.rename(self.part, path)
        self.saved.append({"path": path, "size": self.size})

    def abort(self):
        self.f.close()
        try:
            os.unlink(self.part)
        except OSError:
            pass


# ---------------------------------------------------------------- notifications

def run_bg(args):
    try:
        subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def notify(title, body, actions):
    args = [BARCH, "notify", title, body, "--app", "BArch Drop"]
    for label, cmd in actions:
        args += ["--action", f"{label}={cmd}"]
    try:
        if subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          timeout=10).returncode == 0:
            return
    except (OSError, subprocess.TimeoutExpired):
        pass
    run_bg(["notify-send", "-a", "BArch Drop", title, body])


def show_items_cmd(paths):
    uris = ",".join("'file://" + quote(p) + "'" for p in paths)
    return ("gdbus call --session --dest org.freedesktop.FileManager1 --object-path "
            "/org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems "
            + shlex.quote(f"[{uris}]") + " ''")


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


class Batcher:
    """Collects what arrives and notifies once the iPhone has been quiet for BATCH_S."""

    def __init__(self):
        self.lock, self.files, self.timer = threading.Lock(), [], None

    def add(self, files):
        with self.lock:
            self.files += files
            if self.timer:
                self.timer.cancel()
            self.timer = threading.Timer(BATCH_S, self.flush)
            self.timer.daemon = True
            self.timer.start()

    def flush(self):
        with self.lock:
            files, self.files, self.timer = self.files, [], None
        if not files:
            return
        paths = [f["path"] for f in files]
        total = human(sum(f["size"] for f in files))
        if len(files) == 1:
            title = "From the iPhone"
            body = f"{os.path.basename(paths[0])} ({total})"
            actions = [("Open", "xdg-open " + shlex.quote(paths[0]))]
        else:
            title = f"{len(files)} files from the iPhone"
            names = ", ".join(os.path.basename(p) for p in paths[:4])
            body = f"{names}{', …' if len(files) > 4 else ''} ({total})"
            actions = []
        actions.append(("Show in folder", show_items_cmd(paths)))
        notify(title, body, actions)


def got_text(text):
    text = text.strip()
    if not text:
        return
    try:
        subprocess.run(["wl-copy", "--", text], timeout=5, check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        pass
    actions = []
    if re.match(r"^https?://\S+$", text):
        actions.append(("Open", "xdg-open " + shlex.quote(text)))
    preview = text if len(text) <= 160 else text[:157] + "…"
    notify("Copied from the iPhone", preview, actions)
    record([{"time": int(time.time()), "text": text[:300]}])


# ---------------------------------------------------------------- the server

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "BArchDrop"
    cfg, nets, batcher = {}, [], None

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))

    def allowed(self):
        try:
            ip = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            return False
        if ip.version == 6 and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        return any(ip in n for n in self.nets)

    def reply(self, code, obj=None, body=None, ctype="application/json"):
        data = body if body is not None else (json.dumps(obj) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.allowed():
            return self.reply(403, {"ok": False, "error": "not from the local network"})
        path = urlsplit(self.path).path
        if path == "/ping":
            return self.reply(200, {"ok": True})
        if path in ("/", "/index.html"):
            return self.reply(200, body=page().encode(), ctype="text/html; charset=utf-8")
        if path == "/icon.svg":
            return self.reply(200, body=icon().encode(), ctype="image/svg+xml")
        self.reply(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if not self.allowed():
            self.close_connection = True
            return self.reply(403, {"ok": False, "error": "not from the local network"})
        url = urlsplit(self.path)
        if url.path != "/upload":
            self.close_connection = True
            return self.reply(404, {"ok": False, "error": "not found"})
        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.lower().startswith("bearer ") else self.headers.get("X-Token", "")
        if not hmac.compare_digest(token.encode(), self.cfg["token"].encode()):
            self.close_connection = True
            return self.reply(401, {"ok": False, "error": "wrong token"})

        directory, saved, texts = dest_dir(self.cfg), [], []
        body = BodyReader(self.rfile, self.headers)
        ctype = self.headers.get("Content-Type", "")
        try:
            m = re.search(r'boundary="?([^";]+)"?', ctype)
            if ctype.lower().startswith("multipart/form-data") and m:
                multipart(body, m.group(1).encode(),
                          lambda name, ct: FileSink(directory, name, ct, saved),
                          lambda field, value: texts.append(value))
            else:
                name = self.headers.get("X-Filename") or parse_qs(url.query).get("name", [""])[0]
                if ctype.lower().startswith("text/plain") and not name:
                    sink = TextSink("text", lambda f, v: texts.append(v))
                else:
                    sink = FileSink(directory, unquote(name), ctype, saved)
                try:
                    while chunk := body.read():
                        sink.write(chunk)
                except BaseException:
                    sink.abort()
                    raise
                sink.close()
            while body.read():                       # drain whatever follows the last part
                pass
        except (ValueError, ConnectionError, OSError) as e:
            self.close_connection = True
            if saved:
                self.batcher.add(saved)
            try:
                return self.reply(400, {"ok": False, "error": str(e)})
            except OSError:
                return

        if saved:
            now = int(time.time())
            record([{"time": now, "path": f["path"], "size": f["size"]} for f in saved])
            self.batcher.add(saved)
        for t in texts:
            got_text(t)
        self.reply(200, {"ok": True, "saved": [os.path.basename(f["path"]) for f in saved],
                         "text": len(texts)})


def serve():
    cfg = load_config()
    Handler.cfg = cfg
    Handler.nets = [ipaddress.ip_network(n, strict=False) for n in cfg["allow"]]
    Handler.batcher = Batcher()
    os.makedirs(dest_dir(cfg), exist_ok=True)
    for name in os.listdir(dest_dir(cfg)):         # leftovers of a transfer cut by a restart
        if name.startswith(".") and name.endswith(".part"):
            try:
                os.unlink(os.path.join(dest_dir(cfg), name))
            except OSError:
                pass
    httpd = ThreadingHTTPServer(("0.0.0.0", int(cfg["port"])), Handler)
    httpd.daemon_threads = True
    print(f"barch-drop: listening on :{cfg['port']}, saving to {dest_dir(cfg)}", flush=True)
    httpd.serve_forever()


# ---------------------------------------------------------------- the page

def theme_colors():
    colors = {"crust": "#191a21", "base": "#282a36", "surface": "#44475a", "subtext": "#8b94c3",
              "text": "#f8f8f2", "accent": "#bd93f9", "green": "#50fa7b", "red": "#ff5555"}
    try:
        with open(THEME) as f:
            colors.update(json.load(f).get("colors", {}))
    except (OSError, ValueError):
        pass
    return {k: v for k, v in colors.items() if re.fullmatch(r"#[0-9a-fA-F]{6,8}", str(v))}


def icon():
    c = theme_colors()
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 180 180">'
            f'<rect width="180" height="180" fill="{c["base"]}"/>'
            f'<path d="M90 40v72M58 82l32 32 32-32M50 138h80" fill="none" stroke="{c["accent"]}" '
            f'stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/></svg>')


def page():
    c = theme_colors()
    css_vars = "".join(f"--{k}:{v};" for k, v in c.items())
    return PAGE.replace("/*VARS*/", css_vars)


PAGE = r"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="BArch Drop">
<link rel="apple-touch-icon" href="/icon.svg">
<title>BArch Drop</title>
<style>
:root{/*VARS*/color-scheme:dark light}
*{box-sizing:border-box}
body{margin:0;background:var(--base);color:var(--text);font:16px -apple-system,system-ui,sans-serif;
  padding:calc(env(safe-area-inset-top) + 24px) 18px calc(env(safe-area-inset-bottom) + 24px)}
main{max-width:520px;margin:0 auto}
h1{font-size:22px;margin:0 0 4px}
.sub{color:var(--subtext);margin:0 0 22px;font-size:14px}
.pick{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px;
  border:2px dashed var(--surface);border-radius:18px;padding:38px 16px;background:var(--crust);
  font-weight:600;font-size:18px;cursor:pointer;text-align:center}
.pick span{color:var(--subtext);font-weight:400;font-size:14px}
.pick.drag{border-color:var(--accent)}
input[type=file]{display:none}
textarea{width:100%;margin-top:14px;min-height:64px;border-radius:12px;border:1px solid var(--surface);
  background:var(--crust);color:var(--text);padding:10px;font:inherit}
button{font:inherit;font-weight:600;border:0;border-radius:12px;padding:12px 16px;
  background:var(--accent);color:var(--crust);margin-top:10px;width:100%}
button.ghost{background:var(--surface);color:var(--text)}
ul{list-style:none;padding:0;margin:18px 0 0}
li{background:var(--crust);border-radius:12px;padding:10px 12px;margin-bottom:8px;font-size:14px}
li .row{display:flex;justify-content:space-between;gap:8px}
li .name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
li .st{color:var(--subtext);flex:none}
li.ok .st{color:var(--green)} li.err .st{color:var(--red)}
.bar{height:4px;border-radius:2px;background:var(--surface);margin-top:8px;overflow:hidden}
.bar i{display:block;height:100%;width:0;background:var(--accent)}
details{margin-top:28px;color:var(--subtext);font-size:14px}
summary{cursor:pointer}
code,.field{font:13px ui-monospace,monospace}
.field{display:block;width:100%;margin:6px 0 4px;padding:8px;border-radius:8px;border:1px solid var(--surface);
  background:var(--crust);color:var(--text)}
.warn{background:var(--crust);border-left:3px solid var(--red);padding:10px 12px;border-radius:8px;margin-bottom:16px}
</style></head><body><main>
<h1>BArch Drop</h1>
<p class="sub">Photos, videos and files go straight to the desktop's <code>~/Downloads/iPhone</code>.</p>
<div id="notoken" class="warn" hidden>No token on this page yet. Open it from the link or QR code that
<code>barch drop setup</code> shows on the desktop.</div>
<label class="pick" id="pick">Choose files<span>or photos and videos from the library</span>
  <input type="file" id="files" multiple></label>
<textarea id="text" placeholder="…or a text or link for the desktop's clipboard"></textarea>
<button id="send-text" class="ghost">Send text</button>
<ul id="list"></ul>
<details><summary>For the share sheet Shortcut</summary>
<p>URL</p><input class="field" id="u" readonly>
<p>Header <code>Authorization</code></p><input class="field" id="a" readonly>
<button class="ghost" id="copy-u">Copy URL</button>
<button class="ghost" id="copy-a">Copy header value</button>
</details>
</main>
<script>
const KEY = "barch-drop-token";
let token = "";
try {
  const h = new URLSearchParams(location.hash.slice(1)).get("token");
  if (h) localStorage.setItem(KEY, h);
  token = localStorage.getItem(KEY) || "";
  // keep the token in the address: Add to Home Screen saves this URL, and the home screen app
  // has its own storage, apart from Safari's
  if (token && !h) history.replaceState(null, "", location.pathname + "#token=" + encodeURIComponent(token));
} catch (e) {}
const $ = id => document.getElementById(id);
$("notoken").hidden = !!token;
$("u").value = location.origin + "/upload";
$("a").value = "Bearer " + token;
function copy(el) { el.select(); el.setSelectionRange(0, 9999); try { document.execCommand("copy"); } catch (e) {} }
$("copy-u").onclick = () => copy($("u"));
$("copy-a").onclick = () => copy($("a"));
function size(n) { const u = ["B","KB","MB","GB"]; let i = 0; while (n >= 1024 && i < 3) { n /= 1024; i++; } return (i ? n.toFixed(1) : n) + " " + u[i]; }
function item(name) {
  const li = document.createElement("li");
  li.innerHTML = '<div class="row"><span class="name"></span><span class="st">waiting</span></div><div class="bar"><i></i></div>';
  li.querySelector(".name").textContent = name;
  $("list").prepend(li);
  return li;
}
function send(form, li) {
  return new Promise(done => {
    const x = new XMLHttpRequest();
    x.open("POST", "/upload");
    x.setRequestHeader("Authorization", "Bearer " + token);
    x.upload.onprogress = e => { if (e.lengthComputable) {
      li.querySelector("i").style.width = (100 * e.loaded / e.total) + "%";
      li.querySelector(".st").textContent = Math.round(100 * e.loaded / e.total) + "%"; } };
    x.onload = () => { const ok = x.status === 200; li.className = ok ? "ok" : "err";
      li.querySelector("i").style.width = "100%";
      let msg = "sent"; if (!ok) { try { msg = JSON.parse(x.responseText).error; } catch (e) { msg = "error " + x.status; } }
      li.querySelector(".st").textContent = msg; done(); };
    x.onerror = () => { li.className = "err"; li.querySelector(".st").textContent = "network error"; done(); };
    x.send(form);
  });
}
async function sendFiles(files) {
  const queue = [...files].map(f => [f, item(f.name + " · " + size(f.size))]);
  for (const [f, li] of queue) { const form = new FormData(); form.append("file", f, f.name); await send(form, li); }
}
$("files").onchange = e => { sendFiles(e.target.files); e.target.value = ""; };
const pick = $("pick");
pick.ondragover = e => { e.preventDefault(); pick.classList.add("drag"); };
pick.ondragleave = () => pick.classList.remove("drag");
pick.ondrop = e => { e.preventDefault(); pick.classList.remove("drag"); sendFiles(e.dataTransfer.files); };
$("send-text").onclick = () => { const t = $("text").value.trim(); if (!t) return;
  const form = new FormData(); form.append("text", t);
  send(form, item(t.length > 40 ? t.slice(0, 40) + "…" : t)).then(() => { $("text").value = ""; }); };
</script></body></html>
"""


# ---------------------------------------------------------------- CLI

def service_active():
    try:
        return subprocess.run(["systemctl", "--user", "is-active", "--quiet", "barch-drop.service"]).returncode == 0
    except OSError:
        return False


def status(as_json):
    cfg = load_config(create=False)
    st = read_state()
    url = f"http://{lan_address()}:{cfg['port'] if cfg else DEFAULTS['port']}"
    out = {"ok": True, "running": service_active(), "configured": cfg is not None, "url": url,
           "dir": dest_dir(cfg) if cfg else os.path.expanduser(DEFAULTS["dir"]),
           "received": st.get("received", [])[:10]}
    if as_json:
        print(json.dumps(out, indent=2))
        return 0
    print(f"service: {'running' if out['running'] else 'stopped'} · {url} · saving to {out['dir']}")
    if not out["configured"]:
        print("not configured yet: barch drop setup")
    for r in out["received"]:
        when = time.strftime("%d/%m %H:%M", time.localtime(r["time"]))
        what = os.path.basename(r["path"]) + f" ({human(r['size'])})" if "path" in r else "text: " + r["text"][:60]
        print(f"  {when}  {what}")
    return 0


def setup():
    cfg = load_config()
    base = f"http://{lan_address()}:{cfg['port']}"
    link = f"{base}/#token={cfg['token']}"
    print(f"""BArch Drop ({'running' if service_active() else 'NOT running: systemctl --user enable --now barch-drop'})

1. On the iPhone, open this link in Safari (scan the code with the camera). The page sends files
   by itself (any size, with progress) and Share -> Add to Home Screen makes it an app:

   {link}
""")
    if shutil.which("qrencode"):
        subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "2", link])
    print(f"""
2. The share sheet Shortcut (Shortcuts app -> + ), named "Send to BArch":
   - action "Repeat with Each" -> item in: Shortcut Input
   - inside it, "Get Contents of URL":
       URL      {base}/upload
       Method   POST
       Headers  Authorization = Bearer {cfg['token']}
       Request Body: Form -> Add new field -> File: key  file   value  Repeat Item
   - Shortcut details (i): Show in Share Sheet on; receives Images, Media, Files, PDFs
   The page's "For the share sheet Shortcut" section has the URL and header to copy.

3. Optional, for links and text: a second Shortcut "Copy to BArch", receiving URLs, Text and
   Safari web pages, with one "Get Contents of URL" as above but a Text field:  text = Shortcut Input.

The first run asks for Local Network access: allow it. Files go to {dest_dir(cfg)}.""")
    return 0


def main(argv):
    cmd = argv[0] if argv else "status"
    if cmd == "serve":
        serve()
    elif cmd == "status":
        return status("--json" in argv)
    elif cmd == "setup":
        return setup()
    elif cmd == "open":
        cfg = load_config()
        os.makedirs(dest_dir(cfg), exist_ok=True)
        run_bg(["xdg-open", dest_dir(cfg)])
    else:
        print("usage: drop.py serve|status [--json]|setup|open", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
