# ThuNet-Login.ps1 - unattended login to Tsinghua's srun campus-network portal.
#
# WHAT: this machine's wired wall port needs Tsinghua's real-name authentication after every
# boot and every sleep/resume.  The portal is srun: http://login.tsinghua.edu.cn/ redirects to
# /srun_portal_pc?ac_id=1&theme=pro, and the auth service answers on https://auth4.tsinghua.edu.cn
# (101.6.4.100).  The request format implemented below is the one used by
# https://github.com/WhymustIhaveaname/TsinghuaTunet (connect.py), which is known to work here.
#
# THIS FILE MUST STAY PURE ASCII.  Windows PowerShell 5.1 reads a BOM-less UTF-8 script as ANSI
# (cp936 on a Chinese system), so a non-ASCII literal is decoded into different characters; a
# quote byte that appears inside a multi-byte sequence ends a string early and the WHOLE FILE
# fails to load - and the reported error line is wrong, because it refers to the mis-decoded
# text.  Every comment and every console string here is English for that reason.  The docs
# (README.md, docs/*.md) are Chinese because Markdown has no such constraint.
#
# CREDENTIALS: this script READS credentials and never writes them.  The account name lives in a
# plain text file and the password in a DPAPI-encrypted file (CurrentUser scope), so only the
# Windows user who ran the setup script can decrypt it.  Writing those files is the job of
# Set-ThuNetCredential.ps1, which is the only credential writer in this repository.
#
# USAGE
#   ThuNet-Login.ps1 -Once                        log in once if the link is not authenticated
#   ThuNet-Login.ps1 -Watch -IntervalSeconds 60   stay resident, re-login whenever the link drops
#   ThuNet-Login.ps1 -Watch -MaxRuns 0            same, unlimited (0 = no limit; the default)
#   ThuNet-Login.ps1 -Status                      report stored account + link state, change nothing
#   ThuNet-Login.ps1 -SelfTest                    verify the SRBX1 encoder against a fixed vector
#   ThuNet-Login.ps1 -TestLogin                   attempt one login and print the raw response
#
# ZERO DEPENDENCIES: PowerShell 5.1 built-ins and .NET built-ins only.  No modules, no external
# programs - in particular -SelfTest does NOT call the Python reference implementation any more;
# it compares against a vector recorded from it (see $SelfTestExpectedHex below).

param(
    [switch]$Once,
    [switch]$Watch,
    [switch]$Status,
    [switch]$SelfTest,
    [switch]$TestLogin,
    [int]$IntervalSeconds = 60,
    [int]$MaxRuns = 0,
    [string]$CredentialDir,
    [string]$LogDir
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- paths and layout
# Install root holds machine-local state; credentials and logs live in their own subdirectories
# so that a caller can point -CredentialDir at an existing set (for example a directory another
# script of yours already uses) without dragging the logs along with it.
$script:Root = Join-Path $env:LOCALAPPDATA 'ThuNetAutoLogin'
if (-not $CredentialDir) { $CredentialDir = Join-Path $script:Root 'creds' }
if (-not $LogDir)        { $LogDir        = Join-Path $script:Root 'logs' }
$script:CredDir  = $CredentialDir
$script:LogDir   = $LogDir
# Machine-local state that is NOT a credential - today just the learned ac_id.  It lives beside the
# install rather than in the credential directory, because the credential directory may be a legacy
# or read-only location that this script must not write into.
$script:StateDir = $script:Root

foreach ($d in @($script:Root, $script:CredDir, $script:LogDir)) {
    if ($d -and -not (Test-Path $d)) {
        try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch { }
    }
}

# Credential file names.  The ThuNet-* names are what Set-ThuNetCredential.ps1 writes.  The
# portal-* names are accepted as well so that a set created by an earlier hand-rolled script can
# be pointed at with -CredentialDir without re-entering the password.  Nothing is ever written
# back under the legacy names: this script does not write credentials at all.
function Get-CredentialFile([string]$base) {
    foreach ($n in @("ThuNet-$base", "portal-$base")) {
        $p = Join-Path $script:CredDir $n
        if (Test-Path $p) { return $p }
    }
    return (Join-Path $script:CredDir "ThuNet-$base")
}

# The ac_id cache gets the same name aliasing as the credential files, and this is not cosmetic:
# without it, pointing -CredentialDir at a directory whose cache is still called portal-acid.txt
# silently DROPS the learned value and falls back to whatever the interception happens to reveal
# first - which is the server's default 1, the exact value that earns E2808 on a port whose
# controller is 173.  The write target prefers whichever file already exists so that a legacy
# directory keeps working across runs instead of accumulating a second cache.
#
# WHERE THE CACHE LIVES: $script:StateDir, which defaults to the install root and NOT to the
# credential directory.  The cache is machine-local state, and a credential directory is allowed to
# be somewhere read-only (a shared or legacy location that this script must not write into).  When
# -CredentialDir is given, an existing cache there is still READ first, so a directory that has
# been in use keeps working; the newly learned value is written to the state directory.
function Resolve-AcidFile([string]$Dir, [switch]$ForWrite) {
    if (-not $Dir) { return $null }
    $canonical = Join-Path $Dir 'ThuNet-ac_id.txt'
    $legacy    = Join-Path $Dir 'portal-acid.txt'
    if ($ForWrite) {
        if (Test-Path $legacy) { return $legacy }
        return $canonical
    }
    foreach ($p in @($canonical, $legacy)) { if (Test-Path $p) { return $p } }
    return $null
}

$script:UserFile = Get-CredentialFile 'user.txt'
$script:PassFile = Get-CredentialFile 'pass.dpapi'

$script:AcidReadFiles = @()
# 1. An explicit -CredentialDir, then 2. the default credential directory, then 3. the state
# directory.  Reading all of them costs one file test each and means a learned value is honoured
# wherever it happens to be.
foreach ($d in @($script:CredDir, (Join-Path $script:Root 'creds'), $script:StateDir)) {
    $p = Resolve-AcidFile $d
    if ($p -and ($script:AcidReadFiles -notcontains $p)) { $script:AcidReadFiles += $p }
}
$script:AcidWriteFile = Resolve-AcidFile $script:CredDir -ForWrite
if (-not $script:AcidWriteFile) { $script:AcidWriteFile = Join-Path $script:StateDir 'ThuNet-ac_id.txt' }
$script:LogFile  = Join-Path $script:LogDir  'thunet-login.log'

$script:PortalHost = 'login.tsinghua.edu.cn'
$script:AuthHost   = 'auth4.tsinghua.edu.cn'

# Two console writers, and the difference matters.
#
#   Write-Out   always writes.  Use it for anything the user asked to see: -Status, -SelfTest and
#               the result of a single -Once run.  A read-only diagnostic that prints nothing is
#               indistinguishable from a script that failed to run.
#   Write-Line  writes unless -Watch has taken the console over.  The watcher logs its state to the
#               log file every time that state CHANGES, and echoing each change to a console that
#               nothing is reading (the scheduled task runs it through a hidden launcher) just
#               grows the captured output; when the same script is run by hand the echo is wanted.
#
# These were one function with a flag in the first draft, and the read-only branches set the flag
# the wrong way - so -Status printed absolutely nothing.  Two functions make that class of mistake
# impossible: there is no flag to get backwards.
function Write-Out([string]$msg) { Write-Host $msg }
function Write-Line([string]$msg) {
    if (-not $script:WatchQuiet) { Write-Host $msg }
}

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
        $fi = Get-Item $script:LogFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 256KB) {
            $keep = Get-Content $script:LogFile -Tail 300
            Set-Content -Path $script:LogFile -Value $keep -Encoding UTF8
        }
    } catch { }
}

# TLS 1.1/1.2 explicitly: PowerShell 5.1 on an unpatched .NET defaults to SSL3/TLS1.0, which the
# portal refuses.  The certificate callback accepts the campus chain, which is not in the machine
# store on a freshly installed box; the traffic carries no secret beyond the account itself, and
# the request is what the vendor's own client sends.
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::DefaultConnectionLimit = 8

# ---------------------------------------------------------------- which local address to bind to
# The portal request has to leave through the wired NIC.  get_challenge echoes back the address
# the server saw, and the login authenticates exactly that address - so a request that went out
# over the WiFi fallback would re-authenticate the WiFi address and leave the wired link blocked,
# while every connectivity probe would still report "online" because the WiFi path works.  Binding
# the source address is what makes the check and the login actually mean the wired link.
$script:Candidates  = @()
$script:LastAttempt = @{}
function Get-WiredAddress {
    # Build the candidate list from .NET instead of from `netsh`.
    #
    # EVIDENCE: the original single-shot run started from an interactive shell parsed both adapters
    # fine, and every watcher started since - launched windowless with Start-Process -WindowStyle
    # Hidden - logged "no usable interface address - nothing to do".  The only difference between
    # those runs is the console, and netsh picks its output language from it: an interactive shell
    # gets the English "Configuration for interface ..." / "IP Address:" lines, a process without a
    # console gets the localized ones, so English regexes match nothing and the watcher does
    # nothing at all.  NetworkInterface returns the same data in every locale and needs no parsing.
    # This is why the uninstaller/scheduled-task path must never reintroduce netsh.
    $cands = @()
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        $t = $n.NetworkInterfaceType
        if ($t -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        if ($t -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) { continue }
        if ($n.Name -match 'Tailscale|vEthernet|WSL|Bluetooth') { continue }
        $ip4 = $null
        foreach ($u in $n.GetIPProperties().UnicastAddresses) {
            if ($u.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $s = $u.Address.IPAddressToString
            if ($s -match '^169\.254\.') { continue }
            $ip4 = $s
            break
        }
        if (-not $ip4) { continue }
        $prio = 1
        if ($t -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ethernet) { $prio = 0 }
        $cands += [pscustomobject]@{ Name = $n.Name; IP = $ip4; Priority = $prio }
    }
    $cands = @($cands | Sort-Object Priority)
    $script:Candidates = $cands
    if ($cands.Count -gt 0) { $script:BindIp = $cands[0].IP; return $cands[0].IP }
    Write-Log 'no usable interface address - nothing to do (dotnet enumeration found nothing)'
    return $null
}

function Set-BindDelegate([System.Net.WebRequest]$req) {
    if (-not $script:BindIp) { return }
    try {
        $req.ServicePoint.BindIPEndPointDelegate = [System.Net.BindIPEndPoint]{
            param([System.Net.ServicePoint]$sp, [System.Net.IPEndPoint]$remote, [int]$retry)
            # The framework keeps calling this delegate for as long as it returns an endpoint; only
            # a $null return tells it to give up.  Returning an endpoint unconditionally turned
            # every FAILED connection into a busy retry loop that pins one core - which is why
            # -Status hung: its discovery probe to http://4.5.6.7 cannot answer once the port is
            # authenticated.  Fail after a couple of tries so the request errors normally.
            if ($retry -ge 2) { return $null }
            return (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($script:BindIp), 0))
        }
    } catch { }
}

# ---------------------------------------------------------------- HTTP, proxy bypassed on purpose
# The campus portal is reached over the local link.  Sending it through a local HTTP proxy (a
# VPN/clash-style client on 127.0.0.1:7890 is the common case) would be wrong, and would break
# exactly when the proxy client is what is missing - which it is right after a boot.  So every
# request in this file sets $req.Proxy = $null.
function Invoke-Plain([string]$url) {
    $req = [System.Net.WebRequest]::Create($url)
    $req.Proxy = $null
    $req.Timeout = 15000
    $req.Method = 'GET'
    $req.UserAgent = 'Mozilla/5.0'
    Set-BindDelegate $req
    $resp = $req.GetResponse()
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd()
    $sr.Close(); $resp.Close()
    return $txt
}

# ---------------------------------------------------------------- srun SRBX1 encoder
function URShift([uint32]$x, [int]$n) { return [uint32](([uint64]$x -shr $n) % 4294967296) }
function ULShift([uint32]$x, [int]$n) { return [uint32]((([uint64]$x -shl $n)) % 4294967296) }

function Invoke-XEncode {
    param([byte[]]$Msg, [byte[]]$Key)

    function Pack-Words([byte[]]$a, [bool]$appendLen) {
        $c = $a.Length
        $v = New-Object 'System.Collections.Generic.List[uint32]'
        for ($i = 0; $i -lt $c; $i += 4) {
            $w = [uint32]0
            for ($j = 0; $j -lt 4; $j++) {
                if (($i + $j) -lt $c) {
                    $w = [uint32](($w -bor (ULShift ([uint32]$a[$i + $j]) (8 * $j))) % 4294967296)
                }
            }
            [void]$v.Add($w)
        }
        if ($appendLen) { [void]$v.Add([uint32]$c) }
        return ,$v.ToArray()
    }

    $v = Pack-Words $Msg $true
    $k = Pack-Words $Key $false
    if ($k.Length -lt 4) {
        $t = New-Object 'System.Collections.Generic.List[uint32]'
        $t.AddRange($k)
        while ($t.Count -lt 4) { $t.Add([uint32]0) }
        $k = $t.ToArray()
    }

    $n = $v.Length - 1
    if ($n -lt 1) { return ,([byte[]]@()) }
    $z = $v[$n]
    $c = [uint32]2654435769            # delta, written in decimal because PowerShell reads 0xFFFFFFFF as -1
    $q = 6 + [int][math]::Floor(52 / ($n + 1))
    $d = [uint32]0
    while ($q -gt 0) {
        $q--
        $d = [uint32](($d + $c) % 4294967296)
        $e = (URShift $d 2) -band 3
        for ($p = 0; $p -lt $n; $p++) {
            $y = $v[$p + 1]
            $m = (URShift $z 5) -bxor (ULShift $y 2)
            $m = [uint32](([uint64]$m + ((URShift $y 3) -bxor (ULShift $z 4) -bxor ($d -bxor $y))) % 4294967296)
            $m = [uint32](([uint64]$m + (($k[($p -band 3) -bxor $e]) -bxor $z)) % 4294967296)
            $z = [uint32](([uint64]$v[$p] + $m) % 4294967296)
            $v[$p] = $z
        }
        $p = $n
        $y = $v[0]
        $m = (URShift $z 5) -bxor (ULShift $y 2)
        $m = [uint32](([uint64]$m + ((URShift $y 3) -bxor (ULShift $z 4) -bxor ($d -bxor $y))) % 4294967296)
        $m = [uint32](([uint64]$m + (($k[($p -band 3) -bxor $e]) -bxor $z)) % 4294967296)
        $z = [uint32](([uint64]$v[$n] + $m) % 4294967296)
        $v[$n] = $z
    }

    $out = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($w in $v) {
        [void]$out.Add([byte]($w -band 0xFF))
        [void]$out.Add([byte]((URShift $w 8) -band 0xFF))
        [void]$out.Add([byte]((URShift $w 16) -band 0xFF))
        [void]$out.Add([byte]((URShift $w 24) -band 0xFF))
    }
    return ,$out.ToArray()
}

function ConvertTo-WeirdBase64([byte[]]$b) {
    $std  = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    $srun = 'LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA'
    $s = [Convert]::ToBase64String($b)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $i = $std.IndexOf($ch)
        if ($i -ge 0) { [void]$sb.Append($srun[$i]) } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Get-Hex([byte[]]$b) { return (($b | ForEach-Object { '{0:x2}' -f $_ }) -join '') }

function ConvertTo-JsonLiteral([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '\\', '\\\\' -replace '"', '\"')
}

# ---------------------------------------------------------------- credentials (read-only)
function Test-CredentialPresent {
    return ((Test-Path $script:UserFile) -and (Test-Path $script:PassFile))
}

function Get-StoredUser {
    if (-not (Test-Path $script:UserFile)) { return $null }
    try { return (Get-Content $script:UserFile -Raw).Trim() } catch { return $null }
}

function Get-StoredCredential {
    if (-not (Test-CredentialPresent)) { return $null }
    $u = Get-StoredUser
    try {
        $enc = (Get-Content $script:PassFile -Raw).Trim()
        $sec = ConvertTo-SecureString $enc
        $p = (New-Object System.Net.NetworkCredential('', $sec)).Password
        if (-not $u -or -not $p) { return $null }
        return New-Object psobject -Property @{ User = $u; Pass = $p }
    } catch {
        # A DPAPI blob is bound to the Windows user, and in CurrentUser scope to the machine too.
        # Copying it to another computer, or to another account on this one, always lands here.
        Write-Log ('stored password could not be decrypted: ' + $_.Exception.Message)
        return $null
    }
}

# The message a user without credentials must see.  It is deliberately specific: the fix is a
# different script in this repository, not a flag on this one, because this one never writes.
function Write-NoCredentialHint {
    $m = 'no credential found in ' + $script:CredDir + ' - run Set-ThuNetCredential.ps1 to create one'
    Write-Log $m
    Write-Out $m
}

# ---------------------------------------------------------------- portal
# A captive portal intercepts "generate_204" and answers 200 with its own HTML page.  Accepting a
# bare 200 as "online" makes a blocked link look healthy, so the caller concludes "authenticated"
# and the login never fires - the whole auto-auth becomes a no-op.  The probe has to be strict:
# the code AND the body have to be what the endpoint promises.
function Test-LinkOnline {
    $probes = @(
        @{ Url = 'http://connect.rom.miui.com/generate_204';        Code = 204; Body = $null;                   Match = $null },
        @{ Url = 'http://www.msftconnecttest.com/connecttest.txt';  Code = 200; Body = 'Microsoft Connect Test'; Match = $null },
        @{ Url = 'http://www.baidu.com';                            Code = 200; Body = $null;                   Match = 'baidu' }
    )
    foreach ($p in $probes) {
        try {
            $req = [System.Net.WebRequest]::Create($p.Url)
            $req.Proxy = $null
            $req.Timeout = 8000
            Set-BindDelegate $req
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd()
            $sr.Close(); $resp.Close()
            if ($code -ne $p.Code) { continue }
            if ($p.Body -and $body.Trim() -ne $p.Body) { continue }
            if ($p.Match -and $body -notmatch $p.Match) { continue }
            return $true
        } catch { }
    }
    return $false
}

function Get-AcIdDiscovered {
    # Read the wall port's access-controller id out of the interception itself.  While the port is
    # blocked, any plain HTTP request is answered or redirected by the portal and the redirect
    # chain ends on .../srun_portal_pc?ac_id=<port>&theme=pro - so the FINAL response URI is the
    # most reliable place to look, then the Location header, then the body.
    #
    # History: this used to request srun_portal_pc?theme=pro with no ac_id at all, so the server
    # echoed its own default back as CONFIG.acid and the answer was always 1 - a circular reading
    # of a value we had supplied ourselves.  Sending 1 is exactly what produced E2808 "Control
    # policy not found" on a port whose controller is 173.
    $weak = $null
    $weakFrom = ''
    foreach ($u in @('http://4.5.6.7', 'http://connect.rom.miui.com/generate_204', 'http://www.baidu.com', 'http://auth4.tsinghua.edu.cn/')) {
        $final = ''; $loc = ''; $body = ''
        try {
            $req = [System.Net.WebRequest]::Create($u)
            $req.Proxy = $null
            $req.Timeout = 8000
            $req.AllowAutoRedirect = $true
            $req.UserAgent = 'Mozilla/5.0'
            Set-BindDelegate $req
            $resp = $req.GetResponse()
            $final = $resp.ResponseUri.AbsoluteUri
            $loc = [string]$resp.Headers['Location']
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd()
            $sr.Close(); $resp.Close()
        } catch { continue }
        $pairs = @(@('final-url', $final), @('location', $loc), @('body', $body))
        $fromInterception = ($u -notmatch 'auth4\.tsinghua\.edu\.cn')
        foreach ($pair in $pairs) {
            $src = $pair[1]
            if (-not $src) { continue }
            # Both strong patterns are restricted to an INTERCEPTED request.  The portal's own page
            # is excluded from both: asked directly it redirects to index_1.html and echoes
            # ac_id=1, which are the server's defaults, not this port's controller - that is the
            # trap that made the script try 1 first and earn E2808.
            if ($fromInterception) {
                # The interception points at the portal index belonging to THIS port, e.g.
                #     location.href="http://auth4.tsinghua.edu.cn/index_173.html"
                # That number IS the ac_id - exactly what a browser uses to choose its login page.
                $m = [regex]::Match($src, 'index_(\d{1,4})\.html')
                if ($m.Success) {
                    Write-Log ("ac_id {0} read from index_*.html in the {1} of {2}" -f $m.Groups[1].Value, $pair[0], $u)
                    return [int]$m.Groups[1].Value
                }
                $m2 = [regex]::Match($src, 'srun_portal_pc[^0-9]{0,8}ac_id[^0-9]{0,4}(\d{1,4})')
                if ($m2.Success) {
                    Write-Log ("ac_id {0} taken from the {1} of {2}" -f $m2.Groups[1].Value, $pair[0], $u)
                    return [int]$m2.Groups[1].Value
                }
            }
            # Weak evidence: a bare ac_id=... anywhere.  Kept only as a last resort.
            if (-not $weak) {
                $wm = [regex]::Match($src, 'ac_id=(\d{1,4})')
                if ($wm.Success) { $weak = [int]$wm.Groups[1].Value; $weakFrom = '{0} of {1}' -f $pair[0], $u }
            }
        }
    }
    if ($weak) {
        Write-Log ("ac_id {0} taken from the {1} - weak evidence, it may be the server default" -f $weak, $weakFrom)
        return $weak
    }
    Write-Log 'ac_id is not exposed by the interception'
    return $null
}

function Get-AcIdFromBrowserHistory {
    # The ac_id belongs to the wall port, so it changes with the environment - but the portal URL
    # the browser is sent to carries it, and browsers keep that URL in their history.  So the first
    # time the portal appears in a browser at the new port, the right value is already on disk and
    # can be learned without asking anyone.
    # History is a SQLite file, but only the URL strings are needed, so a raw byte scan is enough.
    # This is best-effort: no browser installed means no candidates from here, not an error.
    $found = New-Object 'System.Collections.Generic.List[int]'
    $paths = @()
    foreach ($rel in @(
            'Microsoft\Edge\User Data\Default\History',
            'Microsoft\Edge\User Data\Profile 1\History',
            'Google\Chrome\User Data\Default\History',
            'Google\Chrome\User Data\Profile 1\History')) {
        $p = Join-Path $env:LOCALAPPDATA $rel
        if (Test-Path $p) { $paths += $p }
    }
    foreach ($p in $paths) {
        try {
            # History is an open SQLite database, so ReadAllBytes throws "being used by another
            # process".  Opening it with FileShare.ReadWrite is allowed and is enough for a scan.
            $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $ms = New-Object System.IO.MemoryStream
            $fs.CopyTo($ms)
            $fs.Close()
            $txt = [System.Text.Encoding]::GetEncoding(28591).GetString($ms.ToArray())
            $ms.Dispose()
        } catch { continue }
        foreach ($m in [regex]::Matches($txt, 'srun_portal_pc[^0-9]{0,8}ac_id[^0-9]{0,4}(\d{1,4})')) {
            $v = [int]$m.Groups[1].Value
            if ($v -gt 0 -and -not $found.Contains($v)) { [void]$found.Add($v) }
        }
        foreach ($m in [regex]::Matches($txt, 'index_(\d{1,4})\.html')) {
            $v = [int]$m.Groups[1].Value
            if ($v -gt 0 -and -not $found.Contains($v)) { [void]$found.Add($v) }
        }
    }
    if ($found.Count -gt 0) {
        Write-Log ("ac_id values found in browser history: " + (($found | ForEach-Object { $_.ToString() }) -join ', '))
    }
    return ,$found.ToArray()
}

# Ordered candidates.  Trying a wrong one only earns E2808 and costs one request, so the order is
# simply "most likely first":
#   1. whatever worked last (the cache file in the credential directory)
#   2. what the interception reveals right now
#   3. every ac_id a browser has ever been sent to (this is what makes a new wall port work)
#   4. two hard fallbacks
# The last group is a fallback and NOT a configuration: ac_id belongs to the access controller the
# wall port is wired to, so it differs per building and per port.  173 is the value measured at the
# port this tool was developed on; it is written here only so that a first run behind an
# interception that reveals nothing still has something to try.  Never treat it as "the" value.
function Get-AcIdCandidates {
    $list = New-Object 'System.Collections.Generic.List[int]'
    $from = ''
    foreach ($f in $script:AcidReadFiles) {
        if (-not (Test-Path $f)) { continue }
        $c = (Get-Content $f -Raw -ErrorAction SilentlyContinue)
        if ($c) { $c = $c.Trim() }
        if ($c -match '^\d+$' -and -not $list.Contains([int]$c)) {
            [void]$list.Add([int]$c)
            if (-not $from) { $from = $f }
        }
    }
    if ($from) { Write-Log ('ac_id {0} taken from the cache ' -f $list[0] + $from) }
    $d = Get-AcIdDiscovered
    if ($d -and -not $list.Contains([int]$d)) { [void]$list.Add([int]$d) }
    foreach ($h in (Get-AcIdFromBrowserHistory)) { if (-not $list.Contains([int]$h)) { [void]$list.Add([int]$h) } }
    foreach ($v in @(173, 1)) { if (-not $list.Contains($v)) { [void]$list.Add($v) } }
    return ,$list.ToArray()
}

function Get-AcId {
    $c = Get-AcIdCandidates
    if ($c.Count -gt 0) { return $c[0] }
    return 173
}

function Get-Challenge([string]$user) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $url = "https://$($script:AuthHost)/cgi-bin/get_challenge?callback=callback&username=$([uri]::EscapeDataString($user))&ip=&double_stack=0&_=$ts"
    $txt = Invoke-Plain $url
    $s = $txt.IndexOf('(')
    $e = $txt.LastIndexOf(')')
    if ($s -lt 0 -or $e -le $s) { throw "get_challenge returned something unexpected: $txt" }
    return ($txt.Substring($s + 1, $e - $s - 1) | ConvertFrom-Json)
}

# One login attempt against one specific access controller id.
function Invoke-PortalLoginWith([int]$acId) {
    $script:LoginErrorCode = ''
    $cred = Get-StoredCredential
    if (-not $cred) { Write-Log 'no stored credential - run Set-ThuNetCredential.ps1'; return $false }

    $ch = Get-Challenge $cred.User
    $token = $ch.challenge
    if (-not $token) { Write-Log ('no challenge in response: ' + ($ch | ConvertTo-Json -Compress)); return $false }
    $ip = ''
    if ($ch.online_ip) { $ip = $ch.online_ip } elseif ($ch.client_ip) { $ip = $ch.client_ip }

    # hmd5 = HMAC-MD5 with the challenge token as key, over the empty message.
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($token)
    $hmac = New-Object System.Security.Cryptography.HMACMD5
    $hmac.Key = $keyBytes
    $hmd5 = Get-Hex ($hmac.ComputeHash([byte[]]@()))

    # The info field is a JSON object that is SRBX1-encoded, and the encoder output was validated
    # byte-for-byte against the Python reference, so its serialization has to match Python's
    # json.dumps defaults exactly - including the spaces after ":" and ", " and the field order.
    #
    # Do NOT build this with the -f operator: the JSON is full of literal braces, which -f reads as
    # format items ("Input string was not in a correct format"), so $infoJson came out empty and
    # the portal answered auth_info_error.  Concatenation avoids the whole class of bug.
    $infoJson = '{"username": "' + (ConvertTo-JsonLiteral $cred.User) + '", "password": "' + (ConvertTo-JsonLiteral $cred.Pass) + '", "ip": "' + $ip + '", "acid": ' + $acId + ', "enc_ver": "srun_bx1"}'
    $enc = Invoke-XEncode -Msg ([System.Text.Encoding]::UTF8.GetBytes($infoJson)) -Key $keyBytes
    $info = '{SRBX1}' + (ConvertTo-WeirdBase64 $enc)

    # The portal page also sends os and name (from its user-agent sniffing) and sets double_stack to
    # 0 unless IPv6 double-stack auth is enabled.  Leaving os empty makes the server answer E2808
    # "Control policy not found": the access policy is chosen per operating system, so an empty os
    # has no policy to find.  None of these three fields is part of chksum, so adding them cannot
    # break the signature.
    $osName  = 'Windows'
    $devName = 'Windows'
    $n = 200
    $typ = 1
    # chksum = sha1(token+username+token+hmd5+token+ac_id+token+ip+token+n+token+type+token+info),
    # all parts joined by the literal string "token" is wrong - the actual key is the VALUE of the
    # challenge token used as a separator, which is what the concatenation below does.
    $chkstr = $token + $cred.User + $token + $hmd5 + $token + "$acId" + $token + $ip + $token + "$n" + $token + "$typ" + $token + $info
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $chksum = Get-Hex ($sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($chkstr)))

    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $q = @(
        'callback=callback'
        ('action=login')
        ('username=' + [uri]::EscapeDataString($cred.User))
        ('password=' + [uri]::EscapeDataString('{MD5}' + $hmd5))
        ('ac_id=' + $acId)
        ('ip=' + [uri]::EscapeDataString($ip))
        ('os=' + [uri]::EscapeDataString($osName))
        ('name=' + [uri]::EscapeDataString($devName))
        ('double_stack=0')
        ('info=' + [uri]::EscapeDataString($info))
        ('chksum=' + $chksum)
        ('n=' + $n)
        ('type=' + $typ)
        ('_=' + $ts)
    ) -join '&'
    $url = "https://$($script:AuthHost)/cgi-bin/srun_portal?$q"

    $txt = Invoke-Plain $url
    if ($script:ShowRaw) { Write-Out ('raw response: ' + $txt) }
    $s = $txt.IndexOf('(')
    $e = $txt.LastIndexOf(')')
    if ($s -lt 0 -or $e -le $s) { Write-Log ('login response unparsable: ' + $txt); return $false }
    $res = $txt.Substring($s + 1, $e - $s - 1) | ConvertFrom-Json
    if ($res.error -eq 'ok') {
        Write-Log ("login ok: user={0} ac_id={1} ip={2} res={3} msg={4}" -f $cred.User, $acId, $ip, $res.res, $res.suc_msg)
        return $true
    }
    Write-Log ('login failed: ' + ($res | ConvertTo-Json -Compress))
    $script:LoginErrorCode = [string]$res.ecode
    return $false
}

# The ac_id belongs to the wall port, so try the candidates in turn: E2808 means "there is no
# access policy for this controller id", which a different candidate may well satisfy.  Whichever
# works gets cached, and that is what makes a second wall port work without editing anything.
# Any other error (bad credentials, no response) is not something another ac_id fixes.
#
# A NOTE ON SUCCESS SEMANTICS, because this is the single easiest thing to misread:
# the success verdict here is the server answering with error == "ok" and msg == "login_ok".
# The server can also answer msg == "ip_already_online_error".  That message means the address was
# ALREADY authenticated before this request - it does NOT mean this request logged anybody in.  It
# is not treated as success here; a caller that wants to accept it must check the link state
# afterwards with a real connectivity probe.  Treating it as a successful login is how a tool
# reports "logged in" forever while the port is actually blocked.
function Invoke-PortalLogin {
    foreach ($acId in (Get-AcIdCandidates)) {
        if (Invoke-PortalLoginWith $acId) {
            try { ([string]$acId) | Set-Content -Path $script:AcidWriteFile -Encoding ASCII -NoNewline } catch { }
            return $true
        }
        if ($script:LoginErrorCode -ne 'E2808') { return $false }
        Write-Log ("ac_id {0} was rejected with E2808 - trying the next candidate" -f $acId)
    }
    Write-Log 'every ac_id candidate was rejected - this port may need a manual login'
    return $false
}

# Every interface that carries a real address gets its own verdict and its own login, because a
# candidate can be fine while another is blocked (WiFi up, wall port still waiting for the portal).
# A candidate that keeps failing is retried at most once every five minutes: a permanently dead
# wall port must not turn into a login request every single minute.
function Repair-Once {
    if (-not $script:Candidates -or $script:Candidates.Count -eq 0) { [void](Get-WiredAddress) }
    if (-not $script:Candidates -or $script:Candidates.Count -eq 0) { return 'no usable interface address - nothing to do' }

    $notes = @()
    $blocked = @()
    foreach ($c in $script:Candidates) {
        $script:BindIp = $c.IP
        if (Test-LinkOnline) { $notes += ('{0}={1}:online' -f $c.Name, $c.IP); continue }

        if (-not (Test-CredentialPresent)) { return 'no credential - run Set-ThuNetCredential.ps1' }

        $tag = '{0}={1}' -f $c.Name, $c.IP
        $last = $script:LastAttempt[$c.IP]
        if ($last -and ((New-TimeSpan -Start $last -End (Get-Date)).TotalSeconds -lt 300)) {
            $blocked += $tag
            $notes += ($tag + ':blocked-backing-off')
            continue
        }
        $script:LastAttempt[$c.IP] = Get-Date

        $ok = Invoke-PortalLogin
        Start-Sleep -Seconds 3
        if ($ok -and (Test-LinkOnline)) {
            $script:LastAttempt.Remove($c.IP)
            $notes += ($tag + ':logged-in')
        } elseif ($ok) {
            $blocked += $tag
            $notes += ($tag + ':portal-ok-but-still-blocked')
        } else {
            $blocked += $tag
            $notes += ($tag + ':login-failed')
        }
    }
    if ($blocked.Count -eq 0) {
        $fresh = $script:Candidates | ForEach-Object { '{0}={1}' -f $_.Name, $_.IP }
        return ('ok: authenticated on ' + ($fresh -join ', '))
    }
    return ($notes -join ' | ')
}

# ---------------------------------------------------------------- entry points
$script:BindIp = Get-WiredAddress

if ($SelfTest) {
    # Read-only.  Compares the encoder against a vector recorded from the Python reference
    # implementation (github.com/WhymustIhaveaname/TsinghuaTunet, connect.py) so that the check
    # needs no Python, no module and no network - it runs on a bare PowerShell 5.1 box.
    # The vector was produced by that oracle with exactly this token and this info string; if the
    # two outputs below stop matching the constants, the encoder was changed.
    $SelfTestToken = 'ae48995cb0a006baddaff24bb8081df3b905afa6381ad498d6a3674ac2110aaf'
    $SelfTestInfo  = '{"username": "testuser", "password": "testpass", "ip": "59.66.18.167", "acid": 1, "enc_ver": "srun_bx1"}'
    $SelfTestExpectedHex  = '94aca64aba9027ba06b0c67399e92be1950dd5aa0fb88ab65d813481500e70fcead4dbf6dc415a8a7d5393814cfb4d0387a03db7ea3168cdd9408e66be0aea2be19d6d86639f013208379246c9a9a9cb58f12fab891eb5222b9c8a837f0abd1de058146c408eda9247d660e7'
    $SelfTestExpectedInfo = '{SRBX1}p8xUmld+RE/Cb91zUrYlD1H0jO/gK2dIcZPtSuLyMgzdj0wI7PiOXqjFYDi9QttJTBL5fQ/6O971+2eUwSld8QCnWZ1kqvPxoJrmhbU3dMfZ4mQlXhBj2XKMX/0AoltnDiSHWPoyI3RNjUJq'

    $enc  = Invoke-XEncode -Msg ([System.Text.Encoding]::UTF8.GetBytes($SelfTestInfo)) -Key ([System.Text.Encoding]::UTF8.GetBytes($SelfTestToken))
    $mine = '{SRBX1}' + (ConvertTo-WeirdBase64 $enc)
    $hex  = Get-Hex $enc

    $ok = ($hex -eq $SelfTestExpectedHex) -and ($mine -eq $SelfTestExpectedInfo)
    Write-Out ('credential dir : ' + $script:CredDir)
    Write-Out ('credential set : ' + $(if (Test-CredentialPresent) { 'present (account file + DPAPI password file)' } else { 'NOT set (run Set-ThuNetCredential.ps1)' }))
    Write-Out ('wired address  : ' + $(if ($script:BindIp) { $script:BindIp } else { '(none found)' }))
    Write-Out ('ac_id          : ' + (Get-AcId))
    Write-Out ('encoder hex    : ' + $hex)
    Write-Out ('encoder info   : ' + $mine)
    Write-Out ('expected hex   : ' + $SelfTestExpectedHex)
    Write-Out ('expected info  : ' + $SelfTestExpectedInfo)
    if ($ok) { Write-Out 'MATCH: encoder is byte-identical to the reference implementation' }
    else     { Write-Out 'MISMATCH: encoder differs from the reference implementation' }
    return
}

if ($Status) {
    # Read-only: reports stored account and link state, changes nothing, logs nothing to disk.
    if (Test-CredentialPresent) {
        $u = Get-StoredUser
        $sec = $null
        try { $sec = ConvertTo-SecureString ((Get-Content $script:PassFile -Raw).Trim()) } catch { }
        Write-Out ("account: {0}   password: {1}" -f $u, $(if ($sec) { 'stored (DPAPI, decryptable by this user on this machine)' } else { 'stored but NOT decryptable by this user/machine' }))
    } else {
        Write-Out ('account: not set yet (run Set-ThuNetCredential.ps1; looked in ' + $script:CredDir + ')')
    }
    Write-Out ('link   : ' + $(if (Test-LinkOnline) { 'authenticated, direct internet works' } else { 'NOT authenticated / unreachable' }))
    Write-Out ('ac_id  : ' + (Get-AcId))
    Write-Out ('bind   : ' + $(if ($script:BindIp) { $script:BindIp } else { '(none found)' }))
    return
}

if ($TestLogin) {
    $script:ShowRaw = $true
    Write-Out ('wired address  : ' + $script:BindIp)
    $cred = Get-StoredCredential
    if ($cred) { Write-Out ('account        : ' + $cred.User) } else { Write-NoCredentialHint; return }
    $ok = Invoke-PortalLogin
    Write-Out ('login returned : ' + $ok)
    return
}

if (-not $Watch) {
    # -Once is the default action; both spellings do the same single pass.
    if (-not (Test-CredentialPresent)) { Write-NoCredentialHint; return }
    $r = Repair-Once
    Write-Out $r
    Write-Log $r
    return
}

# ---------------------------------------------------------------- watch loop
# A resident watcher only: this is the mode the scheduled task runs.  Console echo is switched off
# here, because the task starts it through the hidden launcher and nothing is reading the console.
# Its state changes still go to the log file - that is where a watcher is actually inspected.
$script:WatchQuiet = $true

# One watcher only.  Two of them would race to log the same port in, and the portal counts failed
# attempts; the scheduled task's MultipleInstances=IgnoreNew covers the task path but not a manual
# start.  The mutex is per-user (Local\), which is all that is needed here and keeps the task from
# needing administrator rights.
$mutex = New-Object System.Threading.Mutex($false, 'Local\ThuNetAutoLoginWatcher')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'another ThuNet watcher is already running - exiting'
    Write-Out 'another ThuNet watcher is already running - exiting'
    return
}

$limitText = 'unlimited'
if ($MaxRuns -gt 0) { $limitText = "$MaxRuns" }
Write-Log ("watcher started (interval {0}s, max runs {1})" -f $IntervalSeconds, $limitText)

# -MaxRuns is the loop's stop condition and 0 means "no limit".  It exists so that the loop can be
# exercised in a test without leaving a process behind, and so that a bounded run (a few attempts
# at a stubborn port, then give up and let the daily trigger try again) is expressible without a
# second script.
$runs = 0
$last = ''
try {
    while ($true) {
        if ($MaxRuns -gt 0 -and $runs -ge $MaxRuns) { break }
        try {
            $state = Repair-Once
            if ($state -ne $last) { Write-Log $state; $last = $state }
            Write-Line $state
        } catch {
            Write-Log ('watcher error: ' + $_.Exception.Message)
        }
        $runs++
        if ($MaxRuns -gt 0 -and $runs -ge $MaxRuns) { break }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    # Releasing the mutex in a finally block matters for a bounded -MaxRuns run: otherwise the
    # process holds it until teardown and a second test run started right afterwards exits as
    # "already running", which looks exactly like a broken loop.
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
Write-Log ("watcher stopped after {0} run(s)" -f $runs)
Write-Out ("watcher stopped after {0} run(s)" -f $runs)

