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
        See 1-understand/how-vms-are-routed.md.
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

function Get-ReportCss {
    # Single source of truth for report styling, shared by the assessment-only page
    # and the combined assessment+plan page.
    @"
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
 .tabs{display:flex;gap:4px;border-bottom:2px solid #0078d4;padding:0 32px}
 .tab{background:#edebe9;border:1px solid #edebe9;border-bottom:none;border-radius:8px 8px 0 0;padding:9px 22px;cursor:pointer;font-size:14px;font-weight:600;color:#605e5c;user-select:none}
 .tab.active{background:#fff;color:#0078d4}
 .panel{display:none} .panel.active{display:block}
 .wave{background:#fff;border:1px solid #edebe9;border-radius:8px;margin:16px 0;overflow:hidden}
 .wave-h{padding:10px 16px;font-weight:600;font-size:14px;color:#fff}
 .w0{background:#107c10} .w1{background:#0078d4} .w2{background:#5c2d91} .wr{background:#a4262c}
 .wave .empty{padding:12px 16px;color:#605e5c;font-size:13px}
</style>
"@
}

function Get-AssessmentBodyHtml {
    # Returns the inner HTML for the assessment view (cards, per-subscription rollup,
    # full VM table). Shared by both the assessment page and the combined page.
    # When -TargetLookup is supplied (combined report only), each VM also gets a
    # "Target available?" chip linking the assessment to the capacity verdict.
    param(
        [object[]]  $Rows,
        [hashtable] $TargetLookup
    )

    $showAvail = ($null -ne $TargetLookup)

    $total      = $Rows.Count
    $candidates = @($Rows | Where-Object { $_.Track -notin @('NONE') }).Count
    $modern     = @($Rows | Where-Object { $_.Track -eq 'NONE' }).Count
    $byTrack    = $Rows | Group-Object Track | Sort-Object Name

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
        $availCell = ''
        if ($showAvail) {
            if ($TargetLookup.ContainsKey($_.Name)) {
                $tc = $TargetLookup[$_.Name]
                $availCell = "<td><span class='cap $($tc.VerdictClass)'>$($tc.Verdict)</span></td>"
            }
            else {
                $availCell = "<td><span class='cap unk'>-</span></td>"
            }
        }
        @"
<tr class='$cls'>
  <td>$($_.Name)</td><td>$($_.OsType)</td><td>$($_.CurrentSize)</td>
  <td>$($_.Series)</td><td>$($_.Generation)</td>
  <td><b>$($_.Track)</b> $($_.TrackName)</td>
  <td>$($_.Target)</td>$availCell<td class='sav'>$sav</td><td>$($_.Prerequisites) $flags</td>
  <td>$($_.Location)</td>
</tr>
"@
    }) -join "`n"

    @"
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
   See <code>1-understand/how-vms-are-routed.md</code>.
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
   <th>Track</th><th>Recommended target</th>$(if ($showAvail) { '<th>Target available?</th>' })<th>Est. save</th><th>Prerequisites / flags</th><th>Region</th>
  </tr></thead>
  <tbody>
  $bodyRows
  </tbody>
 </table>
"@
}

function New-HtmlReport {
    param(
        [object[]] $Rows,
        [string]   $Path,
        [object]   $Account
    )

    $gen    = (Get-Date).ToString('u')
    $css    = Get-ReportCss
    $body   = Get-AssessmentBodyHtml -Rows $Rows
    $tenant = if ($Account) { $Account.tenantId } else { 'n/a' }

    $html = @"
<!doctype html><html><head><meta charset='utf-8'>
<title>Azure VM Modernization Assessment</title>
$css</head><body>
<header>
 <h1>Azure VM Modernization Assessment</h1>
 <p>Generated $gen &nbsp;|&nbsp; Tenant $tenant &nbsp;|&nbsp; Read-only, no changes were made</p>
</header>
<div class='wrap'>
$body
</div></body></html>
"@

    $html | Out-File -FilePath $Path -Encoding utf8
}

function Split-VmWaves {
    # Single source of truth for wave bucketing. Takes assessment rows and returns the
    # pilot / non-prod / prod / manual-review buckets. Used by both plan.ps1 and run.ps1
    # so the console output, CSV, and HTML always agree. Makes no changes.
    param([object[]] $Rows)

    $work   = @($Rows | Where-Object { $_.Track -notin @('NONE') })
    $review = @($work | Where-Object { $_.ReviewFlags -or $_.Track -eq 'REVIEW' })
    $batch  = @($work | Where-Object { -not $_.ReviewFlags -and $_.Track -ne 'REVIEW' })

    $isNonProd = {
        param($vm)
        (@($vm.Name, $vm.ResourceGroup) -join ' ') -match '(?i)dev|test|qa|stg|stage|uat|sandbox|nonprod|non-prod|poc'
    }

    $nonprod = @($batch | Where-Object { & $isNonProd $_ })
    $prod    = @($batch | Where-Object { -not (& $isNonProd $_) })

    # Pilot = up to 2 per track from non-prod (fallback to prod if no non-prod exists).
    $pilotPool  = if ($nonprod.Count -gt 0) { $nonprod } else { $prod }
    $pilot      = @($pilotPool | Group-Object Track | ForEach-Object { $_.Group | Select-Object -First 2 })
    $pilotNames = @($pilot.Name)

    $wave1 = @($nonprod | Where-Object { $_.Name -notin $pilotNames })
    $wave2 = @($prod    | Where-Object { $_.Name -notin $pilotNames } | Sort-Object Track, Location)

    [pscustomobject]@{ Pilot = $pilot; Wave1 = $wave1; Wave2 = $wave2; Review = $review }
}

function Export-WavePlanCsv {
    # Writes the wave plan to CSV with a Wave column. Shared by plan.ps1 and run.ps1.
    param([object] $Waves, [string] $Path)

    $tag = {
        param($items, $wave)
        $items | ForEach-Object { $_ | Add-Member -NotePropertyName Wave -NotePropertyValue $wave -Force -PassThru }
    }
    $planned = @()
    $planned += (& $tag $Waves.Pilot  'Wave0-Pilot')
    $planned += (& $tag $Waves.Wave1  'Wave1-NonProd')
    $planned += (& $tag $Waves.Wave2  'Wave2-Prod')
    $planned += (& $tag $Waves.Review 'ManualReview')
    $planned | Select-Object Wave, Track, TrackName, Name, CurrentSize, Target, Series, Generation, Location, Prerequisites, ReviewFlags |
        Export-Csv -Path $Path -NoTypeInformation -Encoding utf8
}

function Get-PlanBodyHtml {
    # Returns the inner HTML for the wave-plan view: summary cards plus one styled
    # section per wave (and the manual-review bucket).
    param(
        [object[]] $Rows,
        [object[]] $Pilot,
        [object[]] $Wave1,
        [object[]] $Wave2,
        [object[]] $Review
    )

    $mkRows = {
        param($items)
        (@($items) | Sort-Object Track, Name | ForEach-Object {
            $cls = switch ($_.Track) { 'A' { 'ta' } 'B' { 'tb' } 'C' { 'tc' } 'D' { 'td' } default { 'rv' } }
            $flags = if ($_.ReviewFlags) { "<span class='flag'>$($_.ReviewFlags)</span>" } else { '' }
            "<tr class='$cls'><td>$($_.Name)</td><td><b>$($_.Track)</b> $($_.TrackName)</td><td>$($_.CurrentSize)</td><td>$($_.Target)</td><td>$($_.Series)</td><td>$($_.Generation)</td><td>$($_.Location)</td><td>$($_.Prerequisites) $flags</td></tr>"
        }) -join "`n"
    }

    $waveSection = {
        param($title, $cls, $items, $empty)
        $n = @($items).Count
        if ($n -eq 0) {
            $inner = "<div class='empty'>$empty</div>"
        }
        else {
            $inner = "<table><thead><tr><th>VM</th><th>Track</th><th>Current size</th><th>Target</th><th>Series</th><th>Gen</th><th>Region</th><th>Prerequisites / flags</th></tr></thead><tbody>$(& $mkRows $items)</tbody></table>"
        }
        "<div class='wave'><div class='wave-h $cls'>$title &nbsp;($n VMs)</div>$inner</div>"
    }

    $candidates = @($Rows | Where-Object { $_.Track -notin @('NONE') }).Count
    $w0 = @($Pilot).Count; $w1 = @($Wave1).Count; $w2 = @($Wave2).Count; $rv = @($Review).Count

    $s0 = & $waveSection 'Wave 0 - Pilot (validate the runbook here first)'    'w0' $Pilot  'No pilot VMs.'
    $s1 = & $waveSection 'Wave 1 - Non-production'                             'w1' $Wave1  'No non-production VMs to batch.'
    $s2 = & $waveSection 'Wave 2 - Production (smallest blast radius first)'    'w2' $Wave2  'No production VMs to batch.'
    $sr = & $waveSection 'Manual review - do NOT batch'                        'wr' $Review 'Nothing needs manual review.'

    @"
 <div class='cards'>
   <div class='card'><div class='big'>$candidates</div><div class='lbl'>Candidates</div></div>
   <div class='card'><div class='big'>$w0</div><div class='lbl'>Wave 0 Pilot</div></div>
   <div class='card'><div class='big'>$w1</div><div class='lbl'>Wave 1 Non-prod</div></div>
   <div class='card'><div class='big'>$w2</div><div class='lbl'>Wave 2 Prod</div></div>
   <div class='card'><div class='big'>$rv</div><div class='lbl'>Manual review</div></div>
 </div>
 <div class='note'>Roll out one wave at a time: prove the track runbook on the pilot, then non-production, then production. Snapshot every VM before you touch it and work inside an approved change window. This plan makes no changes by itself.</div>
 $s0
 $s1
 $s2
 $sr
 <div class='legend'>Next: open the matching runbook in <code>4-execute/</code> for each VM's track and execute it wave by wave. Track <code>A</code> = in-place resize, <code>B</code> = Gen1&rarr;Gen2 then resize, <code>C</code> = AVD image-replace, <code>D</code> = rebuild.</div>
"@
}

function New-PlanHtmlReport {
    # Writes a single page with up to three tabs: the assessment (all scanned VMs), the
    # wave plan, and (when capacity data is supplied) capacity & quota. No external
    # assets, so it renders fine after a browser download.
    param(
        [object[]] $Rows,
        [object[]] $Pilot,
        [object[]] $Wave1,
        [object[]] $Wave2,
        [object[]] $Review,
        [string]   $Path,
        [object]   $Account,
        [hashtable] $TargetLookup,
        [string]   $CapacityBody,
        [string]   $CapacityCss
    )

    $gen   = (Get-Date).ToString('u')
    $css   = Get-ReportCss
    $aBody = Get-AssessmentBodyHtml -Rows $Rows -TargetLookup $TargetLookup
    $pBody = Get-PlanBodyHtml -Rows $Rows -Pilot $Pilot -Wave1 $Wave1 -Wave2 $Wave2 -Review $Review
    $meta  = if ($Account) {
        "Generated $gen &nbsp;|&nbsp; Tenant $($Account.tenantId) &nbsp;|&nbsp; Read-only, no changes were made"
    }
    else {
        "Generated $gen &nbsp;|&nbsp; Read-only, no changes were made"
    }

    $hasCap      = -not [string]::IsNullOrWhiteSpace($CapacityBody)
    $capCssBlock = if ($hasCap) { $CapacityCss } else { '' }
    $capTab      = if ($hasCap) { "<div class='tab' onclick=""showTab('tab-cap',this)"">Capacity &amp; quota</div>" } else { '' }
    $capPanel    = if ($hasCap) { "<div id='tab-cap' class='panel'>`n$CapacityBody`n </div>" } else { '' }

    $html = @"
<!doctype html><html><head><meta charset='utf-8'>
<title>Azure VM Modernization - Assessment and Plan</title>
$css
$capCssBlock</head><body>
<header>
 <h1>Azure VM Modernization - Assessment &amp; Plan</h1>
 <p>$meta</p>
</header>
<div class='tabs'>
 <div class='tab active' onclick="showTab('tab-assess',this)">Assessment</div>
 <div class='tab' onclick="showTab('tab-plan',this)">Wave plan</div>
 $capTab
</div>
<div class='wrap'>
 <div id='tab-assess' class='panel active'>
$aBody
 </div>
 <div id='tab-plan' class='panel'>
$pBody
 </div>
 $capPanel
</div>
<script>
function showTab(id, btn){
  var ps = document.querySelectorAll('.panel');
  for (var i = 0; i < ps.length; i++){ ps[i].classList.remove('active'); }
  var ts = document.querySelectorAll('.tab');
  for (var j = 0; j < ts.length; j++){ ts[j].classList.remove('active'); }
  document.getElementById(id).classList.add('active');
  btn.classList.add('active');
}
</script>
</body></html>
"@

    $html | Out-File -FilePath $Path -Encoding utf8
}

function Test-CloudShell {
    # True when running inside the browser-based Azure Cloud Shell, where the special
    # `download` command (browser file download) is available.
    if ($env:AZUREPS_HOST_ENVIRONMENT -and $env:AZUREPS_HOST_ENVIRONMENT -match 'cloud-shell') { return $true }
    if ($env:ACC_CLOUD) { return $true }
    if (Get-Command download -ErrorAction SilentlyContinue) { return $true }
    return $false
}

function Get-FreePort {
    # Returns the first bindable TCP port at or after $Preferred, so -Serve never crashes
    # with "Address already in use" when a previous preview server is still holding 8080.
    param([int] $Preferred = 8080, [int] $Attempts = 25)
    for ($p = $Preferred; $p -lt ($Preferred + $Attempts); $p++) {
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
            $listener.Start()
            $listener.Stop()
            return $p
        }
        catch { continue }
    }
    return $Preferred
}

function Show-ReportAccess {
    <#
        Makes the finished report effortless to view, so a non-technical customer does
        nothing extra:
          - In Cloud Shell it auto-triggers the browser download of the HTML report.
          - With -Serve it then starts a tiny local web server (on the first free port)
            so the report opens fully rendered through the Cloud Shell "Web preview" button.
        It always prints copy-paste fallbacks so no one is ever stuck.
        This function is read-only and never changes anything in Azure.
    #>
    param(
        [Parameter(Mandatory)] [string] $HtmlPath,
        [Parameter(Mandatory)] [string] $CsvPath,
        [switch] $Serve,
        [int]    $Port = 8080,
        [switch] $NoDownload
    )

    $inCloudShell = Test-CloudShell
    $htmlName = Split-Path $HtmlPath -Leaf
    $dir      = Split-Path $HtmlPath -Parent

    # Option 1 (always first): hand the finished HTML straight to the browser download, so
    # the customer keeps the file even if they never click Web preview or stop the server.
    if ($inCloudShell -and -not $NoDownload) {
        try {
            Write-Host ""
            Write-Host "Sending the HTML report to your browser downloads..." -ForegroundColor Cyan
            download $HtmlPath
            Write-Host "Done. Open the downloaded file to view the report in your browser." -ForegroundColor Green
        }
        catch {
            Write-Host "Auto-download did not trigger. Use the manual command below." -ForegroundColor Yellow
        }
    }

    # Option 2 (optional): also serve a live, clickable, rendered page via Web preview.
    if ($Serve) {
        $py = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $py) {
            Write-Host "Cannot serve: python is not available here. Use the download options below instead." -ForegroundColor Yellow
        }
        else {
            $servePort = Get-FreePort -Preferred $Port
            if ($servePort -ne $Port) {
                Write-Host ("Port {0} was busy, serving on {1} instead." -f $Port, $servePort) -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "Serving your report for in-browser viewing..." -ForegroundColor Cyan
            Write-Host ("  1. In the Cloud Shell toolbar, click 'Web preview' and choose port {0}." -f $servePort) -ForegroundColor Cyan
            Write-Host ("  2. On the page that opens, click '{0}' to view the report." -f $htmlName) -ForegroundColor Cyan
            Write-Host "  3. Press Ctrl+C here when you are done to stop the server." -ForegroundColor DarkGray
            Write-Host ""
            Push-Location $dir
            try { & $py.Source '-m' 'http.server' "$servePort" }
            finally { Pop-Location }
            return
        }
    }

    # Always: copy-paste fallbacks so every customer has a way out.
    Write-Host ""
    Write-Host "Get your report (pick whichever is easiest):" -ForegroundColor Cyan
    if ($inCloudShell) {
        Write-Host "  Download to your computer:" -ForegroundColor DarkGray
        Write-Host ("    download {0}" -f $HtmlPath)
        Write-Host ("    download {0}" -f $CsvPath)
        Write-Host "  View it rendered in the browser (clickable page):" -ForegroundColor DarkGray
        Write-Host "    add -Serve when you run the assessment, then click 'Web preview'"
        Write-Host "  Or use the toolbar: Manage files > Download > paste a path above." -ForegroundColor DarkGray
    }
    else {
        Write-Host ("  Open this file in your browser: {0}" -f $HtmlPath) -ForegroundColor DarkGray
    }
}
