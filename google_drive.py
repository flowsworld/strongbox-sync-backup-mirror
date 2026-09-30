"""Google Drive provider for the upload check, with OAuth access stored in the macOS keychain."""
import base64
from dataclasses import asdict, dataclass, field
from http.client import HTTPException
import json
import re
import subprocess
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from remote import CheckError, RemoteFile

SERVICE = "cloud.diesis.strongbox-sync-backup-mirror.google-drive"
# Drive's alias for My Drive, which has no /folders/ address of its own.
MY_DRIVE = "root"
ACCOUNT = "oauth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/drive.metadata.readonly"
API_URL = "https://www.googleapis.com/drive/v3/"
FILE_FIELDS = "id,name,parents,trashed,size,md5Checksum,sha256Checksum"
# Drive checksum fields in order of preference.
CHECKSUM_FIELDS = (("sha256", "sha256Checksum"), ("md5", "md5Checksum"))


class DriveError(CheckError):
    """Error without HTTP responses, credentials, or request URLs."""


@dataclass(frozen=True)
class Credentials:
    client_id: str
    client_secret: str = field(repr=False)
    refresh_token: str = field(repr=False)

    def __post_init__(self):
        for value in (self.client_id, self.client_secret, self.refresh_token):
            if not isinstance(value, str) or not value or len(value) > 16384 or any(
                    ord(char) < 32 for char in value):
                raise DriveError("Invalid Google credentials.")
            # Requests send the values as UTF-8, which lone surrogates cannot be.
            try:
                value.encode()
            except UnicodeEncodeError:
                raise DriveError("Invalid Google credentials.") from None


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise DriveError("Invalid response from the Drive API.")
    return value


def string_value(value: object) -> str:
    if not isinstance(value, str) or not value or len(value) > 16384:
        raise DriveError("Invalid response from the Drive API.")
    return value


def validate_id(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", value):
        raise DriveError("Invalid Drive folder ID.")
    return value


def _security(arguments, **kwargs):
    try:
        return subprocess.run(["/usr/bin/security", *arguments], capture_output=True,
                              text=True, timeout=20, **kwargs)
    except (OSError, subprocess.TimeoutExpired):
        raise DriveError("macOS keychain not reachable.") from None


def load_credentials() -> Credentials:
    result = _security(["find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"])
    if result.returncode:
        raise DriveError("Google access is missing or the macOS keychain is locked.")
    try:
        raw = base64.b64decode(result.stdout.strip(), validate=True)
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {"client_id", "client_secret", "refresh_token"}:
            raise ValueError
        return Credentials(**value)
    except (ValueError, TypeError, UnicodeError):
        raise DriveError("Invalid Google credentials in the macOS keychain.") from None


def save_credentials(credentials: Credentials) -> None:
    # The base64 value only appears on stdin of the interactive process.
    encoded = base64.b64encode(json.dumps(asdict(credentials)).encode()).decode()
    command = f"add-generic-password -U -s {SERVICE} -a {ACCOUNT} -w {encoded}\n"
    if len(command.encode()) >= 4096:
        raise DriveError("Google credentials are too long for the macOS keychain command.")
    result = _security(["-i"], input=command)
    if result.returncode or load_credentials() != credentials:
        raise DriveError("Could not save Google access in the macOS keychain.")


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise DriveError("Unexpected redirect from the Google API.")


def request_json(url: str, *, data: dict[str, str] | None = None,
                 access_token: str | None = None) -> dict[str, object]:
    """Only use fixed Google endpoints; never forward bearer tokens."""
    if not (url == TOKEN_URL or url.startswith(API_URL)):
        raise DriveError("Disallowed Google API endpoint.")
    headers = {"Accept": "application/json"}
    if access_token is not None:
        access_token = string_value(access_token)
        if any(char.isspace() or ord(char) < 32 for char in access_token):
            raise DriveError("Invalid Google sign-in response.")
        headers["Authorization"] = "Bearer " + access_token
    if data is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    request = Request(url, data=urlencode(data).encode() if data is not None else None,
                      headers=headers)
    try:
        with build_opener(_NoRedirect()).open(request, timeout=20) as response:
            body = response.read(1048577)
            if len(body) > 1048576:
                raise DriveError("Drive API response is too large.")
        return object_value(json.loads(body))
    except HTTPError as error:
        message = {
            400: "Google rejected the request. Check the OAuth setup and folder.",
            401: "Google sign-in expired. Set up the upload check again.",
            403: "Google denied access. Check the permission and the Drive API.",
            404: "Drive file or folder not found.",
            429: "Drive API temporarily overloaded.",
        }.get(error.code, "Drive API temporarily unavailable.")
        if error.code == 400 and url == TOKEN_URL:
            message = "Google sign-in rejected, expired, or revoked. Set up the upload check again."
        error.close()
        raise DriveError(message) from None
    except (URLError, TimeoutError, OSError, HTTPException):
        raise DriveError("Drive API not reachable. Check the network connection.") from None
    except (ValueError, UnicodeError):
        raise DriveError("Invalid response from the Drive API.") from None


class GoogleDrive:
    def __init__(self, credentials: Credentials) -> None:
        self.credentials = credentials
        self._access_token: str | None = None

    def _get(self, path: str, parameters: dict[str, str]) -> dict[str, object]:
        if self._access_token is None:
            token = request_json(TOKEN_URL, data={
                **asdict(self.credentials), "grant_type": "refresh_token"})
            self._access_token = string_value(token.get("access_token"))
        return request_json(API_URL + path + "?" + urlencode(parameters),
                            access_token=self._access_token)

    def account_email(self) -> str:
        user = object_value(self._get("about", {"fields": "user(emailAddress)"}).get("user"))
        email = string_value(user.get("emailAddress"))
        if "@" not in email or any(ord(char) < 32 for char in email):
            raise DriveError("Invalid Google account data.")
        return email

    def get_folder(self, folder_id: str) -> dict[str, object]:
        """Checks the folder. For the MY_DRIVE alias, the result holds the real ID."""
        folder_id = validate_id(folder_id)
        folder = self._get("files/" + folder_id, {
            "fields": "id,name,mimeType,trashed", "supportsAllDrives": "true"})
        validate_id(folder.get("id"))
        if ((folder.get("id") != folder_id and folder_id != MY_DRIVE) or folder.get("trashed") is not False or
                folder.get("mimeType") != "application/vnd.google-apps.folder"):
            raise DriveError("The Drive target is not an available folder.")
        string_value(folder.get("name"))
        return folder

    def find_file(self, folder_id: str, name: str) -> dict[str, object] | None:
        folder_id = validate_id(folder_id)
        if not isinstance(name, str) or not name or len(name) > 1024:
            raise DriveError("Invalid Drive file name.")
        escaped_name = name.replace("\\", "\\\\").replace("'", "\\'")
        parameters = {
            "q": f"'{folder_id}' in parents and name = '{escaped_name}' and trashed = false",
            "fields": f"nextPageToken,incompleteSearch,files({FILE_FIELDS})",
            "spaces": "drive", "pageSize": "100", "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
        }
        match = None
        seen_tokens = set()
        for _ in range(100):
            page = self._get("files", parameters)
            if page.get("incompleteSearch", False) is not False:
                raise DriveError("Drive file search is incomplete.")
            files = page.get("files")
            if not isinstance(files, list):
                raise DriveError("Invalid response from the Drive API.")
            for raw_file in files:
                file = object_value(raw_file)
                validate_id(file.get("id"))
                parents = file.get("parents")
                if (file.get("name") != name or file.get("trashed") is not False or
                        not isinstance(parents, list) or
                        not all(isinstance(parent, str) for parent in parents) or folder_id not in parents):
                    raise DriveError("Drive file does not belong to the selected target.")
                size = file.get("size")
                if not isinstance(size, str) or not re.fullmatch(r"[0-9]{1,20}", size):
                    raise DriveError("Invalid Drive file size.")
                for key, length in (("md5Checksum", 32), ("sha256Checksum", 64)):
                    if key in file:
                        if not isinstance(file[key], str) or not re.fullmatch(
                                f"[0-9a-fA-F]{{{length}}}", file[key]):
                            raise DriveError("Invalid Drive checksum.")
                        file[key] = file[key].lower()
                if match is not None:
                    raise DriveError("Multiple files with the same name in the Drive target folder.")
                match = file
            token = page.get("nextPageToken")
            if token is None:
                return match
            token = string_value(token)
            if token in seen_tokens:
                break
            seen_tokens.add(token)
            parameters["pageToken"] = token
        raise DriveError("Could not complete the Drive file search.")


class DriveFolder:
    """Upload check provider for one Drive folder. Signs in on the first query."""

    def __init__(self, folder_id: str) -> None:
        self.location = validate_id(folder_id)
        self._drive: GoogleDrive | None = None

    def find(self, name: str) -> RemoteFile | None:
        if self._drive is None:
            self._drive = GoogleDrive(load_credentials())
        # Drive lists files under the real folder ID, also for MY_DRIVE.
        folder_id = string_value(self._drive.get_folder(self.location).get("id"))
        file = self._drive.find_file(folder_id, name)
        if file is None:
            return None
        # find_file has already validated these values.
        return RemoteFile(
            id=string_value(file.get("id")),
            size=int(string_value(file.get("size"))),
            checksums={algorithm: string_value(file[key])
                       for algorithm, key in CHECKSUM_FIELDS if key in file},
        )


def provider_from_config(config: dict[str, object]) -> DriveFolder:
    folder_id = config.get("folder_id")
    if not isinstance(folder_id, str) or not folder_id:
        raise DriveError("The Drive target folder is not configured.")
    return DriveFolder(folder_id)
