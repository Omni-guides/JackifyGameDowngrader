from __future__ import annotations

import re
import stat
from dataclasses import dataclass
from pathlib import Path

from .pe_version import read_file_version

_STEAM_ROOT_CANDIDATES = [
    "~/.local/share/Steam",
    "~/.steam/steam",
    "~/.var/app/com.valvesoftware.Steam/data/Steam",  # Flatpak
    "~/snap/steam/common/.local/share/Steam",  # Snap
]

def _vdf_values(text: str, key: str) -> list[str]:
    return re.findall(rf'"{key}"[ \t]*"((?:\\.|[^"\\])*)"', text)


def _vdf_value(text: str, key: str) -> str | None:
    values = _vdf_values(text, key)
    return values[0] if values else None


@dataclass
class GameInstall:
    game_path: Path
    library_root: Path
    acf_path: Path
    buildid: str | None
    version: str | None
    language: str | None = None


def _dedupe(paths: list[Path]) -> list[Path]:
    seen: set[Path] = set()
    return [p for p in paths if not (p in seen or seen.add(p))]


def _steam_roots() -> list[Path]:
    candidates = (Path(c).expanduser() for c in _STEAM_ROOT_CANDIDATES)
    return _dedupe([p.resolve() for p in candidates if p.is_dir()])


def _library_roots(steam_root: Path) -> list[Path]:
    vdf_path = steam_root / "steamapps" / "libraryfolders.vdf"
    roots = [steam_root]
    if vdf_path.is_file():
        text = vdf_path.read_text(errors="replace")
        roots += [Path(p) for p in _vdf_values(text, "path")]
    return _dedupe(roots)


def find_game(appid: int, main_exe: str) -> GameInstall | None:
    for steam_root in _steam_roots():
        for library_root in _library_roots(steam_root):
            acf_path = library_root / "steamapps" / f"appmanifest_{appid}.acf"
            if not acf_path.is_file():
                continue
            text = acf_path.read_text(errors="replace")
            installdir = _vdf_value(text, "installdir")
            if not installdir:
                continue
            game_path = library_root / "steamapps" / "common" / installdir
            exe_path = game_path / main_exe
            if not exe_path.is_file():
                continue
            return GameInstall(
                game_path=game_path,
                library_root=library_root,
                acf_path=acf_path,
                buildid=_vdf_value(text, "buildid"),
                version=read_file_version(exe_path),
                language=_vdf_value(text, "language"),
            )
    return None


def find_content_catalog(library_root: Path, appid: int, installdir: str) -> Path:
    return (
        library_root
        / "steamapps" / "compatdata" / str(appid) / "pfx"
        / "drive_c" / "users" / "steamuser" / "AppData" / "Local"
        / installdir / "ContentCatalog.txt"
    )


def set_acf_readonly(acf_path: Path) -> int:
    prior_mode = stat.S_IMODE(acf_path.stat().st_mode)
    acf_path.chmod(prior_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
    return prior_mode


def restore_acf_writable(acf_path: Path, prior_mode: int) -> None:
    if acf_path.is_file():
        acf_path.chmod(prior_mode)


def find_userdata_localconfigs() -> list[Path]:
    configs = []
    for steam_root in _steam_roots():
        userdata = steam_root / "userdata"
        if not userdata.is_dir():
            continue
        for user_dir in sorted(userdata.iterdir()):
            candidate = user_dir / "config" / "localconfig.vdf"
            if candidate.is_file():
                configs.append(candidate)
    return _dedupe(configs)


def find_userdata_localconfig() -> Path | None:
    configs = find_userdata_localconfigs()
    return configs[0] if configs else None
