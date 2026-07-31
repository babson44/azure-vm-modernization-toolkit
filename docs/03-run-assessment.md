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

## Getting the report onto your screen

The report lives inside Cloud Shell, so you just need a way to view it. The toolkit makes
this automatic, and you do **not** need a storage account for any of it.

**Option 1: it downloads itself (default).**
When the scan finishes in Cloud Shell, the HTML report is **automatically pushed to your
browser's downloads**. Just open the downloaded file, it renders in your browser. Done.

**Option 2: view it live in the browser (clickable, nothing to download).**
Run the assessment with `-Serve`:

```powershell
./scripts/assess.ps1 -Serve
```

Then, in the Cloud Shell toolbar, click **Web preview** and choose port **8080**. A page
opens, click the `assessment-<timestamp>.html` file to view the report rendered. Press
**Ctrl+C** in the shell when you're done to stop the preview server.

**Option 3: download it by hand.**
The scan prints ready-to-paste commands. You can also run them yourself any time:

```powershell
download ./reports/assessment-<timestamp>.html
download ./reports/assessment-<timestamp>.csv
```

**Option 4: the graphical way.**
In the Cloud Shell toolbar, click **Manage files > Download**, and paste the file path
(for example `reports/assessment-<timestamp>.html`).

> **Ephemeral session?** If you reset Cloud Shell into the "no storage" mode, your files
> disappear when the session closes, so download the report (Option 1, 3, or 4) before you
> leave. To keep reports between sessions, reopen Cloud Shell and let it **mount storage**;
> your reports then live under `~/clouddrive`.

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
