<#
Smoke test for the native ARM64 qBittorrent build.
Launches qbittorrent.exe with a throwaway profile, Web UI enabled with random credentials
(only the PBKDF2 hash is written to disk), then exercises the Web API and a real, legal torrent
(Debian arm64 netinst). Everything (profile, downloads) is deleted afterwards.

  .\scripts\smoke-test.ps1 [-Exe <path>] [-Port 8089] [-TorrentTimeout 90] [-KeepProfile]
#>
param(
    [string]$Exe = 'C:\dev\qbt-arm64\dist\qBittorrent\qbittorrent.exe',
    [int]$Port = 8089,
    [int]$TorrentTimeout = 90,
    [switch]$KeepProfile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, [bool]$Pass, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Test = $Name; Result = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
    Write-Host ("[{0}] {1} {2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $Detail) -ForegroundColor $(if ($Pass) { 'Green' } else { 'Red' })
}

if (-not (Test-Path $Exe)) { throw "qbittorrent.exe not found: $Exe" }
$distDir = Split-Path $Exe

# --- 1. PE architecture of every binary (ARM64 = 0xAA64; ARM64X runtime DLLs have an x64 header plus a hybrid ARM64 image;
#        an installed copy also has NSIS's x86 uninst.exe) ---
$bad = @()
$peFiles = Get-ChildItem $distDir -Recurse -Include *.exe, *.dll -File
foreach ($f in $peFiles) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $m = [BitConverter]::ToUInt16($b, [BitConverter]::ToInt32($b, 0x3c) + 4)
    if ($m -ne 0xAA64 -and -not ($m -eq 0x8664 -and $f.Name -like 'vcruntime140_1.dll') -and -not ($m -eq 0x014C -and $f.Name -eq 'uninst.exe')) { $bad += ('{0}=0x{1:X4}' -f $f.Name, $m) }
}
Add-Result 'All binaries ARM64' ($bad.Count -eq 0) "$($peFiles.Count) PE files$(if ($bad) { '; bad: ' + ($bad -join ', ') })"

# --- 2. Expected Qt plugins ---
$pluginDir = Join-Path $distDir 'plugins'
$plugins = @('platforms\qwindows.dll', 'sqldrivers\qsqlite.dll', 'imageformats\qsvg.dll', 'imageformats\qico.dll')
$missing = $plugins | Where-Object { -not (Test-Path (Join-Path $pluginDir $_)) }
$tls = Get-ChildItem (Join-Path $pluginDir 'tls') -Filter *.dll -EA SilentlyContinue
$style = Get-ChildItem (Join-Path $pluginDir 'styles') -Filter *.dll -EA SilentlyContinue
if (-not $tls) { $missing += 'tls\*' }
if (-not $style) { $missing += 'styles\*' }
Add-Result 'Qt plugins present' (-not $missing) $(if ($missing) { 'missing: ' + ($missing -join ', ') } else { "tls: $($tls.Name -join ','); styles: $($style.Name -join ',')" })

# --- 3. Throwaway profile with hashed Web UI credentials ---
$profileDir = Join-Path $env:TEMP "qbt-smoke-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$saveDir = Join-Path $profileDir 'downloads'
$cfgDir = Join-Path $profileDir 'qBittorrent\config'
New-Item -ItemType Directory -Force $cfgDir, $saveDir | Out-Null

$user = 'smoketest'
$pass = -join ((1..24) | ForEach-Object { [char[]]'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789' | Get-Random })
$salt = [byte[]]::new(16); [Security.Cryptography.RandomNumberGenerator]::Fill($salt)
$hash = [Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2([Text.Encoding]::UTF8.GetBytes($pass), $salt, 100000, [Security.Cryptography.HashAlgorithmName]::SHA512, 64)
$pbkdf2 = "@ByteArray($([Convert]::ToBase64String($salt)):$([Convert]::ToBase64String($hash)))"

@"
[LegalNotice]
Accepted=true

[BitTorrent]
Session\DefaultSavePath=$($saveDir.Replace('\', '/'))
Session\TempPathEnabled=false

[Preferences]
WebUI\Enabled=true
WebUI\Address=127.0.0.1
WebUI\Port=$Port
WebUI\Username=$user
WebUI\Password_PBKDF2="$pbkdf2"
WebUI\LocalHostAuth=true
General\StartMinimized=true

[Application]
GUI\Notifications\Enabled=false
"@ | Set-Content (Join-Path $cfgDir 'qBittorrent.ini') -Encoding utf8

$base = "http://127.0.0.1:$Port"
$proc = $null
try {
    # --- 4. Launch and check native process architecture ---
    $proc = Start-Process $Exe -ArgumentList "--profile=`"$profileDir`"", '--no-splash' -PassThru
    Add-Type -Namespace Native -Name K32 -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool IsWow64Process2(IntPtr hProcess, out ushort processMachine, out ushort nativeMachine);
'@
    Start-Sleep 2
    [uint16]$pm = 0; [uint16]$nm = 0
    [void][Native.K32]::IsWow64Process2($proc.Handle, [ref]$pm, [ref]$nm)
    # processMachine 0 = not running under WOW64 emulation (native); nativeMachine 0xAA64 = ARM64 host
    Add-Result 'Process runs natively' ($pm -eq 0 -and $nm -eq 0xAA64) ('processMachine=0x{0:X4} nativeMachine=0x{1:X4}' -f $pm, $nm)

    # --- 5. Web UI up and auth enforced ---
    $up = $false
    for ($i = 0; $i -lt 30 -and -not $up; $i++) {
        Start-Sleep 1
        try { Invoke-WebRequest "$base/" -TimeoutSec 2 | Out-Null; $up = $true } catch { if ($_.Exception.Response) { $up = $true } }
    }
    Add-Result 'Web UI listening' $up "port $Port after ~${i}s"
    if (-not $up) { throw 'Web UI never came up; see the qbittorrent.log in the profile.' }

    $unauth = try { Invoke-WebRequest "$base/api/v2/app/version" -TimeoutSec 5; 'allowed' } catch { [int]$_.Exception.Response.StatusCode }
    Add-Result 'Unauthenticated request rejected' ($unauth -eq 403) "status: $unauth"

    $badLogin = Invoke-WebRequest "$base/api/v2/auth/login" -Method Post -Body @{ username = $user; password = 'wrong-password' } -Headers @{ Referer = $base } -SkipHttpErrorCheck
    Add-Result 'Wrong password rejected' ([string]$badLogin.Content -notmatch '^Ok') "response: $($badLogin.StatusCode) $($badLogin.Content)"

    $s = $null
    $login = Invoke-WebRequest "$base/api/v2/auth/login" -Method Post -Body @{ username = $user; password = $pass } -Headers @{ Referer = $base } -SessionVariable s
    # qBittorrent >= 5.2 answers 204 with an empty body; older versions answer 200 'Ok.'
Add-Result 'Login with credentials' ($login.StatusCode -in 200, 204 -and [string]$login.Content -notmatch 'Fails') "status $($login.StatusCode)$(if ($login.Content) { ': ' + $login.Content })"

    # --- 6. Build info ---
    $ver = Invoke-RestMethod "$base/api/v2/app/version" -WebSession $s
    $bi = Invoke-RestMethod "$base/api/v2/app/buildInfo" -WebSession $s
    Add-Result 'App/build info' ($ver -like 'v5.*' -and $bi.bitness -eq 64) "$ver | Qt $($bi.qt) | libtorrent $($bi.libtorrent) | Boost $($bi.boost) | OpenSSL $($bi.openssl) | zlib $($bi.zlib) | $($bi.bitness)-bit"

    # --- 7. Real torrent: Debian arm64 netinst (legal, well seeded) ---
    $listing = Invoke-WebRequest 'https://cdimage.debian.org/debian-cd/current/arm64/bt-cd/' -UseBasicParsing
    $tName = ([regex]::Matches($listing.Content, 'href="(debian-[\d\.]+-arm64-netinst\.iso\.torrent)"') | Select-Object -First 1).Groups[1].Value
    if (-not $tName) { throw 'Could not find the Debian arm64 netinst .torrent on cdimage.debian.org.' }
    $tUrl = "https://cdimage.debian.org/debian-cd/current/arm64/bt-cd/$tName"
    $add = Invoke-WebRequest "$base/api/v2/torrents/add" -Method Post -WebSession $s -Body @{ urls = $tUrl; savepath = $saveDir; tags = 'smoketest' }
    # qBittorrent >= 5.2 answers JSON counts; older versions answer 'Ok.'
$addOk = [string]$add.Content -match '^Ok'
if (-not $addOk) { try { $j = [string]$add.Content | ConvertFrom-Json; $addOk = ($j.success_count + $j.pending_count) -gt 0 -and $j.failure_count -eq 0 } catch {} }
Add-Result 'Add torrent via API' $addOk "$tName -> $($add.Content)"

    $t = $null; $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false
    while ($sw.Elapsed.TotalSeconds -lt $TorrentTimeout) {
        Start-Sleep 3
        $t = @(Invoke-RestMethod "$base/api/v2/torrents/info?tag=smoketest" -WebSession $s) | Select-Object -First 1
        if ($t -and $t.downloaded -gt 1MB) { $ok = $true; break }
    }
    if ($t) {
        $detail = '{0} | state {1} | {2:N1} MB downloaded | {3:N1} MB/s | {4} seeds | {5:P1} after {6:N0}s' -f $t.name, $t.state, ($t.downloaded / 1MB), ($t.dlspeed / 1MB), $t.num_seeds, $t.progress, $sw.Elapsed.TotalSeconds
    } else { $detail = 'torrent never appeared in the list' }
    Add-Result 'Torrent downloads data' $ok $detail

    if ($t) {
        # tracker status 2 = working; the first announce can still be in progress (3 = updating) when data already flows via DHT
        $working = @()
        for ($k = 0; $k -lt 30 -and $working.Count -eq 0; $k++) {
            $tr = Invoke-RestMethod "$base/api/v2/torrents/trackers?hash=$($t.hash)" -WebSession $s
            $working = @($tr | Where-Object { $_.url -match '^(http|udp)' -and $_.status -eq 2 })
            if ($working.Count -eq 0) { Start-Sleep 1 }
        }
        Add-Result 'Tracker announce working' ($working.Count -gt 0) "$($working.Count) working tracker(s)"

        Invoke-WebRequest "$base/api/v2/torrents/delete" -Method Post -WebSession $s -Body @{ hashes = $t.hash; deleteFiles = 'true' } | Out-Null
        $left = 1
        # removal is asynchronous; file deletion can lag behind the torrent leaving the list
        $filesLeft = 1
        for ($k = 0; $k -lt 30 -and ($left -gt 0 -or $filesLeft -gt 0); $k++) {
            Start-Sleep 1
            $left = @(Invoke-RestMethod "$base/api/v2/torrents/info?tag=smoketest" -WebSession $s | ForEach-Object { $_ } | Where-Object { $_ }).Count
            $filesLeft = @(Get-ChildItem $saveDir -Recurse -File -EA SilentlyContinue).Count
        }
        Add-Result 'Delete torrent + files' ($left -eq 0 -and $filesLeft -eq 0) "torrents left: $left, files left: $filesLeft"
    }

    # --- 8. Clean shutdown ---
    Invoke-WebRequest "$base/api/v2/app/shutdown" -Method Post -WebSession $s | Out-Null
    $exited = $proc.WaitForExit(30000)
    Add-Result 'Clean shutdown via API' $exited $(if ($exited) { "exit code $($proc.ExitCode)" } else { 'still running after 30s' })
}
catch {
    Add-Result 'Unexpected error' $false $_.Exception.Message
}
finally {
    $pass = $null
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; Start-Sleep 2 }
    if ($KeepProfile) { Write-Host "Profile kept at $profileDir" }
    else { Remove-Item $profileDir -Recurse -Force -EA SilentlyContinue }
}

Write-Host ''
$results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host $(if ($failed) { "$failed test(s) FAILED" } else { "All $($results.Count) tests passed" }) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
exit $(if ($failed) { 1 } else { 0 })
