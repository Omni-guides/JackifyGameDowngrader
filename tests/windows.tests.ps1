$ErrorActionPreference = 'Stop'
$env:JGD_TESTING = '1'
. (Join-Path $PSScriptRoot '..\windows\JackifyGameDowngrader.ps1')

$script:Passed = 0

function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ne $Actual) { throw "$Name`: expected '$Expected', got '$Actual'" }
    $script:Passed++
}

function Assert-True([bool]$Value, [string]$Name) {
    if (-not $Value) { throw "$Name`: assertion failed" }
    $script:Passed++
}

$temp = Join-Path $PSScriptRoot ('.tmp-' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $temp)
    $script:StateRoot = Join-Path $temp 'state'
    $script:DataRoot = Join-Path $temp 'data'

    $games = Get-GameDefinitions
    Assert-Equal 4 $games.Count 'game count'
    Assert-Equal 'SkyrimSE.exe' $games['skyrim_se'].main_exe 'game data'
    Assert-True (Test-CreationKit $games['skyrim_se_ck']) 'creation kit definition type'
    Assert-Equal 1946160 $games['fallout4_ck'].appid 'fallout creation kit app id'
    Assert-True ($games['fallout4'].versions.PSObject.Properties.Name -contains '1.11.221') 'fallout 1.11.221 target exists'
    Assert-True ($games['fallout4_ck'].versions.PSObject.Properties.Name -contains '1.10.982.3') 'fallout CK 1.10.982.3 target exists'
    Assert-Equal 0 @(Get-ComponentRecords $null).Count 'null component records normalize to empty array'
    Assert-Equal 0 @(Get-ComponentRecords ([ordered]@{})).Count 'missing component records normalize to empty array'
    $oneRecordState = [ordered]@{ component_backup = [pscustomobject]@{ path = 'CreationKit.exe'; existed = $true } }
    Assert-Equal 1 @(Get-ComponentRecords $oneRecordState).Count 'scalar component record normalizes to one item'
    $manyRecordState = [ordered]@{ component_backup = @(
        [pscustomobject]@{ path = 'CreationKit.exe'; existed = $true },
        [pscustomobject]@{ path = 'CreationKit.ini'; existed = $false }
    ) }
    Assert-Equal 2 @(Get-ComponentRecords $manyRecordState).Count 'multiple component records remain an array'

    $vdf = @'
"libraryfolders"
{
    "1"
    {
        "path" "D:\\SteamLibrary"
    }
}
'@
    Assert-Equal 'D:\\SteamLibrary' (Get-VdfValue $vdf 'path') 'VDF value'
    Assert-Equal $null (Get-VdfValue $vdf 'missing') 'missing VDF value'

    $config = Join-Path $temp 'localconfig.vdf'
    $configText = @'
"UserLocalConfigStore"
{
    "Software"
    {
        "Valve"
        {
            "Steam"
            {
                "apps"
                {
                    "489830"
                    {
                        "AutoUpdateBehavior" "0"
                    }
                    "377160"
                    {
                    }
                }
            }
        }
    }
}
'@
    [IO.File]::WriteAllText($config, $configText)
    $change = Set-VdfUpdateBehavior $config '489830' '1'
    Assert-Equal '0' $change.PriorValue 'prior update setting'
    Assert-True ([IO.File]::ReadAllText($config).Contains('"AutoUpdateBehavior"' + "`t`t" + '"1"')) 'set update setting'
    [void](Set-VdfUpdateBehavior $config '489830' $change.PriorValue)
    Assert-True ([IO.File]::ReadAllText($config).Contains('"AutoUpdateBehavior"' + "`t`t" + '"0"')) 'restore update setting'
    $added = Set-VdfUpdateBehavior $config '377160' '1'
    Assert-True (-not $added.PriorPresent) 'missing prior setting'
    [void](Set-VdfUpdateBehavior $config '377160' $null)
    $fo4Block = Find-VdfBlock ([IO.File]::ReadAllText($config)) '377160'
    $body = [IO.File]::ReadAllText($config).Substring($fo4Block.Start, $fo4Block.End - $fo4Block.Start)
    Assert-True (-not $body.Contains('AutoUpdateBehavior')) 'remove added setting'

    $game = Join-Path $temp 'game'
    $content = Join-Path $temp 'content'
    [void](New-Item -ItemType Directory -Path (Join-Path $game 'Data') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $content 'depot_1\Data') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $content 'depot_2') -Force)
    [IO.File]::WriteAllText((Join-Path $game 'Data\old.txt'), 'old')
    [IO.File]::WriteAllText((Join-Path $content 'depot_1\Data\old.txt'), 'new')
    [IO.File]::WriteAllText((Join-Path $content 'depot_2\new.txt'), 'new')
    $preview = Get-DepotPreview $content $game
    Assert-Equal 1 $preview.Overwrite 'preview overwrite'
    Assert-Equal 1 $preview.New 'preview new'
    Install-DepotFiles $content $game
    Assert-Equal 'new' ([IO.File]::ReadAllText((Join-Path $game 'Data\old.txt'))) 'depot overwrite'
    [IO.File]::WriteAllText((Join-Path $content 'depot_2\stale.txt'), 'stale')
    $selectedPreview = Get-DepotPreview $content $game ([ordered]@{ '1' = 'target-manifest' })
    Assert-Equal 1 $selectedPreview.Overwrite 'selected depot preview overwrite'
    Assert-Equal 0 $selectedPreview.New 'selected depot preview ignores stale depot'
    $selectedGame = Join-Path $temp 'selected-game'
    [void](New-Item -ItemType Directory -Path $selectedGame -Force)
    Install-DepotFiles $content $selectedGame ([ordered]@{ '1' = 'target-manifest' })
    Assert-True (Test-Path -LiteralPath (Join-Path $selectedGame 'Data\old.txt')) 'selected depot install copies requested depot'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $selectedGame 'stale.txt'))) 'selected depot install ignores stale depot'

    $componentGame = Join-Path $temp 'component-game'
    $componentContent = Join-Path $temp 'component-content\depot_1'
    [void](New-Item -ItemType Directory -Path $componentGame -Force)
    [void](New-Item -ItemType Directory -Path $componentContent -Force)
    [IO.File]::WriteAllText((Join-Path $componentGame 'game.exe'), 'game untouched')
    [IO.File]::WriteAllText((Join-Path $componentGame 'CreationKit.exe'), 'new CK')
    [IO.File]::WriteAllText((Join-Path $componentContent 'CreationKit.exe'), 'old CK')
    [IO.File]::WriteAllText((Join-Path $componentContent 'ck-added.ini'), 'old setting')
    $componentRecords = @(Backup-ComponentFiles 'test_ck' (Split-Path -Parent $componentContent) $componentGame @())
    Assert-Equal 2 $componentRecords.Count 'first component backup records overwritten and added files'
    Install-DepotFiles (Split-Path -Parent $componentContent) $componentGame
    Restore-ComponentFiles 'test_ck' $componentGame $componentRecords
    Assert-Equal 'new CK' ([IO.File]::ReadAllText((Join-Path $componentGame 'CreationKit.exe'))) 'component executable restored'
    Assert-Equal 'game untouched' ([IO.File]::ReadAllText((Join-Path $componentGame 'game.exe'))) 'component leaves game file'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $componentGame 'ck-added.ini'))) 'component added file removed'

    $noBackupGame = Join-Path $temp 'component-no-backup-game'
    $noBackupContent = Join-Path $temp 'component-no-backup-content\depot_1'
    [void](New-Item -ItemType Directory -Path $noBackupGame -Force)
    [void](New-Item -ItemType Directory -Path $noBackupContent -Force)
    [IO.File]::WriteAllText((Join-Path $noBackupGame 'CreationKit.exe'), 'current CK')
    [IO.File]::WriteAllText((Join-Path $noBackupContent 'CreationKit.exe'), 'old CK')
    Install-DepotFiles (Split-Path -Parent $noBackupContent) $noBackupGame
    Assert-Equal 'old CK' ([IO.File]::ReadAllText((Join-Path $noBackupGame 'CreationKit.exe'))) 'component no-backup applies depot'
    Assert-True (-not (Test-Path -LiteralPath (Get-ComponentBackupPath 'test_ck_no_backup'))) 'component no-backup creates no backup folder'

    $copy = Join-Path $temp 'copy'
    Copy-Tree $game $copy
    Assert-True (Test-Path -LiteralPath (Join-Path $copy 'new.txt')) 'full backup copy'
    [IO.File]::WriteAllText((Join-Path $game 'extra.txt'), 'remove')
    Reset-GameFromBackup $game $copy
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $game 'extra.txt'))) 'retarget reset removes extra file'
    Assert-True (Test-Path -LiteralPath (Join-Path $copy 'new.txt')) 'retarget keeps original backup'

    $atomicBackup = Join-Path $temp 'atomic-backup'
    New-FullBackup $game $atomicBackup
    Assert-True (Test-Path -LiteralPath (Join-Path $atomicBackup 'new.txt')) 'staged full backup completes'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $temp -Directory -Filter '.jgd-backup-staging-*').Count 'full backup leaves no staging folder'
    $validBackupState = [ordered]@{ backup_path = $atomicBackup }
    Assert-Equal $atomicBackup (Get-UsableFullBackupPath $validBackupState) 'existing full backup remains usable'
    $missingBackupState = [ordered]@{ backup_path = (Join-Path $temp 'deleted-backup') }
    Assert-Equal $null (Get-UsableFullBackupPath $missingBackupState) 'missing full backup resolves to no backup'
    Assert-Equal $null $missingBackupState.backup_path 'missing full backup is cleared from state'
    $failedBackup = $false
    try { New-FullBackup (Join-Path $temp 'missing-source') (Join-Path $temp 'never-created-backup') }
    catch { $failedBackup = $true }
    Assert-True $failedBackup 'failed full backup reports an error'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $temp -Directory -Filter '.jgd-backup-staging-*').Count 'failed full backup removes staging folder'

    $manifest = Join-Path $temp 'appmanifest.acf'
    [IO.File]::WriteAllText($manifest, 'test')
    Test-FileAttributeWrite $manifest
    $wasReadOnly = Set-ManifestReadOnly $manifest
    Assert-True (-not $wasReadOnly) 'manifest prior attribute'
    Assert-True (([IO.File]::GetAttributes($manifest) -band [IO.FileAttributes]::ReadOnly) -ne 0) 'manifest read only'
    Restore-ManifestAttribute $manifest $false
    Assert-True (([IO.File]::GetAttributes($manifest) -band [IO.FileAttributes]::ReadOnly) -eq 0) 'manifest restored'

    Assert-Equal (Join-Path $env:LOCALAPPDATA 'Skyrim Special Edition\ContentCatalog.txt') (Get-ContentCatalogPath $games['skyrim_se']) 'content catalog path'
    Assert-True ((Get-BackupPath $game '1.2.3.4' $null).EndsWith('game (1.2.3.4)')) 'backup name'

    $savedState = [ordered]@{ game_path = $game; backup_path = $copy; version = '1.0' }
    Save-State 'skyrim_se' $savedState
    Assert-Equal '1.0' (Load-State 'skyrim_se').version 'persistent state round trip'
    $legacyState = Join-Path $DataRoot 'fallout4\state.json'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $legacyState) -Force)
    [IO.File]::WriteAllText($legacyState, '{"version":"1.10.163"}')
    Assert-Equal '1.10.163' (Load-State 'fallout4').version 'legacy state migration'
    Assert-True (-not (Test-Path -LiteralPath $legacyState)) 'legacy state moved'

    $liveLog = Join-Path $temp 'console_log.txt'
    [IO.File]::WriteAllText($liveLog, 'Downloading depot 1')
    $heldLog = [IO.File]::Open($liveLog, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try { Assert-Equal 'Downloading depot 1' (Read-SteamCmdLog $liveLog) 'read live SteamCMD log' }
    finally { $heldLog.Dispose() }

    $completedLog = Join-Path $temp 'completed_log.txt'
    [IO.File]::WriteAllText($completedLog, 'old run' + "`n" + 'Depot download complete : "path" (manifest 12345)')
    $versionEntry = [pscustomobject]@{ manifests = [pscustomobject]@{ '1' = '12345' } }
    Assert-SteamCmdDownloads $completedLog 8 $versionEntry
    $script:Passed++
    $missingManifest = [pscustomobject]@{ manifests = [pscustomobject]@{ '1' = '99999' } }
    $rejected = $false
    try { Assert-SteamCmdDownloads $completedLog 8 $missingManifest }
    catch { $rejected = $true }
    Assert-True $rejected 'reject unconfirmed SteamCMD manifest'

    $script:MenuResponses = [Collections.Generic.Queue[string]]::new()
    function Read-Host([string]$Prompt) { return $script:MenuResponses.Dequeue() }
    foreach ($response in @('x', '0', '2')) { $script:MenuResponses.Enqueue($response) }
    Assert-Equal 'skyrim_se' (Select-Game $games '') 'game menu retry'
    foreach ($response in @('9', '1')) { $script:MenuResponses.Enqueue($response) }
    Assert-Equal '1.6.1170' (Select-Version $games['skyrim_se'] '') 'version menu newest first'
    foreach ($response in @('0', '5')) { $script:MenuResponses.Enqueue($response) }
    Assert-Equal 'restore' (Select-InteractiveAction $games).Action 'interactive restore menu'
    $script:MenuResponses.Enqueue('6')
    Assert-Equal 'exit' (Select-InteractiveAction $games).Action 'interactive exit menu'
    $script:MenuResponses.Enqueue('')
    Assert-True (Confirm-DefaultYes 'Backup') 'backup default yes'
    $script:MenuResponses.Enqueue('n')
    Assert-True (-not (Confirm-DefaultYes 'Backup')) 'backup no'
    Remove-Item Function:\Read-Host

    Write-Host "$script:Passed tests passed." -ForegroundColor Green
}
finally {
    Remove-Item Env:JGD_TESTING -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
