@echo off
title Site server
setlocal
set PORT=80
if exist settings.json (
  for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "(Get-Content -Raw settings.json | ConvertFrom-Json).port"`) do set PORT=%%P
)
echo ==================================================
echo                   SITE SERVER
echo ==================================================
echo.
echo  Site address on this computer:
echo    http://localhost:%PORT%
echo.
echo  Addresses for other computers in the network:
powershell -NoProfile -Command "$port='%PORT%'; $lines=@(); ipconfig | ForEach-Object { if($_ -match 'IPv4.*?(\d+\.\d+\.\d+\.\d+)'){ $ip=$Matches[1]; if($ip -notlike '169.254.*'){ $lines += ('   http://' + $ip + ':' + $port) } } }; $lines | ForEach-Object { Write-Host $_ }; if(-not $lines){ Write-Host '   (no network adapters found)' }"
echo.
echo  Other computers must open the IP address, not localhost.
echo  Press Ctrl+C to stop. Keep this window open.
echo ==================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1
pause
