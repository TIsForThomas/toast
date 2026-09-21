@echo off
REM TOAST Image Capture Kit -- step 1 entry point.
REM
REM Exists so the customer double-clicks one file and gets an elevated
REM PowerShell without being told about execution policy. Sysprep needs
REM administrator rights, so there is no non-elevated path that works.
setlocal
title TOAST Image Capture Kit - Step 1

REM Ask for a large window up front. The PowerShell script maximizes it
REM properly once it starts; this only stops the first few lines appearing
REM in a default 80x25 box before that happens.
mode con: cols=120 lines=50 >nul 2>&1

REM Already elevated? "net session" only succeeds as administrator.
net session >nul 2>&1
if %errorlevel% equ 0 goto :elevated

echo.
echo   TOAST Image Capture Kit
echo.
echo   Windows will ask for permission to continue. Click Yes.
echo.
powershell.exe -NoProfile -Command "Start-Process -FilePath %~f0 -WorkingDirectory %~dp0 -Verb RunAs -WindowStyle Maximized"
if %errorlevel% neq 0 (
    echo.
    echo   Could not restart with administrator rights.
    echo   Right-click Run-Toast-Prep.cmd and choose "Run as administrator".
    echo.
    pause
)
exit /b

:elevated
if not exist "%~dp0scripts\Prepare-Sysprep-USB.ps1" (
    echo.
    echo   scripts\Prepare-Sysprep-USB.ps1 is missing.
    echo   Run this from the TOAST USB drive, not from a copy on the computer.
    echo.
    pause
    exit /b 1
)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Prepare-Sysprep-USB.ps1"
set RC=%errorlevel%
if %RC% neq 0 (
    echo.
    echo   Step 1 did not finish ^(code %RC%^). The log is in the logs folder on this drive.
    echo.
    pause
)
exit /b %RC%
