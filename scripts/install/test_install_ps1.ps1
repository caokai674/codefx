# Isolated bootstrap and executable-identity checks; performs no installation.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($name in @('install.ps1', 'install-codefx.ps1')) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $name), [ref]$tokens, [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    if ($name -eq 'install.ps1') {
        $installerAst = $ast
        $versionFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-VersionFromBinary'
        }, $true)
        if ($null -eq $versionFunction) { throw 'Missing executable version check.' }
        Invoke-Expression $versionFunction.Extent.Text
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codefx-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $fakeBinary = Join-Path $testRoot 'codex.ps1'
    foreach ($case in @(
        @{ Output = 'codefx 0.165.0'; ExitCode = 0; Expected = '0.165.0' },
        @{ Output = 'codex-cli 0.165.0'; ExitCode = 0; Expected = $null },
        @{ Output = 'codefx 0.165.0'; ExitCode = 1; Expected = $null }
    )) {
        Set-Content -LiteralPath $fakeBinary -Value (
            '$global:LASTEXITCODE = ' + $case.ExitCode + "`n'" + $case.Output + "'"
        )
        $actual = Get-VersionFromBinary -CodexPath $fakeBinary
        if ($actual -cne $case.Expected) {
            throw "Unexpected identity result for $($case.Output), exit $($case.ExitCode): $actual"
        }
    }

    if ($env:OS -eq 'Windows_NT') {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            foreach ($name in @('Test-CodefxGuardedUpdate','Test-CodefxDaemonInstalled','Assert-CodefxDaemonContext','Start-CodefxTransaction')) {
                $definition = $installerAst.Find({ param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true)
                if ($null -eq $definition) { throw "Missing $name" }
                Invoke-Expression $definition.Extent.Text
            }
            $savedLatest = $env:CODEX_INSTALL_IF_LATEST; $savedCurrent = $env:CODEX_INSTALL_IF_CURRENT
            try {
                $env:CODEX_INSTALL_IF_LATEST = $null; $env:CODEX_INSTALL_IF_CURRENT = $null
                $daemonOnly = $false; $oldUpdaterParent = $false; $KeepDaemon = $false
                $codexHome = Join-Path $testRoot 'elevated-preflight'
                $selection = Join-Path $codexHome 'packages\app-server-daemon\current'
                New-Item -ItemType Directory -Path $selection | Out-Null
                $marker = Join-Path $selection 'preserve.txt'
                [IO.File]::WriteAllText($marker, 'original daemon')
                $script:Cf = @{ Prepared = $false }
                $rejected = $false
                try { Start-CodefxTransaction } catch {
                    if ($_.Exception.Message -notmatch 'non-elevated terminal') { throw }
                    $rejected = $true
                }
                if (-not $rejected -or $script:Cf.Prepared -or [IO.File]::ReadAllText($marker) -cne 'original daemon') {
                    throw 'Elevated daemon migration must stop before preparing a transaction or stopping the original daemon.'
                }
            } finally {
                $env:CODEX_INSTALL_IF_LATEST = $savedLatest; $env:CODEX_INSTALL_IF_CURRENT = $savedCurrent
            }
        }
    }

    $global:CodefxTestManagerCalls = 0
    $global:CodefxTestDownloadAttempted = $false
    function npm { $global:CodefxTestManagerCalls++ }
    function bun { $global:CodefxTestManagerCalls++ }
    function pnpm { $global:CodefxTestManagerCalls++ }
    function vp { $global:CodefxTestManagerCalls++ }
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile, [int]$TimeoutSec)
        $global:CodefxTestDownloadAttempted = $true
        throw 'Mock installer download failure'
    }
    $failed = $false
    try {
        & (Join-Path $PSScriptRoot 'install-codefx.ps1')
    } catch {
        if ($_.Exception.Message -notmatch 'Mock installer download failure') { throw }
        $failed = $true
    }
    if (-not $failed -or -not $global:CodefxTestDownloadAttempted -or $global:CodefxTestManagerCalls -ne 0) {
        throw 'Bootstrap download failure must preserve the existing package.'
    }
    # The negative executable case deliberately sets a native exit status.
    $global:LASTEXITCODE = 0
    Write-Host 'PowerShell syntax, executable identity and bootstrap failure checks passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
    Remove-Variable -Name CodefxTestManagerCalls, CodefxTestDownloadAttempted -Scope Global -ErrorAction SilentlyContinue
}
