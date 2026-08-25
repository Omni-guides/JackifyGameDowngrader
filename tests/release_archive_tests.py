import argparse
import stat
import tempfile
import zipfile
from pathlib import Path


def check_archive(path, expected):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        assert all("\\" not in name for name in names), "archive contains Windows path separators"
        for name in expected:
            assert name in names, f"missing {name}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--linux", type=Path, required=True)
    parser.add_argument("--windows", type=Path, required=True)
    args = parser.parse_args()

    check_archive(
        args.linux,
        ["jackify-game-downgrader", "game_downgrade/__init__.py", "game_downgrade/cli.py"],
    )
    check_archive(
        args.windows,
        ["JackifyGameDowngrader.cmd", "JackifyGameDowngrader.ps1"],
    )

    with zipfile.ZipFile(args.linux) as archive:
        launcher = archive.read("jackify-game-downgrader")
        assert launcher.startswith(b"#!/usr/bin/env python3\n")
        assert b"\r" not in launcher
        mode = archive.getinfo("jackify-game-downgrader").external_attr >> 16
        assert stat.S_IMODE(mode) == 0o755, "Linux launcher is not executable"
        with tempfile.TemporaryDirectory() as directory:
            archive.extractall(directory)
            assert (Path(directory) / "game_downgrade" / "cli.py").is_file()

    print("Release archive tests passed.")


if __name__ == "__main__":
    main()
