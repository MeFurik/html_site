@echo off
title Site server
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
