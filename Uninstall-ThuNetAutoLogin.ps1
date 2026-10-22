# Uninstall-ThuNetAutoLogin.ps1 - remove the tasks installed by Install-ThuNetAutoLogin.ps1.
#
# It removes a task ONLY if the task exists AND its action still points at a script inside this
# repository.  A task that happens to share the name but was created by something else is left
# alone and reported: an uninstaller that matches on name alone is how an unrelated job quietly
# disappears from a machine nobody is looking at.
#
# It does NOT touch credentials, logs or anything else on disk.  Removing the credential files is a
# separate, deliberate step:
#     Set-ThuNetCredential.ps1 -Remove
# Keeping the two apart means re-installing the task does not force re-entering the password, and
# a "clean up the tasks" run cannot lock you out of a machine you are away from by deleting the
# credential a task still needs.
#
# THIS FILE MUST STAY PURE ASCII - see the header of ThuNet-Login.ps1 for why.
#
# USAGE
#   Uninstall-ThuNetAutoLogin.ps1
#   Uninstall-ThuNetAutoLogin.ps1 -WithProbe
#   Uninstall-ThuNetAutoLogin.ps1 -TaskName Something -ProbeTaskName SomethingElse
#   Uninstall-ThuNetAutoLogin.ps1 -WhatIf

param(
    [string]$TaskName = 'ThuNet-Login',
    [string]$ProbeTaskName = 'ThuNet-Probe',
    [switch]$WithProbe,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host '== ThuNet auto-login uninstaller =='
Write-Host ('repo            : ' + $Root)

function Get-TaskXmlOrNull {
    param([string]$Name)
    $out = & schtasks.exe /query /tn $Name /xml 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { return $null }
    return ($out | Out-String)
}

function Remove-One {
    param([string]$Name, [string]$Label)

    Write-Host ('--- ' + $Label + ': ' + $Name)

    $xml = Get-TaskXmlOrNull $Name
    if (-not $xml) {
        Write-Host '  not installed - nothing to do.'
        return $true
    }

    # Ownership check.  The task must reference a script that lives in THIS repository directory,
    # otherwise this is somebody else's task that happens to share the name.
    if ($xml -notlike ('*' + $Root + '*')) {
        Write-Host '  a task with this name exists, but its action does not point into this repository.'
        Write-Host '  Leaving it alone. Remove it by hand if you are sure it is the one you want gone:'
        Write-Host ('    schtasks /delete /tn "' + $Name + '" /f')
        return $false
    }

    if ($WhatIf) {
        Write-Host ('  WhatIf: would run schtasks /delete /tn "' + $Name + '" /f')
        return $true
    }

    $out = & schtasks.exe /delete /tn $Name /f 2>&1
    $code = $LASTEXITCODE
    if ($out) { $out | ForEach-Object { Write-Host ('  ' + $_) } }
    if ($code -ne 0) {
        Write-Host ('  FAILED: schtasks /delete exited with ' + $code)
        return $false
    }

    # Verify: query it again and require "not found".
    $after = Get-TaskXmlOrNull $Name
    if ($after) {
        Write-Host '  FAILED: the task can still be queried after a successful delete.'
        return $false
    }
    Write-Host '  removed.'
    return $true
}

$ok1 = Remove-One -Name $TaskName -Label 'login watcher'
$ok2 = $true
if ($WithProbe) {
    $ok2 = Remove-One -Name $ProbeTaskName -Label 'portal probe'
}
Write-Host ''
Write-Host 'Credentials and logs were not touched. To remove the stored account as well:'
Write-Host '    Set-ThuNetCredential.ps1 -Remove'
if ($ok1 -and $ok2) { exit 0 } else { exit 1 }
