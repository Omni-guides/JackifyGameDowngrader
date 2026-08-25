# Jackify Game Downgrader for Windows

Downgrades the Steam version of Skyrim Special Edition or Fallout 4 to a supported older version.

## Before you start

- Windows 10 or 11 is required.
- You must own the game on Steam.
- Close Steam and the game before starting. If either is still running, the tool asks you to close it before continuing.
- Extract the entire ZIP to a normal folder. Do not run it from inside the ZIP.
- Make sure you have enough free space for the download. If you choose to make a backup, you also need enough space for another complete copy of the game.

## Running it

Double-click `JackifyGameDowngrader.cmd` and follow the prompts.

The tool will ask which game and version you want. It will also offer to back up the current game before making changes. A backup is recommended, but you can skip it if space is limited.

SteamCMD will ask for your Steam password and, if enabled, Steam Guard approval in the same window. These go directly to Valve's SteamCMD and are not saved by this tool.

The first run downloads SteamCMD from Valve. The downgrade itself can take some time because it downloads several gigabytes of game files.

## Restoring or changing version

Run `JackifyGameDowngrader.cmd` again and choose **Restore a previous downgrade** from the menu.

If you made a backup, restore puts it back. Without a backup, the tool restores the Steam settings it changed and tells you to use Steam's **Verify integrity of game files** option to download the current game again.

To change to a different older version, run the downgrader again and choose the new version. Your original backup is kept for a later restore.

Backups are stored beside the game folder and are not deleted automatically. Delete an unwanted backup yourself when you are certain you no longer need it.

## Other commands

Most users do not need these. They are available when running `JackifyGameDowngrader.ps1` from PowerShell:

```powershell
.\JackifyGameDowngrader.ps1 -Game fallout4
.\JackifyGameDowngrader.ps1 -Game fallout4 -Version 1.10.163
.\JackifyGameDowngrader.ps1 -Game fallout4 -DryRun
.\JackifyGameDowngrader.ps1 -Game fallout4 -NoBackup
.\JackifyGameDowngrader.ps1 -ListGames
.\JackifyGameDowngrader.ps1 -Game skyrim_se -ListVersions
.\JackifyGameDowngrader.ps1 -Game fallout4 -Restore
```

`-DryRun` still downloads the game files, but does not change the installed game or its Steam settings.

The tool does not require administrator access. Downloaded depot files are deleted after a successful downgrade. They are kept after a failure so you can retry without downloading everything again.
