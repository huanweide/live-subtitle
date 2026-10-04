@echo off
chcp 65001 >nul
setlocal
for %%f in ("%~dp0*.ps1") do (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%%~ff"
)
endlocal
