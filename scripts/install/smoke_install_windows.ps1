# Real public-package installation and daemon checks in a disposable CI profile.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:CODEFX_TEST_ROOT) { throw 'An isolated CODEFX_TEST_ROOT is required.' }
if ($env:RELEASE_TAG -notmatch '^rust-v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Invalid release tag.' }
$version = $env:RELEASE_TAG.Substring(6)
$env:CODEX_HOME = Join-Path $env:CODEFX_TEST_ROOT ('codefx smoke ' + [char]0x6d4b + '\home')
$env:CODEX_INSTALL_DIR = Join-Path $env:CODEFX_TEST_ROOT ('codefx smoke ' + [char]0x6d4b + '\visible bin')
$cli = Join-Path $env:CODEX_INSTALL_DIR 'codex.exe'
try {
    & (Join-Path $PSScriptRoot 'install-codefx.ps1') -Release $version -ProcessTimeout 120
    $actual = & $cli --version
    if ($LASTEXITCODE -ne 0 -or $actual -cne "codefx $version") { throw 'Published command failed.' }
    $current = Join-Path $env:CODEX_HOME 'packages\standalone\current'
    $metadata = Get-Content -LiteralPath (Join-Path $current 'codex-package.json') -Raw | ConvertFrom-Json
    if ($metadata.target -cne $env:EXPECTED_TARGET) { throw 'Architecture mismatch.' }
    & (Join-Path $current 'codex-path\rg.exe') --version
    if ($LASTEXITCODE -ne 0) { throw 'Bundled rg failed.' }
    & (Join-Path $PSScriptRoot 'install.ps1') -Release $version -ProcessTimeout 120
    & $cli app-server daemon start
    if ($LASTEXITCODE -ne 0) { throw 'Native daemon start failed.' }
    & $cli app-server daemon update --from-cli --yes
    if ($LASTEXITCODE -ne 0) { throw 'Daemon package bootstrap failed.' }
    $before = (& $cli app-server daemon version) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $before.status -ne 'running') { throw 'Daemon did not become healthy.' }
    & (Join-Path $PSScriptRoot 'install.ps1') -Release $version -StopRunning -ProcessTimeout 120
    $after = (& $cli app-server daemon version) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $after.status -ne 'running' -or $after.appServerVersion -cne $version) { throw 'Installer did not restore the running native daemon.' }
    if (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'packages\standalone\.transaction')) { throw 'Unfinished installation transaction.' }
    $global:LASTEXITCODE = 0
} finally {
    if (Test-Path -LiteralPath $cli) { & $cli app-server daemon stop }
}
