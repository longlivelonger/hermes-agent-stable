# Compatibility override for the upstream Windows installer.
# Embedded after hermes-lifecycle.ps1 so this function replaces the base implementation.
# Keep compatible with Windows PowerShell 5.1.
#
# Upstream issue #68058: on some Windows hosts a fresh clone made from the default
# branch is materialized with CRLF before install.ps1 pins core.autocrlf=false.
# The later checkout to a release commit then sees synthetic local changes and aborts.
#
# For release installs we give upstream -Branch <release-tag> as a clone hint while
# retaining -Commit <exact-sha> + -ForceCommit as the source of truth. `git clone
# --branch` accepts tags, so a fresh shallow clone starts at the desired release
# tree and the subsequent exact-SHA pin does not need to replace its worktree.
#
# Some upstream installer paths still leave tracked files marked modified from
# line-ending normalization. After the installer succeeds we reset TRACKED files
# back to the exact pinned commit. We intentionally do not run `git clean`, so
# untracked files are preserved.

function Repair-HermesStableTrackedCheckout {
    param(
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)]$Paths,
        [string]$Label = 'target'
    )

    $git = Get-HermesStableGit -Paths $Paths
    if (-not $git) { throw "Git is unavailable after installing Hermes $Label commit $Commit." }
    if (-not (Test-Path -LiteralPath (Join-Path $Paths.InstallDir '.git') -PathType Container)) {
        throw "Hermes $Label install directory is not a git checkout after installation."
    }

    Write-HermesStableInfo "Normalizing tracked checkout to exact $label commit $Commit"
    $reset = Invoke-HermesStableGit -Git $git -InstallDir $Paths.InstallDir -Arguments @('reset', '--hard', $Commit)
    if ($reset.ExitCode -ne 0) {
        throw "Failed to normalize Hermes $label tracked checkout to $Commit."
    }

    $head = Invoke-HermesStableGit -Git $git -InstallDir $Paths.InstallDir -Arguments @('rev-parse', 'HEAD')
    if ($head.ExitCode -ne 0 -or $head.Output.Trim().ToLowerInvariant() -ne $Commit.ToLowerInvariant()) {
        throw "Hermes $label checkout verification failed after normalization."
    }

    $trackedStatus = Invoke-HermesStableGit -Git $git -InstallDir $Paths.InstallDir -Arguments @('status', '--porcelain', '--untracked-files=no')
    if ($trackedStatus.ExitCode -ne 0) {
        throw "Could not verify Hermes $label tracked checkout cleanliness after normalization."
    }
    if (-not [string]::IsNullOrWhiteSpace($trackedStatus.Output)) {
        throw "Hermes $label tracked checkout remains modified after normalization: $($trackedStatus.Output)"
    }
}

function Install-HermesStableCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Installer,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)]$Paths,
        [string]$Label = 'target'
    )

    if ($Commit -notmatch '^[0-9a-fA-F]{40,64}$') { throw "Invalid $Label commit '$Commit'." }
    Write-HermesStableInfo "Installing Hermes $Label commit $Commit"

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        $powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
    }

    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $Installer,
        '-Commit', $Commit,
        '-ForceCommit',
        '-SkipSetup',
        '-NonInteractive',
        '-HermesHome', $Paths.HermesHome,
        '-InstallDir', $Paths.InstallDir
    )

    if ($Label -match '^release (?<tag>v\d{4}\.\d{1,2}\.\d{1,2}(?:\.\d+)?)$') {
        $branchHint = [string]$Matches['tag']
        Write-HermesStableInfo "Using release tag $branchHint as the upstream clone hint; exact commit verification remains authoritative."
        $arguments += @('-Branch', $branchHint)
    }

    $global:LASTEXITCODE = 0
    $output = & $powershellExe @arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in @($output)) {
        if ($null -ne $line -and "$line".Length -gt 0) { Write-Host "$line" }
    }
    if ($exitCode -ne 0) {
        throw "Upstream Hermes installer returned failure for $label commit $Commit (exit $exitCode)."
    }

    Repair-HermesStableTrackedCheckout -Commit $Commit -Paths $Paths -Label $Label
}
