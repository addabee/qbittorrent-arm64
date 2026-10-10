<#
.SYNOPSIS
    Build qBittorrent natively for Windows ARM64 against a vcpkg (classic mode) installed tree,
    stage a portable folder and zip it.

.DESCRIPTION
    1. Imports the VS 2022 ARM64 developer environment (vcvarsarm64.bat located via vswhere).
    2. Configures qBittorrent with CMake (+ Ninja if available, else VS generator -A ARM64), Release.
    3. Builds.
    4. Stages <Root>\dist\qBittorrent: qbittorrent.exe (+pdb), qt.conf, windeployqt output,
       vcpkg runtime DLLs (resolved recursively with dumpbin /dependents), the MSVC ARM64 CRT
       and third-party license texts (licenses\).
    5. Zips to <Root>\qBittorrent-<version>-arm64-portable.zip.

    Dependencies come from install-deps.ps1 (same -Root).

    Idempotent: re-running reconfigures/rebuilds incrementally and recreates dist + zip from scratch.

.EXAMPLE
    .\build-qbt.ps1
    .\build-qbt.ps1 -Triplet arm64-windows-release -Clean
#>
[CmdletBinding()]
param(
    [string]$Triplet = 'arm64-windows-release',
    [string]$Root = 'C:\dev\qbt-arm64',
    [string]$SourceDir = '',
    [string]$VcpkgRoot = '',
    [string]$VcpkgInstalledDir = '',
    [string]$OverlayTriplets = '',
    [string]$BuildDir = '',
    [string]$DistDir = '',
    [ValidateSet('Release', 'RelWithDebInfo')]
    [string]$Config = 'Release',
    [ValidateSet('Auto', 'ON', 'OFF')]
    [Alias('Stacktrace')][string]$StacktraceMode = 'Auto',
    [string]$LibtorrentDir = '',     # optional: dir containing LibtorrentRasterbarConfig.cmake (e.g. a self-built lt 2.0.x)
    [switch]$Testing,
    [switch]$Clean,
    [switch]$NoPdb,
    [switch]$NoZip,
    [switch]$SkipUpdaterPatch,
    [switch]$ForceVSGenerator
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

if (-not $SourceDir)         { $SourceDir = Join-Path $Root 'qBittorrent' }
if (-not $VcpkgRoot)         { $VcpkgRoot = Join-Path $Root 'vcpkg' }
if (-not $VcpkgInstalledDir) { $VcpkgInstalledDir = Join-Path $VcpkgRoot 'installed' }
if (-not $OverlayTriplets)   { $OverlayTriplets = Join-Path $Root 'triplets' }
if (-not $BuildDir)          { $BuildDir = Join-Path $Root 'build-qbt' }
if (-not $DistDir)           { $DistDir = Join-Path $Root 'dist\qBittorrent' }

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    Write-Host "   > $Exe $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE): $Exe $($Arguments -join ' ')" }
}

# --------------------------------------------------------------------------------------------
# 0. Sanity checks
# --------------------------------------------------------------------------------------------
Write-Step 'Checking inputs'
if (-not (Test-Path (Join-Path $SourceDir 'CMakeLists.txt'))) { throw "qBittorrent source not found at $SourceDir" }
$toolchain = Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
if (-not (Test-Path $toolchain)) { throw "vcpkg toolchain not found: $toolchain" }

$tripletDir = Join-Path $VcpkgInstalledDir $Triplet
if (-not (Test-Path $tripletDir)) {
    # Convenience fallback: accept the release-only overlay triplet (or vice versa).
    $alt = if ($Triplet -like '*-release') { $Triplet -replace '-release$', '' } else { "$Triplet-release" }
    if (Test-Path (Join-Path $VcpkgInstalledDir $alt)) {
        Write-Warning "Installed tree for '$Triplet' not found; falling back to '$alt'."
        $Triplet = $alt
        $tripletDir = Join-Path $VcpkgInstalledDir $Triplet
    } else {
        throw "vcpkg installed tree not found: $tripletDir (are the dependencies built yet?)"
    }
}

$vcpkgBin = Join-Path $tripletDir 'bin'
$required = @(
    (Join-Path $tripletDir 'share\Qt6\Qt6Config.cmake'),
    (Join-Path $tripletDir 'include\libtorrent\version.hpp'),
    (Join-Path $tripletDir 'include\openssl\ssl.h'),
    (Join-Path $tripletDir 'include\zlib.h'),
    (Join-Path $tripletDir 'include\boost\version.hpp')
)
foreach ($f in $required) { if (-not (Test-Path $f)) { throw "Missing dependency file: $f" } }

# libtorrent version check (qBittorrent 5.2.x officially supports lt 1.2.19+ / 2.0.10 - 2.0.x)
$ltVer = Select-String -Path (Join-Path $tripletDir 'include\libtorrent\version.hpp') -Pattern 'define LIBTORRENT_VERSION "([^"]+)"' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
Write-Host "   libtorrent in vcpkg tree: $ltVer"
if ($ltVer -and ([version]($ltVer -replace '[^\d\.].*$', '') -ge [version]'2.1') -and -not $LibtorrentDir) {
    Write-Warning "libtorrent $ltVer is newer than the 2.0.x series qBittorrent 5.2 targets. Configure/compile may fail; if so, build libtorrent 2.0.11 and pass -LibtorrentDir."
}

# STACKTRACE needs boost/stacktrace.hpp (vcpkg port 'boost-stacktrace'); MSVC backend uses dbgeng (present on ARM64 Windows)
$hasStacktraceHdr = Test-Path (Join-Path $tripletDir 'include\boost\stacktrace.hpp')
$stacktraceOpt = 'OFF'
if ($StacktraceMode -ieq 'ON' -or ($StacktraceMode -ieq 'Auto' -and $hasStacktraceHdr)) { $stacktraceOpt = 'ON' }
elseif ($StacktraceMode -notin @('Auto', 'OFF')) { throw "Invalid -Stacktrace value '$StacktraceMode' (use Auto, ON or OFF)." }
if ($stacktraceOpt -eq 'ON' -and -not $hasStacktraceHdr) { throw 'STACKTRACE=ON requested but boost/stacktrace.hpp is missing (install boost-stacktrace).' }
if (($StacktraceMode -eq 'Auto') -and ($stacktraceOpt -eq 'OFF')) {
    Write-Warning 'boost-stacktrace not installed -> building with STACKTRACE=OFF.'
}

# Version from version.h.in
$verFile = Join-Path $SourceDir 'src\base\version.h.in'
$verText = Get-Content $verFile -Raw
$vMaj = [regex]::Match($verText, 'QBT_VERSION_MAJOR\s+(\d+)').Groups[1].Value
$vMin = [regex]::Match($verText, 'QBT_VERSION_MINOR\s+(\d+)').Groups[1].Value
$vFix = [regex]::Match($verText, 'QBT_VERSION_BUGFIX\s+(\d+)').Groups[1].Value
$vStatus = [regex]::Match($verText, 'QBT_VERSION_STATUS\s+"([^"]*)"').Groups[1].Value
if (-not $vMaj) { throw "Could not parse version from $verFile" }
$Version = "$vMaj.$vMin.$vFix$vStatus"
Write-Host "   qBittorrent version: $Version  triplet: $Triplet  STACKTRACE=$stacktraceOpt"

# --------------------------------------------------------------------------------------------
# 1. Source patch (idempotent): updater variant string is hard-coded "Windows x64"; on ARM64
#    that would offer the x64 installer as an "update". Use a distinct variant so nothing matches.
# --------------------------------------------------------------------------------------------
if (-not $SkipUpdaterPatch) {
    $upd = Join-Path $SourceDir 'src\gui\programupdater.cpp'
    $txt = Get-Content $upd -Raw
    if ($txt -notmatch 'Windows ARM64') {
        $needle = '        const auto BASE_OS = u"Windows x64"_s;'
        if (-not $txt.Contains($needle)) { throw "Updater patch: expected line not found in $upd" }
        $repl = "#if defined(_M_ARM64)`n        const auto BASE_OS = u`"Windows ARM64`"_s;`n#else`n$needle`n#endif"
        $txt = $txt.Replace($needle, $repl)
        [System.IO.File]::WriteAllText($upd, $txt, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host '   Patched programupdater.cpp for ARM64 variant.'
    } else {
        Write-Host '   programupdater.cpp already patched.'
    }
}

# --------------------------------------------------------------------------------------------
# 2. VS ARM64 developer environment
# --------------------------------------------------------------------------------------------
Write-Step 'Importing VS ARM64 developer environment'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "vswhere not found: $vswhere" }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
if (-not $vsPath) { $vsPath = & $vswhere -latest -products * -property installationPath }
if (-not $vsPath) { throw 'No Visual Studio installation found by vswhere.' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsarm64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvarsarm64.bat not found: $vcvars" }

if ($env:VSCMD_ARG_TGT_ARCH -ne 'arm64') {
    $envDump = & cmd.exe /d /s /c "`"$vcvars`" >nul 2>&1 && set"
    if ($LASTEXITCODE -ne 0) { throw "vcvarsarm64.bat failed (exit $LASTEXITCODE)" }
    foreach ($line in $envDump) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { Set-Item -Path ("Env:" + $line.Substring(0, $i)) -Value $line.Substring($i + 1) }
    }
}
if ($env:VSCMD_ARG_TGT_ARCH -ne 'arm64') { throw "Developer environment not targeting arm64 (VSCMD_ARG_TGT_ARCH=$env:VSCMD_ARG_TGT_ARCH)" }
Write-Host "   VS: $vsPath  (tools $env:VCToolsVersion)"

$dumpbin = (Get-Command dumpbin.exe -ErrorAction Stop).Source

# CMake: prefer the standalone install, then the one from the dev env
$cmake = $null
foreach ($c in @("$env:ProgramFiles\CMake\bin\cmake.exe",
                 (Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'))) {
    if (Test-Path $c) { $cmake = $c; break }
}
if (-not $cmake) { $cmake = (Get-Command cmake.exe -ErrorAction Stop).Source }
Write-Host "   CMake: $cmake"

$ninja = $null
if (-not $ForceVSGenerator) {
    $ninjaCmd = Get-Command ninja.exe -ErrorAction SilentlyContinue
    if ($ninjaCmd) { $ninja = $ninjaCmd.Source }
    else {
        $n = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
        if (Test-Path $n) { $ninja = $n }
    }
}

# --------------------------------------------------------------------------------------------
# 3. Configure
# --------------------------------------------------------------------------------------------
Write-Step 'Configuring'
$generator = if ($ninja) { 'Ninja' } else { 'Visual Studio 17 2022' }
Write-Host "   Generator: $generator $(if ($ninja) { "($ninja)" })"

# Wipe build dir on -Clean or if it was configured with a different generator
$cache = Join-Path $BuildDir 'CMakeCache.txt'
if ((Test-Path $BuildDir) -and ($Clean -or ((Test-Path $cache) -and -not (Select-String -Path $cache -SimpleMatch "CMAKE_GENERATOR:INTERNAL=$generator" -Quiet)))) {
    Write-Host "   Removing $BuildDir"
    Remove-Item -Recurse -Force $BuildDir
}

$cmakeArgs = @(
    '-S', $SourceDir,
    '-B', $BuildDir,
    '-G', $generator,
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
    "-DVCPKG_TARGET_TRIPLET=$Triplet",
    "-DVCPKG_INSTALLED_DIR=$VcpkgInstalledDir",
    '-DVCPKG_MANIFEST_MODE=OFF',
    '-DVCPKG_APPLOCAL_DEPS=OFF',          # we deploy DLLs ourselves below
    '-DGUI=ON',
    '-DWEBUI=ON',
    "-DSTACKTRACE=$stacktraceOpt",
    "-DTESTING=$(if ($Testing) { 'ON' } else { 'OFF' })",
    '-DMSVC_RUNTIME_DYNAMIC=ON',
    '-DVERBOSE_CONFIGURE=ON'
)
if (Test-Path $OverlayTriplets) { $cmakeArgs += "-DVCPKG_OVERLAY_TRIPLETS=$OverlayTriplets" }
if ($LibtorrentDir) { $cmakeArgs += "-DLibtorrentRasterbar_DIR=$LibtorrentDir" }
if ($ninja) {
    $cmakeArgs += @("-DCMAKE_BUILD_TYPE=$Config", "-DCMAKE_MAKE_PROGRAM=$ninja",
                    '-DCMAKE_C_COMPILER=cl.exe', '-DCMAKE_CXX_COMPILER=cl.exe')
} else {
    $cmakeArgs += @('-A', 'ARM64')
}
Invoke-Native $cmake $cmakeArgs

# --------------------------------------------------------------------------------------------
# 4. Build
# --------------------------------------------------------------------------------------------
Write-Step 'Building'
Invoke-Native $cmake @('--build', $BuildDir, '--config', $Config, '--parallel')

$exe = Get-ChildItem -Path $BuildDir -Recurse -Filter 'qbittorrent.exe' -File |
    Where-Object { $_.FullName -notmatch '\\CMakeFiles\\' } | Select-Object -First 1
if (-not $exe) { throw "qbittorrent.exe not found under $BuildDir" }
$machine = (& $dumpbin /headers $exe.FullName | Select-String 'machine \(' | Select-Object -First 1).Line
Write-Host "   Built: $($exe.FullName)  [$($machine.Trim())]"
if ($machine -notmatch 'ARM64') { throw "qbittorrent.exe is not an ARM64 binary: $machine" }

if ($Testing) {
    Write-Step 'Running tests'
    Invoke-Native $cmake @('--build', $BuildDir, '--config', $Config, '--target', 'check')
}

# --------------------------------------------------------------------------------------------
# 5. Stage portable dist
# --------------------------------------------------------------------------------------------
Write-Step "Staging $DistDir"
if (Test-Path $DistDir) { Remove-Item -Recurse -Force $DistDir }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

Copy-Item $exe.FullName $DistDir
$pdb = Join-Path $exe.DirectoryName 'qbittorrent.pdb'
if ((-not $NoPdb) -and (Test-Path $pdb)) { Copy-Item $pdb $DistDir }
Copy-Item (Join-Path $SourceDir 'dist\windows\qt.conf') $DistDir     # [Paths] Translations = translations
Copy-Item (Join-Path $SourceDir 'COPYING') (Join-Path $DistDir 'COPYING.txt')
# Portable mode: qBittorrent uses a "profile" dir next to the exe when it exists
New-Item -ItemType Directory -Force -Path (Join-Path $DistDir 'profile') | Out-Null

# windeployqt from the vcpkg tools dir
$qtTools = Join-Path $tripletDir 'tools\Qt6\bin'
$windeployqt = Join-Path $qtTools 'windeployqt.exe'
if (-not (Test-Path $windeployqt)) { throw "windeployqt not found: $windeployqt (qtbase[windeployqt] feature needed)" }
$env:PATH = "$vcpkgBin;$qtTools;$env:PATH"

$help = (& $windeployqt --help 2>&1 | Out-String)
$wdqArgs = @('--release', '--dir', $DistDir, '--plugindir', (Join-Path $DistDir 'plugins'),
             '--no-compiler-runtime', '--no-opengl-sw', '--no-system-d3d-compiler', '--verbose', '1')
if ($help -match '--no-system-dxc-compiler') { $wdqArgs += '--no-system-dxc-compiler' }
if ($help -match '--no-ffmpeg')              { $wdqArgs += '--no-ffmpeg' }
if ($help -match '--no-quick-import')        { $wdqArgs += '--no-quick-import' }
if ($help -match '--exclude-plugins')        { $wdqArgs += @('--exclude-plugins', 'qsqlpsql,qsqlodbc,qsqlmysql,qsqlibase,qsqloci') }
$qtpaths = Join-Path $qtTools 'qtpaths.exe'
if (($help -match '--qtpaths') -and (Test-Path $qtpaths)) { $wdqArgs += @('--qtpaths', $qtpaths) }
$wdqArgs += (Join-Path $DistDir 'qbittorrent.exe')
Invoke-Native $windeployqt $wdqArgs

# Ensure the plugins upstream ships are present (copy from vcpkg if windeployqt skipped any)
$qtPluginRoot = @((Join-Path $tripletDir 'Qt6\plugins'), (Join-Path $tripletDir 'plugins')) | Where-Object { Test-Path $_ } | Select-Object -First 1
$wantPlugins = @('platforms\qwindows.dll', 'styles\qmodernwindowsstyle.dll', 'sqldrivers\qsqlite.dll',
                 'tls\qschannelbackend.dll', 'iconengines\qsvgicon.dll', 'imageformats\qsvg.dll',
                 'imageformats\qico.dll', 'imageformats\qjpeg.dll', 'imageformats\qgif.dll')
foreach ($p in $wantPlugins) {
    $dst = Join-Path $DistDir "plugins\$p"
    if (-not (Test-Path $dst)) {
        $src = if ($qtPluginRoot) { Join-Path $qtPluginRoot $p } else { $null }
        if ($src -and (Test-Path $src)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item $src $dst
            Write-Host "   + plugin $p"
        } elseif ($p -match 'qwindows|qsqlite') {
            throw "Required Qt plugin missing: $p"
        } else {
            Write-Warning "Optional Qt plugin not found: $p"
        }
    }
}
# Drop debug plugin variants if any slipped in
Get-ChildItem (Join-Path $DistDir 'plugins') -Recurse -Filter '*d.dll' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.DirectoryName ($_.Name -replace 'd\.dll$', '.dll')) } | Remove-Item -Force

# Recursively resolve non-system DLL dependencies from the vcpkg bin dir (libtorrent, OpenSSL, zlib,
# ICU, pcre2, harfbuzz, freetype, brotli, zstd, double-conversion, ...)
Write-Host '   Resolving vcpkg runtime DLLs via dumpbin /dependents'
$copied = @{}
do {
    $added = 0
    $pes = Get-ChildItem $DistDir -Recurse -Include '*.exe', '*.dll' -File
    foreach ($pe in $pes) {
        $deps = & $dumpbin /nologo /dependents $pe.FullName |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[\w\.\-\+]+\.dll$' }
        foreach ($d in $deps) {
            if ($copied.ContainsKey($d.ToLower())) { continue }
            if (Test-Path (Join-Path $DistDir $d)) { $copied[$d.ToLower()] = $true; continue }
            $src = Join-Path $vcpkgBin $d
            if (Test-Path $src) {
                Copy-Item $src $DistDir
                $copied[$d.ToLower()] = $true
                $added++
                Write-Host "   + $d"
            }
        }
    }
} while ($added -gt 0)

# Explicit check for the key runtime DLLs
$present = (Get-ChildItem $DistDir -Filter '*.dll' -File).Name
foreach ($pat in @('Qt6Core*.dll', 'Qt6Widgets*.dll', 'Qt6Network*.dll', 'Qt6Sql*.dll', 'Qt6Xml*.dll', 'Qt6Svg*.dll',
                   'torrent-rasterbar*.dll', 'libssl-3*.dll', 'libcrypto-3*.dll', 'zlib*.dll')) {
    # newer vcpkg zlib ports name the DLL z.dll instead of zlib1.dll
    if (-not ($present | Where-Object { ($_ -like $pat) -or ($pat -eq 'zlib*.dll' -and $_ -eq 'z.dll') })) {
        # libtorrent / boost may be static in some triplets - only warn for those
        if ($pat -like 'torrent-rasterbar*') { Write-Warning "No $pat in dist (OK only if libtorrent was linked statically)." }
        elseif ($pat -like 'Qt6Svg*') { Write-Warning "No $pat in dist." }
        else { throw "Runtime DLL matching $pat missing from dist." }
    }
}

# MSVC ARM64 CRT (app-local)
$redistRoot = Join-Path $vsPath 'VC\Redist\MSVC'
$crtDir = Get-ChildItem $redistRoot -Directory | Where-Object { $_.Name -match '^\d+\.' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'arm64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $crtDir) { throw "MSVC ARM64 CRT redist not found under $redistRoot" }
Write-Host "   CRT: $($crtDir.FullName)"
Copy-Item (Join-Path $crtDir.FullName '*.dll') $DistDir -Force

# Third-party license texts (vcpkg keeps each port's license as share\<port>\copyright) + qBittorrent's GPL
$licDir = Join-Path $DistDir 'licenses'
New-Item -ItemType Directory -Force $licDir | Out-Null
Get-ChildItem (Join-Path $tripletDir 'share') -Directory | ForEach-Object {
    $c = Join-Path $_.FullName 'copyright'
    if (Test-Path $c) { Copy-Item $c (Join-Path $licDir "$($_.Name).txt") -Force }
}
Copy-Item (Join-Path $SourceDir 'COPYING') (Join-Path $licDir 'qBittorrent-COPYING.txt') -Force
Write-Host "   Licenses: $((Get-ChildItem $licDir -File).Count) files in licenses\"

# Final verification: every PE in dist must be ARM64 (ARM64X/ARM64EC system DLLs are not shipped)
$bad = @()
foreach ($pe in Get-ChildItem $DistDir -Recurse -Include '*.exe', '*.dll' -File) {
    $m = (& $dumpbin /nologo /headers $pe.FullName | Select-String 'machine \(' | Select-Object -First 1).Line
    if ($m -notmatch 'ARM64') { $bad += "$($pe.FullName): $m" }
}
if ($bad) { throw "Non-ARM64 binaries in dist:`n$($bad -join "`n")" }

# --------------------------------------------------------------------------------------------
# 6. Zip
# --------------------------------------------------------------------------------------------
if (-not $NoZip) {
    Write-Step 'Creating zip'
    $zip = Join-Path $Root "qBittorrent-$Version-arm64-portable.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path $DistDir -DestinationPath $zip -CompressionLevel Optimal
    Write-Host "   $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
}

Write-Step "Done. qBittorrent $Version ARM64 staged at $DistDir"
