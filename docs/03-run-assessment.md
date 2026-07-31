# 03 - Run the assessment & read the report

## Run it

From Cloud Shell:

```powershell
iwr https://raw.githubusercontent.com/babson44/azure-vm-modernization-toolkit/main/bootstrap.ps1 | iex
```

Or, if you cloned the repo:

```powershell
./scripts/assess.ps1
```

You'll see a live summary in the console and two files in `./reports`:
an **HTML** report (open in a browser) and a **CSV** (open in Excel).

## Reading the report: every column

The HTML report has summary cards at the top, then one row per VM. Here is what **each
column** means:

| Column | Meaning | What to do with it |
|---|---|---|
| **VM** | The virtual machine name | Identify the workload owner |
| **OS** | Windows or Linux | Drives NVMe / Trusted Launch support checks |
| **Current size** | Today's VM size, e.g. `Standard_D32as_v4` | The starting point |
| **Series** | Extracted series version (`v4`, `v5`, …) | `v1`-`v4` = candidate; `v5`+ = modern |
| **Gen** | **Azure VM generation**: `Gen1` or `Gen2` | Gen1 needs conversion before v6/v7 |
| **Track** | The recommended path: **A / B / C / D / REVIEW / NONE** | Which runbook to follow |
| **Recommended target** | Suggested modern size, e.g. `Standard_D32as_v6` | Validate availability + quota |
| **Prerequisites / flags** | What must be true first; red chips = review flags | Address before executing |
| **Region** | The VM's Azure region | Confirm the target size exists there |

### Summary cards

- **VMs scanned**: everything the query saw.
- **Candidates**: VMs on `v1`-`v4` that have a modernization track.
- **Already modern**: `v5`/`v6`/`v7`; no action (Track NONE).
- **Track A / B / C / D**: how the candidates split across paths.

### Colours & flags

- Row colour matches the track (green = already modern, blue = A, orange = B, purple = C,
  red = D, yellow = REVIEW).
- A **red chip** in *Prerequisites / flags* means the VM has a **review flag**: for example
  `encrypted-disk`, `availability-set-pinned`, `zone-pinned`, or `specialized-sku`. These are
  pulled aside for a human before any batching. See **[04 - Decision tree](04-decision-tree.md)**.

## Common prerequisite terms you'll see

- **`gen2` / `gen2-conversion`**: VM is Gen1 and must be converted to Gen2 first.
- **`nvme-os-check`**: target is v6/v7 (NVMe); confirm the guest OS has NVMe drivers, or it
  won't boot. *This is the #1 gotcha.*
- **`premium-disk-check`**: target needs managed/premium-capable disks.

Full meaning of each is in **[05 - Concepts](05-concepts.md)**.

## After you've reviewed it

1. **Approve the assessment** with your stakeholders, see
   **[06 - Approvals](06-approvals.md)**.
2. Build the **wave plan**:
   ```powershell
   ./scripts/plan.ps1 -AssessmentCsv ./reports/assessment-<timestamp>.csv
   ```
   See **[07 - Plan & waves](07-plan-and-waves.md)**.
