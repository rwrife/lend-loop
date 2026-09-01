#!/usr/bin/env python3
"""Create or verify a flat-directory SHA-256 manifest."""

from __future__ import annotations

import hashlib
from pathlib import Path
import sys


MANIFEST_NAME = "SHA256SUMS"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def files(directory: Path) -> list[Path]:
    return sorted(
        (
            path
            for path in directory.iterdir()
            if path.is_file() and path.name != MANIFEST_NAME
        ),
        key=lambda path: path.name,
    )


def create(directory: Path) -> None:
    manifest = directory / MANIFEST_NAME
    entries = files(directory)
    if not entries:
        raise SystemExit(f"no files available to hash in {directory}")
    lines = [f"{digest(path)}  {path.name}\n" for path in entries]
    manifest.write_text("".join(lines), encoding="utf-8")
    print(f"created {manifest} with {len(entries)} entries")


def verify(directory: Path) -> None:
    manifest = directory / MANIFEST_NAME
    if not manifest.is_file():
        raise SystemExit(f"missing manifest: {manifest}")

    seen: set[str] = set()
    for number, raw_line in enumerate(
        manifest.read_text(encoding="utf-8").splitlines(), start=1
    ):
        try:
            expected, name = raw_line.split("  ", maxsplit=1)
        except ValueError as error:
            raise SystemExit(f"invalid manifest line {number}") from error
        if (
            len(expected) != 64
            or any(character not in "0123456789abcdef" for character in expected)
            or not name
            or name == MANIFEST_NAME
            or Path(name).name != name
            or name in seen
        ):
            raise SystemExit(f"invalid manifest line {number}")
        path = directory / name
        if not path.is_file():
            raise SystemExit(f"missing artifact: {name}")
        actual = digest(path)
        if actual != expected:
            raise SystemExit(f"checksum mismatch: {name}")
        seen.add(name)
        print(f"{name}: OK")

    current = {path.name for path in files(directory)}
    if seen != current:
        omitted = sorted(current - seen)
        unexpected = sorted(seen - current)
        raise SystemExit(
            f"manifest/file set mismatch; omitted={omitted}, unexpected={unexpected}"
        )
    print(f"verified {len(seen)} SHA-256 entries")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in {"create", "verify"}:
        raise SystemExit(f"usage: {sys.argv[0]} create|verify DIRECTORY")
    directory = Path(sys.argv[2]).resolve()
    if not directory.is_dir():
        raise SystemExit(f"not a directory: {directory}")
    if sys.argv[1] == "create":
        create(directory)
    else:
        verify(directory)


if __name__ == "__main__":
    main()
