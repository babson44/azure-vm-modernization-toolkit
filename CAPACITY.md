# Capacity & Quota check (preview)

> Feature branch: `feature/capacity-quota`. This is additive and does **not** change
> the stable assess / plan / run path on `main`.

Modernization plans fail at execution for two boring reasons: the modern target size
is **not offered** in the customer's region, or the subscription has **no vCPU quota**
left in that family. This check answers both, read-only, before anyone schedules a wave.

## What it does

Runs the same read-only scan as the assessment, then for every recommended target it
asks, per subscription and per region:

1. **Availability** — is the target SKU offered to this subscription in this region?
   (Azure Compute resource SKUs + their restrictions.) Verdicts: `Available`,
   `Available (zonal limits)`, `Restricted` (not available to your subscription),
   `Not offered`.
2. **Quota** — is there enough vCPU headroom in that SKU's family to place it?
   (Azure Compute usage vs limits.) Verdicts: `OK`, `Shortfall`.

It also produces a standalone **region-by-family vCPU headroom matrix**, which answers
"what can I actually deploy here" even when nobody is modernizing.

## How to run it

```powershell
# Every region where you have a modernization candidate (zero-config):
./scripts/capacity.ps1

# A specific target region you plan to consolidate into:
./scripts/capacity.ps1 -Regions canadacentral,canadaeast

# View it rendered via the Cloud Shell "Web preview" button:
./scripts/capacity.ps1 -Serve
```

Output: an HTML report plus a CSV in `./reports`.

## The one caveat that must stay in the report

**"Available" and "quota OK" do not guarantee live datacenter capacity at deploy time.**
Regional capacity fluctuates, and constrained regions (for example Canada) are exactly
where "available on paper" and "deployable today" diverge. For those regions, confirm
the wave with the Azure capacity team before committing. The report states this up front.

## How regions are chosen

By default the tool checks exactly the regions where the customer already has
candidates (derived from the scan). Pass `-Regions` to check a deliberate target region
instead. No hard-coded region list.

## Safety

Read-only, Reader role is enough. It calls only `az vm list-skus` and `az vm list-usage`
(both read APIs) and computes verdicts locally. It never requests a quota increase or
changes anything.

## Files added by this feature

- `scripts/capacity.ps1` — entry script.
- `scripts/lib/capacity.ps1` — availability + quota read logic and HTML render.

Nothing else is modified, so merging into `main` is a low-risk, additive change.
