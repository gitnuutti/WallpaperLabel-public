@echo off
setlocal

echo ============================================================
echo   Unblock scripts + allow PowerShell scripts (current user)
echo ============================================================
echo.
echo This folder was downloaded from the internet, so Windows marks every
echo file in it as "blocked" and PowerShell refuses to run unsigned .ps1
echo scripts by default. This fixes both, for YOUR Windows user account
echo only - no admin rights needed, nothing else on the machine is changed.
echo.

echo Unblocking all files in this folder...
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse | Unblock-File"

echo Allowing local PowerShell scripts to run (current user only)...
powershell -NoProfile -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force"

echo.
echo Done. You can now double-click the .ps1 scripts in this folder.
echo.
pause