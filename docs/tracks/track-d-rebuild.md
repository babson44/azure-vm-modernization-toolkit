# Track D: Rebuild from a modern Gen2 image

**When:** the VM is **Gen1** and its **guest OS is too old** to support Gen2 / NVMe (so
Track B conversion isn't viable). You redeploy the workload onto a **new Gen2, modern-series**
VM built from a supported image, and migrate data/config across.

**Downtime:** planned, this is a rebuild, so schedule accordingly.

> This is the right call when the OS can't be converted. Trying to force a resize/convert on
> an unsupported OS just produces a VM that won't boot.

---

## 0. Prerequisites

- **Contributor** on the target resource group.
- A **supported modern image** (Gen2, modern series, NVMe-capable) for the OS you need.
- Documented **app install / config** for the workload (or an automation script).
- Target **region + quota** for the modern series, and a **maintenance window**.

```powershell
$rg     = "<resource-group>"
$oldVm  = "<old-vm-name>"
$newVm  = "<new-vm-name>"
$target = "<Standard_..._v6>"
$loc    = az vm show -g $rg -n $oldVm --query location -o tsv
```

## 1. Snapshot the old VM's disks ✅ / ⚠️ additive

```powershell
$osDiskId = az vm show -g $rg -n $oldVm --query "storageProfile.osDisk.managedDisk.id" -o tsv
az snapshot create -g $rg -n "$oldVm-os-premigration" --source $osDiskId
```

Snapshot data disks too, you may **re-attach** them to the new VM rather than copying data.

## 2. Build the new Gen2 VM ⚠️ change (additive)

Create a fresh VM from a **modern Gen2** image (Trusted Launch on):

```powershell
az vm create -g $rg -n $newVm --location $loc --size $target `
  --image "<publisher:offer:sku:version>" `
  --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true `
  --admin-username "<user>" --generate-ssh-keys   # (Windows: use --admin-password)
```

Confirm it **boots** and NVMe works before migrating anything.

## 3. Migrate data & configuration ⚠️ change

Choose the approach that fits the workload:

- **Re-attach data disks** from the old VM (fastest when data lives on separate managed
  disks): detach from old, attach to new.
- **Copy data** from a snapshot / backup into the new VM.
- **Reinstall the app** and restore config from your documented steps or automation.

## 4. Validate ✅

- New VM **running** on Gen2 + modern series.
- OS boots, services start, **application smoke-tested** by the owner.
- Networking (NSGs, load balancer, DNS, private endpoints) points at the new VM.

## 5. Cutover ⚠️ change

- Repoint DNS / load balancer / dependencies to the **new VM**.
- **Stop (deallocate)** the old VM but **keep it** for a rollback window.

## 6. Rollback (if needed)

- Repoint traffic back to the **old VM** and start it. Because it was only deallocated (not
  deleted), rollback is quick.

## 7. Retire the old VM ⚠️ change (after confidence window)

- Once validated and past the rollback window, delete the old VM and its orphaned disks.

## 8. Done

Record success; proceed to the next VM in the wave.
