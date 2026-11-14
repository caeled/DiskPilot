# Non-elevated mock test of the Invoke-ImageRecovery overlay path. No disk is attached, no diskpart runs:
# Mount/Dismount/Get-DiskImage, Get-AttachedImagePartitions, Get-ImageVolume and New-ImageOverlay are mocked inside the
# module; Add-RawVhdWrap/Remove-RawVhdWrap, Copy-ImageVolumes (real robocopy from temp folders), Remove-ImageOverlay are real.
param([string]$ToolsPath, [string]$CorePath)
$ErrorActionPreference = 'Stop'
$W = Join-Path $env:TEMP 'ud-mockov'; Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $W | Out-Null
Import-Module $CorePath -Force -DisableNameChecking; $m = Import-Module $ToolsPath -Force -DisableNameChecking -PassThru
Set-UDConfig -LogFile (Join-Path $W 'u.log') -HistoryFile (Join-Path $W 'h.json')
foreach ($p in 1, 2) { $s = Join-Path $W "src$p"; New-Item -ItemType Directory "$s\photos" -Force | Out-Null; Set-Content "$s\notes$p.txt" "part $p"; Set-Content "$s\photos\a$p.bin" 'x' }
$img = Join-Path $W 'test.img'; $fs = [IO.File]::Create($img); $fs.SetLength(1MB); $fs.Close(); $h0 = (Get-FileHash $img).Hash
& $m {
    param($W)
    $script:MockW = $W; $script:MockMounted = ''; $script:MockFailRO = @(2)
    function script:Assert-Admin { }
    function script:Mount-DiskImage { param($ImagePath, $Access, $ErrorAction) $script:MockMounted = $ImagePath; $script:MockRO = ($Access -eq 'ReadOnly') }
    function script:Dismount-DiskImage { param($ImagePath, $ErrorAction) $script:MockMounted = '' }
    function script:Get-DiskImage { param($ImagePath, $ErrorAction) [pscustomobject]@{ Number = 99 } }
    function script:Get-AttachedImagePartitions { param($Number) @([pscustomobject]@{ PartitionNumber = 1 }, [pscustomobject]@{ PartitionNumber = 2 }) }
    function script:Get-ImageVolume {
        param($Number, $PartitionNumber)
        if ($script:MockRO -and $PartitionNumber -in $script:MockFailRO) { return [pscustomobject]@{ Letter = ''; Volume = [pscustomobject]@{ FileSystem = ''; FileSystemType = 'Unknown' }; Root = ''; Added = $false; Note = 'mock: mount failed'; MountFailed = $true } }
        [pscustomobject]@{ Letter = ''; Volume = [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemType = 'NTFS'; FileSystemLabel = "P$PartitionNumber" }; Root = (Join-Path $script:MockW "src$PartitionNumber"); Added = $false; Note = ''; MountFailed = $false }
    }
    function script:New-ImageOverlay { param($Parent, $Dirs) $ov = Join-Path $script:MockW 'usbdoctor-overlay-mock.vhd'; Set-Content $ov 'overlay'; $ov }
} $W
$pass = 0; $fail = 0
function T($n, $sb) { try { $o = & $sb; $script:pass++; "PASS $n : $o" } catch { $script:fail++; "FAIL $n : $($_.Exception.Message)" } }
T 'M1 read-only pass, partition 2 needs the overlay (auto), partition 1 read-only' {
    $r = Invoke-ImageRecovery -Image $img -OutDir (Join-Path $W 'out1')
    $t = @($r.Partitions) -join ' || '
    if ($r.FilesCopied -ne 4 -or @($r.Partitions).Count -ne 2 -or @($r.Partitions)[1] -notmatch '^partition 2 .*overlay' -or @($r.Partitions)[0] -match 'overlay' -or (Test-Path (Join-Path $W 'usbdoctor-overlay-mock.vhd')) -or (Get-FileHash $img).Hash -ne $h0 -or -not $r.ImageUnchanged -or @(Get-ChildItem $W -Filter 'test.img.usbdoctor*').Count) { throw "copied=$($r.FilesCopied) parts=$t" }
    "copied=$($r.FilesCopied); $t"
}
T 'M2 -ForceOverlay: both partitions via overlay' {
    $r = Invoke-ImageRecovery -Image $img -OutDir (Join-Path $W 'out2') -ForceOverlay
    $t = @($r.Partitions) -join ' || '
    if ($r.FilesCopied -ne 4 -or @($r.Partitions).Count -ne 2 -or ([regex]::Matches($t, 'overlay')).Count -ne 2 -or (Test-Path (Join-Path $W 'usbdoctor-overlay-mock.vhd')) -or (Get-FileHash $img).Hash -ne $h0) { throw "copied=$($r.FilesCopied) parts=$t" }
    "copied=$($r.FilesCopied); $t"
}
T 'M3 no partition fails: overlay not used' {
    & $m { $script:MockFailRO = @() }
    $r = Invoke-ImageRecovery -Image $img -OutDir (Join-Path $W 'out3'); $t = @($r.Partitions) -join ' || '
    if ($r.FilesCopied -ne 4 -or $t -match 'overlay') { throw "copied=$($r.FilesCopied) parts=$t" }; "copied=$($r.FilesCopied); $t"
}
T 'M4 overlay creation fails (auto mode): partition reported with the reason, no throw' {
    & $m { $script:MockFailRO = @(1, 2); function script:New-ImageOverlay { throw 'mock: diskpart refused' } }
    $r = Invoke-ImageRecovery -Image $img -OutDir (Join-Path $W 'out4'); $t = @($r.Partitions) -join ' || '
    if ($r.FilesCopied -ne 0 -or ([regex]::Matches($t, 'overlay failed: mock')).Count -ne 2 -or (Get-FileHash $img).Hash -ne $h0 -or @(Get-ChildItem $W -Filter 'test.img.usbdoctor*').Count) { throw "copied=$($r.FilesCopied) parts=$t" }; $t
}
T 'M5 overlay creation fails with -ForceOverlay: throws, wrap removed' {
    $e = $null; try { Invoke-ImageRecovery -Image $img -OutDir (Join-Path $W 'out5') -ForceOverlay | Out-Null } catch { $e = $_.Exception.Message }
    if ($e -notmatch 'mock: diskpart refused' -or (Get-FileHash $img).Hash -ne $h0 -or @(Get-ChildItem $W -Filter 'test.img.usbdoctor*').Count) { throw "error=$e" }; "threw: $e"
}
T 'M6 interrupted run with an overlay recorded in the wrap JSON is cleaned up' {
    $st = Add-RawVhdWrap $img; $ov = Join-Path $W 'usbdoctor-overlay-left.vhd'; Set-Content $ov 'x'
    $st | Add-Member -NotePropertyName Overlay -NotePropertyValue $ov -Force; ($st | ConvertTo-Json) | Set-Content "$img.usbdoctor-vhdwrap.json" -Encoding UTF8
    & $m { param($i) Repair-InterruptedWrap $i } $img
    if ((Test-Path $ov) -or (Get-FileHash $img).Hash -ne $h0 -or @(Get-ChildItem $W -Filter 'test.img.usbdoctor*').Count) { throw 'not cleaned' }; 'overlay + wrap removed, image restored'
}
Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue
"DONE pass=$pass fail=$fail"
