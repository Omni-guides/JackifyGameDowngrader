from __future__ import annotations

import json
import shutil
import tempfile
import time
from pathlib import Path

BACKUP_STATE = ".jackify-game-downgrader.json"


def _content_files(content_dir: Path, depot_ids: list[str] | None = None):
    depot_dirs = (
        (content_dir / f"depot_{depot_id}" for depot_id in depot_ids)
        if depot_ids is not None else sorted(content_dir.iterdir())
    )
    for depot_dir in depot_dirs:
        if not depot_dir.is_dir():
            continue
        for src in (p for p in depot_dir.rglob("*") if p.is_file()):
            yield src, src.relative_to(depot_dir)


def preview_downgrade(game_path: Path, content_dir: Path, depot_ids: list[str] | None = None) -> tuple[list[str], list[str]]:
    overwrite, new = [], []
    for _src, rel in _content_files(content_dir, depot_ids):
        (overwrite if (game_path / rel).is_file() else new).append(str(rel))
    return overwrite, new


def apply_component_downgrade(
    install_path: Path,
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
    depot_ids: list[str] | None = None,
) -> Path | None:
    """Apply a shared-directory component without backing up its parent game."""
    existing_records = (existing_state.get("component_backup") or []) if existing_state else []
    if isinstance(existing_records, dict):
        existing_records = [existing_records]
    backup_path = data_dir / "file-backup" if create_backup or existing_records else None
    state = dict(existing_state) if existing_state else {
        "game_path": str(install_path),
        "backup_path": None,
        "component_backup": [],
        "prior_version": prior_version,
        "prior_buildid": prior_buildid,
        "prior_update_behavior": prior_update_behavior,
        "acf_path": str(acf_path) if acf_path else None,
        "prior_acf_mode": prior_acf_mode,
        "localconfigs": localconfigs or [],
    }
    state["version"] = version
    state["timestamp"] = time.strftime("%Y-%m-%d %H:%M:%S")
    records = list(existing_records)
    recorded = {item["path"] for item in records}
    state["component_backup"] = records
    # Steam protection is applied before this function is called. Persist its
    # prior values before file backup work so a copy failure remains restorable.
    save_state(data_dir, state)

    if backup_path is not None:
        with tempfile.TemporaryDirectory(prefix="file-backup-staging-", dir=data_dir) as staging:
            staging_path = Path(staging)
            for _src, rel in _content_files(content_dir, depot_ids):
                rel_text = str(rel)
                if rel_text in recorded:
                    continue
                current = install_path / rel
                existed = current.is_file()
                records.append({"path": rel_text, "existed": existed})
                recorded.add(rel_text)
                if existed:
                    staged = staging_path / rel
                    staged.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(current, staged)
            backup_path.mkdir(parents=True, exist_ok=True)
            for staged in (path for path in staging_path.rglob("*") if path.is_file()):
                saved = backup_path / staged.relative_to(staging_path)
                saved.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(staged, saved)
    state["component_backup"] = records
    save_state(data_dir, state)

    for src, rel in _content_files(content_dir, depot_ids):
        dest = install_path / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
    return backup_path


def restore_component_from_state(data_dir: Path) -> None:
    state = load_state(data_dir)
    if state is None:
        raise RuntimeError("No downgrade state found; nothing to restore.")
    install_path = Path(state["game_path"])
    backup_path = data_dir / "file-backup"
    records = state.get("component_backup", [])
    if not records:
        raise RuntimeError("No Creation Kit file backup was made; use Steam Verify Integrity instead.")
    for item in records:
        rel = Path(item["path"])
        target = install_path / rel
        if item["existed"]:
            source = backup_path / rel
            if not source.is_file():
                raise RuntimeError(f"Component backup file is missing: {source}")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        elif target.is_file():
            target.unlink()
    shutil.rmtree(backup_path, ignore_errors=True)
    clear_state(data_dir)


def backup_path_for(game_path: Path, prior_version: str | None, prior_buildid: str | None) -> Path:
    label = prior_version or (f"build {prior_buildid}" if prior_buildid else "backup")
    candidate = game_path.parent / f"{game_path.name} ({label})"
    n = 2
    while candidate.exists():
        candidate = game_path.parent / f"{game_path.name} ({label}) ({n})"
        n += 1
    return candidate


def _create_full_backup(game_path: Path, backup_path: Path) -> None:
    staging = game_path.parent / f".jgd-backup-staging-{time.time_ns()}"
    try:
        shutil.copytree(game_path, staging)
        staging.rename(backup_path)
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


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
    depot_ids: list[str] | None = None,
) -> Path | None:
    if existing_state is not None:
        state = dict(existing_state)
        backup_path = Path(state["backup_path"]) if state.get("backup_path") else None
        if backup_path is not None and not backup_path.is_dir():
            backup_path = None
            state["backup_path"] = None
        state["version"] = version
        state["timestamp"] = time.strftime("%Y-%m-%d %H:%M:%S")
    else:
        backup_path = None
        intended_backup_path = backup_path_for(game_path, prior_version, prior_buildid) if create_backup else None
        state = {
            "game_path": str(game_path),
            "backup_path": None,
            "version": version,
            "prior_version": prior_version,
            "prior_buildid": prior_buildid,
            "prior_update_behavior": prior_update_behavior,
            "acf_path": str(acf_path) if acf_path else None,
            "prior_acf_mode": prior_acf_mode,
            "localconfigs": localconfigs or [],
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        # Save a restorable settings-only state before a potentially large copy.
        save_state(data_dir, state)
        backup_path = intended_backup_path
        if backup_path is not None:
            _create_full_backup(game_path, backup_path)
            state["backup_path"] = str(backup_path)
    save_state(data_dir, state)
    if backup_path is not None:
        (backup_path / BACKUP_STATE).write_text(json.dumps(state, indent=2))

    for src, rel in _content_files(content_dir, depot_ids):
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
