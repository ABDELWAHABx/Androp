#!/usr/bin/env python3
"""Verify locally supplied release files and exercise the packaged app on macOS.

No download, authentication or decryption is performed here. Example:
    python3 mac/Tools/Release/verify-package.py /tmp/package \
        --tag androp-v0.1.0-preview.6 --expected-source "$GITHUB_SHA"
"""

import argparse
import hashlib
import json
import os
import platform
import plistlib
import posixpath
import re
import stat
import subprocess
import tempfile
import unicodedata
import zipfile
from pathlib import Path, PurePosixPath


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def run(arguments, *, cwd=None, capture=False):
    return subprocess.run(arguments, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def verify_checksums(directory, prefix):
    expected_names = {prefix + suffix for suffix in (".zip", ".dmg", "-BUILD.json")}
    manifest = directory / (prefix + "-SHA256SUMS.txt")
    require(manifest.is_file() and not manifest.is_symlink(), "Missing checksum manifest")
    require(manifest.stat().st_size <= 4096, "Oversized checksum manifest")
    checked = set()
    for line in manifest.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](\S+)", line)
        require(match is not None, "Malformed checksum line")
        expected, name = match.groups()
        require(name in expected_names and name not in checked, "Unexpected or duplicate checksum filename")
        path = directory / name
        require(path.is_file() and not path.is_symlink(), "Missing regular release file: " + name)
        require(digest(path) == expected.lower(), "Checksum mismatch: " + name)
        checked.add(name)
    require(checked == expected_names, "Checksum manifest must cover ZIP, DMG and BUILD.json")


def verify_archive(archive, prefix):
    """Validate paths and framework symlinks before allowing ditto to extract."""
    entries = archive.infolist()
    require(len(entries) <= 50000, "Too many archive entries")
    require(sum(entry.file_size for entry in entries) <= 2 * 1024**3, "Archive exceeds the unpacked size limit")
    paths = set()
    folded_paths = set()
    symlinks = {}
    for entry in entries:
        raw = entry.filename.rstrip("/")
        require(raw and "\\" not in raw and "\x00" not in raw and not raw.startswith("/"), "Unsafe ZIP path")
        require(all(part not in ("", ".", "..") for part in raw.split("/")), "Unsafe ZIP path components")
        path = PurePosixPath(raw)
        permitted = path.parts[0] == prefix or (
            path.parts[0] == "__MACOSX" and (len(path.parts) == 1 or path.parts[1] == prefix))
        require(permitted, "Unexpected archive root: " + raw)
        folded = unicodedata.normalize("NFC", raw).casefold()
        require(raw not in paths and folded not in folded_paths, "Duplicate archive path: " + raw)
        paths.add(raw)
        folded_paths.add(folded)
        require(not entry.flag_bits & 1, "Encrypted inner ZIP members are unsupported")
        mode = entry.external_attr >> 16
        kind = stat.S_IFMT(mode)
        require(kind in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), "Special file in ZIP")
        if kind == stat.S_IFLNK:
            require(entry.file_size <= 4096, "Oversized ZIP symlink")
            target = archive.read(entry).decode("utf-8")
            require(target and "\x00" not in target and "\\" not in target, "Invalid symlink target")
            if raw == prefix + "/Applications":
                require(target == "/Applications", "Unexpected Applications shortcut")
            else:
                require(not target.startswith("/"), "Absolute symlink in app archive")
                resolved = posixpath.normpath(posixpath.join(str(path.parent), target))
                require(resolved == prefix or resolved.startswith(prefix + "/"), "Symlink escapes package")
                symlinks[raw] = resolved
    all_symlinks = set(symlinks)
    if prefix + "/Applications" in paths:
        all_symlinks.add(prefix + "/Applications")
    for raw in paths:
        require(not any(str(parent) in all_symlinks for parent in PurePosixPath(raw).parents),
                "ZIP contains files beneath a symlink")
    for original, target in symlinks.items():
        seen = {original}
        for _ in range(40):
            parts = PurePosixPath(target).parts
            redirect = next(("/".join(parts[:index]) for index in range(1, len(parts) + 1)
                             if "/".join(parts[:index]) in all_symlinks), None)
            if redirect is None:
                require(target in paths, "Broken package symlink: " + original)
                break
            require(redirect in symlinks and redirect not in seen, "Cyclic or escaping package symlink")
            seen.add(redirect)
            target = posixpath.normpath(symlinks[redirect] + target[len(redirect):])
        else:
            raise VerificationError("Excessive package symlink depth")
    require(archive.testzip() is None, "ZIP CRC verification failed")


def verify_source(mac_root, commit, expected_source):
    require(re.fullmatch(r"[0-9a-f]{40}", commit or "") is not None, "Invalid metadata source commit")
    require(re.fullmatch(r"[0-9a-fA-F]{40}", expected_source or "") is not None, "Expected source must be a full commit SHA")
    repository = Path(run(["git", "rev-parse", "--show-toplevel"], cwd=mac_root, capture=True).strip())
    head = run(["git", "rev-parse", "HEAD"], cwd=repository, capture=True).strip()
    require(head == expected_source.lower(), "Checkout HEAD does not match expected source")
    prefix = mac_root.relative_to(repository)
    paths = [str(prefix / path) for path in (
        "airsync-mac", "AirSyncWidget", "AirSync.xcodeproj", "AirSync.entitlements",
        "AirSyncWidgetExtension.entitlements", "Tools/ClosedLidHelper", "Tools/Release/build-mac.sh")]
    run(["git", "cat-file", "-e", commit + "^{commit}"], cwd=repository)
    # A documentation-only commit may follow the build; actual compilation inputs must match.
    run(["git", "diff", "--exit-code", commit, head, "--", *paths], cwd=repository)
    run(["git", "diff", "--exit-code", head, "--", *paths], cwd=repository)
    require(not run(["git", "ls-files", "--others", "--exclude-standard", "--", *paths],
                    cwd=repository, capture=True).strip(), "Untracked compilation inputs in checkout")


def verify_bundle(bundle, identity, minimum):
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleIdentifier") == identity, "Unexpected bundle identity")
    require(info.get("CFBundleVersion") == "37" and info.get("CFBundleShortVersionString") == "4.1.5",
            "Unexpected app/widget version")
    require(info.get("LSMinimumSystemVersion") == minimum, "Unexpected minimum macOS version")
    executable = info.get("CFBundleExecutable", "")
    require(isinstance(executable, str) and executable not in ("", ".", "..") and "/" not in executable,
            "Invalid bundle executable name")
    binary = bundle / "Contents/MacOS" / executable
    require(binary.is_file(), "Bundle executable missing")
    require(run(["lipo", "-archs", str(binary)], capture=True).strip() == "arm64", "Unexpected binary architecture")
    run(["codesign", "--verify", "--deep", "--strict", str(bundle)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_directory", type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--expected-source", "--expected-commit", default=os.environ.get("GITHUB_SHA"))
    parser.add_argument("--runtime-major", choices=("15", "26"), default="15")
    args = parser.parse_args()
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", args.tag) is not None, "Invalid release tag")
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "Verification requires an Apple Silicon Mac")
    require(platform.mac_ver()[0].split(".")[0] == args.runtime_major,
            "This runtime verification requires macOS " + args.runtime_major)
    directory = args.package_directory.resolve(strict=True)
    require(directory.is_dir(), "Package directory is not a directory")
    mac_root = Path(__file__).resolve().parents[2]
    prefix = args.tag + "-arm64"
    verify_checksums(directory, prefix)
    metadata_path = directory / (prefix + "-BUILD.json")
    require(metadata_path.stat().st_size <= 32768, "Oversized build metadata")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    require(isinstance(metadata, dict), "Malformed build metadata")
    for key, expected in {"tag": args.tag, "architecture": "arm64", "signing": "ad-hoc",
                          "notarized": False, "appMinimumMacOS": "14.5", "widgetMinimumMacOS": "15.0",
                          "experimentalClosedLidDefault": False}.items():
        require(metadata.get(key) == expected, "Unexpected build metadata field: " + key)
    verify_source(mac_root, metadata.get("commit"), args.expected_source)
    with zipfile.ZipFile(directory / (prefix + ".zip")) as archive:
        verify_archive(archive, prefix)
        require(archive.read(prefix + "/LICENSE") == (mac_root / "LICENSE").read_bytes(), "Upstream license mismatch")
        require(archive.read(prefix + "/README.upstream.md") == (mac_root / "README.upstream.md").read_bytes(),
                "Upstream attribution mismatch")
        require(json.loads(archive.read(prefix + "/BUILD.json")) == metadata, "Embedded build metadata mismatch")
    run(["hdiutil", "verify", str(directory / (prefix + ".dmg"))])
    with tempfile.TemporaryDirectory(prefix="androp-verified-package-") as temporary:
        unpacked = Path(temporary)
        run(["ditto", "-x", "-k", str(directory / (prefix + ".zip")), str(unpacked)])
        app = unpacked / prefix / "androp.app"
        verify_bundle(app, "app.androp.mac", "14.5")
        verify_bundle(app / "Contents/PlugIns/andropWidget.appex", "app.androp.mac.widget", "15.0")
        helper = app / "Contents/Helpers/androp-closed-lid-helper"
        require(helper.is_file(), "Closed-lid helper missing")
        require(run(["lipo", "-archs", str(helper)], capture=True).strip() == "arm64", "Unexpected helper architecture")
        run(["codesign", "--verify", "--strict", str(helper)])
        run(["bash", str(mac_root / "Tests/run-app-lifecycle-tests.sh"), str(app)], cwd=mac_root)
    print("VERIFIED_MAC_METADATA " + json.dumps(metadata, sort_keys=True))
    print("Packaged arm64 app: signatures, source, hashes, encrypted IPv4 pairing and real Pause/Resume passed on macOS " + args.runtime_major + ".")


if __name__ == "__main__":
    try:
        main()
    except (VerificationError, OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        raise SystemExit("Package verification failed: " + str(error)) from error
