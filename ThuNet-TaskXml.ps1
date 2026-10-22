# ThuNet-TaskXml.ps1 - build the scheduled-task definition used by the installer.
#
# WHY THIS IS A SEPARATE FILE: the task definition is a piece of XML that is easy to get subtly
# wrong (an unescaped quote, a missing element that makes schtasks reject the file with a generic
# error, a trigger that never fires).  Keeping it away from the install/uninstall logic means it
# can be dot-sourced and its output inspected on its own - which is how it is checked in this
# repository, because registering a task that fires at logon is not something a test run should do.
#
# WHY schtasks AND NOT Register-ScheduledTask: Register-ScheduledTask reports failure as a
# NON-TERMINATING error.  A try/catch around it therefore never fires, and an installer that only
# checks for an exception happily prints "installed" while no task exists.  schtasks is an external
# program, so its result is a real exit code in $LASTEXITCODE and can be checked honestly.
#
# THIS FILE MUST STAY PURE ASCII - see the header of ThuNet-Login.ps1 for why.

function New-ThuNetTaskXml {
    param(
        [Parameter(Mandatory=$true)][string]$TaskName,
        [Parameter(Mandatory=$true)][string]$Description,
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [string]$ScriptArgs = '',
        [string]$RunHiddenPath,
        [string]$UserId,
        [switch]$AtLogon,
        [string]$AtTime,
        [ValidateSet('Limited','HighestAvailable')][string]$RunLevel = 'Limited'
    )

    # wscript.exe is the launcher whenever the hidden-VBS shim is available: it asks Windows for
    # CREATE_NO_WINDOW, so the watcher never draws a console - not even for one frame.  A
    # -WindowStyle Hidden powershell action still creates a console that flashes on the desktop.
    $command = 'powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    if ($ScriptArgs) { $arguments += ' ' + $ScriptArgs }
    if ($RunHiddenPath -and (Test-Path $RunHiddenPath)) {
        # wscript receives the script and its arguments; the VBScript re-quotes the script path and
        # passes the rest through, so the quoting below has to survive the VBScript parser.  That
        # parser ONLY treats a doubled quote ("") as a literal quote and treats a backslash as a
        # plain character - so a cmd-style \" escape would come out as literal backslash+quote and
        # break the inner PowerShell argument.  Doubling is what is emitted here.
        $command = 'wscript.exe'
        $arguments = '//B //Nologo "' + $RunHiddenPath + '" "' + $ScriptPath + '"'
        $wrapped = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
        if ($ScriptArgs) { $wrapped += ' ' + $ScriptArgs }
        $arguments += ' ' + $wrapped
    }

    # XML escaping is done by hand rather than with a serializer so that the exact text handed to
    # schtasks is visible in this file.  Order matters: & first, or the & of the entities produced
    # for the other characters would be escaped again.
    function Esc([string]$s) {
        if ($null -eq $s) { return '' }
        return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
    }

    if (-not $UserId) {
        # DOMAIN\user, as schtasks expects it in a Principal UserId.
        $UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-16"?>')
    [void]$sb.AppendLine('<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">')
    [void]$sb.AppendLine('  <RegistrationInfo>')
    [void]$sb.AppendLine('    <Description>' + (Esc $Description) + '</Description>')
    [void]$sb.AppendLine('  </RegistrationInfo>')
    [void]$sb.AppendLine('  <Triggers>')
    if ($AtLogon) {
        # A logon trigger fires when THIS user logs on, which is exactly when the port needs
        # re-authenticating.  Delay is deliberately short: the network stack needs a moment before
        # an interface has an address, and the script itself exits harmlessly if it has none.
        [void]$sb.AppendLine('    <LogonTrigger>')
        [void]$sb.AppendLine('      <Enabled>true</Enabled>')
        [void]$sb.AppendLine('      <UserId>' + (Esc $UserId) + '</UserId>')
        [void]$sb.AppendLine('      <Delay>PT15S</Delay>')
        [void]$sb.AppendLine('    </LogonTrigger>')
    }
    if ($AtTime) {
        # A daily safety net.  A logon trigger does not fire for a resume from sleep, and a
        # sleep/resume is one of the events that drops the authentication.
        [void]$sb.AppendLine('    <CalendarTrigger>')
        [void]$sb.AppendLine('      <StartBoundary>' + (Esc $AtTime) + '</StartBoundary>')
        [void]$sb.AppendLine('      <Enabled>true</Enabled>')
        [void]$sb.AppendLine('      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>')
        [void]$sb.AppendLine('    </CalendarTrigger>')
    }
    [void]$sb.AppendLine('  </Triggers>')
    [void]$sb.AppendLine('  <Principals>')
    # LogonType InteractiveToken: the task runs in the user's own session with the user's own
    # token, which is what makes the DPAPI credential readable.  S4U or a password-based principal
    # would run outside the user profile and fail to decrypt the password file.
    [void]$sb.AppendLine('    <Principal id="Author">')
    [void]$sb.AppendLine('      <UserId>' + (Esc $UserId) + '</UserId>')
    [void]$sb.AppendLine('      <LogonType>InteractiveToken</LogonType>')
    [void]$sb.AppendLine('      <RunLevel>' + $RunLevel + '</RunLevel>')
    [void]$sb.AppendLine('    </Principal>')
    [void]$sb.AppendLine('  </Principals>')
    [void]$sb.AppendLine('  <Settings>')
    # IgnoreNew is the task-level half of the single-instance guarantee; the other half is the mutex
    # inside the script, which also covers a manual start.
    [void]$sb.AppendLine('    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>')
    [void]$sb.AppendLine('    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>')
    [void]$sb.AppendLine('    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>')
    [void]$sb.AppendLine('    <AllowHardTerminate>true</AllowHardTerminate>')
    [void]$sb.AppendLine('    <StartWhenAvailable>true</StartWhenAvailable>')
    [void]$sb.AppendLine('    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>')
    [void]$sb.AppendLine('    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>')
    [void]$sb.AppendLine('    <AllowStartOnDemand>true</AllowStartOnDemand>')
    [void]$sb.AppendLine('    <Enabled>true</Enabled>')
    [void]$sb.AppendLine('    <Hidden>false</Hidden>')
    [void]$sb.AppendLine('    <RunOnlyIfIdle>false</RunOnlyIfIdle>')
    [void]$sb.AppendLine('    <WakeToRun>false</WakeToRun>')
    # No ExecutionTimeLimit: this task is a resident watcher, so a limit would be a scheduled
    # termination of the very process that is supposed to keep running.
    [void]$sb.AppendLine('    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>')
    [void]$sb.AppendLine('    <Priority>4</Priority>')
    # RestartOnFailure: if PowerShell dies (a crash, a killed process), the watcher should come back
    # without waiting for the next logon.
    [void]$sb.AppendLine('    <RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure>')
    [void]$sb.AppendLine('  </Settings>')
    [void]$sb.AppendLine('  <Actions Context="Author">')
    [void]$sb.AppendLine('    <Exec>')
    [void]$sb.AppendLine('      <Command>' + (Esc $command) + '</Command>')
    [void]$sb.AppendLine('      <Arguments>' + (Esc $arguments) + '</Arguments>')
    [void]$sb.AppendLine('    </Exec>')
    [void]$sb.AppendLine('  </Actions>')
    [void]$sb.AppendLine('</Task>')
    return $sb.ToString()
}
