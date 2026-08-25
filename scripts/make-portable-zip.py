#!/usr/bin/env python3
import argparse
import stat
import zipfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--executable", action="append", default=[])
    args = parser.parse_args()

    executable = set(args.executable)
    with zipfile.ZipFile(args.destination, "w") as archive:
        for path in sorted(args.source.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(args.source).as_posix()
            info = zipfile.ZipInfo(relative, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if relative in executable else 0o644
            info.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(info, path.read_bytes())


if __name__ == "__main__":
    main()
