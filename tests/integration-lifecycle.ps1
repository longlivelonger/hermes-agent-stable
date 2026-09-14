param(
    [Parameter(Mandatory = $true)][string]$TargetTag,
    [Parameter(Mandatory = $true)][string]$TargetCommit,
    [string]$DesktopSourcePath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools\hermes-release.ps1')
. (Join-Path $root 'scripts\hermes-lifecycle.ps1')
. (Join-Path $root 'scripts\hermes-install-compat.ps1')
. (Join-Path $root 'scripts\hermes-desktop.ps1')

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
    Invoke-HermesStableInstall -TargetTag $TargetTag -TargetCommit $TargetCommit -PackageVersion ($TargetTag -replace '^v', '') -UpstreamInstallerPath $targetInstaller.Path -DesktopSourcePath $DesktopSourcePath
    $desktopHash = $null
    $desktopExe = Join-Path $hermesHome 'hermes-agent\apps\desktop\release\win-unpacked\Hermes.exe'
    if ($DesktopSourcePath) { $desktopHash = (Get-FileHash -LiteralPath $desktopExe).Hash }

    $paths = Get-HermesStablePaths
    $checkout = Get-HermesStableCheckoutInfo -Paths $paths
    if ($checkout.Commit -ne $TargetCommit.ToLowerInvariant()) { throw 'Integration update did not land on target commit.' }
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'User marker disappeared during update.' }

    $receipt = Get-Content -Raw -LiteralPath (Join-Path $paths.StateDir 'last-update.json') | ConvertFrom-Json
    if ($receipt.status -ne 'completed') { throw 'Successful update receipt is not completed.' }
    if (-not $receipt.backup -or -not (Test-HermesStableBackupArchive -Path ([string]$receipt.backup))) { throw 'Update did not produce a valid full backup.' }

    Write-Host '=== Intentional failure to exercise automatic rollback ==='
    # Install a real different revision and corrupt the marker before failing.
    # A no-op code/data rollback must not be able to pass this test.
    $failureEvidence = Join-Path $work 'failed-install-commit.txt'
    $failingInstaller = Join-Path $installerDir 'fail-after-install.ps1'
    $failureScript = (Get-Content -LiteralPath $previousInstaller.Path -Raw) + "`n" + @'
# Fail only after the real pinned installer has completed successfully.
$head = & git -C $InstallDir rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head.Trim() -ne $Commit) { throw 'Failure fixture did not change the checkout commit.' }
Set-Content -LiteralPath (Join-Path $HermesHome 'skills\ci-hermes-agent-stable\MARKER.txt') -Value 'changed-during-failed-install' -Encoding UTF8
Set-Content -LiteralPath '__EVIDENCE__' -Value $head.Trim() -Encoding UTF8
exit 73
'@
    $failureScript = $failureScript.Replace('__EVIDENCE__', $failureEvidence.Replace("'", "''"))
    Set-Content -LiteralPath $failingInstaller -Value $failureScript -Encoding UTF8
    $failedAsExpected = $false
    try {
        Invoke-HermesStableInstall -TargetTag $previousTag -TargetCommit $previousCommit -PackageVersion $previousVersion -UpstreamInstallerPath $failingInstaller
    } catch {
        $failedAsExpected = $true
        Write-Host "Expected failure observed: $($_.Exception.Message)"
    }
    if (-not $failedAsExpected) { throw 'Intentional invalid update unexpectedly succeeded.' }
    if (-not (Test-Path -LiteralPath $failureEvidence) -or (Get-Content -Raw -LiteralPath $failureEvidence).Trim() -ne $previousCommit) {
        throw 'Failure fixture did not reach the code/data mutation stage.'
    }

    $checkoutAfterRollback = Get-HermesStableCheckoutInfo -Paths $paths
    if ($checkoutAfterRollback.Commit -ne $TargetCommit.ToLowerInvariant()) { throw 'Rollback did not restore the pre-failure commit.' }
    if ($desktopHash -and (Get-FileHash -LiteralPath $desktopExe).Hash -ne $desktopHash) { throw 'Agent rollback damaged the installed Desktop.' }
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'User marker is missing after rollback/restore.' }
    if ((Get-Content -Raw -LiteralPath $marker).Trim() -cne 'preserve-me') { throw 'Rollback did not restore the original user marker contents.' }

    $rollbackReceipt = Get-Content -Raw -LiteralPath (Join-Path $paths.StateDir 'last-rollback.json') | ConvertFrom-Json
    if (-not $rollbackReceipt.codeRollbackSucceeded) { throw 'Rollback integration test: code rollback did not succeed.' }
    if (-not $rollbackReceipt.dataRollbackSucceeded) { throw 'Rollback integration test: data restore did not succeed.' }
    $attempt = Get-Content -Raw -LiteralPath (Join-Path $paths.StateDir 'last-attempt.json') | ConvertFrom-Json
    if ($attempt.status -ne 'rolled-back') { throw "Rollback integration test: last-attempt status is '$($attempt.status)'." }

    Write-Host 'Lifecycle integration update + rollback test passed.' -ForegroundColor Green
} finally {
    if ($null -eq $oldHermesHome) { Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue } else { $env:HERMES_HOME = $oldHermesHome }
}
