# ThuNet-Probe.ps1 - record what the campus portal is doing when the link is blocked.
#
# WHY THIS EXISTS: a captive portal has to be identified before a login can be written against it,
# and the portal of a building you are not in cannot be studied from where you are.  This script
# does not guess.  It waits until the machine is actually sitting behind a portal, then records
# exactly what that portal is - the redirect target, the response headers and a slice of the page
# body - into a capture file.  With that capture the login step can be checked against the real
# portal instead of against an assumption.
#
# It deliberately bypasses the Windows system proxy: a captive portal intercepts direct traffic, so
# routing these probes through a local HTTP proxy would hide the interception and record nothing.
#
# It is also useful as a plain "is the link really up" heartbeat, which is what -Watch gives you.
#
# THIS FILE MUST STAY PURE ASCII - see the header of ThuNet-Login.ps1 for why.
#
# USAGE
#   ThuNet-Probe.ps1                            probe once and report
#   ThuNet-Probe.ps1 -Watch                     stay resident and keep recording (default 120s)
#   ThuNet-Probe.ps1 -Watch -IntervalSeconds 30
#   ThuNet-Probe.ps1 -LogDir <path>

param(
    [switch]$Watch,
    [int]$IntervalSeconds = 120,
    [int]$MaxRuns = 0,
    [string]$LogDir
)

$ErrorActionPreference = 'Continue'

$Root = Join-Path $env:LOCALAPPDATA 'ThuNetAutoLogin'
if (-not $LogDir) { $LogDir = Join-Path $Root 'logs' }
foreach ($d in @($Root, $LogDir)) {
    if ($d -and -not (Test-Path $d)) {
        try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch { }
    }
}
$LogFile = Join-Path $LogDir 'thunet-probe.log'
$CapFile = Join-Path $LogDir 'thunet-probe-capture.txt'

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
        $fi = Get-Item $LogFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 256KB) {
            Set-Content -Path $LogFile -Value (Get-Content $LogFile -Tail 200) -Encoding UTF8
        }
    } catch { }
}

function Fetch-Raw([string]$url) {
    $req = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        # No automatic redirect: the intercepting response IS the evidence, and following it would
        # replace the 302 with the portal's landing page.
        $req.AllowAutoRedirect = $false
        $req.Timeout = 10000
        $req.ReadWriteTimeout = 10000
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        $req.Proxy = $null
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd()
        $sr.Close()
        $code = [int]$resp.StatusCode
        $loc = $resp.Headers['Location']
        $srv = $resp.Headers['Server']
        $ctype = $resp.ContentType
        $resp.Close()
        return [pscustomobject]@{ Url = $url; Code = $code; Location = $loc; Server = $srv; CType = $ctype; Body = $body }
    } catch [System.Net.WebException] {
        # A 302 shows up here rather than above, because a redirect is an error for a request that
        # refuses to follow one.  Its response object still carries the headers being looked for.
        $r = $_.Exception.Response
        if ($r) {
            $code = [int]$r.StatusCode
            $loc = $r.Headers['Location']
            $srv = $r.Headers['Server']
            $ctype = $r.ContentType
            try {
                $sr = New-Object System.IO.StreamReader($r.GetResponseStream())
                $body = $sr.ReadToEnd()
                $sr.Close()
            } catch { $body = '' }
            $r.Close()
            return [pscustomobject]@{ Url = $url; Code = $code; Location = $loc; Server = $srv; CType = $ctype; Body = $body }
        }
        return [pscustomobject]@{ Url = $url; Code = -1; Location = ''; Server = ''; CType = ''; Body = $_.Exception.Message }
    } catch {
        return [pscustomobject]@{ Url = $url; Code = -1; Location = ''; Server = ''; CType = ''; Body = $_.Exception.Message }
    }
}

function Get-Online {
    # Strict on purpose, exactly like the check in ThuNet-Login.ps1: a portal answers 200 with its
    # own page, so a bare 200 means "intercepted", not "online".  The body has to be exactly what
    # the endpoint promises (whitespace ignored, because the real answer ends with a newline).
    $r = Fetch-Raw 'http://www.msftconnecttest.com/connecttest.txt'
    $clean = ($r.Body -replace '\s', '')
    if ($r.Code -eq 200 -and $clean -eq 'MicrosoftConnectTest') { return $true }
    return $false
}

function Capture-Portal {
    $probes = @(
        'http://www.msftconnecttest.com/connecttest.txt',
        'http://captive.apple.com/hotspot-detect.html',
        'http://connect.rom.miui.com/generate_204',
        'http://detectportal.firefox.com/success.txt'
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('================================================================')
    [void]$sb.AppendLine(('portal capture at {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    [void]$sb.AppendLine('--- network ---')
    try {
        Get-NetIPConfiguration -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$sb.AppendLine(('  if={0} ipv4={1} gw={2}' -f $_.InterfaceAlias, ($_.IPv4Address.IPAddress -join ','), ($_.IPv4DefaultGateway.NextHop -join ',')))
        }
    } catch { }
    $locations = @()
    foreach ($u in $probes) {
        $r = Fetch-Raw $u
        [void]$sb.AppendLine(('--- {0}' -f $u))
        [void]$sb.AppendLine(('  status={0}  location={1}  server={2}  type={3}' -f $r.Code, $r.Location, $r.Server, $r.CType))
        if ($r.Location) { $locations += $r.Location }
        $b = $r.Body
        if ($b -and $b.Length -gt 4000) { $b = $b.Substring(0, 4000) + ' ...[truncated]' }
        [void]$sb.AppendLine('  body:')
        foreach ($line in (($b -split "`n") | Select-Object -First 80)) { [void]$sb.AppendLine('    ' + $line.Trim()) }
    }
    $text = $sb.ToString()
    try {
        Add-Content -Path $CapFile -Value $text -Encoding UTF8
        $fi = Get-Item $CapFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 512KB) {
            Set-Content -Path $CapFile -Value (Get-Content $CapFile -Tail 400) -Encoding UTF8
        }
    } catch { }
    # The most useful single fact: where the interception sends us.  Note the probes above were
    # already fetched with AllowAutoRedirect off, so the Location seen here is the first hop of the
    # chain, which is where the portal identifies itself.
    $loc = @($locations | Where-Object { $_ } | Select-Object -First 1)
    if ($loc.Count -gt 0) { return ('portal interception recorded; redirect target = ' + $loc[0]) }
    return 'portal interception recorded; redirect target = (none seen - portal may serve its own page instead of redirecting)'
}

function Run-Once {
    if (Get-Online) { return 'online: no portal in the way' }
    return (Capture-Portal)
}

if (-not $Watch) {
    $r = Run-Once
    Write-Host $r
    return
}

$limitText = 'unlimited'
if ($MaxRuns -gt 0) { $limitText = "$MaxRuns" }
Write-Log ("probe started (interval {0}s, max runs {1})" -f $IntervalSeconds, $limitText)

# One probe only, for the same reason the login watcher takes a mutex: two probes writing the same
# capture file interleave and produce a file that reads as if the portal changed twice a minute.
$mutex = New-Object System.Threading.Mutex($false, 'Local\ThuNetAutoLoginProbe')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'another ThuNet probe is already running - exiting'
    return
}

$runs = 0
$last = ''
try {
    while ($true) {
        if ($MaxRuns -gt 0 -and $runs -ge $MaxRuns) { break }
        try {
            $state = Run-Once
            if ($state -ne $last) { Write-Log $state; $last = $state }
            Write-Host $state
        } catch {
            Write-Log ('probe error: ' + $_.Exception.Message)
        }
        $runs++
        if ($MaxRuns -gt 0 -and $runs -ge $MaxRuns) { break }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
Write-Log ("probe stopped after {0} run(s)" -f $runs)
