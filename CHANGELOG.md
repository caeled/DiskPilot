# Changelog

All notable changes to this project are documented here.

## [0.3.0] - 2026-11-14

### USBDoctor (`usbdoctor/`) 1.1.0 - Prepare & Tools (not repairs)
- New module `USBDoctor.Tools.psm1`, separate from the repair engine, with its own switches and window tab,
  *Prepare / Tools (not repairs)*. The catalog rule stands: **format is never a repair**. The repair engine
  (`USBDoctor.Core.psm1`) still has no format, initialize or clean code. Erasing tools are refused on non-USB and
  system disks (C:, D:, Windows, boot, pagefile), on dying-media signatures, on recorded counterfeits and on
  read-only drives. They show a plan that says whether the stick holds files and offers a Rescue copy first, then
  need typed `ERASE <n>` and re-check the disk's identity before writing.
- `-Format`: new MBR (Auto; GPT above 2 TB) or GPT table, one 1 MiB-aligned full-size partition, NTFS / exFAT
  (default) / FAT32, label and letter. FAT32 above 32 GB is refused with a clear message (exFAT/NTFS or
  `-SizeMB 32000`).
- `-Wipe -Passes Zero|Random`: one pass over the whole stick with progress, ETA and Stop, then a verify sample
  (first/last MiB + 64 random MiB). The wear-leveling limit is documented: not guaranteed erasure; encrypt, or
  destroy the stick physically.
- `-MakeBootable -Iso`: hybrid ISOs are written raw and verified by read-back. Windows installers get an active
  FAT32 partition, files copied from the read-only mounted ISO, `install.wim` over 4 GB split to `.swm` with
  `dism /Split-Image`, and `bootsect /nt60` when the ISO has it. NTFS mode is optional (legacy BIOS; no UEFI:NTFS
  helper). Optional `-Sha256` check before writing.
- `-Benchmark -Letter X`: unbuffered (`NO_BUFFERING` + `WRITE_THROUGH`) sequential and 4 KiB random read/write
  on a temp file (default 256 MB), every block verified, free space checked, temp file deleted.
  `-Benchmark -ReadOnly -Disk N`: raw reads only. Results are kept in `history.json`; a slowdown over 30% against
  the median of earlier runs is flagged.
- `-Recover -Image`: copies readable files out of a rescue image attached read-only (raw images get a temporary
  VHD footer, removed exactly afterwards). `-Carve` runs PhotoRec if it is installed. Nothing is downloaded: the
  TestDisk download page is shown instead. The source stick is never touched.
- `-Watch Install|Uninstall|Status|Run [-DryRun]`: non-elevated scheduled task (at logon and every 30 minutes,
  hidden) that records read errors, drop-outs and capacity changes per drive in `history.json` and notifies (toast,
  BurntToast or msg) when errors rise or a verdict changes.
- `-PortMap [-Html]`: controllers, root hubs, hubs, ports and devices, with per-port errors and drops from the
  history and user port labels (`-LabelPort`, `port-labels.json`). Shown as text, as a section of the HTML/TXT
  `-Report`, and as a tree on the window's *Port map* tab.
- `-PreviewOnly` prints the plan of any Prepare tool without UAC.

### Docs
- Catalog: new "Prepare & Tools — destinations, not repairs" section that keeps "format is never a repair"
  explicit. The MBR refusal is clarified to cover repairs. PDF re-rendered.
- USBDoctor README: Prepare & Tools table, safety rules, wear-leveling note, limitations.

### Fixed after the first elevated VHD test run (2026-11-14)
- Format, wipe and the bootable maker reported `diskpart failed (exit 0)` although diskpart had succeeded:
  `online disk noerr` on a disk that is already online prints a harmless "Virtual Disk Service error: This disk is
  already online." The diskpart wrapper now trusts the exit code first, ignores only that message, and still fails on
  any other VDS error, "DiskPart has encountered an error", "not supported" or "Access is denied". After a wipe or
  raw-ISO clean, USBDoctor checks that the disk really has no partitions before writing; format already checked the
  new volume and its file system.
- Bootable (Windows mode) no longer stops on `System Volume Information` (access denied) when the source volume has
  one: that folder and `$RECYCLE.BIN` are skipped when listing, copying and verifying.
- Recovery from a rescue image waits for Windows to list the attached image's partitions and mount its volume (up
  to ~25 s instead of a fixed 2 s), brings an image that arrives offline online (that writes nothing to it), retries
  the drive letter and falls back to the volume GUID path. When a partition still can't be read, the reason is given.
- `-Benchmark -Letter` accepts `X`, `X:` and `X:\`; `-Format -Letter` accepts `X:\` too.
- Recovery could not read an NTFS image that was taken while the volume was mounted, or from a stick pulled without
  "Safely Remove" (found in the fifth elevated run, G36/G37). The Windows log showed NTFS refusing the read-only mount
  with `{Write Protect Error}` (0xC00000A2, "Volume restart applied: false"): the NTFS journal has to be replayed
  before the volume mounts, and the replay writes. USBDoctor now attaches the image read-only first; when a partition's
  file system will not mount, it detaches and re-attaches through a temporary differencing (overlay) disk in `%TEMP%`.
  The image is only the read-only parent, the replay goes into the overlay, and the overlay is deleted afterwards
  (an interrupted run cleans it up next time). A volume whose file system failed to mount is now recognised at once:
  Windows reports it as `Unknown`, not `RAW`, so the old check waited the full 15 s and never named the cause.
- The folder recovered files were copied into (`part1-<label>`) was hidden: robocopy gives the destination folder the
  Hidden+System attributes of the source volume root. USBDoctor now clears both after each copy (found in the
  recovery-only re-run; reproduced read-only with `robocopy H:\ <temp> /LEV:1 /XF * /XD *`).
- `Invoke-ImageRecovery -ForceOverlay` (module only, for tests and diagnosis) reads every partition through the
  overlay, so the overlay path is tested even when the image comes out clean.
- The overlay path failed with "The property 'Text' cannot be found on this object" the first time it ran elevated:
  the per-partition copy returned its results wrapped in one more array. The same mistake made an image with two or more
  partitions retry every partition through the overlay and fail to add up the copied-file counts. Fixed, and checked
  with a non-elevated mock test (mocked attach, real wrap, robocopy and cleanup).

### Test status
- Parse, import and non-elevated tests pass. These cover the benchmark logic against a test folder, the image-wrap
  round trip, the plans and refusals, the port map, port labels, health-watch dry runs, the window smoke test, and
  (new) the diskpart success detection against recorded real outputs and the System Volume Information skip.
- First elevated VHD run: 98 passed, 22 failed. Every refusal held (system disks, wrong phrases, dying drives,
  oversized ISOs). The failures were the diskpart bug above and its knock-on effects, the recovery timing, and harness
  bugs (`-SimulateWrapAt 32MB` passed as text through `powershell -File`; a GPT damage step that did not stick; it now patches the detached VHD file).
- Fifth elevated VHD run: 110 passed, 2 failed (G36/G37, the read-only NTFS mount above). The image hash and length
  stayed unchanged. Recovery-only re-run (`run-recovery.ps1`): files copied, but into a hidden folder (fixed above);
  the next re-run is pending.

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
