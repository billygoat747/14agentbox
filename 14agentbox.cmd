@echo off
REM 14agentbox Windows CMD Wrapper
REM Forwards arguments to PowerShell runner
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp014agentbox.ps1" %*
