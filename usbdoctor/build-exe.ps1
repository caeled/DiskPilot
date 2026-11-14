#Requires -Version 5.1
<#
.SYNOPSIS
  Build a console USBDoctor.exe with PS2EXE, sitting next to the .psm1 modules.

.DESCRIPTION
  Packaging is "exe next to modules": USBDoctor.exe loads USBDoctor.Core.psm1 and
  USBDoctor.Tools.psm1 from its own folder. A single self-contained exe was not
  used because the modules are shared with USBDoctor.ps1 / USBDoctor.cmd and stay
  easier to update and inspect this way.

  The exe is a console application (not -noConsole) so the interactive CLI works.
  It is built WITHOUT -requireAdmin. A requireAdmin manifest would show a UAC
  prompt even for read-only commands such as -List, -Diagnose and -?, and would
  ignore -NoElevate. USBDoctor.cmd does not use an admin manifest either: the
  script self-elevates with Start-Process -Verb RunAs when the GUI or a repair
  command needs administrator rights. The compiled exe does the same, relaunching
  itself.

  This build script does not request elevation.

.PARAMETER SourceDir
  Folder containing USBDoctor.ps1, the two .psm1 modules, and (usually) USBDoctor.ico.
  Defaults to the folder this script is in.

.PARAMETER OutDir
  Folder that receives USBDoctor.exe and copies of the modules and icon.
  Defaults to <SourceDir>\exe.

.EXAMPLE
  .\build-exe.ps1
  .\build-exe.ps1 -OutDir .
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$OutDir,
    [string]$IconFile,
    [string]$Version = '0.3.1.0'
)
$ErrorActionPreference = 'Stop'
if (-not $SourceDir) { $SourceDir = $PSScriptRoot }
$SourceDir = [IO.Path]::GetFullPath($SourceDir)
if (-not $OutDir) { $OutDir = Join-Path $SourceDir 'exe' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not $IconFile) {
    foreach ($c in @((Join-Path $SourceDir 'USBDoctor.ico'), (Join-Path $OutDir 'USBDoctor.ico'))) {
        if (Test-Path -LiteralPath $c) { $IconFile = $c; break }
    }
}
if (-not $IconFile -or -not (Test-Path -LiteralPath $IconFile)) {
    throw "USBDoctor.ico not found. Pass -IconFile or put it in $SourceDir."
}

$inputFile = Join-Path $SourceDir 'USBDoctor.ps1'
$core = Join-Path $SourceDir 'USBDoctor.Core.psm1'
$tools = Join-Path $SourceDir 'USBDoctor.Tools.psm1'
foreach ($f in @($inputFile, $core, $tools)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Required file missing: $f" }
}

if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
    Import-Module ps2exe -Force
} else {
    Import-Module ps2exe -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

foreach ($f in @($core, $tools, $IconFile)) {
    $dest = Join-Path $OutDir (Split-Path $f -Leaf)
    if ([IO.Path]::GetFullPath($f) -ne [IO.Path]::GetFullPath($dest)) {
        Copy-Item -LiteralPath $f -Destination $dest -Force
    }
}

$outputFile = Join-Path $OutDir 'USBDoctor.exe'
if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile -Force }

Write-Host "Building $outputFile from $inputFile"
Write-Host "Icon: $IconFile"
Invoke-ps2exe -inputFile $inputFile -outputFile $outputFile -iconFile $IconFile `
    -title 'USBDoctor' `
    -product 'USBDoctor' `
    -description 'Diagnose and repair USB drive problems' `
    -company 'Steven Powell' `
    -copyright 'Copyright (c) Steven Powell' `
    -version $Version `
    -STA -supportOS -DPIAware `
    -noConfigFile

if (-not (Test-Path -LiteralPath $outputFile)) { throw "Build finished but $outputFile was not created." }
$hash = Get-FileHash -LiteralPath $outputFile -Algorithm SHA256
$item = Get-Item -LiteralPath $outputFile
$vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($outputFile)
[pscustomobject]@{
    Exe             = $outputFile
    Length          = $item.Length
    SHA256          = $hash.Hash
    Product         = $vi.ProductName
    ProductVersion  = $vi.ProductVersion
    FileVersion     = $vi.FileVersion
    Company         = $vi.CompanyName
    Copyright       = $vi.LegalCopyright
    Description     = $vi.FileDescription
}
