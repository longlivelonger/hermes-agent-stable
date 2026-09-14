param(
    [string]$OutputPath = '',
    [string]$Tag = '',
    [int]$StableOffset = 0
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
# Legacy Agent-only fixture generator. It must never replace the Desktop package.
if (-not $OutputPath) { throw 'Use the Desktop release workflow to publish. Agent-only fixtures require an explicit -OutputPath outside bucket/hermes-agent-stable.json.' }
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ($destination -eq (Join-Path $repoRoot 'bucket\hermes-agent-stable.json')) { throw 'The Agent-only generator cannot overwrite the published Desktop manifest.' }
$lifecycle = Join-Path $repoRoot 'scripts\hermes-lifecycle.ps1'
$compatibility = Join-Path $repoRoot 'scripts\hermes-install-compat.ps1'
$builder = Join-Path $PSScriptRoot 'build-manifest.ps1'
. (Join-Path $PSScriptRoot 'hermes-release.ps1')

$release = if ($Tag) { Get-HermesReleaseByTag -Tag $Tag } else { Get-HermesStableRelease -Offset $StableOffset }
$tag = [string]$release.tag_name
if ([string]::IsNullOrWhiteSpace($tag)) { throw 'Selected release has no tag_name.' }
$version = $tag -replace '^v', ''
if ($version -notmatch '^\d') { throw "Unexpected Hermes release tag '$tag'; refusing to publish automatically." }

$commit = Resolve-HermesTagCommit -Tag $tag
$temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-install-" + [Guid]::NewGuid().ToString('N') + '.ps1')
try {
    $installer = Save-HermesInstallerForCommit -Commit $commit -Destination $temp
    & $builder -Version $version -Tag $tag -Commit $commit -InstallerUrl $installer.Url -InstallerSha256 $installer.Sha256 -LifecycleScript $lifecycle -CompatibilityScript $compatibility -OutputPath $OutputPath
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}

if ($env:GITHUB_OUTPUT) {
    "version=$version" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    "tag=$tag" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    "commit=$commit" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
Write-Host "Stable release selected: $tag @ $commit ($($release.name))"
