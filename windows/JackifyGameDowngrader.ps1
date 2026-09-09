[CmdletBinding()]
param(
    [string]$Game,
    [string]$Version,
    [switch]$Restore,
    [switch]$DryRun,
    [switch]$NoBackup,
    [Alias('managed-restart')]
    [switch]$ManagedRestart,
    [switch]$ListGames,
    [switch]$ListVersions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$DataRoot = Join-Path $ScriptRoot 'data'
$StateRoot = if ($env:JGD_STATE_DIR) { $env:JGD_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'JackifyGameDowngrader' }
$SteamCmdUrl = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'
$BackupStateName = '.jackify-game-downgrader.json'

function Get-GamesPath {
    $local = Join-Path $ScriptRoot 'games'
    if (Test-Path -LiteralPath $local -PathType Container) { return $local }
    return (Join-Path (Split-Path -Parent $ScriptRoot) 'games')
}

function Get-GameDefinitions {
    $path = Get-GamesPath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Game definitions were not found at $path"
    }
    $result = [ordered]@{}
    $items = foreach ($file in Get-ChildItem -LiteralPath $path -Filter '*.json' -File) {
        $definition = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        [pscustomobject]@{ Key = $file.BaseName; Definition = $definition; IsComponent = [int](Test-CreationKit $definition) }
    }
    foreach ($item in @($items | Sort-Object IsComponent, Key)) {
        $result[$item.Key] = $item.Definition
    }
    return $result
}

function Test-CreationKit($Definition) {
    return ($Definition.PSObject.Properties['component'] -and $Definition.component -eq 'creation_kit')
}

function Get-ParentGameVersion([string[]]$Libraries, $Definition) {
    if (-not (Test-CreationKit $Definition)) { return $null }
    $parent = [pscustomobject]@{ appid = $Definition.parent_appid; main_exe = $Definition.parent_main_exe }
    $install = Find-GameInstall $Libraries $parent
    if ($install) { return $install.Version }
    return $null
}

function Select-Game([Collections.IDictionary]$Games, [string]$Key) {
    if ($Key) {
        if (-not $Games.Contains($Key)) { throw "Unknown game '$Key'." }
        return $Key
    }
    Write-Host 'Which game?'
    $keys = @($Games.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        Write-Host "  $($i + 1)) $($Games[$keys[$i]].name)"
    }
    while ($true) {
        $choice = 0
        if ([int]::TryParse((Read-Host 'Pick a game [number]'), [ref]$choice) -and
            $choice -ge 1 -and $choice -le $keys.Count) { return $keys[$choice - 1] }
        Write-Host "Enter a number from 1 to $($keys.Count)." -ForegroundColor Yellow
    }
}

function Select-InteractiveAction([Collections.IDictionary]$Games) {
    Write-Host 'What would you like to do?'
    $keys = @($Games.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        Write-Host "  $($i + 1)) Downgrade $($Games[$keys[$i]].name)"
    }
    $restoreChoice = $keys.Count + 1
    $exitChoice = $keys.Count + 2
    Write-Host "  $restoreChoice) Restore a previous downgrade"
    Write-Host "  $exitChoice) Exit"
    while ($true) {
        $choice = 0
        if ([int]::TryParse((Read-Host 'Pick an option [number]'), [ref]$choice) -and
            $choice -ge 1 -and $choice -le $exitChoice) {
            if ($choice -eq $restoreChoice) { return [pscustomobject]@{ Action = 'restore'; Game = $null } }
            if ($choice -eq $exitChoice) { return [pscustomobject]@{ Action = 'exit'; Game = $null } }
            return [pscustomobject]@{ Action = 'downgrade'; Game = $keys[$choice - 1] }
        }
        Write-Host "Enter a number from 1 to $exitChoice." -ForegroundColor Yellow
    }
}

function Select-RestoreGame([Collections.IDictionary]$Games) {
    $available = [ordered]@{}
    $steamRoots = @(Get-SteamRoots)
    $libraries = @(Get-LibraryRoots $steamRoots)
    foreach ($key in $Games.Keys) {
        $install = Find-GameInstall $libraries $Games[$key]
        if ((Load-State $key) -or (Get-BackupCandidates $install $Games[$key])) {
            $available[$key] = $Games[$key]
        }
    }
    if ($available.Count -eq 0) { return $null }
    if ($available.Count -eq 1) { return @($available.Keys)[0] }
    Write-Host 'Restore which game?'
    return (Select-Game $available '')
}

function Select-Version($Definition, [string]$Requested, [string]$ParentVersion = '') {
    $versions = @($Definition.versions.PSObject.Properties.Name | Sort-Object { [version]$_ } -Descending)
    if ($Requested) {
        if ($versions -notcontains $Requested) { throw "Unknown version '$Requested'." }
        return $Requested
    }
    Write-Host 'Downgrade to:'
    for ($i = 0; $i -lt $versions.Count; $i++) {
        $entry = $Definition.versions.PSObject.Properties[$versions[$i]].Value
        $recommended = $false
        if ($ParentVersion -and $entry.PSObject.Properties['recommended_for']) {
            foreach ($item in @($entry.recommended_for)) {
                if ($ParentVersion.StartsWith([string]$item, [StringComparison]::OrdinalIgnoreCase)) { $recommended = $true }
            }
        }
        $suffix = if ($recommended) { ' [recommended]' } elseif ($entry.PSObject.Properties['note']) { " - $($entry.note)" } else { '' }
        Write-Host "  $($i + 1)) $($versions[$i])$suffix"
    }
    while ($true) {
        $choice = 0
        if ([int]::TryParse((Read-Host 'Pick a target version [number]'), [ref]$choice) -and
            $choice -ge 1 -and $choice -le $versions.Count) { return $versions[$choice - 1] }
        Write-Host "Enter a number from 1 to $($versions.Count)." -ForegroundColor Yellow
    }
}

function Get-SteamRoots {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        if (-not (Test-Path $key)) { continue }
        $item = Get-ItemProperty $key
        foreach ($name in @('SteamPath', 'InstallPath')) {
            $property = $item.PSObject.Properties[$name]
            if ($property -and $property.Value) { $candidates.Add([string]$property.Value) }
        }
    }
    $candidates.Add("${env:ProgramFiles(x86)}\Steam")
    $candidates.Add("$env:ProgramFiles\Steam")
    $seen = @{}
    foreach ($candidate in $candidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath (Join-Path $candidate 'steam.exe'))) { continue }
        $full = [IO.Path]::GetFullPath($candidate)
        if (-not $seen.ContainsKey($full)) { $seen[$full] = $true; $full }
    }
}

function Get-VdfValues([string]$Text, [string]$Key) {
    $pattern = '"' + [regex]::Escape($Key) + '"[ \t]*"((?:\\.|[^"\\])*)"'
    foreach ($match in [regex]::Matches($Text, $pattern)) { $match.Groups[1].Value }
}

function Get-VdfValue([string]$Text, [string]$Key) {
    $values = @(Get-VdfValues $Text $Key | Select-Object -First 1)
    if ($values.Count) { return $values[0] }
    return $null
}

function Get-LibraryRoots([string[]]$SteamRoots) {
    $seen = @{}
    foreach ($steamRoot in $SteamRoots) {
        $candidates = @($steamRoot)
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $text = [IO.File]::ReadAllText($vdf)
            $candidates += @(Get-VdfValues $text 'path' | ForEach-Object { $_.Replace('\\', '\') })
        }
        foreach ($candidate in $candidates) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
            $full = [IO.Path]::GetFullPath($candidate)
            if (-not $seen.ContainsKey($full)) { $seen[$full] = $true; $full }
        }
    }
}

function Find-GameInstall([string[]]$Libraries, $Definition) {
    foreach ($library in $Libraries) {
        $acf = Join-Path $library "steamapps\appmanifest_$($Definition.appid).acf"
        if (-not (Test-Path -LiteralPath $acf -PathType Leaf)) { continue }
        $text = [IO.File]::ReadAllText($acf)
        $installDir = Get-VdfValue $text 'installdir'
        if (-not $installDir) { continue }
        $gamePath = Join-Path $library "steamapps\common\$installDir"
        $exe = Join-Path $gamePath $Definition.main_exe
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        return [pscustomobject]@{
            GamePath = $gamePath
            LibraryRoot = $library
            AcfPath = $acf
            BuildId = Get-VdfValue $text 'buildid'
            Version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion
        }
    }
    return $null
}

function Get-LocalConfigs([string[]]$SteamRoots) {
    foreach ($root in $SteamRoots) {
        $userdata = Join-Path $root 'userdata'
        if (-not (Test-Path -LiteralPath $userdata -PathType Container)) { continue }
        foreach ($dir in Get-ChildItem -LiteralPath $userdata -Directory) {
            $path = Join-Path $dir.FullName 'config\localconfig.vdf'
            if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
        }
    }
}

function Find-VdfBlock([string]$Text, [string]$Key) {
    $match = [regex]::Match($Text, '"' + [regex]::Escape($Key) + '"\s*\{')
    if (-not $match.Success) { return $null }
    $start = $match.Index + $match.Length
    $depth = 1
    for ($i = $start; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '{') { $depth++ }
        elseif ($Text[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) { return @{ Start = $start; End = $i } }
        }
    }
    return $null
}

function Set-VdfUpdateBehavior([string]$Path, [string]$AppId, [AllowNull()][string]$Value) {
    $text = [IO.File]::ReadAllText($Path)
    $block = Find-VdfBlock $text $AppId
    if (-not $block) { return $null }
    $body = $text.Substring($block.Start, $block.End - $block.Start)
    $pattern = '"AutoUpdateBehavior"\s+"(\d+)"'
    $match = [regex]::Match($body, $pattern)
    $priorPresent = $match.Success
    $prior = if ($priorPresent) { $match.Groups[1].Value } else { $null }
    if ([string]::IsNullOrEmpty($Value)) {
        $newBody = [regex]::Replace($body, '\r?\n[ \t]*"AutoUpdateBehavior"\s+"\d+"', '', 1)
    }
    elseif ($match.Success) {
        $newBody = [regex]::Replace($body, $pattern, '"AutoUpdateBehavior"' + "`t`t" + '"' + $Value + '"', 1)
    }
    else {
        $newBody = $body + "`r`n`t`t`t" + '"AutoUpdateBehavior"' + "`t`t" + '"' + $Value + '"'
    }
    if ($newBody -ne $body) {
        $updated = $text.Substring(0, $block.Start) + $newBody + $text.Substring($block.End)
        [IO.File]::WriteAllText($Path, $updated, [Text.UTF8Encoding]::new($false))
    }
    return [pscustomobject]@{ Path = $Path; PriorPresent = $priorPresent; PriorValue = $prior }
}

function Confirm-SteamRestartWarning {
    Write-Host ''
    Write-Host 'Steam will close before game files are changed and will restart when finished.' -ForegroundColor Yellow
    Write-Host 'Any game currently running through Steam will also be closed.' -ForegroundColor Yellow
    return (Confirm-Action 'Continue?')
}

function Stop-SteamAndGame([string]$GameProcess) {
    Write-Host 'Stopping Steam...'
    $steam = Get-Process -Name steam -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($steam -and $steam.Path) {
        [void](Start-Process -FilePath $steam.Path -ArgumentList '-shutdown' -PassThru)
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ((Get-Process -Name steam -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
    }
    Get-Process -Name steam -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process -Name $GameProcess -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        throw 'Steam could not be closed. Close it manually and try again.'
    }
}

function Start-SteamAgain([string[]]$SteamRoots, [bool]$WasRunning) {
    if (-not $WasRunning) { return }
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) { return }
    $exe = $SteamRoots | ForEach-Object { Join-Path $_ 'steam.exe' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $exe) {
        Write-Host 'Steam could not be restarted automatically. Please start it manually.' -ForegroundColor Yellow
        return
    }
    Write-Host 'Starting Steam...'
    try {
        [void](Start-Process -FilePath $exe)
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Get-Process -Name steam -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 1
        }
        if (Get-Process -Name steam -ErrorAction SilentlyContinue) { Write-Host 'Steam started.' }
        else { Write-Host 'Steam could not be restarted automatically. Please start it manually.' -ForegroundColor Yellow }
    }
    catch { Write-Host 'Steam could not be restarted automatically. Please start it manually.' -ForegroundColor Yellow }
}

function Test-DirectoryWrite([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Directory not found: $Path" }
    $probe = Join-Path $Path ('.jgd-write-test-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, ''); Remove-Item -LiteralPath $probe -Force }
    catch { throw "No write access to $Path" }
}

function Test-FileWrite([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $stream.Dispose()
    }
    catch { throw "No write access to $Path" }
}

function Test-FileAttributeWrite([string]$Path) {
    try {
        $attributes = [IO.File]::GetAttributes($Path)
        [IO.File]::SetAttributes($Path, $attributes)
    }
    catch { throw "Cannot change file attributes on $Path" }
}

function Get-DirectorySize([string]$Path) {
    $total = [int64]0
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue) { $total += $file.Length }
    return $total
}

function Read-SteamCmdLog([string]$Path) {
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Write-SteamCmdProgress([string]$Text) {
    $width = [math]::Max(100, $Text.Length)
    [Console]::Write("`r{0}`r", $Text.PadRight($width))
}

function Assert-SteamCmdDownloads([string]$LogPath, [int]$LogOffset, $VersionEntry) {
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { throw 'SteamCMD did not create its console log.' }
    $log = Read-SteamCmdLog $LogPath
    $currentRun = if ($log.Length -gt $LogOffset) { $log.Substring($LogOffset) } else { '' }
    foreach ($manifest in $VersionEntry.manifests.PSObject.Properties) {
        $pattern = 'Depot download complete.*\(manifest ' + [regex]::Escape([string]$manifest.Value) + '\)'
        if ($currentRun -notmatch $pattern) {
            throw "SteamCMD did not confirm depot $($manifest.Name) manifest $($manifest.Value)."
        }
    }
}

function Wait-SteamCmdWithProgress($Process, [string]$SteamCmdDir, [string]$AppId, [int]$LogOffset) {
    $logPath = Join-Path $SteamCmdDir 'logs\console_log.txt'
    $depotId = $null
    $totalMb = 0
    $spinner = @('|', '/', '-', '\')
    $frame = 0
    $estimatedMb = 0.0
    $lastActualMb = 0.0
    $rateMbPerSecond = 20.0
    $lastGrowthAt = [DateTime]::UtcNow
    $lastEstimateAt = $lastGrowthAt
    try {
        while (-not $Process.HasExited) {
            $Process.Refresh()
            $frame++
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                try { $log = Read-SteamCmdLog $logPath }
                catch [IO.IOException] { $log = $null }
                if ($log.Length -gt $LogOffset) {
                    $newLog = $log.Substring($LogOffset)
                    $LogOffset = $log.Length
                    $events = 'Downloading depot (\d+) \(\d+ files?, ([\d,]+) MB\)|Depot download complete'
                    foreach ($match in [regex]::Matches($newLog, $events)) {
                        if ($match.Groups[1].Success) {
                            $depotId = $match.Groups[1].Value
                            $totalMb = [int64]$match.Groups[2].Value.Replace(',', '')
                            $estimatedMb = 0.0
                            $lastActualMb = 0.0
                            $rateMbPerSecond = 20.0
                            $lastGrowthAt = [DateTime]::UtcNow
                            $lastEstimateAt = $lastGrowthAt
                        }
                        else {
                            Write-SteamCmdProgress ''
                            $depotId = $null
                            $totalMb = 0
                        }
                    }
                }
            }
            if ($depotId -and $totalMb -gt 0) {
                $depotPath = Join-Path $SteamCmdDir "steamapps\content\app_$AppId\depot_$depotId"
                $actualMb = (Get-DirectorySize $depotPath) / 1000000
                $now = [DateTime]::UtcNow
                if ($actualMb -gt $lastActualMb) {
                    $growthSeconds = ($now - $lastGrowthAt).TotalSeconds
                    if ($lastActualMb -gt 0 -and $growthSeconds -gt 0) {
                        $observedRate = ($actualMb - $lastActualMb) / $growthSeconds
                        if ($observedRate -gt 0) { $rateMbPerSecond = $observedRate }
                    }
                    $lastActualMb = $actualMb
                    $lastGrowthAt = $now
                }
                $estimatedMb += $rateMbPerSecond * ($now - $lastEstimateAt).TotalSeconds
                $estimatedMb = [math]::Max($estimatedMb, $actualMb)
                $lastEstimateAt = $now
                $shownMb = [math]::Min($estimatedMb, $totalMb * 0.99)
                if ($actualMb -ge $totalMb) { $shownMb = $totalMb }
                $percent = [math]::Floor($shownMb / $totalMb * 100)
                $suffix = if ($actualMb -ge $totalMb) { ', finalising' } else { '' }
                Write-SteamCmdProgress ("  {0} depot {1}: {2}% ({3:N0}/{4:N0} MB{5})" -f $spinner[$frame % $spinner.Count], $depotId, $percent, $shownMb, $totalMb, $suffix)
            }
            Start-Sleep -Milliseconds 500
        }
        $Process.WaitForExit()
    }
    finally {
        Write-SteamCmdProgress ''
    }
}

function Assert-FreeSpace([string]$Path, [int64]$Required, [string]$Label) {
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    $free = ([IO.DriveInfo]::new($root)).AvailableFreeSpace
    if ($free -lt $Required) {
        $needGb = [math]::Ceiling($Required / 1GB)
        $freeGb = [math]::Floor($free / 1GB)
        throw "$Label needs about $needGb GB free on $root; $freeGb GB is available."
    }
}

function Get-BackupPath([string]$GamePath, [string]$CurrentVersion, [string]$BuildId) {
    $label = if ($CurrentVersion) { $CurrentVersion } elseif ($BuildId) { "build $BuildId" } else { 'backup' }
    $parent = Split-Path -Parent $GamePath
    $name = Split-Path -Leaf $GamePath
    $candidate = Join-Path $parent "$name ($label)"
    $number = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $parent "$name ($label) ($number)"
        $number++
    }
    return $candidate
}

function Copy-Tree([string]$Source, [string]$Destination) {
    $sourceFull = [IO.Path]::GetFullPath($Source).TrimEnd('\') + '\'
    [void](New-Item -ItemType Directory -Path $Destination -Force)
    foreach ($item in Get-ChildItem -LiteralPath $Source -Recurse -Force) {
        $relative = $item.FullName.Substring($sourceFull.Length)
        $target = Join-Path $Destination $relative
        if ($item.PSIsContainer) { [void](New-Item -ItemType Directory -Path $target -Force) }
        else {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

function New-FullBackup([string]$Source, [string]$Destination) {
    $staging = Join-Path (Split-Path -Parent $Destination) ('.jgd-backup-staging-' + [guid]::NewGuid().ToString('N'))
    try {
        Copy-Tree $Source $staging
        [IO.Directory]::Move($staging, $Destination)
    }
    finally {
        if (Test-Path -LiteralPath $staging -PathType Container) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

function Get-UsableFullBackupPath($State) {
    if ($null -eq $State) { return $null }
    $path = [string]$State.backup_path
    if (-not $path) { return $null }
    if (Test-Path -LiteralPath $path -PathType Container) { return $path }
    if ($State -is [Collections.IDictionary]) { $State['backup_path'] = $null }
    else { $State.backup_path = $null }
    return $null
}

function Reset-GameFromBackup([string]$GamePath, [string]$BackupPath) {
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) { throw "Backup not found: $BackupPath" }
    Remove-Item -LiteralPath $GamePath -Recurse -Force
    try {
        Copy-Tree $BackupPath $GamePath
        $marker = Join-Path $GamePath $BackupStateName
        if (Test-Path -LiteralPath $marker -PathType Leaf) { Remove-Item -LiteralPath $marker -Force }
    }
    catch {
        Write-Host "Reset failed. The original backup remains intact at $BackupPath" -ForegroundColor Red
        throw
    }
}

function Get-DepotFiles([string]$ContentPath) {
    foreach ($depot in Get-ChildItem -LiteralPath $ContentPath -Directory | Sort-Object Name) {
        $root = $depot.FullName.TrimEnd('\') + '\'
        foreach ($file in Get-ChildItem -LiteralPath $depot.FullName -File -Recurse -Force) {
            [pscustomobject]@{ Source = $file.FullName; Relative = $file.FullName.Substring($root.Length) }
        }
    }
}

function Install-DepotFiles([string]$ContentPath, [string]$GamePath) {
    foreach ($file in Get-DepotFiles $ContentPath) {
        $target = Join-Path $GamePath $file.Relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
        Copy-Item -LiteralPath $file.Source -Destination $target -Force
    }
}

function Get-ComponentBackupPath([string]$GameKey) {
    return (Join-Path $StateRoot "$GameKey\file-backup")
}

function Get-ComponentRecords($State) {
    if ($null -eq $State) { return }
    $value = $null
    if ($State -is [Collections.IDictionary]) {
        if ($State.Contains('component_backup')) { $value = $State['component_backup'] }
    }
    elseif ($State.PSObject.Properties['component_backup']) {
        $value = $State.component_backup
    }
    foreach ($item in @($value)) {
        if ($null -ne $item) { $item }
    }
}

function Backup-ComponentFiles([string]$GameKey, [string]$ContentPath, [string]$GamePath, $ExistingRecords) {
    $backupPath = Get-ComponentBackupPath $GameKey
    $stagingPath = Join-Path (Split-Path -Parent $backupPath) ('file-backup-staging-' + [guid]::NewGuid().ToString('N'))
    $records = [Collections.ArrayList]::new()
    $recorded = @{}
    foreach ($item in @($ExistingRecords)) {
        if ($null -eq $item) { continue }
        [void]$records.Add($item)
        $recorded[[string]$item.path] = $true
    }
    try {
        [void](New-Item -ItemType Directory -Path $stagingPath -Force)
        foreach ($file in Get-DepotFiles $ContentPath) {
            if ($recorded.ContainsKey($file.Relative)) { continue }
            $target = Join-Path $GamePath $file.Relative
            $existed = Test-Path -LiteralPath $target -PathType Leaf
            [void]$records.Add([pscustomobject]@{ path = $file.Relative; existed = $existed })
            $recorded[$file.Relative] = $true
            if ($existed) {
                $staged = Join-Path $stagingPath $file.Relative
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $staged) -Force)
                Copy-Item -LiteralPath $target -Destination $staged -Force
            }
        }
        [void](New-Item -ItemType Directory -Path $backupPath -Force)
        foreach ($file in Get-ChildItem -LiteralPath $stagingPath -File -Recurse -Force) {
            $relative = $file.FullName.Substring($stagingPath.Length).TrimStart([char[]]'\/')
            $saved = Join-Path $backupPath $relative
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force)
            Copy-Item -LiteralPath $file.FullName -Destination $saved -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingPath -PathType Container) { Remove-Item -LiteralPath $stagingPath -Recurse -Force }
    }
    return @($records)
}

function Restore-ComponentFiles([string]$GameKey, [string]$GamePath, $Records) {
    $backupPath = Get-ComponentBackupPath $GameKey
    foreach ($item in @($Records)) {
        $target = Join-Path $GamePath ([string]$item.path)
        if ([bool]$item.existed) {
            $saved = Join-Path $backupPath ([string]$item.path)
            if (-not (Test-Path -LiteralPath $saved -PathType Leaf)) { throw "Component backup file is missing: $saved" }
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            Copy-Item -LiteralPath $saved -Destination $target -Force
        }
        elseif (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
    }
    if (Test-Path -LiteralPath $backupPath -PathType Container) { Remove-Item -LiteralPath $backupPath -Recurse -Force }
}

function Get-DepotPreview([string]$ContentPath, [string]$GamePath) {
    $overwrite = 0
    $new = 0
    foreach ($file in Get-DepotFiles $ContentPath) {
        if (Test-Path -LiteralPath (Join-Path $GamePath $file.Relative) -PathType Leaf) { $overwrite++ } else { $new++ }
    }
    return [pscustomobject]@{ Overwrite = $overwrite; New = $new }
}

function Get-SteamCmd {
    $dir = Join-Path $DataRoot 'steamcmd'
    $exe = Join-Path $dir 'steamcmd.exe'
    $ready = Join-Path $dir '.ready'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
        $zip = Join-Path $dir 'steamcmd.zip'
        Write-Host "Downloading SteamCMD from $SteamCmdUrl"
        Invoke-WebRequest -Uri $SteamCmdUrl -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
        Remove-Item -LiteralPath $zip -Force
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'SteamCMD extraction failed.' }
    }
    if (-not (Test-Path -LiteralPath $ready -PathType Leaf)) {
        $running = @(Get-Process steamcmd -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
        if ($running) { throw 'SteamCMD is still running from an earlier attempt. Close it in Task Manager, then run the downgrader again.' }
        Write-Host 'Installing the SteamCMD first-run update...'
        [void](Start-Process -FilePath $exe -ArgumentList '+quit' -NoNewWindow -PassThru)
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        do {
            $running = @(Get-Process steamcmd -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
            if (-not $running) { break }
            Start-Sleep -Seconds 1
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($running) { throw 'SteamCMD setup did not finish within five minutes. Close steamcmd.exe in Task Manager and try again.' }
        [IO.File]::WriteAllText($ready, '')
        Write-Host 'SteamCMD setup complete.'
    }
    return $exe
}

function Download-Depots([string]$Username, $Definition, $VersionEntry) {
    $exe = Get-SteamCmd
    Write-Host 'Starting SteamCMD login...'
    $arguments = @('+login', $Username)
    foreach ($manifest in $VersionEntry.manifests.PSObject.Properties) {
        $arguments += @('+download_depot', [string]$Definition.appid, $manifest.Name, [string]$manifest.Value)
    }
    $arguments += '+quit'
    $logPath = Join-Path (Split-Path -Parent $exe) 'logs\console_log.txt'
    $logOffset = if (Test-Path -LiteralPath $logPath -PathType Leaf) { (Read-SteamCmdLog $logPath).Length } else { 0 }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru
    Wait-SteamCmdWithProgress $process (Split-Path -Parent $exe) ([string]$Definition.appid) $logOffset
    Assert-SteamCmdDownloads $logPath $logOffset $VersionEntry
    $appPath = Join-Path (Split-Path -Parent $exe) "steamapps\content\app_$($Definition.appid)"
    if (-not (Test-Path -LiteralPath $appPath -PathType Container)) {
        $match = Get-ChildItem -LiteralPath (Split-Path -Parent $exe) -Directory -Recurse -Filter "app_$($Definition.appid)" | Select-Object -First 1
        if (-not $match) { throw 'SteamCMD depot output was not found.' }
        $appPath = $match.FullName
    }
    foreach ($manifest in $VersionEntry.manifests.PSObject.Properties) {
        if (-not (Test-Path -LiteralPath (Join-Path $appPath "depot_$($manifest.Name)") -PathType Container)) {
            throw "Depot $($manifest.Name) was not downloaded."
        }
    }
    return $appPath
}

function Set-ManifestReadOnly([string]$Path) {
    $attributes = [IO.File]::GetAttributes($Path)
    $wasReadOnly = (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0)
    [IO.File]::SetAttributes($Path, ($attributes -bor [IO.FileAttributes]::ReadOnly))
    return $wasReadOnly
}

function Restore-ManifestAttribute([string]$Path, [bool]$WasReadOnly) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $attributes = [IO.File]::GetAttributes($Path)
    if ($WasReadOnly) { $attributes = $attributes -bor [IO.FileAttributes]::ReadOnly }
    else { $attributes = $attributes -band (-bnot [IO.FileAttributes]::ReadOnly) }
    [IO.File]::SetAttributes($Path, $attributes)
}

function Get-ContentCatalogPath($Definition) {
    if (-not $Definition.PSObject.Properties['localappdata_dir']) { return $null }
    return (Join-Path $env:LOCALAPPDATA "$($Definition.localappdata_dir)\ContentCatalog.txt")
}

function Remove-ContentCatalog($Definition) {
    $path = Get-ContentCatalogPath $Definition
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "Removed stale Creation Club content catalog: $path"
    }
}

function Get-StatePath([string]$GameKey) { return (Join-Path $StateRoot "$GameKey\state.json") }

function Save-State([string]$GameKey, $State) {
    $path = Get-StatePath $GameKey
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
    [IO.File]::WriteAllText($path, ($State | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Load-State([string]$GameKey) {
    $path = Get-StatePath $GameKey
    $legacy = Join-Path $DataRoot "$GameKey\state.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -and (Test-Path -LiteralPath $legacy -PathType Leaf)) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        Move-Item -LiteralPath $legacy -Destination $path
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return [IO.File]::ReadAllText($path) | ConvertFrom-Json
}

function Get-BackupCandidates($Install, $Definition) {
    if (Test-CreationKit $Definition) { return @() }
    if (-not $Install) { return @() }
    $parent = Split-Path -Parent $Install.GamePath
    $prefix = (Split-Path -Leaf $Install.GamePath) + ' ('
    return @(Get-ChildItem -LiteralPath $parent -Directory | Where-Object {
        $_.Name.StartsWith($prefix) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName $Definition.main_exe) -PathType Leaf)
    } | Sort-Object Name)
}

function Recover-State([string]$GameKey, $Definition, [string[]]$SteamRoots) {
    if (Test-CreationKit $Definition) { return $null }
    $install = Find-GameInstall @(Get-LibraryRoots $SteamRoots) $Definition
    $backups = @(Get-BackupCandidates $install $Definition)
    if (-not $backups) { return $null }
    Write-Host "Found $($backups.Count) backup folder(s) beside $($Definition.name):"
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $backups[$i].FullName $Definition.main_exe)).FileVersion
        Write-Host "  $($i + 1)) $($backups[$i].Name) [$version]"
    }
    while ($true) {
        $answer = (Read-Host 'Choose a backup to restore, or press Enter to cancel').Trim()
        if (-not $answer) { return $null }
        $choice = 0
        if ([int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $backups.Count) { break }
        Write-Host "Enter a number from 1 to $($backups.Count)." -ForegroundColor Yellow
    }
    $backup = $backups[$choice - 1].FullName
    $marker = Join-Path $backup $BackupStateName
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $state = [IO.File]::ReadAllText($marker) | ConvertFrom-Json
        $state.game_path = $install.GamePath
        $state.backup_path = $backup
    }
    else {
        $state = [ordered]@{
            game_path = $install.GamePath
            backup_path = $backup
            version = $install.Version
            prior_version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $backup $Definition.main_exe)).FileVersion
            prior_buildid = $null
            acf_path = $install.AcfPath
            acf_was_readonly = $false
            localconfigs = @()
            timestamp = 'recovered from backup folder'
            recovered = $true
        }
    }
    Save-State $GameKey $state
    return (Load-State $GameKey)
}

function Confirm-Action([string]$Prompt) { return ((Read-Host "$Prompt [y/N]").Trim().ToLowerInvariant() -eq 'y') }

function Confirm-DefaultYes([string]$Prompt) {
    $answer = (Read-Host "$Prompt [Y/n]").Trim().ToLowerInvariant()
    return ($answer -eq '' -or $answer -eq 'y' -or $answer -eq 'yes')
}

function Wait-ForMainMenu {
    Write-Host 'Press any key to return to the main menu, or Esc to exit.' -ForegroundColor Cyan
    $key = [Console]::ReadKey($true)
    return ($key.Key -ne [ConsoleKey]::Escape)
}

function Invoke-Restore([string]$GameKey, $Definition, [string[]]$SteamRoots) {
    $state = Load-State $GameKey
    if (-not $state) { $state = Recover-State $GameKey $Definition $SteamRoots }
    if (-not $state) { throw "No downgrade state or backup folder was found for $($Definition.name)." }
    if (-not $ManagedRestart -and -not (Confirm-SteamRestartWarning)) { Write-Host 'Aborted.'; return }
    Write-Host "Game folder: $($state.game_path)"
    $savedComponentRecords = @(Get-ComponentRecords $state)
    if ((Test-CreationKit $Definition) -and $savedComponentRecords.Count -gt 0) { Write-Host 'Backup:      Creation Kit files only; the parent game is untouched' }
    elseif ($state.backup_path) { Write-Host "Backup:      $($state.backup_path)" }
    else { Write-Host 'Backup:      none; Steam verification will be required' }
    if (-not (Confirm-Action 'Restore this downgrade?')) { Write-Host 'Aborted.'; return }
    $gameProcess = [IO.Path]::GetFileNameWithoutExtension($Definition.main_exe)
    $steamWasRunning = $false
    if (-not $ManagedRestart) {
        $steamWasRunning = [bool](Get-Process -Name steam -ErrorAction SilentlyContinue)
        try { Stop-SteamAndGame $gameProcess }
        catch { Start-SteamAgain $SteamRoots $steamWasRunning; throw }
    }
    $gamePath = [string]$state.game_path
    $recordedBackupPath = [string]$state.backup_path
    $backupPath = if (Test-CreationKit $Definition) { $recordedBackupPath } else { Get-UsableFullBackupPath $state }
    if ($recordedBackupPath -and -not $backupPath) {
        Write-Host "The recorded backup is missing: $recordedBackupPath" -ForegroundColor Yellow
        Write-Host 'Steam settings will still be restored; verify the game through Steam to recover its files.' -ForegroundColor Yellow
    }
    try {
        $componentRecords = @(Get-ComponentRecords $state)
        if ((Test-CreationKit $Definition) -and $componentRecords.Count -gt 0) {
            Restore-ComponentFiles $GameKey $gamePath $componentRecords
        }
        elseif ($backupPath) {
            if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) { throw "Backup not found: $backupPath" }
            $temporary = "$gamePath.jgd-restore-$([guid]::NewGuid().ToString('N'))"
            [IO.Directory]::Move($gamePath, $temporary)
            try { [IO.Directory]::Move($backupPath, $gamePath) }
            catch { [IO.Directory]::Move($temporary, $gamePath); throw }
            Remove-Item -LiteralPath $temporary -Recurse -Force
            $marker = Join-Path $gamePath $BackupStateName
            if (Test-Path -LiteralPath $marker -PathType Leaf) { Remove-Item -LiteralPath $marker -Force }
        }
        foreach ($config in @($state.localconfigs)) {
            if (-not (Test-Path -LiteralPath $config.path -PathType Leaf)) { continue }
            $value = if ([bool]$config.prior_present) { [string]$config.prior_value } else { $null }
            [void](Set-VdfUpdateBehavior $config.path ([string]$Definition.appid) $value)
        }
        Restore-ManifestAttribute $state.acf_path ([bool]$state.acf_was_readonly)
        Remove-ContentCatalog $Definition
        Remove-Item -LiteralPath (Get-StatePath $GameKey) -Force
    }
    finally {
        if (-not $ManagedRestart) { Start-SteamAgain $SteamRoots $steamWasRunning }
    }
    if ((Test-CreationKit $Definition) -and $componentRecords.Count -gt 0) { Write-Host 'Creation Kit restore complete.' -ForegroundColor Green }
    elseif ($backupPath) { Write-Host 'Restore complete.' -ForegroundColor Green }
    else {
        $subject = if (Test-CreationKit $Definition) { 'Creation Kit' } else { 'game' }
        Write-Host "Steam settings restored. Verify the $subject in Steam to reinstall its current build." -ForegroundColor Green
    }
    if ($state.PSObject.Properties['recovered']) {
        Write-Host 'The original Steam update setting was unavailable and was left unchanged.' -ForegroundColor Yellow
    }
}

function Invoke-Downgrade([string]$GameKey, $Definition, [string]$TargetVersion, [switch]$PreviewOnly, [switch]$NoBackup, [switch]$ReturnToMenu) {
    $steamRoots = @(Get-SteamRoots)
    if (-not $steamRoots) { throw 'Steam was not found.' }
    $libraries = @(Get-LibraryRoots $steamRoots)
    $install = Find-GameInstall $libraries $Definition
    if (-not $install) {
        if ((Test-CreationKit $Definition) -and $ReturnToMenu) {
            Write-Host "$($Definition.name) was not found in a Steam library." -ForegroundColor Yellow
            Write-Host 'Download the free Creation Kit through Steam and run it once first.'
            if (Wait-ForMainMenu) { $script:MenuReturnRequested = $true }
            else { $script:MenuExitRequested = $true }
            return
        }
        if (Test-CreationKit $Definition) { throw "$($Definition.name) was not found. Download the free Creation Kit through Steam and run it once first." }
        throw "$($Definition.name) was not found in a Steam library."
    }
    if (-not $PreviewOnly -and -not $ManagedRestart -and -not (Confirm-SteamRestartWarning)) { Write-Host 'Aborted.'; return }
    $existingState = Load-State $GameKey
    $retarget = ($null -ne $existingState)
    $retargetBackupPath = $null
    if ($retarget -and -not (Test-CreationKit $Definition)) {
        $retargetBackupPath = Get-UsableFullBackupPath $existingState
    }
    $parentVersion = Get-ParentGameVersion $libraries $Definition
    if ($parentVersion) {
        Write-Host "Installed parent game: $parentVersion" -ForegroundColor Cyan
        if ($Definition.PSObject.Properties['unavailable_matches']) {
            foreach ($item in $Definition.unavailable_matches.PSObject.Properties) {
                if ($parentVersion.StartsWith($item.Name, [StringComparison]::OrdinalIgnoreCase)) { Write-Host "Note: $($item.Value)" -ForegroundColor Yellow }
            }
        }
    }
    $target = Select-Version $Definition $TargetVersion $parentVersion
    $entry = $Definition.versions.PSObject.Properties[$target].Value
    if ((Test-CreationKit $Definition) -and $parentVersion -and $entry.PSObject.Properties['recommended_for']) {
        $matchesParent = $false
        foreach ($item in @($entry.recommended_for)) {
            if ($parentVersion.StartsWith([string]$item, [StringComparison]::OrdinalIgnoreCase)) { $matchesParent = $true }
        }
        if (-not $matchesParent) {
            Write-Host "Creation Kit $target is not the recommended version for parent game $parentVersion." -ForegroundColor Yellow
            if (-not $TargetVersion -and -not (Confirm-Action 'Continue with this advanced selection?')) { Write-Host 'Aborted.'; return }
        }
    }
    $backupPath = Get-BackupPath $install.GamePath $install.Version $install.BuildId
    $gameSize = if (Test-CreationKit $Definition) { 0 } else { Get-DirectorySize $install.GamePath }
    $createBackup = (-not $PreviewOnly -and -not $NoBackup -and -not $retarget)
    Write-Host ''
    Write-Host "$($Definition.name): $($install.Version) -> $target" -ForegroundColor Cyan
    Write-Host "Game folder: $($install.GamePath)"
    if ($PreviewOnly) { Write-Host 'Dry run: no game or Steam settings will be changed.' }
    else {
        if ($retarget -and (Test-CreationKit $Definition)) {
            $retargetRecords = @(Get-ComponentRecords $existingState)
            if ($retargetRecords.Count -gt 0) { Write-Host 'Original Creation Kit file backup retained for restore.' }
            else { Write-Host 'No original CK file backup is available; Steam verification may be required.' -ForegroundColor Yellow }
        }
        elseif ($retarget) {
            if ($retargetBackupPath) {
                Write-Host "Original backup retained at: $retargetBackupPath"
                Write-Host 'The game will be reset from that backup before applying the new target.'
            }
            else {
                Write-Host 'No original backup is available. The new target will be applied over the current files.' -ForegroundColor Yellow
                Write-Host 'Steam verification may be required if versions contain different files.' -ForegroundColor Yellow
            }
        }
        elseif (-not $retarget -and -not $NoBackup) {
            if (Test-CreationKit $Definition) {
                $createBackup = Confirm-DefaultYes 'Back up the Creation Kit files that will be replaced? Recommended'
            }
            else {
                $createBackup = Confirm-DefaultYes ("Create a full {0:N1} GB backup? Recommended, but optional" -f ($gameSize / 1GB))
            }
        }
        if ($createBackup -and (Test-CreationKit $Definition)) {
            Write-Host 'Creation Kit file backup: stored under the tool state directory'
            Write-Host 'The parent game is not backed up or changed as a unit.'
        }
        elseif ($createBackup) {
            Write-Host "Full backup: $backupPath"
            Write-Host ("Backup size: approximately {0:N1} GB. It remains until restored or deleted by you." -f ($gameSize / 1GB))
        }
        elseif (-not $retarget) {
            $subject = if (Test-CreationKit $Definition) { 'Creation Kit' } else { 'game' }
            Write-Host "Backup: skipped. Steam must redownload the $subject if you need to recover it." -ForegroundColor Yellow
        }
    }
    [void](New-Item -ItemType Directory -Path $DataRoot -Force)
    $downloadSize = [int64]$Definition.download_size_gb * 1GB
    $backupParent = Split-Path -Parent $backupPath
    $dataDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($DataRoot))
    $backupDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($backupParent))
    if ($createBackup -and -not (Test-CreationKit $Definition) -and $dataDrive -eq $backupDrive) {
        Assert-FreeSpace $DataRoot ($downloadSize + $gameSize) 'Depot downloads and the full backup'
    }
    else {
        Assert-FreeSpace $DataRoot $downloadSize 'Depot downloads'
        if ($createBackup -and -not (Test-CreationKit $Definition)) { Assert-FreeSpace $backupParent $gameSize 'The full backup' }
    }
    if (-not (Confirm-Action 'Proceed?')) { Write-Host 'Aborted.'; return }
    Test-DirectoryWrite $DataRoot
    if (-not $PreviewOnly) {
        Test-DirectoryWrite $install.GamePath
        if ($createBackup -and -not (Test-CreationKit $Definition)) { Test-DirectoryWrite (Split-Path -Parent $install.GamePath) }
        Test-FileAttributeWrite $install.AcfPath
        foreach ($config in @(Get-LocalConfigs $steamRoots)) { Test-FileWrite $config }
    }
    $username = (Read-Host 'Steam username for SteamCMD').Trim()
    if (-not $username) { throw 'A Steam username is required.' }
    Write-Host 'SteamCMD handles your password and Steam Guard prompts directly.'
    $contentPath = Download-Depots $username $Definition $entry
    if ($PreviewOnly) {
        $preview = Get-DepotPreview $contentPath $install.GamePath
        Write-Host "Would overwrite $($preview.Overwrite) files and add $($preview.New) files."
        Remove-Item -LiteralPath $contentPath -Recurse -Force
        return
    }
    $gameProcess = [IO.Path]::GetFileNameWithoutExtension($Definition.main_exe)
    $steamWasRunning = $false
    if (-not $ManagedRestart) {
        $steamWasRunning = [bool](Get-Process -Name steam -ErrorAction SilentlyContinue)
        try { Stop-SteamAndGame $gameProcess }
        catch { Start-SteamAgain $steamRoots $steamWasRunning; throw }
    }
    try {
        if ($retarget -and -not (Test-CreationKit $Definition) -and $retargetBackupPath) {
            Write-Host 'Resetting the game from the original backup...'
            Reset-GameFromBackup $install.GamePath $retargetBackupPath
        }
        elseif ($createBackup -and -not (Test-CreationKit $Definition)) {
            Write-Host 'Creating full backup...'
            New-FullBackup $install.GamePath $backupPath
        }
        elseif ($createBackup -and (Test-CreationKit $Definition)) {
            Write-Host 'Backing up the Creation Kit files being replaced...'
        }
        if ($retarget) {
            $state = $existingState
            $state.version = $target
            $state.timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        else {
            $configState = @()
            foreach ($config in @(Get-LocalConfigs $steamRoots)) {
                $result = Set-VdfUpdateBehavior $config ([string]$Definition.appid) '1'
                if ($result) {
                    $configState += [pscustomobject]@{ path = $result.Path; prior_present = $result.PriorPresent; prior_value = $result.PriorValue }
                    Write-Host "Protected Steam account config: $config"
                }
            }
            $acfWasReadOnly = Set-ManifestReadOnly $install.AcfPath
        $state = [ordered]@{
                game_path = $install.GamePath
                backup_path = $(if ($createBackup -and -not (Test-CreationKit $Definition)) { $backupPath } else { $null })
                version = $target
                prior_version = $install.Version
                prior_buildid = $install.BuildId
                acf_path = $install.AcfPath
                acf_was_readonly = $acfWasReadOnly
                localconfigs = $configState
            timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            recovered = $false
        }
    }
    # Persist Steam's prior settings before component backup work so that even a
    # later filesystem failure can be restored cleanly on the next run.
    Save-State $GameKey $state
    if (Test-CreationKit $Definition) {
        $existingRecords = @(Get-ComponentRecords $state)
        if ($createBackup -or $existingRecords.Count -gt 0) {
            $records = @(Backup-ComponentFiles $GameKey $contentPath $install.GamePath $existingRecords)
            if ($state -is [Collections.IDictionary]) { $state['component_backup'] = $records }
            elseif ($state.PSObject.Properties['component_backup']) { $state.component_backup = $records }
            else { $state | Add-Member -NotePropertyName component_backup -NotePropertyValue $records }
        }
    }
    Save-State $GameKey $state
    if ($state.backup_path) {
        [IO.File]::WriteAllText(
            (Join-Path ([string]$state.backup_path) $BackupStateName),
            ($state | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false)
        )
    }
        Write-Host 'Installing depot files...'
        Install-DepotFiles $contentPath $install.GamePath
        $installed = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $install.GamePath $Definition.main_exe)).FileVersion
        if (-not $installed.StartsWith($target, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Expected $target, but the installed executable reports $installed. The backup is intact."
        }
        Remove-ContentCatalog $Definition
        Remove-Item -LiteralPath $contentPath -Recurse -Force
    }
    finally {
        if (-not $ManagedRestart) { Start-SteamAgain $steamRoots $steamWasRunning }
    }
    Write-Host "Downgrade complete: $installed" -ForegroundColor Green
    if ($createBackup -and (Test-CreationKit $Definition)) { Write-Host "Creation Kit file backup retained at $(Get-ComponentBackupPath $GameKey)" }
    elseif ($createBackup) { Write-Host "Backup retained at $backupPath" }
}

function Main {
    $games = Get-GameDefinitions
    if ($ListGames) { foreach ($key in $games.Keys) { Write-Host "$key`: $($games[$key].name)" }; return }
    $restoreMode = [bool]$Restore
    if (-not $Game -and -not $restoreMode) {
        while ($true) {
            $selection = Select-InteractiveAction $games
            if ($selection.Action -eq 'exit') { return }
            if ($selection.Action -eq 'downgrade') {
                $gameKey = $selection.Game
                $definition = $games[$gameKey]
                $script:MenuReturnRequested = $false
                $script:MenuExitRequested = $false
                try {
                    Invoke-Downgrade $gameKey $definition $Version -PreviewOnly:$DryRun -NoBackup:$NoBackup -ReturnToMenu
                }
                catch {
                    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                    if (-not (Wait-ForMainMenu)) { return }
                    Write-Host ''
                    continue
                }
                if ($script:MenuExitRequested) { return }
                if ($script:MenuReturnRequested) { Write-Host ''; continue }
                if (-not (Wait-ForMainMenu)) { return }
                Write-Host ''
                continue
            }
            $restoreKey = Select-RestoreGame $games
            if (-not $restoreKey) {
                Write-Host 'No previous downgrade state was found.' -ForegroundColor Yellow
                Write-Host ''
                continue
            }
            $restoreDefinition = $games[$restoreKey]
            $restoreSteamRoots = @(Get-SteamRoots)
            try { Invoke-Restore $restoreKey $restoreDefinition $restoreSteamRoots }
            catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
            if (-not (Wait-ForMainMenu)) { return }
            Write-Host ''
        }
    }
    elseif ($restoreMode -and -not $Game) {
        $gameKey = Select-RestoreGame $games
        if (-not $gameKey) { throw 'No previous downgrade state was found.' }
    }
    else { $gameKey = Select-Game $games $Game }
    $definition = $games[$gameKey]
    if ($ListVersions) { foreach ($item in @($definition.versions.PSObject.Properties.Name | Sort-Object { [version]$_ } -Descending)) { Write-Host $item }; return }
    $steamRoots = @(Get-SteamRoots)
    if ($restoreMode) { Invoke-Restore $gameKey $definition $steamRoots }
    else { Invoke-Downgrade $gameKey $definition $Version -PreviewOnly:$DryRun -NoBackup:$NoBackup }
}

if ($env:JGD_TESTING -ne '1') {
    try { Main }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}
