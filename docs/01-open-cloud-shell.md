# 01 – Open Azure Cloud Shell

**Azure Cloud Shell** is a terminal that runs **inside your browser**, already signed in to
your Azure account. There is **nothing to install** and nothing to configure. This is the
recommended way to run the assessment.

> If you'd rather use your own computer, skip to
> **[02 – Sign in & scope](02-sign-in-and-scope.md)** (local PowerShell section).

## Step 1 — Open it

1. Open a browser and go to **https://shell.azure.com**.
   *(Or, in the Azure Portal https://portal.azure.com, click the **`>_`** icon in the top
   toolbar.)*
2. Sign in with your Azure account if prompted.

## Step 2 — Choose PowerShell

- If Cloud Shell asks **"Bash or PowerShell?"**, choose **PowerShell**.
- If it opens in Bash, type `pwsh` and press **Enter** to switch to PowerShell.
- If this is your very first time, Cloud Shell asks to create a small storage account for
  itself. Click **Create storage** — this is a one‑time setup and costs a few cents/month.
  *(This storage is for Cloud Shell itself; the toolkit doesn't need it.)*

You'll know you're ready when you see a prompt like:

```
PS /home/you>
```

## Step 3 — Confirm you're signed in

Paste this and press **Enter**:

```powershell
az account show --output table
```

You should see your account and default subscription. If you see an error, run:

```powershell
az login
```

and follow the prompt.

## Step 4 — Run the assessment

Paste this single line and press **Enter**:

```powershell
iwr https://raw.githubusercontent.com/babson44/azure-vm-modernization-toolkit/main/bootstrap.ps1 | iex
```

It will scan every subscription you can read and write a report into a `reports` folder in
your Cloud Shell home directory.

## Step 5 — Get the report

List the reports:

```powershell
Get-ChildItem ./reports
```

You'll see an `.html` and a `.csv` file. To view the HTML, download it:

1. In the Cloud Shell toolbar, click **Manage files → Download**.
2. Type the path, e.g. `reports/assessment-20260731-101500.html`.
3. Open the downloaded file in your browser.

➡️ Next: understand scope and access in
**[02 – Sign in & scope](02-sign-in-and-scope.md)**, or jump to reading the results in
**[03 – Run the assessment](03-run-assessment.md)**.
