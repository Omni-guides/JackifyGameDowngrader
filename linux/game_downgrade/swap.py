from __future__ import annotations

import json
import shutil
import time
from pathlib import Path

BACKUP_STATE = ".jackify-game-downgrader.json"


def _content_files(content_dir: Path):
    for depot_dir in sorted(content_dir.iterdir()):
        if not depot_dir.is_dir():
            continue
        for src in (p for p in depot_dir.rglob("*") if p.is_file()):
            yield src, src.relative_to(depot_dir)


def preview_downgrade(game_path: Path, content_dir: Path) -> tuple[list[str], list[str]]:
    overwrite, new = [], []
    for _src, rel in _content_files(content_dir):
        (overwrite if (game_path / rel).is_file() else new).append(str(rel))
    return overwrite, new


def backup_path_for(game_path: Path, prior_version: str | None, prior_buildid: str | None) -> Path:
    label = prior_version or (f"build {prior_buildid}" if prior_buildid else "backup")
    candidate = game_path.parent / f"{game_path.name} ({label})"
    n = 2
    while candidate.exists():
        candidate = game_path.parent / f"{game_path.name} ({label}) ({n})"
        n += 1
    return candidate


def reset_game_from_backup(game_path: Path, backup_path: Path) -> None:
    if not backup_path.is_dir():
        raise RuntimeError(f"Backup not found at {backup_path}.")
    shutil.rmtree(game_path)
    try:
        shutil.copytree(backup_path, game_path)
        marker = game_path / BACKUP_STATE
        if marker.is_file():
            marker.unlink()
    except BaseException:
        raise RuntimeError(
            f"Reset failed. The original backup remains intact at {backup_path}."
        )


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
    create_backup: bool = True,
    existing_state: dict | None = None,
    localconfigs: list[dict] | None = None,
) -> Path | None:
    if existing_state is not None:
        state = dict(existing_state)
        backup_path = Path(state["backup_path"]) if state.get("backup_path") else None
        state["version"] = version
        state["timestamp"] = time.strftime("%Y-%m-%d %H:%M:%S")
    else:
        backup_path = backup_path_for(game_path, prior_version, prior_buildid) if create_backup else None
        if backup_path is not None:
            shutil.copytree(game_path, backup_path)
        state = {
            "game_path": str(game_path),
            "backup_path": str(backup_path) if backup_path else None,
            "version": version,
            "prior_version": prior_version,
            "prior_buildid": prior_buildid,
            "prior_update_behavior": prior_update_behavior,
            "acf_path": str(acf_path) if acf_path else None,
            "prior_acf_mode": prior_acf_mode,
            "localconfigs": localconfigs or [],
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
    save_state(data_dir, state)
    if backup_path is not None:
        (backup_path / BACKUP_STATE).write_text(json.dumps(state, indent=2))

    for src, rel in _content_files(content_dir):
        dest = game_path / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)

    return backup_path


def clear_state(data_dir: Path) -> None:
    path = _state_path(data_dir)
    if path.is_file():
        path.unlink()


def save_state(data_dir: Path, state: dict) -> None:
    data_dir.mkdir(parents=True, exist_ok=True)
    _state_path(data_dir).write_text(json.dumps(state, indent=2))


def _state_path(data_dir: Path) -> Path:
    return data_dir / "state.json"


def load_state(data_dir: Path) -> dict | None:
    path = _state_path(data_dir)
    if not path.is_file():
        return None
    return json.loads(path.read_text())


def load_backup_state(backup_path: Path) -> dict | None:
    path = backup_path / BACKUP_STATE
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


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
    marker = game_path / BACKUP_STATE
    if marker.is_file():
        marker.unlink()
    _state_path(data_dir).unlink()
