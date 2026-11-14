@echo off
rem USBDoctor launcher - asks for administrator approval (UAC), then opens the window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0USBDoctor.ps1" %*
