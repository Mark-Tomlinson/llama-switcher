@echo off
REM =============================================================================
REM Configuration - edit these paths for your installation
REM =============================================================================
set "LlamaSwitcher=D:\llama-switcher\llama-switcher.ps1"
set "SillyTavern=D:\SillyTavern\UpdateAndStart.bat"
REM =============================================================================

REM Launch llama-switcher (PowerShell script needs powershell.exe)
start "llama-switcher" cmd /c powershell.exe -ExecutionPolicy Bypass -File "%LlamaSwitcher%"

REM Launch SillyTavern
start "SillyTavern" cmd /c "%SillyTavern%"

exit /b