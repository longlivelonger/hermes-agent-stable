$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\hermes-lifecycle.ps1')
. (Join-Path $root 'scripts\hermes-install-compat.ps1')
function Repair-HermesStableTrackedCheckout { }
function ConvertTo-HermesStableInstaller { param([string]$Source) $Source }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('hermes-stderr-' + [Guid]::NewGuid().ToString('N') + '.ps1')
try {
    foreach ($code in @(0, 73)) {
        @"
param([string]`$Commit, [switch]`$ForceCommit, [switch]`$SkipSetup, [switch]`$NonInteractive, [string]`$HermesHome, [string]`$InstallDir)
[Console]::Error.WriteLine('Installer diagnostic on stderr')
exit $code
"@ | Set-Content -LiteralPath $fixture -Encoding UTF8
        $failed = $false
        try {
            Install-HermesStableCommit -Installer $fixture -Commit ('a' * 40) -Paths @{HermesHome='C:\fixture';InstallDir='C:\fixture\hermes-agent'}
        } catch {
            $failed = $true
            if ($code -eq 0 -or $_.Exception.Message -notlike '*exit 73*') { throw }
        }
        if ($code -eq 73 -and -not $failed) { throw 'Nonzero installer exit was ignored.' }
        if ($ErrorActionPreference -ne 'Stop') { throw 'Installer leaked its error preference.' }
    }
    @'
param([string]$Commit, [switch]$ForceCommit, [switch]$SkipSetup, [switch]$NonInteractive, [string]$HermesHome, [string]$InstallDir, [switch]$SkipComputerUse)
if (-not $SkipComputerUse) { exit 74 }
exit 0
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
    Install-HermesStableCommit -Installer $fixture -Commit ('a' * 40) -Paths @{HermesHome='C:\fixture';InstallDir='C:\fixture\hermes-agent'} -Label 'rollback'
    Write-Host 'Native installer stderr and exit-code tests passed.'
} finally {
    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
}
