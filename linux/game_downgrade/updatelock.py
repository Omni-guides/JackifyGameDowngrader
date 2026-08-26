from __future__ import annotations

import re
from pathlib import Path

_BEHAVIOR_RE = re.compile(r'"AutoUpdateBehavior"\s+"(\d+)"')


def _find_block(text: str, key: str) -> tuple[int, int] | None:
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
    if value is None:
        return re.sub(r'\n[ \t]*"AutoUpdateBehavior"\s+"\d+"', "", body)
    replacement = f'"AutoUpdateBehavior"\t\t"{value}"'
    if _BEHAVIOR_RE.search(body):
        return _BEHAVIOR_RE.sub(replacement, body)
    return body + "\n\t\t\t" + replacement


def _edit_behavior(localconfig_path: Path, appid: int, value: str) -> str | None:
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
    return _edit_behavior(localconfig_path, appid, "1")


def revert_update_behavior(localconfig_path: Path, appid: int, prior_value: str | None) -> None:
    text = localconfig_path.read_text(errors="replace")
    block = _find_block(text, str(appid))
    if block is None:
        return
    start, end = block
    localconfig_path.write_text(text[:start] + _with_behavior(text[start:end], prior_value) + text[end:])
