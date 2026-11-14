# Changelog

All notable changes to this project are documented here.

## [0.2.0] - 2026-11-14

### Docs
- New [USB Drive Problem Catalog](docs/USB-Problem-Catalog.md) ([PDF](docs/USB-Problem-Catalog.pdf)): Tier 0-4
  problems, the refusal list and the per-diagnosis output format, each with a tool-coverage line (switch, detect-only
  vs repair, gate) across DiskPilot, USBImager and USBDoctor.

### USBDoctor (`usbdoctor/`) 1.0.0 - new
- Windows PowerShell 5.1 tool with a WinForms window and a command line, built to the USB problem catalog ([docs/USB-Problem-Catalog.md](docs/USB-Problem-Catalog.md))
  (#0-#15 plus the refusal list; see the coverage table in `usbdoctor/README.md`).
- Order of operations: read-only diagnosis, then Tier 0 fault owner (drive / connection / machine / permissions), then
  image before any writing repair (or typed `REPAIR <n>`), then refusal on dying-media signatures ("DYING - image what
  you can, do not repair"). Every drive is reported as State, Fault owner, Safe action or refusal, and what would
  have to change.
- Tier 0: per-stick history file (`C:\ProgramData\USBDoctor\history.json`) with ports, hub or not, per-port read
  errors and drops, time-to-drop, raw-read results and recorded other-port/other-PC results (`-Tier0Result`, GUI
  buttons); machine health (WMI timeout, storage timing, USBSTOR start type/driver, host controller errors, other USB
  disks healthy). Drive verdicts stay provisional until tried elsewhere.
- Detection: timed 64 KiB raw read with a 10 s watchdog (#3), Code 43 vs Code 10/28/31, offline incl. signature
  collision, read-only with return tracking, access-denied folders (takeown/icacls advice), dirty bit, RAW with
  identification of ext2/3/4, APFS, HFS+, XFS, Btrfs, F2FS, LUKS, swap, ISO 9660, ReFS and BitLocker ("healthy, wrong
  OS"), NTFS/FAT32/exFAT backup boot sectors, GPT primary/backup header and entry CRCs, MBR with no backup (reported,
  never written), letter conflicts incl. disconnected mappings and MountedDevices reservations, capacity flapping
  and drops from the System and Partition/Diagnostic event logs, ImageUSB-shifted MBR.
- Repairs, each previewed and gated: drive letter (persistent, verified; not gated), automount, selective suspend,
  remove/reset failed devices, online (signature rewrite disclosed), clear read-only once with a test write,
  chkdsk only after a clean raw read, boot-sector restore from backup, GPT restore from the backup header (protective
  MBR required; MBR writes refused), extend NTFS, convert FAT32 to NTFS.
- Capacity test (#13): destructive write/read-verify across the claimed size, only on a blank stick, with typed
  `ERASE <n>`; counterfeits are recorded and extend is refused on them.
- ImageUSB shift (design decision): the stick is never rewritten. `-FixImageUsbShift -Disk N` makes a rescue image,
  strips the 512-byte imageUSB header from the image file (MBR at offset 0, verified) and hands off to USBImager
  (`-Burn`). `-FixImageUsbShift -Image file` fixes an existing image file.
- Rescue copy: skip-on-error imaging (1 MiB reads, 4 KiB fallback, zero-fill, read watchdog), resumable progress file,
  automatic resume after a drop-out; completed images are recorded and unlock gated repairs for that drive.
- No format, initialize or clean code anywhere. Text and HTML reports.
- **Test status (2026-11-14):** USBDoctor's v2 repair paths are parse-checked and dry-run checked without admin rights. The earlier build passed 46 of 48 elevated tests against virtual disks (VHDs); the two failures were rescue stop/resume test-hook timing, since fixed. A final elevated test run of v2 is still pending, so treat the repairs as beta and try them on a disposable stick first.

## [0.1.0] - 2026-11-13

Initial public release, combining two tools in one repository.

### DiskPilot (`partition/`)
- .NET 10 CLI: `list`, `show`, `init` (GPT), `create`, `delete`, `format` (NTFS/exFAT/FAT32, ext4 on Linux).
- Windows backend via the Storage PowerShell module; Linux backend via lsblk, sysfs, findmnt, wipefs, parted and mkfs.
- Dry run by default, SHA-256 disk fingerprints, typed `ERASE <id> <fingerprint> <op>` confirmation,
  re-validation of identity and layout immediately before every write.
- Avalonia 11.3.9 desktop GUI with File/Disk/Partition/Help menus, preview step, separate confirmation dialog
  and a `--demo` mode backed by a fixture device.
- Managed safety/backend tests, Windows backend fixture tests and a headless GUI smoke test.

### USBImager (`usbimager/`) 1.0.0
- Windows PowerShell 5.1 tool with a WinForms window and a command line (`-List`, `-Capture`, `-Burn`).
- Capture modes: Files (compact expanding VHDX), Raw used partitions, Raw whole drive; JSON metadata with SHA256.
- Burn: whole-drive single partition (NTFS or exFAT) with file restore and count/byte verification for VHDX images;
  raw write with read-back verification for `.img`/`.bin`, automatic ImageUSB header and fixed-VHD footer handling,
  NTFS extension to the full drive and MBR disk-signature collision fix.
- USB-only listing, protection of system/C:/D:/pagefile disks, typed `ERASE <n>` confirmation and identity re-check.
