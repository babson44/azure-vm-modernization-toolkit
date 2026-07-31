#requires -Version 7.0
<#
    bootstrap.ps1  -  one-line entry point for Azure Cloud Shell.

    Usage (paste into Cloud Shell > PowerShell):
        iwr https://raw.githubusercontent.com/babson44/azure-vm-modernization-toolkit/main/bootstrap.ps1 | iex

    It downloads this toolkit to your home folder, runs the READ-ONLY assess + plan
    across every subscription you can read in one shot, and writes a combined report
    (Assessment + Wave plan tabs) into ./reports in your current Cloud Shell directory.
    It changes nothing in Azure.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo   = 'https://github.com/babson44/azure-vm-modernization-toolkit'
$branch = 'main'
# Keep the toolkit on disk (in your home folder) so the plan step is available afterwards.
$tk = Join-Path $HOME 'azure-vm-modernization-toolkit'

Write-Host ""
Write-Host "Azure VM Modernization Toolkit" -ForegroundColor Cyan
Write-Host "Read-only assessment. Nothing in your environment will be changed." -ForegroundColor DarkGray
Write-Host ""

# Get the toolkit (refresh it if it is already there).
if (Test-Path (Join-Path $tk 'scripts' 'assess.ps1')) {
    Write-Host "Toolkit already present at $tk (refreshing)..." -ForegroundColor Yellow
    if (Get-Command git -ErrorAction SilentlyContinue) { git -C $tk pull --ff-only 2>$null | Out-Null }
}
elseif (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "Downloading toolkit (git clone) to $tk ..." -ForegroundColor Yellow
    git clone --depth 1 --branch $branch "$repo.git" $tk 2>$null | Out-Null
}

if (-not (Test-Path (Join-Path $tk 'scripts' 'assess.ps1'))) {
    Write-Host "Downloading toolkit (zip) to $tk ..." -ForegroundColor Yellow
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ("vmmod-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".zip")
    Invoke-WebRequest "$repo/archive/refs/heads/$branch.zip" -OutFile $zip
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vmmod-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $inner = Get-ChildItem $tmp -Directory | Where-Object Name -like 'azure-vm-modernization-toolkit-*' | Select-Object -First 1
    if ($inner) { Move-Item $inner.FullName $tk -Force }
}

$run = Join-Path $tk 'scripts' 'run.ps1'
if (-not (Test-Path $run)) { throw "Could not locate run.ps1 after download." }

# Reports go into ./reports in your current folder, so 'download reports/...' works from here.
$localReports = Join-Path (Get-Location) 'reports'
& $run -OutputDir $localReports
