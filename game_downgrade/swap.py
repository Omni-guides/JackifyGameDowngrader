"""Back up the whole game install as a sibling folder, copy staged depot
content over the real one, and record enough to undo it with the restore
command.
"""
from __future__ import annotations

import json
import shutil
import time
from pathlib import Path


def _content_files(content_dir: Path):
    """Yield (src, rel_path) for every file under content_dir's depot_* trees."""
    for depot_dir in sorted(content_dir.iterdir()):
        if not depot_dir.is_dir():
            continue
        for src in (p for p in depot_dir.rglob("*") if p.is_file()):
            yield src, src.relative_to(depot_dir)


def preview_downgrade(game_path: Path, content_dir: Path) -> tuple[list[str], list[str]]:
    """Report what apply_downgrade would overwrite/add, without changing anything."""
    overwrite, new = [], []
    for _src, rel in _content_files(content_dir):
        (overwrite if (game_path / rel).is_file() else new).append(str(rel))
    return overwrite, new


def backup_path_for(game_path: Path, prior_version: str | None, prior_buildid: str | None) -> Path:
    """Where apply_downgrade would put the full pre-downgrade copy.

    Named by the game's own version (e.g. "1.7.99.0") when it could be read
    from the exe, since that's what people actually mean by a version.
    Steam's internal build id is used here only as a fallback, if reading
    the exe's version failed.
    """
    label = prior_version or (f"build {prior_buildid}" if prior_buildid else "backup")
    candidate = game_path.parent / f"{game_path.name} ({label})"
    n = 2
    while candidate.exists():
        candidate = game_path.parent / f"{game_path.name} ({label}) ({n})"
        n += 1
    return candidate


def apply_downgrade(
    game_path: Path,
    content_dir: Path,
    version: str,
    prior_version: str | None,
    prior_buildid: str | None,
    data_dir: Path,
    prior_update_behavior: str | None = None,
    acf_path: Path | None = None,
    prior_acf_mode: int | None = None,
) -> Path:
    """Copy the whole game folder to a sibling backup, then copy every file
    under content_dir's depot_* trees over game_path. Returns the backup path.
    """
    backup_path = backup_path_for(game_path, prior_version, prior_buildid)
    shutil.copytree(game_path, backup_path)

    for src, rel in _content_files(content_dir):
        dest = game_path / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)

    state = {
        "game_path": str(game_path),
        "backup_path": str(backup_path),
        "version": version,
        "prior_version": prior_version,
        "prior_buildid": prior_buildid,
        "prior_update_behavior": prior_update_behavior,
        "acf_path": str(acf_path) if acf_path else None,
        "prior_acf_mode": prior_acf_mode,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    data_dir.mkdir(parents=True, exist_ok=True)
    _state_path(data_dir).write_text(json.dumps(state, indent=2))
    return backup_path


def _state_path(data_dir: Path) -> Path:
    return data_dir / "state.json"


def load_state(data_dir: Path) -> dict | None:
    path = _state_path(data_dir)
    if not path.is_file():
        return None
    return json.loads(path.read_text())


def restore_from_state(data_dir: Path) -> None:
    state = load_state(data_dir)
    if state is None:
        raise RuntimeError("No downgrade state found; nothing to restore.")

    game_path = Path(state["game_path"])
    backup_path = Path(state["backup_path"])
    if not backup_path.is_dir():
        raise RuntimeError(f"Backup not found at {backup_path}; can't restore.")

    shutil.rmtree(game_path)
    shutil.move(str(backup_path), str(game_path))
    _state_path(data_dir).unlink()
