# Offline, native Windows integration: real PE files, tar archives and junctions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this integration test on Windows.' }
$base = Join-Path $PSScriptRoot 'install.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('codefx native test ' + [char]0x6d4b + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$savedEnv = @{}
foreach ($name in @('CODEX_HOME','CODEX_INSTALL_DIR','CODEX_NON_INTERACTIVE','CODEFX_FIXTURE_COUNTER','CODEFX_FIXTURE_FAIL','Path')) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$savedUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
try {
    $compile = Join-Path $root 'compile.ps1'
    @'
param([string]$Root)
$source = @"
using System;
using System.IO;
public class CodefxFixture {
  public static int Main(string[] args) {
    if (args.Length > 0 && args[0] == "--hold-output-child") { System.Threading.Thread.Sleep(5000); return 0; }
    if (args.Length > 0 && args[0] == "--hold-output") {
      var start = new System.Diagnostics.ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location, "--hold-output-child");
      start.UseShellExecute = false;
      System.Diagnostics.Process.Start(start); return 0;
    }
    if (args.Length > 0 && args[0] == "--version") {
      string file = Environment.GetEnvironmentVariable("CODEFX_FIXTURE_COUNTER");
      int count = File.Exists(file) ? int.Parse(File.ReadAllText(file)) + 1 : 1;
      File.WriteAllText(file, count.ToString());
      if (Environment.GetEnvironmentVariable("CODEFX_FIXTURE_FAIL") == "visible" && count == 3) return 73;
      Console.WriteLine("codefx 0.164.0"); return 0;
    }
    if (Array.IndexOf(args, "update") >= 0 && Environment.GetEnvironmentVariable("CODEFX_FIXTURE_FAIL") == "daemon") return 71;
    string state = Environment.GetEnvironmentVariable("CODEFX_FIXTURE_COUNTER") + ".daemon";
    if (Array.IndexOf(args, "start") >= 0) File.WriteAllText(state, "running");
    if (Array.IndexOf(args, "stop") >= 0 && File.Exists(state)) File.Delete(state);
    Console.WriteLine(File.Exists(state) ? "{\"status\":\"running\",\"appServerVersion\":\"0.164.0\"}" : "{\"status\":\"notRunning\"}"); return 0;
  }
}
"@
Add-Type -TypeDefinition $source -OutputAssembly (Join-Path $Root 'new.exe') -OutputType ConsoleApplication
Add-Type -TypeDefinition 'using System; public class OldFixture { public static int Main(string[] args) { Console.WriteLine("codefx 0.163.0"); return 0; } }' -OutputAssembly (Join-Path $Root 'old.exe') -OutputType ConsoleApplication
'@ | Set-Content -LiteralPath $compile
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compile $root
    if ($LASTEXITCODE -ne 0) { throw 'Fixture compilation failed.' }
    $tokens = $null; $parseErrors = $null
    $installerAst = [System.Management.Automation.Language.Parser]::ParseFile($base, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    $bounded = $installerAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CodefxBounded'
    }, $true)
    Invoke-Expression $bounded.Extent.Text
    $ProcessTimeout = 1
    $watch = [Diagnostics.Stopwatch]::StartNew(); $outputTimedOut = $false
    try { $null = Invoke-CodefxBounded (Join-Path $root 'new.exe') @('--hold-output') } catch {
        if ($_.Exception.Message -notmatch 'Timed out') { throw }
        $outputTimedOut = $true
    }
    if (-not $outputTimedOut -or $watch.Elapsed.TotalSeconds -gt 4) { throw 'Inherited child output pipes bypassed the lifecycle timeout.' }
    $archiveWriter = Join-Path $root 'archive.py'
    @'
from pathlib import Path
import sys, tarfile
package = Path(sys.argv[1])
with tarfile.open(sys.argv[2], 'w:gz') as archive:
    for path in sorted(package.rglob('*')):
        archive.add(path, arcname=str(path.relative_to(package)), recursive=False)
'@ | Set-Content -LiteralPath $archiveWriter -Encoding ASCII
    $target = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
    $asset = "codex-package-$target.tar.gz"
    $fixture = @{ Metadata = $null; Archive = $null; Sums = $null; Active = $false; BadHash = $false; ManagerCalls = 0; Downloads = 0; FailCache = $false }
    function Invoke-RestMethod { param([string]$Uri, [int]$TimeoutSec, [object]$Headers) return $fixture.Metadata }
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile, [int]$TimeoutSec)
        $fixture.Downloads++
        if ($Uri.EndsWith('codex-package_SHA256SUMS') -or $Uri.EndsWith('.sha256')) { Copy-Item -LiteralPath $fixture.Sums -Destination $OutFile }
        else {
            Copy-Item -LiteralPath $fixture.Archive -Destination $OutFile
            if ($fixture.BadHash) { Add-Content -LiteralPath $OutFile -Value 'corruption' }
        }
    }
    function Move-Item {
        param([string]$LiteralPath, [string]$Destination, [switch]$Force, [object]$ErrorAction)
        if ($fixture.FailCache -and $LiteralPath.EndsWith('codefx-update-source.next')) { throw 'Mock update-source commit failure.' }
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }
    function Get-CimInstance {
        param([string]$ClassName, [string]$Filter, [object]$ErrorAction)
        if ($Filter -match '^ProcessId') { return [pscustomobject]@{ ParentProcessId = 0 } }
        if ($fixture.Active) { [pscustomobject]@{ Name = 'codex.exe'; ProcessId = 999999; ParentProcessId = 1; ExecutablePath = 'C:\fixture\codex.exe' } }
    }
    function Invoke-CimMethod { param($InputObject, $MethodName, $ErrorAction) [pscustomobject]@{ ReturnValue=0; Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value } }
    function npm { $fixture.ManagerCalls++; throw 'Unexpected package-manager mutation.' }
    function pnpm { $fixture.ManagerCalls++; throw 'Unexpected package-manager mutation.' }
    function bun { $fixture.ManagerCalls++; throw 'Unexpected package-manager mutation.' }
    function vp { $fixture.ManagerCalls++; throw 'Unexpected package-manager mutation.' }

    foreach ($case in @('success','checksum','target','active','dry-run','visible','daemon','repeat','guarded','daemon-running','active-timeout','committed-recovery','interrupted-recovery','cache-rollback','flat-native','flat-rollback','empty-native','empty-rollback','unknown-native','sidecar','daemon-managed-only')) {
        Write-Host "Native Windows case: $case"
        $caseRoot = Join-Path $root $case
        $package = Join-Path $caseRoot 'package'
        foreach ($folder in @('bin','codex-path','codex-resources')) { New-Item -ItemType Directory -Force -Path (Join-Path $package $folder) | Out-Null }
        foreach ($file in @('bin\codex.exe','bin\codex-code-mode-host.exe','codex-path\rg.exe','codex-resources\codex-command-runner.exe','codex-resources\codex-windows-sandbox-setup.exe')) {
            Copy-Item -LiteralPath (Join-Path $root 'new.exe') -Destination (Join-Path $package $file)
        }
        @{ version='0.164.0'; target=$(if ($case -eq 'target') { 'wrong-target' } else { $target }); entrypoint='bin/codex.exe' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $package 'codex-package.json')
        $fixture.Archive = Join-Path $caseRoot $asset
        & python $archiveWriter $package $fixture.Archive
        if ($LASTEXITCODE -ne 0) { throw 'Fixture archive creation failed.' }
        $fixture.Sums = Join-Path $caseRoot 'codex-package_SHA256SUMS'
        ((Get-FileHash -LiteralPath $fixture.Archive -Algorithm SHA256).Hash.ToLowerInvariant() + "  $asset") |
            Set-Content -LiteralPath $fixture.Sums -Encoding ASCII
        $fixture.Metadata = @{ tag_name='rust-v0.164.0'; assets=@(
            @{ name=$asset; digest=('sha256:' + (Get-FileHash $fixture.Archive).Hash.ToLowerInvariant()); browser_download_url="https://fixture.invalid/$asset" },
            @{ name='codex-package_SHA256SUMS'; digest=('sha256:' + (Get-FileHash $fixture.Sums).Hash.ToLowerInvariant()); browser_download_url='https://fixture.invalid/codex-package_SHA256SUMS' }
        ) }
        if ($case -eq 'sidecar') {
            $fixture.Metadata.assets[1].name = "$target.sha256"
            $fixture.Metadata.assets[1].browser_download_url = "https://fixture.invalid/$target.sha256"
        }
        $fixture.Active = $case -in @('active','active-timeout'); $fixture.BadHash = $case -eq 'checksum'; $fixture.FailCache = $case -eq 'cache-rollback'
        $env:CODEX_HOME = Join-Path $caseRoot 'home'
        $env:CODEX_INSTALL_DIR = Join-Path $caseRoot 'visible bin'
        $env:CODEX_NON_INTERACTIVE = '1'
        $env:CODEFX_FIXTURE_COUNTER = Join-Path $caseRoot 'counter'
        $env:CODEFX_FIXTURE_FAIL = if ($case -in @('flat-rollback','empty-rollback')) { 'visible' } else { $case }
        $standalone = Join-Path $env:CODEX_HOME 'packages\standalone'
        $release = Join-Path $standalone "releases\0.164.0-$target"
        New-Item -ItemType Directory -Force -Path (Join-Path $release 'bin') | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'old.exe') -Destination (Join-Path $release 'bin\codex.exe')
        New-Item -ItemType Junction -Path (Join-Path $standalone 'current') -Target $release | Out-Null
        if ($case -in @('flat-native','flat-rollback','unknown-native','empty-native','empty-rollback')) {
            New-Item -ItemType Directory -Path $env:CODEX_INSTALL_DIR | Out-Null
            if ($case -notin @('empty-native','empty-rollback')) {
                Copy-Item -LiteralPath (Join-Path $root 'old.exe') -Destination (Join-Path $env:CODEX_INSTALL_DIR 'codex.exe')
                Copy-Item -LiteralPath (Join-Path $root 'old.exe') -Destination (Join-Path $env:CODEX_INSTALL_DIR 'rg.exe')
            }
            if ($case -eq 'unknown-native') { 'preserve this file' | Set-Content -LiteralPath (Join-Path $env:CODEX_INSTALL_DIR 'keep.txt') }
        } else { New-Item -ItemType Junction -Path $env:CODEX_INSTALL_DIR -Target (Join-Path $standalone 'current\bin') | Out-Null }
        $oldHash = (Get-FileHash (Join-Path $release 'bin\codex.exe')).Hash
        $cache = Join-Path $env:CODEX_HOME 'version.json'
        $oldCache = '{"latest_version":"999.0.0","dismissed_version":"999.0.0"}'
        [IO.File]::WriteAllText($cache, $oldCache)
        if ($case -in @('daemon','daemon-running','daemon-managed-only')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $env:CODEX_HOME 'app-server-daemon') | Out-Null
            '{}' | Set-Content -LiteralPath (Join-Path $env:CODEX_HOME 'app-server-daemon\settings.json')
            $daemonRelease = Join-Path $env:CODEX_HOME 'packages\app-server-daemon\releases\old'
            New-Item -ItemType Directory -Force -Path $daemonRelease | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $env:CODEX_HOME 'packages\app-server-daemon\current') -Target $daemonRelease | Out-Null
        }
        if ($case -eq 'daemon-running') {
            $shims = Join-Path $caseRoot 'npm shims'; New-Item -ItemType Directory -Path $shims | Out-Null
            @'
@echo off
if "%1"=="--version" (echo codex-cli 0.163.0& exit /b 0)
if "%3"=="version" (echo {"status":"running","appServerVersion":"0.163.0"}& exit /b 0)
if "%3"=="stop" (del "%CODEFX_FIXTURE_COUNTER%.daemon"& echo {"status":"stopped"}& exit /b 0)
if "%3"=="start" (echo running>"%CODEFX_FIXTURE_COUNTER%.daemon"& echo {"status":"started"}& exit /b 0)
exit /b 1
'@ | Set-Content -LiteralPath (Join-Path $shims 'codex.cmd') -Encoding ASCII
            'running' | Set-Content -LiteralPath ($env:CODEFX_FIXTURE_COUNTER + '.daemon')
            $env:Path = "$shims;$env:Path"
        }
        if ($case -eq 'daemon-managed-only') {
            [IO.Directory]::Delete($env:CODEX_INSTALL_DIR)
            Copy-Item -LiteralPath (Join-Path $root 'new.exe') -Destination (Join-Path $release 'bin\codex.exe') -Force
            'running' | Set-Content -LiteralPath ($env:CODEFX_FIXTURE_COUNTER + '.daemon')
            $env:Path = "$env:SystemRoot\System32;$env:SystemRoot;$PSHOME"
        }
        $failed = $false
        try {
            if ($case -eq 'active-timeout') { & $base -Release '0.164.0' -StopRunning -ProcessTimeout 2 }
            elseif ($case -in @('daemon-running','daemon-managed-only')) { & $base -Release '0.164.0' -StopRunning -ProcessTimeout 10 }
            elseif ($case -eq 'dry-run') { & $base -Release '0.164.0' -DryRun }
            else { & $base -Release '0.164.0' -ProcessTimeout 3 }
        } catch { $failed = $true; Write-Host "Expected failure if negative case: $_" }
        $negative = $case -in @('checksum','target','active','active-timeout','visible','daemon','cache-rollback','flat-rollback','empty-rollback','unknown-native')
        if ($failed -ne $negative) { throw "Unexpected installer result for $case (failed=$failed)." }
        if ($negative -or $case -eq 'dry-run') {
            if ([IO.File]::ReadAllText($cache) -cne $oldCache) { throw "Original version cache was not restored for $case." }
            if ($case -eq 'empty-rollback') {
                $emptyItem = Get-Item -LiteralPath $env:CODEX_INSTALL_DIR
                if (($emptyItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or @(Get-ChildItem -LiteralPath $env:CODEX_INSTALL_DIR -Force).Count -ne 0) { throw 'Original empty directory was not restored.' }
            } elseif ((Get-FileHash (Join-Path $env:CODEX_INSTALL_DIR 'codex.exe')).Hash -ne $oldHash) { throw "Original installation was not restored for $case." }
            if ($case -eq 'unknown-native' -and (Get-Content -LiteralPath (Join-Path $env:CODEX_INSTALL_DIR 'keep.txt')) -ne 'preserve this file') { throw 'Unknown directory contents changed.' }
        } else {
            if (Test-Path -LiteralPath $cache) { throw "Official version cache was retained for $case." }
            $output = & (Join-Path $env:CODEX_INSTALL_DIR 'codex.exe') --version
            if ($output -ne 'codefx 0.164.0') { throw "New entrypoint failed for $case." }
            if ($case -eq 'repeat') {
                [IO.File]::WriteAllText($cache, '{"dismissed_version":"0.165.0"}')
                & $base -Release '0.164.0' -ProcessTimeout 3
                if ([IO.File]::ReadAllText($cache) -cne '{"dismissed_version":"0.165.0"}') { throw 'Same-source update lost version dismissals.' }
            }
            if ($case -in @('committed-recovery','interrupted-recovery')) {
                $receipt = Get-ChildItem -LiteralPath $standalone -Directory -Force -Filter '.rollback.*' | Select-Object -First 1
                $journal = Join-Path $receipt.FullName 'journal.json'
                if ($case -eq 'interrupted-recovery') {
                    $record = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
                    $record.Committed = $false
                    $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $journal -Encoding UTF8
                    $fixture.BadHash = $true
                }
                Move-Item -LiteralPath $receipt.FullName -Destination (Join-Path $standalone '.transaction')
                $downloadsBeforeRecovery = $fixture.Downloads
                $recoveryFailed = $false
                try { & $base -Release '0.164.0' -ProcessTimeout 3 } catch { $recoveryFailed = $true }
                if ($case -eq 'committed-recovery') {
                    if ($recoveryFailed -or $fixture.Downloads -ne $downloadsBeforeRecovery) { throw 'Committed recovery repeated or rolled back a successful installation.' }
                } else {
                    if (-not $recoveryFailed -or (Get-FileHash (Join-Path $env:CODEX_INSTALL_DIR 'codex.exe')).Hash -ne $oldHash) { throw 'Interrupted recovery did not preserve the original executable.' }
                }
            }
            if ($case -eq 'guarded') {
                # A stale guarded updater must leave a pinned installation intact.
                $env:CODEX_INSTALL_IF_LATEST='1'; $env:CODEX_UPDATE_FROM_RELEASE='stale-selection'
                try { & $base -ProcessTimeout 3 } finally { Remove-Item Env:CODEX_INSTALL_IF_LATEST, Env:CODEX_UPDATE_FROM_RELEASE }
            }
        }
        if ($case -in @('daemon-running','daemon-managed-only') -and -not (Test-Path -LiteralPath ($env:CODEFX_FIXTURE_COUNTER + '.daemon'))) { throw 'Running daemon state was not restored.' }
        if (@(Get-ChildItem -LiteralPath (Join-Path $standalone 'releases') -Directory -Force -Filter '.staging.*').Count -gt 0) { throw "Unfinished staging files for $case." }
        if (Test-Path -LiteralPath (Join-Path $standalone '.transaction')) { throw "Unfinished transaction for $case." }
        $env:Path = $savedEnv.Path
    }
    if ($fixture.ManagerCalls -ne 0) { throw 'Package-manager registrations were changed.' }
    $global:LASTEXITCODE = 0
    Write-Host 'Native Windows transaction, rollback, process guard, idempotence and PowerShell compatibility checks passed.'
} finally {
    [Environment]::SetEnvironmentVariable('Path', $savedUserPath, 'User')
    foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process') }
    # Remove junctions themselves before removing the disposable fixture tree.
    Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { [IO.Directory]::Delete($_.FullName) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
