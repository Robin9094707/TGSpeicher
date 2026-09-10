#!/usr/bin/env python3
"""
TGSpeicher Background Relay
===========================
Single-file HTTPS-backend companion for TGSpeicher's optional iOS PhotoKit
background upload extension.

The relay intentionally contains everything except TLS termination. Run it on
0.0.0.0 behind Caddy/nginx/Traefik, or expose it only on a trusted private
network. The iOS PhotoKit background uploader requires HTTPS in production.

First start:
    python3 TGSpeicherBackgroundRelay.py

Useful commands:
    python3 TGSpeicherBackgroundRelay.py --setup
    python3 TGSpeicherBackgroundRelay.py --port 8765
    python3 TGSpeicherBackgroundRelay.py --show-config

Dependency:
    Telethon 1.44.0. If it is missing, this script can install it automatically.

Files created in ~/.tgspeicher-relay by default (override with TGS_RELAY_HOME):
    tgs_relay_config.json        server/Telegram configuration (chmod 600)
    tgs_relay.session            Telethon authorization session (chmod 600)
    relay.sqlite3                durable upload queue/index
    uploads/                     temporary upload spool (removed after success)

Security:
    Keep the config and .session file private. Possession of the Telegram
    session may allow access to the Telegram account.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import getpass
import hashlib
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
import traceback
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import unquote, urlparse

APP_NAME = "TGSpeicher Background Relay"
VERSION = "1.0.0"
DEFAULT_BIND_HOST = "0.0.0.0"
DEFAULT_PORT = 8765
DEFAULT_MAX_UPLOAD_BYTES = 50 * 1024 * 1024 * 1024
DEFAULT_TELEGRAM_PART_BYTES = 1_900_000_000
READ_BLOCK = 1024 * 1024
SCRIPT_DIR = Path(__file__).resolve().parent
RELAY_HOME = Path(os.environ.get("TGS_RELAY_HOME", str(Path.home() / ".tgspeicher-relay"))).expanduser().resolve()
CONFIG_PATH = RELAY_HOME / "tgs_relay_config.json"
SESSION_PATH = RELAY_HOME / "tgs_relay"
DATA_DIR = RELAY_HOME
UPLOAD_DIR = RELAY_HOME / "uploads"
DB_PATH = RELAY_HOME / "relay.sqlite3"
STOP_EVENT = threading.Event()

_TELETHON_IMPORTED = False
TelegramClient = None
telethon_errors = None


def utc_ts() -> float:
    return time.time()


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {message}", flush=True)


def chmod_private(path: Path) -> None:
    with contextlib.suppress(Exception):
        os.chmod(path, 0o600)


def import_telethon(auto_install: bool = True) -> None:
    global _TELETHON_IMPORTED, TelegramClient, telethon_errors
    if _TELETHON_IMPORTED:
        return
    try:
        from telethon import TelegramClient as _TelegramClient, errors as _errors
        TelegramClient = _TelegramClient
        telethon_errors = _errors
        _TELETHON_IMPORTED = True
        return
    except ModuleNotFoundError:
        if not auto_install:
            raise

    log("Telethon fehlt. Installiere Telethon 1.44.0 automatisch …")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "Telethon==1.44.0"])
    except Exception as exc:
        raise SystemExit(
            "Telethon konnte nicht automatisch installiert werden.\n"
            f"Fehler: {exc}\n"
            "Bitte einmal ausführen: python3 -m pip install Telethon==1.44.0"
        )
    from telethon import TelegramClient as _TelegramClient, errors as _errors
    TelegramClient = _TelegramClient
    telethon_errors = _errors
    _TELETHON_IMPORTED = True


DEFAULT_CONFIG: Dict[str, Any] = {
    "bind_host": DEFAULT_BIND_HOST,
    "port": DEFAULT_PORT,
    "api_id": 0,
    "api_hash": "",
    "phone": "",
    "telegram_target": "me",
    "auth_token": "",
    "public_base_url": "",
    "max_upload_bytes": DEFAULT_MAX_UPLOAD_BYTES,
    "telegram_part_bytes": DEFAULT_TELEGRAM_PART_BYTES,
    "prefer_native_media": True,
    "delete_after_success": True,
    "resumable_uploads": False,
    "retry_base_seconds": 15,
    "retry_max_seconds": 1800,
    "spool_reserve_bytes": 2 * 1024 * 1024 * 1024,
}


def save_config(cfg: Dict[str, Any]) -> None:
    RELAY_HOME.mkdir(parents=True, exist_ok=True)
    with contextlib.suppress(Exception):
        os.chmod(RELAY_HOME, 0o700)
    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    chmod_private(tmp)
    os.replace(tmp, CONFIG_PATH)
    chmod_private(CONFIG_PATH)


def prompt(text: str, default: Optional[str] = None, secret: bool = False) -> str:
    suffix = f" [{default}]" if default not in (None, "") else ""
    while True:
        if secret:
            value = getpass.getpass(f"{text}{suffix}: ").strip()
        else:
            value = input(f"{text}{suffix}: ").strip()
        if value:
            return value
        if default is not None:
            return default


def setup_config(existing: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    cfg = dict(DEFAULT_CONFIG)
    if existing:
        cfg.update(existing)

    print("\n=== TGSpeicher Background Relay – Einrichtung ===\n")
    print("Die Telegram API-ID und den API-Hash bekommst du über my.telegram.org.")
    print("Als Ziel kannst du 'me' für Gespeicherte Nachrichten verwenden oder eine Chat-/Kanal-ID.\n")

    cfg["bind_host"] = prompt("Bind-Adresse", str(cfg.get("bind_host") or DEFAULT_BIND_HOST))
    cfg["port"] = int(prompt("Port", str(cfg.get("port") or DEFAULT_PORT)))

    current_api_id = int(cfg.get("api_id") or 0)
    cfg["api_id"] = int(prompt("Telegram API-ID", str(current_api_id) if current_api_id else None))
    cfg["api_hash"] = prompt(
        "Telegram API-Hash",
        str(cfg.get("api_hash") or "") or None,
        secret=bool(cfg.get("api_hash")),
    )
    cfg["phone"] = prompt("Telefonnummer mit Ländervorwahl, z.B. +49123…", str(cfg.get("phone") or "") or None)
    cfg["telegram_target"] = prompt("Telegram-Ziel", str(cfg.get("telegram_target") or "me"))

    if not cfg.get("auth_token"):
        cfg["auth_token"] = secrets.token_urlsafe(36)

    current_public = str(cfg.get("public_base_url") or "")
    print("\nDie öffentliche HTTPS-Adresse kann leer bleiben und später in der JSON-Datei gesetzt werden.")
    cfg["public_base_url"] = prompt("Öffentliche Basis-URL (optional)", current_public)

    save_config(cfg)
    print(f"\nKonfiguration gespeichert: {CONFIG_PATH}")
    print("WICHTIG: Den folgenden Token später in TGSpeicher eintragen und geheim halten:")
    print(f"\n{cfg['auth_token']}\n")
    return cfg


def load_config(force_setup: bool = False) -> Dict[str, Any]:
    if force_setup or not CONFIG_PATH.exists():
        existing = None
        if CONFIG_PATH.exists():
            try:
                existing = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            except Exception:
                existing = None
        return setup_config(existing)

    try:
        loaded = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Konfiguration {CONFIG_PATH} ist ungültig: {exc}")

    cfg = dict(DEFAULT_CONFIG)
    cfg.update(loaded)
    if not cfg.get("auth_token"):
        cfg["auth_token"] = secrets.token_urlsafe(36)
        save_config(cfg)
    chmod_private(CONFIG_PATH)
    return cfg


def validate_config(cfg: Dict[str, Any]) -> None:
    if int(cfg.get("api_id") or 0) <= 0 or not str(cfg.get("api_hash") or "").strip():
        raise SystemExit("Telegram API-ID/API-Hash fehlen. Starte mit --setup.")
    if not str(cfg.get("phone") or "").strip():
        raise SystemExit("Telefonnummer fehlt. Starte mit --setup.")
    port = int(cfg.get("port") or 0)
    if not (1 <= port <= 65535):
        raise SystemExit("Ungültiger Port in der Konfiguration.")


def open_db() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with contextlib.suppress(Exception):
        os.chmod(DATA_DIR, 0o700)
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=FULL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db() -> None:
    with open_db() as db:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS uploads (
                id TEXT PRIMARY KEY,
                resource_key TEXT,
                asset_id TEXT,
                resource_type TEXT,
                filename TEXT NOT NULL,
                media_kind TEXT NOT NULL DEFAULT 'file',
                creation_date TEXT,
                preserve_original INTEGER NOT NULL DEFAULT 0,
                path TEXT NOT NULL,
                size INTEGER NOT NULL DEFAULT 0,
                sha256 TEXT,
                state TEXT NOT NULL,
                upload_offset INTEGER NOT NULL DEFAULT 0,
                complete INTEGER NOT NULL DEFAULT 0,
                received_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt REAL NOT NULL DEFAULT 0,
                last_error TEXT,
                telegram_message_ids TEXT,
                telegram_target TEXT,
                telegram_marker TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_uploads_state_next
                ON uploads(state, next_attempt, received_at);
            CREATE INDEX IF NOT EXISTS idx_uploads_resource_key
                ON uploads(resource_key);
            CREATE INDEX IF NOT EXISTS idx_uploads_sha256
                ON uploads(sha256);
            """
        )
        db.execute(
            "UPDATE uploads SET state='retry', next_attempt=0, "
            "last_error=COALESCE(last_error, 'Prozess während Telegram-Upload beendet') "
            "WHERE state='uploading'"
        )
        db.commit()
    chmod_private(DB_PATH)


def db_get(upload_id: str) -> Optional[sqlite3.Row]:
    with open_db() as db:
        return db.execute("SELECT * FROM uploads WHERE id=?", (upload_id,)).fetchone()


def db_find_sent(resource_key: Optional[str] = None, sha256_hex: Optional[str] = None) -> Optional[sqlite3.Row]:
    with open_db() as db:
        if resource_key:
            row = db.execute(
                "SELECT * FROM uploads WHERE resource_key=? AND state='sent' ORDER BY updated_at DESC LIMIT 1",
                (resource_key,),
            ).fetchone()
            if row:
                return row
        if sha256_hex:
            return db.execute(
                "SELECT * FROM uploads WHERE sha256=? AND state='sent' ORDER BY updated_at DESC LIMIT 1",
                (sha256_hex,),
            ).fetchone()
    return None


def db_insert_receiving(
    upload_id: str,
    resource_key: Optional[str],
    asset_id: Optional[str],
    resource_type: Optional[str],
    filename: str,
    media_kind: str,
    creation_date: Optional[str],
    preserve_original: bool,
    path: str,
    telegram_target: str,
) -> None:
    now = utc_ts()
    with open_db() as db:
        db.execute(
            """
            INSERT OR REPLACE INTO uploads(
                id, resource_key, asset_id, resource_type, filename, media_kind,
                creation_date, preserve_original, path, size, sha256, state,
                upload_offset, complete, received_at, updated_at, attempts,
                next_attempt, last_error, telegram_message_ids, telegram_target,
                telegram_marker
            ) VALUES(?,?,?,?,?,?,?,?,?,0,NULL,'receiving',0,0,?,?,0,0,NULL,NULL,?,NULL)
            """,
            (
                upload_id,
                resource_key,
                asset_id,
                resource_type,
                filename,
                media_kind,
                creation_date,
                1 if preserve_original else 0,
                path,
                now,
                now,
                telegram_target,
            ),
        )
        db.commit()


def db_update_offset(upload_id: str, offset: int) -> None:
    with open_db() as db:
        db.execute(
            "UPDATE uploads SET upload_offset=?, size=?, updated_at=? WHERE id=?",
            (offset, offset, utc_ts(), upload_id),
        )
        db.commit()


def db_mark_ready(upload_id: str, final_path: str, size: int, sha256_hex: str) -> None:
    with open_db() as db:
        db.execute(
            """
            UPDATE uploads
               SET path=?, size=?, sha256=?, state='ready', upload_offset=?, complete=1,
                   updated_at=?, next_attempt=0, last_error=NULL
             WHERE id=?
            """,
            (final_path, size, sha256_hex, size, utc_ts(), upload_id),
        )
        db.commit()


def db_mark_duplicate(upload_id: str, existing: sqlite3.Row) -> None:
    with open_db() as db:
        db.execute(
            """
            UPDATE uploads
               SET state='sent', complete=1, updated_at=?, last_error=NULL,
                   telegram_message_ids=?, telegram_marker=?
             WHERE id=?
            """,
            (
                utc_ts(),
                existing["telegram_message_ids"],
                existing["telegram_marker"],
                upload_id,
            ),
        )
        db.commit()


def db_next_ready() -> Optional[sqlite3.Row]:
    now = utc_ts()
    with open_db() as db:
        return db.execute(
            """
            SELECT * FROM uploads
             WHERE state IN ('ready','retry') AND complete=1 AND next_attempt<=?
             ORDER BY received_at ASC LIMIT 1
            """,
            (now,),
        ).fetchone()


def db_mark_uploading(upload_id: str) -> None:
    with open_db() as db:
        db.execute(
            "UPDATE uploads SET state='uploading', attempts=attempts+1, updated_at=?, last_error=NULL WHERE id=?",
            (utc_ts(), upload_id),
        )
        db.commit()


def db_mark_retry(upload_id: str, message: str, delay: int) -> None:
    with open_db() as db:
        db.execute(
            "UPDATE uploads SET state='retry', next_attempt=?, updated_at=?, last_error=? WHERE id=?",
            (utc_ts() + max(1, delay), utc_ts(), message[:2000], upload_id),
        )
        db.commit()


def db_mark_sent(upload_id: str, message_ids: List[int], marker: str) -> None:
    with open_db() as db:
        db.execute(
            """
            UPDATE uploads
               SET state='sent', updated_at=?, next_attempt=0, last_error=NULL,
                   telegram_message_ids=?, telegram_marker=?
             WHERE id=?
            """,
            (utc_ts(), json.dumps(message_ids), marker, upload_id),
        )
        db.commit()


def db_delete(upload_id: str) -> None:
    with open_db() as db:
        db.execute("DELETE FROM uploads WHERE id=?", (upload_id,))
        db.commit()


def db_counts() -> Dict[str, int]:
    with open_db() as db:
        rows = db.execute("SELECT state, COUNT(*) AS c FROM uploads GROUP BY state").fetchall()
    return {str(row["state"]): int(row["c"]) for row in rows}


def db_recent(limit: int = 25) -> List[Dict[str, Any]]:
    with open_db() as db:
        rows = db.execute(
            """
            SELECT id, resource_key, filename, media_kind, size, state, received_at,
                   updated_at, attempts, next_attempt, last_error, telegram_message_ids
              FROM uploads ORDER BY received_at DESC LIMIT ?
            """,
            (max(1, min(limit, 100)),),
        ).fetchall()
    return [dict(row) for row in rows]


def sanitize_filename(value: Optional[str]) -> str:
    value = unquote(value or "").replace("\\", "/").split("/")[-1].strip()
    value = re.sub(r"[\x00-\x1f\x7f]", "_", value)
    value = value[:240]
    return value or f"TGSpeicher-{uuid.uuid4().hex}.bin"


def header_bool(value: Optional[str], default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on", "?1"}


def normalize_media_kind(value: Optional[str], filename: str) -> str:
    v = (value or "").strip().lower()
    if v in {"photo", "image"}:
        return "photo"
    if v in {"video", "movie"}:
        return "video"
    if v in {"file", "document", "raw", "livephoto", "live-photo"}:
        return "file"
    mime, _ = mimetypes.guess_type(filename)
    if mime and mime.startswith("image/"):
        return "photo"
    if mime and mime.startswith("video/"):
        return "video"
    return "file"


def request_complete(headers: Any) -> bool:
    incomplete = headers.get("Upload-Incomplete")
    if incomplete is not None:
        return not header_bool(incomplete, False)
    complete = headers.get("Upload-Complete")
    if complete is not None:
        return header_bool(complete, False)
    return True


def resource_marker(resource_key: Optional[str], sha256_hex: Optional[str], upload_id: str) -> str:
    key_material = resource_key or sha256_hex or upload_id
    key_hash = hashlib.sha256(key_material.encode("utf-8", errors="replace")).hexdigest()[:24]
    return f"tgsbg_{key_hash}"


def resolve_target(raw: str) -> Any:
    raw = str(raw or "me").strip()
    if raw.lower() in {"me", "self", "saved", "savedmessages"}:
        return "me"
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return raw


@dataclass
class RelayState:
    telegram_connected: bool = False
    telegram_account: str = ""
    telegram_target: str = ""
    premium: Optional[bool] = None
    last_telegram_error: str = ""
    worker_last_activity: float = 0.0


STATE = RelayState()
STATE_LOCK = threading.Lock()


def state_snapshot() -> Dict[str, Any]:
    with STATE_LOCK:
        return {
            "telegram_connected": STATE.telegram_connected,
            "telegram_account": STATE.telegram_account,
            "telegram_target": STATE.telegram_target,
            "premium": STATE.premium,
            "last_telegram_error": STATE.last_telegram_error,
            "worker_last_activity": STATE.worker_last_activity,
        }


async def ensure_telegram_authorized(cfg: Dict[str, Any]) -> None:
    import_telethon()
    client = TelegramClient(str(SESSION_PATH), int(cfg["api_id"]), str(cfg["api_hash"]))
    await client.connect()
    try:
        if not await client.is_user_authorized():
            print("\n=== Telegram-Anmeldung für den VPS ===")
            print("Telegram sendet jetzt einen Anmeldecode. Bei aktivierter 2FA wird danach das Passwort abgefragt.\n")
            await client.start(phone=str(cfg["phone"]))
        me = await client.get_me()
        display = " ".join(x for x in [getattr(me, "first_name", None), getattr(me, "last_name", None)] if x) or str(getattr(me, "id", "Telegram"))
        target = resolve_target(str(cfg.get("telegram_target") or "me"))
        entity = await client.get_entity(target)
        target_name = getattr(entity, "title", None) or getattr(entity, "username", None) or ("Gespeicherte Nachrichten" if target == "me" else str(getattr(entity, "id", target)))
        print(f"Telegram angemeldet als: {display}")
        print(f"Upload-Ziel geprüft: {target_name}\n")
    finally:
        await client.disconnect()
    chmod_private(SESSION_PATH.with_suffix(".session"))


class TelegramWorker(threading.Thread):
    def __init__(self, cfg: Dict[str, Any]):
        super().__init__(name="TGSpeicherTelegramWorker", daemon=True)
        self.cfg = cfg

    def run(self) -> None:
        try:
            asyncio.run(self._run())
        except Exception as exc:
            with STATE_LOCK:
                STATE.telegram_connected = False
                STATE.last_telegram_error = f"Worker beendet: {exc}"
            log(f"Telegram-Worker beendet: {exc}")
            traceback.print_exc()

    async def _run(self) -> None:
        import_telethon()
        client = TelegramClient(str(SESSION_PATH), int(self.cfg["api_id"]), str(self.cfg["api_hash"]))
        while not STOP_EVENT.is_set():
            try:
                if not client.is_connected():
                    await client.connect()
                if not await client.is_user_authorized():
                    raise RuntimeError("Telegram-Session ist nicht autorisiert. Starte das Skript mit --setup erneut.")
                me = await client.get_me()
                target_raw = str(self.cfg.get("telegram_target") or "me")
                target = resolve_target(target_raw)
                target_entity = await client.get_entity(target)
                display = " ".join(x for x in [getattr(me, "first_name", None), getattr(me, "last_name", None)] if x) or str(getattr(me, "id", "Telegram"))
                target_name = getattr(target_entity, "title", None) or getattr(target_entity, "username", None) or ("Gespeicherte Nachrichten" if target == "me" else str(getattr(target_entity, "id", target)))
                with STATE_LOCK:
                    STATE.telegram_connected = True
                    STATE.telegram_account = display
                    STATE.telegram_target = str(target_name)
                    STATE.premium = bool(getattr(me, "premium", False))
                    STATE.last_telegram_error = ""

                row = db_next_ready()
                if not row:
                    await asyncio.sleep(2)
                    continue

                db_mark_uploading(str(row["id"]))
                row = db_get(str(row["id"]))
                if row:
                    await self._upload_one(client, target_entity, row)
            except Exception as exc:
                with STATE_LOCK:
                    STATE.telegram_connected = False
                    STATE.last_telegram_error = str(exc)
                log(f"Telegram-Verbindung/Worker: {exc}")
                with contextlib.suppress(Exception):
                    await client.disconnect()
                await asyncio.sleep(5)
        with contextlib.suppress(Exception):
            await client.disconnect()

    async def _telegram_already_has_marker(self, client: Any, target: Any, marker: str) -> Optional[int]:
        try:
            async for message in client.iter_messages(target, search=marker, limit=8):
                text = (getattr(message, "message", None) or "")
                if marker in text:
                    return int(message.id)
        except Exception as exc:
            log(f"Marker-Suche übersprungen ({marker}): {exc}")
        return None

    async def _upload_one(self, client: Any, target: Any, row: sqlite3.Row) -> None:
        upload_id = str(row["id"])
        path = Path(str(row["path"]))
        if not path.exists():
            db_mark_retry(upload_id, "Lokale Spool-Datei fehlt", 300)
            return

        marker = resource_marker(row["resource_key"], row["sha256"], upload_id)
        existing_id = await self._telegram_already_has_marker(client, target, marker)
        if existing_id is not None:
            log(f"{row['filename']}: bereits auf Telegram gefunden ({marker}), kein Doppelupload")
            db_mark_sent(upload_id, [existing_id], marker)
            if bool(self.cfg.get("delete_after_success", True)):
                with contextlib.suppress(Exception):
                    path.unlink()
            return

        with STATE_LOCK:
            STATE.worker_last_activity = utc_ts()

        attempts = int(row["attempts"] or 1)
        caption_base = (
            f"#TGSpeicherBackgroundV1 {marker}\n"
            f"name={row['filename']}\n"
            f"sha256={str(row['sha256'] or '')[:32]}"
        )
        if row["resource_key"]:
            safe_key = str(row["resource_key"]).replace("\n", " ")[:300]
            caption_base += f"\nsourceKey={safe_key}"

        try:
            ids = await self._send_path(client, target, path, row, caption_base, marker)
            db_mark_sent(upload_id, ids, marker)
            log(f"Telegram ✅ {row['filename']} ({row['size']} Bytes, Nachrichten {ids})")
            if bool(self.cfg.get("delete_after_success", True)):
                with contextlib.suppress(Exception):
                    path.unlink()
        except telethon_errors.FloodWaitError as exc:
            delay = int(getattr(exc, "seconds", 60)) + 2
            db_mark_retry(upload_id, f"Telegram FLOOD_WAIT {delay}s", delay)
            log(f"Telegram FLOOD_WAIT: {delay}s für {row['filename']}")
        except Exception as exc:
            base = max(5, int(self.cfg.get("retry_base_seconds", 15)))
            maximum = max(base, int(self.cfg.get("retry_max_seconds", 1800)))
            delay = min(maximum, base * (2 ** min(max(0, attempts - 1), 7)))
            db_mark_retry(upload_id, f"{type(exc).__name__}: {exc}", delay)
            log(f"Telegram-Upload fehlgeschlagen ({row['filename']}), neuer Versuch in {delay}s: {exc}")

    async def _send_path(
        self,
        client: Any,
        target: Any,
        path: Path,
        row: sqlite3.Row,
        caption_base: str,
        marker: str,
    ) -> List[int]:
        part_limit = int(self.cfg.get("telegram_part_bytes") or DEFAULT_TELEGRAM_PART_BYTES)
        part_limit = max(5 * 1024 * 1024, part_limit)
        size = int(row["size"] or path.stat().st_size)
        media_kind = str(row["media_kind"] or "file")
        preserve_original = bool(row["preserve_original"])
        prefer_native = bool(self.cfg.get("prefer_native_media", True)) and not preserve_original

        if size <= part_limit:
            force_document = not (prefer_native and media_kind in {"photo", "video"})
            kwargs: Dict[str, Any] = {
                "caption": caption_base,
                "force_document": force_document,
            }
            if media_kind == "video" and not force_document:
                kwargs["supports_streaming"] = True
            try:
                message = await client.send_file(target, str(path), **kwargs)
            except Exception:
                if force_document:
                    raise
                message = await client.send_file(target, str(path), caption=caption_base, force_document=True)
            if isinstance(message, list):
                return [int(m.id) for m in message]
            return [int(message.id)]

        total_parts = (size + part_limit - 1) // part_limit
        ids: List[int] = []
        with path.open("rb") as src:
            for index in range(1, total_parts + 1):
                part_name = f"{path.name}.tgs-part-{index:04d}-of-{total_parts:04d}"
                part_path = UPLOAD_DIR / f"{row['id']}-{part_name}"
                try:
                    remaining = min(part_limit, size - (index - 1) * part_limit)
                    with part_path.open("wb") as dst:
                        while remaining > 0:
                            chunk = src.read(min(READ_BLOCK, remaining))
                            if not chunk:
                                raise IOError("Quelldatei endete unerwartet beim Aufteilen")
                            dst.write(chunk)
                            remaining -= len(chunk)
                        dst.flush()
                        os.fsync(dst.fileno())
                    caption = f"{caption_base}\npart={index}/{total_parts}\n{marker}_p{index:04d}"
                    msg = await client.send_file(target, str(part_path), caption=caption, force_document=True)
                    ids.append(int(msg.id))
                finally:
                    with contextlib.suppress(Exception):
                        part_path.unlink()
        return ids


class RelayHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: Tuple[str, int], handler: Any, cfg: Dict[str, Any]):
        super().__init__(address, handler)
        self.cfg = cfg
        self.started_at = utc_ts()


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"TGSpeicherRelay/{VERSION}"

    @property
    def cfg(self) -> Dict[str, Any]:
        return self.server.cfg  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        log(f"HTTP {self.client_address[0]} - {fmt % args}")

    def _json(self, status: int, payload: Dict[str, Any], extra: Optional[Dict[str, str]] = None) -> None:
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-TG-Relay-Version", VERSION)
        if extra:
            for key, value in extra.items():
                self.send_header(key, value)
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(raw)

    def _empty(self, status: int, extra: Optional[Dict[str, str]] = None) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-TG-Relay-Version", VERSION)
        if extra:
            for key, value in extra.items():
                self.send_header(key, value)
        self.end_headers()

    def _authorized(self) -> bool:
        expected = str(self.cfg.get("auth_token") or "")
        supplied = self.headers.get("Authorization", "")
        if not expected or not supplied.startswith("Bearer "):
            return False
        return secrets.compare_digest(supplied[7:].strip(), expected)

    def _require_auth(self) -> bool:
        if self._authorized():
            return True
        self._json(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": "unauthorized"}, {"WWW-Authenticate": "Bearer"})
        return False

    def _path_parts(self) -> List[str]:
        return [p for p in urlparse(self.path).path.split("/") if p]

    def _public_base(self) -> str:
        configured = str(self.cfg.get("public_base_url") or "").strip().rstrip("/")
        if configured:
            return configured
        proto = self.headers.get("X-Forwarded-Proto", "http").split(",")[0].strip()
        host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host") or f"127.0.0.1:{self.cfg['port']}"
        return f"{proto}://{host}".rstrip("/")

    def _upload_location(self, upload_id: str) -> str:
        return f"{self._public_base()}/upload/{upload_id}"

    def _content_length(self) -> Optional[int]:
        raw = self.headers.get("Content-Length")
        if raw is None:
            return None
        try:
            value = int(raw)
            return value if value >= 0 else None
        except ValueError:
            return None

    def _check_disk(self, incoming: int) -> bool:
        try:
            free = shutil.disk_usage(UPLOAD_DIR).free
            reserve = int(self.cfg.get("spool_reserve_bytes") or 0)
            return incoming <= max(0, free - reserve)
        except Exception:
            return True

    def _metadata(self) -> Dict[str, Any]:
        filename_b64 = self.headers.get("X-TG-Filename-B64")
        filename: Optional[str] = None
        if filename_b64:
            try:
                import base64
                filename = base64.urlsafe_b64decode(filename_b64 + "=" * (-len(filename_b64) % 4)).decode("utf-8")
            except Exception:
                filename = None
        filename = sanitize_filename(filename or self.headers.get("X-TG-Filename") or self.headers.get("X-Filename"))
        resource_key = self.headers.get("X-TG-Resource-Key") or self.headers.get("X-Resource-Key")
        asset_id = self.headers.get("X-TG-Asset-ID") or self.headers.get("X-Asset-ID")
        resource_type = self.headers.get("X-TG-Resource-Type") or self.headers.get("X-Resource-Type")
        creation_date = self.headers.get("X-TG-Creation-Date") or self.headers.get("X-Creation-Date")
        media_kind = normalize_media_kind(self.headers.get("X-TG-Media-Kind"), filename)
        preserve_original = header_bool(self.headers.get("X-TG-Preserve-Original"), False)
        return {
            "filename": filename,
            "resource_key": resource_key,
            "asset_id": asset_id,
            "resource_type": resource_type,
            "creation_date": creation_date,
            "media_kind": media_kind,
            "preserve_original": preserve_original,
        }

    def _receive_exact(self, path: Path, length: int, append: bool, start_offset: int = 0) -> int:
        mode = "ab" if append else "wb"
        received = 0
        with path.open(mode) as f:
            while received < length:
                chunk = self.rfile.read(min(READ_BLOCK, length - received))
                if not chunk:
                    break
                f.write(chunk)
                received += len(chunk)
            f.flush()
            os.fsync(f.fileno())
        return start_offset + received

    def _finalize(self, upload_id: str, row: sqlite3.Row) -> Tuple[sqlite3.Row, bool]:
        part_path = Path(str(row["path"]))
        if not part_path.exists():
            raise FileNotFoundError("Upload-Spooldatei fehlt")
        digest = hashlib.sha256()
        size = 0
        with part_path.open("rb") as f:
            while True:
                block = f.read(4 * READ_BLOCK)
                if not block:
                    break
                digest.update(block)
                size += len(block)
        sha = digest.hexdigest()

        existing = db_find_sent(row["resource_key"], sha)
        if existing and str(existing["id"]) != upload_id:
            db_mark_duplicate(upload_id, existing)
            with contextlib.suppress(Exception):
                part_path.unlink()
            return db_get(upload_id) or existing, True

        final_path = UPLOAD_DIR / f"{upload_id}-{sanitize_filename(str(row['filename']))}"
        if final_path != part_path:
            if final_path.exists():
                final_path.unlink()
            os.replace(part_path, final_path)
        db_mark_ready(upload_id, str(final_path), size, sha)
        return db_get(upload_id), False  # type: ignore[return-value]

    def do_GET(self) -> None:
        parts = self._path_parts()
        if parts == ["health"] or parts == []:
            snap = state_snapshot()
            counts = db_counts()
            self._json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "service": APP_NAME,
                    "version": VERSION,
                    "time": iso_now(),
                    "uptime_seconds": int(utc_ts() - self.server.started_at),  # type: ignore[attr-defined]
                    "telegram_connected": snap["telegram_connected"],
                    "queue": counts,
                },
            )
            return
        if parts == ["status"]:
            if not self._require_auth():
                return
            snap = state_snapshot()
            self._json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "service": APP_NAME,
                    "version": VERSION,
                    "time": iso_now(),
                    "telegram": snap,
                    "queue": db_counts(),
                    "recent": db_recent(30),
                    "resumable_uploads": bool(self.cfg.get("resumable_uploads", False)),
                    "max_upload_bytes": int(self.cfg.get("max_upload_bytes") or DEFAULT_MAX_UPLOAD_BYTES),
                },
            )
            return
        self._json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"})

    def do_OPTIONS(self) -> None:
        parts = self._path_parts()
        if not parts or parts[0] != "upload":
            self._empty(HTTPStatus.NO_CONTENT, {"Allow": "GET,HEAD,POST,PATCH,DELETE,OPTIONS"})
            return
        if not self._require_auth():
            return
        if not bool(self.cfg.get("resumable_uploads", False)):
            self._empty(HTTPStatus.NOT_IMPLEMENTED)
            return
        self._empty(
            HTTPStatus.OK,
            {
                "Upload-Limit": str(int(self.cfg.get("max_upload_bytes") or DEFAULT_MAX_UPLOAD_BYTES)),
                "Allow": "POST,PATCH,HEAD,DELETE,OPTIONS",
            },
        )

    def do_HEAD(self) -> None:
        parts = self._path_parts()
        if len(parts) == 2 and parts[0] == "upload":
            if not self._require_auth():
                return
            row = db_get(parts[1])
            if not row:
                self._empty(HTTPStatus.NOT_FOUND)
                return
            complete = bool(row["complete"])
            headers = {
                "Upload-Offset": str(int(row["upload_offset"] or 0)),
                "Upload-Incomplete": "?0" if complete else "?1",
                "Upload-Complete": "?1" if complete else "?0",
                "X-Server-Resource-ID": str(row["id"]),
            }
            self._empty(HTTPStatus.NO_CONTENT, headers)
            return
        self._empty(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        parts = self._path_parts()
        if parts != ["upload"]:
            self._json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"})
            return
        if not self._require_auth():
            return
        length = self._content_length()
        if length is None:
            self._json(HTTPStatus.LENGTH_REQUIRED, {"ok": False, "error": "content_length_required"})
            return
        max_bytes = int(self.cfg.get("max_upload_bytes") or DEFAULT_MAX_UPLOAD_BYTES)
        if length > max_bytes:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"ok": False, "error": "upload_too_large", "max_bytes": max_bytes})
            return
        if not self._check_disk(length):
            self._json(HTTPStatus.INSUFFICIENT_STORAGE, {"ok": False, "error": "insufficient_spool_space"})
            return

        meta = self._metadata()
        upload_id = uuid.uuid4().hex
        part_path = UPLOAD_DIR / f"{upload_id}.part"
        target = str(self.cfg.get("telegram_target") or "me")
        db_insert_receiving(
            upload_id,
            meta["resource_key"],
            meta["asset_id"],
            meta["resource_type"],
            meta["filename"],
            meta["media_kind"],
            meta["creation_date"],
            meta["preserve_original"],
            str(part_path),
            target,
        )

        resumable = bool(self.cfg.get("resumable_uploads", False))
        location = self._upload_location(upload_id)
        if resumable:
            try:
                self.send_response_only(104)
                self.send_header("Location", location)
                self.end_headers()
                self.wfile.flush()
            except Exception:
                pass

        try:
            offset = self._receive_exact(part_path, length, append=False, start_offset=0)
            db_update_offset(upload_id, offset)
            if offset != length:
                if resumable:
                    return
                db_mark_retry(upload_id, "HTTP-Upload unvollständig; erneuter vollständiger Upload nötig", 60)
                self._json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "incomplete_body", "received": offset, "expected": length})
                return

            if resumable and not request_complete(self.headers):
                self._empty(
                    HTTPStatus.CREATED,
                    {
                        "Location": location,
                        "Upload-Offset": str(offset),
                        "Upload-Incomplete": "?1",
                        "Upload-Complete": "?0",
                        "X-Server-Resource-ID": upload_id,
                    },
                )
                return

            row = db_get(upload_id)
            if not row:
                raise RuntimeError("Upload-Datensatz fehlt nach Empfang")
            final_row, duplicate = self._finalize(upload_id, row)
            self._json(
                HTTPStatus.CREATED,
                {
                    "ok": True,
                    "resource_id": upload_id,
                    "state": final_row["state"],
                    "duplicate": duplicate,
                    "telegram_pending": final_row["state"] != "sent",
                },
                {
                    "Location": location,
                    "Upload-Offset": str(int(final_row["size"] or offset)),
                    "Upload-Incomplete": "?0",
                    "Upload-Complete": "?1",
                    "X-Server-Resource-ID": upload_id,
                },
            )
        except (BrokenPipeError, ConnectionResetError):
            with contextlib.suppress(Exception):
                if part_path.exists():
                    db_update_offset(upload_id, part_path.stat().st_size)
        except Exception as exc:
            log(f"HTTP upload finalization error: {exc}")
            self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "error": "server_error", "message": str(exc)})

    def do_PATCH(self) -> None:
        parts = self._path_parts()
        if len(parts) != 2 or parts[0] != "upload":
            self._json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"})
            return
        if not self._require_auth():
            return
        if not bool(self.cfg.get("resumable_uploads", False)):
            self._json(HTTPStatus.NOT_IMPLEMENTED, {"ok": False, "error": "resume_disabled"})
            return
        upload_id = parts[1]
        row = db_get(upload_id)
        if not row:
            self._json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "unknown_upload"})
            return
        if bool(row["complete"]):
            self._json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "upload_already_complete"})
            return

        try:
            requested_offset = int(self.headers.get("Upload-Offset", "-1"))
        except ValueError:
            requested_offset = -1
        current_offset = int(row["upload_offset"] or 0)
        if requested_offset != current_offset:
            self._empty(
                HTTPStatus.CONFLICT,
                {
                    "Upload-Offset": str(current_offset),
                    "Upload-Incomplete": "?1",
                    "Upload-Complete": "?0",
                },
            )
            return
        length = self._content_length()
        if length is None:
            self._json(HTTPStatus.LENGTH_REQUIRED, {"ok": False, "error": "content_length_required"})
            return
        max_bytes = int(self.cfg.get("max_upload_bytes") or DEFAULT_MAX_UPLOAD_BYTES)
        if current_offset + length > max_bytes:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"ok": False, "error": "upload_too_large", "max_bytes": max_bytes})
            return
        if not self._check_disk(length):
            self._json(HTTPStatus.INSUFFICIENT_STORAGE, {"ok": False, "error": "insufficient_spool_space"})
            return

        path = Path(str(row["path"]))
        location = self._upload_location(upload_id)
        try:
            offset = self._receive_exact(path, length, append=True, start_offset=current_offset)
            db_update_offset(upload_id, offset)
            if offset != current_offset + length:
                return
            if not request_complete(self.headers):
                self._empty(
                    HTTPStatus.CREATED,
                    {
                        "Location": location,
                        "Upload-Offset": str(offset),
                        "Upload-Incomplete": "?1",
                        "Upload-Complete": "?0",
                        "X-Server-Resource-ID": upload_id,
                    },
                )
                return
            row = db_get(upload_id)
            if not row:
                raise RuntimeError("Upload-Datensatz fehlt")
            final_row, duplicate = self._finalize(upload_id, row)
            self._json(
                HTTPStatus.CREATED,
                {
                    "ok": True,
                    "resource_id": upload_id,
                    "state": final_row["state"],
                    "duplicate": duplicate,
                    "telegram_pending": final_row["state"] != "sent",
                },
                {
                    "Location": location,
                    "Upload-Offset": str(int(final_row["size"] or offset)),
                    "Upload-Incomplete": "?0",
                    "Upload-Complete": "?1",
                    "X-Server-Resource-ID": upload_id,
                },
            )
        except (BrokenPipeError, ConnectionResetError):
            with contextlib.suppress(Exception):
                if path.exists():
                    db_update_offset(upload_id, path.stat().st_size)
        except Exception as exc:
            self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "error": "server_error", "message": str(exc)})

    def do_DELETE(self) -> None:
        parts = self._path_parts()
        if len(parts) != 2 or parts[0] != "upload":
            self._json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"})
            return
        if not self._require_auth():
            return
        row = db_get(parts[1])
        if not row:
            self._empty(HTTPStatus.NOT_FOUND)
            return
        if str(row["state"]) in {"uploading", "sent"}:
            self._json(HTTPStatus.CONFLICT, {"ok": False, "error": "cannot_cancel_in_state", "state": row["state"]})
            return
        with contextlib.suppress(Exception):
            Path(str(row["path"])).unlink()
        db_delete(parts[1])
        self._empty(HTTPStatus.NO_CONTENT)


def print_config_summary(cfg: Dict[str, Any]) -> None:
    safe = dict(cfg)
    if safe.get("api_hash"):
        safe["api_hash"] = "***"
    if safe.get("auth_token"):
        token = str(safe["auth_token"])
        safe["auth_token"] = token[:6] + "…" + token[-4:]
    print(json.dumps(safe, ensure_ascii=False, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("--setup", action="store_true", help="Konfiguration neu/erneut interaktiv einrichten")
    parser.add_argument("--port", type=int, help="Port nur für diesen Start überschreiben")
    parser.add_argument("--bind", help="Bind-Adresse nur für diesen Start überschreiben")
    parser.add_argument("--show-config", action="store_true", help="Konfiguration ohne Geheimnisse anzeigen und beenden")
    parser.add_argument("--no-auto-install", action="store_true", help="Telethon nicht automatisch via pip installieren")
    args = parser.parse_args()

    cfg = load_config(force_setup=args.setup)
    if args.port is not None:
        cfg["port"] = args.port
    if args.bind is not None:
        cfg["bind_host"] = args.bind
    validate_config(cfg)

    if args.show_config:
        print_config_summary(cfg)
        return

    import_telethon(auto_install=not args.no_auto_install)
    init_db()

    try:
        asyncio.run(ensure_telegram_authorized(cfg))
    except KeyboardInterrupt:
        print("\nAbgebrochen.")
        return
    except Exception as exc:
        raise SystemExit(f"Telegram-Anmeldung/Prüfung fehlgeschlagen: {exc}")

    worker = TelegramWorker(cfg)
    worker.start()

    host = str(cfg.get("bind_host") or DEFAULT_BIND_HOST)
    port = int(cfg.get("port") or DEFAULT_PORT)
    server = RelayHTTPServer((host, port), RelayHandler, cfg)

    print("\n============================================================")
    print(f"{APP_NAME} v{VERSION}")
    print(f"HTTP:  http://{host}:{port}")
    print("Health: /health")
    print("Upload: /upload")
    print(f"Spool:  {UPLOAD_DIR}")
    print(f"DB:     {DB_PATH}")
    print("HTTPS:  bitte per Caddy/nginx/Traefik davor schalten")
    print("============================================================\n")
    if not bool(cfg.get("resumable_uploads", False)):
        log("Apple-Resume-Protokoll ist absichtlich AUS. Normale PhotoKit-Background-Uploads funktionieren; abgebrochene HTTP-Uploads starten neu.")
    else:
        log("Apple-Resume-Protokoll ist AN. Prüfe, ob dein HTTPS-Reverse-Proxy HTTP 104 durchreicht.")

    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        log("Beende Server …")
    finally:
        STOP_EVENT.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=10)


if __name__ == "__main__":
    main()
