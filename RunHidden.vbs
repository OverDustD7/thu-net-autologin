' RunHidden.vbs - launch a PowerShell script with NO console window at all.
'
' Why not "powershell.exe -WindowStyle Hidden": that still creates a console for a moment, which
' shows up as a black box flashing on the desktop - and if the script is a -Watch loop that was
' launched slightly wrong, the box stays open, which on an unattended machine is both ugly and a
' hint that something is misconfigured.  WScript.Shell.Run with window style 0 asks Windows for
' CREATE_NO_WINDOW, so nothing is ever drawn.
'
' Usage:  wscript.exe //B //Nologo RunHidden.vbs "<script.ps1>" [arguments...]
'   //B      batch mode - no script errors are shown in a dialog box
'   //Nologo suppresses the wscript banner
' Both are optional; the task installer passes them so that a parse error in the target script
' cannot pop a modal dialog on a machine nobody is sitting at.
'
' The script path is quoted here explicitly, so a path containing spaces works.  The task installer
' passes it already quoted as well: the quotes are passed through twice on purpose, because the
' inner powershell.exe -File needs its own pair and the WScript.Arguments parser has already
' consumed the outer one by the time the command string is built.
'
' THIS FILE MUST STAY PURE ASCII (see the header of ThuNet-Login.ps1 for why).

Option Explicit

Dim sh, cmd, i

If WScript.Arguments.Count = 0 Then
    ' Nothing to run.  Exit with a distinct code so the failure is visible in a task history.
    WScript.Quit 2
End If

Set sh = CreateObject("WScript.Shell")

' The script path is the first argument.  Inner quotes are left alone: they are what the
' powershell.exe -File parser needs.
cmd = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """"

For i = 1 To WScript.Arguments.Count - 1
    cmd = cmd & " " & WScript.Arguments(i)
Next

' 0 = hidden window (CREATE_NO_WINDOW), False = do not wait for it to finish.
sh.Run cmd, 0, False

Set sh = Nothing
