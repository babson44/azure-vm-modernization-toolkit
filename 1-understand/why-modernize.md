# Why modernize?

Start here. Before any scanning or planning, this is the case for moving your VMs off
**older series (v1-v4)** and off **Gen1** onto **modern Gen2 series (v5 / v6 / v7)**.

## What you gain

- **Better price/performance.** Newer CPUs do more work per dollar. You often get the
  same or better performance at a **lower size and cost**. The assessment report includes
  a rough monthly savings hint per VM.
- **Faster storage.** Modern series attach disks over **NVMe**, which means much higher
  IOPS and throughput and lower latency than the older SCSI interface.
- **Stronger security.** Gen2 unlocks **Trusted Launch** (Secure Boot + vTPM) on a modern
  UEFI baseline. Many security standards now expect it.
- **Bigger boot disks.** UEFI/GPT removes the roughly 2 TB Gen1 boot-disk ceiling.
- **More headroom.** Modern families scale further on memory and networking, and support
  the latest accelerated-networking features.
- **Longer support runway.** You stay on hardware generations Azure keeps investing in,
  instead of families heading toward retirement.

## The risk of staying put

Staying on v1-v4 and Gen1 is not free. Older series drift toward retirement, you miss the
security baseline your auditors increasingly ask for, you keep paying more for less
compute, and the newest, best-value sizes stay out of reach because **v6/v7 require
Gen2**. The longer you wait, the larger the eventual jump.

## The honest trade-off

Modernization is a **change to a running VM**, so it carries the normal change risk: a
resize or a Gen1-to-Gen2 conversion restarts the VM, and moving to an NVMe size needs the
right guest-OS drivers. This toolkit exists to make that change **safe and ordered**:
assess everything read-only, plan the rollout in waves, snapshot before every change, and
validate each VM before moving on. Nothing here changes your environment on its own.

Next: understand what actually changes in [gen1-vs-gen2.md](gen1-vs-gen2.md), then the
supporting ideas in [key-concepts.md](key-concepts.md).
