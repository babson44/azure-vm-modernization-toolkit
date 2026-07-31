# 02 – Sign in & scope

Azure organizes resources like this:

```
Tenant (your organization)
└── Subscription(s)        <- billing + access boundary; customers usually have MANY
    └── Resource group(s)
        └── Virtual machines
```

The assessment scans **every subscription you can read** in your **current tenant**, in one
pass, using **Azure Resource Graph**. You don't have to loop through subscriptions yourself.

## What access do I need?

**Reader** on the subscriptions you want to assess. That's it.

- Reader lets the script **see** VMs and disks. It **cannot** change anything.
- If you only have Reader on *some* subscriptions, the report simply covers those.

## Check what you can see

List the subscriptions your account can access:

```powershell
az account list --query "[].{Name:name, Id:id, State:state}" --output table
```

## Multiple tenants?

If your organization uses more than one tenant, sign in to the one you want:

```powershell
az login --tenant <tenant-id-or-domain>
```

Then re‑run the assessment. Repeat per tenant if needed.

## Run it

**Cloud Shell (recommended):**

```powershell
iwr https://raw.githubusercontent.com/babson44/azure-vm-modernization-toolkit/main/bootstrap.ps1 | iex
```

**Local PowerShell 7+ (equal fallback):**

1. Install prerequisites once:
   - **PowerShell 7+** — https://aka.ms/powershell
   - **Azure CLI** — https://aka.ms/azcli
2. Sign in:
   ```powershell
   az login
   ```
3. Get the toolkit and run it:
   ```powershell
   git clone https://github.com/babson44/azure-vm-modernization-toolkit.git
   cd azure-vm-modernization-toolkit
   ./scripts/assess.ps1
   ```

Either way, the output is identical: an HTML + CSV report in `./reports`.

## "Nothing leaves your tenant"

The toolkit runs **in your session**, queries **your** Azure via **your** credentials, and
writes files to **your** Cloud Shell / machine. No data is sent anywhere else.

➡️ Next: **[03 – Run the assessment](03-run-assessment.md)**.
