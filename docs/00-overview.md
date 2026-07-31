# 00 - Overview

This toolkit helps you move Azure Virtual Machines off **older series (v1-v4)** and off
**Gen1** onto **modern Gen2 series (v5 / v6 / v7)**: safely and in the right order.

## The two things that change (and why people confuse them)

There are **two independent properties** of a VM, and modernization touches both:

| Axis | What it is | Example |
|---|---|---|
| **Series version** | The `vN` suffix on the size, the CPU/hardware generation | `Standard_D8s_v4` → `Standard_D8s_v6` |
| **Azure VM generation** | **Gen1 (BIOS)** vs **Gen2 (UEFI + Trusted Launch)** | Gen1 → Gen2 |

They are **different axes**. You can be on an old series but already Gen2, or on a newer
series but still Gen1. The modern **v6/v7** sizes **require Gen2** *and* an **NVMe-capable
guest OS**. That's why a Gen1 VM can't simply be resized to v6, it has to become Gen2
first. Full explanation in **[05 - Concepts](05-concepts.md)**.

## The workflow

```
  scan  ->  assess  ->  [APPROVE]  ->  plan  ->  [APPROVE]  ->  execute (track runbooks)
  (read-only, self-serve)   human      (read-only)   human      you, in a change window
```

- **Assess** and **plan** are **read-only** and safe for anyone with **Reader** to run.
- **Execution** is done by you, following a **track runbook**, with snapshots and rollback.
- Two **human approval gates** stop automation from skipping review, see
  **[06 - Approvals](06-approvals.md)**.

## The four tracks

Every candidate VM is routed to exactly one track by the
**[decision tree](04-decision-tree.md)**:

| Track | When | What you do |
|---|---|---|
| **A - Resize** | Already Gen2, older series | In-place resize to the modern size |
| **B - Gen1→Gen2** | Gen1, OS supports Gen2/NVMe | Convert to Gen2 (Trusted Launch), then resize |
| **C - AVD image-replace** | Azure Virtual Desktop host pool | Build new modern hosts, drain the old ones |
| **D - Rebuild** | Gen1, OS too old to convert | Redeploy from a modern Gen2 image |

## Where to start

New to Azure Cloud Shell? → **[01 - Open Cloud Shell](01-open-cloud-shell.md)**
Ready to sign in and scope? → **[02 - Sign in & scope](02-sign-in-and-scope.md)**
Just want to run it? → **[03 - Run the assessment](03-run-assessment.md)**
