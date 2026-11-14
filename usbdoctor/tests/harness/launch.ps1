# Elevated launcher: keeps the window open on error and records it.
$ErrorActionPreference = 'Stop'
try { & 'C:\ProgramData\USBDoctor\test\run-tests.ps1' }
catch { $_ | Out-String | Set-Content 'C:\ProgramData\USBDoctor\test\launcher-error.txt'; Write-Host $_ -ForegroundColor Red; Read-Host 'Error - press Enter to close' }
