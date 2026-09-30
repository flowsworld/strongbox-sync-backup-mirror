"""Types shared by the upload check core and its providers.

upload_check.py runs as __main__, so a provider that imported it would load a
second copy of the core. Both sides import only this module instead.
"""
from dataclasses import dataclass
from typing import Protocol


class CheckError(Exception):
    """User-facing error without HTTP responses, credentials, or URLs."""


@dataclass(frozen=True)
class RemoteFile:
    id: str
    size: int
    # Algorithm name to lowercase hex digest, in the provider's order of preference.
    checksums: dict[str, str]


class Provider(Protocol):
    @property
    def location(self) -> str:
        """Stable identity of the remote target location, for example a folder ID."""
        ...

    def find(self, name: str) -> RemoteFile | None:
        """Returns None while the file is not uploaded yet.

        Raises CheckError on any problem, including an unavailable target location.
        """
        ...
