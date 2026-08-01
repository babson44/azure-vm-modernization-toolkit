# Stage 4 - Execute: make the change safely

This is the only stage that **changes** anything, and the toolkit does **not** do it for
you. You run each change deliberately, from a **track runbook**, during an approved change
window, with a snapshot taken first. That is by design: modernization touches running VMs,
so a human stays in control.

> **Approve first.** Don't start until the plan is approved (Gate 2). See
> [../3-plan/approvals.md](../3-plan/approvals.md).

## Pick the runbook for each VM

The plan gives every VM a **track**. Open the matching runbook and follow it:

| Track | When | Runbook |
|---|---|---|
| **A - Resize** | Already Gen2, older series | [track-a-resize.md](track-a-resize.md) |
| **B - Gen1 → Gen2, then resize** | Gen1, OS supports Gen2/NVMe | [track-b-gen1-to-gen2.md](track-b-gen1-to-gen2.md) |
| **C - AVD image-replace** | Azure Virtual Desktop host pool | [track-c-avd-image-replace.md](track-c-avd-image-replace.md) |
| **D - Rebuild** | Gen1, OS too old to convert | [track-d-rebuild.md](track-d-rebuild.md) |

Not sure why a VM landed on its track? See
[how each VM is routed](../1-understand/how-vms-are-routed.md).

## The safe sequence for every VM

Whatever the track, the discipline is the same. For each VM, in wave order:

1. **Confirm target size availability + quota** in the VM's region (the runbook shows how).
2. **For v6/v7 targets, verify guest-OS NVMe support** first, this is the #1 cause of a VM
   that won't boot after a resize.
3. **Snapshot** the OS (and data) disks. This is your rollback. Non-negotiable.
4. **Follow the track runbook**, resize / convert / rebuild / AVD replace.
5. **Start and validate**, OS boots, services up, application smoke-tested.
6. **Tick it off and move on.** If anything fails, **roll back from the snapshot** and move
   that VM to manual review.

Do a full wave, including validation, before starting the next one. Prove everything on the
**Wave 0 pilot** first.

## Migration gotchas (read before you execute)

- **NVMe on v6/v7:** the guest OS must have NVMe drivers or the VM **won't boot**. Verify and
  pilot first. The single most common failure.
- **Quota:** modern families have their own vCPU quota. Check or request quota **per target
  family per region** before a wave.
- **Zones / availability sets:** the target size must exist in the specific zone, and be
  supported by the availability set.
- **Snapshots:** always snapshot before changing a VM. It's your rollback.

Stuck on something? See [help/faq-and-troubleshooting.md](../help/faq-and-troubleshooting.md).
