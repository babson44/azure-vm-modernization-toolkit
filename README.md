# Azure VM Modernization Toolkit

Assess your Azure Virtual Machines and get a **safe, guided plan** to modernize them
from older series (v1–v4) and **Gen1** to modern **Gen2** series (**v5 / v6 / v7**).

> **Read‑only and safe to run.** The assessment only *reads* your environment — it
> **cannot change, stop, or delete anything**. Nothing leaves your Azure tenant.

---

## What this toolkit does

1. **Scans every subscription you can read** (in one pass, using Azure Resource Graph).
2. **Applies a decision tree** to each VM to determine the right modernization **track**.
3. **Produces a report** (HTML + CSV) with, for every VM: current size, generation,
   the recommended target size, what has to happen first, and an estimated monthly
   **cost saving**.
4. **Builds a wave plan** so you can modernize in safe batches (pilot → non‑prod → prod).

It does **not** make changes. Execution runbooks are provided as **step‑by‑step guides**
(`docs/tracks/`) that you follow deliberately, during a change window, with approvals.

---

## How each VM is routed

Every VM is sent down **one** track. Full detail: **[docs/04-decision-tree.md](docs/04-decision-tree.md)**.

```mermaid
flowchart TD
    A([VM found]) --> B{Series<br/>v5, v6 or v7?}
    B -- Yes --> Z[Track NONE<br/>already modern]
    B -- No  --> C{Azure Virtual Desktop<br/>session host?}
    C -- Yes --> TC[Track C<br/>AVD image-replace]
    C -- No  --> D{Mapped to a<br/>modern target?}
    D -- No  --> RV[REVIEW<br/>manual mapping]
    D -- Yes --> E{Azure VM<br/>generation?}
    E -- Gen2 --> TA[Track A<br/>in-place resize]
    E -- Gen1 --> F{Guest OS supports<br/>Gen2 + NVMe?}
    F -- Yes --> TB[Track B<br/>convert to Gen2, then resize]
    F -- No  --> TD[Track D<br/>rebuild from image]

    classDef none fill:#e6f4ea,stroke:#107c10,color:#0b3d16;
    classDef ta   fill:#e5f1fb,stroke:#0078d4,color:#04263f;
    classDef tb   fill:#fff4e5,stroke:#d67c00,color:#5a3300;
    classDef tc   fill:#f6e9ff,stroke:#8661c5,color:#3a2258;
    classDef td   fill:#fde7e7,stroke:#d13438,color:#5a1416;
    classDef rv   fill:#fff9e0,stroke:#c9a400,color:#5a4b00;
    classDef q    fill:#f3f2f1,stroke:#8a8886,color:#1b1b1b;
    class Z none; class TA ta; class TB tb; class TC tc; class TD td; class RV rv;
    class B,C,D,E,F q;
```

🟢 **NONE** already modern &nbsp;·&nbsp; 🔵 **A** resize &nbsp;·&nbsp; 🟠 **B** Gen1→Gen2 &nbsp;·&nbsp; 🟣 **C** AVD image‑replace &nbsp;·&nbsp; 🔴 **D** rebuild &nbsp;·&nbsp; 🟡 **REVIEW** manual

---

## 60‑second start (Azure Cloud Shell — recommended)

No installation. Works in any browser. You're already signed in.

1. Open **[https://shell.azure.com](https://shell.azure.com)** and choose **PowerShell**.
2. Paste this line and press **Enter**:

   ```powershell
   iwr https://raw.githubusercontent.com/babson44/azure-vm-modernization-toolkit/main/bootstrap.ps1 | iex
   ```

3. When it finishes, open the generated report:

   ```powershell
   Get-ChildItem ./reports
   ```

That's it. New to Cloud Shell? Follow the zero‑assumptions guide:
**[docs/01-open-cloud-shell.md](docs/01-open-cloud-shell.md)**.

---

## Prefer your own machine?

You can run exactly the same thing from local **PowerShell 7+** with the **Azure CLI**.
See **[docs/02-sign-in-and-scope.md](docs/02-sign-in-and-scope.md)**.

---

## Documentation

| Doc | What it covers |
|---|---|
| [00 – Overview](docs/00-overview.md) | The whole approach at a glance |
| [01 – Open Cloud Shell](docs/01-open-cloud-shell.md) | Step‑by‑step, nothing assumed |
| [02 – Sign in & scope](docs/02-sign-in-and-scope.md) | Tenants, multiple subscriptions, required access |
| [03 – Run the assessment](docs/03-run-assessment.md) | Run it and read **every** column of the report |
| [04 – Decision tree & tracks](docs/04-decision-tree.md) | How each VM is routed to Track A/B/C/D |
| [05 – Concepts explained](docs/05-concepts.md) | Gen1 vs Gen2, BIOS/UEFI, Trusted Launch, NVMe, why upgrade |
| [06 – Approvals](docs/06-approvals.md) | The two human sign‑off gates |
| [07 – Plan & waves](docs/07-plan-and-waves.md) | Batching the rollout safely |
| [08 – FAQ & troubleshooting](docs/08-faq-troubleshooting.md) | Common questions and fixes |

**Track runbooks** (the actual how‑to for making changes):
[Track A – Resize](docs/tracks/track-a-resize.md) ·
[Track B – Gen1→Gen2](docs/tracks/track-b-gen1-to-gen2.md) ·
[Track C – AVD image‑replace](docs/tracks/track-c-avd-image-replace.md) ·
[Track D – Rebuild](docs/tracks/track-d-rebuild.md)

---

## Large environments & many subscriptions

Built for tenants with **hundreds of subscriptions and tens of thousands of VMs**:

- **One pass, all subscriptions.** Uses **Azure Resource Graph**, which queries every
  subscription your identity can read in a single call — there is no per‑subscription loop
  to babysit. Grant **Reader at the management‑group root** and the scan covers everything
  beneath it automatically.
- **Paged + throttle‑aware.** Results are fetched page‑by‑page (1,000 rows at a time) and
  each page **retries with exponential backoff** if Resource Graph throttles (HTTP 429).
  If a page can't be recovered, the scan **stops and tells you** rather than silently
  returning a partial fleet.
- **The CSV is the authoritative artifact.** The HTML report is great for a few thousand
  rows; for very large fleets, work from the **CSV** (open in Excel / Power BI, filter,
  pivot). The HTML always includes a **per‑subscription rollup** so a big tenant is
  digestible at a glance.
- **Multiple tenants?** Resource Graph is scoped to the signed‑in tenant. For each
  additional tenant, run `az login --tenant <id>` and re‑run the assessment. See
  **[docs/02-sign-in-and-scope.md](docs/02-sign-in-and-scope.md)**.

---

## What you need

- An Azure account with **Reader** on the subscriptions you want to assess.
  (Reader is enough — the assessment never writes.)
- **Azure Cloud Shell** (nothing to install) *or* local **PowerShell 7+** with **Azure CLI**.

---

## Safety & scope

- The assessment is **100% read‑only**. Required role: **Reader**.
- Making changes (resize, convert, rebuild) is done by **you**, following the track
  runbooks, with **snapshots first** and a **rollback** path documented.
- See **[DISCLAIMER.md](DISCLAIMER.md)**. Licensed under **[MIT](LICENSE)**.

---

## Roadmap

- **Phase 1 (this release):** assess + plan + guided track runbooks. *Read‑only.*
- **Phase 2 (planned):** optional gated execution scripts (dry‑run default, snapshot +
  rollback) for customers who want automation once the decision tree is proven.
