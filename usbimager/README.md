# USBImager

A small Windows companion to DiskPilot for imaging USB sticks. It **captures** a USB drive to an image
file, and **burns** an image onto another USB drive so the new drive uses its **whole capacity**
while getting back all of the original files.

DiskPilot is a partition manager that, by design, never writes raw disk data, so imaging lives in this
separate tool. USBImager is plain Windows PowerShell 5.1 (a WinForms window plus a command line); there is
nothing to build or install.

## Requirements

* Windows 10 or 11 with **Windows PowerShell 5.1** (`powershell.exe`, not PowerShell 7) and the built-in
  Storage module, `diskpart` and `robocopy`. VHDX images are created with `diskpart` and mounted with
  `Mount-DiskImage`, so Hyper-V is not needed.
* **Administrator rights.** The script re-launches itself through the normal UAC prompt unless `-NoElevate` is given.
* Enough free space in the output folder for the image.

## Start it

Double-click **`USBImager.cmd`** in this folder, then approve the Windows UAC prompt.
(Or right-click `USBImager.ps1` > Run with PowerShell.)

## Safety

* Only **USB** disks (bus type `USB`) appear in the list. The disks holding C:, D:, Windows, boot, or the
  pagefile are refused even if they somehow appear, and internal SATA/NVMe/RAID disks are never listed.
* Burning needs you to type **`ERASE <disk number>`**. Right before writing, the tool checks again that
  the disk is still the same drive (same ID and size). If anything changed, it stops without writing.
* The image file can't be on the drive being captured or burned.
* Everything is logged to `C:\ProgramData\USBImager\USBImager.log`, and each copy also gets a robocopy log
  in the same folder.

## Capture (drive -> image)

Select a drive, pick a folder (default `D:\USB-Backups\Images`) and a type:

| Type | What you get | Best for |
|---|---|---|
| **Files** (recommended) | `NAME-date.vhdx`, an expanding virtual disk holding only the used data (NTFS) | Normal data sticks. Smallest. You can double-click the .vhdx to browse it. |
| Raw, partitions only | `.img`, byte-for-byte up to the end of the last partition | Bootable or odd sticks |
| Raw, whole drive | `.img` holding every byte of the drive | Exact clones |

Each image gets a `.json` file next to it with the source model, serial, label, file system, file count,
byte count, SHA256 and date. The source drive is only read.

## Burn (image -> drive)

Select the target drive, choose an image, then click **Burn...** and type the confirmation.

* **.vhdx / .vhd (Files image):** the drive is wiped and gets one partition spanning the whole drive
  (MBR, or GPT if the drive is over 2 TB). It is formatted **NTFS** (or **exFAT** if you pick it, for Macs, TVs
  and cars), labeled with the original label, and filled with the files. The tool then checks that the file
  count and total bytes match the image. If the .json is present, it checks the image's SHA256 first.
* **.img / .bin (Raw image):** written byte-for-byte and read back to verify. If the last partition is NTFS,
  it's extended to the whole drive. ImageUSB `.bin` files, which have a 512-byte "imageUSB" header,
  and fixed `.vhd` files are detected and handled automatically. FAT partitions can't be enlarged by Windows.
  To get a full-size drive from one of those, burn it, capture it in **Files** mode, then burn that .vhdx.

## Command line

| Switch | Meaning |
|---|---|
| `-List` | List attached USB disks that the tool is allowed to use |
| `-Capture -Disk N` | Capture disk N; `-Mode Files` (default), `RawUsed` or `RawFull`; `-OutDir` (default `D:\USB-Backups\Images`); optional `-Name` (defaults to the volume label) |
| `-Burn -Image FILE -Disk N` | Burn an image to disk N; `-FileSystem NTFS` (default) or `exFAT` and `-Label` apply to Files images |
| `-ConfirmPhrase "ERASE N"` | Supply the confirmation non-interactively; anything else aborts before writing |
| `-SkipHashCheck` | Skip verifying the image SHA256 against its `.json` |
| `-LogFile path` | Log somewhere other than `C:\ProgramData\USBImager\USBImager.log` |
| `-NoElevate` | Do not self-elevate (the operation then fails unless already elevated) |
| `-PauseAtEnd` | Keep the console open at the end (added automatically when it self-elevates in CLI mode) |
| `-SmokeTest` | Build the window, list disks, print a one-line summary and exit without showing the UI |

```
USBImager.ps1 -List
USBImager.ps1 -Capture -Disk 3 [-Mode Files|RawUsed|RawFull] [-OutDir D:\USB-Backups\Images] [-Name MYSTICK]
USBImager.ps1 -Burn -Image D:\USB-Backups\Images\MYSTICK-20261113-2130.vhdx -Disk 3 [-FileSystem NTFS|exFAT] [-Label MYSTICK] [-ConfirmPhrase "ERASE 3"]
```

Run from a normal PowerShell, it asks for UAC and opens an elevated window. Without `-ConfirmPhrase`,
it asks you to type the phrase. Other options: `-LogFile path`, `-SkipHashCheck`.

## Limits

* Windows only. The default image folder is `D:\USB-Backups\Images`; on a PC without a D: drive pass `-OutDir`
  or pick another folder in the window.
* The disks holding drive letters **C:** and **D:** are always treated as protected and hidden, so a USB stick that
  happens to be mounted as D: will not be listed.
* Raw images are written as-is. Only an NTFS last partition is grown to the whole drive; FAT/exFAT partitions keep
  their original size, and a raw GPT image smaller than the target is not re-laid-out (its backup GPT stays where
  the image put it).
* A Files image copies the largest volume on the drive. Use a Raw image for multi-partition or bootable sticks.
* A Files image restores files, folders, timestamps and attributes, not NTFS permissions.
  It doesn't make a drive bootable.
* exFAT labels are limited to 11 characters and NTFS labels to 32.
* Capturing a drive that is being written to at the same time can give an inconsistent image. Close open files first.

## Files

* `USBImager.cmd`: launcher
* `USBImager.ps1`: window and command line
* `USBImager.Core.psm1`: engine (disk list, capture, burn, verify)
* Requires Windows 10/11 with Windows PowerShell 5.1. Nothing to install.

## Status

Version 1.0.0 (`$script:Version` in `USBImager.Core.psm1`). This is a new tool. Try it on a disposable stick
first and keep a copy of anything important before burning. For testing without real sticks, the hidden
`-AllowVirtual` switch also lists attached VHD/VHDX disks (bus type `File Backed Virtual`).
