# Elevated launcher for the recovery-only test: keeps the window open on error and records it.
$ErrorActionPreference = 'Stop'
try { & 'C:\ProgramData\USBDoctor\test\run-recovery.ps1' }
catch { $_ | Out-String | Set-Content 'C:\ProgramData\USBDoctor\test\launcher-recovery-error.txt'; Write-Host $_ -ForegroundColor Red; Read-Host 'Error - press Enter to close' }
