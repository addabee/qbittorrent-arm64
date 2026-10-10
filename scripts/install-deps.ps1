<#
.SYNOPSIS
    Builds qBittorrent's native ARM64 dependencies with vcpkg (classic mode).

.DESCRIPTION
    1. Clones vcpkg into <Root>\vcpkg (full history; needed to extract an older libtorrent port) and checks out
       the pinned commit, then bootstraps it.
    2. Copies the release-only, dynamic arm64 overlay triplet into <Root>\triplets.
    3. Extracts the newest libtorrent 2.0.x port from vcpkg's version database into <Root>\overlay-ports
       (qBittorrent 5.x supports libtorrent 1.2.x / 2.0.x, while the vcpkg baseline may already ship 2.1).
    4. Installs Qt 6, libtorrent, the Boost libraries qBittorrent uses, OpenSSL and zlib.

    Must run on an ARM64 Windows host with VS 2022 (or Build Tools) including the ARM64 C++ tools.

.EXAMPLE
    .\install-deps.ps1
    .\install-deps.ps1 -Root C:\q
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\dev\qbt-arm64',
    [string]$VcpkgCommit = 'e456309491fd875487bf02b8a0dca76c1b1b00cc',
    [string]$Triplet = 'arm64-windows-release',
    [string]$LibtorrentSeries = '2.0'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE): $Exe $($Arguments -join ' ')" }
}

$repoDir = Split-Path $PSScriptRoot
$vcpkg = Join-Path $Root 'vcpkg'
$triplets = Join-Path $Root 'triplets'
$overlay = Join-Path $Root 'overlay-ports'
New-Item -ItemType Directory -Force $Root, $triplets, $overlay | Out-Null

Write-Host "==> vcpkg @ $VcpkgCommit"
if (-not (Test-Path (Join-Path $vcpkg '.git'))) {
    Invoke-Checked git @('clone', 'https://github.com/microsoft/vcpkg.git', $vcpkg)
}
Invoke-Checked git @('-C', $vcpkg, 'fetch', '--quiet', 'origin')
Invoke-Checked git @('-C', $vcpkg, '-c', 'advice.detachedHead=false', 'checkout', '--quiet', $VcpkgCommit)
Invoke-Checked (Join-Path $vcpkg 'bootstrap-vcpkg.bat') @('-disableMetrics')

Write-Host "==> Overlay triplet $Triplet"
Copy-Item (Join-Path $repoDir "triplets\$Triplet.cmake") $triplets -Force

Write-Host "==> libtorrent $LibtorrentSeries.x overlay port"
$db = Get-Content (Join-Path $vcpkg 'versions\l-\libtorrent.json') -Raw | ConvertFrom-Json
$entry = $db.versions | Where-Object {
    $ver = if ($_.PSObject.Properties['version']) { $_.version } elseif ($_.PSObject.Properties['version-semver']) { $_.'version-semver' } else { $_.'version-string' }
    $ver -like "$LibtorrentSeries.*"
} | Select-Object -First 1   # the version database lists newest first
if (-not $entry) { throw "No libtorrent $LibtorrentSeries.x port found in vcpkg's version database." }
$ltPort = Join-Path $overlay 'libtorrent'
if (Test-Path $ltPort) { Remove-Item $ltPort -Recurse -Force }
$zip = Join-Path $Root 'libtorrent-port.zip'
Invoke-Checked git @('-C', $vcpkg, 'archive', '--format=zip', '-o', $zip, $entry.'git-tree')
Expand-Archive $zip $ltPort -Force
Remove-Item $zip
$ltVer = (Get-Content (Join-Path $ltPort 'vcpkg.json') -Raw | ConvertFrom-Json).version
Write-Host "   libtorrent $ltVer (git-tree $($entry.'git-tree'))"

Write-Host '==> vcpkg install'
# boost-*: exactly the Boost libraries qBittorrent includes (asio, circular_buffer, multi_index, stacktrace)
$ports = @('qtbase', 'qtsvg', 'qttools', 'libtorrent', 'boost-headers', 'boost-cmake', 'boost-asio',
           'boost-circular-buffer', 'boost-multi-index', 'boost-stacktrace', 'openssl', 'zlib')
Invoke-Checked (Join-Path $vcpkg 'vcpkg.exe') (@('install') + $ports + @(
    "--triplet=$Triplet", "--host-triplet=$Triplet",
    "--overlay-triplets=$triplets", "--overlay-ports=$overlay",
    "--x-buildtrees-root=$(Join-Path $Root 'bt')", '--clean-after-build', '--disable-metrics'))

Write-Host "==> Dependencies ready in $vcpkg\installed\$Triplet"
