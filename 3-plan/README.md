# Stage 3 - Plan: in what order do I roll this out?

The assessment told you *what* you have and *where* each VM should go. This stage answers
the other half: **in what order, and in what batches**, so you never change the whole fleet
at once. That sequencing is the value the plan adds.

Like the assessment, the plan is **read-only**. It changes nothing.

> **Approve first.** Before you build the plan, confirm the assessment picture is correct
> with the right people. See [approvals.md](approvals.md) (Gate 1).

---

## Build the plan

```powershell
./scripts/plan.ps1 -AssessmentCsv ./reports/assessment-<timestamp>.csv
```

Replace `<timestamp>` with your real file name. `<timestamp>` is a **placeholder**, run
`ls ./reports` to see the actual name (for example `assessment-20260731-174256.csv`). The
assessment prints the exact command, with the real path filled in, when it finishes, so the
easiest path is to copy that line.

> Ran the one-liner or `run.ps1`? Then the plan was already built for you alongside the
> assessment, in the same combined report. Use this step when you want to run the plan
> separately, for example after a formal Gate 1 approval.

This reads the approved CSV and writes two artifacts to `reports/`:

- **`plan-<timestamp>.html`** - a single page with two tabs: an **Assessment** tab (every VM
  scanned) and a **Wave plan** tab (the batches below). It downloads itself in Cloud Shell,
  or add `-Serve` to view it rendered through **Web preview**, exactly like the assessment
  (see [Stage 2, Step 5](../2-assess/README.md#step-5---get-the-report-onto-your-screen)).
- **`plan-<timestamp>.csv`** - the same VMs with a **Wave** column, the authoritative,
  filterable artifact for large fleets.

A console summary of the waves is printed as well.

## How VMs are grouped

```
Wave 0  Pilot          Up to 2 low-risk VMs per track (prefers non-prod). Prove the runbook.
Wave 1  Non-production  Everything else identified as dev/test/qa/staging/uat/sandbox/poc.
Wave 2  Production      Remaining production VMs, smallest blast radius first.
Manual review           VMs with review flags or no mapping - handled individually, NOT batched.
```

- **Non-prod vs prod** is inferred from name / resource-group patterns (`dev`, `test`, `qa`,
  `stg`, `stage`, `uat`, `sandbox`, `nonprod`, `poc`). Adjust by editing the plan CSV if your
  naming differs.
- **Review-flagged** VMs (encryption, zone/av-set pinning, specialized SKUs) are deliberately
  kept out of the automated waves. See
  [how-vms-are-routed.md](../1-understand/how-vms-are-routed.md).

## The golden rules of waves

1. **Pilot first.** Do Wave 0 completely, including application validation, before touching
   Wave 1. The pilot is where you find OS/NVMe surprises cheaply.
2. **One track, one runbook.** Each VM's row tells you its track; follow the matching runbook
   in [Stage 4 - Execute](../4-execute/README.md).
3. **Snapshot every VM before you change it.** Non-negotiable. It's your rollback.
4. **Validate before proceeding.** The VM must **boot** and the **app must work** before the
   next VM in the wave.
5. **Smallest blast radius first** in production, single, non-clustered, low-traffic VMs
   before shared/critical ones.
6. **Change window + comms** for every production wave.

---

## Next

1. **Approve the plan** (Gate 2) with your stakeholders, [approvals.md](approvals.md).
2. Execute wave by wave, [Stage 4 - Execute](../4-execute/README.md).
