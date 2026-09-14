# Compatibility overrides for the managed stable Windows installer.
# Embedded after hermes-lifecycle.ps1 so these functions replace base implementations.
# Keep compatible with Windows PowerShell 5.1.
#
# The wrapper must never confuse another Hermes installation on PATH with the
# installation rooted at the current HERMES_HOME. This matters both for users with
# multiple homes and for CI, where a clean-install test runs before an isolated
# lifecycle integration test.
#
# PowerShell 7 can throw `Argument types do not match` when the base lifecycle
# implementation wraps a generic List[object] containing CIM-derived PSCustomObjects
# in @(...). Override the blocker scan with a native PowerShell array instead.
#
# Upstream issue #68058: on some Windows hosts a fresh clone made from the default
# branch is materialized with CRLF before install.ps1 pins core.autocrlf=false.
# The later checkout to a release commit then sees synthetic local changes and aborts.
# For release installs we therefore give upstream -Branch <release-tag> as a clone
# hint while retaining -Commit <exact-sha> + -ForceCommit as the source of truth.
#
# Some upstream installer paths still leave tracked files marked modified from
# line-ending normalization. After the installer succeeds we reset TRACKED files
# back to the exact pinned commit. We intentionally do not run `git clean`, so
# untracked files are preserved.

function Get-HermesStableCommand {
    param([Parameter(Mandatory = $true)]$Paths)

    # Managed lifecycle operations are scoped to this Hermes home only. Never fall
    # back to an arbitrary `hermes` found on PATH: it may belong to another home.
    $candidates = @(
        (Join-Path $Paths.HermesHome 'bin\hermes.exe'),
        (Join-Path $Paths.HermesHome 'bin\hermes.cmd'),
        (Join-Path $Paths.InstallDir 'venv\Scripts\hermes.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-HermesStableBlockingProcesses {
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $normalized = [IO.Path]::GetFullPath($InstallDir).Replace('/', '\').TrimEnd('\') + '\'
    $commandPattern = '(?:^|[\s"''=])' + [regex]::Escape($normalized)
    $found = @()
    try {
        foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            if ($proc.ProcessId -eq $PID) { continue }
            $exe = "$($proc.ExecutablePath)"
            $cmd = "$($proc.CommandLine)"
            $owned = $false
            if ($exe) {
                try {
                    $fullExe = [IO.Path]::GetFullPath($exe).Replace('/', '\')
                    if ($fullExe.StartsWith($normalized, [StringComparison]::OrdinalIgnoreCase)) { $owned = $true }
                } catch { }
            }
            if (-not $owned -and $cmd -and $cmd.Replace('/', '\') -match $commandPattern) { $owned = $true }
            if ($owned) {
                $found += [pscustomobject]@{ Id = $proc.ProcessId; Name = $proc.Name; ExecutablePath = $exe }
            }
        }
    } catch {
        throw "Could not inspect Windows processes; update aborted: $($_.Exception.Message)"
    }
    return @($found)
}

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

    $savedPreference = $ErrorActionPreference
    try {
        # PowerShell 5.1 turns native stderr into ErrorRecords. Diagnostics
        # must not interrupt the child before its actual exit code is known.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $output = & $powershellExe @arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    foreach ($line in @($output)) {
        if ($null -ne $line -and "$line".Length -gt 0) { Write-Host "$line" }
    }
    if ($exitCode -ne 0) {
        throw "Upstream Hermes installer returned failure for $label commit $Commit (exit $exitCode)."
    }

    Repair-HermesStableTrackedCheckout -Commit $Commit -Paths $Paths -Label $Label
}
