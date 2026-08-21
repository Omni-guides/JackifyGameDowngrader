# Jackify Game Downgrader

Downgrades a Steam install of a modded game on Linux (Steam Deck or desktop)
to an older pinned build, for script-extender/mod compatibility. Python
stdlib only, no dependencies to install. Currently supports **Skyrim
Special Edition** and **Fallout 4**, the two games this problem actually
recurs for at scale in the Wabbajack ecosystem.

## Why

Both games got a live update that broke their script extender and a large
share of mods built against it: Skyrim SE's Anniversary Edition update moved
the runtime past 1.6.x (SKSE64 mods want 1.5.97 or a specific 1.6.x build),
and Fallout 4's 2024 "Next-Gen" update did the same to F4SE (most F4SE mods
want 1.10.163). "Downgrading" means pulling that older build's game files
back from Steam. Existing guides do this by hand through Steam's GUI
developer console; this tool automates it with `steamcmd` instead, since the
GUI console can't be scripted.

## Requirements

- The game installed through Steam (not GOG/Epic).
- Steam and the game both closed while running this.
- A terminal. On Steam Deck, use Desktop Mode (Game Mode can't run this).
- Your Steam login (steamcmd needs it to fetch the depots you own; you'll
  be prompted for password / Steam Guard interactively). Your password goes
  straight to steamcmd (Valve's own tool); this tool never sees, stores, or
  logs it. steamcmd may cache its own login session on disk so you aren't
  reprompted every run, which is steamcmd's own behavior, not something
  this tool adds.

## Usage

```
./jackify-game-downgrader                                    # asks which game, then: pick a version, confirm, go
./jackify-game-downgrader --game fallout4                     # same, skipping the game prompt
./jackify-game-downgrader --game fallout4 --version 1.10.163   # skip the version prompt too
./jackify-game-downgrader --dry-run                            # preview a downgrade, change nothing
./jackify-game-downgrader list-games                           # show supported games
./jackify-game-downgrader list-versions --game skyrim_se        # show available targets for a game
./jackify-game-downgrader restore --game fallout4               # undo the last downgrade for that game
```

There is deliberately no default game. `--game` always has to be given or
answered at the prompt, so a mistyped command can't accidentally downgrade
the wrong install. Before changing anything, the tool copies the whole
current install to a sibling folder next to it in the same Steam library,
e.g. `Skyrim Special Edition (1.7.99.0)`, named after the game's own
version, read directly from the exe (falling back to Steam's internal build
id if that ever fails, since it's not something a person recognizes).
`restore` deletes the downgraded folder and renames that backup back into
place, and also reverts just that game's Steam auto-update setting. The two
games' downgrades are otherwise fully independent, but they do share
Steam's single `localconfig.vdf`, so revert only ever touches the one app
entry, never the whole file.

Note this backs up the *entire* game folder, not just the files being
changed, so make sure there's enough free space in that Steam library for a
second full copy of the game during a downgrade. Restoring only puts back
what this tool itself changed. Run "Verify Integrity of Game Files" in
Steam afterward too, for anything outside that (e.g. Creation Club content).

## After downgrading

Steam will try to update the game back to latest on next launch. This tool
sets the game's per-app "Automatic Updates" to "Only update this game when
I launch it", but you should still either launch Steam in Offline Mode
before playing, or avoid clicking Update if Steam prompts for one.

## Adding a game / updating manifests

Each supported game is one JSON file under `game_downgrade/games/` (e.g.
`skyrim_se.json`, `fallout4.json`): appid, main executable name, depot IDs,
and a map of version to per-depot manifest ID. No code changes are needed
to add a new pinned version, or a new game with the same Steam-depot
downgrade shape.

Valve prunes old manifests over time, so an entry can go stale. If a
downgrade fails with a manifest error, check:

- [SteamDB](https://steamdb.info/): search the game's depot pages for
  currently available manifests.
- Nexus's ["Steam Manifest List for Skyrim"](https://www.nexusmods.com/skyrimspecialedition/articles/6536)
  article (Skyrim-specific, but the community keeps it updated) and
  equivalent Fallout 4 downgrade guides on Nexus/Steam Community for F4SE
  pins.

Then add or fix an entry in that game's JSON file.

## Steam Deck notes

This tool's own data (steamcmd, restore state) stays in `game_downgrade/data/`
next to the extracted package, not anywhere in your home directory; Steam
itself still lives at its usual `~/.local/share/Steam`. No root access or
system packages are needed, so this works fine under SteamOS's read-only
filesystem. `steamcmd`
needs the 32-bit runtime libraries SteamOS already ships for Steam itself;
on other distros, if `steamcmd` fails to start, that's the first thing to
check.

## Limitations

- Steam only. Skyrim SE (not VR/Enderal) and Fallout 4 only for now. Other
  games weren't found to need this at any real scale in the Wabbajack
  ecosystem, so they're out of scope until that changes.
- No automated test suite. This is inherently I/O-heavy (real Steam
  install, real downloads, real file swaps), so testing is a manual
  run-through against an actual install.
- CLI only for now; a GUI/Jackify integration is a possible future step.

## License

GPLv3. See [LICENSE](LICENSE).
