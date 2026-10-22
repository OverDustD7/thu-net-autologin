@echo off
rem Change-ThuNetCredential.cmd - double-click entry for "I changed my campus password".
rem
rem Equivalent to:  Setup-ThuNetAutoLogin.ps1 -ForceCredential
rem It asks for the account and the new password, overwrites the stored credential, restarts the
rem watcher and then verifies by doing one real login attempt, so the result is visible immediately
rem instead of at the next logon.
rem
rem No reboot and no task re-registration is needed: the watcher re-reads the credential files on
rem every cycle, so a new password takes effect within one interval (60 s by default).  The
rem verification at the end is what proves it, not the file write.
rem
rem THIS FILE IS ASCII AND MUST STAY THAT WAY (same reason as the .ps1 files).

setlocal
set "SCRIPT=%~dp0Setup-ThuNetAutoLogin.ps1"

if not exist "%SCRIPT%" (
  echo ERROR: Setup-ThuNetAutoLogin.ps1 was not found next to this file.
  echo        Keep the repository files together and run this from the repository directory.
  echo.
  pause
  exit /b 1
)

echo Changing the stored campus-network credential.
echo The password is asked for twice and is not echoed.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ForceCredential %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (echo Credential changed.) else (echo Exited with code %RC% - read the messages above.)
echo.
pause
exit /b %RC%
