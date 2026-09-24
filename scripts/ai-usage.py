#!/usr/bin/env python3
"""Windows runner for the ai-usage Herdr plugin."""

import base64
import hashlib
import json
import os
import re
import shutil
import tempfile
import sqlite3
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

PROVIDERS = (
    {
        "id": "cursor",
        "name": "Cursor",
        "left": "Auto",
        "right": "Other",
        "menu_left": "Auto",
        "menu_right": "Other",
        "color": (196, 167, 231),
    },
    {
        "id": "chatgpt",
        "name": "ChatGPT",
        "left": "5시간",
        "right": "주간",
        "menu_left": "5h",
        "menu_right": "Weekly",
        "color": (156, 207, 216),
    },
    {
        "id": "claude",
        "name": "Claude",
        "left": "5시간",
        "right": "주간",
        "menu_left": "5h",
        "menu_right": "Weekly",
        "color": (235, 188, 186),
    },
)
BY_ID = {item["id"]: item for item in PROVIDERS}
ORDER = [item["id"] for item in PROVIDERS]
GATE_SECONDS = 60
FRESH_SECONDS = 4 * 60
COOLDOWN_SECONDS = 300
TITLE_MARKER = "ai-usage-status"
OPENED_AT = {}
READ_FAILED = object()


def now():
    return datetime.now(timezone.utc)


def iso(value):
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(raw):
    if not raw or not isinstance(raw, str):
        return None
    text = raw.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def home():
    return os.path.expanduser("~")


def data_dir():
    root = os.environ.get("APPDATA") or home()
    path = os.path.join(root, "AIUsage")
    os.makedirs(path, exist_ok=True)
    return path


def snapshot_path():
    return os.path.join(data_dir(), "usage-snapshot.json")


def accounts_path():
    return os.path.join(data_dir(), "accounts.json")


def visibility_path():
    return os.path.join(data_dir(), "visibility.json")


def cooldown_path():
    return os.path.join(data_dir(), "cooldown.json")


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return default


def save_json(path, value):
    temp = path + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
    os.replace(temp, path)


def herdr_bin():
    return os.environ.get("HERDR_BIN_PATH") or "herdr"


def run_herdr(args):
    try:
        proc = subprocess.run(
            [herdr_bin(), *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError:
        return {}
    text = proc.stdout or ""
    start = text.find("{")
    if start < 0:
        return {}
    try:
        return json.loads(text[start:])
    except json.JSONDecodeError:
        return {}


def remaining(used):
    if used is None:
        return None
    value = int(round(100.0 - float(used)))
    return max(0, min(100, value))


def as_float(value):
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def epoch_date(value):
    if isinstance(value, dict):
        seconds = as_float(value.get("seconds"))
        if seconds is None:
            return None
        nanos = as_float(value.get("nanos")) or 0
        return datetime.fromtimestamp(seconds + nanos / 1_000_000_000, timezone.utc)
    number = as_float(value)
    if number is None and isinstance(value, str):
        parsed = parse_iso(value)
        if parsed:
            return parsed
        number = as_float(value)
    if number is None:
        return None
    if number > 10_000_000_000:
        number = number / 1000
    return datetime.fromtimestamp(number, timezone.utc)


def empty_provider(provider_id, status="missingAuth", message=None):
    meta = BY_ID[provider_id]
    return {
        "id": provider_id,
        "displayName": meta["name"],
        "planName": None,
        "status": status,
        "statusMessage": message,
        "left": {"label": meta["left"], "remainingPercent": None, "resetsAt": None},
        "right": {"label": meta["right"], "remainingPercent": None, "resetsAt": None},
        "api": None,
        "accountLabel": None,
    }


def meter(label, percent, resets_at):
    return {
        "label": label,
        "remainingPercent": percent,
        "resetsAt": iso(resets_at) if isinstance(resets_at, datetime) else resets_at,
    }


def http_json(url, headers=None, method="GET", body=None):
    data = None if body is None else body.encode("utf-8")
    request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = response.read()
            return response.status, payload
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except (urllib.error.URLError, TimeoutError, OSError):
        return None, b""


def failure(provider_id, status, unauthorized):
    if status == 401:
        return empty_provider(provider_id, "missingAuth", unauthorized)
    if status == 429:
        return empty_provider(provider_id, "rateLimited", None)
    if status is None or status >= 400:
        return empty_provider(provider_id, "unavailable", None)
    return None


def cursor_db_path():
    appdata = os.environ.get("APPDATA") or ""
    return os.path.join(appdata, "Cursor", "User", "globalStorage", "state.vscdb")


def read_cursor_session():
    path = cursor_db_path()
    if not os.path.exists(path):
        return None
    uri = "file:" + path.replace("\\", "/") + "?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=2)
    except sqlite3.Error:
        return READ_FAILED
    try:
        rows = conn.execute(
            """
            SELECT key, value FROM ItemTable WHERE key IN (
                'cursorAuth/accessToken',
                'cursorAuth/refreshToken',
                'cursorAuth/cachedEmail'
            )
            """
        ).fetchall()
    except sqlite3.Error:
        return READ_FAILED
    finally:
        conn.close()
    token = None
    refresh = None
    email = None
    for key, value in rows:
        if isinstance(value, bytes):
            value = value.decode("utf-8", "replace")
        text = (value or "").strip()
        if key == "cursorAuth/accessToken":
            token = text or None
        elif key == "cursorAuth/refreshToken":
            refresh = text or None
        elif key == "cursorAuth/cachedEmail":
            email = text or None
    if not token:
        return None
    return {"accessToken": token, "refreshToken": refresh, "email": email}


def codex_auth_path():
    return os.path.join(home(), ".codex", "auth.json")


CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
CODEX_REFRESH_URL = "https://auth.openai.com/oauth/token"


def codex_bundle_from_payload(payload):
    if not isinstance(payload, dict):
        return None
    tokens = payload.get("tokens") if isinstance(payload.get("tokens"), dict) else {}
    access = tokens.get("access_token") or payload.get("access_token")
    if not access:
        return None
    kept = {
        "access_token": access,
        "refresh_token": tokens.get("refresh_token") or payload.get("refresh_token"),
        "id_token": tokens.get("id_token") or payload.get("id_token"),
        "account_id": tokens.get("account_id") or payload.get("account_id"),
    }
    return {
        "auth_mode": payload.get("auth_mode") or "chatgpt",
        "tokens": {key: value for key, value in kept.items() if value},
    }


def codex_bundle_paths():
    directory = os.path.dirname(codex_auth_path())
    if not os.path.isdir(directory):
        return []
    names = []
    for name in os.listdir(directory):
        if name == "auth.json" or name.startswith("auth.json.bak"):
            names.append(os.path.join(directory, name))
    return names


def load_codex_bundle(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None
    return codex_bundle_from_payload(payload)


def jwt_exp(token):
    exp = jwt_payload(token).get("exp") if token else None
    if isinstance(exp, (int, float)):
        return int(exp)
    return None


def bundle_for_saved_chatgpt(account):
    stored = account.get("codexAuth")
    if isinstance(stored, dict) and (stored.get("tokens") or {}).get("access_token"):
        return stored
    account_id = account.get("accountID")
    access = account.get("oauthToken")
    best = None
    for path in codex_bundle_paths():
        bundle = load_codex_bundle(path)
        if not bundle:
            continue
        tokens = bundle.get("tokens") or {}
        if account_id and tokens.get("account_id") != account_id:
            continue
        if best is None or (tokens.get("refresh_token") and not (best.get("tokens") or {}).get("refresh_token")):
            best = bundle
    if best and access:
        best = {"auth_mode": best.get("auth_mode") or "chatgpt", "tokens": dict(best.get("tokens") or {})}
        saved_exp = jwt_exp(access) or 0
        current_exp = jwt_exp(best["tokens"].get("access_token") or "") or 0
        if saved_exp >= current_exp:
            best["tokens"]["access_token"] = access
        if account_id:
            best["tokens"]["account_id"] = account_id
        return best
    if access:
        tokens = {"access_token": access}
        if account_id:
            tokens["account_id"] = account_id
        return {"auth_mode": "chatgpt", "tokens": tokens}
    return None


def refresh_codex_bundle(bundle):
    tokens = dict((bundle or {}).get("tokens") or {})
    refresh = tokens.get("refresh_token")
    if not refresh:
        return bundle, "missing"
    status, body = http_json(
        CODEX_REFRESH_URL,
        headers={"Content-Type": "application/json"},
        method="POST",
        body=json.dumps(
            {
                "client_id": CODEX_CLIENT_ID,
                "grant_type": "refresh_token",
                "refresh_token": refresh,
            }
        ),
    )
    if status in (400, 401, 403):
        return bundle, "failed"
    if status != 200:
        return bundle, "offline"
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return bundle, "failed"
    if not isinstance(payload, dict) or not payload.get("access_token"):
        return bundle, "failed"
    tokens["access_token"] = payload["access_token"]
    if payload.get("refresh_token"):
        tokens["refresh_token"] = payload["refresh_token"]
    if payload.get("id_token"):
        tokens["id_token"] = payload["id_token"]
    return {"auth_mode": bundle.get("auth_mode") or "chatgpt", "tokens": tokens}, "ok"


def write_codex_bundle(bundle):
    tokens = {key: value for key, value in (bundle.get("tokens") or {}).items() if value}
    if not tokens.get("access_token"):
        return False, "저장한 Codex 세션에 액세스 토큰이 없습니다"
    path = codex_auth_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    current = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as handle:
                loaded = json.load(handle)
            if isinstance(loaded, dict):
                current = loaded
        except (OSError, json.JSONDecodeError):
            current = {}
    current["auth_mode"] = bundle.get("auth_mode") or "chatgpt"
    current["tokens"] = tokens
    current["last_refresh"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    temp = path + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump(current, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    if os.path.exists(path):
        backup = path + ".bak." + datetime.now().strftime("%Y%m%d-%H%M%S")
        if not os.path.exists(backup):
            shutil.copy2(path, backup)
    os.replace(temp, path)
    return True, None


def write_cursor_session(access_token, refresh_token, email):
    path = cursor_db_path()
    if not os.path.exists(path):
        return False, "Cursor 세션 데이터베이스가 없습니다"
    if not access_token:
        return False, "저장한 Cursor 세션에 액세스 토큰이 없습니다"
    try:
        connection = sqlite3.connect(path, timeout=2)
    except sqlite3.Error:
        return False, "Cursor를 종료한 뒤 다시 세션을 적용하세요"
    try:
        for key, value in (
            ("cursorAuth/accessToken", access_token),
            ("cursorAuth/refreshToken", refresh_token),
            ("cursorAuth/cachedEmail", email),
        ):
            if not value:
                continue
            updated = connection.execute("UPDATE ItemTable SET value = ? WHERE key = ?", (value, key))
            if updated.rowcount == 0:
                connection.execute("INSERT INTO ItemTable (key, value) VALUES (?, ?)", (key, value))
        connection.commit()
    except sqlite3.Error:
        return False, "Cursor를 종료한 뒤 다시 세션을 적용하세요"
    finally:
        connection.close()
    return True, None


def read_claude_oauth():
    token = read_claude_token()
    if token is READ_FAILED or not token:
        return None
    try:
        with open(claude_credentials_path(), encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None
    oauth = payload.get("claudeAiOauth") if isinstance(payload, dict) else None
    return oauth if isinstance(oauth, dict) else None


def write_claude_oauth(oauth):
    if not isinstance(oauth, dict) or not oauth.get("accessToken"):
        return False, "저장한 Claude 세션에 액세스 토큰이 없습니다"
    path = claude_credentials_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    current = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as handle:
                loaded = json.load(handle)
            if isinstance(loaded, dict):
                current = loaded
        except (OSError, json.JSONDecodeError):
            current = {}
    current["claudeAiOauth"] = oauth
    temp = path + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump(current, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(temp, path)
    return True, None


def absorb_live_codex(accounts):
    bundle = load_codex_bundle(codex_auth_path())
    tokens = (bundle or {}).get("tokens") or {}
    account_id = tokens.get("account_id")
    if not account_id or not tokens.get("refresh_token"):
        return
    for item in accounts:
        if item.get("provider") != "chatgpt" or item.get("accountID") != account_id:
            continue
        stored = item.get("codexAuth") if isinstance(item.get("codexAuth"), dict) else {}
        if (stored.get("tokens") or {}).get("refresh_token"):
            continue
        item["codexAuth"] = bundle
        item["oauthToken"] = tokens.get("access_token") or item.get("oauthToken")


def install_saved_session(account):
    provider_id = account.get("provider")
    if provider_id == "chatgpt":
        bundle = bundle_for_saved_chatgpt(account)
        tokens = (bundle or {}).get("tokens") or {}
        if not tokens.get("access_token"):
            return False, "저장한 Codex 세션을 찾지 못했습니다"
        if not tokens.get("refresh_token") or not tokens.get("id_token"):
            return False, "이 계정은 사용량 조회용 토큰만 저장되어 있어 Codex 앱 로그인을 바꾸지 못했습니다. Codex에서 이 계정으로 로그인한 뒤 '현재 세션 저장'을 다시 하세요."
        live_tokens = (load_codex_bundle(codex_auth_path()) or {}).get("tokens") or {}
        if (
            external_codex_running()
            and live_tokens.get("refresh_token")
            and live_tokens.get("refresh_token") == tokens.get("refresh_token")
        ):
            return False, "Codex 앱이 실행 중입니다. 앱을 완전히 종료한 뒤 다시 적용하세요. 켜 둔 상태에서는 앱이 로그인 파일을 예전 계정으로 덮어씁니다."
        bundle, refresh_state = refresh_codex_bundle(bundle)
        if refresh_state == "offline":
            return False, "Codex 갱신 서버에 연결하지 못했습니다. 네트워크를 확인한 뒤 다시 적용하세요."
        if refresh_state != "ok":
            return False, "저장해 둔 Codex 갱신 토큰이 더 이상 유효하지 않습니다. Codex에서 이 계정으로 로그인한 뒤 '현재 세션 저장'을 다시 하세요."
        new_tokens = bundle.get("tokens") or {}
        if not new_tokens.get("access_token") or not new_tokens.get("refresh_token") or not new_tokens.get("id_token"):
            return False, "Codex가 갱신 응답에 로그인 토큰을 모두 주지 않았습니다. Codex에서 이 계정으로 다시 로그인한 뒤 세션을 저장하세요."
        account["codexAuth"] = bundle
        account["oauthToken"] = new_tokens.get("access_token")
        account["accountID"] = new_tokens.get("account_id") or account.get("accountID")
        ok, message = write_codex_bundle(bundle)
        if not ok:
            return False, message
        return True, "Codex 로그인을 이 계정으로 바꿨습니다. Codex를 다시 열면 이 계정으로 들어갑니다."
    if provider_id == "cursor":
        stored = account.get("cursorAuth") if isinstance(account.get("cursorAuth"), dict) else {}
        email = stored.get("email") or account.get("displayName")
        if not isinstance(email, str) or "@" not in email:
            email = None
        ok, message = write_cursor_session(
            stored.get("accessToken") or account.get("oauthToken"),
            stored.get("refreshToken"),
            email,
        )
        return ok, message or "Cursor 로그인 세션을 이 계정으로 바꿨습니다. Cursor를 완전히 종료한 뒤 다시 여세요."
    stored = account.get("claudeAuth") if isinstance(account.get("claudeAuth"), dict) else None
    if stored:
        ok, message = write_claude_oauth(stored)
        return ok, message or "Claude 로그인 세션을 이 계정으로 바꿨습니다. Claude를 완전히 종료한 뒤 다시 여세요."
    if account.get("oauthToken"):
        ok, message = write_claude_oauth({"accessToken": account.get("oauthToken")})
        return ok, message or "Claude 로그인 세션을 이 계정으로 바꿨습니다. Claude를 완전히 종료한 뒤 다시 여세요."
    return False, "저장한 Claude 세션을 앱 로그인 파일에 넣지 못했습니다"


def read_chatgpt_auth(path=None):
    target = path or codex_auth_path()
    if not os.path.exists(target):
        return None
    try:
        with open(target, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return READ_FAILED
    if not isinstance(payload, dict):
        return None
    tokens = payload.get("tokens") if isinstance(payload.get("tokens"), dict) else {}
    token = tokens.get("access_token") or payload.get("access_token")
    if not token:
        return None
    account_id = tokens.get("account_id") or payload.get("account_id")
    return {
        "accessToken": token,
        "accountID": account_id,
        "bundle": codex_bundle_from_payload(payload),
    }


def claude_credentials_path():
    return os.path.join(home(), ".claude", ".credentials.json")


def read_claude_token(path=None):
    target = path or claude_credentials_path()
    if not os.path.exists(target):
        return None
    try:
        with open(target, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return READ_FAILED
    if not isinstance(payload, dict):
        return None
    oauth = payload.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        return None
    token = oauth.get("accessToken")
    return token or None


def claude_api_key():
    value = (os.environ.get("ANTHROPIC_API_KEY") or "").strip()
    return value or None


def claude_user_agent():
    try:
        proc = subprocess.run(
            ["claude", "--version"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=2,
        )
        token = (proc.stdout or proc.stderr or "").split()
        if token:
            return "claude-code/" + token[0]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return "claude-code/2.0.32"


def map_cursor_period(payload):
    plan = payload.get("planUsage")
    if not isinstance(plan, dict):
        individual = payload.get("individualUsage")
        plan = individual.get("plan") if isinstance(individual, dict) else None
    plan = plan if isinstance(plan, dict) else {}
    end = (
        epoch_date(payload.get("billingCycleEnd"))
        or epoch_date(payload.get("billing_cycle_end"))
        or epoch_date((payload.get("planInfo") or {}).get("billingCycleEnd") if isinstance(payload.get("planInfo"), dict) else None)
    )
    meta = BY_ID["cursor"]
    snap = empty_provider("cursor", "ok", None)
    snap["left"] = meter(meta["left"], remaining(as_float(plan.get("autoPercentUsed"))), end)
    snap["right"] = meter(meta["right"], remaining(as_float(plan.get("apiPercentUsed"))), end)
    return snap


def map_cursor_auth(payload):
    bucket = payload.get("gpt-4") if isinstance(payload.get("gpt-4"), dict) else {}
    used = as_float(bucket.get("numRequests"))
    maximum = as_float(bucket.get("maxRequestUsage"))
    percent = None
    if used is not None and maximum and maximum > 0:
        percent = remaining((used / maximum) * 100)
    end = epoch_date(payload.get("billingCycleEnd")) or epoch_date(payload.get("startOfMonth"))
    if end and payload.get("billingCycleEnd") is None and payload.get("startOfMonth") is not None:
        end = end + timedelta(days=31)
    meta = BY_ID["cursor"]
    snap = empty_provider("cursor", "ok", None)
    snap["left"] = meter(meta["left"], percent, end)
    snap["right"] = meter(meta["right"], None, end)
    return snap


def fetch_cursor(token=None, email=None):
    session = None
    if token is None:
        session = read_cursor_session()
        if session is READ_FAILED:
            return empty_provider("cursor", "unavailable", None)
        if session:
            token = session["accessToken"]
            email = session.get("email")
    snap = empty_provider("cursor", "missingAuth", "Cursor에서 로그인")
    if not token:
        return snap
    status, body = http_json(
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
        headers={
            "Authorization": "Bearer " + token,
            "Connect-Protocol-Version": "1",
            "Content-Type": "application/json",
        },
        method="POST",
        body="{}",
    )
    failed = failure("cursor", status, "Cursor에서 로그인")
    if failed:
        failed["accountLabel"] = email
        return failed
    try:
        mapped = map_cursor_period(json.loads(body.decode("utf-8")))
    except (json.JSONDecodeError, UnicodeDecodeError):
        mapped = empty_provider("cursor", "unavailable", None)
    if mapped["left"]["remainingPercent"] is None and mapped["right"]["remainingPercent"] is None:
        status, body = http_json(
            "https://api2.cursor.sh/auth/usage",
            headers={"Authorization": "Bearer " + token},
        )
        failed = failure("cursor", status, "Cursor에서 로그인")
        if failed:
            failed["accountLabel"] = email
            return failed
        try:
            mapped = map_cursor_auth(json.loads(body.decode("utf-8")))
        except (json.JSONDecodeError, UnicodeDecodeError):
            mapped = empty_provider("cursor", "unavailable", None)
    mapped["accountLabel"] = email
    return mapped


def jwt_payload(token):
    parts = (token or "").split(".")
    if len(parts) < 2:
        return {}
    body = parts[1] + ("=" * (-len(parts[1]) % 4))
    try:
        payload = json.loads(base64.urlsafe_b64decode(body.encode("ascii")))
    except (json.JSONDecodeError, UnicodeError, ValueError):
        return {}
    return payload if isinstance(payload, dict) else {}


def jwt_email(token):
    payload = jwt_payload(token)
    email = payload.get("email")
    if isinstance(email, str) and email.strip():
        return email.strip()
    profile = payload.get("https://api.openai.com/profile")
    if isinstance(profile, dict):
        email = profile.get("email")
        if isinstance(email, str) and email.strip():
            return email.strip()
    return None


def jwt_plan(token):
    payload = jwt_payload(token)
    auth = payload.get("https://api.openai.com/auth")
    if isinstance(auth, dict):
        plan = auth.get("chatgpt_plan_type")
        if isinstance(plan, str) and plan.strip():
            return plan.strip()
    return None


def map_chatgpt(payload):
    rate = payload.get("rate_limit") if isinstance(payload.get("rate_limit"), dict) else {}
    primary = rate.get("primary_window") or payload.get("primary")
    secondary = rate.get("secondary_window") or payload.get("secondary")
    windows = [item for item in (primary, secondary) if isinstance(item, dict)]

    def seconds(window):
        return as_float(window.get("limit_window_seconds") or window.get("limitWindowSeconds"))

    short = next((item for item in windows if seconds(item) is not None and seconds(item) < 86400), None)
    long = next((item for item in windows if seconds(item) is not None and seconds(item) >= 86400), None)
    if short is None and long is None:
        short = primary if isinstance(primary, dict) else None
        long = secondary if isinstance(secondary, dict) else None

    def one(label, window):
        if not isinstance(window, dict):
            return meter(label, None, None)
        used = as_float(window.get("used_percent") if window.get("used_percent") is not None else window.get("usedPercent"))
        reset = epoch_date(window.get("reset_at") if window.get("reset_at") is not None else window.get("resetsAt"))
        return meter(label, remaining(used), reset)

    meta = BY_ID["chatgpt"]
    snap = empty_provider("chatgpt", "ok", None)
    snap["planName"] = payload.get("planType") or payload.get("plan_type")
    snap["accountLabel"] = payload.get("email")
    snap["left"] = one(meta["left"], short)
    snap["right"] = one(meta["right"], long)
    return snap


def fetch_chatgpt(auth=None):
    if auth is None:
        auth = read_chatgpt_auth()
    if auth is READ_FAILED:
        return empty_provider("chatgpt", "unavailable", None)
    if not auth:
        return empty_provider("chatgpt", "missingAuth", "ChatGPT 또는 Codex에서 로그인")
    headers = {"Authorization": "Bearer " + auth["accessToken"]}
    if auth.get("accountID"):
        headers["ChatGPT-Account-ID"] = auth["accountID"]
    status, body = http_json("https://chatgpt.com/backend-api/wham/usage", headers=headers)
    if status == 200:
        try:
            mapped = map_chatgpt(json.loads(body.decode("utf-8")))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return empty_provider("chatgpt", "unavailable", None)
        if not mapped.get("accountLabel"):
            mapped["accountLabel"] = jwt_email(auth.get("accessToken") or "")
        if not mapped.get("planName"):
            mapped["planName"] = jwt_plan(auth.get("accessToken") or "")
        return mapped
    failed = failure("chatgpt", status, "ChatGPT 또는 Codex에서 로그인")
    return failed or empty_provider("chatgpt", "unavailable", None)


def map_claude(payload):
    def one(label, window):
        if not isinstance(window, dict):
            return meter(label, None, None)
        return meter(label, remaining(as_float(window.get("utilization"))), parse_iso(window.get("resets_at")))

    meta = BY_ID["claude"]
    snap = empty_provider("claude", "ok", None)
    snap["left"] = one(meta["left"], payload.get("five_hour"))
    snap["right"] = one(meta["right"], payload.get("seven_day"))
    return snap


def fetch_claude(token=None, api_key=None):
    if token is None and api_key is None:
        token = read_claude_token()
        if token is READ_FAILED:
            return empty_provider("claude", "unavailable", None)
        api_key = claude_api_key()
    oauth = None
    if token:
        status, body = http_json(
            "https://api.anthropic.com/api/oauth/usage",
            headers={
                "Authorization": "Bearer " + token,
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": claude_user_agent(),
            },
        )
        failed = failure("claude", status, "Claude Code를 한 번 실행해 로그인 상태를 갱신하세요")
        if failed:
            oauth = failed
        else:
            try:
                oauth = map_claude(json.loads(body.decode("utf-8")))
            except (json.JSONDecodeError, UnicodeDecodeError):
                oauth = empty_provider("claude", "unavailable", None)
    if oauth and oauth["status"] == "ok":
        return oauth
    if oauth:
        return oauth
    if api_key:
        return empty_provider("claude", "ok", "API 키는 찾았지만 이번 달 사용액을 아직 못 읽었습니다")
    return empty_provider("claude", "missingAuth", "Claude Code에서 로그인 또는 ANTHROPIC_API_KEY")


def load_accounts():
    payload = load_json(accounts_path(), {"accounts": []})
    accounts = payload.get("accounts") if isinstance(payload, dict) else None
    return accounts if isinstance(accounts, list) else []


def save_accounts(accounts):
    save_json(accounts_path(), {"accounts": accounts})


def active_account(provider_id):
    matches = [item for item in load_accounts() if item.get("provider") == provider_id]
    return next((item for item in matches if item.get("active")), None)


def token_fingerprint(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def identity_key(provider_id, account_id, email, token):
    if account_id:
        return f"{provider_id}:id:{account_id}"
    if email and "@" in email:
        return f"{provider_id}:email:{email.strip().lower()}"
    if token:
        return f"{provider_id}:token:{token_fingerprint(token)}"
    return None


def account_identity(account):
    email = account.get("displayName") or ""
    return identity_key(
        account.get("provider") or "",
        account.get("accountID"),
        email,
        account.get("oauthToken") or account.get("apiKey") or "",
    )


def live_identity(provider_id):
    if provider_id == "cursor":
        session = read_cursor_session()
        if session is READ_FAILED:
            return READ_FAILED
        if not isinstance(session, dict):
            return None
        return identity_key("cursor", None, session.get("email"), session.get("accessToken") or "")
    if provider_id == "chatgpt":
        auth = read_chatgpt_auth()
        if auth is READ_FAILED:
            return READ_FAILED
        if not isinstance(auth, dict):
            return None
        token = auth.get("accessToken") or ""
        return identity_key("chatgpt", auth.get("accountID"), jwt_email(token), token)
    token = read_claude_token()
    if token is READ_FAILED:
        return READ_FAILED
    if token:
        return identity_key("claude", None, jwt_email(token), token)
    api_key = claude_api_key()
    if api_key:
        return identity_key("claude", None, None, api_key)
    return None


def source_path():
    return os.path.join(data_dir(), "session-source.json")


def load_sources():
    payload = load_json(source_path(), {})
    return payload if isinstance(payload, dict) else {}


def save_source(provider_id, record):
    payload = load_sources()
    payload[provider_id] = record
    save_json(source_path(), payload)


def stored_identity(value):
    if value is READ_FAILED:
        return None
    return value


def should_follow_saved(record, live, saved):
    if live is READ_FAILED or not isinstance(record, dict) or record.get("mode") != "saved":
        return False
    if not saved or saved.get("id") != record.get("accountId"):
        return False
    return record.get("liveIdentity") == live


def align_active_account(provider_id, live):
    if live is READ_FAILED:
        return
    accounts = load_accounts()
    changed = False
    for item in accounts:
        if item.get("provider") != provider_id:
            continue
        should = live is not None and account_identity(item) == live
        if bool(item.get("active")) != should:
            item["active"] = should
            changed = True
    if changed:
        save_accounts(accounts)


def resolve_saved_account(provider_id):
    live = live_identity(provider_id)
    record = load_sources().get(provider_id)
    record = record if isinstance(record, dict) else {}
    saved = None
    if record.get("mode") == "saved":
        saved = next((item for item in load_accounts() if item.get("id") == record.get("accountId")), None)
    if should_follow_saved(record, live, saved):
        return saved
    if live is READ_FAILED:
        return saved
    if record.get("mode") != "live" or record.get("liveIdentity") != live:
        save_source(provider_id, {"mode": "live", "liveIdentity": live})
        align_active_account(provider_id, live)
    return None


def remember_saved_source(provider_id, account_id):
    save_source(
        provider_id,
        {
            "mode": "saved",
            "accountId": account_id,
            "liveIdentity": stored_identity(live_identity(provider_id)),
        },
    )


def credential_stamp():
    stamps = []
    for provider_id in ORDER:
        ident = live_identity(provider_id)
        if ident is READ_FAILED:
            return None
        stamps.append(ident)
    return tuple(stamps)


def fetch_provider(provider_id):
    saved = resolve_saved_account(provider_id)
    if provider_id == "cursor":
        if saved and saved.get("oauthToken"):
            snap = fetch_cursor(saved.get("oauthToken"), saved.get("displayName"))
        else:
            snap = fetch_cursor()
    elif provider_id == "chatgpt":
        if saved and saved.get("oauthToken"):
            snap = fetch_chatgpt({"accessToken": saved["oauthToken"], "accountID": saved.get("accountID")})
        else:
            snap = fetch_chatgpt()
    else:
        if saved and (saved.get("oauthToken") or saved.get("apiKey")):
            snap = fetch_claude(saved.get("oauthToken"), saved.get("apiKey"))
        else:
            snap = fetch_claude()
    if saved:
        accounts = load_accounts()
        for item in accounts:
            if item.get("id") == saved.get("id"):
                item["planName"] = snap.get("planName")
                item["displayName"] = snap.get("accountLabel") or item.get("displayName")
        save_accounts(accounts)
    return snap


def load_snapshot():
    payload = load_json(snapshot_path(), None)
    return payload if isinstance(payload, dict) else None


def provider_of(snapshot, provider_id):
    if not snapshot:
        return None
    for item in snapshot.get("providers") or []:
        if item.get("id") == provider_id:
            return item
    return None


def has_meters(provider):
    if not provider:
        return False
    return provider.get("left", {}).get("remainingPercent") is not None or provider.get("right", {}).get("remainingPercent") is not None


def merge_provider(previous, incoming):
    if not has_meters(previous) or incoming.get("status") == "ok":
        return incoming
    merged = dict(incoming)
    merged["left"] = dict(incoming.get("left") or {})
    merged["right"] = dict(incoming.get("right") or {})
    merged["left"]["remainingPercent"] = previous["left"].get("remainingPercent")
    merged["right"]["remainingPercent"] = previous["right"].get("remainingPercent")
    merged["left"]["resetsAt"] = previous["left"].get("resetsAt")
    merged["right"]["resetsAt"] = previous["right"].get("resetsAt")
    merged["api"] = incoming.get("api") or previous.get("api")
    merged["planName"] = incoming.get("planName") or previous.get("planName")
    return merged


def cooling(provider_id):
    stamp = load_json(cooldown_path(), {}).get(provider_id)
    if not stamp:
        return False
    return time.time() - float(stamp) < COOLDOWN_SECONDS


def mark_limited(provider_id):
    payload = load_json(cooldown_path(), {})
    payload[provider_id] = time.time()
    save_json(cooldown_path(), payload)


def snapshot_age(snapshot):
    fetched = parse_iso((snapshot or {}).get("fetchedAt"))
    if not fetched:
        return None
    return (now() - fetched.astimezone(timezone.utc)).total_seconds()


def refresh(force=False, ignore_gate=False):
    cached = load_snapshot()
    age = snapshot_age(cached)
    if cached and not force and age is not None and age < FRESH_SECONDS:
        return cached
    started = parse_iso((cached or {}).get("lastNetworkStartedAt"))
    if (
        not ignore_gate
        and cached
        and started
        and (now() - started.astimezone(timezone.utc)).total_seconds() < GATE_SECONDS
    ):
        return cached
    providers = []
    for provider_id in ORDER:
        prior = provider_of(cached, provider_id)
        if cooling(provider_id) and prior:
            providers.append(prior)
            continue
        incoming = fetch_provider(provider_id)
        if incoming.get("status") == "rateLimited":
            mark_limited(provider_id)
        providers.append(merge_provider(prior, incoming))
    stamp = iso(now())
    snapshot = {"fetchedAt": stamp, "lastNetworkStartedAt": stamp, "providers": providers}
    save_json(snapshot_path(), snapshot)
    return snapshot


def load_visible():
    raw = load_json(visibility_path(), ORDER)
    if not isinstance(raw, list):
        return list(ORDER)
    chosen = [item for item in ORDER if item in raw]
    return chosen


def save_visible(ids):
    save_json(visibility_path(), [item for item in ORDER if item in ids])


def compact(provider_id, provider):
    meta = BY_ID[provider_id]
    if provider and provider.get("left", {}).get("remainingPercent") is None and provider.get("right", {}).get("remainingPercent") is None and provider.get("api"):
        api = provider["api"]
        return f"{meta['name']} {api.get('label', 'API')} {api.get('detail', '')}"
    parts = []
    if provider and provider.get("left", {}).get("remainingPercent") is not None:
        parts.append(f"{meta['menu_left']} {provider['left']['remainingPercent']}%")
    if provider and provider.get("right", {}).get("remainingPercent") is not None:
        parts.append(f"{meta['menu_right']} {provider['right']['remainingPercent']}%")
    if not parts:
        left = "—"
        right = "—"
        if provider and provider.get("left", {}).get("remainingPercent") is not None:
            left = f"{provider['left']['remainingPercent']}%"
        if provider and provider.get("right", {}).get("remainingPercent") is not None:
            right = f"{provider['right']['remainingPercent']}%"
        return f"{meta['name']} {meta['menu_left']} {left} · {meta['menu_right']} {right}"
    return f"{meta['name']} " + " · ".join(parts)


def status_line(snapshot=None):
    snapshot = snapshot if snapshot is not None else load_snapshot()
    visible = load_visible() or list(ORDER)
    return "  ".join(compact(provider_id, provider_of(snapshot, provider_id)) for provider_id in visible)


def fg(text, color, bold=False):
    red, green, blue = color
    weight = "1;" if bold else ""
    return f"\x1b[{weight}38;2;{red};{green};{blue}m{text}\x1b[0m"


def pad(text, width):
    if len(text) >= width:
        return text
    return text + (" " * (width - len(text)))


def level_color(percent):
    if percent is None:
        return (156, 207, 142)
    if percent <= 10:
        return (235, 111, 146)
    if percent <= 20:
        return (246, 193, 119)
    return (156, 207, 142)


def bar(percent, width=10):
    if percent is None:
        return "·" * width
    filled = int(round(max(0, min(100, percent)) / 100 * width))
    return ("█" * filled) + ("░" * (width - filled))


def connected(provider):
    if not provider or provider.get("status") == "missingAuth":
        return False
    has_usage = (
        provider.get("left", {}).get("remainingPercent") is not None
        or provider.get("right", {}).get("remainingPercent") is not None
        or provider.get("api")
    )
    if provider.get("status") == "unavailable":
        return has_usage
    return True


def statusbar_frame(snapshot):
    rows = []
    visible = load_visible() or list(ORDER)
    for provider_id in visible:
        provider = provider_of(snapshot, provider_id)
        if not connected(provider):
            continue
        meta = BY_ID[provider_id]
        fields = []
        for side, label in (("left", meta["menu_left"]), ("right", meta["menu_right"])):
            percent = provider.get(side, {}).get("remainingPercent")
            if percent is None:
                continue
            color = level_color(percent)
            reset = provider.get(side, {}).get("resetsAt")
            text = f"{fg(pad(label, 8), (224, 222, 244))}  {fg(pad(str(percent) + '%', 10), color, True)} {fg(bar(percent), color)}"
            if reset:
                parsed = parse_iso(reset)
                if parsed:
                    text += " " + fg("reset " + parsed.astimezone().strftime("%m/%d %H:%M"), (246, 193, 119))
            fields.append(text)
        if not fields and provider.get("api"):
            fields.append(fg(provider["api"].get("detail", ""), (156, 207, 142), True))
        if fields:
            rows.append(" " + fg(pad(meta["name"], 8), meta["color"], True) + "  " + "   ".join(fields))
    return "\n".join(rows)


def generic_account_name(name):
    return (name or "").strip() in {"", "ChatGPT", "Cursor", "Claude"}


def profile_from_token(provider_id, token, email=None):
    label = email or jwt_email(token)
    plan = jwt_plan(token)
    if provider_id == "cursor":
        return label or "Cursor", plan
    if provider_id == "chatgpt":
        return label or "ChatGPT", plan
    return label or "Claude", plan


def backfill_account_profiles():
    accounts = load_accounts()
    changed = False
    for item in accounts:
        token = item.get("oauthToken") or ""
        if not token:
            continue
        label, plan = profile_from_token(item.get("provider"), token)
        if generic_account_name(item.get("displayName")) and label and not generic_account_name(label):
            item["displayName"] = label
            changed = True
        if not item.get("planName") and plan:
            item["planName"] = plan
            changed = True
    if changed:
        save_accounts(accounts)
    return changed


def capture(provider_id):
    accounts = load_accounts()
    plan = None
    extra = {}
    if provider_id == "cursor":
        session = read_cursor_session()
        token = session.get("accessToken") if isinstance(session, dict) else None
        email = session.get("email") if isinstance(session, dict) else None
        label, plan = profile_from_token("cursor", token or "", email)
        account_id = None
        api_key = None
        if isinstance(session, dict):
            extra["cursorAuth"] = {
                "accessToken": session.get("accessToken"),
                "refreshToken": session.get("refreshToken"),
                "email": email,
            }
        missing = "Cursor에서 로그인하세요"
    elif provider_id == "chatgpt":
        auth = read_chatgpt_auth()
        token = auth.get("accessToken") if isinstance(auth, dict) else None
        account_id = auth.get("accountID") if isinstance(auth, dict) else None
        api_key = None
        label, plan = profile_from_token("chatgpt", token or "")
        if isinstance(auth, dict) and auth.get("bundle"):
            extra["codexAuth"] = auth["bundle"]
        missing = "ChatGPT 또는 Codex에서 로그인하세요"
    else:
        oauth = read_claude_oauth()
        token = oauth.get("accessToken") if isinstance(oauth, dict) else None
        if token is None:
            token = read_claude_token()
            if token is READ_FAILED:
                token = None
        api_key = claude_api_key()
        account_id = None
        label, plan = profile_from_token("claude", token or "")
        if not token and api_key:
            label = "Claude"
        if isinstance(oauth, dict):
            extra["claudeAuth"] = oauth
        missing = "Claude Code 로그인 또는 ANTHROPIC_API_KEY를 확인하세요"
    if not token and not api_key:
        return missing
    match = None
    for item in accounts:
        if item.get("provider") != provider_id:
            continue
        if account_id and item.get("accountID") == account_id:
            match = item
            break
        saved_email = None
        if isinstance(item.get("cursorAuth"), dict):
            saved_email = item["cursorAuth"].get("email")
        if (
            provider_id == "cursor"
            and isinstance(email, str)
            and isinstance(saved_email, str)
            and saved_email.lower() == email.lower()
        ):
            match = item
            break
        if token and item.get("oauthToken") == token:
            match = item
            break
    for item in accounts:
        if item.get("provider") == provider_id and item is not match:
            item["active"] = False
    if match:
        match["displayName"] = label
        match["planName"] = plan
        match["active"] = True
        match["oauthToken"] = token
        match["accountID"] = account_id
        match["apiKey"] = api_key
        match.update(extra)
    else:
        record = {
            "id": str(uuid.uuid4()),
            "provider": provider_id,
            "displayName": label,
            "planName": plan,
            "active": True,
            "oauthToken": token,
            "accountID": account_id,
            "apiKey": api_key,
        }
        record.update(extra)
        accounts.append(record)
    save_accounts(accounts)
    return "현재 세션을 저장했습니다"


def toggle_visible(provider_id):
    visible = set(load_visible() or ORDER)
    shown = provider_id not in visible
    if shown:
        visible.add(provider_id)
    else:
        visible.discard(provider_id)
    save_visible(visible)
    return shown


def pad_width(text, width, align="left"):
    gap = max(0, width - display_width(text))
    if align == "right":
        return (" " * gap) + text
    return text + (" " * gap)


def store_provider(snapshot, provider):
    providers = [item for item in ((snapshot or {}).get("providers") or []) if item.get("id") != provider.get("id")]
    providers.append(provider)
    providers.sort(key=lambda item: ORDER.index(item["id"]) if item.get("id") in ORDER else 99)
    stamp = iso(now())
    updated = {
        "fetchedAt": stamp,
        "lastNetworkStartedAt": (snapshot or {}).get("lastNetworkStartedAt") or stamp,
        "providers": providers,
    }
    save_json(snapshot_path(), updated)
    return updated


AGENT_KIND = {"cursor": "cursor", "chatgpt": "codex", "claude": "claude"}


def same_path(left, right):
    if not left or not right:
        return False
    return os.path.normcase(os.path.normpath(left)) == os.path.normcase(os.path.normpath(right))


def pane_process(pane_id):
    payload = run_herdr(["pane", "process-info", "--pane", pane_id])
    return ((payload.get("result") or {}).get("process_info") or {})


def foreground_text(info):
    parts = []
    for proc in info.get("foreground_processes") or []:
        parts.append(proc.get("cmdline") or "")
        parts.append(proc.get("name") or "")
    return " ".join(parts).lower()


def foreground_matches(kind, info):
    text = foreground_text(info)
    if "ai-usage.py" in text:
        return False
    if kind == "cursor":
        return "cursor-agent" in text
    if kind == "codex":
        return "codex.exe" in text or "\\codex" in text
    if kind == "claude":
        return "claude.exe" in text or "claude" in text.split()
    return False


def herdr_foreground_pids(kind):
    pids = set()
    payload = run_herdr(["pane", "list"])
    for pane in ((payload.get("result") or {}).get("panes") or []):
        info = pane_process(pane.get("pane_id"))
        if not foreground_matches(kind, info):
            continue
        for proc in info.get("foreground_processes") or []:
            if proc.get("pid"):
                pids.add(int(proc["pid"]))
    return pids


def external_codex_running():
    try:
        proc = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq Codex.exe", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    hosted = herdr_foreground_pids("codex")
    for line in (proc.stdout or "").splitlines():
        if "codex.exe" not in line.lower():
            continue
        bits = [part.strip('"') for part in line.split(",")]
        if len(bits) < 2 or not bits[1].isdigit():
            return True
        if int(bits[1]) not in hosted:
            return True
    return False


def cursor_conversation_id(pid):
    directory = os.path.join(tempfile.gettempdir(), "cursor-agent-logs-" + (os.environ.get("USERNAME") or ""))
    if not os.path.isdir(directory):
        return None
    matches = []
    for name in os.listdir(directory):
        if f"-{pid}-" in name and name.endswith(".log"):
            matches.append(os.path.join(directory, name))
    found = None
    for path in sorted(matches, key=os.path.getmtime):
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    marker = '"conversationId":"'
                    start = line.rfind(marker)
                    if start < 0:
                        continue
                    start += len(marker)
                    end = line.find('"', start)
                    if end > start:
                        found = line[start:end]
        except OSError:
            continue
    return found


def codex_conversation_id(cwd, used):
    root = os.path.join(home(), ".codex", "sessions")
    if not os.path.isdir(root):
        return None
    best = None
    for dirpath, _dirs, names in os.walk(root):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, encoding="utf-8") as handle:
                    meta = json.loads(handle.readline() or "{}")
            except (OSError, json.JSONDecodeError):
                continue
            payload = meta.get("payload") if isinstance(meta.get("payload"), dict) else {}
            session_id = payload.get("session_id") or payload.get("id")
            if not session_id or session_id in used or not same_path(payload.get("cwd"), cwd):
                continue
            stamp = os.path.getmtime(path)
            if best is None or stamp > best[0]:
                best = (stamp, session_id)
    return best[1] if best else None


def claude_conversation_id(cwd):
    path = os.path.join(home(), ".claude", "history.jsonl")
    if not os.path.exists(path):
        return None
    found = None
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if same_path(item.get("project"), cwd) and item.get("sessionId"):
                    found = item["sessionId"]
    except OSError:
        return None
    return found


def conversation_id(kind, pane, info, used):
    session = pane.get("agent_session") if isinstance(pane.get("agent_session"), dict) else {}
    if session.get("kind") == "id" and session.get("value"):
        return session["value"]
    cwd = pane.get("cwd") or pane.get("foreground_cwd")
    if kind == "cursor":
        for proc in info.get("foreground_processes") or []:
            if proc.get("pid"):
                found = cursor_conversation_id(proc["pid"])
                if found:
                    return found
        return None
    if kind == "codex":
        return codex_conversation_id(cwd, used)
    if kind == "claude":
        return claude_conversation_id(cwd)
    return None


def resume_args(kind, session_id):
    if kind == "codex":
        return ["resume", session_id]
    return ["--resume", session_id]


def agent_name(kind, pane_id, taken):
    suffix = re.sub(r"[^a-z0-9_-]", "", (pane_id or "").lower().split(":")[-1]) or "pane"
    base = f"reuse-{kind}-{suffix}"[:32]
    name = base
    number = 2
    while name in taken:
        extra = f"-{number}"
        name = (base[: 32 - len(extra)] + extra)
        number += 1
    taken.add(name)
    return name


def shell_ready(pane_id):
    info = pane_process(pane_id)
    text = foreground_text(info)
    return any(name in text for name in ("powershell", "pwsh", "cmd.exe"))


def stop_agent(pane_id, kind):
    for _ in range(6):
        if shell_ready(pane_id):
            return True
        run_herdr(["pane", "send-keys", pane_id, "ctrl+c"])
        time.sleep(0.7)
    return shell_ready(pane_id)


def restart_provider_sessions(provider_id):
    kind = AGENT_KIND.get(provider_id)
    if not kind:
        return ""
    payload = run_herdr(["pane", "list"])
    panes = ((payload.get("result") or {}).get("panes") or [])
    used = set()
    taken = set()
    restarted = 0
    missed = 0
    for pane in panes:
        if pane.get("label") == "AI Usage":
            continue
        pane_id = pane.get("pane_id")
        if not pane_id:
            continue
        info = pane_process(pane_id)
        if pane.get("agent") != kind and not foreground_matches(kind, info):
            continue
        session_id = conversation_id(kind, pane, info, used)
        if not session_id:
            missed += 1
            continue
        used.add(session_id)
        if not stop_agent(pane_id, kind):
            missed += 1
            continue
        name = agent_name(kind, pane_id, taken)
        started = False
        for _ in range(3):
            if not shell_ready(pane_id):
                time.sleep(0.5)
                continue
            try:
                proc = subprocess.run(
                    [herdr_bin(), "agent", "start", name, "--kind", kind, "--pane", pane_id, "--timeout", "45000", "--", *resume_args(kind, session_id)],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=60,
                )
            except (OSError, subprocess.TimeoutExpired):
                proc = None
            if proc is not None and proc.returncode == 0:
                started = True
                break
            time.sleep(0.8)
        if not started:
            missed += 1
            continue
        restarted += 1
    if not restarted and not missed:
        return ""
    label = {"cursor": "Cursor", "codex": "Codex", "claude": "Claude"}[kind]
    parts = []
    if restarted:
        parts.append(f"{label} 터미널 {restarted}곳을 같은 대화로 다시 열었습니다")
    if missed:
        parts.append(f"{missed}곳은 다시 열지 못했습니다")
    return " ".join(parts)


def activate_account(account_id):
    accounts = load_accounts()
    chosen = next((item for item in accounts if item.get("id") == account_id), None)
    if not chosen:
        return None, "계정을 찾지 못했습니다"
    if chosen.get("provider") == "chatgpt":
        absorb_live_codex(accounts)
    installed, detail = install_saved_session(chosen)
    if chosen.get("provider") == "chatgpt":
        save_accounts(accounts)
    if not installed:
        return None, detail
    for item in accounts:
        if item.get("provider") == chosen.get("provider"):
            item["active"] = item.get("id") == account_id
    save_accounts(accounts)
    remember_saved_source(chosen["provider"], chosen["id"])
    restarted = restart_provider_sessions(chosen["provider"])
    if restarted:
        detail = detail + " " + restarted
    return fetch_provider(chosen["provider"]), detail


def delete_account(account_id):
    accounts = load_accounts()
    chosen = next((item for item in accounts if item.get("id") == account_id), None)
    if not chosen:
        return None, "계정을 찾지 못했습니다"
    save_accounts([item for item in accounts if item.get("id") != account_id])
    record = load_sources().get(chosen.get("provider"))
    if isinstance(record, dict) and record.get("accountId") == account_id:
        save_source(
            chosen["provider"],
            {"mode": "live", "liveIdentity": stored_identity(live_identity(chosen["provider"]))},
        )
    return fetch_provider(chosen["provider"]), "저장한 세션을 제거했습니다"


def clear_live_session(provider_id):
    if provider_id == "cursor":
        ok, message = clear_cursor_session()
    elif provider_id == "chatgpt":
        ok, message = delete_session_file(codex_auth_path(), "Codex")
    else:
        ok, message = delete_session_file(claude_credentials_path(), "Claude")
    if not ok:
        return None, message
    accounts = load_accounts()
    for item in accounts:
        if item.get("provider") == provider_id:
            item["active"] = False
    save_accounts(accounts)
    save_source(provider_id, {"mode": "live", "liveIdentity": stored_identity(live_identity(provider_id))})
    return fetch_provider(provider_id), message


def delete_session_file(path, name):
    if not os.path.exists(path):
        return False, f"지울 {name} 세션 파일이 없습니다"
    try:
        os.remove(path)
    except OSError:
        return False, f"{name} 세션 파일을 지우지 못했습니다"
    return True, f"{name} 세션 파일을 지웠습니다"


def clear_cursor_session():
    path = cursor_db_path()
    if not os.path.exists(path):
        return False, "지울 Cursor 세션이 없습니다"
    try:
        connection = sqlite3.connect(path, timeout=2)
        try:
            connection.execute(
                """
                DELETE FROM ItemTable WHERE key IN (
                    'cursorAuth/accessToken',
                    'cursorAuth/refreshToken'
                )
                """
            )
            connection.commit()
        finally:
            connection.close()
    except sqlite3.Error:
        return False, "Cursor를 종료한 뒤 다시 세션을 지우세요"
    return True, "Cursor 로그인 세션을 지웠습니다"


TEXT = (224, 222, 244)
MUTED = (144, 140, 170)
DIM = (110, 106, 134)
ACCENT = (246, 193, 119)
SELECT_BG = (88, 78, 122)
CRITICAL = (235, 111, 146)


def display_width(text):
    width = 0
    for char in text:
        width += 2 if unicodedata.east_asian_width(char) in {"F", "W"} else 1
    return width


def terminal_size():
    columns, lines = raw_terminal_size()
    return max(columns, 40), max(lines, 16)


def raw_terminal_size():
    try:
        size = os.get_terminal_size()
        return max(size.columns, 1), max(size.lines, 1)
    except OSError:
        return 80, 3


def clip_ansi(text, width):
    if width <= 0:
        return ""
    kept = []
    used = 0
    index = 0
    while index < len(text):
        if text[index] == "\x1b":
            end = text.find("m", index)
            if end < 0:
                break
            kept.append(text[index : end + 1])
            index = end + 1
            continue
        char = text[index]
        char_width = 2 if unicodedata.east_asian_width(char) in {"F", "W"} else 1
        if used + char_width > width:
            break
        kept.append(char)
        used += char_width
        index += 1
    kept.append("\x1b[0m")
    return "".join(kept)


def fit_frame(frame, columns, rows):
    lines = [clip_ansi(line, columns) for line in frame.split("\n") if line] if frame else []
    return "\n".join(lines[: max(rows, 1)])


def paint(text, color, bold=False):
    weight = "1;" if bold else ""
    red, green, blue = color
    return f"\x1b[{weight}38;2;{red};{green};{blue}m{text}"


def paint_line(segments, width, background=None):
    body = "".join(paint(text, color, bold) for text, color, bold in segments)
    used = sum(display_width(text) for text, _, _ in segments)
    pad = " " * max(0, width - used)
    if background:
        red, green, blue = background
        return f"\x1b[48;2;{red};{green};{blue}m{body}{pad}\x1b[0m"
    return body + "\x1b[0m"


def menu_items(accounts, expanded):
    items = []
    for provider_id in ORDER:
        items.append({"kind": "toggle", "provider": provider_id, "key": ("toggle", provider_id)})
        items.append({"kind": "save", "provider": provider_id, "key": ("save", provider_id)})
        items.append({"kind": "logout", "provider": provider_id, "key": ("logout", provider_id)})
        items.append({"kind": "sessions", "provider": provider_id, "key": ("sessions", provider_id)})
        if provider_id in expanded:
            for account in accounts:
                if account.get("provider") == provider_id:
                    items.append(
                        {
                            "kind": "account",
                            "provider": provider_id,
                            "account": account,
                            "key": ("account", account.get("id")),
                        }
                    )
    return items


def clip_text(text, width):
    if width <= 0:
        return ""
    if display_width(text) <= width:
        return text
    kept = ""
    for char in text:
        if display_width(kept + char) > width - 1:
            break
        kept += char
    return kept + "…"


def exact_width(text, width):
    text = clip_text(text, width)
    return text + (" " * max(0, width - display_width(text)))


def frame_line(left, content, right, border, inner, background=None):
    body = paint_line(content, inner, background)
    return paint(left, border, True) + "\x1b[0m" + body + paint(right, border, True) + "\x1b[0m"


def plain_segments(text, color, bold=False):
    return [(text, color, bold)]


def content_window_start(selected_at, total, room, card_starts):
    """Keep the shortcut header from covering the card that holds the selection.

    The first screen stays pinned to the top, so the Cursor card renders fully
    under the shortcut guide. Later cards scroll to their own top border.
    """
    if room <= 0 or total <= room or selected_at < room:
        return 0
    card = 0
    for start in card_starts:
        if start <= selected_at:
            card = start
        else:
            break
    max_start = total - room
    start = card
    if selected_at >= start + room:
        start = selected_at - room + 1
    return max(0, min(start, max_start))


def render_dashboard(snapshot, accounts, visible, selected_key, notice, error, width, height, expanded):
    width = max(width, 48)
    inner = width - 2
    meter_bar = max(8, inner - 30)
    stamp = parse_iso((snapshot or {}).get("fetchedAt"))
    clock = stamp.astimezone().strftime("%H:%M:%S") if stamp else "--:--:--"
    items = menu_items(accounts, expanded)
    if selected_key not in {item["key"] for item in items} and items:
        selected_key = items[0]["key"]

    def banner(title, badge, border):
        core = f"─ {title} "
        tail = f" {badge} ─" if badge else "─"
        fill = max(0, inner - display_width(core) - display_width(tail))
        text = exact_width(core + ("─" * fill) + tail, inner)
        return frame_line("╭", plain_segments(text, border), "╮", border, inner)

    def edge(char, border):
        return frame_line(char, plain_segments("─" * inner, border), "╯" if char == "╰" else "╮", border, inner)

    def row(segments, border, background=None):
        return frame_line("│", segments, "│", border, inner, background)

    current = next((item for item in items if item["key"] == selected_key), None)
    if current and current["kind"] == "account":
        shortcuts = "  ↑↓ 이동    Enter 적용    d 세션 제거    q 닫기"
    else:
        shortcuts = "  ↑↓ 이동    Enter 실행    r 새로고침    q 닫기"
    header_border = (186, 170, 214)
    header = [
        banner("AI USAGE", clock, header_border),
        row(plain_segments(exact_width(shortcuts, inner), MUTED), header_border),
        edge("╰", header_border),
    ]
    lines = [""]
    selected_at = 0
    card_starts = []

    for provider_id in ORDER:
        meta = BY_ID[provider_id]
        provider = provider_of(snapshot, provider_id) or empty_provider(provider_id)
        shown = provider_id in visible
        border = meta["color"] if shown else DIM
        badge = "표시" if shown else "숨김"
        card_starts.append(len(lines))
        lines.append(banner(meta["name"], badge, border))
        muted = not shown
        detail = [part for part in (provider.get("accountLabel"), provider.get("planName")) if part]
        if detail:
            lines.append(row(plain_segments(exact_width("  " + " · ".join(detail), inner), DIM if muted else MUTED), border))
        for side, label in (("left", meta["left"]), ("right", meta["right"])):
            meter = provider.get(side) or {}
            percent = meter.get("remainingPercent")
            value = "—" if percent is None else f"{percent}%"
            graph = bar(percent, meter_bar) if percent is not None else "·" * meter_bar
            tone = DIM if muted else (MUTED if percent is None else level_color(percent))
            label_tone = DIM if muted else TEXT
            parsed = parse_iso(meter.get("resetsAt")) if meter.get("resetsAt") else None
            reset = parsed.astimezone().strftime("%m/%d %H:%M") if parsed else " " * 11
            label_text = "  " + pad_width(label, 6) + "  "
            value_text = pad_width(value, 4, "right") + "  "
            reset_text = "  " + reset
            lines.append(
                row(
                    [
                        (label_text, label_tone, False),
                        (value_text, tone, True),
                        (graph, tone, False),
                        (reset_text, DIM if muted or not parsed else ACCENT, False),
                        (" ", TEXT, False),
                    ],
                    border,
                )
            )
        if provider.get("statusMessage"):
            tone = MUTED if provider.get("status") == "ok" else CRITICAL
            lines.append(row(plain_segments(exact_width("  " + provider["statusMessage"], inner), tone), border))
        saved = [item for item in accounts if item.get("provider") == provider_id]
        opened = provider_id in expanded
        session_label = "세션 목록 닫기" if opened else "세션 목록 보기"
        if not opened and saved:
            session_label = f"세션 목록 보기  {len(saved)}개"
        actions = [
            ("toggle", "상태줄에서 숨기기" if shown else "상태줄에 표시", False),
            ("save", "현재 세션 저장", False),
            ("logout", "현재 세션 파일 제거", True),
            ("sessions", session_label, False),
        ]
        for kind, label, danger in actions:
            key = (kind, provider_id)
            selected = key == selected_key
            if selected:
                selected_at = len(lines)
            mark = "▸ " if selected else "  "
            hint = "Enter" if selected else ""
            label_text = mark + label
            room = inner - 3 - display_width(hint)
            text = " " + clip_text(label_text, room)
            gap = max(1, inner - 1 - display_width(text) - display_width(hint))
            lines.append(
                row(
                    [
                        (text, CRITICAL if selected and danger else TEXT if selected else MUTED, selected),
                        (" " * gap, TEXT, False),
                        (hint, CRITICAL if selected and danger else ACCENT if selected else DIM, False),
                        (" ", TEXT, False),
                    ],
                    border,
                    SELECT_BG if selected else None,
                )
            )
        if opened:
            caption = " 저장한 세션 "
            fill = max(0, inner - 2 - display_width(caption))
            left = fill // 2
            rule = " " + ("─" * left) + caption + ("─" * (fill - left)) + " "
            lines.append(row(plain_segments(rule, DIM), border))
            if not saved:
                lines.append(row(plain_segments(exact_width("  저장된 세션이 없습니다", inner), DIM), border))
        for account in saved if opened else []:
            key = ("account", account.get("id"))
            selected = key == selected_key
            if selected:
                selected_at = len(lines)
            name = account.get("displayName") or meta["name"]
            plan_name = account.get("planName")
            if generic_account_name(name) or not plan_name:
                token_label, token_plan = profile_from_token(provider_id, account.get("oauthToken") or "")
                if generic_account_name(name) and not generic_account_name(token_label):
                    name = token_label
                if not plan_name:
                    plan_name = token_plan
            plan = f" · {plan_name}" if plan_name else ""
            if account.get("active"):
                hint = "적용 중"
                mark = "● "
            else:
                hint = "Enter 적용" if selected else ""
                mark = "○ "
            prefix = ("▸ " if selected else "  ") + mark
            room = inner - 3 - display_width(hint)
            text = " " + clip_text(prefix + name + plan, max(4, room))
            gap = max(1, inner - 1 - display_width(text) - display_width(hint))
            lines.append(
                row(
                    [
                        (text, TEXT if selected else MUTED, selected or account.get("active")),
                        (" " * gap, TEXT, False),
                        (hint, ACCENT if selected else (156, 207, 142) if account.get("active") else DIM, False),
                        (" ", TEXT, False),
                    ],
                    border,
                    SELECT_BG if selected else None,
                )
            )
        lines.append(edge("╰", border))
        lines.append("")

    notice_lines = []
    if notice:
        tone = CRITICAL if error else ACCENT
        notice_lines = ["", banner(notice, "", tone), edge("╰", tone)]
    room = max(1, height - len(header) - len(notice_lines))
    if len(lines) > room:
        start = content_window_start(selected_at, len(lines), room, card_starts)
        lines = lines[start : start + room]
    return "\n".join(header + lines + notice_lines), selected_key


def read_stream_key():
    data = sys.stdin.buffer.read(1)
    if not data:
        return "q"
    if data == b"\x1b":
        extra = b""
        if os.name == "nt":
            import ctypes

            avail = ctypes.c_ulong()
            handle = ctypes.windll.kernel32.GetStdHandle(-10)
            if ctypes.windll.kernel32.PeekNamedPipe(handle, None, 0, None, ctypes.byref(avail), None) and avail.value:
                extra = sys.stdin.buffer.read(min(int(avail.value), 6))
        text = extra.decode("ascii", "replace")
        if text in {"[A", "OA"}:
            return "up"
        if text in {"[B", "OB"}:
            return "down"
        return "esc"
    if data in {b"\r", b"\n"}:
        return "enter"
    if data == b"\x03":
        return "ctrl-c"
    return data.decode("utf-8", "replace").lower()


def console_input_ready():
    if os.name != "nt":
        return sys.stdin.isatty()
    import ctypes

    handle = ctypes.windll.kernel32.GetStdHandle(-10)
    mode = ctypes.c_uint()
    return bool(ctypes.windll.kernel32.GetConsoleMode(handle, ctypes.byref(mode)))


def read_key():
    if os.name == "nt" and console_input_ready():
        import msvcrt

        char = msvcrt.getwch()
        if char in {"\x00", "\xe0"}:
            nxt = msvcrt.getwch()
            return {"H": "up", "P": "down", "K": "left", "M": "right", "S": "delete"}.get(nxt, "")
        if char == "\x1b":
            sequence = ""
            while msvcrt.kbhit() and len(sequence) < 6:
                sequence += msvcrt.getwch()
            if sequence in {"[A", "OA"}:
                return "up"
            if sequence in {"[B", "OB"}:
                return "down"
            return "esc"
        if char in {"\r", "\n"}:
            return "enter"
        if char == "\x03":
            return "ctrl-c"
        return char.lower()
    if os.name == "nt":
        return read_stream_key()
    import select
    import termios
    import tty

    fd = sys.stdin.fileno()
    attrs = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        char = sys.stdin.read(1)
        if char == "\x1b":
            extra = ""
            while select.select([sys.stdin], [], [], 0.02)[0] and len(extra) < 6:
                extra += sys.stdin.read(1)
            if extra in {"[A", "OA"}:
                return "up"
            if extra in {"[B", "OB"}:
                return "down"
            return "esc"
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, attrs)
    if char in {"\r", "\n"}:
        return "enter"
    if char == "\x03":
        return "ctrl-c"
    return char.lower()


def input_waiting():
    if os.name == "nt" and console_input_ready():
        import msvcrt

        return msvcrt.kbhit()
    if os.name == "nt":
        import ctypes

        avail = ctypes.c_ulong()
        handle = ctypes.windll.kernel32.GetStdHandle(-10)
        if not ctypes.windll.kernel32.PeekNamedPipe(handle, None, 0, None, ctypes.byref(avail), None):
            return None
        return avail.value > 0
    import select

    return bool(select.select([sys.stdin], [], [], 0)[0])


def read_key_or_pause(seconds=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        waiting = input_waiting()
        if waiting is None:
            return read_key()
        if waiting:
            return read_key()
        time.sleep(0.05)
    return None


def render_confirm(title, detail, selected, width, height):
    width = max(width, 48)
    inner = width - 2
    border = CRITICAL
    header_border = (186, 170, 214)

    def band(left, text, right, frame_color, text_color, bold=False, background=None):
        return frame_line(
            left,
            [(exact_width(text, inner), text_color, bold)],
            right,
            frame_color,
            inner,
            background,
        )

    def banner(text, color):
        core = f"─ {text} "
        fill = max(0, inner - display_width(core) - 1)
        return band("╭", core + ("─" * fill) + "─", "╮", color, color, True)

    def edge(color):
        return band("╰", "─" * inner, "╯", color, color)

    lines = [
        banner("확인", header_border),
        band("│", "  ↑↓ 선택    Enter 확인    q 취소", "│", header_border, MUTED),
        edge(header_border),
        "",
        banner(title, border),
        band("│", "  " + detail, "│", border, TEXT),
        band("│", "", "│", border, TEXT),
    ]
    for index, label in enumerate(("제거", "취소")):
        chosen = index == selected
        mark = "▸ " if chosen else "  "
        tone = CRITICAL if chosen and label == "제거" else TEXT if chosen else MUTED
        lines.append(band("│", "  " + mark + label, "│", border, tone, chosen, SELECT_BG if chosen else None))
    lines.append(edge(border))
    if len(lines) > height:
        lines = lines[:height]
    return "\n".join(lines)


def ask_confirm(title, detail, width, height):
    selected = 1
    while True:
        draw_dashboard(render_confirm(title, detail, selected, width, height))
        key = read_key()
        if key in {"up", "k", "down", "j"}:
            selected = 1 - selected
        elif key in {"enter", " "}:
            return selected == 0
        elif key in {"q", "esc", "ctrl-c"}:
            return False


def draw_dashboard(frame):
    sys.stdout.write("\x1b[H\x1b[J" + frame)
    sys.stdout.flush()


def dashboard():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stdout.write("\x1b[?1049h\x1b[?25l")
    sys.stdout.flush()
    notice = "불러오는 중…"
    error = False
    selected = ("toggle", "cursor")
    expanded = set()
    try:
        width, height = terminal_size()
        snapshot = load_snapshot()
        frame, selected = render_dashboard(snapshot, load_accounts(), set(load_visible() or ORDER), selected, notice, error, width, height, expanded)
        draw_dashboard(frame)
        backfill_account_profiles()
        snapshot = refresh(force=True, ignore_gate=True)
        notice = None
        seen_login = credential_stamp()
        while True:
            accounts = load_accounts()
            visible = set(load_visible() or ORDER)
            width, height = terminal_size()
            frame, selected = render_dashboard(snapshot, accounts, visible, selected, notice, error, width, height, expanded)
            draw_dashboard(frame)
            key = None
            while key is None:
                key = read_key_or_pause()
                current_login = credential_stamp()
                if current_login is not None and current_login != seen_login:
                    seen_login = current_login
                    notice = "로그인한 계정을 다시 읽는 중…"
                    error = False
                    frame, selected = render_dashboard(snapshot, load_accounts(), set(load_visible() or ORDER), selected, notice, error, width, height, expanded)
                    draw_dashboard(frame)
                    snapshot = refresh(force=True, ignore_gate=True)
                    notice = "로그인한 계정이 바뀌어 사용량을 갱신했습니다"
                    key = "login-changed"
                    break
            if key == "login-changed":
                continue
            notice = None
            error = False
            items = menu_items(load_accounts(), expanded)
            keys = [item["key"] for item in items]
            if selected not in keys and keys:
                selected = keys[0]
            index = keys.index(selected) if selected in keys else 0
            if key in {"q", "esc", "ctrl-c"}:
                return
            if key in {"up", "k"} and keys:
                selected = keys[(index - 1) % len(keys)]
                continue
            if key in {"down", "j"} and keys:
                selected = keys[(index + 1) % len(keys)]
                continue
            if key == "r":
                notice = "새로고침 중…"
                frame, selected = render_dashboard(snapshot, load_accounts(), set(load_visible() or ORDER), selected, notice, False, width, height, expanded)
                draw_dashboard(frame)
                snapshot = refresh(force=True, ignore_gate=True)
                seen_login = credential_stamp()
                notice = "사용량을 새로고침했습니다"
                continue
            current = next((item for item in items if item["key"] == selected), None)
            if not current:
                continue
            if key in {"enter", " "}:
                if current["kind"] == "toggle":
                    shown = toggle_visible(current["provider"])
                    notice = "상태줄에 표시합니다" if shown else "상태줄에서 숨겼습니다"
                elif current["kind"] == "sessions":
                    provider_id = current["provider"]
                    if provider_id in expanded:
                        expanded.discard(provider_id)
                    else:
                        expanded.add(provider_id)
                elif current["kind"] == "save":
                    notice = "현재 세션을 저장하는 중…"
                    frame, selected = render_dashboard(snapshot, load_accounts(), set(load_visible() or ORDER), selected, notice, False, width, height, expanded)
                    draw_dashboard(frame)
                    notice = capture(current["provider"])
                    error = "저장했습니다" not in notice
                    if not error:
                        snapshot = store_provider(snapshot, fetch_provider(current["provider"]))
                elif current["kind"] == "account":
                    notice = "저장한 세션을 적용하는 중…"
                    frame, selected = render_dashboard(snapshot, load_accounts(), set(load_visible() or ORDER), selected, notice, False, width, height, expanded)
                    draw_dashboard(frame)
                    provider, notice = activate_account(current["account"].get("id"))
                    error = provider is None
                    if provider:
                        snapshot = store_provider(snapshot, provider)
                elif current["kind"] == "logout":
                    name = BY_ID[current["provider"]]["name"]
                    if not ask_confirm("현재 세션 파일 제거", f"{name}에 로그인된 세션 파일을 지웁니다.", width, height):
                        notice = "세션 파일 제거를 취소했습니다"
                        continue
                    notice = "현재 세션 파일을 제거하는 중…"
                    frame, selected = render_dashboard(snapshot, load_accounts(), set(load_visible() or ORDER), selected, notice, False, width, height, expanded)
                    draw_dashboard(frame)
                    provider, notice = clear_live_session(current["provider"])
                    error = provider is None
                    if provider:
                        snapshot = store_provider(snapshot, provider)
                continue
            if key == "d" and current["kind"] == "account":
                label = current["account"].get("displayName") or "이 세션"
                if not ask_confirm("저장한 세션 제거", f"{label} 세션을 목록에서 지웁니다.", width, height):
                    notice = "세션 제거를 취소했습니다"
                    continue
                provider, notice = delete_account(current["account"].get("id"))
                error = provider is None
                if provider:
                    snapshot = store_provider(snapshot, provider)
    finally:
        sys.stdout.write("\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()


def statusbar():
    sys.stdout.write(f"\x1b]0;{TITLE_MARKER}\x07\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H")
    sys.stdout.flush()
    try:
        while True:
            columns, rows = raw_terminal_size()
            frame = fit_frame(statusbar_frame(load_snapshot()), columns, rows)
            # Repaint the fixed viewport. A normal-screen newline would scroll a
            # copy of the same row into history, and a scrolled pane shows those copies.
            sys.stdout.write("\x1b[H\x1b[2J" + frame)
            sys.stdout.flush()
            time.sleep(2)
    finally:
        sys.stdout.write("\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()


def socket_path():
    configured = os.environ.get("HERDR_SOCKET_PATH")
    if configured:
        return configured
    appdata = os.environ.get("APPDATA")
    if appdata:
        return os.path.join(appdata, "herdr", "herdr.sock")
    return os.path.join(home(), ".config", "herdr", "herdr.sock")


def rpc(method, params):
    path = socket_path()
    endpoint = "\\\\.\\pipe\\" + path if os.name == "nt" else path
    try:
        with open(endpoint, "r+b", buffering=0) as handle:
            handle.write(json.dumps({"id": "ai-usage", "method": method, "params": params}).encode("utf-8") + b"\n")
            data = b""
            while b"\n" not in data and len(data) < 500_000:
                chunk = handle.read(65536)
                if not chunk:
                    break
                data += chunk
    except OSError:
        return None
    try:
        return json.loads(data.split(b"\n", 1)[0].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None


def layout_root(tab_id):
    payload = rpc("layout.export", {"tab_id": tab_id}) or {}
    layout = ((payload.get("result") or {}).get("layout") or {})
    return layout.get("root") or layout or None


def find_split(node, pane_id, path=None):
    if not isinstance(node, dict):
        return None
    path = path or []
    first = node.get("first")
    second = node.get("second")
    if node.get("type") == "pane" or (node.get("pane_id") and first is None):
        return None
    if isinstance(second, dict) and second.get("pane_id") == pane_id:
        return path, float(node.get("ratio") or 0), True
    if isinstance(first, dict) and first.get("pane_id") == pane_id:
        return path, float(node.get("ratio") or 0), False
    if isinstance(first, dict):
        found = find_split(first, pane_id, path + [False])
        if found:
            return found
    if isinstance(second, dict):
        return find_split(second, pane_id, path + [True])
    return None


def pin_status(tab_id, pane_id):
    found = find_split(layout_root(tab_id), pane_id)
    if not found:
        return
    path, ratio, status_is_second = found
    target = 0.9 if status_is_second else 0.1
    if abs(ratio - target) < 0.02:
        return
    rpc("layout.set_split_ratio", {"tab_id": tab_id, "path": path, "ratio": target})


def pane_rows():
    result = (run_herdr(["pane", "list"]).get("result") or {})
    panes = []
    for pane in result.get("panes") or []:
        pane_id = pane.get("pane_id")
        tab_id = pane.get("tab_id")
        if not pane_id or not tab_id:
            continue
        title = pane.get("terminal_title") or pane.get("terminal_title_stripped") or ""
        label = pane.get("label") or ""
        status = TITLE_MARKER in title
        scroll = pane.get("scroll") or {}
        panes.append(
            {
                "id": pane_id,
                "tab_id": tab_id,
                "title": title,
                "label": label,
                "focused": bool(pane.get("focused")),
                "status": status,
                "stale": label == "AI Usage" and not status,
                "offset": scroll.get("offset_from_bottom") or 0,
            }
        )
    return panes


def focused_workspace():
    result = (run_herdr(["workspace", "list"]).get("result") or {})
    workspaces = result.get("workspaces") or []
    chosen = next((item for item in workspaces if item.get("focused")), None) or (workspaces[0] if workspaces else None)
    return chosen.get("workspace_id") if chosen else None


def tab_ids(workspace_id):
    result = (run_herdr(["tab", "list"]).get("result") or {})
    ids = []
    for tab in result.get("tabs") or []:
        if workspace_id and tab.get("workspace_id") != workspace_id:
            continue
        if tab.get("tab_id"):
            ids.append(tab["tab_id"])
    return ids


def close_stale_shells(tab_id, panes):
    now = time.time()
    closed = False
    for pane in panes:
        if pane["tab_id"] != tab_id or not pane["stale"]:
            continue
        opened = OPENED_AT.get(pane["id"])
        if opened is not None and now - opened < 3:
            continue
        run_herdr(["pane", "close", pane["id"]])
        OPENED_AT.pop(pane["id"], None)
        closed = True
    return closed


def stick_status_panes(panes):
    for pane in panes:
        if pane["status"] and pane.get("offset"):
            rpc("pane.scroll", {"pane_id": pane["id"], "offset_from_bottom": 0})


def dedupe_status(on_tab):
    slots = [pane for pane in on_tab if pane["status"] or pane["stale"]]
    if len(slots) < 2:
        return False
    keeper = next((pane for pane in slots if pane["status"]), slots[0])
    closed = False
    for pane in slots:
        if pane["id"] == keeper["id"]:
            continue
        run_herdr(["pane", "close", pane["id"]])
        OPENED_AT.pop(pane["id"], None)
        closed = True
    return closed


def ensure(all_workspaces=False, repair_ratio=True):
    workspace_id = None if all_workspaces else focused_workspace()
    if not all_workspaces and not workspace_id:
        return
    panes = pane_rows()
    stick_status_panes(panes)
    for tab_id in tab_ids(workspace_id):
        if close_stale_shells(tab_id, panes):
            panes = pane_rows()
        on_tab = [pane for pane in panes if pane["tab_id"] == tab_id]
        if dedupe_status(on_tab):
            panes = pane_rows()
            on_tab = [pane for pane in panes if pane["tab_id"] == tab_id]
        content = [pane for pane in on_tab if not pane["status"] and not pane["stale"]]
        if not content:
            if any(pane["status"] for pane in on_tab):
                run_herdr(["tab", "close", tab_id])
            continue
        # A just-opened status pane is labeled AI Usage before its title is set.
        # Treat that pane as the status slot so a second one is not opened.
        existing = next((pane for pane in on_tab if pane["status"] or pane["stale"]), None)
        if existing:
            if repair_ratio:
                pin_status(tab_id, existing["id"])
            continue
        target = next((pane for pane in content if pane["focused"]), None) or content[0]
        before = {pane["id"] for pane in panes}
        run_herdr(
            [
                "plugin",
                "pane",
                "open",
                "--plugin",
                "ai-usage",
                "--entrypoint",
                "statusbar",
                "--placement",
                "split",
                "--direction",
                "down",
                "--target-pane",
                target["id"],
                "--no-focus",
            ]
        )
        created = next((pane for pane in pane_rows() if pane["tab_id"] == tab_id and pane["id"] not in before), None)
        if created:
            OPENED_AT[created["id"]] = time.time()
            pin_status(tab_id, created["id"])


def watch():
    ensure(all_workspaces=True, repair_ratio=True)
    backfill_account_profiles()
    refresh(force=True, ignore_gate=True)
    seen_login = credential_stamp()
    ticks = 0
    while True:
        ensure(all_workspaces=False, repair_ratio=ticks % 10 == 0)
        time.sleep(0.2)
        ticks += 1
        if ticks % 10 == 0:
            current_login = credential_stamp()
            if current_login is not None and current_login != seen_login:
                seen_login = current_login
                refresh(force=True, ignore_gate=True)
        if ticks >= 1500:
            ticks = 0
            refresh(force=False)


def open_dashboard():
    proc = subprocess.run(
        [herdr_bin(), "plugin", "pane", "open", "--plugin", "ai-usage", "--entrypoint", "dashboard", "--focus"],
        check=False,
    )
    raise SystemExit(proc.returncode)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "dashboard"
    if command == "status":
        print(status_line(refresh(force=False)))
        return
    if command == "refresh":
        snapshot = refresh(force=True)
        for provider_id in ORDER:
            print(compact(provider_id, provider_of(snapshot, provider_id)))
        return
    if command == "statusbar":
        statusbar()
        return
    if command == "watch":
        watch()
        return
    if command == "open":
        open_dashboard()
        return
    dashboard()


if __name__ == "__main__":
    main()
