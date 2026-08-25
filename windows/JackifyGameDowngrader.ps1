[CmdletBinding()]
param(
    [string]$Game,
    [string]$Version,
    [switch]$Restore,
    [switch]$DryRun,
    [switch]$NoBackup,
    [switch]$ListGames,
    [switch]$ListVersions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$DataRoot = Join-Path $ScriptRoot 'data'
$SteamCmdUrl = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'

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
    foreach ($file in Get-ChildItem -LiteralPath $path -Filter '*.json' -File | Sort-Object Name) {
        $result[$file.BaseName] = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    }
    return $result
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
    Write-Host "  $restoreChoice) Restore a previous downgrade"
    while ($true) {
        $choice = 0
        if ([int]::TryParse((Read-Host 'Pick an option [number]'), [ref]$choice) -and
            $choice -ge 1 -and $choice -le $restoreChoice) {
            if ($choice -eq $restoreChoice) { return [pscustomobject]@{ Action = 'restore'; Game = $null } }
            return [pscustomobject]@{ Action = 'downgrade'; Game = $keys[$choice - 1] }
        }
        Write-Host "Enter a number from 1 to $restoreChoice." -ForegroundColor Yellow
    }
}

function Select-RestoreGame([Collections.IDictionary]$Games) {
    $available = [ordered]@{}
    foreach ($key in $Games.Keys) {
        if (Load-State $key) { $available[$key] = $Games[$key] }
    }
    if ($available.Count -eq 0) { return $null }
    if ($available.Count -eq 1) { return @($available.Keys)[0] }
    Write-Host 'Restore which game?'
    return (Select-Game $available '')
}

function Select-Version($Definition, [string]$Requested) {
    $versions = @($Definition.versions.PSObject.Properties.Name | Sort-Object { [version]$_ } -Descending)
    if ($Requested) {
        if ($versions -notcontains $Requested) { throw "Unknown version '$Requested'." }
        return $Requested
    }
    Write-Host 'Downgrade to:'
    for ($i = 0; $i -lt $versions.Count; $i++) { Write-Host "  $($i + 1)) $($versions[$i])" }
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

function Wait-ForProcessExit([string]$Name, [string]$Label) {
    while (Get-Process -Name $Name -ErrorAction SilentlyContinue) {
        [void](Read-Host "Close $Label, then press Enter to continue")
    }
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

function Reset-GameFromBackup([string]$GamePath, [string]$BackupPath) {
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) { throw "Backup not found: $BackupPath" }
    Remove-Item -LiteralPath $GamePath -Recurse -Force
    try { Copy-Tree $BackupPath $GamePath }
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
    return (Join-Path $env:LOCALAPPDATA "$($Definition.localappdata_dir)\ContentCatalog.txt")
}

function Remove-ContentCatalog($Definition) {
    $path = Get-ContentCatalogPath $Definition
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "Removed stale Creation Club content catalog: $path"
    }
}

function Get-StatePath([string]$GameKey) { return (Join-Path $DataRoot "$GameKey\state.json") }

function Save-State([string]$GameKey, $State) {
    $path = Get-StatePath $GameKey
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
    [IO.File]::WriteAllText($path, ($State | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Load-State([string]$GameKey) {
    $path = Get-StatePath $GameKey
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return [IO.File]::ReadAllText($path) | ConvertFrom-Json
}

function Confirm-Action([string]$Prompt) { return ((Read-Host "$Prompt [y/N]").Trim().ToLowerInvariant() -eq 'y') }

function Confirm-DefaultYes([string]$Prompt) {
    $answer = (Read-Host "$Prompt [Y/n]").Trim().ToLowerInvariant()
    return ($answer -eq '' -or $answer -eq 'y' -or $answer -eq 'yes')
}

function Invoke-Restore([string]$GameKey, $Definition, [string[]]$SteamRoots) {
    $state = Load-State $GameKey
    if (-not $state) { throw "No downgrade state found for $($Definition.name)." }
    Write-Host "Game folder: $($state.game_path)"
    if ($state.backup_path) { Write-Host "Backup:      $($state.backup_path)" }
    else { Write-Host 'Backup:      none; Steam verification will be required' }
    if (-not (Confirm-Action 'Restore this backup?')) { Write-Host 'Aborted.'; return }
    Wait-ForProcessExit 'steam' 'Steam'
    Wait-ForProcessExit ([IO.Path]::GetFileNameWithoutExtension($Definition.main_exe)) $Definition.name
    $gamePath = [string]$state.game_path
    $backupPath = [string]$state.backup_path
    if ($backupPath) {
        if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) { throw "Backup not found: $backupPath" }
        $temporary = "$gamePath.jgd-restore-$([guid]::NewGuid().ToString('N'))"
        [IO.Directory]::Move($gamePath, $temporary)
        try { [IO.Directory]::Move($backupPath, $gamePath) }
        catch { [IO.Directory]::Move($temporary, $gamePath); throw }
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
    foreach ($config in @($state.localconfigs)) {
        if (-not (Test-Path -LiteralPath $config.path -PathType Leaf)) { continue }
        $value = if ([bool]$config.prior_present) { [string]$config.prior_value } else { $null }
        [void](Set-VdfUpdateBehavior $config.path ([string]$Definition.appid) $value)
    }
    Restore-ManifestAttribute $state.acf_path ([bool]$state.acf_was_readonly)
    Remove-ContentCatalog $Definition
    Remove-Item -LiteralPath (Get-StatePath $GameKey) -Force
    if ($backupPath) { Write-Host 'Restore complete.' -ForegroundColor Green }
    else {
        Write-Host 'Steam settings restored. Use Steam Verify Integrity of Game Files to reinstall the current game build.' -ForegroundColor Green
    }
}

function Invoke-Downgrade([string]$GameKey, $Definition, [string]$TargetVersion, [switch]$PreviewOnly, [switch]$NoBackup) {
    Wait-ForProcessExit 'steam' 'Steam'
    Wait-ForProcessExit ([IO.Path]::GetFileNameWithoutExtension($Definition.main_exe)) $Definition.name
    $steamRoots = @(Get-SteamRoots)
    if (-not $steamRoots) { throw 'Steam was not found.' }
    $libraries = @(Get-LibraryRoots $steamRoots)
    $install = Find-GameInstall $libraries $Definition
    if (-not $install) { throw "$($Definition.name) was not found in a Steam library." }
    $existingState = Load-State $GameKey
    $retarget = ($null -ne $existingState)
    $target = Select-Version $Definition $TargetVersion
    $entry = $Definition.versions.PSObject.Properties[$target].Value
    $backupPath = Get-BackupPath $install.GamePath $install.Version $install.BuildId
    $gameSize = Get-DirectorySize $install.GamePath
    $createBackup = (-not $PreviewOnly -and -not $NoBackup -and -not $retarget)
    Write-Host ''
    Write-Host "$($Definition.name): $($install.Version) -> $target" -ForegroundColor Cyan
    Write-Host "Game folder: $($install.GamePath)"
    if ($PreviewOnly) { Write-Host 'Dry run: no game or Steam settings will be changed.' }
    else {
        if ($retarget) {
            if ($existingState.backup_path -and (Test-Path -LiteralPath $existingState.backup_path -PathType Container)) {
                Write-Host "Original backup retained at: $($existingState.backup_path)"
                Write-Host 'The game will be reset from that backup before applying the new target.'
            }
            else {
                Write-Host 'No original backup is available. The new target will be applied over the current files.' -ForegroundColor Yellow
                Write-Host 'Steam verification may be required if versions contain different files.' -ForegroundColor Yellow
            }
        }
        elseif (-not $NoBackup) {
            $createBackup = Confirm-DefaultYes ("Create a full {0:N1} GB backup? Recommended, but optional" -f ($gameSize / 1GB))
        }
        if ($createBackup) {
            Write-Host "Full backup: $backupPath"
            Write-Host ("Backup size: approximately {0:N1} GB. It remains until restored or deleted by you." -f ($gameSize / 1GB))
        }
        elseif (-not $retarget) { Write-Host 'Full backup: skipped. Steam must redownload the game if you need to recover it.' -ForegroundColor Yellow }
    }
    [void](New-Item -ItemType Directory -Path $DataRoot -Force)
    $downloadSize = [int64]$Definition.download_size_gb * 1GB
    $backupParent = Split-Path -Parent $backupPath
    $dataDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($DataRoot))
    $backupDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($backupParent))
    if ($createBackup -and $dataDrive -eq $backupDrive) {
        Assert-FreeSpace $DataRoot ($downloadSize + $gameSize) 'Depot downloads and the full backup'
    }
    else {
        Assert-FreeSpace $DataRoot $downloadSize 'Depot downloads'
        if ($createBackup) { Assert-FreeSpace $backupParent $gameSize 'The full backup' }
    }
    if (-not (Confirm-Action 'Proceed?')) { Write-Host 'Aborted.'; return }
    Test-DirectoryWrite $DataRoot
    if (-not $PreviewOnly) {
        Test-DirectoryWrite $install.GamePath
        if ($createBackup) { Test-DirectoryWrite (Split-Path -Parent $install.GamePath) }
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
    if ($retarget -and $existingState.backup_path -and (Test-Path -LiteralPath $existingState.backup_path -PathType Container)) {
        Write-Host 'Resetting the game from the original backup...'
        Reset-GameFromBackup $install.GamePath $existingState.backup_path
    }
    elseif ($createBackup) {
        Write-Host 'Creating full backup...'
        Copy-Tree $install.GamePath $backupPath
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
            backup_path = $(if ($createBackup) { $backupPath } else { $null })
            version = $target
            prior_version = $install.Version
            prior_buildid = $install.BuildId
            acf_path = $install.AcfPath
            acf_was_readonly = $acfWasReadOnly
            localconfigs = $configState
            timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }
    Save-State $GameKey $state
    Write-Host 'Installing depot files...'
    Install-DepotFiles $contentPath $install.GamePath
    $installed = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $install.GamePath $Definition.main_exe)).FileVersion
    if (-not $installed.StartsWith($target, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Expected $target, but the installed executable reports $installed. The backup is intact."
    }
    Remove-ContentCatalog $Definition
    Remove-Item -LiteralPath $contentPath -Recurse -Force
    Write-Host "Downgrade complete: $installed" -ForegroundColor Green
    if ($createBackup) { Write-Host "Backup retained at $backupPath" }
}

function Main {
    $games = Get-GameDefinitions
    if ($ListGames) { foreach ($key in $games.Keys) { Write-Host "$key`: $($games[$key].name)" }; return }
    $restoreMode = [bool]$Restore
    if (-not $Game -and -not $restoreMode) {
        while ($true) {
            $selection = Select-InteractiveAction $games
            if ($selection.Action -eq 'downgrade') { $gameKey = $selection.Game; break }
            $gameKey = Select-RestoreGame $games
            if ($gameKey) { $restoreMode = $true; break }
            Write-Host 'No previous downgrade state was found.' -ForegroundColor Yellow
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
