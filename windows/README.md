# Jackify Game Downgrader for Windows

Downgrades the Steam version of Skyrim Special Edition, Fallout 4, or either game's Creation Kit to a supported older version.

## Before you start

- Windows 10 or 11 is required.
- You must own the game on Steam.
- Extract the entire ZIP to a normal folder. Do not run it from inside the ZIP.
- Make sure you have enough free space for the download. If you choose to make a backup, you also need enough space for another complete copy of the game.

## Running it

Double-click `JackifyGameDowngrader.cmd` and follow the prompts.

The tool will ask which game or Creation Kit and version you want. Creation Kit choices are separate and optional: a game downgrade never changes its CK. Download the free CK through Steam and run it once before downgrading it. If it is missing after you select it, press any key to return to the main menu and choose again, or Esc to exit. After an operation completes or is cancelled, the interactive tool offers the same choice. For CK operations, the tool recommends a version based on the installed parent game but permits an advanced override, and backs up only the CK files being replaced rather than copying the shared game folder.

Before continuing, you must accept a warning that Steam will close. This also closes any game currently running through Steam. The tool starts Steam again when it finishes.

SteamCMD will ask for your Steam password and, if enabled, Steam Guard approval in the same window. These go directly to Valve's SteamCMD and are not saved by this tool.

The first run downloads SteamCMD from Valve. The downgrade itself can take some time because it downloads several gigabytes of game files.

## Restoring or changing version

Run `JackifyGameDowngrader.cmd` again and choose **Restore a previous downgrade** from the menu.

If you made a backup, restore puts it back. Without a backup, the tool restores the Steam settings it changed and tells you to use Steam's **Verify integrity of game files** option to download the current game again.

Restore records are stored in `%LOCALAPPDATA%\JackifyGameDowngrader\` so they survive tool updates and new ZIP extractions. If a record is missing, the tool can find compatible backup folders beside the game and ask which one to restore.

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
.\JackifyGameDowngrader.ps1 -Game fallout4 --managed-restart
.\JackifyGameDowngrader.ps1 -Game fallout4_ck -Version 1.10.162
.\JackifyGameDowngrader.ps1 -Game skyrim_se_ck -Version 1.6.1130
```

`-DryRun` still downloads the game files, but does not change the installed game or its Steam settings.

The tool does not require administrator access. Downloaded depot files are deleted after a successful downgrade. They are kept after a failure so you can retry without downloading everything again.

`--managed-restart` is for launchers such as Jackify that manage Steam themselves. Most users do not need it.
