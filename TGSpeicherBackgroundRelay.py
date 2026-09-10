#!/usr/bin/env python3
"""TGSpeicher Background Relay 2.2 — zero-CLI single-file VPS relay.

Start in AMP with exactly:
    python3 TGSpeicherBackgroundRelay.py

Listener:   0.0.0.0:8765
Public URL: https://backup.rjuhas.eu
State:      ~/.tgspeicher-relay/

On first start the HTTP server comes up immediately. Open the public URL,
log in with the preconfigured bootstrap dashboard password, and finish setup
(API ID/hash, phone and Telegram target) in the browser. No terminal setup or
restart is required. Telegram login / 2FA and iPhone pairing are also web based.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import hashlib
import html
import hmac
import json
import mimetypes
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, quote, unquote, urlparse

APP = "TGSpeicher Background Relay"
VERSION = "2.2.0"
HOST = os.environ.get("TGS_RELAY_BIND", "0.0.0.0")
PORT = int(os.environ.get("TGS_RELAY_PORT", "8765"))
PUBLIC = "https://backup.rjuhas.eu"
HOME = Path(os.environ.get("TGS_RELAY_HOME", str(Path.home() / ".tgspeicher-relay"))).expanduser()
CONFIG = HOME / "tgs_relay_config.json"
DB = HOME / "relay.sqlite3"
SPOOL = HOME / "uploads"
SESSION = HOME / "tgs_relay"
BLOCK = 1024 * 1024
TG_PART = 1_900_000_000
PASSWORD_ROUNDS = 600_000
# Salted PBKDF2 hash only; the plaintext bootstrap password is not stored here.
BOOTSTRAP_PASSWORD_HASH = "pbkdf2_sha256$600000$NmIgArnXK3VZ2QDS-gN7rg$raG7yIw6qjFr7ojb5ZBEXhwAKc64gaarJJZd2JnHZ4o"

STOP = threading.Event()
WORKER = None
WORKER_LOCK = threading.RLock()
LOGIN_LOCK = threading.Lock()
LOGIN_FAILS: dict[str, list[float]] = {}
TelegramClient = None
errors = None
utils = None


def now():
    return time.time()


def iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def log(message):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)


def priv(path):
    with contextlib.suppress(Exception):
        os.chmod(path, 0o600)


def shash(value):
    return hashlib.sha256(str(value).encode()).hexdigest()


def phash(password):
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PASSWORD_ROUNDS)
    enc = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
    return f"pbkdf2_sha256${PASSWORD_ROUNDS}${enc(salt)}${enc(digest)}"


def pverify(password, stored):
    try:
        algorithm, rounds, salt, digest = stored.split("$", 3)
        dec = lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
        candidate = hashlib.pbkdf2_hmac("sha256", password.encode(), dec(salt), int(rounds))
        return algorithm == "pbkdf2_sha256" and hmac.compare_digest(candidate, dec(digest))
    except Exception:
        return False


def telethon():
    global TelegramClient, errors, utils
    if TelegramClient:
        return
    try:
        from telethon import TelegramClient as C, errors as E, utils as U
    except ModuleNotFoundError:
        log("Telethon fehlt; installiere Telethon 1.44.0 …")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "Telethon==1.44.0"])
        from telethon import TelegramClient as C, errors as E, utils as U
    TelegramClient, errors, utils = C, E, U


DEFAULT = {
    "bind_host": HOST,
    "port": PORT,
    "public_base_url": PUBLIC,
    "api_id": 0,
    "api_hash": "",
    "phone": "",
    "telegram_target": "me",
    "web_password_hash": "",
    "setup_complete": False,
    "max_upload_bytes": 50 * 1024**3,
    "telegram_part_bytes": TG_PART,
    "delete_after_success": True,
    "prefer_native_media": True,
    "retry_base_seconds": 15,
    "retry_max_seconds": 1800,
    "spool_reserve_bytes": 2 * 1024**3,
}


def save_cfg(cfg):
    HOME.mkdir(parents=True, exist_ok=True)
    os.chmod(HOME, 0o700)
    tmp = CONFIG.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
    priv(tmp)
    os.replace(tmp, CONFIG)
    priv(CONFIG)


def load_cfg():
    cfg = dict(DEFAULT)
    if CONFIG.exists():
        try:
            saved = json.loads(CONFIG.read_text())
            if isinstance(saved, dict):
                cfg.update(saved)
                if "setup_complete" not in saved and int(cfg.get("api_id") or 0) > 0 and cfg.get("api_hash") and cfg.get("web_password_hash"):
                    cfg["setup_complete"] = True
        except Exception as exc:
            log(f"Konfiguration unlesbar, starte Web-Recovery-Setup: {exc}")
    cfg["bind_host"] = HOST
    cfg["port"] = PORT
    cfg["public_base_url"] = PUBLIC
    return cfg


def configured(cfg):
    return bool(
        cfg.get("setup_complete")
        and int(cfg.get("api_id") or 0) > 0
        and str(cfg.get("api_hash") or "").strip()
        and str(cfg.get("web_password_hash") or "").strip()
    )


def conn():
    HOME.mkdir(parents=True, exist_ok=True)
    SPOOL.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DB, timeout=30, check_same_thread=False)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    return db


def init_db():
    with conn() as db:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS uploads(
              id TEXT PRIMARY KEY, resource_key TEXT, asset_id TEXT, resource_type TEXT,
              filename TEXT NOT NULL, media_kind TEXT NOT NULL, creation_date TEXT,
              path TEXT NOT NULL, size INTEGER NOT NULL DEFAULT 0, sha256 TEXT,
              state TEXT NOT NULL, received REAL NOT NULL, updated REAL NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0,
              last_error TEXT, message_ids TEXT, target TEXT, device_id TEXT
            );
            CREATE INDEX IF NOT EXISTS uploads_next ON uploads(state,next_attempt,received);
            CREATE INDEX IF NOT EXISTS uploads_resource ON uploads(resource_key);
            CREATE TABLE IF NOT EXISTS devices(
              id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
              created REAL NOT NULL, last_seen REAL NOT NULL, last_upload REAL,
              revoked INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS pairing(
              code_hash TEXT PRIMARY KEY, label TEXT, expires REAL NOT NULL, used REAL
            );
            CREATE TABLE IF NOT EXISTS web_sessions(
              token_hash TEXT PRIMARY KEY, csrf TEXT NOT NULL, expires REAL NOT NULL,
              last_seen REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS events(
              id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL,
              kind TEXT NOT NULL, message TEXT NOT NULL
            );
            """
        )
        db.execute(
            "UPDATE uploads SET state='retry',next_attempt=0,"
            "last_error=COALESCE(last_error,'Relay-Neustart während Telegram-Upload') "
            "WHERE state='uploading'"
        )
        db.execute("DELETE FROM web_sessions WHERE expires<?", (now(),))
        db.commit()
    priv(DB)


def event(kind, message):
    with conn() as db:
        db.execute("INSERT INTO events(at,kind,message) VALUES(?,?,?)", (now(), kind[:30], message[:1000]))
        db.execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 500)")
        db.commit()


def one(query, args=()):
    with conn() as db:
        return db.execute(query, args).fetchone()


def rows(query, args=()):
    with conn() as db:
        return [dict(row) for row in db.execute(query, args).fetchall()]


def execute(query, args=()):
    with conn() as db:
        db.execute(query, args)
        db.commit()


def counts():
    result = {str(x["state"]): int(x["c"]) for x in rows("SELECT state,COUNT(*) c FROM uploads GROUP BY state")}
    result["total"] = sum(result.values())
    return result


def pairing(label):
    code = "-".join(f"{secrets.randbelow(1000):03d}" for _ in range(3))
    execute("INSERT INTO pairing(code_hash,label,expires,used) VALUES(?,?,?,NULL)", (shash(code), label[:80], now() + 600))
    event("pairing", f"Pairing-Code für {label}")
    return code


def pair_exchange(code, name):
    code_hash = shash(code.strip())
    row = one("SELECT * FROM pairing WHERE code_hash=? AND used IS NULL AND expires>?", (code_hash, now()))
    if not row:
        return None
    token = secrets.token_urlsafe(48)
    device_id = uuid.uuid4().hex
    with conn() as db:
        db.execute(
            "INSERT INTO devices(id,name,token_hash,created,last_seen,last_upload,revoked) VALUES(?,?,?,?,?,NULL,0)",
            (device_id, (name or row["label"] or "iPhone")[:100], shash(token), now(), now()),
        )
        db.execute("UPDATE pairing SET used=? WHERE code_hash=?", (now(), code_hash))
        db.commit()
    event("device", f"Gekoppelt: {name or 'iPhone'}")
    return device_id, token


def device(token, touch=False, upload=False):
    if not token:
        return None
    row = one("SELECT * FROM devices WHERE token_hash=? AND revoked=0", (shash(token),))
    if row and touch:
        execute(
            "UPDATE devices SET last_seen=?,last_upload=CASE WHEN ? THEN ? ELSE last_upload END WHERE id=?",
            (now(), 1 if upload else 0, now(), row["id"]),
        )
    return row


def web_issue():
    token = secrets.token_urlsafe(48)
    csrf = secrets.token_urlsafe(24)
    execute("INSERT INTO web_sessions(token_hash,csrf,expires,last_seen) VALUES(?,?,?,?)", (shash(token), csrf, now() + 7 * 86400, now()))
    return token, csrf


def web_get(token):
    row = one("SELECT * FROM web_sessions WHERE token_hash=? AND expires>?", (shash(token), now())) if token else None
    if row:
        execute("UPDATE web_sessions SET last_seen=? WHERE token_hash=?", (now(), shash(token)))
    return row


def clean_name(value):
    return (re.sub(r"[\r\n\\/]", "_", os.path.basename((value or "Upload.bin").replace("\0", ""))).strip()[:240] or "Upload.bin")


def media_kind(value, name):
    value = (value or "").lower()
    if value in {"photo", "video", "file"}:
        return value
    mime = mimetypes.guess_type(name)[0] or ""
    return "photo" if mime.startswith("image/") else "video" if mime.startswith("video/") else "file"


def target(value):
    value = str(value or "me").strip()
    if value.lower() in {"me", "self", "saved", "savedmessages"}:
        return "me"
    return int(value) if re.fullmatch(r"-?\d+", value) else value


def stable_uuid(sha, chat):
    raw = bytearray(hashlib.sha256(f"TGSpeicher.media.v3|{chat}|{sha}".encode()).digest()[:16])
    raw[6] = (raw[6] & 15) | 80
    raw[8] = (raw[8] & 63) | 128
    return str(uuid.UUID(bytes=bytes(raw))).upper()


def marker(resource, sha, uid):
    return "tgsbg_" + hashlib.sha256((resource or sha or uid).encode()).hexdigest()[:24]


def manifest(row, chat, kind, index, count, part_sha, mark):
    date = row["creation_date"] or iso()
    sha = str(row["sha256"] or "")
    obj = {
        "format": 3 if kind.startswith("native") else 2,
        "kind": kind,
        "fileID": stable_uuid(sha, chat),
        "folderID": None,
        "parentFolderID": None,
        "name": row["filename"],
        "originalSize": int(row["size"]),
        "chunkIndex": index,
        "chunkCount": count,
        "createdAt": date,
        "tagIDs": [],
        "sha256": part_sha if kind == "fileChunk" else None,
        "sourceKey": row["resource_key"],
        "mediaKind": row["media_kind"],
        "assetLocalIdentifier": row["asset_id"],
        "resourceTypeRawValue": int(row["resource_type"]) if str(row["resource_type"] or "").lstrip("-").isdigit() else None,
        "mediaCreationDate": date if row["creation_date"] else None,
    }
    encoded = base64.b64encode(json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()).decode()
    return f"#TGSpeicherV2 {encoded}\n#TGSpeicherBackgroundV2 {mark}"


def decoded(text):
    match = re.search(r"#TGSpeicherV2\s+([A-Za-z0-9+/=]+)", text or "")
    try:
        return json.loads(base64.b64decode(match.group(1))) if match else None
    except Exception:
        return None


@dataclass
class State:
    connected: bool = False
    account: str = ""
    target_name: str = ""
    target_id: Optional[int] = None
    premium: Optional[bool] = None
    auth: str = "not_authorized"
    error: str = ""
    active_file: str = ""
    active_sent: int = 0
    active_total: int = 0
    last_activity: float = 0


STATE = State()
STATE_LOCK = threading.Lock()


def snapshot():
    with STATE_LOCK:
        return dict(STATE.__dict__)


class TgWorker(threading.Thread):
    def __init__(self, cfg):
        super().__init__(daemon=True, name="TGSpeicher-Telegram")
        self.cfg = cfg
        self.loop = None
        self.client = None
        self.ready = threading.Event()
        self.phone = str(cfg.get("phone") or "")

    def run(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        try:
            telethon()
            self.client = TelegramClient(str(SESSION), int(self.cfg["api_id"]), str(self.cfg["api_hash"]))
            self.loop.run_until_complete(self.client.connect())
            priv(SESSION.with_suffix(".session"))
            self.ready.set()
            self.loop.run_until_complete(self.main())
        except Exception as exc:
            self.ready.set()
            with STATE_LOCK:
                STATE.error = str(exc)
                STATE.connected = False
            log(f"Telegram-Worker: {exc}")

    async def main(self):
        while not STOP.is_set():
            try:
                if not self.client.is_connected():
                    await self.client.connect()
                if not await self.client.is_user_authorized():
                    with STATE_LOCK:
                        STATE.connected = False
                        if STATE.auth not in {"code_sent", "password_needed"}:
                            STATE.auth = "not_authorized"
                    await asyncio.sleep(1.5)
                    continue
                await self.profile()
                row = one("SELECT * FROM uploads WHERE state IN ('ready','retry') AND next_attempt<=? ORDER BY received LIMIT 1", (now(),))
                if not row:
                    await asyncio.sleep(1.5)
                    continue
                execute("UPDATE uploads SET state='uploading',attempts=attempts+1,updated=?,last_error=NULL WHERE id=?", (now(), row["id"]))
                await self.upload(one("SELECT * FROM uploads WHERE id=?", (row["id"],)))
            except Exception as exc:
                with STATE_LOCK:
                    STATE.error = str(exc)
                await asyncio.sleep(3)

    async def profile(self):
        me = await self.client.get_me()
        ent = await self.client.get_entity(target(self.cfg.get("telegram_target")))
        tid = int(utils.get_peer_id(ent))
        name = " ".join(filter(None, [getattr(me, "first_name", ""), getattr(me, "last_name", "")])).strip() or str(getattr(me, "username", "Telegram"))
        tname = (getattr(ent, "title", None) or "Gespeicherte Nachrichten") if target(self.cfg.get("telegram_target")) == "me" else (getattr(ent, "title", None) or str(self.cfg.get("telegram_target")))
        with STATE_LOCK:
            STATE.connected = True
            STATE.account = name
            STATE.target_name = str(tname)
            STATE.target_id = tid
            STATE.premium = bool(getattr(me, "premium", False))
            STATE.auth = "authorized"
            STATE.error = ""

    def submit(self, coro, timeout=90):
        if not self.loop or not self.client:
            raise RuntimeError("Telegram-Worker startet noch")
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(timeout=timeout)

    async def send_code_async(self, phone):
        self.phone = str(phone).strip()
        self.cfg["phone"] = self.phone
        save_cfg(self.cfg)
        await self.client.send_code_request(self.phone)
        with STATE_LOCK:
            STATE.auth = "code_sent"
        return True

    def send_code(self, phone):
        return self.submit(self.send_code_async(phone))

    async def verify_async(self, code):
        try:
            await self.client.sign_in(self.phone or str(self.cfg.get("phone") or ""), str(code).replace(" ", ""))
            with STATE_LOCK:
                STATE.auth = "authorized"
            return "ok"
        except errors.SessionPasswordNeededError:
            with STATE_LOCK:
                STATE.auth = "password_needed"
            return "2fa"

    def verify(self, code):
        return self.submit(self.verify_async(code))

    async def password_async(self, password):
        await self.client.sign_in(password=password)
        with STATE_LOCK:
            STATE.auth = "authorized"
        return True

    def password(self, password):
        return self.submit(self.password_async(password))

    async def logout_async(self, reset=False):
        with contextlib.suppress(Exception):
            if await self.client.is_user_authorized():
                await self.client.log_out()
        await self.client.disconnect()
        if reset:
            for path in HOME.glob("tgs_relay.session*"):
                with contextlib.suppress(Exception):
                    path.unlink()
        self.client = TelegramClient(str(SESSION), int(self.cfg["api_id"]), str(self.cfg["api_hash"]))
        await self.client.connect()
        with STATE_LOCK:
            STATE.connected = False
            STATE.auth = "not_authorized"
            STATE.account = ""
            STATE.target_name = ""
            STATE.target_id = None

    def logout(self, reset=False):
        return self.submit(self.logout_async(reset))

    async def already(self, ent, row, mark):
        with contextlib.suppress(Exception):
            async for msg in self.client.iter_messages(ent, search=mark, limit=10):
                if mark in (msg.message or ""):
                    return int(msg.id)
        key = str(row["resource_key"] or "")
        if key:
            with contextlib.suppress(Exception):
                async for msg in self.client.iter_messages(ent, search="#TGSpeicherV2", limit=250):
                    item = decoded(msg.message or "")
                    if item and item.get("sourceKey") == key:
                        return int(msg.id)
        return None

    async def progress(self, sent, total):
        with STATE_LOCK:
            STATE.active_sent = int(sent)
            STATE.active_total = int(total)
            STATE.last_activity = now()

    async def upload(self, row):
        uid = str(row["id"])
        path = Path(row["path"])
        if not path.exists():
            execute("UPDATE uploads SET state='retry',next_attempt=?,last_error=? WHERE id=?", (now() + 300, "Spool-Datei fehlt", uid))
            return
        ent = await self.client.get_entity(target(row["target"] or self.cfg.get("telegram_target")))
        chat = int(utils.get_peer_id(ent))
        mark = marker(row["resource_key"], row["sha256"], uid)
        old = await self.already(ent, row, mark)
        if old:
            execute("UPDATE uploads SET state='sent',updated=?,message_ids=?,last_error=NULL WHERE id=?", (now(), json.dumps([old]), uid))
            path.unlink(missing_ok=True)
            event("upload", f"Duplikat vermieden: {row['filename']}")
            return
        with STATE_LOCK:
            STATE.active_file = row["filename"]
            STATE.active_sent = 0
            STATE.active_total = int(row["size"])
            STATE.last_activity = now()
        try:
            ids = await self.send_path(ent, chat, path, row, mark)
            execute("UPDATE uploads SET state='sent',updated=?,message_ids=?,last_error=NULL WHERE id=?", (now(), json.dumps(ids), uid))
            event("upload", f"Telegram ✅ {row['filename']}")
            if self.cfg.get("delete_after_success", True):
                path.unlink(missing_ok=True)
        except errors.FloodWaitError as exc:
            delay = int(getattr(exc, "seconds", 60)) + 2
            execute("UPDATE uploads SET state='retry',next_attempt=?,updated=?,last_error=? WHERE id=?", (now() + delay, now(), f"FLOOD_WAIT {delay}s", uid))
            event("flood", f"FLOOD_WAIT {delay}s")
        except Exception as exc:
            attempts = int(row["attempts"] or 1)
            base = int(self.cfg.get("retry_base_seconds", 15))
            maximum = int(self.cfg.get("retry_max_seconds", 1800))
            delay = min(maximum, base * 2 ** min(attempts, 7))
            execute("UPDATE uploads SET state='retry',next_attempt=?,updated=?,last_error=? WHERE id=?", (now() + delay, now(), str(exc)[:1500], uid))
            event("error", f"{row['filename']}: {exc}")
        finally:
            with STATE_LOCK:
                STATE.active_file = ""
                STATE.active_sent = 0
                STATE.active_total = 0

    async def send_path(self, ent, chat, path, row, mark):
        limit = int(self.cfg.get("telegram_part_bytes") or TG_PART)
        size = int(row["size"])
        kind = str(row["media_kind"])
        native = bool(self.cfg.get("prefer_native_media", True)) and kind in {"photo", "video"}
        if size <= limit:
            if native:
                try:
                    caption = manifest(row, chat, "nativePhoto" if kind == "photo" else "nativeVideo", 1, 1, None, mark)
                    kwargs = {"caption": caption, "force_document": False, "progress_callback": self.progress}
                    if kind == "video":
                        kwargs["supports_streaming"] = True
                    msg = await self.client.send_file(ent, str(path), **kwargs)
                    return [int(x.id) for x in msg] if isinstance(msg, list) else [int(msg.id)]
                except Exception:
                    pass
            msg = await self.client.send_file(ent, str(path), caption=manifest(row, chat, "fileChunk", 1, 1, row["sha256"], mark), force_document=True, progress_callback=self.progress)
            return [int(msg.id)]
        total = (size + limit - 1) // limit
        ids = []
        with path.open("rb") as source:
            for index in range(1, total + 1):
                part = SPOOL / f"{row['id']}.part-{index:05d}-of-{total:05d}"
                digest = hashlib.sha256()
                left = min(limit, size - (index - 1) * limit)
                with part.open("wb") as output:
                    while left:
                        data = source.read(min(BLOCK, left))
                        if not data:
                            raise IOError("Quelldatei unerwartet zu Ende")
                        output.write(data)
                        digest.update(data)
                        left -= len(data)
                    output.flush()
                    os.fsync(output.fileno())
                try:
                    msg = await self.client.send_file(ent, str(part), caption=manifest(row, chat, "fileChunk", index, total, digest.hexdigest(), mark), force_document=True, progress_callback=self.progress)
                    ids.append(int(msg.id))
                finally:
                    part.unlink(missing_ok=True)
        return ids


def ensure_worker(cfg):
    global WORKER
    if not configured(cfg):
        return None
    with WORKER_LOCK:
        if WORKER and WORKER.is_alive():
            return WORKER
        telethon()
        WORKER = TgWorker(cfg)
        WORKER.start()
        WORKER.ready.wait(15)
        event("service", "Telegram-Worker gestartet")
        return WORKER


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, cfg):
        super().__init__(address, handler)
        self.cfg = cfg
        self.started = now()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"TGSpeicherRelay/{VERSION}"

    @property
    def cfg(self):
        return self.server.cfg

    def log_message(self, fmt, *args):
        log(f"HTTP {self.client_address[0]} - {fmt % args}")

    def sendb(self, status, ctype, data, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        for key, value in (extra or {}).items():
            self.send_header(key, str(value))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(data)

    def js(self, status, obj, extra=None):
        self.sendb(status, "application/json; charset=utf-8", json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode(), extra)

    def page(self, title, body, refresh=False):
        css = "body{margin:0;background:#080b14;color:#f7f8ff;font:15px -apple-system,BlinkMacSystemFont,sans-serif}.w{max-width:1100px;margin:auto;padding:28px 16px 70px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(235px,1fr));gap:14px}.c{background:rgba(255,255,255,.075);border:1px solid rgba(255,255,255,.12);border-radius:22px;padding:18px;margin-bottom:14px;backdrop-filter:blur(25px)}h1{font-size:30px;margin:3px 0 20px}h2{font-size:18px}small,.muted{color:#aab2c8}.good{color:#4bd28a}.bad{color:#ff6b77}.big{font-size:26px;font-weight:700}input{width:100%;box-sizing:border-box;padding:11px;margin:5px 0 10px;border:1px solid #ffffff25;border-radius:12px;background:#0005;color:#fff}button{padding:10px 14px;border:0;border-radius:12px;font-weight:650;cursor:pointer}.secondary{background:#ffffff18;color:#fff}.danger{background:#a93645;color:white}table{width:100%;border-collapse:collapse}td,th{padding:9px;border-bottom:1px solid #ffffff18;text-align:left}code{background:#0006;padding:4px 7px;border-radius:8px}.hero{max-width:560px;margin:7vh auto}.step{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:#8ca8ff}"
        meta = "<meta http-equiv=refresh content=20>" if refresh else ""
        return f"<!doctype html><html lang=de><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>{meta}<title>{html.escape(title)} · TGSpeicher</title><style>{css}</style><body><div class=w>{body}</div></body></html>"

    def parts(self):
        return [unquote(x) for x in urlparse(self.path).path.split("/") if x]

    def query(self):
        return parse_qs(urlparse(self.path).query)

    def length(self):
        try:
            return int(self.headers.get("Content-Length", "0"))
        except Exception:
            return 0

    def form(self):
        raw = self.rfile.read(min(self.length(), 1024 * 1024)).decode(errors="replace")
        parsed = parse_qs(raw)
        return {key: (value[-1] if value else "") for key, value in parsed.items()}

    def body(self):
        try:
            return json.loads(self.rfile.read(min(self.length(), 1024 * 1024)))
        except Exception:
            return {}

    def cookie(self):
        cookie = SimpleCookie()
        with contextlib.suppress(Exception):
            cookie.load(self.headers.get("Cookie", ""))
        return cookie.get("tgs_session").value if cookie.get("tgs_session") else ""

    def session(self):
        return web_get(self.cookie())

    def redirect(self, url, cookie=None):
        headers = {"Location": url}
        if cookie:
            headers["Set-Cookie"] = cookie
        self.sendb(303, "text/plain", b"", headers)

    def bearer(self):
        header = self.headers.get("Authorization", "")
        return header[7:].strip() if header.startswith("Bearer ") else ""

    def api(self, upload=False):
        if not configured(self.cfg):
            self.js(503, {"ok": False, "error": "relay_not_configured"})
            raise PermissionError
        found = device(self.bearer(), True, upload)
        if not found:
            self.js(401, {"ok": False, "error": "unauthorized"}, {"WWW-Authenticate": "Bearer"})
            raise PermissionError
        return found

    def require_web(self):
        session = self.session()
        if not session:
            self.redirect("/login")
            return None
        return session

    def csrf(self, session, form):
        return hmac.compare_digest(str(session["csrf"]), str(form.get("csrf") or ""))

    def client_ip(self):
        return (self.headers.get("X-Real-IP") or self.client_address[0]).split(",")[0]

    def login_page(self, msg=""):
        error = f"<p class=bad>{html.escape(msg)}</p>" if msg else ""
        subtitle = "Erstzugriff · sicher anmelden" if not configured(self.cfg) else "Dashboard"
        return self.page("Anmelden", f"<div class='c hero'><div class=step>{subtitle}</div><h1>Background Relay</h1>{error}<form method=post action=/login><input type=password name=password placeholder='Dashboard-Passwort' required autofocus><button>Anmelden</button></form><p class=muted>Server: {html.escape(PUBLIC)} · intern Port {PORT}</p></div>")

    def setup_page(self, session, msg=""):
        csrf = html.escape(str(session["csrf"]))
        error = f"<div class=c><b class=bad>{html.escape(msg)}</b></div>" if msg else ""
        return self.page("Einrichtung", f"<div class='c hero'><div class=step>Einmalige Einrichtung</div><h1>TGSpeicher Relay</h1><p>Der Server läuft bereits. Trage nur noch deine Telegram-API-Daten ein. Danach startet Telegram sofort im selben Prozess – kein AMP-Neustart nötig.</p>{error}<form method=post action=/setup><input type=hidden name=csrf value='{csrf}'><label>Telegram API-ID</label><input inputmode=numeric name=api_id placeholder='12345678' required><label>Telegram API-Hash</label><input name=api_hash autocomplete=off placeholder='API-Hash' required><label>Telefonnummer</label><input name=phone placeholder='+49…' required><label>Telegram-Ziel</label><input name=telegram_target value='me' required><button>Einrichtung speichern & Telegram starten</button></form><p class=muted><b>me</b> = Gespeicherte Nachrichten. Öffentliche Adresse ist fest auf {html.escape(PUBLIC)} gesetzt.</p></div>")

    def fmt_time(self, value):
        return "Noch nie" if not value else datetime.fromtimestamp(float(value)).strftime("%d.%m.%Y %H:%M:%S")

    def fmt_size(self, number):
        number = float(number or 0)
        for unit in ["B", "KB", "MB", "GB", "TB"]:
            if number < 1024:
                return f"{number:.1f} {unit}"
            number /= 1024
        return f"{number:.1f} PB"

    def dashboard(self, session, paircode="", msg=""):
        st = snapshot()
        cs = counts()
        dev = rows("SELECT id,name,created,last_seen,last_upload,revoked FROM devices ORDER BY created DESC")
        ups = rows("SELECT filename,size,state,updated,last_error FROM uploads ORDER BY received DESC LIMIT 25")
        ev = rows("SELECT at,kind,message FROM events ORDER BY id DESC LIMIT 15")
        disk = shutil.disk_usage(SPOOL)
        csrf = html.escape(str(session["csrf"]))
        active = [x for x in dev if not x["revoked"]]
        last = max([x["last_seen"] or 0 for x in active] or [0])
        lastup = max([x["last_upload"] or 0 for x in active] or [0])
        pct = int(100 * st["active_sent"] / st["active_total"]) if st["active_total"] else 0
        notice = f"<div class=c><b>{html.escape(msg)}</b></div>" if msg else ""
        pairbox = f"<div class=c><h2>Einmal-Code</h2><div class=big><code>{html.escape(paircode)}</code></div><p class=muted>10 Minuten gültig, nur einmal verwendbar.</p></div>" if paircode else ""
        if st["connected"]:
            tg = f"<div class='big good'>Verbunden</div><b>{html.escape(st['account'])}</b><p class=muted>Ziel: {html.escape(st['target_name'])}</p><form method=post action=/web/telegram/logout><input type=hidden name=csrf value='{csrf}'><button class=secondary>Abmelden</button></form> <form method=post action=/web/telegram/reset style='display:inline'><input type=hidden name=csrf value='{csrf}'><button class=danger>Session zurücksetzen</button></form>"
        elif st["auth"] == "code_sent":
            tg = f"<div class='big bad'>Code erwartet</div><form method=post action=/web/telegram/verify><input type=hidden name=csrf value='{csrf}'><input name=code placeholder='Telegram-Code' required><button>Bestätigen</button></form>"
        elif st["auth"] == "password_needed":
            tg = f"<div class='big bad'>2FA erwartet</div><form method=post action=/web/telegram/password><input type=hidden name=csrf value='{csrf}'><input type=password name=password placeholder='Telegram 2FA-Passwort' required><button>2FA bestätigen</button></form>"
        else:
            tg = f"<div class='big bad'>Nicht angemeldet</div><form method=post action=/web/telegram/code><input type=hidden name=csrf value='{csrf}'><input name=phone value='{html.escape(str(self.cfg.get('phone') or ''))}' placeholder='+49…' required><button>Telegram-Code senden</button></form>"
        device_rows = "".join(f"<tr><td>{html.escape(x['name'])}</td><td>{self.fmt_time(x['last_seen'])}</td><td>{self.fmt_time(x['last_upload'])}</td><td>{'Widerrufen' if x['revoked'] else f'''<form method=post action=/web/device/revoke><input type=hidden name=csrf value='{csrf}'><input type=hidden name=device_id value='{x['id']}'><button class=secondary>Trennen</button></form>'''}</td></tr>" for x in dev)
        upload_rows = "".join(f"<tr><td>{html.escape(x['filename'])}</td><td>{self.fmt_size(x['size'])}</td><td>{html.escape(x['state'])}</td><td>{self.fmt_time(x['updated'])}</td></tr>" for x in ups)
        event_rows = "".join(f"<tr><td>{self.fmt_time(x['at'])}</td><td>{html.escape(x['kind'])}</td><td>{html.escape(x['message'])}</td></tr>" for x in ev)
        body = f"<div style='display:flex;justify-content:space-between'><div><small>TGSpeicher</small><h1>Background Relay</h1></div><form method=post action=/logout><input type=hidden name=csrf value='{csrf}'><button class=secondary>Dashboard abmelden</button></form></div>{notice}<div class=grid><div class=c><h2>Telegram</h2>{tg}</div><div class=c><h2>iPhone</h2><div class=big>{len(active)} gekoppelt</div><p class=muted>Letzter Kontakt: {self.fmt_time(last)}<br>Letzter Upload: {self.fmt_time(lastup)}</p></div><div class=c><h2>Upload-Queue</h2><div class=big>{cs.get('ready',0)+cs.get('retry',0)+cs.get('uploading',0)}</div><p class=muted>Telegram gesendet: {cs.get('sent',0)}</p></div><div class=c><h2>Aktiv</h2><div class=big>{pct}%</div><p>{html.escape(st['active_file'] or 'Kein Telegram-Upload')}</p></div><div class=c><h2>VPS</h2><div class=big>{self.fmt_size(disk.free)} frei</div><p class=muted>{self.fmt_size(disk.used)} belegt</p></div></div><div class=grid><div class=c><h2>iPhone koppeln</h2><form method=post action=/web/pairing/new><input type=hidden name=csrf value='{csrf}'><input name=label value='Mein iPhone'><button>Einmal-Code erzeugen</button></form></div><div class=c><h2>Telegram-Ziel</h2><form method=post action=/web/config/target><input type=hidden name=csrf value='{csrf}'><input name=target value='{html.escape(str(self.cfg.get('telegram_target') or 'me'))}'><button>Speichern</button></form><p class=muted>me = Gespeicherte Nachrichten</p></div></div>{pairbox}<div class=c><h2>Geräte</h2><table><tr><th>Name</th><th>Kontakt</th><th>Upload</th><th></th></tr>{device_rows or '<tr><td colspan=4>Noch kein Gerät</td></tr>'}</table></div><div class=c><h2>Letzte Uploads</h2><table><tr><th>Datei</th><th>Größe</th><th>Status</th><th>Zeit</th></tr>{upload_rows or '<tr><td colspan=4>Noch keine Uploads</td></tr>'}</table></div><div class=c><h2>Ereignisse</h2><table>{event_rows}</table></div>"
        return self.page("Dashboard", body, refresh=True)

    def metadata(self):
        name = None
        encoded = self.headers.get("X-TG-Filename-B64")
        if encoded:
            with contextlib.suppress(Exception):
                name = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()
        name = clean_name(name or self.headers.get("X-TG-Filename") or self.headers.get("X-Filename"))
        return {
            "filename": name,
            "resource_key": self.headers.get("X-TG-Resource-Key"),
            "asset_id": self.headers.get("X-TG-Asset-ID"),
            "resource_type": self.headers.get("X-TG-Resource-Type"),
            "creation_date": self.headers.get("X-TG-Creation-Date"),
            "media_kind": media_kind(self.headers.get("X-TG-Media-Kind"), name),
        }

    def do_GET(self):
        parts = self.parts()
        if parts == ["health"]:
            self.js(200, {"ok": True, "version": VERSION, "configured": configured(self.cfg), "telegram_connected": snapshot()["connected"], "queue": counts(), "time": iso()})
            return
        if parts == ["api", "device", "status"]:
            try:
                found = self.api()
            except PermissionError:
                return
            self.js(200, {"ok": True, "version": VERSION, "telegram": snapshot(), "queue": counts(), "device": {"id": found["id"], "name": found["name"], "last_seen": found["last_seen"], "last_upload": found["last_upload"]}})
            return
        if parts == ["login"]:
            self.sendb(200, "text/html; charset=utf-8", self.login_page().encode())
            return
        if parts == ["setup"]:
            session = self.require_web()
            if not session:
                return
            if configured(self.cfg):
                self.redirect("/")
                return
            self.sendb(200, "text/html; charset=utf-8", self.setup_page(session).encode())
            return
        if not parts:
            session = self.require_web()
            if not session:
                return
            if not configured(self.cfg):
                self.redirect("/setup")
                return
            query = self.query()
            self.sendb(200, "text/html; charset=utf-8", self.dashboard(session, (query.get("pairing") or [""])[0], (query.get("message") or [""])[0]).encode())
            return
        self.js(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        parts = self.parts()
        if parts == ["login"]:
            ip = self.client_ip()
            cutoff = now() - 600
            with LOGIN_LOCK:
                LOGIN_FAILS[ip] = [x for x in LOGIN_FAILS.get(ip, []) if x > cutoff]
                allowed = len(LOGIN_FAILS[ip]) < 8
            if not allowed:
                self.sendb(429, "text/html; charset=utf-8", self.login_page("Zu viele Fehlversuche.").encode())
                return
            form = self.form()
            password_hash = self.cfg.get("web_password_hash") or BOOTSTRAP_PASSWORD_HASH
            if not pverify(form.get("password", ""), password_hash):
                with LOGIN_LOCK:
                    LOGIN_FAILS[ip].append(now())
                self.sendb(401, "text/html; charset=utf-8", self.login_page("Passwort falsch.").encode())
                return
            token, _ = web_issue()
            self.redirect("/setup" if not configured(self.cfg) else "/", f"tgs_session={token}; Path=/; HttpOnly; SameSite=Strict; Secure; Max-Age={7*86400}")
            return
        if parts == ["api", "pair"]:
            if not configured(self.cfg):
                self.js(503, {"ok": False, "error": "relay_not_configured"})
                return
            body = self.body()
            result = pair_exchange(str(body.get("code") or ""), str(body.get("device_name") or "iPhone"))
            if not result:
                self.js(401, {"ok": False, "error": "invalid_or_expired_pairing_code"})
                return
            self.js(201, {"ok": True, "device_id": result[0], "device_token": result[1], "base_url": PUBLIC})
            return
        if parts == ["upload"]:
            self.upload_post()
            return
        session = self.require_web()
        if not session:
            return
        form = self.form()
        if not self.csrf(session, form):
            self.js(403, {"ok": False, "error": "csrf"})
            return
        if parts == ["setup"]:
            if configured(self.cfg):
                self.redirect("/")
                return
            try:
                api_id = int((form.get("api_id") or "0").strip())
                api_hash = (form.get("api_hash") or "").strip()
                phone = (form.get("phone") or "").strip()
                tg_target = (form.get("telegram_target") or "me").strip()
                if api_id <= 0 or len(api_hash) < 10 or not phone:
                    raise ValueError("API-ID, API-Hash und Telefonnummer vollständig eintragen.")
                self.cfg.update({"api_id": api_id, "api_hash": api_hash, "phone": phone, "telegram_target": tg_target, "web_password_hash": BOOTSTRAP_PASSWORD_HASH, "setup_complete": True, "public_base_url": PUBLIC, "bind_host": HOST, "port": PORT})
                save_cfg(self.cfg)
                ensure_worker(self.cfg)
                event("setup", "Web-Einrichtung abgeschlossen")
                self.redirect("/?message=" + quote("Einrichtung gespeichert. Jetzt Telegram-Code anfordern."))
            except Exception as exc:
                self.sendb(400, "text/html; charset=utf-8", self.setup_page(session, str(exc)).encode())
            return
        if not configured(self.cfg):
            self.redirect("/setup")
            return
        if parts == ["logout"]:
            execute("DELETE FROM web_sessions WHERE token_hash=?", (shash(self.cookie()),))
            self.redirect("/login", "tgs_session=; Path=/; Max-Age=0; Secure")
            return
        if parts == ["web", "pairing", "new"]:
            self.redirect("/?pairing=" + quote(pairing(form.get("label") or "iPhone")))
            return
        if parts == ["web", "device", "revoke"]:
            execute("UPDATE devices SET revoked=1 WHERE id=?", (form.get("device_id"),))
            self.redirect("/?message=" + quote("Gerät getrennt."))
            return
        if parts == ["web", "config", "target"]:
            self.cfg["telegram_target"] = (form.get("target") or "me").strip()
            save_cfg(self.cfg)
            self.redirect("/?message=" + quote("Telegram-Ziel gespeichert."))
            return
        try:
            worker = ensure_worker(self.cfg)
            if not worker:
                raise RuntimeError("Telegram-Worker nicht verfügbar")
            if parts == ["web", "telegram", "code"]:
                worker.send_code(form.get("phone", ""))
                self.redirect("/?message=" + quote("Telegram-Code angefordert."))
                return
            if parts == ["web", "telegram", "verify"]:
                result = worker.verify(form.get("code", ""))
                self.redirect("/?message=" + quote("2FA-Passwort erforderlich." if result == "2fa" else "Telegram verbunden."))
                return
            if parts == ["web", "telegram", "password"]:
                worker.password(form.get("password", ""))
                self.redirect("/?message=" + quote("Telegram verbunden."))
                return
            if parts == ["web", "telegram", "logout"]:
                worker.logout(False)
                self.redirect("/?message=" + quote("Telegram abgemeldet."))
                return
            if parts == ["web", "telegram", "reset"]:
                worker.logout(True)
                self.redirect("/?message=" + quote("Telegram-Session zurückgesetzt."))
                return
        except Exception as exc:
            event("error", f"Telegram-Anmeldung: {exc}")
            self.redirect("/?message=" + quote("Telegram-Fehler: " + str(exc)))
            return
        self.js(404, {"ok": False, "error": "not_found"})

    def upload_post(self):
        try:
            found = self.api(upload=True)
        except PermissionError:
            return
        length = self.length()
        maximum = int(self.cfg.get("max_upload_bytes") or DEFAULT["max_upload_bytes"])
        if length <= 0:
            self.js(411, {"ok": False, "error": "content_length_required"})
            return
        if length > maximum:
            self.js(413, {"ok": False, "error": "too_large", "max": maximum})
            return
        reserve = int(self.cfg.get("spool_reserve_bytes") or 0)
        if length > max(0, shutil.disk_usage(SPOOL).free - reserve):
            self.js(507, {"ok": False, "error": "insufficient_storage"})
            return
        meta = self.metadata()
        uid = uuid.uuid4().hex
        partial = SPOOL / (uid + ".part")
        received = 0
        execute(
            "INSERT INTO uploads(id,resource_key,asset_id,resource_type,filename,media_kind,creation_date,path,size,sha256,state,received,updated,attempts,next_attempt,last_error,message_ids,target,device_id) VALUES(?,?,?,?,?,?,?,?,0,NULL,'receiving',?,?,0,0,NULL,NULL,?,?)",
            (uid, meta["resource_key"], meta["asset_id"], meta["resource_type"], meta["filename"], meta["media_kind"], meta["creation_date"], str(partial), now(), now(), str(self.cfg.get("telegram_target") or "me"), found["id"]),
        )
        try:
            digest = hashlib.sha256()
            with partial.open("wb") as output:
                while received < length:
                    data = self.rfile.read(min(BLOCK, length - received))
                    if not data:
                        break
                    output.write(data)
                    digest.update(data)
                    received += len(data)
                output.flush()
                os.fsync(output.fileno())
            if received != length:
                execute("UPDATE uploads SET state='retry',size=?,updated=?,last_error=? WHERE id=?", (received, now(), "HTTP body incomplete", uid))
                return
            sha = digest.hexdigest()
            old = one("SELECT * FROM uploads WHERE id<>? AND state='sent' AND ((resource_key IS NOT NULL AND resource_key=?) OR sha256=?) ORDER BY updated DESC LIMIT 1", (uid, meta["resource_key"], sha))
            if old:
                execute("UPDATE uploads SET state='sent',size=?,sha256=?,updated=?,message_ids=? WHERE id=?", (received, sha, now(), old["message_ids"], uid))
                partial.unlink(missing_ok=True)
                state, duplicate = "sent", True
            else:
                final = SPOOL / f"{uid}-{meta['filename']}"
                os.replace(partial, final)
                execute("UPDATE uploads SET path=?,state='ready',size=?,sha256=?,updated=? WHERE id=?", (str(final), received, sha, now(), uid))
                state, duplicate = "ready", False
            event("iphone", f"Empfangen: {meta['filename']} ({received} Bytes)")
            self.js(201, {"ok": True, "resource_id": uid, "state": state, "duplicate": duplicate, "telegram_pending": state != "sent"}, {"X-Server-Resource-ID": uid, "X-TG-Resource-Key": meta["resource_key"] or ""})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            event("error", f"HTTP upload: {exc}")
            self.js(500, {"ok": False, "error": "server_error"})

    def do_OPTIONS(self):
        self.sendb(204, "text/plain", b"", {"Allow": "GET,POST,OPTIONS"})


def main():
    global WORKER
    parser = argparse.ArgumentParser()
    parser.add_argument("--show-config", action="store_true")
    args = parser.parse_args()
    cfg = load_cfg()
    init_db()
    if args.show_config:
        safe = dict(cfg)
        safe["api_hash"] = "***" if safe.get("api_hash") else ""
        safe["web_password_hash"] = "configured" if safe.get("web_password_hash") else "bootstrap"
        print(json.dumps(safe, ensure_ascii=False, indent=2))
        return
    server = Server((HOST, PORT), Handler, cfg)
    if configured(cfg):
        with contextlib.suppress(Exception):
            ensure_worker(cfg)
    print(f"\n{APP} v{VERSION}\nIntern: http://{HOST}:{PORT}\nWeb: {PUBLIC}/\nDaten: {HOME}\n")
    if not configured(cfg):
        print("Erststart: Weboberfläche öffnen, anmelden und Einrichtung im Browser abschließen.\n")
    event("service", f"Relay {VERSION} gestartet")
    try:
        server.serve_forever(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        STOP.set()
        server.server_close()
        if WORKER:
            WORKER.join(10)


if __name__ == "__main__":
    main()
