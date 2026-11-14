@echo off
rem USBImager launcher - asks for administrator approval (UAC), then opens the window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0USBImager.ps1" %*
