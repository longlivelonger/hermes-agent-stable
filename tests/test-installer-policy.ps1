param([Parameter(Mandatory = $true)][string]$InstallerPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\hermes-install-compat.ps1')
$original = Get-Content -LiteralPath $InstallerPath -Raw -Encoding UTF8
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
    # Repair must work through the actual caller: PowerShell resolves warning
    # functions dynamically from Install-NodeDeps into Install-CuaDriver.
    & {
        . (Get-PolicyFunction 'Install-NodeDeps')
        . (Get-PolicyFunction 'Install-CuaDriver')
        $HasNode = $true; $InstallDir = $work; $SkipComputerUse = $false
        function Ensure-NodeExeOnPath { }; function Install-BrowserUseCli { }
        function Write-Info { }; function Write-Success { }
        function Write-Warn { param($Message) $script:repairWarning = $Message }
        function Get-Command {
            param($Name)
            if ($Name -eq 'npm') { return [pscustomobject]@{ Source = 'fixture-npm.cmd' } }
            if ($Name -eq 'cua-driver') { return [pscustomobject]@{ Source = 'fixture-driver.exe' } }
            throw "Unexpected command lookup: $Name"
        }
        function Test-CuaDriverRuntimeContract { return $script:pathRefreshed -and $script:repairWorks }
        function Start-Job { $script:repairStarted = $true; return 1 }
        function Wait-Job { return $true }; function Receive-Job { }; function Remove-Job { }
        function Update-ProcessPathForPackages { $script:pathRefreshed = $true }
        foreach ($script:repairWorks in @($true, $false)) {
            $script:pathRefreshed = $false; $script:repairStarted = $false; $script:repairWarning = ''
            if ($script:repairWorks) { Install-NodeDeps }
            else { Assert-Throws { Install-NodeDeps } 'runtime verification failed' }
            if (-not $script:repairStarted -or -not $script:pathRefreshed) { throw 'Old driver repair did not run through the Node stage.' }
            if ($script:repairWarning -notlike '*repairing it*') { throw 'Old driver repair warning was lost.' }
        }
    }
    # Exercise real Node-stage subprocesses with tiny local command fixtures.
    # Required components still fail even though warning logging is nonfatal.
    & {
        . (Get-PolicyFunction 'Install-NodeDeps')
        $HasNode = $true; $InstallDir = $work
        function Ensure-NodeExeOnPath { }; function Write-Info { }; function Write-Success { }; function Write-Warn { }
        function Show-NpmCertHint { }; function Write-NpmDebugLogTail { }
        function Install-BrowserUseCli { }; function Install-CuaDriver { $script:reachedCua = $true }
        function Get-Command {
            param($Name)
            if ($Name -eq 'npm' -and $script:hasNpm) { return [pscustomobject]@{ Source = (Join-Path $work 'npm.cmd') } }
            return $null
        }
        Set-Content (Join-Path $work 'package.json') '{}' -Encoding ascii
        $tui = New-Item -ItemType Directory (Join-Path $work 'ui-tui')
        Set-Content (Join-Path $tui.FullName 'package.json') '{}' -Encoding ascii
        Set-Content (Join-Path $work 'npm.cmd') "@if exist fail-npm exit /b 73`r`n@exit /b 0" -Encoding ascii
        $script:hasNpm = $false
        Assert-Throws { Install-NodeDeps } 'requires npm'
        $script:hasNpm = $true
        $savedTemp = $env:TEMP
        try {
            $env:TEMP = $work
            Set-Content (Join-Path $work 'fail-npm') ''
            Assert-Throws { Install-NodeDeps } 'Browser tools npm installation failed'
            Remove-Item (Join-Path $work 'fail-npm')
            Assert-Throws { Install-NodeDeps } 'npx not found'
            foreach ($exit in @(73, 124)) {
                Set-Content (Join-Path $work 'npx.cmd') "@exit /b $exit" -Encoding ascii
                $message = if ($exit -eq 124) { 'Chromium install timed out' } else { 'Chromium install failed -- exit code 73' }
                Assert-Throws { Install-NodeDeps } $message
            }
            Set-Content (Join-Path $work 'npx.cmd') '@exit /b 0' -Encoding ascii
            Set-Content (Join-Path $tui.FullName 'fail-npm') ''
            Assert-Throws { Install-NodeDeps } 'TUI npm installation failed'
            Remove-Item (Join-Path $tui.FullName 'fail-npm')
            $script:reachedCua = $false
            Install-NodeDeps
            if (-not $script:reachedCua) { throw 'Successful Node stages did not reach CUA.' }
        } finally { $env:TEMP = $savedTemp }
    }
    Assert-Throws { ConvertTo-HermesStableInstaller -Source ($original.Replace('function Install-CuaDriver {', 'function Unknown-CuaDriver {')) } 'Unsupported upstream installer'
    if ((Get-Content -LiteralPath $InstallerPath -Raw -Encoding UTF8) -cne $original) { throw 'Pinned installer was modified.' }
    Write-Host 'Pinned installer policy tests passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    $global:LASTEXITCODE = 0
}
