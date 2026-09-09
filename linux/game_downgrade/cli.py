from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

from . import steam_lifecycle, steam_paths, steamcmd, swap, updatelock


def _newest_versions_first(versions):
    return sorted(versions, key=lambda value: tuple(int(part) for part in value.split(".")), reverse=True)
from .paths import STEAMCMD_DIR, game_data_dir
from .pe_version import read_file_version

GAMES_DIR = Path(__file__).parents[2] / "games"
if not GAMES_DIR.is_dir():
    GAMES_DIR = Path(__file__).parent.parent / "games"

RETURN_TO_MENU = 2


def available_games() -> list[str]:
    paths = list(GAMES_DIR.glob("*.json"))
    return [
        path.stem for path in sorted(
            paths,
            key=lambda item: (
                json.loads(item.read_text()).get("component") == "creation_kit",
                item.stem,
            ),
        )
    ]


def load_game(game_key: str) -> dict:
    path = GAMES_DIR / f"{game_key}.json"
    if not path.is_file():
        raise ValueError(f"Unknown game '{game_key}'. Available: {', '.join(available_games())}")
    return json.loads(path.read_text())


def _is_component(game: dict) -> bool:
    return game.get("component") == "creation_kit"


def _parent_version(game: dict) -> str | None:
    if not _is_component(game):
        return None
    parent = steam_paths.find_game(game["parent_appid"], game["parent_main_exe"])
    return parent.version if parent else None


def _resolve_game(args: argparse.Namespace) -> tuple[str, dict]:
    if args.game:
        return args.game, load_game(args.game)
    keys = available_games()
    print("Which game?")
    for i, key in enumerate(keys, 1):
        print(f"  {i}) {load_game(key)['name']}")
    while True:
        choice = input("Pick a game [number]: ").strip()
        try:
            index = int(choice) - 1
            if index < 0:
                raise IndexError
            key = keys[index]
            return key, load_game(key)
        except (ValueError, IndexError):
            print(f"Enter a number from 1 to {len(keys)}.")


def _confirm(prompt: str) -> bool:
    return input(f"{prompt} [y/N] ").strip().lower() == "y"


def _confirm_default_yes(prompt: str) -> bool:
    return input(f"{prompt} [Y/n] ").strip().lower() in {"", "y", "yes"}


def _section(title: str) -> None:
    print()
    print(f"== {title} ==")


def _directory_size(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def _existing_parent(path: Path) -> Path:
    while not path.exists():
        path = path.parent
    return path


def _assert_free_space(path: Path, required: int, label: str) -> None:
    free = shutil.disk_usage(_existing_parent(path)).free
    if free < required:
        raise RuntimeError(
            f"{label} needs about {(required + 10**9 - 1) // 10**9} GB free; "
            f"only {free // 10**9} GB is available."
        )


def _test_directory_write(path: Path) -> None:
    try:
        with tempfile.NamedTemporaryFile(dir=path):
            pass
    except OSError as exc:
        raise RuntimeError(f"No write access to {path}.") from exc


def _test_file_write(path: Path) -> None:
    try:
        with path.open("r+"):
            pass
    except OSError as exc:
        raise RuntimeError(f"No write access to {path}.") from exc


def cmd_list_games(_args: argparse.Namespace) -> int:
    print("Supported games:")
    for key in available_games():
        game = load_game(key)
        print(f"  {key}: {game['name']}")
    return 0


def cmd_list_versions(args: argparse.Namespace) -> int:
    _key, game = _resolve_game(args)
    print(f"Available downgrade targets for {game['name']}:")
    for key in _newest_versions_first(game["versions"]):
        note = game["versions"][key].get("note")
        print(f"  {key}{f' - {note}' if note else ''}")
    return 0


def _accept_steam_warning() -> bool:
    print()
    print("Steam will close before game files are changed and will restart when finished.")
    print("Any game currently running through Steam will also be closed.")
    return _confirm("Continue?")


def _restart_steam(session: steam_lifecycle.Session) -> None:
    if not session.running:
        return
    print("Starting Steam...")
    if steam_lifecycle.start(session):
        print("Steam started.")
    else:
        print("Steam could not be restarted automatically. Please start it manually.")


def _backup_candidates(game: dict):
    if _is_component(game):
        return steam_paths.find_game(game["appid"], game["main_exe"]), []
    install = steam_paths.find_game(game["appid"], game["main_exe"])
    if install is None:
        return None, []
    prefix = f"{install.game_path.name} ("
    backups = [
        path for path in install.game_path.parent.iterdir()
        if path.is_dir() and path.name.startswith(prefix) and (path / game["main_exe"]).is_file()
    ]
    return install, sorted(backups, key=lambda path: path.name)


def _recover_state(game: dict, data_dir: Path) -> dict | None:
    install, backups = _backup_candidates(game)
    if not backups:
        return None
    print(f"Found {len(backups)} backup folder(s) beside {game['name']}:")
    for index, backup in enumerate(backups, 1):
        version = read_file_version(backup / game["main_exe"]) or "unknown version"
        print(f"  {index}) {backup.name} [{version}]")
    while True:
        choice = input("Choose a backup to restore, or press Enter to cancel: ").strip()
        if not choice:
            return None
        try:
            index = int(choice) - 1
            if index < 0:
                raise IndexError
            backup = backups[index]
            break
        except (ValueError, IndexError):
            print(f"Enter a number from 1 to {len(backups)}.")

    state = swap.load_backup_state(backup)
    if state is None:
        current_mode = stat.S_IMODE(install.acf_path.stat().st_mode)
        state = {
            "game_path": str(install.game_path),
            "backup_path": str(backup),
            "version": install.version,
            "prior_version": read_file_version(backup / game["main_exe"]),
            "prior_buildid": None,
            "acf_path": str(install.acf_path),
            "prior_acf_mode": current_mode | stat.S_IWUSR,
            "localconfigs": [],
            "timestamp": "recovered from backup folder",
            "recovered": True,
        }
    else:
        state["game_path"] = str(install.game_path)
        state["backup_path"] = str(backup)
    swap.save_state(data_dir, state)
    return state


def cmd_restore(args: argparse.Namespace) -> int:
    game_key, game = _resolve_game(args)
    data_dir = game_data_dir(game_key)
    state = swap.load_state(data_dir)
    if state is None and not _is_component(game):
        state = _recover_state(game, data_dir)
    if state is None:
        print(f"No downgrade state or backup was found for {game['name']}.")
        return 1
    managed_restart = getattr(args, "managed_restart", False)
    if not managed_restart and not _accept_steam_warning():
        print("Aborted.")
        return 1

    _section(f"Restore: {game['name']}")
    print(f"Game folder: {state['game_path']}")
    if _is_component(game) and state.get("component_backup"):
        print("Backup taken: Creation Kit files only (the parent game is untouched)")
    elif state.get("backup_path") and not state.get("recovered"):
        print(f"Backup taken: {state['timestamp']} (just before downgrading to {state['version']})")
    elif state.get("backup_path"):
        print(f"Backup selected: {state['backup_path']}")
    else:
        print("Backup taken: none; Steam verification will be required")
    if not _confirm("Proceed?"):
        print("Aborted.")
        return 1

    game_path = Path(state["game_path"])
    steam_root = game_path.parents[2]
    recorded_backup = state.get("backup_path")
    if recorded_backup and not Path(recorded_backup).is_dir():
        print(f"The recorded backup is missing: {recorded_backup}")
        print("Steam settings will still be restored; verify the game through Steam to recover its files.")
        state["backup_path"] = None
        swap.save_state(data_dir, state)
    steam_session = None
    if not managed_restart:
        print("Stopping Steam...")
        steam_session = steam_lifecycle.stop(game["main_exe"])

    try:
        if _is_component(game) and state.get("component_backup"):
            swap.restore_component_from_state(data_dir)
        elif state.get("backup_path"):
            swap.restore_from_state(data_dir)

        config_states = state.get("localconfigs", [])
        if config_states:
            for config_state in config_states:
                localconfig = Path(config_state["path"])
                if localconfig.is_file():
                    updatelock.revert_update_behavior(
                        localconfig, game["appid"], config_state.get("prior_value")
                    )
                    print(f"Reverted Steam update setting in {localconfig}.")
        else:
            localconfig = steam_paths.find_userdata_localconfig()
            if localconfig is not None and "prior_update_behavior" in state:
                updatelock.revert_update_behavior(localconfig, game["appid"], state["prior_update_behavior"])
                print(f"Reverted {game['name']}'s auto-update setting back to what it was before.")

        if state.get("acf_path") and state.get("prior_acf_mode") is not None:
            acf_path = Path(state["acf_path"])
            steam_paths.restore_acf_writable(acf_path, state["prior_acf_mode"])
            print(f"Restored write permissions on {acf_path.name}.")

        if not _is_component(game):
            content_catalog = steam_paths.find_content_catalog(
                steam_root, game["appid"], game_path.name
            )
            if content_catalog.is_file():
                content_catalog.unlink()
                print("Removed stale Creation Club content catalog (ContentCatalog.txt);")
                print("Steam regenerates it on next launch.")

        if not state.get("backup_path"):
            swap.clear_state(data_dir)
    finally:
        if steam_session is not None:
            _restart_steam(steam_session)

    print()
    if _is_component(game) and state.get("component_backup"):
        print("Creation Kit restore complete.")
    elif state.get("backup_path"):
        print("Restore complete. Run 'Verify Integrity of Game Files' in Steam to fully")
        print("resync anything this tool didn't track (e.g. Creation Club content).")
        if state.get("recovered"):
            print("The original Steam update setting was unavailable and was left unchanged.")
    else:
        subject = "Creation Kit" if _is_component(game) else "game"
        print(f"Steam settings restored. Verify the {subject} in Steam")
        print(f"to reinstall the current {subject} build.")
    return 0


def cmd_downgrade(args: argparse.Namespace) -> int:
    game_key, game = _resolve_game(args)

    install = steam_paths.find_game(game["appid"], game["main_exe"])
    if install is None:
        print(f"Could not find a {game['name']} install via Steam's library files.")
        if _is_component(game):
            print("Download the free Creation Kit through Steam and run it once first.")
            if getattr(args, "return_to_menu", False):
                input("Press Enter to return to the main menu: ")
                return RETURN_TO_MENU
        else:
            print("Make sure it's installed through Steam (not GOG/Epic; this tool is Steam-only).")
        return 1
    managed_restart = getattr(args, "managed_restart", False)
    if not args.dry_run and not managed_restart and not _accept_steam_warning():
        print("Aborted.")
        return 1

    versions = game["versions"]

    if args.version:
        version_key = args.version
        if version_key not in versions:
            print(f"Unknown version '{version_key}'. Run list-versions --game {game_key} to see options.")
            return 1
    else:
        keys = _newest_versions_first(versions)
        current = install.version or (f"build {install.buildid}" if install.buildid else "unknown version")
        _section(game["name"])
        print(f"Location:       {install.game_path}")
        print(f"Current version: {current}")
        print()
        parent_version = _parent_version(game)
        if parent_version:
            print(f"Installed parent game: {parent_version}")
            for item, message in game.get("unavailable_matches", {}).items():
                if parent_version.startswith(item):
                    print(f"Note: {message}")
            print()
        print("Downgrade to:")
        for i, key in enumerate(keys, 1):
            recommended = parent_version and any(
                parent_version.startswith(item) for item in versions[key].get("recommended_for", [])
            )
            note = versions[key].get("note")
            suffix = " [recommended]" if recommended else (f" - {note}" if note else "")
            print(f"  {i}) {key}{suffix}")
        while True:
            choice = input("Pick a target version [number]: ").strip()
            try:
                index = int(choice) - 1
                if index < 0:
                    raise IndexError
                version_key = keys[index]
                break
            except (ValueError, IndexError):
                print(f"Enter a number from 1 to {len(keys)}.")

    parent_version = _parent_version(game)
    recommended_for = versions[version_key].get("recommended_for", [])
    if _is_component(game) and parent_version and not any(
        parent_version.startswith(item) for item in recommended_for
    ):
        print()
        print(f"Warning: {version_key} is not the recommended Creation Kit for parent game {parent_version}.")
        if not args.version and not _confirm("Continue with this advanced selection?"):
            print("Aborted.")
            return 1

    entry = versions[version_key]
    data_dir = game_data_dir(game_key)
    existing_state = swap.load_state(data_dir)
    retarget = existing_state is not None
    create_backup = not args.dry_run and not args.no_backup and not retarget
    game_size = 0 if _is_component(game) else _directory_size(install.game_path)
    if create_backup:
        prompt = (
            "Back up the Creation Kit files that will be replaced? Recommended"
            if _is_component(game)
            else "Create a full game backup? Recommended, but optional if space is limited"
        )
        create_backup = _confirm_default_yes(prompt)

    download_size = int(game.get("download_size_gb", 0)) * 10**9
    backup_parent = install.game_path.parent
    download_parent = STEAMCMD_DIR
    same_device = (
        os.stat(_existing_parent(backup_parent)).st_dev
        == os.stat(_existing_parent(download_parent)).st_dev
    )
    if create_backup and same_device and not _is_component(game):
        _assert_free_space(
            download_parent, download_size + game_size,
            "Depot downloads and the full backup",
        )
    else:
        _assert_free_space(download_parent, download_size, "Depot downloads")
        if create_backup and not _is_component(game):
            _assert_free_space(backup_parent, game_size, "The full backup")

    _section("Dry run" if args.dry_run else "Plan")
    if args.dry_run:
        print(f"Previewing a downgrade of {game['name']} to {version_key}.")
        print("This will log into Steam and download the real depot data to preview")
        print("against, but no game files or Steam settings will be changed.")
    else:
        print(f"Downgrade {game['name']} to {version_key}:")
        print(f"  Game folder: {install.game_path}")
        if retarget and _is_component(game):
            if existing_state.get("component_backup"):
                print("  Original Creation Kit file backup retained for restore")
            else:
                print("  No original CK file backup is available; Steam verification may be required")
        elif retarget:
            existing_backup = existing_state.get("backup_path")
            if existing_backup and Path(existing_backup).is_dir():
                print(f"  Original backup retained at: {existing_backup}")
                print("  The game will be reset from it before applying the new target")
            else:
                print("  No original backup is available; applying over the current files")
                print("  Steam verification may be required if versions contain different files")
        elif create_backup and _is_component(game):
            print("  Files replaced by the downgrade backed up under the tool's state directory")
            print("  The parent game files are not backed up or changed as a unit")
        elif create_backup:
            backup_path = swap.backup_path_for(install.game_path, install.version, install.buildid)
            print(f"  Current install backed up to: {backup_path}")
            print(f"  Approximate backup size: {game_size / 10**9:.1f} GB")
            print("  The backup remains until restored or deleted by you")
        else:
            subject = "Creation Kit" if _is_component(game) else "game"
            print(f"  Backup skipped; Steam must redownload the {subject} to recover it")
        print(f"  Steam auto-update for {game['name']} set to 'only update when launched'")
    if not _confirm("Proceed?"):
        print("Aborted.")
        return 1
    data_dir.parent.mkdir(parents=True, exist_ok=True)
    _test_directory_write(data_dir.parent)
    _test_directory_write(_existing_parent(download_parent))
    if not args.dry_run:
        _test_directory_write(install.game_path)
        if create_backup and not _is_component(game):
            _test_directory_write(install.game_path.parent)
        for localconfig in steam_paths.find_userdata_localconfigs():
            _test_file_write(localconfig)

    _section("Steam login & download")
    print("Your password/Steam Guard code goes straight to steamcmd (Valve's own tool).")
    print("This tool never sees, stores, or logs it.")
    username = input("Steam username (for steamcmd login): ").strip()
    if not username:
        print("A Steam username is required: steamcmd needs to log in to fetch the depots.")
        return 1
    print()
    content_dir = steamcmd.download_depots(username, game["appid"], entry["manifests"])

    if args.dry_run:
        overwrite, new = swap.preview_downgrade(install.game_path, content_dir)
        shutil.rmtree(content_dir, ignore_errors=True)
        _section("Result")
        print(f"Would overwrite {len(overwrite)} existing file(s) and add {len(new)} new file(s).")
        print("DRY RUN complete. No game files or Steam settings were changed.")
        return 0

    steam_session = None
    if not managed_restart:
        print("Stopping Steam...")
        steam_session = steam_lifecycle.stop(game["main_exe"])

    try:
        if retarget:
            localconfigs = steam_paths.find_userdata_localconfigs()
            prior_update_behavior = existing_state.get("prior_update_behavior")
            prior_acf_mode = existing_state.get("prior_acf_mode")
            localconfig_states = existing_state.get("localconfigs", [])
        else:
            localconfigs = steam_paths.find_userdata_localconfigs()
            prior_update_behavior = None
            localconfig_states = []
            for localconfig in localconfigs:
                prior = updatelock.set_manual_update(localconfig, game["appid"])
                localconfig_states.append({"path": str(localconfig), "prior_value": prior})
                if prior_update_behavior is None:
                    prior_update_behavior = prior
                print(f"Protected Steam account config: {localconfig}")
            if not localconfigs:
                print(f"Could not find localconfig.vdf. Set {game['name']}'s Automatic Updates")
                print("to 'Only update this game when I launch it' manually in Steam's")
                print("game Properties, or it may silently re-update on next launch.")
            prior_acf_mode = None

        _section("Applying downgrade")
        if retarget and existing_state.get("backup_path") and Path(existing_state["backup_path"]).is_dir():
            print("Resetting the game from the original backup...")
            swap.reset_game_from_backup(install.game_path, Path(existing_state["backup_path"]))
        elif create_backup and _is_component(game):
            print("Backing up the Creation Kit files being replaced and copying downgraded files in...")
        elif create_backup:
            print("Backing up the current install and copying downgraded files in...")
        else:
            backup_kind = "Creation Kit file backup" if _is_component(game) else "full backup"
            print(f"Copying downgraded files in without a {backup_kind}...")
        apply = swap.apply_component_downgrade if _is_component(game) else swap.apply_downgrade
        backup_path = apply(
            install.game_path, content_dir, version_key, install.version, install.buildid, data_dir,
            prior_update_behavior, install.acf_path, prior_acf_mode,
            create_backup=create_backup,
            existing_state=existing_state,
            localconfigs=localconfig_states,
        )
        if backup_path is not None:
            label = "Creation Kit file backup" if _is_component(game) else "Backup"
            print(f"{label} saved to {backup_path}")
        if localconfigs:
            print(f"Set {game['name']} to 'only update when launched' in Steam.")

        installed_version = read_file_version(install.game_path / game["main_exe"])
        if installed_version is None or not installed_version.startswith(version_key):
            raise RuntimeError(
                f"Expected {version_key}, but the installed executable reports "
                f"{installed_version or 'an unknown version'}. The backup is intact."
            )

        shutil.rmtree(content_dir, ignore_errors=True)

        if not _is_component(game):
            content_catalog = steam_paths.find_content_catalog(
                install.library_root, game["appid"], install.game_path.name
            )
            if content_catalog.is_file():
                content_catalog.unlink()
                print("Removed stale Creation Club content catalog (ContentCatalog.txt);")
                print("Steam regenerates it on next launch.")
    finally:
        if steam_session is not None:
            _restart_steam(steam_session)

    _section("Done")
    print(f"{game['name']} is now on {version_key}.")
    if _is_component(game):
        print("Keep this Creation Kit's Steam updates disabled, or Steam may replace it.")
    else:
        print(f"Do not launch vanilla {game['name']} through Steam or click Update.")
        print("Launch your modded setup through its MO2 shortcut instead.")
    return 0


def cmd_interactive(_args: argparse.Namespace) -> int:
    keys = available_games()
    while True:
        print("What would you like to do?")
        for index, key in enumerate(keys, 1):
            print(f"  {index}) Downgrade {load_game(key)['name']}")
        restore_choice = len(keys) + 1
        exit_choice = len(keys) + 2
        print(f"  {restore_choice}) Restore a previous downgrade")
        print(f"  {exit_choice}) Exit")
        choice = input("Pick an option [number]: ").strip()
        try:
            index = int(choice) - 1
        except ValueError:
            index = -1
        if 0 <= index < len(keys):
            result = cmd_downgrade(argparse.Namespace(
                game=keys[index], version=None, dry_run=False, no_backup=False,
                return_to_menu=True,
            ))
            if result == RETURN_TO_MENU:
                print()
                continue
            input("Press Enter to return to the main menu: ")
            print()
            continue
        if index == len(keys):
            available = []
            for key in keys:
                game = load_game(key)
                if swap.load_state(game_data_dir(key)) or _backup_candidates(game)[1]:
                    available.append(key)
            if not available:
                print("No previous downgrade state was found.\n")
                continue
            if len(available) == 1:
                restore_key = available[0]
            else:
                print("Restore which game?")
                for item_index, key in enumerate(available, 1):
                    print(f"  {item_index}) {load_game(key)['name']}")
                while True:
                    selected = input("Pick a game [number]: ").strip()
                    try:
                        selected_index = int(selected) - 1
                        if selected_index < 0:
                            raise IndexError
                        restore_key = available[selected_index]
                        break
                    except (ValueError, IndexError):
                        print(f"Enter a number from 1 to {len(available)}.")
            cmd_restore(argparse.Namespace(game=restore_key))
            input("Press Enter to return to the main menu: ")
            print()
            continue
        if index == len(keys) + 1:
            return 0
        print(f"Enter a number from 1 to {exit_choice}.")


def _add_game_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--game", default=None,
        help="Which game or Creation Kit to target (asked if omitted). Run list-games to see options.",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Downgrade a Steam install of a modded game on Linux.")
    sub = parser.add_subparsers(dest="command")

    p_interactive = sub.add_parser("interactive", help=argparse.SUPPRESS)
    p_interactive.set_defaults(func=cmd_interactive)

    p_games = sub.add_parser("list-games", help="List supported games")
    p_games.set_defaults(func=cmd_list_games)

    p_list = sub.add_parser("list-versions", help="List available downgrade targets for a game")
    _add_game_arg(p_list)
    p_list.set_defaults(func=cmd_list_versions)

    p_restore = sub.add_parser("restore", help="Undo the last downgrade for a game")
    _add_game_arg(p_restore)
    p_restore.add_argument(
        "--managed-restart", action="store_true",
        help="Leave Steam and game process management to the calling application",
    )
    p_restore.set_defaults(func=cmd_restore)

    p_downgrade = sub.add_parser("downgrade", help="Downgrade a game (default if no command given)")
    _add_game_arg(p_downgrade)
    p_downgrade.add_argument("--version", help="Target version key, e.g. 1.5.97 (skips the interactive prompt)")
    p_downgrade.add_argument(
        "--dry-run", action="store_true",
        help="Log in and download the depot data to preview it, but change no game files or Steam settings",
    )
    p_downgrade.add_argument(
        "--no-backup", action="store_true",
        help="Skip the optional full game backup",
    )
    p_downgrade.add_argument(
        "--managed-restart", action="store_true",
        help="Leave Steam and game process management to the calling application",
    )
    p_downgrade.set_defaults(func=cmd_downgrade)

    argv = list(argv if argv is not None else sys.argv[1:])
    known_commands = {"interactive", "list-games", "list-versions", "restore", "downgrade", "-h", "--help"}
    if not argv:
        argv = ["interactive"]
    elif argv[0] not in known_commands:
        argv = ["downgrade", *argv]

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ValueError as exc:
        print(exc)
        return 1
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
