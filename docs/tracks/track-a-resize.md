# Track A — In‑place resize (Gen2, older series)

**When:** the VM is **already Gen2** but on an older series (`v1`–`v4`). You resize it in
place to the modern equivalent (e.g. `Standard_D8s_v4` → `Standard_D8s_v6`).

**Downtime:** minutes — the VM restarts during the resize.

> Do **Wave 0 (pilot)** first. Validate on one non‑prod VM before batching.

---

## 0. Prerequisites

- **Contributor** on the VM (or a custom role with `Microsoft.Compute/virtualMachines/write`).
- The VM's **region and quota** support the target size.
- If the target is **v6/v7**: the **guest OS supports NVMe** (see
  [05 – Concepts](../05-concepts.md)).
- A booked **change window** and the workload owner informed.

Set variables (fill these in):

```powershell
$rg     = "<resource-group>"
$vm     = "<vm-name>"
$target = "<Standard_..._v6>"   # from the report's "Recommended target"
```

## 1. Confirm the target is available in the region ✅ read‑only

```powershell
az vm list-skus --location (az vm show -g $rg -n $vm --query location -o tsv) `
  --size $target --query "[].name" -o tsv
```

If nothing returns, use the **fallback** from `config/sku-map.json` (usually the v5 size) or
pick another supported size.

## 2. Check quota for the target family ✅ read‑only

```powershell
az vm list-usage --location (az vm show -g $rg -n $vm --query location -o tsv) `
  --query "[?contains(localName, 'Family')].{Name:localName, Used:currentValue, Limit:limit}" -o table
```

Request an increase if the family is near its limit **before** you proceed.

## 3. (v6/v7 only) Verify NVMe OS support ✅ read‑only

Confirm the guest OS has NVMe drivers (recent Windows Server / modern Linux kernel). If in
doubt, **test on the pilot VM** — a missing driver means the VM won't boot after resize.

## 4. Snapshot the OS (and data) disks ⚠️ change (safe / additive)

```powershell
$osDiskId = az vm show -g $rg -n $vm --query "storageProfile.osDisk.managedDisk.id" -o tsv
az snapshot create -g $rg -n "$vm-os-premigration" --source $osDiskId
```

Repeat for any critical data disks. **This is your rollback.**

## 5. Resize ⚠️ change (restarts the VM)

```powershell
az vm resize -g $rg -n $vm --size $target
```

Azure stops, resizes, and restarts the VM.

## 6. Validate ✅

- VM shows **running**: `az vm get-instance-view -g $rg -n $vm --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv`
- **OS boots**, services start, and the **application is smoke‑tested** by the owner.

## 7. Rollback (only if validation fails)

Resize back to the original size:

```powershell
az vm resize -g $rg -n $vm --size "<original-size>"
```

If the disk itself is compromised, recreate the OS disk from the snapshot taken in step 4 and
reattach. Then move this VM to **manual review**.

## 8. Done

Record success, then proceed to the next VM in the wave.
