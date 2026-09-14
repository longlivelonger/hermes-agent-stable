$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\hermes-lifecycle.ps1')
. (Join-Path $root 'scripts\hermes-install-compat.ps1')
function Assert-HermesStableInstallerPolicy { }

function Assert-FixtureThrows {
    param([scriptblock]$Action, [string]$Expected)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure containing '$Expected' was not raised."
}

& {
    function Get-CimInstance { throw 'fixture CIM failure' }
    Assert-FixtureThrows { Assert-HermesStableNoBlockers -InstallDir 'C:\fixture\hermes-agent' } 'Could not inspect Windows processes'
}

& {
    function Get-CimInstance {
        @(
            @{ ProcessId = 910001; ExecutablePath = 'C:\fixture\hermes-agent-other\python.exe'; CommandLine = '' },
            @{ ProcessId = 910002; ExecutablePath = ''; CommandLine = 'python C:\fixture\hermes-agent-other\run.py' },
            @{ ProcessId = 910003; ExecutablePath = 'C:\fixture\hermes-agent\venv\python.exe'; CommandLine = '' },
            @{ ProcessId = 910004; ExecutablePath = ''; CommandLine = 'python "C:\fixture\hermes-agent\run.py"' },
            @{ ProcessId = 910005; ExecutablePath = ''; CommandLine = 'python --script=C:/fixture/hermes-agent/run.py' },
            @{ ProcessId = 910006; ExecutablePath = ''; CommandLine = 'python C:\other\C:\fixture\hermes-agent\run.py' }
        ) | ForEach-Object { [pscustomobject]($_ + @{ Name = 'python.exe' }) }
    }
    $blockers = @(Get-HermesStableBlockingProcesses -InstallDir 'C:\fixture\hermes-agent')
    if (($blockers.Id -join ',') -ne '910003,910004,910005') {
        throw "Process ownership fixture matched the wrong processes: $($blockers.Id -join ',')"
    }
}

& {
    function Invoke-HermesStableCommand {
        param($HermesCommand, $Arguments, [switch]$Echo)
        if ($Arguments[1] -eq 'stop') { throw 'Gateway stop must not run after a failed snapshot.' }
        [pscustomobject]@{ ExitCode = 1; Output = @('fixture failure') }
    }
    Assert-FixtureThrows {
        $running = @(Get-HermesStableRunningGateways -HermesCommand 'fixture')
        Stop-HermesStableGateways -HermesCommand 'fixture' -PreviouslyRunning $running
    } 'Could not snapshot gateway state'
    function Invoke-HermesStableCommand { [pscustomobject]@{ ExitCode = 1; Output = @() } }
    Assert-FixtureThrows { Stop-HermesStableGateways -HermesCommand 'fixture' -PreviouslyRunning @() } 'Failed to stop running Hermes gateways'
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-safety-' + [Guid]::NewGuid().ToString('N'))
try {
    & {
        $fixturePaths = [pscustomobject]@{
            HermesHome = Join-Path $fixtureRoot 'home'
            InstallDir = Join-Path $fixtureRoot 'home\hermes-agent'
            StateDir = Join-Path $fixtureRoot 'state'
        }
        function Get-HermesStablePaths { $fixturePaths }
        function Get-HermesStableCommand { $null }
        function Get-HermesStableCheckoutInfo {
            [pscustomobject]@{ Dirty = $false; IsGitCheckout = $true; GitAvailable = $false; RevisionKnown = $false; StatusKnown = $false; Tag = $null; Commit = $null }
        }
        function Install-HermesStableCommit { throw 'fixture fresh installer reached' }
        $installArgs = @{
            TargetTag = 'v2026.9.11'; TargetCommit = ('a' * 40); PackageVersion = '2026.9.11'
            UpstreamInstallerPath = Join-Path $root 'scripts\hermes-lifecycle.ps1'
        }

        New-Item -ItemType Directory -Path $fixturePaths.InstallDir -Force | Out-Null
        Assert-FixtureThrows { Invoke-HermesStableInstall @installArgs } 'managed CLI is missing'
        Remove-Item -LiteralPath $fixturePaths.InstallDir # Empty directory only.
        Set-Content -LiteralPath (Join-Path $fixturePaths.HermesHome 'config.yaml') -Value 'fixture'
        Assert-FixtureThrows { Invoke-HermesStableInstall @installArgs } 'managed CLI is missing'
        Remove-Item -LiteralPath (Join-Path $fixturePaths.HermesHome 'config.yaml')
        Assert-FixtureThrows { Invoke-HermesStableInstall @installArgs } 'fixture fresh installer reached'
    }
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Failure safety tests passed.' -ForegroundColor Green
