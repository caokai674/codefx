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
        @{ Output = 'codefx 0.164.0'; ExitCode = 0; Expected = '0.164.0' },
        @{ Output = 'codex-cli 0.164.0'; ExitCode = 0; Expected = $null },
        @{ Output = 'codefx 0.164.0'; ExitCode = 1; Expected = $null }
    )) {
        Set-Content -LiteralPath $fakeBinary -Value (
            '$global:LASTEXITCODE = ' + $case.ExitCode + "`n'" + $case.Output + "'"
        )
        $actual = Get-VersionFromBinary -CodexPath $fakeBinary
        if ($actual -cne $case.Expected) {
            throw "Unexpected identity result for $($case.Output), exit $($case.ExitCode): $actual"
        }
    }

    $script:managerCalls = 0
    $script:downloadAttempted = $false
    function npm { $script:managerCalls++ }
    function bun { $script:managerCalls++ }
    function pnpm { $script:managerCalls++ }
    function vp { $script:managerCalls++ }
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
        $script:downloadAttempted = $true
        throw 'Mock installer download failure'
    }
    $failed = $false
    try {
        & (Join-Path $PSScriptRoot 'install-codefx.ps1')
    } catch {
        if ($_.Exception.Message -notmatch 'Mock installer download failure') { throw }
        $failed = $true
    }
    if (-not $failed -or -not $script:downloadAttempted -or $script:managerCalls -ne 0) {
        throw 'Bootstrap download failure must preserve the existing package.'
    }
    Write-Host 'PowerShell syntax, executable identity and bootstrap failure checks passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
