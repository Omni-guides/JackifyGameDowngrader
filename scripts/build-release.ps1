[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dist = [IO.Path]::GetFullPath((Join-Path $root '..\dist'))
$stage = Join-Path $dist '.stage'

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
[void](New-Item -ItemType Directory -Path $stage -Force)

try {
    $linux = Join-Path $stage 'linux'
    $windows = Join-Path $stage 'windows'
    [void](New-Item -ItemType Directory -Path $linux, $windows)

    Copy-Item -LiteralPath (Join-Path $root 'linux\jackify-game-downgrader') -Destination $linux
    $linuxLauncher = Join-Path $linux 'jackify-game-downgrader'
    $launcherText = [IO.File]::ReadAllText($linuxLauncher).Replace("`r`n", "`n")
    [IO.File]::WriteAllText($linuxLauncher, $launcherText, [Text.UTF8Encoding]::new($false))
    $linuxPackage = Join-Path $linux 'game_downgrade'
    [void](New-Item -ItemType Directory -Path $linuxPackage)
    Copy-Item -Path (Join-Path $root 'linux\game_downgrade\*.py') -Destination $linuxPackage
    Copy-Item -LiteralPath (Join-Path $root 'linux\README.md') -Destination (Join-Path $linux 'README.md')
    Copy-Item -LiteralPath (Join-Path $root 'games') -Destination $linux -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $linux

    Copy-Item -LiteralPath (Join-Path $root 'windows\JackifyGameDowngrader.cmd') -Destination $windows
    Copy-Item -LiteralPath (Join-Path $root 'windows\JackifyGameDowngrader.ps1') -Destination $windows
    Copy-Item -LiteralPath (Join-Path $root 'windows\README.md') -Destination (Join-Path $windows 'README.md')
    Copy-Item -LiteralPath (Join-Path $root 'games') -Destination $windows -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $windows

    $archives = @(
        @{ Name = "JackifyGameDowngrader-Linux-$Version.zip"; Source = $linux },
        @{ Name = "JackifyGameDowngrader-Windows-$Version.zip"; Source = $windows }
    )
    foreach ($archive in $archives) {
        $path = Join-Path $dist $archive.Name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        $zipArguments = @(
            (Join-Path $PSScriptRoot 'make-portable-zip.py'),
            '--source', $archive.Source,
            '--destination', $path
        )
        if ($archive.Source -eq $linux) {
            $zipArguments += @('--executable', 'jackify-game-downgrader')
        }
        & python @zipArguments
        if ($LASTEXITCODE -ne 0) { throw "Failed to create $($archive.Name)" }
    }

    & python (Join-Path $root 'tests\release_archive_tests.py') `
        --linux (Join-Path $dist $archives[0].Name) `
        --windows (Join-Path $dist $archives[1].Name)
    if ($LASTEXITCODE -ne 0) { throw 'Release archive validation failed' }

    $checksumPath = Join-Path $dist "SHA256SUMS-$Version.txt"
    $lines = foreach ($archive in $archives) {
        $path = Join-Path $dist $archive.Name
        '{0}  {1}' -f (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(), $archive.Name
    }
    [IO.File]::WriteAllLines($checksumPath, $lines, [Text.UTF8Encoding]::new($false))
    Write-Host "Release files written to $dist" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
