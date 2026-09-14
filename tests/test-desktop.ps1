$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\hermes-desktop.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-desktop-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $paths = @{ InstallDir = Join-Path $testRoot 'checkout'; StateDir = $testRoot }
    $source = Join-Path $testRoot 'source'
    New-Item -ItemType Directory -Path (Join-Path $source 'resources') -Force | Out-Null
    Set-Content (Join-Path $source 'Hermes.exe') 'new-desktop'
    Set-Content (Join-Path $source 'resources\app.asar') 'fixture'
    $commit = 'a' * 40
    @{commit = $commit; dirty = $false} | ConvertTo-Json | Set-Content (Join-Path $source 'resources\install-stamp.json')
    $rejected = $false
    try { $null = New-HermesStableDesktopStage -Source $source -Commit ('b' * 40) -Paths $paths } catch { $rejected = $true }
    if (-not $rejected) { throw 'Desktop/Agent mismatch was accepted.' }
    $target = Join-Path $paths.InstallDir 'apps\desktop\release\win-unpacked'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Set-Content (Join-Path $target 'Hermes.exe') 'old-desktop'
    $stage = New-HermesStableDesktopStage -Source $source -Commit $commit -Paths $paths
    $deployment = Set-HermesStableDesktop -Stage $stage -Paths $paths
    if ((Get-Content (Join-Path $target 'Hermes.exe') -Raw).Trim() -ne 'new-desktop') { throw 'New Desktop was not deployed.' }
    Undo-HermesStableDesktop -Deployment $deployment
    if ((Get-Content (Join-Path $target 'Hermes.exe') -Raw).Trim() -ne 'old-desktop') { throw 'Desktop rollback did not restore old bytes.' }
    $failed = $false
    try { $null = Set-HermesStableDesktop -Stage (Join-Path $testRoot 'missing') -Paths $paths } catch { $failed = $true }
    if (-not $failed -or (Get-Content (Join-Path $target 'Hermes.exe') -Raw).Trim() -ne 'old-desktop') { throw 'Interrupted Desktop deployment lost the old executable.' }
    # A cross-volume move can create part of its destination before failing.
    # The old executable must still be at the canonical path in that case.
    $partialStage = New-HermesStableDesktopStage -Source $source -Commit $commit -Paths $paths
    function Move-Item {
        param([string]$LiteralPath, [string]$Destination)
        if ($LiteralPath -eq $partialStage) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Set-Content (Join-Path $Destination 'partial.tmp') 'interrupted copy'
            throw 'Injected cross-volume move failure.'
        }
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination
    }
    try {
        $failed = $false
        try { $null = Set-HermesStableDesktop -Stage $partialStage -Paths $paths } catch { $failed = $true }
        if (-not $failed -or -not (Test-Path (Join-Path $target 'Hermes.exe'))) { throw 'Partial move displaced the working Desktop.' }
        if ((Get-Content (Join-Path $target 'Hermes.exe') -Raw).Trim() -ne 'old-desktop') { throw 'Partial move corrupted the working Desktop.' }
    } finally { Remove-Item Function:\Move-Item }
    $renameStage = New-HermesStableDesktopStage -Source $source -Commit $commit -Paths $paths
    function Rename-Item {
        param([string]$LiteralPath, [string]$NewName)
        if ((Split-Path $LiteralPath -Leaf) -like 'stable-next-*' -and $NewName -eq 'win-unpacked') {
            throw 'Injected activation failure.'
        }
        Microsoft.PowerShell.Management\Rename-Item -LiteralPath $LiteralPath -NewName $NewName
    }
    try {
        $failed = $false
        try { $null = Set-HermesStableDesktop -Stage $renameStage -Paths $paths } catch { $failed = $true }
        if (-not $failed -or (Get-Content (Join-Path $target 'Hermes.exe') -Raw).Trim() -ne 'old-desktop') { throw 'Failed activation did not restore the working Desktop.' }
    } finally { Remove-Item Function:\Rename-Item }
    Write-Host 'Desktop provenance and rollback tests passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
