#requires -Version 7.0
<#
.SYNOPSIS
    One command: assess every readable subscription AND build the wave plan, then
    write a single combined report. Read-only.

.DESCRIPTION
    This is the fastest path. It does exactly what assess.ps1 + plan.ps1 do, back to
    back, without you having to copy a CSV path between them:

        1. Scans every subscription you can read (Azure Resource Graph).
        2. Routes each VM through the modernization decision tree.
        3. Groups the candidates into safe rollout waves (pilot, non-prod, prod).
        4. Checks target SKU availability + vCPU quota in the regions you use today.
        5. Writes ONE HTML report with three tabs (Assessment + Wave plan + Capacity)
           plus CSVs.

    It NEVER changes, stops, or deletes anything. Minimum role: Reader. The sign-off
    that matters happens later, before you run a track runbook to make real changes.

.EXAMPLE
    ./scripts/run.ps1
    Scan, plan, capacity-check, and auto-open the combined report.

.EXAMPLE
    ./scripts/run.ps1 -Serve
    Same, then serve the report so you can open it, fully rendered, from the
    Cloud Shell "Web preview" button.

.EXAMPLE
    ./scripts/run.ps1 -SkipCapacity
    Assess + plan only (faster; skips the per-region availability/quota reads).
#>
[CmdletBinding()]
param(
    [string] $OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'reports'),

    # Serve the finished report over a local web server for in-browser (Web preview) viewing.
    [switch] $Serve,

    # Port to serve on when -Serve is used.
    [int]    $Port = 8080,

    # Skip the automatic browser download of the HTML report in Cloud Shell.
    [switch] $NoDownload,

    # Skip the capacity + quota tab (faster; avoids per-region availability/quota reads).
    [switch] $SkipCapacity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'common.ps1')
. (Join-Path $PSScriptRoot 'lib' 'capacity.ps1')

Write-Host ""
Write-Host "Azure VM Modernization Toolkit - Assess + Plan + Capacity (read-only)" -ForegroundColor Cyan
Write-Host "---------------------------------------------------------------------"

Assert-AzCli
$acct = Assert-SignedIn
Write-Host ("Signed in as: {0}" -f $acct.user.name) -ForegroundColor DarkGray
Write-Host ("Tenant:       {0}" -f $acct.tenantId) -ForegroundColor DarkGray
Write-Host ""
Write-Host "Step 1 of 3 - Scanning all readable subscriptions via Azure Resource Graph..." -ForegroundColor Yellow

$config = Get-ToolkitConfig
$rows   = ConvertTo-Assessment -Config $config

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "No virtual machines were found in the subscriptions you can read." -ForegroundColor Yellow
    return
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$asrCsv  = Join-Path $OutputDir "assessment-$stamp.csv"
$planCsv = Join-Path $OutputDir "plan-$stamp.csv"
$html    = Join-Path $OutputDir "modernization-$stamp.html"

$rows | Export-Csv -Path $asrCsv -NoTypeInformation -Encoding utf8

# Assessment summary
$total      = $rows.Count
$candidates = @($rows | Where-Object { $_.Track -notin @('NONE') }).Count
$subCount   = @($rows | Select-Object -ExpandProperty Subscription -Unique).Count
$savRows    = @($rows | Where-Object { $_.Track -notin @('NONE') -and $_.EstSavingsPct })
$avgSav     = if ($savRows.Count) { [math]::Round(($savRows | Measure-Object EstSavingsPct -Average).Average, 0) } else { 0 }
Write-Host ""
Write-Host ("Scanned {0} VMs across {1} subscription(s). Modernization candidates: {2}." -f $total, $subCount, $candidates) -ForegroundColor Green
if ($avgSav -gt 0) {
    Write-Host ("Estimated average list-price saving on candidates: ~{0}% (guidance only)." -f $avgSav) -ForegroundColor Green
}

Write-Host ""
Write-Host "Step 2 of 3 - Grouping candidates into safe rollout waves..." -ForegroundColor Yellow

$waves = Split-VmWaves -Rows $rows
Export-WavePlanCsv -Waves $waves -Path $planCsv

Write-Host ""
Write-Host ("  Wave 0 Pilot:    {0} VMs" -f @($waves.Pilot).Count)
Write-Host ("  Wave 1 Non-prod: {0} VMs" -f @($waves.Wave1).Count)
Write-Host ("  Wave 2 Prod:     {0} VMs" -f @($waves.Wave2).Count)
Write-Host ("  Manual review:   {0} VMs" -f @($waves.Review).Count)

# Step 3: capacity + quota for the recommended targets, in the regions the VMs live in
# today (in-place modernization lands the target in the same region). Wrapped so a
# capacity read failure degrades gracefully to a note and never breaks assess + plan.
$capBody       = ''
$capCss        = ''
$targetLookup  = $null
$capCsv        = $null
if (-not $SkipCapacity) {
    Write-Host ""
    Write-Host "Step 3 of 3 - Checking target SKU availability + vCPU quota per region (read-only)..." -ForegroundColor Yellow
    try {
        $capRegions = Get-CandidateRegions -Rows $rows
        if (-not $capRegions -or $capRegions.Count -eq 0) {
            throw "No candidate regions to check."
        }
        Write-Host ("  Regions in scope: {0}" -f ($capRegions -join ', ')) -ForegroundColor DarkGray

        $skuMap    = Get-RegionSkuMap   -Regions $capRegions
        $usageMap  = Get-RegionUsageMap -Regions $capRegions
        $targetCap = Get-TargetCapacity   -Rows $rows -SkuMap $skuMap -UsageMap $usageMap
        $matrix    = Get-RegionQuotaMatrix -UsageMap $usageMap -TargetCapacity $targetCap

        $capCsv = Join-Path $OutputDir "capacity-$stamp.csv"
        $targetCap | Export-Csv -Path $capCsv -NoTypeInformation -Encoding utf8

        $capBody = Get-CapacityBodyHtml -TargetCapacity $targetCap -QuotaMatrix $matrix
        $capCss  = Get-CapacityCss

        # Per-VM lookup so the Assessment tab can show "Target available?" inline.
        # Key: "<Target>|<location-lower>" -> the matching target-capacity row.
        $capIndex = @{}
        foreach ($tc in @($targetCap)) {
            $k = "{0}|{1}" -f $tc.Target, ([string]$tc.Region).ToLower()
            if (-not $capIndex.ContainsKey($k)) { $capIndex[$k] = $tc }
        }
        $targetLookup = @{}
        foreach ($vm in @($rows | Where-Object { $_.Track -notin @('NONE') -and $_.Target })) {
            $k = "{0}|{1}" -f $vm.Target, ([string]$vm.Location).ToLower()
            if ($capIndex.ContainsKey($k)) {
                $tc = $capIndex[$k]
                $targetLookup[$vm.Name] = [pscustomobject]@{
                    Verdict      = $tc.Verdict
                    VerdictClass = $tc.VerdictClass
                }
            }
        }

        $capBlockers = @($targetCap | Where-Object { $_.VerdictClass -eq 'bad' }).Count
        if ($capBlockers -gt 0) {
            Write-Host ("  {0} target/region combination(s) have a capacity or quota blocker (see Capacity tab)." -f $capBlockers) -ForegroundColor DarkYellow
        } else {
            Write-Host "  No availability or quota blockers found (still confirm live capacity with the capacity team)." -ForegroundColor Green
        }
    }
    catch {
        Write-Host ("  Capacity check skipped: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        $msg = [string]$_.Exception.Message
        if (-not $msg) { $msg = 'the capacity read did not complete' }
        $msg = $msg.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
        $capBody = "<div class='note cap-warn'><b>Capacity data unavailable.</b> The assessment and plan above are complete and accurate. The capacity + quota check could not finish this run ($msg). Re-run, or run <span class='mono'>./scripts/capacity.ps1</span> on its own. This does not affect the assessment or plan.</div>"
        $capCss  = Get-CapacityCss
        $targetLookup = $null
    }
}

# One page: Assessment + Wave plan (+ Capacity when gathered). Real account context.
New-PlanHtmlReport -Rows $rows -Pilot $waves.Pilot -Wave1 $waves.Wave1 -Wave2 $waves.Wave2 -Review $waves.Review -Path $html -Account $acct -TargetLookup $targetLookup -CapacityBody $capBody -CapacityCss $capCss

Write-Host ""
Write-Host "Combined report written:" -ForegroundColor Green
if ($capBody -and -not $SkipCapacity) {
    Write-Host ("  HTML (Assessment + Plan + Capacity tabs): {0}" -f $html)
} else {
    Write-Host ("  HTML (Assessment + Plan tabs): {0}" -f $html)
}
Write-Host ("  Assessment CSV:                {0}" -f $asrCsv)
Write-Host ("  Plan CSV:                      {0}" -f $planCsv)
if ($capCsv) {
    Write-Host ("  Capacity CSV:                  {0}" -f $capCsv)
}
Write-Host ""
Write-Host "Next: open the matching track runbook for each wave in 4-execute/ and" -ForegroundColor Cyan
Write-Host "execute during an approved change window, snapshotting each VM first." -ForegroundColor Cyan

# Make the report effortless to open (auto-download in Cloud Shell, or -Serve to view rendered).
# Kept last because -Serve blocks while the preview server runs.
Show-ReportAccess -HtmlPath $html -CsvPath $planCsv -Serve:$Serve -Port $Port -NoDownload:$NoDownload
Write-Host ""
