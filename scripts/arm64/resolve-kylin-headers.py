#!/usr/bin/env python3
"""Resolve exact Kylin header packages without relying on directory listings.

Bootstrap a vendor keyring through vendor HTTPS, or use an independently
trusted public keyring supplied by the maintainer. Every header package
must then be authenticated through a verified Release and Packages hash.
No unsigned repository or generic Ubuntu header fallback is permitted.
"""
import argparse
import bz2
import gzip
import hashlib
import lzma
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from functools import cmp_to_key
from urllib.parse import quote

ARCHIVE = "https://archive.kylinos.cn/kylin/KYLIN-ALL"
# The signed 2303 update index yielded the required ARM64 header pair in CI.
# Try it first, but retain all official historical fallbacks.
SUITES = ("10.1-2303-updates", "10.1", "10.1-2107-updates",
          "10.1-2203-updates", "10.0", "10.1-2209-updates")
COMMON = "linux-headers-5.4.18-53"
FLAVOR = COMMON + "-generic"
REVISION = re.compile(r"^5\.4\.18-53(?:\.[0-9]+[A-Za-z0-9.+~:-]*)?$")
HEX256 = re.compile(r"^[0-9a-fA-F]{64}$")


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, **kwargs)


def log(message):
    print(message, flush=True)


def safe_path(value):
    p = PurePosixPath(value)
    return (
        value and not p.is_absolute() and ".." not in p.parts and
        all(re.fullmatch(r"[A-Za-z0-9._+~:-]+", x) for x in p.parts)
    )


def fetch(url, path):
    log("GET " + url)
    path.unlink(missing_ok=True)
    result = subprocess.run([
        "curl", "--proto", "=https", "--proto-redir", "=https",
        "--location", "--fail", "--silent", "--show-error",
        "--connect-timeout", "12", "--max-time", "60", "--retry", "1",
        "--retry-delay", "1", "--output", str(path), url,
    ])
    if result.returncode:
        path.unlink(missing_ok=True)
        return False
    return True


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def verify(path, sha, size=None):
    if not HEX256.fullmatch(sha):
        raise ValueError("Invalid SHA256 in metadata")
    if size is not None and path.stat().st_size != int(size):
        raise ValueError("Size mismatch: " + str(path))
    if digest(path).lower() != sha.lower():
        raise ValueError("SHA256 mismatch: " + str(path))


def control_records(raw):
    # Debian control format. Continuation lines cannot redefine fields.
    text = raw.decode("utf-8", errors="replace")
    for stanza in re.split(r"\n\s*\n", text):
        fields = {}
        for line in stanza.splitlines():
            if line.startswith((" ", "\t")) or ": " not in line:
                continue
            k, v = line.split(": ", 1)
            fields[k] = v.strip()
        if fields.get("Package"):
            yield fields


def read_index(path, suffix):
    data = path.read_bytes()
    if suffix.endswith(".xz"):
        return lzma.decompress(data)
    if suffix.endswith(".gz"):
        return gzip.decompress(data)
    if suffix.endswith(".bz2"):
        return bz2.decompress(data)
    return data


def release_hashes(raw):
    hashes = {}
    active = False
    for line in raw.decode("utf-8", errors="replace").splitlines():
        if line == "SHA256:":
            active = True
            continue
        if active and not line.startswith((" ", "\t")):
            break
        if active:
            fields = line.split()
            if len(fields) == 3 and HEX256.fullmatch(fields[0]) and safe_path(fields[2]):
                hashes[fields[2]] = (fields[0], int(fields[1]))
    if not hashes:
        raise ValueError("Release has no SHA256 section")
    return hashes


def version_compare(a, b):
    if a == b:
        return 0
    return -1 if subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0 else 1


def package_record(record, name, arch):
    filename = record.get("Filename", "")
    return (
        record.get("Package") == name and record.get("Architecture") in arch
        and safe_path(filename) and filename.startswith("pool/")
        and filename.endswith(".deb")
        and HEX256.fullmatch(record.get("SHA256", "")) is not None
        and record.get("Size", "").isdigit()
    )


def get_package(record, path):
    url = ARCHIVE + "/" + quote(record["Filename"], safe="/._+-~:")
    if not fetch(url, path):
        raise ValueError("Package download unavailable: " + record["Filename"])
    verify(path, record["SHA256"], record["Size"])
    for field in ("Package", "Version", "Architecture"):
        actual = subprocess.check_output(["dpkg-deb", "-f", str(path), field], text=True).strip()
        if actual != record[field]:
            raise ValueError("Package metadata mismatch: " + field)


def get_index(suite, work, hashes=None, arch="arm64"):
    prefix = "main/binary-" + arch + "/Packages"
    # Prefer compressed indexes; optionally use the signed by-hash location.
    for suffix in (".xz", ".gz", ".bz2", ""):
        name = prefix + suffix
        if hashes is not None and name not in hashes:
            continue
        path = work / ("Packages-" + suite + "-" + arch + suffix)
        if hashes is not None:
            sha, size = hashes[name]
            byhash = name.rsplit("/", 1)[0] + "/by-hash/SHA256/" + sha
            urls = [byhash, name]
        else:
            urls = [name]
        for rel in urls:
            if not fetch(ARCHIVE + "/dists/" + suite + "/" + rel, path):
                continue
            try:
                if hashes is not None:
                    verify(path, sha, size)
                records = list(control_records(read_index(path, suffix)))
                if not records:
                    raise ValueError("Empty package index")
                log("Parsed {} {} package entries from {}".format(len(records), arch, suite))
                return records
            except (OSError, EOFError, ValueError, lzma.LZMAError) as exc:
                log("Rejected package index: " + str(exc))
    raise ValueError("No usable {} index for {}".format(arch, suite))


def bootstrap(work, suites):
    gpg_home = work / "gnupg"
    gpg_home.mkdir(mode=0o700)
    def import_key(path):
        run(["gpg", "--batch", "--homedir", str(gpg_home), "--import", str(path)])
    supplied = os.getenv("KYLIN_PUBLIC_KEYRING_FILE", "")
    encoded = os.getenv("KYLIN_PUBLIC_KEYRING_BASE64", "")
    if supplied or encoded:
        if supplied and encoded:
            raise ValueError("Choose one supplied public keyring source")
        if encoded:
            import base64
            path = work / "supplied-keyring"
            path.write_bytes(base64.b64decode(encoded, validate=True))
        else:
            path = Path(supplied)
        log("Using maintainer-supplied trusted public keyring")
        import_key(path)
    else:
        pinned = os.getenv("KYLIN_KEYRING_SHA256", "")
        if pinned and not HEX256.fullmatch(pinned):
            raise ValueError("Invalid KYLIN_KEYRING_SHA256")
        # The official archive's authenticated HTTPS endpoint is the bootstrap
        # trust anchor only. Signed Release verification follows before any
        # kernel header download is accepted.
        for suite in suites:
            try:
                log("Discovering vendor keyring via official HTTPS index: " + suite)
                records = get_index(suite, work)
                candidates = [r for r in records if package_record(
                    r, "kylin-keyring", ("all", "arm64"))]
                if not candidates:
                    log("No kylin-keyring package in " + suite)
                    continue
                candidates.sort(key=cmp_to_key(
                    lambda a,b: version_compare(a["Version"], b["Version"])), reverse=True)
                for rec in candidates:
                    if pinned and rec["SHA256"].lower() != pinned.lower():
                        continue
                    deb = work / "keyring.deb"
                    get_package(rec, deb)
                    extracted = work / "keyring-files"
                    run(["dpkg-deb", "-x", str(deb), str(extracted)])
                    paths = [p for p in extracted.rglob("*")
                             if p.is_file() and not p.is_symlink()
                             and p.suffix in (".gpg", ".asc")
                             and ("keyrings" in p.parts or "trusted.gpg.d" in p.parts)
                             and not any(x in p.name.lower() for x in ("removed", "revoked", "obsolete"))]
                    legacy = extracted / "etc/apt/trusted.gpg"
                    if legacy.is_file():
                        paths.append(legacy)
                    if not paths:
                        raise ValueError("Vendor keyring package has no usable public key files")
                    for p in paths:
                        import_key(p)
                    log("Vendor keyring revision: {} SHA256 {}".format(rec["Version"], rec["SHA256"]))
                    break
                else:
                    continue
                break
            except (OSError, ValueError, subprocess.CalledProcessError) as exc:
                log("Keyring discovery unavailable: " + str(exc))
        else:
            raise ValueError("Official keyring unavailable. Supply a trusted vendor public keyring "
                             "from the official installation medium or an authorized Kylin machine.")
    run(["gpg", "--batch", "--homedir", str(gpg_home), "--fingerprint"])
    out = work / "trusted-kylin.gpg"
    with out.open("wb") as stream:
        run(["gpg", "--batch", "--homedir", str(gpg_home), "--export"], stdout=stream)
    if not out.stat().st_size:
        raise ValueError("No public keys exported")
    return out


def verified_release(suite, work, keyring):
    signed = work / (suite + ".InRelease")
    release = work / (suite + ".Release")
    signature = work / (suite + ".Release.gpg")
    base = ARCHIVE + "/dists/" + suite + "/"
    if fetch(base + "InRelease", signed):
        run(["gpgv", "--keyring", str(keyring), "--output", str(release), str(signed)])
    else:
        if not fetch(base + "Release", release) or not fetch(base + "Release.gpg", signature):
            raise ValueError("Official signed Release unavailable: " + suite)
        run(["gpgv", "--keyring", str(keyring), str(signature), str(release)])
    return release_hashes(release.read_bytes())


def self_test():
    sha = "a" * 64
    raw = ("Package: " + FLAVOR + "\nVersion: 5.4.18-53.42\nArchitecture: arm64\n"
           "Filename: pool/main/l/linux/header.deb\nSHA256: " + sha + "\nSize: 7\n\n").encode()
    rec = list(control_records(raw))[0]
    assert package_record(rec, FLAVOR, ("arm64",))
    assert not package_record(rec, FLAVOR, ("all",))
    assert not package_record(dict(rec, Filename="../header.deb"), FLAVOR, ("arm64",))
    assert not package_record(dict(rec, Filename="https://other.test/header.deb"), FLAVOR, ("arm64",))
    assert not package_record(dict(rec, SHA256="bad"), FLAVOR, ("arm64",))
    assert REVISION.fullmatch("5.4.18-53.42")
    assert not REVISION.fullmatch("5.4.0-216")
    assert release_hashes(("SHA256:\n " + sha + " 7 main/binary-arm64/Packages.xz\n").encode()) == {
        "main/binary-arm64/Packages.xz": (sha, 7)}
    assert version_compare("5.4.18-53.9", "5.4.18-53.42") < 0
    log("Kylin package resolver self-tests passed")


def resolve(work, requested_suite, requested_version):
    if requested_suite == "auto":
        suites = SUITES
    elif requested_suite in SUITES:
        suites = tuple(dict.fromkeys((requested_suite, "10.1", "10.0")))
    else:
        raise ValueError("Unknown Kylin APT suite")
    if requested_version and not REVISION.fullmatch(requested_version):
        raise ValueError("Requested header revision is not 5.4.18-53")
    # Bootstrap using base repositories first, then historical update suites.
    keyring = bootstrap(work, tuple(dict.fromkeys(("10.1", "10.0") + suites)))
    packages = {}
    for suite in suites:
        try:
            hashes = verified_release(suite, work, keyring)
            records = get_index(suite, work, hashes)
            for rec in records:
                name = rec.get("Package")
                if name not in (COMMON, FLAVOR):
                    continue
                archs = ("arm64",) if name == FLAVOR else ("all", "arm64")
                if not package_record(rec, name, archs):
                    continue
                version = rec.get("Version", "")
                if REVISION.fullmatch(version) and (not requested_version or version == requested_version):
                    packages.setdefault((version, name), []).append(rec)
            versions = sorted({v for v, n in packages if (v, COMMON) in packages
                               and (v, FLAVOR) in packages}, key=cmp_to_key(version_compare), reverse=True)
            if not versions:
                log("No authenticated matching header pair yet: " + suite)
                continue
            # Use the first suite that yields a complete matching pair, and
            # the newest matching version within the inspected suites. Log it;
            # it still must match the installed kernel's exact package revision.
            version = versions[0]
            out = work / "headers"
            out.mkdir(exist_ok=True)
            for name in (COMMON, FLAVOR):
                candidates = packages[(version, name)]
                if len({r["SHA256"] for r in candidates}) != 1:
                    raise ValueError("Conflicting signed package hashes for " + name + "=" + version)
                get_package(candidates[0], out / (name + ".deb"))
            (out / "VERSION").write_text(version + "\n", encoding="utf-8")
            log("Authenticated ARM64 header pair: " + version)
            return
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            log("Suite " + suite + " unavailable or rejected: " + str(exc))
    raise ValueError("No exact authenticated ARM64 header pair could be downloaded from official suites. "
                     "Obtain the matching two vendor .deb packages and trusted hashes through an approved channel.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--work", type=Path)
    parser.add_argument("--suite", default="auto")
    parser.add_argument("--version", default="")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        if not args.work:
            parser.error("--work is required")
        args.work.mkdir(parents=True, exist_ok=True)
        resolve(args.work, args.suite, args.version)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print("Kylin header acquisition blocked: " + str(exc), file=sys.stderr)
        sys.exit(1)
