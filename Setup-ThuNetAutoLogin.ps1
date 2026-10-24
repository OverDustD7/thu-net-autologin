# Setup-ThuNetAutoLogin.ps1 - the one script to run.
#
# Takes a machine from "nothing installed" to "the campus link keeps itself authenticated", in one
# pass, and is safe to run again later: every step checks what is already there before changing it.
#
# WHAT IT DOES, IN ORDER
#   1. credentials  - if the credential files are missing, calls Set-ThuNetCredential.ps1, which
#                     prompts for the account and the password (twice, not echoed).  If they are
#                     already present it says so and moves on; -ForceCredential asks anyway.
#   2. autostart    - registers the logon-triggered scheduled task (plus one daily safety-net
#                     trigger) by calling Install-ThuNetAutoLogin.ps1, which builds the task XML
#                     and hands it to schtasks.  No elevation is needed: the task runs as this
#                     user, with this user's token.
#   3. start now    - starts the watcher immediately, so the link is watched from this moment
#                     rather than from the next logon.
#   4. verify       - re-queries the task, proves the watcher is really running (it holds the
#                     single-instance mutex), and prints the read-only link status.
#
# AUTOSTART IS AT LOGON, NOT AT BOOT - and that is a design consequence, not an omission.  The
# password is encrypted with DPAPI at the CurrentUser scope, so only a task running inside this
# user's own session can decrypt it.  A task that ran before logon, or as SYSTEM, would hold no key
# to the password file and could not log in at all.  On a machine that boots straight into this
# account (Windows automatic logon) the logon trigger fires seconds after boot, which is what
# "starts with the machine" looks like in practice.  True pre-logon operation would require storing
# the password where any process on the machine can read it; that is a worse trade and this script
# will not make it silently.
#
# THIS FILE MUST STAY PURE ASCII - see the header of ThuNet-Login.ps1 for why (PowerShell 5.1 reads
# a BOM-less script as ANSI/cp936 and a non-ASCII literal corrupts the parse).
#
# USAGE
#   Setup-ThuNetAutoLogin.cmd                       double-click wrapper (runs this, then pauses)
#   Setup-ThuNetAutoLogin.ps1                       install or update, keep existing credentials
#   Setup-ThuNetAutoLogin.ps1 -WhatIf               print every action, change nothing
#   Setup-ThuNetAutoLogin.ps1 -ForceCredential      ask for account and password again
#   Setup-ThuNetAutoLogin.ps1 -WithProbe            also install the diagnostic probe
#   Setup-ThuNetAutoLogin.ps1 -IntervalSeconds 30   how often the watcher re-checks the link
#   Setup-ThuNetAutoLogin.ps1 -RunLevel HighestAvailable   full token (run this elevated)

param(
    [switch]$WhatIf,
    [switch]$ForceCredential,
    [switch]$WithProbe,
    [int]$IntervalSeconds = 60,
    [string]$CredentialDir,
    [string]$LogDir,
    [string]$DailyAt = '09:00',
    [ValidateSet('LeastPrivilege','HighestAvailable','Limited','Highest')][string]$RunLevel = 'LeastPrivilege',
    [string]$TaskName = 'ThuNet-Login',
    [string]$ProbeTaskName = 'ThuNet-Probe'
)

$ErrorActionPreference = 'Continue'

$Root         = Split-Path -Parent $MyInvocation.MyCommand.Path
$LoginPs1     = Join-Path $Root 'ThuNet-Login.ps1'
$CredPs1      = Join-Path $Root 'Set-ThuNetCredential.ps1'
$InstallPs1   = Join-Path $Root 'Install-ThuNetAutoLogin.ps1'
$TaskXmlPs1   = Join-Path $Root 'ThuNet-TaskXml.ps1'
$RunHidden    = Join-Path $Root 'RunHidden.vbs'

if (-not $CredentialDir) { $CredentialDir = Join-Path (Join-Path $env:LOCALAPPDATA 'ThuNetAutoLogin') 'creds' }
if (-not $LogDir)        { $LogDir        = Join-Path (Join-Path $env:LOCALAPPDATA 'ThuNetAutoLogin') 'logs' }

function Say([string]$m)  { Write-Host $m }
function Step([string]$m) { Write-Host ''; Write-Host ('== ' + $m) }
function Note([string]$m) { Write-Host ('   ' + $m) }

# Display-only quoting: what the command would look like typed into a prompt.
function Show-Args([string[]]$a) {
    $p = @()
    foreach ($x in $a) { if ($x -match '\s') { $p += ('"' + $x + '"') } else { $p += $x } }
    return ($p -join ' ')
}

# Run a sibling script in its own powershell process.  Deliberately a separate process and not a
# dot-source: the callee's "exit" then ends only itself, its exit code is a real process exit code,
# and its interactive prompts still share this console.  Arguments are splatted, so PowerShell does
# the quoting and paths with spaces survive.
function Invoke-Sibling([string]$Path, [string[]]$ScriptArgs) {
    $head = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path)
    if ($ScriptArgs) { $head += $ScriptArgs }
    if ($WhatIf) {
        Note ('would run: powershell.exe ' + (Show-Args $head))
        return 0
    }
    $out = & powershell.exe @head 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($out)) { Note ([string]$line) }
    return $code
}

# The watcher's own single-instance mutex, taken in a "is it free?" probe.  If the watcher is
# running, WaitOne(0) fails; if it is not, this probe takes it and hands it straight back.
function Test-WatcherRunning {
    $m = New-Object System.Threading.Mutex($false, 'Local\ThuNetAutoLoginWatcher')
    $got = $false
    try { $got = $m.WaitOne(0) } catch { $got = $false }
    if ($got) { try { $m.ReleaseMutex() } catch { } }
    try { $m.Dispose() } catch { }
    return (-not $got)
}

# Credentials may have been created by this repository (ThuNet-*) or by an older hand-rolled
# script (portal-*) in the same directory; both are accepted, as everywhere else in this repo.
function Find-Cred([string]$base) {
    foreach ($n in @("ThuNet-$base", "portal-$base")) {
        $p = Join-Path $CredentialDir $n
        if (Test-Path $p) { return $p }
    }
    return $null
}

# A second tool logging the same port in is not harmless: the portal counts failed attempts, and two
# watchers race each other.  Warn loudly if something that looks like an older installer is present.
function Get-LookalikeTasks {
    $found = @()
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
            if ($t.TaskName -eq $TaskName -or $t.TaskName -eq $ProbeTaskName) { continue }
            if ($t.TaskName -match '(?i)portal|srun|thunet|autologin|netlogin') { $found += $t.TaskName }
        }
    } catch { }
    return $found
}

Say '== ThuNet auto-login setup =='
Say ('repo            : ' + $Root)
Say ('credential dir  : ' + $CredentialDir)
Say ('log dir         : ' + $LogDir)
Say ('task            : ' + $TaskName + '   (watcher interval ' + $IntervalSeconds + 's)')
if ($WhatIf) { Say 'mode            : WhatIf - nothing will be changed' }

# ---------------------------------------------------------------- 0. pre-flight
$missing = @()
foreach ($f in @($LoginPs1, $CredPs1, $InstallPs1, $TaskXmlPs1, $RunHidden)) {
    if (-not (Test-Path $f)) { $missing += $f }
}
if ($missing.Count -gt 0) {
    Say ''
    foreach ($f in $missing) { Say ('ERROR: missing file: ' + $f) }
    Say 'Run this script from the repository directory (it expects its sibling scripts next to it).'
    Say 'Nothing was changed.'
    exit 1
}

$lookalike = Get-LookalikeTasks
if ($lookalike.Count -gt 0) {
    Say ''
    Say ('WARNING: other tasks that look like campus-network logins are already registered: ' + ($lookalike -join ', '))
    Say '         If one of them is still enabled, two logins will race the same port. Check with:'
    Say ('         schtasks /query /tn "' + $lookalike[0] + '"')
}

# ---------------------------------------------------------------- 1. credentials
Step '1/4 credentials'
$hasUser = [bool](Find-Cred 'user.txt')
$hasPass = [bool](Find-Cred 'pass.dpapi')
if (-not $ForceCredential -and $hasUser -and $hasPass) {
    Say '   already set - keeping them (pass -ForceCredential to enter them again)'
} else {
    if ($ForceCredential) { Say '   -ForceCredential given - asked again' }
    else { Say '   not set yet - you will be asked for the account and the password' }
    $credArgs = @('-CredentialDir', $CredentialDir)
    $rc = Invoke-Sibling $CredPs1 $credArgs
    if ($rc -ne 0 -and -not $WhatIf) {
        Say ''
        Say ('Credentials were not stored (exit code ' + $rc + '). The task will still be registered,')
        Say 'but the watcher can do nothing until a credential exists. Re-run this script afterwards.'
    }
}

# ---------------------------------------------------------------- 2. autostart
Step '2/4 register the logon task'
$instArgs = @(
    '-TaskName', $TaskName,
    '-ProbeTaskName', $ProbeTaskName,
    '-IntervalSeconds', "$IntervalSeconds",
    '-DailyAt', $DailyAt,
    '-RunLevel', $RunLevel,
    '-CredentialDir', $CredentialDir,
    '-LogDir', $LogDir,
    '-Force'
)
if ($WithProbe) { $instArgs += '-WithProbe' }
if ($WhatIf)    { $instArgs += '-WhatIf' }
$rcInstall = Invoke-Sibling $InstallPs1 $instArgs
if ($rcInstall -ne 0 -and -not $WhatIf) {
    Say ''
    Say ('Registering the task failed (exit code ' + $rcInstall + '). Nothing further was done.')
    Say 'Those lines are schtasks output. A complaint about access or a permission problem means'
    Say 'this needs an elevated PowerShell. A "value is incorrectly formatted or out of range"'
    Say 'complaint names the element and XML line - that is a bug in this repository, not in what'
    Say 'you did, and the same line tells which value to report.'
    exit 1
}

# ---------------------------------------------------------------- 3. start it now
Step '3/4 start the watcher now'
if ($WhatIf) {
    Say ('   would run: schtasks /run /tn ' + $TaskName)
} else {
    Say ('   schtasks /run /tn ' + $TaskName)
    $null = & schtasks.exe /run /tn $TaskName 2>&1
    $rcRun = $LASTEXITCODE
    if ($rcRun -ne 0) {
        Say ('   schtasks /run exited with ' + $rcRun + ' - the task is registered, so the next logon will start it.')
    } else {
        Say '   start requested'
    }
    Start-Sleep -Seconds 8
}

# ---------------------------------------------------------------- 4. verify
Step '4/4 verify'
if (-not $WhatIf) {
    $q = & schtasks.exe /query /tn $TaskName /fo LIST 2>&1
    foreach ($line in @($q)) {
        $t = ([string]$line).Trim()
        if ($t -match '^(TaskName|Status|Logon Mode|Next Run Time|Task To Run|Repeat: Every|Run As User)') { Say ('   ' + $t) }
    }
}

$running = Test-WatcherRunning
if ($WhatIf) {
    Say '   watcher process : (not checked in WhatIf mode)'
} elseif ($running) {
    Say '   watcher process : running (holds the single-instance mutex)'
} else {
    Say '   watcher process : NOT running'
    Say '                     it may have exited on a missing credential, or the task was just started'
    Say '                     and has not come up yet. Inspect the newest log file listed below.'
}

# Prove the credential actually gets this machine online.  The first version only ran -Status
# (read-only) here, so a run could print "Done" while the machine was still offline - reported
# 2026-10-24: after changing the password nothing connected, and it only came up when -TestLogin was
# run by hand.  Saving a credential is NOT the same as proving it works, and "the watcher is
# running" is not the same either.  The only honest check is a real 204 probe, before and after.
if (-not $WhatIf) {
    Say ''
    Say '   verifying the link (runs a real login if the machine is offline):'
    $probeOnline = $false
    try {
        $probeReq = [System.Net.WebRequest]::Create('http://connect.rom.miui.com/generate_204')
        $probeReq.Proxy = $null
        $probeReq.Timeout = 8000
        $probeResp = $probeReq.GetResponse()
        $probeOnline = ([int]$probeResp.StatusCode -eq 204)
        $probeResp.Close()
    } catch { $probeOnline = $false }

    if ($probeOnline) {
        Say '      already online - no login needed (this means the credential was NOT exercised)'
    } else {
        Say '      OFFLINE - running ThuNet-Login.ps1 -Once'
        $onceArgs = @('-Once', '-CredentialDir', $CredentialDir, '-LogDir', $LogDir)
        $onceOut = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $LoginPs1 @onceArgs 2>&1
        foreach ($line in @($onceOut)) { Say ('      ' + [string]$line) }
        Start-Sleep -Seconds 3
        # Re-probe rather than trusting the login's own verdict: the script reports what the portal
        # answered, and that is not the same as this machine getting out.
        $probeOnline2 = $false
        try {
            $probeReq2 = [System.Net.WebRequest]::Create('http://connect.rom.miui.com/generate_204')
            $probeReq2.Proxy = $null
            $probeReq2.Timeout = 8000
            $probeResp2 = $probeReq2.GetResponse()
            $probeOnline2 = ([int]$probeResp2.StatusCode -eq 204)
            $probeResp2.Close()
        } catch { $probeOnline2 = $false }
        if ($probeOnline2) {
            Say '      now online - the stored credential works'
        } else {
            Say '      STILL OFFLINE - treat this as a FAILURE of this run:'
            Say '        * the password is probably wrong (note: the srun portal password is NOT the'
            Say '          Tsinghua-secure WiFi password), or'
            Say '        * this wall port needs one manual browser login first.'
            Say '      Re-run this script with the correct password, or check the log below.'
        }
    }
}

$statusArgs = @('-Status', '-CredentialDir', $CredentialDir, '-LogDir', $LogDir)
Say '   link status (read-only):'
$statusOut = @()
if ($WhatIf) {
    Say ('      would run: powershell.exe ' + (Show-Args (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LoginPs1) + $statusArgs)))
} else {
    $statusOut = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $LoginPs1 @statusArgs 2>&1
    foreach ($line in @($statusOut)) { Say ('      ' + [string]$line) }
}

$logFile = $null
try {
    $logFile = Get-ChildItem $LogDir -Filter *.log -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
} catch { }

Say ''
Say '== summary =='
Say ('autostart       : at logon (plus a daily trigger at ' + $DailyAt + ' to cover a resume from sleep)')
Say ('task            : ' + $TaskName + '   [schtasks /query /tn "' + $TaskName + '"]')
if ($logFile) { Say ('newest log      : ' + $logFile.FullName) } else { Say ('log dir         : ' + $LogDir) }
Say ('start / stop    : schtasks /run /tn "' + $TaskName + '"   |   schtasks /end /tn "' + $TaskName + '"')
Say ('remove          : .\Uninstall-ThuNetAutoLogin.ps1     (use -WithProbe to remove the probe too;')
Say ('                  credentials and logs are NOT touched - drop them with Set-ThuNetCredential.ps1 -Remove)')
Say ('other machine   : the DPAPI password is per Windows user AND per machine - run this script there too')
if ($WhatIf) {
    Say ''
    Say 'WhatIf: nothing on this machine was changed.'
} else {
    Say ''
    if ($running) {
        Say 'Done: the link is now watched continuously and the watcher will start again at every logon.'
    } else {
        Say 'Registered, but the watcher does not appear to be running - read the log file above.'
    }
}
