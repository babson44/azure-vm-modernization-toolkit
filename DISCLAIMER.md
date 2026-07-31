# Disclaimer

This toolkit is provided **as-is, without warranty of any kind**, under the terms of the
[MIT License](LICENSE). It is a community/field aid, **not an official Microsoft product**
and not supported by Microsoft Support.

## What is safe

- The **assessment** (`scripts/assess.ps1`, `scripts/plan.ps1`, and `bootstrap.ps1`) is
  **read-only**. It uses Azure Resource Graph and `az vm` **read** operations only. It
  **cannot** create, modify, resize, deallocate, or delete any resource. The minimum role
  required is **Reader**.

## What requires care

- The **track runbooks** in `docs/tracks/` describe operations that **do change your
  environment** (resize, Gen1→Gen2 conversion, rebuild, AVD host replacement). You perform
  these yourself, deliberately.
- **Always:**
  - Test on a **non-production** VM first.
  - Take a **snapshot** of OS (and data) disks **before** any change.
  - Validate the VM **boots and the application works** before moving to the next.
  - Have a **rollback** path ready (restore from snapshot).
- Recommended sizes and cost estimates are **guidance**. Validate SKU availability, quota,
  and application compatibility in **your** regions before committing.

By using this toolkit you accept that **you are responsible** for changes made to your
Azure environment.
