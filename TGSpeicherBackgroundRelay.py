#!/usr/bin/env python3
"""TGSpeicher Background Relay 2.1 — single-file VPS relay + web dashboard.

Default listener: 0.0.0.0:8765
Public URL:      https://backup.rjuhas.eu
Runtime state:   ~/.tgspeicher-relay/

First start:
  python3 TGSpeicherBackgroundRelay.py --setup
Then:
  python3 TGSpeicherBackgroundRelay.py

The setup stores only a salted password hash. Telegram API credentials, the
Telethon session, pairing tokens and the durable queue live outside this file.
The web dashboard performs the Telegram phone-code / 2FA login and creates
single-use iPhone pairing codes.
"""
from __future__ import annotations
import argparse, asyncio, base64, contextlib, getpass, hashlib, html, hmac, json
import mimetypes, os, re, secrets, shutil, sqlite3, subprocess, sys, threading, time, uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional
from urllib.parse import parse_qs, quote, unquote, urlparse

APP="TGSpeicher Background Relay"; VERSION="2.1.0"
HOST="0.0.0.0"; PORT=8765; PUBLIC="https://backup.rjuhas.eu"
HOME=Path(os.environ.get("TGS_RELAY_HOME",str(Path.home()/".tgspeicher-relay"))).expanduser()
CONFIG=HOME/"tgs_relay_config.json"; DB=HOME/"relay.sqlite3"; SPOOL=HOME/"uploads"; SESSION=HOME/"tgs_relay"
BLOCK=1024*1024; TG_PART=1_900_000_000; PASSWORD_ROUNDS=600_000
STOP=threading.Event(); WORKER=None; LOGIN_LOCK=threading.Lock(); LOGIN_FAILS:dict[str,list[float]]={}
TelegramClient=None; errors=None; utils=None

def now(): return time.time()
def iso(): return datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
def log(s): print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {s}",flush=True)
def priv(p):
    with contextlib.suppress(Exception): os.chmod(p,0o600)
def shash(s): return hashlib.sha256(s.encode()).hexdigest()
def phash(p):
    salt=secrets.token_bytes(16); d=hashlib.pbkdf2_hmac("sha256",p.encode(),salt,PASSWORD_ROUNDS)
    e=lambda b:base64.urlsafe_b64encode(b).decode().rstrip("=")
    return f"pbkdf2_sha256${PASSWORD_ROUNDS}${e(salt)}${e(d)}"
def pverify(p,v):
    try:
        alg,r,s,d=v.split("$",3); dec=lambda x:base64.urlsafe_b64decode(x+"="*(-len(x)%4))
        return alg=="pbkdf2_sha256" and hmac.compare_digest(hashlib.pbkdf2_hmac("sha256",p.encode(),dec(s),int(r)),dec(d))
    except Exception:return False

def telethon():
    global TelegramClient,errors,utils
    if TelegramClient:return
    try: from telethon import TelegramClient as C,errors as E,utils as U
    except ModuleNotFoundError:
        log("Telethon fehlt; installiere Telethon 1.44.0 …")
        subprocess.check_call([sys.executable,"-m","pip","install","Telethon==1.44.0"])
        from telethon import TelegramClient as C,errors as E,utils as U
    TelegramClient,errors,utils=C,E,U

DEFAULT={"bind_host":HOST,"port":PORT,"public_base_url":PUBLIC,"api_id":0,"api_hash":"","phone":"","telegram_target":"me","web_password_hash":"","max_upload_bytes":50*1024**3,"telegram_part_bytes":TG_PART,"delete_after_success":True,"prefer_native_media":True,"retry_base_seconds":15,"retry_max_seconds":1800,"spool_reserve_bytes":2*1024**3}
def save_cfg(c):
    HOME.mkdir(parents=True,exist_ok=True); os.chmod(HOME,0o700); t=CONFIG.with_suffix(".tmp")
    t.write_text(json.dumps(c,ensure_ascii=False,indent=2)+"\n"); priv(t); os.replace(t,CONFIG); priv(CONFIG)
def ask(s,default=None,secret=False):
    suffix=f" [{default}]" if default not in (None,"") else ""
    while True:
        v=(getpass.getpass if secret else input)(s+suffix+": ").strip()
        if v:return v
        if default is not None:return default
def setup(old=None):
    c=dict(DEFAULT); c.update(old or {}); print("\n=== TGSpeicher Background Relay ===\n")
    c["bind_host"]=ask("Bind-Adresse",str(c.get("bind_host") or HOST)); c["port"]=int(ask("Port",str(c.get("port") or PORT)))
    c["public_base_url"]=ask("Öffentliche HTTPS-Adresse",str(c.get("public_base_url") or PUBLIC)).rstrip("/")
    c["api_id"]=int(ask("Telegram API-ID",str(c.get("api_id")) if c.get("api_id") else None)); c["api_hash"]=ask("Telegram API-Hash",str(c.get("api_hash") or "") or None,True)
    c["phone"]=ask("Telegram Telefonnummer (+49…)",str(c.get("phone") or "") or ""); c["telegram_target"]=ask("Telegram-Ziel (me = Gespeichertes)",str(c.get("telegram_target") or "me"))
    env=os.environ.get("TGS_WEB_PASSWORD","")
    if env:c["web_password_hash"]=phash(env)
    elif not c.get("web_password_hash") or ask("Dashboard-Passwort ändern? (j/N)","N").lower().startswith("j"):
        a=ask("Dashboard-Passwort",secret=True); b=ask("Passwort wiederholen",secret=True)
        if a!=b: raise SystemExit("Passwörter stimmen nicht überein.")
        c["web_password_hash"]=phash(a)
    save_cfg(c); print(f"\nGespeichert: {CONFIG}\nDashboard: {c['public_base_url']}/\nTelegram-Anmeldung anschließend im Dashboard.\n"); return c
def load_cfg(force=False):
    old={}
    if CONFIG.exists():
        with contextlib.suppress(Exception): old=json.loads(CONFIG.read_text())
    if force or not CONFIG.exists():return setup(old)
    c=dict(DEFAULT); c.update(old)
    if not c.get("web_password_hash"):
        if not sys.stdin.isatty():raise SystemExit("Kein Dashboard-Passwort. Einmal --setup ausführen.")
        c=setup(c)
    return c

def conn():
    HOME.mkdir(parents=True,exist_ok=True); SPOOL.mkdir(parents=True,exist_ok=True)
    x=sqlite3.connect(DB,timeout=30,check_same_thread=False); x.row_factory=sqlite3.Row
    x.execute("PRAGMA journal_mode=WAL"); x.execute("PRAGMA synchronous=FULL"); return x
def init_db():
    with conn() as d:
        d.executescript("""
        CREATE TABLE IF NOT EXISTS uploads(id TEXT PRIMARY KEY,resource_key TEXT,asset_id TEXT,resource_type TEXT,filename TEXT NOT NULL,media_kind TEXT NOT NULL,creation_date TEXT,path TEXT NOT NULL,size INTEGER NOT NULL DEFAULT 0,sha256 TEXT,state TEXT NOT NULL,received REAL NOT NULL,updated REAL NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,next_attempt REAL NOT NULL DEFAULT 0,last_error TEXT,message_ids TEXT,target TEXT,device_id TEXT);
        CREATE INDEX IF NOT EXISTS uploads_next ON uploads(state,next_attempt,received);
        CREATE INDEX IF NOT EXISTS uploads_resource ON uploads(resource_key);
        CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,name TEXT NOT NULL,token_hash TEXT NOT NULL UNIQUE,created REAL NOT NULL,last_seen REAL NOT NULL,last_upload REAL,revoked INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS pairing(code_hash TEXT PRIMARY KEY,label TEXT,expires REAL NOT NULL,used REAL);
        CREATE TABLE IF NOT EXISTS web_sessions(token_hash TEXT PRIMARY KEY,csrf TEXT NOT NULL,expires REAL NOT NULL,last_seen REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT,at REAL NOT NULL,kind TEXT NOT NULL,message TEXT NOT NULL);
        """)
        d.execute("UPDATE uploads SET state='retry',next_attempt=0,last_error=COALESCE(last_error,'Relay-Neustart während Telegram-Upload') WHERE state='uploading'")
        d.execute("DELETE FROM web_sessions WHERE expires<?",(now(),)); d.commit(); priv(DB)
def event(k,m):
    with conn() as d:
        d.execute("INSERT INTO events(at,kind,message) VALUES(?,?,?)",(now(),k[:30],m[:1000])); d.execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 500)"); d.commit()
def one(q,a=()):
    with conn() as d:return d.execute(q,a).fetchone()
def rows(q,a=()):
    with conn() as d:return [dict(x) for x in d.execute(q,a).fetchall()]
def execute(q,a=()):
    with conn() as d:d.execute(q,a);d.commit()
def counts():
    r={str(x["state"]):int(x["c"]) for x in rows("SELECT state,COUNT(*) c FROM uploads GROUP BY state")};r["total"]=sum(r.values());return r

def pairing(label):
    code="-".join(f"{secrets.randbelow(1000):03d}" for _ in range(3)); execute("INSERT INTO pairing(code_hash,label,expires,used) VALUES(?,?,?,NULL)",(shash(code),label[:80],now()+600)); event("pairing",f"Pairing-Code für {label}");return code
def pair_exchange(code,name):
    h=shash(code.strip()); r=one("SELECT * FROM pairing WHERE code_hash=? AND used IS NULL AND expires>?",(h,now()))
    if not r:return None
    token=secrets.token_urlsafe(48); did=uuid.uuid4().hex
    with conn() as d:
        d.execute("INSERT INTO devices(id,name,token_hash,created,last_seen,last_upload,revoked) VALUES(?,?,?,?,?,NULL,0)",(did,(name or r['label'] or 'iPhone')[:100],shash(token),now(),now()));d.execute("UPDATE pairing SET used=? WHERE code_hash=?",(now(),h));d.commit()
    event("device",f"Gekoppelt: {name or 'iPhone'}");return did,token
def device(token,touch=False,upload=False):
    if not token:return None
    r=one("SELECT * FROM devices WHERE token_hash=? AND revoked=0",(shash(token),))
    if r and touch: execute("UPDATE devices SET last_seen=?,last_upload=CASE WHEN ? THEN ? ELSE last_upload END WHERE id=?",(now(),1 if upload else 0,now(),r['id']))
    return r

def web_issue():
    t=secrets.token_urlsafe(48); csrf=secrets.token_urlsafe(24);execute("INSERT INTO web_sessions(token_hash,csrf,expires,last_seen) VALUES(?,?,?,?)",(shash(t),csrf,now()+7*86400,now()));return t,csrf
def web_get(t):
    r=one("SELECT * FROM web_sessions WHERE token_hash=? AND expires>?",(shash(t),now())) if t else None
    if r:execute("UPDATE web_sessions SET last_seen=? WHERE token_hash=?",(now(),shash(t)))
    return r

def clean_name(v):return (re.sub(r"[\r\n\\/]","_",os.path.basename((v or "Upload.bin").replace("\0",""))).strip()[:240] or "Upload.bin")
def media_kind(v,name):
    v=(v or "").lower()
    if v in {"photo","video","file"}:return v
    m=mimetypes.guess_type(name)[0] or "";return "photo" if m.startswith("image/") else "video" if m.startswith("video/") else "file"
def target(v):
    v=str(v or "me").strip();return "me" if v.lower() in {"me","self","saved","savedmessages"} else int(v) if re.fullmatch(r"-?\d+",v) else v
def stable_uuid(sha,chat):
    b=bytearray(hashlib.sha256(f"TGSpeicher.media.v3|{chat}|{sha}".encode()).digest()[:16]);b[6]=(b[6]&15)|80;b[8]=(b[8]&63)|128;return str(uuid.UUID(bytes=bytes(b))).upper()
def marker(resource,sha,uid):return "tgsbg_"+hashlib.sha256((resource or sha or uid).encode()).hexdigest()[:24]
def manifest(r,chat,kind,index,count,part_sha,mark):
    date=r["creation_date"] or iso(); sha=str(r["sha256"] or "")
    obj={"format":3 if kind.startswith("native") else 2,"kind":kind,"fileID":stable_uuid(sha,chat),"folderID":None,"parentFolderID":None,"name":r["filename"],"originalSize":int(r["size"]),"chunkIndex":index,"chunkCount":count,"createdAt":date,"tagIDs":[],"sha256":part_sha if kind=="fileChunk" else None,"sourceKey":r["resource_key"],"mediaKind":r["media_kind"],"assetLocalIdentifier":r["asset_id"],"resourceTypeRawValue":int(r["resource_type"]) if str(r["resource_type"] or "").lstrip("-").isdigit() else None,"mediaCreationDate":date if r["creation_date"] else None}
    enc=base64.b64encode(json.dumps(obj,separators=(",",":"),ensure_ascii=False).encode()).decode();return f"#TGSpeicherV2 {enc}\n#TGSpeicherBackgroundV2 {mark}"
def decoded(text):
    m=re.search(r"#TGSpeicherV2\s+([A-Za-z0-9+/=]+)",text or "")
    try:return json.loads(base64.b64decode(m.group(1))) if m else None
    except Exception:return None

@dataclass
class State:
    connected:bool=False; account:str=""; target_name:str=""; target_id:Optional[int]=None; premium:Optional[bool]=None; auth:str="not_authorized"; error:str=""; active_file:str=""; active_sent:int=0; active_total:int=0; last_activity:float=0
STATE=State(); STATE_LOCK=threading.Lock()
def snapshot():
    with STATE_LOCK:return dict(STATE.__dict__)

class TgWorker(threading.Thread):
    def __init__(self,cfg):super().__init__(daemon=True);self.cfg=cfg;self.loop=None;self.client=None;self.ready=threading.Event();self.phone=str(cfg.get("phone") or "")
    def run(self):
        self.loop=asyncio.new_event_loop();asyncio.set_event_loop(self.loop);self.ready.set()
        try:self.loop.run_until_complete(self.main())
        except Exception as e:
            with STATE_LOCK:STATE.error=str(e);STATE.connected=False
        finally:
            if self.client:
                with contextlib.suppress(Exception):self.loop.run_until_complete(self.client.disconnect())
            self.loop.close()
    async def main(self):
        telethon();self.client=TelegramClient(str(SESSION),int(self.cfg["api_id"]),str(self.cfg["api_hash"]));await self.client.connect();priv(SESSION.with_suffix(".session"))
        while not STOP.is_set():
            try:
                if not self.client.is_connected():await self.client.connect()
                if not await self.client.is_user_authorized():
                    with STATE_LOCK:STATE.connected=False
                    await asyncio.sleep(1.5);continue
                await self.profile();r=one("SELECT * FROM uploads WHERE state IN ('ready','retry') AND next_attempt<=? ORDER BY received LIMIT 1",(now(),))
                if not r:await asyncio.sleep(1.5);continue
                execute("UPDATE uploads SET state='uploading',attempts=attempts+1,updated=?,last_error=NULL WHERE id=?",(now(),r['id']));await self.upload(one("SELECT * FROM uploads WHERE id=?",(r['id'],)))
            except Exception as e:
                with STATE_LOCK:STATE.error=str(e)
                await asyncio.sleep(3)
    async def profile(self):
        me=await self.client.get_me(); ent=await self.client.get_entity(target(self.cfg.get("telegram_target"))); tid=int(utils.get_peer_id(ent));name=" ".join(filter(None,[getattr(me,"first_name",None),getattr(me,"last_name",None)])) or str(me.id)
        tn=getattr(ent,"title",None) or getattr(ent,"username",None) or ("Gespeicherte Nachrichten" if target(self.cfg.get("telegram_target"))=="me" else str(tid))
        with STATE_LOCK:STATE.connected=True;STATE.account=name;STATE.target_name=str(tn);STATE.target_id=tid;STATE.premium=bool(getattr(me,"premium",False));STATE.auth="authorized";STATE.error=""
    def submit(self,coro,timeout=45):
        if not self.ready.wait(5):raise RuntimeError("Telegram-Worker startet noch")
        return asyncio.run_coroutine_threadsafe(coro,self.loop).result(timeout)
    async def send_code_async(self,phone):
        self.phone=phone.strip();self.cfg["phone"]=self.phone;save_cfg(self.cfg);await self.client.send_code_request(self.phone)
        with STATE_LOCK:STATE.auth="code_sent";STATE.error=""
    def send_code(self,p):return self.submit(self.send_code_async(p))
    async def verify_async(self,code):
        try:await self.client.sign_in(phone=self.phone or self.cfg.get("phone"),code=code.strip());await self.profile();event("telegram","Telegram angemeldet");return "ok"
        except errors.SessionPasswordNeededError:
            with STATE_LOCK:STATE.auth="password_needed"
            return "2fa"
    def verify(self,c):return self.submit(self.verify_async(c))
    async def password_async(self,p):await self.client.sign_in(password=p);await self.profile();event("telegram","Telegram 2FA bestätigt")
    def password(self,p):return self.submit(self.password_async(p))
    async def logout_async(self,reset):
        with contextlib.suppress(Exception):
            if await self.client.is_user_authorized():await self.client.log_out()
        await self.client.disconnect()
        if reset:
            for p in HOME.glob("tgs_relay.session*"):
                with contextlib.suppress(Exception):p.unlink()
        self.client=TelegramClient(str(SESSION),int(self.cfg["api_id"]),str(self.cfg["api_hash"]));await self.client.connect()
        with STATE_LOCK:STATE.connected=False;STATE.auth="not_authorized";STATE.account="";STATE.target_name="";STATE.target_id=None
    def logout(self,reset=False):return self.submit(self.logout_async(reset))
    async def already(self,ent,r,m):
        with contextlib.suppress(Exception):
            async for msg in self.client.iter_messages(ent,search=m,limit=10):
                if m in (msg.message or ""):return int(msg.id)
        key=str(r["resource_key"] or "")
        if key:
            with contextlib.suppress(Exception):
                async for msg in self.client.iter_messages(ent,search="#TGSpeicherV2",limit=250):
                    x=decoded(msg.message or "")
                    if x and x.get("sourceKey")==key:return int(msg.id)
        return None
    async def progress(self,sent,total):
        with STATE_LOCK:STATE.active_sent=int(sent);STATE.active_total=int(total);STATE.last_activity=now()
    async def upload(self,r):
        uid=str(r['id']);p=Path(r['path'])
        if not p.exists():execute("UPDATE uploads SET state='retry',next_attempt=?,last_error=? WHERE id=?",(now()+300,"Spool-Datei fehlt",uid));return
        ent=await self.client.get_entity(target(r['target'] or self.cfg.get('telegram_target')));chat=int(utils.get_peer_id(ent));m=marker(r['resource_key'],r['sha256'],uid);old=await self.already(ent,r,m)
        if old:
            execute("UPDATE uploads SET state='sent',updated=?,message_ids=?,last_error=NULL WHERE id=?",(now(),json.dumps([old]),uid));p.unlink(missing_ok=True);event("upload",f"Duplikat vermieden: {r['filename']}");return
        with STATE_LOCK:STATE.active_file=r['filename'];STATE.active_sent=0;STATE.active_total=int(r['size']);STATE.last_activity=now()
        try:
            ids=await self.send_path(ent,chat,p,r,m);execute("UPDATE uploads SET state='sent',updated=?,message_ids=?,last_error=NULL WHERE id=?",(now(),json.dumps(ids),uid));event("upload",f"Telegram ✅ {r['filename']}")
            if self.cfg.get("delete_after_success",True):p.unlink(missing_ok=True)
        except errors.FloodWaitError as e:
            delay=int(getattr(e,"seconds",60))+2;execute("UPDATE uploads SET state='retry',next_attempt=?,updated=?,last_error=? WHERE id=?",(now()+delay,now(),f"FLOOD_WAIT {delay}s",uid));event("flood",f"FLOOD_WAIT {delay}s")
        except Exception as e:
            attempts=int(r['attempts'] or 1);base=int(self.cfg.get('retry_base_seconds',15));mx=int(self.cfg.get('retry_max_seconds',1800));delay=min(mx,base*2**min(attempts,7));execute("UPDATE uploads SET state='retry',next_attempt=?,updated=?,last_error=? WHERE id=?",(now()+delay,now(),str(e)[:1500],uid));event("error",f"{r['filename']}: {e}")
        finally:
            with STATE_LOCK:STATE.active_file="";STATE.active_sent=0;STATE.active_total=0
    async def send_path(self,ent,chat,p,r,m):
        limit=int(self.cfg.get("telegram_part_bytes") or TG_PART);size=int(r['size']);kind=str(r['media_kind']);native=bool(self.cfg.get('prefer_native_media',True)) and kind in {'photo','video'}
        if size<=limit:
            if native:
                try:
                    cap=manifest(r,chat,"nativePhoto" if kind=='photo' else "nativeVideo",1,1,None,m);kw={"caption":cap,"force_document":False,"progress_callback":self.progress}
                    if kind=='video':kw['supports_streaming']=True
                    msg=await self.client.send_file(ent,str(p),**kw);return [int(x.id) for x in msg] if isinstance(msg,list) else [int(msg.id)]
                except Exception:pass
            msg=await self.client.send_file(ent,str(p),caption=manifest(r,chat,"fileChunk",1,1,r['sha256'],m),force_document=True,progress_callback=self.progress);return [int(msg.id)]
        total=(size+limit-1)//limit;ids=[]
        with p.open('rb') as src:
            for i in range(1,total+1):
                q=SPOOL/f"{r['id']}.part-{i:05d}-of-{total:05d}";h=hashlib.sha256();left=min(limit,size-(i-1)*limit)
                with q.open('wb') as out:
                    while left:
                        b=src.read(min(BLOCK,left));
                        if not b:raise IOError("Quelldatei unerwartet zu Ende")
                        out.write(b);h.update(b);left-=len(b)
                    out.flush();os.fsync(out.fileno())
                try:
                    msg=await self.client.send_file(ent,str(q),caption=manifest(r,chat,'fileChunk',i,total,h.hexdigest(),m),force_document=True,progress_callback=self.progress);ids.append(int(msg.id))
                finally:q.unlink(missing_ok=True)
        return ids

class Server(ThreadingHTTPServer):
    daemon_threads=True;allow_reuse_address=True
    def __init__(self,a,h,c):super().__init__(a,h);self.cfg=c;self.started=now()
class Handler(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1";server_version=f"TGSpeicherRelay/{VERSION}"
    @property
    def cfg(self):return self.server.cfg
    def log_message(self,f,*a):log(f"HTTP {self.client_address[0]} - {f%a}")
    def sendb(self,status,ctype,data,extra=None):
        self.send_response(status);self.send_header("Content-Type",ctype);self.send_header("Content-Length",str(len(data)));self.send_header("Cache-Control","no-store");self.send_header("X-Content-Type-Options","nosniff");self.send_header("X-Frame-Options","DENY");self.send_header("Referrer-Policy","no-referrer")
        for k,v in (extra or {}).items():self.send_header(k,str(v))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError,ConnectionResetError):self.wfile.write(data)
    def js(self,s,o,extra=None):self.sendb(s,"application/json; charset=utf-8",json.dumps(o,ensure_ascii=False,separators=(",",":")).encode(),extra)
    def page(self,title,body):
        css="body{margin:0;background:#080b14;color:#f7f8ff;font:15px -apple-system,BlinkMacSystemFont,sans-serif}.w{max-width:1100px;margin:auto;padding:28px 16px 70px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(235px,1fr));gap:14px}.c{background:rgba(255,255,255,.075);border:1px solid rgba(255,255,255,.12);border-radius:22px;padding:18px;margin-bottom:14px;backdrop-filter:blur(25px)}h1{font-size:30px;margin:3px 0 20px}h2{font-size:18px}small,.muted{color:#aab2c8}.good{color:#4bd28a}.bad{color:#ff6b77}.big{font-size:26px;font-weight:700}input{width:100%;box-sizing:border-box;padding:11px;margin:5px 0 10px;border:1px solid #ffffff25;border-radius:12px;background:#0005;color:#fff}button{padding:10px 14px;border:0;border-radius:12px;font-weight:650;cursor:pointer}.secondary{background:#ffffff18;color:#fff}.danger{background:#a93645;color:white}table{width:100%;border-collapse:collapse}td,th{padding:9px;border-bottom:1px solid #ffffff18;text-align:left}code{background:#0006;padding:4px 7px;border-radius:8px}"
        return f"<!doctype html><html lang=de><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><meta http-equiv=refresh content=20><title>{html.escape(title)} · TGSpeicher</title><style>{css}</style><body><div class=w>{body}</div></body></html>"
    def parts(self):return [unquote(x) for x in urlparse(self.path).path.split('/') if x]
    def query(self):return parse_qs(urlparse(self.path).query)
    def length(self):
        try:return int(self.headers.get('Content-Length','0'))
        except:return 0
    def form(self):
        x=parse_qs(self.rfile.read(min(self.length(),1024*1024)).decode(errors='replace'));return {k:(v[-1] if v else '') for k,v in x.items()}
    def body(self):
        try:return json.loads(self.rfile.read(min(self.length(),1024*1024)))
        except:return {}
    def cookie(self):
        c=SimpleCookie();
        with contextlib.suppress(Exception):c.load(self.headers.get('Cookie',''))
        return c.get('tgs_session').value if c.get('tgs_session') else ''
    def session(self):return web_get(self.cookie())
    def redirect(self,u,cookie=None):self.sendb(303,"text/plain",b"",{"Location":u,**({"Set-Cookie":cookie} if cookie else {})})
    def bearer(self):
        h=self.headers.get('Authorization','');return h[7:].strip() if h.startswith('Bearer ') else ''
    def api(self,upload=False):
        d=device(self.bearer(),True,upload)
        if not d:self.js(401,{"ok":False,"error":"unauthorized"},{"WWW-Authenticate":"Bearer"});raise PermissionError
        return d
    def require_web(self):
        s=self.session()
        if not s:self.redirect('/login');return None
        return s
    def csrf(self,s,f):return hmac.compare_digest(str(s['csrf']),str(f.get('csrf') or ''))
    def client_ip(self):return (self.headers.get('X-Real-IP') or self.client_address[0]).split(',')[0]
    def login_page(self,msg=''):
        e=f"<p class=bad>{html.escape(msg)}</p>" if msg else ''
        return self.page('Anmelden',f"<div class=c style='max-width:420px;margin:10vh auto'><small>TGSpeicher</small><h1>Background Relay</h1>{e}<form method=post action=/login><input type=password name=password placeholder='Dashboard-Passwort' required autofocus><button>Anmelden</button></form></div>")
    def fmt_time(self,t):return 'Noch nie' if not t else datetime.fromtimestamp(float(t)).strftime('%d.%m.%Y %H:%M:%S')
    def fmt_size(self,n):
        n=float(n or 0)
        for u in ['B','KB','MB','GB','TB']:
            if n<1024:return f"{n:.1f} {u}"
            n/=1024
        return f"{n:.1f} PB"
    def dashboard(self,s,paircode='',msg=''):
        st=snapshot();cs=counts();dev=rows("SELECT id,name,created,last_seen,last_upload,revoked FROM devices ORDER BY created DESC");ups=rows("SELECT filename,size,state,updated,last_error FROM uploads ORDER BY received DESC LIMIT 25");ev=rows("SELECT at,kind,message FROM events ORDER BY id DESC LIMIT 15");disk=shutil.disk_usage(SPOOL);csrf=html.escape(str(s['csrf']))
        active=[x for x in dev if not x['revoked']];last=max([x['last_seen'] or 0 for x in active] or [0]);lastup=max([x['last_upload'] or 0 for x in active] or [0]);pct=int(100*st['active_sent']/st['active_total']) if st['active_total'] else 0
        notice=f"<div class=c><b>{html.escape(msg)}</b></div>" if msg else '';pairbox=f"<div class=c><h2>Einmal-Code</h2><div class=big><code>{html.escape(paircode)}</code></div><p class=muted>10 Minuten gültig, nur einmal verwendbar.</p></div>" if paircode else ''
        if st['connected']:
            tg=f"<div class='big good'>Verbunden</div><b>{html.escape(st['account'])}</b><p class=muted>Ziel: {html.escape(st['target_name'])}</p><form method=post action=/web/telegram/logout><input type=hidden name=csrf value='{csrf}'><button class=secondary>Abmelden</button></form> <form method=post action=/web/telegram/reset style='display:inline'><input type=hidden name=csrf value='{csrf}'><button class=danger>Session zurücksetzen</button></form>"
        elif st['auth']=='code_sent':tg=f"<div class='big bad'>Code erwartet</div><form method=post action=/web/telegram/verify><input type=hidden name=csrf value='{csrf}'><input name=code placeholder='Telegram-Code' required><button>Bestätigen</button></form>"
        elif st['auth']=='password_needed':tg=f"<div class='big bad'>2FA erwartet</div><form method=post action=/web/telegram/password><input type=hidden name=csrf value='{csrf}'><input type=password name=password placeholder='Telegram 2FA-Passwort' required><button>2FA bestätigen</button></form>"
        else:tg=f"<div class='big bad'>Nicht angemeldet</div><form method=post action=/web/telegram/code><input type=hidden name=csrf value='{csrf}'><input name=phone value='{html.escape(str(self.cfg.get('phone') or ''))}' placeholder='+49…' required><button>Telegram-Code senden</button></form>"
        dr=''.join(f"<tr><td>{html.escape(x['name'])}</td><td>{self.fmt_time(x['last_seen'])}</td><td>{self.fmt_time(x['last_upload'])}</td><td>{'Widerrufen' if x['revoked'] else f'''<form method=post action=/web/device/revoke><input type=hidden name=csrf value='{csrf}'><input type=hidden name=device_id value='{x['id']}'><button class=secondary>Trennen</button></form>'''}</td></tr>" for x in dev)
        ur=''.join(f"<tr><td>{html.escape(x['filename'])}</td><td>{self.fmt_size(x['size'])}</td><td>{html.escape(x['state'])}</td><td>{self.fmt_time(x['updated'])}</td></tr>" for x in ups);er=''.join(f"<tr><td>{self.fmt_time(x['at'])}</td><td>{html.escape(x['kind'])}</td><td>{html.escape(x['message'])}</td></tr>" for x in ev)
        return self.page('Dashboard',f"<div style='display:flex;justify-content:space-between'><div><small>TGSpeicher</small><h1>Background Relay</h1></div><form method=post action=/logout><input type=hidden name=csrf value='{csrf}'><button class=secondary>Dashboard abmelden</button></form></div>{notice}<div class=grid><div class=c><h2>Telegram</h2>{tg}</div><div class=c><h2>iPhone</h2><div class=big>{len(active)} gekoppelt</div><p class=muted>Letzter Kontakt: {self.fmt_time(last)}<br>Letzter Upload: {self.fmt_time(lastup)}</p></div><div class=c><h2>Upload-Queue</h2><div class=big>{cs.get('ready',0)+cs.get('retry',0)+cs.get('uploading',0)}</div><p class=muted>Telegram gesendet: {cs.get('sent',0)}</p></div><div class=c><h2>Aktiv</h2><div class=big>{pct}%</div><p>{html.escape(st['active_file'] or 'Kein Telegram-Upload')}</p></div><div class=c><h2>VPS</h2><div class=big>{self.fmt_size(disk.free)} frei</div><p class=muted>{self.fmt_size(disk.used)} belegt</p></div></div><div class=grid><div class=c><h2>iPhone koppeln</h2><form method=post action=/web/pairing/new><input type=hidden name=csrf value='{csrf}'><input name=label value='Mein iPhone'><button>Einmal-Code erzeugen</button></form></div><div class=c><h2>Telegram-Ziel</h2><form method=post action=/web/config/target><input type=hidden name=csrf value='{csrf}'><input name=target value='{html.escape(str(self.cfg.get('telegram_target') or 'me'))}'><button>Speichern</button></form><p class=muted>me = Gespeicherte Nachrichten</p></div></div>{pairbox}<div class=c><h2>Geräte</h2><table><tr><th>Name</th><th>Kontakt</th><th>Upload</th><th></th></tr>{dr or '<tr><td colspan=4>Noch kein Gerät</td></tr>'}</table></div><div class=c><h2>Letzte Uploads</h2><table><tr><th>Datei</th><th>Größe</th><th>Status</th><th>Zeit</th></tr>{ur or '<tr><td colspan=4>Noch keine Uploads</td></tr>'}</table></div><div class=c><h2>Ereignisse</h2><table>{er}</table></div>")
    def metadata(self):
        name=None;b64=self.headers.get('X-TG-Filename-B64')
        if b64:
            with contextlib.suppress(Exception):name=base64.urlsafe_b64decode(b64+'='*(-len(b64)%4)).decode()
        name=clean_name(name or self.headers.get('X-TG-Filename') or self.headers.get('X-Filename'))
        return {"filename":name,"resource_key":self.headers.get('X-TG-Resource-Key'),"asset_id":self.headers.get('X-TG-Asset-ID'),"resource_type":self.headers.get('X-TG-Resource-Type'),"creation_date":self.headers.get('X-TG-Creation-Date'),"media_kind":media_kind(self.headers.get('X-TG-Media-Kind'),name)}
    def do_GET(self):
        p=self.parts()
        if p==['health']:self.js(200,{"ok":True,"version":VERSION,"telegram_connected":snapshot()['connected'],"queue":counts(),"time":iso()});return
        if p==['api','device','status']:
            try:d=self.api()
            except PermissionError:return
            self.js(200,{"ok":True,"version":VERSION,"telegram":snapshot(),"queue":counts(),"device":{"id":d['id'],"name":d['name'],"last_seen":d['last_seen'],"last_upload":d['last_upload']}});return
        if p==['login']:self.sendb(200,"text/html; charset=utf-8",self.login_page().encode());return
        if not p:
            s=self.require_web()
            if not s:return
            q=self.query();self.sendb(200,"text/html; charset=utf-8",self.dashboard(s,(q.get('pairing') or [''])[0],(q.get('message') or [''])[0]).encode());return
        self.js(404,{"ok":False,"error":"not_found"})
    def do_POST(self):
        p=self.parts()
        if p==['login']:
            ip=self.client_ip();cut=now()-600
            with LOGIN_LOCK:
                LOGIN_FAILS[ip]=[x for x in LOGIN_FAILS.get(ip,[]) if x>cut];allowed=len(LOGIN_FAILS[ip])<8
            if not allowed:self.sendb(429,"text/html",self.login_page('Zu viele Fehlversuche.').encode());return
            f=self.form()
            if not pverify(f.get('password',''),self.cfg['web_password_hash']):
                with LOGIN_LOCK:LOGIN_FAILS[ip].append(now())
                self.sendb(401,"text/html",self.login_page('Passwort falsch.').encode());return
            tok,_=web_issue();self.redirect('/',f"tgs_session={tok}; Path=/; HttpOnly; SameSite=Strict; Secure; Max-Age={7*86400}");return
        if p==['api','pair']:
            b=self.body();r=pair_exchange(str(b.get('code') or ''),str(b.get('device_name') or 'iPhone'))
            if not r:self.js(401,{"ok":False,"error":"invalid_or_expired_pairing_code"});return
            self.js(201,{"ok":True,"device_id":r[0],"device_token":r[1],"base_url":self.cfg['public_base_url']});return
        if p==['upload']:self.upload_post();return
        s=self.require_web()
        if not s:return
        f=self.form()
        if not self.csrf(s,f):self.js(403,{"ok":False,"error":"csrf"});return
        if p==['logout']:execute("DELETE FROM web_sessions WHERE token_hash=?",(shash(self.cookie()),));self.redirect('/login','tgs_session=; Path=/; Max-Age=0; Secure');return
        if p==['web','pairing','new']:self.redirect('/?pairing='+quote(pairing(f.get('label') or 'iPhone')));return
        if p==['web','device','revoke']:execute("UPDATE devices SET revoked=1 WHERE id=?",(f.get('device_id'),));self.redirect('/?message='+quote('Gerät getrennt.'));return
        if p==['web','config','target']:self.cfg['telegram_target']=(f.get('target') or 'me').strip();save_cfg(self.cfg);self.redirect('/?message='+quote('Telegram-Ziel gespeichert.'));return
        try:
            if p==['web','telegram','code']:WORKER.send_code(f.get('phone',''));self.redirect('/?message='+quote('Telegram-Code angefordert.'));return
            if p==['web','telegram','verify']:r=WORKER.verify(f.get('code',''));self.redirect('/?message='+quote('2FA-Passwort erforderlich.' if r=='2fa' else 'Telegram verbunden.'));return
            if p==['web','telegram','password']:WORKER.password(f.get('password',''));self.redirect('/?message='+quote('Telegram verbunden.'));return
            if p==['web','telegram','logout']:WORKER.logout(False);self.redirect('/?message='+quote('Telegram abgemeldet.'));return
            if p==['web','telegram','reset']:WORKER.logout(True);self.redirect('/?message='+quote('Telegram-Session zurückgesetzt.'));return
        except Exception as e:event('error',f'Telegram-Anmeldung: {e}');self.redirect('/?message='+quote('Telegram-Fehler: '+str(e)));return
        self.js(404,{"ok":False,"error":"not_found"})
    def upload_post(self):
        try:d=self.api(upload=True)
        except PermissionError:return
        length=self.length();mx=int(self.cfg.get('max_upload_bytes') or DEFAULT['max_upload_bytes'])
        if length<=0:self.js(411,{"ok":False,"error":"content_length_required"});return
        if length>mx:self.js(413,{"ok":False,"error":"too_large","max":mx});return
        reserve=int(self.cfg.get('spool_reserve_bytes') or 0)
        if length>max(0,shutil.disk_usage(SPOOL).free-reserve):self.js(507,{"ok":False,"error":"insufficient_storage"});return
        meta=self.metadata();uid=uuid.uuid4().hex;part=SPOOL/(uid+'.part');received=0
        execute("INSERT INTO uploads(id,resource_key,asset_id,resource_type,filename,media_kind,creation_date,path,size,sha256,state,received,updated,attempts,next_attempt,last_error,message_ids,target,device_id) VALUES(?,?,?,?,?,?,?,?,0,NULL,'receiving',?,?,0,0,NULL,NULL,?,?)",(uid,meta['resource_key'],meta['asset_id'],meta['resource_type'],meta['filename'],meta['media_kind'],meta['creation_date'],str(part),now(),now(),str(self.cfg.get('telegram_target') or 'me'),d['id']))
        try:
            h=hashlib.sha256()
            with part.open('wb') as out:
                while received<length:
                    b=self.rfile.read(min(BLOCK,length-received))
                    if not b:break
                    out.write(b);h.update(b);received+=len(b)
                out.flush();os.fsync(out.fileno())
            if received!=length:
                execute("UPDATE uploads SET state='retry',size=?,updated=?,last_error=? WHERE id=?",(received,now(),'HTTP body incomplete',uid));return
            sha=h.hexdigest();old=one("SELECT * FROM uploads WHERE id<>? AND state='sent' AND ((resource_key IS NOT NULL AND resource_key=?) OR sha256=?) ORDER BY updated DESC LIMIT 1",(uid,meta['resource_key'],sha))
            if old:
                execute("UPDATE uploads SET state='sent',size=?,sha256=?,updated=?,message_ids=? WHERE id=?",(received,sha,now(),old['message_ids'],uid));part.unlink(missing_ok=True);state='sent';duplicate=True
            else:
                final=SPOOL/f"{uid}-{meta['filename']}";os.replace(part,final);execute("UPDATE uploads SET path=?,state='ready',size=?,sha256=?,updated=? WHERE id=?",(str(final),received,sha,now(),uid));state='ready';duplicate=False
            event('iphone',f"Empfangen: {meta['filename']} ({received} Bytes)");self.js(201,{"ok":True,"resource_id":uid,"state":state,"duplicate":duplicate,"telegram_pending":state!='sent'},{"X-Server-Resource-ID":uid,"X-TG-Resource-Key":meta['resource_key'] or ''})
        except (BrokenPipeError,ConnectionResetError):pass
        except Exception as e:event('error',f'HTTP upload: {e}');self.js(500,{"ok":False,"error":"server_error"})
    def do_OPTIONS(self):self.sendb(204,"text/plain",b"",{"Allow":"GET,POST,OPTIONS"})

def main():
    global WORKER
    a=argparse.ArgumentParser();a.add_argument('--setup',action='store_true');a.add_argument('--port',type=int);a.add_argument('--bind');a.add_argument('--show-config',action='store_true');z=a.parse_args();c=load_cfg(z.setup)
    if z.port:c['port']=z.port
    if z.bind:c['bind_host']=z.bind
    if z.show_config:
        safe=dict(c);safe['api_hash']='***';safe['web_password_hash']='configured';print(json.dumps(safe,indent=2));return
    if int(c.get('api_id') or 0)<=0 or not c.get('api_hash'):raise SystemExit('API-ID/API-Hash fehlen; --setup ausführen.')
    telethon();init_db();WORKER=TgWorker(c);WORKER.start();srv=Server((str(c.get('bind_host') or HOST),int(c.get('port') or PORT)),Handler,c)
    print(f"\n{APP} v{VERSION}\nIntern: http://{c.get('bind_host')}:{c.get('port')}\nWeb: {c.get('public_base_url')}/\nDaten: {HOME}\n")
    event('service',f'Relay {VERSION} gestartet')
    try:srv.serve_forever(.5)
    except KeyboardInterrupt:pass
    finally:STOP.set();srv.server_close();WORKER.join(10)
if __name__=='__main__':main()
