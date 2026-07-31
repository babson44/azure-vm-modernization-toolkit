# 08 – FAQ & troubleshooting

## General

**Is this safe to run? Will it change anything?**
No. `bootstrap.ps1`, `assess.ps1` and `plan.ps1` are **read‑only** — Resource Graph queries
and `az` read calls only. The minimum role is **Reader**. Making changes is done by *you*,
following the track runbooks.

**Does my data leave my environment?**
No. Everything runs in your Cloud Shell / machine, using your credentials, and writes files
locally. Nothing is sent anywhere.

**Do I need a GitHub Copilot license?**
No. Copilot is an optional accelerator. The toolkit runs entirely with Cloud Shell (or local
PowerShell) + Azure CLI.

## Running it

**`az: command not found`**
Use **Azure Cloud Shell** (it's pre‑installed), or install the Azure CLI locally:
https://aka.ms/azcli

**`You are not signed in` / no subscriptions listed**
Run `az login` (Cloud Shell usually signs you in automatically). Check what you can see with
`az account list -o table`. You need **Reader** on the subscriptions you want to assess.

**The `resource-graph` extension error**
The script adds it automatically. To do it manually:
`az extension add -n resource-graph`.

**PowerShell won't run the script (execution policy) — local Windows**
Start PowerShell 7 and run:
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` then run the script again. (Cloud
Shell is unaffected.)

**The report is empty / fewer VMs than expected**
The assessment only sees subscriptions where you have **Reader**. Confirm your access, and
check whether the VMs live in a **different tenant** (`az login --tenant <id>` and re‑run).

## Understanding results

**A VM shows Track B but its OS is old — will conversion work?**
Track B is the **default** for Gen1. The runbook has you **verify Gen2 + NVMe OS support
first**. If the OS can't support it, switch that VM to **Track D (rebuild)**.

**Why is my whole AVD pool one track (C) and not resized in place?**
AVD host pools are modernized by **image replacement** (new hosts, drain old) for near‑zero
user impact and clean rollback. See **[04 – Decision tree](04-decision-tree.md)**.

**A VM has a red flag chip. What now?**
It has a **review flag** (encrypted disk, zone/availability‑set pinning, or a specialized
SKU). Handle it individually — don't sweep it into a wave. Details in
**[04 – Decision tree](04-decision-tree.md)**.

**The recommended target isn't available in my region.**
Use the **fallback** in `config/sku-map.json` (usually the v5 equivalent), or pick another
supported size. Always confirm availability + quota in the VM's region/zone before executing.

## Migration gotchas (read before you execute)

- **NVMe on v6/v7:** the guest OS must have NVMe drivers or the VM **won't boot**. Verify and
  pilot first. This is the single most common failure.
- **Quota:** modern families have their own vCPU quota. Check/request quota **per target
  family per region** before a wave.
- **Zones / availability sets:** the target size must exist in the specific zone, and be
  supported by the availability set.
- **Snapshots:** always snapshot before changing a VM. It's your rollback.

## Contributing / questions

Open an issue or PR on the repo. Improvements to the SKU map, OS‑support notes, and regional
guidance are especially welcome.
