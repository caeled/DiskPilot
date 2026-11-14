# USBDoctor elevated test: recovery section only (G34-G38), same helpers and cleanup as run-tests.ps1. Real drives are not touched.
param([string]$AppDir = '\\FILESERVER\Share\research\MyApps\Partition\USBDoctor', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$T = 'C:\ProgramData\USBDoctor\test'
$sfx = '-recovery'
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
    Say '=== G. Recovery from a rescue image (recovery-only run)'
    Set-UDConfig -LogFile $log -AllowVirtual -HistoryFile $TH
    Remove-Item $TH -Force -ErrorAction SilentlyContinue
    $rb = New-Object byte[] 3MB; (New-Object Random 11).NextBytes($rb)
    # recovery from a rescue image
    $vr = New-TestVhd 'ud-recsrc' 64 60 'ntfs' 'UDREC'; $vhds += $vr; $nr = $vr.Number; [void]$sigs.Add([uint32](Get-Disk -Number $nr).Signature); $LR = Get-Letter $nr
    New-Item -ItemType Directory -Force "${LR}:\photos" | Out-Null; Set-Content "${LR}:\notes.txt" 'recover me'; [IO.File]::WriteAllBytes("${LR}:\photos\img.bin", $rb); Write-VolumeCache -DriveLetter $LR
    Remove-Item (Join-Path $T 'ud-recovered') -Recurse -Force -ErrorAction SilentlyContinue
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
