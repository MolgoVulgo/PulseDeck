"""Small local authentication helpers for PulseDeck Admin."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import time


PBKDF2_ITERATIONS = 240_000
SESSION_TTL = 12 * 60 * 60
ADMIN_STATE_DIR = Path("/var/lib/pulsedeck/admin")
PASSWORD_HASH_PATH = ADMIN_STATE_DIR / "password.hash"
SESSION_KEY_PATH = ADMIN_STATE_DIR / "session.key"
COOKIE_NAME = "pulsedeck_session"


def _b64e(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _b64d(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def hash_password(password: str, *, iterations: int = PBKDF2_ITERATIONS) -> str:
    if len(password) < 12:
        raise ValueError("admin password must contain at least 12 characters")
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return f"pbkdf2_sha256${iterations}${_b64e(salt)}${_b64e(digest)}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        algorithm, rounds, salt_text, digest_text = encoded.strip().split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        iterations = int(rounds)
        salt = _b64d(salt_text)
        expected = _b64d(digest_text)
    except (ValueError, TypeError):
        return False
    actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return hmac.compare_digest(actual, expected)


def generate_password() -> str:
    # 18 random bytes -> 24 URL-safe characters, no shell-hostile punctuation.
    return secrets.token_urlsafe(18)


def ensure_session_key(path: Path = SESSION_KEY_PATH) -> bytes:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        value = path.read_bytes()
    except FileNotFoundError:
        value = secrets.token_bytes(32)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(value)
    if len(value) < 32:
        raise ValueError("admin session key is invalid")
    return value


def make_session(secret: bytes, *, now: int | None = None, ttl: int = SESSION_TTL) -> str:
    issued = int(time.time()) if now is None else now
    payload = _b64e(json.dumps({"u": "admin", "exp": issued + ttl}, separators=(",", ":")).encode("utf-8"))
    signature = _b64e(hmac.new(secret, payload.encode("ascii"), hashlib.sha256).digest())
    return f"{payload}.{signature}"


def verify_session(token: str, secret: bytes, *, now: int | None = None) -> bool:
    try:
        payload, signature = token.split(".", 1)
        expected = _b64e(hmac.new(secret, payload.encode("ascii"), hashlib.sha256).digest())
        if not hmac.compare_digest(signature, expected):
            return False
        data = json.loads(_b64d(payload))
        current = int(time.time()) if now is None else now
        return data.get("u") == "admin" and isinstance(data.get("exp"), int) and data["exp"] >= current
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return False
