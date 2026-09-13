param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Commit,
    [Parameter(Mandatory = $true)][string]$InstallerUrl,
    [Parameter(Mandatory = $true)][string]$InstallerSha256,
    [Parameter(Mandatory = $true)][string]$LifecycleScript,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
if ($Commit -notmatch '^[0-9a-fA-F]{40,64}$') { throw "Invalid release commit '$Commit'." }
$commit = $Commit.ToLowerInvariant()
$lines = @(Get-Content -LiteralPath $LifecycleScript)
$invokeLine = "Invoke-HermesStableInstall -TargetTag '$Tag' -TargetCommit '$commit' -PackageVersion '$Version' -UpstreamInstallerPath (Join-Path `$dir 'install.ps1')"
$scriptLines = @($lines) + @($invokeLine)

$manifest = [ordered]@{
    version = $Version
    description = 'Hermes Agent stable releases for native Windows (unofficial community Scoop package)'
    homepage = 'https://github.com/NousResearch/hermes-agent'
    license = 'MIT'
    url = $InstallerUrl
    hash = $InstallerSha256.ToLowerInvariant()
    installer = [ordered]@{
        script = $scriptLines
    }
    notes = @(
        "Release tag: $Tag",
        "Pinned upstream commit: $commit",
        'Tracks only official non-draft, non-prerelease Hermes Agent GitHub releases.',
        'Existing installs receive a full pre-update backup in %USERPROFILE%\Hermes Backups.',
        'Interactive config migrations are intentionally NOT run during package updates; use: hermes config migrate',
        'This wrapper intentionally has no Scoop uninstaller hook. `scoop uninstall hermes-agent-stable` unregisters the wrapper but leaves Hermes installed.',
        'To remove Hermes while preserving user data, run: hermes uninstall --yes'
    )
}

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Generated $OutputPath for $Tag @ $commit"
