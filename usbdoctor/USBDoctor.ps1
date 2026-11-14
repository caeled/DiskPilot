<#
 USBDoctor - diagnose USB drive problems read-only, decide who is at fault (drive, connection, this PC, permissions),
 and offer only the repairs that are safe for that state. Follows the USB problem catalog in docs/USB-Problem-Catalog.md (#0-#15 + refusal list).
 GUI:  USBDoctor.ps1            (or double-click USBDoctor.cmd)
 CLI (read-only, no UAC):  -List | -Diagnose [-Disk N] | -Report [-ReportDir X]
      -Tier0Result OtherPortFails|OtherPortWorks|OtherMachineFails|OtherMachineWorks (-Disk N | -Device <identity>)
      -FixImageUsbShift -Image <imageusb.bin/img> [-Out clean.img]      (fixes the IMAGE FILE only)
 CLI (repairs, UAC):
      -AssignLetter -Disk N [-Partition P] [-Letter X] [-Persistent] [-Force]      (no image needed)
      -Online -Disk N | -ClearReadOnly -Disk N | -Chkdsk -Letter X | -Extend -Disk N | -ConvertToNtfs -Letter X
      -RestoreBootSector -Disk N [-Partition P] | -RestoreGpt -Disk N
          -> refused on dying drives; otherwise need a complete Rescue image of the drive, or -ConfirmPhrase "REPAIR N"
      -FixImageUsbShift -Disk N [-Out clean.img]    image the stick, strip the imageUSB header from the image, burn with USBImager
      -CapacityTest -Disk N [-Quick] -ConfirmPhrase "ERASE N"    blank sticks only, erases it
      -Rescue -Disk N | -WaitForModel <text>  [-Out file.img] [-WaitMinutes 30]
      -EnableAutomount | -DisableSelectiveSuspend | -RemoveGhostDevices [-IncludeOldDrives] | -ResetDevice -Device <instance id> | -Eject -Letter X
 USBDoctor never formats anything as a repair and never writes an MBR. Only USB disks are ever changed; the disks holding
 C:, D:, Windows, boot and the pagefile are always refused.
#>
[CmdletBinding()]
param(
    [switch]$List, [switch]$Diagnose, [switch]$Report,
    [switch]$AssignLetter, [switch]$EnableAutomount, [switch]$Online, [switch]$Chkdsk, [switch]$DisableSelectiveSuspend,
    [switch]$RemoveGhostDevices, [switch]$IncludeOldDrives, [switch]$FixImageUsbShift, [switch]$Extend, [switch]$ConvertToNtfs,
    [switch]$Eject, [switch]$Rescue, [switch]$ClearReadOnly, [switch]$RestoreBootSector, [switch]$RestoreGpt, [switch]$CapacityTest, [switch]$Quick,
    [switch]$ResetDevice, [ValidateSet('', 'OtherPortFails', 'OtherPortWorks', 'OtherMachineFails', 'OtherMachineWorks')][string]$Tier0Result = '', [string]$Device, [string]$Image, [string]$Note,
    [int]$Disk = -1, [int]$Partition = 0, [string]$Letter, [switch]$Persistent, [switch]$Force,
    [string]$ConfirmPhrase, [switch]$Confirm, [string]$BackupDir, [string]$Out, [string]$WaitForModel, [int]$WaitMinutes = 30,
    [string]$ReportDir, [int]$Days = 7, [string]$LogFile,
    [switch]$NoElevate, [switch]$Elevate, [switch]$PauseAtEnd, [switch]$SmokeTest,
    [Parameter(DontShow)][switch]$AllowVirtual,
    [Parameter(DontShow)][string]$SimulateBadRanges,
    [Parameter(DontShow)][int64]$SimulateDropAt = -1,
    [Parameter(DontShow)][int64]$StopAfterBytes = 0,
    [Parameter(DontShow)][int64]$SimulateWrapAt = 0,
    [Parameter(DontShow)][int]$SimulateRawTimeoutDisk = -1,
    [Parameter(DontShow)][string]$HistoryFile
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$core = Join-Path $here 'USBDoctor.Core.psm1'
Import-Module $core -Force -DisableNameChecking
$hooks = @{}; if ($SimulateRawTimeoutDisk -ge 0) { $hooks.RawTimeoutDisk = $SimulateRawTimeoutDisk }
Set-UDConfig -LogFile $LogFile -AllowVirtual:$AllowVirtual -HistoryFile $HistoryFile -TestHooks $hooks
$fileOnlyFix = $FixImageUsbShift -and $Image -and $Disk -lt 0
$readOnlyCli = $List -or $Diagnose -or $Report -or [bool]$Tier0Result -or $fileOnlyFix
$changeCli = $AssignLetter -or $EnableAutomount -or $Online -or $Chkdsk -or $DisableSelectiveSuspend -or $RemoveGhostDevices -or ($FixImageUsbShift -and -not $fileOnlyFix) -or $Extend -or $ConvertToNtfs -or $Eject -or $Rescue -or
    $ClearReadOnly -or $RestoreBootSector -or $RestoreGpt -or $CapacityTest -or $ResetDevice
$isCli = $readOnlyCli -or $changeCli

function ConvertTo-Unc([string]$p) {
    # Elevated sessions do not see the user's mapped drives (e.g. Z:), so pass UNC paths.
    if ($p -match '^([A-Za-z]):') {
        $d = Get-PSDrive -Name $Matches[1] -ErrorAction SilentlyContinue
        if ($d -and $d.DisplayRoot -and $d.DisplayRoot.StartsWith('\\')) { return $d.DisplayRoot.TrimEnd('\') + $p.Substring(2) }
    }
    $p
}

$needAdmin = ((-not $isCli) -and -not $SmokeTest) -or $changeCli -or $Elevate
if ($needAdmin -and -not (Test-IsAdmin) -and -not $NoElevate) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA')
    if (-not $isCli) { $argList += @('-WindowStyle', 'Hidden') }
    $argList += @('-File', ('"{0}"' -f (ConvertTo-Unc $MyInvocation.MyCommand.Path)))
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'Elevate') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } }
        else { $s = "$v"; if ($k -in 'Out', 'BackupDir', 'ReportDir', 'LogFile', 'Image', 'HistoryFile') { $s = ConvertTo-Unc $s }; $argList += "-$k"; $argList += ('"{0}"' -f $s) }
    }
    if ($isCli -and -not $PauseAtEnd) { $argList += '-PauseAtEnd' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList | Out-Null }
    catch {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show('USBDoctor needs administrator approval (UAC) to repair drives. Read-only checks work without it: USBDoctor.ps1 -Diagnose', 'USBDoctor') | Out-Null
    }
    return
}

# ------------------------------------------------------------------ CLI
function Confirm-Cli($plan) {
    Write-Host ''
    Write-Host "== $($plan.Title)" -ForegroundColor Cyan
    Write-Host $plan.Text
    if ($plan.Text -match 'Nothing to do\.') { return 'skip' }
    if ($plan.Destructive) {
        $p = $ConfirmPhrase
        if (-not $p) { Write-Host ''; $p = Read-Host "This writes to disk $($plan.DiskNumber). Type $($plan.Phrase) to continue" }
        if ($p -cne $plan.Phrase) { throw "Confirmation did not match '$($plan.Phrase)'. Nothing was changed." }
        return $p
    }
    if ($Confirm) { return 'yes' }
    $a = Read-Host 'Go ahead? (Y/N)'
    if ($a -notmatch '^[Yy]') { throw 'Cancelled. Nothing was changed.' }
    'yes'
}

function Show-Result($r) { if ($r) { $r | Format-List | Out-String -Width 200 | Write-Host } }

if ($isCli) {
    $code = 0
    try {
        if ($List) {
            $d = @(Get-UsbDisks)
            if (-not $d.Count) { Write-Host 'No USB disks found.' }
            foreach ($x in $d) { (Format-UsbDisk $x) | Write-Host; Write-Host '' }
            $p = @(Get-UsbProblemDevices | Where-Object { $_.Kind -ne 'OldDrive' })
            if ($p.Count) { Write-Host 'Problem / leftover USB device entries:'; $p | Format-Table Kind, Present, Code, FriendlyName, InstanceId -AutoSize | Out-String -Width 220 | Write-Host }
        }
        if ($Diagnose) { (Format-UsbDiagnosis (Invoke-UsbDiagnosis -DiskNumber $Disk -Days $Days)) | Write-Host }
        if ($Report) { Show-Result (New-UsbDoctorReport -OutDir $ReportDir -Days $Days) }
        if ($AssignLetter) {
            if ($Disk -lt 0) { throw 'Use -AssignLetter -Disk N [-Partition P] [-Letter X] [-Persistent].' }
            $a = @{ DiskNumber = $Disk; PartitionNumber = $Partition; Letter = $Letter; Persistent = $Persistent; Force = $Force }
            if ((Confirm-Cli (Set-UsbDriveLetter @a -Preview)) -ne 'skip') { Show-Result (Set-UsbDriveLetter @a) }
        }
        if ($EnableAutomount) { if ((Confirm-Cli (Enable-UsbAutomount -Preview)) -ne 'skip') { Show-Result (Enable-UsbAutomount) } }
        if ($DisableSelectiveSuspend) { if ((Confirm-Cli (Disable-UsbSelectiveSuspend -Preview)) -ne 'skip') { Show-Result (Disable-UsbSelectiveSuspend) } }
        if ($RemoveGhostDevices) { if ((Confirm-Cli (Remove-UsbGhostDevices -IncludeOldDrives:$IncludeOldDrives -Preview)) -ne 'skip') { Show-Result (Remove-UsbGhostDevices -IncludeOldDrives:$IncludeOldDrives) } }
        if ($Tier0Result) { Show-Result (Set-Tier0Result -DiskNumber $Disk -Device $Device -Result $Tier0Result -Note $Note) }
        if ($Online) {
            if ($Disk -lt 0) { throw 'Use -Online -Disk N.' }
            $p = Confirm-Cli (Set-UsbDiskOnline -DiskNumber $Disk -Preview); if ($p -ne 'skip') { Show-Result (Set-UsbDiskOnline -DiskNumber $Disk -ConfirmPhrase $p) }
        }
        if ($ClearReadOnly) {
            if ($Disk -lt 0) { throw 'Use -ClearReadOnly -Disk N.' }
            $p = Confirm-Cli (Clear-UsbReadOnly -DiskNumber $Disk -Preview); if ($p -ne 'skip') { Show-Result (Clear-UsbReadOnly -DiskNumber $Disk -ConfirmPhrase $p) }
        }
        if ($Chkdsk) {
            if (-not $Letter) { throw 'Use -Chkdsk -Letter X.' }
            $p = Confirm-Cli (Invoke-UsbChkdsk -Letter $Letter -Preview); if ($p -ne 'skip') { Show-Result (Invoke-UsbChkdsk -Letter $Letter -ConfirmPhrase $p) }
        }
        if ($Extend) {
            if ($Disk -lt 0) { throw 'Use -Extend -Disk N [-Partition P].' }
            $p = Confirm-Cli (Expand-UsbPartition -DiskNumber $Disk -PartitionNumber $Partition -Preview)
            if ($p -ne 'skip') { Show-Result (Expand-UsbPartition -DiskNumber $Disk -PartitionNumber $Partition -ConfirmPhrase $p) }
        }
        if ($ConvertToNtfs) {
            if (-not $Letter) { throw 'Use -ConvertToNtfs -Letter X.' }
            $p = Confirm-Cli (Convert-UsbToNtfs -Letter $Letter -Preview)
            if ($p -ne 'skip') { Show-Result (Convert-UsbToNtfs -Letter $Letter -ConfirmPhrase $p) }
        }
        if ($RestoreBootSector) {
            if ($Disk -lt 0) { throw 'Use -RestoreBootSector -Disk N [-Partition P].' }
            $p = Confirm-Cli (Restore-UsbBootSector -DiskNumber $Disk -PartitionNumber $Partition -Preview)
            if ($p -ne 'skip') { Show-Result (Restore-UsbBootSector -DiskNumber $Disk -PartitionNumber $Partition -ConfirmPhrase $p) }
        }
        if ($RestoreGpt) {
            if ($Disk -lt 0) { throw 'Use -RestoreGpt -Disk N.' }
            $p = Confirm-Cli (Restore-UsbGpt -DiskNumber $Disk -Preview); if ($p -ne 'skip') { Show-Result (Restore-UsbGpt -DiskNumber $Disk -ConfirmPhrase $p) }
        }
        if ($FixImageUsbShift) {
            if ($Image -and $Disk -lt 0) { [void](Confirm-Cli (Convert-ImageUsbFile -Image $Image -Out $Out -Preview)); Show-Result (Convert-ImageUsbFile -Image $Image -Out $Out) }
            elseif ($Disk -ge 0) { [void](Confirm-Cli (Invoke-ImageUsbFix -DiskNumber $Disk -OutFile $Out -Preview)); Show-Result (Invoke-ImageUsbFix -DiskNumber $Disk -OutFile $Out) }
            else { throw 'Use -FixImageUsbShift -Disk N [-Out clean.img] (images the stick first) or -FixImageUsbShift -Image file [-Out clean.img].' }
        }
        if ($CapacityTest) {
            if ($Disk -lt 0) { throw 'Use -CapacityTest -Disk N [-Quick] -ConfirmPhrase "ERASE N".' }
            $p = Confirm-Cli (Test-UsbCapacity -DiskNumber $Disk -Quick:$Quick -Preview)
            Show-Result (Test-UsbCapacity -DiskNumber $Disk -Quick:$Quick -ConfirmPhrase $p -SimulateWrapAt $SimulateWrapAt)
        }
        if ($ResetDevice) {
            if (-not $Device) { throw 'Use -ResetDevice -Device <instance id> (see -List).' }
            [void](Confirm-Cli (Reset-UsbDevice -InstanceId $Device -Preview)); Show-Result (Reset-UsbDevice -InstanceId $Device)
        }
        if ($Rescue) {
            if ($Disk -lt 0 -and -not $WaitForModel) { throw 'Use -Rescue -Disk N or -Rescue -WaitForModel <text>, optional -Out file.img.' }
            Show-Result (Start-UsbRescue -DiskNumber $Disk -WaitForModel $WaitForModel -OutFile $Out -WaitMinutes $WaitMinutes -SimulateBadRanges $SimulateBadRanges -SimulateDropAt $SimulateDropAt -StopAfterBytes $StopAfterBytes)
        }
        if ($Eject) {
            if (-not $Letter -and $Disk -lt 0) { throw 'Use -Eject -Letter X (or -Disk N).' }
            [void](Confirm-Cli (Dismount-UsbDrive -Letter $Letter -DiskNumber $Disk -Preview)); Show-Result (Dismount-UsbDrive -Letter $Letter -DiskNumber $Disk)
        }
    } catch { Write-UDLog "FAILED: $($_.Exception.Message)" 'ERROR'; $code = 1 }
    if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }
    exit $code
}

# ------------------------------------------------------------------ GUI
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$global:USBDoctorQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$queue = $global:USBDoctorQueue
$shared = [hashtable]::Synchronized(@{ Cancel = $false; Diag = $null; Result = $null })
$font = New-Object Drawing.Font('Segoe UI', 9)

$form = New-Object Windows.Forms.Form
$form.Text = "USBDoctor $(Get-UDVersion) - diagnose and repair USB drives"
$form.Size = New-Object Drawing.Size(1080, 930); $form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'; $form.Font = $font

function New-Ctl($type, $x, $y, $w, $h, $text, $parent) {
    $c = New-Object "Windows.Forms.$type"; $c.Location = New-Object Drawing.Point($x, $y); $c.Size = New-Object Drawing.Size($w, $h)
    if ($null -ne $text) { $c.Text = $text }; $parent.Controls.Add($c); $c
}

$lblDisks = New-Ctl Label 12 10 800 20 'USB drives (internal and system disks are never shown):' $form
$btnRefresh = New-Ctl Button 950 6 100 26 'Re-check' $form; $btnRefresh.Anchor = 'Top,Right'
$lv = New-Ctl ListView 12 34 1038 140 $null $form
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false; $lv.Anchor = 'Top,Left,Right'
foreach ($c in @(@('Disk', 40), @('Model', 150), @('Size', 70), @('USB ID', 95), @('Serial', 110), @('Volumes', 230), @('State', 200), @('Fault owner', 140))) { [void]$lv.Columns.Add($c[0], $c[1]) }
$lblSys = New-Ctl Label 12 178 1038 34 'Checking this PC...' $form; $lblSys.Anchor = 'Top,Left,Right'

$txtFind = New-Ctl TextBox 12 214 560 404 '' $form
$txtFind.Multiline = $true; $txtFind.ScrollBars = 'Both'; $txtFind.ReadOnly = $true; $txtFind.WordWrap = $true
$txtFind.Font = New-Object Drawing.Font('Consolas', 9); $txtFind.Anchor = 'Top,Left,Right'

$g = New-Ctl GroupBox 582 208 468 410 'Fixes (each previews, refuses if unsafe, asks first)' $form; $g.Anchor = 'Top,Right'
New-Ctl Label 10 24 50 20 'Letter:' $g | Out-Null
$cmbLetter = New-Ctl ComboBox 60 21 55 23 $null $g; $cmbLetter.DropDownStyle = 'DropDownList'
$chkPersist = New-Ctl CheckBox 122 22 120 22 'Keep this letter' $g; $chkPersist.Checked = $true
$chkForce = New-Ctl CheckBox 245 22 130 22 'Release reservation' $g
$btnLetter = New-Ctl Button 378 19 80 27 'Assign' $g
$y = 54
$btnChk = New-Ctl Button 10 $y 145 28 'Check disk (chkdsk)...' $g
$btnOnline = New-Ctl Button 160 $y 145 28 'Bring online...' $g
$btnRO = New-Ctl Button 310 $y 148 28 'Clear read-only...' $g
$y += 32
$btnExtend = New-Ctl Button 10 $y 145 28 'Extend to full size...' $g
$btnConvert = New-Ctl Button 160 $y 145 28 'FAT32 to NTFS...' $g
$btnShift = New-Ctl Button 310 $y 148 28 'ImageUSB: image + fix...' $g
$y += 32
$btnBoot = New-Ctl Button 10 $y 145 28 'Restore boot sector...' $g
$btnGpt = New-Ctl Button 160 $y 145 28 'Restore GPT...' $g
$btnCap = New-Ctl Button 310 $y 148 28 'Capacity test (erases)...' $g
foreach ($b in @($btnExtend, $btnConvert, $btnBoot, $btnGpt, $btnCap, $btnChk, $btnRO, $btnOnline)) { $b.ForeColor = [Drawing.Color]::DarkRed }
$y += 32
$btnEject = New-Ctl Button 10 $y 145 28 'Safe eject' $g
New-Ctl Label 160 ($y + 6) 300 20 'Red = writes; needs a Rescue image or typed REPAIR N.' $g | Out-Null
$y += 36
New-Ctl Label 10 ($y + 4) 450 20 'Tier 0 - after trying the selected drive on another port / PC:' $g | Out-Null
$y += 24
$btnT0a = New-Ctl Button 10 $y 110 28 'Port: fails' $g
$btnT0b = New-Ctl Button 122 $y 110 28 'Port: works' $g
$btnT0c = New-Ctl Button 234 $y 110 28 'Other PC: fails' $g
$btnT0d = New-Ctl Button 346 $y 112 28 'Other PC: works' $g
$y += 36
New-Ctl Label 10 ($y + 4) 120 20 'This PC:' $g | Out-Null
$y += 24
$btnAuto = New-Ctl Button 10 $y 145 28 'Turn on automount' $g
$btnSuspend = New-Ctl Button 160 $y 145 28 'USB power saving off' $g
$btnGhost = New-Ctl Button 310 $y 148 28 'Remove failed devices' $g
$y += 38
New-Ctl Label 10 ($y + 3) 130 20 'Rescue copy to:' $g | Out-Null
$txtOut = New-Ctl TextBox 140 $y 230 23 '' $g
$btnOut = New-Ctl Button 376 ($y - 1) 82 25 'Browse...' $g
$y += 30
$btnRescue = New-Ctl Button 140 $y 150 28 'Start rescue copy' $g
$btnStop = New-Ctl Button 296 $y 80 28 'Stop' $g; $btnStop.Enabled = $false
$btnReport = New-Ctl Button 10 $y 125 28 'Save report' $g
$btnLog = New-Ctl Button 381 $y 77 28 'Log...' $g

$progress = New-Ctl ProgressBar 12 626 1038 14 $null $form
$progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 0; $progress.Anchor = 'Top,Left,Right'
$txtLog = New-Ctl TextBox 12 646 1038 230 '' $form
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true; $txtLog.WordWrap = $false
$txtLog.Font = New-Object Drawing.Font('Consolas', 9); $txtLog.Anchor = 'Top,Bottom,Left,Right'

$script:diag = $null; $script:job = $null
$allButtons = @($btnRefresh, $btnLetter, $btnChk, $btnOnline, $btnRO, $btnEject, $btnExtend, $btnConvert, $btnShift, $btnBoot, $btnGpt, $btnCap, $btnT0a, $btnT0b, $btnT0c, $btnT0d, $btnAuto, $btnSuspend, $btnGhost, $btnRescue, $btnReport, $btnOut)

function Fill-Letters {
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
    $used += @(Get-ChildItem HKCU:\Network -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName.ToUpper() })
    $cur = "$($cmbLetter.SelectedItem)"
    $cmbLetter.Items.Clear()
    foreach ($c in [char[]](68..90)) { $s = [string]$c; if ($s -notin $used) { [void]$cmbLetter.Items.Add($s) } }
    if ($cur -and $cmbLetter.Items.Contains($cur)) { $cmbLetter.SelectedItem = $cur } elseif ($cmbLetter.Items.Count) { $cmbLetter.SelectedIndex = $cmbLetter.Items.Count - 1 }
}

function Show-Diag {
    $lv.Items.Clear()
    $d = $script:diag
    if (-not $d) { return }
    foreach ($r in $d.Disks) {
        $x = $r.Disk
        $it = New-Object Windows.Forms.ListViewItem("$($x.Number)")
        foreach ($s in @($x.Model, (Format-Bytes $x.Size), $(if ($x.VID) { "$($x.VID):$($x.PID)" } else { '-' }), $x.Serial, $x.Summary, $r.Verdict, $r.Assessment.FaultOwner)) { [void]$it.SubItems.Add("$s") }
        switch ($r.Level) { 'FAILING' { $it.ForeColor = [Drawing.Color]::DarkRed } 'PROBLEM' { $it.ForeColor = [Drawing.Color]::Firebrick } 'WARN' { $it.ForeColor = [Drawing.Color]::DarkGoldenrod } }
        $it.Tag = $r; [void]$lv.Items.Add($it)
    }
    $lblDisks.Text = "USB drives (internal and system disks are never shown): $($d.Disks.Count) found, checked $($d.Time.ToString('HH:mm:ss'))"
    $lblSys.Text = 'This PC: ' + ((@($d.System | Where-Object { $_.Level -ne 'INFO' -or $_.Code -in 'Ghosts' }) | ForEach-Object { $_.Text }) -join '  |  ')
    if ($lv.Items.Count) { $lv.Items[0].Selected = $true } else { $txtFind.Text = ((Format-UsbDiagnosis $d) -join "`r`n") }
}

function Get-Selected { if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Tag } else { $null } }
function Need-Selected { $s = Get-Selected; if (-not $s) { [Windows.Forms.MessageBox]::Show('Select a USB drive in the list first.', 'USBDoctor') | Out-Null }; $s }
function Get-SelLetter($r) { ($r.Disk.Volumes | Where-Object Letter | Sort-Object PartSize -Descending | Select-Object -First 1).Letter }

function Set-Busy([bool]$b) {
    foreach ($c in $allButtons) { $c.Enabled = -not $b }
    $lv.Enabled = -not $b; $btnStop.Enabled = $b -and $script:job -and $script:job.Fn -in 'Start-UsbRescue', 'Invoke-ImageUsbFix'
    $progress.MarqueeAnimationSpeed = if ($b) { 30 } else { 0 }
}

function Start-Work([string]$Fn, [hashtable]$P, [string]$Title) {
    $shared.Cancel = $false
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('USBDoctorQueue', $queue)
    $rs.SessionStateProxy.SetVariable('USBDoctorShared', $shared)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Core, $Log, $AllowVirtual, $Fn, $P)
        $ErrorActionPreference = 'Stop'
        try {
            Import-Module $Core -Force -DisableNameChecking
            Set-UDConfig -LogFile $Log -AllowVirtual:$AllowVirtual
            if ($Fn -in 'Start-UsbRescue', 'Invoke-ImageUsbFix') { $P.Control = $USBDoctorShared }
            $r = & $Fn @P
            if ($Fn -eq 'Invoke-UsbDiagnosis') { $USBDoctorShared.Diag = $r; $USBDoctorQueue.Enqueue('##DONE##OK##') }
            else { $USBDoctorQueue.Enqueue('##DONE##OK##' + (($r | Format-List | Out-String -Width 160).Trim())) }
        } catch {
            try { Write-UDLog "FAILED: $($_.Exception.Message)" 'ERROR' } catch {}
            $USBDoctorQueue.Enqueue('##DONE##FAIL##' + $_.Exception.Message)
        }
    }).AddArgument($core).AddArgument((Get-UDLogFile)).AddArgument([bool]$AllowVirtual).AddArgument($Fn).AddArgument($P)
    $script:job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Fn = $Fn; Title = $Title }
    Set-Busy $true
}

function Start-Scan { $txtLog.AppendText("--- Checking USB drives (this can take 20-30 seconds the first time)`r`n"); Start-Work 'Invoke-UsbDiagnosis' @{ Days = $Days } 'Check' }

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 300
$timer.Add_Tick({
    $line = $null
    while ($queue.TryDequeue([ref]$line)) {
        if ($line.StartsWith('##DONE##')) {
            $ok = $line.StartsWith('##DONE##OK##'); $msg = $line.Substring($(if ($ok) { 12 } else { 14 }))
            $fn = ''; $title = ''
            if ($script:job) { try { $script:job.PS.EndInvoke($script:job.Handle) | Out-Null } catch {}; $script:job.PS.Dispose(); $script:job.RS.Dispose(); $fn = $script:job.Fn; $title = $script:job.Title; $script:job = $null }
            Set-Busy $false
            if ($fn -eq 'Invoke-UsbDiagnosis') {
                if ($ok) { $script:diag = $shared.Diag; Show-Diag; Fill-Letters; $txtLog.AppendText("Check finished.`r`n") }
                else { [Windows.Forms.MessageBox]::Show("Checking failed:`n`n$msg", 'USBDoctor', 'OK', 'Error') | Out-Null }
            } else {
                if ($ok) { [Windows.Forms.MessageBox]::Show("$title finished.`n`n$msg", 'USBDoctor', 'OK', 'Information') | Out-Null }
                else { [Windows.Forms.MessageBox]::Show("$title failed:`n`n$msg`n`nSee the log for details.", 'USBDoctor', 'OK', 'Error') | Out-Null }
                Start-Scan
            }
        } else { $txtLog.AppendText($line + "`r`n") }
    }
})

function Show-Confirm($plan) {
    # Returns $null (cancel), 'yes', or the typed phrase for destructive fixes.
    $f = New-Object Windows.Forms.Form; $f.Text = $plan.Title; $f.Size = New-Object Drawing.Size(640, 430); $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.Font = $font
    $t = New-Ctl TextBox 12 12 600 270 $plan.Text $f; $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Vertical'
    $ok = New-Ctl Button 410 345 100 30 'Do it' $f; $ok.DialogResult = 'OK'
    $cn = New-Ctl Button 515 345 95 30 'Cancel' $f; $cn.DialogResult = 'Cancel'; $f.CancelButton = $cn
    $box = $null
    if ($plan.Destructive) {
        $l = New-Ctl Label 12 292 600 20 "This writes to disk $($plan.DiskNumber). Type  $($plan.Phrase)  to enable the button:" $f; $l.ForeColor = [Drawing.Color]::DarkRed
        $box = New-Ctl TextBox 12 315 200 23 '' $f
        $ok.Enabled = $false; $phrase = $plan.Phrase
        $box.Add_TextChanged({ $ok.Enabled = ($box.Text.Trim() -ceq $phrase) }.GetNewClosure())
    } elseif ($plan.Text -match 'Nothing to do\.') { $ok.Enabled = $false }
    if ($f.ShowDialog($form) -ne 'OK') { return $null }
    if ($box) { return $box.Text.Trim() }
    'yes'
}

function Invoke-Fix([string]$Fn, [hashtable]$P, [string]$Title) {
    # Preview in the window thread (read-only), confirm, then run the change in the background.
    $form.Cursor = 'WaitCursor'
    try { $plan = & $Fn @P -Preview } catch { $form.Cursor = 'Default'; [Windows.Forms.MessageBox]::Show($_.Exception.Message, $Title, 'OK', 'Warning') | Out-Null; return }
    $form.Cursor = 'Default'
    $answer = Show-Confirm $plan
    if (-not $answer) { return }
    if ($plan.Destructive) { $P.ConfirmPhrase = $answer }
    $txtLog.AppendText("--- $Title`r`n")
    Start-Work $Fn $P $Title
}

$lv.Add_SelectedIndexChanged({
    $r = Get-Selected
    if (-not $r) { return }
    $lines = @(Format-UsbDisk $r.Disk) + '' + @($r.Findings | ForEach-Object { "[{0}] {1}" -f $_.Level, $_.Text }) + '' + @(Format-Assessment $r.Assessment)
    $txtFind.Text = $lines -join "`r`n"
    if (-not $txtOut.Text -or $txtOut.Tag -ne 'user') { $txtOut.Text = Join-Path (Join-Path (Get-DefaultDataDir) 'Rescue') ('{0}-{1}.img' -f ($r.Disk.Model -replace '[^A-Za-z0-9]+', '_'), $(if ($r.Disk.Serial) { $r.Disk.Serial -replace '[^A-Za-z0-9]+', '_' } else { 'noserial' })) }
})
$btnRefresh.Add_Click({ Start-Scan })
$btnLog.Add_Click({ Start-Process explorer.exe (Split-Path (Get-UDLogFile)) })
$btnOut.Add_Click({
    $d = New-Object Windows.Forms.SaveFileDialog; $d.Filter = 'Disk image (*.img)|*.img'; $d.OverwritePrompt = $false
    if ($txtOut.Text) { $d.FileName = Split-Path $txtOut.Text -Leaf; $p = Split-Path $txtOut.Text; if (Test-Path $p) { $d.InitialDirectory = $p } }
    if ($d.ShowDialog($form) -eq 'OK') { $txtOut.Text = $d.FileName; $txtOut.Tag = 'user' }
})
$btnLetter.Add_Click({
    $r = Need-Selected; if (-not $r) { return }
    $P = @{ DiskNumber = $r.Disk.Number; Letter = "$($cmbLetter.SelectedItem)"; Persistent = $chkPersist.Checked; Force = $chkForce.Checked }
    Invoke-Fix 'Set-UsbDriveLetter' $P 'Assign drive letter'
})
$btnChk.Add_Click({ $r = Need-Selected; if (-not $r) { return }; $l = Get-SelLetter $r; if (-not $l) { [Windows.Forms.MessageBox]::Show('This drive has no drive letter. Assign one first.', 'USBDoctor') | Out-Null; return }; Invoke-Fix 'Invoke-UsbChkdsk' @{ Letter = $l } 'Check disk' })
$btnOnline.Add_Click({ $r = Need-Selected; if ($r) { Invoke-Fix 'Set-UsbDiskOnline' @{ DiskNumber = $r.Disk.Number } 'Bring disk online' } })
$btnRO.Add_Click({ $r = Need-Selected; if ($r) { Invoke-Fix 'Clear-UsbReadOnly' @{ DiskNumber = $r.Disk.Number } 'Clear read-only' } })
$btnBoot.Add_Click({ $r = Need-Selected; if ($r) { Invoke-Fix 'Restore-UsbBootSector' @{ DiskNumber = $r.Disk.Number } 'Restore boot sector' } })
$btnGpt.Add_Click({ $r = Need-Selected; if ($r) { Invoke-Fix 'Restore-UsbGpt' @{ DiskNumber = $r.Disk.Number } 'Restore GPT' } })
$btnCap.Add_Click({ $r = Need-Selected; if ($r) { Invoke-Fix 'Test-UsbCapacity' @{ DiskNumber = $r.Disk.Number } 'Capacity test' } })
function Save-Tier0([string]$Result) {
    $r = Need-Selected; if (-not $r) { return }
    try { [void](Set-Tier0Result -Device $r.Disk.Identity -Result $Result -Note "disk $($r.Disk.Number) $($r.Disk.Model), GUI"); $txtLog.AppendText("Tier 0 recorded: $Result for $($r.Disk.Model)`r`n"); Start-Scan }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'USBDoctor') | Out-Null }
}
$btnT0a.Add_Click({ Save-Tier0 'OtherPortFails' }); $btnT0b.Add_Click({ Save-Tier0 'OtherPortWorks' })
$btnT0c.Add_Click({ Save-Tier0 'OtherMachineFails' }); $btnT0d.Add_Click({ Save-Tier0 'OtherMachineWorks' })
$btnEject.Add_Click({ $r = Need-Selected; if ($r) { Invoke-Fix 'Dismount-UsbDrive' @{ DiskNumber = $r.Disk.Number } 'Safe eject' } })
$btnExtend.Add_Click({ $r = Need-Selected; if ($r) { Invoke-Fix 'Expand-UsbPartition' @{ DiskNumber = $r.Disk.Number } 'Extend partition' } })
$btnConvert.Add_Click({ $r = Need-Selected; if (-not $r) { return }; $l = Get-SelLetter $r; if (-not $l) { [Windows.Forms.MessageBox]::Show('This drive has no drive letter. Assign one first.', 'USBDoctor') | Out-Null; return }; Invoke-Fix 'Convert-UsbToNtfs' @{ Letter = $l } 'Convert to NTFS' })
$btnShift.Add_Click({
    $r = Need-Selected; if (-not $r) { return }
    $o = if ($txtOut.Text) { [IO.Path]::ChangeExtension($txtOut.Text, $null).TrimEnd('.') + '-fixed.img' } else { '' }
    Invoke-Fix 'Invoke-ImageUsbFix' @{ DiskNumber = $r.Disk.Number; OutFile = $o } 'ImageUSB: image + strip header'
})
$btnAuto.Add_Click({ Invoke-Fix 'Enable-UsbAutomount' @{} 'Enable automount' })
$btnSuspend.Add_Click({ Invoke-Fix 'Disable-UsbSelectiveSuspend' @{} 'Turn off USB selective suspend' })
$btnGhost.Add_Click({ Invoke-Fix 'Remove-UsbGhostDevices' @{} 'Remove failed USB device entries' })
$btnRescue.Add_Click({
    $r = Need-Selected; if (-not $r) { return }
    if (-not $txtOut.Text) { [Windows.Forms.MessageBox]::Show('Choose where to save the image.', 'USBDoctor') | Out-Null; return }
    $msg = "Copy all of disk $($r.Disk.Number) ($($r.Disk.Model), $(Format-Bytes $r.Disk.Size)) to:`n$($txtOut.Text)`n`nThe drive is only read. Unreadable spots are skipped and zero-filled. If the drive drops out, unplug and replug it and the copy carries on. Needs $(Format-Bytes $r.Disk.Size) free."
    if ([Windows.Forms.MessageBox]::Show($msg, 'Rescue copy', 'OKCancel', 'Information') -ne 'OK') { return }
    $txtLog.AppendText("--- Rescue copy of disk $($r.Disk.Number)`r`n")
    Start-Work 'Start-UsbRescue' @{ DiskNumber = $r.Disk.Number; OutFile = $txtOut.Text } 'Rescue copy'
})
$btnStop.Add_Click({ $shared.Cancel = $true; $txtLog.AppendText("Stopping after the current block...`r`n") })
$btnReport.Add_Click({
    if (-not $script:diag) { return }
    try { $r = New-UsbDoctorReport -Diag $script:diag; Start-Process $r.Html } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'USBDoctor') | Out-Null }
})
$form.Add_FormClosing({ param($s, $e) if ($script:job) { [Windows.Forms.MessageBox]::Show('Please wait for the current operation to finish (or press Stop for a rescue copy).', 'USBDoctor') | Out-Null; $e.Cancel = $true } })
$form.Add_Shown({ $timer.Start(); $txtLog.AppendText("USBDoctor ready. Log: $(Get-UDLogFile)`r`n"); Fill-Letters; Start-Scan })

if ($SmokeTest) {
    $script:diag = Invoke-UsbDiagnosis -Days $Days; Show-Diag; Fill-Letters
    "SMOKE OK: form built, controls=$($form.Controls.Count), fixes=$($g.Controls.Count), disks listed=$($lv.Items.Count): " + (($script:diag.Disks | ForEach-Object { "$($_.Disk.Number)=$($_.Disk.Model) [$($_.Level)]" }) -join ', ') + "; free letters=$($cmbLetter.Items.Count)"
    $form.Dispose(); return
}
[void]$form.ShowDialog()
$timer.Stop()
