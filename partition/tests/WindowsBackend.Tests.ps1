# No disk mutation: native discovery and mutation commands are replaced with fixtures.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../windows.ps1"
$script:called = ''
function Get-CimInstance { @() }
function Get-Disk {
    [pscustomobject]@{ Number=7; UniqueId='fixture-id'; SerialNumber='serial'; FriendlyName='Fixture'; Size=1GB; PartitionStyle='GPT'; BusType='USB'; HealthStatus='Healthy'; IsBoot=$false; IsSystem=$false; BootFromDisk=$false; IsReadOnly=$false; IsOffline=$false }
}
function Get-Partition {
    [pscustomobject]@{ PartitionNumber=1; Offset=1MB; Size=100MB; GptType='{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'; AccessPaths=@('\\?\Volume{fixture}\'); DriveLetter=''; IsBoot=$false; IsSystem=$false; IsActive=$false; IsHidden=$false; IsReadOnly=$false }
}
function Get-Volume { [pscustomobject]@{ FileSystemType='NTFS' } }
function New-Partition { param($DiskNumber, $Offset, $Size, $Confirm) $script:called = "create:$DiskNumber`:$Offset`:$Size" }
function Format-Volume { param([Parameter(ValueFromPipeline)]$InputObject, $FileSystem, $Confirm) process { $script:called = "format:$FileSystem" } }
function Remove-Partition { param([Parameter(ValueFromPipeline)]$InputObject, $Confirm) process { $script:called = 'delete' } }
$disk = @(Get-Inventory)[0]
if ($disk.Blocks.Count -or $disk.Partitions[0].Mounts.Count) { throw 'Volume GUID must not count as user mount' }
function Payload($d, $action) {
    $json = @{ Disk=$d; Request=@{ Action=$action; StartMiB=101; SizeMiB=100; Partition=1; FileSystem='ntfs' } } | ConvertTo-Json -Depth 10 -Compress
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}
foreach ($action in @('create','format','delete')) {
    Invoke-Change (Payload $disk $action)
    if (-not $script:called.StartsWith($action)) { throw "Wrong dispatch for $action" }
    Write-Output "PASS mocked $action"
}
$disk.Identity = 'replacement'
$script:called = ''
$refused = $false
try { Invoke-Change (Payload $disk 'delete') } catch { $refused = $true }
if (-not $refused -or $script:called) { throw 'Identity race not blocked' }
Write-Output 'PASS native identity recheck'
function Get-Partition {
    [pscustomobject]@{ PartitionNumber=1; Offset=1MB; Size=100MB; GptType='{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'; AccessPaths=@('E:\'); DriveLetter='E'; IsBoot=$false; IsSystem=$false; IsActive=$false; IsHidden=$false; IsReadOnly=$false }
}
$mounted = @(Get-Inventory)[0]
if (-not $mounted.Blocks.Count -or $mounted.Partitions[0].Mounts.Count -ne 1) { throw 'Mounted volume not blocked' }
Write-Output 'PASS mounted volume detection'
Write-Output '5 Windows backend fixture tests passed. No real disks accessed.'
