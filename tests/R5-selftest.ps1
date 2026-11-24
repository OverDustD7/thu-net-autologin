param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$TempRoot,
    [Parameter(Mandatory=$true)][string]$CredDir
)
$ErrorActionPreference = 'Continue'
$env:LOCALAPPDATA = $TempRoot
$env:APPDATA = $TempRoot
$logDir = Join-Path $TempRoot 'logs'
New-Item -ItemType Directory -Path $CredDir, $logDir -Force | Out-Null

$sentinelUser = Join-Path $CredDir 'ThuNet-user.txt'
$sentinelAcid = Join-Path $CredDir 'ThuNet-ac_id.txt'
Set-Content -Path $sentinelUser -Value 'R5-SENTINEL-ACCOUNT' -Encoding ASCII
Set-Content -Path $sentinelAcid -Value '999' -Encoding ASCII
$lockUser = [System.IO.File]::Open($sentinelUser, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
$lockAcid = [System.IO.File]::Open($sentinelAcid, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)

Add-Type -TypeDefinition @"
using System;
using System.Net;
public class R5BlockFactory : IWebRequestCreate {
    public static int Count;
    public WebRequest Create(Uri uri) {
        Count++;
        throw new WebException("blocked by R5 network guard");
    }
}
"@
$factory = New-Object R5BlockFactory
[void][System.Net.WebRequest]::RegisterPrefix('http', $factory)
[void][System.Net.WebRequest]::RegisterPrefix('https', $factory)

$out = @()
try {
    $out = @(& $Source -SelfTest -CredentialDir $CredDir -LogDir $logDir 2>&1 6>&1 | ForEach-Object { $_.ToString() })
} finally {
    $lockUser.Dispose()
    $lockAcid.Dispose()
}
Write-Output ('NETCOUNT=' + [R5BlockFactory]::Count)
Write-Output ('OUTLINES=' + $out.Count)
foreach ($line in $out) { Write-Output ('OUT=' + $line) }