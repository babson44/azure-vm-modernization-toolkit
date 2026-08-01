# Stage 2 - Assess: what do I have?

This stage scans **every subscription you can read**, routes each VM through the
[decision tree](../1-understand/how-vms-are-routed.md), and produces a report telling you,
per VM: current size and generation, the recommended target, what must happen first, and an
estimated saving. It is **100% read-only**, the minimum role is **Reader**, and nothing
leaves your tenant.

There is **one thing to run** in this stage. The rest is understanding what comes back.

---

## Step 1 - Open Azure Cloud Shell (recommended)

**Azure Cloud Shell** is a terminal that runs **inside your browser**, already signed in to
your Azure account. Nothing to install.

1. Go to **https://shell.azure.com** *(or click the `>_` icon in the Azure Portal toolbar)*.
2. If asked **"Bash or PowerShell?"**, choose **PowerShell**. If it opens in Bash, type
   `pwsh` and press Enter.
3. First time only: Cloud Shell offers to create a small storage account for itself. Click
   **Create storage** (a one-time setup, a few cents/month). The toolkit itself doesn't need
   it.

You're ready when you see a prompt like `PS /home/you>`.

> Prefer your own computer? See [Run it locally](#run-it-locally) below. The output is
> identical.

## Step 2 - Confirm you're signed in

```powershell
az account show --output table
```

If you see an error, run `az login` and follow the prompt.

## Step 3 - Understand scope (multi-subscription)

Azure organizes resources like this:

```
Tenant (your organization)
└── Subscription(s)        <- billing + access boundary; customers usually have MANY
    └── Resource group(s)
        └── Virtual machines
```

The assessment scans **every subscription you can read** in your **current tenant** in one
pass, using **Azure Resource Graph**. You don't loop through subscriptions yourself.

**Access needed: Reader**, on the subscriptions you want to assess. Reader lets the script
*see* VMs and disks; it **cannot** change anything. If you only have Reader on some
subscriptions, the report simply covers those.

**Large tenants: scope once at the management group.** Don't assign Reader
subscription-by-subscription. Assign **Reader once at the management-group root** and it
inherits down to every subscription beneath it, so one run covers the whole estate. Check
your management-group tree with:

```powershell
az account management-group list --query "[].{Name:name, DisplayName:displayName}" -o table
```

See what you can currently read:

```powershell
az account list --query "[].{Name:name, Id:id, State:state}" --output table
```

**Multiple tenants?** Resource Graph is scoped to the signed-in tenant. For each additional
tenant, run `az login --tenant <tenant-id-or-domain>` and re-run the assessment.

> Resource Graph fans out across all subscriptions you can read, even thousands, and the
> toolkit pages through results and backs off if it gets throttled. You don't shard or loop
> anything yourself.

## Step 4 - Run the assessment

Paste this single line and press **Enter**:

```powershell
iwr https://raw.githubusercontent.com/babson44/azure-vm-modernization-toolkit/main/bootstrap.ps1 | iex
```

The one-liner runs the **assessment and the wave plan together** and writes a combined
report. To run **only** the assessment, clone the repo and run `assess.ps1` (see
[Run it locally](#run-it-locally)). Either way, output lands in a `reports` folder: an
**HTML** report and a **CSV**.

## Step 5 - Get the report onto your screen

The report lives inside Cloud Shell. You do **not** need a storage account for any of this.

- **It downloads itself (default).** When the scan finishes, the HTML report is
  **automatically pushed to your browser's downloads**. Open the downloaded file, it renders
  in your browser. Done.
- **View it live (nothing to download).** Add `-Serve`, then click **Web preview** in the
  Cloud Shell toolbar and choose port **8080**. Press **Ctrl+C** to stop the preview server.
- **Download by hand.** The scan prints ready-to-paste commands, for example
  `download ./reports/assessment-<timestamp>.html`.
- **The graphical way.** Cloud Shell toolbar → **Manage files → Download**, paste the path.

> **Ephemeral session?** If you reset Cloud Shell into "no storage" mode, files disappear
> when the session closes, so download the report before you leave. To keep reports between
> sessions, let Cloud Shell **mount storage**; reports then live under `~/clouddrive`.

`<timestamp>` is a **placeholder**, use the real file name the scan printed (for example
`assessment-20260731-174256.html`). `ls ./reports` shows it.

---

## Read the report: every column

The HTML report has summary cards at the top, then one row per VM.

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

**Summary cards:** VMs scanned (everything seen), Candidates (`v1`-`v4` with a track),
Already modern (`v5`+, Track NONE), and how candidates split across Track A/B/C/D.

**Colours & flags:** row colour matches the track (green = already modern, blue = A,
orange = B, purple = C, red = D, yellow = REVIEW). A **red chip** in *Prerequisites / flags*
means a **review flag** (`encrypted-disk`, `availability-set-pinned`, `zone-pinned`,
`specialized-sku`), pulled aside for a human before batching. Full meaning of every
prerequisite term is in [key-concepts.md](../1-understand/key-concepts.md) and the routing
logic is in [how-vms-are-routed.md](../1-understand/how-vms-are-routed.md).

---

## Run it locally

Same tool, same output, from your own machine.

1. Install once: **PowerShell 7+** (https://aka.ms/powershell) and **Azure CLI**
   (https://aka.ms/azcli).
2. Sign in: `az login`.
3. Get the toolkit and run it:
   ```powershell
   git clone https://github.com/babson44/azure-vm-modernization-toolkit.git
   cd azure-vm-modernization-toolkit
   ./scripts/assess.ps1          # assessment only
   # or ./scripts/run.ps1        # assessment + plan in one shot
   ```

On Windows, if the execution policy blocks the script:
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`, then run again.

---

## Next

1. **Approve the assessment** with your stakeholders,
   [Stage 3 → approvals](../3-plan/approvals.md).
2. Build the **wave plan**, [Stage 3 → plan](../3-plan/README.md).
