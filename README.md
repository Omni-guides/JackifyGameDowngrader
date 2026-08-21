# Jackify Game Downgrader

Downgrades a Steam install of Skyrim Special Edition or Fallout 4 to an
older, script-extender-compatible build. Python stdlib only, no
dependencies.

## Why

The August 2026 updates to Skyrim SE and Fallout 4, like every update before
them, broke most modlists until each author gets time to recompile. Until
then, downgrading the vanilla game to the previous version lets a modlist
still be installed and played. Most downgrading tools are designed for
Windows or still require manual steps afterwards.

This tool automatically:

* Pulls an older depot build via `steamcmd`, natively on Linux
* Backs up the existing game directory (can be deleted later if you need the space)
* Copies the depot files into place
* Sets the game's Steam auto-update to "Only update this game when I launch it"
* Marks the game's Steam file (the `.acf`) read-only to block updates it would otherwise still try
* Deletes `ContentCatalog.txt` from the game's Proton prefix so Steam regenerates it

Jackify Game Downgrader is standalone for now; longer term it will be
integrated as an additional task in Jackify, my Wabbajack-on-Linux tool, but
works fine on its own until that integration happens.

## Requirements

- Game installed through Steam (not GOG/Epic).
- Steam and the game closed while running this.
- A terminal, e.g. Konsole (Steam Deck: Desktop Mode, not Game Mode).
- Your Steam login. Credentials go straight to `steamcmd` (this tool never
  sees or stores them).

## Usage

### Download

Download the latest release from GitHub: **[TODO: add link to the `latest`
release once one exists]**. Extract the zip anywhere, then run the
downgrader from a terminal inside that folder.

### Running it

Interactive downgrade session:

```
./jackify-game-downgrader
```

Other commands include:

```
./jackify-game-downgrader --game fallout4
./jackify-game-downgrader --game fallout4 --version 1.10.163
./jackify-game-downgrader --dry-run                            # preview only, changes nothing
./jackify-game-downgrader list-games
./jackify-game-downgrader list-versions --game skyrim_se
./jackify-game-downgrader restore --game fallout4               # undo the last downgrade
```

Before changing anything, the whole game folder is copied to a
backup (e.g. `Skyrim Special Edition (1.7.99.0)`) in the same Steam library.
Make sure there's room for a second full copy. `restore` puts that backup
back and reverts the Steam settings this tool changed (auto-update
behavior, manifest permissions); anything outside that, run Steam's "Verify
Integrity of Game Files" for.

## Steam Deck notes

This tool's own data lives in `game_downgrade/data/`, next to the downgrader.
No root or system packages needed; it works under read-only filesystems such
as SteamOS. `steamcmd` needs the 32-bit runtime libs SteamOS already ships
for Steam itself; on other distros, that's the first thing to check if
`steamcmd` won't start.

## Limitations

- Steam only, Skyrim SE and Fallout 4 only.
- No automated tests; this is I/O-heavy against a real Steam install.
- CLI only until the Jackify integration.

## License

GPLv3. See [LICENSE](LICENSE).
