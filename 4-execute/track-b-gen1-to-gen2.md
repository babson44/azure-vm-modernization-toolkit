# Track B: Gen1 → Gen2, then resize

**When:** the VM is **Gen1**, but its **guest OS supports Gen2 + NVMe**. You convert it to
Gen2 (enabling Trusted Launch), then resize to the modern series.

**Downtime:** short, the conversion and resize each restart the VM.

> This is the **default** route for Gen1 VMs. If step 1 shows the OS **cannot** support
> Gen2/NVMe, switch this VM to **[Track D - Rebuild](track-d-rebuild.md)**.

---

## 0. Prerequisites

- **Contributor** on the VM.
- Target region + quota support the modern size (same checks as
  [Track A](track-a-resize.md), steps 1-2).
- A booked **change window**.

```powershell
$rg     = "<resource-group>"
$vm     = "<vm-name>"
$target = "<Standard_..._v6>"
```

## 1. Verify the guest OS supports Gen2 + NVMe ✅ read-only / owner check

Gen1 → Gen2 conversion requires an OS that boots under **UEFI** and (for v6/v7) has **NVMe**
drivers. Confirm the OS version is supported:

- **Windows Server 2016+** generally supports the conversion path; newer is better.
- **Linux:** a modern, UEFI-capable distro/kernel with NVMe support.

If the OS is too old to support UEFI/Gen2 or NVMe → **stop** and use
**[Track D - Rebuild](track-d-rebuild.md)** instead.

## 2. Snapshot the OS (and data) disks ⚠️ change (safe / additive)

```powershell
$osDiskId = az vm show -g $rg -n $vm --query "storageProfile.osDisk.managedDisk.id" -o tsv
az snapshot create -g $rg -n "$vm-os-premigration" --source $osDiskId
```

Snapshot data disks too. **This is your rollback.**

## 3. Validate the disk is Gen2-ready ✅ read-only

Azure provides a validation step before conversion. Deallocate, then run the Gen2 validation
/ conversion for your VM per the current Microsoft guidance
(**Trusted Launch upgrade**). Confirm the OS disk is **UEFI/GPT** capable.

```powershell
az vm deallocate -g $rg -n $vm
```

## 4. Convert Gen1 → Gen2 (Trusted Launch) ⚠️ change

Enable Trusted Launch (Secure Boot + vTPM) as part of the upgrade:

```powershell
az vm update -g $rg -n $vm --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true
```

> Follow the current Microsoft "Trusted Launch upgrade / Gen1→Gen2" runbook for your OS,
> exact steps and support boundaries evolve. The command above enables the security profile
> once the disk is Gen2-ready.

## 5. Resize to the modern series ⚠️ change (restarts the VM)

```powershell
az vm resize -g $rg -n $vm --size $target
az vm start -g $rg -n $vm
```

## 6. Validate ✅

- VM **running**; OS **boots under UEFI**.
- Confirm Trusted Launch: `az vm show -g $rg -n $vm --query "securityProfile" -o json`
- Services up and **application smoke-tested** by the owner.

## 7. Rollback (if validation fails)

Recreate the OS disk from the step-2 snapshot, attach it to a **new Gen1 VM** of the original
size, and reattach data disks. Move this VM to **manual review** and consider
**[Track D](track-d-rebuild.md)**.

## 8. Done

Record success; proceed to the next VM in the wave.
