# USBDoctor elevated test harness v3 (catalog spec + Prepare & Tools). Real drives: read-only only. All repairs run on VHDs in C:\ProgramData\USBDoctor\test.
param([string]$AppDir = '\\FILESERVER\Share\research\MyApps\Partition\USBDoctor', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$T = 'C:\ProgramData\USBDoctor\test'
$sfx = if ($DryRun) { '-dry' } else { '' }
$res = Join-Path $T "results$sfx.txt"
try { Start-Transcript -Path (Join-Path $T "transcript$sfx.txt") -Force | Out-Null } catch { Start-Transcript -Path (Join-Path $T ("transcript-" + (Get-Date -f HHmmss) + ".txt")) -Force -ErrorAction SilentlyContinue | Out-Null }
"STARTED $(Get-Date -Format s) admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators'))" | Set-Content $res
function Say([string]$s) { Add-Content -LiteralPath $res -Value $s; Write-Host $s }
if (-not (Test-Path "$AppDir\USBDoctor.Core.psm1")) { Say "UNC not reachable elevated, using staging copy"; $AppDir = 'C:\Users\testuser\usbdoctor-staging' }
Say "AppDir=$AppDir"
$ps1 = Join-Path $AppDir 'USBDoctor.ps1'
Import-Module (Join-Path $AppDir 'USBDoctor.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $AppDir 'USBDoctor.Tools.psm1') -Force -DisableNameChecking
$log = Join-Path $T "test$sfx.log"
$TH = Join-Path $T 'history-test.json'
Set-UDConfig -LogFile $log
$script:pass = 0; $script:fail = 0; $script:runId = Get-Date -Format HHmmss
Get-ChildItem $T -Filter *.vhd -ErrorAction SilentlyContinue | ForEach-Object { try { $di = Get-DiskImage -ImagePath $_.FullName -ErrorAction Stop; if ($di.Attached) { Dismount-DiskImage -ImagePath $_.FullName -ErrorAction Stop | Out-Null } } catch {}; Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
function Check([string]$Name, [scriptblock]$Sb, [string]$ExpectError) {
    try {
        $o = & $Sb
        if ($ExpectError) { $script:fail++; Say "FAIL  $Name : expected an error matching '$ExpectError' but it succeeded: $(($o | Out-String).Trim())" }
        elseif ($o -is [bool] -and -not $o) { $script:fail++; Say "FAIL  $Name : returned false" }
        else { $script:pass++; Say "PASS  $Name $(if ($o -and -not ($o -is [bool])) { ': ' + (($o | Out-String -Width 300).Trim() -replace '\s*\r?\n\s*', ' | ') })" }
    } catch {
        $m = $_.Exception.Message
        if ($ExpectError -and $m -match $ExpectError) { $script:pass++; Say "PASS  $Name (refused as expected: $m)" }
        else { $script:fail++; Say "FAIL  $Name : $m" }
    }
}
function DP([string[]]$Lines) {
    $f = Join-Path $T 'dp.txt'; Set-Content $f ($Lines -join "`r`n") -Encoding ASCII
    $o = & diskpart.exe /s $f 2>&1 | Out-String; Remove-Item $f
    if ($LASTEXITCODE -ne 0) { throw "diskpart exit $LASTEXITCODE : $o" }
    try { Update-HostStorageCache -ErrorAction Stop } catch {}
    $o
}
function New-TestVhd([string]$Name, [int]$MB, [int]$PartMB, [string]$Fs, [string]$Label, [switch]$NoLetter, [string]$Style = 'mbr', [switch]$Blank, [string]$Id) {
    $f = Join-Path $T "$Name-$script:runId.vhd"
    if (Test-Path $f) { DP @("select vdisk file=`"$f`"", 'detach vdisk noerr') | Out-Null; Remove-Item $f -Force }
    $l = @("create vdisk file=`"$f`" maximum=$MB type=fixed", "select vdisk file=`"$f`"", 'attach vdisk')
    if (-not $Blank) {
        $l += "convert $Style"
        $l += $(if ($Id) { "create partition primary size=$PartMB id=$Id" } else { "create partition primary size=$PartMB" })
        if ($Fs) { $l += "format fs=$Fs quick label=$Label" }
        if ($NoLetter -or -not $Fs) { $l += 'remove all noerr' } else { $l += 'assign' }
    }
    DP $l | Out-Null
    Start-Sleep 3
    $n = Get-VhdNumber $f
    [pscustomobject]@{ File = $f; Number = [int]$n }
}
function Get-VhdNumber([string]$f) {
    $n = $null; try { $n = (Get-DiskImage -ImagePath $f -ErrorAction Stop).Number } catch {}
    if ($null -eq $n) { $n = (Get-Disk | Where-Object { $_.Location -eq $f }).Number }
    if ($null -eq $n) { throw "cannot find disk number of $f" }
    [int]$n
}
function Get-Letter([int]$n) { $p = Get-Partition -DiskNumber $n | Where-Object { "$($_.DriveLetter)" -match '^[A-Za-z]$' } | Select-Object -First 1; if ($p) { "$($p.DriveLetter)" } else { '' } }
function Get-FreeTestLetters {
    $used = @([IO.DriveInfo]::GetDrives() | % { $_.Name.Substring(0, 1) }) + @(Get-ChildItem HKCU:\Network -EA SilentlyContinue | % PSChildName)
    $mv = Get-ItemProperty HKLM:\SYSTEM\MountedDevices
    @('T', 'U', 'V', 'W', 'S', 'R', 'Q', 'P') | Where-Object { $_ -notin $used -and -not $mv."\DosDevices\${_}:" }
}
function Write-Raw([int]$n, [int64]$off, [byte[]]$bytes, [string]$LockLetter, [switch]$NoRefresh) {
    # test-only: damage a VHD on purpose
    $locks = @(); if ($LockLetter) { $m = ''; $lh = [UsbDocNative]::LockVolume("\\.\${LockLetter}:", [ref]$m); if ($lh) { $locks += $lh } }
    $h = [UsbDocNative]::OpenDisk($n, $true)
    try { [UsbDocNative]::WriteAt($h, $off, $bytes, $bytes.Length); [void][UsbDocNative]::Flush($h); if (-not $NoRefresh) { [void][UsbDocNative]::UpdateProperties($h) } } finally { $h.Close(); foreach ($x in $locks) { $x.Close() } }
}
function Set-VhdFileBytes([string]$File, [int64]$Off, [byte[]]$Bytes) {
    # test-only: patch a DETACHED fixed VHD file directly (fixed VHD: disk byte N = file byte N; 512-byte footer at the end)
    $fs = [IO.File]::Open($File, 'Open', 'ReadWrite', 'None'); try { $fs.Position = $Off; $fs.Write($Bytes, 0, $Bytes.Length); $fs.Flush() } finally { $fs.Close() }
}
function Get-VhdFileAscii([string]$File, [int64]$Off, [int]$N) {
    $fs = [IO.File]::OpenRead($File); try { if ($Off -lt 0) { $Off = $fs.Length + $Off }; $b = New-Object byte[] $N; $fs.Position = $Off; [void]$fs.Read($b, 0, $N) } finally { $fs.Close() }
    ([Text.Encoding]::ASCII.GetString($b) -replace '[^ -~]', '.')
}
function Get-DiskAscii([int]$n, [int64]$Off) { ([Text.Encoding]::ASCII.GetString([byte[]](Read-DiskBytes $n $Off 512), 0, 8) -replace '[^ -~]', '.') }
function Codes($diag) { @($diag.Disks[0].Findings | ForEach-Object Code) }
function UD($n) { @(Get-UsbDisks) | Where-Object { $_.Number -eq $n } | Select-Object -First 1 }
$vhds = @(); $sigs = New-Object System.Collections.Generic.List[uint32]; $gptGuids = @()
try {
    # ---------------- A. real drives: read-only
    Say '=== A. Real drives (read-only)'
    Check 'A1 -List (CLI, elevated)' { (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -List -NoElevate -LogFile $log 2>&1 | Out-String) -match 'SMI USB DISK' }
    $diagOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -Diagnose -Disk 2 -NoElevate -LogFile $log 2>&1 | Out-String
    Set-Content (Join-Path $T 'diag-disk2-admin.txt') $diagOut
    Check 'A2 -Diagnose -Disk 2 elevated (timed raw read, boot sector, access test; all read-only)' { if ($diagOut -notmatch 'STATE:\s+(.+)') { throw $diagOut }; $st = $Matches[1].Trim(); if ($diagOut -match 'RawReadTimeout|RawReadError') { throw "raw read flagged: $st" }; "STATE: $st" }
    Check 'A3 timed raw read of disk 2 (64 KiB, read-only)' { $r = Test-RawRead 2; if ($r.Result -ne 'OK') { throw ($r | Out-String) }; $r.Detail }
    Check 'A4 H: partition identified (read-only)' { $p = Get-Partition -DriveLetter H; $fi = Get-PartitionFsInfo 2 $p.Offset $p.Size; if ($fi.Kind -ne 'NTFS' -or -not $fi.PrimaryValid) { throw ($fi | Out-String) }; "Kind=$($fi.Kind) PrimaryValid=$($fi.PrimaryValid)" }
    Check 'A5 refuse disk 1 (holds C:)' { Set-UsbDriveLetter -DiskNumber 1 -Letter T -Preview } 'never changes it'
    Check 'A6 refuse disk 0 (holds D:)' { Restore-UsbGpt -DiskNumber 0 -Preview } 'never changes it'
    Check 'A7 capacity test refused on H: (not blank)' { Test-UsbCapacity -DiskNumber 2 -Preview } 'REFUSED.*blank'
    Check 'A8 boot-sector restore refused on H: (no RAW partition)' { Restore-UsbBootSector -DiskNumber 2 -Preview } 'no RAW partition'
    Check 'A9 ImageUSB fix refused on H: (not shifted)' { Invoke-ImageUsbFix -DiskNumber 2 -Preview } 'Nothing to fix'
    Check 'A10 machine health (Tier 0)' { $m = Test-MachineHealth; if ($m.Sick) { throw ($m.Findings | Out-String) }; "WMI $($m.WmiMs) ms, not sick" }
    Check 'A11 previews only: automount / suspend / ghosts' { (Enable-UsbAutomount -Preview).Text + ' | ' + (Disable-UsbSelectiveSuspend -Preview).Text + ' | ' + ((Remove-UsbGhostDevices -Preview).Text -split "`r`n")[0] }
    Check 'A12 letter-in-use detection for Z: (mapped share)' { $u = Get-LetterUse 'Z'; if (-not $u) { throw 'Z: not detected as in use' }; $u }
    Check 'A13 old disk-writing ImageUSB repair is gone' { if (Get-Command Repair-ImageUsbShift -ErrorAction SilentlyContinue) { throw 'Repair-ImageUsbShift still exported' }; 'not present' }

    if ($DryRun) { throw 'dry run: stopping before the VHD tests' }
    Set-UDConfig -LogFile $log -HistoryFile $TH
    Remove-Item $TH -Force -ErrorAction SilentlyContinue
    # ---------------- B. VHD1 NTFS
    Say '=== B. VHD1 (NTFS 128 of 256 MB, no letter)'
    $v1 = New-TestVhd 'ud-ntfs' 256 128 'ntfs' 'UDTEST' -NoLetter; $vhds += $v1
    [void]$sigs.Add([uint32](Get-Disk -Number $v1.Number).Signature)
    $n1 = $v1.Number; Say "VHD1 is disk $n1"
    Check 'B0 virtual disk refused without -AllowVirtual' { Set-UsbDriveLetter -DiskNumber $n1 -Letter T -Preview } 'not a USB drive'
    Set-UDConfig -LogFile $log -AllowVirtual -HistoryFile $TH
    $d1 = Invoke-UsbDiagnosis -DiskNumber $n1
    Set-Content (Join-Path $T 'diag-vhd1.txt') (Format-UsbDiagnosis $d1)
    Check 'B1 diagnose: NoLetter + Unallocated; State/Fault/Action/Change present' { $c = Codes $d1; $a = $d1.Disks[0].Assessment; if ('NoLetter' -notin $c -or 'Unallocated' -notin $c -or -not $a.State -or -not $a.FaultOwner -or -not $a.Change) { throw "codes: $c" }; "State=$($a.State) | Fault=$($a.FaultOwner) | Action=$($a.Actions[0])" }
    $free = @(Get-FreeTestLetters); Say "free test letters: $($free -join ',')"
    $L1 = $free[0]; $L2 = $free[1]; $L3 = $free[2]
    Check 'B2 refuse letter H: (in use by USBDATA)' { Set-UsbDriveLetter -DiskNumber $n1 -Letter H -Persistent } 'already in use'
    Check 'B3 refuse letter Z: (mapped network drive)' { Set-UsbDriveLetter -DiskNumber $n1 -Letter Z -Persistent } 'already in use'
    $fake = [Text.Encoding]::Unicode.GetBytes('_??_USBSTOR#Disk&Ven_Fake&Prod_TestStick&Rev_1.00#0000TEST&0#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}')
    New-ItemProperty -Path HKLM:\SYSTEM\MountedDevices -Name "\DosDevices\${L3}:" -PropertyType Binary -Value $fake -Force | Out-Null
    Check "B4 refuse ${L3}: reserved for absent stick (no -Force)" { Set-UsbDriveLetter -DiskNumber $n1 -Letter $L3 -Persistent } 'reserved by Windows'
    Check "B5 assign ${L1}: persistent (#6, no image needed)" { $r = Set-UsbDriveLetter -DiskNumber $n1 -Letter $L1 -Persistent; if (-not $r.Persistent -or $r.Letter -ne $L1) { throw ($r | Out-String) }; $r }
    Check "B6 take ${L3}: with -Force (releases reservation, shown first)" { $r = Set-UsbDriveLetter -DiskNumber $n1 -Letter $L3 -Persistent -Force; if (-not $r.Persistent) { throw ($r | Out-String) }; $r }
    Check 'B7 CLI assign back with -Confirm' { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -AssignLetter -Disk $n1 -Letter $L1 -Persistent -Confirm -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($LASTEXITCODE -ne 0) { throw $o }; ($o -split "`n" | Select-String 'Persistent|Letter ') -join ' ' }
    Set-Content "${L1}:\hello.txt" 'USBDoctor test file'
    & fsutil.exe dirty set "${L1}:" | Out-Null
    Check 'B8 diagnose finds Dirty (#10)' { $c = Codes (Invoke-UsbDiagnosis -DiskNumber $n1); if ('Dirty' -notin $c) { throw "codes: $c" }; 'Dirty found' }
    Check 'B9 chkdsk refused: no image, no phrase' { Invoke-UsbChkdsk -Letter $L1 } 'No complete Rescue image'
    Check 'B10 chkdsk with typed REPAIR N (risk accepted)' { Invoke-UsbChkdsk -Letter $L1 -ConfirmPhrase "REPAIR $n1" }
    Check 'B11 dirty bit cleared' { (& fsutil.exe dirty query "${L1}:" | Out-String) -match 'NOT Dirty' }
    Set-Disk -Number $n1 -IsReadOnly $true
    Check 'B12 diagnose finds ReadOnly (#8)' { $c = Codes (Invoke-UsbDiagnosis -DiskNumber $n1); if ('ReadOnly' -notin $c) { throw "codes: $c" }; 'ReadOnly found' }
    Check 'B13 clear read-only (REPAIR N) + test write + recorded' { $r = Clear-UsbReadOnly -DiskNumber $n1 -ConfirmPhrase "REPAIR $n1"; if ($r.WriteTest -notmatch 'OK') { throw ($r | Out-String) }; $id = (UD $n1).Identity; $h = Get-DeviceHistoryRecord $id; "$($r.WriteTest); clears on file: $(@($h.ReadOnlyClears).Count)" }
    Set-Disk -Number $n1 -IsReadOnly $true   # simulate: read-only came back after replug
    $dRo = Invoke-UsbDiagnosis -DiskNumber $n1
    Check 'B14 read-only returned -> DYING, copy-only' { $c = Codes $dRo; $a = $dRo.Disks[0].Assessment; if ('ReadOnlyReturned' -notin $c -or $a.State -notmatch '^DYING') { throw "codes $c state $($a.State)" }; "State=$($a.State) | Refused: $($a.Refusals -join ' / ')" }
    Check 'B15 second read-only clear refused' { Clear-UsbReadOnly -DiskNumber $n1 -ConfirmPhrase "REPAIR $n1" } 'REFUSED'
    Check 'B16 chkdsk also refused on the dying drive' { Invoke-UsbChkdsk -Letter $L1 -ConfirmPhrase "REPAIR $n1" } 'REFUSED.*dying'
    Set-Disk -Number $n1 -IsReadOnly $false; Remove-Item $TH -Force   # test reset
    Set-Disk -Number $n1 -IsOffline $true
    Check 'B17 diagnose finds Offline (#4)' { $c = Codes (Invoke-UsbDiagnosis -DiskNumber $n1); if ('Offline' -notin $c) { throw "codes: $c" }; 'Offline found' }
    Check 'B18 online preview shows gate, then online (REPAIR N)' { $p = Set-UsbDiskOnline -DiskNumber $n1 -Preview; $r = Set-UsbDiskOnline -DiskNumber $n1 -ConfirmPhrase "REPAIR $n1"; "destructive=$($p.Destructive) online=$($r.Online)" }
    Start-Sleep 2
    Check 'B19 extend refused: no image, wrong phrase' { Expand-UsbPartition -DiskNumber $n1 -ConfirmPhrase 'REPAIR 99' } 'No complete Rescue image'
    # rescue: simulated bad sectors, stop, resume, simulated drop-out
    Set-Disk -Number $n1 -IsOffline $true
    $img = Join-Path $T 'rescue-vhd1.img'; Remove-Item "$img*" -Force -ErrorAction SilentlyContinue
    Check 'B20 rescue run 1 (2 simulated bad ranges, stop after 50 MB)' { $r = Start-UsbRescue -DiskNumber $n1 -OutFile $img -SimulateBadRanges '1048576:8192,5246976:4096' -StopAfterBytes 50MB; if ($r.Status -ne 'stopped' -or $r.BytesBad -ne 12288 -or $r.Position -gt 60MB) { throw ($r | Out-String) }; $r }
    Check 'B21 rescue resume with simulated drop-out at 150 MB' { $r = Start-UsbRescue -DiskNumber $n1 -OutFile $img -SimulateDropAt 150MB -WaitMinutes 2; if ($r.Status -ne 'done' -or $r.DropOuts -ne 1 -or $r.BytesBad -ne 12288 -or $r.BadRanges -ne 2) { throw ($r | Out-String) }; $r }
    Check 'B22 rescue image == disk except zero-filled bad ranges' {
        $direct = Join-Path $T 'direct-vhd1.img'
        $h = [UsbDocNative]::OpenDisk($n1, $false); $size = [UsbDocNative]::GetLength($h)
        $fs = New-Object IO.FileStream($direct, 'Create', 'ReadWrite'); try { [UsbDocNative]::CopyDiskToStream($h, [int64]0, [int64]$size, $fs); $z = New-Object byte[] 8192; $fs.Position = 1048576; $fs.Write($z, 0, 8192); $fs.Position = 5246976; $fs.Write($z, 0, 4096) } finally { $fs.Close(); $h.Close() }
        $a = (Get-FileHash $img).Hash; $b2 = (Get-FileHash $direct).Hash; Remove-Item $direct
        if ($a -ne $b2) { throw "hash mismatch $a vs $b2" }; "SHA256 match $a"
    }
    Set-Disk -Number $n1 -IsOffline $false; Start-Sleep 2
    $id1 = (UD $n1).Identity
    Check 'B23 completed image recorded in history' { $i = Get-DeviceImage $id1; if (-not $i) { throw "no image for $id1" }; "$id1 -> $($i.Path)" }
    Check 'B24 extend WITHOUT phrase now allowed (image on file)' { $r = Expand-UsbPartition -DiskNumber $n1; if ($r.NewSize -lt 250MB) { throw ($r | Out-String) }; $r }
    $L1 = Get-Letter $n1
    Check 'B25 file still readable after extend' { (Get-Content "${L1}:\hello.txt") -eq 'USBDoctor test file' }
    # #3 dying signature via test hook
    Set-UDConfig -LogFile $log -AllowVirtual -HistoryFile $TH -TestHooks @{ RawTimeoutDisk = $n1 }
    $dT = Invoke-UsbDiagnosis -DiskNumber $n1
    Set-Content (Join-Path $T 'diag-vhd1-rawtimeout.txt') (Format-UsbDiagnosis $dT)
    Check 'B26 simulated raw-read timeout -> DYING, image only, provisional Tier 0 prompt' { $a = $dT.Disks[0].Assessment; if ('RawReadTimeout' -notin (Codes $dT) -or $a.State -notmatch '^DYING' -or -not $a.Provisional) { throw ($a | Out-String) }; "State=$($a.State) | Fault=$($a.FaultOwner) | Action=$($a.Actions[0])" }
    Check 'B27 chkdsk refused while raw read times out (even with phrase + image)' { Invoke-UsbChkdsk -Letter $L1 -ConfirmPhrase "REPAIR $n1" } 'REFUSED'
    Check 'B28 CLI chkdsk refused with simulated timeout' { $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -Chkdsk -Letter $L1 -ConfirmPhrase "REPAIR $n1" -SimulateRawTimeoutDisk $n1 -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($LASTEXITCODE -eq 0) { throw "ran: $o" }; 'exit 1, refused' }
    Check 'B29 Tier 0 recorded: other port fails -> fault owner confirmed Drive' { [void](Set-Tier0Result -DiskNumber $n1 -Result OtherPortFails -Note 'test'); $a = (Invoke-UsbDiagnosis -DiskNumber $n1).Disks[0].Assessment; if ($a.FaultOwner -notmatch '^Drive \(.*confirmed' -or $a.Provisional) { throw $a.FaultOwner }; $a.FaultOwner }
    Set-UDConfig -LogFile $log -AllowVirtual -HistoryFile $TH -TestHooks @{ None = 1 }
    Check 'B30 rescue CLI path (-Rescue -WaitForModel, fresh file)' { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -Rescue -WaitForModel 'Virtual Disk' -Out (Join-Path $T 'rescue-cli.img') -WaitMinutes 1 -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($LASTEXITCODE -ne 0 -or $o -notmatch 'Status\s*:\s*done') { throw $o }; ($o -split "`n" | Select-String 'Status|BytesBad') -join ' ' }
    # #5 boot sector restore
    $p1 = Get-Partition -DiskNumber $n1 | Where-Object { $_.Size -gt 100MB } | Select-Object -First 1
    Write-Raw $n1 ([int64]$p1.Offset) (New-Object byte[] 512) $L1
    Start-Sleep 2; try { Update-Disk -Number $n1 } catch {}; Start-Sleep 2
    $dB = Invoke-UsbDiagnosis -DiskNumber $n1
    Check 'B31 zeroed NTFS boot sector -> BootSectorDamaged, backup found' { $c = Codes $dB; if ('BootSectorDamaged' -notin $c) { throw "codes: $c / $(($dB.Disks[0].Findings | % Text) -join ' / ')" }; ($dB.Disks[0].Findings | Where-Object Code -eq 'BootSectorDamaged').Text }
    Check 'B32 restore boot sector from backup (image on file, no phrase)' { $r = Restore-UsbBootSector -DiskNumber $n1; if ($r.FileSystemNow -ne 'NTFS') { throw ($r | Out-String) }; $r }
    Start-Sleep 2; $L1 = Get-Letter $n1; if (-not $L1) { $L1 = (Set-UsbDriveLetter -DiskNumber $n1).Letter }
    Check 'B33 file readable after boot-sector restore' { (Get-Content "${L1}:\hello.txt") -eq 'USBDoctor test file' }

    # ---------------- C. VHD2 FAT32
    Say '=== C. VHD2 (FAT32 128 of 200 MB)'
    $v2 = New-TestVhd 'ud-fat' 200 128 'fat32' 'FATTEST'; $vhds += $v2
    [void]$sigs.Add([uint32](Get-Disk -Number $v2.Number).Signature)
    $L4 = Get-Letter $v2.Number; if (-not $L4) { $L4 = (Set-UsbDriveLetter -DiskNumber $v2.Number).Letter }
    Say "VHD2 is disk $($v2.Number) letter $L4"
    Set-Content "${L4}:\fat.txt" 'fat file'
    Check 'C1 diagnose finds FatCantGrow (#13 truncated partition)' { $c = Codes (Invoke-UsbDiagnosis -DiskNumber $v2.Number); if ('FatCantGrow' -notin $c) { throw "codes: $c" }; "codes: $($c -join ',')" }
    Check 'C2 extend refused on FAT32' { Expand-UsbPartition -DiskNumber $v2.Number -ConfirmPhrase "REPAIR $($v2.Number)" } "can't enlarge FAT"
    Check 'C3 convert FAT32 -> NTFS (REPAIR N)' { Convert-UsbToNtfs -Letter $L4 -ConfirmPhrase "REPAIR $($v2.Number)" }
    Check 'C4 file kept after convert' { (Get-Content "${L4}:\fat.txt") -eq 'fat file' }
    Check 'C5 CLI -Extend with -ConfirmPhrase' { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -Extend -Disk $v2.Number -ConfirmPhrase "REPAIR $($v2.Number)" -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($LASTEXITCODE -ne 0) { throw $o }; ($o -split "`n" | Select-String 'NewSize|VolumeSize') -join ' ' }
    Check 'C6 safe eject (virtual: detach)' { Dismount-UsbDrive -Letter $L4 }

    # ---------------- D. VHD3 ImageUSB shift: image + strip header, stick never written
    Say '=== D. VHD3 (ImageUSB-shifted MBR)'
    $v3 = New-TestVhd 'ud-shift' 64 48 'ntfs' 'SHIFT'; $vhds += $v3
    [void]$sigs.Add([uint32](Get-Disk -Number $v3.Number).Signature)
    $L5 = Get-Letter $v3.Number; if (-not $L5) { $L5 = (Set-UsbDriveLetter -DiskNumber $v3.Number).Letter }
    $rnd = New-Object byte[] (3MB); (New-Object Random 42).NextBytes($rnd); [IO.File]::WriteAllBytes("${L5}:\payload.bin", $rnd)
    DP @("select vdisk file=`"$($v3.File)`"", 'detach vdisk') | Out-Null
    $all = [IO.File]::ReadAllBytes($v3.File); $dataLen = $all.Length - 512
    $sha = [Security.Cryptography.SHA256]::Create(); $origHash = ([BitConverter]::ToString($sha.ComputeHash($all, 0, $dataLen - 512))).Replace('-', '')
    $new = New-Object byte[] $all.Length
    $hdr = [Text.Encoding]::ASCII.GetBytes('imageUSB test header'); [Array]::Copy($hdr, 0, $new, 0, $hdr.Length)
    [Array]::Copy($all, 0, $new, 512, $dataLen - 512)
    [Array]::Copy($all, $dataLen, $new, $dataLen, 512)   # keep VHD footer
    [IO.File]::WriteAllBytes($v3.File, $new); $all = $null; $new = $null; $before = (Get-FileHash $v3.File).Hash
    DP @("select vdisk file=`"$($v3.File)`"", 'attach vdisk') | Out-Null
    Start-Sleep 3
    $v3.Number = Get-VhdNumber $v3.File; $n3 = $v3.Number
    Say "VHD3 re-attached shifted as disk $n3, style $((Get-Disk -Number $n3).PartitionStyle); original data SHA256 $origHash"
    $d3 = Invoke-UsbDiagnosis -DiskNumber $n3
    Set-Content (Join-Path $T 'diag-vhd3-shifted.txt') (Format-UsbDiagnosis $d3)
    Check 'D1 diagnose finds ImageUsbShift' { $c = Codes $d3; if ('ImageUsbShift' -notin $c) { throw "codes: $c" }; "codes: $($c -join ','); action: $(@($d3.Disks[0].Assessment.Actions) -match 'USBImager')" }
    $clean = Join-Path $T 'shift-clean.img'
    Check 'D2 CLI -FixImageUsbShift -Disk N: rescue image + strip header' { $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -FixImageUsbShift -Disk $n3 -Out $clean -Confirm -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($LASTEXITCODE -ne 0) { throw $o }; ($o -split "`n" | Select-String 'FixedImage|StickWritten|BurnCommand') -join ' ' }
    Check 'D3 stick untouched (VHD file hash identical, still RAW)' { $st = (Get-Disk -Number $n3).PartitionStyle; DP @("select vdisk file=`"$($v3.File)`"", 'detach vdisk') | Out-Null; Start-Sleep 2; $after = (Get-FileHash $v3.File).Hash; DP @("select vdisk file=`"$($v3.File)`"", 'attach vdisk') | Out-Null; Start-Sleep 3; $script:n3 = Get-VhdNumber $v3.File; $v3.Number = $script:n3; if ($after -ne $before) { throw 'VHD3 CHANGED' }; "style $st, hash unchanged" }
    Check 'D4 clean image = original unshifted disk data (MBR at 0)' { $h = (Get-FileHash $clean).Hash; if ($h -ne $origHash) { throw "clean $h != original $origHash" }; "SHA256 match $h, $((Get-Item $clean).Length) bytes" }
    $raw = Get-ChildItem $T -Filter 'shift-clean-raw-imageusb.img' | Select-Object -First 1
    Check 'D5 file-only CLI -FixImageUsbShift -Image (no disk access)' { $o2 = Join-Path $T 'shift-clean2.img'; $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -FixImageUsbShift -Image $raw.FullName -Out $o2 -Confirm -NoElevate -LogFile $log 2>&1 | Out-String; if ($LASTEXITCODE -ne 0) { throw $o }; if ((Get-FileHash $o2).Hash -ne $origHash) { throw 'hash differs' }; 'same clean image' }
    Check 'D6 stripping a clean image refused' { Convert-ImageUsbFile -Image $clean -Out (Join-Path $T 'x.img') } 'Nothing to strip'
    Check 'D7 -Report with virtual disks' { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -Report -ReportDir (Join-Path $T 'reports') -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($LASTEXITCODE -ne 0) { throw $o }; (Get-ChildItem (Join-Path $T 'reports')).Name -join ', ' }

    # ---------------- E. GPT primary damaged -> restore from backup (#11)
    Say '=== E. VHD4 (GPT, primary header destroyed)'
    $v4 = New-TestVhd 'ud-gpt' 64 32 'ntfs' 'GPTTEST' -Style gpt; $vhds += $v4; $n4 = $v4.Number
    $gptGuids += @(Get-Partition -DiskNumber $n4 | ForEach-Object { "$($_.Guid)" })
    $L7 = Get-Letter $n4; if (-not $L7) { $L7 = (Set-UsbDriveLetter -DiskNumber $n4).Letter }
    Set-Content "${L7}:\gpt.txt" 'gpt file'
    # Why the old in-place zeroing never stuck: read LBA 1 back right after the raw write, then again after Windows re-reads the disk.
    Write-Raw $n4 512 (New-Object byte[] 512) $L7 -NoRefresh
    $s1 = Get-DiskAscii $n4 512
    try { Update-Disk -Number $n4 -ErrorAction Stop } catch {}; Start-Sleep 2
    $s2 = Get-DiskAscii $n4 512
    Say "E0 in-place zero of LBA 1: header right after the write reads '$s1', after Windows re-reads the disk '$s2' ('EFI PART' = Windows rewrote it)"
    # Make the damage stick: detach, zero LBA 1 in the VHD file itself, check the backup header at the end, reattach.
    $gptAttach = {
        param([string]$Mode)
        DP @("select vdisk file=`"$($v4.File)`"", 'detach vdisk noerr') | Out-Null; Start-Sleep 2
        Set-VhdFileBytes $v4.File 512 (New-Object byte[] 512)
        $ph = Get-VhdFileAscii $v4.File 512 8; $bh = Get-VhdFileAscii $v4.File -1024 8
        DP @("select vdisk file=`"$($v4.File)`"", $(if ($Mode -eq 'ro') { 'attach vdisk readonly' } else { 'attach vdisk' })) | Out-Null; Start-Sleep 3
        $nn = Get-VhdNumber $v4.File
        Say "E file patch ($Mode attach): file primary header '$ph', file backup header '$bh'; after attach disk $nn LBA 1 reads '$(Get-DiskAscii $nn 512)'"
        $nn
    }
    $n4 = & $gptAttach 'rw'
    $gptAuto = ((Get-DiskAscii $n4 512) -eq 'EFI PART')
    if ($gptAuto) {
        Say "NOTE E: Windows rewrote the primary GPT from the backup by itself when the damaged disk was attached writable. Detection and refusal are tested on a read-only attach; the restore write (E4/E5) cannot be exercised on this Windows build."
        $n4 = & $gptAttach 'ro'
    }
    Check 'E1 GPT check: primary invalid, backup valid, protective MBR present' { $g = Get-GptInfo $n4 (Get-Disk -Number $n4).Size; if ($g.PrimaryValid -or -not $g.BackupValid -or -not $g.ProtectiveMbr) { throw ($g | Select ProtectiveMbr, PrimaryValid, BackupValid, Detail | Out-String) }; 'primary=bad backup=ok pmbr=ok' }
    $d4 = Invoke-UsbDiagnosis -DiskNumber $n4
    Check 'E2 diagnose finds GptPrimaryDamaged' { $c = Codes $d4; if ('GptPrimaryDamaged' -notin $c) { throw "codes: $c" }; "codes: $($c -join ',')" }
    Check 'E3 GPT restore refused without image/phrase' { Restore-UsbGpt -DiskNumber $n4 } $(if ($gptAuto) { 'No complete Rescue image|read-only|write-protected' } else { 'No complete Rescue image' })
    if ($gptAuto) { Say 'SKIP  E4/E5 GPT restore write: Windows repairs the primary GPT itself on a writable attach (see NOTE E)' }
    else {
        Check 'E4 GPT restore with REPAIR N' { $r = Restore-UsbGpt -DiskNumber $n4 -ConfirmPhrase "REPAIR $n4"; if (-not $r.PrimaryValid) { throw ($r | Out-String) }; $r }
        Start-Sleep 2; $L7 = Get-Letter $n4; if (-not $L7) { $L7 = (Set-UsbDriveLetter -DiskNumber $n4).Letter }
        Check 'E5 file readable after GPT restore' { (Get-Content "${L7}:\gpt.txt") -eq 'gpt file' }
    }

    # ---------------- F. foreign file system (#5) and capacity test (#13)
    Say '=== F. VHD5 (Linux partition id=83 + ext magic), VHD6 (blank) capacity test'
    $v5 = New-TestVhd 'ud-ext' 32 16 '' '' -Id 83; $vhds += $v5; $n5 = $v5.Number
    [void]$sigs.Add([uint32](Get-Disk -Number $n5).Signature)
    $p5 = Get-Partition -DiskNumber $n5 | Select-Object -First 1
    $sb = New-Object byte[] 512; $sb[56] = 0x53; $sb[57] = 0xEF   # ext superblock at +1024, magic at +1080
    Write-Raw $n5 ([int64]$p5.Offset + 1024) $sb ''
    $d5 = Invoke-UsbDiagnosis -DiskNumber $n5
    Check 'F1 ext partition -> ForeignFs, healthy drive wrong OS, no repair' { $a = $d5.Disks[0].Assessment; if ('ForeignFs' -notin (Codes $d5) -or $a.FaultOwner -notmatch 'wrong OS') { throw "codes $(Codes $d5) / $($a.FaultOwner)" }; "State=$($a.State) | Fault=$($a.FaultOwner)" }
    Check 'F2 boot-sector restore refused on foreign FS' { Restore-UsbBootSector -DiskNumber $n5 -ConfirmPhrase "REPAIR $n5" } 'another OS'
    Check 'F3 capacity test refused (RAW partition, contents unknown)' { Test-UsbCapacity -DiskNumber $n5 -ConfirmPhrase "ERASE $n5" } 'REFUSED'
    $v6 = New-TestVhd 'ud-blank' 64 0 '' '' -Blank; $vhds += $v6; $n6 = $v6.Number
    Check 'F4 capacity test refused with wrong phrase' { Test-UsbCapacity -DiskNumber $n6 -ConfirmPhrase "REPAIR $n6" } 'ERASE'
    Check 'F5 capacity test on blank genuine VHD -> Genuine' { $r = Test-UsbCapacity -DiskNumber $n6 -ConfirmPhrase "ERASE $n6"; if ($r.Result -ne 'Genuine') { throw ($r | Out-String) }; "$($r.Blocks) blocks OK" }
    Check 'F6 CLI capacity test with simulated wrap at 32 MB -> Counterfeit' { $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -CapacityTest -Disk $n6 -ConfirmPhrase "ERASE $n6" -SimulateWrapAt 33554432 -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($o -notmatch 'Result\s*:\s*Counterfeit') { throw $o }; ($o -split "`n" | Select-String 'BadBlocks|GoodBytes|Verdict') -join ' ' }
    $d6 = Invoke-UsbDiagnosis -DiskNumber $n6
    Check 'F7 diagnose: COUNTERFEIT condemned, capacity repair refused' { $a = $d6.Disks[0].Assessment; $g = Get-GateStatus (UD $n6) 'Extend'; if ($a.State -notmatch '^COUNTERFEIT' -or $g.Refusal -notmatch 'counterfeit') { throw "$($a.State) / $($g.Refusal)" }; "State=$($a.State) | gate: $($g.Refusal)" }
    Check 'F8 no format anywhere: no exported command formats' { $bad = @(Get-Command -Module USBDoctor.Core | Where-Object { $_.Definition -match 'Format-Volume|format fs=|Initialize-Disk|Clear-Disk' }); if ($bad.Count) { throw ($bad.Name -join ',') }; 'none' }

    # ---------------- G. PREPARE & TOOLS (v3): format / wipe / bootable / benchmark / recovery / port map / watch. Not repairs.
    Say '=== G. Prepare & Tools (VHDs only)'
    Set-UDConfig -LogFile $log -AllowVirtual -HistoryFile $TH -TestHooks @{ None = 1 }
    Set-UDToolsConfig -LabelsFile (Join-Path $T 'port-labels-test.json')
    Check 'G0 erase code only in the Prepare commands; Core still has none (F8)' { $pc = @(Get-PrepareCommands); $e = @(Get-Command -Module USBDoctor.Tools | Where-Object { $_.Definition -match 'format fs=|''clean''|WipeSlice' } | ForEach-Object Name); $bad = @($e | Where-Object { $_ -notin $pc -and $_ -notin 'Write-RawIsoToDisk', 'Write-WindowsIsoToDisk' }); if ($bad.Count) { throw "erase code outside Prepare: $($bad -join ',')" }; "erase code in: $($e -join ', ')" }
    Check 'G1 format refused on the counterfeit VHD (F6 record)' { Format-UsbDrive -DiskNumber $n6 -Preview } 'counterfeit'
    Check 'G2 wipe refused on the counterfeit VHD too' { Clear-UsbDrive -DiskNumber $n6 -Preview } 'counterfeit'
    Check 'G3 format refused on disk 1 (holds C:)' { Format-UsbDrive -DiskNumber 1 -Preview } 'never changes it'
    Check 'G4 wipe refused on disk 0 (holds D:)' { Clear-UsbDrive -DiskNumber 0 -Preview } 'never changes it'
    $v7 = New-TestVhd 'ud-prep' 96 0 '' '' -Blank; $vhds += $v7; $n7 = $v7.Number; Say "VHD7 (prepare target, 96 MB blank) is disk $n7"
    $free = @(Get-FreeTestLetters); $LP = $free[0]; Say "prepare letter: $LP"
    Check 'G5 format refused with wrong phrase' { Format-UsbDrive -DiskNumber $n7 -FileSystem NTFS -ConfirmPhrase "REPAIR $n7" } 'type ERASE'
    Check 'G6 FAT32 label rule' { Format-UsbDrive -DiskNumber $n7 -FileSystem FAT32 -Label 'WAY_TOO_LONG_LABEL' -Preview } 'at most 11'
    Set-UDConfig -LogFile $log -AllowVirtual -HistoryFile $TH -TestHooks @{ RawTimeoutDisk = $n7 }
    Check 'G7 format refused on a dying drive (simulated raw-read timeout)' { Format-UsbDrive -DiskNumber $n7 -Preview } 'dying'
    Check 'G8 bootable refused on a dying drive' { $f = Join-Path $T 'ud-small.iso'; [IO.File]::WriteAllBytes($f, (New-Object byte[] 1MB)); New-BootableUsb -IsoPath $f -DiskNumber $n7 -Mode Raw -Preview } 'dying'
    Set-UDConfig -LogFile $log -AllowVirtual -HistoryFile $TH -TestHooks @{ None = 1 }
    Check "G9 format NTFS / MBR with -Letter ${LP}:" { $r = Format-UsbDrive -DiskNumber $n7 -FileSystem NTFS -Label UDNTFS -Letter $LP -PartitionStyle MBR -ConfirmPhrase "ERASE $n7"; $p = @(Get-Partition -DiskNumber $n7); $dk = Get-Disk -Number $n7; [void]$sigs.Add([uint32]$dk.Signature); if ($r.FileSystem -ne 'NTFS' -or $r.Letter -ne $LP -or $dk.PartitionStyle -ne 'MBR' -or $p.Count -ne 1 -or $p[0].Offset -ne 1MB) { throw ($r | Out-String) + " style=$($dk.PartitionStyle) parts=$($p.Count) off=$($p[0].Offset)" }; "$($r.Letter): $($r.FileSystem) '$($r.Label)' $($r.Size) bytes, offset 1 MiB" }
    Set-Content "${LP}:\keep.txt" 'data that would be erased'
    Check 'G10 preview on a stick with files says it holds data (Rescue offered)' { $p = Format-UsbDrive -DiskNumber $n7 -Preview; if (-not $p.HasFiles -or $p.Phrase -ne "ERASE $n7") { throw ($p | Out-String) }; "HasFiles=$($p.HasFiles) Phrase=$($p.Phrase)" }
    Check 'G11 CLI -Format -PreviewOnly (no change)' { $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -Format -Disk $n7 -FileSystem exFAT -PreviewOnly -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($o -notmatch 'PREPARE, NOT A REPAIR' -or -not (Test-Path "${LP}:\keep.txt")) { throw $o }; 'plan printed, file still there' }
    Check 'G12 format exFAT / GPT' { $r = Format-UsbDrive -DiskNumber $n7 -FileSystem exFAT -Label UDEXFAT -PartitionStyle GPT -ConfirmPhrase "ERASE $n7"; $dk = Get-Disk -Number $n7; $ps = @(Get-Partition -DiskNumber $n7 | Where-Object { Get-PartLetter $_ }); $script:gptGuids += @(Get-Partition -DiskNumber $n7 | ForEach-Object { "$($_.Guid)" }); if ($r.FileSystem -ne 'exFAT' -or $dk.PartitionStyle -ne 'GPT' -or $ps.Count -ne 1 -or ($ps[0].Offset % 1MB)) { throw ($r | Out-String) }; "$($r.Letter): exFAT GPT, data partition at $($ps[0].Offset)" }
    Check 'G13 format FAT32 / MBR (Auto style)' { $r = Format-UsbDrive -DiskNumber $n7 -FileSystem FAT32 -Label UDFAT -ConfirmPhrase "ERASE $n7"; $dk = Get-Disk -Number $n7; [void]$sigs.Add([uint32]$dk.Signature); if ($r.FileSystem -ne 'FAT32' -or $dk.PartitionStyle -ne 'MBR') { throw ($r | Out-String) }; "$($r.Letter): FAT32 MBR $($r.Size) bytes" }
    $vb = Join-Path $T "ud-big-$script:runId.vhd"; DP @("create vdisk file=`"$vb`" maximum=40960 type=expandable", "select vdisk file=`"$vb`"", 'attach vdisk') | Out-Null; Start-Sleep 3
    $vhds += [pscustomobject]@{ File = $vb; Number = (Get-VhdNumber $vb) }; $nb = Get-VhdNumber $vb
    Check 'G14 FAT32 on a 40 GB disk refused with a clear message' { Format-UsbDrive -DiskNumber $nb -FileSystem FAT32 -Preview } 'only up to 32 GB'
    Check 'G15 FAT32 with -SizeMB 32000 on the 40 GB disk: plan OK' { $p = Format-UsbDrive -DiskNumber $nb -FileSystem FAT32 -SizeMB 32000 -Preview; if ($p.Phrase -ne "ERASE $nb") { throw ($p | Out-String) }; 'plan OK' }
    Check 'G16 exFAT on the 40 GB disk: plan OK (MBR auto)' { $p = Format-UsbDrive -DiskNumber $nb -FileSystem exFAT -Preview; ($p.Text -join ' ') -match 'MBR' }
    # wipe
    Check 'G17 wipe refused with wrong phrase' { Clear-UsbDrive -DiskNumber $n7 -Passes Zero -ConfirmPhrase "ERASE 99" } 'type ERASE'
    Check 'G18 wipe Zero + verify' { $r = Clear-UsbDrive -DiskNumber $n7 -Passes Zero -ConfirmPhrase "ERASE $n7"; Update-HostStorageCache; $pc = @(Get-Partition -DiskNumber $n7 -ErrorAction SilentlyContinue).Count; $b = Read-DiskBytes $n7 0 1MB; $nz = @($b | Where-Object { $_ -ne 0 } | Select-Object -First 1).Count; if ($r.Status -ne 'done' -or $r.BadSamples -or $pc -or $nz -or $r.Bytes -ne (Get-Disk -Number $n7).Size) { throw ($r | Out-String) + " parts=$pc nonzero=$nz" }; "$($r.Bytes) bytes, $($r.Verified) samples OK, $($r.MBps) MB/s, no partitions" }
    Check 'G19 wipe Random + verify (first MiB zeroed at the end)' { $r = Clear-UsbDrive -DiskNumber $n7 -Passes Random -ConfirmPhrase "ERASE $n7"; $b = Read-DiskBytes $n7 0 1MB; $nz = @($b | Where-Object { $_ -ne 0 } | Select-Object -First 1).Count; $mid = Read-DiskBytes $n7 (48MB) 4096; $nzm = @($mid | Where-Object { $_ -ne 0 }).Count; if ($r.Status -ne 'done' -or $r.BadSamples -or $nz -or $nzm -lt 3000) { throw ($r | Out-String) + " first-MiB-nonzero=$nz mid-nonzero=$nzm" }; "$($r.Verified) samples OK; mid-disk random ($nzm/4096 non-zero bytes); first MiB zero" }
    Check 'G20 CLI -Wipe -PreviewOnly mentions wear leveling' { $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -Wipe -Disk $n7 -Passes Zero -PreviewOnly -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($o -notmatch 'wear') { throw $o }; 'plan printed with wear-leveling note' }
    # bootable: raw (synthetic hybrid ISO)
    $iso = Join-Path $T 'ud-hybrid.iso'; $ib = New-Object byte[] (8MB + 1536); (New-Object Random 7).NextBytes($ib); $ib[510] = 0x55; $ib[511] = 0xAA; [Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($ib, 32769); [IO.File]::WriteAllBytes($iso, $ib)
    $isoHash = (Get-FileHash $iso -Algorithm SHA256).Hash
    Check 'G21 bootable: SHA-256 mismatch refused, nothing written' { New-BootableUsb -IsoPath $iso -DiskNumber $n7 -Sha256 ('0' * 64) -ConfirmPhrase "ERASE $n7" } 'SHA-256 mismatch'
    Check 'G22 bootable raw: hybrid ISO written + read-back verified' { $r = New-BootableUsb -IsoPath $iso -DiskNumber $n7 -Sha256 $isoHash -ConfirmPhrase "ERASE $n7"; $b = Read-DiskBytes $n7 0 (8MB + 1536); $same = [Linq.Enumerable]::SequenceEqual([byte[]]$b, [byte[]]$ib); if ($r.Mode -ne 'Raw' -or -not $r.Verified -or -not $same) { throw ($r | Out-String) + " independent compare=$same" }; "Raw, $($r.Bytes) bytes, verified; independent compare OK" }
    $bigIso = Join-Path $T 'ud-toobig.iso'; $fs = [IO.File]::Create($bigIso); $fs.SetLength(200MB); $fs.Close()
    Check 'G23 bootable raw: ISO bigger than the stick refused' { New-BootableUsb -IsoPath $bigIso -DiskNumber $n7 -Mode Raw -Preview } 'bigger than the stick'
    Check 'G24 bootable: non-hybrid, non-Windows image refused' { New-BootableUsb -IsoPath (Join-Path $T 'ud-small.iso') -DiskNumber $n7 -ConfirmPhrase "ERASE $n7" } 'REFUSED'
    # bootable: Windows mode from a fake installer (source VHD with a real small install.wim, split at 1 MB)
    $vs = New-TestVhd 'ud-winsrc' 128 120 'ntfs' 'WINSRC'; $vhds += $vs; [void]$sigs.Add([uint32](Get-Disk -Number $vs.Number).Signature); $LS = Get-Letter $vs.Number; Say "Windows source VHD disk $($vs.Number) at ${LS}:"
    $cap = Join-Path $T 'ud-capture'; New-Item -ItemType Directory -Force "$cap\data" | Out-Null; $rb = New-Object byte[] 3MB; (New-Object Random 11).NextBytes($rb); [IO.File]::WriteAllBytes("$cap\data\random.bin", $rb); Set-Content "$cap\readme.txt" 'fake windows image'
    New-Item -ItemType Directory -Force "${LS}:\sources", "${LS}:\efi\boot", "${LS}:\boot" | Out-Null
    Set-Content "${LS}:\bootmgr" 'fake bootmgr'; Set-Content "${LS}:\efi\boot\bootx64.efi" 'fake efi'; Set-Content "${LS}:\sources\boot.wim" 'fake boot.wim'; Set-Content "${LS}:\setup.exe" 'fake setup'
    $dz = & dism.exe /Capture-Image /ImageFile:"${LS}:\sources\install.wim" /CaptureDir:"$cap" /Name:UDTest /Compress:none 2>&1 | Out-String
    Check 'G25 test install.wim captured with DISM' { if (-not (Test-Path "${LS}:\sources\install.wim")) { throw $dz }; "install.wim $((Get-Item "${LS}:\sources\install.wim").Length) bytes" }
    DP @("select vdisk file=`"$($vs.File)`"", 'detach vdisk') | Out-Null; Start-Sleep 2
    Check 'G26 bootable Windows (FAT32, install.wim split to .swm at 1 MB)' { $r = New-BootableUsb -IsoPath $vs.File -DiskNumber $n7 -Mode Windows -Label UDWIN -SplitThresholdBytes 1MB -ConfirmPhrase "ERASE $n7"; [void]$sigs.Add([uint32](Get-Disk -Number $n7).Signature); $L = $r.Letter; $swm = @(Get-ChildItem "${L}:\sources" -Filter 'install*.swm'); $pa = Get-Partition -DiskNumber $n7 | Select-Object -First 1; if ($r.Status -ne 'done' -or -not $r.Verified -or $swm.Count -lt 2 -or (Test-Path "${L}:\sources\install.wim") -or -not (Test-Path "${L}:\bootmgr") -or -not (Test-Path "${L}:\efi\boot\bootx64.efi") -or -not $pa.IsActive -or (Get-Volume -DriveLetter $L).FileSystemType -ne 'FAT32') { throw ($r | Out-String) + " swm=$($swm.Count) active=$($pa.IsActive)" }; "$($r.Files) files, $($swm.Count) swm parts, active FAT32, bootsect: $($r.BootSect)" }
    Check 'G27 swm parts are a valid split image (dism /Get-WimInfo)' { $L = Get-Letter $n7; $o = & dism.exe /Get-WimInfo /WimFile:"${L}:\sources\install.swm" 2>&1 | Out-String; if ($o -notmatch 'UDTest') { throw $o }; 'DISM reads install.swm: UDTest' }
    # benchmark on the VHD
    Check 'G28 format exFAT for the benchmark' { $r = Format-UsbDrive -DiskNumber $n7 -FileSystem exFAT -Label UDBENCH -ConfirmPhrase "ERASE $n7"; [void]$sigs.Add([uint32](Get-Disk -Number $n7).Signature); $script:LB = $r.Letter; "$($r.Letter): exFAT" }
    Check 'G29 benchmark file mode (16 MB, verified, temp file deleted)' { if (-not $script:LB) { throw 'no benchmark letter: G28 (format) failed first' }; $r = Invoke-UsbBenchmark -Letter $script:LB -SizeMB 16 -RandomSeconds 2 -MaxRandomOps 500; $left = @(Get-ChildItem "$($script:LB):\" -Filter 'USBDoctor-bench-*' -Force).Count; if ($r.Integrity -notmatch 'read back correctly' -or $left) { throw ($r | Out-String) }; "read $($r.SeqReadMBs) MB/s, write $($r.SeqWriteMBs) MB/s, 4K $($r.RandRead4kIops)/$($r.RandWrite4kIops) IOPS" }
    Check 'G30 benchmark second run compared with history' { if (-not $script:LB) { throw 'no benchmark letter: G28 (format) failed first' }; $r = Invoke-UsbBenchmark -Letter $script:LB -SizeMB 16 -RandomSeconds 2 -MaxRandomOps 500; $id = (UD $n7).Identity; $h = Get-DeviceHistoryRecord $id; if (@($h.Benchmarks).Count -lt 2 -or $r.Comparison -match 'First benchmark') { throw ($r | Out-String) }; "$(@($h.Benchmarks).Count) runs recorded; $($r.Comparison)" }
    Check 'G31 benchmark refused when too little free space' { if (-not $script:LB) { throw 'no benchmark letter: G28 (format) failed first' }; Invoke-UsbBenchmark -Letter $script:LB -SizeMB 512 } 'Not enough free space'
    Check 'G32 benchmark -ReadOnly raw (nothing written)' { $before = (Get-FileHash -InputStream ([IO.MemoryStream]::new([byte[]](Read-DiskBytes $n7 0 1MB)))).Hash; $r = Invoke-UsbBenchmark -DiskNumber $n7 -ReadOnly -SizeMB 32 -RandomSeconds 2 -MaxRandomOps 500; $after = (Get-FileHash -InputStream ([IO.MemoryStream]::new([byte[]](Read-DiskBytes $n7 0 1MB)))).Hash; if ($r.Mode -ne 'Raw' -or $before -ne $after -or $r.Integrity -notmatch 'No read errors') { throw ($r | Out-String) }; "raw read $($r.SeqReadMBs) MB/s, 4K $($r.RandRead4kIops) IOPS, first MiB unchanged" }
    Check 'G33 CLI -Benchmark -Letter on the VHD' { if (-not $script:LB) { throw 'no benchmark letter: G28 (format) failed first' }; $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -Benchmark -Letter $script:LB -SizeMB 16 -NoElevate -AllowVirtual -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($LASTEXITCODE -ne 0 -or $o -notmatch 'read back correctly') { throw $o }; 'CLI benchmark OK' }
    # recovery from a rescue image
    $vr = New-TestVhd 'ud-recsrc' 64 60 'ntfs' 'UDREC'; $vhds += $vr; $nr = $vr.Number; [void]$sigs.Add([uint32](Get-Disk -Number $nr).Signature); $LR = Get-Letter $nr
    New-Item -ItemType Directory -Force "${LR}:\photos" | Out-Null; Set-Content "${LR}:\notes.txt" 'recover me'; [IO.File]::WriteAllBytes("${LR}:\photos\img.bin", $rb); Write-VolumeCache -DriveLetter $LR
    $rimg = Join-Path $T 'ud-recsrc.img'; Remove-Item $rimg, "$rimg.rescue.json" -Force -ErrorAction SilentlyContinue
    Check 'G34 rescue image of the recovery source' { $r = Start-UsbRescue -DiskNumber $nr -OutFile $rimg -WaitMinutes 1; if ($r.Status -ne 'done') { throw ($r | Out-String) }; "$($r.Position) bytes imaged" }
    DP @("select vdisk file=`"$($vr.File)`"", 'detach vdisk') | Out-Null; Start-Sleep 2
    $rh = (Get-FileHash $rimg -Algorithm SHA256).Hash; $rout = Join-Path $T 'ud-recovered'
    Check 'G35 recovery preview (PhotoRec presence or download link)' { $p = Invoke-ImageRecovery -Image $rimg -OutDir $rout -Preview; $t = ($p | Out-String); if ($t -notmatch 'cgsecurity|photorec') { throw $t }; 'preview OK' }
    Check 'G36 recovery copies the files; image unchanged, no wrap left' { $r = Invoke-ImageRecovery -Image $rimg -OutDir $rout; $f = @(Get-ChildItem $rout -Recurse -File | Where-Object { $_.Name -in 'notes.txt', 'img.bin' }); $h2 = (Get-FileHash $rimg -Algorithm SHA256).Hash; $left = @(Get-ChildItem $T -Filter 'ud-recsrc.img.usbdoctor*').Count + @(Get-ChildItem $env:TEMP, $rout -Filter 'usbdoctor-overlay-*' -ErrorAction SilentlyContinue).Count; $pf = @(Get-ChildItem $rout -Directory -Force | Where-Object Name -like 'part*'); $hid = @($pf | Where-Object { $_.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System) }).Count; if ($f.Count -ne 2 -or $h2 -ne $rh -or $left -or -not $r.ImageUnchanged -or -not $pf.Count -or $hid) { throw ($r | Out-String) + " files=$($f.Count) hashSame=$($h2 -eq $rh) leftovers=$left partFolders=$($pf.Count) hiddenOrSystem=$hid ($(($pf | ForEach-Object { "$($_.Name)=$($_.Attributes)" }) -join ', '))" }; "$($r.FilesCopied) files copied; part folder visible; image hash unchanged; wrap and overlay removed; $(@($r.Partitions) -join '; ')" }
    Check 'G36b recovery through the overlay (-ForceOverlay): files, image unchanged, overlay deleted' { $ro = Join-Path $T 'ud-recovered-ov'; Remove-Item $ro -Recurse -Force -ErrorAction SilentlyContinue; $r = Invoke-ImageRecovery -Image $rimg -OutDir $ro -ForceOverlay; $f = @(Get-ChildItem $ro -Recurse -File | Where-Object { $_.Name -in 'notes.txt', 'img.bin' }); $txt = (Get-ChildItem $ro -Recurse -Filter notes.txt | Select-Object -First 1 | Get-Content); $h2 = (Get-FileHash $rimg -Algorithm SHA256).Hash; $left = @(Get-ChildItem $T -Filter 'ud-recsrc.img.usbdoctor*').Count + @(Get-ChildItem $env:TEMP, $ro -Filter 'usbdoctor-overlay-*' -ErrorAction SilentlyContinue).Count; $ov = (@($r.Partitions) -join '; ') -match 'overlay'; if ($f.Count -ne 2 -or $txt -ne 'recover me' -or $h2 -ne $rh -or $left -or -not $r.ImageUnchanged -or -not $ov) { throw ($r | Out-String) + " files=$($f.Count) text=$txt hashSame=$($h2 -eq $rh) leftovers=$left overlayUsed=$ov" }; "$($r.FilesCopied) files via overlay; image hash unchanged; overlay deleted" }
    # an image taken while the volume is mounted and unflushed (like run 5): NTFS may need a journal replay -> automatic overlay
    $vd = New-TestVhd 'ud-recdirty' 64 60 'ntfs' 'UDDIRTY'; $vhds += $vd; [void]$sigs.Add([uint32](Get-Disk -Number $vd.Number).Signature); $LD = Get-Letter $vd.Number
    Set-Content "${LD}:\dirty.txt" 'dirty'; $dimg = Join-Path $T 'ud-recdirty.img'; Remove-Item $dimg, "$dimg.rescue.json" -Force -ErrorAction SilentlyContinue; $null = Start-UsbRescue -DiskNumber $vd.Number -OutFile $dimg -WaitMinutes 1
    DP @("select vdisk file=`"$($vd.File)`"", 'detach vdisk') | Out-Null; Start-Sleep 2
    Check 'G36c recovery of an image taken from a mounted, unflushed volume (overlay used if Windows needs it)' { $dh = (Get-FileHash $dimg -Algorithm SHA256).Hash; $ro = Join-Path $T 'ud-recovered-dirty'; Remove-Item $ro -Recurse -Force -ErrorAction SilentlyContinue; $r = Invoke-ImageRecovery -Image $dimg -OutDir $ro; $pt = @($r.Partitions) -join '; '; $left = @(Get-ChildItem $T -Filter 'ud-recdirty.img.usbdoctor*').Count + @(Get-ChildItem $env:TEMP, $ro -Filter 'usbdoctor-overlay-*' -ErrorAction SilentlyContinue).Count; if ($pt -match 'no readable file system' -or $left -or -not $r.ImageUnchanged -or (Get-FileHash $dimg -Algorithm SHA256).Hash -ne $dh) { throw ($r | Out-String) + " leftovers=$left" }; $(if ($pt -match 'overlay') { "journal replay needed: read through the overlay; $pt" } else { "image came out clean, overlay trigger NOT exercised this run; $pt" }) }
    Check 'G37 recovered file content matches' { (Get-ChildItem $rout -Recurse -Filter notes.txt | Select-Object -First 1 | Get-Content) -eq 'recover me' }
    Check 'G38 CLI -Recover -PreviewOnly' { $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ps1 -Recover -Image $rimg -OutDir $rout -PreviewOnly -NoElevate -LogFile $log -HistoryFile $TH 2>&1 | Out-String; if ($o -notmatch 'image') { throw $o }; 'plan printed' }
    # port map, watch (dry run only: never installs the task)
    Check 'G39 port map elevated (controllers found, text + HTML)' { $m = Get-UsbPortMap; $txt = Format-UsbPortMap $m; $html = ConvertTo-UsbPortMapHtml $m; if (-not @($m.Controllers).Count -or -not $html) { throw 'no controllers' }; "$(@($m.Controllers).Count) controller(s), $(@($txt).Count) text lines" }
    Check 'G40 watch dry run with the test history (no write, no task)' { $hb = (Get-FileHash $TH).Hash; $r = Invoke-UsbHealthWatch -DryRun; $i = Install-UsbHealthWatch -ScriptPath $ps1 -DryRun; $ha = (Get-FileHash $TH).Hash; $t = Get-ScheduledTask -TaskName 'USBDoctor Health Watch' -ErrorAction SilentlyContinue; if (-not $r.DryRun -or $hb -ne $ha -or $t) { throw "dry=$($r.DryRun) same=$($hb -eq $ha) task=$([bool]$t)" }; "$($r.DevicesSeen) devices, $($r.Alerts) alerts; history unchanged; task not registered" }
} catch {
    $script:fail++; Say "FAIL  harness: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
} finally {
    Say '=== Cleanup'
    foreach ($v in $vhds) { try { DP @("select vdisk file=`"$($v.File)`"", 'detach vdisk noerr') | Out-Null } catch { Say "detach $($v.File): $($_.Exception.Message)" } }
    Start-Sleep 2
    $mv = Get-Item HKLM:\SYSTEM\MountedDevices; $removed = 0
    foreach ($n in $mv.GetValueNames()) {
        $b = $mv.GetValue($n)
        $hit = ($b -is [byte[]] -and $b.Length -eq 12 -and $sigs.Contains([BitConverter]::ToUInt32($b, 0))) -or ($b -is [byte[]] -and [Text.Encoding]::Unicode.GetString($b) -like '*Ven_Fake&Prod_TestStick*')
        if (-not $hit -and $b -is [byte[]] -and $b.Length -ge 24 -and [Text.Encoding]::ASCII.GetString($b, 0, 8) -eq 'DMIO:ID:') { $g = "{$(New-Object Guid (, [byte[]]($b[8..23])))}"; $hit = $gptGuids -contains $g }
        if ($hit) { Remove-ItemProperty -Path HKLM:\SYSTEM\MountedDevices -Name $n; $removed++ }
    }
    Say "Removed $removed MountedDevices test entries (signatures: $(($sigs | % { $_.ToString('X8') }) -join ','); GPT partitions: $($gptGuids.Count))"
    Get-ChildItem $T -Recurse -File | Where-Object { $_.Extension -in '.vhd', '.img', '.bin', '.iso', '.wim', '.swm' -or $_.Name -like '*.usbdoctor-vhdwrap.json' -or $_.Name -like '*.rescue.json' -or $_.Name -like '*.badranges.txt' -or $_.Name -like 'history-test.json*' } | ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { Start-Sleep 3; Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue } }
    foreach ($dd in 'ud-capture', 'ud-recovered', 'ud-recovered-ov', 'ud-recovered-dirty') { $pp = Join-Path $T $dd; if (Test-Path $pp) { Remove-Item $pp -Recurse -Force -ErrorAction SilentlyContinue; Say "removed $dd" } }
    $bk = Join-Path (Get-DefaultDataDir) 'USBDoctor-Backups'
    Get-ChildItem $bk -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^disk\d+-(part\d+-bootsector|gpt-sectors)' -and $_.LastWriteTime -gt (Get-Date).AddHours(-2) } | ForEach-Object { Say "removed test backup $($_.Name)"; Remove-Item $_.FullName -Force }
    Say "Leftover VHD/IMG files: $(@(Get-ChildItem $T -Recurse -File | Where-Object { $_.Extension -in '.vhd', '.img' }).Count)"
    Say "Virtual disks still attached: $(@(Get-Disk | Where-Object BusType -eq 'File Backed Virtual').Count)"
    Say "DONE pass=$script:pass fail=$script:fail $(Get-Date -Format s)"
    try { Stop-Transcript | Out-Null } catch {}
}
