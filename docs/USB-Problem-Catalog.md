# USB Drive Problem Catalog — DiskPilot / USBImager / USBDoctor

A field catalog of the USB drive problems this repository's tools are built around, drawn from real case files.
Each entry says what you see, what usually causes it, how to tell, what the safe repair is, and a
**Tool coverage** line naming the switch, whether the tool only detects the problem or also repairs it, and the
gate the repair must pass.

- **DiskPilot** (`partition/`): general partition manager. GPT writes only; MBR disks are display-only.
  Formatting is something you choose here deliberately, never a "repair".
- **USBImager** (`usbimager/`): capture a stick to an image, burn an image to a stick (whole-drive erase,
  typed `ERASE <n>`).
- **USBDoctor** (`usbdoctor/`): read-only diagnosis, fault owner, gated repairs, rescue copies; plus a
  separate Prepare & Tools area (format, wipe, bootable maker, benchmark, recovery, health watch, port map) that
  is never offered as a repair.

"Gated" means the repair needs a completed USBDoctor Rescue image of that drive on file, or a typed
`REPAIR <n>` that accepts the risk. It is refused outright when the drive shows dying-media signatures.

## The standing order of operations (applies to every entry below)

1. **Diagnose read-only.** Nothing writes during detection. Same rule as the rest of DiskPilot.
2. **Decide whose fault it is before repairing anything (Tier 0).** Half of "bad drives" are bad ports, bad hubs,
   or a sick Windows.
3. **Image before repair.** Any fix that writes (letter assignment excluded, see #6) is offered only after a raw
   image exists or the user explicitly accepts the risk with the typed confirmation.
4. **Refuse on dying-media signatures.** Repeated disconnects during reads, detection that never completes,
   reported capacity that shrinks or changes. The verdict is "dying — image what you can, do not repair", not a
   fix attempt.

**Tool coverage:** USBDoctor applies this order to every diagnosis (`-Diagnose`, the window, `-Report`). The
write gate (`Assert-WriteGate`) enforces steps 3 and 4 for every writing repair.

## Tier 0 — Differential first: drive, connection, or machine?

**Symptom:** any of the failures below. **Test:** same drive in a different port (directly on the PC, no hub or
extension cable), then the same drive on a different machine. **Read:** fails the same way on a healthy machine →
the drive. Works on the other machine → the first machine's USB/storage stack or the port. Works in another port →
the port or hub power.

**Why it's in the tool.** Case: a PC whose Explorer hung for months because of a pile-up of cloud-storage shell
extensions, and which still had unresolved WMI hangs afterwards. That machine had blamed hardware before. A repair
tool that skips this step will "fix" healthy drives on sick machines.

**Tool coverage:** USBDoctor, detect only.

- Every diagnosis names a fault owner: drive, connection, machine, permissions, or "healthy drive, wrong OS".
- A local history file (`C:\ProgramData\USBDoctor\history.json`) records, per stick, the items below, so USBDoctor can say "same failure on N ports":
  - every port it was seen on, and whether that was through a hub;
  - read errors and drops on each port;
  - time from plug-in to drop.
- Machine health is checked: WMI response time (with a timeout), the USB mass-storage driver (USBSTOR) and its
  start type, host controller and root hub errors, and whether other USB disks on the machine work.
- A drive verdict stays **provisional** until you record the result of trying it elsewhere with
  `-Tier0Result OtherPortFails|OtherPortWorks|OtherMachineFails|OtherMachineWorks` (or the Tier 0 buttons in the
  window).

## Tier 1 — Detection and enumeration

### #1 Device descriptor request failed (Device Manager Code 43)

- **Sees:** "USB device not recognized"; the device shows as Unknown USB Device.
- **Usually:** dead controller, damaged connector, or cheap counterfeit hardware that never worked right.
- **Diagnose:** second machine (Tier 0). If Code 43 follows the drive, it's the drive.
- **Repair:** none safe. Verdict: hardware failure. Offer an image only if it ever enumerates as a disk.

**Tool coverage:** USBDoctor, detect only.

- Present Code 43 devices are reported as hardware faults with no repair.
- Leftover "Device Descriptor Request Failed" entries are listed with the ports they failed on.
- `-RemoveGhostDevices` only tidies away those leftover entries. It does not repair anything.

### #2 Device enumerates, no disk appears (Code 10 / 28 / 31)

- **Sees:** something appears in Device Manager with a warning, nothing in Disk Management.
- **Usually:** a driver stack problem on that machine, not the drive.
- **Repair (machine side, safe):** remove the device in Device Manager and rescan; check the USB mass-storage driver.
  Never format anything; there is nothing to format yet.

**Tool coverage:** USBDoctor, repair (machine side, not gated).

- Fault owner is reported as the machine.
- `-ResetDevice -Device <instance id>` runs `pnputil` remove and rescan for one device; `-RemoveGhostDevices` does
  every failed entry.
- The USBSTOR start type is checked: 3 is expected; 4 means disabled, usually by policy. It is reported but not
  overridden.

### #3 Disk appears, takes a letter, never finishes detecting

Case: a stick that showed up as a drive letter and then hung Explorer.

- **Sees:** the drive shows a letter in Explorer but hangs on open. Disk Management sits at "Connecting to Virtual
  Disk Service", or the volume never reports a filesystem.
- **Usually:** the controller is alive but the media underneath is failing: bad blocks in the early filesystem
  structures, dying NAND.
- **Diagnose:** read-only raw read of the first sectors with a timeout. Completes → filesystem damage (see
  #10/#11). Times out or disconnects → dying media.
- **Repair:** none on the original. Image first (raw, with retry and skip-bad-regions), then repair the image or a
  clone, never the source. If imaging itself can't complete, the verdict is dying.

**Tool coverage:** USBDoctor, detect only (+ rescue image).

- `Test-RawRead` reads the first 64 KiB with a 10 s watchdog, as administrator. A timeout, read error, or the disk
  vanishing marks the drive **DYING**.
- `-Rescue -Disk N` images it: 1 MiB reads, 4 KiB retries, zero-fill of unreadable areas, resume after a
  drop-out.
- All write repairs are refused on that drive.

### #4 Disk shows Offline

- **Sees:** Disk Management lists the disk as Offline; a signature collision warning is common.
- **Usually:** the disk's signature collides with another disk (typical after cloning; imaged sticks do this), or a
  policy set it offline.
- **Repair (safe, metadata only):** bring it online in Disk Management, or with `diskpart` (`online disk`). If
  Windows reports a signature collision, bringing it online makes Windows write a new disk signature. Disclose that
  before doing it.

**Tool coverage:** USBDoctor, repair (gated).

- `-Online -Disk N`.
- On a collision, the preview says first that Windows will write a new 4-byte MBR disk signature, and what that
  breaks. It then needs typed `REPAIR <n>`.
- USBImager's raw burn also fixes a collision on the stick it just wrote.

### #5 Volume shows RAW / "You need to format the disk before you can use it"

- **Sees:** the letter exists; Explorer demands a format.
- **Usually:** Windows doesn't recognise the filesystem boot sector or type. Either the FAT/exFAT/NTFS boot region
  is corrupt, or a healthy drive holds a filesystem Windows can't read (ext4, APFS).
- **Diagnose:** read the boot sector.
  - Valid non-Windows signature → healthy drive, wrong OS. Say so and stop.
  - Corrupt boot sector with a valid backup (NTFS, FAT32 and exFAT keep one) → recoverable.
- **Repair:** restore from the backup boot sector, or carve files from an image. The format prompt is the trap; the
  tool's job is to stand between the user and that button.

**Tool coverage:** USBDoctor, detect only for foreign file systems; repair (gated) from a backup boot sector.

- Identifies ext2/3/4, APFS, HFS+, XFS, Btrfs, F2FS, LUKS, swap, ISO 9660, ReFS and BitLocker, and reports
  "healthy drive, wrong OS".
- `-RestoreBootSector -Disk N [-Partition P]` saves the damaged sectors to a file, then copies the intact backup over them:
  - NTFS: the last sector of the partition.
  - FAT32: sectors 6–8.
  - exFAT: sectors 12–23.
- Format is never offered.

## Tier 2 — Identity and access

### #6 No drive letter

Case: a letter-less stick that was never broken.

- **Sees:** Disk Management shows a healthy partition with no letter; Explorer shows nothing.
- **Usually:** automount cleared the letter, or no letter was ever assigned after imaging/cloning.
- **Repair (safe, the one write that's metadata-only and reversible):** assign an unused letter (`diskpart`:
  `assign letter=X`, or `mountvol`). This is the correct first fix and the tool's most confident one.
- **Case outcome:** a stick that had been put aside as "broken" for a long time came back with nothing more than
  a letter assignment.

**Tool coverage:** USBDoctor, repair (not gated).

- `-AssignLetter -Disk N [-Letter X] -Persistent`. Afterwards it checks that Windows recorded the letter for that
  drive in `HKLM\SYSTEM\MountedDevices`.
- It warns that a stick without a unique serial is identified by its USB port, so a fixed letter only follows it
  on that port.
- `-EnableAutomount` fixes automount when it is off.

### #7 Drive letter conflict / squatting

- **Sees:** the USB drive gets no letter, or a letter that opens a network share or nothing at all.
- **Usually:** the letter is held by a mapped network drive or another device. A disconnected mapping can squat
  invisibly.
- **Repair:** list current mappings (`net use`), find the squatter, assign the USB volume a free letter. Don't
  delete the user's network mapping without showing it first.

**Tool coverage:** USBDoctor, repair (assign a different letter; not gated).

- Checks volumes, `net use` (including disconnected mappings), `HKCU\Network`, `subst` and MountedDevices
  reservations, and shows the squatter.
- A reservation held by an absent drive is released only on request (`-Force` / "Release reservation"), after it
  is shown and logged.
- Network mappings are never deleted.

### #8 Disk or volume stuck read-only

- **Sees:** files are visible, every write fails; `diskpart` reports `Read-only: Yes`.
- Two very different causes, and the tool must separate them:
  - **Attribute stuck** (the volume/disk read-only flag is set, common after a dirty removal). Clear it with
    `attributes disk clear readonly` / `attributes volume clear readonly`. Safe repair.
  - **NAND end of life.** Failing flash controllers drop into permanent read-only so you can copy the data off.
    The clear appears to work, or fails outright, and the read-only state returns. Diagnose by clearing, writing a
    test file, and re-reading the attribute after a replug. If it comes back → verdict: dying, copy-only mode, no
    repair.

**Tool coverage:** USBDoctor, repair once (gated).

- `-ClearReadOnly -Disk N` clears the disk and partition flags, remounts, writes, reads back and deletes a 64 KiB
  test file, records the clear, and asks for a replug and re-diagnose.
- If read-only returns, the drive is marked **DYING / copy-only** and a second clear is refused.

### #9 Access denied on a healthy volume

- **Sees:** the letter opens, folders deny access.
- **Usually:** NTFS permissions from another machine/profile, not damage.
- **Repair:** not a disk repair. Identify it as permissions, point at take-ownership/ACL tools, and stop. The tool
  should say "the disk is fine" out loud.

**Tool coverage:** USBDoctor, detect only.

- A folder-access test reports the denied folders and says the disk is fine.
- It gives the exact `takeown` / `icacls` commands and changes nothing.

## Tier 3 — Filesystem (image first, then repair the copy or with consent)

### #10 Dirty bit / "scan and fix" prompt on every plug-in

- **Sees:** Windows offers Scan and fix; chkdsk reports the volume dirty.
- **Usually:** unclean removal. Sometimes: the early warning of #3.
- **Repair:** chkdsk /f on a healthy drive is fine. On any drive that also shows #3 symptoms, imaging comes first,
  because chkdsk on failing media finishes the job the failure started.

**Tool coverage:** USBDoctor, repair (gated).

- `-Chkdsk -Letter X` runs `chkdsk /f /x` only after the timed raw read completed.
- It is refused on a drive with #3 symptoms or any dying signature.

### #11 Corrupt partition table (MBR/GPT)

- **Sees:** the disk shows as unallocated or with the wrong layout; partitions are gone.
- **Usually:** an interrupted write, a bad imaging run, or a tool that wrote the table wrong.
- **Diagnose:** GPT keeps a backup header and partition list at the end of the disk. Check it before declaring
  loss.
- **Repair:** restore the GPT from its backup. MBR has no backup; partition recovery is carve-and-rebuild
  territory.
- **Boundary note:** DiskPilot refuses MBR writes by design (MBR disks are display-only), and USBDoctor inherits
  that refusal and says why.

**Tool coverage:** USBDoctor; repair (gated) for GPT, detect only for MBR.

- USBDoctor validates both GPT headers and their CRCs.
- `-RestoreGpt -Disk N` rebuilds the primary header and partition list from the backup, with CRCs recomputed and
  the damaged sectors saved first. It only runs when the protective MBR is intact, because USBDoctor never writes an
  MBR.
- A damaged MBR is reported. The way back is: image it (`-Rescue`), recover from the image, rebuild with USBImager.

### #12 Partition fine, filesystem unreadable after imaging

- **Sees:** an imaged-and-restored stick boots or reads on one OS and not another.
- **Usually:** the restore preserved the files but not the exact filesystem the target expects. A
  whole-capacity restore changes the partition size, and the filesystem must be rebuilt to match, not stretched.
- **Repair:** rewrite the filesystem at the new size from the file set, rather than sector-stretching the old one.

**Tool coverage:** USBImager repair; USBDoctor detect only.

- USBImager's **Files** capture (`.vhdx`) + burn builds one new partition across the whole stick (NTFS or exFAT)
  and copies the files back, with count/byte verification.
- A raw `.img` burn only extends a last NTFS partition.
- USBDoctor reports an unmountable filesystem (or one with no recognisable boot sector and no backup) and points to
  this rebuild path after imaging.

## Tier 4 — Capacity and media truth

### #13 Reported capacity lies

- **Sees:** a stick claims 512 GB and files are corrupt past ~32 GB; or a real stick shows only part of its size.
- **Two directions:**
  - **Counterfeit:** the controller reports false capacity, so writes past the real NAND wrap around and destroy
    earlier data. Diagnose with a write-read-verify pass across the full claimed size, on a blank stick only, since
    the test is destructive.
  - **Truncated:** the partition is smaller than the device. Repair by extending or rebuilding at full capacity
    (USBImager's core case).
- **Verdict matters:** counterfeit = condemn; truncated = repair.

**Tool coverage:** USBDoctor capacity test (destructive, opt-in) and repair (gated).

- `-CapacityTest -Disk N [-Quick] -ConfirmPhrase "ERASE N"` runs only on a blank or empty stick. It writes a
  unique pattern to every 1 MiB block, then reads them all back.
- A counterfeit result is recorded in the history, and `-Extend` is then refused on that stick.
- A truncated partition gets `-Extend` (NTFS/exFAT), or `-ConvertToNtfs` then `-Extend`, or a USBImager rebuild.

### #14 Intermittent disconnects under load

- **Sees:** the drive appears, vanishes mid-copy, reappears.
- **Usually:** power (hub, front-panel port, cable) before media. Tier 0 separates them: a different port (directly
  on the PC, no hub; rear ports where the PC has accessible ones), a different cable.
- **Repair:** none on the drive if power is the cause. If disconnects follow the drive across machines and ports →
  controller dying; image in small chunks if anything is needed.

**Tool coverage:** USBDoctor, detect only.

- Per-port drops and surprise removals from the event log and history, with time-to-drop, plus advice on ports
  and hubs.
- `-DisableSelectiveSuspend` turns off USB power saving if it is on.
- A drop during reading counts as a dying signature.
- `-Rescue` images resumably: progress is saved continuously, so a drop only pauses the copy.

### #15 Works, then drops to zero bytes / asks to format after replug

- **Sees:** fine one session, RAW or empty the next.
- **Usually:** end-stage NAND failure, or a counterfeit at its wrap point. Treat as #3 + #13 combined: image
  immediately if it ever reads, and expect the image to be partial.

**Tool coverage:** USBDoctor, detect only (+ rescue image).

- Zero capacity, or a capacity that changes between connects (from the Partition/Diagnostic event log), marks the
  drive **DYING**.
- `-Rescue -Disk N` images what it can.

### ImageUSB-shifted partition table (not a failure; a burn artefact)

- **Sees:** a stick written raw from an ImageUSB `.bin` shows as RAW / unpartitioned. Sector 0 holds an `imageUSB`
  header and the real MBR sits in sector 1 (the `0x55AA` signature at byte 1022 instead of 510).
- **Repair route:** **never rewrite the stick in place.**
  1. Image the stick (raw).
  2. Fix the image file by stripping the 512-byte header, so the MBR is at offset 0.
  3. Burn the clean image with USBImager.

**Tool coverage:** USBDoctor; repairs the image file only, the stick is just read.

- `-FixImageUsbShift -Disk N [-Out clean.img]` does steps 1–2, verifies the result and prints the burn command
  (`USBImager.cmd -Burn -Image clean.img -Disk <N>`).
- `-FixImageUsbShift -Image file.img` fixes an existing image file without touching any disk.
- USBImager's raw burn also detects the header itself.

## Prepare & Tools — destinations, not repairs

**Format is never a repair.** Nothing in the tiers above is fixed by formatting. A format prompt on a RAW volume
(#5), an unreadable file system (#12), or a stick that drops to zero (#15) is the trap, not the cure. USBDoctor's
diagnosis never suggests a format, and its repair engine contains no format, initialize or clean code.

Some jobs really do start from an empty stick: a fresh file system, a secure wipe before passing it on, a
bootable installer. Those are **destinations the user chooses**, kept in a separate, clearly labelled area. On the
command line they have their own switches; in the window they sit on their own tab, *Prepare / Tools (not
repairs)*, with a red warning. They build a brand-new partition table from scratch. The rule "never write an MBR"
applies to repairs: a repair can't rebuild what has no backup. These tools don't repair. They replace the whole
layout, after the user has been shown what will be lost.

Every erasing tool (format, wipe, bootable maker) follows the same rules:

- **USB disks only.** The disks holding C:, D:, Windows, boot or the pagefile are refused, and so is anything not on
  the USB bus.
- **Not on a dying drive.** Dying-media signatures refuse it: image what you can. It is also refused on a stick
  the capacity test recorded as counterfeit (#13), because data would land on flash that isn't there, and on a
  read-only drive (#8).
- **Plan first.** The preview says what will be erased, whether the stick holds files, and whether a Rescue image
  exists. If it holds files and has no image, a Rescue copy is offered before anything else.
- **Typed `ERASE <n>`** and an identity re-check right before writing.

| Tool | USBDoctor switch | Notes |
|---|---|---|
| Format / prepare | `-Format -Disk N [-FileSystem exFAT\|NTFS\|FAT32] [-Label X] [-Letter Y] [-PartitionStyle Auto\|MBR\|GPT]` | New MBR (default for removable sticks, GPT above 2 TB) or GPT table, one full-size partition aligned at 1 MiB. FAT32 above 32 GB is refused with a clear message (use exFAT/NTFS, or `-SizeMB 32000`). |
| Wipe | `-Wipe -Disk N [-Passes Zero\|Random]` | One pass over every byte, with progress and a verify sample. **Wear leveling:** flash controllers retire and remap blocks, and old data in retired blocks can survive any overwrite. A wipe is not guaranteed erasure: encrypt from the start, or destroy the stick physically if it held sensitive data unencrypted. |
| Bootable maker | `-MakeBootable -Iso file -Disk N [-Mode Auto\|Windows\|Raw] [-Sha256 hex]` | Hybrid ISOs (most Linux installers) are written raw, like `dd`, and verified by read-back. Windows installers get an active FAT32 partition with `install.wim` split into `.swm` parts by DISM when it exceeds 4 GB. NTFS is optional; it boots legacy BIOS only, because no UEFI:NTFS helper is added. The SHA-256 is checked before anything is written. |
| Benchmark | `-Benchmark -Letter X` / `-Benchmark -ReadOnly -Disk N` | Unbuffered sequential and 4 KiB random reads and writes on a temp file, data verified, temp file deleted. `-ReadOnly` uses raw reads only. Results are kept per stick, and a slowdown of more than 30% against earlier runs is flagged, which is an early sign of wearing flash (#14/#15). Not run on dying drives. |
| Recover from an image | `-Recover -Image file.img [-OutDir dir] [-Carve]` | The #12 path: works on the Rescue image only, attached read-only, and **never writes to the source stick**. Copies readable files. `-Carve` hands the image to PhotoRec (TestDisk suite) if it is installed; USBDoctor never downloads it and points to https://www.cgsecurity.org/wiki/TestDisk_Download instead. |
| Health watch | `-Watch Install\|Uninstall\|Status\|Run [-DryRun]` | A non-elevated scheduled task (at logon and every 30 minutes) that logs read errors, drop-outs and capacity changes into the history and notifies when they rise or a verdict changes. This catches #14/#15 early. |
| Port map | `-PortMap`, `-LabelPort name -Disk N` | Tree of host controllers, hubs, ports and devices, with errors and drops per port from the history. It supports Tier 0: the same stick failing on one port only points at the connection. |

**Tool coverage:** USBDoctor, Prepare & Tools (`USBDoctor.Tools.psm1`), separate from the repair engine.
DiskPilot's `format` and USBImager's burn remain the other deliberate rebuild paths.

## Refusal list — the tool says no, and says why

- Any write repair on a drive that disconnects during read-only diagnosis.
- chkdsk or boot-sector repair on a drive whose raw first-sector read times out.
- Capacity "repair" on a counterfeit (there is nothing to repair; the capacity was never there).
- Clearing read-only a second time after it returned on replug.
- Formatting anything as a "repair". Format is a destination the user chooses (DiskPilot proper, a USBImager
  burn, or USBDoctor's separate Prepare & Tools area), never a fix the repair tool proposes.
- Writing an MBR as a repair. An MBR has no backup to restore from; DiskPilot treats MBR disks as display-only and USBDoctor
  inherits that rule. (The one MBR-area change allowed is #4: bringing a signature-collided disk online lets
  Windows rewrite the 4-byte disk signature, and USBDoctor discloses that first.)

**Tool coverage:** USBDoctor enforces all six:

- `Assert-WriteGate` refuses every writing repair on a drive with a dying signature.
- It also refuses chkdsk and boot-sector repair after a failed timed raw read, `-Extend` on a recorded counterfeit,
  and a second `-ClearReadOnly`.
- No format, initialize or clean code exists in USBDoctor's repair engine (`USBDoctor.Core.psm1`). The GPT restore
  never touches sector 0. Format, wipe and the bootable maker live only in Prepare & Tools (see above), behind
  `ERASE <n>`, and are refused on dying, counterfeit and system disks.

## Output format per diagnosis

State (what was found) → Fault owner (drive / connection / machine / permissions) → Safe action or refusal → If
refused, what would have to change (a second-machine result, a completed image).

**Tool coverage:** USBDoctor prints exactly this for every drive as `STATE`, `FAULT OWNER`, `SAFE ACTION` /
`REFUSED`, and `TO CHANGE`, in the console, the window and the TXT/HTML report. It adds a Tier 0 prompt while the
verdict is provisional.
