#!/usr/bin/env python3
"""Validate that a PulseDeck Git tag matches every declared hub version."""

from __future__ import annotations

import argparse
import ast
from pathlib import Path
import re
import sys
import tomllib

TAG_RE = re.compile(r"^v(?P<version>0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _pyproject_version(root: Path) -> str:
    path = root / "hub" / "pyproject.toml"
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    try:
        version = data["project"]["version"]
    except (KeyError, TypeError) as exc:
        raise ValueError(f"missing [project].version in {path}") from exc
    if not isinstance(version, str) or not version.strip():
        raise ValueError(f"invalid [project].version in {path}")
    return version.strip()


def _package_version(root: Path) -> str:
    path = root / "hub" / "src" / "pulsedeck_hub" / "__init__.py"
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(target, ast.Name) and target.id == "__version__" for target in node.targets):
            continue
        if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            value = node.value.value.strip()
            if value:
                return value
    raise ValueError(f"missing string __version__ assignment in {path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="Git tag to validate, for example v0.5.0")
    args = parser.parse_args()

    match = TAG_RE.fullmatch(args.tag)
    if match is None:
        print(f"invalid stable release tag: {args.tag!r}; expected vMAJOR.MINOR.PATCH", file=sys.stderr)
        return 2

    root = _repo_root()
    try:
        pyproject_version = _pyproject_version(root)
        package_version = _package_version(root)
    except (OSError, SyntaxError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f"release version validation failed: {exc}", file=sys.stderr)
        return 2

    tag_version = args.tag[1:]
    declared = {
        "hub/pyproject.toml": pyproject_version,
        "hub/src/pulsedeck_hub/__init__.py": package_version,
    }

    failures = [f"{path}={version}" for path, version in declared.items() if version != tag_version]
    if pyproject_version != package_version:
        failures.append("declared hub versions disagree")

    if failures:
        print(f"release tag {args.tag} does not match PulseDeck version {tag_version}", file=sys.stderr)
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)
        return 1

    print(f"PulseDeck release version OK: {args.tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
