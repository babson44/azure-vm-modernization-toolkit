# 07 – Plan & waves

Once the assessment is approved, turn it into a **wave plan** — modernizing in safe batches
instead of all at once.

## Build the plan

```powershell
./scripts/plan.ps1 -AssessmentCsv ./reports/assessment-<timestamp>.csv
```

This reads the approved CSV and writes `reports/plan-<timestamp>.csv` with a **Wave** column,
plus a console summary.

## How VMs are grouped

```
Wave 0  Pilot         Up to 2 low-risk VMs per track (prefers non-prod). Prove the runbook.
Wave 1  Non-production Everything else identified as dev/test/qa/staging/uat/sandbox/poc.
Wave 2  Production     Remaining production VMs, smallest blast radius first.
Manual review          VMs with review flags or no mapping - handled individually, NOT batched.
```

- **Non‑prod vs prod** is inferred from name / resource‑group patterns
  (`dev`, `test`, `qa`, `stg`, `stage`, `uat`, `sandbox`, `nonprod`, `poc`). Adjust by editing
  the plan CSV if your naming differs.
- **Review‑flagged** VMs (encryption, zone/av‑set pinning, specialized SKUs) are deliberately
  kept out of the automated waves. See **[04 – Decision tree](04-decision-tree.md)**.

## The golden rules of waves

1. **Pilot first.** Do Wave 0 completely — including application validation — before touching
   Wave 1. The pilot is where you find OS/NVMe surprises cheaply.
2. **One track, one runbook.** Each VM's row tells you its track; follow the matching runbook
   in `docs/tracks/`.
3. **Snapshot every VM before you change it.** Non‑negotiable. It's your rollback.
4. **Validate before proceeding.** VM must **boot** and the **app must work** before the next
   VM in the wave.
5. **Smallest blast radius first** in production — single, non‑clustered, low‑traffic VMs
   before shared/critical ones.
6. **Change window + comms** for every production wave.

## Suggested sequencing per wave

For each VM in the wave:

1. Confirm target size **availability + quota** in the VM's region (runbook shows how).
2. For v6/v7 targets, **verify guest‑OS NVMe support**.
3. **Snapshot** OS (and data) disks.
4. Follow the **track runbook** (resize / convert / rebuild / AVD replace).
5. **Start and validate** — OS boots, services up, app smoke‑tested.
6. Tick it off; move on. If anything fails, **roll back from snapshot** and move that VM to
   manual review.

## Tracks index

- [Track A – Resize](tracks/track-a-resize.md)
- [Track B – Gen1 → Gen2 then resize](tracks/track-b-gen1-to-gen2.md)
- [Track C – AVD image‑replace](tracks/track-c-avd-image-replace.md)
- [Track D – Rebuild](tracks/track-d-rebuild.md)
