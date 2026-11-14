# DiskPilot

Two small, safety-first disk tools for USB sticks and data disks:

| Tool | Folder | What it does | Platform |
|---|---|---|---|
| **DiskPilot** | [`partition/`](partition/) | Conservative partition manager (list, show, init GPT, create, delete, format) with a CLI and an Avalonia desktop GUI. Calls the OS's own storage tools and never writes raw disk data itself. | Windows and Linux, .NET 10 |
| **USBImager** | [`usbimager/`](usbimager/) | Captures a USB stick to an image and burns an image to another stick so the new stick uses its **whole capacity** while restoring the original files. Also burns raw `.img`/`.bin` images (including ImageUSB `.bin` files). | Windows, PowerShell 5.1 |

> Both tools can destroy data when you confirm a write. They are new, personal-project tools, not certified disk
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

## Safety model

Shared ideas, implemented separately in each tool:

- **Look before you write.** DiskPilot defaults every operation to a dry run and its GUI has a Preview step.
  USBImager shows the target drive's model, size and volumes in its erase dialog.
- **Typed confirmation.** DiskPilot needs `ERASE <disk-id> <fingerprint> <operation>` in an interactive terminal or
  its GUI dialog; USBImager needs `ERASE <disk number>`.
- **Re-check right before writing.** Both re-read the disk after confirmation and abort if its identity, size or
  (for DiskPilot) layout changed.
- **System disks are refused.** DiskPilot refuses boot/system/pagefile disks, protected or special partitions,
  mounted volumes, MBR writes and virtual/RAID buses. USBImager only ever lists USB disks and additionally hides the
  disks holding C:, D:, Windows, boot and the pagefile.
- **No hidden shell tricks.** Native tools are called with explicit paths and argument lists; DiskPilot passes data to
  PowerShell as encoded JSON.
- **No undo.** Neither tool can roll back a completed or partially completed write.

## Requirements

| | DiskPilot | USBImager |
|---|---|---|
| Build | .NET 10 SDK (Avalonia 11.3.9 from nuget.org for the GUI) | none |
| Run | .NET 10 runtime; Windows PowerShell 5.1 + Storage module on Windows; util-linux, parted, udev and the relevant `mkfs` tools on Linux | Windows 10/11, Windows PowerShell 5.1, diskpart, robocopy |
| Privileges | Administrator/root to apply changes | Administrator (self-elevates via UAC) |

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
└── usbimager/           USBImager (Windows PowerShell 5.1)
    ├── USBImager.cmd    launcher
    ├── USBImager.ps1    window + command line
    ├── USBImager.Core.psm1  engine (list, capture, burn, verify)
    └── README.md
```

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Steven Powell. Provided as is, without warranty; you are
responsible for the disks you point these tools at.
