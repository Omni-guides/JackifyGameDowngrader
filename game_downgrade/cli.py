from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from . import steam_paths, steamcmd, swap, updatelock
from .paths import game_data_dir

GAMES_DIR = Path(__file__).parent / "games"


def available_games() -> list[str]:
    return sorted(p.stem for p in GAMES_DIR.glob("*.json"))


def load_game(game_key: str) -> dict:
    path = GAMES_DIR / f"{game_key}.json"
    if not path.is_file():
        raise ValueError(f"Unknown game '{game_key}'. Available: {', '.join(available_games())}")
    return json.loads(path.read_text())


def _resolve_game(args: argparse.Namespace) -> tuple[str, dict]:
    """Return (game_key, game_data) for --game, or ask if it wasn't given.

    There is deliberately no default game: picking the wrong one here means
    downgrading the wrong install, so it's always either explicit on the
    command line or an explicit interactive choice, never silent.
    """
    if args.game:
        return args.game, load_game(args.game)
    keys = available_games()
    print("Which game?")
    for i, key in enumerate(keys, 1):
        print(f"  {i}) {load_game(key)['name']}")
    choice = input("Pick a game [number]: ").strip()
    try:
        key = keys[int(choice) - 1]
    except (ValueError, IndexError):
        raise ValueError("Invalid choice.")
    return key, load_game(key)


def _process_running(name: str) -> bool:
    try:
        result = subprocess.run(["pgrep", "-x", name], stdout=subprocess.DEVNULL)
        return result.returncode == 0
    except FileNotFoundError:
        return False  # pgrep unavailable, so don't block the user


def _confirm(prompt: str) -> bool:
    return input(f"{prompt} [y/N] ").strip().lower() == "y"


def _section(title: str) -> None:
    print()
    print(f"== {title} ==")


def _press_any_key(prompt: str) -> None:
    print(prompt, end="", flush=True)
    if not sys.stdin.isatty():
        input()  # not a real terminal (e.g. piped input), so fall back to Enter
        return
    import termios
    import tty

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)  # single keypress, no Enter needed, and keeps Ctrl+C (ISIG) working
        sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    print()


def _require_closed(name: str, label: str) -> None:
    while _process_running(name):
        _press_any_key(
            f"The downgrader requires {label} to be closed. "
            f"Please fully exit {label} and then press any key to continue... "
        )


def cmd_list_games(_args: argparse.Namespace) -> int:
    print("Supported games:")
    for key in available_games():
        game = load_game(key)
        print(f"  {key}: {game['name']}")
    return 0


def cmd_list_versions(args: argparse.Namespace) -> int:
    _key, game = _resolve_game(args)
    print(f"Available downgrade targets for {game['name']}:")
    for key in game["versions"]:
        print(f"  {key}")
    return 0


def cmd_restore(args: argparse.Namespace) -> int:
    game_key, game = _resolve_game(args)
    data_dir = game_data_dir(game_key)
    state = swap.load_state(data_dir)
    if state is None:
        print(f"No downgrade state found for {game['name']}; nothing to restore.")
        return 1

    _section(f"Restore: {game['name']}")
    print(f"Game folder: {state['game_path']}")
    print(f"Backup taken: {state['timestamp']} (just before downgrading to {state['version']})")
    if not _confirm("Proceed?"):
        print("Aborted.")
        return 1

    swap.restore_from_state(data_dir)

    localconfig = steam_paths.find_userdata_localconfig()
    if localconfig is not None and "prior_update_behavior" in state:
        updatelock.revert_update_behavior(localconfig, game["appid"], state["prior_update_behavior"])
        print(f"Reverted {game['name']}'s auto-update setting back to what it was before.")

    if state.get("acf_path") and state.get("prior_acf_mode") is not None:
        acf_path = Path(state["acf_path"])
        steam_paths.restore_acf_writable(acf_path, state["prior_acf_mode"])
        print(f"Restored write permissions on {acf_path.name}.")

    game_path = Path(state["game_path"])
    content_catalog = steam_paths.find_content_catalog(
        game_path.parents[2], game["appid"], game_path.name
    )
    if content_catalog.is_file():
        content_catalog.unlink()
        print("Removed stale Creation Club content catalog (ContentCatalog.txt);")
        print("Steam regenerates it on next launch.")

    print()
    print("Restore complete. Run 'Verify Integrity of Game Files' in Steam to fully")
    print("resync anything this tool didn't track (e.g. Creation Club content).")
    return 0


def cmd_downgrade(args: argparse.Namespace) -> int:
    _require_closed("steam", "Steam")
    game_key, game = _resolve_game(args)
    _require_closed(game["main_exe"], game["name"])

    install = steam_paths.find_game(game["appid"], game["main_exe"])
    if install is None:
        print(f"Could not find a {game['name']} install via Steam's library files.")
        print("Make sure it's installed through Steam (not GOG/Epic; this tool is Steam-only).")
        return 1

    versions = game["versions"]

    if args.version:
        version_key = args.version
        if version_key not in versions:
            print(f"Unknown version '{version_key}'. Run list-versions --game {game_key} to see options.")
            return 1
    else:
        keys = list(versions.keys())
        current = install.version or (f"build {install.buildid}" if install.buildid else "unknown version")
        _section(game["name"])
        print(f"Location:       {install.game_path}")
        print(f"Current version: {current}")
        print()
        print("Downgrade to:")
        for i, key in enumerate(keys, 1):
            print(f"  {i}) {key}")
        choice = input("Pick a target version [number]: ").strip()
        try:
            version_key = keys[int(choice) - 1]
        except (ValueError, IndexError):
            print("Invalid choice.")
            return 1

    entry = versions[version_key]
    data_dir = game_data_dir(game_key)

    _section("Dry run" if args.dry_run else "Plan")
    if args.dry_run:
        print(f"Previewing a downgrade of {game['name']} to {version_key}.")
        print("This will log into Steam and download the real depot data to preview")
        print("against, but no game files or Steam settings will be changed.")
    else:
        backup_path = swap.backup_path_for(install.game_path, install.version, install.buildid)
        print(f"Downgrade {game['name']} to {version_key}:")
        print(f"  Game folder: {install.game_path}")
        print(f"  Current install backed up to: {backup_path}")
        print(f"  Steam auto-update for {game['name']} set to 'only update when launched'")
        print(f"  Steam manifest (appmanifest_{game['appid']}.acf) set to read-only")
    if not _confirm("Proceed?"):
        print("Aborted.")
        return 1

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

    localconfig = steam_paths.find_userdata_localconfig()
    prior_update_behavior = None
    if localconfig is not None:
        prior_update_behavior = updatelock.set_manual_update(localconfig, game["appid"])
    else:
        print(f"Could not find localconfig.vdf. Set {game['name']}'s Automatic Updates")
        print("to 'Only update this game when I launch it' manually in Steam's")
        print("game Properties, or it may silently re-update on next launch.")

    prior_acf_mode = steam_paths.set_acf_readonly(install.acf_path)

    _section("Applying downgrade")
    print("Backing up the current install and copying downgraded files in...")
    backup_path = swap.apply_downgrade(
        install.game_path, content_dir, version_key, install.version, install.buildid, data_dir,
        prior_update_behavior, install.acf_path, prior_acf_mode,
    )
    print(f"Backup saved to {backup_path}")
    if localconfig is not None:
        print(f"Set {game['name']} to 'only update when launched' in Steam.")
    print(f"Set {install.acf_path.name} to read-only so Steam can't rewrite it back.")

    shutil.rmtree(content_dir, ignore_errors=True)

    content_catalog = steam_paths.find_content_catalog(
        install.library_root, game["appid"], install.game_path.name
    )
    if content_catalog.is_file():
        content_catalog.unlink()
        print("Removed stale Creation Club content catalog (ContentCatalog.txt);")
        print("Steam regenerates it on next launch.")

    _section("Done")
    print(f"{game['name']} is now on {version_key}.")
    print("Before playing: launch Steam, and either use Offline Mode or avoid")
    print("clicking Update if Steam prompts for one.")
    return 0


def _add_game_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--game", default=None,
        help="Which game to target (asked if omitted). Run list-games to see options.",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Downgrade a Steam install of a modded game on Linux.")
    sub = parser.add_subparsers(dest="command")

    p_games = sub.add_parser("list-games", help="List supported games")
    p_games.set_defaults(func=cmd_list_games)

    p_list = sub.add_parser("list-versions", help="List available downgrade targets for a game")
    _add_game_arg(p_list)
    p_list.set_defaults(func=cmd_list_versions)

    p_restore = sub.add_parser("restore", help="Undo the last downgrade for a game")
    _add_game_arg(p_restore)
    p_restore.set_defaults(func=cmd_restore)

    p_downgrade = sub.add_parser("downgrade", help="Downgrade a game (default if no command given)")
    _add_game_arg(p_downgrade)
    p_downgrade.add_argument("--version", help="Target version key, e.g. 1.5.97 (skips the interactive prompt)")
    p_downgrade.add_argument(
        "--dry-run", action="store_true",
        help="Log in and download the depot data to preview it, but change no game files or Steam settings",
    )
    p_downgrade.set_defaults(func=cmd_downgrade)

    argv = list(argv if argv is not None else sys.argv[1:])
    known_commands = {"list-games", "list-versions", "restore", "downgrade", "-h", "--help"}
    if not argv or argv[0] not in known_commands:
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
