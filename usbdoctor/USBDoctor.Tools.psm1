# USBDoctor.Tools.psm1 - "Prepare & Tools" for USBDoctor. These are NOT repairs.
# Format, wipe and the bootable-USB maker ERASE the whole drive (typed ERASE N). They are destinations you choose, never a fix
# USBDoctor proposes for a problem: the repair side (USBDoctor.Core.psm1) still contains no format code at all.
# Benchmark, file recovery, health watch and the port map change no drive (the benchmark writes and deletes one temp file).
# Windows PowerShell 5.1.
if (-not (Get-Command Get-RepairDisk -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'USBDoctor.Core.psm1') -DisableNameChecking -Global }
$script:LabelsFile = Join-Path $env:ProgramData 'USBDoctor\port-labels.json'
$script:Fat32MaxBytes = [int64]32GB          # Windows' own FAT32 formatter refuses bigger volumes
$script:Fat32BootMB = 32000                  # FAT32 partition size used for big sticks (bootable maker, -SizeMB hint)
$script:TaskName = 'USBDoctor Health Watch'
$script:CgsUrl = 'https://www.cgsecurity.org/wiki/TestDisk_Download'

function Set-UDToolsConfig { param([string]$LabelsFile) if ($LabelsFile) { $script:LabelsFile = $LabelsFile } }
function Get-PrepareCommands { @('Format-UsbDrive', 'Clear-UsbDrive', 'New-BootableUsb') }

# ------------------------------------------------------------------ common gate for Prepare (format / wipe / bootable)
function Get-PrepareDisk([int]$Number, [string]$What) {
    # USB only (Get-RepairDisk refuses C:, D:, Windows, boot, pagefile and non-USB disks), never a dying or counterfeit drive.
    $d = Get-RepairDisk $Number
    $g = Get-GateStatus $d 'Prepare'
    if ($g.Refusal) { throw "REFUSED on disk ${Number}: $What is not done on a drive that is $($g.Refusal)" }
    $rec = Get-DeviceHistoryRecord $d.Identity
    if ($rec -and $rec.Counterfeit) { throw "REFUSED on disk ${Number}: this stick failed the capacity test (counterfeit; real size about $(Format-Bytes ([int64]$rec.Counterfeit.GoodBytes)) of $(Format-Bytes ([int64]$rec.Counterfeit.Claimed))). $What would put data on flash that isn't there. Condemn it." }
    if ($d.ReadOnly) { throw "REFUSED on disk ${Number}: the disk is write-protected (read-only). See #8: clear it once with -ClearReadOnly; if it returns, the flash is worn out." }
    $bl = Test-DiskBlank $d
    [pscustomobject]@{ Disk = $d; Gate = $g; Blank = $bl; Image = (Get-DeviceImage $d.Identity) }
}

function Get-PrepareDataText($pd) {
    $d = $pd.Disk
    $t = @("Now on it: $($d.Summary).")
    if ($pd.Blank.Blank) { $t += "It looks empty ($($pd.Blank.Why))." }
    else {
        $t += "IT HOLDS DATA ($($pd.Blank.Why)). Everything on it is lost and cannot be recovered afterwards."
        if ($pd.Image) { $t += "A Rescue image of this drive is on file: $($pd.Image.Path) ($($pd.Image.Time))." }
        else { $t += "No Rescue image of this drive exists. Make one first (Rescue copy / -Rescue -Disk $($d.Number)) unless you are sure nothing on it matters." }
    }
    $t
}

function New-ErasePlan([string]$Action, [string]$Title, [string[]]$Text, $pd) {
    $p = New-Plan $Action $Title ($Text + @('', "Type ERASE $($pd.Disk.Number) to confirm.")) $true $pd.Disk.Number
    $p.Phrase = "ERASE $($pd.Disk.Number)"
    $p | Add-Member NoteProperty HasFiles ([bool](-not $pd.Blank.Blank -and -not $pd.Image))
    $p | Add-Member NoteProperty Prepare $true
    $p
}

function Assert-ErasePhrase([int]$Number, [string]$Phrase) {
    if ("$Phrase".Trim() -cne "ERASE $Number") { throw "Not confirmed: type ERASE $Number exactly. Nothing was written." }
}

function Get-NewPartitionLetter([int]$Number) {
    for ($i = 0; $i -lt 10; $i++) {
        try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch {}
        $p = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue | Where-Object { Get-PartLetter $_ }) | Select-Object -First 1
        if ($p) { return (Get-PartLetter $p) }
        Start-Sleep -Milliseconds 700
    }
    ''
}

function Assert-DiskEmptied([int]$Number) {
    # diskpart said it emptied the disk; check that Windows now really sees no partitions before anything else is written.
    $left = @()
    for ($i = 0; $i -lt 10; $i++) {
        try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch {}
        $left = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue)
        if (-not $left.Count) { return }
        Start-Sleep -Milliseconds 700
    }
    throw "diskpart reported success, but disk $Number still shows $($left.Count) partition(s). Nothing more was written; check Disk Management."
}

function Get-SourceFiles([string]$Root) {
    # Every file under $Root, skipping Windows' own per-volume folders: they are never part of an installer and
    # reading them is access-denied ('System Volume Information', '$RECYCLE.BIN').
    $skip = @('System Volume Information', '$RECYCLE.BIN')
    $q = New-Object System.Collections.Generic.Queue[string]; $q.Enqueue($Root)
    while ($q.Count) {
        $dir = $q.Dequeue()
        foreach ($i in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
            if ($i.PSIsContainer) { if ($i.Name -notin $skip) { $q.Enqueue($i.FullName) } } else { $i }
        }
    }
}

function Test-FatLabel([string]$Label, [string]$Fs) {
    if ($Label -match '["*?/\\|<>]') { throw "The label '$Label' contains a character Windows does not allow in volume labels." }
    if ($Fs -in 'FAT32', 'exFAT' -and $Label.Length -gt 11) { throw "$Fs labels are at most 11 characters ('$Label' has $($Label.Length))." }
    if ($Fs -eq 'NTFS' -and $Label.Length -gt 32) { throw "NTFS labels are at most 32 characters." }
    if ($Fs -eq 'FAT32' -and $Label -match '[\.,;:+=\[\]]') { throw "FAT32 labels can't contain . , ; : + = [ ]" }
}

# ------------------------------------------------------------------ 1. Format / Prepare
function Format-UsbDrive {
    # PREPARE, NOT A REPAIR: erase the whole stick and give it one new, empty, full-size partition (1 MiB aligned).
    param([int]$DiskNumber, [ValidateSet('NTFS', 'exFAT', 'FAT32')][string]$FileSystem = 'exFAT', [string]$Label = 'USB', [string]$Letter,
        [ValidateSet('Auto', 'MBR', 'GPT')][string]$PartitionStyle = 'Auto', [int]$SizeMB = 0, [string]$ConfirmPhrase, [switch]$Preview)
    $pd = Get-PrepareDisk $DiskNumber 'Formatting'
    $d = $pd.Disk
    $Label = "$Label".Trim(); if (-not $Label) { $Label = 'USB' }
    Test-FatLabel $Label $FileSystem
    if ($Letter) {
        $Letter = $Letter.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
        if ($Letter -notmatch '^[D-Z]$') { throw "Use a drive letter from D to Z." }
        $use = Get-LetterUse $Letter
        if ($use -and -not ($d.Volumes | Where-Object { $_.Letter -eq $Letter })) { throw "Letter ${Letter}: is in use ($use). Pick another or leave -Letter out." }
    }
    $style = $PartitionStyle
    if ($style -eq 'Auto') { $style = if ([int64]$d.Size -gt 2TB) { 'GPT' } else { 'MBR' } }
    if ($style -eq 'MBR' -and [int64]$d.Size -gt 2TB) { throw "An MBR partition table can't address more than 2 TB; this disk is $(Format-Bytes $d.Size). Use -PartitionStyle GPT." }
    $avail = [int64]$d.Size - 1MB - $(if ($style -eq 'GPT') { 1MB } else { 0 })
    $part = if ($SizeMB -gt 0) { [int64]$SizeMB * 1MB } else { $avail }
    if ($part -gt $avail) { throw "-SizeMB $SizeMB is larger than the disk allows ($([int64]($avail / 1MB)) MB)." }
    if ($FileSystem -eq 'FAT32' -and $part -gt $script:Fat32MaxBytes) {
        throw ("REFUSED: Windows formats FAT32 only up to 32 GB and this partition would be {0}. Use exFAT (Windows, macOS, most TVs, cars and cameras) or NTFS, or make a smaller FAT32 partition with -SizeMB {1} (the rest stays unallocated). USBDoctor deliberately does not ship its own large-FAT32 formatter." -f (Format-Bytes $part), $script:Fat32BootMB)
    }
    $txt = @("PREPARE, NOT A REPAIR. Formatting is a fresh start you choose; USBDoctor never proposes it as a fix.",
        "This ERASES ALL OF disk $DiskNumber ($($d.Model), $(Format-Bytes $d.Size), $($d.PartitionStyle)).") + @(Get-PrepareDataText $pd) + @('',
        "New layout: new $style partition table, one primary partition of $(Format-Bytes $part) starting at 1 MiB (aligned), $FileSystem, label '$Label', letter $(if ($Letter) { "${Letter}:" } else { 'chosen by Windows' }).")
    if ($style -eq 'MBR') { $txt += 'MBR is the most compatible choice for USB sticks (TVs, cars, older PCs, cameras).' }
    switch ($FileSystem) {
        'exFAT' { $txt += 'exFAT: no 4 GB file limit; read/write on Windows and macOS, most TVs and car stereos.' }
        'NTFS' { $txt += 'NTFS: best for Windows-only use; macOS reads it but cannot write, many TVs and cars cannot read it.' }
        'FAT32' { $txt += 'FAT32: most compatible, but no single file can be 4 GB or larger.' }
    }
    if ($Preview) { return New-ErasePlan 'Format' 'Format / prepare drive (erases everything)' $txt $pd }
    Assert-ErasePhrase $DiskNumber $ConfirmPhrase
    Assert-Admin 'Formatting'
    $d = Assert-SameDisk $d
    Write-UDLog "=== PREPARE format disk $DiskNumber $($d.Model): $style, $FileSystem '$Label', $(Format-Bytes $part)"
    $lines = @("select disk $DiskNumber", 'online disk noerr', 'clean', "convert $($style.ToLower())",
        $(if ($SizeMB -gt 0) { "create partition primary size=$SizeMB align=1024" } else { 'create partition primary align=1024' }),
        "format fs=$($FileSystem.ToLower()) quick label=""$Label""", $(if ($Letter) { "assign letter=$Letter" } else { 'assign' }))
    [void](Invoke-Diskpart $lines)
    $L = Get-NewPartitionLetter $DiskNumber
    $v = $null; if ($L) { $v = Get-Volume -DriveLetter $L -ErrorAction SilentlyContinue }
    if (-not $v -or "$($v.FileSystemType)" -ne $FileSystem) { throw "diskpart finished but the new $FileSystem volume did not appear as expected (letter '$L', file system '$(if ($v) { $v.FileSystemType })'). Check Disk Management." }
    Update-DeviceHistory $d.Identity $d.Model { param($x) $x.Prepared = @(@($x.Prepared) + @(@{ Time = (Get-Date).ToString('s'); Action = 'Format'; FileSystem = $FileSystem; Style = $style; Size = [int64]$v.Size })) } | Out-Null
    Write-UDLog "=== Format OK: ${L}: $FileSystem '$($v.FileSystemLabel)' $(Format-Bytes $v.Size)"
    [pscustomobject]@{ Disk = $DiskNumber; Letter = $L; FileSystem = "$($v.FileSystemType)"; Label = "$($v.FileSystemLabel)"; Size = [int64]$v.Size; PartitionStyle = $style }
}

# ------------------------------------------------------------------ 3. Secure wipe
function Clear-UsbDrive {
    # PREPARE, NOT A REPAIR: one pass of zeros or pseudo-random data over every byte, then a verify sample.
    param([int]$DiskNumber, [ValidateSet('Zero', 'Random')][string]$Passes = 'Zero', [int]$VerifySamples = 64, [string]$ConfirmPhrase, [switch]$Preview, $Control)
    $pd = Get-PrepareDisk $DiskNumber 'Wiping'
    $d = $pd.Disk
    $txt = @("PREPARE, NOT A REPAIR. A wipe is for retiring or giving away a stick, never a fix.",
        "This ERASES ALL OF disk $DiskNumber ($($d.Model), $(Format-Bytes $d.Size)): one pass of $(if ($Passes -eq 'Zero') { 'zeros' } else { 'pseudo-random data' }) over every byte, then $VerifySamples random 1 MiB samples plus the first and last MiB are read back and checked.") + @(Get-PrepareDataText $pd) + @('',
        'LIMITS: USB flash sticks remap worn blocks internally (wear-leveling and spare blocks). Old data in blocks the controller has retired can survive any overwrite, and no tool on the PC can reach them. A wipe is NOT guaranteed erasure.',
        'For sensitive data: encrypt the stick from the start (BitLocker To Go / VeraCrypt) so leftovers are unreadable, or physically destroy it.',
        'Afterwards the stick has no partitions; use Format to set it up again.')
    if ($Passes -eq 'Random') { $txt += 'Random mode zeroes the first 1 MiB at the end so Windows sees a clean, blank disk.' }
    if ($Preview) { return New-ErasePlan 'Wipe' "Wipe drive ($Passes, erases everything)" $txt $pd }
    Assert-ErasePhrase $DiskNumber $ConfirmPhrase
    Assert-Admin 'Wiping'
    $d = Assert-SameDisk $d
    $size = [int64]$d.Size; $mode = if ($Passes -eq 'Random') { 1 } else { 0 }; $seed = [uint32](Get-Random -Minimum 1 -Maximum 2147483647)
    Write-UDLog "=== PREPARE wipe disk $DiskNumber $($d.Model) $(Format-Bytes $size), $Passes"
    [void](Invoke-Diskpart @("select disk $DiskNumber", 'online disk noerr', 'clean'))
    Assert-DiskEmptied $DiskNumber
    $sw = [Diagnostics.Stopwatch]::StartNew(); $t = [Diagnostics.Stopwatch]::StartNew(); $done = [int64]0; $slice = [int64]64MB; $status = 'done'
    $h = [UsbDocNative]::OpenDisk($DiskNumber, $true)
    try {
        while ($done -lt $size) {
            if ($Control -and $Control.Cancel) { $status = 'stopped'; break }
            $n = [int64][Math]::Min($slice, $size - $done)
            [UsbDocNative]::WipeSlice($h, $done, $n, $mode, $seed)
            $done += $n
            if ($t.ElapsedMilliseconds -gt 10000 -or $done -eq $size) {
                $mbs = $done / 1MB / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)
                $eta = if ($mbs -gt 0) { [TimeSpan]::FromSeconds(($size - $done) / 1MB / $mbs) } else { [TimeSpan]::Zero }
                Write-UDLog ("Wipe: {0} of {1} ({2:N0}%), {3:N1} MB/s, about {4:hh\:mm\:ss} left" -f (Format-Bytes $done), (Format-Bytes $size), (100.0 * $done / $size), $mbs, $eta); $t.Restart()
            }
        }
        [void][UsbDocNative]::Flush($h)
    } finally { $h.Close() }
    $secs = $sw.Elapsed.TotalSeconds
    $bad = 0; $checked = 0
    if ($status -eq 'done') {
        $blk = [int64]1MB; $nblk = [int64][Math]::Floor($size / $blk)
        $offs = @([int64]0, [int64](($nblk - 1) * $blk)) + @(for ($i = 0; $i -lt $VerifySamples; $i++) { [int64](Get-Random -Minimum 0 -Maximum ([int64]$nblk)) * $blk }) | Sort-Object -Unique
        $r = [UsbDocNative]::OpenDisk($DiskNumber, $false)
        try { foreach ($o in $offs) { $len = [int][Math]::Min($blk, $size - $o); $c = [UsbDocNative]::WipeCheck($r, [int64]$o, $len, $mode, $seed); $checked++; if ($c -ne 0) { $bad++; Write-UDLog "Wipe verify: block at byte $o $(if ($c -eq 2) { 'could not be read' } else { 'did not hold the written data' })" 'WARN' } } } finally { $r.Close() }
        if ($mode -eq 1) { $w = [UsbDocNative]::OpenDisk($DiskNumber, $true); try { [UsbDocNative]::WipeSlice($w, [int64]0, [int64]1MB, 0, $seed); [void][UsbDocNative]::Flush($w) } finally { $w.Close() } }
    }
    try { Update-Disk -Number $DiskNumber -ErrorAction Stop } catch {}
    $verdict = if ($status -ne 'done') { "Stopped after $(Format-Bytes $done). The drive is partly wiped and has no partition table." }
    elseif ($bad) { "Wipe written, but $bad of $checked verify samples came back wrong: the flash is failing or counterfeit. Do not trust it with data; destroy it if the old data was sensitive." }
    else { "Wiped: $checked samples verified. Remember: wear-leveling means retired flash blocks may still hold old data." }
    Write-UDLog "=== Wipe $status`: $verdict" $(if ($bad) { 'WARN' } else { 'INFO' })
    Update-DeviceHistory $d.Identity $d.Model { param($x) $x.Prepared = @(@($x.Prepared) + @(@{ Time = (Get-Date).ToString('s'); Action = "Wipe-$Passes"; Status = $status; BadSamples = $bad })) } | Out-Null
    [pscustomobject]@{ Disk = $DiskNumber; Mode = $Passes; Status = $status; Bytes = $done; Seconds = [int]$secs; MBps = [Math]::Round($done / 1MB / [Math]::Max(0.001, $secs), 1); Verified = $checked; BadSamples = $bad; Verdict = $verdict }
}

# ------------------------------------------------------------------ 4. Bootable USB maker
function Get-IsoKind([string]$Path) {
    # Hybrid ISOs (most Linux installers) carry an MBR in sector 0 and can be written raw. Windows ISOs don't.
    $b = New-Object byte[] 34816
    $fs = [IO.File]::OpenRead($Path); try { $n = $fs.Read($b, 0, $b.Length); $len = $fs.Length } finally { $fs.Close() }
    $mbr = ($n -ge 512 -and $b[510] -eq 0x55 -and $b[511] -eq 0xAA)
    $iso = ($n -ge 32774 -and [Text.Encoding]::ASCII.GetString($b, 32769, 5) -eq 'CD001')
    $vhd = $Path -match '\.vhdx?$'
    [pscustomobject]@{ Path = $Path; Length = [int64]$len; Hybrid = ($mbr -and -not $vhd); Iso9660 = $iso; Vhd = $vhd }
}

function Mount-SourceImage([string]$Path) {
    # Read-only attach of an ISO (or, for tests, a VHD) and return its drive letter.
    $img = Mount-DiskImage -ImagePath $Path -Access ReadOnly -PassThru -ErrorAction Stop
    $L = ''
    for ($i = 0; $i -lt 15 -and -not $L; $i++) {
        Start-Sleep -Milliseconds 600
        if ($Path -match '\.iso$') { $v = $img | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1; if ($v -and $v.DriveLetter) { $L = "$($v.DriveLetter)" } }
        else { $n = (Get-DiskImage -ImagePath $Path).Number; if ($null -ne $n) { $p = @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue | Where-Object { Get-PartLetter $_ }) | Select-Object -First 1; if ($p) { $L = Get-PartLetter $p } } }
    }
    $num = $null; try { $num = (Get-DiskImage -ImagePath $Path).Number } catch {}
    if (-not $L) { try { Dismount-DiskImage -ImagePath $Path | Out-Null } catch {}; throw "Mounted $Path but Windows gave it no drive letter." }
    [pscustomobject]@{ Path = $Path; Letter = $L; DiskNumber = $num }
}

function Test-WindowsMedia([string]$L) {
    $boot = Test-Path "${L}:\sources\boot.wim"
    $inst = @('install.wim', 'install.esd', 'install.swm') | Where-Object { Test-Path "${L}:\sources\$_" } | Select-Object -First 1
    $ldr = (Test-Path "${L}:\bootmgr") -or (Test-Path "${L}:\efi\boot")
    [pscustomobject]@{ IsWindows = ($boot -and $ldr -and [bool]$inst); Install = $inst }
}

function New-BootableUsb {
    # PREPARE, NOT A REPAIR: erase the stick and make it boot an installer ISO.
    param([string]$IsoPath, [int]$DiskNumber, [ValidateSet('Auto', 'Windows', 'Raw')][string]$Mode = 'Auto', [string]$Sha256,
        [ValidateSet('FAT32', 'NTFS')][string]$FileSystem = 'FAT32', [string]$Label, [string]$ConfirmPhrase, [switch]$Preview, $Control,
        [Parameter(DontShow)][int64]$SplitThresholdBytes = 4294967295)
    if (-not $IsoPath -or -not (Test-Path -LiteralPath $IsoPath)) { throw "ISO file '$IsoPath' not found." }
    $IsoPath = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
    if ($Sha256 -and $Sha256.Trim() -notmatch '^[0-9A-Fa-f]{64}$') { throw '-Sha256 must be the 64-character hex SHA-256 published for the ISO.' }
    $pd = Get-PrepareDisk $DiskNumber 'Making a bootable stick'
    $d = $pd.Disk
    if ((Get-DiskNumberOfPath $IsoPath) -eq $DiskNumber) { throw 'The ISO is on the stick that would be erased. Copy it to the PC first.' }
    $k = Get-IsoKind $IsoPath
    $kind = $Mode; $win = $null; $mnt = $null; $note = ''
    if ($kind -eq 'Auto' -and $k.Hybrid) { $kind = 'Raw' }
    if ($kind -in 'Auto', 'Windows') {
        try { $mnt = Mount-SourceImage $IsoPath; $win = Test-WindowsMedia $mnt.Letter }
        catch { $note = "Could not open the ISO to look inside ($($_.Exception.Message))." }
        finally { if ($mnt) { try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch {} } }
        if ($mnt -and $mnt.DiskNumber -eq $DiskNumber) { throw 'Source and target are the same disk.' }
        if ($win -and $win.IsWindows) { $kind = 'Windows' }
        elseif ($kind -eq 'Windows') { if ($win) { throw "REFUSED: $IsoPath is not a Windows installer (no sources\boot.wim + install image + boot loader)." } elseif (-not $Preview) { throw "REFUSED: $note" } }
        elseif ($win) { throw "REFUSED: $IsoPath is neither a hybrid ISO (no MBR in sector 0, so it can't be written raw) nor a Windows installer. Use the distribution's own USB tool." }
        elseif (-not $Preview) { throw "REFUSED: $note" }
    }
    $txt = @("PREPARE, NOT A REPAIR. This ERASES ALL OF disk $DiskNumber ($($d.Model), $(Format-Bytes $d.Size)) and makes it boot:",
        "  $IsoPath ($(Format-Bytes $k.Length))") + @(Get-PrepareDataText $pd) + @('')
    $txt += $(if ($Sha256) { "The ISO's SHA-256 is computed and must equal $($Sha256.ToUpper()) before anything is written." } else { "The ISO's SHA-256 is computed and logged (give -Sha256 to check it against the publisher's value)." })
    switch ($kind) {
        'Raw' {
            if ($k.Length -gt [int64]$d.Size) { throw "REFUSED: the ISO ($(Format-Bytes $k.Length)) is bigger than the stick ($(Format-Bytes $d.Size))." }
            $txt += @('Method: hybrid ISO, written byte-for-byte to the whole stick (like dd), then read back and compared.',
                'The stick then carries the ISO''s own layout; Windows may show only a small partition or none. Use Format afterwards to make it a normal stick again.')
        }
        'Windows' {
            $txt += "Method: Windows installer. New MBR partition table, one active $FileSystem partition, files copied from the mounted ISO, boot code via bootsect if the ISO has it."
            if ($FileSystem -eq 'FAT32') { $txt += "FAT32 boots on both UEFI and legacy BIOS PCs. install.wim larger than 4 GB is split into install.swm parts with DISM (/Split-Image); Windows Setup reads them. The partition is at most $script:Fat32BootMB MB on big sticks (Windows' FAT32 limit)." }
            else { $txt += 'NTFS: no file-size limit and boots on legacy BIOS, but most UEFI firmware cannot boot from NTFS. Rufus adds a small UEFI:NTFS helper partition for that; USBDoctor does not. Prefer FAT32 unless the PC boots in legacy/CSM mode.' }
        }
        default { $txt += "The ISO type is checked when you run it as administrator (opening an ISO needs it). $note Nothing is written unless it is a hybrid ISO or a Windows installer." }
    }
    if ($Preview) { return New-ErasePlan 'MakeBootable' "Make bootable USB ($kind, erases everything)" $txt $pd }
    Assert-ErasePhrase $DiskNumber $ConfirmPhrase
    Assert-Admin 'Making a bootable stick'
    $d = Assert-SameDisk $d
    Write-UDLog "=== PREPARE bootable disk $DiskNumber $($d.Model) from $IsoPath ($kind)"
    Write-UDLog 'Computing the ISO SHA-256...'
    $hash = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash
    Write-UDLog "ISO SHA-256: $hash"
    if ($Sha256 -and $hash -ne $Sha256.Trim().ToUpper()) { throw "REFUSED: SHA-256 mismatch. The ISO is $hash, expected $($Sha256.ToUpper()). The download is damaged or not the file you think. Nothing was written." }
    if ($kind -eq 'Raw') { $r = Write-RawIsoToDisk $IsoPath $DiskNumber $k.Length $Control }
    else { $r = Write-WindowsIsoToDisk $IsoPath $d $FileSystem $Label $SplitThresholdBytes }
    $r | Add-Member NoteProperty Sha256 $hash
    Update-DeviceHistory $d.Identity $d.Model { param($x) $x.Prepared = @(@($x.Prepared) + @(@{ Time = (Get-Date).ToString('s'); Action = "Bootable-$kind"; Iso = (Split-Path $IsoPath -Leaf); Sha256 = $hash; Status = $r.Status })) } | Out-Null
    $r
}

function Write-RawIsoToDisk([string]$IsoPath, [int]$DiskNumber, [int64]$Length, $Control) {
    [void](Invoke-Diskpart @("select disk $DiskNumber", 'online disk noerr', 'clean'))
    Assert-DiskEmptied $DiskNumber
    $sec = 512; $body = [int64]([Math]::Floor($Length / $sec) * $sec); $tail = [int]($Length - $body)
    $fs = [IO.File]::OpenRead($IsoPath)
    $status = 'done'; $sw = [Diagnostics.Stopwatch]::StartNew(); $t = [Diagnostics.Stopwatch]::StartNew()
    try {
        $h = [UsbDocNative]::OpenDisk($DiskNumber, $true)
        try {
            $done = [int64]0
            while ($done -lt $body) {
                if ($Control -and $Control.Cancel) { $status = 'stopped'; break }
                $n = [int64][Math]::Min([int64]64MB, $body - $done)
                [UsbDocNative]::CopyStreamToDisk($fs, $done, $h, $done, $n); $done += $n
                if ($t.ElapsedMilliseconds -gt 10000 -or $done -eq $body) { Write-UDLog ("Writing ISO: {0} of {1}, {2:N1} MB/s" -f (Format-Bytes $done), (Format-Bytes $Length), ($done / 1MB / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds))); $t.Restart() }
            }
            if ($status -eq 'done' -and $tail -gt 0) { $b = New-Object byte[] $tail; $fs.Position = $body; [void]$fs.Read($b, 0, $tail); [UsbDocNative]::WritePadded($h, $body, $b, $tail, $sec) }
            [void][UsbDocNative]::Flush($h)
        } finally { $h.Close() }
        $bad = -1
        if ($status -eq 'done') {
            Write-UDLog 'Reading the stick back and comparing with the ISO...'
            $r = [UsbDocNative]::OpenDisk($DiskNumber, $false)
            try {
                $done = [int64]0
                while ($done -lt $body -and $bad -lt 0) {
                    $n = [int64][Math]::Min([int64]64MB, $body - $done)
                    $bad = [UsbDocNative]::CompareDiskToStream($r, $done, $fs, $done, $n); $done += $n
                }
                if ($bad -lt 0 -and $tail -gt 0) {
                    $a = New-Object byte[] $sec; $e = 0; [void][UsbDocNative]::ReadAt($r, $body, $a, $sec, 30000, [ref]$e)
                    $b = New-Object byte[] $tail; $fs.Position = $body; [void]$fs.Read($b, 0, $tail)
                    for ($i = 0; $i -lt $tail; $i++) { if ($a[$i] -ne $b[$i]) { $bad = $body; break } }
                }
            } finally { $r.Close() }
        }
    } finally { $fs.Close() }
    try { Update-Disk -Number $DiskNumber -ErrorAction Stop } catch {}
    if ($status -ne 'done') { Write-UDLog '=== Bootable stopped: the stick is incomplete and will not boot.' 'WARN'; return [pscustomobject]@{ Disk = $DiskNumber; Mode = 'Raw'; Status = 'stopped'; Verified = $false } }
    if ($bad -ge 0) { throw "Read-back check FAILED at byte ${bad}: the stick did not store what was written. It is failing or counterfeit; don't boot from it." }
    Write-UDLog "=== Bootable OK (raw): $(Format-Bytes $Length) written and verified by read-back."
    [pscustomobject]@{ Disk = $DiskNumber; Mode = 'Raw'; Status = 'done'; Bytes = $Length; Verified = $true; Seconds = [int]$sw.Elapsed.TotalSeconds }
}

function Write-WindowsIsoToDisk([string]$IsoPath, $d, [string]$FileSystem, [string]$Label, [int64]$SplitThresholdBytes) {
    $n = $d.Number
    $mnt = Mount-SourceImage $IsoPath
    try {
        $S = $mnt.Letter
        $files = @(Get-SourceFiles "${S}:\")
        $total = [int64](($files | Measure-Object Length -Sum).Sum)
        $wim = $files | Where-Object { $_.FullName -ieq "${S}:\sources\install.wim" } | Select-Object -First 1
        $split = ($FileSystem -eq 'FAT32' -and $wim -and $wim.Length -gt $SplitThresholdBytes)
        if ($FileSystem -eq 'FAT32') {
            $big = @($files | Where-Object { $_.Length -gt $SplitThresholdBytes -and -not ($split -and $_.FullName -ieq $wim.FullName) })
            if ($big.Count) { throw "REFUSED: $($big[0].FullName.Substring(3)) is $(Format-Bytes $big[0].Length), too big for FAT32 and only install.wim can be split. Use -FileSystem NTFS (see the UEFI note)." }
        }
        $partMB = [int64][Math]::Floor(([int64]$d.Size - 2MB) / 1MB)
        if ($FileSystem -eq 'FAT32' -and $partMB * 1MB -gt $script:Fat32MaxBytes) { $partMB = $script:Fat32BootMB }
        if ($total + 64MB -gt $partMB * 1MB) { throw "REFUSED: the installer needs $(Format-Bytes $total) and the partition would be $(Format-Bytes ($partMB * 1MB))." }
        if (-not $Label) { $Label = 'WINUSB' }
        Test-FatLabel $Label $FileSystem
        Write-UDLog "Windows installer: $($files.Count) files, $(Format-Bytes $total); $FileSystem partition of $partMB MB$(if ($split) { "; install.wim ($(Format-Bytes $wim.Length)) will be split" })"
        [void](Invoke-Diskpart @("select disk $n", 'online disk noerr', 'clean', 'convert mbr', "create partition primary size=$partMB align=1024", 'active',
                "format fs=$($FileSystem.ToLower()) quick label=""$Label""", 'assign'))
        $T = Get-NewPartitionLetter $n
        if (-not $T) { throw 'The new partition got no drive letter.' }
        $rlog = Join-Path (Split-Path (Get-UDLogFile)) 'bootable-robocopy.log'
        $xf = if ($split) { @('/XF', 'install.wim') } else { @() }
        Write-UDLog "Copying files ${S}: -> ${T}: (robocopy log: $rlog)"
        & robocopy.exe "${S}:\" "${T}:\" /E /R:1 /W:1 /A-:R /NP /NFL /NDL /XD 'System Volume Information' '$RECYCLE.BIN' "/LOG:$rlog" @xf | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -ge 8) { throw "robocopy reported failures (exit $rc); see $rlog. The stick is incomplete." }
        if ($split) {
            $mb = [int][Math]::Max(1, [Math]::Min(3800, [Math]::Floor($SplitThresholdBytes / 1MB)))
            Write-UDLog "Splitting install.wim into ${mb} MB install.swm parts (DISM /Split-Image)..."
            $o = & dism.exe /Split-Image "/ImageFile:${S}:\sources\install.wim" "/SWMFile:${T}:\sources\install.swm" "/FileSize:$mb" 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "DISM /Split-Image failed (exit $LASTEXITCODE): $(($o -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')" }
        }
        $bs = "${S}:\boot\bootsect.exe"; $bsNote = 'no boot\bootsect.exe on the ISO (UEFI boot uses efi\boot and does not need it)'
        if (Test-Path $bs) {
            $o = & $bs /nt60 "${T}:" /force 2>&1 | Out-String
            $bsNote = if ($LASTEXITCODE -eq 0) { 'bootsect /nt60 applied (legacy BIOS boot code)' } else { "bootsect failed (exit $LASTEXITCODE; a 64-bit bootsect can't run on 32-bit Windows). UEFI boot is unaffected." }
        }
        Write-UDLog $bsNote
        $out = @(Get-ChildItem -LiteralPath "${T}:\" -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(System Volume Information|\$RECYCLE\.BIN)\\' })
        $want = @($files | Where-Object { -not ($split -and $_.FullName -ieq $wim.FullName) }).Count
        $got = @($out | Where-Object { $_.Name -notlike 'install*.swm' }).Count
        $swm = @($out | Where-Object { $_.Name -like 'install*.swm' }).Count
        if ($got -lt $want -or ($split -and $swm -lt 2)) { throw "Verification failed: expected $want files$(if ($split) { ' plus at least 2 install*.swm parts' }), found $got$(if ($split) { " and $swm swm" }). The stick is incomplete." }
        if (-not (Test-Path "${T}:\sources\boot.wim")) { throw 'Verification failed: sources\boot.wim is missing on the stick.' }
        Write-UDLog "=== Bootable OK (Windows, $FileSystem): ${T}: holds $got files$(if ($split) { " + $swm install.swm parts" }); $bsNote."
        [pscustomobject]@{ Disk = $n; Mode = 'Windows'; Status = 'done'; Letter = $T; FileSystem = $FileSystem; Files = $got; SplitParts = $swm; BootSect = $bsNote; Verified = $true }
    } finally { try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch {} }
}

# ------------------------------------------------------------------ 5. File recovery from a rescue image
function ConvertTo-BigEndian([byte[]]$b) { [Array]::Reverse($b); $b }
function New-VhdFooter([int64]$Size) {
    # Fixed-VHD footer (VHD spec 1.0). Appending it to a raw image makes the image attachable as a VHD.
    $f = New-Object byte[] 512
    $put = { param([int]$o, [byte[]]$v) [Array]::Copy($v, 0, $f, $o, $v.Length) }
    & $put 0 ([Text.Encoding]::ASCII.GetBytes('conectix'))
    & $put 8 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint32]2)))
    & $put 12 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint32]0x00010000)))
    & $put 16 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint64]::MaxValue)))
    & $put 24 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint32](([DateTime]::UtcNow - [DateTime]'2000-01-01').TotalSeconds))))
    & $put 28 ([Text.Encoding]::ASCII.GetBytes('udoc'))
    & $put 32 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint32]0x00010000)))
    & $put 36 ([Text.Encoding]::ASCII.GetBytes('Wi2k'))
    & $put 40 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint64]$Size)))
    & $put 48 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint64]$Size)))
    $ts = [int64][Math]::Min([int64]($Size / 512), [int64]65535 * 16 * 255)
    if ($ts -ge [int64]65535 * 16 * 63) { $spt = 255; $hd = 16; $cth = [int64][Math]::Floor($ts / $spt) }
    else {
        $spt = 17; $cth = [int64][Math]::Floor($ts / $spt); $hd = [int64][Math]::Floor(($cth + 1023) / 1024); if ($hd -lt 4) { $hd = 4 }
        if ($cth -ge $hd * 1024 -or $hd -gt 16) { $spt = 31; $hd = 16; $cth = [int64][Math]::Floor($ts / $spt) }
        if ($cth -ge $hd * 1024) { $spt = 63; $hd = 16; $cth = [int64][Math]::Floor($ts / $spt) }
    }
    $cyl = [int64][Math]::Floor($cth / $hd)
    & $put 56 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint16]$cyl))); $f[58] = [byte]$hd; $f[59] = [byte]$spt
    & $put 60 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint32]2)))
    & $put 68 ([guid]::NewGuid().ToByteArray())
    [uint32]$sum = 0; foreach ($x in $f) { $sum += $x }
    & $put 64 (ConvertTo-BigEndian ([BitConverter]::GetBytes([uint32]([int64]4294967295 - [int64]$sum))))
    , $f
}
function Test-VhdFooter([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try { if ($fs.Length -lt 512) { return $false }; $b = New-Object byte[] 8; $fs.Position = $fs.Length - 512; [void]$fs.Read($b, 0, 8) } finally { $fs.Close() }
    [Text.Encoding]::ASCII.GetString($b) -eq 'conectix'
}

function Add-RawVhdWrap([string]$Image) {
    # Temporarily make a raw image attachable: append a 512-byte fixed-VHD footer and expose it under a .vhd name
    # (a hard link, or a rename where hard links are impossible). Remove-RawVhdWrap undoes both exactly.
    $len = (Get-Item -LiteralPath $Image).Length
    if ($len % 512) { throw "$Image is not a whole number of 512-byte sectors; it can't be attached." }
    if (Test-VhdFooter $Image) { throw "$Image already ends in a VHD footer. If an earlier recovery was interrupted, run -Recover again after checking $Image.usbdoctor-vhdwrap.json." }
    $vhd = "$Image.usbdoctor.vhd"
    $how = 'link'
    try { New-Item -ItemType HardLink -Path $vhd -Target $Image -ErrorAction Stop | Out-Null } catch { $how = 'rename' }
    $st = [pscustomobject]@{ Image = $Image; Vhd = $vhd; Length = [int64]$len; How = $how; Time = (Get-Date).ToString('s') }
    ($st | ConvertTo-Json) | Set-Content -LiteralPath "$Image.usbdoctor-vhdwrap.json" -Encoding UTF8
    if ($how -eq 'rename') { Move-Item -LiteralPath $Image -Destination $vhd }
    $fs = [IO.File]::Open($vhd, 'Open', 'ReadWrite', 'None')
    try { $fs.Position = $len; $f = New-VhdFooter $len; $fs.Write($f, 0, 512) } finally { $fs.Close() }
    $st
}
function Remove-RawVhdWrap($st) {
    $p = if ($st.How -eq 'rename') { $st.Vhd } else { $st.Image }
    if ((Get-Item -LiteralPath $p).Length -eq $st.Length + 512 -and (Test-VhdFooter $p)) {
        $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); try { $fs.SetLength($st.Length) } finally { $fs.Close() }
    }
    if ($st.How -eq 'rename') { Move-Item -LiteralPath $st.Vhd -Destination $st.Image } else { Remove-Item -LiteralPath $st.Vhd -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath "$($st.Image).usbdoctor-vhdwrap.json" -Force -ErrorAction SilentlyContinue
    if ((Get-Item -LiteralPath $st.Image).Length -ne $st.Length) { throw "Could not restore $($st.Image) to its original length $($st.Length)." }
}
function Repair-InterruptedWrap([string]$Image) {
    $m = "$Image.usbdoctor-vhdwrap.json"
    if (Test-Path -LiteralPath $m) {
        $st = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
        if ($st.PSObject.Properties['Overlay'] -and $st.Overlay) { Remove-ImageOverlay $st.Overlay }
        try { Dismount-DiskImage -ImagePath $st.Vhd -ErrorAction SilentlyContinue | Out-Null } catch {}
        Write-UDLog "Undoing an interrupted VHD wrap of $Image" 'WARN'
        Remove-RawVhdWrap $st
    }
}

function Find-CgSecurityTool([string[]]$Names, [string]$ToolsDir) {
    $dirs = @($ToolsDir, (Join-Path $env:ProgramData 'USBDoctor\tools'), $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:USERPROFILE 'Downloads')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($n in $Names) { $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { return $c.Source } }
    foreach ($dir in $dirs) {
        foreach ($n in $Names) { $p = Join-Path $dir $n; if (Test-Path -LiteralPath $p) { return $p } }
        $sub = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'testdisk|photorec|USBDoctor|tools' -or $dir -eq $ToolsDir })
        foreach ($s in $sub) { foreach ($n in $Names) { $p = Join-Path $s.FullName $n; if (Test-Path -LiteralPath $p) { return $p } } }
    }
    $null
}

function Get-AttachedImagePartitions([int]$Number) {
    # A freshly attached image needs a moment before Windows lists its partitions; read-only images can also arrive
    # offline (SAN policy or a signature clash). Bringing a disk online changes nothing on it.
    $pl = @()
    for ($i = 0; $i -lt 20; $i++) {
        try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch {}
        $dk = Get-Disk -Number $Number -ErrorAction SilentlyContinue
        if ($dk -and $dk.IsOffline) {
            Write-UDLog "The attached image (disk $Number) is offline ($($dk.OfflineReason)); bringing it online read-only."
            try { Set-Disk -Number $Number -IsOffline $false -ErrorAction Stop } catch { Write-UDLog "Could not bring disk $Number online: $($_.Exception.Message)" 'WARN' }
        }
        $pl = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue | Sort-Object Offset)
        if ($pl.Count -and $dk -and -not $dk.IsOffline) { break }
        Start-Sleep -Milliseconds 750
    }
    $pl
}

function Get-VolumeFsName($v) {
    # MSFT_Volume.FileSystemType has no RAW value: a volume whose file system failed to mount shows as 'Unknown'.
    # The FileSystem string says 'RAW' or is empty then. Returns '' when no readable file system is mounted.
    if (-not $v) { return '' }
    $fs = "$($v.FileSystem)".Trim()
    if (-not $fs) { $fs = "$($v.FileSystemType)".Trim() }
    if ($fs -in '', 'Unknown', 'RAW') { return '' }
    $fs
}

function Get-ImageVolume([int]$Number, [int]$PartitionNumber) {
    # Wait for the volume of one partition of an attached image and return a path robocopy can read from:
    # its drive letter, a letter USBDoctor assigns, or failing both the volume GUID path.
    $r = [ordered]@{ Letter = ''; Volume = $null; Root = ''; Added = $false; Note = ''; MountFailed = $false }
    $p = $null; $seen = 0
    for ($i = 0; $i -lt 30; $i++) {
        if ($i % 4 -eq 0) { try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch {} }
        $p = Get-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
        if (-not $p) { Start-Sleep -Milliseconds 500; continue }
        $v = $null; try { $v = $p | Get-Volume -ErrorAction Stop } catch {}
        if ($v -and (Get-VolumeFsName $v)) { $r.Volume = $v; break }
        # The volume exists but no file system mounts on it: waiting longer does not help (NTFS retries the same mount).
        if ($v) { $seen++; if ($seen -ge 10) { $r.Volume = $v; $r.MountFailed = $true; $r.Note = "Windows found the volume but could not mount its file system ($(if ("$($v.FileSystem)") { "$($v.FileSystem)" } else { 'no file system' }))"; return [pscustomobject]$r } }
        Start-Sleep -Milliseconds 500
    }
    if (-not $r.Volume) { $r.MountFailed = [bool]$p; $r.Note = 'Windows did not mount a volume on it within 15 s'; return [pscustomobject]$r }
    $r.Letter = Get-PartLetter $p
    if (-not $r.Letter) {
        for ($k = 0; $k -lt 3 -and -not $r.Letter; $k++) {
            try { Add-PartitionAccessPath -DiskNumber $Number -PartitionNumber $PartitionNumber -AssignDriveLetter -ErrorAction Stop; $r.Added = $true } catch { $r.Note = "no letter: $($_.Exception.Message.Trim())" }
            Start-Sleep 1
            $r.Letter = Get-PartLetter (Get-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue)
        }
    }
    if ($r.Letter) { $r.Root = "$($r.Letter):\"; $r.Note = '' }
    else {
        $g = @($p.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' }) | Select-Object -First 1
        if (-not $g -and $r.Volume.Path) { $g = $r.Volume.Path }
        if ($g) { $r.Root = $g; Write-UDLog "Partition ${PartitionNumber}: no drive letter ($($r.Note)); reading it by volume path $g" 'WARN' }
    }
    [pscustomobject]$r
}

function Get-ImageDiskNumber([string]$Path) {
    $num = $null
    for ($i = 0; $i -lt 20 -and $null -eq $num; $i++) { Start-Sleep -Milliseconds 500; try { $num = (Get-DiskImage -ImagePath $Path -ErrorAction Stop).Number } catch {} }
    if ($null -eq $num) { throw "$Path attached but Windows gave it no disk number." }
    [int]$num
}

function Show-CopiedRootFolder([string]$Dir) {
    # robocopy gives the destination folder the attributes of the source folder. A volume root is Hidden+System, so a
    # copy from X:\ into a subfolder leaves that subfolder hidden and the user can't see their files. Clear both.
    $d = Get-Item -LiteralPath $Dir -Force -ErrorAction SilentlyContinue
    if (-not $d) { return }
    $hs = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
    if ($d.Attributes -band $hs) {
        try { $d.Attributes = $d.Attributes -band -bnot $hs } catch { Write-UDLog "Could not unhide $Dir : $($_.Exception.Message)" 'WARN' }
    }
}

function Copy-ImageVolumes([int]$Number, [string]$OutDir, [int[]]$Only) {
    # One result per partition of the attached image: copied with robocopy, or why it could not be read.
    $out = @()
    foreach ($p in (Get-AttachedImagePartitions $Number)) {
        if ($Only -and $p.PartitionNumber -notin $Only) { continue }
        $vi = Get-ImageVolume $Number $p.PartitionNumber
        $v = $vi.Volume; $src = $vi.Root; $fs = Get-VolumeFsName $v
        if (-not $src -or -not $fs) {
            $out += [pscustomobject]@{ Number = [int]$p.PartitionNumber; Copied = 0; Readable = $false; MountFailed = [bool]$vi.MountFailed; Text = "partition $($p.PartitionNumber): no readable file system (try -Carve)$(if ($vi.Note) { " [$($vi.Note)]" })" }
            continue
        }
        $dest = Join-Path $OutDir ('part{0}-{1}' -f $p.PartitionNumber, ($(if ($v.FileSystemLabel) { $v.FileSystemLabel } else { $fs }) -replace '[^A-Za-z0-9_-]+', '_'))
        $rlog = Join-Path $OutDir 'recovery-robocopy.log'
        Write-UDLog "Copying $src ($fs '$($v.FileSystemLabel)') -> $dest"
        & robocopy.exe $src $dest /E /R:0 /W:0 /COPY:DT /DCOPY:T /XJ /NP /NFL /NDL /XD 'System Volume Information' '$RECYCLE.BIN' "/LOG+:$rlog" | Out-Null
        $rc = $LASTEXITCODE
        Show-CopiedRootFolder $dest
        $n = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue).Count
        $out += [pscustomobject]@{ Number = [int]$p.PartitionNumber; Copied = $n; Readable = $true; MountFailed = $false; Text = "partition $($p.PartitionNumber) ($fs '$($v.FileSystemLabel)'): $n files copied$(if ($rc -ge 8) { " - some files could not be read (robocopy exit $rc, see $rlog)" })" }
    }
    # Emit the results one by one (callers wrap the call in @()). A ', $out' here made @(...) an array holding one array,
    # so $x.Text on it failed and MountFailed/Copied were read from every partition at once.
    $out
}

function New-ImageOverlay([string]$Parent, [string[]]$Dirs) {
    # A differencing (child) virtual disk on top of the image: Windows opens the image read-only as the parent and
    # every write - an NTFS journal replay, a signature fix - lands in the child, which is deleted afterwards.
    $ext = if ($Parent -match '\.vhdx$') { '.vhdx' } else { '.vhd' }
    $errs = @()
    foreach ($d in ($Dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        $ov = Join-Path $d ('usbdoctor-overlay-{0}{1}' -f [guid]::NewGuid().ToString('N').Substring(0, 12), $ext)
        try { [void](Invoke-Diskpart @("create vdisk file=""$ov"" parent=""$Parent""")); if (Test-Path -LiteralPath $ov) { return $ov } }
        catch { $errs += "$d : $($_.Exception.Message)"; Remove-Item -LiteralPath $ov -Force -ErrorAction SilentlyContinue }
    }
    throw "Could not create a temporary overlay disk ($($errs -join '; '))."
}
function Remove-ImageOverlay([string]$Overlay) {
    if (-not $Overlay -or -not (Test-Path -LiteralPath $Overlay)) { return }
    try { Dismount-DiskImage -ImagePath $Overlay -ErrorAction SilentlyContinue | Out-Null } catch {}
    for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $Overlay); $i++) { Remove-Item -LiteralPath $Overlay -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $Overlay) { Start-Sleep -Milliseconds 500 } }
    if (Test-Path -LiteralPath $Overlay) { Write-UDLog "Could not delete the temporary overlay $Overlay; delete it by hand (the image itself is not affected)." 'WARN' }
}

function Invoke-ImageRecovery {
    # Copy readable files out of a rescue image (attached read-only), and optionally carve deleted/lost files with PhotoRec.
    # Works on the image file only: never opens or writes the USB stick.
    # -ForceOverlay (tests and diagnosis only, not on the command line): skip the read-only attempt and go straight to the overlay.
    param([string]$Image, [string]$OutDir, [string]$ToolsDir, [switch]$Carve, [switch]$Preview, [switch]$ForceOverlay)
    if (-not $Image -or -not (Test-Path -LiteralPath $Image)) { throw "Image '$Image' not found." }
    $Image = (Resolve-Path -LiteralPath $Image).ProviderPath
    if (-not $OutDir) { $OutDir = Join-Path (Join-Path (Get-DefaultDataDir) 'Recovered') ([IO.Path]::GetFileNameWithoutExtension($Image)) }
    $len = (Get-Item -LiteralPath $Image).Length
    $isVhd = $Image -match '\.vhdx?$'
    $photorec = Find-CgSecurityTool @('photorec_win.exe', 'photorec.exe') $ToolsDir
    $testdisk = Find-CgSecurityTool @('testdisk_win.exe', 'testdisk.exe') $ToolsDir
    $free = Get-FreeBytes $OutDir
    $txt = @("Recover files from the image $Image ($(Format-Bytes $len)) into $OutDir.",
        'Only the image is used; the USB stick is not opened or written.',
        $(if ($isVhd) { '1. Attach the virtual disk read-only and copy every readable file (robocopy, one folder per partition).' }
            else { '1. Attach the raw image read-only (a 512-byte VHD footer is appended for the attach and removed afterwards; the image bytes are unchanged) and copy every readable file (robocopy, one folder per partition).' }))
    if ($Carve) {
        if ($isVhd -and $Image -match '\.vhdx$') { $txt += '2. Carving: PhotoRec cannot read .vhdx files. Carve a raw image (USBDoctor Rescue copy) instead.' }
        elseif ($photorec) { $txt += "2. Carve deleted/lost files with PhotoRec ($photorec) into $OutDir\carved (by file type, original names are lost)." }
        else { $txt += "2. Carving needs PhotoRec, which was not found (looked in PATH, $(Join-Path $env:ProgramData 'USBDoctor\tools'), Program Files and Downloads). Get TestDisk & PhotoRec (free, GPL) from $script:CgsUrl, unzip it, then run again with -ToolsDir <folder>. USBDoctor does not download it for you." }
    } else { $txt += "2. Deleted or lost files: add -Carve to run PhotoRec on the image$(if (-not $photorec) { " (not installed: $script:CgsUrl)" })." }
    $txt += $(if ($testdisk) { "Lost partitions: run ""$testdisk"" /log ""$Image"" (interactive) - also image-only." } else { "Lost partitions: TestDisk (same download, $script:CgsUrl) can rebuild partition tables on a copy of the image." })
    if ($free -ge 0 -and $free -lt $len) { $txt += "Note: $(Format-Bytes $free) free at the destination; the image holds up to $(Format-Bytes $len)." }
    if ($Preview) { return New-Plan 'Recover' 'Recover files from a rescue image' $txt $false -1 }
    Assert-Admin 'Attaching an image'
    $usbOut = Get-DiskNumberOfPath $OutDir
    if ($usbOut -ge 0) { $od = Get-Disk -Number $usbOut -ErrorAction SilentlyContinue; if ($od -and $od.IsReadOnly) { throw "$OutDir is on a read-only disk." } }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    Repair-InterruptedWrap $Image
    Write-UDLog "=== Recover files from $Image -> $OutDir"
    $wrap = $null; $attach = $Image; $copied = 0; $parts = @(); $mounted = $null; $overlay = $null
    try {
        if (-not $isVhd) { $wrap = Add-RawVhdWrap $Image; $attach = $wrap.Vhd }
        $res = @(); $retry = @()
        if ($ForceOverlay) { Write-UDLog 'ForceOverlay: skipping the read-only attach and reading every partition through a temporary overlay.' }
        else {
            Mount-DiskImage -ImagePath $attach -Access ReadOnly -ErrorAction Stop | Out-Null; $mounted = $attach
            $res = @(Copy-ImageVolumes (Get-ImageDiskNumber $attach) $OutDir)
            $retry = @($res | Where-Object { $_.MountFailed } | ForEach-Object { $_.Number })
        }
        if ($retry.Count -or $ForceOverlay) {
            # Seen on real rescue images and in the elevated test: NTFS refuses a read-only mount with
            # STATUS_MEDIA_WRITE_PROTECTED (0xC00000A2) when its journal must be replayed first (the stick was pulled or
            # imaged while mounted). The replay needs to write, so it goes to a throw-away overlay; the image stays read-only.
            if ($retry.Count) { Write-UDLog "Partition(s) $($retry -join ', '): Windows could not mount the file system read-only (usually a journal that must be replayed because the drive was not safely removed). Re-attaching through a temporary overlay disk so any replay writes go there; the image itself stays read-only." }
            if ($mounted) { Dismount-DiskImage -ImagePath $attach -ErrorAction Stop | Out-Null; $mounted = $null; Start-Sleep 1 }
            try {
                $overlay = New-ImageOverlay $attach @($env:TEMP, $OutDir)
                if ($wrap) { $wrap | Add-Member -NotePropertyName Overlay -NotePropertyValue $overlay -Force; ($wrap | ConvertTo-Json) | Set-Content -LiteralPath "$Image.usbdoctor-vhdwrap.json" -Encoding UTF8 }
                Write-UDLog "Overlay: $overlay"
                Mount-DiskImage -ImagePath $overlay -ErrorAction Stop | Out-Null; $mounted = $overlay
                $res2 = @(Copy-ImageVolumes (Get-ImageDiskNumber $overlay) $OutDir $(if ($retry.Count) { $retry } else { $null }))
                foreach ($x in $res2) { $x.Text += $(if ($x.Readable) { ' (read through a temporary overlay; any journal replay went there)' } else { ' (also not readable through a temporary overlay)' }) }
                if ($ForceOverlay) { $res = $res2 }
                else { $res = @($res | Where-Object { $_.Number -notin $retry }) + @(foreach ($n in $retry) { $x = $res2 | Where-Object { $_.Number -eq $n } | Select-Object -First 1; if ($x) { $x } else { $res | Where-Object { $_.Number -eq $n } } }) | Sort-Object Number }
            } catch {
                $em = $_.Exception.Message.Trim(); Write-UDLog "Overlay attach failed: $em" 'WARN'
                if ($ForceOverlay) { throw }
                foreach ($x in $res) { if ($x.Number -in $retry) { $x.Text += " [overlay failed: $em]" } }
            }
        }
        foreach ($x in $res) { $copied += $x.Copied; $parts += $x.Text }
        if (-not $parts.Count) { $parts += 'no partitions found in the image (try -Carve)' }
    } finally {
        if ($mounted) { try { Dismount-DiskImage -ImagePath $mounted -ErrorAction Stop | Out-Null } catch { Write-UDLog "Detach failed: $($_.Exception.Message)" 'WARN' } }
        if ($overlay) { Start-Sleep 1; Remove-ImageOverlay $overlay }
        if ($wrap) {
            # The attach can hold the file for a moment after the detach returns; retry before giving up.
            for ($k = 1; $k -le 5; $k++) { Start-Sleep 1; try { Remove-RawVhdWrap $wrap; break } catch { if ($k -eq 5) { throw } } }
        }
    }
    foreach ($x in $parts) { Write-UDLog $x }
    $carved = $null; $carveNote = ''
    if ($Carve) {
        if ($Image -match '\.vhdx$') { $carveNote = 'PhotoRec cannot read .vhdx; not carved.' }
        elseif (-not $photorec) { $carveNote = "PhotoRec not found. Download TestDisk & PhotoRec from $script:CgsUrl and run again with -ToolsDir <folder>." }
        else {
            $cdir = Join-Path $OutDir 'carved'; New-Item -ItemType Directory -Path $cdir -Force | Out-Null
            Write-UDLog "Carving with PhotoRec (this can take a long time; it reads the image only)..."
            $p = Start-Process -FilePath $photorec -ArgumentList @('/log', '/logname', ('"{0}"' -f (Join-Path $OutDir 'photorec.log')), '/d', ('"{0}"' -f (Join-Path $cdir 'recup')), '/cmd', ('"{0}"' -f $Image), 'partition_none,fileopt,everything,enable,search') -WorkingDirectory $OutDir -Wait -PassThru -WindowStyle Minimized
            $carved = @(Get-ChildItem -LiteralPath $cdir -Recurse -File -ErrorAction SilentlyContinue).Count
            $carveNote = "PhotoRec exit $($p.ExitCode): $carved file(s) carved into $cdir (named by type, e.g. f0012345.jpg)."
        }
        Write-UDLog $carveNote
    }
    Write-UDLog "=== Recovery done: $copied files copied to $OutDir"
    [pscustomobject]@{ Image = $Image; OutDir = $OutDir; FilesCopied = $copied; Partitions = $parts; Carved = $carved; CarveNote = $carveNote; ImageUnchanged = ((Get-Item -LiteralPath $Image).Length -eq $len) }
}

# ------------------------------------------------------------------ 2. Speed / health benchmark
function Get-Median([double[]]$x) { $s = @($x | Sort-Object); if (-not $s.Count) { return 0 }; if ($s.Count % 2) { $s[[int][Math]::Floor($s.Count / 2)] } else { ($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2 } }

function Get-BenchmarkComparison($Current, [object[]]$Previous) {
    # Compare with the median of up to 5 earlier runs of the same mode for this device. Slower by more than 30% = flagged.
    $prev = @($Previous | Where-Object { $_.Mode -eq $Current.Mode } | Select-Object -Last 5)
    if (-not $prev.Count) { return [pscustomobject]@{ Runs = 0; Slowdown = $false; Text = 'First benchmark of this device in this mode; later runs are compared with it.'; Details = @() } }
    $det = @(); $slow = $false
    foreach ($m in 'SeqReadMBs', 'SeqWriteMBs', 'RandReadIops', 'RandWriteIops') {
        $c = [double]$Current.$m; if ($c -lt 0) { continue }
        $vals = @($prev | ForEach-Object { [double]$_.$m } | Where-Object { $_ -gt 0 }); if (-not $vals.Count) { continue }
        $med = Get-Median $vals; $pct = if ($med -gt 0) { ($c - $med) / $med * 100 } else { 0 }
        if ($pct -lt -30) { $slow = $true }
        $det += ('{0}: {1:N1} now vs {2:N1} before ({3:+0;-0}%){4}' -f $m, $c, $med, $pct, $(if ($pct -lt -30) { '  <-- SLOWER' } else { '' }))
    }
    $ports = @($prev | ForEach-Object { $_.Port } | Where-Object { $_ } | Sort-Object -Unique)
    $txt = if ($slow) { "SLOWDOWN: more than 30% slower than the median of the last $($prev.Count) run(s). Worn flash slows down before it fails; check the port first (USB 2 vs USB 3, hub) - same port as before: $(if ($Current.Port -and $ports -contains $Current.Port) { 'yes' } else { 'no/unknown' })." }
    else { "Within 30% of the last $($prev.Count) run(s)." }
    [pscustomobject]@{ Runs = $prev.Count; Slowdown = $slow; Text = $txt; Details = $det }
}

function Invoke-UsbBenchmark {
    # Sequential and 4 KiB random speed, unbuffered, data verified. File mode writes one temp file and deletes it.
    # -ReadOnly: raw reads of the disk only (administrator), nothing written.
    param([string]$Letter, [int]$DiskNumber = -1, [int]$SizeMB = 256, [switch]$ReadOnly, [int]$RandomSeconds = 8, [int]$MaxRandomOps = 4000, [switch]$NoHistory,
        [Parameter(DontShow)][string]$TestPath)
    if ($SizeMB -lt 16 -or $SizeMB -gt 8192) { throw '-SizeMB must be between 16 and 8192.' }
    if ($Letter) { $Letter = $Letter.Trim().TrimEnd('\').TrimEnd(':').ToUpper(); if ($Letter -notmatch '^[A-Z]$') { throw "'$Letter' is not a drive letter. Use -Letter X (X, X: or X:\ all work)." } }
    $bytes = [int64]$SizeMB * 1MB
    $seed = [uint32](Get-Random -Minimum 1 -Maximum 2147483647)
    $d = $null; $ident = ''; $model = ''; $port = ''
    if ($TestPath) {
        # test hook: benchmark logic against a plain folder (no USB checks). Hidden; for the test harness only.
        if (-not (Test-Path -LiteralPath $TestPath -PathType Container)) { throw "Test folder '$TestPath' not found." }
        $root = (Resolve-Path -LiteralPath $TestPath).ProviderPath; $ident = "TESTPATH|$root"; $model = 'test folder'; $mode = 'File'
    } else {
        if ($Letter) { $DiskNumber = (Get-DiskOfLetter $Letter).DiskNumber }
        if ($DiskNumber -lt 0) { throw 'Use -Benchmark -Letter X (file test) or -Benchmark -ReadOnly -Disk N (raw read test).' }
        $d = Get-RepairDisk $DiskNumber
        $ident = $d.Identity; $model = $d.Model; $port = $d.PortKey
        $g = Get-GateStatus $d 'Benchmark'
        if ($g.Refusal) { throw "REFUSED on disk ${DiskNumber}: a benchmark stresses the drive, and it is $($g.Refusal)" }
        $rec = Get-DeviceHistoryRecord $ident
        if ($ReadOnly) { $mode = 'Raw' }
        else {
            $mode = 'File'
            if ($rec -and $rec.Counterfeit) { throw "REFUSED: this stick failed the capacity test (counterfeit). Writing a test file could land on flash that isn't there and destroy files. Use -ReadOnly." }
            if (-not $Letter) { $Letter = ($d.Volumes | Where-Object Letter | Sort-Object Free -Descending | Select-Object -First 1).Letter }
            if (-not $Letter) { throw "Disk $DiskNumber has no drive letter for the file test. Assign one, or use -ReadOnly." }
            $L = $Letter.Trim().TrimEnd(':').ToUpper()
            $vol = $d.Volumes | Where-Object { $_.Letter -eq $L } | Select-Object -First 1
            if ($d.ReadOnly -or ($vol -and $vol.PartReadOnly)) { throw "${L}: is read-only. Use -ReadOnly for a raw read test." }
            $root = "${L}:\"
        }
    }
    if ($mode -eq 'File') {
        $free = Get-FreeBytes $root
        if ($free -ge 0 -and $free -lt $bytes + 64MB) { throw "Not enough free space on $root ($(Format-Bytes $free) free, $(Format-Bytes ($bytes + 64MB)) needed). Use a smaller -SizeMB, or -ReadOnly." }
        $tmp = Join-Path $root ("USBDoctor-bench-{0}.tmp" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        Write-UDLog "=== Benchmark (file, unbuffered, verified): $SizeMB MB on $root ($model)"
        try { $r = [UsbDocBench]::FileBench($tmp, $bytes, $RandomSeconds, $MaxRandomOps, $seed) }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmp) { Write-UDLog "Could not delete the temp file $tmp; delete it by hand." 'WARN' }
    } else {
        Assert-Admin 'The read-only raw benchmark'
        Write-UDLog "=== Benchmark (raw, read-only): disk $DiskNumber $model, first $SizeMB MB + 4 KiB random reads"
        $r = [UsbDocBench]::RawBench("\\.\PhysicalDrive$DiskNumber", [int64]$d.Size, $bytes, $RandomSeconds, $MaxRandomOps, $seed)
    }
    $cur = [ordered]@{ Time = (Get-Date).ToString('s'); Mode = $mode; SizeMB = $SizeMB; Port = $port
        SeqReadMBs = [Math]::Round($r.SeqReadMBs, 1); SeqWriteMBs = [Math]::Round($r.SeqWriteMBs, 1)
        RandReadIops = [Math]::Round($r.RandReadIops, 0); RandWriteIops = [Math]::Round($r.RandWriteIops, 0)
        Mismatches = [int64]$r.Mismatches; ReadErrors = [int64]$r.ReadErrors }
    $rec = Get-DeviceHistoryRecord $ident
    $cmp = Get-BenchmarkComparison ([pscustomobject]$cur) @($(if ($rec) { $rec.Benchmarks }) | Where-Object { $_ } | ForEach-Object { [pscustomobject]$_ })
    $cur.Slowdown = $cmp.Slowdown
    $integrity = if ($r.Mismatches -gt 0) { "DATA CAME BACK WRONG in $($r.Mismatches) block(s): the drive corrupts data. Failing or counterfeit - stop trusting it." }
    elseif ($r.ReadErrors -gt 0) { "$($r.ReadErrors) read error(s) during the test: the media is failing. Image it (-Rescue)." }
    elseif ($mode -eq 'File') { 'All data read back correctly.' } else { 'No read errors (read-only test, nothing written).' }
    if (-not $NoHistory) { Update-DeviceHistory $ident $model { param($x) $x.Benchmarks = @(@(@($x.Benchmarks | Where-Object { $_ }) + @($cur)) | Select-Object -Last 20) } | Out-Null }
    $res = [pscustomobject]@{ Target = $(if ($mode -eq 'File') { $root } else { "disk $DiskNumber" }); Device = $model; Mode = $mode; SizeMB = $SizeMB
        SeqReadMBs = $cur.SeqReadMBs; SeqWriteMBs = $(if ($mode -eq 'File') { $cur.SeqWriteMBs } else { 'n/a (read-only)' })
        RandRead4kIops = $cur.RandReadIops; RandWrite4kIops = $(if ($mode -eq 'File') { $cur.RandWriteIops } else { 'n/a (read-only)' })
        Integrity = $integrity; Comparison = $cmp.Text; Details = ($cmp.Details -join '; '); Slowdown = $cmp.Slowdown }
    Write-UDLog ("Benchmark: seq read {0} MB/s, seq write {1} MB/s, 4K read {2} IOPS, 4K write {3} IOPS. {4} {5}" -f $res.SeqReadMBs, $res.SeqWriteMBs, $res.RandRead4kIops, $res.RandWrite4kIops, $integrity, $cmp.Text) $(if ($cmp.Slowdown -or $r.Mismatches -or $r.ReadErrors) { 'WARN' } else { 'INFO' })
    $res
}

# ------------------------------------------------------------------ 6. Drive health watch
function Show-UDToast([string]$Title, [string]$Text) {
    # Built-in Windows toast first (WinRT from PowerShell), then BurntToast if installed, then msg.exe. Returns the method used.
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $x = New-Object Windows.Data.Xml.Dom.XmlDocument
        $x.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$([Security.SecurityElement]::Escape($Title))</text><text>$([Security.SecurityElement]::Escape($Text))</text></binding></visual></toast>")
        $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show((New-Object Windows.UI.Notifications.ToastNotification $x))
        return 'toast'
    } catch {}
    try { if (Get-Module -ListAvailable BurntToast) { Import-Module BurntToast -ErrorAction Stop; New-BurntToastNotification -Text $Title, $Text -ErrorAction Stop; return 'BurntToast' } } catch {}
    try { & msg.exe $env:USERNAME /TIME:600 "$Title - $Text" 2>$null; if ($LASTEXITCODE -eq 0) { return 'msg' } } catch {}
    Write-UDLog "Notification (no toast method worked): $Title - $Text" 'WARN'
    'log'
}

function Get-WatchVerdict($s) {
    if (-not $s) { return 'OK' }
    if ($s.DropsAfterErrors -gt 0 -or $s.CapacityChanged) { return 'DYING' }
    if ($s.ReadErrors -gt 0) { return 'ERRORS' }
    'OK'
}

function Invoke-UsbHealthWatch {
    # One watch pass (the scheduled task runs this every 30 min and at logon): per USB drive seen in the event logs,
    # count new read errors, drop-outs and capacity changes since the last pass, keep them in history.json, and notify
    # when a drive's error rate rises or its verdict changes. -DryRun: compute and print only (no history write, no toast).
    param([int]$ErrorThreshold = 3, [switch]$DryRun, [switch]$NoToast)
    $h = Get-UDHistory
    $lastRun = $null; if ($h.Watch -and $h.Watch.LastRun) { try { $lastRun = [datetime]$h.Watch.LastRun } catch {} }
    $since = if ($lastRun) { $lastRun } else { (Get-Date).AddDays(-1) }
    $hist = Get-UsbEventHistory 7
    $keys = @($hist.Arrivals | Where-Object { $_.BusType -eq 7 -and $_.Key -notlike 'UNKNOWN*' } | ForEach-Object Key | Sort-Object -Unique)
    $out = @()
    foreach ($k in $keys) {
        $s = Get-DeviceHistorySummary $hist $k
        $verdict = Get-WatchVerdict $s
        $newErr = @($s.ErrorTimes | Where-Object { $_ -gt $since }).Count
        $newDrops = @($s.DropTimes | Where-Object { $_ -gt $since }).Count
        $r = Get-DeviceRecord $h $k $s.Model
        $prev = if ($r.Watch) { $r.Watch } else { $null }
        $prevVerdict = if ($prev) { "$($prev.Verdict)" } else { '' }
        $prevCaps = if ($prev -and $prev.Capacities) { @($prev.Capacities | ForEach-Object { [int64]$_ }) } else { @() }
        $newCap = @($s.Capacities | Where-Object { $prevCaps.Count -and $_ -notin $prevCaps }).Count -gt 0
        $reasons = @()
        if ($prevVerdict -and $prevVerdict -ne $verdict) { $reasons += "verdict $prevVerdict -> $verdict" }
        elseif (-not $prevVerdict -and $verdict -ne 'OK') { $reasons += "verdict $verdict" }
        if ($newErr -ge $ErrorThreshold) { $reasons += "$newErr new read errors" }
        if ($newDrops -gt 0) { $reasons += "$newDrops new drop-out(s) after errors" }
        if ($newCap) { $reasons += "capacity changed ($((@($s.Capacities) | ForEach-Object { Format-Bytes $_ }) -join ', '))" }
        $alert = [bool]$reasons.Count
        $out += [pscustomobject]@{ Device = $k; Model = $s.Model; Verdict = $verdict; PreviousVerdict = $prevVerdict; NewReadErrors = $newErr; NewDrops = $newDrops
            ReadErrors7d = $s.ReadErrors; Drops7d = $s.DropsAfterErrors; Capacities = (@($s.Capacities) | ForEach-Object { Format-Bytes $_ }) -join ', '; Alert = $alert; Reason = ($reasons -join '; ') }
        if (-not $DryRun) {
            $r.Watch = @{ LastRun = (Get-Date).ToString('s'); Verdict = $verdict; ReadErrors7d = $s.ReadErrors; Drops7d = $s.DropsAfterErrors; Capacities = @($s.Capacities | ForEach-Object { [int64]$_ }); LastAlert = $(if ($alert) { (Get-Date).ToString('s') } elseif ($prev) { $prev.LastAlert } else { $null }) }
        }
    }
    $alerts = @($out | Where-Object Alert)
    if (-not $DryRun) {
        $h.Watch = @{ LastRun = (Get-Date).ToString('s'); Devices = $keys.Count; Alerts = $alerts.Count }
        Save-UDHistory $h
        if ($alerts.Count -and -not $NoToast) {
            $a = $alerts[0]
            $how = Show-UDToast "USBDoctor: $($a.Model) - $($a.Verdict)" ("{0}{1}. Open USBDoctor to diagnose." -f $a.Reason, $(if ($alerts.Count -gt 1) { " (+$($alerts.Count - 1) more drive(s))" }))
            Write-UDLog "Health watch: $($alerts.Count) alert(s), notified via $how"
        }
    }
    [pscustomobject]@{ DryRun = [bool]$DryRun; Since = $since.ToString('s'); DevicesSeen = $keys.Count; Alerts = $alerts.Count; Results = $out }
}

function Get-WatchTaskSpec([string]$ScriptPath, [int]$Minutes) {
    # A compiled USBDoctor.exe must be launched directly; powershell -File cannot run an .exe.
    if ($ScriptPath -match '(?i)\.exe$') {
        $execute = $ScriptPath
        $a = '-WatchRun'
    } else {
        $execute = 'powershell.exe'
        $a = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -WatchRun' -f $ScriptPath
    }
    [pscustomobject]@{ TaskName = $script:TaskName; Execute = $execute; Arguments = $a; User = "$env:USERDOMAIN\$env:USERNAME"
        Triggers = "at logon of $env:USERNAME, and every $Minutes minutes"; RunLevel = 'Limited (not elevated)'; Hidden = $true }
}

function Install-UsbHealthWatch {
    param([string]$ScriptPath, [int]$Minutes = 30, [switch]$DryRun)
    if (-not $ScriptPath) {
        $ps1 = Join-Path $PSScriptRoot 'USBDoctor.ps1'
        $exe = Join-Path $PSScriptRoot 'USBDoctor.exe'
        $ScriptPath = if (Test-Path -LiteralPath $ps1) { $ps1 } elseif (Test-Path -LiteralPath $exe) { $exe } else { $ps1 }
    }
    $spec = Get-WatchTaskSpec $ScriptPath $Minutes
    if ($DryRun) { $spec | Add-Member NoteProperty Status 'DRY RUN: nothing was registered.'; return $spec }
    $act = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Arguments
    $rep = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $spec.User
    $pr = New-ScheduledTaskPrincipal -UserId $spec.User -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $note = ''
    try { Register-ScheduledTask -TaskName $script:TaskName -Action $act -Trigger @($logon, $rep) -Principal $pr -Settings $set -Description 'USBDoctor: watch USB drive errors, drop-outs and capacity changes; notify on change.' -Force -ErrorAction Stop | Out-Null }
    catch {
        Register-ScheduledTask -TaskName $script:TaskName -Action $act -Trigger @($rep) -Principal $pr -Settings $set -Description 'USBDoctor: watch USB drive errors, drop-outs and capacity changes; notify on change.' -Force -ErrorAction Stop | Out-Null
        $note = " (the logon trigger was refused without administrator rights: $($_.Exception.Message); the $Minutes-minute trigger still runs)"
    }
    Write-UDLog "Health watch installed: task '$($script:TaskName)'$note"
    $spec | Add-Member NoteProperty Status "Installed$note"; $spec
}

function Uninstall-UsbHealthWatch([switch]$DryRun) {
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return [pscustomobject]@{ TaskName = $script:TaskName; Status = 'Not installed.' } }
    if ($DryRun) { return [pscustomobject]@{ TaskName = $script:TaskName; Status = 'DRY RUN: would be removed.' } }
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    Write-UDLog "Health watch removed."
    [pscustomobject]@{ TaskName = $script:TaskName; Status = 'Removed.' }
}

function Get-UsbHealthWatchStatus {
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    $h = Get-UDHistory
    [pscustomobject]@{ TaskName = $script:TaskName; Installed = [bool]$t; State = $(if ($t) { "$($t.State)" } else { '' })
        LastRun = $(if ($h.Watch) { $h.Watch.LastRun } else { '' }); LastAlerts = $(if ($h.Watch) { $h.Watch.Alerts } else { '' }) }
}

# ------------------------------------------------------------------ 7. USB port map
function Get-UsbPortLabels {
    $m = @{}
    if (Test-Path -LiteralPath $script:LabelsFile) { try { $o = Get-Content -LiteralPath $script:LabelsFile -Raw | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $m[$p.Name] = "$($p.Value)" } } catch {} }
    $m
}

function Set-UsbPortLabel {
    # Name a physical port (e.g. 'front-left'). Key: the port's location path (stable), or USBDoctor's port key.
    param([string]$Port, [int]$DiskNumber = -1, [string]$Label)
    if ($DiskNumber -ge 0) {
        $d = @(Get-UsbDisks) | Where-Object { $_.Number -eq $DiskNumber }
        if (-not $d) { throw "Disk $DiskNumber is not an attached USB disk." }
        $Port = if ($d.LocationPath) { $d.LocationPath } else { $d.PortKey }
    }
    if (-not $Port) { throw 'Use -LabelPort <text> with -Disk N (the port that drive is plugged into) or -Port <location path / port key from -PortMap>.' }
    $m = Get-UsbPortLabels
    if ($Label) { $m[$Port] = $Label } else { [void]$m.Remove($Port) }
    $dir = Split-Path $script:LabelsFile; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ([pscustomobject]$m | ConvertTo-Json) | Set-Content -LiteralPath $script:LabelsFile -Encoding UTF8
    Write-UDLog "Port label: '$Port' = '$Label'"
    [pscustomobject]@{ Port = $Port; Label = $Label; File = $script:LabelsFile }
}

function Get-PnpProps([string]$Id) {
    $o = @{}
    try { foreach ($p in @(Get-PnpDeviceProperty -InstanceId $Id -KeyName DEVPKEY_Device_FriendlyName, DEVPKEY_Device_DeviceDesc, DEVPKEY_Device_Children, DEVPKEY_Device_LocationInfo, DEVPKEY_Device_LocationPaths, DEVPKEY_Device_Class, DEVPKEY_Device_ProblemCode -ErrorAction Stop)) { $o[$p.KeyName] = $p.Data } } catch {}
    $o
}

function Get-UsbPortMap {
    # Host controllers -> root hubs -> hubs -> ports -> devices, with per-port error/drop history and user labels.
    $labels = Get-UsbPortLabels
    $hist = Get-UDHistory
    $portStats = @{}
    foreach ($dev in $hist.Devices.Values) {
        if (-not $dev.Ports) { continue }
        foreach ($pk in $dev.Ports.Keys) {
            $p = $dev.Ports[$pk]
            if (-not $portStats.ContainsKey($pk)) { $portStats[$pk] = [pscustomobject]@{ Drops = 0; ReadErrors = 0; Seen = 0; Models = @() } }
            $portStats[$pk].Drops += [int]$p.Drops; $portStats[$pk].ReadErrors += [int]$p.ReadErrors; $portStats[$pk].Seen += [int]$p.Seen
            if ($dev.Model -and $portStats[$pk].Models -notcontains $dev.Model) { $portStats[$pk].Models += $dev.Model }
        }
    }
    $disks = @{}; foreach ($d in @(Get-UsbDisks)) { if ($d.ParentId) { $disks[$d.ParentId.ToUpper()] = $d } }
    $ctrls = @(Get-PnpDevice -PresentOnly -Class USB -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -notlike 'USB\*' } | Sort-Object FriendlyName)
    $seenPorts = @{}
    $build = $null
    $build = {
        param([string]$Id, [int]$Depth)
        $pr = Get-PnpProps $Id
        $name = "$($pr['DEVPKEY_Device_FriendlyName'])"; if (-not $name) { $name = "$($pr['DEVPKEY_Device_DeviceDesc'])" }
        $loc = "$($pr['DEVPKEY_Device_LocationInfo'])"; $lp = "$(@($pr['DEVPKEY_Device_LocationPaths'])[0])"
        $kind = if ($Depth -eq 0) { 'Controller' } elseif ($Id -match 'ROOT_HUB') { 'RootHub' } elseif ($name -match '\bHub\b') { 'Hub' } elseif ($Id -like 'USB\*') { 'Device' } else { 'Function' }
        $portNo = if ($loc -match 'Port_#0*(\d+)') { [int]$Matches[1] } else { $null }
        $pk = if ($Id -like 'USB\*' -and $kind -ne 'RootHub') { Get-PortKey $Id $lp $loc } else { '' }
        $st = $null; if ($pk -and $portStats.ContainsKey($pk)) { $st = $portStats[$pk] }
        $lab = if ($lp -and $labels.ContainsKey($lp)) { $labels[$lp] } elseif ($pk -and $labels.ContainsKey($pk)) { $labels[$pk] } else { '' }
        if ($pk) { $seenPorts[$pk] = $true }; if ($lp) { $seenPorts[$lp] = $true }
        $disk = $disks[$Id.ToUpper()]
        $code = 0; try { $code = [int]$pr['DEVPKEY_Device_ProblemCode'] } catch {}
        $kids = @()
        if ($Depth -lt 9 -and $kind -in 'Controller', 'RootHub', 'Hub', 'Device') {
            foreach ($c in @($pr['DEVPKEY_Device_Children'])) {
                if (-not $c) { continue }
                if ($kind -eq 'Device' -and $c -notlike 'USB\*') { continue }   # skip interface/disk/volume plumbing below a device
                $kids += & $build "$c" ($Depth + 1)
            }
        }
        [pscustomobject]@{ InstanceId = $Id; Name = $name; Kind = $kind; Port = $portNo; LocationInfo = $loc; LocationPath = $lp; PortKey = $pk; Label = $lab
            Problem = $code; Drops = $(if ($st) { $st.Drops } else { 0 }); ReadErrors = $(if ($st) { $st.ReadErrors } else { 0 }); Seen = $(if ($st) { $st.Seen } else { 0 })
            Disk = $(if ($disk) { "disk $($disk.Number): $($disk.Summary)" } else { '' }); Children = $kids }
    }
    $tree = @(foreach ($c in $ctrls) { & $build $c.InstanceId 0 })
    $absent = @(foreach ($k in $portStats.Keys) { if (-not $seenPorts.ContainsKey($k)) { $s = $portStats[$k]; [pscustomobject]@{ PortKey = $k; Label = $(if ($labels.ContainsKey($k)) { $labels[$k] } else { '' }); Drops = $s.Drops; ReadErrors = $s.ReadErrors; Seen = $s.Seen; Models = ($s.Models -join ', ') } } })
    $absent += @(foreach ($k in $labels.Keys) { if (-not $seenPorts.ContainsKey($k) -and -not $portStats.ContainsKey($k)) { [pscustomobject]@{ PortKey = $k; Label = $labels[$k]; Drops = 0; ReadErrors = 0; Seen = 0; Models = '' } } })
    [pscustomobject]@{ Time = Get-Date; Controllers = $tree; PortsNotInUse = $absent; LabelsFile = $script:LabelsFile }
}

function Get-PortNodeText($n) {
    $s = switch ($n.Kind) { 'Controller' { "[controller] $($n.Name)" } 'RootHub' { "[root hub] $($n.Name)" } 'Hub' { "$(if ($n.Port) { "port $($n.Port): " })[hub] $($n.Name)" } default { "$(if ($n.Port) { "port $($n.Port): " })$($n.Name)" } }
    if ($n.Label) { $s += "  <$($n.Label)>" }
    if ($n.Disk) { $s += "  = $($n.Disk)" }
    if ($n.Problem) { $s += "  !! problem code $($n.Problem)" }
    if ($n.Drops -or $n.ReadErrors) { $s += "  !! history on this port: $($n.Drops) drop(s), $($n.ReadErrors) read error(s)" }
    elseif ($n.Seen) { $s += "  (history: seen $($n.Seen)x, no errors)" }
    $s
}

function Format-UsbPortMap($Map) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('USB PORT MAP (controllers > root hubs > hubs > ports > devices). Empty ports are not listed by Windows.')
    $walk = $null
    $walk = { param($n, [string]$pre, [bool]$last, [bool]$top)
        $branch = if ($top) { '' } elseif ($last) { '`-- ' } else { '+-- ' }
        $lines.Add($pre + $branch + (Get-PortNodeText $n))
        $np = if ($top) { '  ' } else { $pre + $(if ($last) { '    ' } else { '|   ' }) }
        $kids = @($n.Children)
        for ($i = 0; $i -lt $kids.Count; $i++) { & $walk $kids[$i] $np ($i -eq $kids.Count - 1) $false }
    }
    foreach ($c in @($Map.Controllers)) { & $walk $c '' $true $true }
    if (@($Map.PortsNotInUse).Count) {
        $lines.Add(''); $lines.Add('Ports with history or a label but nothing plugged in now:')
        foreach ($p in $Map.PortsNotInUse) { $lines.Add("  $($p.PortKey)$(if ($p.Label) { "  <$($p.Label)>" }): $($p.Drops) drop(s), $($p.ReadErrors) read error(s)$(if ($p.Models) { "; drives: $($p.Models)" })") }
    }
    $lines.Add(''); $lines.Add("Label a port: USBDoctor -LabelPort 'front-left' -Disk N  (labels: $($Map.LabelsFile))")
    , $lines.ToArray()
}

function ConvertTo-UsbPortMapHtml($Map) {
    $enc = { param($s) [Net.WebUtility]::HtmlEncode("$s") }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('<h3>USB port map</h3><p>Controllers &gt; root hubs &gt; hubs &gt; ports &gt; devices. Red = this port has drops or read errors in the history. Empty ports are not listed by Windows.</p>')
    $node = $null
    $node = { param($n)
        $bad = ($n.Drops -or $n.ReadErrors -or $n.Problem)
        [void]$sb.Append("<li$(if ($bad) { " style='color:#a40e26'" })>" + (& $enc (Get-PortNodeText $n)))
        if ($n.PortKey) { [void]$sb.Append(" <small style='color:#777'>[" + (& $enc $(if ($n.LocationPath) { $n.LocationPath } else { $n.PortKey })) + ']</small>') }
        if (@($n.Children).Count) { [void]$sb.Append('<ul>'); foreach ($k in $n.Children) { & $node $k }; [void]$sb.Append('</ul>') }
        [void]$sb.Append('</li>')
    }
    [void]$sb.Append('<ul>'); foreach ($c in @($Map.Controllers)) { & $node $c }; [void]$sb.Append('</ul>')
    if (@($Map.PortsNotInUse).Count) {
        [void]$sb.Append('<p>Ports with history or a label but nothing plugged in now:</p><ul>')
        foreach ($p in $Map.PortsNotInUse) { [void]$sb.Append('<li>' + (& $enc "$($p.PortKey) $(if ($p.Label) { "<$($p.Label)>" }): $($p.Drops) drop(s), $($p.ReadErrors) read error(s) $($p.Models)") + '</li>') }
        [void]$sb.Append('</ul>')
    }
    $sb.ToString()
}

Export-ModuleMember -Function Set-UDToolsConfig, Get-PrepareCommands, Get-PrepareDisk, Format-UsbDrive, Clear-UsbDrive, Get-IsoKind, Test-WindowsMedia, New-BootableUsb,
    New-VhdFooter, Test-VhdFooter, Add-RawVhdWrap, Remove-RawVhdWrap, Find-CgSecurityTool, Invoke-ImageRecovery,
    Get-BenchmarkComparison, Invoke-UsbBenchmark, Show-UDToast, Invoke-UsbHealthWatch, Install-UsbHealthWatch, Uninstall-UsbHealthWatch, Get-UsbHealthWatchStatus, Get-WatchTaskSpec,
    Get-UsbPortLabels, Set-UsbPortLabel, Get-UsbPortMap, Format-UsbPortMap, ConvertTo-UsbPortMapHtml
