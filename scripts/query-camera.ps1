#!/usr/bin/env pwsh
# query-camera.ps1 - read files from the camera's HTTP server.
#
# CRITICAL: the camera sends NO WWW-Authenticate header, so standard
# client URL auth (http://user:pass@host/) FAILS with 401.
# You MUST hand-build the Basic auth header. This script does that.
#
# Usage: ./query-camera.ps1 -IP 192.168.4.119 -Path /devices/deviceinfo

param(
  [Parameter(Mandatory=$true)][string]$IP,
  [Parameter(Mandatory=$true)][string]$Path,
  [string]$User = 'admin',
  [string]$Pass = '056565099',
  [int]$TimeoutMs = 5000
)

$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
try {
  $c = New-Object System.Net.Sockets.TcpClient
  $iar = $c.BeginConnect($IP, 80, $null, $null)
  if (-not $iar.AsyncWaitHandle.WaitOne(2000)) { $c.Close(); throw "connect timeout" }
  $c.EndConnect($iar)
  $s = $c.GetStream()
  $rq = "GET $Path HTTP/1.1`r`nHost: $IP`r`nAuthorization: Basic $auth`r`nConnection: close`r`n`r`n"
  $b = [Text.Encoding]::ASCII.GetBytes($rq)
  $s.Write($b, 0, $b.Length); $s.Flush()
  $s.ReadTimeout = $TimeoutMs
  $buf = New-Object byte[] 131072
  $n = $s.Read($buf, 0, 131072)
  $c.Close()
  $resp = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
  ($resp -split "`r`n`r`n", 2)[1]
} catch { Write-Error $_ }