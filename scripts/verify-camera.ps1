#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Verify the documented findings against a live camera.

.DESCRIPTION
  This repo makes specific, testable claims about the Geeni/Merkury CW017
  (Mini 11S) on firmware 2.10.6 / HiSilicon hi_sfc. This script re-tests them
  against a real device so the documentation cannot silently drift.

  Usage:
    ./verify-camera.ps1 -IP 192.168.4.119
    ./verify-camera.ps1 -IP 192.168.4.119 -SkipHackTest

.NOTES
  READ-ONLY. Nothing here writes to the camera or its flash.
  Safe to run against a working camera.

  CRITICAL: the camera sends NO WWW-Authenticate header, so standard
  client URL auth (http://user:pass@host/) FAILS with 401. Every request
  here hand-builds the Basic auth header. See README "Credentials".
#>

param(
  [Parameter(Mandatory=$true)][string]$IP,
  [string]$User = 'admin',
  [string]$Pass = '056565099',
  [switch]$SkipHackTest
)

$ErrorActionPreference = 'Continue'

# NOTE: do not name these $pass/$fail - PowerShell reserves them and assigns
# a string, which breaks the ++ operator.
$script:nPass = 0
$script:nFail = 0
$script:nInfo = 0

function Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

function Check($name, $condition, $detail) {
  if ($condition) {
    Write-Host ("  [PASS] {0}" -f $name) -ForegroundColor Green
    $script:nPass = $script:nPass + 1
  } else {
    Write-Host ("  [FAIL] {0}" -f $name) -ForegroundColor Red
    if ($detail) { Write-Host ("         {0}" -f $detail) -ForegroundColor DarkGray }
    $script:nFail = $script:nFail + 1
  }
}

function Note($msg) {
  Write-Host ("  [info] {0}" -f $msg) -ForegroundColor DarkGray
  $script:nInfo = $script:nInfo + 1
}

# Raw Basic-auth GET. Required because the camera omits WWW-Authenticate.
# Connection: close is essential - the device closes the socket itself and a
# keep-alive read would block until timeout.
function Get-CameraPath($path, $timeoutMs = 6000) {
  $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect($IP, 80, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(2500)) { $c.Close(); return $null }
    $c.EndConnect($iar)
    $s = $c.GetStream()
    $rq = "GET $path HTTP/1.1`r`nHost: $IP`r`nAuthorization: Basic $auth`r`nConnection: close`r`n`r`n"
    $b = [Text.Encoding]::ASCII.GetBytes($rq)
    $s.Write($b, 0, $b.Length); $s.Flush()

    # Read the whole response, not a single Read() - headers and body can
    # arrive in separate TCP segments.
    $ms = New-Object System.IO.MemoryStream
    $s.ReadTimeout = $timeoutMs
    $buf = New-Object byte[] 16384
    try {
      while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
    } catch { }
    $c.Close()

    $bytes = $ms.ToArray()
    if ($bytes.Length -eq 0) { return $null }
    $resp = [Text.Encoding]::ASCII.GetString($bytes)
    if (($resp -split "`r`n")[0] -notmatch '200') { return $null }
    return ($resp -split "`r`n`r`n", 2)[1]
  } catch { return $null }
}

Write-Host "########################################################"
Write-Host "#  CW017 / Mini 11S 2.10.6 (hi_sfc) - claim verification"
Write-Host "#  target: $IP"
Write-Host "########################################################"

# ---------------------------------------------------------------- reachability
Section "Reachability"

$alive = Test-Connection -TargetName $IP -Count 2 -Quiet -TimeoutSeconds 2 -ErrorAction SilentlyContinue
Check "host responds to ping" $alive "camera may be unplugged or on another subnet"

$mac = (Get-NetNeighbor -IPAddress $IP -ErrorAction SilentlyContinue | Select-Object -First 1).LinkLayerAddress
if ($mac) { Note "MAC: $mac" }

# ------------------------------------------------------------------- port 80
Section "Claim: HTTP is on port 80 (NOT 8090) on 2.10.x"

$p80   = Test-NetConnection -ComputerName $IP -Port 80   -WarningAction SilentlyContinue -InformationLevel Quiet
$p8090 = Test-NetConnection -ComputerName $IP -Port 8090 -WarningAction SilentlyContinue -InformationLevel Quiet
$p6668 = Test-NetConnection -ComputerName $IP -Port 6668 -WarningAction SilentlyContinue -InformationLevel Quiet

Check "port 80 OPEN (ppsFactoryTool.txt hot-inserted)" $p80 "port 80 closed => SD card not inserted, or hack not active"
Check "port 8090 CLOSED (that is 4.0.x only)" (-not $p8090) "8090 opened - unusual for 2.10.x, please report"
Check "port 6668 OPEN (Tuya LAN service)" $p6668

if (-not $p80) {
  Write-Host "`n  Port 80 is closed - cannot verify further claims." -ForegroundColor Yellow
  Write-Host "  Fix: hot-insert the SD card containing ppsFactoryTool.txt while the camera runs." -ForegroundColor Yellow
  Write-Host "       (NO reset and NO power cycle - see README)" -ForegroundColor Yellow
  Write-Host "`n  PASS: $script:nPass   FAIL: $script:nFail"
  exit 1
}

# -------------------------------------------------------------- raw auth trap
Section "Claim: URL-style auth fails; raw Basic auth works"

$urlStyleWorked = $false
try {
  $r = Invoke-WebRequest -Uri "http://${User}:${Pass}@${IP}/devices/deviceinfo" -TimeoutSec 5 -ErrorAction Stop
  $urlStyleWorked = $true
} catch { }

$body = Get-CameraPath "/devices/deviceinfo"
Check "raw Basic auth returns data" ([bool]$body) "no response from /devices/deviceinfo"
if (-not $urlStyleWorked) {
  Note "confirmed: http://user:pass@host/ style FAILED (expected - no WWW-Authenticate header)"
} else {
  Note "url-style auth worked on this client (provider-dependent; raw auth still correct)"
}

# ------------------------------------------------------------------- identity
Section "Device identity"

if ($body) {
  try {
    $d = $body | ConvertFrom-Json
    Note "model       : $($d.model)"
    Note "software    : $($d.softwareversion)"
    Note "hardware    : $($d.hardwareversion)"
    Note "firmware    : $($d.firmwareversion)"
    Note "serial      : $($d.serialno)"
    Note "WiFi MAC    : $($d.'WiFi MAC')"

    Check "model is 'Mini 11S'"       ($d.model -eq 'Mini 11S')
    Check "software version is 2.10.6" ($d.softwareversion -eq '2.10.6') "got $($d.softwareversion) - documentation may not apply"
    Check "brand is geeni"            ($d.firmwareversion -match 'geeni')
  } catch {
    Check "deviceinfo parses as JSON" $false $_.Exception.Message
  }
} else {
  Check "deviceinfo readable" $false
}

# --------------------------------------------------------------- cmdline/hw
Section "Claim: platform is HiSilicon hi_sfc, not spi0.0"

$cmdline = Get-CameraPath "/proc/cmdline"
if ($cmdline) {
  Note "cmdline: $($cmdline.Trim())"
  Check "cmdline contains 'hi_sfc'"  ($cmdline -match 'hi_sfc')
  Check "cmdline does NOT contain 'spi0.0'" ($cmdline -notmatch 'spi0\.0')
  Check "mem=37M (not 64M)"          ($cmdline -match 'mem=37M')
} else { Check "/proc/cmdline readable" $false }

$cpu = Get-CameraPath "/proc/version"
if ($cpu) { Note "kernel: $($cpu.Trim())" }

$mtd = Get-CameraPath "/proc/mtd"
if ($mtd) {
  Section "Flash layout"
  $mtd.Trim() -split "`n" | ForEach-Object { Note $_.Trim() }
  Check "app partition is 4352k" ($mtd -match '00440000')
}

# ------------------------------------------------------------ boot hack status
if (-not $SkipHackTest) {
  Section "Claim: the SD boot hack does NOT work (bootloader lacks 'run')"

  if ($cmdline) {
    $hasHack = $cmdline -match 'initrun\.sh'
    Check "cmdline does NOT contain initrun.sh (confirms dead end)" (-not $hasHack) `
      "initrun.sh IS present - the boot hack worked on this unit, please report!"
  }

  $hackFile = Get-CameraPath "/proc/self/root/mnt/mmc01/hack"
  Check "no 'hack' marker on SD card" (-not $hackFile) "hack marker present - boot hack worked, please report"

  $homeDir = Get-CameraPath "/proc/self/root/mnt/mmc01/home"
  Check "no 'home/' dir on SD card" (-not $homeDir) "home/ present - boot hack worked, please report"
}

# ---------------------------------------------------------------- the prize
Section "Claim: onvif_enable exists and is 0 by default"

$cfg = Get-CameraPath "/proc/self/root/home/cfg/tuya_config.json"
if ($cfg) {
  $m = [regex]::Matches($cfg, '"onvif\w*":\s*\S+')
  foreach ($x in $m) { Note $x.Value }
  Check "tuya_config.json readable" $true
  Check "onvif_enable present" ($cfg -match '"onvif_enable"')
  Check "onvif_enable is 0" ($cfg -match '"onvif_enable":\s*0') "already 1 - check for ports 8000/8554"
} else { Check "tuya_config.json readable" $false }

$rtsp = Test-NetConnection -ComputerName $IP -Port 8554 -WarningAction SilentlyContinue -InformationLevel Quiet
$onvif = Test-NetConnection -ComputerName $IP -Port 8000 -WarningAction SilentlyContinue -InformationLevel Quiet
Check "RTSP 8554 still closed (not yet enabled)" (-not $rtsp) "8554 OPEN - ONVIF is enabled on this unit!"
Check "ONVIF 8000 still closed" (-not $onvif) "8000 OPEN - ONVIF is enabled on this unit"

# ------------------------------------------------------------ injection point
Section "Claim: /etc/init.d/rcS runs any /etc/init.d/S## script as root"

$rcs = Get-CameraPath "/proc/self/root/etc/init.d/rcS"
if ($rcs) {
  Check "rcS readable" $true
  Check "rcS iterates /etc/init.d/S[0-9][0-9]*" ($rcs -match 'S\[0-9\]\[0-9\]')
  Check "rcS echoes 'Meari Tech'" ($rcs -match 'Meari Tech')
} else { Check "rcS readable" $false }

$s70 = Get-CameraPath "/proc/self/root/etc/init.d/S70custom"
Check "S70custom NOT yet installed (flash not modified)" (-not $s70) "S70custom present - this unit HAS been flashed!"

# ------------------------------------------------------------------- summary
Section "Summary"
Write-Host ("  PASS: {0}   FAIL: {1}   info: {2}" -f $script:nPass, $script:nFail, $script:nInfo) -ForegroundColor $(if ($script:nFail -eq 0) { 'Green' } else { 'Yellow' })

if ($script:nFail -eq 0) {
  Write-Host "`n  All documented claims hold on this device." -ForegroundColor Green
} else {
  Write-Host "`n  $script:nFail claim(s) did NOT hold - the docs may have drifted," -ForegroundColor Yellow
  Write-Host "  or this is a different hardware/firmware revision. Please open an issue" -ForegroundColor Yellow
  Write-Host "  with your /devices/deviceinfo and /proc/cmdline output." -ForegroundColor Yellow
}

exit $(if ($script:nFail -eq 0) { 0 } else { 1 })
