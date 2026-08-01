# Key concepts

The supporting ideas behind modernization, and **why each one matters** for your
migration. If you read only one page in this section, read this one.

## Trusted Launch (Secure Boot + vTPM)

**Trusted Launch** is a Gen2 security capability with two main parts:

- **Secure Boot:** the firmware only loads boot components signed by trusted keys, blocking
  boot-level malware (rootkits and bootkits).
- **vTPM:** a virtual Trusted Platform Module that stores keys and measurements and enables
  **boot integrity / attestation** (proof the VM booted a known-good chain).

**Why it matters:** it's a major, largely **free security upgrade** you get by moving to
Gen2. Many security baselines now **expect** Trusted Launch, and some newer series enable
it by default. Enabling it needs a **Gen2 VM with a supported OS**, which is why it shows
up as a prerequisite on the Gen1 tracks.

## NVMe disk attach (v6/v7)

Newer series (v6/v7) attach their disks over **NVMe** instead of the older SCSI interface.

- **What it means:** dramatically **higher IOPS and throughput** and lower latency, a big
  part of the performance gain in modern series.
- **Why it matters (the #1 gotcha):** the **guest OS must have NVMe drivers**, or the VM
  **will not boot** after moving to a v6/v7 size. Recent Windows Server and modern Linux
  kernels include them; older or unpatched OSes may not. **Always** verify OS NVMe support
  (and test on one VM) before resizing to v6/v7.

## Prerequisite terms you'll see in the report

The assessment tags each candidate with prerequisites. The common ones:

- **`gen2` / `gen2-conversion`:** the VM is Gen1 and must be converted to Gen2 first.
- **`nvme-os-check`:** the target is v6/v7 (NVMe); confirm the guest OS has NVMe drivers or
  it won't boot. This is the single most common failure.
- **`premium-disk-check`:** the target needs managed / premium-capable disks.

## How these connect

Moving a VM to a modern size can mean three things stacked together: **UEFI/Gen2** boot,
**Trusted Launch** security, and **NVMe** storage. That's why an old Gen1 VM heading to v6
isn't a one-click resize, it's a short sequence the [decision tree](how-vms-are-routed.md)
lays out and the [track runbooks](../4-execute/README.md) walk you through safely.
