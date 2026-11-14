<#
 USBImager - capture a USB stick to an image, and burn an image to another USB stick using the whole drive.
 GUI:  USBImager.ps1            (or double-click USBImager.cmd)
 CLI:  USBImager.ps1 -List
       USBImager.ps1 -Capture -Disk 3 [-Mode Files|RawUsed|RawFull] [-OutDir D:\USB-Backups\Images] [-Name MYSTICK]
       USBImager.ps1 -Burn -Image D:\USB-Backups\Images\MYSTICK-20261113-2130.vhdx -Disk 3 [-FileSystem NTFS|exFAT] [-Label X] -ConfirmPhrase "ERASE 3"
 Only USB disks are ever listed or touched. Self-elevates through the normal UAC prompt.
#>
[CmdletBinding()]
param(
    [switch]$List, [switch]$Capture, [switch]$Burn,
    [int]$Disk = -1,
    [ValidateSet('Files', 'RawUsed', 'RawFull')][string]$Mode = 'Files',
    [string]$OutDir = 'D:\USB-Backups\Images',
    [string]$Name,
    [string]$Image,
    [ValidateSet('NTFS', 'exFAT')][string]$FileSystem = 'NTFS',
    [string]$Label,
    [string]$ConfirmPhrase,
    [string]$LogFile,
    [switch]$SkipHashCheck,
    [switch]$NoElevate,
    [switch]$PauseAtEnd,
    [switch]$SmokeTest,
    [Parameter(DontShow)][switch]$AllowVirtual
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$core = Join-Path $here 'USBImager.Core.psm1'
Import-Module $core -Force -DisableNameChecking
Set-UIConfig -LogFile $LogFile -AllowVirtual:$AllowVirtual
$isCli = $List -or $Capture -or $Burn

function ConvertTo-Unc([string]$p) {
    # Elevated sessions do not see the user's mapped drives (e.g. Z:), so pass UNC paths.
    if ($p -match '^([A-Za-z]):') {
        $d = Get-PSDrive -Name $Matches[1] -ErrorAction SilentlyContinue
        if ($d -and $d.DisplayRoot -and $d.DisplayRoot.StartsWith('\\')) { return $d.DisplayRoot.TrimEnd('\') + $p.Substring(2) }
    }
    $p
}

if (-not (Test-IsAdmin) -and -not $NoElevate) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA')
    if (-not $isCli) { $argList += @('-WindowStyle', 'Hidden') }
    $argList += @('-File', ('"{0}"' -f (ConvertTo-Unc $MyInvocation.MyCommand.Path)))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } }
        else { $s = "$v"; if ($k -in 'OutDir', 'Image', 'LogFile') { $s = ConvertTo-Unc $s }; $argList += "-$k"; $argList += ('"{0}"' -f $s) }
    }
    if ($isCli -and -not $PauseAtEnd) { $argList += '-PauseAtEnd' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList | Out-Null }
    catch {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show('USBImager needs administrator approval (UAC) to read and write USB drives.', 'USBImager') | Out-Null
    }
    return
}

# ------------------------------------------------------------------ CLI
if ($isCli) {
    $code = 0
    try {
        if ($List) {
            $d = @(Get-UsbDisks)
            if (-not $d.Count) { Write-Host 'No USB disks found.' }
            $d | Format-Table Number, Model, @{n = 'Size'; e = { Format-Bytes $_.Size } }, Bus, @{n = 'Volumes'; e = { $_.Summary } } -AutoSize | Out-String -Width 220 | Write-Host
        }
        if ($Capture) {
            if ($Disk -lt 0) { throw 'Use -Disk <number> (see -List).' }
            New-UsbImage -DiskNumber $Disk -OutDir $OutDir -Mode $Mode -Name $Name | Format-List | Out-String | Write-Host
        }
        if ($Burn) {
            if ($Disk -lt 0 -or -not $Image) { throw 'Use -Image <file> -Disk <number>.' }
            if (-not $ConfirmPhrase) {
                $t = Get-AllowedDisk $Disk
                Write-Host ("`nTHIS ERASES EVERYTHING ON DISK {0}: {1} {2} [{3}]" -f $t.Number, $t.Model, (Format-Bytes $t.Size), $t.Summary) -ForegroundColor Yellow
                $ConfirmPhrase = Read-Host "Type ERASE $Disk to continue"
            }
            Invoke-UsbBurn -ImagePath $Image -DiskNumber $Disk -FileSystem $FileSystem -Label $Label -ConfirmPhrase $ConfirmPhrase -SkipHashCheck:$SkipHashCheck | Format-List | Out-String | Write-Host
        }
    } catch { Write-UILog "FAILED: $($_.Exception.Message)" 'ERROR'; $code = 1 }
    if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }
    exit $code
}

# ------------------------------------------------------------------ GUI
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$global:USBImagerQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$queue = $global:USBImagerQueue
$font = New-Object Drawing.Font('Segoe UI', 9)

$form = New-Object Windows.Forms.Form
$form.Text = 'USBImager - capture and burn USB drives'
$form.Size = New-Object Drawing.Size(900, 720); $form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'; $form.Font = $font

function New-Ctl($type, $x, $y, $w, $h, $text, $parent) {
    $c = New-Object "Windows.Forms.$type"; $c.Location = New-Object Drawing.Point($x, $y); $c.Size = New-Object Drawing.Size($w, $h)
    if ($null -ne $text) { $c.Text = $text }; $parent.Controls.Add($c); $c
}

$lblDisks = New-Ctl Label 12 10 700 20 'USB drives (system and internal disks are never shown):' $form
$btnRefresh = New-Ctl Button 770 6 100 26 'Refresh' $form
$lv = New-Ctl ListView 12 34 858 150 $null $form
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false
[void]$lv.Columns.Add('Disk', 45); [void]$lv.Columns.Add('Model', 190); [void]$lv.Columns.Add('Size', 80); [void]$lv.Columns.Add('Bus', 70); [void]$lv.Columns.Add('Volumes', 460)
$lv.Anchor = 'Top,Left,Right'; $btnRefresh.Anchor = 'Top,Right'

$gCap = New-Ctl GroupBox 12 192 858 110 '1. Capture: save the selected drive to an image' $form
$gCap.Anchor = 'Top,Left,Right'
New-Ctl Label 12 26 80 20 'Save to:' $gCap | Out-Null
$txtOut = New-Ctl TextBox 95 23 520 23 $OutDir $gCap
$btnOut = New-Ctl Button 622 22 80 25 'Browse...' $gCap
New-Ctl Label 12 58 80 20 'Type:' $gCap | Out-Null
$cmbMode = New-Ctl ComboBox 95 55 330 23 $null $gCap
$cmbMode.DropDownStyle = 'DropDownList'
[void]$cmbMode.Items.AddRange(@('Files - compact .vhdx, used data only (recommended)', 'Raw - partitions only (.img)', 'Raw - whole drive, every byte (.img)'))
$cmbMode.SelectedIndex = 0
New-Ctl Label 440 58 50 20 'Name:' $gCap | Out-Null
$txtName = New-Ctl TextBox 492 55 210 23 '' $gCap
$btnCapture = New-Ctl Button 722 22 120 58 'Capture' $gCap
$btnCapture.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
New-Ctl Label 95 84 600 20 'Name is optional (defaults to the drive label). The drive being captured is only read.' $gCap | Out-Null

$gBurn = New-Ctl GroupBox 12 310 858 120 '2. Burn: restore an image onto the selected drive (ERASES that drive)' $form
$gBurn.Anchor = 'Top,Left,Right'
New-Ctl Label 12 26 80 20 'Image:' $gBurn | Out-Null
$txtImg = New-Ctl TextBox 95 23 520 23 '' $gBurn
$btnImg = New-Ctl Button 622 22 80 25 'Browse...' $gBurn
New-Ctl Label 12 58 80 20 'File system:' $gBurn | Out-Null
$cmbFs = New-Ctl ComboBox 95 55 100 23 $null $gBurn
$cmbFs.DropDownStyle = 'DropDownList'; [void]$cmbFs.Items.AddRange(@('NTFS', 'exFAT')); $cmbFs.SelectedIndex = 0
New-Ctl Label 210 58 45 20 'Label:' $gBurn | Out-Null
$txtLabel = New-Ctl TextBox 258 55 170 23 '' $gBurn
$lblImgInfo = New-Ctl Label 95 86 610 28 '.vhdx images: new single partition over the whole drive, files restored and verified. .img/.bin: written raw, NTFS extended to the whole drive.' $gBurn
$btnBurn = New-Ctl Button 722 22 120 58 'Burn...' $gBurn
$btnBurn.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold); $btnBurn.ForeColor = [Drawing.Color]::DarkRed

$progress = New-Ctl ProgressBar 12 440 700 18 $null $form
$progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 0; $progress.Anchor = 'Top,Left,Right'
$btnLog = New-Ctl Button 720 436 150 26 'Open log folder' $form; $btnLog.Anchor = 'Top,Right'
$txtLog = New-Ctl TextBox 12 468 858 200 '' $form
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true; $txtLog.WordWrap = $false
$txtLog.Font = New-Object Drawing.Font('Consolas', 9); $txtLog.Anchor = 'Top,Bottom,Left,Right'

$script:disks = @(); $script:job = $null

function Refresh-Disks {
    $lv.Items.Clear()
    $script:disks = @(Get-UsbDisks)
    foreach ($d in $script:disks) {
        $it = New-Object Windows.Forms.ListViewItem("$($d.Number)")
        [void]$it.SubItems.Add($d.Model); [void]$it.SubItems.Add((Format-Bytes $d.Size)); [void]$it.SubItems.Add($d.Bus); [void]$it.SubItems.Add($d.Summary)
        $it.Tag = $d; [void]$lv.Items.Add($it)
    }
    $lblDisks.Text = "USB drives (system and internal disks are never shown): $($script:disks.Count) found"
}
function Get-Selected { if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Tag } else { $null } }
function Set-Busy([bool]$b) {
    foreach ($c in @($btnCapture, $btnBurn, $btnRefresh, $lv, $btnOut, $btnImg)) { $c.Enabled = -not $b }
    $progress.MarqueeAnimationSpeed = if ($b) { 30 } else { 0 }
}

function Start-Work([string]$Op, [hashtable]$P) {
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('USBImagerQueue', $queue)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Core, $Log, $AllowVirtual, $Op, $P)
        $ErrorActionPreference = 'Stop'
        try {
            Import-Module $Core -Force -DisableNameChecking
            Set-UIConfig -LogFile $Log -AllowVirtual:$AllowVirtual
            if ($Op -eq 'Capture') { $r = New-UsbImage @P } else { $r = Invoke-UsbBurn @P }
            $USBImagerQueue.Enqueue('##DONE##OK##' + (($r | Format-List | Out-String).Trim()))
        } catch {
            try { Write-UILog "FAILED: $($_.Exception.Message)" 'ERROR' } catch {}
            $USBImagerQueue.Enqueue('##DONE##FAIL##' + $_.Exception.Message)
        }
    }).AddArgument($core).AddArgument((Get-UILogFile)).AddArgument([bool]$AllowVirtual).AddArgument($Op).AddArgument($P)
    $script:job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Op = $Op }
    Set-Busy $true
}

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 300
$timer.Add_Tick({
    $line = $null
    while ($queue.TryDequeue([ref]$line)) {
        if ($line.StartsWith('##DONE##')) {
            $ok = $line.StartsWith('##DONE##OK##'); $msg = $line.Substring($(if ($ok) { 12 } else { 14 }))
            if ($script:job) { try { $script:job.PS.EndInvoke($script:job.Handle) | Out-Null } catch {}; $script:job.PS.Dispose(); $script:job.RS.Dispose(); $op = $script:job.Op; $script:job = $null }
            Set-Busy $false; Refresh-Disks
            if ($ok) { [Windows.Forms.MessageBox]::Show("$op finished successfully.`n`n$msg", 'USBImager', 'OK', 'Information') | Out-Null }
            else { [Windows.Forms.MessageBox]::Show("$op failed:`n`n$msg`n`nSee the log for details.", 'USBImager', 'OK', 'Error') | Out-Null }
        } else { $txtLog.AppendText($line + "`r`n") }
    }
})

function Show-EraseConfirm($d) {
    $f = New-Object Windows.Forms.Form; $f.Text = 'Confirm erase'; $f.Size = New-Object Drawing.Size(520, 260); $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.Font = $font
    $l = New-Ctl Label 15 12 480 110 ("EVERYTHING on this drive will be erased:`n`nDisk {0}: {1}, {2}`n{3}`n`nType  ERASE {0}  below to continue." -f $d.Number, $d.Model, (Format-Bytes $d.Size), $d.Summary) $f
    $l.ForeColor = [Drawing.Color]::DarkRed
    $t = New-Ctl TextBox 15 130 200 23 '' $f
    $ok = New-Ctl Button 300 170 95 30 'Erase and burn' $f; $ok.Enabled = $false; $ok.DialogResult = 'OK'
    $cn = New-Ctl Button 405 170 90 30 'Cancel' $f; $cn.DialogResult = 'Cancel'; $f.CancelButton = $cn
    $phrase = "ERASE $($d.Number)"
    $t.Add_TextChanged({ $ok.Enabled = ($t.Text.Trim() -ceq $phrase) }.GetNewClosure())
    if ($f.ShowDialog($form) -eq 'OK') { return $t.Text.Trim() }
    $null
}

$btnRefresh.Add_Click({ Refresh-Disks })
$btnLog.Add_Click({ Start-Process explorer.exe (Split-Path (Get-UILogFile)) })
$btnOut.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog; $d.SelectedPath = $txtOut.Text
    if ($d.ShowDialog($form) -eq 'OK') { $txtOut.Text = $d.SelectedPath }
})
$btnImg.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Filter = 'USB images (*.vhdx;*.vhd;*.img;*.bin)|*.vhdx;*.vhd;*.img;*.bin|All files (*.*)|*.*'
    if (Test-Path $txtOut.Text) { $d.InitialDirectory = $txtOut.Text }
    if ($d.ShowDialog($form) -eq 'OK') {
        $txtImg.Text = $d.FileName
        $i = Get-ImageInfo $d.FileName
        $raw = $i.Kind -eq 'Raw'
        $cmbFs.Enabled = -not $raw; $txtLabel.Enabled = -not $raw
        $txtLabel.Text = $i.Label
        if ($raw) { $lblImgInfo.Text = "Raw image, $(Format-Bytes $i.Length). Written byte-for-byte; an NTFS partition is then extended to the whole drive (FAT cannot be)." }
        elseif ($i.Meta) { $lblImgInfo.Text = ("Files image from {0} '{1}': {2:N0} files, {3}. Captured {4}." -f $i.Meta.Source.Model, $i.Meta.Source.Label, [long]$i.Meta.Content.Files, (Format-Bytes ([long]$i.Meta.Content.Bytes)), $i.Meta.Created) }
        else { $lblImgInfo.Text = 'VHD/VHDX image (no .json found). Its files will be copied onto a new whole-drive partition.' }
    }
})
$btnCapture.Add_Click({
    $d = Get-Selected; if (-not $d) { [Windows.Forms.MessageBox]::Show('Select a USB drive first.', 'USBImager') | Out-Null; return }
    $mode = @('Files', 'RawUsed', 'RawFull')[$cmbMode.SelectedIndex]
    $txtLog.AppendText("--- Capture disk $($d.Number) ($mode) to $($txtOut.Text)`r`n")
    $p = @{ DiskNumber = $d.Number; OutDir = $txtOut.Text; Mode = $mode }; if ($txtName.Text.Trim()) { $p.Name = $txtName.Text.Trim() }
    Start-Work 'Capture' $p
})
$btnBurn.Add_Click({
    $d = Get-Selected; if (-not $d) { [Windows.Forms.MessageBox]::Show('Select the USB drive to burn to first.', 'USBImager') | Out-Null; return }
    if (-not $txtImg.Text -or -not (Test-Path -LiteralPath $txtImg.Text)) { [Windows.Forms.MessageBox]::Show('Choose an image file first.', 'USBImager') | Out-Null; return }
    $phrase = Show-EraseConfirm $d; if (-not $phrase) { return }
    $txtLog.AppendText("--- Burn $($txtImg.Text) to disk $($d.Number)`r`n")
    $p = @{ ImagePath = $txtImg.Text; DiskNumber = $d.Number; FileSystem = "$($cmbFs.SelectedItem)"; ConfirmPhrase = $phrase; ExpectedUniqueId = $d.UniqueId }
    if ($txtLabel.Enabled -and $txtLabel.Text.Trim()) { $p.Label = $txtLabel.Text.Trim() }
    Start-Work 'Burn' $p
})
$form.Add_FormClosing({ param($s, $e) if ($script:job) { [Windows.Forms.MessageBox]::Show('Please wait for the current operation to finish.', 'USBImager') | Out-Null; $e.Cancel = $true } })
$form.Add_Shown({ Refresh-Disks; $timer.Start(); $txtLog.AppendText("USBImager ready. Log: $(Get-UILogFile)`r`n") })

if ($SmokeTest) {
    Refresh-Disks
    "SMOKE OK: form built, controls=$($form.Controls.Count), disks listed=$($script:disks.Count): " + (($script:disks | ForEach-Object { "$($_.Number)=$($_.Model)" }) -join ', ')
    $form.Dispose(); return
}
[void]$form.ShowDialog()
$timer.Stop()
