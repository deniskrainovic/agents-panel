#!/usr/bin/env python3
"""Read, validate, or bump the app's release metadata."""
import argparse
import json
from pathlib import Path
import re

VERSION_FILE = Path(__file__).resolve().parent.parent / "version.json"


def version_parts(value):
    if not isinstance(value, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value):
        raise ValueError("Version must be three numbers, for example 1.0.10 (no v prefix).")
    return tuple(map(int, value.split(".")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--set", metavar="VERSION", help="Increase the version and increment the build number.")
    parser.add_argument("--tag", help="Require an exact matching release tag, for example v1.0.10.")
    parser.add_argument("--field", choices=["version", "build"], default="version")
    args = parser.parse_args()
    try:
        data = json.loads(VERSION_FILE.read_text())
        current = version_parts(data["version"])
        if type(data["build"]) is not int or data["build"] < 1:
            raise ValueError("Build number must be a positive integer.")
        if args.set:
            if args.tag:
                raise ValueError("Use --set and --tag separately.")
            if version_parts(args.set) <= current:
                raise ValueError("The new version must be greater than the current version.")
            data = {"version": args.set, "build": data["build"] + 1}
            VERSION_FILE.write_text(json.dumps(data, indent=2) + "\n")
        if args.tag is not None and args.tag != "v" + data["version"]:
            raise ValueError(f"Release tag {args.tag!r} does not match v{data['version']}.")
        print(data[args.field])
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Version error: {error}\n")


if __name__ == "__main__":
    main()
