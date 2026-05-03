#!/usr/bin/env python3
import argparse
import bz2
import gzip
import hashlib
import io
import os
import shutil
import tarfile
from datetime import datetime, timezone
from pathlib import Path


def read_ar_members(path):
    data = Path(path).read_bytes()
    if data[:8] != b"!<arch>\n":
        raise ValueError(f"{path} is not an ar archive")
    off = 8
    members = {}
    while off + 60 <= len(data):
        header = data[off:off + 60]
        off += 60
        name = header[:16].decode("utf-8", "replace").strip()
        size = int(header[48:58].decode("ascii").strip())
        body = data[off:off + size]
        off += size + (size % 2)
        members[name.rstrip("/")] = body
    return members


def control_from_deb(path):
    members = read_ar_members(path)
    control_name = next((n for n in members if n.startswith("control.tar")), None)
    if not control_name:
        raise ValueError(f"{path} has no control.tar member")

    mode = "r:*"
    with tarfile.open(fileobj=io.BytesIO(members[control_name]), mode=mode) as tar:
        for member in tar.getmembers():
            normalized = member.name.lstrip("./")
            if normalized == "control":
                f = tar.extractfile(member)
                if f is None:
                    break
                return f.read().decode("utf-8")
    raise ValueError(f"{path} has no DEBIAN/control file")


def digest(path, algorithm):
    h = hashlib.new(algorithm)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def package_entry(repo_root, deb_path):
    rel = deb_path.relative_to(repo_root).as_posix()
    control = control_from_deb(deb_path).rstrip()
    size = deb_path.stat().st_size
    return (
        f"{control}\n"
        f"Filename: {rel}\n"
        f"Size: {size}\n"
        f"MD5sum: {digest(deb_path, 'md5')}\n"
        f"SHA1: {digest(deb_path, 'sha1')}\n"
        f"SHA256: {digest(deb_path, 'sha256')}\n"
    )


def write_release(repo_root, packages_bytes):
    now = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S %z")
    package_files = [
        ("Packages", repo_root / "Packages"),
        ("Packages.gz", repo_root / "Packages.gz"),
        ("Packages.bz2", repo_root / "Packages.bz2"),
    ]
    lines = [
        "Origin: Showcase",
        "Label: Showcase",
        "Suite: stable",
        "Codename: ios12-rootful",
        "Version: 1.0",
        "Architectures: iphoneos-arm",
        "Components: main",
        f"Date: {now}",
        "Description: Showcase jailbreak package repository",
        "MD5Sum:",
    ]
    for name, path in package_files:
        lines.append(f" {digest(path, 'md5')} {path.stat().st_size} {name}")
    lines.append("SHA1:")
    for name, path in package_files:
        lines.append(f" {digest(path, 'sha1')} {path.stat().st_size} {name}")
    lines.append("SHA256:")
    for name, path in package_files:
        lines.append(f" {digest(path, 'sha256')} {path.stat().st_size} {name}")
    (repo_root / "Release").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Generate a small jailbreak APT repository index.")
    parser.add_argument("repo", nargs="?", default="repo", help="Repository root containing debs/")
    args = parser.parse_args()

    repo_root = Path(args.repo).resolve()
    debs = sorted((repo_root / "debs").glob("*.deb"))
    if not debs:
        raise SystemExit(f"No .deb files found in {repo_root / 'debs'}")

    entries = [package_entry(repo_root, deb) for deb in debs]
    packages = "\n".join(entries).encode("utf-8")

    (repo_root / "Packages").write_bytes(packages)
    with gzip.open(repo_root / "Packages.gz", "wb", compresslevel=9) as f:
        f.write(packages)
    with bz2.open(repo_root / "Packages.bz2", "wb", compresslevel=9) as f:
        f.write(packages)

    source_depictions = Path(__file__).resolve().parents[1] / "depictions"
    if source_depictions.is_dir():
        target_depictions = repo_root / "depictions"
        if target_depictions.exists():
            shutil.rmtree(target_depictions)
        shutil.copytree(source_depictions, target_depictions)

    write_release(repo_root, packages)
    print(f"Wrote Packages, Packages.gz, Packages.bz2, and Release for {len(debs)} deb(s).")


if __name__ == "__main__":
    main()
