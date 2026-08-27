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
    Assert-Equal 2 $games.Count 'game count'
    Assert-Equal 'SkyrimSE.exe' $games['skyrim_se'].main_exe 'game data'

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

    $copy = Join-Path $temp 'copy'
    Copy-Tree $game $copy
    Assert-True (Test-Path -LiteralPath (Join-Path $copy 'new.txt')) 'full backup copy'
    [IO.File]::WriteAllText((Join-Path $game 'extra.txt'), 'remove')
    Reset-GameFromBackup $game $copy
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $game 'extra.txt'))) 'retarget reset removes extra file'
    Assert-True (Test-Path -LiteralPath (Join-Path $copy 'new.txt')) 'retarget keeps original backup'

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
    foreach ($response in @('0', '3')) { $script:MenuResponses.Enqueue($response) }
    Assert-Equal 'restore' (Select-InteractiveAction $games).Action 'interactive restore menu'
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
