#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import threading
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit
from uuid import uuid4


BASE_DIR = Path(__file__).resolve().parent
PUBLIC_DIR = BASE_DIR / "public"
CONFIG_FILE = BASE_DIR / "config.yaml"
SUBSCRIPTION_FILE = BASE_DIR / ".subscription_url"
SUBSCRIPTIONS_FILE = BASE_DIR / ".subscriptions.json"
UPDATE_SCRIPT = BASE_DIR / "update-subscription.sh"
YQ_BIN = BASE_DIR / "bin" / "yq"
HTML_FILE = PUBLIC_DIR / "subscription.html"
UPDATE_LOCK = threading.Lock()


def run_command(args: list[str], timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=str(BASE_DIR),
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def current_secret() -> str:
    result = run_command([str(YQ_BIN), "-r", ".secret // \"\"", str(CONFIG_FILE)])
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def current_subscription_url() -> str:
    if not SUBSCRIPTION_FILE.exists():
        return ""
    return SUBSCRIPTION_FILE.read_text(encoding="utf-8").strip()


def current_service_state() -> str:
    result = run_command(["systemctl", "--user", "is-active", "mihomo.service"])
    state = result.stdout.strip()
    return state or "unknown"


def default_name_from_url(url: str, index: int | None = None) -> str:
    parts = urlsplit(url)
    if parts.scheme in {"http", "https"}:
        label = parts.hostname or "subscription"
    elif url.startswith("file://"):
        label = Path(url[7:]).name or "local-file"
    elif Path(url).exists():
        label = Path(url).name or "local-file"
    else:
        label = "subscription"

    if index is not None and label == "subscription":
        return f"Subscription {index}"
    return label


def sanitize_subscription(raw: object, index: int) -> dict[str, str] | None:
    if not isinstance(raw, dict):
        return None

    url = str(raw.get("url", "")).strip()
    if not url:
        return None

    sub_id = str(raw.get("id", "")).strip() or uuid4().hex
    created_at = str(raw.get("created_at", "")).strip() or now_iso()
    updated_at = str(raw.get("updated_at", "")).strip() or created_at
    name = str(raw.get("name", "")).strip() or default_name_from_url(url, index)

    return {
        "id": sub_id,
        "name": name,
        "url": url,
        "created_at": created_at,
        "updated_at": updated_at,
    }


def read_store() -> tuple[dict[str, object], bool]:
    changed = False
    raw_store: dict[str, object] = {"version": 1, "active_id": "", "subscriptions": []}

    if SUBSCRIPTIONS_FILE.exists():
        try:
            loaded = json.loads(SUBSCRIPTIONS_FILE.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                raw_store = loaded
            else:
                changed = True
        except json.JSONDecodeError:
            changed = True

    sanitized_subscriptions: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    for index, raw in enumerate(raw_store.get("subscriptions", []), start=1):
        sanitized = sanitize_subscription(raw, index)
        if sanitized is None:
            changed = True
            continue
        if sanitized["id"] in seen_ids:
            sanitized["id"] = uuid4().hex
            changed = True
        seen_ids.add(sanitized["id"])
        sanitized_subscriptions.append(sanitized)

    active_id = str(raw_store.get("active_id", "")).strip()
    if active_id and active_id not in seen_ids:
        active_id = ""
        changed = True

    current_url = current_subscription_url()
    if current_url:
        matched = next((item for item in sanitized_subscriptions if item["url"] == current_url), None)
        if matched is None:
            imported = {
                "id": uuid4().hex,
                "name": f"Imported {default_name_from_url(current_url)}",
                "url": current_url,
                "created_at": now_iso(),
                "updated_at": now_iso(),
            }
            sanitized_subscriptions.insert(0, imported)
            active_id = imported["id"]
            changed = True
        elif active_id != matched["id"]:
            active_id = matched["id"]
            changed = True

    store: dict[str, object] = {
        "version": 1,
        "active_id": active_id,
        "subscriptions": sanitized_subscriptions,
    }
    return store, changed


def write_store(store: dict[str, object]) -> None:
    SUBSCRIPTIONS_FILE.write_text(
        json.dumps(store, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def ensure_store() -> dict[str, object]:
    store, changed = read_store()
    if changed or not SUBSCRIPTIONS_FILE.exists():
        write_store(store)
    return store


def find_subscription(store: dict[str, object], sub_id: str) -> dict[str, str] | None:
    for item in store["subscriptions"]:
        if item["id"] == sub_id:
            return item
    return None


def active_subscription(store: dict[str, object]) -> dict[str, str] | None:
    active_id = str(store.get("active_id", "")).strip()
    if not active_id:
        return None
    return find_subscription(store, active_id)


def build_base_url(host_header: str) -> str:
    parsed = urlsplit(f"http://{host_header or '127.0.0.1'}")
    host = parsed.hostname or "127.0.0.1"
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"http://{host}"


def api_payload(base_url: str, store: dict[str, object] | None = None) -> dict[str, object]:
    store = store or ensure_store()
    active_item = active_subscription(store)

    return {
        "subscription_url": active_item["url"] if active_item else current_subscription_url(),
        "service_status": current_service_state(),
        "ui_url": f"{base_url}:9090/ui",
        "subscription_ui_url": f"{base_url}:9090/ui/subscription.html",
        "admin_url": f"{base_url}:9091/",
        "subscriptions": store["subscriptions"],
        "active_id": store.get("active_id", ""),
        "active_subscription": active_item,
    }


def summarize_failure(output: str) -> tuple[str, str]:
    normalized = output.lower()

    if "404" in output and "curl: (22)" in output:
        return (
            "subscription update failed",
            "The remote server returned HTTP 404. The subscription URL may be wrong, expired, or the provider may reject non-Clash/Mihomo clients.",
        )

    if "403" in output and "curl: (22)" in output:
        return (
            "subscription update failed",
            "The remote server returned HTTP 403. The subscription URL may require a new token or authorization.",
        )

    if "timed out" in normalized:
        return (
            "subscription update failed",
            "The remote server did not respond in time. Try again later or verify the subscription URL from another machine.",
        )

    if "could not resolve host" in normalized:
        return (
            "subscription update failed",
            "DNS resolution failed for the subscription host. Check the domain name in the URL.",
        )

    if "unsupported subscription source" in normalized:
        return (
            "subscription update failed",
            "Only http, https, file URLs, or existing local files are supported.",
        )

    return ("subscription update failed", "Check the execution output for the exact download or parse error.")


def upsert_subscription(
    store: dict[str, object],
    sub_id: str,
    name: str,
    url: str,
    activate: bool,
) -> tuple[dict[str, object], dict[str, str]]:
    timestamp = now_iso()
    entry = find_subscription(store, sub_id) if sub_id else None

    if entry is None and sub_id:
        raise ValueError("subscription not found")

    if entry is not None:
        active_id = str(store.get("active_id", "")).strip()
        if entry["id"] == active_id and entry["url"] != url and not activate:
            raise ValueError("editing the active subscription requires 'save and switch'")

        entry["name"] = name
        entry["url"] = url
        entry["updated_at"] = timestamp
        saved_entry = entry
    else:
        saved_entry = {
            "id": uuid4().hex,
            "name": name,
            "url": url,
            "created_at": timestamp,
            "updated_at": timestamp,
        }
        store["subscriptions"].insert(0, saved_entry)

    write_store(store)
    return store, saved_entry


def activate_subscription(
    store: dict[str, object],
    sub_id: str,
    base_url: str,
) -> tuple[int, dict[str, object]]:
    entry = find_subscription(store, sub_id)
    if entry is None:
        return HTTPStatus.NOT_FOUND, {"ok": False, "error": "subscription not found"}

    if not UPDATE_LOCK.acquire(blocking=False):
        return HTTPStatus.CONFLICT, {"ok": False, "error": "another update is in progress"}

    try:
        try:
            result = run_command([str(UPDATE_SCRIPT), entry["url"]], timeout=600)
        except subprocess.TimeoutExpired:
            return HTTPStatus.GATEWAY_TIMEOUT, {"ok": False, "error": "update timed out"}
    finally:
        UPDATE_LOCK.release()

    combined_output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        error, hint = summarize_failure(combined_output)
        latest_store = ensure_store()
        return (
            HTTPStatus.INTERNAL_SERVER_ERROR,
            {
                "ok": False,
                "error": error,
                "error_hint": hint,
                "output": combined_output,
                "saved_subscription": entry,
                **api_payload(base_url, latest_store),
            },
        )

    latest_store = ensure_store()
    latest_store["active_id"] = entry["id"]
    write_store(latest_store)

    return (
        HTTPStatus.OK,
        {
            "ok": True,
            "message": "subscription switched",
            "output": combined_output,
            "saved_subscription": entry,
            **api_payload(base_url, latest_store),
        },
    )


class Handler(BaseHTTPRequestHandler):
    server_version = "MihomoSubscriptionAdmin/2.0"

    def _base_url(self) -> str:
        return build_base_url(self.headers.get("Host", "").strip())

    def end_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Mihomo-Secret")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        super().end_headers()

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.client_address[0]} - {fmt % args}")

    def _write_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            return

    def _write_html(self, html: str) -> None:
        body = html.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            return

    def _write_text(self, status: int, text: str) -> None:
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            return

    def _authorized(self) -> bool:
        supplied = self.headers.get("X-Mihomo-Secret", "").strip()
        secret = current_secret()
        return bool(secret) and supplied == secret

    def _read_json_body(self) -> dict[str, object] | None:
        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length) if length > 0 else b"{}"
        try:
            loaded = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError:
            return None
        return loaded if isinstance(loaded, dict) else None

    def _require_auth(self) -> bool:
        if not self._authorized():
            self._write_json(HTTPStatus.FORBIDDEN, {"ok": False, "error": "invalid secret"})
            return False
        return True

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    def do_GET(self) -> None:
        path = urlsplit(self.path).path

        if path in ("/", "/subscription.html"):
            self._write_html(HTML_FILE.read_text(encoding="utf-8"))
            return

        if path == "/api/health":
            self._write_json(HTTPStatus.OK, {"ok": True})
            return

        if path == "/api/status":
            if not self._require_auth():
                return
            store = ensure_store()
            self._write_json(HTTPStatus.OK, {"ok": True, **api_payload(self._base_url(), store)})
            return

        self._write_text(HTTPStatus.NOT_FOUND, "Not Found")

    def do_POST(self) -> None:
        path = urlsplit(self.path).path
        base_url = self._base_url()

        if path not in {"/api/subscription", "/api/subscriptions", "/api/subscriptions/activate"}:
            self._write_text(HTTPStatus.NOT_FOUND, "Not Found")
            return

        if not self._require_auth():
            return

        payload = self._read_json_body()
        if payload is None:
            self._write_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid json"})
            return

        if path == "/api/subscriptions/activate":
            sub_id = str(payload.get("id", "")).strip()
            if not sub_id:
                self._write_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "subscription id is required"})
                return
            store = ensure_store()
            status, response = activate_subscription(store, sub_id, base_url)
            self._write_json(status, response)
            return

        raw_url = str(payload.get("url", "")).strip()
        if not raw_url:
            self._write_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "subscription url is required"})
            return

        requested_id = str(payload.get("id", "")).strip()
        activate = bool(payload.get("activate", path == "/api/subscription"))
        store = ensure_store()

        if path == "/api/subscription" and not requested_id:
            existing = next((item for item in store["subscriptions"] if item["url"] == raw_url), None)
            if existing is not None:
                requested_id = existing["id"]

        default_index = len(store["subscriptions"]) + 1
        name = str(payload.get("name", "")).strip() or default_name_from_url(raw_url, default_index)

        try:
            store, saved_entry = upsert_subscription(store, requested_id, name, raw_url, activate)
        except ValueError as exc:
            self._write_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": str(exc)})
            return

        if activate:
            status, response = activate_subscription(store, saved_entry["id"], base_url)
            if response.get("ok"):
                response["message"] = "subscription saved and switched"
            response["saved_subscription"] = saved_entry
            self._write_json(status, response)
            return

        latest_store = ensure_store()
        self._write_json(
            HTTPStatus.OK,
            {
                "ok": True,
                "message": "subscription saved",
                "saved_subscription": saved_entry,
                **api_payload(base_url, latest_store),
            },
        )

    def do_DELETE(self) -> None:
        path = urlsplit(self.path).path
        base_url = self._base_url()

        if not path.startswith("/api/subscriptions/"):
            self._write_text(HTTPStatus.NOT_FOUND, "Not Found")
            return

        if not self._require_auth():
            return

        sub_id = unquote(path.rsplit("/", 1)[-1]).strip()
        if not sub_id:
            self._write_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "subscription id is required"})
            return

        store = ensure_store()
        entry = find_subscription(store, sub_id)
        if entry is None:
            self._write_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "subscription not found"})
            return

        if str(store.get("active_id", "")).strip() == sub_id:
            self._write_json(
                HTTPStatus.CONFLICT,
                {
                    "ok": False,
                    "error": "cannot delete the active subscription",
                    "error_hint": "Switch to another subscription first, then delete this one.",
                },
            )
            return

        store["subscriptions"] = [item for item in store["subscriptions"] if item["id"] != sub_id]
        write_store(store)
        latest_store = ensure_store()
        self._write_json(
            HTTPStatus.OK,
            {
                "ok": True,
                "message": "subscription deleted",
                "deleted_subscription": entry,
                **api_payload(base_url, latest_store),
            },
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Mihomo browser-based subscription admin")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=9091)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"subscription admin listening on http://{args.host}:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
