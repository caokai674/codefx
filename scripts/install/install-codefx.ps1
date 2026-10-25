$ErrorActionPreference = 'Stop'
$repo = if ($env:CODEFX_GITHUB_REPO) { $env:CODEFX_GITHUB_REPO } else { 'hitmux/codefx' }
$ref = if ($env:CODEFX_INSTALL_REF) { $env:CODEFX_INSTALL_REF } else { 'main' }
$url = if ($env:CODEFX_INSTALLER_URL) { $env:CODEFX_INSTALLER_URL } else { "https://raw.githubusercontent.com/$repo/$ref/scripts/install/install.ps1" }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("codefx-install-" + [guid]::NewGuid().ToString('N') + '.ps1')
try {
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
  $env:CODEFX_GITHUB_REPO = $repo
  $env:CODEFX_REPLACE_OFFICIAL = '1'
  if (-not $env:CODEX_NON_INTERACTIVE) { $env:CODEX_NON_INTERACTIVE = '1' }
  & powershell -ExecutionPolicy Bypass -File $tmp @args
  if ($LASTEXITCODE) { exit $LASTEXITCODE }
} finally {
  Remove-Item -Force -ErrorAction SilentlyContinue $tmp
}
