# Gen1 vs Gen2 (and series vs generation)

This is the one idea that clears up most of the confusion. A VM has **two independent
properties**, and modernization touches both.

## Two different axes

| Axis | What it is | Example |
|---|---|---|
| **Series version** | The `vN` suffix on the size, the CPU/hardware generation of the host | `Standard_D8s_v4` → `Standard_D8s_v6` |
| **Azure VM generation** | **Gen1 (BIOS)** vs **Gen2 (UEFI + Trusted Launch)**, how the VM boots | Gen1 → Gen2 |

They are **not** the same thing. You can be on an old series but already Gen2, or on a
newer series but still Gen1.

> **Why it matters:** the modern **v6/v7** sizes are **Gen2-only** and use **NVMe**
> storage. So "upgrade the series" and "move to Gen2" are often the *same project* for an
> older VM. A Gen1 VM cannot simply be resized to v6, it has to become Gen2 first.

*(Technical note: the raw Azure API field that stores this is literally named
`hyperVGeneration`, because Azure's hosts run on Hyper-V. Everywhere else we just say
"Azure VM generation (Gen1/Gen2)". Azure VMs top out at **Gen2**; there is no "Gen3".)*

## The Gen1 vs Gen2 difference

| | **Gen1** | **Gen2** |
|---|---|---|
| Firmware / boot | **BIOS** | **UEFI** |
| Partition style | MBR | GPT |
| Max OS disk boot size | ~2 TB | > 2 TB |
| Trusted Launch (Secure Boot + vTPM) | No | Yes |
| Required for v6/v7 | No | Yes |

**Why it matters:** Gen2 is the modern baseline. It unlocks Trusted Launch, larger boot
disks, and is a **hard prerequisite** for the newest, best price/perf VM series. Staying
on Gen1 puts a ceiling on how modern you can go.

## BIOS boot (Gen1)

**BIOS** (Basic Input/Output System) is the legacy firmware that starts a Gen1 VM, using
the **MBR** partition scheme.

- **What it means:** older, simpler boot process; boot disk effectively capped around
  **2 TB**; no firmware-level secure boot.
- **Why it matters:** BIOS/MBR is the thing you're **leaving behind**. Its 2 TB boot limit
  and lack of modern security features are exactly why Gen1 → Gen2 exists.

## UEFI boot (Gen2)

**UEFI** (Unified Extensible Firmware Interface) is the modern replacement for BIOS, using
the **GPT** partition scheme.

- **What it means:** boot disks **larger than 2 TB**, faster and more capable boot, and the
  foundation that **Secure Boot** and **vTPM** build on.
- **Why it matters:** UEFI is what makes a VM "Gen2". Everything modern, Trusted Launch and
  the latest series, assumes UEFI. This is the boot mode your modernized VMs will run on.

Next: the security and storage ideas that ride on top of Gen2, in
[key-concepts.md](key-concepts.md).
