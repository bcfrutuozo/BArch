#!/usr/bin/env python3
"""barch-voice: always-on voice control of the desktop, in Brazilian Portuguese (or any language
whisper knows: `voice.py language <code>`, the bar's microphone panel).

Like a car: the microphone is always open, nothing happens until a sentence starts with the
wake word ("barch"). Everything runs on this machine: PipeWire capture (pw-record), an energy
VAD, whisper.cpp for the words (GPU through ggml-cuda when installed), a table of intents in
commands.json for the usual commands (no AI, no credits), `claude -p` for whatever the table
does not know, and Piper for the spoken answers.

    voice.py                 the daemon (barch-voice.service)
    voice.py status          what it is doing (JSON)
    voice.py run "texto"     handle a sentence as if it had been heard (no wake word needed)
    voice.py say "texto"     speak
    voice.py pause|resume|toggle|reload|stop
    voice.py language [code]  the language it listens and answers in (pt, en, auto…); languages lists them
    voice.py match "texto"   which intent a sentence hits and what it would run (offline, runs nothing)

State for the bar: ~/.local/state/barch/voice/state.json (the bar watches it); control socket:
$XDG_RUNTIME_DIR/barch-voice.sock (newline-delimited JSON). Settings: config.json next to this
file; intents: commands.json; the prompt of the Claude fallback: fallback.md; the languages and
their Piper voices: languages.json (the choice is kept in ~/.local/state/barch/voice/language).

Only Portuguese has the command table: in any other language the sentence goes, as whisper wrote
it, to Claude, who answers in that language with that language's Piper voice (downloaded the
first time the language is picked; a language without one answers in a notification).
"""
from __future__ import annotations

import difflib
import glob
import io
import json
import math
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import unicodedata
import wave
from datetime import datetime
from pathlib import Path

try:
    import numpy as np
except ImportError:  # pragma: no cover - numpy is in packages/pacman.txt
    np = None

HERE = Path(__file__).resolve().parent
HOME = Path.home()
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "barch/voice"
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
SOCKET = RUNTIME / "barch-voice.sock"
STATE_FILE = STATE_DIR / "state.json"
UNMATCHED = STATE_DIR / "unmatched.log"
LANG_FILE = STATE_DIR / "language"


def load_languages() -> dict:
    """languages.json → {code: entry}, in its order (auto first)."""
    try:
        doc = json.loads((HERE / "languages.json").read_text())
        return {e["code"]: e for e in doc.get("languages", [])}
    except (OSError, json.JSONDecodeError, KeyError):
        return {"pt": {"code": "pt", "name": "Portuguese", "native": "Português", "voice": "pt_BR-faber-medium", "latin": True}}


LANGUAGES = load_languages()
LANG_BY_NAME = {e["name"].lower(): c for c, e in LANGUAGES.items()}   # whisper's detected_language → code

# what the daemon itself says when something fails: Portuguese, and English for every other language
MESSAGES = {
    "pt": {"slow": "O Claude demorou demais.", "noanswer": "O Claude não respondeu.", "login": "A sessão do Claude expirou. Faça login de novo.",
           "failed": "O Claude não conseguiu.", "unknown": "Não entendi.", "cancel": "Cancelado.", "confirm": "Confirma?"},
    "en": {"slow": "Claude took too long.", "noanswer": "Claude did not answer.", "login": "Claude's session expired. Log in again.",
           "failed": "Claude could not do it.", "unknown": "I did not understand.", "cancel": "Cancelled.", "confirm": "Confirm?"},
}


def msg(lang: str, key: str) -> str:
    return MESSAGES.get(lang, MESSAGES["en"])[key]


# a yes or a no to "Confirm?" in any language: normalized (Latin letters) or as written
YES = re.compile(r"(sim|confirma|confirmo|pode|isso|vai|bora|yes|yeah|yep|sure|ok|okay|claro|do it|go ahead|si|oui|ja|jawohl|"
                 r"tak|da|ano|igen|evet|ndio|kylla|jah)( .*)?")
NO = re.compile(r"(nao|cancela|cancelar|deixa|esquece|para|no|nope|cancel|stop|non|nein|nie|ne ?ne|hayir|nej|ei|nu)( .*)?")
YES_RAW = ("да", "так", "是", "好", "对", "はい", "うん", "네", "예", "응", "نعم", "بله", "हाँ", "हां", "כן", "ναι", "ใช่", "có", "evet")
NO_RAW = ("нет", "ні", "不", "不是", "いいえ", "아니", "아니요", "لا", "نه", "नहीं", "לא", "όχι", "ไม่", "không")


def yes_no(text: str) -> bool | None:
    raw = text.strip().lower().strip(" ,.!?。、！？")
    if any(raw.startswith(w) for w in YES_RAW):
        return True
    if any(raw.startswith(w) for w in NO_RAW):
        return False
    t = normalize(text)
    if NO.fullmatch(t) and not YES.fullmatch(t):
        return False
    if YES.fullmatch(t):
        return True
    return None
HISTORY = STATE_DIR / "history.log"
BARCH = HOME / ".local/bin/barch"
RATE = 16000
FRAME = 320                      # 20 ms at 16 kHz
BYTES_PER_FRAME = FRAME * 2      # s16

DEFAULTS = {
    "wake": ["barch", "bartch", "bark", "barque", "bach", "barche", "bart", "bash", "march", "parch", "barg"],
    "wake_min_ratio": 0.72,
    "wake_window_s": 8,          # after "barch" alone, how long the next sentence counts as the command
    "followup_s": 8,             # after an answer, how long the next sentence needs no "barch" (0 = off)
    "context_s": 90,             # how long the last command counts for "mais", "menos", "de novo"
    "launch_wait_s": 12,         # how long to watch for the window of an app just opened
    "head_s": 2.2,               # how much of a sentence is transcribed to look for the wake word
    "vad_floor_mult": 4.0,
    "vad_min_rms": 220,
    "vad_start_frames": 4,
    "vad_end_ms": 700,
    "vad_preroll_ms": 400,
    "utterance_min_ms": 350,
    "utterance_max_s": 15,
    "mic_target": "",            # PipeWire node name/serial; empty = default source
    "whisper_model": "",         # path; empty = first found in whisper_model_search
    "whisper_model_search": [
        "/usr/share/whisper.cpp-model-large-v3-turbo-q5_0/ggml-large-v3-turbo-q5_0.bin",
        "/usr/share/whisper.cpp-model-large-v3-turbo/ggml-large-v3-turbo.bin",
        "/usr/share/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin",
        "/usr/share/whisper.cpp/models/*.bin",
        "~/.local/share/whisper.cpp/models/*.bin",
        "~/.local/share/barch-voice/models/*.bin",
        "/usr/share/whisper.cpp-model-*/*.bin",
    ],
    "whisper_port": 18791,
    "whisper_threads": 4,
    # Only the spelling of the wake word: whisper writes the prompt itself back when it hears noise
    # (keyboard, a chair), so a prompt with commands in it ran them ("Barch, fecha a janela.").
    "whisper_prompt": "Barch.",
    "tts_voice": "pt_BR-faber-medium",
    "tts_dir": "~/.local/share/piper",
    "tts_speed": 1.0,
    "confirm_sound": True,
    "claude": True,
    "claude_model": "claude-sonnet-5-5",
    "claude_timeout_s": 120,
    "claude_tools": [
        "Bash(barch *)", "Bash(hyprctl *)", "Bash(uwsm app *)", "Bash(qs ipc *)", "Bash(wpctl *)",
        "Bash(playerctl *)", "Bash(foot *)", "Bash(xdg-open *)", "Bash(systemctl --user *)",
        "Bash(loginctl *)", "Bash(date *)", "Bash(cat *)", "Bash(ls *)", "Bash(df *)", "Bash(free *)",
        "Bash(checkupdates *)", "Bash(khal *)", "Read", "Glob", "Grep",
    ],
    "project_roots": ["~/Source", "~/Projects", "~/BArch"],
    "terminal": "foot",
    "debug": False,
}

NUMBERS = {
    "zero": 0, "um": 1, "uma": 1, "dois": 2, "duas": 2, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6,
    "sete": 7, "oito": 8, "nove": 9, "dez": 10, "onze": 11, "doze": 12, "treze": 13, "quatorze": 14,
    "catorze": 14, "quinze": 15, "vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50,
    "sessenta": 60, "setenta": 70, "oitenta": 80, "noventa": 90, "cem": 100,
}
COUNTRIES = {
    "brasil": "BR", "brazil": "BR", "argentina": "AR", "chile": "CL", "uruguai": "UY", "colombia": "CO", "peru": "PE",
    "mexico": "MX", "estados unidos": "US", "eua": "US", "america": "US", "canada": "CA", "alemanha": "DE",
    "franca": "FR", "espanha": "ES", "portugal": "PT", "italia": "IT", "inglaterra": "GB", "reino unido": "GB",
    "londres": "GB", "irlanda": "IE", "holanda": "NL", "paises baixos": "NL", "belgica": "BE", "suica": "CH",
    "austria": "AT", "suecia": "SE", "noruega": "NO", "dinamarca": "DK", "finlandia": "FI", "islandia": "IS",
    "polonia": "PL", "republica tcheca": "CZ", "tchequia": "CZ", "hungria": "HU", "romenia": "RO", "grecia": "GR",
    "turquia": "TR", "ucrania": "UA", "russia": "RU", "japao": "JP", "coreia": "KR", "coreia do sul": "KR",
    "china": "CN", "hong kong": "HK", "taiwan": "TW", "singapura": "SG", "india": "IN", "australia": "AU",
    "nova zelandia": "NZ", "africa do sul": "ZA", "egito": "EG", "israel": "IL", "emirados": "AE", "dubai": "AE",
    "tailandia": "TH", "vietna": "VN", "indonesia": "ID", "filipinas": "PH", "malasia": "MY", "luxemburgo": "LU",
    "venezuela": "VE", "panama": "PA", "costa rica": "CR", "cuba": "CU", "jamaica": "JM", "marrocos": "MA",
}
FILLERS = [
    "por favor", "por gentileza", "pra mim", "para mim", "voce pode", "voce poderia", "pode", "poderia",
    "quero que voce", "quero que", "eu quero", "queria", "me", "ai", "entao", "e ai", "oh", "ei", "hey",
]


def log(*a):
    print(datetime.now().strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


# What whisper writes when there is no speech (noise, breathing, the tail of a sentence): never a command.
HALLUCINATIONS = {
    "obrigado", "obrigada", "tchau", "e ai", "legendas pela comunidade amara org", "amara org",
    "legendas", "inscreva-se", "inscreva se no canal", "ate a proxima", "ate mais",
    "thank you", "thanks", "thanks for watching", "thank you for watching", "bye", "you",
}

# Words whisper spells its own way → what commands.json and the aliases use.
SYNONYMS = [
    (r"\bh[iy]per ?land\b", "hyprland"),
    (r"\bquick ?shell\b", "quickshell"),
    (r"\bcl[ao]ude?\b", "claude"),
]


# "coloca ele no workspace dois", "fecha isso": the pronoun is the last window we touched or opened.
PRONOUNS = re.compile(r"\b(nele|nela|ele|ela|esse|essa|isso|isto)\b")
# intents whose target is the focused window: the window becomes "ele" for the next sentence
WINDOW_INTENTS = {"window-close", "window-fullscreen", "window-float", "window-minimize", "window-pin",
                  "window-swap", "workspace-move", "scratchpad-move", "focus-named"}


def normalize(text: str) -> str:
    t = unicodedata.normalize("NFD", text.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    t = re.sub(r"[^a-z0-9%+\- ]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def fix_names(t: str) -> str:
    for pat, to in SYNONYMS:
        t = re.sub(pat, to, t)
    return t


def strip_fillers(t: str) -> str:
    changed = True
    while changed:
        changed = False
        for f in FILLERS:
            if t.startswith(f + " "):
                t = t[len(f) + 1:]
                changed = True
            if t.endswith(" " + f):
                t = t[: -len(f) - 1]
                changed = True
    return t


def number_from(word: str) -> int | None:
    w = normalize(word)
    if w.isdigit():
        return int(w)
    total, found = 0, False
    for part in w.replace(" e ", " ").split():
        if part in NUMBERS:
            total += NUMBERS[part]
            found = True
        elif part.isdigit():
            total += int(part)
            found = True
    return total if found else None


def fuzzy(name: str, candidates: dict[str, str], cutoff=0.6) -> str | None:
    """candidates: normalized label → value. Exact, then substring, then closest."""
    q = normalize(name)
    if not q:
        return None
    if q in candidates:
        return candidates[q]
    subs = [k for k in candidates if q in k or k in q]
    if subs:
        return candidates[min(subs, key=lambda k: abs(len(k) - len(q)))]
    close = difflib.get_close_matches(q, list(candidates), n=1, cutoff=cutoff)
    return candidates[close[0]] if close else None


def atomic_write(path: Path, data: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(data)
    tmp.replace(path)


def run(cmd: list[str], timeout=20, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)


def spawn(cmd: list[str], cwd: str | None = None):
    """Start a desktop program detached from the daemon (own session, no inherited pipes)."""
    subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def read_exact(f, n: int) -> bytes | None:
    """n bytes from a pipe, or None at EOF."""
    chunks = []
    got = 0
    while got < n:
        b = f.read(n - got)
        if not b:
            return None
        chunks.append(b)
        got += len(b)
    return b"".join(chunks)


def wav_bytes(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)
    return buf.getvalue()


# ---------------------------------------------------------------- speech to text

class Whisper:
    """whisper.cpp: whisper-server kept warm when it exists, whisper-cli per sentence otherwise."""
    detected = "pt"                  # the language of the last transcription (whisper's detection)

    def __init__(self, cfg):
        self.cfg = cfg
        self.model = self._find_model()
        self.server = None
        self.port = int(cfg["whisper_port"])
        self.lock = threading.Lock()
        self.cli = shutil.which("whisper-cli")
        self.server_bin = shutil.which("whisper-server")

    def _find_model(self) -> str:
        if self.cfg["whisper_model"]:
            return str(Path(self.cfg["whisper_model"]).expanduser())
        for pat in self.cfg["whisper_model_search"]:
            hits = sorted(glob.glob(str(Path(pat).expanduser())))
            if hits:
                return hits[0]
        return ""

    @property
    def available(self) -> bool:
        return bool(self.model) and bool(self.server_bin or self.cli)

    def start(self):
        if not self.server_bin or not self.model:
            return
        cmd = [self.server_bin, "-m", self.model, "-l", "pt", "--host", "127.0.0.1", "--port", str(self.port),
               "-t", str(self.cfg["whisper_threads"]), "--no-timestamps", "--convert"]
        self.server = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
        for _ in range(600):
            if self.server.poll() is not None:
                log("whisper-server exited early; falling back to whisper-cli")
                self.server = None
                return
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    log(f"whisper-server ready ({Path(self.model).name})")
                    return
            except OSError:
                time.sleep(0.1)
        log("whisper-server did not come up; falling back to whisper-cli")
        self.server.kill()
        self.server = None

    def stop(self):
        if self.server and self.server.poll() is None:
            self.server.terminate()
            try:
                self.server.wait(5)
            except subprocess.TimeoutExpired:
                self.server.kill()

    def transcribe(self, pcm: bytes, lang: str = "pt") -> str:
        """The words in `lang` (a whisper code, or "auto"); the language whisper heard goes to
        self.detected (a code; only the server reports it, the CLI leaves the asked one)."""
        if not self.available:
            return ""
        self.detected = lang
        with self.lock:
            try:
                if self.server and self.server.poll() is None:
                    return self._server(pcm, lang)
                return self._cli(pcm, lang)
            except Exception as e:  # noqa: BLE001
                log("whisper failed:", e)
                return ""

    def _server(self, pcm: bytes, lang: str) -> str:
        import urllib.request
        boundary = "----barchvoice"
        fields = {"temperature": "0.0", "response_format": "verbose_json", "language": lang,
                  "prompt": self.cfg["whisper_prompt"]}
        body = b""
        for k, v in fields.items():
            body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n"
                 f"Content-Type: audio/wav\r\n\r\n").encode() + wav_bytes(pcm) + f"\r\n--{boundary}--\r\n".encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/inference", data=body, method="POST",
                                     headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read().decode())
        name = str(data.get("detected_language") or "").lower()
        self.detected = LANG_BY_NAME.get(name, lang)
        return (data.get("text") or "").strip()

    def _cli(self, pcm: bytes, lang: str) -> str:
        path = RUNTIME / "barch-voice-in.wav"
        path.write_bytes(wav_bytes(pcm))
        r = run([self.cli, "-m", self.model, "-l", lang, "-t", str(self.cfg["whisper_threads"]), "-nt", "-np",
                 "--prompt", self.cfg["whisper_prompt"], "-f", str(path)], timeout=120)
        return " ".join(line.strip() for line in r.stdout.splitlines() if line.strip())


# ---------------------------------------------------------------- text to speech

class Speaker:
    def __init__(self, cfg, on_busy):
        self.cfg = cfg
        self.on_busy = on_busy          # called with True while sound plays (the mic ignores it)
        self.piper = shutil.which("piper") or shutil.which("piper-tts")
        self.warned = False
        self.player = shutil.which("pw-play") or shutil.which("paplay")
        self.dir = Path(cfg["tts_dir"]).expanduser()
        self.lock = threading.Lock()
        self.current = None
        self.chimes = {}
        self._make_chimes()

    @property
    def available(self) -> bool:
        return bool(self.piper and self.player and self.voice_model())

    def voice_for(self, lang: str) -> str:
        """The Piper voice of a language: tts_voice for Portuguese, tts_voices[lang] or languages.json."""
        if lang == "pt":
            return self.cfg["tts_voice"]
        return (self.cfg.get("tts_voices") or {}).get(lang) or (LANGUAGES.get(lang) or {}).get("voice") or ""

    def has(self, lang: str) -> bool:
        return bool(self.piper and self.player and self.voice_model(self.voice_for(lang)))

    def download(self, voice: str) -> bool:
        """piper 1.x: `python -m piper.download_voices` (the AUR piper-tts ships the module)."""
        self.dir.mkdir(parents=True, exist_ok=True)
        try:
            r = subprocess.run([sys.executable, "-m", "piper.download_voices", "--download-dir", str(self.dir), voice],
                               capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired) as e:
            log("voice download failed:", voice, e)
            return False
        ok = bool(self.voice_model(voice))
        log(f"voice {voice}:", "downloaded" if ok else "download failed " + (r.stderr or "").strip()[-200:])
        return ok

    def voice_model(self, v: str = "") -> str:
        """The .onnx of a voice (tts_voice by default) under tts_dir (also one level down, how older piper laid them out)."""
        v = v or self.cfg["tts_voice"]
        if not v:
            return ""
        for pat in (f"{v}.onnx", f"*/{v}.onnx"):
            hits = sorted(self.dir.glob(pat))
            if hits:
                return str(hits[0])
        return ""

    def _tone(self, parts, name):
        """parts: [(freq, ms)] → short wav in the runtime dir."""
        rate = 48000
        frames = bytearray()
        for freq, ms in parts:
            n = int(rate * ms / 1000)
            for i in range(n):
                env = min(1.0, i / (rate * 0.008), (n - i) / (rate * 0.03))
                v = int(9000 * env * math.sin(2 * math.pi * freq * i / rate))
                frames += struct.pack("<h", v)
        path = RUNTIME / f"barch-voice-{name}.wav"
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(bytes(frames))
        self.chimes[name] = path

    def _make_chimes(self):
        try:
            self._tone([(880, 70), (1320, 110)], "wake")      # "I'm listening"
            self._tone([(1320, 60)], "ok")                     # done
            self._tone([(440, 90), (330, 140)], "fail")        # no
        except OSError as e:
            log("could not write the chimes:", e)

    def chime(self, name):
        p = self.chimes.get(name)
        if p and self.player:
            self._play(p)

    def _play(self, path: Path):
        with self.lock:
            self.on_busy(True)
            try:
                self.current = subprocess.Popen([self.player, "-P", '{ application.name = "barch-voice" }', str(path)],
                                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                                stderr=subprocess.DEVNULL)
                self.current.wait(60)
            except Exception as e:  # noqa: BLE001
                log("playback failed:", e)
            finally:
                self.current = None
                time.sleep(0.25)        # the room's echo of our own voice
                self.on_busy(False)

    def say(self, text: str, lang: str = "pt") -> bool:
        text = (text or "").strip()
        if not text:
            return False
        model = self.voice_model(self.voice_for(lang))
        if lang != "pt" and not model:
            log(f"say (no voice for {lang}):", text)
            return False
        if not self.available:
            log("say (no piper):", text)
            if not self.warned:
                self.warned = True
                why = "piper-tts not installed" if not self.piper else f"voice {self.cfg['tts_voice']} not in {self.dir}"
                log(f"spoken answers off: {why} (barch voice setup --install)")
            return False
        out = RUNTIME / "barch-voice-say.wav"
        try:
            r = subprocess.run([self.piper, "-m", model or self.voice_model(), "--length-scale", str(1 / float(self.cfg["tts_speed"])),
                                "-f", str(out)], input=text, capture_output=True, text=True, timeout=60)
            if r.returncode != 0:
                log("piper failed:", r.stderr.strip()[-300:])
                return False
        except Exception as e:  # noqa: BLE001
            log("piper failed:", e)
            return False
        self._play(out)
        return True

    def hush(self):
        p = self.current
        if p and p.poll() is None:
            p.terminate()


# ---------------------------------------------------------------- the desktop

class Desktop:
    """What the intents resolve against: apps, projects, palettes, scenes, VPN regions."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.apps: dict[str, str] = {}          # normalized name → desktop id
        self.app_labels: dict[str, str] = {}    # desktop id → Name
        self.projects: dict[str, str] = {}      # normalized name → path
        self.palettes: dict[str, tuple[str, str]] = {}   # normalized label/id → (id, dark|light)
        self.scenes: dict[str, str] = {}
        self.regions: dict[str, str] = {}       # normalized name → id
        self.region_list: list[dict] = []
        self.loaded = 0

    def refresh(self, force=False):
        if not force and time.time() - self.loaded < 300:
            return
        self.loaded = time.time()
        self._apps()
        self._projects()
        self._bar()

    def _apps(self):
        apps, labels = {}, {}
        dirs = [Path(d) / "applications" for d in
                [os.environ.get("XDG_DATA_HOME", str(HOME / ".local/share"))]
                + os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")]
        seen = set()
        for d in dirs:
            for f in sorted(d.glob("*.desktop")) if d.is_dir() else []:
                if f.name in seen:
                    continue
                seen.add(f.name)
                try:
                    txt = f.read_text(errors="replace")
                except OSError:
                    continue
                entry = txt.split("[Desktop Entry]", 1)[-1].split("\n[", 1)[0]
                kv = dict(line.split("=", 1) for line in entry.splitlines() if "=" in line and not line.startswith("#"))
                if kv.get("NoDisplay", "").lower() == "true" or kv.get("Hidden", "").lower() == "true":
                    continue
                if kv.get("Type", "Application") != "Application":
                    continue
                name = kv.get("Name[pt_BR]") or kv.get("Name[pt]") or kv.get("Name")
                if not name:
                    continue
                labels[f.name] = name
                apps[normalize(name)] = f.name
                for alt in [kv.get("GenericName[pt_BR]"), kv.get("GenericName"), f.stem.split(".")[-1]]:
                    if alt and normalize(alt) not in apps:
                        apps[normalize(alt)] = f.name
        self.apps, self.app_labels = apps, labels

    def _projects(self):
        found = {}
        for root in self.cfg["project_roots"]:
            r = Path(root).expanduser()
            if not r.is_dir():
                continue
            if (r / ".git").exists():
                found[normalize(r.name)] = str(r)
            for child in sorted(r.iterdir()):
                if child.is_dir() and not child.name.startswith("."):
                    found[normalize(child.name)] = str(child)
                    # one more level (Source/<group>/<repo>)
                    if not (child / ".git").exists():
                        for sub in sorted(child.iterdir()):
                            if sub.is_dir() and (sub / ".git").exists():
                                found.setdefault(normalize(sub.name), str(sub))
        self.projects = found

    def _bar(self):
        try:
            r = run([str(BARCH), "--json", "theme", "palettes"], timeout=5)
            d = json.loads(r.stdout) if r.returncode == 0 else {}
            pal = {}
            for side in ("dark", "light"):
                for p in d.get(side, []):
                    pal[normalize(p["label"])] = (p["id"], side)
                    pal.setdefault(normalize(p["id"]), (p["id"], side))
            if pal:
                self.palettes = pal
        except Exception:  # noqa: BLE001
            pass
        try:
            r = run([str(BARCH), "--json", "wallpaper", "list"], timeout=5)
            d = json.loads(r.stdout) if r.returncode == 0 else {}
            sc = {}
            for s in d.get("scenes", []):
                sc[normalize(s["label"])] = s["id"]
                sc.setdefault(normalize(s["id"]), s["id"])
            if sc:
                self.scenes = sc
        except Exception:  # noqa: BLE001
            pass
        try:
            r = run([str(BARCH), "--json", "vpn", "regions"], timeout=8)
            d = json.loads(r.stdout) if r.returncode == 0 else {}
            rg = {}
            for x in d.get("regions", []):
                rg[normalize(x.get("name", ""))] = x["id"]
            if rg:
                self.regions = rg
                self.region_list = d["regions"]
        except Exception:  # noqa: BLE001
            pass

    def region_for(self, text: str) -> str | None:
        """A PIA region from a spoken place: 'alemanha' → the plain German region, else by name."""
        q = normalize(text)
        if not q or q in ("auto", "automatica", "automatico", "mais rapida", "melhor"):
            return "auto"
        cc = COUNTRIES.get(q) or (COUNTRIES.get(q[:-1]) if q.endswith("s") else None)
        if cc:
            plain = [r for r in self.region_list if r.get("country") == cc and "streaming" not in r["name"].lower()]
            any_ = [r for r in self.region_list if r.get("country") == cc]
            if plain or any_:
                return (plain or any_)[0]["id"]
        names = {k: v for k, v in self.regions.items() if "streaming" not in k}
        return fuzzy(q, names, cutoff=0.75)

    def default_browser(self) -> str:
        try:
            r = run(["xdg-settings", "get", "default-web-browser"], timeout=5)
            return r.stdout.strip()
        except Exception:  # noqa: BLE001
            return ""

    def clients(self) -> list[dict]:
        try:
            r = run(["hyprctl", "-j", "clients"], timeout=3)
            return json.loads(r.stdout) if r.stdout.strip() else []
        except Exception:  # noqa: BLE001
            return []

    def active_window(self) -> dict:
        try:
            r = run(["hyprctl", "-j", "activewindow"], timeout=3)
            return json.loads(r.stdout) if r.stdout.strip() else {}
        except Exception:  # noqa: BLE001
            return {}

    def locked(self) -> bool:
        try:
            r = run(["qs", "-p", str(HOME / ".config/quickshell/lock"), "ipc", "call", "lock", "state"], timeout=3)
            return bool(json.loads(r.stdout).get("locked"))
        except Exception:  # noqa: BLE001
            return False


# ---------------------------------------------------------------- intents

class Intents:
    def __init__(self, cfg, desktop: Desktop, speaker: Speaker, ask_claude):
        self.cfg = cfg
        self.desktop = desktop
        self.speaker = speaker
        self.ask_claude = ask_claude
        self.rules = []
        self.aliases = {}
        self.pending = None          # (expires, callable) waiting for "sim"
        self.dry = False             # `voice.py match`: say what would run, run nothing
        # short memory: the last command (for "mais", "de novo"), the window we opened or touched
        # last (for "ele", "essa janela") and the last exchanges (for the Claude fallback)
        self.last = None             # (rule, groups, res, time)
        self.window = ""             # hyprland address of "ele"
        self.launch_until = 0.0      # while > now, an app was just opened and its window may still be coming
        self.history = []            # [(heard, said)] newest last, at most 6
        self.load()

    def load(self):
        data = json.loads((HERE / "commands.json").read_text())
        self.aliases = {normalize(k): v for k, v in data.get("app_aliases", {}).items()}
        rules = []
        for r in data["intents"]:
            pats = [re.compile("^(?:" + p + ")$") for p in r["patterns"]]
            rules.append((r, pats))
        self.rules = rules
        log(f"{len(rules)} intents loaded")

    # -- helpers for templates
    def _expand(self, s: str, groups: dict) -> str:
        def sub(m):
            k = m.group(1)
            return str(groups.get(k, ""))
        return re.sub(r"(?<!\{)\{(\w+)\}(?!\})", sub, s)

    def _onoff(self, groups: dict) -> str:
        v = groups.get("verb", "")
        return "off" if re.search(r"^off$|desl|desat|desconect|derrub|tira|fecha|cancela|remove|apaga|^para|^sai|^desce", v) else "on"

    def handle(self, text: str, heard=True) -> dict:
        """Returns {"matched": bool, "say": str, "intent": name}."""
        raw = fix_names(re.sub(r"^(?:barch|bart|bartch)\b[ ,]*", "", normalize(text)).strip())
        t = strip_fillers(raw)
        if not t:
            return {"matched": False, "say": ""}
        self.desktop.refresh()

        # a yes/no for a pending confirmation
        if self.pending:
            expires, fn, what = self.pending
            self.pending = None
            if time.time() < expires:
                if re.fullmatch(r"(sim|confirma|confirmo|pode|isso|vai|bora|yes|ok|okay|claro)( .*)?", t):
                    return fn()
                if re.fullmatch(r"(nao|cancela|cancelar|deixa|esquece|para|no)( .*)?", t):
                    return {"matched": True, "say": "Cancelado.", "intent": "cancel"}

        # "coloca ele no workspace dois" → "coloca a janela no workspace dois", on the window we remember
        referring = bool(PRONOUNS.search(t)) and len(t.split()) > 1 and bool(self.window or self.launch_until > time.time() or self.dry)
        if referring:
            raw = normalize(PRONOUNS.sub("a janela", raw)).replace("a a janela", "a janela").replace("o a janela", "a janela")
            t = normalize(PRONOUNS.sub("a janela", t)).replace("a a janela", "a janela").replace("o a janela", "a janela")

        for rule, pats in self.rules:
            for p in pats:
                m = p.match(raw) or (p.match(t) if t != raw else None)
                if m:
                    groups = {k: (v or "") for k, v in m.groupdict().items()}
                    if referring and rule["name"] in WINDOW_INTENTS and not self.dry:
                        self.focus_remembered()
                    try:
                        res = self.execute(rule, groups, t)
                    except Exception as e:  # noqa: BLE001
                        log("intent failed:", rule["name"], e)
                        res = {"matched": True, "say": "Deu erro: " + str(e)[:80], "intent": rule["name"], "ok": False}
                    if res is not None:
                        res.setdefault("intent", rule["name"])
                        if rule.get("kind") != "again":
                            self.remember(rule, groups, res)
                        return res
        return {"matched": False, "say": ""}

    # -- short memory
    def remember(self, rule: dict, groups: dict, res: dict):
        """After a command ran: it is what "mais"/"de novo" repeat, its window is "ele"."""
        now = time.time()
        if self.last and self.last[0] is rule and now - self.last[3] < float(self.cfg["context_s"]) \
                and res.get("ok", True) and res.get("say") and res.get("say") == self.last[2].get("say"):
            res["say"] = ""          # the same answer twice in a row: a chime is enough
            res.setdefault("sound", "default")
        self.last = (rule, dict(groups), dict(res), now)
        if rule["name"] in WINDOW_INTENTS and rule["name"] != "window-close" and not self.dry:
            win = self.desktop.active_window()
            if win.get("address"):
                self.window = win["address"]

    def note(self, heard: str, said: str):
        self.history = (self.history + [(heard, said)])[-6:]

    def watch_launch(self):
        """An app was just started: the first new window is "ele" (polled, in the background)."""
        before = {c.get("address") for c in self.desktop.clients()}
        self.launch_until = time.time() + float(self.cfg["launch_wait_s"])

        def poll():
            while time.time() < self.launch_until:
                time.sleep(0.4)
                for c in self.desktop.clients():
                    if c.get("address") not in before and c.get("mapped", True):
                        self.window = c["address"]
                        self.launch_until = 0
                        return
        threading.Thread(target=poll, daemon=True).start()

    def focus_remembered(self) -> bool:
        """Bring "ele" to the front (waiting a little if it is still opening). False when it is gone."""
        deadline = time.time() + 4
        while not self.window and self.launch_until > time.time() and time.time() < deadline:
            time.sleep(0.2)
        if not self.window:
            return False
        clients = {c.get("address"): c for c in self.desktop.clients()}
        if self.window not in clients:
            self.window = ""
            return False
        if self.desktop.active_window().get("address") != self.window:
            run(["hyprctl", "dispatch", f"hl.dsp.focus({{ window = 'address:{self.window}' }})"], timeout=5)
            time.sleep(0.15)
        return True

    def find_window(self, name: str) -> dict | None:
        """A window by what it is called: the app's name or alias, its class, or a word of its title."""
        q = normalize(name)
        if not q:
            return None
        alias = self._alias(q)
        if alias and alias.endswith(".desktop"):
            q = normalize(alias[:-8].split(".")[-1].replace("-launcher", ""))
        elif alias == "foot" or q in ("terminal", "console"):
            q = "foot"
        elif alias == "browser":
            did = self.desktop.default_browser() or ""
            q = normalize(did[:-8]) if did.endswith(".desktop") else q
        clients = [c for c in self.desktop.clients() if c.get("address")]
        classes = {}
        for c in clients:
            for key in (c.get("class"), c.get("initialClass")):
                if key:
                    classes.setdefault(normalize(key), c)
        hit = fuzzy(q, classes, cutoff=0.75)
        if hit:
            return hit
        if len(q) >= 4:
            for c in clients:
                if q in normalize(c.get("title", "")) or q in normalize(c.get("initialTitle", "")):
                    return c
        return None

    def confirm(self, what: str, fn, lang: str = "pt") -> dict:
        self.pending = (time.time() + 15, fn, what)
        # outside Portuguese Claude writes the whole question in the language (fallback.md)
        say = what + " " + msg("pt", "confirm") if lang == "pt" else what.rstrip(".") + ("" if what.rstrip(".").endswith("?") else "?")
        return {"matched": True, "say": say, "intent": "confirm", "sound": None}

    def answer_pending(self, text: str, lang: str) -> dict | None:
        """Outside Portuguese only the yes/no to a pending confirmation is handled here."""
        if not self.pending:
            return None
        expires, fn, _ = self.pending
        self.pending = None
        if time.time() >= expires:
            return None
        answer = yes_no(re.sub(r"^\W*(?:barch|bart|bartch|bartsch)\b[ ,]*", "", text, flags=re.I))
        if answer is True:
            return fn()
        if answer is False:
            return {"matched": True, "say": msg(lang, "cancel"), "intent": "cancel"}
        return None

    def execute(self, rule: dict, g: dict, text: str) -> dict | None:
        kind = rule.get("kind", "exec")
        say = rule.get("say", "")
        res = {"matched": True, "say": "", "ok": True}
        for k, v in rule.get("defaults", {}).items():
            if not g.get(k):
                g[k] = v
        for k, table in rule.get("map", {}).items():
            if k in g:
                g[k] = table.get(normalize(g[k]), g[k])
        if "onoff" in rule:
            g["onoff"] = rule["onoff"] if rule["onoff"] in ("on", "off") else self._onoff(g)
            g["onoff_pt"] = "ligado" if g["onoff"] == "on" else "desligado"
        if "sound" in rule:
            res["sound"] = rule["sound"]
        for k in list(g):
            if k.startswith("n_") and g[k]:
                n = number_from(g[k])
                if n is None:
                    return None
                g[k] = str(n)
        if self.dry:
            return self._plan(kind, rule, g, res)

        if kind == "exec":
            cmd = [self._expand(a, g) for a in rule["run"]]
            r = run(cmd, timeout=rule.get("timeout", 30))
            res["ok"] = r.returncode == 0
            if not res["ok"]:
                err = (r.stderr or r.stdout).strip().splitlines()
                res["say"] = rule.get("fail", "Não consegui. " + (err[-1][:80] if err else ""))
                return res
            if rule.get("say_output"):
                res["say"] = r.stdout.strip()[:400]
                return res
        elif kind == "spawn":
            spawn([self._expand(a, g) for a in rule["run"]])
        elif kind == "hypr":
            r = run(["hyprctl", "dispatch", self._expand(rule["dispatch"], g)], timeout=5)
            res["ok"] = r.returncode == 0 and "ok" in r.stdout.lower()
        elif kind == "app":
            return self._app(g.get("app", ""), res)
        elif kind == "again":
            return self._again(rule.get("how", "again"), text)
        elif kind == "winref":
            win = self.find_window(g.get("win", ""))
            if not win:
                return None                      # "fecha o fulano" with no such window: maybe something else
            if rule.get("action") == "close":
                run(["hyprctl", "dispatch", f"hl.dsp.focus({{ window = 'address:{win['address']}' }})"], timeout=5)
                time.sleep(0.15)
                if self.desktop.active_window().get("address") == win["address"]:
                    run(["hyprctl", "dispatch", "hl.dsp.window.close()"], timeout=5)
                res["sound"] = None
            else:
                run(["hyprctl", "dispatch", f"hl.dsp.focus({{ window = 'address:{win['address']}' }})"], timeout=5)
                self.window = win["address"]
                res["sound"] = None
            res["window"] = win.get("title", "")
        elif kind == "project":
            return self._project(g.get("proj", ""), rule.get("with", ""), res)
        elif kind == "palette":
            hit = fuzzy(g.get("palette", ""), self.desktop.palettes)
            if not hit:
                res["say"] = "Não conheço essa paleta."
                res["ok"] = False
                return res
            pid, side = hit
            r = run([str(BARCH), "theme", side, pid], timeout=20)
            res["ok"] = r.returncode == 0
            say = rule.get("say", "").replace("{palette}", pid)
        elif kind == "scene":
            hit = fuzzy(g.get("scene", ""), self.desktop.scenes)
            if not hit:
                res["say"] = "Não conheço esse papel de parede."
                res["ok"] = False
                return res
            extra = ["--lock"] if "bloqueio" in text or "lock" in text else ["--desktop"] if "desktop" in text or "area de trabalho" in text else []
            r = run([str(BARCH), "wallpaper", hit] + extra, timeout=20)
            res["ok"] = r.returncode == 0
        elif kind == "region":
            hit = self.desktop.region_for(g.get("region", ""))
            if not hit:
                res["say"] = "Não achei essa região."
                res["ok"] = False
                return res
            r = run([str(BARCH), rule.get("what") or "vpn", "on", hit], timeout=90)
            res["ok"] = r.returncode == 0
            say = rule.get("say", "").replace("{region}", g.get("region") or "automática")
        elif kind == "confirm":
            cmd = [self._expand(a, g) for a in rule["run"]]
            return self.confirm(rule.get("ask", "Tem certeza?"), lambda: self._confirmed(cmd, rule.get("say", "")))
        elif kind == "say":
            pass
        elif kind == "time":
            now = datetime.now()
            say = f"São {now.hour} e {now.minute:02d}." if now.minute else f"São {now.hour} horas em ponto."
        elif kind == "date":
            now = datetime.now()
            dias = ["segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado", "domingo"]
            meses = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro",
                     "outubro", "novembro", "dezembro"]
            say = f"Hoje é {dias[now.weekday()]}, {now.day} de {meses[now.month - 1]}."
        elif kind == "health":
            r = run([str(BARCH), "--json", "health"], timeout=30)
            try:
                d = json.loads(r.stdout)
                issues = d.get("issues") or d.get("items") or []
                if isinstance(issues, dict):
                    issues = [v for v in issues.values() if v]
                say = "Tudo em ordem." if not issues else f"{len(issues)} pontos de atenção: " + "; ".join(
                    (i.get("title") or i.get("text") or str(i)) if isinstance(i, dict) else str(i) for i in issues[:4])
            except Exception:  # noqa: BLE001
                say = r.stdout.strip()[:300] or "Não consegui ler a saúde do sistema."
        elif kind == "remind":
            mins = number_from(g.get("n_min", "")) or 0
            what = g.get("what", "").strip() or "lembrete"
            if mins <= 0:
                return None
            r = run(["systemd-run", "--user", "--quiet", "--collect", f"--on-active={mins}min",
                     str(BARCH), "notify", "Lembrete", what, "--critical"], timeout=10)
            res["ok"] = r.returncode == 0
            say = f"Te lembro em {mins} minuto{'s' if mins != 1 else ''}."
        elif kind == "claude":
            return self.ask_claude(g.get("q") or text)  # pragma: no cover (dry mode returned above)
        elif kind == "pause":
            res["action"] = "pause"
        elif kind == "hush":
            self.speaker.hush()
            res["sound"] = None
            return res
        else:
            return None
        res["say"] = self._expand(say, g)
        return res

    def _plan(self, kind, rule, g, res):
        """What execute would do, for `voice.py match` (nothing runs)."""
        plan = {"matched": True, "intent": rule["name"], "kind": kind, "say": self._expand(rule.get("say", ""), g),
                "groups": {k: v for k, v in g.items() if v}}
        if kind in ("exec", "spawn", "confirm"):
            plan["run"] = [self._expand(a, g) for a in rule["run"]]
        elif kind == "hypr":
            plan["dispatch"] = self._expand(rule["dispatch"], g)
        elif kind == "app":
            q = normalize(g.get("app", ""))
            plan["app"] = self._alias(q) or fuzzy(q, self.desktop.apps, cutoff=0.7) or "(not found → Claude)"
        elif kind == "project":
            plan["project"] = fuzzy(g.get("proj", ""), self.desktop.projects, cutoff=0.6) or "(not found)"
            plan["with"] = rule.get("with", "")
        elif kind == "again":
            plan["how"] = rule.get("how", "again")
            plan["repeats"] = self.last[0]["name"] if self.last else "(nothing recent: ignored)"
        elif kind == "winref":
            win = self.find_window(g.get("win", ""))
            plan["action"] = rule.get("action", "focus")
            plan["window"] = f"{win.get('class')}: {win.get('title')}" if win else "(no such window → next rule)"
        elif kind == "palette":
            plan["palette"] = fuzzy(g.get("palette", ""), self.desktop.palettes) or "(not found)"
        elif kind == "scene":
            plan["scene"] = fuzzy(g.get("scene", ""), self.desktop.scenes) or "(not found)"
        elif kind == "region":
            plan["region"] = self.desktop.region_for(g.get("region", "")) or "(not found)"
            plan["what"] = rule.get("what") or "vpn"
        return plan

    def _again(self, how: str, text: str) -> dict | None:
        """"mais" / "menos" / "de novo": the last command again, a step further, or its inverse."""
        if not self.last or time.time() - self.last[3] > float(self.cfg["context_s"]):
            return None
        rule, groups, _, _ = self.last
        groups = dict(groups)
        adj = rule.get("adjust")
        if adj and how in ("more", "less"):
            cur = number_from(groups.get(adj["group"], "")) or 0
            groups[adj["group"]] = str(max(0, cur + (adj["by"] if how == "more" else -adj["by"])))
        elif how in ("more", "less") and rule.get("direction"):
            # "menos" after "menos" keeps going down: the pair knows which side is which
            if rule["direction"] != how:
                rule = next((r for r, _ in self.rules if r["name"] == rule.get("inverse")), None)
                if not rule:
                    return None
        elif how == "less":
            return None
        if self.dry:
            plan = self.execute(rule, groups, text) or {}
            plan["via"] = how
            return plan
        res = self.execute(rule, groups, text)
        if res is not None:
            res.setdefault("intent", rule["name"])
            self.remember(rule, groups, res)
        return res

    def _confirmed(self, cmd, say):
        r = run(cmd, timeout=30)
        return {"matched": True, "say": say if r.returncode == 0 else "Não deu.", "ok": r.returncode == 0,
                "intent": "confirmed"}

    def _alias(self, q: str) -> str | None:
        """An alias said exactly, or inside what was said ("painel de controle do hyprland")."""
        return self.aliases.get(q) or (fuzzy(q, self.aliases, cutoff=0.85) if len(q) >= 4 else None)

    def _app(self, name: str, res: dict) -> dict | None:
        q = normalize(name)
        if not q:
            return None
        alias = self._alias(q)
        if alias:
            if alias == "browser":
                did = self.desktop.default_browser()
                if did:
                    self.watch_launch()
                    spawn(["uwsm", "app", "--", did])
                    return res
            elif alias.endswith(".desktop"):
                self.watch_launch()
                spawn(["uwsm", "app", "--", alias])
                return res
            else:
                self.watch_launch()
                spawn(alias.split())
                return res
        did = fuzzy(q, self.desktop.apps, cutoff=0.7)
        if not did:
            # not an app we know: let the sentence go on to the Claude fallback instead of a dead end
            log("no app for:", q)
            return None
        self.watch_launch()
        spawn(["uwsm", "app", "--", did])
        res["app"] = self.desktop.app_labels.get(did, did)
        return res

    def _project(self, name: str, with_: str, res: dict) -> dict:
        path = fuzzy(name, self.desktop.projects, cutoff=0.6)
        if not path:
            res["ok"] = False
            res["say"] = f"Não achei o projeto {name}."
            return res
        term = self.cfg["terminal"]
        title = Path(path).name
        self.watch_launch()
        if with_ == "claude":
            spawn([term, "-D", path, "-T", f"Claude: {title}", "claude"])
        elif with_ == "nvim":
            spawn([term, "-D", path, "-T", title, "-e", "nvim", "."])
        elif with_ == "files":
            spawn(["xdg-open", path])
        else:
            spawn([term, "-D", path, "-T", title])
        res["project"] = title
        return res


# ---------------------------------------------------------------- the daemon

class Voice:
    def __init__(self):
        self.cfg = dict(DEFAULTS)
        try:
            self.cfg.update(json.loads((HERE / "config.json").read_text()))
        except (OSError, json.JSONDecodeError) as e:
            log("config.json not used:", e)
        if os.environ.get("BARCH_VOICE_DEBUG") == "1":
            self.cfg["debug"] = True
        for k in ("XDG_RUNTIME_DIR",):
            os.environ.setdefault(k, str(RUNTIME))
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self.state = {"state": "starting", "heard": "", "said": "", "time": time.time(), "paused": False,
                      "whisper": False, "tts": False, "model": ""}
        self.language = self._load_language()   # what whisper listens in: a code of languages.json, or "auto"
        self.downloading = ""                    # the Piper voice being downloaded for it
        self.statelock = threading.Lock()
        self.paused = False
        self.playing_until = 0.0
        self.awaiting_until = 0.0        # after "barch" alone, or during the follow-up window after an answer
        self.followup = False            # the awaiting window is a follow-up (room talk must not reach Claude)
        self.last_claude = 0.0           # when Claude answered last: a follow-up to that may go to him again
        self.stop_event = threading.Event()
        self.whisper = Whisper(self.cfg)
        self.speaker = Speaker(self.cfg, self._busy)
        self.desktop = Desktop(self.cfg)
        self.intents = Intents(self.cfg, self.desktop, self.speaker, self.ask_claude)
        self.capture = None
        self.worklock = threading.Lock()
        self.write_state("starting")

    # -- language
    def _load_language(self) -> str:
        try:
            code = LANG_FILE.read_text().strip()
        except OSError:
            code = str(self.cfg.get("language") or "pt")
        return code if code in LANGUAGES else "pt"

    def set_language(self, code: str) -> dict:
        code = (code or "").strip().lower()
        if code not in LANGUAGES:
            return {"ok": False, "error": f"unknown language {code!r} (voice.py languages lists them)"}
        self.language = code
        atomic_write(LANG_FILE, code + "\n")
        log("language:", code)
        self.ensure_voice(code)
        self.write_state()
        return {"ok": True, **self.language_info()}

    def ensure_voice(self, code: str):
        """Download the Piper voice of a language in the background the first time it is picked."""
        # auto: the two he speaks; any other detected language speaks if its voice is there
        for c in (["pt", "en"] if code == "auto" else [code]):
            v = self.speaker.voice_for(c)
            if v and self.speaker.piper and not self.speaker.voice_model(v) and not self.downloading:
                def work(v=v):
                    self.downloading = v
                    self.write_state()
                    try:
                        self.speaker.download(v)
                    finally:
                        self.downloading = ""
                        self.write_state()
                threading.Thread(target=work, daemon=True).start()
                return

    def language_info(self) -> dict:
        e = LANGUAGES.get(self.language, {})
        voice = self.speaker.voice_for(self.language) if self.language != "auto" else ""
        return {"language": self.language, "language_name": e.get("name", self.language),
                "language_native": e.get("native", ""), "voice": voice,
                "voice_ready": self.speaker.has(self.language) if self.language != "auto" else self.speaker.available,
                "downloading": self.downloading}

    # -- state for the bar
    def write_state(self, state=None, **kw):
        with self.statelock:           # the voice download thread writes it too (same .tmp file)
            self._write_state(state, **kw)

    def _write_state(self, state=None, **kw):
        if state:
            self.state["state"] = state
        self.state.update(kw)
        self.state["time"] = time.time()
        self.state["paused"] = self.paused
        self.state["whisper"] = self.whisper.available
        self.state["tts"] = self.speaker.available
        self.state["model"] = Path(self.whisper.model).name if self.whisper.model else ""
        self.state.update(self.language_info())
        try:
            atomic_write(STATE_FILE, json.dumps(self.state))
        except OSError as e:
            log("state:", e)

    def _busy(self, on: bool):
        self.playing_until = float("inf") if on else time.time() + 0.3

    # -- audio
    def _capture_cmd(self):
        # no media.role: "Communication" makes WirePlumber route the stream to another source (the
        # onboard line-in here), not the default microphone. --raw: no WAV header on the pipe.
        cmd = ["pw-record", "-P", '{ application.name = "barch-voice" node.name = "barch-voice" }',
               "--rate", str(RATE), "--channels", "1", "--format", "s16", "--raw"]
        if self.cfg["mic_target"]:
            cmd += ["--target", self.cfg["mic_target"]]
        return cmd + ["-"]

    def listen(self):
        """Capture loop: VAD → utterances → worker."""
        start_frames = int(self.cfg["vad_start_frames"])
        end_frames = int(self.cfg["vad_end_ms"] / 20)
        preroll = int(self.cfg["vad_preroll_ms"] / 20)
        max_frames = int(self.cfg["utterance_max_s"] * 50)
        min_frames = int(self.cfg["utterance_min_ms"] / 20)
        mult = float(self.cfg["vad_floor_mult"])
        min_rms = float(self.cfg["vad_min_rms"])
        while not self.stop_event.is_set():
            try:
                self.capture = subprocess.Popen(self._capture_cmd(), stdout=subprocess.PIPE, stdin=subprocess.DEVNULL,
                                                stderr=subprocess.PIPE, bufsize=0)
            except OSError as e:
                log("pw-record:", e)
                self.write_state("error", error=str(e))
                time.sleep(5)
                continue
            if self.state["state"] in ("starting", "error"):
                self.write_state("listening", error="")
            floor = None
            ring: list[bytes] = []
            utter: list[bytes] = []
            speech_run = 0
            silence_run = 0
            in_speech = False
            recent = []
            out = self.capture.stdout
            while not self.stop_event.is_set():
                buf = read_exact(out, BYTES_PER_FRAME)     # pipe reads come in odd sizes
                if buf is None:
                    break
                if time.time() < self.playing_until or self.paused:
                    # our own voice, or paused: keep the floor, drop the audio
                    in_speech, utter, speech_run, silence_run = False, [], 0, 0
                    continue
                x = np.frombuffer(buf, dtype=np.int16).astype(np.float32)
                rms = float(np.sqrt(np.mean(x * x))) if len(x) else 0.0
                if floor is None:
                    floor = max(rms, 30.0)
                thr = max(floor * mult, min_rms)
                is_speech = rms > thr
                recent.append(is_speech)
                if len(recent) > 6:
                    recent.pop(0)
                if not in_speech:
                    if not is_speech:
                        # the noise floor follows the room: down fast, up slowly (a click or the
                        # first frames must not lift the threshold for long)
                        a = 0.1 if rms < floor else 0.02
                        floor = max(30.0, floor * (1 - a) + rms * a)
                    ring.append(buf)
                    if len(ring) > preroll:
                        ring.pop(0)
                    if sum(recent) >= start_frames:
                        in_speech = True
                        utter = ring[:]
                        silence_run = 0
                        if self.awaiting_until > time.time():
                            self.write_state("hearing")
                else:
                    utter.append(buf)
                    silence_run = 0 if is_speech else silence_run + 1
                    if silence_run >= end_frames or len(utter) >= max_frames:
                        pcm = b"".join(utter[: len(utter) - max(0, silence_run - 10)])
                        in_speech, utter, recent = False, [], []
                        if self.cfg["debug"]:
                            log(f"utterance: {len(pcm) / RATE / 2:.2f}s rms_floor={floor:.0f} thr={thr:.0f}")
                        if len(pcm) // BYTES_PER_FRAME >= min_frames:
                            threading.Thread(target=self.process, args=(pcm,), daemon=True).start()
            err = b""
            try:
                if self.capture.poll() is None:
                    self.capture.terminate()
                err = self.capture.stderr.read() if self.capture.stderr else b""
            except Exception:  # noqa: BLE001
                pass
            if not self.stop_event.is_set():
                log("capture ended:", err.decode(errors="replace").strip()[-200:])
                self.write_state("error", error="microphone capture ended; retrying")
                time.sleep(3)

    # -- one sentence
    def wake_in(self, text: str) -> tuple[bool, str]:
        """Does the sentence start with the wake word? Returns (yes, the rest)."""
        t = normalize(text)
        if not t:
            return False, ""
        words = t.split()
        wake = self.cfg["wake"]
        ratio = float(self.cfg["wake_min_ratio"])
        for n in (1, 2):
            if len(words) < n:
                break
            head = "".join(words[:n])
            best = max((difflib.SequenceMatcher(None, head, w).ratio() for w in wake), default=0)
            if head in wake or best >= ratio or (n == 1 and head.startswith("bar") and len(head) <= 6):
                return True, " ".join(words[n:])
        # "e aí barch", "ô barch": the wake word as the second word
        if len(words) >= 2 and words[0] in ("e", "ai", "o", "oi", "ei", "hey", "ola", "oh"):
            yes, rest = self.wake_in(" ".join(words[1:]))
            if yes:
                return True, rest
        return False, ""

    def process(self, pcm: bytes):
        with self.worklock:
            try:
                self._process(pcm)
            except Exception as e:  # noqa: BLE001
                log("process failed:", e)
                self.write_state("listening")

    def hallucinated(self, text: str) -> bool:
        """whisper's answers to silence: the prompt itself, 'Obrigado', subtitle credits."""
        t = normalize(text)
        if not t:
            return False
        prompt = {normalize(x) for x in re.split(r"[.!?]", self.cfg["whisper_prompt"]) if normalize(x)}
        return t in prompt or t in HALLUCINATIONS

    def _process(self, pcm: bytes):
        if not self.whisper.available:
            self.write_state("error", error="whisper.cpp or its model is missing")
            return
        now = time.time()
        awaiting = now < self.awaiting_until
        head_bytes = int(float(self.cfg["head_s"]) * RATE) * 2
        followup = awaiting and self.followup
        chosen = self.language
        # the wake word is looked for in Latin letters: in the chosen language when whisper writes it
        # that way, else in English ("барч" would never match); auto: Portuguese, and the language
        # whisper detects there is the one the whole sentence is transcribed in
        head_lang = "pt" if chosen == "auto" else chosen if (LANGUAGES.get(chosen) or {}).get("latin") else "en"
        lang = chosen
        raw = ""
        alone = False
        if awaiting:
            text = self.whisper.transcribe(pcm, "auto" if chosen == "auto" else chosen)
            lang = self.whisper.detected if chosen == "auto" else chosen
            if self.hallucinated(text):
                log("dropped (whisper hallucination):", text.strip())
                return
            yes, rest = self.wake_in(text)
            command = rest if yes else normalize(text)
            raw = text
            if yes:
                followup = False             # he said "barch": a normal command, whatever came before
            self.write_state("processing")
        else:
            t0 = time.time()
            head = self.whisper.transcribe(pcm[:head_bytes], head_lang)
            if chosen == "auto":
                lang = self.whisper.detected
            yes, rest = self.wake_in(head)
            if self.cfg["debug"]:
                log(f"heard ({time.time() - t0:.2f}s, {head_lang}→{lang}): {head!r} wake={yes}")
            if not yes or self.hallucinated(head):
                return
            alone = len(pcm) <= head_bytes and not rest.strip(" ,.!?")   # "barch" and nothing else
            self.write_state("processing", heard="…")
            if len(pcm) > head_bytes or lang != head_lang:
                full = self.whisper.transcribe(pcm, lang)
                if self.hallucinated(full):
                    log("dropped (whisper hallucination):", full.strip())
                    self.write_state("listening")
                    return
                yes2, rest2 = self.wake_in(full)
                command = rest2 if yes2 else normalize(full)
                raw = full
            else:
                command = rest
                raw = head
        if lang not in LANGUAGES or lang == "auto":
            lang = "pt"
        if lang != "pt":
            # no command table outside Portuguese: Claude gets the sentence as whisper wrote it
            # (normalize() keeps only a-z), wake word included; empty only when nothing follows it
            latin = (LANGUAGES.get(lang) or {}).get("latin")
            if raw.strip() and (command.strip(" ,.!?") or (not latin and not (not awaiting and alone))):
                command = raw.strip()
        self.awaiting_until = 0
        self.followup = False
        command = strip_fillers(command.strip(" ,.!?"))
        if not command:
            if followup:
                self.open_followup()
                return
            # "barch" alone: a chime, and the next sentence is the command
            self.awaiting_until = time.time() + float(self.cfg["wake_window_s"])
            self.write_state("wake", heard="")
            self.speaker.chime("wake")
            threading.Timer(float(self.cfg["wake_window_s"]) + 0.5, self._wake_timeout).start()
            return
        log(("command" if not followup else "follow-up") + (f" [{lang}]:" if lang != "pt" else ":"), command)
        self.write_state("processing", heard=command)
        self.run_text(command, followup=followup, lang=lang)

    def _wake_timeout(self):
        if self.state["state"] in ("wake", "followup") and time.time() >= self.awaiting_until:
            self.followup = False
            self.write_state("listening")

    def open_followup(self, seconds: float | None = None):
        """The next sentence needs no "barch": a conversation, like answering "sim" or saying "mais"."""
        secs = float(self.cfg["followup_s"]) if seconds is None else seconds
        if secs <= 0 or self.paused:
            return
        self.awaiting_until = time.time() + secs
        self.followup = True
        self.write_state("followup")
        threading.Timer(secs + 0.5, self._wake_timeout).start()

    def run_text(self, command: str, followup: bool = False, lang: str = "pt") -> dict:
        if self.desktop.locked():
            log("ignored (session locked):", command)
            self.write_state("listening", heard="")
            return {"matched": False, "say": "", "locked": True}
        if lang == "pt":
            res = self.intents.handle(command)
        else:
            res = self.intents.answer_pending(command, lang) or {"matched": False}
        if not res.get("matched"):
            talking_to_claude = time.time() - self.last_claude < 60 and (len(command.split()) >= 2 or lang != "pt")
            if followup and not talking_to_claude:
                # a follow-up window catches whatever is said in the room: without a command in it, drop it
                log("follow-up ignored (no command):", command)
                self.write_state("listening", heard="")
                return {"matched": False, "say": "", "ignored": True}
            if self.cfg["claude"] and shutil.which("claude"):
                res = self.ask_claude(command, lang=lang)
            else:
                res = {"matched": False, "say": msg(lang, "unknown")}
            with UNMATCHED.open("a") as f:
                f.write(f"{datetime.now():%Y-%m-%d %H:%M} | {command} | {res.get('say', '')[:120]}\n")
        with HISTORY.open("a") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} | {command} | {res.get('intent', '-')} | {res.get('say', '')[:160]}\n")
        say = (res.get("say") or "").strip()
        self.intents.note(command, say)
        if res.get("intent") in ("claude", "confirm") and "cost" in res:
            self.last_claude = time.time()
        if res.get("action") == "pause":
            self.set_paused(True)
        if say:
            self.write_state("speaking", heard=command, said=say)
            if not self.speaker.say(say, lang) and lang != "pt":
                # no voice for this language (yet): the answer as a notification
                subprocess.Popen([str(BARCH), "notify", "Voice", say, "--app", "barch-voice"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif res.get("sound", "default") is not None and self.cfg["confirm_sound"]:
            self.speaker.chime("ok" if res.get("ok", True) else "fail")
        self.write_state("listening", heard=command, said=say)
        if res.get("intent") == "confirm":
            self.open_followup(15)           # "Confirma?" waits for the "sim" without a "barch"
        elif res.get("action") != "pause":
            self.open_followup()
        return res

    # -- Claude fallback
    def ask_claude(self, question: str, confirmed: bool = False, lang: str = "pt") -> dict:
        self.write_state("thinking", heard=question)
        prompt_file = HERE / "fallback.md"
        try:
            prompt = prompt_file.read_text()
        except OSError:
            prompt = "You control Bruno's Hyprland desktop through the `barch` CLI. Answer in one short Portuguese sentence in `say`."
        win = self.desktop.active_window()
        last = next((c for c in self.desktop.clients() if c.get("address") == self.intents.window), None)
        e = LANGUAGES.get(lang) or {}
        ctx = {
            "heard": question,
            "language": "Brazilian Portuguese" if lang == "pt" else f"{e.get('name', lang)} ({lang})",
            "confirmed": confirmed,
            "time": datetime.now().strftime("%A %Y-%m-%d %H:%M"),
            "active_window": {"class": win.get("class"), "title": win.get("title"),
                              "workspace": (win.get("workspace") or {}).get("name")},
            "last_window": {"address": last.get("address"), "class": last.get("class"), "title": last.get("title")} if last else None,
            "recent": [{"heard": h, "said": s} for h, s in self.intents.history],
            "projects": sorted(Path(p).name for p in set(self.desktop.projects.values()))[:40],
        }
        schema = json.dumps({"type": "object", "properties": {"say": {"type": "string"}, "done": {"type": "boolean"},
                                                              "confirm": {"type": "string"}},
                             "required": ["say", "done"]})
        cmd = ["claude", "-p", "--output-format", "json", "--permission-mode", "dontAsk", "--strict-mcp-config",
               "--json-schema", schema, "--disallowedTools", "Edit", "Write", "NotebookEdit",
               "--allowedTools", *self.cfg["claude_tools"]]
        if self.cfg["claude_model"]:
            cmd += ["--model", self.cfg["claude_model"]]
        full = prompt + "\n\n## Agora\n\n```json\n" + json.dumps(ctx, ensure_ascii=False, indent=2) + "\n```\n"
        env = dict(os.environ, BARCH_VOICE="1")
        try:
            r = subprocess.run(cmd, input=full, capture_output=True, text=True, cwd=str(HOME),
                               timeout=float(self.cfg["claude_timeout_s"]), env=env)
            data = json.loads(r.stdout) if r.stdout.strip() else {}
        except subprocess.TimeoutExpired:
            return {"matched": False, "say": msg(lang, "slow"), "intent": "claude"}
        except (json.JSONDecodeError, OSError) as err:
            log("claude:", err)
            return {"matched": False, "say": msg(lang, "noanswer"), "intent": "claude"}
        out = data.get("structured_output") or {}
        if data.get("is_error") or not out:
            msg = str(data.get("result") or r.stderr or "")[:200]
            log("claude error:", msg)
            if "authenticate" in msg.lower() or "login" in msg.lower():
                return {"matched": False, "say": msg(lang, "login"), "intent": "claude"}
            return {"matched": False, "say": msg(lang, "failed"), "intent": "claude"}
        log(f"claude: {out.get('say')!r} confirm={out.get('confirm')!r} cost={data.get('total_cost_usd')}")
        if data.get("total_cost_usd") is not None:
            try:  # one line per call, what `barch metrics summary` adds up
                with (STATE_DIR.parent / "claude-cost.log").open("a") as f:
                    f.write(f"{int(time.time())} voice {data['total_cost_usd']} {question[:100]}\n")
            except OSError:
                pass
        if out.get("confirm") and not confirmed:
            # something risky: say what it would do and wait for the "sim" (then ask again, confirmed)
            what = out["confirm"].strip().rstrip(".") + "."
            res = self.intents.confirm(what, lambda: self.ask_claude(question, confirmed=True, lang=lang), lang)
            res["intent"] = "confirm"
            res["cost"] = data.get("total_cost_usd")
            return res
        return {"matched": True, "say": out.get("say", ""), "intent": "claude", "ok": bool(out.get("done", True)),
                "cost": data.get("total_cost_usd")}

    # -- control socket
    def set_paused(self, on: bool):
        self.paused = on
        self.awaiting_until = 0
        self.write_state("paused" if on else "listening")

    def serve(self):
        try:
            SOCKET.unlink()
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(SOCKET))
        os.chmod(SOCKET, 0o600)
        srv.listen(4)
        srv.settimeout(1.0)
        while not self.stop_event.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._client, args=(conn,), daemon=True).start()
        srv.close()
        try:
            SOCKET.unlink()
        except FileNotFoundError:
            pass

    def _client(self, conn: socket.socket):
        with conn:
            conn.settimeout(600)
            try:
                data = conn.makefile("r").readline()
                req = json.loads(data) if data.strip() else {}
            except (OSError, json.JSONDecodeError) as e:
                conn.sendall(json.dumps({"ok": False, "error": str(e)}).encode() + b"\n")
                return
            try:
                ans = self.command(req)
            except Exception as e:  # noqa: BLE001
                ans = {"ok": False, "error": str(e)}
            try:
                conn.sendall(json.dumps(ans, ensure_ascii=False).encode() + b"\n")
            except OSError:
                pass

    def command(self, req: dict) -> dict:
        c = req.get("cmd")
        if c == "status":
            return {"ok": True, **self.state, "socket": str(SOCKET), "intents": len(self.intents.rules)}
        if c == "say":
            text = req.get("text", "")
            if not self.speaker.available:
                return {"ok": False, "error": "piper-tts (and pw-play) is not installed: nothing can be spoken"}
            self.write_state("speaking", said=text)
            ok = self.speaker.say(text)
            self.write_state("paused" if self.paused else "listening")
            return {"ok": ok, "said": text, "error": "" if ok else "piper failed (see barch voice log)"}
        if c == "run":
            lang = self.language if self.language != "auto" else "pt"
            text = req.get("text", "")
            with self.worklock:
                res = self.run_text(strip_fillers(normalize(text)) if lang == "pt" else text.strip(), lang=lang)
            return {"ok": res.get("ok", res.get("matched", False)), **res}
        if c == "pause":
            self.set_paused(True)
            return {"ok": True, "paused": True}
        if c == "resume":
            self.set_paused(False)
            return {"ok": True, "paused": False}
        if c == "toggle":
            self.set_paused(not self.paused)
            return {"ok": True, "paused": self.paused}
        if c == "language":
            if req.get("code"):
                return self.set_language(req["code"])
            return {"ok": True, **self.language_info()}
        if c == "reload":
            self.intents.load()
            self.desktop.refresh(force=True)
            return {"ok": True, "intents": len(self.intents.rules)}
        if c == "stop":
            threading.Thread(target=self.shutdown, daemon=True).start()
            return {"ok": True}
        return {"ok": False, "error": f"unknown command {c!r}"}

    # -- lifecycle
    def shutdown(self, *_):
        if self.stop_event.is_set():
            return
        self.stop_event.set()
        try:
            if self.capture and self.capture.poll() is None:
                self.capture.terminate()
        except Exception:  # noqa: BLE001
            pass
        self.whisper.stop()
        self.write_state("off")

    def main(self):
        if np is None:
            log("python-numpy is missing")
            self.write_state("error", error="python-numpy is missing")
            return 1
        signal.signal(signal.SIGTERM, self.shutdown)
        signal.signal(signal.SIGINT, self.shutdown)
        log("whisper:", self.whisper.model or "no model", "| piper:", "yes" if self.speaker.available else "no",
            "| claude:", "on" if self.cfg["claude"] else "off")
        if not self.whisper.available:
            self.write_state("error", error="whisper.cpp or its model is missing (see README: Voice)")
        self.whisper.start()
        self.ensure_voice(self.language)
        threading.Thread(target=self.serve, daemon=True).start()
        self.desktop.refresh(force=True)
        try:
            self.listen()
        finally:
            self.shutdown()
        return 0


# ---------------------------------------------------------------- client

def match(argv: list[str]) -> int:
    """voice.py match "sentence": which intent would run, without the daemon and without running it."""
    if not argv:
        print("usage: voice.py match <text>", file=sys.stderr)
        return 2
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads((HERE / "config.json").read_text()))
    except (OSError, json.JSONDecodeError):
        pass
    desktop = Desktop(cfg)
    desktop.refresh(force=True)
    intents = Intents(cfg, desktop, None, lambda q: {"matched": False, "say": "", "intent": "claude", "question": q})
    intents.dry = True
    res = intents.handle(" ".join(argv))
    if not res.get("matched"):
        res = {"matched": False, "intent": "claude" if cfg["claude"] else None, "normalized": strip_fillers(normalize(" ".join(argv)))}
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res.get("matched") else 1


def languages() -> int:
    """voice.py languages: every language with its voice and whether that voice is downloaded."""
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads((HERE / "config.json").read_text()))
    except (OSError, json.JSONDecodeError):
        pass
    sp = Speaker.__new__(Speaker)
    sp.cfg, sp.dir = cfg, Path(cfg["tts_dir"]).expanduser()
    out = []
    for code, e in LANGUAGES.items():
        v = sp.voice_for(code) if code != "auto" else ""
        out.append({"code": code, "name": e.get("name"), "native": e.get("native"), "voice": v or None,
                    "downloaded": bool(v and sp.voice_model(v)), "commands": code == "pt"})
    print(json.dumps({"ok": True, "languages": out}, ensure_ascii=False))
    return 0


def client(argv: list[str]) -> int:
    cmd = argv[0]
    req = {"cmd": cmd}
    if cmd == "language" and len(argv) > 1:
        req["code"] = argv[1]
    if cmd in ("say", "run"):
        if len(argv) < 2:
            print(f"usage: voice.py {cmd} <text>", file=sys.stderr)
            return 2
        req["text"] = " ".join(argv[1:])
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(float(os.environ.get("BARCH_VOICE_TIMEOUT", "180")))
            s.connect(str(SOCKET))
            s.sendall(json.dumps(req).encode() + b"\n")
            data = s.makefile("r").readline()
    except (OSError, ConnectionError) as e:
        print(json.dumps({"ok": False, "error": f"barch-voice is not running ({e})"}))
        return 3
    print(data.strip())
    try:
        return 0 if json.loads(data).get("ok") else 1
    except json.JSONDecodeError:
        return 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("status", "say", "run", "pause", "resume", "toggle", "reload", "stop", "language"):
        sys.exit(client(sys.argv[1:]))
    if len(sys.argv) > 1 and sys.argv[1] == "languages":
        sys.exit(languages())
    if len(sys.argv) > 1 and sys.argv[1] == "match":
        sys.exit(match(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] not in ("daemon",):
        print(__doc__)
        sys.exit(2)
    sys.exit(Voice().main())
