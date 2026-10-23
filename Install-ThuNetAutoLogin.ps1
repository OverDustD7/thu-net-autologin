# Install-ThuNetAutoLogin.ps1 - register "run at logon" scheduled tasks for ThuNet-Login.ps1.
#
# WHAT IT CREATES
#   ThuNet-Login   one task that starts the login WATCHER at logon (and daily as a safety net).
#                  The watcher is itself the thing that notices a dropped link, so a second
#                  periodic task would only duplicate work.
#   ThuNet-Probe   optional (-WithProbe): a separate portal PROBE, for collecting evidence when
#                  the login script does not behave the way it should.
#
# HOW IT REGISTERS THEM
#   schtasks /create /xml, not Register-ScheduledTask.  The cmdlet's failures are NON-TERMINATING
#   errors, so a try/catch around it never fires and an installer can print "installed" while
#   nothing was created.  schtasks is an external program: its result is a real process exit code,
#   so every call here is followed by a check of $LASTEXITCODE and the output is captured.
#
#   The task is registered with the CURRENT USER's token (LogonType InteractiveToken), which is the
#   only way the DPAPI-encrypted password can be decrypted at run time.  Because of that this script
#   does NOT need to run elevated for a normal per-user task - pass -RunLevel HighestAvailable and run it
#   from an elevated prompt only if you specifically want the task to have the full token.
#
# THE ACTION IS ALWAYS wscript.exe -> RunHidden.vbs -> powershell.exe.  Never a bare powershell.exe
# action: that creates a console window, and a hidden one still flashes on the desktop.
#
# THIS FILE MUST STAY PURE ASCII - see the header of ThuNet-Login.ps1 for why.
#
# USAGE
#   Install-ThuNetAutoLogin.ps1                    register the login watcher task
#   Install-ThuNetAutoLogin.ps1 -WithProbe         register the watcher and the probe
#   Install-ThuNetAutoLogin.ps1 -WhatIf            print what would be registered, change nothing
#   Install-ThuNetAutoLogin.ps1 -Force             replace an existing task without asking
#   Install-ThuNetAutoLogin.ps1 -IntervalSeconds 30
#   Install-ThuNetAutoLogin.ps1 -CredentialDir <path> -LogDir <path>
#   Install-ThuNetAutoLogin.ps1 -RunLevel HighestAvailable  (run this from an elevated prompt)

param(
    [string]$TaskName = 'ThuNet-Login',
    [string]$ProbeTaskName = 'ThuNet-Probe',
    [int]$IntervalSeconds = 60,
    [switch]$WithProbe,
    [switch]$WhatIf,
    [switch]$Force,
    [ValidateSet('LeastPrivilege','HighestAvailable','Limited','Highest')][string]$RunLevel = 'LeastPrivilege',
    [string]$CredentialDir,
    [string]$LogDir,
    # The time of the daily safety-net trigger.  A logon trigger does not fire on resume from
    # sleep, and a resume is one of the events that drops the authentication.
    [string]$DailyAt = '09:00',
    [string]$UserId
)

$ErrorActionPreference = 'Continue'

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$LoginPs1   = Join-Path $Root 'ThuNet-Login.ps1'
$ProbePs1   = Join-Path $Root 'ThuNet-Probe.ps1'
$TaskXmlPs1 = Join-Path $Root 'ThuNet-TaskXml.ps1'
$RunHidden  = Join-Path $Root 'RunHidden.vbs'

Write-Host '== ThuNet auto-login installer =='
Write-Host ('repo            : ' + $Root)

# ---------------------------------------------------------------- pre-flight
# Every check below has to pass before anything is registered.  A half-installed task that points
# at a script which does not exist is worse than no task: it fails silently at every logon.
$problems = @()
foreach ($f in @($LoginPs1, $TaskXmlPs1, $RunHidden)) {
    if (-not (Test-Path $f)) { $problems += ('missing file: ' + $f) }
}
if ($WithProbe -and -not (Test-Path $ProbePs1)) { $problems += ('missing file: ' + $ProbePs1) }
if (-not $UserId) { $UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host ('ERROR: ' + $p) }
    Write-Host 'Nothing was registered.'
    exit 1
}

# The credential check is a warning and not a hard failure: installing the task before entering the
# password is a legitimate order of operations, as long as the user knows the task will do nothing
# useful until they run the setup script.  It is deliberately loud.
$credDirResolved = $CredentialDir
if (-not $credDirResolved) { $credDirResolved = Join-Path (Join-Path $env:LOCALAPPDATA 'ThuNetAutoLogin') 'creds' }
$hasUser = $false; $hasPass = $false
foreach ($n in @('ThuNet-user.txt','portal-user.txt')) { if (Test-Path (Join-Path $credDirResolved $n)) { $hasUser = $true } }
foreach ($n in @('ThuNet-pass.dpapi','portal-pass.dpapi')) { if (Test-Path (Join-Path $credDirResolved $n)) { $hasPass = $true } }
if ($hasUser -and $hasPass) {
    Write-Host ('credential      : present in ' + $credDirResolved)
} else {
    Write-Host ('credential      : NOT set in ' + $credDirResolved)
    Write-Host '                  the task will be registered anyway, but the watcher can only report'
    Write-Host '                  "no credential" until you run Set-ThuNetCredential.ps1.'
}

Write-Host ('run as user     : ' + $UserId)
Write-Host ('run level       : ' + $RunLevel)
Write-Host ('daily trigger   : ' + $DailyAt)
Write-Host ''

# ThuNet-TaskXml.ps1 is dot-sourced: it only defines New-ThuNetTaskXml, it has no side effects.
. $TaskXmlPs1

# ---------------------------------------------------------------- task definitions
# Arguments handed to the script through the scheduled task.  They are built as one string and end
# up inside a single XML attribute, so anything with a space has to be quoted.
function Get-ScriptArgs {
    param([string]$Extra)
    $a = ''
    if ($CredentialDir) { $a += ' -CredentialDir "' + $CredentialDir + '"' }
    if ($LogDir)        { $a += ' -LogDir "' + $LogDir + '"' }
    if ($Extra)         { $a += ' ' + $Extra }
    return $a.Trim()
}

$loginArgs = Get-ScriptArgs ('-Watch -IntervalSeconds ' + $IntervalSeconds)
$loginDesc = 'ThuNet: keep the Tsinghua srun portal authenticated on this machine. Starts the login watcher at logon and daily as a safety net. Installed from ' + $Root

$xmlLogin = New-ThuNetTaskXml -TaskName $TaskName -Description $loginDesc -ScriptPath $LoginPs1 `
    -ScriptArgs $loginArgs -RunHiddenPath $RunHidden -UserId $UserId `
    -AtLogon -AtTime ('2026-01-01T' + $DailyAt + ':00') -RunLevel $RunLevel

$xmlProbe = $null
if ($WithProbe) {
    $probeArgs = Get-ScriptArgs '-Watch -IntervalSeconds 120'
    $probeDesc = 'ThuNet: record what the campus portal does when the link is blocked. Diagnostic companion to ' + $TaskName + '.'
    $xmlProbe = New-ThuNetTaskXml -TaskName $ProbeTaskName -Description $probeDesc -ScriptPath $ProbePs1 `
        -ScriptArgs $probeArgs -RunHiddenPath $RunHidden -UserId $UserId `
        -AtLogon -AtTime ('2026-01-01T' + $DailyAt + ':00') -RunLevel $RunLevel
}

# ---------------------------------------------------------------- what would be registered
# -WhatIf prints the full XML and stops.  This is also how the task definition is inspected in CI
# or by hand: registering a task that fires at every logon is not something a test run should do to
# the machine it is testing on.
if ($WhatIf) {
    Write-Host '--- WhatIf: nothing is registered. Task XML for ' + $TaskName + ' ---'
    Write-Host $xmlLogin
    if ($xmlProbe) {
        Write-Host ''
        Write-Host '--- WhatIf: nothing is registered. Task XML for ' + $ProbeTaskName + ' ---'
        Write-Host $xmlProbe
    }
    return
}

# ---------------------------------------------------------------- registration
function Invoke-Schtasks {
    param([string[]]$SchtasksArgs)
    # Capture both streams into one string for the report, and return the exit code to the caller.
    # $LASTEXITCODE is read immediately: any command in between would overwrite it.
    $out = & schtasks.exe @SchtasksArgs 2>&1
    $code = $LASTEXITCODE
    if ($out) { $out | ForEach-Object { Write-Host ('  ' + $_) } }
    return $code
}

function Register-One {
    param([string]$Name, [string]$Xml, [string]$Label)

    Write-Host ('--- ' + $Label + ': ' + $Name)

    # Replace an existing definition only with -Force.  Overwriting someone else's task silently
    # would be a surprise, and this repository explicitly does not touch tasks it did not create.
    # The probe's exit code is what decides this, so the "task not found" complaint is swallowed
    # rather than printed - it is the expected answer here, not a problem.
    $null = & schtasks.exe /query /tn $Name > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        if (-not $Force) {
            Write-Host ('  a task named "' + $Name + '" already exists - leaving it alone.')
            Write-Host '  re-run with -Force to replace it, or pick another name with -TaskName.'
            return $false
        }
        Write-Host '  replacing the existing task (-Force).'
    }

    # schtasks /create /xml wants a UTF-16LE file with a BOM.  A UTF-8 file makes it fail with
    # "The task XML contains a value which is incorrectly formatted or out of range", which reads
    # like a content problem and is really an encoding problem.
    $tmp = Join-Path $env:TEMP ('thunet-task-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        $enc = New-Object System.Text.UnicodeEncoding($false, $true)
        [System.IO.File]::WriteAllText($tmp, $Xml, $enc)

        $code = Invoke-Schtasks @('/create', '/f', '/tn', $Name, '/xml', $tmp)
        if ($code -ne 0) {
            Write-Host ('  FAILED: schtasks /create exited with ' + $code)
            return $false
        }
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    # Verify by querying it back.  "The create call did not error" is not the same as "the task
    # exists with the trigger and action that were intended", so both are read back.
    Write-Host '  querying it back:'
    $qcode = Invoke-Schtasks @('/query', '/tn', $Name, '/xml')
    if ($qcode -ne 0) {
        Write-Host ('  FAILED: the task was created but cannot be queried (exit ' + $qcode + ')')
        return $false
    }
    return $true
}

$okLogin = Register-One -Name $TaskName -Xml $xmlLogin -Label 'login watcher'
$okProbe = $true
if ($WithProbe) { $okProbe = Register-One -Name $ProbeTaskName -Xml $xmlProbe -Label 'portal probe' }

Write-Host ''
if ($okLogin -and $okProbe) {
    Write-Host 'Done.'
    Write-Host ('  Start it now with : schtasks /run /tn ' + $TaskName)
    Write-Host ('  Check its output  : ThuNet-Login.ps1 -Status')
    Write-Host ('  Remove it with    : Uninstall-ThuNetAutoLogin.ps1')
    exit 0
}
Write-Host 'Finished with errors - see the lines above.'
exit 1
