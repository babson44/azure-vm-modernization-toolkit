# Approvals: the two human sign-off gates

Modernization has **two human sign-off gates**. They exist so that no one, and no automation
or Copilot flow, moves from *analysis* to *change* without a person deciding it's ready.

```
assess  ─▶  ✅ GATE 1: Approve the assessment  ─▶  plan  ─▶  ✅ GATE 2: Approve the plan  ─▶  execute
```

## Gate 1: Approve the assessment

**Before** you build a wave plan, review the assessment report with the right people and
confirm the picture is correct.

- [ ] The **candidate list** looks right (no surprise VMs, nothing critical missed).
- [ ] **Owners** are identified for each workload / resource group.
- [ ] **Review-flagged VMs** (encryption, zone/av-set pinning, specialized SKUs) have an owner
      and a decision.
- [ ] **AVD host pools** (Track C) are confirmed and their owners looped in.
- [ ] For anything targeting **v6/v7**, a plan exists to **verify NVMe OS support**.
- [ ] Target **regions/quota** will be checked before execution (the track runbooks cover this).

**Record the approval** (email, ticket, or change record). Keep the approved CSV.

## Gate 2: Approve the plan

After running `plan.ps1`, review the **wave plan** and confirm the rollout order and change
windows.

- [ ] **Wave 0 (Pilot)** VMs are genuinely low-risk / non-prod.
- [ ] **Change windows** are booked for each wave; stakeholders notified.
- [ ] **Snapshots** are part of every runbook step (they are).
- [ ] **Rollback** owner and steps are understood for each track.
- [ ] **Manual-review** VMs are handled separately, not swept into a wave.
- [ ] Success criteria are defined: *VM boots + application validated* before the next VM.

**Record the approval.** Then execute wave by wave using the
[track runbooks](../4-execute/README.md).

## Optional: enforce the gates as files

If you want the gates to be **machine-enforced** (useful when scripting or driving with
Copilot), drop a marker file after each approval and have your process check for it:

```powershell
# after Gate 1
New-Item ./reports/APPROVED_ASSESSMENT -ItemType File

# after Gate 2
New-Item ./reports/APPROVED_PLAN -ItemType File
```

You can then gate any later automation on the presence of these files, so an approval can't
be skipped by accident.

> In **Phase 1** (this release) execution is manual via the runbooks, so the gates are process
> gates. When optional execution scripts arrive in **Phase 2**, they will **require** these
> marker files before doing anything, and default to **dry-run**.
