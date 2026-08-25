"""Download pinned depot manifests through Valve's SteamCMD."""
from __future__ import annotations

import os
import pty
import re
import select
import subprocess
import sys
import tarfile
import time
import urllib.request
from pathlib import Path

from .paths import STEAMCMD_DIR

STEAMCMD_URL = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

STEAMCMD_BIN = STEAMCMD_DIR / "steamcmd.sh"


def ensure_steamcmd() -> Path:
    if STEAMCMD_BIN.is_file():
        return STEAMCMD_BIN

    STEAMCMD_DIR.mkdir(parents=True, exist_ok=True)
    archive_path = STEAMCMD_DIR / "steamcmd_linux.tar.gz"
    print()
    print(f"Downloading steamcmd from {STEAMCMD_URL} ...")
    urllib.request.urlretrieve(STEAMCMD_URL, archive_path)
    with tarfile.open(archive_path) as tar:
        tar.extractall(STEAMCMD_DIR)
    archive_path.unlink()
    STEAMCMD_BIN.chmod(0o755)

    if not STEAMCMD_BIN.is_file():
        raise RuntimeError(
            f"steamcmd download did not produce {STEAMCMD_BIN}; "
            "download or extraction likely failed."
        )
    return STEAMCMD_BIN


_DEPOT_START_RE = re.compile(r"Downloading depot (\d+) \(\d+ files?, ([\d,]+) MB\)")
_DEPOT_DONE_RE = re.compile(r"Depot download complete")
_SELF_UPDATE_RE = re.compile(r"^\[\s*\d+%\]|^\[-{2,}\]")
_ERROR_REASON_RE = re.compile(r"ERROR[! ]*\(([^)]+)\)")
_SPINNER = "|/-\\"

# Bookkeeping messages hidden from the user-facing output.
_NOISE_SUBSTRINGS = (
    "steamcmd.sh[",
    "Redirecting stderr to ",
    "Logging directory: ",
    "IPC function call ",
    "UpdateUI: skip show logo",
    "ILocalize::AddFile() failed to load file",
    "PosixFileOpen: RESOLVE_BENEATH unsupported",
)


def _dir_size(path: Path) -> int:
    if not path.is_dir():
        return 0
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def _run_with_spinner(cmd: list[str], appid: int) -> tuple[int, str | None]:
    """Run SteamCMD in a PTY so login prompts remain interactive.

    Complete lines are filtered for diagnostic noise. Unterminated prompts
    are forwarded during quiet periods, and depot progress is estimated from
    the files SteamCMD writes on disk.
    """
    controller_fd, worker_fd = pty.openpty()
    proc = subprocess.Popen(cmd, stdout=worker_fd, stderr=worker_fd, close_fds=True)
    os.close(worker_fd)

    pending = b""  # bytes received since the last completed/flushed line
    depot: tuple[str, float, int] | None = None  # (depot id, start time, total MB) while mid-transfer
    frame = 0
    overlay_shown = False  # true while the terminal's last write was a spinner/status overlay
    last_poll = 0.0
    last_done_mb = 0.0
    error_reason: str | None = None

    def clear_overlay() -> None:
        nonlocal overlay_shown
        if overlay_shown:
            sys.stdout.write("\r\x1b[K")  # cursor to column 0, erase to end of line
            overlay_shown = False

    def write_overlay(text: str) -> None:
        nonlocal overlay_shown
        sys.stdout.write(f"\r\x1b[K{text}")
        sys.stdout.flush()
        overlay_shown = True

    try:
        while True:
            try:
                ready, _, _ = select.select([controller_fd], [], [], 0.15)
            except OSError:
                break  # controller_fd closed, meaning steamcmd exited

            if not ready:
                if pending:
                    clear_overlay()
                    sys.stdout.buffer.write(pending)
                    sys.stdout.flush()
                    pending = b""
                elif depot:
                    depot_id, started, total_mb = depot
                    frame += 1
                    now = time.monotonic()
                    if now - last_poll >= 1.0:
                        last_poll = now
                        depot_dir = STEAMCMD_DIR / "linux32" / "steamapps" / "content" / f"app_{appid}" / f"depot_{depot_id}"
                        last_done_mb = _dir_size(depot_dir) / 1_000_000
                    shown_mb = min(last_done_mb, total_mb)
                    pct = shown_mb / total_mb * 100 if total_mb else 0
                    suffix = ", finalising" if last_done_mb >= total_mb else ""
                    write_overlay(
                        f"  {_SPINNER[frame % len(_SPINNER)]} depot {depot_id}: "
                        f"{pct:.0f}% ({shown_mb:.0f}/{total_mb} MB{suffix})"
                    )
                continue

            try:
                chunk = os.read(controller_fd, 1)
            except OSError:
                break
            if not chunk:
                break

            pending += chunk
            if chunk != b"\n":
                continue
            text, pending = pending.decode(errors="replace"), b""
            stripped = text.strip()

            reason = _ERROR_REASON_RE.search(text)
            if reason:
                error_reason = reason.group(1)

            if _SELF_UPDATE_RE.match(stripped):
                # steamcmd's own (first-run, or occasional) self-update: dozens
                # of individual percentage/status lines with no real value
                # beyond "still working", collapsed to one overwritten line.
                write_overlay(f"  updating steamcmd... {stripped}")
                continue

            start = _DEPOT_START_RE.search(text)
            if start:
                print()  # separate this depot's block from whatever came before
                depot = (start.group(1), time.monotonic(), int(start.group(2).replace(",", "")))
                last_poll, last_done_mb = 0.0, 0.0  # force a fresh poll for this depot
            elif _DEPOT_DONE_RE.search(text) and depot:
                clear_overlay()
                print(f"  (depot {depot[0]} took {time.monotonic() - depot[1]:.0f}s)")
                depot = None
                continue

            if not any(noise in text for noise in _NOISE_SUBSTRINGS):
                clear_overlay()
                sys.stdout.write(text)
                sys.stdout.flush()

        clear_overlay()
        return proc.wait(), error_reason
    except BaseException:
        # Do not leave SteamCMD running after an interruption.
        proc.terminate()
        proc.wait()
        raise
    finally:
        os.close(controller_fd)


def download_depots(username: str, appid: int, manifests: dict[str, str]) -> Path:
    """Run steamcmd to pull each depot's pinned manifest.

    Login and any Steam Guard prompt are interactive (stdin is left connected
    to the terminal) since this is meant to run in a foreground terminal
    session, not headless/unattended.
    """
    print("Note: steamcmd itself reports no progress for the depot download (just a")
    print("start/complete line per depot). The percentage shown below is this tool")
    print("estimating from files written on disk. It may show 'finalising' while")
    print("steamcmd finishes expanding and checking the depot.")
    print("If your account uses Steam Guard's mobile authenticator, check your phone")
    print("for an approval prompt after entering your password. steamcmd waits")
    print("silently for it.", flush=True)

    steamcmd_bin = ensure_steamcmd()  # may print a one-time download notice here

    cmd = [str(steamcmd_bin), "+login", username]
    for depotid, manifestid in manifests.items():
        cmd += ["+download_depot", str(appid), str(depotid), str(manifestid)]
    cmd.append("+quit")

    print()  # steamcmd's own output starts right after this
    returncode, error_reason = _run_with_spinner(cmd, appid)

    if returncode != 0:
        if error_reason:
            raise RuntimeError(f"steamcmd failed: {error_reason}")
        raise RuntimeError(
            f"steamcmd exited with code {returncode}. "
            "Check the output above; a common cause is a stale/pruned "
            "manifest ID (see README for how to refresh the JSON file under games/)."
        )

    # download_depot ignores force_install_dir. It always lands relative to
    # steamcmd's own install, in a location its own docs don't fix, so it's
    # located by searching rather than assumed.
    app_dirs = list(STEAMCMD_DIR.rglob(f"app_{appid}"))
    if not app_dirs:
        raise RuntimeError(f"Could not find steamcmd's depot output (app_{appid}) under {STEAMCMD_DIR}.")
    content_dir = app_dirs[0]
    for depotid in manifests:
        depot_dir = content_dir / f"depot_{depotid}"
        if not depot_dir.is_dir():
            raise RuntimeError(f"Expected depot output at {depot_dir}, but it wasn't created.")
    return content_dir
