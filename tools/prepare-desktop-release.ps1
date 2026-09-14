param([string]$OutputDirectory = '', [string]$Tag = '')
$ErrorActionPreference = 'Stop'
if (-not $env:RUNNER_TEMP) { throw 'Release preparation must run in GitHub Actions.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $env:RUNNER_TEMP 'hermes-release' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
. (Join-Path $PSScriptRoot 'hermes-release.ps1')
$release = if ($Tag) { Get-HermesReleaseByTag -Tag $Tag } else { Get-HermesStableRelease }
$tag = [string]$release.tag_name
if ($tag -notmatch '^v\d{4}\.\d{1,2}\.\d{1,2}(\.\d+)?$') { throw "Unexpected stable tag $tag" }
$commit = Resolve-HermesTagCommit -Tag $tag
$revision = (Get-Content (Join-Path $PSScriptRoot '..\packaging-revision.txt') -Raw).Trim()
if ($revision -notmatch '^[1-9]\d*$') { throw 'Invalid packaging revision.' }
$version = ($tag -replace '^v', '') + '.' + $revision
$releaseTag = "desktop-$tag-r$revision"
$repo = $env:GITHUB_REPOSITORY
$archive = Join-Path $OutputDirectory 'hermes-desktop-windows-x64.zip'
$published = $false
try {
    $existing = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/$releaseTag" -Headers (Get-HermesReleaseHeaders)
    if ($existing.draft -or $existing.prerelease) { throw "Release $releaseTag exists but is not published stable. Inspect it before retrying." }
    $published = $true
} catch {
    if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
}
if ($published) {
    & gh release download $releaseTag --repo $repo --pattern 'hermes-desktop-windows-x64.zip' --dir $OutputDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Failed to download existing immutable Desktop release.' }
} else {
    $source = Join-Path $env:RUNNER_TEMP ('hermes-desktop-source-' + [Guid]::NewGuid().ToString('N'))
    & git -c core.autocrlf=false clone --depth 1 --branch $tag https://github.com/NousResearch/hermes-agent.git $source
    if ($LASTEXITCODE -ne 0) { throw 'Upstream checkout failed.' }
    $head = & git -C $source rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head.Trim() -ne $commit) { throw 'Release tag changed during build preparation.' }
    $savedSha = $env:GITHUB_SHA
    $savedRef = $env:GITHUB_REF_NAME
    try {
        $env:GITHUB_SHA = $commit
        $env:GITHUB_REF_NAME = $tag
        $env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
        $env:PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = '1'
        Push-Location $source
        try {
            & npm.cmd ci --no-audit --no-fund
            if ($LASTEXITCODE -ne 0) { throw 'Locked Desktop dependency installation failed.' }
            & npm.cmd run pack --workspace apps/desktop
            if ($LASTEXITCODE -ne 0) { throw 'Desktop packaging failed.' }
        } finally { Pop-Location }
    } finally {
        $env:GITHUB_SHA = $savedSha
        $env:GITHUB_REF_NAME = $savedRef
    }
    $payload = Join-Path $source 'apps\desktop\release\win-unpacked'
    $stamp = Get-Content (Join-Path $payload 'resources\install-stamp.json') -Raw | ConvertFrom-Json
    if ($stamp.commit -ne $commit -or $stamp.dirty) { throw 'Packaged Desktop has incorrect provenance.' }
    $archiveRoot = Join-Path $OutputDirectory 'payload'
    New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
    Copy-Item -LiteralPath $payload -Destination (Join-Path $archiveRoot 'desktop') -Recurse
    & tar.exe -a -c -f $archive -C $archiveRoot desktop
    if ($LASTEXITCODE -ne 0) { throw 'Desktop ZIP creation failed.' }
}
$installer = Save-HermesInstallerForCommit -Commit $commit -Destination (Join-Path $OutputDirectory 'install.ps1')
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'build-manifest.ps1') -Version $version -Tag $tag -Commit $commit -InstallerUrl $installer.Url -InstallerSha256 $installer.Sha256 -LifecycleScript (Join-Path $root 'scripts\hermes-lifecycle.ps1') -CompatibilityScript (Join-Path $root 'scripts\hermes-install-compat.ps1') -DesktopUrl "https://github.com/$repo/releases/download/$releaseTag/hermes-desktop-windows-x64.zip" -DesktopSha256 $hash -OutputPath (Join-Path $root 'bucket\hermes-agent-stable.json')
@{
    upstreamTag = $tag; upstreamCommit = $commit; version = $version
    releaseTag = $releaseTag; desktopSha256 = $hash; alreadyPublished = $published
    packageSourceCommit = $env:GITHUB_SHA
} | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'release-plan.json') -Encoding utf8
"$hash  hermes-desktop-windows-x64.zip" | Set-Content (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ascii
@"
Hermes Desktop for Windows x64, paired with Agent $tag at commit $commit.

Install and update through the hermes-agent-stable Scoop package. The ZIP contains the complete unpacked Desktop application. Agent and its Python dependencies are installed by the pinned upstream installer; this is not an offline bundle. The executable is unsigned.

Close Desktop before updating. Built-in manual updates remain unchanged; use Scoop to keep the tested Desktop/Agent pair.
"@ | Set-Content (Join-Path $OutputDirectory 'release-notes.md') -Encoding utf8
foreach ($entry in @{version=$version;tag=$tag;commit=$commit;releaseTag=$releaseTag;published=$published.ToString().ToLowerInvariant();directory=$OutputDirectory}.GetEnumerator()) {
    "$($entry.Key)=$($entry.Value)" | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
}
