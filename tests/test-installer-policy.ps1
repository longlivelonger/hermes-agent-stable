param([Parameter(Mandatory = $true)][string]$InstallerPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\hermes-install-compat.ps1')
$original = Get-Content -LiteralPath $InstallerPath -Raw
$source = ConvertTo-HermesStableInstaller -Source $original
function Get-PolicyFunction([string]$Name, [string]$Text = $source) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $node = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true))[0]
    if (-not $node) { throw "Fixture function missing: $Name" }
    return [scriptblock]::Create($node.Extent.Text)
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure: $Message"
}
$work = Join-Path ([IO.Path]::GetTempPath()) ('hermes-policy-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
try {
    # Execute the actual upstream helper with the policy applied, under both
    # PowerShell hosts. A zero exit and a nonzero exit must survive identically.
    & {
        . (Get-PolicyFunction '_Invoke-NativeWithTimeout')
        foreach ($exit in @(0, 73)) {
            $exe = Join-Path $work 'native.cmd'
            Set-Content $exe "@echo native diagnostic 1>&2`r`n@exit /b $exit" -Encoding ascii
            $code = _Invoke-NativeWithTimeout $exe '' $work (Join-Path $work 'native.log') 5
            if ($null -eq $code -or $code -ne $exit) { throw "Expected native exit $exit; got '$code'." }
        }
    }
    # Exercise the actual dependency function. Native uv is replaced at its
    # boundary so a failed locked sync cannot reach any pip fallback.
    & {
        . (Get-PolicyFunction 'Install-Dependencies')
        $InstallDir = $work; $NoVenv = $true; $UvCmd = 'Invoke-FixtureUv'; $PythonVersion = '3.11'
        function Write-Info { }; function Write-Success { }; function Write-Warn { }
        function Complete-VenvTransaction { }; function Restore-VenvBackup { $script:restored = $true }
        function Test-Path { param($Path) return $Path -eq 'uv.lock' -and $script:hasLock }
        function Invoke-NativeWithRelaxedErrorAction { param([scriptblock]$Command) & $Command }
        function Invoke-FixtureUv {
            if ($args[0] -eq 'pip') { throw 'UNLOCKED FALLBACK REACHED' }
            if ($args[0] -eq 'sync') {
                if ($env:UV_NO_CONFIG -ne 'false') { throw 'Project uv configuration remained disabled.' }
                $global:LASTEXITCODE = $script:uvExit
            } else { 'missing-fixture-python' }
        }
        $saved = $env:UV_NO_CONFIG; $savedProject = $env:UV_PROJECT_ENVIRONMENT
        try {
            $env:UV_NO_CONFIG = '1'; $script:hasLock = $true
            $script:uvExit = 1; $script:restored = $false
            Assert-Throws { Install-Dependencies } 'refusing an unlocked'
            if (-not $script:restored) { throw 'Failed sync did not restore the previous venv.' }
            if ($env:UV_NO_CONFIG -ne '1') { throw 'Failed sync leaked uv configuration.' }
            $script:uvExit = 0
            Install-Dependencies
            if ($script:InstalledTier -ne 'hash-verified (uv.lock)') { throw 'Locked tier not selected.' }
            if ($env:UV_NO_CONFIG -ne '1') { throw 'Successful sync leaked uv configuration.' }
            $script:hasLock = $false
            Assert-Throws { Install-Dependencies } 'requires uv.lock'
        } finally { $env:UV_NO_CONFIG = $saved; $env:UV_PROJECT_ENVIRONMENT = $savedProject }
    }
    # A job can install successfully while its parent's PATH remains stale.
    & {
        . (Get-PolicyFunction 'Install-CuaDriver')
        $SkipComputerUse = $false
        function Write-Info { }; function Write-Warn { }; function Write-Success { }
        function Start-Job { return 1 }; function Wait-Job { return $true }
        function Receive-Job { }; function Remove-Job { }
        function Update-ProcessPathForPackages { $script:pathRefreshed = $true }
        function Get-Command {
            if ($script:pathRefreshed) { return [pscustomobject]@{ Source = 'fixture-driver.exe' } }
            return $null
        }
        function Test-CuaDriverRuntimeContract { return $script:driverCompatible }
        $script:pathRefreshed = $false; $script:driverCompatible = $true
        Install-CuaDriver
        if (-not $script:pathRefreshed) { throw 'Driver was checked before refreshing PATH.' }
        $script:pathRefreshed = $false; $script:driverCompatible = $false
        Assert-Throws { Install-CuaDriver } 'runtime verification failed'
    }
    # The npm stage must propagate a failed installation, not just print it.
    & {
        . (Get-PolicyFunction 'Install-NodeDeps')
        $HasNode = $true; $InstallDir = $work
        function Ensure-NodeExeOnPath { }; function Write-Info { }
        function Get-Command { [pscustomobject]@{ Source = (Join-Path $work 'fail-npm.cmd') } }
        Set-Content (Join-Path $work 'package.json') '{}' -Encoding ascii
        Set-Content (Join-Path $work 'fail-npm.cmd') '@exit /b 73' -Encoding ascii
        Assert-Throws { Install-NodeDeps } 'Stable Node dependencies'
    }
    Assert-Throws { ConvertTo-HermesStableInstaller -Source ($original.Replace('function Install-CuaDriver {', 'function Unknown-CuaDriver {')) } 'Unsupported upstream installer'
    if ((Get-Content -LiteralPath $InstallerPath -Raw) -cne $original) { throw 'Pinned installer was modified.' }
    Write-Host 'Pinned installer policy tests passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    $global:LASTEXITCODE = 0
}
