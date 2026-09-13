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
}
