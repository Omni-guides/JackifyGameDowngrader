@echo off
setlocal
title Jackify Game Downgrader
cd /d "%~dp0"
set "JGD_MANAGED=0"
for %%A in (%*) do if /i "%%~A"=="--managed-restart" set "JGD_MANAGED=1"

if not exist "%~dp0JackifyGameDowngrader.ps1" (
    echo ERROR: JackifyGameDowngrader.ps1 was not found beside this launcher.
    echo Extract the complete ZIP before running the tool.
    set "JGD_EXIT=1"
    goto finish
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: Windows PowerShell was not found.
    set "JGD_EXIT=1"
    goto finish
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0JackifyGameDowngrader.ps1" %*
set "JGD_EXIT=%ERRORLEVEL%"
:finish
if "%JGD_MANAGED%"=="1" exit /b %JGD_EXIT%
echo.
if not "%JGD_EXIT%"=="0" echo Downgrader exited with error code %JGD_EXIT%.
echo Press any key to close this window.
pause >nul
exit /b %JGD_EXIT%
