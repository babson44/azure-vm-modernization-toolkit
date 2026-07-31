#requires -Version 7.0
<#
    bootstrap.ps1  -  one-line entry point for Azure Cloud Shell.

    Usage (paste into Cloud Shell > PowerShell):
        iwr https://raw.githubusercontent.com/babson44/azure-vm-modernization-toolkit/main/bootstrap.ps1 | iex

    It downloads this toolkit to a temp folder, runs the READ-ONLY assessment across
    every subscription you can read, and copies the report into ./reports in your
    current Cloud Shell directory. It changes nothing in Azure.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo   = 'https://github.com/babson44/azure-vm-modernization-toolkit'
$branch = 'main'
$work   = Join-Path ([System.IO.Path]::GetTempPath()) ("vmmod-" + [guid]::NewGuid().ToString('N').Substring(0,8))

Write-Host ""
Write-Host "Azure VM Modernization Toolkit" -ForegroundColor Cyan
Write-Host "Read-only assessment. Nothing in your environment will be changed." -ForegroundColor DarkGray
Write-Host ""

New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Host "Downloading toolkit (git clone)..." -ForegroundColor Yellow
        git clone --depth 1 --branch $branch "$repo.git" $work 2>$null | Out-Null
    }
    if (-not (Test-Path (Join-Path $work 'scripts' 'assess.ps1'))) {
        Write-Host "Downloading toolkit (zip)..." -ForegroundColor Yellow
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) ("vmmod-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".zip")
        Invoke-WebRequest "$repo/archive/refs/heads/$branch.zip" -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $work -Force
        $inner = Get-ChildItem $work -Directory | Where-Object Name -like 'azure-vm-modernization-toolkit-*' | Select-Object -First 1
        if ($inner) { $work = $inner.FullName }
    }

    $assess = Join-Path $work 'scripts' 'assess.ps1'
    if (-not (Test-Path $assess)) { throw "Could not locate assess.ps1 after download." }

    $localReports = Join-Path (Get-Location) 'reports'
    & $assess -OutputDir $localReports
}
finally {
    # Best-effort cleanup of the clone; the reports were written to ./reports already.
    if (Test-Path $work -PathType Container) {
        try { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}
