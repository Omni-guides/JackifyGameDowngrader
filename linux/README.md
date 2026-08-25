# Jackify Game Downgrader for Linux

Downgrades the Steam version of Skyrim Special Edition or Fallout 4 to a supported older version.

## Before you start

- Python 3.10 or newer is required.
- You must own the game on Steam.
- Close Steam and the game before starting. If either is still running, the tool asks you to close it before continuing.
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

The tool will ask which game and version you want. It will also offer to back up the current game before making changes. A backup is recommended, but you can skip it if space is limited.

SteamCMD will ask for your Steam password and, if enabled, Steam Guard approval. These go directly to Valve's SteamCMD and are not saved by this tool. The downgrade can take some time because it downloads several gigabytes of game files.

## Restoring or changing version

Run the tool again and choose **Restore a previous downgrade** from the menu.

If you made a backup, restore puts it back. Without a backup, the tool restores the Steam settings it changed and tells you to use Steam's **Verify integrity of game files** option to download the current game again.

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
```

`--dry-run` still downloads the game files, but does not change the installed game or its Steam settings.

Downloaded depot files are deleted after a successful downgrade. They are kept after a failure so you can retry without downloading everything again.
