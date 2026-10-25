# Rust updater contract: CODEX_INSTALL_IF_LATEST CODEX_INSTALL_IF_CURRENT
# CODEX_INSTALL_DAEMON_ONLY CODEX_INSTALL_DEFER_SELECTION are forwarded unchanged.
$priorErrorPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
$repo = if ($env:CODEFX_GITHUB_REPO) { $env:CODEFX_GITHUB_REPO } else { 'hitmux/codefx' }
$ref = if ($env:CODEFX_INSTALL_REF) { $env:CODEFX_INSTALL_REF } else { 'main' }
if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $repo.Contains('..')) { throw 'Invalid CODEFX_GITHUB_REPO.' }
if ($ref -notmatch '^[A-Za-z0-9_./-]+$' -or $ref.Contains('..') -or $ref.StartsWith('/')) { throw 'Invalid CODEFX_INSTALL_REF.' }
function Get-CodefxBootstrapFile {
    param([string]$Uri, [string]$OutFile)
    if (-not $Uri.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) { throw 'Installer downloads require HTTPS.' }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $request = @{ UseBasicParsing=$true; Uri=$Uri; OutFile="$OutFile.part"; TimeoutSec=120 }
            if ($Uri.StartsWith("https://api.github.com/repos/$repo/", [StringComparison]::OrdinalIgnoreCase) -and $env:CODEFX_GITHUB_TOKEN) {
                $request.Headers = @{ Authorization="Bearer $env:CODEFX_GITHUB_TOKEN" }
            }
            Invoke-WebRequest @request
            Move-Item -LiteralPath "$OutFile.part" -Destination $OutFile -Force
            return
        } catch { if ($attempt -eq 3) { throw }; Start-Sleep -Seconds $attempt }
    }
}
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('codefx-install-' + [guid]::NewGuid().ToString('N'))
$previousEnvironment = @{}
foreach ($key in @('CODEFX_GITHUB_REPO','CODEX_NON_INTERACTIVE','CODEX_INSTALLER_USE_RELEASES_OPENAI_COM')) {
    $previousEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
try {
    New-Item -ItemType Directory -Path $tmpRoot | Out-Null
    if ($env:CODEFX_INSTALLER_URL) { $url = $env:CODEFX_INSTALLER_URL }
    else {
        $sha = $ref
        if ($sha -notmatch '^[0-9a-f]{40}$') {
            Get-CodefxBootstrapFile "https://api.github.com/repos/$repo/commits/$ref" (Join-Path $tmpRoot 'commit.json')
            $sha = (Get-Content -LiteralPath (Join-Path $tmpRoot 'commit.json') -Raw | ConvertFrom-Json).sha
        }
        if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'Cannot resolve installer commit.' }
        $url = "https://raw.githubusercontent.com/$repo/$sha/scripts/install/install.ps1"
    }
    $installer = Join-Path $tmpRoot 'install.ps1'
    Get-CodefxBootstrapFile $url $installer
    $env:CODEFX_GITHUB_REPO = $repo
    if (-not $env:CODEX_NON_INTERACTIVE) { $env:CODEX_NON_INTERACTIVE = '1' }
    if (-not $env:CODEX_INSTALLER_USE_RELEASES_OPENAI_COM) { $env:CODEX_INSTALLER_USE_RELEASES_OPENAI_COM = 'false' }
    $engine = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $engine)) { $engine = Join-Path $PSHOME 'powershell.exe' }
    if (-not (Test-Path -LiteralPath $engine)) { $engine = Join-Path $PSHOME 'pwsh' }
    & $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer @args
    if ($LASTEXITCODE -ne 0) { throw "Codefx installer exited with code $LASTEXITCODE." }
    if ($env:CODEX_INSTALL_DAEMON_ONLY -ne '1' -and $args -notcontains '-DryRun') {
        $bin = if ($env:CODEX_INSTALL_DIR) { $env:CODEX_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin' }
        $env:Path = (@($bin) + @($env:Path.Split(';') | Where-Object { $_ -and $_.TrimEnd('\') -ine $bin.TrimEnd('\') })) -join ';'
        $selected = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $selected -and ($selected.CommandType -ne 'Application' -or -not $selected.Source.Equals((Join-Path $bin 'codex.exe'), [StringComparison]::OrdinalIgnoreCase))) {
            Write-Warning "This PowerShell session resolves codex to $($selected.CommandType) $($selected.Name). Use $bin\codex.exe or adjust the existing alias, function or command cache."
        }
        Write-Host "Codefx executable: $bin\codex.exe"
    }
} finally {
    foreach ($key in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key], 'Process') }
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    $ErrorActionPreference = $priorErrorPreference
}
