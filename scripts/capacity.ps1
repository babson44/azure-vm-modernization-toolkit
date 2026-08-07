#requires -Version 7.0
<#
.SYNOPSIS
    Read-only region CAPACITY + QUOTA check for the modernization plan.

.DESCRIPTION
    Runs the same read-only scan as the assessment, then for every modern target it
    recommends it asks two questions, per subscription and per region:

        1. Is that target SKU OFFERED to this subscription in that region?
        2. Is there enough vCPU QUOTA left in the SKU's family to place it?

    It writes an HTML + CSV "Capacity & Quota" report with:
        - Recommended targets, with an Available / Restricted / Not-offered verdict and
          an OK / Shortfall quota verdict.
        - A region-by-family vCPU headroom matrix ("what can I actually deploy here").

    Regions checked default to every region where you have a modernization candidate.
    Pass -Regions to check specific target regions instead (for example a region you
    plan to consolidate into).

    IMPORTANT: "Available" + "quota OK" does NOT guarantee live datacenter capacity at
    deploy time. In constrained regions, confirm a wave with the Azure capacity team.
    This script NEVER changes anything. Minimum role: Reader.

.EXAMPLE
    ./scripts/capacity.ps1
    Check capacity in every region where you have candidates.

.EXAMPLE
    ./scripts/capacity.ps1 -Regions canadacentral,canadaeast
    Check capacity specifically in Canada Central and Canada East.

.EXAMPLE
    ./scripts/capacity.ps1 -Serve
    Same, then serve the report for the Cloud Shell "Web preview" button.
#>
[CmdletBinding()]
param(
    # Regions to check. Default: every region where you have a modernization candidate.
    [string[]] $Regions,

    [string] $OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'reports'),

    # Serve the finished report over a local web server for in-browser (Web preview) viewing.
    [switch] $Serve,

    # Port to serve on when -Serve is used.
    [int]    $Port = 8080,

    # Skip the automatic browser download of the HTML report in Cloud Shell.
    [switch] $NoDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'common.ps1')
. (Join-Path $PSScriptRoot 'lib' 'capacity.ps1')

Write-Host ""
Write-Host "Azure VM Modernization Toolkit - Capacity & Quota (read-only)" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------"

Assert-AzCli
$acct = Assert-SignedIn
Write-Host ("Signed in as: {0}" -f $acct.user.name) -ForegroundColor DarkGray
Write-Host ("Tenant:       {0}" -f $acct.tenantId) -ForegroundColor DarkGray
Write-Host ""
Write-Host "Step 1 of 3 - Scanning readable subscriptions to find candidates and regions..." -ForegroundColor Yellow

$config = Get-ToolkitConfig
$rows   = ConvertTo-Assessment -Config $config

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "No virtual machines were found in the subscriptions you can read." -ForegroundColor Yellow
    return
}

$regions = Get-CandidateRegions -Rows $rows -Regions $Regions
if (-not $regions -or $regions.Count -eq 0) {
    Write-Host "No modernization candidates were found, so there are no regions to check." -ForegroundColor Yellow
    Write-Host "Tip: pass -Regions canadacentral to check a specific region anyway." -ForegroundColor DarkGray
    return
}
Write-Host ("  Regions to check: {0}" -f ($regions -join ', ')) -ForegroundColor DarkGray

Write-Host ""
Write-Host "Step 2 of 3 - Reading SKU availability and quota per region (read-only)..." -ForegroundColor Yellow
$skuMap   = Get-RegionSkuMap  -Regions $regions
$usageMap = Get-RegionUsageMap -Regions $regions

Write-Host ""
Write-Host "Step 3 of 3 - Cross-referencing recommended targets against availability + quota..." -ForegroundColor Yellow
$targetCap = Get-TargetCapacity   -Rows $rows -SkuMap $skuMap -UsageMap $usageMap
$matrix    = Get-RegionQuotaMatrix -UsageMap $usageMap

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$htmlPath = Join-Path $OutputDir "capacity-$stamp.html"
$csvPath  = Join-Path $OutputDir "capacity-$stamp.csv"

$targetCap | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
New-CapacityHtmlReport -TargetCapacity $targetCap -QuotaMatrix $matrix -Path $htmlPath -Account $acct -Regions $regions

# Console summary
$blocked = @($targetCap | Where-Object { $_.Availability -in @('Restricted','Not offered') -or $_.Quota -eq 'Shortfall' })
Write-Host ""
Write-Host ("Checked {0} target/region combination(s) across {1} region(s)." -f @($targetCap).Count, $regions.Count) -ForegroundColor Green
if ($blocked.Count -gt 0) {
    Write-Host ("  {0} combination(s) have a capacity or quota blocker to resolve:" -f $blocked.Count) -ForegroundColor Yellow
    $blocked | ForEach-Object {
        Write-Host ("    {0} in {1}: availability={2}, quota={3}" -f $_.Target, $_.Region, $_.Availability, $_.Quota) -ForegroundColor DarkYellow
    }
} else {
    Write-Host "  No availability or quota blockers found (still confirm live capacity with the capacity team)." -ForegroundColor Green
}
Write-Host ""
Write-Host "Reports written:" -ForegroundColor Green
Write-Host ("  HTML: {0}" -f $htmlPath)
Write-Host ("  CSV:  {0}" -f $csvPath)
Write-Host ""
Write-Host "Reminder: availability + quota do NOT guarantee live datacenter capacity." -ForegroundColor Cyan
Write-Host "For constrained regions, confirm the wave with the Azure capacity team." -ForegroundColor Cyan

# Make the report effortless to open (auto-download in Cloud Shell, or -Serve to view rendered).
Show-ReportAccess -HtmlPath $htmlPath -CsvPath $csvPath -Serve:$Serve -Port $Port -NoDownload:$NoDownload
Write-Host ""
