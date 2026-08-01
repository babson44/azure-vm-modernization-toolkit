#requires -Version 7.0
<#
.SYNOPSIS
    Turn an approved assessment CSV into a safe, batched wave plan (read-only).

.DESCRIPTION
    Reads an assessment CSV produced by assess.ps1 and groups the candidate VMs into
    modernization waves by track and blast radius, so you roll out in safe batches:
        Wave 0  Pilot        - a few low-risk, non-prod VMs per track
        Wave 1  Non-prod     - remaining non-production
        Wave 2  Production   - production, smallest blast radius first
    Review-flagged VMs (encryption, zone/av-set pinning, specialized SKUs) are pulled
    into a separate "Manual review" bucket. This script makes NO changes.

.EXAMPLE
    ./scripts/plan.ps1 -AssessmentCsv ./reports/assessment-20260731-101500.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AssessmentCsv,
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

if (-not (Test-Path $AssessmentCsv)) { throw "Assessment CSV not found: $AssessmentCsv" }

Write-Host ""
Write-Host "Azure VM Modernization Toolkit - Wave Plan (read-only)" -ForegroundColor Cyan
Write-Host "------------------------------------------------------"

$rows = Import-Csv $AssessmentCsv
$work = @($rows | Where-Object { $_.Track -notin @('NONE') })

if ($work.Count -eq 0) {
    Write-Host "Nothing to plan - all VMs are already modern." -ForegroundColor Green
    return
}

# Bucket the fleet into waves (shared logic, so console/CSV/HTML always agree).
$waves  = Split-VmWaves -Rows $rows
$pilot  = $waves.Pilot
$wave1  = $waves.Wave1
$wave2  = $waves.Wave2
$review = $waves.Review

function Write-Wave {
    param([string]$Title, [object[]]$Items)
    Write-Host ""
    Write-Host ("== {0}  ({1} VMs) ==" -f $Title, @($Items).Count) -ForegroundColor Yellow
    if (@($Items).Count -eq 0) { Write-Host "   (none)"; return }
    $Items | Group-Object Track | Sort-Object Name | ForEach-Object {
        Write-Host ("   Track {0}: {1}" -f $_.Name, ($_.Group.Name -join ', '))
    }
}

Write-Wave -Title 'Wave 0  Pilot (validate the runbook here first)' -Items $pilot
Write-Wave -Title 'Wave 1  Non-production'                          -Items $wave1
Write-Wave -Title 'Wave 2  Production (smallest blast radius first)' -Items $wave2

Write-Host ""
Write-Host ("== Manual review (do NOT batch - {0} VMs) ==" -f $review.Count) -ForegroundColor Red
$review | ForEach-Object {
    Write-Host ("   {0,-24} [{1}] flags: {2}" -f $_.Name, $_.Track, $_.ReviewFlags)
}

# Persist the plan as CSV with a Wave column.
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$planPath = Join-Path $OutputDir "plan-$stamp.csv"

Export-WavePlanCsv -Waves $waves -Path $planPath

# Combined, tabbed HTML: Assessment tab + Wave plan tab on one page.
$planHtml = Join-Path $OutputDir "plan-$stamp.html"
New-PlanHtmlReport -Rows $rows -Pilot $pilot -Wave1 $wave1 -Wave2 $wave2 -Review $review -Path $planHtml -Account $null

Write-Host ""
Write-Host "Wave plan written:" -ForegroundColor Green
Write-Host ("  HTML (Assessment + Plan tabs): {0}" -f $planHtml)
Write-Host ("  CSV:                           {0}" -f $planPath)
Write-Host ""
Write-Host "Next: open the matching track runbook for each wave in 4-execute/ and" -ForegroundColor Cyan
Write-Host "execute during an approved change window, snapshotting each VM first." -ForegroundColor Cyan

# Make the report effortless to open (auto-download in Cloud Shell, or -Serve to view rendered).
# Kept last because -Serve blocks while the preview server runs.
Show-ReportAccess -HtmlPath $planHtml -CsvPath $planPath -Serve:$Serve -Port $Port -NoDownload:$NoDownload
Write-Host ""
