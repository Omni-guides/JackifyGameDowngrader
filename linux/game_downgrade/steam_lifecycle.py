from __future__ import annotations

import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Session:
    running: bool
    steam_deck: bool
    flatpak: bool


def is_running() -> bool:
    return _run(["pgrep", "-f", "steamwebhelper"]).returncode == 0


def stop(game_exe: str) -> Session:
    session = Session(is_running(), _is_steam_deck(), _is_flatpak_running())
    if session.steam_deck:
        _run(["systemctl", "--user", "stop", "app-steam@autostart.service"])
    elif session.flatpak:
        _run(["flatpak", "kill", "com.valvesoftware.Steam"])

    _run(["pkill", "steam"])
    _wait_for_exit("steamwebhelper", 15)
    if is_running():
        _run(["pkill", "-9", "steam"])
        _wait_for_exit("steamwebhelper", 5)
    if is_running():
        raise RuntimeError("Steam could not be closed. Close it manually and try again.")

    _stop_process(game_exe)
    return session


def start(session: Session) -> bool:
    if session.steam_deck:
        command = ["systemctl", "--user", "restart", "app-steam@autostart.service"]
    elif session.flatpak:
        command = ["flatpak", "run", "com.valvesoftware.Steam"]
    else:
        executable = shutil.which("steam")
        if not executable:
            executable = next(
                (path for path in ("/usr/games/steam", "/usr/bin/steam") if Path(path).is_file()),
                None,
            )
        if not executable:
            return False
        command = [executable]

    try:
        subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return False

    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if is_running():
            return True
        time.sleep(1)
    return False


def _run(command: list[str]) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return subprocess.CompletedProcess(command, 1)


def _wait_for_exit(pattern: str, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _run(["pgrep", "-f", pattern]).returncode != 0:
            return
        time.sleep(0.5)


def _stop_process(name: str) -> None:
    if _run(["pgrep", "-x", name]).returncode != 0:
        return
    _run(["pkill", "-x", name])
    _wait_for_exit(name, 5)
    if _run(["pgrep", "-x", name]).returncode == 0:
        _run(["pkill", "-9", "-x", name])


def _is_steam_deck() -> bool:
    for path in (Path("/etc/os-release"), Path("/sys/devices/virtual/dmi/id/product_name")):
        try:
            text = path.read_text(errors="ignore").lower()
            if "steam deck" in text or "steamos" in text:
                return True
        except OSError:
            pass
    return False


def _is_flatpak_running() -> bool:
    return _run(["pgrep", "-f", "com.valvesoftware.Steam"]).returncode == 0
