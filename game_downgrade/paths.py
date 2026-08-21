"""Shared on-disk locations for this tool's own data (state, the cached
steamcmd install). Kept next to the package itself rather than anywhere in
the user's home directory, so the tool stays self-contained: download,
extract, run, and delete the folder when done. Namespaced by game key so
downgrading Skyrim SE and Fallout 4 don't collide with each other's state.
"""
from __future__ import annotations

from pathlib import Path

ROOT_DATA_DIR = Path(__file__).parent / "data"
STEAMCMD_DIR = ROOT_DATA_DIR / "steamcmd"


def game_data_dir(game_key: str) -> Path:
    return ROOT_DATA_DIR / game_key
