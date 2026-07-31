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
    [string] $OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

# Split off anything needing a human before it can be batched.
$review = @($work | Where-Object { $_.ReviewFlags -or $_.Track -eq 'REVIEW' })
$batchable = @($work | Where-Object { -not $_.ReviewFlags -and $_.Track -ne 'REVIEW' })

function Test-NonProd {
    param($vm)
    return (@($vm.Name, $vm.ResourceGroup) -join ' ') -match '(?i)dev|test|qa|stg|stage|uat|sandbox|nonprod|non-prod|poc'
}

$nonprod = @($batchable | Where-Object { Test-NonProd $_ })
$prod    = @($batchable | Where-Object { -not (Test-NonProd $_) })

# Pilot = up to 2 per track from non-prod (fallback to prod if no non-prod exists).
$pilotPool = if ($nonprod.Count -gt 0) { $nonprod } else { $prod }
$pilot = $pilotPool | Group-Object Track | ForEach-Object { $_.Group | Select-Object -First 2 }
$pilotNames = $pilot.Name

$wave1 = @($nonprod | Where-Object { $_.Name -notin $pilotNames })
$wave2 = @($prod    | Where-Object { $_.Name -notin $pilotNames } | Sort-Object Track, Location)

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

$tag = {
    param($items,$wave)
    $items | ForEach-Object { $_ | Add-Member -NotePropertyName Wave -NotePropertyValue $wave -Force -PassThru }
}
$planned = @()
$planned += (& $tag $pilot  'Wave0-Pilot')
$planned += (& $tag $wave1  'Wave1-NonProd')
$planned += (& $tag $wave2  'Wave2-Prod')
$planned += (& $tag $review 'ManualReview')
$planned | Select-Object Wave, Track, TrackName, Name, CurrentSize, Target, Series, Generation, Location, Prerequisites, ReviewFlags |
    Export-Csv -Path $planPath -NoTypeInformation -Encoding utf8

Write-Host ""
Write-Host ("Wave plan written: {0}" -f $planPath) -ForegroundColor Green
Write-Host ""
Write-Host "Next: open the matching track runbook for each wave in docs/tracks/ and" -ForegroundColor Cyan
Write-Host "execute during an approved change window, snapshotting each VM first." -ForegroundColor Cyan
Write-Host ""
