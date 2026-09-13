# Shared GitHub release helpers used by manifest generation and CI integration tests.
# This file is not downloaded by end-user package installs.

function Get-HermesReleaseHeaders {
    $headers = @{ 'User-Agent' = 'scoop-hermes-agent-stable' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    return $headers
}

function Get-HermesStableRelease {
    param([int]$Offset = 0)

    $headers = Get-HermesReleaseHeaders
    if ($Offset -eq 0) {
        $uri = 'https://api.github.com/repos/NousResearch/hermes-agent/releases/latest'
        Write-Host "Querying $uri"
        $release = Invoke-RestMethod -Uri $uri -Headers $headers
        if ($release.draft -or $release.prerelease) {
            throw 'GitHub releases/latest unexpectedly returned a draft or prerelease.'
        }
        return $release
    }

    $limit = [Math]::Max(10, ($Offset + 1) * 4)
    $uri = "https://api.github.com/repos/NousResearch/hermes-agent/releases?per_page=$limit"
    Write-Host "Querying $uri for stable release offset $Offset"
    $stable = @(Invoke-RestMethod -Uri $uri -Headers $headers) |
        Where-Object { -not $_.draft -and -not $_.prerelease -and $_.published_at } |
        Sort-Object { [DateTime]$_.published_at } -Descending
    if ($stable.Count -le $Offset) { throw "Could not find stable Hermes release at offset $Offset." }
    return $stable[$Offset]
}

function ConvertTo-HermesCalVer {
    param([Parameter(Mandatory = $true)][string]$Tag)

    if ($Tag -notmatch '^v(?<year>\d{4})\.(?<month>\d{1,2})\.(?<day>\d{1,2})(?:\.(?<patch>\d+))?$') {
        return $null
    }

    $year = [int]$Matches['year']
    $month = [int]$Matches['month']
    $day = [int]$Matches['day']
    $patch = if ($Matches['patch']) { [int]$Matches['patch'] } else { 0 }

    if ($month -lt 1 -or $month -gt 12 -or $day -lt 1 -or $day -gt 31 -or $patch -lt 0 -or $patch -gt 999999) {
        return $null
    }

    $key = ([int64]$year * 10000000000L) + ([int64]$month * 100000000L) + ([int64]$day * 1000000L) + [int64]$patch
    return [pscustomobject]@{
        Tag = $Tag
        Year = $year
        Month = $month
        Day = $day
        Patch = $patch
        Key = $key
    }
}

function Get-HermesPreviousStableTag {
    param([Parameter(Mandatory = $true)][string]$BeforeTag)

    $before = ConvertTo-HermesCalVer -Tag $BeforeTag
    if (-not $before) { throw "Target tag '$BeforeTag' is not a supported Hermes CalVer tag." }

    $headers = Get-HermesReleaseHeaders
    $baseUri = 'https://api.github.com/repos/NousResearch/hermes-agent/git/refs/tags'
    $refs = New-Object System.Collections.Generic.List[object]
    $page = 1

    do {
        if ($page -gt 100) {
            throw 'Hermes tag pagination exceeded 100 pages; refusing an unbounded GitHub API scan.'
        }

        $uri = "$baseUri?per_page=100&page=$page"
        Write-Host "Querying $uri for the stable tag before $BeforeTag"
        $batch = @(Invoke-RestMethod -Uri $uri -Headers $headers)
        foreach ($ref in $batch) { $refs.Add($ref) }
        $page++
    } while ($batch.Count -eq 100)

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($ref in $refs) {
        $name = [string]$ref.ref
        if (-not $name.StartsWith('refs/tags/')) { continue }
        $tag = $name.Substring('refs/tags/'.Length)
        $parsed = ConvertTo-HermesCalVer -Tag $tag
        if ($parsed -and $parsed.Key -lt $before.Key) {
            $candidates.Add($parsed)
        }
    }

    if ($candidates.Count -eq 0) { throw "Could not find an older Hermes CalVer tag before '$BeforeTag'." }
    $previous = $candidates | Sort-Object Key -Descending | Select-Object -First 1
    Write-Host "Previous Hermes stable tag selected for integration test: $($previous.Tag)"
    return [string]$previous.Tag
}

function Get-HermesReleaseByTag {
    param([Parameter(Mandatory = $true)][string]$Tag)

    $headers = Get-HermesReleaseHeaders
    $escaped = [Uri]::EscapeDataString($Tag)
    $uri = "https://api.github.com/repos/NousResearch/hermes-agent/releases/tags/$escaped"
    Write-Host "Querying $uri"
    $release = Invoke-RestMethod -Uri $uri -Headers $headers
    if ($release.draft -or $release.prerelease) { throw "Release '$Tag' is not a stable published release." }
    return $release
}

function Resolve-HermesTagCommit {
    param([Parameter(Mandatory = $true)][string]$Tag)

    $headers = Get-HermesReleaseHeaders
    $escaped = [Uri]::EscapeDataString($Tag)
    $refUri = "https://api.github.com/repos/NousResearch/hermes-agent/git/ref/tags/$escaped"
    Write-Host "Resolving release tag to exact commit: $Tag"
    $ref = Invoke-RestMethod -Uri $refUri -Headers $headers
    $object = $ref.object
    $guard = 0
    while ($object.type -eq 'tag') {
        $guard++
        if ($guard -gt 8) { throw "Annotated tag chain for '$Tag' is unexpectedly deep." }
        $tagObject = Invoke-RestMethod -Uri ([string]$object.url) -Headers $headers
        $object = $tagObject.object
    }
    if ($object.type -ne 'commit') { throw "Tag '$Tag' resolves to '$($object.type)', not a commit." }
    $sha = ([string]$object.sha).ToLowerInvariant()
    if ($sha -notmatch '^[0-9a-f]{40,64}$') { throw "Tag '$Tag' resolved to invalid commit SHA '$sha'." }
    return $sha
}

function Get-HermesInstallerUrlForCommit {
    param([Parameter(Mandatory = $true)][string]$Commit)
    if ($Commit -notmatch '^[0-9a-fA-F]{40,64}$') { throw "Invalid Hermes commit '$Commit'." }
    return "https://raw.githubusercontent.com/NousResearch/hermes-agent/$($Commit.ToLowerInvariant())/scripts/install.ps1"
}

function Save-HermesInstallerForCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $url = Get-HermesInstallerUrlForCommit -Commit $Commit
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Write-Host "Downloading exact-commit installer: $url"
    Invoke-WebRequest -Uri $url -Headers @{ 'User-Agent' = 'scoop-hermes-agent-stable' } -OutFile $Destination | Out-Null
    $text = Get-Content -Raw -LiteralPath $Destination
    if ($text -notmatch '\[string\]\s*\$Commit' -or $text -notmatch '\[switch\]\s*\$ForceCommit') {
        throw "Installer at commit $Commit does not expose required -Commit/-ForceCommit parameters."
    }
    $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -notmatch '^[0-9a-f]{64}$') { throw 'Failed to calculate a valid installer SHA-256.' }
    return [pscustomobject]@{ Url = $url; Sha256 = $hash; Path = $Destination; Commit = $Commit.ToLowerInvariant() }
}
