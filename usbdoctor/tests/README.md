# USBDoctor tests

These tests only change virtual disks (VHD files). Real drives are read-only: section A only reads them and checks that USBDoctor refuses to change system disks or a stick that holds data.

## Harness (`harness/`)

| File | What it does |
|---|---|
| `run-tests.ps1` | The full elevated test, sections A to G (about 1 hour). Creates and removes its own VHDs and cleans up MountedDevices entries afterwards. |
| `run-recovery.ps1` | Elevated recovery-only run (G34 to G38, including G36b and G36c), about 2 to 5 minutes. |
| `launch.ps1`, `launch-recovery.ps1` | Launchers used with `Start-Process powershell -Verb RunAs`. They write a launcher error file if the run fails to start. |
| `mock-overlay.ps1` | Non-elevated mock test of the recovery overlay logic (no disks touched). |
| `unit-nonadmin.ps1` | Non-elevated unit checks. |

The harness expects the test folder `C:\ProgramData\USBDoctor\test` and the app folder set in the script; adjust the paths for your machine. Machine names, user names, share paths and volume labels in the harness and logs were replaced with placeholders (TESTPC, testuser, \\FILESERVER\Share, USBDATA).

## Logs (`logs/2026-11-14/`), USBDoctor 0.3.0 on Windows 11 (build 26300), PowerShell 5.1

| Run | Result | Files |
|---|---|---|
| Full elevated run (5th), 13:28 to 14:30 ET | 110 pass, 2 fail (G36/G37 recovery), E4/E5 skipped | `results.txt`, `test.log`, `transcript.txt` |
| Recovery-only retest after the fixes, 14:55 to 14:59 ET | 7 pass, 0 fail | `results-recovery.txt`, `test-recovery.log`, `transcript-recovery.txt` |

The two recovery failures in the full run had three causes, all fixed in 0.3.0 and confirmed by the recovery-only retest:

1. An NTFS image taken while the volume was mounted, or from a stick pulled without Safely Remove, needs a journal replay and won't mount read-only (NTFS event 305, `0xC00000A2`). Recovery now reads through a temporary differencing overlay, so the image itself is never written.
2. robocopy from a volume root made the recovered folder Hidden and System. It is now made visible.
3. An array-wrapping bug in `Copy-ImageVolumes` broke the overlay path.

E4/E5 (GPT restore write) are skipped because Windows repairs a damaged primary GPT from the backup by itself when the disk is attached writable. Detection and refusal are still tested on a read-only attach.
