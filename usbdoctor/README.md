# USBDoctor

A Windows companion to DiskPilot and USBImager for **diagnosing and safely repairing USB drives**. It follows
the USB problem catalog ([../docs/USB-Problem-Catalog.md](../docs/USB-Problem-Catalog.md)): it diagnoses read-only first, works out who is at fault (the drive, the connection,
this PC, or permissions), and offers only the repair that is safe for that state. It **refuses** to write to a
drive that shows dying-media signatures, and it **never formats anything as a "repair"**. Separate from the
repairs, a clearly labelled **Prepare & Tools** area formats, wipes, makes bootable sticks, benchmarks, recovers
files from images, watches drive health and maps USB ports (see [Prepare & Tools](#prepare--tools-not-repairs)).

Plain Windows PowerShell 5.1 (a WinForms window plus a command line). Nothing to build or install.

## Order of operations (how every diagnosis runs)

1. **Diagnose read-only.** Inventory, event-log history, a *timed* raw read of the first 64 KiB (10 s timeout,
   administrator), boot-sector / partition-table checks, a folder-access test. Nothing is written to the drive.
2. **Tier 0: find the fault owner.** Drive, connection (port/hub/cable), this machine (WMI, storage stack,
   USBSTOR driver, host controllers, whether other USB disks work), or permissions. Verdicts that blame the drive
   stay **provisional** until it has been tried on another port or PC (recorded with `-Tier0Result` or the Tier 0
   buttons). A local history file remembers every port a stick was seen on, read errors and drops per port, and
   time from plug-in to drop, so USBDoctor can say "same failure on N ports".
3. **Image before any writing repair.** Every writing repair is gated: it needs a completed Rescue image of that
   drive on file (recorded in the history), or you type **`REPAIR <disk>`** to accept the risk. The exception is
   drive-letter assignment, which only changes Windows' records.
4. **Refuse on dying-media signatures.** A disconnect during reading, detection or a raw read that never
   completes, and capacity that flaps or shrinks all give the verdict **"DYING - image what you can, do not
   repair"**.

Every drive gets the same four-part answer:

```
STATE:        what is wrong
FAULT OWNER:  drive / connection / machine / permissions (provisional or confirmed)
SAFE ACTION:  the one safe thing to do (or REFUSED: and why)
TO CHANGE:    what would have to change for a different answer
```

## Start it

Double-click **`USBDoctor.cmd`** and approve the UAC prompt. The window checks every USB drive and shows the
State and Fault owner for each. Select a drive to see its findings and the four-part assessment.

Read-only checks also work from a normal (non-admin) PowerShell, with no UAC prompt. Without admin, the timed raw
read and the boot-sector checks are skipped, and the output says so:

```
powershell -File USBDoctor.ps1 -List
powershell -File USBDoctor.ps1 -Diagnose [-Disk N]
powershell -File USBDoctor.ps1 -Report [-ReportDir X]     # TXT + HTML; default D:\USB-Backups\Reports (or Documents)
```

## Coverage table (catalog #0-#15 and refusal list)

"Detect only" means USBDoctor reports the problem and gives the safe next step but changes nothing. "Repair" means
USBDoctor can make the change itself, after a preview, the gate, and confirmation.

| # | Catalog problem | USBDoctor feature / switch | Detect only / Repair |
|---|---|---|---|
| 0 | Tier 0: whose fault (drive, port, machine, permissions) | `-Diagnose` fault owner. History file `C:\ProgramData\USBDoctor\history.json` (ports, hub or not, per-port errors/drops, time-to-drop, raw-read results, Tier 0 results). Machine health: WMI timing with timeout, Get-Disk time, USBSTOR start type and driver file, host controller/root hub errors, other USB disks healthy. Prompts to try another port/PC; `-Tier0Result OtherPortFails\|OtherPortWorks\|OtherMachineFails\|OtherMachineWorks -Disk N` (or the GUI Tier 0 buttons) records the result. | Detect only (records history) |
| 1 | Code 43 / descriptor request failed | System section: present Code 43 devices and absent "Device Descriptor Request Failed" ghosts are reported as **hardware, no repair**, with the ports involved. `-RemoveGhostDevices` only cleans up the leftover entries. | Detect only (no repair exists) |
| 2 | Code 10 / 28 / 31 | Fault owner: machine. `-ResetDevice -Device <instance id>` (pnputil remove + rescan); `-RemoveGhostDevices` does all failed entries. Checks the USBSTOR service start type (3 expected; 4 = disabled by policy, reported, not overridden) and that `USBSTOR.SYS` exists. | Repair (remove + rescan) |
| 3 | Letter appears but never finishes | Timed raw read of the first 64 KiB, 10 s timeout, in a separate runspace (`Test-RawRead`). Completes: file-system issue, continue. Times out, fails, or the disk vanishes: **DYING**, image only. Also flags a volume that has a letter but no size. | Detect only |
| 4 | Offline, incl. signature collision | `-Online -Disk N`. On a collision (OfflineReason or partmgr event 58) it states first that Windows will write a **new MBR disk signature** and what that breaks; needs typed `REPAIR N`. | Repair (gated) |
| 5 | RAW | Reads the partition's boot sector. Identifies non-Windows file systems (ext2/3/4, APFS, HFS+, XFS, Btrfs, F2FS, LUKS, swap, ISO 9660, ReFS, BitLocker): **"healthy drive, wrong OS"**, no repair. A damaged NTFS/FAT32/exFAT boot sector with an intact backup: `-RestoreBootSector -Disk N [-Partition P]` copies the backup back, after saving the damaged sectors (image first or `REPAIR N`). **Never offers format.** | Detect only (foreign FS); Repair (boot sector from backup, gated) |
| 6 | No drive letter | `-AssignLetter -Disk N [-Letter X] -Persistent`, verified in `HKLM\SYSTEM\MountedDevices`; warns when a stick without a unique serial is keyed by port. `-EnableAutomount` if automount is off. Not gated (letter assignment is the exception). | Repair |
| 7 | Letter conflicts | Checks volumes, `net use` (incl. disconnected mappings), `HKCU\Network`, `subst`, and MountedDevices reservations. Diagnosis shows the squatter when a volume's remembered letter is taken. Assignment refuses a used letter; a reservation by an absent drive is released only with `-Force` / "Release reservation", after the entry is shown and logged. Network mappings are never deleted. | Repair (assign another letter; reservation release only on request) |
| 8 | Read-only | `-ClearReadOnly -Disk N`: clears disk and partition read-only (gated), remounts, test-writes 64 KiB, records the clear in history, asks for a replug and re-diagnose. If read-only comes back: **DYING, copy-only**, and a second clear is refused. | Repair (once, gated) |
| 9 | Access denied | Folder-access test on each volume. Denials on a readable disk are reported as **permissions, disk is fine**, with the exact `takeown` / `icacls` commands. USBDoctor stops there. | Detect only |
| 10 | Dirty bit | `fsutil dirty query`. `-Chkdsk -Letter X` (chkdsk /f /x) runs only when the timed raw read passed (no #3 symptoms) and the gate is satisfied; otherwise it is refused and you are told to image first. | Repair (gated) |
| 11 | Partition table | GPT: validates primary and backup headers and entry CRCs. `-RestoreGpt -Disk N` rebuilds the primary from the backup (CRCs recomputed, damaged sectors saved first), only when the protective MBR is present. **MBR: no backup exists**, so it is reported, not written; USBDoctor refuses MBR writes (DiskPilot rule) and says why. | Repair (GPT, gated); Detect only (MBR) |
| 12 | Partition fine, FS unreadable after imaging | A valid boot sector that Windows still can't mount, or an unrecognisable partition with no backup: after the Rescue image, rebuild with **USBImager**. | Detect only (hand-off to USBImager) |
| 13 | Counterfeit capacity | `-CapacityTest -Disk N [-Quick] -ConfirmPhrase "ERASE N"`: destructive write-then-read-verify of every 1 MiB block across the full claimed size, **only on a blank/empty stick**. Failures = counterfeit, recorded in history, condemned; extend is then refused. A genuine stick with a short partition is reported as a truncated partition: `-Extend` (NTFS/exFAT) or `-ConvertToNtfs` then `-Extend`, or rebuild with USBImager. | Repair (extend); test is destructive and opt-in |
| 14 | Intermittent disconnects | Surprise removals and drops per port from the event log and history, with time-to-drop. Advice: rear port, no hub or extension. `-DisableSelectiveSuspend` if USB power saving is on. A drop during reading counts as a dying signature. | Detect only (+ power setting) |
| 15 | Drops to zero or RAW after replug | Capacity 0, or capacity that changes between connects (event 1006 history): treated as #3 + #13, **DYING, image immediately**: `-Rescue -Disk N` (skip-on-error, zero-fill, resume after unplug/replug). | Detect only (+ rescue image) |
| ImageUSB | Partition table 512 bytes late (imageUSB header in sector 0) | Design decision: the stick's MBR is **not** rewritten. `-FixImageUsbShift -Disk N [-Out clean.img]` makes a Rescue image of the stick (read-only), strips the 512-byte imageUSB header from the **image file** so the MBR is at offset 0, verifies it, and prints the USBImager burn command (`USBImager.cmd -Burn -Image clean.img -Disk <N>`). `-FixImageUsbShift -Image file.img` fixes an existing image file without touching any disk. USBDoctor refuses MBR writes on real disks, same as DiskPilot. | Repair of the image file only; the disk is only read |

| Refusal (from the catalog) | How USBDoctor enforces it |
|---|---|
| Any write repair on a drive that disconnects during read-only diagnosis | `Assert-WriteGate` refuses every writing repair (online, clear read-only, chkdsk, boot sector, GPT, extend, convert) when a dying signature is present: drop after read errors, raw read timeout/error, vanished during read, capacity 0 or flapping, read-only returned. |
| chkdsk or boot-sector repair on a drive whose raw first-sector read times out | Gate kinds `Chkdsk` and `BootSector` are refused unless the timed raw read completed. |
| Capacity "repair" on a counterfeit | Gate kind `Extend` is refused when the history has a failed capacity test. |
| Clearing read-only a second time after it returned on replug | `-ClearReadOnly` checks the history and refuses; the drive is marked DYING / copy-only. |
| Formatting anything as a "repair" | No format, initialize, or clean code exists in the repair engine (`USBDoctor.Core.psm1`), and no diagnosis ever suggests a format. Empty or unreadable partitions point to a Rescue image and USBImager / DiskPilot for a deliberate rebuild. Format, wipe and the bootable maker exist only in the separate Prepare & Tools area, as destinations you choose. |

## Fixes and the gate

Every fix first shows a preview of exactly what it will do (a dialog in the window, or the plan text on the
command line), including the gate status:

- **Refused** with the reason (dying signature, counterfeit, read-only returned), or
- **Rescue image on file** (no typed phrase needed), or
- **No image**: type `REPAIR <disk>` to accept the risk of writing without one.

The capacity test always needs `ERASE <disk>` and only runs on a blank stick. All fixes are logged to
`C:\ProgramData\USBDoctor\USBDoctor.log`. Repairs that overwrite sectors (boot sector, GPT) first save the old
sectors to `D:\USB-Backups\USBDoctor-Backups\` so they can be undone.

| Fix | Switch | Gated | What it writes |
|---|---|---|---|
| Assign / keep a drive letter | `-AssignLetter -Disk N [-Letter X] [-Persistent] [-Force]` | no | Windows mount records only |
| Enable automount | `-EnableAutomount` | no | `mountvol /E` |
| USB power saving off | `-DisableSelectiveSuspend` | no | current power plan |
| Remove failed devices / reset one | `-RemoveGhostDevices [-IncludeOldDrives]`, `-ResetDevice -Device ID` | no | device entries (pnputil) |
| Bring online | `-Online -Disk N` | yes | disk attribute (+ new signature on a collision, disclosed) |
| Clear read-only | `-ClearReadOnly -Disk N` | yes | disk/partition attribute + 64 KiB test file |
| Check disk | `-Chkdsk -Letter X` | yes | file system (chkdsk /f /x) |
| Restore boot sector | `-RestoreBootSector -Disk N [-Partition P]` | yes | 1 (NTFS), 3 (FAT32) or 12 (exFAT) sectors |
| Restore GPT | `-RestoreGpt -Disk N` | yes | GPT header (LBA 1) + entry array; never the MBR |
| Extend | `-Extend -Disk N [-Partition P]` | yes | partition table + file system size |
| FAT32 to NTFS | `-ConvertToNtfs -Letter X` | yes | file system (`convert /FS:NTFS /NoSecurity`) |
| ImageUSB fix | `-FixImageUsbShift -Disk N [-Out f]` / `-Image f` | n/a | image files only |
| Capacity test | `-CapacityTest -Disk N [-Quick] -ConfirmPhrase "ERASE N"` | blank only | whole stick (destructive) |
| Rescue copy | `-Rescue -Disk N` or `-WaitForModel text` `[-Out f] [-WaitMinutes 30]` | n/a | image file only |
| Safe eject | `-Eject -Letter X` | no | nothing |

Only USB disks are ever changed. The disks holding C:, D:, Windows, boot or the pagefile are refused, and so is
anything that isn't on the USB bus.

## Rescue copy

`-Rescue -Disk N` (or the window's "Start rescue copy") reads the whole stick into an image file. It uses 1 MiB
reads, retries unreadable blocks in 4 KiB pieces, zero-fills what can't be read (listed in
`<image>.badranges.txt`), and saves progress to `<image>.rescue.json`. If the stick drops out, it waits for the
same stick (model, serial, size) to come back and carries on. Stop it and run the same command again to resume.
A completed image is recorded in the history, which unlocks gated repairs for that drive without the typed phrase.

## Prepare & Tools (not repairs)

Format, wipe and the bootable maker are **not repairs**. USBDoctor never proposes them as a fix for any problem in
the catalog: its repairs never format and never write an MBR. These tools are destinations you choose. They live in
a separate module (`USBDoctor.Tools.psm1`), behind their own switches and on their own window tab,
**Prepare / Tools (not repairs)**, which carries a red warning. They build a brand-new partition table from scratch
and erase the whole stick.

Every erasing tool:

- Works only on USB disks. The disks holding C:, D:, Windows, boot or the pagefile are refused, and so is
  anything that isn't on the USB bus.
- Refuses a drive with dying-media signatures ("image it, don't prepare it"), a drive recorded as counterfeit by
  the capacity test, and a read-only drive.
- Shows a plan first (`-PreviewOnly`, or the window's dialog). The plan says whether the stick holds files and
  whether a Rescue image of it exists. If it holds files and has no image, you are offered a Rescue copy first.
- Needs the typed phrase **`ERASE <disk>`**, re-checks the disk's identity just before writing, and logs
  everything.

| Tool | Switch | What it does | Erases |
|---|---|---|---|
| Format / prepare | `-Format -Disk N [-FileSystem exFAT\|NTFS\|FAT32] [-Label X] [-Letter Y] [-PartitionStyle Auto\|MBR\|GPT] [-SizeMB n]` | `diskpart clean`, a new partition table (Auto = MBR, or GPT above 2 TB), one primary partition starting at 1 MiB (aligned) and filling the disk (or `-SizeMB`), quick format, a letter. Defaults: exFAT, label `USB`. **FAT32 over 32 GB is refused** with a clear message: use exFAT or NTFS, or a smaller FAT32 partition with `-SizeMB 32000`. Labels are checked (FAT32/exFAT max 11 characters). | yes, `ERASE N` |
| Wipe | `-Wipe -Disk N [-Passes Zero\|Random]` | Removes the partition table, then one pass of zeros or seeded pseudo-random data over every byte (64 MB slices, progress, ETA, Stop button). Verifies the first and last MiB and 64 random 1 MiB samples. Random mode zeroes the first MiB at the end so Windows sees a blank disk. | yes, `ERASE N` |
| Bootable maker | `-MakeBootable -Iso file -Disk N [-Mode Auto\|Windows\|Raw] [-Sha256 hex] [-FileSystem FAT32\|NTFS] [-Label X]` | Computes the ISO's SHA-256 and refuses a mismatch with `-Sha256` before writing anything. **Raw** (hybrid ISOs with an MBR in sector 0, which covers most Linux installers): written byte-for-byte like `dd`, then read back and compared. **Windows** (detected by mounting the ISO read-only: `sources\boot.wim`, an install image, `bootmgr`/`efi\boot`): new MBR table, one active FAT32 partition (max 32000 MB), files copied, and `install.wim` over 4 GB split into `install.swm` parts with `dism /Split-Image`. `boot\bootsect.exe /nt60` is run from the ISO if present. Optional NTFS mode boots legacy BIOS only, because no UEFI:NTFS helper is added. ISOs that are neither are refused. | yes, `ERASE N` |
| Benchmark | `-Benchmark -Letter X [-SizeMB 256]` / `-Benchmark -ReadOnly -Disk N [-SizeMB 256]` | **File mode** (no UAC): one temp file, unbuffered (`FILE_FLAG_NO_BUFFERING` + `WRITE_THROUGH`). It measures sequential write and read, then 4 KiB random write and read (8 s or 4000 operations each). Every 4 KiB block is verified. Free space is checked first and the temp file is always deleted. **-ReadOnly** (administrator): raw reads only, nothing written. Results go to the stick's history (last 20). A run more than 30% slower than the median of the last 5 runs in the same mode is flagged. Refused on dying drives; file mode is also refused on counterfeit sticks. | no (temp file only) |
| Recover from an image | `-Recover -Image file.img [-OutDir dir] [-Carve] [-ToolsDir dir]` | Works on the **image file only**; the stick is never opened. Attaches the image **read-only**; if a file system needs its journal replayed before Windows will mount it (a stick pulled without Safely Remove), it re-attaches through a temporary overlay disk that takes the writes and is deleted afterwards, so the image is still never written. A raw `.img` gets a temporary 512-byte fixed-VHD footer exposed as a `.vhd` hard link, which is removed afterwards, and the image's length and contents are restored exactly. Readable files are copied with robocopy. `-Carve` runs PhotoRec (TestDisk suite) on the image for deleted or lost files, if PhotoRec is found in PATH, `-ToolsDir`, `C:\ProgramData\USBDoctor\tools`, Program Files or Downloads. If not, USBDoctor prints the download page (https://www.cgsecurity.org/wiki/TestDisk_Download). It **never downloads binaries**. | no |
| Health watch | `-Watch Install\|Uninstall\|Status\|Run [-DryRun]` | Installs a scheduled task, *USBDoctor Health Watch*, that runs as you and **not elevated**: at logon and every 30 minutes, in a hidden window. Each pass reads the event logs for read errors, drop-outs and capacity changes per USB drive, stores them in `history.json`, and shows a notification when a drive's errors rise (3 or more new read errors, or new drops) or its verdict changes (OK, ERRORS or DYING). Notifications use a Windows toast, then BurntToast, then `msg.exe`. `-DryRun` computes and prints only. | no |
| Port map | `-PortMap [-Html file]`, `-LabelPort 'front-left' (-Disk N \| -Port key)` | Tree of USB host controllers, root hubs, hubs, ports and devices, with errors and drops per port from the history. Ports with problems are marked. Text on the console, an HTML section in `-Report`, and a tree on the window's **Port map** tab. Your port labels are kept in `C:\ProgramData\USBDoctor\port-labels.json` (`-LabelPort -` removes one). | no |

**Wipe and wear leveling.** USB flash controllers remap worn blocks internally. Old data in blocks the controller
has retired can survive any overwrite, and no tool on the PC can reach them. A wipe is therefore **not guaranteed
erasure**. For sensitive data, encrypt the stick from the start (BitLocker To Go). For a stick that held sensitive
data unencrypted, destroy it physically.

## Files

| File | Purpose |
|---|---|
| `USBDoctor.cmd` | Launcher (double-click); self-elevates through the UNC path |
| `USBDoctor.ps1` | Window + command line |
| `USBDoctor.Core.psm1` | Diagnosis and repair logic (inventory, diagnosis, Tier 0, gate, repairs, rescue, report); no format code |
| `USBDoctor.Tools.psm1` | Prepare & Tools (not repairs): format, wipe, bootable maker, benchmark, image recovery, health watch, port map |
| `C:\ProgramData\USBDoctor\USBDoctor.log` | Log of every check and change |
| `C:\ProgramData\USBDoctor\history.json` | Per-stick history: ports, errors/drops, raw reads, Tier 0 results, read-only clears, capacity tests, images, benchmarks, prepare actions, watch passes |
| `C:\ProgramData\USBDoctor\port-labels.json` | Your names for USB ports (port map) |

## Known limitations

- **Test status (2026-11-14):** the 1.1.0 build (repairs plus Prepare & Tools) is parse-checked, import-checked and
  dry-run checked without admin rights. The benchmark logic ran against a test folder, the image-wrap round trip
  ran on a test file, and the plans (previews), refusals, port map, labels and a watch dry run ran against real
  hardware read-only. The elevated test run against virtual disks (VHDs), which covers the v2 repairs and the new
  format, wipe, bootable, raw benchmark and recovery paths, is **still pending**. Treat the repairs and the Prepare
  tools as beta and try them on a disposable stick first.

- Without administrator rights, the timed raw read (#3), boot-sector, GPT and ImageUSB checks are skipped. Dying
  detection then relies on the event log only.
- Sticks without a unique USB serial are identified by VID/PID plus a blank serial, so two identical no-name sticks
  share one history entry.
- Port identification comes from the PnP parent and location path. Only one plug-in history is kept per port and
  hub instance.
- The capacity test skips the first 1 MiB, but on a counterfeit stick, writes past the real flash wrap around and
  can land there anyway. That's why the test only runs on a blank stick with `ERASE N`.
- Prepare & Tools: FAT32 above 32 GB is refused rather than formatted with a custom formatter. The Windows bootable
  maker adds no UEFI:NTFS helper, so NTFS mode boots legacy BIOS only (FAT32 mode, the default, boots both).
  Wipe can't guarantee erasure on flash (see above).
- Recovery attaches images through Windows (administrator). PhotoRec can't read `.vhdx`; carve a raw `.img` instead.
- The health watch task starts a hidden PowerShell window, which may flash briefly. Toast display depends on
  Windows notification settings.
- The port map takes 10-20 s (PnP property queries) and lists ports that have a device attached, plus labelled or
  previously used ports that are empty now.
- A hung raw read is abandoned, not killed. Windows may keep that thread until the stick is unplugged.
- Bringing a signature-collision disk online lets Windows rewrite the 4-byte disk signature. That is the one
  MBR-area change USBDoctor allows (Windows makes it, and it's disclosed first).
