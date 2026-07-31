#requires -Version 7.0
<#
.SYNOPSIS
    Read-only assessment of Azure VMs for series/generation modernization.

.DESCRIPTION
    Scans every subscription you can read (Azure Resource Graph), routes each VM through
    the modernization decision tree, and writes an HTML + CSV report to ./reports.
    This script NEVER changes, stops, or deletes anything. Minimum role: Reader.

.EXAMPLE
    ./scripts/assess.ps1

.EXAMPLE
    ./scripts/assess.ps1 -OutputDir ./reports
#>
[CmdletBinding()]
param(
    [string] $OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'common.ps1')

Write-Host ""
Write-Host "Azure VM Modernization Toolkit - Assessment (read-only)" -ForegroundColor Cyan
Write-Host "-------------------------------------------------------"

Assert-AzCli
$acct = Assert-SignedIn
Write-Host ("Signed in as: {0}" -f $acct.user.name) -ForegroundColor DarkGray
Write-Host ("Tenant:       {0}" -f $acct.tenantId) -ForegroundColor DarkGray
Write-Host ""
Write-Host "Scanning all readable subscriptions via Azure Resource Graph..." -ForegroundColor Yellow

$config = Get-ToolkitConfig
$rows   = ConvertTo-Assessment -Config $config

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "No virtual machines were found in the subscriptions you can read." -ForegroundColor Yellow
    return
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath  = Join-Path $OutputDir "assessment-$stamp.csv"
$htmlPath = Join-Path $OutputDir "assessment-$stamp.html"

$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
New-HtmlReport -Rows $rows -Path $htmlPath -Account $acct

# Console summary
$total      = $rows.Count
$candidates = @($rows | Where-Object { $_.Track -notin @('NONE') }).Count
Write-Host ""
Write-Host ("Scanned {0} VMs. Modernization candidates: {1}." -f $total, $candidates) -ForegroundColor Green
$rows | Group-Object Track | Sort-Object Name | ForEach-Object {
    Write-Host ("  Track {0,-6} {1}" -f $_.Name, $_.Count)
}
Write-Host ""
Write-Host "Reports written:" -ForegroundColor Green
Write-Host ("  HTML: {0}" -f $htmlPath)
Write-Host ("  CSV:  {0}" -f $csvPath)
Write-Host ""
Write-Host "Next: review the report, then build a wave plan:" -ForegroundColor Cyan
Write-Host ("  ./scripts/plan.ps1 -AssessmentCsv `"{0}`"" -f $csvPath)
Write-Host ""
