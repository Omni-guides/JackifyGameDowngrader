"""Set a game's per-app auto-update behavior so Steam doesn't silently
re-update it back to latest on next launch.

AutoUpdateBehavior values (Steam client "Automatic Updates" setting):
  0 = always keep this game updated
  1 = only update this game when I launch it
  2 = high priority (always auto-update, ahead of other games)

This edits localconfig.vdf directly. Steam MUST be closed first: the
client rewrites this file on its own schedule and would clobber or fight
an edit made while it's running.

localconfig.vdf is shared by every Steam app, so a downgrade of one game
(e.g. Skyrim SE) can share this file with a downgrade of another (e.g.
Fallout 4). Reverting must therefore only touch that one app's
AutoUpdateBehavior key, never restore/overwrite the whole file, since
undoing one game's change could otherwise wipe out the other's.
"""
from __future__ import annotations

import re
from pathlib import Path

_BEHAVIOR_RE = re.compile(r'"AutoUpdateBehavior"\s+"(\d+)"')


def _find_block(text: str, key: str) -> tuple[int, int] | None:
    """Find the {..} block belonging to "key" (VDF's nested braces mean a
    naive non-greedy regex would stop at the first nested closing brace
    instead of this block's own, so depth is tracked explicitly).
    Returns (body_start, body_end) spanning just inside the braces.
    """
    header_match = re.search(rf'"{re.escape(key)}"\s*\{{', text)
    if not header_match:
        return None
    body_start = header_match.end()
    depth = 1
    i = body_start
    while i < len(text) and depth > 0:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    if depth != 0:
        return None  # unbalanced braces, so don't touch the file
    body_end = i - 1  # position of the matching closing brace
    return body_start, body_end


def _with_behavior(body: str, value: str | None) -> str:
    """Return body with AutoUpdateBehavior set to value (removed if None)."""
    if value is None:
        return re.sub(r'\n[ \t]*"AutoUpdateBehavior"\s+"\d+"', "", body)
    replacement = f'"AutoUpdateBehavior"\t\t"{value}"'
    if _BEHAVIOR_RE.search(body):
        return _BEHAVIOR_RE.sub(replacement, body)
    return body + "\n\t\t\t" + replacement


def _edit_behavior(localconfig_path: Path, appid: int, value: str) -> str | None:
    """Set one app's AutoUpdateBehavior, returning its prior value (or None
    if the key wasn't present before)."""
    text = localconfig_path.read_text(errors="replace")
    block = _find_block(text, str(appid))
    if block is None:
        return None
    start, end = block
    body = text[start:end]
    prior = _BEHAVIOR_RE.search(body)
    prior_value = prior.group(1) if prior else None
    if prior_value != value:
        localconfig_path.write_text(text[:start] + _with_behavior(body, value) + text[end:])
    return prior_value


def set_manual_update(localconfig_path: Path, appid: int) -> str | None:
    """Set AutoUpdateBehavior to manual (1) for one app.

    Returns the prior value (as a string, e.g. "0"), or None if the key
    wasn't present before. Either way, the caller should keep this to
    pass to revert_update_behavior() later.
    """
    return _edit_behavior(localconfig_path, appid, "1")


def revert_update_behavior(localconfig_path: Path, appid: int, prior_value: str | None) -> None:
    """Put AutoUpdateBehavior back to what it was before set_manual_update()."""
    text = localconfig_path.read_text(errors="replace")
    block = _find_block(text, str(appid))
    if block is None:
        return
    start, end = block
    localconfig_path.write_text(text[:start] + _with_behavior(text[start:end], prior_value) + text[end:])
