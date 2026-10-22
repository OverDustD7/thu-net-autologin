@echo off
rem Setup-ThuNetAutoLogin.cmd - the double-click entry point for the campus-network auto-login.
rem
rem Windows opens a .ps1 in Notepad when it is double-clicked, so THIS is the file to click: it runs
rem the sibling PowerShell script, bypassing the execution policy for this one process only (no
rem system-wide setting is touched), and then pauses so the result can be read.
rem
rem Arguments pass straight through, for example:
rem     Setup-ThuNetAutoLogin.cmd -WhatIf
rem     Setup-ThuNetAutoLogin.cmd -ForceCredential
rem     Setup-ThuNetAutoLogin.cmd -IntervalSeconds 30
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

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (echo Setup finished.) else (echo Setup exited with code %RC% - read the messages above.)
echo.
pause
exit /b %RC%
