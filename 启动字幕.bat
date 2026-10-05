@echo off
chcp 65001 >nul
setlocal

rem ============================================================
rem  Launcher: starts ONLY the main script.
rem
rem  The old version was:
rem      for %%f in ("%~dp0*.ps1") do ( start ... -File "%%~ff" )
rem  which started EVERY .ps1 in this folder - including setup.ps1.
rem  So every double-click silently re-ran the installer in a hidden
rem  window, where it then blocked forever on a Read-Host prompt.
rem  Now setup.ps1 is explicitly skipped.
rem ============================================================

for %%f in ("%~dp0*.ps1") do (
    if /i not "%%~nxf"=="setup.ps1" (
        start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%%~ff"
    )
)

endlocal
