#!/usr/bin/env python3
"""Confirms the cloud state through the configured provider. Runs under the lock of sync.zsh."""
import argparse
from collections.abc import Callable
from datetime import datetime
import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from remote import CheckError, Provider, RemoteFile

POLL_SECONDS = 900
# Provider name in upload-check.json to module name. Modules are imported only
# when configured and expose provider_from_config(config) -> Provider.
PROVIDERS = {"google-drive": "google_drive"}
# sha256 always identifies the local content; the others serve as fallbacks.
LOCAL_HASHES = {"sha256": hashlib.sha256, "md5": hashlib.md5}


def read_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise CheckError(f"Could not read {path.name}.") from error
    if not isinstance(value, dict):
        raise CheckError(f"{path.name} is invalid.")
    return value


def load_provider(config: dict[str, object]) -> tuple[str, Provider]:
    name = config.get("provider")
    if not isinstance(name, str) or name not in PROVIDERS:
        raise CheckError("The upload check provider is missing or unknown.")
    module = importlib.import_module(PROVIDERS[name])
    factory: Callable[[dict[str, object]], Provider] = module.provider_from_config
    return name, factory(config)


def write_json(path: Path, value: dict) -> None:
    # mkstemp creates the file with 0600. Only a complete file replaces the old one.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=f".{path.stem}-", delete=False) as file:
            temporary = Path(file.name)
            json.dump(value, file, ensure_ascii=False, indent=2)
            file.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def previous_state(path: Path) -> dict:
    if not path.exists():
        return {}
    value = read_json(path)
    status = value.get("status")
    if not isinstance(status, str) or status not in {"confirmed", "pending", "overdue", "error"}:
        raise CheckError("The saved cloud status is invalid.")
    for key in ("pending_seconds", "checked_at", "last_confirmed_at", "previous_mismatch_at"):
        number = value.get(key)
        optional = key in {"last_confirmed_at", "previous_mismatch_at"}
        if not (number is None and optional) and (type(number) is not int or number < 0):
            raise CheckError("The saved cloud status is invalid.")
    for key in ("context", "local_sha256", "message"):
        if not isinstance(value.get(key), str):
            raise CheckError("The saved cloud status is invalid.")
    # Missing in files written before retries existed.
    for key in ("log_pending", "notification_pending"):
        if key in value and type(value[key]) is not bool:
            raise CheckError("The saved cloud status is invalid.")
    return value


def checksums(target: Path) -> tuple[dict[str, str], os.stat_result]:
    """Hashes the file with every supported algorithm in one read pass.

    This runs before the provider query, so an API error can still keep the
    pending timer of unchanged content, which requires local_sha256.
    """
    before = target.stat()
    hashes = {algorithm: new() for algorithm, new in LOCAL_HASHES.items()}
    with target.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            for digest in hashes.values():
                digest.update(chunk)
    ensure_unchanged(target, before)
    return {algorithm: digest.hexdigest() for algorithm, digest in hashes.items()}, before


def ensure_unchanged(target: Path, before: os.stat_result) -> None:
    after = target.stat()
    if (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
    ):
        raise CheckError("The local copy changed during the cloud check.")


def matches(remote: RemoteFile, local: dict[str, str], size: int) -> bool:
    """Compares with the provider's preferred checksum that is supported locally."""
    algorithm = next((name for name in remote.checksums if name in LOCAL_HASHES), None)
    if algorithm is None:
        raise CheckError("The provider returns no supported checksum for the target file.")
    return remote.size == size and remote.checksums[algorithm] == local[algorithm]


def next_state(previous: dict, context: str, local: dict[str, str], now: int,
               remote: RemoteFile | None, size: int, warning_seconds: int) -> dict:
    """Only time between successful queries counts toward the upload warning."""
    sha256 = local["sha256"]
    same_content = previous.get("context") == context and previous.get("local_sha256") == sha256
    state = {
        "context": context, "local_sha256": sha256, "checked_at": now,
        "last_confirmed_at": previous.get("last_confirmed_at") if same_content else None,
        "pending_seconds": 0, "previous_mismatch_at": None,
    }
    matching = False
    if remote is not None:
        matching = matches(remote, local, size)
        state["remote_file_id"] = remote.id
    if matching:
        state.update(status="confirmed", message="Upload confirmed, cloud checksum matches.",
                     last_confirmed_at=now)
        return state
    pending = previous.get("pending_seconds", 0) if same_content else 0
    last_mismatch = previous.get("previous_mismatch_at") if same_content else None
    if last_mismatch is not None:
        # Do not count long sleep or missed runs as online time.
        pending += min(POLL_SECONDS, max(0, now - last_mismatch))
    overdue = pending >= warning_seconds
    state.update(status="overdue" if overdue else "pending", pending_seconds=pending,
                 previous_mismatch_at=now,
                 message="Upload overdue, cloud state does not match yet." if overdue
                 else "Upload pending, cloud state does not match yet.")
    return state


def report(state_dir: Path, previous: dict, state: dict, notify: bool) -> None:
    """Saves the result, then logs a change and notifies about a new problem.

    log_pending and notification_pending mark a log entry or notification that
    failed. The next run with the same result retries it; delivered ones stay
    deduplicated.
    """
    path = state_dir / "cloud-status.json"
    state["log_pending"] = previous.get("log_pending") is True or (
        previous.get("status"), previous.get("message"), previous.get("local_sha256")
    ) != (state["status"], state["message"], state["local_sha256"])
    # New content must not report the same API error again.
    new_problem = previous.get("notification_pending") is True or (
        previous.get("status"), previous.get("message")
    ) != (state["status"], state["message"])
    state["notification_pending"] = notify and new_problem and state["status"] in {"error", "overdue"}
    # The result must be current even if logging or the notification fails.
    write_json(path, state)
    if not (state["log_pending"] or state["notification_pending"]):
        return
    failure: Exception | None = None
    if state["log_pending"]:
        print(state["message"])
        timestamp = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S")
        try:
            with (state_dir / "sync.log").open("a") as file:
                file.write(f"{timestamp} CLOUD: {state['message']}\n")
            state["log_pending"] = False
        except OSError as error:
            failure = error
    if state["notification_pending"]:
        try:
            result = subprocess.run([
                "/usr/bin/osascript", "-", state["message"],
            ], input='on run argv\ndisplay notification (item 1 of argv) with title "Strongbox upload"\nend run\n',
                capture_output=True, text=True, timeout=15)
            if result.returncode:
                raise CheckError("Could not show the cloud error notification.")
            state["notification_pending"] = False
        except (CheckError, OSError, subprocess.TimeoutExpired) as error:
            failure = failure or error
    write_json(path, state)
    if failure is not None:
        raise failure


def check(target: Path, state_dir: Path, name: str, warning_seconds: int, notify: bool,
          now: int | None = None) -> int:
    now = int(time.time()) if now is None else now
    try:
        previous = previous_state(state_dir / "cloud-status.json")
    except CheckError as error:
        # Report once and replace it, instead of failing silently on every
        # later run. The next run checks normally, without the old waiting time.
        report(state_dir, {}, {
            "context": "", "local_sha256": "", "checked_at": now, "last_confirmed_at": None,
            "pending_seconds": 0, "previous_mismatch_at": None, "status": "error",
            "message": f"{error} It was reset.",
        }, notify)
        return 1
    context = ""
    sha256 = ""
    try:
        provider_name, provider = load_provider(read_json(state_dir / "upload-check.json"))
        context = f"{provider_name}:{provider.location}/{name}"
        local, before = checksums(target)
        sha256 = local["sha256"]
        remote = provider.find(name)
        ensure_unchanged(target, before)
        state = next_state(previous, context, local, now, remote, before.st_size, warning_seconds)
    except (CheckError, OSError) as error:
        same_content = previous.get("context") == context and previous.get("local_sha256") == sha256
        state = {
            "context": context, "local_sha256": sha256, "checked_at": now,
            "last_confirmed_at": previous.get("last_confirmed_at") if same_content else None,
            "pending_seconds": previous.get("pending_seconds", 0) if same_content else 0,
            "previous_mismatch_at": None, "status": "error",
            "message": str(error) if isinstance(error, CheckError)
            else "Could not read the local file for the cloud check.",
        }
    report(state_dir, previous, state, notify)
    return 1 if state["status"] in {"error", "overdue"} else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--warning-seconds", type=int, default=1800)
    parser.add_argument("--notify", choices=("0", "1"), default="1")
    args = parser.parse_args()
    if args.warning_seconds <= 0:
        parser.error("--warning-seconds must be positive")
    try:
        return check(args.target, args.state_dir, args.name, args.warning_seconds, args.notify == "1")
    except (CheckError, OSError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, CheckError)
              else "Could not save or report the cloud status.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
