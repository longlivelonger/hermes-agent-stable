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

# Adapt a copy of the hash-pinned upstream installer. Never alter the downloaded
# original or the tracked Agent checkout. Unknown upstream shapes fail preflight.
function ConvertTo-HermesStableInstaller {
    param([Parameter(Mandatory = $true)][string]$Source)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Cannot apply stable policy to an invalid upstream installer.' }
    function Replace-PolicyText([string]$Text, [string]$Old, [string]$New) {
        if ([regex]::Matches($Text, [regex]::Escape($Old)).Count -ne 1) {
            throw "Unsupported upstream installer policy anchor: $Old"
        }
        return $Text.Replace($Old, $New)
    }
    $edits = @()
    foreach ($name in @('Install-Dependencies', 'Install-NodeDeps', 'Install-CuaDriver')) {
        $functions = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
        }, $true))
        if ($functions.Count -ne 1) { throw "Unsupported upstream installer: expected one $name function." }
        $extent = $functions[0].Extent
        $text = $extent.Text
        switch ($name) {
            'Install-Dependencies' {
                $text = Replace-PolicyText $text 'Invoke-NativeWithRelaxedErrorAction { & $UvCmd sync --extra all --locked }' @'
# Managed Python sets UV_NO_CONFIG=1, which also hides the project's uv
# quarantine/override settings. Read those settings for the locked sync only.
$stableUvNoConfig = $env:UV_NO_CONFIG
try {
    $env:UV_NO_CONFIG = 'false'
    Invoke-NativeWithRelaxedErrorAction { & $UvCmd sync --extra all --locked }
    if ($LASTEXITCODE -ne 0) { throw 'Stable dependency sync failed; refusing an unlocked PyPI fallback.' }
} finally {
    if ($null -eq $stableUvNoConfig) { Remove-Item Env:UV_NO_CONFIG -ErrorAction SilentlyContinue }
    else { $env:UV_NO_CONFIG = $stableUvNoConfig }
}
'@
                $text = Replace-PolicyText $text 'Write-Info "uv.lock not found -- falling back to PyPI resolve (no hash verification)"' "throw 'Stable installation requires uv.lock.'"
                $text = Replace-PolicyText $text '& $UvCmd pip install --reinstall -e .' '& $UvCmd pip install --no-deps --reinstall -e .'
                $text = Replace-PolicyText $text 'Write-Warn "fastapi/uvicorn not importable -- `hermes dashboard` will not work."' "throw 'Locked environment is missing Desktop backend dependencies.'"
            }
            'Install-NodeDeps' {
                $text = Replace-PolicyText $text 'function Install-NodeDeps {' @'
function Install-NodeDeps {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'Stable installation requires npm.' }
'@
                # Check stage results explicitly. Overriding Write-Warn here
                # also affects nested callers and aborts recoverable CUA repair.
                $text = Replace-PolicyText $text 'Write-Warn "npm not found on PATH -- skipping Node.js dependencies."' "throw 'Stable installation requires npm.'"
                $text = Replace-PolicyText $text '$browserNpmOk = _Run-NpmInstall "Browser tools" $InstallDir $browserLog $npmExe' @'
$browserNpmOk = _Run-NpmInstall "Browser tools" $InstallDir $browserLog $npmExe
        if (-not $browserNpmOk) { throw 'Stable Node dependencies: Browser tools npm installation failed.' }
'@
                $text = Replace-PolicyText $text '[void](_Run-NpmInstall "TUI" $tuiDir $tuiLog $npmExe)' @'
if (-not (_Run-NpmInstall "TUI" $tuiDir $tuiLog $npmExe)) {
            throw 'Stable Node dependencies: TUI npm installation failed.'
        }
'@
                foreach ($failure in @(
                    '"npx not found -- cannot install Playwright Chromium."',
                    '"Playwright Chromium install timed out after $([math]::Round($nodeDepsTimeoutSec / 60)) minutes."',
                    '"Playwright Chromium install failed -- exit code $pwCode"',
                    '"Playwright Chromium install could not be launched: $_"'
                )) {
                    $text = Replace-PolicyText $text ("Write-Warn $failure") ("throw $failure")
                }
                $text = Replace-PolicyText $text '$deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec)' @'
# Cache the process handle before it exits. PS 5.1 otherwise loses ExitCode.
        $null = $proc.Handle
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec)
'@
                $text = Replace-PolicyText $text 'return $proc.ExitCode' @'
$proc.WaitForExit()
        $code = $proc.ExitCode
        $proc.Dispose()
        if ($null -eq $code) { throw 'Native dependency process returned no exit code.' }
        return [int]$code
'@
            }
            'Install-CuaDriver' {
                $text = Replace-PolicyText $text '$prevEAP = $ErrorActionPreference' @'
$job = $null
    $prevEAP = $ErrorActionPreference
'@
                $text = Replace-PolicyText $text 'if (Wait-Job $job -Timeout 660) {' @'
$finished = $false
        $interactiveRepair = $false
        try {
            $finished = [bool](Wait-Job $job -Timeout 660 -ErrorAction Stop)
        } catch {
            if ($job.State -ne 'Blocked') { throw }
            # CUA installs the binaries before offering interactive daemon
            # repair. Do not answer prompts or request elevation from Scoop.
            Stop-Job $job -ErrorAction Stop
            $interactiveRepair = $true
        }
        if ($finished -or $interactiveRepair) {
'@
                $text = Replace-PolicyText $text 'Receive-Job $job -ErrorAction SilentlyContinue | Out-Null' @'
if (-not $interactiveRepair) {
                Receive-Job $job -ErrorAction Stop | Out-Null
                if ($job.State -eq 'Failed') { throw 'Computer Use driver background installation failed.' }
            }
'@
                $text = Replace-PolicyText $text 'Write-Success "Computer Use driver installed (enable via ''hermes tools'' -> Computer Use)"' @'
if ($interactiveRepair) {
                    Write-Warn 'Computer Use binaries verified; interactive daemon repair was deferred. Run hermes computer-use install in a terminal if Computer Use is unavailable.'
                }
                Write-Success "Computer Use driver installed (enable via 'hermes tools' -> Computer Use)"
'@
                $text = Replace-PolicyText $text '$ErrorActionPreference = $prevEAP' @'
if ($job) {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
        $ErrorActionPreference = $prevEAP
'@
                $text = Replace-PolicyText $text '$installedCuaDriver = Get-Command cua-driver -ErrorAction SilentlyContinue' @'
# The child job cannot update its parent's environment after adding user PATH.
            Update-ProcessPathForPackages
            $installedCuaDriver = Get-Command cua-driver -ErrorAction SilentlyContinue
'@
                $text = Replace-PolicyText $text 'Write-Warn "Computer Use driver install did not produce a compatible runtime -- repair it before enabling the tool."' "throw 'Computer Use driver runtime verification failed.'"
                $text = Replace-PolicyText $text 'Write-Warn "Computer Use driver install timed out -- it will install on demand when you enable the tool."' "throw 'Computer Use driver installation timed out.'"
                $text = Replace-PolicyText $text 'Write-Warn "Computer Use driver install failed: $_"' 'throw "Computer Use driver installation failed: $_"'
            }
        }
        $edits += @{ Start = $extent.StartOffset; Length = $extent.EndOffset - $extent.StartOffset; Text = $text }
    }
    foreach ($edit in ($edits | Sort-Object Start -Descending)) {
        $Source = $Source.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text)
    }
    # Upstream's interactive catch prints the error but can exit with code 0.
    $Source = Replace-PolicyText $Source 'Write-Err "Installation failed: $_"' "Write-Err `"Installation failed: `$_`"`n    exit 1"
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Stable installer policy produced invalid PowerShell.' }
    return $Source
}

function Assert-HermesStableInstallerPolicy {
    param([string]$Installer)
    $null = ConvertTo-HermesStableInstaller -Source (Get-Content -LiteralPath $Installer -Raw -Encoding UTF8)
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

    $policySource = ConvertTo-HermesStableInstaller -Source (Get-Content -LiteralPath $Installer -Raw -Encoding UTF8)
    $policyInstaller = Join-Path ([IO.Path]::GetTempPath()) ('hermes-stable-installer-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $policyInstaller -Value $policySource -Encoding UTF8
    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $policyInstaller,
        '-Commit', $Commit,
        '-ForceCommit',
        '-SkipSetup',
        '-NonInteractive',
        '-HermesHome', $Paths.HermesHome,
        '-InstallDir', $Paths.InstallDir
    )

    # CUA is shared user infrastructure, not part of the Agent checkout.
    # Rolling back Agent must not retry the dependency that broke its update.
    if ($Label -eq 'rollback') { $arguments += '-SkipComputerUse' }

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
    } finally {
        $ErrorActionPreference = $savedPreference
        Remove-Item -LiteralPath $policyInstaller -Force -ErrorAction SilentlyContinue
    }
    foreach ($line in @($output)) {
        if ($null -ne $line -and "$line".Length -gt 0) { Write-Host "$line" }
    }
    if ($exitCode -ne 0) {
        throw "Upstream Hermes installer returned failure for $label commit $Commit (exit $exitCode)."
    }

    Repair-HermesStableTrackedCheckout -Commit $Commit -Paths $Paths -Label $Label
}
