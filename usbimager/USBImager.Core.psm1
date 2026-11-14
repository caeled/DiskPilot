# USBImager.Core.psm1 - engine for USBImager (capture / burn USB images)
# Windows PowerShell 5.1. Requires Administrator for disk access.
$script:Version      = '1.0.0'
$script:LogFile      = Join-Path $env:ProgramData 'USBImager\USBImager.log'
$script:AllowVirtual = $false
$script:Excludes     = @('System Volume Information', '$RECYCLE.BIN')

if (-not ('UsbImgNative' -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Collections.Generic;
using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class UsbImgNative {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr i, uint il, IntPtr o, uint ol, out uint r, IntPtr ov);
  const uint GR = 0x80000000, GW = 0x40000000;
  public static FileStream OpenDisk(int number, bool write) {
    string p = @"\\.\PhysicalDrive" + number;
    SafeFileHandle h = CreateFile(p, write ? (GR | GW) : GR, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (h.IsInvalid) throw new IOException("Cannot open " + p + " (Win32 error " + Marshal.GetLastWin32Error() + ")");
    return new FileStream(h, write ? FileAccess.ReadWrite : FileAccess.Read, 4096, false);
  }
  // Lock (best effort) and dismount a volume, e.g. "H". Handle is closed afterwards.
  public static bool Dismount(string letter) {
    SafeFileHandle h = CreateFile(@"\\.\" + letter + ":", GR | GW, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (h.IsInvalid) return false;
    uint r; DeviceIoControl(h, 0x00090018, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
    bool ok = DeviceIoControl(h, 0x00090020, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
    h.Close(); return ok;
  }
  // Returns {files, folders, bytes, unreadableFolders}; skips reparse-point folders and excluded names.
  public static long[] TreeStats(string root, string[] excludes) {
    HashSet<string> ex = new HashSet<string>(excludes, StringComparer.OrdinalIgnoreCase);
    long f = 0, d = 0, b = 0, bad = 0; Stack<string> st = new Stack<string>(); st.Push(root);
    while (st.Count > 0) {
      string cur = st.Pop(); FileSystemInfo[] items;
      try { items = new DirectoryInfo(cur).GetFileSystemInfos(); } catch { bad++; continue; }
      foreach (FileSystemInfo it in items) {
        if ((it.Attributes & FileAttributes.Directory) != 0) {
          if (ex.Contains(it.Name) || (it.Attributes & FileAttributes.ReparsePoint) != 0) continue;
          d++; st.Push(it.FullName);
        } else { f++; b += ((FileInfo)it).Length; }
      }
    }
    return new long[] { f, d, b, bad };
  }
}
'@
}

function Set-UIConfig {
    param([string]$LogFile, [switch]$AllowVirtual)
    if ($LogFile) { $script:LogFile = $LogFile }
    $script:AllowVirtual = [bool]$AllowVirtual
    $dir = Split-Path $script:LogFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
function Get-UILogFile { $script:LogFile }

function Write-UILog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch {}
    if ($global:USBImagerQueue) { $global:USBImagerQueue.Enqueue($line) } else { Write-Host $line }
}

function Format-Bytes([double]$b) {
    if ($b -ge 1TB) { return '{0:N2} TB' -f ($b / 1TB) }
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    return '{0:N0} KB' -f ($b / 1KB)
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DiskNumberOfPath([string]$Path) {
    # Disk number holding a local path, or -1 for network/unknown.
    if (-not $Path -or $Path -notmatch '^[A-Za-z]:') { return -1 }
    try { return [int](Get-Partition -DriveLetter $Path.Substring(0, 1) -ErrorAction Stop).DiskNumber } catch { return -1 }
}

function Get-ProtectedDiskNumbers {
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    $letters = @('C', 'D', $env:SystemDrive.Substring(0, 1))
    try { $letters += @(Get-CimInstance Win32_PageFileUsage -OperationTimeoutSec 15 -ErrorAction Stop | ForEach-Object { $_.Name.Substring(0, 1) }) } catch {}
    foreach ($l in ($letters | Sort-Object -Unique)) {
        try { [void]$set.Add([int](Get-Partition -DriveLetter $l -ErrorAction Stop).DiskNumber) } catch {}
    }
    foreach ($d in @(Get-Disk)) { if ($d.IsBoot -or $d.IsSystem) { [void]$set.Add([int]$d.Number) } }
    , $set
}

function Get-UsbDisks {
    # Only USB disks (plus attached VHD/VHDX test disks when -AllowVirtual). Never boot/system/C:/D:/pagefile disks.
    $prot = Get-ProtectedDiskNumbers
    foreach ($d in @(Get-Disk | Sort-Object Number)) {
        $bus = "$($d.BusType)"
        $virtual = $bus -eq 'File Backed Virtual'
        if ($prot.Contains([int]$d.Number)) { continue }
        if (-not ($bus -eq 'USB' -or ($virtual -and $script:AllowVirtual))) { continue }
        $vols = @()
        foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object Offset)) {
            $v = $null; try { $v = $p | Get-Volume -ErrorAction Stop } catch {}
            $letter = Get-PartLetter $p
            $vols += [pscustomobject]@{
                PartitionNumber = [int]$p.PartitionNumber; Offset = [long]$p.Offset; PartSize = [long]$p.Size
                Letter = $letter; Label = $(if ($v) { "$($v.FileSystemLabel)" } else { '' })
                FileSystem = $(if ($v) { "$($v.FileSystemType)" } else { '' })
                Size = $(if ($v) { [long]$v.Size } else { 0 }); Free = $(if ($v) { [long]$v.SizeRemaining } else { 0 })
            }
        }
        $sum = ($vols | Where-Object { $_.FileSystem -and $_.FileSystem -ne 'Unknown' } | ForEach-Object {
                $n = if ($_.Letter) { "$($_.Letter):" } else { '(no letter)' }
                '{0} {1} {2} {3}' -f $n, $(if ($_.Label) { $_.Label } else { '(no label)' }), $_.FileSystem, (Format-Bytes $_.Size)
            }) -join '; '
        if (-not $sum) { $sum = $(if ($vols.Count) { 'unreadable / raw partition' } else { 'no partitions' }) }
        [pscustomobject]@{
            Number = [int]$d.Number; Model = "$($d.FriendlyName)".Trim(); Size = [long]$d.Size; Bus = $bus
            Serial = "$($d.SerialNumber)".Trim(); UniqueId = "$($d.UniqueId)"; PartitionStyle = "$($d.PartitionStyle)"
            SectorSize = [int]$d.LogicalSectorSize; ReadOnly = [bool]$d.IsReadOnly; Location = "$($d.Location)"
            Volumes = $vols; Summary = $sum
        }
    }
}

function Get-AllowedDisk([int]$Number) {
    $d = @(Get-UsbDisks) | Where-Object { $_.Number -eq $Number }
    if (-not $d) { throw "Disk $Number is not an attached USB disk this tool may use (system, fixed and non-USB disks are always refused)." }
    $d
}

function Assert-SameDisk($Expected) {
    $now = Get-AllowedDisk $Expected.Number
    if ($now.UniqueId -ne $Expected.UniqueId -or $now.Size -ne $Expected.Size) {
        throw "Disk $($Expected.Number) changed since it was selected (identity or size differs). Nothing was written. Refresh and pick it again."
    }
    if ($now.ReadOnly) { throw "Disk $($Expected.Number) is read-only / write-protected." }
    $now
}

function Invoke-Diskpart([string[]]$Lines) {
    $f = Join-Path $env:TEMP ("usbimager-dp-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $f -Value ($Lines -join "`r`n") -Encoding ASCII
    try { $out = (& diskpart.exe /s $f 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    $tail = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' | '
    Write-UILog "diskpart: $tail"
    if ($rc -ne 0 -or $out -match 'Virtual Disk Service error|DiskPart has encountered an error|is not supported|Access is denied') {
        throw "diskpart failed (exit $rc): $tail"
    }
    $out
}

function Get-PartLetter($p) {
    $c = [string]$p.DriveLetter
    if ($c -and $c.Trim([char]0).Trim() -match '^[A-Za-z]$') { return $c.Trim([char]0).Trim().ToUpper() }
    ''
}

function Get-SafeLabel([string]$Label, [string]$FileSystem) {
    $l = ($Label -replace '[\"\*\?/\\\|,;:\+=<>\[\]\t]', '').Trim()
    $max = if ($FileSystem -eq 'NTFS') { 32 } else { 11 }
    if ($l.Length -gt $max) { $l = $l.Substring(0, $max); Write-UILog "Label shortened to '$l' ($FileSystem allows $max characters)." 'WARN' }
    $l
}

function Invoke-Robo([string]$Source, [string]$Dest, [string]$What) {
    $rlog = Join-Path (Split-Path $script:LogFile) ("robocopy-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-UILog "Copying files $What ($Source -> $Dest). Robocopy log: $rlog"
    $a = @($Source, $Dest, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ', '/MT:8', '/NP', '/NFL', '/NDL', "/UNILOG:$rlog", '/XD') + $script:Excludes
    & robocopy.exe @a | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { throw "Robocopy reported failures (exit $rc). See $rlog" }
    Write-UILog "Robocopy finished (exit $rc)."
}

function Get-TreeStats([string]$Root) {
    $r = [UsbImgNative]::TreeStats($Root, [string[]]$script:Excludes)
    [pscustomobject]@{ Files = $r[0]; Folders = $r[1]; Bytes = $r[2]; Unreadable = $r[3] }
}

function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

function Ensure-Letter([int]$DiskNumber, [int]$PartitionNumber) {
    $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber
    if (-not (Get-PartLetter $p)) {
        $p | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
        Start-Sleep -Seconds 2
        $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber
    }
    Get-PartLetter $p
}

function Dismount-DiskVolumes([int]$DiskNumber) {
    foreach ($p in @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)) {
        $l = Get-PartLetter $p
        if ($l) {
            $ok = [UsbImgNative]::Dismount($l)
            Write-UILog "Dismount ${l}: $(if ($ok) { 'ok' } else { 'not possible (continuing)' })"
        }
    }
}

function Get-DataPartition([int]$DiskNumber) {
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object { $_.Type -notin @('Reserved', 'System') })
    $withFs = @($parts | Where-Object { $v = $_ | Get-Volume -ErrorAction SilentlyContinue; $v -and $v.FileSystemType -and "$($v.FileSystemType)" -ne 'Unknown' })
    if (-not $withFs.Count) { return $null }
    $withFs | Sort-Object Size -Descending | Select-Object -First 1
}

# ------------------------------------------------------------------ CAPTURE
function New-UsbImage {
    param([Parameter(Mandatory)][int]$DiskNumber, [string]$OutDir = 'D:\USB-Backups\Images',
          [ValidateSet('Files', 'RawUsed', 'RawFull')][string]$Mode = 'Files', [string]$Name)
    if (-not (Test-IsAdmin)) { throw 'Administrator rights are required.' }
    $disk = Get-AllowedDisk $DiskNumber
    Write-UILog "=== CAPTURE ($Mode) from disk $($disk.Number): $($disk.Model) $(Format-Bytes $disk.Size) [$($disk.Summary)]"
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath
    if ((Get-DiskNumberOfPath $OutDir) -eq $DiskNumber) { throw 'The image folder is on the drive being captured. Pick a folder on another drive.' }
    if ($Mode -eq 'Files') { New-FileImage $disk $OutDir $Name } else { New-RawImage $disk $OutDir $Name ($Mode -eq 'RawFull') }
}

function Get-FreeBytes([string]$Dir) {
    try { return [long]([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Dir))).AvailableFreeSpace } catch { return [long]::MaxValue }
}

function New-BaseName([string]$Name, [string]$Label) {
    $n = if ($Name) { $Name } elseif ($Label) { $Label } else { 'USB' }
    $n = ($n -replace '[^\w\.\- ]', '_').Trim()
    '{0}-{1}' -f $n, (Get-Date -Format 'yyyyMMdd-HHmm')
}

function New-FileImage($disk, [string]$OutDir, [string]$Name) {
    $part = Get-DataPartition $disk.Number
    if (-not $part) { throw 'No readable file system was found on this drive. Use a Raw capture instead.' }
    $readable = @($disk.Volumes | Where-Object { $_.FileSystem -and $_.FileSystem -ne 'Unknown' })
    if ($readable.Count -gt 1) { Write-UILog "Drive has $($readable.Count) volumes; only the largest (partition $($part.PartitionNumber)) is captured. Use Raw mode to keep all partitions." 'WARN' }
    $letter = Ensure-Letter $disk.Number $part.PartitionNumber
    $vol = Get-Volume -DriveLetter $letter
    $label = "$($vol.FileSystemLabel)"
    $src = "${letter}:\"
    Write-UILog "Source volume ${letter}: label '$label' $($vol.FileSystemType), scanning files..."
    $s = Get-TreeStats $src
    Write-UILog ("Source: {0:N0} files, {1:N0} folders, {2}" -f $s.Files, $s.Folders, (Format-Bytes $s.Bytes))
    if ($s.Unreadable) { Write-UILog "$($s.Unreadable) folder(s) could not be read on the source." 'WARN' }
    $base = New-BaseName $Name $label
    $vhdx = Join-Path $OutDir "$base.vhdx"
    if (Test-Path -LiteralPath $vhdx) { throw "$vhdx already exists." }
    $maxMB = [long][Math]::Ceiling(($s.Bytes * 1.15 + $s.Files * 8KB + $s.Folders * 4KB + 512MB) / 1MB)
    if ($maxMB -lt 1024) { $maxMB = 1024 }
    if ((Get-FreeBytes $OutDir) -lt ($s.Bytes + 512MB)) { throw "Not enough free space in $OutDir for about $(Format-Bytes $s.Bytes)." }
    Write-UILog "Creating expanding VHDX (max $maxMB MB): $vhdx"
    Invoke-Diskpart @("create vdisk file=`"$vhdx`" maximum=$maxMB type=expandable") | Out-Null
    $mounted = $false
    try {
        Mount-DiskImage -ImagePath $vhdx -ErrorAction Stop | Out-Null; $mounted = $true
        $vd = Get-DiskImage -ImagePath $vhdx | Get-Disk
        Initialize-Disk -Number $vd.Number -PartitionStyle MBR -ErrorAction Stop
        $np = New-Partition -DiskNumber $vd.Number -UseMaximumSize -MbrType IFS -ErrorAction Stop
        $np | Format-Volume -FileSystem NTFS -NewFileSystemLabel (Get-SafeLabel $label 'NTFS') -Confirm:$false -Force -ErrorAction Stop | Out-Null
        $il = Ensure-Letter $vd.Number $np.PartitionNumber
        Invoke-Robo $src "${il}:\" 'into image'
        $t = Get-TreeStats "${il}:\"
        Write-UILog ("Image holds: {0:N0} files, {1:N0} folders, {2}" -f $t.Files, $t.Folders, (Format-Bytes $t.Bytes))
        $ok = ($t.Files -eq $s.Files -and $t.Bytes -eq $s.Bytes)
        if (-not $ok) { Write-UILog 'VERIFY MISMATCH between source and image (see robocopy log).' 'ERROR' }
    } finally { if ($mounted) { Dismount-DiskImage -ImagePath $vhdx -ErrorAction SilentlyContinue | Out-Null } }
    Write-UILog 'Computing SHA256 of image...'
    $hash = Get-Sha256 $vhdx
    $len = (Get-Item -LiteralPath $vhdx).Length
    $meta = [ordered]@{
        Tool = 'USBImager'; Version = $script:Version; Format = 'Files-VHDX'; Created = (Get-Date).ToString('o')
        Computer = $env:COMPUTERNAME
        Source = [ordered]@{ Model = $disk.Model; Serial = $disk.Serial; DiskSize = $disk.Size; PartitionStyle = $disk.PartitionStyle
                             Label = $label; FileSystem = "$($vol.FileSystemType)"; VolumeSize = [long]$vol.Size }
        Content = [ordered]@{ Files = $s.Files; Folders = $s.Folders; Bytes = $s.Bytes }
        Image = [ordered]@{ File = (Split-Path $vhdx -Leaf); Length = $len; SHA256 = $hash; Verified = $ok }
    }
    $json = "$vhdx.json"
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $json -Encoding UTF8
    Write-UILog "Saved $vhdx ($(Format-Bytes $len)) + $json. SHA256 $hash"
    if (-not $ok) { throw 'Capture finished but verification failed.' }
    Write-UILog '=== CAPTURE OK'
    [pscustomobject]@{ Image = $vhdx; Metadata = $json; Files = $s.Files; Bytes = $s.Bytes; SHA256 = $hash; Length = $len }
}

function New-RawImage($disk, [string]$OutDir, [string]$Name, [bool]$Full) {
    $len = [long]$disk.Size
    if (-not $Full) {
        $end = 0L; foreach ($v in $disk.Volumes) { $e = $v.Offset + $v.PartSize; if ($e -gt $end) { $end = $e } }
        if ($end -le 0) { throw 'No partitions found; use Raw (whole drive) instead.' }
        $len = [long]([Math]::Ceiling($end / 1MB) * 1MB); if ($len -gt $disk.Size) { $len = [long]$disk.Size }
        if ($disk.PartitionStyle -eq 'GPT') { Write-UILog 'GPT disk: the backup GPT at the end of the drive is not in a used-area image; Windows rebuilds it on restore. Use Raw (whole drive) for an exact copy.' 'WARN' }
    }
    $label = ($disk.Volumes | Where-Object Label | Select-Object -First 1).Label
    $img = Join-Path $OutDir ("{0}.img" -f (New-BaseName $Name $label))
    if ((Get-FreeBytes $OutDir) -lt ($len + 64MB)) { throw "Not enough free space in $OutDir for $(Format-Bytes $len)." }
    Write-UILog "Reading $(Format-Bytes $len) from \\.\PhysicalDrive$($disk.Number) to $img"
    $sha = [Security.Cryptography.SHA256]::Create()
    $in = [UsbImgNative]::OpenDisk($disk.Number, $false)
    $out = [IO.File]::Open($img, 'CreateNew', 'Write')
    try {
        $buf = New-Object byte[] (4MB); $done = 0L; $next = 5
        while ($done -lt $len) {
            $n = [int][Math]::Min($buf.Length, $len - $done)
            $got = 0; while ($got -lt $n) { $r = $in.Read($buf, $got, $n - $got); if ($r -le 0) { throw "Read error at byte $($done + $got)" }; $got += $r }
            $out.Write($buf, 0, $n); [void]$sha.TransformBlock($buf, 0, $n, $null, 0); $done += $n
            $pct = [int](100 * $done / $len); if ($pct -ge $next) { Write-UILog "  read $pct% ($(Format-Bytes $done))"; $next = $pct + 5 }
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
    } finally { $in.Close(); $out.Close() }
    $hash = [BitConverter]::ToString($sha.Hash).Replace('-', '')
    $meta = [ordered]@{
        Tool = 'USBImager'; Version = $script:Version; Format = $(if ($Full) { 'Raw-Full' } else { 'Raw-Used' }); Created = (Get-Date).ToString('o')
        Computer = $env:COMPUTERNAME
        Source = [ordered]@{ Model = $disk.Model; Serial = $disk.Serial; DiskSize = $disk.Size; PartitionStyle = $disk.PartitionStyle
                             Volumes = @($disk.Volumes | ForEach-Object { [ordered]@{ Label = $_.Label; FileSystem = $_.FileSystem; Offset = $_.Offset; Size = $_.PartSize } }) }
        Image = [ordered]@{ File = (Split-Path $img -Leaf); Length = $len; SHA256 = $hash }
    }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$img.json" -Encoding UTF8
    Write-UILog "Saved $img + .json. SHA256 $hash"
    Write-UILog '=== CAPTURE OK'
    [pscustomobject]@{ Image = $img; Metadata = "$img.json"; Length = $len; SHA256 = $hash }
}

# ------------------------------------------------------------------ BURN
function Get-ImageInfo([string]$Path) {
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $meta = $null; if (Test-Path -LiteralPath "$Path.json") { try { $meta = Get-Content -LiteralPath "$Path.json" -Raw | ConvertFrom-Json } catch {} }
    $kind = if ($ext -in '.vhdx', '.vhd') { 'Files' } else { 'Raw' }
    $label = ''; if ($meta -and $meta.Source.PSObject.Properties['Label']) { $label = "$($meta.Source.Label)" }
    [pscustomobject]@{ Path = $Path; Kind = $kind; Meta = $meta; Label = $label; Length = (Get-Item -LiteralPath $Path).Length }
}

function Invoke-UsbBurn {
    param([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][int]$DiskNumber,
          [ValidateSet('NTFS', 'exFAT')][string]$FileSystem = 'NTFS', [string]$Label,
          [Parameter(Mandatory)][string]$ConfirmPhrase, [switch]$SkipHashCheck, [string]$ExpectedUniqueId)
    if (-not (Test-IsAdmin)) { throw 'Administrator rights are required.' }
    if (-not (Test-Path -LiteralPath $ImagePath)) { throw "Image not found: $ImagePath" }
    $ImagePath = (Resolve-Path -LiteralPath $ImagePath).ProviderPath
    $disk = Get-AllowedDisk $DiskNumber
    if ($ExpectedUniqueId -and $disk.UniqueId -ne $ExpectedUniqueId) { throw "Disk $DiskNumber is no longer the drive you selected. Nothing was written." }
    if ($ConfirmPhrase -ne "ERASE $DiskNumber") { throw "Confirmation phrase must be exactly 'ERASE $DiskNumber'. Nothing was written." }
    if ((Get-DiskNumberOfPath $ImagePath) -eq $DiskNumber) { throw 'The image file is on the target drive.' }
    if ($disk.Location -and $disk.Location -ieq $ImagePath) { throw 'Target is the image itself.' }
    $info = Get-ImageInfo $ImagePath
    Write-UILog "=== BURN $($info.Kind) image $ImagePath -> disk $($disk.Number): $($disk.Model) $(Format-Bytes $disk.Size) [$($disk.Summary)]"
    if (-not $SkipHashCheck -and $info.Meta -and $info.Meta.Image.SHA256) {
        Write-UILog 'Checking image SHA256 against its .json...'
        $h = Get-Sha256 $ImagePath
        if ($h -ne $info.Meta.Image.SHA256) { throw "Image checksum does not match its .json ($h). The image may be damaged. Nothing was written." }
        Write-UILog 'Image checksum OK.'
    }
    if ($info.Kind -eq 'Files') { Invoke-FileBurn $info $disk $FileSystem $Label } else { Invoke-RawBurn $info $disk }
}

function Initialize-Target($disk, [string]$FileSystem, [string]$Label) {
    $disk = Assert-SameDisk $disk
    $style = if ($disk.Size -gt 2TB) { 'gpt' } else { 'mbr' }
    Write-UILog "Erasing disk $($disk.Number) and creating one $FileSystem partition over the whole drive ($style, label '$Label')"
    Dismount-DiskVolumes $disk.Number
    $lines = @("select disk $($disk.Number)", 'attributes disk clear readonly noerr', 'clean', "convert $style", 'create partition primary',
               "format fs=$($FileSystem.ToLower()) label=`"$Label`" quick", 'assign')
    Invoke-Diskpart $lines | Out-Null
    Update-HostStorageCache; Start-Sleep -Seconds 3
    $p = Get-DataPartition $disk.Number
    if (-not $p) { throw 'New partition did not appear after formatting.' }
    $letter = Ensure-Letter $disk.Number $p.PartitionNumber
    [pscustomobject]@{ Partition = $p; Letter = $letter }
}

function Report-Fill([int]$DiskNumber) {
    $d = Get-Disk -Number $DiskNumber
    $p = Get-Partition -DiskNumber $DiskNumber | Sort-Object Offset | Select-Object -Last 1
    $end = $p.Offset + $p.Size; $gap = $d.Size - $end
    $pct = 100.0 * $p.Size / $d.Size
    Write-UILog ("Partition {0}: {1} of {2} disk ({3:N2}%), unused at end: {4}" -f $p.PartitionNumber, (Format-Bytes $p.Size), (Format-Bytes $d.Size), $pct, (Format-Bytes ([Math]::Max(0, $gap))))
    ($gap -le 2MB)
}

function Invoke-FileBurn($info, $disk, [string]$FileSystem, [string]$Label) {
    $mounted = $false; $img = $info.Path
    try {
        Write-UILog 'Mounting image read-only...'
        Mount-DiskImage -ImagePath $img -Access ReadOnly -ErrorAction Stop | Out-Null; $mounted = $true
        Start-Sleep -Seconds 2
        $vd = Get-DiskImage -ImagePath $img | Get-Disk
        if ($vd.Number -eq $disk.Number) { throw 'Target is the image itself.' }
        $sp = Get-DataPartition $vd.Number
        if (-not $sp) { throw 'Image has no readable file system.' }
        $sl = Ensure-Letter $vd.Number $sp.PartitionNumber
        $sv = Get-Volume -DriveLetter $sl
        if (-not $Label) { $Label = if ($info.Label) { $info.Label } else { "$($sv.FileSystemLabel)" } }
        $Label = Get-SafeLabel $Label $FileSystem
        $s = Get-TreeStats "${sl}:\"
        Write-UILog ("Image content: {0:N0} files, {1:N0} folders, {2}" -f $s.Files, $s.Folders, (Format-Bytes $s.Bytes))
        if ($s.Bytes + 256MB -gt $disk.Size * 0.97) { throw "Image content ($(Format-Bytes $s.Bytes)) does not fit on $(Format-Bytes $disk.Size). Nothing was written." }
        $t = Initialize-Target $disk $FileSystem $Label
        Invoke-Robo "${sl}:\" "$($t.Letter):\" 'to target'
        $r = Get-TreeStats "$($t.Letter):\"
        Write-UILog ("Target holds: {0:N0} files, {1:N0} folders, {2}" -f $r.Files, $r.Folders, (Format-Bytes $r.Bytes))
        $ok = ($r.Files -eq $s.Files -and $r.Bytes -eq $s.Bytes)
        $fill = Report-Fill $disk.Number
        $v = Get-Volume -DriveLetter $t.Letter
        Write-UILog ("Target $($t.Letter): '{0}' {1}, {2} total, {3} free" -f $v.FileSystemLabel, $v.FileSystemType, (Format-Bytes $v.Size), (Format-Bytes $v.SizeRemaining))
        if (-not $ok) { throw 'VERIFY MISMATCH: file count or bytes differ between image and target (see robocopy log).' }
        if (-not $fill) { Write-UILog 'Partition does not reach the end of the drive.' 'WARN' }
        Write-UILog "=== BURN OK: $($r.Files) files verified on $($t.Letter):"
        [pscustomobject]@{ Letter = $t.Letter; Files = $r.Files; Bytes = $r.Bytes; FillsDisk = $fill; FileSystem = "$($v.FileSystemType)"; Label = "$($v.FileSystemLabel)" }
    } finally { if ($mounted) { Dismount-DiskImage -ImagePath $img -ErrorAction SilentlyContinue | Out-Null } }
}

function Invoke-RawBurn($info, $disk) {
    $img = $info.Path; $offset = 0L; $len = [long]$info.Length
    $fs = [IO.File]::OpenRead($img)
    try {
        $head = New-Object byte[] 512; [void]$fs.Read($head, 0, 512)
        if ([Text.Encoding]::ASCII.GetString($head, 0, 8) -eq 'imageUSB') { $offset = 512; Write-UILog 'ImageUSB .bin header detected; skipping its 512-byte header.' }
        if ($len -ge 1024) {
            $fs.Position = $len - 512; $tail = New-Object byte[] 512; [void]$fs.Read($tail, 0, 512)
            if ([Text.Encoding]::ASCII.GetString($tail, 0, 8) -eq 'conectix') { $len -= 512; Write-UILog 'Fixed-VHD footer detected; it will not be written.' }
        }
        $dataLen = $len - $offset
        $fs.Position = $offset; $mbr = New-Object byte[] 512; [void]$fs.Read($mbr, 0, 512)
        if (-not ($mbr[510] -eq 0x55 -and $mbr[511] -eq 0xAA)) { Write-UILog 'Image does not start with a partition table / boot signature. It will be written as-is.' 'WARN' }
    } finally { $fs.Close() }
    $sector = [Math]::Max(512, $disk.SectorSize)
    $padded = [long]([Math]::Ceiling($dataLen / $sector) * $sector)
    if ($padded -gt $disk.Size) { throw "Image ($(Format-Bytes $padded)) is larger than the target ($(Format-Bytes $disk.Size)). Nothing was written." }
    $disk = Assert-SameDisk $disk
    Write-UILog "Erasing disk $($disk.Number), then writing $(Format-Bytes $dataLen) raw"
    Dismount-DiskVolumes $disk.Number
    Invoke-Diskpart @("select disk $($disk.Number)", 'attributes disk clear readonly noerr', 'clean') | Out-Null
    Start-Sleep -Seconds 2
    $shaI = [Security.Cryptography.SHA256]::Create()
    $in = [IO.File]::OpenRead($img); $in.Position = $offset
    $out = [UsbImgNative]::OpenDisk($disk.Number, $true)
    try {
        $buf = New-Object byte[] (4MB); $done = 0L; $next = 5
        while ($done -lt $padded) {
            $n = [int][Math]::Min($buf.Length, $padded - $done)
            $want = [int][Math]::Max(0, [Math]::Min($n, $dataLen - $done))
            $got = 0; while ($got -lt $want) { $r = $in.Read($buf, $got, $want - $got); if ($r -le 0) { throw 'Short read from image' }; $got += $r }
            if ($want -lt $n) { [Array]::Clear($buf, $want, $n - $want) }
            $out.Write($buf, 0, $n); [void]$shaI.TransformBlock($buf, 0, $n, $null, 0); $done += $n
            $pct = [int](100 * $done / $padded); if ($pct -ge $next) { Write-UILog "  wrote $pct%"; $next = $pct + 5 }
        }
        $out.Flush(); [void]$shaI.TransformFinalBlock($buf, 0, 0)
    } finally { $in.Close(); $out.Close() }
    Write-UILog 'Verifying by reading the drive back...'
    $shaD = [Security.Cryptography.SHA256]::Create(); $chk = [UsbImgNative]::OpenDisk($disk.Number, $false)
    try {
        $buf = New-Object byte[] (4MB); $done = 0L
        while ($done -lt $padded) {
            $n = [int][Math]::Min($buf.Length, $padded - $done)
            $got = 0; while ($got -lt $n) { $r = $chk.Read($buf, $got, $n - $got); if ($r -le 0) { throw 'Read-back error' }; $got += $r }
            [void]$shaD.TransformBlock($buf, 0, $n, $null, 0); $done += $n
        }
        [void]$shaD.TransformFinalBlock($buf, 0, 0)
    } finally { $chk.Close() }
    $hI = [BitConverter]::ToString($shaI.Hash).Replace('-', ''); $hD = [BitConverter]::ToString($shaD.Hash).Replace('-', '')
    if ($hI -ne $hD) { throw "READ-BACK MISMATCH: wrote $hI, drive has $hD" }
    Write-UILog "Read-back verified (SHA256 $hI)."
    # Avoid MBR disk-signature collisions (a duplicate makes Windows take the new disk offline).
    if ($mbr[510] -eq 0x55 -and $mbr[511] -eq 0xAA -and $mbr[450] -ne 0xEE) {
        $sig = [BitConverter]::ToUInt32($mbr, 440)
        $others = @(Get-Disk | Where-Object { $_.Number -ne $disk.Number -and $_.PartitionStyle -eq 'MBR' } | ForEach-Object { [uint32]$_.Signature })
        if ($sig -eq 0 -or $others -contains $sig) {
            $new = [uint32](Get-Random -Minimum 1 -Maximum 2147483647)
            $s0 = [UsbImgNative]::OpenDisk($disk.Number, $true)
            try { $sec = New-Object byte[] $sector; [void]$s0.Read($sec, 0, $sector); [BitConverter]::GetBytes($new).CopyTo($sec, 440); $s0.Position = 0; $s0.Write($sec, 0, $sector); $s0.Flush() } finally { $s0.Close() }
            Write-UILog ('Disk signature {0:X8} was already in use; changed to {1:X8}.' -f $sig, $new)
        }
    }
    Update-HostStorageCache; Start-Sleep -Seconds 4
    $p = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Sort-Object Offset | Select-Object -Last 1
    $extended = $false; $letter = ''
    if ($p) {
        $v = $p | Get-Volume -ErrorAction SilentlyContinue
        $fsType = if ($v) { "$($v.FileSystemType)" } else { '' }
        if ($fsType -eq 'NTFS') {
            $sz = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $p.PartitionNumber
            if ($sz.SizeMax -gt $p.Size + 1MB) {
                Write-UILog "Extending NTFS partition $($p.PartitionNumber) from $(Format-Bytes $p.Size) to $(Format-Bytes $sz.SizeMax)"
                Resize-Partition -DiskNumber $disk.Number -PartitionNumber $p.PartitionNumber -Size $sz.SizeMax -ErrorAction Stop
            }
            $extended = $true
        } elseif ($fsType) {
            Write-UILog "Last partition is $fsType, which Windows cannot extend in place. Restored as-is; for full size capture it in Files mode and burn that image instead." 'WARN'
        } else { Write-UILog 'No readable file system found on the written partition table.' 'WARN' }
        try { $letter = Ensure-Letter $disk.Number $p.PartitionNumber } catch { Write-UILog "Could not assign a drive letter: $_" 'WARN' }
    } else { Write-UILog 'Windows found no partitions in the written image.' 'WARN' }
    $fill = if ($p) { Report-Fill $disk.Number } else { $false }
    if ($letter) {
        $s = Get-TreeStats "${letter}:\"; $vv = Get-Volume -DriveLetter $letter
        Write-UILog ("Target ${letter}: '{0}' {1}, {2} total, {3:N0} files, {4}" -f $vv.FileSystemLabel, $vv.FileSystemType, (Format-Bytes $vv.Size), $s.Files, (Format-Bytes $s.Bytes))
    }
    Write-UILog '=== BURN OK (raw)'
    [pscustomobject]@{ Letter = $letter; Extended = $extended; FillsDisk = $fill; SHA256 = $hI }
}

Export-ModuleMember -Function Set-UIConfig, Get-UILogFile, Write-UILog, Format-Bytes, Test-IsAdmin, Get-UsbDisks, Get-AllowedDisk,
    New-UsbImage, Invoke-UsbBurn, Get-ImageInfo, Get-TreeStats
