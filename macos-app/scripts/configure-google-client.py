#!/usr/bin/env python3
"""Embed only explicit native Desktop client configuration in a build candidate."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import stat


def read_configuration(path: Path) -> dict[str, str]:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 65_536:
            raise ValueError("The native client configuration must be a small regular file.")
        with os.fdopen(descriptor, "r", encoding="utf-8", closefd=False) as stream:
            contents = stream.read(65_537)
    finally:
        os.close(descriptor)
    values: dict[str, str] = {}
    allowed = {"GOOGLE_DRIVE_NATIVE_PROJECT_ID", "GOOGLE_DRIVE_NATIVE_CLIENT_ID", "GOOGLE_DRIVE_NATIVE_CLIENT_SECRET"}
    for line in contents.splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in allowed or key in values:
            raise ValueError("Invalid native client configuration key.")
        values[key] = value
    client_id = values.get("GOOGLE_DRIVE_NATIVE_CLIENT_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client_id) or len(client_id) > 16_384:
        raise ValueError("A valid native Desktop client ID is required.")
    secret = values.get("GOOGLE_DRIVE_NATIVE_CLIENT_SECRET", "")
    if secret and (not re.fullmatch(r"[A-Za-z0-9_-]+", secret) or len(secret) > 16_384):
        raise ValueError("Invalid Desktop client configuration.")
    project = values.get("GOOGLE_DRIVE_NATIVE_PROJECT_ID", "")
    if project and not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", project):
        raise ValueError("Invalid native project ID.")
    return values


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("configuration", type=Path)
    parser.add_argument("info_plist", type=Path)
    arguments = parser.parse_args()
    try:
        values = read_configuration(arguments.configuration)
        with arguments.info_plist.open("rb") as stream:
            info = plistlib.load(stream)
        if not isinstance(info, dict):
            raise ValueError("The candidate Info.plist must be a dictionary.")
        info["GoogleDriveOAuthClientID"] = values["GOOGLE_DRIVE_NATIVE_CLIENT_ID"]
        secret = values.get("GOOGLE_DRIVE_NATIVE_CLIENT_SECRET", "")
        if secret:
            info["GoogleDriveOAuthClientSecret"] = secret
        else:
            info.pop("GoogleDriveOAuthClientSecret", None)
        with arguments.info_plist.open("wb") as stream:
            plistlib.dump(info, stream)
    except (OSError, UnicodeError, ValueError, plistlib.InvalidFileException):
        parser.exit(2, "The native Google Desktop client configuration could not be applied.\n")


if __name__ == "__main__":
    main()
