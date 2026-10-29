#!/usr/bin/env python3
"""TableLog's loopback Mac transcription server and local-only device management."""
import argparse
import asyncio
import hashlib
import io
import json
import os
import secrets
import sqlite3
import sys
import tempfile
import threading
import time
import wave
from collections import deque
from contextlib import closing
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

ROOT = Path(os.environ.get("TABLELOG_SERVER_HOME", Path.home() / "Library/Application Support/TableLogServer"))
MODEL = "whisper-large-v3-turbo"
TEXT_MODEL = "tablelog-qwen3.5-4b"
TEXT_PYTHON = Path.home() / "Library/Application Support/CoworkPython/envs/tablelog-text/bin/python"
TEXT_MODEL_DIR = ROOT / "models/qwen3.5-4b-4bit"
MAX_BODY = 12 * 1024**2
TOKEN_SECONDS = 30 * 86400


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class Devices:
    def __init__(self, root=ROOT):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.root / "devices.sqlite3"
        with closing(self.connect()) as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS codes(hash TEXT PRIMARY KEY,name TEXT,expires REAL);
                CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,name TEXT,hash TEXT UNIQUE,
                    created REAL,expires REAL,revoked INTEGER DEFAULT 0);
            """)
        self.path.chmod(0o600)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        return db

    def issue(self, name):
        code = "".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(12))
        with closing(self.connect()) as db, db:
            db.execute("DELETE FROM codes WHERE expires < ?", (time.time(),))
            db.execute("INSERT INTO codes VALUES(?,?,?)", (digest(code), name[:80], time.time() + 600))
        return "-".join(code[i:i+4] for i in range(0, 12, 4))

    def connect_device(self, code):
        normalized = code.replace("-", "").replace(" ", "").upper()
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM codes WHERE hash=? AND expires>?", (digest(normalized), time.time())).fetchone()
            if not row:
                raise HTTPException(401, "연결 코드가 만료되었거나 올바르지 않습니다.")
            token, ident, now = secrets.token_urlsafe(32), secrets.token_hex(16), time.time()
            db.execute("INSERT INTO devices VALUES(?,?,?,?,?,0)", (ident, row["name"], digest(token), now, now + TOKEN_SECONDS))
            db.execute("DELETE FROM codes WHERE hash=?", (row["hash"],))
        return {"device_id": ident, "access_token": token, "expires_in": TOKEN_SECONDS, "speech_model": MODEL}

    def authenticate(self, header):
        if not header.startswith("Bearer ") or not 32 <= len(header[7:]) <= 128:
            raise HTTPException(401, "기기 연결이 필요합니다.")
        with closing(self.connect()) as db:
            row = db.execute("SELECT * FROM devices WHERE hash=? AND expires>?", (digest(header[7:]), time.time())).fetchone()
        if not row:
            raise HTTPException(401, "기기 연결이 만료되었거나 올바르지 않습니다.")
        if row["revoked"]:
            raise HTTPException(403, "이 기기의 연결이 해제되었습니다.")
        return row["id"]

    def revoke(self, ident):
        with closing(self.connect()) as db, db:
            return db.execute("UPDATE devices SET revoked=1 WHERE id=?", (ident,)).rowcount > 0

    def list(self):
        with closing(self.connect()) as db:
            return [dict(r) for r in db.execute("SELECT id,name,created,expires,revoked FROM devices ORDER BY created")]


def validate_wav(data):
    try:
        with wave.open(io.BytesIO(data), "rb") as wav:
            if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (1, 2, 16000, "NONE"):
                raise ValueError()
            frames = wav.getnframes()
            if not 0 < frames <= 300 * 16000 or len(wav.readframes(frames)) != frames * 2:
                raise ValueError()
            return frames / 16000
    except (wave.Error, EOFError, ValueError):
        raise HTTPException(422, "5분 이하의 16kHz mono PCM16 WAV가 필요합니다.")


class AccessLimits:
    """Authenticate before reading uploads. No token/body logging or redirects."""
    def __init__(self, app, devices):
        self.app, self.devices = app, devices
        self.attempts = deque()
        self.lock = threading.Lock()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers", []))
        path = scope["path"]
        try:
            if path == "/health" and scope["method"] == "GET":
                pass
            elif path == "/v1/devices/connect" and scope["method"] == "POST":
                with self.lock:
                    now = time.monotonic()
                    while self.attempts and self.attempts[0] < now - 60:
                        self.attempts.popleft()
                    if len(self.attempts) >= 20:
                        raise HTTPException(429, "연결 시도가 많습니다. 1분 뒤 다시 시도해 주세요.")
                    self.attempts.append(now)
            else:
                ident = self.devices.authenticate(headers.get(b"authorization", b"").decode("latin1"))
                scope.setdefault("state", {})["device_id"] = ident
            limit = 4096 if path == "/v1/devices/connect" else 512 * 1024 if path == "/v1/chat/completions" else MAX_BODY
            try:
                size = int(headers.get(b"content-length", b"0"))
            except ValueError:
                raise HTTPException(400, "잘못된 요청 크기입니다.")
            if size < 0 or size > limit:
                raise HTTPException(413, "요청 크기 제한을 초과했습니다.")
        except HTTPException as exc:
            return await JSONResponse({"detail": exc.detail}, exc.status_code, headers={"Cache-Control": "no-store"})(scope, receive, send)
        used = 0
        async def bounded_receive():
            nonlocal used
            message = await receive()
            used += len(message.get("body", b""))
            if used > limit:
                raise HTTPException(413, "요청 크기 제한을 초과했습니다.")
            return message
        await self.app(scope, bounded_receive, send)


class ConnectInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    code: str = Field(min_length=12, max_length=32)


class ChatMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")
    role: str = Field(pattern="^(system|user|assistant)$")
    content: str = Field(min_length=1, max_length=45000)


class ChatInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    model: str
    messages: list[ChatMessage] = Field(min_length=1, max_length=20)
    stream: bool = False
    max_tokens: int = Field(default=2048, ge=32, le=3072)


def create_app(devices=None, worker=None, text_worker=None, text_python=None):
    devices = devices or Devices()
    api = FastAPI(title="TableLog Mac Studio", version="0.4.0", docs_url=None, redoc_url=None, openapi_url=None)
    api.add_middleware(AccessLimits, devices=devices)
    gate = threading.Lock()
    text_gate = threading.Lock()
    text_ready = text_worker is not None or (TEXT_PYTHON.is_file() and (TEXT_MODEL_DIR / "config.json").is_file())

    @api.middleware("http")
    async def response_headers(request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @api.get("/health")
    def health():
        return {"status": "ok", "service": "TableLog Mac Studio", "version": "0.4.0", "busy": gate.locked(), "text_busy": text_gate.locked(), "text_available": text_ready}

    @api.post("/v1/devices/connect")
    def connect(payload: ConnectInput):
        result = devices.connect_device(payload.code)
        if text_ready: result["text_model"] = TEXT_MODEL
        return result

    @api.post("/v1/devices/revoke")
    def revoke(request: Request):
        devices.revoke(request.state.device_id)
        return {"revoked": True}

    @api.get("/v1/models")
    def models():
        return {"data": [{"id": MODEL, "object": "model", "task": "transcription"}] + ([{"id": TEXT_MODEL, "object": "model", "task": "chat"}] if text_ready else [])}

    @api.post("/v1/chat/completions")
    async def chat(payload: ChatInput, request: Request):
        if payload.model != TEXT_MODEL or payload.stream or sum(len(m.content) for m in payload.messages) > 45000:
            raise HTTPException(422, "텍스트 요청 형식 또는 길이를 확인해 주세요.")
        if not text_ready:
            raise HTTPException(503, "맥의 회의 AI 모델이 준비되지 않았습니다.")
        if not text_gate.acquire(blocking=False):
            raise HTTPException(429, "다른 회의 AI 작업이 진행 중입니다. 잠시 후 다시 요청해 주세요.")
        proc = None
        try:
            with tempfile.TemporaryDirectory(prefix="tablelog-text-") as temp:
                source, output = Path(temp) / "input.json", Path(temp) / "output.json"
                source.write_text(payload.model_dump_json())
                proc = await asyncio.create_subprocess_exec(str(text_python or TEXT_PYTHON), str(text_worker or Path(__file__).with_name("text_worker.py")),
                    "--input", str(source), "--output", str(output), stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
                started = time.monotonic()
                while proc.returncode is None:
                    if await request.is_disconnected() or time.monotonic() - started > 210:
                        raise HTTPException(504, "회의 AI 요청이 취소되었거나 시간이 초과되었습니다.")
                    await asyncio.sleep(.1)
                if proc.returncode != 0 or not output.is_file() or output.stat().st_size > 512 * 1024:
                    raise HTTPException(503, "회의 AI 모델을 실행하지 못했습니다. 녹음과 기존 기록은 보존되어 있습니다.")
                return json.loads(output.read_text())
        finally:
            if proc and proc.returncode is None:
                proc.kill()
                await proc.wait()
            text_gate.release()

    @api.post("/v1/audio/transcriptions")
    async def transcribe(request: Request):
        if not gate.acquire(blocking=False):
            raise HTTPException(429, "다른 전사가 진행 중입니다. 잠시 후 다시 요청해 주세요.")
        proc = None
        try:
            async with request.form(max_files=1, max_fields=3, max_part_size=4096) as form:
                if form.get("model") != MODEL or form.get("language", "ko") not in ("ko", "en", "auto") or form.get("response_format", "verbose_json") != "verbose_json":
                    raise HTTPException(422, "지원하지 않는 모델 또는 응답 형식입니다.")
                language = form.get("language", "ko")
                upload = form.get("file")
                if upload is None or not hasattr(upload, "read"):
                    raise HTTPException(422, "녹음 파일이 필요합니다.")
                data = await upload.read(MAX_BODY + 1)
            if len(data) > MAX_BODY:
                raise HTTPException(413, "녹음 크기 제한을 초과했습니다.")
            validate_wav(data)
            with tempfile.TemporaryDirectory(prefix="tablelog-stt-") as temp:
                source, output = Path(temp) / "input.wav", Path(temp) / "output.json"
                source.write_bytes(data)
                proc = await asyncio.create_subprocess_exec(sys.executable, str(worker or Path(__file__).with_name("transcribe_worker.py")),
                    "--input", str(source), "--output", str(output), "--language", language, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
                started = time.monotonic()
                while proc.returncode is None:
                    if await request.is_disconnected() or time.monotonic() - started > 210:
                        raise HTTPException(504, "전사가 중단되었거나 시간이 초과되었습니다. 녹음은 기기에 남습니다.")
                    await asyncio.sleep(.1)
                if proc.returncode != 0 or not output.is_file():
                    raise HTTPException(503, "맥의 음성 모델을 실행하지 못했습니다. 서버 설치 상태를 확인해 주세요.")
                return json.loads(output.read_text())
        finally:
            if proc and proc.returncode is None:
                proc.kill()
                await proc.wait()
            gate.release()

    return api


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("serve"); run.add_argument("--port", type=int, default=7870)
    issue = sub.add_parser("issue-code"); issue.add_argument("--name", default="내 태블릿")
    sub.add_parser("devices")
    revoke = sub.add_parser("revoke"); revoke.add_argument("device_id")
    args = parser.parse_args()
    devices = Devices()
    if args.command == "issue-code":
        print("10분간 유효한 일회용 연결 코드:", devices.issue(args.name))
    elif args.command == "devices":
        print(json.dumps(devices.list(), ensure_ascii=False, indent=2))
    elif args.command == "revoke":
        print("연결 해제됨" if devices.revoke(args.device_id) else "기기를 찾지 못했습니다.")
    else:
        import uvicorn
        uvicorn.run(create_app(devices), host="127.0.0.1", port=args.port, access_log=False, proxy_headers=False)


if __name__ == "__main__":
    main()
