# OVA-Repair
OVA-Repair — Fix VMware "cannot be opened directly" &amp; OVA import errors on Windows
# OVA-Repair — Fix VMware "cannot be opened directly" & OVA import errors on Windows

> **A single Windows batch script that imports a broken OVA/OVF into VMware Workstation, repairs its VMDK, and generates a ready-to-boot `.vmx` — no wizard clicking required.**

If you have ever tried to open a `.vmdk` extracted from an OVA and hit:

```
"<disk>.vmdk" cannot be opened directly.
Open the virtual machine configuration file (.vmx) instead.
```

…or your OVA import fails in VMware Workstation with **"The OVF package is invalid and cannot be deployed"**, or 7‑Zip/`tar` complains **"Unexpected end of archive"** while extracting an `.ova` — this tool fixes all of it in one run.

<!-- SEO keywords: vmware ova cannot be opened directly, open the virtual machine configuration file vmx instead, ova vmdk cannot be opened directly vmware workstation, vmware ovf package is invalid and cannot be deployed, ova unexpected end of archive 7-zip, convert ova to vmx, import ova into vmware workstation error, vmware-vdiskmanager repair vmdk, ctf ova import vmware, hackthebox vulnhub ova vmware, debian 11 ova vmware workstation, ova to vmdk to vmx converter windows batch -->

---

## Table of contents

- [Which errors this fixes](#which-errors-this-fixes)
- [Why it happens](#why-it-happens)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Options](#options)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [License](#license)

---

## Which errors this fixes

This script is built specifically for these Windows + VMware Workstation import failures:

| Error message | Cause | This tool |
|---|---|---|
| `<disk>.vmdk cannot be opened directly. Open the virtual machine configuration file (.vmx) instead.` | You pointed VMware at a raw VMDK instead of a VM config. | Generates a valid `.vmx` around the repaired disk. |
| `The OVF package is invalid and cannot be deployed` / `Failed to open OVF descriptor` | The OVA/OVF descriptor references a disk format VMware Workstation will not import as‑is. | Rewrites the disk to a clean `monolithicSparse` VMDK. |
| `Unexpected end of archive` (7‑Zip / tar) on an `.ova` | The OVA (a tar archive) is missing its trailing zero padding. | Ignores the harmless warning and validates by checking the extracted VMDK. |
| VM boots to `Operating System not found` / disk not detected | Wrong SCSI controller or firmware for the imported disk. | Lets you pick the controller (`lsilogic`, `lsisas1068`, `pvscsi`, `nvme`) and firmware (`bios`/`efi`). |

## Why it happens

An **OVA is just a `tar` archive** containing an `.ovf` descriptor, an `.mf` manifest, and one or more `.vmdk` disks. Two things routinely break the import:

1. **Stream‑optimized / newer‑format VMDKs.** VMware Workstation often refuses to attach the disk straight out of the OVA. Running it through `vmware-vdiskmanager -r ... -t 0` re‑writes it as a plain single‑file growable disk that Workstation always accepts.
2. **A bare VMDK is not a VM.** A VMDK is only a disk. VMware needs a `.vmx` describing CPU, RAM, controller, NIC, etc. This tool writes that `.vmx` for you and points it at the repaired disk — replacing the entire *Create a New Virtual Machine → remove disk → add existing disk* dance.

## Requirements

- **Windows 10 / 11** (uses the built‑in `tar.exe`; no extra tools needed).
- **VMware Workstation** (any recent version — the tool auto‑detects it and matches `virtualHW.version` to your build).
- *(Optional)* **7‑Zip** — only used as a fallback if `tar.exe` is unavailable.

## Quick start

```bat
:: Double-click, or from a terminal:
ova-repair.bat "D:\VMs\Leaky\Leaky.ova"
```

On the **first run** it asks once for your VMware Workstation folder and caches it in `ova-repair.cfg` next to the script. Every later run reuses it automatically — no repeated prompts.

## Usage

```
ova-repair.bat [source] [options]
```

`source` is the full path to a `.ova` or `.ovf` file. If omitted, you are prompted for it.

```bat
:: Interactive
ova-repair.bat

:: Fully specified, opens the VM when done
ova-repair.bat "D:\VMs\Leaky\Leaky.ova" --ram 4096 --cpu 4 --open

:: Re-run the one-time VMware folder setup
ova-repair.bat --config
```

## Options

| Flag | Description | Default |
|---|---|---|
| `--ram <MB>` | Memory size in MB | prompt / `2048` |
| `--cpu <N>` | Number of vCPUs | prompt / `2` |
| `--guest <id>` | VMware `guestOS` id (e.g. `debian11-64`, `ubuntu-64`, `windows9-64`) | `debian11-64` |
| `--firmware <t>` | `bios` or `efi` | `bios` |
| `--controller <t>` | `lsilogic`, `lsisas1068`, `pvscsi`, or `nvme` | `lsilogic` |
| `--open` / `--no-open` | Open the VM in VMware when finished | ask |
| `--config` | Re-run VMware folder detection/setup | — |
| `--no-color` | Disable ANSI colors | — |
| `-h`, `--help` | Show help | — |
| `-v`, `--version` | Show version | — |

## How it works

```
 .ova / .ovf
     │
 [1] detect VMware + version  ──►  pick correct virtualHW.version
     │
 [2] extract  (tar built-in, 7-Zip fallback; OVF = no extract)
     │
 [3] locate the VMDK  (ignores previous *-fix.vmdk output)
     │
 [4] vmware-vdiskmanager -r <src> -t 0 <src>-fix.vmdk   (single file)
     │
 [5] write <name>-fixed.vmx  ──►  optionally open in VMware
```

The original OVA/OVF and its disk are **never modified** — the repaired disk is written alongside as `*-fix.vmdk` and the config as `*-fixed.vmx`.

### virtualHW.version mapping

The tool reads your installed VMware version and picks a compatible hardware version (undershooting is safe; overshooting triggers *"created with a newer version of VMware"*):

| VMware Workstation | `virtualHW.version` |
|---|---|
| 17.6+ | 22 |
| 17.5 | 21 |
| 17.0–17.4 | 20 |
| 16.1–16.2 | 19 |
| 16.0 | 18 |
| 15.x | 16 |
| 14.x | 14 |
| unknown | 19 (safe fallback) |

## Troubleshooting

**"Unexpected end of archive" during extraction, but it still worked.**
Expected and harmless — an OVA is a tar without trailing padding. The tool only fails if no VMDK actually appears.

**Conversion fails / disk errors.**
The OVA download is likely truncated. Compare its size against the source and re‑download.

**VM powers on but shows `Operating System not found`.**
Match the original hardware: re‑run with `--controller lsisas1068` (or `nvme`), and if the guest was UEFI, add `--firmware efi`.

**Wrong VMware folder cached.**
Run `ova-repair.bat --config` to set it again.

**Colors show as garbage (`←[0m`).**
Old console host. Run with `--no-color`.

## FAQ

**Does this modify my original OVA?** No. It only writes new `*-fix.vmdk` and `*-fixed.vmx` files next to the source.

**Do I need 7‑Zip?** No — Windows 10/11 ship `tar`, which the tool uses first. 7‑Zip is only a fallback.

**Can I use it for `.ovf` (not `.ova`)?** Yes. For an OVF the disk is already on disk next to the descriptor, so no extraction step runs.

**Is it only for Debian?** No. `debian11-64` is just the default `guestOS`; override it with `--guest` for any OS.

## License

MIT © the author. Contributions and issue reports welcome.
