#requires -Version 7.0
<#
    common.ps1  -  shared, read-only helpers for the Azure VM Modernization Toolkit.
    Nothing in here changes any Azure resource. It only reads inventory and computes
    recommendations locally.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ToolkitRoot {
    # scripts/lib/common.ps1  ->  repo root is two levels up.
    return (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
}

function Get-ToolkitConfig {
    $cfgPath = Join-Path (Get-ToolkitRoot) 'config' 'sku-map.json'
    if (-not (Test-Path $cfgPath)) {
        throw "Could not find config/sku-map.json at '$cfgPath'."
    }
    return Get-Content $cfgPath -Raw | ConvertFrom-Json
}

function Assert-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') was not found. Use Azure Cloud Shell, or install it: https://aka.ms/azcli"
    }
    # The Resource Graph extension is required. Cloud Shell usually has it; add quietly if not.
    $ext = az extension list --query "[?name=='resource-graph'].name" -o tsv 2>$null
    if (-not $ext) {
        Write-Host "  Adding the 'resource-graph' CLI extension (one-time)..." -ForegroundColor DarkGray
        az extension add -n resource-graph -y 2>$null | Out-Null
    }
}

function Assert-SignedIn {
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) {
        throw "You are not signed in. Run 'az login' first (Cloud Shell signs you in automatically)."
    }
    return $acct
}

function Invoke-InventoryQuery {
    <#
        Runs the Resource Graph inventory query across every subscription the caller can
        read, following the pagination skip-token. Returns an array of PSCustomObjects.
    #>
    param(
        [string] $KqlPath = (Join-Path $PSScriptRoot 'inventory.kql'),
        [int]    $PageSize = 1000
    )
    if (-not (Test-Path $KqlPath)) { throw "Query file not found: $KqlPath" }

    # Strip // comment lines so the query is compact for the CLI.
    $kql = (Get-Content $KqlPath | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"

    # Resource Graph queries EVERY subscription the signed-in identity can read, in one
    # call (no per-subscription loop). Large tenants come back in pages; we follow the
    # skip-token until it is empty. Throttling (429) is expected at fleet scale, so each
    # page is retried with exponential backoff. We NEVER silently return partial data:
    # if a page ultimately fails, we throw so the customer knows the scan is incomplete.
    $all  = New-Object System.Collections.Generic.List[object]
    $skip = $null
    $page = 0
    do {
        $page++
        $qargs = @('graph','query','-q', $kql, '--first', "$PageSize", '-o','json')
        if ($skip) { $qargs += @('--skip-token', $skip) }

        $attempt = 0; $maxAttempts = 5; $result = $null
        while ($true) {
            $attempt++
            $raw  = az @qargs 2>&1
            $exit = $LASTEXITCODE
            $err  = $null
            if ($exit -eq 0 -and $raw) {
                try { $result = ($raw | Out-String | ConvertFrom-Json) }
                catch { $err = "Response was not valid JSON." }
            } else {
                $err = ($raw | Out-String).Trim()
            }
            if ($result) { break }

            if ($attempt -ge $maxAttempts) {
                throw "Resource Graph query failed on page $page after $maxAttempts attempts; the scan is INCOMPLETE. Last error: $err"
            }
            $throttled = $err -match '(?i)throttl|429|TooManyRequests|rate.?limit|Quota'
            $wait = [math]::Min(60, [int][math]::Pow(2, $attempt))
            $why  = if ($throttled) { 'throttled by Resource Graph' } else { 'transient query error' }
            Write-Host ("  {0} - retry {1}/{2} in {3}s..." -f $why, $attempt, $maxAttempts, $wait) -ForegroundColor DarkYellow
            Start-Sleep -Seconds $wait
        }

        foreach ($row in $result.data) { $all.Add($row) }
        $skip = $result.skip_token
        if ($skip) { Write-Host ("  ...retrieved {0} VMs, fetching more" -f $all.Count) -ForegroundColor DarkGray }
    } while ($skip)

    return $all.ToArray()
}

function Test-IsAvdHost {
    <#
        Heuristic AVD (Azure Virtual Desktop) session-host detection. AVD host pools are
        modernized by image-replacement (Track C), not in-place resize, so we flag them.
    #>
    param([object] $Vm)

    $hay = @($Vm.resourceGroup, $Vm.name, $Vm.tags) -join ' '
    if ($hay -match '(?i)avd|wvd|session.?host|hostpool|host-pool|windowsvirtualdesktop') { return $true }
    return $false
}

function Resolve-Target {
    <#
        Given a source vmSize and the config, returns the recommended target size(s),
        prerequisites, family label and a rough savings hint.
    #>
    param(
        [string] $VmSize,
        [object] $Config
    )
    foreach ($rule in $Config.rules) {
        $m = [regex]::Match($VmSize, $rule.match)
        if ($m.Success) {
            $cpu = if ($m.Groups.Count -gt 1) { $m.Groups[1].Value } else { '' }
            return [pscustomobject]@{
                Family        = $rule.family
                TargetPreferred = ($rule.targetPreferred -replace '\{0\}', $cpu)
                TargetFallback  = if ($rule.targetFallback) { ($rule.targetFallback -replace '\{0\}', $cpu) } else { $null }
                Prerequisites = @($rule.prerequisites)
                EstSavingsPct = [double]$rule.estSavingsPct
                Note          = $rule.note
                Matched       = $true
            }
        }
    }
    return [pscustomobject]@{
        Family = 'Unmapped'; TargetPreferred = $null; TargetFallback = $null
        Prerequisites = @(); EstSavingsPct = 0
        Note = $Config.defaultTarget.note; Matched = $false
    }
}

function Get-Verdict {
    <#
        The per-VM decision tree. Returns a verdict object: Track (A/B/C/D or NONE),
        Action summary, and ReviewFlags that pull a VM aside for a human regardless.
        See docs/04-decision-tree.md.
    #>
    param(
        [object] $Vm,
        [object] $Config
    )

    $flags = New-Object System.Collections.Generic.List[string]
    if ($Vm.encryption -eq 'true') { $flags.Add('encrypted-disk') }
    if ($Vm.avSet)  { $flags.Add('availability-set-pinned') }
    if ($Vm.zone)   { $flags.Add("zone-pinned($($Vm.zone))") }
    if ($Vm.vmSize -match '(?i)^Standard_(N|H|M|DC|EC)') { $flags.Add('specialized-sku') }

    # Already modern -> nothing to do.
    if ($Vm.seriesVersion -in @('v5','v6','v7')) {
        return [pscustomobject]@{
            Track = 'NONE'; TrackName = 'Already modern'
            Action = "Already on $($Vm.seriesVersion). No modernization needed."
            Target = $null; Prerequisites = @(); ReviewFlags = $flags.ToArray()
            EstSavingsPct = 0
        }
    }

    $target = Resolve-Target -VmSize $Vm.vmSize -Config $Config

    # AVD host pool -> Track C (image replace), regardless of generation.
    if (Test-IsAvdHost -Vm $Vm) {
        return [pscustomobject]@{
            Track = 'C'; TrackName = 'AVD image-replace'
            Action = 'AVD session host. Replace with new Gen2/modern-series hosts and drain the old ones (near-zero downtime). Do NOT in-place resize.'
            Target = $target.TargetPreferred; Prerequisites = @('new-image','host-pool-drain')
            ReviewFlags = $flags.ToArray(); EstSavingsPct = $target.EstSavingsPct
        }
    }

    if (-not $target.Matched) {
        return [pscustomobject]@{
            Track = 'REVIEW'; TrackName = 'Manual review'
            Action = "No target mapping for '$($Vm.vmSize)'. Review manually."
            Target = $null; Prerequisites = @(); ReviewFlags = $flags.ToArray()
            EstSavingsPct = 0
        }
    }

    # Gen2 already -> Track A (in-place resize).
    if ($Vm.generation -eq 'Gen2') {
        return [pscustomobject]@{
            Track = 'A'; TrackName = 'In-place resize'
            Action = "Gen2 already. Resize $($Vm.vmSize) -> $($target.TargetPreferred). Check region/quota/NVMe."
            Target = $target.TargetPreferred; Prerequisites = $target.Prerequisites
            ReviewFlags = $flags.ToArray(); EstSavingsPct = $target.EstSavingsPct
        }
    }

    # Gen1 -> Track B (convert to Gen2, then resize). OS-support for Gen2+NVMe is verified
    # in the runbook; a modern OS is assumed possible here and called out as a prerequisite.
    return [pscustomobject]@{
        Track = 'B'; TrackName = 'Gen1 -> Gen2 then resize'
        Action = "Gen1. Convert to Gen2 (Trusted Launch) then resize -> $($target.TargetPreferred). If the guest OS cannot support Gen2/NVMe, use Track D (rebuild)."
        Target = $target.TargetPreferred
        Prerequisites = (@('gen2-conversion') + $target.Prerequisites)
        ReviewFlags = $flags.ToArray(); EstSavingsPct = $target.EstSavingsPct
    }
}

function ConvertTo-Assessment {
    # Runs the whole read-only pipeline and returns enriched rows.
    param([object] $Config)

    $inv = Invoke-InventoryQuery
    $rows = foreach ($vm in $inv) {
        $v = Get-Verdict -Vm $vm -Config $Config
        [pscustomobject]@{
            Name          = $vm.name
            Subscription  = $vm.subscriptionId
            ResourceGroup = $vm.resourceGroup
            Location      = $vm.location
            OsType        = $vm.osType
            CurrentSize   = $vm.vmSize
            Series        = $vm.seriesVersion
            Generation    = $vm.generation
            PowerState    = ($vm.powerState -replace 'PowerState/','')
            Track         = $v.Track
            TrackName     = $v.TrackName
            Target        = $v.Target
            Action        = $v.Action
            Prerequisites = ($v.Prerequisites -join '; ')
            ReviewFlags   = ($v.ReviewFlags -join '; ')
            EstSavingsPct = $v.EstSavingsPct
        }
    }
    return $rows
}

function New-HtmlReport {
    param(
        [object[]] $Rows,
        [string]   $Path,
        [object]   $Account
    )

    $total      = $Rows.Count
    $candidates = @($Rows | Where-Object { $_.Track -notin @('NONE') }).Count
    $modern     = @($Rows | Where-Object { $_.Track -eq 'NONE' }).Count
    $byTrack    = $Rows | Group-Object Track | Sort-Object Name
    $gen        = (Get-Date).ToString('u')

    # Weighted-average list-price saving across candidate VMs (guidance only).
    $savRows = @($Rows | Where-Object { $_.Track -notin @('NONE') -and $_.EstSavingsPct })
    $avgSav  = if ($savRows.Count) { [math]::Round(($savRows | Measure-Object EstSavingsPct -Average).Average, 0) } else { 0 }

    # Per-subscription rollup - the key view for large, many-subscription tenants.
    $subGroups = $Rows | Group-Object Subscription | Sort-Object { -(@($_.Group | Where-Object { $_.Track -notin @('NONE') }).Count) }
    $subRows = ($subGroups | ForEach-Object {
        $g = $_.Group
        $c = @($g | Where-Object { $_.Track -notin @('NONE') }).Count
        $a = @($g | Where-Object { $_.Track -eq 'A' }).Count
        $b = @($g | Where-Object { $_.Track -eq 'B' }).Count
        $tc= @($g | Where-Object { $_.Track -eq 'C' }).Count
        $d = @($g | Where-Object { $_.Track -eq 'D' }).Count
        $r = @($g | Where-Object { $_.Track -eq 'REVIEW' }).Count
        "<tr><td class='mono'>$($_.Name)</td><td>$($g.Count)</td><td><b>$c</b></td><td>$a</td><td>$b</td><td>$tc</td><td>$d</td><td>$r</td></tr>"
    }) -join "`n"

    $trackCards = ($byTrack | ForEach-Object {
        "<div class='card'><div class='big'>$($_.Count)</div><div class='lbl'>Track $($_.Name)</div></div>"
    }) -join "`n"

    $bodyRows = ($Rows | Sort-Object Track, Series, Name | ForEach-Object {
        $cls = switch ($_.Track) {
            'NONE'   { 'ok' }
            'A'      { 'ta' }
            'B'      { 'tb' }
            'C'      { 'tc' }
            'D'      { 'td' }
            default  { 'rv' }
        }
        $flags = if ($_.ReviewFlags) { "<span class='flag'>$($_.ReviewFlags)</span>" } else { '' }
        $sav   = if ($_.Track -notin @('NONE') -and $_.EstSavingsPct) { "~$($_.EstSavingsPct)%" } else { '-' }
        @"
<tr class='$cls'>
  <td>$($_.Name)</td><td>$($_.OsType)</td><td>$($_.CurrentSize)</td>
  <td>$($_.Series)</td><td>$($_.Generation)</td>
  <td><b>$($_.Track)</b> $($_.TrackName)</td>
  <td>$($_.Target)</td><td class='sav'>$sav</td><td>$($_.Prerequisites) $flags</td>
  <td>$($_.Location)</td>
</tr>
"@
    }) -join "`n"

    $html = @"
<!doctype html><html><head><meta charset='utf-8'>
<title>Azure VM Modernization Assessment</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:0;color:#1b1b1b;background:#faf9f8}
 header{background:#0078d4;color:#fff;padding:20px 32px}
 header h1{margin:0;font-size:22px} header p{margin:4px 0 0;opacity:.9;font-size:13px}
 .wrap{padding:24px 32px}
 .cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:20px}
 .card{background:#fff;border:1px solid #edebe9;border-radius:8px;padding:14px 18px;min-width:96px;text-align:center}
 .big{font-size:26px;font-weight:600} .lbl{font-size:12px;color:#605e5c}
 table{border-collapse:collapse;width:100%;background:#fff;font-size:13px}
 th,td{border:1px solid #edebe9;padding:7px 9px;text-align:left;vertical-align:top}
 th{background:#f3f2f1;position:sticky;top:0}
 tr.ok{background:#f3faf3} tr.ta{background:#f3f8ff} tr.tb{background:#fff8f0}
 tr.tc{background:#fbf3ff} tr.td{background:#fff3f3} tr.rv{background:#fffbe6}
 .flag{display:inline-block;background:#fde7e9;color:#a4262c;border-radius:4px;padding:1px 6px;margin-left:4px;font-size:11px}
 .mono{font-family:Consolas,monospace;font-size:12px} .sav{text-align:right;color:#107c10;font-weight:600}
 h2{font-size:15px;margin:22px 0 8px} .sub-table{max-width:760px}
 .note{font-size:12px;color:#605e5c;background:#f3f2f1;border-left:3px solid #0078d4;padding:8px 12px;margin:12px 0}
 .legend{font-size:12px;color:#605e5c;margin:14px 0}
 code{background:#f3f2f1;padding:1px 5px;border-radius:3px}
</style></head><body>
<header>
 <h1>Azure VM Modernization Assessment</h1>
 <p>Generated $gen &nbsp;|&nbsp; Tenant $($Account.tenantId) &nbsp;|&nbsp; Read-only, no changes were made</p>
</header>
<div class='wrap'>
 <div class='cards'>
   <div class='card'><div class='big'>$total</div><div class='lbl'>VMs scanned</div></div>
   <div class='card'><div class='big'>$candidates</div><div class='lbl'>Candidates</div></div>
   <div class='card'><div class='big'>$modern</div><div class='lbl'>Already modern</div></div>
   <div class='card'><div class='big'>~$avgSav%</div><div class='lbl'>Avg. list-price saving</div></div>
   $trackCards
 </div>
 <div class='legend'>
   <b>Tracks:</b>
   <code>A</code> in-place resize (Gen2) &middot;
   <code>B</code> Gen1&rarr;Gen2 then resize &middot;
   <code>C</code> AVD image-replace &middot;
   <code>D</code> rebuild &middot;
   <code>REVIEW</code> manual. Red chips = review flags (encryption, zone/av-set pinning, specialized SKU).
   See <code>docs/04-decision-tree.md</code>.
 </div>
 <h2>By subscription</h2>
 <table class='sub-table'>
  <thead><tr><th>Subscription ID</th><th>VMs</th><th>Candidates</th><th>A</th><th>B</th><th>C</th><th>D</th><th>Review</th></tr></thead>
  <tbody>
  $subRows
  </tbody>
 </table>
 <h2>All VMs</h2>
 <div class='note'>Est. saving is indicative list-price guidance (source series &rarr; target series), not a quote, validate against your actual pricing/reservations. For very large fleets the companion <b>CSV</b> is the authoritative, filterable artifact.</div>
 <table>
  <thead><tr>
   <th>VM</th><th>OS</th><th>Current size</th><th>Series</th><th>Gen</th>
   <th>Track</th><th>Recommended target</th><th>Est. save</th><th>Prerequisites / flags</th><th>Region</th>
  </tr></thead>
  <tbody>
  $bodyRows
  </tbody>
 </table>
</div></body></html>
"@

    $html | Out-File -FilePath $Path -Encoding utf8
}
