# Changelog

All notable changes to this project are documented here.

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
