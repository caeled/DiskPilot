# Non-elevated checks of the 0.3.0 fixes. Writes only under $env:TEMP\ud-unit. No disk writes, no diskpart.
$ErrorActionPreference = 'Stop'
$S = Split-Path -Parent $MyInvocation.MyCommand.Path
$W = Join-Path $env:TEMP 'ud-unit'; Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $W | Out-Null
Import-Module (Join-Path $S 'USBDoctor.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $S 'USBDoctor.Tools.psm1') -Force -DisableNameChecking
Set-UDConfig -LogFile (Join-Path $W 'u.log') -HistoryFile (Join-Path $W 'h.json')
$p = 0; $f = 0
function T([string]$n, [scriptblock]$b, [string]$expectErr) {
    try { $o = & $b; if ($expectErr) { $script:f++; "FAIL $n : expected error /$expectErr/, got: $o" } elseif ($o -is [bool] -and -not $o) { $script:f++; "FAIL $n : false" } else { $script:p++; "PASS $n $(if ($o -isnot [bool]) { ": $o" })" } }
    catch { if ($expectErr -and $_.Exception.Message -match $expectErr) { $script:p++; "PASS $n (error: $($_.Exception.Message))" } else { $script:f++; "FAIL $n : $($_.Exception.Message)" } }
}
# --- 1. Invoke-Diskpart success detection with a mocked diskpart.exe (functions win over applications)
$script:mockOut = ''; $script:mockRc = 0
function global:diskpart.exe { $global:LASTEXITCODE = $script:mockRc; $script:mockOut }
$fmtOk = "`r`nMicrosoft DiskPart version 10.0`r`n`r`nDisk 8 is now the selected disk.`r`n`r`nVirtual Disk Service error:`r`nThis disk is already online.`r`n`r`nDiskPart succeeded in cleaning the disk.`r`n`r`nDiskPart successfully converted the selected disk to MBR format.`r`n`r`nDiskPart succeeded in creating the specified partition.`r`n`r`n    0 percent completed`r`n  100 percent completed`r`n`r`nDiskPart successfully formatted the volume.`r`n`r`nDiskPart successfully assigned the drive letter or mount point.`r`n"
$cleanOk = "Disk 8 is now the selected disk.`r`n`r`nVirtual Disk Service error:`r`nThis disk is already online. `r`n`r`nDiskPart succeeded in cleaning the disk.`r`n"
$realErr = "Disk 8 is now the selected disk.`r`n`r`nVirtual Disk Service error:`r`nThe media is write protected.`r`n"
$deny = "Disk 8 is now the selected disk.`r`n`r`nDiskPart has encountered an error: Access is denied.`r`nSee the System Event Log for more information.`r`n"
T 'D1 format output with benign already-online, exit 0 -> success' { $script:mockOut = $fmtOk; $script:mockRc = 0; $o = Invoke-Diskpart @('select disk 8'); [bool]($o -match 'successfully formatted') }
T 'D2 clean output with benign already-online, exit 0 -> success' { $script:mockOut = $cleanOk; $script:mockRc = 0; $o = Invoke-Diskpart @('select disk 8'); [bool]($o -match 'succeeded in cleaning') }
T 'D3 real VDS error (write protected), exit 0 -> failure' { $script:mockOut = $realErr; $script:mockRc = 0; Invoke-Diskpart @('x') } 'diskpart failed.*write protected'
T 'D4 real VDS error with non-zero exit -> failure' { $script:mockOut = $realErr; $script:mockRc = 2147024809; Invoke-Diskpart @('x') } 'diskpart failed \(exit 2147024809\)'
T 'D5 access denied -> failure' { $script:mockOut = $deny; $script:mockRc = 5; Invoke-Diskpart @('x') } 'Access is denied'
T 'D6 benign text but non-zero exit -> failure (exit code wins)' { $script:mockOut = $cleanOk; $script:mockRc = 1; Invoke-Diskpart @('x') } 'exit 1'
T 'D7 already-online AND a later real error -> failure' { $script:mockOut = $cleanOk + "`r`nVirtual Disk Service error:`r`nThe operation is not supported on removable media.`r`n"; $script:mockRc = 0; Invoke-Diskpart @('x') } 'not supported'
Remove-Item function:\diskpart.exe
# --- 2. Get-SourceFiles skips System Volume Information / $RECYCLE.BIN even when access is denied
$src = Join-Path $W 'src'; New-Item -ItemType Directory "$src\sources", "$src\efi\boot", "$src\System Volume Information", "$src\`$RECYCLE.BIN\S-1" -Force | Out-Null
'a' | Set-Content "$src\bootmgr"; 'b' | Set-Content "$src\sources\boot.wim"; 'c' | Set-Content "$src\efi\boot\bootx64.efi"; 'x' | Set-Content "$src\System Volume Information\tracking.log"; 'y' | Set-Content "$src\`$RECYCLE.BIN\S-1\r.txt"
& icacls.exe "$src\System Volume Information" /deny "${env:USERNAME}:(OI)(CI)(RX)" | Out-Null
$mod = Get-Module USBDoctor.Tools
T 'S1 old enumeration really fails on the denied folder (reproduces G26)' { Get-ChildItem -LiteralPath $src -Recurse -Force -File -ErrorAction Stop | Out-Null } 'denied'
T 'S2 Get-SourceFiles returns the 3 installer files only' { $l = @(& $mod { param($r) Get-SourceFiles $r } $src); if ($l.Count -ne 3 -or ($l.FullName -match 'System Volume|RECYCLE')) { throw ($l.FullName -join ', ') }; ($l.Name -join ',') }
& icacls.exe "$src\System Volume Information" /remove:d "${env:USERNAME}" | Out-Null
# --- 3. Benchmark letter forms
T 'B1 -Letter "Q:\" normalised (fails on the missing drive, not on the format)' { Invoke-UsbBenchmark -Letter 'Q:\' -SizeMB 16 } 'No partition has drive letter Q:'
T 'B2 -Letter "q:" normalised' { Invoke-UsbBenchmark -Letter 'q:' -SizeMB 16 } 'No partition has drive letter Q:'
T 'B3 -Letter "12" refused as not a letter' { Invoke-UsbBenchmark -Letter '12' -SizeMB 16 } 'not a drive letter'
T 'B4 no letter, no disk -> usage message (what G29-G31 hit because G28 left $LB empty)' { Invoke-UsbBenchmark -Letter '' -SizeMB 16 } 'Use -Benchmark -Letter X'
$bt = Join-Path $W 'bench'; New-Item -ItemType Directory $bt | Out-Null
T 'B5 file benchmark logic on a temp folder (TestPath hook), temp file removed' { $r = Invoke-UsbBenchmark -TestPath $bt -SizeMB 16 -RandomSeconds 1 -MaxRandomOps 200 -NoHistory; if ($r.Integrity -notmatch 'read back correctly' -or @(Get-ChildItem $bt -Force).Count) { throw ($r | Out-String) }; "read $($r.SeqReadMBs) MB/s write $($r.SeqWriteMBs) MB/s" }
# --- 4. CLI: -SimulateWrapAt via -File needs digits; '32MB' is what broke F6
$ps1 = Join-Path $S 'USBDoctor.ps1'
T 'C1 powershell -File with -SimulateWrapAt 32MB fails at binding (harness bug reproduced)' { $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -CapacityTest -Disk 99 -SimulateWrapAt 32MB -NoElevate -LogFile (Join-Path $W 'c.log') -HistoryFile (Join-Path $W 'h.json') 2>&1 | Out-String; if ($o -match "Cannot convert value .32MB.") { 'binder rejects 32MB' } else { throw $o } }
T 'C2 -SimulateWrapAt 33554432 binds (fails later only on the missing disk 99)' { $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -CapacityTest -Disk 99 -ConfirmPhrase 'ERASE 99' -SimulateWrapAt 33554432 -NoElevate -LogFile (Join-Path $W 'c.log') -HistoryFile (Join-Path $W 'h.json') 2>&1 | Out-String; if ($o -match 'SimulateWrapAt|Cannot convert') { throw $o }; ($o.Trim() -split "`r?`n" | Select-Object -Last 1) }
# --- 5. Get-ImageVolume against H: (disk 2, USBDATA) - queries only: it has a letter, so nothing is assigned or written
$hp = Get-Partition -DriveLetter H -ErrorAction SilentlyContinue
if ($hp) { T 'V1 Get-ImageVolume finds the volume + letter (read-only query on H:)' { $v = & $mod { param($n, $pn) Get-ImageVolume $n $pn } $hp.DiskNumber $hp.PartitionNumber; if ($v.Root -ne 'H:\' -or $v.Added -or "$($v.Volume.FileSystemType)" -ne 'NTFS') { throw ($v | Out-String) }; "Root=$($v.Root) FS=$($v.Volume.FileSystemType) Added=$($v.Added)" } }
# --- 6. counterfeit record -> Get-PrepareDisk message contains 'counterfeit' (string check on the module source)
T 'P1 Get-PrepareDisk refuses recorded counterfeits with the word counterfeit' { [bool]((Get-Command Get-PrepareDisk).Definition -match 'Counterfeit\) \{ throw "REFUSED on disk \$\{Number\}: this stick failed the capacity test \(counterfeit') }
"DONE pass=$p fail=$f"
Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue
