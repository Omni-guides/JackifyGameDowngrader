from __future__ import annotations

from pathlib import Path

ROOT_DATA_DIR = Path(__file__).parent / "data"
STEAMCMD_DIR = ROOT_DATA_DIR / "steamcmd"


def game_data_dir(game_key: str) -> Path:
    return ROOT_DATA_DIR / game_key
