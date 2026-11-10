#!/usr/bin/env python3
"""Read and validate the top-level version from a Flutter pubspec."""

import argparse
from pathlib import Path
import re
import sys


_TOP_LEVEL_VERSION = re.compile(r"^version:[ \t]*(.*)$")
_VERSION = re.compile(
    r"(?P<version>"
    r"(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)"
    r"(?:\+(?P<build>[0-9]+))?"
    r")"
)


def parse_pubspec_version(contents: str, require_build: bool = True) -> tuple[str, str]:
    """Return (version, build). With require_build=False a plain major.minor.patch is
    accepted too, and build comes back as an empty string."""
    values = []
    for line in contents.splitlines():
        match = _TOP_LEVEL_VERSION.match(line)
        if match:
            value = re.sub(r"[ \t]+#.*$", "", match.group(1)).strip()
            values.append(value)

    if len(values) != 1:
        raise ValueError(
            f"expected one top-level 'version:' field, found {len(values)}"
        )

    match = _VERSION.fullmatch(values[0])
    if not match or (require_build and match.group("build") is None):
        expected = "major.minor.patch+numeric-build" if require_build else "major.minor.patch[+numeric-build]"
        raise ValueError(
            f"top-level version must use {expected} syntax; got {values[0]!r}"
        )

    return match.group("version"), match.group("build") or ""


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read and validate the top-level pubspec version."
    )
    parser.add_argument(
        "pubspec",
        nargs="?",
        type=Path,
        default=Path("pubspec.yaml"),
        help="path to pubspec.yaml (default: ./pubspec.yaml)",
    )
    parser.add_argument(
        "--build-number",
        action="store_true",
        help="print only the numeric build metadata",
    )
    args = parser.parse_args()

    try:
        contents = args.pubspec.read_text(encoding="utf-8")
        version, build = parse_pubspec_version(contents)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Error: {args.pubspec}: {error}", file=sys.stderr)
        return 1

    print(build if args.build_number else version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
