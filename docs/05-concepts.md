# 05 - Concepts explained

This page explains the ideas behind VM modernization in plain language, and **why each one
matters** for your migration. If you read only one doc, read this one.

---

## Series version vs. Azure VM generation

These are the **two different axes** mentioned in the overview. Keep them straight:

- **Series version** = the `vN` suffix on a size (`Standard_D8s_v4` → the "`v4`"). It's the
  **CPU / hardware generation** of the physical host. Newer = faster CPUs, better price/perf,
  more memory bandwidth, newer storage.
- **Azure VM generation** = **Gen1** or **Gen2**. This is about how the VM **boots** and what
  platform security features it can use. It is *not* the same thing as the series version.

> **Why it matters:** the modern **v6/v7** sizes are **Gen2-only** and use **NVMe** storage.
> So "upgrade the series" and "move to Gen2" are often the *same project* for an older VM,
> you can't land on v6 while staying Gen1.

*(Technical note: the raw Azure API field that stores this is literally named
`hyperVGeneration`, because Azure's hosts run on Hyper-V. Everywhere else we just say
"Azure VM generation (Gen1/Gen2)". Azure VMs top out at **Gen2**; there is no "Gen3".)*

---

## Gen1 vs Gen2

| | **Gen1** | **Gen2** |
|---|---|---|
| Firmware / boot | **BIOS** | **UEFI** |
| Partition style | MBR | GPT |
| Max OS disk boot size | ~2 TB | > 2 TB |
| Trusted Launch (Secure Boot + vTPM) | ❌ | ✅ |
| Required for v6/v7 | ❌ | ✅ |

**Why it matters:** Gen2 is the modern baseline. It unlocks Trusted Launch (below), larger
boot disks, and, crucially, is a **hard prerequisite** for the newest, best price/perf VM
series. Staying on Gen1 puts a ceiling on how modern you can go.

---

## BIOS boot (Gen1)

**BIOS** (Basic Input/Output System) is the legacy firmware that starts a Gen1 VM. It uses
the **MBR** partition scheme.

- **What it means:** older, simpler boot process; boot disk effectively capped around **2 TB**;
  no firmware-level secure boot.
- **Why it matters:** BIOS/MBR is the thing you're **leaving behind**. Its 2 TB boot limit and
  lack of modern security features are exactly why Gen1 → Gen2 exists.

---

## UEFI boot (Gen2)

**UEFI** (Unified Extensible Firmware Interface) is the modern replacement for BIOS. It uses
the **GPT** partition scheme.

- **What it means:** boot disks **larger than 2 TB**, faster/more capable boot, and it's the
  foundation that **Secure Boot** and **vTPM** build on.
- **Why it matters:** UEFI is what makes a VM "Gen2". Everything modern, Trusted Launch, the
  latest series, assumes UEFI. This is the boot mode your modernized VMs will run on.

---

## Trusted Launch (Secure Boot + vTPM)

**Trusted Launch** is a Gen2 security capability with two main parts:

- **Secure Boot**: the firmware only loads boot components signed by trusted keys, blocking
  boot-level malware (rootkits/bootkits).
- **vTPM**: a virtual Trusted Platform Module that stores keys/measurements and enables
  **boot integrity / attestation** (proof the VM booted a known-good chain).

- **Why it matters:** it's a major, largely **free security upgrade** you get by moving to
  Gen2. Many security baselines now **expect** Trusted Launch. Some newer series enable it by
  default. Note: enabling it needs a **Gen2 VM with a supported OS**, which is why it appears
  as a prerequisite on Gen1 tracks.

---

## NVMe disk attach (v6/v7)

Newer series (v6/v7) attach their disks over **NVMe** instead of the older SCSI interface.

- **What it means:** dramatically **higher IOPS and throughput** and lower latency, a big
  part of the performance gain in modern series.
- **Why it matters (the #1 gotcha):** the **guest OS must have NVMe drivers**, or the VM
  **will not boot** after moving to a v6/v7 size. Recent Windows Server and modern Linux
  kernels include them; older/unpatched OSes may not. **Always** verify OS NVMe support (and
  test on one VM) before resizing to v6/v7. This is why `nvme-os-check` shows up as a
  prerequisite throughout the toolkit.

---

## Why upgrade at all? (the benefits)

Moving from v1-v4 / Gen1 to modern Gen2 v5-v7 gives you:

- **Better price/performance**: newer CPUs do more work per dollar; you often get the same or
  better performance at a **lower size / cost**. (The report includes a rough savings hint.)
- **Faster storage**: NVMe means much higher IOPS/throughput for the same disk.
- **Stronger security**: Trusted Launch (Secure Boot + vTPM) and a modern UEFI baseline.
- **Bigger boot disks**: UEFI/GPT removes the ~2 TB Gen1 boot-disk ceiling.
- **More memory & networking headroom**: modern families scale further and support the latest
  accelerated-networking features.
- **Longer support runway**: you stay on hardware generations Azure will keep investing in,
  rather than families heading toward retirement.

➡️ Ready to route your VMs? See **[04 - Decision tree](04-decision-tree.md)**. Ready to plan
the rollout? See **[07 - Plan & waves](07-plan-and-waves.md)**.
