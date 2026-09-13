param(
    [Parameter(Mandatory = $true)][string]$TargetTag,
    [Parameter(Mandatory = $true)][string]$TargetCommit
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools\hermes-release.ps1')
. (Join-Path $root 'scripts\hermes-lifecycle.ps1')
. (Join-Path $root 'scripts\hermes-install-compat.ps1')

if (-not $env:RUNNER_TEMP) { throw 'integration-lifecycle.ps1 is intended for a disposable Windows CI runner.' }
$work = Join-Path $env:RUNNER_TEMP ('hermes-stable-integration-' + [Guid]::NewGuid().ToString('N'))
$hermesHome = Join-Path $work 'hermes-home'
$installerDir = Join-Path $work 'installers'
New-Item -ItemType Directory -Force -Path $installerDir | Out-Null
$oldHermesHome = $env:HERMES_HOME
$env:HERMES_HOME = $hermesHome

try {
    $previousTag = Get-HermesPreviousStableTag -BeforeTag $TargetTag
    $previousCommit = Resolve-HermesTagCommit -Tag $previousTag
    $previousVersion = $previousTag -replace '^v', ''

    $previousInstaller = Save-HermesInstallerForCommit -Commit $previousCommit -Destination (Join-Path $installerDir 'previous-install.ps1')
    $targetInstaller = Save-HermesInstallerForCommit -Commit $TargetCommit -Destination (Join-Path $installerDir 'target-install.ps1')

    Write-Host "=== Fresh-install previous stable: $previousTag @ $previousCommit ==="
    Invoke-HermesStableInstall -TargetTag $previousTag -TargetCommit $previousCommit -PackageVersion $previousVersion -UpstreamInstallerPath $previousInstaller.Path

    $markerDir = Join-Path $hermesHome 'skills\ci-hermes-agent-stable'
    New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
    $marker = Join-Path $markerDir 'MARKER.txt'
    Set-Content -LiteralPath $marker -Value 'preserve-me' -Encoding UTF8

    Write-Host "=== Upgrade to target stable: $TargetTag @ $TargetCommit ==="
    Invoke-HermesStableInstall -TargetTag $TargetTag -TargetCommit $TargetCommit -PackageVersion ($TargetTag -replace '^v', '') -UpstreamInstallerPath $targetInstaller.Path

    $paths = Get-HermesStablePaths
    $checkout = Get-HermesStableCheckoutInfo -Paths $paths
    if ($checkout.Commit -ne $TargetCommit.ToLowerInvariant()) { throw 'Integration update did not land on target commit.' }
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'User marker disappeared during update.' }

    $receipt = Get-Content -Raw -LiteralPath (Join-Path $paths.StateDir 'last-update.json') | ConvertFrom-Json
    if ($receipt.status -ne 'completed') { throw 'Successful update receipt is not completed.' }
    if (-not $receipt.backup -or -not (Test-HermesStableBackupArchive -Path ([string]$receipt.backup))) { throw 'Update did not produce a valid full backup.' }

    Write-Host '=== Intentional failure to exercise automatic rollback ==='
    $badCommit = ('0' * 39) + '1'
    $failedAsExpected = $false
    try {
        Invoke-HermesStableInstall -TargetTag 'ci-intentional-invalid' -TargetCommit $badCommit -PackageVersion '0.0.0-ci-invalid' -UpstreamInstallerPath $targetInstaller.Path
    } catch {
        $failedAsExpected = $true
        Write-Host "Expected failure observed: $($_.Exception.Message)"
    }
    if (-not $failedAsExpected) { throw 'Intentional invalid update unexpectedly succeeded.' }

    $checkoutAfterRollback = Get-HermesStableCheckoutInfo -Paths $paths
    if ($checkoutAfterRollback.Commit -ne $TargetCommit.ToLowerInvariant()) { throw 'Rollback did not restore the pre-failure commit.' }
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'User marker is missing after rollback/restore.' }

    $rollbackReceipt = Get-Content -Raw -LiteralPath (Join-Path $paths.StateDir 'last-rollback.json') | ConvertFrom-Json
    if (-not $rollbackReceipt.codeRollbackSucceeded) { throw 'Rollback integration test: code rollback did not succeed.' }
    if (-not $rollbackReceipt.dataRollbackSucceeded) { throw 'Rollback integration test: data restore did not succeed.' }
    $attempt = Get-Content -Raw -LiteralPath (Join-Path $paths.StateDir 'last-attempt.json') | ConvertFrom-Json
    if ($attempt.status -ne 'rolled-back') { throw "Rollback integration test: last-attempt status is '$($attempt.status)'." }

    Write-Host 'Lifecycle integration update + rollback test passed.' -ForegroundColor Green
} finally {
    if ($null -eq $oldHermesHome) { Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue } else { $env:HERMES_HOME = $oldHermesHome }
}
