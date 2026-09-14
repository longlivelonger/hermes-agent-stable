# The Scoop archive has already been SHA-256 verified and extracted.
function New-HermesStableDesktopStage {
    param([string]$Source, [string]$Commit, $Paths)
    $stamp = Get-Content -LiteralPath (Join-Path $Source 'resources\install-stamp.json') -Raw | ConvertFrom-Json
    if ($stamp.commit -ne $Commit -or $stamp.dirty) { throw 'Desktop build does not match the clean pinned Agent commit.' }
    foreach ($file in @('Hermes.exe', 'resources\app.asar', 'resources\install-stamp.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Source $file) -PathType Leaf)) { throw "Desktop payload is missing $file." }
    }
    $stage = Join-Path $Paths.StateDir ('desktop-stage-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -Path (Join-Path $Source '*') -Destination $stage -Recurse -Force
    return $stage
}

function Set-HermesStableDesktop {
    param([string]$Stage, $Paths)
    $parent = Join-Path $Paths.InstallDir 'apps\desktop\release'
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $target = Join-Path $parent 'win-unpacked'
    $previous = Join-Path $parent ('stable-previous-' + [Guid]::NewGuid().ToString('N'))
    # Both move targets are fixed children of the managed release directory.
    $hadPrevious = Test-Path -LiteralPath $target
    if ($hadPrevious) { Move-Item -LiteralPath $target -Destination $previous }
    try {
        Move-Item -LiteralPath $Stage -Destination $target
    } catch {
        if ($hadPrevious) { Move-Item -LiteralPath $previous -Destination $target }
        throw
    }
    return @{ Target = $target; Previous = $previous; HadPrevious = $hadPrevious }
}

function Undo-HermesStableDesktop {
    param($Deployment)
    if (-not $Deployment) { return }
    # Retain failed payload for diagnosis instead of deleting it.
    Move-Item -LiteralPath $Deployment.Target -Destination ($Deployment.Target + '-failed-' + [Guid]::NewGuid().ToString('N'))
    if ($Deployment.HadPrevious) { Move-Item -LiteralPath $Deployment.Previous -Destination $Deployment.Target }
}

function Install-HermesStableDesktopShortcut {
    param($Paths)
    $exe = Join-Path $Paths.InstallDir 'apps\desktop\release\win-unpacked\Hermes.exe'
    $launcher = Join-Path $Paths.HermesHome 'bin\hermes-desktop.ps1'
    $homeLiteral = $Paths.HermesHome.Replace("'", "''")
    $rootLiteral = $Paths.InstallDir.Replace("'", "''")
    $exeLiteral = $exe.Replace("'", "''")
    @(
        "`$env:HERMES_HOME = '$homeLiteral'"
        "`$env:HERMES_DESKTOP_HERMES_ROOT = '$rootLiteral'"
        "Start-Process -FilePath '$exeLiteral'"
    ) | Set-Content -LiteralPath $launcher -Encoding UTF8
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Hermes Stable.lnk'))
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
    $shortcut.IconLocation = $exe
    $shortcut.WorkingDirectory = $Paths.HermesHome
    $shortcut.Save()
}
