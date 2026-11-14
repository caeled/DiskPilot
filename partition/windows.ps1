$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Import-Module Storage -ErrorAction Stop

function Get-Inventory {
    $pagefiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop)
    foreach ($d in @(Get-Disk | Sort-Object Number)) {
        $blocks = [Collections.Generic.List[string]]::new()
        if ($d.IsBoot -or $d.IsSystem -or $d.BootFromDisk) { $blocks.Add('Boot/system disk') }
        if ($d.IsOffline) { $blocks.Add('Offline disk') }
        if ($d.IsReadOnly) { $blocks.Add('Read-only disk') }
        if ("$($d.HealthStatus)" -ne 'Healthy') { $blocks.Add('Disk health is not Healthy') }
        if ("$($d.BusType)" -notin @('USB','SATA','ATA','NVMe','SAS','SCSI','SD','MMC')) { $blocks.Add('Unsupported storage bus (virtual/RAID/Spaces)') }
        $parts = @()
        # RAW media legitimately have no MSFT_Partition objects.
        if ("$($d.PartitionStyle)" -ne 'RAW') { $parts = @(Get-Partition -DiskNumber $d.Number | Sort-Object PartitionNumber) }
        $rows = @()
        foreach ($p in $parts) {
            $type = "$($p.GptType)".Trim('{}').ToLowerInvariant()
            $reserved = $type -eq 'e3c9e316-0b5c-4db8-817d-f92df00215ae'
            if ($p.IsBoot -or $p.IsSystem -or $p.IsActive -or ($p.IsHidden -and -not $reserved) -or $p.IsReadOnly) { $blocks.Add('Protected partition') }
            if ($type -ne 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7' -and -not $reserved) { $blocks.Add('Special/boot/unknown partition type') }
            $mounts = @($p.AccessPaths | Where-Object { $_ -and $_ -notmatch '^\\\\\?\\Volume\{' } | Sort-Object)
            if ($mounts.Count) { $blocks.Add('Mounted volume: remove drive letters/folder mount points first') }
            if ($pagefiles | Where-Object { $_.Name.StartsWith("$($p.DriveLetter):", [StringComparison]::OrdinalIgnoreCase) }) { $blocks.Add('Pagefile disk') }
            $v = if ($reserved) { @() } else { @($p | Get-Volume -ErrorAction Stop) }
            $fs = if ($v.Count) { "$($v[0].FileSystemType)" } else { '' }
            if ($fs -notin @('', 'Unknown', 'NTFS', 'FAT32', 'exFAT', 'FAT')) { $blocks.Add('Unsupported filesystem') }
            $rows += [pscustomobject]@{ Number=[int]$p.PartitionNumber; Path="Disk$($d.Number)/Partition$($p.PartitionNumber)"; Offset=[long]$p.Offset; Size=[long]$p.Size; FileSystem=$fs; Type="$($p.GptType)"; Mounts=[string[]]$mounts }
        }
        [pscustomobject]@{ Id="$($d.Number)"; Identity="$($d.UniqueId)|$($d.SerialNumber)"; Model="$($d.FriendlyName)"; Size=[long]$d.Size; Table="$($d.PartitionStyle)".ToLowerInvariant(); Bus="$($d.BusType)"; ReadOnly=[bool]$d.IsReadOnly; Blocks=[string[]]@($blocks | Sort-Object -Unique); Partitions=@($rows) }
    }
}

function Invoke-Change([string]$Payload) {
    $data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
    $expected = $data.Disk
    $r = $data.Request
    $now = @(Get-Inventory | Where-Object { $_.Id -eq $expected.Id })
    if ($now.Count -ne 1) { throw 'Disk disappeared or became ambiguous' }
    $now = $now[0]
    if ($now.Identity -ne $expected.Identity -or $now.Size -ne $expected.Size -or $now.Model -ne $expected.Model -or $now.Table -ne $expected.Table) { throw 'Disk identity changed' }
    if ($now.Blocks.Count -or $now.ReadOnly -or $now.Identity -eq '|') { throw 'Disk is protected or identity unavailable' }
    # Compare exact geometry and usage in this same process before calling Storage cmdlets.
    $a = ConvertTo-Json -InputObject @($now.Partitions) -Depth 6 -Compress
    $b = ConvertTo-Json -InputObject @($expected.Partitions) -Depth 6 -Compress
    if ($a -cne $b) { throw 'Partition layout or usage changed' }
    $diskNumber = [uint32]$now.Id
    if ($r.Action -in @('delete', 'format')) {
        $target = @($now.Partitions | Where-Object { $_.Number -eq $r.Partition })
        if ($target.Count -ne 1 -or $target[0].Type.Trim('{}').ToLowerInvariant() -ne 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7') { throw 'Target must be a basic data partition' }
    }
    switch ($r.Action) {
        'init' {
            if ($now.Table -ne 'raw' -or $now.Partitions.Count) { throw 'Initialization requires RAW empty disk' }
            Initialize-Disk -Number $diskNumber -PartitionStyle GPT -Confirm:$false | Out-Null
        }
        'create' { New-Partition -DiskNumber $diskNumber -Offset ([uint64]$r.StartMiB * 1MB) -Size ([uint64]$r.SizeMiB * 1MB) -Confirm:$false | Out-Null }
        'delete' { Get-Partition -DiskNumber $diskNumber -PartitionNumber $r.Partition | Remove-Partition -Confirm:$false }
        'format' { Get-Partition -DiskNumber $diskNumber -PartitionNumber $r.Partition | Format-Volume -FileSystem $r.FileSystem -Confirm:$false | Out-Null }
        default { throw 'Unknown operation' }
    }
}
