from __future__ import annotations

import os
import shutil
from pathlib import Path

ROOT_DATA_DIR = Path(__file__).parent / "data"
STEAMCMD_DIR = ROOT_DATA_DIR / "steamcmd"


def game_data_dir(game_key: str) -> Path:
    override = os.environ.get("JGD_STATE_DIR")
    base = Path(override).expanduser() if override else Path(
        os.environ.get("XDG_STATE_HOME", "~/.local/state")
    ).expanduser() / "jackify-game-downgrader"
    target = base / game_key
    old_state = ROOT_DATA_DIR / game_key / "state.json"
    new_state = target / "state.json"
    if old_state.is_file() and not new_state.exists():
        target.mkdir(parents=True, exist_ok=True)
        shutil.move(old_state, new_state)
    return target
