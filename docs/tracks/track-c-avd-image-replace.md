# Track C: AVD image-replace (Azure Virtual Desktop host pools)

**When:** the VMs are **Azure Virtual Desktop session hosts**. You do **not** resize these in
place. Instead you build **new Gen2 / modern-series hosts** from an updated image, add them to
the host pool, and **drain** users off the old hosts.

**Downtime:** near-zero for users (they reconnect to new hosts as old ones drain).

> This is how the largest, most homogeneous fleets are modernized with the least risk and the
> cleanest rollback (keep the old hosts until you're confident).

---

## Why image-replace, not resize

An AVD host pool is a set of **interchangeable** hosts built from a shared image. Replacing
them lets you:

- Roll out **Gen2 + modern series + NVMe** hosts from a validated image.
- Move users gradually with **drain mode** (no forced logoffs).
- **Roll back instantly** by re-enabling the old hosts if anything is wrong.

## 0. Prerequisites

- **Contributor** on the host pool / session-host resource group.
- Access to the **image** source (Azure Compute Gallery / custom image / marketplace image).
- Target **region + quota** for the new modern series.
- A **maintenance window** for the drain, and user comms.

## 1. Prepare a modern Gen2 image ✅ / ⚠️ additive

- Start from a **Gen2, modern-series, NVMe-capable** base image.
- Install your apps/agents, run updates, and **generalize/capture** it into an **Azure
  Compute Gallery** image version.
- Verify the image OS has **NVMe drivers** and supports **Trusted Launch**.

## 2. Add new session hosts to the pool ⚠️ change (additive)

- Deploy **new session hosts** from the modern image into the **same host pool**, sized to a
  modern series (e.g. `..._v6`).
- Confirm they register and show **Available** in the host pool.

*(Use your existing AVD deployment method, portal "Add session hosts", ARM/Bicep/Terraform,
or your provisioning pipeline. Keep host-pool settings, FSLogix, and networking identical.)*

## 3. Drain the old hosts ⚠️ change (no data loss)

- Put the **old Gen1 hosts** into **drain mode** (stop accepting new sessions).
- Let existing sessions finish, or notify users to sign out and back in during the window.
- Users reconnect and land on the **new modern hosts**.

## 4. Validate ✅

- New hosts show **Available** and are taking sessions.
- Launch published apps/desktops; confirm **FSLogix profiles**, printers, and performance.
- Watch for **NVMe / driver** issues on the new hosts (should be none if the image was
  validated).

## 5. Retire the old hosts ⚠️ change (after confidence window)

- Once all users are on new hosts and validated, **remove** the old hosts from the pool and
  deallocate/delete them.
- **Keep them (deallocated) for a rollback window** before deleting.

## 6. Rollback (if needed)

- Take the **new** hosts out of the pool (or drain them) and **re-enable** the old hosts.
- Because you never modified the old hosts, rollback is immediate.

## 7. Done

Record the pool as modernized. Repeat per host pool.
