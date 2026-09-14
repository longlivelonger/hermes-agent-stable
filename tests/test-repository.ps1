$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'test-desktop.ps1')
& (Join-Path $PSScriptRoot 'test-installer-stderr.ps1')
$root = Split-Path -Parent $PSScriptRoot
$lifecyclePath = Join-Path $root 'scripts\hermes-lifecycle.ps1'
$compatibilityPath = Join-Path $root 'scripts\hermes-install-compat.ps1'
$releaseHelperPath = Join-Path $root 'tools\hermes-release.ps1'
$manifestPath = Join-Path $root 'bucket\hermes-agent-stable.json'

# Parse every PowerShell source file with the native parser. This catches syntax errors
# in both Windows PowerShell 5.1 and PowerShell 7 when the workflow runs under each host.
$psFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1')
foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $detail = ($errors | ForEach-Object { "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
        throw "PowerShell parse errors detected:`n$detail"
    }
}

if (-not (Test-Path -LiteralPath $lifecyclePath)) { throw 'Missing lifecycle script.' }
if (-not (Test-Path -LiteralPath $compatibilityPath)) { throw 'Missing installer compatibility script.' }
if (-not (Test-Path -LiteralPath $releaseHelperPath)) { throw 'Missing release helper script.' }
$lifecycleLines = @(Get-Content -LiteralPath $lifecyclePath)
$compatibilityLines = @(Get-Content -LiteralPath $compatibilityPath)
$lifecycleText = $lifecycleLines -join "`n"
$compatibilityText = $compatibilityLines -join "`n"
foreach ($required in @(
    'function Invoke-HermesStableInstall',
    'TargetCommit',
    "@('backup', '-o'",
    'Test-HermesStableBackupArchive',
    'Hermes Backups',
    "'config', 'check'",
    "@('doctor')",
    'config migrate',
    'Save-HermesStableRollbackInstaller',
    'Test-HermesStableInstallerCommitCapability',
    'ForceCommit',
    'TryParse',
    'last-attempt.json'
)) {
    if ($lifecycleText -notlike "*$required*") { throw "Lifecycle script is missing required contract marker: $required" }
}
foreach ($required in @(
    'function Get-HermesStableCommand',
    'function Get-HermesStableBlockingProcesses',
    'function Install-HermesStableCommit',
    'function Repair-HermesStableTrackedCheckout',
    '@(''reset'', ''--hard'', $Commit)',
    "'status', '--porcelain', '--untracked-files=no'",
    "'-Branch'",
    'release tag',
    'exact commit verification remains authoritative',
    'Never fall',
    '$found = @()'
)) {
    if ($compatibilityText -notlike "*$required*") { throw "Installer compatibility script is missing required contract marker: $required" }
}

# Unit-test CalVer parsing and previous-stable selection without any network dependency.
. $releaseHelperPath
$older = ConvertTo-HermesCalVer -Tag 'v2026.9.7'
$newer = ConvertTo-HermesCalVer -Tag 'v2026.9.11'
if (-not $older -or -not $newer -or $older.Key -ge $newer.Key) {
    throw 'CalVer ordering fixture failed for v2026.9.7 < v2026.9.11.'
}
$previousFixture = Select-HermesPreviousStableTag -BeforeTag 'v2026.9.11' -TagNames @(
    'backup/not-a-release',
    'v2026.9.11',
    'v2026.9.7',
    'v2026.8.30',
    'v2026.9.7.1'
)
if ($previousFixture -cne 'v2026.9.7.1') {
    throw "Previous stable tag selection fixture failed: '$previousFixture'."
}

. $lifecyclePath
. $compatibilityPath

# A different Hermes executable on PATH must never make an isolated Hermes home look
# installed. This regression previously made the E2E test confuse its clean-install
# home with the separate upgrade/rollback home.
$commandFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-command-fixture-' + [Guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $commandFixtureRoot 'foreign-bin'
$isolatedHome = Join-Path $commandFixtureRoot 'isolated-home'
$previousPath = $env:PATH
try {
    New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeBin 'hermes.cmd') -Value '@echo off' -Encoding Ascii
    $env:PATH = "$fakeBin;$previousPath"
    $fixturePaths = [pscustomobject]@{
        HermesHome = $isolatedHome
        InstallDir = Join-Path $isolatedHome 'hermes-agent'
    }
    $resolvedForeign = Get-Command hermes -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $resolvedForeign) { throw 'PATH isolation fixture failed to expose the foreign Hermes command.' }
    $managedCommand = Get-HermesStableCommand -Paths $fixturePaths
    if ($managedCommand) { throw "Managed Hermes command lookup leaked across homes: '$managedCommand'." }
} finally {
    $env:PATH = $previousPath
    Remove-Item -LiteralPath $commandFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Exercise the real CIM-based blocker scan under both PowerShell hosts. The previous
# generic List[object] return path threw `Argument types do not match` on PowerShell 7
# even when the scan itself succeeded.
$blockerProbeDir = Join-Path ([IO.Path]::GetTempPath()) ('hermes-blocker-probe-' + [Guid]::NewGuid().ToString('N'))
$blockerProbe = @(Get-HermesStableBlockingProcesses -InstallDir $blockerProbeDir)
if ($null -eq $blockerProbe) { throw 'Blocker process probe returned null instead of an array.' }

# Fixture-test the isolated human-readable gateway parser.
$check = [char]0x2713
$circle = [char]0x25CB
$dash = [char]0x2014
$fixture = @(
    "$check default (current) $dash PID 1234",
    "$check coder $dash PID 5678",
    "$circle sleeping $dash not running"
)
$parsed = @(ConvertFrom-HermesStableGatewayListOutput -Lines $fixture -Multiplex:$false)
if (($parsed -join ',') -ne 'default,coder') { throw "Gateway parser fixture failed: $($parsed -join ',')" }
$parsedMultiplex = @(ConvertFrom-HermesStableGatewayListOutput -Lines $fixture -Multiplex:$true)
if (($parsedMultiplex -join ',') -ne 'default') { throw "Gateway multiplex parser fixture failed: $($parsedMultiplex -join ',')" }

& (Join-Path $PSScriptRoot 'test-failure-safety.ps1')

if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Warning 'Generated manifest is not present yet. This is expected before the first update-stable workflow run.'
    Write-Host 'Repository tests passed without generated manifest.' -ForegroundColor Green
    exit 0
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.version -notmatch '^\d') { throw 'Manifest version must begin with a digit.' }
$urls = @($manifest.url)
$hashes = @($manifest.hash)
if ($manifest.architecture) {
    $urls = @($manifest.architecture.'64bit'.url)
    $hashes = @($manifest.architecture.'64bit'.hash)
}
if ($urls[0] -notmatch '^https://raw\.githubusercontent\.com/NousResearch/hermes-agent/[0-9a-f]{40,64}/scripts/install\.ps1$') { throw 'Manifest installer URL must be pinned to an exact upstream commit.' }
if ($urls.Count -ne $hashes.Count) { throw 'Every download needs its own checksum.' }
foreach ($hash in $hashes) { if ($hash -notmatch '^[0-9a-f]{64}$') { throw 'Manifest hash must be SHA-256.' } }
if (-not $manifest.installer.script) { throw 'Manifest installer.script is missing.' }
if ($manifest.uninstaller -or $manifest.pre_uninstall -or $manifest.post_uninstall) { throw 'Scoop uninstaller hooks are forbidden by SPEC.md because Scoop runs them during upgrades.' }

$embedded = @($manifest.installer.script)
$expectedEmbedded = @($lifecycleLines) + @('') + @($compatibilityLines)
if ($manifest.architecture) {
    $expectedEmbedded += @('') + @(Get-Content -LiteralPath (Join-Path $root 'scripts\hermes-desktop.ps1'))
    if ($urls.Count -ne 2 -or $urls[1] -notmatch '^https://github.com/longlivelonger/hermes-agent-stable/releases/download/[^/]+/hermes-desktop-windows-x64.zip$') { throw 'Desktop must come from an immutable package release.' }
    if ([string]$embedded[-1] -notmatch '-DesktopSourcePath') { throw 'Desktop payload is not installed.' }
}
if ($embedded.Count -ne ($expectedEmbedded.Count + 1)) { throw 'Embedded lifecycle/compatibility line count differs from source scripts.' }
for ($i = 0; $i -lt $expectedEmbedded.Count; $i++) {
    if ([string]$embedded[$i] -cne [string]$expectedEmbedded[$i]) { throw "Embedded installer script differs from source at line $($i + 1)." }
}
if ([string]$embedded[-1] -notmatch '^Invoke-HermesStableInstall .* -TargetCommit ''[0-9a-f]{40,64}'' ') { throw 'Manifest does not invoke lifecycle with an exact target commit.' }

Write-Host 'Repository tests passed.' -ForegroundColor Green
