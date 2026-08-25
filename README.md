# Jackify Game Downgrader

Downgrades supported Steam installs of Skyrim Special Edition or Fallout 4 to older, script-extender-compatible builds. Linux and Windows downloads are available. Game files come directly from Steam through Valve's SteamCMD; they are not included with this tool.

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
- Steam and the game to be closed. If either is still running, the tool asks you to close it before continuing.
- Enough free space for the depot download (around 20 GB for Skyrim).
- More free space if you choose the optional full backup. The tool shows its approximate size before starting.
- Windows 10 or 11, or Python 3.10 or newer on Linux.

The examples below downgrade Skyrim Special Edition to `1.6.1170`. Paths, sizes, usernames, timings, and progress values will differ on your computer.

## Windows walkthrough

### 1. Start the tool

Open the extracted folder and double-click `JackifyGameDowngrader.cmd`. No administrator access is required.

Choose Skyrim Special Edition by entering `2`:

```text
What would you like to do?
  1) Downgrade Fallout 4
  2) Downgrade Skyrim Special Edition
  3) Restore a previous downgrade
Pick an option [number]: 2
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
Skyrim Special Edition: 1.7.99.0 -> 1.6.1170
Game folder: D:\SteamLibrary\steamapps\common\Skyrim Special Edition
Create a full 17.2 GB backup? Recommended, but optional [Y/n]:
```

- Press `Enter` or type `y` to make the backup.
- Type `n` to continue without one and save disk space.

If selected, the backup is stored beside the game folder and is not deleted automatically:

```text
Full backup: D:\SteamLibrary\steamapps\common\Skyrim Special Edition (1.7.99.0)
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

After every requested depot is confirmed, the tool makes the optional backup, applies the downloaded files, adjusts the Steam settings, and checks the installed game version:

```text
Creating full backup...
Protected Steam account config: C:\Program Files (x86)\Steam\userdata\...\localconfig.vdf
Installing depot files...
Removed stale Creation Club content catalog: C:\Users\...\AppData\Local\Skyrim Special Edition\ContentCatalog.txt
Downgrade complete: 1.6.1170.0
Backup retained at D:\SteamLibrary\steamapps\common\Skyrim Special Edition (1.7.99.0)
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
  3) Restore a previous downgrade
Pick an option [number]: 2
```

The tool locates the game and lists the newest downgrade target first. Enter `1` for `1.6.1170`:

```text
== Skyrim Special Edition ==
Location:       /home/user/.local/share/Steam/steamapps/common/Skyrim Special Edition
Current version: 1.7.99.0

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
  Current install backed up to: /home/user/.local/share/Steam/steamapps/common/Skyrim Special Edition (1.7.99.0)
  Approximate backup size: 17.2 GB
  The backup remains until restored or deleted by you
  Steam auto-update for Skyrim Special Edition set to 'only update when launched'
  Steam manifest (appmanifest_489830.acf) set to read-only
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
== Applying downgrade ==
Backing up the current install and copying downgraded files in...
Backup saved to /home/user/.local/share/Steam/steamapps/common/Skyrim Special Edition (1.7.99.0)
Set Skyrim Special Edition to 'only update when launched' in Steam.
Set appmanifest_489830.acf to read-only so Steam can't rewrite it back.
Removed stale Creation Club content catalog (ContentCatalog.txt);
Steam regenerates it on next launch.

== Done ==
Skyrim Special Edition is now on 1.6.1170.
Before playing: launch Steam, and either use Offline Mode or avoid
clicking Update if Steam prompts for one.
```

## Restoring or changing version

Run the tool again and choose option `3`, **Restore a previous downgrade**.

If you made a backup, restore puts it back and returns the Steam settings changed by the tool to their previous values. If you skipped the backup, it restores those settings and tells you to use Steam's **Verify integrity of game files** option to download the current game again.

To change from one older version to another, run the downgrade again and select the new target. The original pre-downgrade backup is retained and remains the version used by restore.

Backups are never deleted automatically. Remove one yourself only when you are certain you no longer need it.

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
```

Dry run downloads and checks the real depot data but does not modify the game, Steam settings, app manifest, or content catalog.

## Supported versions

- Skyrim Special Edition: 1.6.1170, 1.6.640, 1.5.97
- Fallout 4: 1.10.163

## What the tool changes

Before continuing, the tool shows the game path, backup choice, and required disk space. It then:

- Downloads the selected depots through SteamCMD.
- Optionally copies the complete current game folder to a version-labelled backup beside it.
- Installs the selected depot files.
- Sets Steam to update the game only when launched.
- Marks the app manifest read-only.
- Removes stale `ContentCatalog.txt` data that can crash an older game build.
- Records the backup and prior Steam settings for restore.

Depot downloads are removed after success and retained after failure so the operation can be retried.

## Development

- `games/`: shared game and manifest definitions
- `linux/`: Python standard-library implementation
- `windows/`: Windows PowerShell 5.1 implementation
- `tests/`: dependency-free tests
- `scripts/`: release tools

Build local release files in the workspace-level `../dist/` directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -Version 0.2.0
```

## License

GPLv3. See [LICENSE](LICENSE).
