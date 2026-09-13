$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lifecyclePath = Join-Path $root 'scripts\hermes-lifecycle.ps1'
$compatibilityPath = Join-Path $root 'scripts\hermes-install-compat.ps1'
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
    'function Install-HermesStableCommit',
    "'-Branch'",
    'release tag',
    'exact commit verification remains authoritative'
)) {
    if ($compatibilityText -notlike "*$required*") { throw "Installer compatibility script is missing required contract marker: $required" }
}

# Fixture-test the isolated human-readable gateway parser.
. $lifecyclePath
. $compatibilityPath
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

if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Warning 'Generated manifest is not present yet. This is expected before the first update-stable workflow run.'
    Write-Host 'Repository tests passed without generated manifest.' -ForegroundColor Green
    exit 0
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.version -notmatch '^\d') { throw 'Manifest version must begin with a digit.' }
if ($manifest.url -notmatch '^https://raw\.githubusercontent\.com/NousResearch/hermes-agent/[0-9a-f]{40,64}/scripts/install\.ps1$') { throw 'Manifest installer URL must be pinned to an exact upstream commit.' }
if ($manifest.hash -notmatch '^[0-9a-f]{64}$') { throw 'Manifest hash must be SHA-256.' }
if (-not $manifest.installer.script) { throw 'Manifest installer.script is missing.' }
if ($manifest.uninstaller -or $manifest.pre_uninstall -or $manifest.post_uninstall) { throw 'Scoop uninstaller hooks are forbidden by SPEC.md because Scoop runs them during upgrades.' }

$embedded = @($manifest.installer.script)
$expectedEmbedded = @($lifecycleLines) + @('') + @($compatibilityLines)
if ($embedded.Count -ne ($expectedEmbedded.Count + 1)) { throw 'Embedded lifecycle/compatibility line count differs from source scripts.' }
for ($i = 0; $i -lt $expectedEmbedded.Count; $i++) {
    if ([string]$embedded[$i] -cne [string]$expectedEmbedded[$i]) { throw "Embedded installer script differs from source at line $($i + 1)." }
}
if ([string]$embedded[-1] -notmatch '^Invoke-HermesStableInstall .* -TargetCommit ''[0-9a-f]{40,64}'' ') { throw 'Manifest does not invoke lifecycle with an exact target commit.' }

Write-Host 'Repository tests passed.' -ForegroundColor Green
