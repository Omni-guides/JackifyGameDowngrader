# Jackify Game Downgrader

Downgrades supported Steam installs of Skyrim Special Edition, Fallout 4, and their Creation Kits to older modding-compatible builds. Linux and Windows downloads are available. Files come directly from Steam through Valve's SteamCMD; they are not included with this tool.

## Quick navigation

- [Before you start](#before-you-start)
- [Windows walkthrough](#windows-walkthrough)
- [Linux walkthrough](#linux-walkthrough)
- [Restoring or changing version](#restoring-or-changing-version)
- [Other commands](#other-commands)
- [What the tool changes](#what-the-tool-changes)

## Before you start

Download the archive for your operating system from the [latest release](https://github.com/Omni-guides/JackifyGameDowngrader/releases/latest):

- `JackifyGameDowngrader-Windows-<version>.zip`
- `JackifyGameDowngrader-Linux-<version>.zip`

Extract the complete ZIP somewhere outside the game folder. Do not run the tool from inside the ZIP preview.

You will need:

- The Steam edition of the game, not GOG, Epic, or Game Pass.
- A Steam account that owns the game.
- Enough free space for the depot download (around 20 GB for Skyrim).
- More free space if you choose the optional full backup. The tool shows its approximate size before starting.
- Windows 10 or 11, or Python 3.10 or newer on Linux.

Creation Kit downgrades are separate and optional. The free Creation Kit must first be downloaded through Steam and run once. If an interactive CK selection cannot find it, acknowledge the message to return to the main menu and choose again. Choosing a game downgrade never changes or protects its Creation Kit. Bethesda supports the Creation Kits themselves on Windows; downloading their files on Linux is provided for Wine/Proton and modlist workflows.

The examples below downgrade Skyrim Special Edition to `1.6.1170`. Paths, sizes, usernames, timings, and progress values will differ on your computer.

## Windows walkthrough

### 1. Start the tool

Open the extracted folder and double-click `JackifyGameDowngrader.cmd`. No administrator access is required.

Choose Skyrim Special Edition by entering `2`:

```text
What would you like to do?
  1) Downgrade Fallout 4
  2) Downgrade Skyrim Special Edition
  3) Downgrade Fallout 4: Creation Kit
  4) Downgrade Skyrim Special Edition: Creation Kit
  5) Restore a previous downgrade
Pick an option [number]: 2
```

The tool warns that Steam will be closed later in the process. This also closes any game currently running through Steam:

```text
Steam will close before game files are changed and will restart when finished.
Any game currently running through Steam will also be closed.
Continue? [y/N]: y
```

Choose `1.6.1170` by entering `1`:

```text
Downgrade to:
  1) 1.6.1170
  2) 1.6.640
  3) 1.5.97
Pick a target version [number]: 1
```

If you enter an invalid number, the tool asks again.

### 2. Choose whether to make a backup

The tool finds the game, shows the planned version change, and offers to copy the complete game folder before changing it:

```text
Skyrim Special Edition: 1.7.104.0 -> 1.6.1170
Game folder: D:\SteamLibrary\steamapps\common\Skyrim Special Edition
Create a full 17.2 GB backup? Recommended, but optional [Y/n]:
```

- Press `Enter` or type `y` to make the backup.
- Type `n` to continue without one and save disk space.

If selected, the backup is stored beside the game folder and is not deleted automatically:

```text
Full backup: D:\SteamLibrary\steamapps\common\Skyrim Special Edition (1.7.104.0)
Backup size: approximately 17.2 GB. It remains until restored or deleted by you.
Proceed? [y/N]: y
```

Review the paths before entering `y`. Any other response cancels the downgrade.

### 3. Sign in to SteamCMD

Enter the username of the Steam account that owns the game:

```text
Steam username for SteamCMD: your-steam-name
SteamCMD handles your password and Steam Guard prompts directly.
Starting SteamCMD login...
```

SteamCMD is downloaded from Valve on first use. It then asks for your Steam password:

```text
Loading Steam API...OK
Cached credentials not found.

password:
```

Your password may not appear while you type, not even as dots or asterisks. This is normal. Type it and press `Enter`.

If your account uses Steam Guard mobile approval, check your phone:

```text
This account is protected by a Steam Guard mobile authenticator.
Please confirm the login in the Steam Mobile app on your phone.

Waiting for confirmation...
```

Approve the login and leave the window open. The waiting message comes from SteamCMD.

### 4. Wait for the depot downloads

SteamCMD downloads several large depots. The status line updates while each one is processed:

```text
Downloading depot 489831 (19 files, 4663 MB) ...
  / depot 489831: 42% (1,958/4,663 MB)
Depot download complete : "...\depot_489831" (manifest 8442952117333549665)
```

The Windows percentage is an estimate because SteamCMD writes some large files in chunks. It may speed up, slow down, or show `finalising` near the end. Do not close the window while the spinner is moving or SteamCMD is still producing output.

### 5. Let the tool apply the downgrade

After the downloads finish, the tool closes Steam, makes the optional backup, applies the downloaded files, adjusts the Steam settings, checks the installed game version, and starts Steam again:

```text
Stopping Steam...
Creating full backup...
Protected Steam account config: C:\Program Files (x86)\Steam\userdata\...\localconfig.vdf
Installing depot files...
Removed stale Creation Club content catalog: C:\Users\...\AppData\Local\Skyrim Special Edition\ContentCatalog.txt
Starting Steam...
Steam started.
Downgrade complete: 1.6.1170.0
Backup retained at D:\SteamLibrary\steamapps\common\Skyrim Special Edition (1.7.104.0)
```

When you see `Downgrade complete`, press a key to close the window.

## Linux walkthrough

### 1. Start the tool

Open a terminal in the extracted folder and run:

```sh
./jackify-game-downgrader
```

If Linux says the file is not executable, run this once and try again:

```sh
chmod +x jackify-game-downgrader
```

Choose Skyrim Special Edition by entering `2`:

```text
What would you like to do?
  1) Downgrade Fallout 4
  2) Downgrade Skyrim Special Edition
  3) Downgrade Fallout 4: Creation Kit
  4) Downgrade Skyrim Special Edition: Creation Kit
  5) Restore a previous downgrade
Pick an option [number]: 2
```

The tool warns that Steam will be closed later in the process. This also closes any game currently running through Steam:

```text
Steam will close before game files are changed and will restart when finished.
Any game currently running through Steam will also be closed.
Continue? [y/N]: y
```

The tool locates the game and lists the newest downgrade target first. Enter `1` for `1.6.1170`:

```text
== Skyrim Special Edition ==
Location:       /home/user/.local/share/Steam/steamapps/common/Skyrim Special Edition
Current version: 1.7.104.0

Downgrade to:
  1) 1.6.1170
  2) 1.6.640
  3) 1.5.97
Pick a target version [number]: 1
```

If you enter an invalid number, the tool asks again.

### 2. Choose whether to make a backup

```text
Create a full game backup? Recommended, but optional if space is limited [Y/n]:
```

- Press `Enter` or type `y` to make the backup.
- Type `n` to continue without one and save disk space.

The plan shows exactly what will happen:

```text
== Plan ==
Downgrade Skyrim Special Edition to 1.6.1170:
  Game folder: /home/user/.local/share/Steam/steamapps/common/Skyrim Special Edition
  Current install backed up to: /home/user/.local/share/Steam/steamapps/common/Skyrim Special Edition (1.7.104.0)
  Approximate backup size: 17.2 GB
  The backup remains until restored or deleted by you
  Steam auto-update for Skyrim Special Edition set to 'only update when launched'
Proceed? [y/N]: y
```

Review the paths before entering `y`. Any other response cancels the downgrade.

### 3. Sign in to SteamCMD

```text
== Steam login & download ==
Your password/Steam Guard code goes straight to steamcmd (Valve's own tool).
This tool never sees, stores, or logs it.
Steam username (for steamcmd login): your-steam-name
```

SteamCMD asks for your password. Your typing may be invisible; type the password and press `Enter`. If prompted for Steam Guard approval, approve the login on your phone and leave the terminal open.

### 4. Wait for the depot downloads

```text
Downloading depot 489831 (19 files, 4663 MB) ...
  / depot 489831: 42% (1,958/4,663 MB)
  (depot 489831 took 95s)
```

The percentage is estimated from the files SteamCMD writes to disk. It may show `finalising` while SteamCMD expands and checks a depot.

### 5. Let the tool apply the downgrade

```text
Stopping Steam...

== Applying downgrade ==
Backing up the current install and copying downgraded files in...
Backup saved to /home/user/.local/share/Steam/steamapps/common/Skyrim Special Edition (1.7.104.0)
Set Skyrim Special Edition to 'only update when launched' in Steam.
Removed stale Creation Club content catalog (ContentCatalog.txt);
Steam regenerates it on next launch.
Starting Steam...
Steam started.

== Done ==
Skyrim Special Edition is now on 1.6.1170.
Do not launch vanilla Skyrim Special Edition through Steam or click Update.
Launch your modded setup through its MO2 shortcut instead.
```

On Linux, Steam may make its game manifest writable again after an MO2/Proton session. Preventing that reliably requires elevated filesystem permissions, so the Linux version does not rely on the manifest remaining read-only.

## Restoring or changing version

Run the tool again and choose option `5`, **Restore a previous downgrade**.

If you made a backup, restore puts it back and returns the Steam settings changed by the tool to their previous values. If you skipped the backup, it restores those settings and tells you to use Steam's **Verify integrity of game files** option to download the current game again.

Restore records are kept in your user profile so they survive tool updates and new ZIP extractions. If a record is missing, the tool lists compatible backup folders beside the game and asks which one to restore.

To change from one older version to another, run the downgrade again and select the new target. The original pre-downgrade backup is retained and remains the version used by restore.

Backups are never deleted automatically. Remove one yourself only when you are certain you no longer need it.

Creation Kit restore is tracked separately from game restore. A CK downgrade backs up only the CK files it replaces under the tool's persistent state directory; it does not duplicate, restore, or remove the parent game as a unit. If you skip that small backup, restore returns the Steam settings and directs you to verify the Creation Kit through Steam.

## Other commands

Most users only need the interactive menu. Advanced commands are also available.

Windows PowerShell:

```powershell
.\JackifyGameDowngrader.ps1 -Game fallout4
.\JackifyGameDowngrader.ps1 -Game fallout4 -Version 1.10.163
.\JackifyGameDowngrader.ps1 -DryRun                         # download and preview only
.\JackifyGameDowngrader.ps1 -Game fallout4 -NoBackup
.\JackifyGameDowngrader.ps1 -ListGames
.\JackifyGameDowngrader.ps1 -Game skyrim_se -ListVersions
.\JackifyGameDowngrader.ps1 -Game fallout4 -Restore
.\JackifyGameDowngrader.ps1 -Game fallout4 --managed-restart
.\JackifyGameDowngrader.ps1 -Game fallout4_ck -Version 1.10.162
.\JackifyGameDowngrader.ps1 -Game skyrim_se_ck -Version 1.6.1130
```

Linux:

```sh
./jackify-game-downgrader --game fallout4
./jackify-game-downgrader --game fallout4 --version 1.10.163
./jackify-game-downgrader --dry-run                         # download and preview only
./jackify-game-downgrader --game fallout4 --no-backup
./jackify-game-downgrader list-games
./jackify-game-downgrader list-versions --game skyrim_se
./jackify-game-downgrader restore --game fallout4
./jackify-game-downgrader --game fallout4 --managed-restart
./jackify-game-downgrader --game fallout4_ck --version 1.10.162
./jackify-game-downgrader --game skyrim_se_ck --version 1.6.1130
```

Dry run downloads and checks the real depot data but does not modify the game, Steam settings, app manifest, or content catalog.

`--managed-restart` is for launchers such as Jackify that close and restart Steam themselves. Most users do not need it.

## Supported versions

- Skyrim Special Edition: 1.6.1170, 1.6.640, 1.5.97
- Fallout 4: 1.10.163
- Skyrim Special Edition Creation Kit: 1.6.1130 (recommended for game 1.6.1170), 1.6.438 (recommended for game 1.6.640)
- Fallout 4 Creation Kit: 1.10.162 (recommended for game 1.10.163)

Skyrim 1.5.97's matching CK 1.5.73 is not available as a Steam depot and requires a separate binary patcher, so it is not an automatic target. The tool shows the installed parent-game version, marks its matching CK target as recommended, and warns before an interactive mismatched selection. An explicit command-line version remains available for advanced authoring setups.

## What the tool changes

Before continuing, the tool shows the game path, backup choice, and required disk space. It then:

- Downloads the selected depots through SteamCMD.
- Closes Steam before changing any files and starts it again afterward.
- Optionally copies the complete current game folder to a version-labelled backup beside it.
- Installs the selected depot files.
- Sets Steam to update the game only when launched.
- On Windows, marks the app manifest read-only.
- Removes stale `ContentCatalog.txt` data that can crash an older game build.
- Records the backup and prior Steam settings for restore.

For a Creation Kit operation, these changes apply to the CK app ID and manifest only. The tool uses a file-level CK backup because Steam installs each CK inside its parent game's directory.

On Linux, do not launch the vanilla game through Steam or accept an update. Launch the modded setup through its MO2 shortcut instead.

Depot downloads are removed after success and retained after failure so the operation can be retried.

## Development

- `games/`: shared game and manifest definitions
- `linux/`: Python standard-library implementation
- `windows/`: Windows PowerShell 5.1 implementation
- `tests/`: dependency-free tests
- `scripts/`: release tools

Build local release files in the workspace-level `../dist/` directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -Version 0.2.5
```

## License

GPLv3. See [LICENSE](LICENSE).
