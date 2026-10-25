[CmdletBinding()]
param(
    [string]$Release = $env:CODEX_RELEASE,
    [switch]$DryRun,
    [switch]$StopRunning,
    [switch]$DeferUntilIdle,
    [switch]$KeepDaemon,
    [ValidateRange(1,300)][int]$ProcessTimeout = 30,
    [ValidateRange(1,3600)][int]$IdleWaitTimeout = 900,
    [ValidateRange(1,600)][int]$LockTimeout = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if ($DeferUntilIdle -and $StopRunning) {
    throw '-DeferUntilIdle and -StopRunning are mutually exclusive.'
}

if ([string]::IsNullOrWhiteSpace($Release)) {
    $Release = "latest"
}

$NonInteractive = $env:CODEX_NON_INTERACTIVE -match "^(?i:1|true|yes)$"
$CodefxGithubRepo = if ([string]::IsNullOrWhiteSpace($env:CODEFX_GITHUB_REPO)) { "hitmux/codefx" } else { $env:CODEFX_GITHUB_REPO }
$CodefxReplaceOfficial = $env:CODEFX_REPLACE_OFFICIAL -match "^(?i:1|true|yes)$"
$DefaultPreferReleasesOpenAICom = $false
$PreferReleasesOpenAICom = if ([string]::IsNullOrWhiteSpace($env:CODEX_INSTALLER_USE_RELEASES_OPENAI_COM)) {
    $DefaultPreferReleasesOpenAICom
} else {
    $env:CODEX_INSTALLER_USE_RELEASES_OPENAI_COM -match "^(?i:1|true|yes)$"
}
$ReleasesBaseUri = "https://releases.openai.com/codex"
$ReleasesMetadataTimeoutSec = 30
$ReleasesAssetTimeoutSec = 300

function Write-Step {
    param(
        [string]$Message
    )

    Write-Host "==> $Message"
}

function Write-WarningStep {
    param(
        [string]$Message
    )

    Write-Warning $Message
}

function Prompt-YesNo {
    param(
        [string]$Prompt
    )

    if ($NonInteractive) {
        return $false
    }

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return $false
    }

    $choice = Read-Host "$Prompt [y/N]"
    return $choice -match "^(?i:y(?:es)?)$"
}

function Normalize-Version {
    param(
        [string]$RawVersion
    )

    if ([string]::IsNullOrWhiteSpace($RawVersion) -or $RawVersion -eq "latest") {
        return "latest"
    }

    if ($RawVersion.StartsWith("rust-v")) {
        return $RawVersion.Substring(6)
    }

    if ($RawVersion.StartsWith("v")) {
        return $RawVersion.Substring(1)
    }

    return $RawVersion
}

function Assert-ValidReleaseVersion {
    param(
        [string]$Version
    )

    if ($Version -cne "latest" -and $Version -cnotmatch "^[0-9]+\.[0-9]+\.[0-9]+(?:-alpha(?:\.[0-9]+){0,2}|-beta(?:\.[0-9]+)?)?$") {
        throw "Invalid Codefx release version: $Version. Expected latest or x.y.z[-alpha[.N[.M]]|-beta[.N]]."
    }
}

function Find-ReleaseAssetMetadata {
    param(
        [string]$AssetName,
        [object]$ReleaseMetadata,
        [string]$Url = $null,
        [string]$FallbackUrl = $null
    )

    $asset = $ReleaseMetadata.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if ($null -eq $asset) {
        return $null
    }

    $digestMatch = [regex]::Match([string]$asset.digest, "^sha256:([0-9a-fA-F]{64})$")
    if (-not $digestMatch.Success) {
        throw "Could not find SHA-256 digest for release asset $AssetName."
    }

    return [PSCustomObject]@{
        Url = if ([string]::IsNullOrWhiteSpace($Url)) { $asset.browser_download_url } else { $Url }
        FallbackUrl = $FallbackUrl
        Sha256 = $digestMatch.Groups[1].Value.ToLowerInvariant()
    }
}

function Invoke-CodefxDownload {
    param([string]$Uri, [string]$OutFile)
    if (([uri]$Uri).Scheme -ne 'https') { throw 'Downloads require HTTPS.' }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec $ReleasesAssetTimeoutSec
            return
        } catch { if ($attempt -eq 3) { throw }; Start-Sleep -Seconds $attempt }
    }
}

function Invoke-WebRequestWithFallback {
    param(
        [object]$Metadata,
        [string]$OutFile,
        [string]$ExpectedDigest,
        [string]$AssetName,
        [string]$ReleaseVersion,
        [string]$RequiredManifestAsset
    )

    try {
        if ($Metadata.Url.StartsWith("$ReleasesBaseUri/", [System.StringComparison]::OrdinalIgnoreCase)) {
            Invoke-WebRequest -UseBasicParsing -Uri $Metadata.Url -OutFile $OutFile -TimeoutSec $ReleasesAssetTimeoutSec
        } else {
            Invoke-CodefxDownload -Uri $Metadata.Url -OutFile $OutFile
        }
        Test-ArchiveDigest -ArchivePath $OutFile -ExpectedDigest $ExpectedDigest
        if (-not [string]::IsNullOrWhiteSpace($RequiredManifestAsset)) {
            $null = Get-PackageArchiveDigest -ManifestPath $OutFile -AssetName $RequiredManifestAsset
        }
    } catch {
        if ([string]::IsNullOrWhiteSpace($Metadata.FallbackUrl)) {
            throw
        }
        Write-WarningStep "Could not download or verify $($Metadata.Url); retrying from GitHub Releases."
        Invoke-CodefxDownload -Uri $Metadata.FallbackUrl -OutFile $OutFile
        try {
            Test-ArchiveDigest -ArchivePath $OutFile -ExpectedDigest $ExpectedDigest
            if (-not [string]::IsNullOrWhiteSpace($RequiredManifestAsset)) {
                $null = Get-PackageArchiveDigest -ManifestPath $OutFile -AssetName $RequiredManifestAsset
            }
        } catch {
            $githubRelease = Resolve-ReleaseFromGitHub -NormalizedVersion $ReleaseVersion
            $githubAssetMetadata = Find-ReleaseAssetMetadata -AssetName $AssetName -ReleaseMetadata $githubRelease.Metadata
            if ($null -eq $githubAssetMetadata) {
                throw "Could not find GitHub release metadata for asset $AssetName."
            }
            Test-ArchiveDigest -ArchivePath $OutFile -ExpectedDigest $githubAssetMetadata.Sha256
            if (-not [string]::IsNullOrWhiteSpace($RequiredManifestAsset)) {
                $null = Get-PackageArchiveDigest -ManifestPath $OutFile -AssetName $RequiredManifestAsset
            }
        }
    }
}

function Resolve-ReleaseAssetSelection {
    param(
        [object]$ResolvedRelease,
        [string]$Target,
        [string]$NpmTag
    )

    $version = $ResolvedRelease.Version
    $releaseMetadata = $ResolvedRelease.Metadata
    $packageAsset = "codex-package-$Target.tar.gz"
    $checksumAsset = "codex-package_SHA256SUMS"
    if ($null -ne (Find-ReleaseAssetMetadata -AssetName "$Target.sha256" -ReleaseMetadata $releaseMetadata)) { $checksumAsset = "$Target.sha256" }
    $packageUrl = $null
    $packageFallbackUrl = $null
    $checksumUrl = $null
    $checksumFallbackUrl = $null
    if ($ResolvedRelease.Source -eq "ReleasesOpenAICom") {
        $packageUrl = "$ReleasesBaseUri/releases/$version/$packageAsset"
        $packageFallbackUrl = "https://github.com/$CodefxGithubRepo/releases/download/rust-v$version/$packageAsset"
        $checksumUrl = "$ReleasesBaseUri/releases/$version/$checksumAsset"
        $checksumFallbackUrl = "https://github.com/$CodefxGithubRepo/releases/download/rust-v$version/$checksumAsset"
    }

    $packageMetadata = Find-ReleaseAssetMetadata -AssetName $packageAsset -ReleaseMetadata $releaseMetadata -Url $packageUrl -FallbackUrl $packageFallbackUrl
    $checksumMetadata = Find-ReleaseAssetMetadata -AssetName $checksumAsset -ReleaseMetadata $releaseMetadata -Url $checksumUrl -FallbackUrl $checksumFallbackUrl
    if ($null -ne $packageMetadata -and $null -ne $checksumMetadata) {
        return [PSCustomObject]@{
            PackageAsset = $packageAsset
            PackageMetadata = $packageMetadata
            ChecksumMetadata = $checksumMetadata
            ChecksumAsset = $checksumAsset
            InstallLayout = "Package"
        }
    }

    $packageAsset = "codex-npm-$NpmTag-$version.tgz"
    $packageUrl = $null
    $packageFallbackUrl = $null
    if ($ResolvedRelease.Source -eq "ReleasesOpenAICom") {
        $packageUrl = "$ReleasesBaseUri/releases/$version/$packageAsset"
        $packageFallbackUrl = "https://github.com/$CodefxGithubRepo/releases/download/rust-v$version/$packageAsset"
    }
    $packageMetadata = Find-ReleaseAssetMetadata -AssetName $packageAsset -ReleaseMetadata $releaseMetadata -Url $packageUrl -FallbackUrl $packageFallbackUrl
    if ($null -eq $packageMetadata) {
        throw "Could not find Codex package or platform npm release assets for Codefx $version."
    }

    return [PSCustomObject]@{
        PackageAsset = $packageAsset
        PackageMetadata = $packageMetadata
        ChecksumMetadata = $null
        ChecksumAsset = "codex-package_SHA256SUMS"
        InstallLayout = "LegacyPlatformNpm"
    }
}

function Test-ArchiveDigest {
    param(
        [string]$ArchivePath,
        [string]$ExpectedDigest
    )

    # A native launcher can pass PowerShell 7 module paths to Windows PowerShell,
    # preventing Get-FileHash from loading. Hash directly without module lookup.
    $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArchivePath)
    $sha256 = [System.Security.Cryptography.SHA256CryptoServiceProvider]::new()
    try {
        $stream = [System.IO.File]::OpenRead($providerPath)
        try {
            $actualDigest = [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace("-", "").ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }

    if ($actualDigest -ne $ExpectedDigest) {
        throw "Downloaded Codex archive checksum did not match expected digest. Expected $ExpectedDigest but got $actualDigest."
    }
}

function Get-PackageArchiveDigest {
    param(
        [string]$ManifestPath,
        [string]$AssetName
    )

    $escapedAssetName = [regex]::Escape($AssetName)
    foreach ($line in Get-Content -LiteralPath $ManifestPath) {
        $match = [regex]::Match($line, "^\s*([0-9a-fA-F]{64})\s+$escapedAssetName\s*$")
        if ($match.Success) {
            return $match.Groups[1].Value.ToLowerInvariant()
        }
    }

    throw "Could not find SHA-256 digest for $AssetName in codex-package_SHA256SUMS."
}

function Path-Contains {
    param(
        [string]$PathValue,
        [string]$Entry
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }

    $needle = $Entry.TrimEnd("\")
    foreach ($segment in $PathValue.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment.TrimEnd("\") -ieq $needle) {
            return $true
        }
    }

    return $false
}

function Find-CodefxCommandOnPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    foreach ($entry in $PathValue.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
        $directory = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
        if ($directory -notmatch '^[A-Za-z]:[\\/]') { continue }
        try { if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($directory)).DriveType -eq [IO.DriveType]::Network) { continue } } catch { continue }
        foreach ($extension in @('.ps1','.exe','.cmd','.bat','.com')) {
            $candidate = Join-Path $directory ("codex" + $extension)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return $null
}

function Prepend-PathEntry {
    param(
        [string]$PathValue,
        [string]$Entry
    )

    $needle = $Entry.TrimEnd("\")
    $segments = @($Entry)
    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        $segments += $PathValue.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries) |
            Where-Object { $_.TrimEnd("\") -ine $needle }
    }

    return ($segments -join ";")
}

function Invoke-WithInstallLock {
    param(
        [string]$LockPath,
        [scriptblock]$Script
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LockPath) | Out-Null
    $lock = $null
    $lockDeadline = [DateTime]::UtcNow.AddSeconds($LockTimeout)
    while ($null -eq $lock) {
        try {
            $lock = [System.IO.File]::Open(
                $LockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $lockDeadline) { throw "Installer lock timed out." }
            Start-Sleep -Milliseconds 250
        }
    }
    try {
        & $Script
        if ($script:Cf.Prepared) {
            $script:Cf.Committed = $true
            try { Save-CodefxJournal } catch { $script:Cf.Committed = $false; throw }
            Complete-CodefxReceipt
        }
    } catch {
        if ($script:Cf.Prepared -and -not $script:Cf.Committed) {
            Write-WarningStep 'Restoring the previous installation after an incomplete transaction.'
            try { Undo-CodefxTransaction; Remove-Item -LiteralPath $script:Cf.Root -Recurse -Force }
            catch { Write-WarningStep "Rollback needs attention; recovery files retained at $($script:Cf.Root): $_" }
        }
        throw
    } finally {
        try {
            if ($script:Cf.StagePath -and (Split-Path -Leaf $script:Cf.StagePath).EndsWith(".$PID") -and
                [IO.Path]::GetFullPath((Split-Path -Parent $script:Cf.StagePath)).Equals([IO.Path]::GetFullPath($releasesDir), [StringComparison]::OrdinalIgnoreCase)) {
                $stageItem = Get-Item -LiteralPath $script:Cf.StagePath -Force -ErrorAction SilentlyContinue
                if ($null -ne $stageItem) {
                    if ($stageItem.PSIsContainer -and ($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        [IO.Directory]::Delete($script:Cf.StagePath)
                    } else { Remove-Item -LiteralPath $script:Cf.StagePath -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }
        } catch { Write-WarningStep 'Could not remove temporary staging files.' }
        finally { $lock.Dispose() }
    }
}

function Remove-StaleInstallArtifacts {
    param(
        [string]$ReleasesDir
    )

    if (Test-Path -LiteralPath $ReleasesDir -PathType Container) {
        Get-ChildItem -LiteralPath $ReleasesDir -Force -Directory -Filter ".staging.*" -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-VersionFromReleaseMetadata {
    param(
        [object]$ReleaseMetadata
    )

    if (-not $ReleaseMetadata.tag_name) {
        throw "Failed to resolve the latest Codefx release version."
    }

    $resolvedVersion = Normalize-Version -RawVersion $ReleaseMetadata.tag_name
    Assert-ValidReleaseVersion -Version $resolvedVersion
    return $resolvedVersion
}

function Get-CodefxApiHeaders {
    $headers = @{}
    if ($env:CODEFX_GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:CODEFX_GITHUB_TOKEN" }
    return $headers
}

function Resolve-ReleaseFromGitHub {
    param(
        [string]$NormalizedVersion
    )

    if ($NormalizedVersion -eq "latest") {
        $requestedRelease = "latest"
        $metadataUri = "https://api.github.com/repos/$CodefxGithubRepo/releases/latest"
    } else {
        $resolvedVersion = $NormalizedVersion
        $requestedRelease = $resolvedVersion
        $metadataUri = "https://api.github.com/repos/$CodefxGithubRepo/releases/tags/rust-v$resolvedVersion"
    }

    try {
        $releaseMetadata = Invoke-RestMethod -Uri $metadataUri -Headers (Get-CodefxApiHeaders) -TimeoutSec $ReleasesMetadataTimeoutSec
    } catch {
        throw "Could not fetch GitHub release metadata for Codex $requestedRelease. GitHub API may be unavailable or rate limited. $($_.Exception.Message)"
    }

    if ($NormalizedVersion -eq "latest") {
        $resolvedVersion = Resolve-VersionFromReleaseMetadata -ReleaseMetadata $releaseMetadata
    }

    return [PSCustomObject]@{
        Version = $resolvedVersion
        Metadata = $releaseMetadata
        Source = "GitHub"
    }
}

function Resolve-ReleaseFromReleases {
    param(
        [string]$NormalizedVersion
    )

    $metadataUri = if ($NormalizedVersion -eq "latest") {
        "$ReleasesBaseUri/channels/latest"
    } else {
        "$ReleasesBaseUri/releases/$NormalizedVersion/release.json"
    }
    try {
        $metadataResponse = Invoke-WebRequest -UseBasicParsing -Uri $metadataUri -TimeoutSec $ReleasesMetadataTimeoutSec
        $releaseMetadata = [string]$metadataResponse.Content | ConvertFrom-Json -ErrorAction Stop
        $resolvedVersion = Resolve-VersionFromReleaseMetadata -ReleaseMetadata $releaseMetadata
        if ($NormalizedVersion -ne "latest" -and $resolvedVersion -cne $NormalizedVersion) {
            throw "Release metadata version did not match requested Codex version $NormalizedVersion."
        }
        $resolvedRelease = [PSCustomObject]@{
            Version = $resolvedVersion
            Metadata = $releaseMetadata
            Source = "ReleasesOpenAICom"
        }
        $null = Resolve-ReleaseAssetSelection -ResolvedRelease $resolvedRelease -Target $target -NpmTag $npmTag
    } catch {
        return $null
    }
    return $resolvedRelease
}

function Resolve-Release {
    $normalizedVersion = Normalize-Version -RawVersion $Release
    Assert-ValidReleaseVersion -Version $normalizedVersion

    if ($PreferReleasesOpenAICom) {
        $release = Resolve-ReleaseFromReleases -NormalizedVersion $normalizedVersion
        if ($null -ne $release) {
            return $release
        }
        Write-WarningStep "releases.openai.com is unavailable; falling back to GitHub Releases."
    }

    return Resolve-ReleaseFromGitHub -NormalizedVersion $normalizedVersion
}

function Get-VersionFromBinary {
    param(
        [string]$CodexPath
    )

    if (-not (Test-Path -LiteralPath $CodexPath -PathType Leaf)) {
        return $null
    }

    try {
        if ([IO.Path]::GetExtension($CodexPath) -ieq '.exe') {
            $versionOutput = (Invoke-CodefxBounded $CodexPath @('--version')).Trim()
            if ($versionOutput -cmatch '^codefx ([0-9][0-9A-Za-z.+-]*)$') { return $matches[1] }
            return $null
        }
        $versionOutput = & $CodexPath --version 2>$null
    } catch {
        return $null
    }

    if ($LASTEXITCODE -eq 0 -and $versionOutput -match '^codefx ([0-9][0-9A-Za-z.+-]*)$') {
        return $matches[1]
    }

    return $null
}

function Get-CurrentInstalledVersion {
    param(
        [string]$StandaloneCurrentDir
    )

    $standaloneVersion = Get-VersionFromBinary -CodexPath (Join-Path $StandaloneCurrentDir "bin\codex.exe")
    if (-not [string]::IsNullOrWhiteSpace($standaloneVersion)) {
        return $standaloneVersion
    }

    $standaloneVersion = Get-VersionFromBinary -CodexPath (Join-Path $StandaloneCurrentDir "codex.exe")
    if (-not [string]::IsNullOrWhiteSpace($standaloneVersion)) {
        return $standaloneVersion
    }

    return $null
}

function Test-OldStandaloneBinLayout {
    param(
        [string]$VisibleBinDir,
        [string]$DefaultVisibleBinDir
    )

    if (-not (Test-Path -LiteralPath $VisibleBinDir -PathType Container)) {
        return $false
    }

    $item = Get-Item -LiteralPath $VisibleBinDir -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return $false
    }

    $requiredFiles = @("codex.exe", "rg.exe")
    foreach ($fileName in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $VisibleBinDir $fileName) -PathType Leaf)) {
            return $false
        }
    }

    try {
        $identity = (Invoke-CodefxBounded (Join-Path $VisibleBinDir 'codex.exe') @('--version')).Trim()
        if ($identity -cnotmatch '^(codefx|codex-cli) [0-9][0-9A-Za-z.+-]*$') { return $false }
    } catch { return $false }
    $knownFiles = @(
        "codex-code-mode-host.exe",
        "codex.exe",
        "rg.exe",
        "codex-command-runner.exe",
        "codex-windows-sandbox.exe",
        "codex-windows-sandbox-setup.exe"
    )
    foreach ($child in Get-ChildItem -LiteralPath $VisibleBinDir -Force) {
        if ($child.PSIsContainer) {
            return $false
        }
        if ($knownFiles -notcontains $child.Name) {
            return $false
        }
    }

    return $true
}

function Move-OldStandaloneBinIfApproved {
    param(
        [string]$VisibleBinDir,
        [string]$DefaultVisibleBinDir
    )

    if (-not (Test-OldStandaloneBinLayout -VisibleBinDir $VisibleBinDir -DefaultVisibleBinDir $DefaultVisibleBinDir)) {
        return $null
    }

    $backupDir = "$VisibleBinDir.backup.$([guid]::NewGuid().ToString('N'))"
    Write-Step "Preserving the verified older standalone install at $backupDir"
    $script:Cf.VisibleBackup = $backupDir
    Save-CodefxJournal
    Move-Item -LiteralPath $VisibleBinDir -Destination $backupDir
    return $backupDir
}

function Add-JunctionSupportType {
    # Older installer types remain loaded when users rerun irm | iex in one session.
    if (([System.Management.Automation.PSTypeName]'CodexInstaller.JunctionV3').Type) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexInstaller
{
    public static class JunctionV3
    {
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint FILE_SHARE_DELETE = 0x00000004;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FSCTL_SET_REPARSE_POINT = 0x000900A4;
        private const uint IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003;
        private const int HeaderLength = 20;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            SafeFileHandle hDevice,
            uint dwIoControlCode,
            byte[] lpInBuffer,
            int nInBufferSize,
            IntPtr lpOutBuffer,
            int nOutBufferSize,
            out int lpBytesReturned,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file, StringBuilder path, uint length, uint flags);

        // Read the journal entry for the junction itself, never the target.
        // Unlike a timestamp this changes on an in-place retarget, including away and back.
        public static string SelectionIdentity(string path)
        {
            using (SafeFileHandle handle = CreateFileW(
                path, 0x80, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero))
            {
                if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                IntPtr buffer = Marshal.AllocHGlobal(1024);
                try {
                    int returned;
                    // No input requests USN_RECORD_V2. current's filename fits in 1024 bytes.
                    if (!DeviceIoControl(handle, 0x000900eb, null, 0, buffer, 1024, out returned, IntPtr.Zero)) {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    long usn = Marshal.ReadInt64(buffer, 24);
                    if (returned < 32 || Marshal.ReadInt16(buffer, 4) != 2 || usn <= 0) {
                        throw new IOException("No reliable daemon selection journal record.");
                    }
                    return Marshal.ReadInt64(buffer, 8).ToString("x")
                        + " " + usn.ToString("x");
                } finally {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }

        public static string ResolveDirectory(string path)
        {
            using (SafeFileHandle handle = CreateFileW(
                path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
            {
                if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                StringBuilder resolved = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandleW(handle, resolved, (uint)resolved.Capacity, 0);
                if (length == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                if (length >= resolved.Capacity) { throw new IOException("Resolved path is too long."); }
                return resolved.ToString().TrimEnd('\\');
            }
        }

        public static void SetTarget(string linkPath, string targetPath)
        {
            string substituteName = "\\??\\" + Path.GetFullPath(targetPath);
            byte[] substituteNameBytes = Encoding.Unicode.GetBytes(substituteName);
            if (substituteNameBytes.Length > ushort.MaxValue - HeaderLength) {
                throw new ArgumentException("Junction target path is too long.", "targetPath");
            }

            byte[] reparseBuffer = new byte[substituteNameBytes.Length + HeaderLength];
            WriteUInt32(reparseBuffer, 0, IO_REPARSE_TAG_MOUNT_POINT);
            WriteUInt16(reparseBuffer, 4, checked((ushort)(substituteNameBytes.Length + 12)));
            WriteUInt16(reparseBuffer, 8, 0);
            WriteUInt16(reparseBuffer, 10, checked((ushort)substituteNameBytes.Length));
            WriteUInt16(reparseBuffer, 12, checked((ushort)(substituteNameBytes.Length + 2)));
            WriteUInt16(reparseBuffer, 14, 0);
            Buffer.BlockCopy(substituteNameBytes, 0, reparseBuffer, 16, substituteNameBytes.Length);

            using (SafeFileHandle handle = CreateFileW(
                linkPath,
                GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero))
            {
                if (handle.IsInvalid) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                int bytesReturned;
                if (!DeviceIoControl(
                    handle,
                    FSCTL_SET_REPARSE_POINT,
                    reparseBuffer,
                    reparseBuffer.Length,
                    IntPtr.Zero,
                    0,
                    out bytesReturned,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
        }

        private static void WriteUInt16(byte[] buffer, int offset, ushort value)
        {
            buffer[offset] = (byte)value;
            buffer[offset + 1] = (byte)(value >> 8);
        }

        private static void WriteUInt32(byte[] buffer, int offset, uint value)
        {
            buffer[offset] = (byte)value;
            buffer[offset + 1] = (byte)(value >> 8);
            buffer[offset + 2] = (byte)(value >> 16);
            buffer[offset + 3] = (byte)(value >> 24);
        }
    }
}
"@
}

function Set-JunctionTarget {
    param(
        [string]$LinkPath,
        [string]$TargetPath
    )

    Add-JunctionSupportType
    [CodexInstaller.JunctionV3]::SetTarget($LinkPath, $TargetPath)
}

function Test-IsJunction {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Path -Force
    return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.LinkType -eq "Junction"
}

function Ensure-Junction {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$InstallerOwnedTargetPrefix
    )

    if (-not (Test-Path -LiteralPath $LinkPath)) {
        New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
        return
    }

    $item = Get-Item -LiteralPath $LinkPath -Force
    if (Test-IsJunction -Path $LinkPath) {
        Add-JunctionSupportType
        $existingTarget = [CodexInstaller.JunctionV3]::ResolveDirectory($LinkPath)
        if (-not [string]::IsNullOrWhiteSpace($InstallerOwnedTargetPrefix)) {
            $ownedTargetPrefix = [CodexInstaller.JunctionV3]::ResolveDirectory($InstallerOwnedTargetPrefix) + "\"
            if (-not $existingTarget.StartsWith($ownedTargetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to retarget junction at $LinkPath because it is not managed by this installer."
            }
        }
        if ($existingTarget.Equals([CodexInstaller.JunctionV3]::ResolveDirectory($TargetPath), [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }

        # Keep the path itself in place and only retarget the junction. That
        # avoids a gap where current or the visible bin path disappears during
        # an update.
        Set-JunctionTarget -LinkPath $LinkPath -TargetPath $TargetPath
        return
    }

    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to replace non-junction reparse point at $LinkPath."
    }

    if ($item.PSIsContainer) {
        if ((Get-ChildItem -LiteralPath $LinkPath -Force | Select-Object -First 1) -ne $null) {
            throw "Refusing to replace non-empty directory at $LinkPath with a junction."
        }

        Remove-Item -LiteralPath $LinkPath -Force
        New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
        return
    }

    throw "Refusing to replace file at $LinkPath with a junction."
}

function Test-PackageContentsAreComplete {
    param(
        [string]$PackageDir
    )

    if (-not (Test-Path -LiteralPath $PackageDir -PathType Container)) {
        return $false
    }

    $expectedFiles = @(
        "codex-package.json",
        "bin\codex.exe",
        "bin\codex-code-mode-host.exe",
        "codex-path\rg.exe",
        "codex-resources\codex-command-runner.exe",
        "codex-resources\codex-windows-sandbox-setup.exe"
    )
    foreach ($name in $expectedFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageDir $name) -PathType Leaf)) {
            return $false
        }
    }

    try {
        $manifest = Get-Content -LiteralPath (Join-Path $PackageDir 'codex-package.json') -Raw | ConvertFrom-Json
        if ($manifest.version -cne $resolvedVersion -or $manifest.target -cne $target -or $manifest.entrypoint -cne 'bin/codex.exe') { return $false }
    } catch { return $false }
    return $true
}

function Test-LegacyPlatformNpmContentsAreComplete {
    param(
        [string]$PackageDir
    )

    if (-not (Test-Path -LiteralPath $PackageDir -PathType Container)) {
        return $false
    }

    $expectedFiles = @(
        "codex.exe",
        "codex-resources\codex-command-runner.exe",
        "codex-resources\codex-windows-sandbox-setup.exe",
        "codex-resources\rg.exe"
    )
    foreach ($name in $expectedFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageDir $name) -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Test-ReleaseIsComplete {
    param(
        [string]$ReleaseDir,
        [string]$ExpectedVersion,
        [string]$ExpectedTarget,
        [string]$Layout
    )

    switch ($Layout) {
        "Package" {
            if (-not (Test-PackageContentsAreComplete -PackageDir $ReleaseDir)) {
                return $false
            }
            $codexPath = Join-Path $ReleaseDir "bin\codex.exe"
        }
        "LegacyPlatformNpm" {
            if (-not (Test-LegacyPlatformNpmContentsAreComplete -PackageDir $ReleaseDir)) {
                return $false
            }
            $codexPath = Join-Path $ReleaseDir "codex.exe"
        }
        default {
            throw "Unknown Codex installer layout: $Layout"
        }
    }

    return (Split-Path -Leaf $ReleaseDir) -eq "$ExpectedVersion-$ExpectedTarget" -and
        (Get-VersionFromBinary -CodexPath $codexPath) -ceq $ExpectedVersion
}

function Get-ExistingCodexCommand {
    $existing = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $existing) {
        return $null
    }

    return $existing.Source
}

function Get-ExistingCodexManager {
    param(
        [string]$ExistingPath,
        [string]$VisibleBinDir
    )

    if ([string]::IsNullOrWhiteSpace($ExistingPath)) {
        return $null
    }

    if ($ExistingPath.StartsWith($VisibleBinDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if ($ExistingPath -match "\\.bun\\") {
        return "bun"
    }

    if ($ExistingPath -match "node_modules" -or $ExistingPath -match "\\npm\\") {
        return "npm"
    }

    return $null
}

function Get-ConflictingInstall {
    param(
        [string]$VisibleBinDir
    )

    $existingPath = Get-ExistingCodexCommand
    $manager = Get-ExistingCodexManager -ExistingPath $existingPath -VisibleBinDir $VisibleBinDir
    if ($null -eq $manager) {
        if (-not $existingPath -or $existingPath.StartsWith($VisibleBinDir, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $manager = "native"
    }

    Write-Step "Detected existing $manager-managed Codex at $existingPath"
    Write-WarningStep "Multiple managed Codex installs can be ambiguous because PATH order decides which one runs."

    return [PSCustomObject]@{
        Manager = $manager
        Path = $existingPath
    }
}

function Maybe-HandleConflictingInstall {
    param([object]$Conflict)
    if ($null -ne $Conflict) { Write-Step "Original package-manager installation retained at $($Conflict.Path)." }
}

function Test-VisibleCodexCommand {
    param(
        [string]$VisibleBinDir
    )

    $codexCommand = Join-Path $VisibleBinDir "codex.exe"
    if ((Get-VersionFromBinary $codexCommand) -cne $resolvedVersion) {
        throw "Installed Codex command failed verification: $codexCommand --version"
    }
}

if ($env:OS -ne "Windows_NT") {
    Write-Error "install.ps1 supports Windows only. Use install.sh on macOS or Linux."
    exit 1
}

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "Codex requires a 64-bit version of Windows."
    exit 1
}

function Test-CodefxGuardedUpdate {
    return $env:CODEX_INSTALL_IF_LATEST -eq '1' -or $env:CODEX_INSTALL_IF_CURRENT -eq '1' -or $daemonOnly -or $oldUpdaterParent
}

function Invoke-CodefxBounded {
    param([string]$File, [string[]]$Arguments)
    # ProcessStartInfo.ArgumentList is unavailable in Windows PowerShell 5.1.
    # Quote according to the Win32 command-line convention, including backslashes.
    $quoted = foreach ($arg in $Arguments) {
        '"' + ([regex]::Replace(([regex]::Replace($arg, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"'
    }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $File
    $start.Arguments = $quoted -join ' '
    if ([IO.Path]::GetExtension($File) -in @('.cmd','.bat','.ps1')) {
        # npm/pnpm/Bun shims need an interpreter. Encode the fully quoted
        # expression so spaces, Unicode and shell metacharacters remain literal.
        $literalFile = "'" + $File.Replace("'", "''") + "'"
        $literalArgs = @($Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ' '
        $expression = "& $literalFile $literalArgs; exit `$LASTEXITCODE"
        $engine = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $engine)) { $engine = Join-Path $PSHOME 'powershell.exe' }
        $start.FileName = $engine
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($expression))
    }
    $start.UseShellExecute = $false
    $start.EnvironmentVariables.Remove('CODEFX_GITHUB_TOKEN')
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $start
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        if (-not $proc.Start()) { throw "Cannot start $File" }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($ProcessTimeout * 1000)) {
            try { $proc.Kill() } catch {}
            throw "Timed out running $File $($Arguments -join ' ')"
        }
        # A shim can exit while its child still holds the redirected pipes.
        # Bound draining those pipes by the same overall lifecycle deadline.
        $remaining = [int][Math]::Max(0, $ProcessTimeout * 1000 - $watch.ElapsedMilliseconds)
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), $remaining)) {
            throw "Timed out reading output from $File"
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        if ($proc.ExitCode -ne 0) { throw "$File exited $($proc.ExitCode): $stderr" }
        return $stdout
    } finally { $proc.Dispose() }
}

function Get-CodefxProcesses {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $all = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'codex%.exe' OR Name LIKE 'codefx%.exe'" -OperationTimeoutSec ([uint32][Math]::Min(30, $ProcessTimeout)) -ErrorAction Stop)
    foreach ($entry in $all) {
        if ($entry.Name -notmatch '^(codex|codefx)([-_.].*)?\.exe$') { continue }
        $owner = Invoke-CimMethod -InputObject $entry -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -ne 0) { throw "Cannot inspect ownership of Codex PID $($entry.ProcessId)." }
        if ($owner.Sid -eq $identity) { $entry }
    }
}

function Assert-CodefxOutsideActiveAncestor {
    param([object[]]$Active)
    if ($Active.Count -eq 0) { return }
    $installerStarted = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime()
    # A process created after the installer host cannot be its ancestor.
    $possibleAncestors = @($Active | Where-Object {
        $null -eq $_.PSObject.Properties['CreationDate'] -or $null -eq $_.CreationDate -or
            $_.CreationDate.ToUniversalTime() -le $installerStarted
    })
    if ($possibleAncestors.Count -eq 0) { return }
    $ancestor = [long]$PID
    $visited = New-Object 'System.Collections.Generic.HashSet[long]'
    $ancestryWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($ancestor -gt 4) {
        if (-not $visited.Add($ancestor) -or $visited.Count -gt 128 -or $ancestryWatch.Elapsed.TotalSeconds -ge $ProcessTimeout) {
            throw "Cannot safely inspect process ancestry (cycle, reused PID, or timeout at PID $ancestor). Run from a fresh external terminal."
        }
        if ($possibleAncestors.ProcessId -contains $ancestor) {
            throw 'Run the installer from an external terminal; its ancestor is Codex.'
        }
        $remaining = [uint32][Math]::Max(1, [Math]::Min(10, $ProcessTimeout - $ancestryWatch.Elapsed.TotalSeconds))
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $ancestor" -OperationTimeoutSec $remaining -ErrorAction Stop
        if ($null -eq $parent) { break }
        $ancestor = [long]$parent.ParentProcessId
    }
}

function Confirm-CodefxActivePreflight {
    if (Test-CodefxGuardedUpdate) { return }
    $active = @(Get-CodefxProcesses)
    if ($active.Count -gt 0) {
        Write-Host ($active | Select-Object ProcessId, ExecutablePath | Out-String)
        Assert-CodefxOutsideActiveAncestor -Active $active
        if ($DeferUntilIdle) {
            Write-Step "Waiting up to $IdleWaitTimeout seconds for Codex to exit naturally."
            $deadline = [DateTime]::UtcNow.AddSeconds($IdleWaitTimeout)
            while ($active.Count -gt 0) {
                if ([DateTime]::UtcNow -ge $deadline) {
                    throw 'Codex is still running. Installation cancelled before downloading the package.'
                }
                Start-Sleep -Seconds 1
                $active = @(Get-CodefxProcesses)
            }
            Write-Step 'Codex sessions are idle; continuing installation.'
        } elseif (-not $StopRunning) {
            if (Prompt-YesNo 'Attempt to close running Codex sessions and managed daemon to continue installation?') {
                $script:StopRunning = $true
            } else {
                throw 'Codex was left running. Installation cancelled before downloading the package.'
            }
        }
    }
    if ($KeepDaemon -or -not (Test-CodefxDaemonInstalled)) { return }
    $oldCli = Get-ExistingCodexCommand
    if (-not $oldCli -and (Test-Path -LiteralPath (Join-Path $visibleBinDir 'codex.exe'))) {
        $oldCli = Join-Path $visibleBinDir 'codex.exe'
    }
    foreach ($candidate in @((Join-Path $currentDir 'bin\codex.exe'), (Join-Path $currentDir 'codex.exe'))) {
        if (-not $oldCli -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $oldCli = $candidate }
    }
    if ($oldCli) {
        $version = $null
        try { $version = (Invoke-CodefxBounded $oldCli @('app-server','daemon','version')) | ConvertFrom-Json } catch {}
        if ($null -ne $version -and $version.status -eq 'running' -and -not $StopRunning) {
            if (Prompt-YesNo 'A managed app-server daemon is running. Stop and restart it during installation?') {
                $script:StopRunning = $true
            } else {
                throw 'Managed daemon was left running. Installation cancelled before downloading the package.'
            }
        }
    }
}

function Complete-CodefxReceipt {
    $receipt = '.rollback.' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + '.' + [guid]::NewGuid().ToString('N')
    Move-Item -LiteralPath $script:Cf.Root -Destination (Join-Path $standaloneRoot $receipt)
}

function Save-CodefxJournal {
    $journal = Join-Path $script:Cf.Root 'journal.json'
    $script:Cf | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$journal.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$journal.tmp" -Destination $journal -Force
}

function Save-CodefxPath {
    param([string]$Path, [string]$Key)
    $record = @{ Path = $Path; Kind = 'absent'; Backup = $null }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        if (Test-IsJunction -Path $Path) {
            Add-JunctionSupportType
            $record.Kind = 'junction'
            $record.Backup = [CodexInstaller.JunctionV3]::ResolveDirectory($Path)
            # Windows PowerShell's junction provider does not normalize Win32
            # extended-length prefixes. Store a provider-compatible target.
            if ($record.Backup.StartsWith('\\?\UNC\')) { $record.Backup = '\\' + $record.Backup.Substring(8) }
            elseif ($record.Backup.StartsWith('\\?\')) { $record.Backup = $record.Backup.Substring(4) }
        } elseif ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Unsupported reparse point at $Path."
        } elseif ($item.PSIsContainer) {
            if ($Key -ne 'visible') { throw "Unexpected directory at $Path." }
            # Move-OldStandaloneBinIfApproved validates this layout before moving it.
            $record.Kind = if (@(Get-ChildItem -LiteralPath $Path -Force).Count -eq 0) { 'empty-directory' } else { 'directory' }
        } else {
            $record.Kind = 'file'
            $record.Backup = Join-Path $script:Cf.Root "$Key.file"
            Copy-Item -LiteralPath $Path -Destination $record.Backup
        }
    }
    $script:Cf.Paths += $record
    Save-CodefxJournal
}

function Test-CodefxDaemonInstalled {
    $selection = Get-Item -LiteralPath (Join-Path $codexHome 'packages\app-server-daemon\current') -Force -ErrorAction SilentlyContinue
    if ($null -ne $selection) { return $true }
    foreach ($name in @('daemon.pid','daemon.stderr.log','daemon-updater.pid','daemon-updater.stderr.log','app-server.pid','app-server.stderr.log','app-server-updater.pid','app-server-updater.stderr.log')) {
        if (Test-Path -LiteralPath (Join-Path $codexHome "app-server-daemon\$name")) { return $true }
    }
    return $false
}

function Test-CodefxDetachedLaunch {
    param([string]$Executable)
    if (-not ('CodexInstaller.LaunchProbeV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace CodexInstaller {
  public static class LaunchProbeV1 {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct StartupInfo {
      public int cb;
      public string reserved, desktop, title;
      public int x,y,width,height,xchars,ychars,fill,flags;
      public short show, reservedSize;
      public IntPtr reservedBytes,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processSecurity,
      IntPtr threadSecurity, bool inheritHandles, uint flags, IntPtr environment, string directory,
      ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    public static void Check(string executable) {
      var startup = new StartupInfo(); startup.cb = Marshal.SizeOf(typeof(StartupInfo));
      ProcessInfo process;
      // The probe never runs user code: create suspended, then terminate and reap.
      if (!CreateProcessW(executable, new StringBuilder("\""+executable+"\" --version"),
          IntPtr.Zero,IntPtr.Zero,false,0x01000000|0x00000004|0x00000008,IntPtr.Zero,null,ref startup,out process))
        throw new Win32Exception(Marshal.GetLastWin32Error(), "This terminal cannot launch the independent Windows daemon. Use a normal external terminal before migrating.");
      try {
        if (!TerminateProcess(process.process,0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (WaitForSingleObject(process.process,5000)!=0) throw new Exception("Suspended daemon launch probe did not terminate.");
      } finally { CloseHandle(process.thread); CloseHandle(process.process); }
    }
  }
}
'@
    }
    [CodexInstaller.LaunchProbeV1]::Check($Executable)
}

function Assert-CodefxDaemonContext {
    param([string]$Executable)
    if ((Test-CodefxGuardedUpdate) -or $KeepDaemon -or -not (Test-CodefxDaemonInstalled)) { return }
    # The daemon rejects an elevated launcher. Check before stopping the old
    # runtime, because it must remain possible to restart it during rollback.
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Migrate the Windows daemon from a non-elevated terminal so it can restart safely. The original installation is retained.'
    }
    Test-CodefxDetachedLaunch $Executable
}

function Start-CodefxTransaction {
    param([string]$Executable)
    if ($script:Cf.Prepared) { return }
    Assert-CodefxDaemonContext $Executable
    $active = @()
    if (-not (Test-CodefxGuardedUpdate)) {
        $active = @(Get-CodefxProcesses)
        if ($active.Count -gt 0) {
            Write-Host ($active | Select-Object ProcessId, ExecutablePath | Out-String)
            if (-not $StopRunning) {
                if (Prompt-YesNo 'A Codex session started during download. Attempt to close it?') {
                    $script:StopRunning = $true
                } else {
                    throw 'Codex was left running; existing installation preserved.'
                }
            }
            Assert-CodefxOutsideActiveAncestor -Active $active
        }
    }
    New-Item -ItemType Directory -Path $script:Cf.Root | Out-Null
    $script:Cf.Prepared = $true
    Save-CodefxJournal
    Save-CodefxPath $currentDir current
    Save-CodefxPath $autoUpdateVersion channel
    if (-not $daemonOnly) {
        Save-CodefxPath $visibleBinDir visible
        if (-not (Test-CodefxGuardedUpdate)) {
            Save-CodefxPath (Join-Path $codexHome 'version.json') version-cache
            Save-CodefxPath (Join-Path $standaloneRoot 'codefx-update-source') update-source
        }
    }
    Save-CodefxPath (Join-Path $standaloneRoot 'selection-history') history
    if (-not (Test-CodefxGuardedUpdate) -and -not $KeepDaemon) {
        Save-CodefxPath (Join-Path $codexHome 'packages\app-server-daemon\current') daemon-current
        Save-CodefxPath (Join-Path $codexHome 'packages\app-server-daemon\auto-update-version') daemon-channel
        Save-CodefxPath (Join-Path $codexHome 'packages\app-server-daemon\selection-history') daemon-history
        Save-CodefxPath (Join-Path $codexHome 'app-server-daemon\settings.json') daemon-settings
    }
    if (-not (Test-CodefxGuardedUpdate)) {
        $oldCli = Get-ExistingCodexCommand
        if (-not $oldCli -and (Test-Path -LiteralPath (Join-Path $visibleBinDir 'codex.exe'))) { $oldCli = Join-Path $visibleBinDir 'codex.exe' }
        foreach ($candidate in @((Join-Path $currentDir 'bin\codex.exe'), (Join-Path $currentDir 'codex.exe'))) {
            if (-not $oldCli -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $oldCli = $candidate }
        }
        if ($oldCli -and -not $KeepDaemon -and
            ((Test-Path -LiteralPath (Join-Path $codexHome 'app-server-daemon')) -or
             (Test-Path -LiteralPath (Join-Path $codexHome 'packages\app-server-daemon')))) {
            $version = $null
            try { $version = (Invoke-CodefxBounded $oldCli @('app-server','daemon','version')) | ConvertFrom-Json } catch {}
            if ($null -ne $version -and $version.status -eq 'running') {
                if (-not $StopRunning) {
                    if (Prompt-YesNo 'A managed daemon started during download. Stop and restart it?') {
                        $script:StopRunning = $true
                    } else {
                        throw 'Managed daemon was left running; existing installation preserved.'
                    }
                }
                $script:Cf.RestartCli = $oldCli
                Save-CodefxJournal
                $null = Invoke-CodefxBounded $oldCli @('app-server','daemon','stop')
            }
        }
        # CloseMainWindow requests normal shutdown. Console sessions without a
        # window need to be closed by their owner; never use Stop-Process on them.
        foreach ($entry in $active) {
            $proc = Get-Process -Id $entry.ProcessId -ErrorAction SilentlyContinue
            if ($null -ne $proc -and [Math]::Abs(($proc.StartTime.ToUniversalTime() - $entry.CreationDate.ToUniversalTime()).TotalMilliseconds) -lt 1) {
                $null = $proc.CloseMainWindow()
            }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($ProcessTimeout)
        while (@(Get-CodefxProcesses).Count -gt 0) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for Codex. Close console sessions manually; the original installation will be restored.' }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Repair-CodefxRestoredHistory {
    param([string]$Root, [string]$Current)
    $history = Join-Path $Root 'selection-history'
    if (-not (Test-Path -LiteralPath $history) -or -not (Test-IsJunction $Current)) { return }
    try {
        Add-JunctionSupportType
        $lines = @(Get-Content -LiteralPath $history)
        if ($lines.Count -ne 3) { return }
        $selected = [CodexInstaller.JunctionV3]::ResolveDirectory($Current)
        if ($lines[0] -cne (Split-Path -Leaf $selected)) { return }
        $identity = [CodexInstaller.JunctionV3]::SelectionIdentity($Current)
        [IO.File]::WriteAllText("$history.tmp.$PID", "$($lines[0])`n$($lines[1])`n$identity`n")
        Move-Item -LiteralPath "$history.tmp.$PID" -Destination $history -Force
    } catch { Write-WarningStep 'Could not refresh restored selection history; pruning will skip it.' }
}

function Undo-CodefxTransaction {
    if ($script:Cf.MigrationAttempted) {
        $newCli = Join-Path $visibleBinDir 'codex.exe'
        $null = Invoke-CodefxBounded $newCli @('app-server','daemon','stop')
    }
    if ($script:Cf.ReleaseBackup -and (Test-Path -LiteralPath $script:Cf.ReleaseBackup)) {
        if (Test-Path -LiteralPath $script:Cf.ReleasePath) { Remove-Item -LiteralPath $script:Cf.ReleasePath -Recurse -Force }
        Move-Item -LiteralPath $script:Cf.ReleaseBackup -Destination $script:Cf.ReleasePath
    }
    foreach ($record in $script:Cf.Paths) {
        if ($record.Kind -eq 'directory') { continue }
        $item = Get-Item -LiteralPath $record.Path -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                [IO.Directory]::Delete($record.Path)
            } elseif ($item.PSIsContainer) {
                if ($record.Kind -eq 'empty-directory' -and @(Get-ChildItem -LiteralPath $record.Path -Force).Count -eq 0) { continue }
                throw "Rollback preserved unexpected directory $($record.Path)."
            }
            else { Remove-Item -LiteralPath $record.Path -Force }
        }
        switch ($record.Kind) {
            'empty-directory' { New-Item -ItemType Directory -Path $record.Path | Out-Null }
            'junction' { New-Item -ItemType Junction -Path $record.Path -Target $record.Backup | Out-Null }
            'file' { Copy-Item -LiteralPath $record.Backup -Destination $record.Path }
        }
    }
    if ($script:Cf.VisibleBackup -and (Test-Path -LiteralPath $script:Cf.VisibleBackup)) {
        $item = Get-Item -LiteralPath $visibleBinDir -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) { [IO.Directory]::Delete($visibleBinDir) }
        Move-Item -LiteralPath $script:Cf.VisibleBackup -Destination $visibleBinDir
    }
    Repair-CodefxRestoredHistory $standaloneRoot $currentDir
    if (@($script:Cf.Paths | Where-Object { $_.Path -eq (Join-Path $codexHome 'packages\app-server-daemon\current') }).Count -gt 0) {
        Repair-CodefxRestoredHistory (Join-Path $codexHome 'packages\app-server-daemon') (Join-Path $codexHome 'packages\app-server-daemon\current')
    }
    [Environment]::SetEnvironmentVariable('Path', $script:Cf.UserPath, 'User')
    $env:Path = $script:Cf.ProcessPath
    if ($script:Cf.RestartCli) { $null = Invoke-CodefxBounded $script:Cf.RestartCli @('app-server','daemon','start') }
}

function Update-CodefxVersionCache {
    if (Test-CodefxGuardedUpdate) { return }
    $source = Join-Path $standaloneRoot 'codefx-update-source'
    $oldSource = if (Test-Path -LiteralPath $source) { [IO.File]::ReadAllText($source).Trim() } else { '' }
    if ($oldSource -cne $CodefxGithubRepo) {
        $cache = Join-Path $codexHome 'version.json'
        if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Force }
        $nextSource = Join-Path $script:Cf.Root 'codefx-update-source.next'
        [IO.File]::WriteAllText($nextSource, $CodefxGithubRepo)
        Move-Item -LiteralPath $nextSource -Destination $source -Force
    }
}

function Update-CodefxDaemon {
    if ((Test-CodefxGuardedUpdate) -or $KeepDaemon) { return }
    if ((Test-CodefxDaemonInstalled) -or $script:Cf.RestartCli) {
        $newCli = Join-Path $visibleBinDir 'codex.exe'
        $script:Cf.MigrationAttempted = $true
        Save-CodefxJournal
        Write-Step 'Migrating the managed daemon to the verified Codefx package'
        $null = Invoke-CodefxBounded $newCli @('app-server','daemon','update','--from-cli','--yes')
        if ($script:Cf.RestartCli) {
            $null = Invoke-CodefxBounded $newCli @('app-server','daemon','start')
            $health = (Invoke-CodefxBounded $newCli @('app-server','daemon','version')) | ConvertFrom-Json
            if ($health.status -ne 'running' -or $health.appServerVersion -cne $resolvedVersion) { throw 'Daemon health check failed.' }
        } else { $null = Invoke-CodefxBounded $newCli @('app-server','daemon','stop') }
    }
}

function Invoke-CodefxArchiveTool {
    param([string]$Archive, [ValidateSet('list','types','extract')][string]$Mode, [string]$Destination)
    # Windows tar builds can use ANSI argv, and Windows PowerShell's redirected
    # stdin writer can emit an encoding preamble. Use ASCII relative filenames
    # and pass the Unicode working directory through CreateProcessW.
    $systemTar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not [Environment]::Is64BitProcess) { $systemTar = Join-Path $env:SystemRoot 'Sysnative\tar.exe' }
    if (-not (Test-Path -LiteralPath $systemTar)) {
        $available = Get-Command tar.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $systemTar = $available.Source
    }
    $working = Split-Path -Parent $Archive
    $name = Split-Path -Leaf $Archive
    $privateInput = $null
    if ($Mode -eq 'extract') {
        $working = $Destination
        $name = '.codefx-input-' + [guid]::NewGuid().ToString('N') + '.tar.gz'
        $privateInput = Join-Path $working $name
        Copy-Item -LiteralPath $Archive -Destination $privateInput
    }
    if ($name -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Archive input filename must use ASCII letters, numbers, dot, dash or underscore.' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $systemTar
    $operation = switch ($Mode) { 'list' { '-tzf' }; 'types' { '-tvzf' }; 'extract' { '-xzf' } }
    $start.Arguments = "$operation $name"
    $start.WorkingDirectory = $working
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $start
    try {
        if (-not $proc.Start()) { throw 'Cannot start the archive reader.' }
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(300000)) { throw 'Archive processing timed out.' }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($proc.ExitCode -ne 0) { throw "Archive reader failed: $errorText" }
        return $output
    } catch {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
        throw
    } finally {
        $proc.Dispose()
        if ($null -ne $privateInput) { Remove-Item -LiteralPath $privateInput -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-CodefxArchive {
    param([string]$Archive)
    $names = @((Invoke-CodefxArchiveTool $Archive list) -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    foreach ($name in $names) {
        if ($name -match '(^[/\\]|\\|(^|/)\.\.(/|$)|[\x00-\x1f]|:)' -or $name -match '(?i)(^|/)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])([./]|$)' -or $name -match '[. ](/|$)') {
            throw "Unsafe archive member: $name"
        }
    }
    $types = @((Invoke-CodefxArchiveTool $Archive types) -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    foreach ($line in $types) { if ($line -notmatch '^[-d]') { throw 'Archive links and special files are not allowed.' } }
}

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$target = $null
$platformLabel = $null
$npmTag = $null
switch ($architecture) {
    "Arm64" {
        $target = "aarch64-pc-windows-msvc"
        $platformLabel = "Windows (ARM64)"
        $npmTag = "win32-arm64"
    }
    "X64" {
        $target = "x86_64-pc-windows-msvc"
        $platformLabel = "Windows (x64)"
        $npmTag = "win32-x64"
    }
    default {
        Write-Error "Unsupported architecture: $architecture"
        exit 1
    }
}

$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE ".codex"
} else {
    $env:CODEX_HOME
}
$daemonOnly = $env:CODEX_INSTALL_DAEMON_ONLY -eq "1"
$standaloneRoot = Join-Path $codexHome $(if ($daemonOnly) { "packages\app-server-daemon" } else { "packages\standalone" })
$releasesDir = Join-Path $standaloneRoot "releases"
$currentDir = Join-Path $standaloneRoot "current"
$deferSelection = $env:CODEX_INSTALL_DEFER_SELECTION -eq "1"
if ($deferSelection) {
    if (-not $daemonOnly) { throw "Deferred selection requires a daemon-only installation." }
    $currentDir = Join-Path $standaloneRoot ".migration-current"
}
$autoUpdateVersion = Join-Path $standaloneRoot "auto-update-version"
$lockPath = Join-Path $standaloneRoot "install.lock"

$defaultVisibleBinDir = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin"
if ([string]::IsNullOrWhiteSpace($env:CODEX_INSTALL_DIR)) {
    $visibleBinDir = $defaultVisibleBinDir
} else {
    $visibleBinDir = $env:CODEX_INSTALL_DIR
}

foreach ($path in @($codexHome, $visibleBinDir)) {
    if ($path -notmatch '^[A-Za-z]:[\\/]') { throw 'CODEX_HOME and CODEX_INSTALL_DIR must use absolute paths on local Windows drives.' }
}
$canonicalVisible = [IO.Path]::GetFullPath($visibleBinDir).TrimEnd('\') + '\'
$canonicalRoot = [IO.Path]::GetFullPath($standaloneRoot).TrimEnd('\') + '\'
if ($canonicalVisible.StartsWith($canonicalRoot, [StringComparison]::OrdinalIgnoreCase) -or $canonicalRoot.StartsWith($canonicalVisible, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'CODEX_INSTALL_DIR must be a separate directory outside the managed package tree.'
}
$currentVersion = Get-CurrentInstalledVersion -StandaloneCurrentDir $currentDir
$resolvedRelease = Resolve-Release
$resolvedVersion = $resolvedRelease.Version
$releaseMetadata = $resolvedRelease.Metadata
$releaseName = "$resolvedVersion-$target"
$releaseDir = Join-Path $releasesDir $releaseName

if (-not [string]::IsNullOrWhiteSpace($currentVersion) -and $currentVersion -ne $resolvedVersion) {
    Write-Step "Updating Codefx CLI from $currentVersion to $resolvedVersion"
} elseif (-not [string]::IsNullOrWhiteSpace($currentVersion)) {
    Write-Step "Updating Codefx CLI"
} else {
    Write-Step "Installing Codefx CLI"
}
Write-Step "Detected platform: $platformLabel"
Write-Step "Resolved version: $resolvedVersion"

$conflictingInstall = if ($daemonOnly) { $null } else { Get-ConflictingInstall -VisibleBinDir $visibleBinDir }
$oldStandaloneBackup = $null

$checksumAsset = "codex-package_SHA256SUMS"
$assetSelection = Resolve-ReleaseAssetSelection -ResolvedRelease $resolvedRelease -Target $target -NpmTag $npmTag
$checksumAsset = $assetSelection.ChecksumAsset
$packageAsset = $assetSelection.PackageAsset
$packageMetadata = $assetSelection.PackageMetadata
$checksumMetadata = $assetSelection.ChecksumMetadata
$installLayout = $assetSelection.InstallLayout
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-install-" + [System.Guid]::NewGuid().ToString("N"))
$guardRejected = $false
$script:Cf = @{
    Root = (Join-Path $standaloneRoot '.transaction'); Prepared = $false; Committed = $false; Paths = @();
    StagePath = $null; ReleaseBackup = $null; ReleasePath = $releaseDir; VisibleBackup = $null; RestartCli = $null; MigrationAttempted = $false
    UserPath = [Environment]::GetEnvironmentVariable('Path', 'User'); ProcessPath = $env:Path
}
Write-Step 'Existing codex commands (deduplicated PATH entries):'
$seenCommands = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
Get-Command codex -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object {
    $canonical = [IO.Path]::GetFullPath($_.Source)
    if ($seenCommands.Add($canonical)) { Write-Host "    $($_.Source)" }
}
if ($DryRun) {
    Write-Step "Dry run: release $resolvedVersion, target $target, destination $visibleBinDir. No changes made."
    return
}

New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
try {
    Invoke-WithInstallLock -LockPath $lockPath -Script {
        if (Test-Path -LiteralPath $script:Cf.Root) {
            $saved = Get-Content -LiteralPath (Join-Path $script:Cf.Root 'journal.json') -Raw | ConvertFrom-Json
            $fresh = $script:Cf
            $recovered = @{}
            foreach ($key in $fresh.Keys) { $recovered[$key] = $fresh[$key] }
            foreach ($property in $saved.PSObject.Properties) { $recovered[$property.Name] = $property.Value }
            $script:Cf = $recovered
            if ($script:Cf.Committed) {
                Write-Step 'Finishing the recovery receipt of a committed installation.'
                Complete-CodefxReceipt
            } else {
                Write-WarningStep 'Recovering an interrupted installation.'
                Undo-CodefxTransaction
                Remove-Item -LiteralPath $script:Cf.Root -Recurse -Force
            }
            $script:Cf = $fresh
        }
        $updaterRecord = Join-Path $codexHome "app-server-daemon\app-server-updater.pid"
        if ($daemonOnly) { $updaterRecord = Join-Path $codexHome "app-server-daemon\daemon-updater.pid" }
        $oldUpdaterParent = $false
        if ($Release -eq "latest" -and $env:CODEX_INSTALL_IF_LATEST -ne "1" -and $env:CODEX_INSTALL_IF_CURRENT -ne "1" -and (Test-Path -LiteralPath $updaterRecord)) {
            $updaterPid = $null
            $updaterStartTime = $null
            try {
                $record = Get-Content -LiteralPath $updaterRecord -Raw | ConvertFrom-Json
                $updaterPid = [long]$record.pid
                $updaterStartTime = [string]$record.processStartTime
            } catch {
                # Empty or stale PID reservations must not block a manual install.
            }
            if ($null -ne $updaterPid -and $updaterPid -gt 0 -and -not [string]::IsNullOrEmpty($updaterStartTime)) {
                $updaterProcess = Get-Process -Id $updaterPid -ErrorAction SilentlyContinue
                if ($null -ne $updaterProcess -and $updaterStartTime -eq [string]$updaterProcess.StartTime.ToFileTimeUtc()) {
                    try {
                        $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).ParentProcessId
                        if ([long]$parentPid -le 0) { throw "Missing updater parent process." }
                    } catch {
                        try {
                            $parentPid = (Get-WmiObject Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).ParentProcessId
                            if ([long]$parentPid -le 0) { throw "Missing updater parent process." }
                        } catch {
                            throw "Cannot verify whether the standalone installer was launched by an older updater."
                        }
                    }
                    $oldUpdaterParent = $updaterPid -eq $parentPid
                }
            }
        }
        if ($env:CODEX_INSTALL_IF_LATEST -eq "1" -or $env:CODEX_INSTALL_IF_CURRENT -eq "1" -or $oldUpdaterParent) {
            $previousRelease = if ($oldUpdaterParent -and (Test-Path -LiteralPath $autoUpdateVersion)) {
                [System.IO.File]::ReadAllText($autoUpdateVersion)
            } else {
                $env:CODEX_UPDATE_FROM_RELEASE
            }
            Add-JunctionSupportType
            $currentTarget = if (Test-Path -LiteralPath $currentDir) { (Get-Item -LiteralPath $currentDir).Target } else { $null }
            if ($Release -ne "latest" -or [string]::IsNullOrEmpty($previousRelease) -or [string]::IsNullOrEmpty($currentTarget) -or
                -not (Test-Path -LiteralPath (Join-Path $releasesDir $previousRelease)) -or
                [CodexInstaller.JunctionV3]::ResolveDirectory($currentDir) -ne [CodexInstaller.JunctionV3]::ResolveDirectory((Join-Path $releasesDir $previousRelease))) {
                if ($env:CODEX_INSTALL_IF_CURRENT -eq "1") { throw "Daemon selection changed; retry the update." }
                $script:guardRejected = $true
                return
            }
            # Explicit daemon updates may leave a local or pinned release.
            if ($env:CODEX_INSTALL_IF_CURRENT -ne "1" -and
                (-not (Test-Path -LiteralPath $autoUpdateVersion) -or
                [System.IO.File]::ReadAllText($autoUpdateVersion) -cne $previousRelease)) {
                $script:guardRejected = $true
                return
            }
        }
        Confirm-CodefxActivePreflight
        Remove-StaleInstallArtifacts -ReleasesDir $releasesDir

        if (-not (Test-ReleaseIsComplete -ReleaseDir $releaseDir -ExpectedVersion $resolvedVersion -ExpectedTarget $target -Layout $installLayout)) {
            if (Test-Path -LiteralPath $releaseDir) {
                if ($daemonOnly) { throw "Refusing to overwrite existing daemon release $releaseDir." }
                Write-WarningStep "Found incomplete existing release at $releaseDir. Reinstalling."
            }

            $archivePath = Join-Path $tempDir $packageAsset
            $checksumPath = Join-Path $tempDir $checksumAsset
            $stagingDir = Join-Path $releasesDir ".staging.$releaseName.$PID"
            $script:Cf.StagePath = $stagingDir

            Write-Step "Downloading Codefx CLI"
            if ($installLayout -eq "Package") {
                Invoke-WebRequestWithFallback -Metadata $checksumMetadata -OutFile $checksumPath -ExpectedDigest $checksumMetadata.Sha256 -AssetName $checksumAsset -ReleaseVersion $resolvedVersion -RequiredManifestAsset $packageAsset
                $expectedPackageDigest = Get-PackageArchiveDigest -ManifestPath $checksumPath -AssetName $packageAsset
            } else {
                $expectedPackageDigest = $packageMetadata.Sha256
            }
            Invoke-WebRequestWithFallback -Metadata $packageMetadata -OutFile $archivePath -ExpectedDigest $expectedPackageDigest -AssetName $packageAsset -ReleaseVersion $resolvedVersion

            New-Item -ItemType Directory -Force -Path $releasesDir | Out-Null
            if (Test-Path -LiteralPath $stagingDir) {
                Remove-Item -LiteralPath $stagingDir -Recurse -Force
            }
            New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
            Assert-CodefxArchive $archivePath
            if ($installLayout -eq "Package") {
                $null = Invoke-CodefxArchiveTool $archivePath extract $stagingDir
                if (-not (Test-PackageContentsAreComplete -PackageDir $stagingDir)) {
                    throw "Downloaded Codex package archive did not contain the expected package layout."
                }
            } else {
                $extractDir = Join-Path $tempDir "extract"
                New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
                $null = Invoke-CodefxArchiveTool $archivePath extract $extractDir

                $vendorRoot = Join-Path $extractDir "package/vendor/$target"
                $resourcesDir = Join-Path $stagingDir "codex-resources"
                New-Item -ItemType Directory -Force -Path $resourcesDir | Out-Null
                $copyMap = @{
                    "codex/codex.exe" = "codex.exe"
                    "codex/codex-command-runner.exe" = "codex-resources\codex-command-runner.exe"
                    "codex/codex-windows-sandbox-setup.exe" = "codex-resources\codex-windows-sandbox-setup.exe"
                    "path/rg.exe" = "codex-resources\rg.exe"
                }

                foreach ($relativeSource in $copyMap.Keys) {
                    Copy-Item -LiteralPath (Join-Path $vendorRoot $relativeSource) -Destination (Join-Path $stagingDir $copyMap[$relativeSource])
                }

                if (-not (Test-LegacyPlatformNpmContentsAreComplete -PackageDir $stagingDir)) {
                    throw "Downloaded Codex npm archive did not contain the expected legacy platform package layout."
                }
            }

            $stagedCodex = if ($installLayout -eq "Package") {
                Join-Path $stagingDir "bin\codex.exe"
            } else {
                Join-Path $stagingDir "codex.exe"
            }
            if ((Get-VersionFromBinary -CodexPath $stagedCodex) -cne $resolvedVersion) {
                throw "Staged Codefx package failed executable or version validation; existing installation preserved."
            }
            Start-CodefxTransaction -Executable $stagedCodex
            if (Test-Path -LiteralPath $releaseDir) {
                $backupRelease = Join-Path $releasesDir ".backup.$releaseName.$PID"
                $script:Cf.ReleaseBackup = $backupRelease
                Save-CodefxJournal
                Move-Item -LiteralPath $releaseDir -Destination $backupRelease
                try {
                    Move-Item -LiteralPath $stagingDir -Destination $releaseDir
                } catch {
                    Move-Item -LiteralPath $backupRelease -Destination $releaseDir
                    throw
                }
            } else {
                Move-Item -LiteralPath $stagingDir -Destination $releaseDir
            }
        }

        if (-not (Test-ReleaseIsComplete -ReleaseDir $releaseDir -ExpectedVersion $resolvedVersion -ExpectedTarget $target -Layout $installLayout)) {
            throw "Installed Codex command did not report expected version $resolvedVersion."
        }

        $selectedExecutable = Join-Path $releaseDir $(if ($installLayout -eq 'Package') { 'bin\codex.exe' } else { 'codex.exe' })
        Start-CodefxTransaction -Executable $selectedExecutable
        New-Item -ItemType Directory -Force -Path $standaloneRoot | Out-Null
        if ($deferSelection -and (Get-Item -LiteralPath (Join-Path $standaloneRoot "current") -Force -ErrorAction SilentlyContinue)) {
            throw "A dedicated daemon is already selected; retry the update."
        }
        if ($daemonOnly -and -not $deferSelection) {
            $installedCodex = Join-Path $releaseDir $(if ($installLayout -eq "Package") { "bin\codex.exe" } else { "codex.exe" })
            & $installedCodex app-server daemon pid-update-loop --check-package-ownership | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "The production release does not support daemon-owned packages; the current selection was left unchanged."
            }
        }
        $previousDirectory = $null
        if ($daemonOnly -and -not $deferSelection) {
            Add-JunctionSupportType
            if (Test-Path -LiteralPath $currentDir) {
                $previousDirectory = [CodexInstaller.JunctionV3]::ResolveDirectory($currentDir)
            }
        }
        Ensure-Junction -LinkPath $currentDir -TargetPath $releaseDir -InstallerOwnedTargetPrefix $releasesDir
        if ($daemonOnly -and -not $deferSelection -and
            $previousDirectory -cne [CodexInstaller.JunctionV3]::ResolveDirectory($currentDir)) {
            try {
                $previousName = if ($null -eq $previousDirectory) { "" } else { Split-Path -Leaf $previousDirectory }
                $selectionId = [CodexInstaller.JunctionV3]::SelectionIdentity($currentDir)
                $history = Join-Path $standaloneRoot "selection-history"
                [System.IO.File]::WriteAllText("$history.tmp.$PID", "$releaseName`n$previousName`n$selectionId`n")
                Move-Item -LiteralPath "$history.tmp.$PID" -Destination $history -Force -ErrorAction Stop
            } catch {
                Write-WarningStep "Could not record daemon selection; pruning will be skipped."
            }
        }
        if ($Release -eq "latest") {
            $tempMarker = "$autoUpdateVersion.tmp.$PID"
            [System.IO.File]::WriteAllText($tempMarker, $releaseName)
            Move-Item -LiteralPath $tempMarker -Destination $autoUpdateVersion -Force
        } else {
            if (Test-Path -LiteralPath $autoUpdateVersion) {
                Remove-Item -LiteralPath $autoUpdateVersion -Force -ErrorAction Stop
            }
        }

        if ($daemonOnly) { return }
        $visibleParent = Split-Path -Parent $visibleBinDir
        $currentBinDir = if ($installLayout -eq "Package") {
            Join-Path $currentDir "bin"
        } else {
            $currentDir
        }
        New-Item -ItemType Directory -Force -Path $visibleParent | Out-Null
        $oldStandaloneBackup = Move-OldStandaloneBinIfApproved -VisibleBinDir $visibleBinDir -DefaultVisibleBinDir $defaultVisibleBinDir
        $script:Cf.VisibleBackup = $oldStandaloneBackup
        Save-CodefxJournal
        Ensure-Junction -LinkPath $visibleBinDir -TargetPath $currentBinDir -InstallerOwnedTargetPrefix $standaloneRoot
        Test-VisibleCodexCommand -VisibleBinDir $visibleBinDir
        Update-CodefxDaemon
        if ($guardRejected -or $daemonOnly) { return }

Maybe-HandleConflictingInstall -Conflict $conflictingInstall

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$prioritizeVisibleBin = $null -ne $conflictingInstall
if ($prioritizeVisibleBin) {
    $newUserPath = Prepend-PathEntry -PathValue $userPath -Entry $visibleBinDir
    if ($newUserPath -cne $userPath) {
        [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
        Write-Step "PATH updated for future PowerShell sessions."
    } else {
        Write-Step "$visibleBinDir is already first on PATH."
    }
} elseif (-not (Path-Contains -PathValue $userPath -Entry $visibleBinDir)) {
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $newUserPath = $visibleBinDir
    } else {
        $newUserPath = "$visibleBinDir;$userPath"
    }

    [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
    Write-Step "PATH updated for future PowerShell sessions."
} elseif (Path-Contains -PathValue $env:Path -Entry $visibleBinDir) {
    Write-Step "$visibleBinDir is already on PATH."
} else {
    Write-Step "PATH is already configured for future PowerShell sessions."
}

if ($prioritizeVisibleBin) {
    $env:Path = Prepend-PathEntry -PathValue $env:Path -Entry $visibleBinDir
} elseif (-not (Path-Contains -PathValue $env:Path -Entry $visibleBinDir)) {
    if ([string]::IsNullOrWhiteSpace($env:Path)) {
        $env:Path = $visibleBinDir
    } else {
        $env:Path = "$visibleBinDir;$env:Path"
    }
}

Write-Step "Current PowerShell session: codex"
$machineCommand = Find-CodefxCommandOnPath ([Environment]::GetEnvironmentVariable('Path', 'Machine'))
if ($machineCommand -and -not (Split-Path -Parent $machineCommand).TrimEnd('\').Equals($visibleBinDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    Write-WarningStep "System PATH contains $machineCommand before the user PATH. New terminals may select it. Use $visibleBinDir\codex.exe, or remove the older system command through its original package manager."
} else { Write-Step "New PowerShell windows: check Get-Command codex -All; expected $visibleBinDir\codex.exe" }
Write-Host "Codefx CLI $resolvedVersion installed successfully."

        Test-VisibleCodexCommand -VisibleBinDir $visibleBinDir
        Update-CodefxVersionCache
    }
} finally {
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}
if ($guardRejected -or $daemonOnly) { return }

$codexCommand = Join-Path $visibleBinDir "codex.exe"
if (Prompt-YesNo "Start Codex now?") {
    Write-Step "Launching Codex"
    & $codexCommand
}
