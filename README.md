# DiskPilot

Three small, safety-first disk tools for USB sticks and data disks:

| Tool | Folder | What it does | Platform |
|---|---|---|---|
| **DiskPilot** | [`partition/`](partition/) | Conservative partition manager (list, show, init GPT, create, delete, format) with a CLI and an Avalonia desktop GUI. Calls the OS's own storage tools and never writes raw disk data itself. | Windows and Linux, .NET 10 |
| **USBImager** | [`usbimager/`](usbimager/) | Captures a USB stick to an image and burns an image to another stick so the new stick uses its **whole capacity** while restoring the original files. Also burns raw `.img`/`.bin` images (including ImageUSB `.bin` files). | Windows, PowerShell 5.1 |
| **USBDoctor** | [`usbdoctor/`](usbdoctor/) | Diagnoses USB drive problems read-only, decides who is at fault (drive, port/hub, this PC, permissions) with a per-stick port history, and offers only the repair that is safe for that state. It refuses on dying-media signatures, requires a rescue image (or typed `REPAIR <n>`) before any writing repair, and never formats as a repair. Covers no letter, letter conflicts, offline/collision, read-only, dirty bit, RAW (incl. non-Windows file systems and boot-sector restore from backup), GPT restore, counterfeit capacity test, Code 43/10/28/31, ImageUSB-shifted images (fixed in the image file, then burned with USBImager) and skip-on-error rescue copies. A separate, clearly labelled **Prepare & Tools** area (not repairs) adds format, wipe, a bootable-stick maker (hybrid ISO raw write or Windows installer with install.wim split), an unbuffered verified benchmark with slowdown history, file recovery from rescue images (PhotoRec hand-off), a non-elevated health-watch task and a USB port map. | Windows, PowerShell 5.1 |

> These tools can destroy data when you confirm a write. They are new, personal-project tools, not certified disk
> utilities. Try them on a disposable stick first and keep backups.

## Quick start

### DiskPilot (partition manager)

Requires the [.NET 10 SDK](https://dotnet.microsoft.com/download).

```text
cd partition
dotnet restore tests/DiskPilot.Tests.csproj --configfile NuGet.Config
dotnet build tests/DiskPilot.Tests.csproj -c Release --no-restore
dotnet tests/bin/Release/net10.0/DiskPilot.Tests.dll      # safety tests
dotnet bin/Release/net10.0/DiskPilot.dll list             # read-only disk listing

# GUI in safe demo mode (needs nuget.org for Avalonia)
dotnet restore Gui/DiskPilot.Gui.csproj --configfile NuGet.Config --source https://api.nuget.org/v3/index.json
dotnet build Gui/DiskPilot.Gui.csproj -c Release --no-restore
dotnet run --project Gui/DiskPilot.Gui.csproj -c Release --no-build -- --demo
```

Every change command is a dry run until you add `--apply` and type the confirmation phrase. See
[`partition/README.md`](partition/README.md).

### USBImager

Requires Windows 10/11, Windows PowerShell 5.1 and administrator rights. Nothing to build.

```text
usbimager\USBImager.cmd                                   # window (asks for UAC)
powershell -File usbimager\USBImager.ps1 -List            # command line
powershell -File usbimager\USBImager.ps1 -Capture -Disk 3 -OutDir E:\Images
powershell -File usbimager\USBImager.ps1 -Burn -Image E:\Images\MYSTICK-20260101-1200.vhdx -Disk 4
```

See [`usbimager/README.md`](usbimager/README.md).

### USBDoctor

Requires Windows 10/11 and Windows PowerShell 5.1. Read-only checks run without admin; fixes ask for UAC.

```text
usbdoctor\USBDoctor.cmd                                    # window (asks for UAC)
powershell -File usbdoctor\USBDoctor.ps1 -Diagnose          # read-only: State / Fault owner / Safe action / To change
powershell -File usbdoctor\USBDoctor.ps1 -AssignLetter -Disk 3 -Letter U -Persistent
powershell -File usbdoctor\USBDoctor.ps1 -Rescue -Disk 3 -Out E:\Rescue\stick.img
powershell -File usbdoctor\USBDoctor.ps1 -FixImageUsbShift -Disk 3 -Out E:\Rescue\clean.img   # image + strip header; stick only read
powershell -File usbdoctor\USBDoctor.ps1 -Benchmark -Letter U                 # Prepare & Tools: unbuffered, verified
powershell -File usbdoctor\USBDoctor.ps1 -Format -Disk 3 -FileSystem exFAT -PreviewOnly   # not a repair; ERASE 3 to run
powershell -File usbdoctor\USBDoctor.ps1 -MakeBootable -Iso C:\ISO\distro.iso -Disk 3 -Sha256 <hex>
powershell -File usbdoctor\USBDoctor.ps1 -PortMap
```

See [`usbdoctor/README.md`](usbdoctor/README.md) for the coverage table mapping every catalog entry (#0-#15 and the
refusal list) to a feature or switch. The catalog itself, with a tool-coverage line for each problem across DiskPilot,
USBImager and USBDoctor, is in [`docs/USB-Problem-Catalog.md`](docs/USB-Problem-Catalog.md)
([PDF](docs/USB-Problem-Catalog.pdf)).

> **Test status (2026-11-14):** USBDoctor 1.1.0 (repairs plus Prepare & Tools) is parse-checked, import-checked and dry-run checked without admin rights; benchmark logic, image wrap/unwrap, previews, refusals, port map and a health-watch dry run were tested without UAC. The elevated test run against virtual disks (VHDs), covering the v2 repairs and the new format, wipe, bootable, raw-benchmark and recovery paths, is still pending, so treat the repairs and Prepare tools as beta and try them on a disposable stick first.

## Safety model

Shared ideas, implemented separately in each tool:

- **Look before you write.** DiskPilot defaults every operation to a dry run and its GUI has a Preview step.
  USBImager shows the target drive's model, size and volumes in its erase dialog.
- **Typed confirmation.** DiskPilot needs `ERASE <disk-id> <fingerprint> <operation>` in an interactive terminal or
  its GUI dialog; USBImager needs `ERASE <disk number>`; USBDoctor previews every fix, and its writing repairs need a completed
  rescue image of that drive or a typed `REPAIR <disk number>` (its capacity test and its Prepare tools - format, wipe,
  bootable maker - need `ERASE <disk number>`).
- **Re-check right before writing.** Both re-read the disk after confirmation and abort if its identity, size or
  (for DiskPilot) layout changed.
- **System disks are refused.** DiskPilot refuses boot/system/pagefile disks, protected or special partitions,
  mounted volumes, MBR writes and virtual/RAID buses. USBImager only ever lists USB disks and additionally hides the
  disks holding C:, D:, Windows, boot and the pagefile. USBDoctor uses the same USB-only rule for every fix, refuses every writing repair on a drive with dying-media
  signatures, and its repairs refuse MBR writes like DiskPilot and never format. Its separate Prepare tools build a
  new partition table from scratch only when you choose them, and refuse dying, counterfeit and system disks.
- **No hidden shell tricks.** Native tools are called with explicit paths and argument lists; DiskPilot passes data to
  PowerShell as encoded JSON.
- **No undo.** No tool can roll back a completed or partially completed write.

## Requirements

| | DiskPilot | USBImager | USBDoctor |
|---|---|---|---|
| Build | .NET 10 SDK (Avalonia 11.3.9 from nuget.org for the GUI) | none | none |
| Run | .NET 10 runtime; Windows PowerShell 5.1 + Storage module on Windows; util-linux, parted, udev and the relevant `mkfs` tools on Linux | Windows 10/11, Windows PowerShell 5.1, diskpart, robocopy | Windows 10/11, Windows PowerShell 5.1 (uses mountvol, chkdsk, convert, powercfg, pnputil, fsutil; Prepare & Tools also diskpart, robocopy, dism, optional PhotoRec) |
| Privileges | Administrator/root to apply changes | Administrator (self-elevates via UAC) | None for diagnosis (raw-read checks need Administrator); Administrator for fixes (self-elevates via UAC) |

## Repository layout

```text
.
├── README.md            this file
├── CHANGELOG.md
├── LICENSE              MIT
├── partition/           DiskPilot (.NET 10)
│   ├── DiskPilot.csproj CLI project
│   ├── Program.cs  Core.cs  OperationSession.cs
│   ├── WindowsBackend.cs  windows.ps1   Windows backend (Storage cmdlets)
│   ├── LinuxBackend.cs                  Linux backend (lsblk, parted, mkfs)
│   ├── Gui/             Avalonia GUI (+ Gui/Tests headless smoke test)
│   ├── tests/           safety/backend tests + Windows fixture tests
│   ├── docs/            screenshot
│   └── README.md
├── usbimager/           USBImager (Windows PowerShell 5.1)
│   ├── USBImager.cmd    launcher
│   ├── USBImager.ps1    window + command line
│   ├── USBImager.Core.psm1  engine (list, capture, burn, verify)
│   └── README.md
├── docs/                USB-Problem-Catalog.md / .pdf (problem catalog with tool coverage)
└── usbdoctor/           USBDoctor (Windows PowerShell 5.1)
    ├── USBDoctor.cmd    launcher
    ├── USBDoctor.ps1    window + command line
    ├── USBDoctor.Core.psm1  engine (inventory, diagnosis, Tier 0 history, write gate, repairs, rescue, report)
    ├── USBDoctor.Tools.psm1 Prepare & Tools, not repairs (format, wipe, bootable, benchmark, recovery, watch, port map)
    └── README.md
```

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Steven Powell. Provided as is, without warranty; you are
responsible for the disks you point these tools at.
