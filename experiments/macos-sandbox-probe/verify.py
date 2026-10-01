"""Exercises native catalog parsing with generated binary keyed archives, never real databases."""
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
from urllib.parse import quote

PROBE = Path(__file__).resolve().parent
CLI = PROBE / "build/catalog-fixture-cli"
APP = PROBE / "build/StrongboxSandboxProbe.app/Contents/MacOS/StrongboxSandboxProbe"
FIRST = "11111111-1111-1111-1111-111111111111"
SECOND = "22222222-2222-2222-2222-222222222222"


def metadata(entries):
    objects = ["$null"]

    def ref(value):
        objects.append(value)
        return plistlib.UID(len(objects) - 1)

    array_class = ref({"$classname": "NSArray", "$classes": ["NSArray", "NSObject"]})
    database_class = ref({"$classname": "DatabaseMetadata", "$classes": ["DatabaseMetadata", "NSObject"]})
    url_class = ref({"$classname": "NSURL", "$classes": ["NSURL", "NSObject"]})
    references = []
    for identifier, name, nickname, provider in entries:
        uri = f"strongbox-cloud:/{quote(name)}?uuid={identifier}" if provider == 10 else "file:///local.kdbx"
        url = ref({"$class": url_class, "NS.relative": ref(uri), "NS.base": plistlib.UID(0)})
        references.append(ref({"$class": database_class, "uuid": ref(identifier),
                               "nickName": ref(nickname), "fileUrl": url, "storageProvider": provider}))
    root = ref({"$class": array_class, "NS.objects": references})
    return {"databases": plistlib.dumps({"$archiver": "NSKeyedArchiver", "$version": 100000,
                                         "$top": {"root": root}, "$objects": objects}, fmt=plistlib.FMT_BINARY)}


def run(mode, path, expected=0, binary=CLI):
    result = subprocess.run([str(binary), mode, str(path)], capture_output=True, text=True)
    assert result.returncode == expected, (mode, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)


with tempfile.TemporaryDirectory(prefix="strongbox-native-fixtures-") as scratch:
    root = Path(scratch)
    preferences = root / "Library/Preferences/group.strongbox.mac.mcguill.plist"
    preferences.parent.mkdir(parents=True)
    entries = [(FIRST, "My%20Passwords.kdbx", "Privat ü & <Test>", 10),
               (SECOND, "My%20Passwords.kdbx", "Firma", 10),
               ("33333333-3333-3333-3333-333333333333", "Local.kdbx", "Lokal", 0)]

    def write(value):
        preferences.write_bytes(plistlib.dumps(value))

    write(metadata(entries))
    catalog = run("--catalog", preferences)
    assert len(catalog) == 2
    assert catalog[0]["name"] == "My%20Passwords.kdbx", catalog
    assert catalog[0]["displayName"] == "Privat ü & <Test>", catalog
    assert catalog[1]["displayName"] == "Firma", catalog
    print("PASS: multiple Sync databases, distinct nicknames, one-time percent decoding, local excluded")

    for identifier in (FIRST, SECOND):
        folder = root / "backups" / identifier
        folder.mkdir(parents=True)
        (folder / "first.bak").write_bytes(b"artificial encrypted fixture")
    result = run("--inspect-fixture", root)
    assert result["databaseCount"] == 2 and result["readableBackupCount"] == 2, result
    print("PASS: newest encrypted backup read for each selected source")

    newest = root / "backups" / FIRST / "newest-empty.bak"
    newest.touch()
    result = run("--inspect-fixture", root)
    assert result["backupFailures"] == {"emptyBackup": 1}, result
    assert not result["allBackupsReadable"], result
    newest.unlink()
    print("PASS: newest empty backup fails instead of silently choosing older backup")

    (root / "backups" / FIRST / "linked.bak").symlink_to(root / "backups" / SECOND / "first.bak")
    result = run("--inspect-fixture", root)
    assert result["backupFailures"] == {"unsafeBackup": 1}, result
    print("PASS: linked backup rejected")

    write(metadata(entries + [entries[0]]))
    assert run("--catalog", preferences, expected=1)["error"] == "inconsistentIdentifier"
    contradictory = metadata(entries)
    archive = plistlib.loads(contradictory["databases"])
    for index, value in enumerate(archive["$objects"]):
        if isinstance(value, str) and value.startswith("strongbox-cloud:/") and FIRST in value:
            archive["$objects"][index] = value.replace(FIRST, SECOND)
    contradictory["databases"] = plistlib.dumps(archive, fmt=plistlib.FMT_BINARY)
    write(contradictory)
    assert run("--catalog", preferences, expected=1)["error"] == "inconsistentIdentifier"
    write(metadata([(FIRST, "../escape.kdbx", "Unsafe", 10)]))
    assert run("--catalog", preferences, expected=1)["error"] == "invalidDatabase"
    write({"databases": plistlib.dumps({"$objects": []}, fmt=plistlib.FMT_BINARY)})
    assert run("--catalog", preferences, expected=1)["error"] == "invalidMetadata"
    print("PASS: duplicate UUID, contradictory URL UUID, unsafe filename and unknown archive rejected")

# The baseline is inside the checkout, outside the sandbox and any granted source.
sentinel = PROBE / "build/outside-sandbox-sentinel.txt"
sentinel.write_text("artificial fixture, no user data\n")
assert run("--denied", sentinel, binary=APP)["outsideFileDenied"]
print("PASS: signed sandbox process cannot read unselected checkout file")
