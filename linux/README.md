# Jackify Game Downgrader for Linux

Downgrades the Steam version of Skyrim Special Edition, Fallout 4, or either game's Creation Kit to a supported older version.

## Before you start

- Python 3.10 or newer is required.
- You must own the game on Steam.
- Extract the entire ZIP to a normal folder.
- Make sure you have enough free space for the download. If you choose to make a backup, you also need enough space for another complete copy of the game.

## Running it

Open a terminal in the extracted folder and run:

```sh
./jackify-game-downgrader
```

If Linux says the file is not executable, run this once and try again:

```sh
chmod +x jackify-game-downgrader
```

The tool will ask which game or Creation Kit and version you want. Creation Kit choices are separate and optional: a game downgrade never changes its CK. Download the free CK through Steam and run it once before downgrading it. If it is missing after you select it, press Enter to return to the main menu and choose again. After an operation completes or is cancelled, the interactive tool returns to the main menu. The CK applications are officially Windows-only; their Linux choices are intended for Wine/Proton and modlist workflows. CK restore uses a small file-level backup and does not restore the shared parent game directory.

Before continuing, you must accept a warning that Steam will close. This also closes any game currently running through Steam. The tool starts Steam again when it finishes.

SteamCMD will ask for your Steam password and, if enabled, Steam Guard approval. These go directly to Valve's SteamCMD and are not saved by this tool. The downgrade can take some time because it downloads several gigabytes of game files.

After downgrading, do not launch the vanilla game through Steam or click Update. Launch your modded setup through its MO2 shortcut instead. Steam may make its game manifest writable again after an MO2/Proton session, so the Linux version does not rely on the manifest remaining read-only.

## Restoring or changing version

Run the tool again and choose **Restore a previous downgrade** from the menu.

If you made a backup, restore puts it back. Without a backup, the tool restores the Steam settings it changed and tells you to use Steam's **Verify integrity of game files** option to download the current game again.

Restore records are stored in `~/.local/state/jackify-game-downgrader/` so they survive tool updates and new ZIP extractions. If a record is missing, the tool can find compatible backup folders beside the game and ask which one to restore.

To change to a different older version, run the downgrader again and choose the new version. Your original backup is kept for a later restore.

Backups are stored beside the game folder and are not deleted automatically. Delete an unwanted backup yourself when you are certain you no longer need it.

## Other commands

Most users do not need these:

```sh
./jackify-game-downgrader --game fallout4
./jackify-game-downgrader --game fallout4 --version 1.10.163
./jackify-game-downgrader --dry-run
./jackify-game-downgrader --game fallout4 --no-backup
./jackify-game-downgrader list-games
./jackify-game-downgrader list-versions --game skyrim_se
./jackify-game-downgrader restore --game fallout4
./jackify-game-downgrader --game fallout4 --managed-restart
./jackify-game-downgrader --game fallout4_ck --version 1.10.162
./jackify-game-downgrader --game skyrim_se_ck --version 1.6.1130
```

`--dry-run` still downloads the game files, but does not change the installed game or its Steam settings.

Downloaded depot files are deleted after a successful downgrade. They are kept after a failure so you can retry without downloading everything again.

`--managed-restart` is for launchers such as Jackify that manage Steam themselves. Most users do not need it.
