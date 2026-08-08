#requires -Version 7.0
<#
    capacity.ps1  -  read-only region capacity + quota helpers.

    This module answers two field questions, per subscription and per region:
      1. Is the modern target SKU we recommend actually OFFERED in that region for
         this subscription? (Azure Compute "resource SKUs" + its restrictions.)
      2. Does the subscription have enough vCPU QUOTA left in that SKU's family to
         place it? (Azure Compute usage/limits.)

    IMPORTANT, and stated plainly in the report: "offered" + "quota available" does
    NOT guarantee live datacenter capacity at deploy time. In constrained regions
    (for example Canada), confirm a migration wave with the Azure capacity team
    before committing. Nothing here changes any resource - it only reads.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    <#
        Runs a read-only 'az ... -o json' command with the same retry/backoff posture
        as the inventory query. Returns parsed objects, or throws after max attempts so
        we never silently show partial capacity data.
    #>
    param(
        [string[]] $AzArgs,
        [int]      $MaxAttempts = 4,
        [switch]   $AllowEmpty
    )
    $attempt = 0
    while ($true) {
        $attempt++
        $raw  = az @AzArgs 2>&1
        $exit = $LASTEXITCODE
        if ($exit -eq 0) {
            $text = ($raw | Out-String).Trim()
            if (-not $text) { if ($AllowEmpty) { return @() } else { $text = '[]' } }
            try { return ($text | ConvertFrom-Json) } catch { }
        }
        if ($attempt -ge $MaxAttempts) {
            $err = ($raw | Out-String).Trim()
            throw "Azure read command failed after $MaxAttempts attempts (az $($AzArgs -join ' ')). Last error: $err"
        }
        $wait = [math]::Min(30, [int][math]::Pow(2, $attempt))
        Write-Host ("  capacity read retry {0}/{1} in {2}s..." -f $attempt, $MaxAttempts, $wait) -ForegroundColor DarkYellow
        Start-Sleep -Seconds $wait
    }
}

function Get-CandidateRegions {
    <#
        Regions to check = every region where the caller actually has a modernization
        candidate (Track != NONE), unless the operator passes -Regions to override.
        This keeps the capacity scan zero-config for the common case but lets someone
        deliberately check a target region they plan to consolidate into.
    #>
    param(
        [object[]] $Rows,
        [string[]] $Regions
    )
    if ($Regions -and $Regions.Count -gt 0) {
        return @($Regions | ForEach-Object { $_.ToLower().Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }
    return @($Rows |
        Where-Object { $_.Track -notin @('NONE') -and $_.Location } |
        Select-Object -ExpandProperty Location -Unique |
        ForEach-Object { $_.ToLower() } |
        Sort-Object)
}

function Get-RegionSkuMap {
    <#
        For each region, pulls the VM resource SKUs and indexes them by size name.
        Captures family, vCPUs, and any subscription/zone restrictions so we can tell
        "offered" from "restricted for your subscription".
        Returns: hashtable  region -> ( hashtable sizeName -> info ).
    #>
    param([string[]] $Regions)

    $map = @{}
    foreach ($region in $Regions) {
        Write-Host ("  reading SKU availability in {0}..." -f $region) -ForegroundColor DarkGray
        $skus = Invoke-AzJson -AzArgs @('vm','list-skus','--location',$region,'--resource-type','virtualMachines','-o','json') -AllowEmpty
        $byName = @{}
        foreach ($s in @($skus)) {
            $vcpu = 0
            if ($s.capabilities) {
                $c = $s.capabilities | Where-Object { $_.name -eq 'vCPUs' } | Select-Object -First 1
                if ($c) { [int]::TryParse([string]$c.value, [ref]$vcpu) | Out-Null }
            }

            # Restriction analysis. A Location-scoped restriction means the size is not
            # offered to THIS subscription in THIS region. Zone-scoped restrictions only
            # limit specific zones, so the size is still usable (regional / other zones).
            $locRestricted = $false
            $restrictedZones = @()
            $reason = $null
            foreach ($r in @($s.restrictions)) {
                if ($r.type -eq 'Location') { $locRestricted = $true; if ($r.reasonCode) { $reason = $r.reasonCode } }
                elseif ($r.type -eq 'Zone' -and $r.restrictionInfo -and $r.restrictionInfo.zones) {
                    $restrictedZones += @($r.restrictionInfo.zones)
                    if ($r.reasonCode) { $reason = $r.reasonCode }
                }
            }

            $byName[$s.name] = [pscustomobject]@{
                Name            = $s.name
                Family          = $s.family
                VCpus           = $vcpu
                LocationRestricted = $locRestricted
                RestrictedZones = ($restrictedZones | Select-Object -Unique)
                Reason          = $reason
            }
        }
        $map[$region] = $byName
    }
    return $map
}

function Get-RegionUsageMap {
    <#
        For each region, pulls current vCPU usage vs limit per VM family.
        Returns: hashtable  region -> ( hashtable familyName -> @{ Current; Limit } ).
        familyName here matches the 'family' field on the SKU objects above.
    #>
    param([string[]] $Regions)

    $map = @{}
    foreach ($region in $Regions) {
        Write-Host ("  reading quota / usage in {0}..." -f $region) -ForegroundColor DarkGray
        $usage = Invoke-AzJson -AzArgs @('vm','list-usage','--location',$region,'-o','json') -AllowEmpty
        $byFamily = @{}
        foreach ($u in @($usage)) {
            $key = if ($u.name -and $u.name.value) { $u.name.value } else { [string]$u.name }
            if (-not $key) { continue }
            # Keep only vCPU/core quotas: per-family core limits (e.g. "standardDSv5Family")
            # and the regional total ("cores"). This drops storage/snapshot/disk-GB rows
            # that share this endpoint and are noise for a compute modernization.
            if (-not ($key -match 'Family$' -or $key -eq 'cores')) { continue }
            $byFamily[$key] = @{
                Current   = [int]$u.currentValue
                Limit     = [int]$u.limit
                LocalName = if ($u.name -and $u.name.localizedValue) { $u.name.localizedValue } else { $key }
            }
        }
        $map[$region] = $byFamily
    }
    return $map
}

function Get-TargetCapacity {
    <#
        Cross-references each recommended target (from the assessment) against the
        region SKU map and usage map, and produces a plain-language verdict per
        (target, region). Two modes:

          - Default (in-place resize): each target is checked in the region its VMs
            already run in. Group by (Target, Location).
          - Consolidation (-OverrideRegions): each distinct target is checked in every
            region the operator named, because they intend to land the VMs there.

        Quota need is aggregated across the whole wave (VMs x target vCPUs), and when it
        exceeds free quota the exact "+N cores" to request is surfaced.
    #>
    param(
        [object[]]  $Rows,
        [hashtable] $SkuMap,
        [hashtable] $UsageMap,
        [string[]]  $OverrideRegions
    )

    $candidates = @($Rows | Where-Object { $_.Track -notin @('NONE') -and $_.Target -and $_.Location })
    $override   = @($OverrideRegions | Where-Object { $_ } | ForEach-Object { $_.ToLower().Trim() } | Select-Object -Unique)

    # Build (target, region, vmCount) tuples for the chosen mode.
    $tuples = New-Object System.Collections.Generic.List[object]
    if ($override.Count -gt 0) {
        foreach ($g in ($candidates | Group-Object Target)) {
            foreach ($region in $override) {
                $tuples.Add([pscustomobject]@{ Target = $g.Name; Region = $region; VmCount = $g.Count })
            }
        }
    }
    else {
        foreach ($g in ($candidates | Group-Object { "{0}|{1}" -f $_.Target, $_.Location.ToLower() })) {
            $first = $g.Group[0]
            $tuples.Add([pscustomobject]@{ Target = $first.Target; Region = $first.Location.ToLower(); VmCount = $g.Count })
        }
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tuples) {
        $target = $t.Target; $region = $t.Region; $count = [int]$t.VmCount

        # Only emit rows for regions we actually scanned, so we never show "unknown" noise.
        if (-not $SkuMap.ContainsKey($region)) { continue }

        $availability = 'Unknown'; $availDetail = ''; $family = ''; $famLocal = ''; $vcpuPer = 0
        $quota = 'Unknown'; $quotaDetail = ''; $used = 0; $limit = 0; $free = 0; $needed = 0; $deficit = 0

        $regionSkus = $SkuMap[$region]
        if (-not $regionSkus.ContainsKey($target)) {
            $availability = 'Not offered'
            $availDetail  = 'Target size is not offered in this region.'
        }
        else {
            $info    = $regionSkus[$target]
            $family  = $info.Family
            $vcpuPer = [int]$info.VCpus
            if ($info.LocationRestricted) {
                $availability = 'Restricted'
                $availDetail  = "Not available to this subscription in $region ($($info.Reason))."
            }
            elseif ($info.RestrictedZones -and $info.RestrictedZones.Count -gt 0) {
                $availability = 'Available (zonal limits)'
                $availDetail  = "Some zones restricted: $($info.RestrictedZones -join ', ')."
            }
            else {
                $availability = 'Available'
                $availDetail  = 'Offered to this subscription in this region.'
            }

            # Quota only meaningful when the size is at least offered. Test the WHOLE wave.
            if ($availability -ne 'Restricted' -and $availability -ne 'Not offered') {
                $needed = $vcpuPer * $count
                $regionUsage = $UsageMap[$region]
                if ($regionUsage -and $family -and $regionUsage.ContainsKey($family)) {
                    $u = $regionUsage[$family]
                    $used = [int]$u.Current; $limit = [int]$u.Limit; $free = $limit - $used; $famLocal = $u.LocalName
                    if ($needed -gt 0 -and $free -lt $needed) {
                        $deficit     = $needed - $free
                        $quota       = 'Shortfall'
                        $quotaDetail = "Need $needed vCPU for $count VM(s), only $free free of $limit in '$famLocal'. Request +$deficit cores."
                    }
                    else {
                        $quota       = 'OK'
                        $quotaDetail = "$free of $limit vCPU free in '$famLocal' (this wave needs $needed for $count VM(s))."
                    }
                }
                else {
                    $quotaDetail = 'No vCPU usage figure returned for this family.'
                }
            }
        }

        # Single combined verdict for the money table.
        $verdict = 'Unknown'; $vclass = 'unk'
        if ($availability -eq 'Not offered') { $verdict = 'Not offered here'; $vclass = 'bad' }
        elseif ($availability -eq 'Restricted') { $verdict = 'Restricted (subscription)'; $vclass = 'bad' }
        elseif ($quota -eq 'Shortfall') { $verdict = "Request quota (+$deficit cores)"; $vclass = 'bad' }
        elseif ($availability -eq 'Available (zonal limits)') { $verdict = 'Ready (zonal limits)'; $vclass = 'warn' }
        elseif ($quota -eq 'OK') { $verdict = 'Ready'; $vclass = 'ok' }
        elseif ($quota -eq 'Unknown') { $verdict = 'Check quota'; $vclass = 'unk' }

        $out.Add([pscustomobject]@{
            Target        = $target
            Region        = $region
            Family        = $(if ($famLocal) { $famLocal } else { $family })
            FamilyKey     = $family
            VmCount       = $count
            VCpusPerVm    = $vcpuPer
            VCpusNeeded   = $needed
            Used          = $used
            Limit         = $limit
            Free          = $free
            Deficit       = $deficit
            Availability  = $availability
            AvailDetail   = $availDetail
            Quota         = $quota
            QuotaDetail   = $quotaDetail
            Verdict       = $verdict
            VerdictClass  = $vclass
        })
    }
    return @($out | Sort-Object Region, Target)
}

function Get-RegionQuotaMatrix {
    <#
        The standalone "what can I deploy here" view: for each scanned region, the vCPU
        families with the most headroom. Useful even when nobody is modernizing - it is
        the capacity question sellers and customers ask on its own. When target capacity
        is supplied, a "Needed now" column shows how much of that headroom this migration
        would consume, so the two views reconcile.
    #>
    param(
        [hashtable] $UsageMap,
        [object[]]  $TargetCapacity
    )

    # region|familyKey -> vCPUs this migration needs; plus a per-region grand total for "cores".
    $needByFam   = @{}
    $needByRegion = @{}
    foreach ($r in @($TargetCapacity)) {
        if (-not $r.FamilyKey) { continue }
        $k = "{0}|{1}" -f $r.Region, $r.FamilyKey
        if (-not $needByFam.ContainsKey($k)) { $needByFam[$k] = 0 }
        $needByFam[$k] += [int]$r.VCpusNeeded
        if (-not $needByRegion.ContainsKey($r.Region)) { $needByRegion[$r.Region] = 0 }
        $needByRegion[$r.Region] += [int]$r.VCpusNeeded
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($region in ($UsageMap.Keys | Sort-Object)) {
        foreach ($fam in $UsageMap[$region].Keys) {
            $u = $UsageMap[$region][$fam]
            if ($u.Limit -le 0) { continue }
            $free = $u.Limit - $u.Current
            $needed = if ($fam -eq 'cores') {
                if ($needByRegion.ContainsKey($region)) { [int]$needByRegion[$region] } else { 0 }
            }
            else {
                $k = "{0}|{1}" -f $region, $fam
                if ($needByFam.ContainsKey($k)) { [int]$needByFam[$k] } else { 0 }
            }
            $rows.Add([pscustomobject]@{
                Region    = $region
                Family    = $u.LocalName
                Used      = $u.Current
                Limit     = $u.Limit
                Free      = $free
                Needed    = $needed
                UsedPct   = [math]::Round(($u.Current / $u.Limit) * 100, 0)
            })
        }
    }
    # Families this migration touches first (needed desc), then the rest by free headroom.
    return @($rows | Sort-Object Region, @{Expression='Needed';Descending=$true}, @{Expression='Free';Descending=$true})
}

function Get-CapacityBodyHtml {
    <#
        Renders the capacity view: a scorecard, the standing caution note, a region-first
        "can I land my modernization" table (grouped by region, then target family), and
        the region/family vCPU headroom matrix. Reuses the shared report CSS classes from
        common.ps1 plus the capacity chips from Get-CapacityCss.
    #>
    param(
        [object[]] $TargetCapacity,
        [object[]] $QuotaMatrix
    )

    $tc = @($TargetCapacity)

    # --- Scorecard -----------------------------------------------------------------
    $sumVms   = ($tc | Measure-Object VmCount -Sum).Sum;      if (-not $sumVms)   { $sumVms = 0 }
    $sumVcpu  = ($tc | Measure-Object VCpusNeeded -Sum).Sum;  if (-not $sumVcpu)  { $sumVcpu = 0 }
    $nRegions = @($tc | Select-Object -ExpandProperty Region -Unique).Count
    $nFam     = @($tc | Where-Object { $_.FamilyKey } | Select-Object -ExpandProperty FamilyKey -Unique).Count
    $nBlock   = @($tc | Where-Object { $_.Quota -eq 'Shortfall' }).Count
    $nRestr   = @($tc | Where-Object { $_.Availability -in @('Restricted','Not offered') }).Count
    $blockCls = if ($nBlock -gt 0) { 'big cap-num-bad' } else { 'big' }
    $restrCls = if ($nRestr -gt 0) { 'big cap-num-bad' } else { 'big' }

    $cards = @"
 <div class='cards'>
   <div class='card'><div class='big'>$sumVms</div><div class='lbl'>Legacy VMs in scope</div></div>
   <div class='card'><div class='big'>$sumVcpu</div><div class='lbl'>vCPUs to place</div></div>
   <div class='card'><div class='big'>$nRegions</div><div class='lbl'>Regions</div></div>
   <div class='card'><div class='big'>$nFam</div><div class='lbl'>Target families</div></div>
   <div class='card'><div class='$blockCls'>$nBlock</div><div class='lbl'>Quota blockers</div></div>
   <div class='card'><div class='$restrCls'>$nRestr</div><div class='lbl'>Restricted / not offered</div></div>
 </div>
"@

    # --- Section B: region-first "can I land it" table -----------------------------
    $regionSections = ''
    foreach ($region in (@($tc | Select-Object -ExpandProperty Region -Unique) | Sort-Object)) {
        $rrows = @($tc | Where-Object { $_.Region -eq $region } | Sort-Object @{Expression='VerdictClass';Descending=$false}, Target)
        $rBlockers = @($rrows | Where-Object { $_.VerdictClass -eq 'bad' }).Count
        $badge = if ($rBlockers -gt 0) { "<span class='cap bad'>$rBlockers to resolve</span>" } else { "<span class='cap ok'>all clear</span>" }

        $body = (@($rrows) | ForEach-Object {
            $usedLimit = if ($_.Limit -gt 0) { "$($_.Used) / $($_.Limit)" } else { '-' }
            $freeCell  = if ($_.Limit -gt 0) { "<b>$($_.Free)</b>" } else { '-' }
            $after     = if ($_.Quota -in @('OK','Shortfall')) {
                $h = $_.Free - $_.VCpusNeeded
                if ($h -lt 0) { "<span class='cap bad'>$h</span>" } else { "$h" }
            } else { '-' }
            $needCell  = if ($_.VCpusNeeded -gt 0) { $_.VCpusNeeded } else { '-' }
            "<tr><td class='mono'>$($_.Target)</td><td>$($_.Family)</td><td class='num'>$($_.VmCount)</td><td class='num'>$needCell</td><td class='num'>$usedLimit</td><td class='num'>$freeCell</td><td class='num'>$after</td><td><span class='cap $($_.VerdictClass)'>$($_.Verdict)</span><div class='cap-d'>$($_.QuotaDetail)$($_.AvailDetail)</div></td></tr>"
        }) -join "`n"
        if (-not $body) { $body = "<tr><td colspan='8'>No candidates in this region.</td></tr>" }

        $regionSections += @"
 <div class='cap-region'>$region &nbsp; $badge</div>
 <table>
  <thead><tr><th>Target size</th><th>Family</th><th>VMs</th><th>vCPUs needed</th><th>Used / Limit</th><th>Free</th><th>Headroom after</th><th>Verdict</th></tr></thead>
  <tbody>
  $body
  </tbody>
 </table>
"@
    }
    if (-not $regionSections) { $regionSections = "<div class='legend'>No modernization candidates to check.</div>" }

    # --- Section C: compute-family headroom matrix ---------------------------------
    $matrixRows = (@($QuotaMatrix) | ForEach-Object {
        $cls = if ($_.UsedPct -ge 90) { 'bad' } elseif ($_.UsedPct -ge 70) { 'warn' } else { 'ok' }
        $needCell = if ($_.Needed -gt 0) { "<b>$($_.Needed)</b>" } else { '-' }
        "<tr><td class='mono'>$($_.Region)</td><td>$($_.Family)</td><td class='num'>$($_.Used)</td><td class='num'>$($_.Limit)</td><td class='num'><b>$($_.Free)</b></td><td class='num'>$needCell</td><td class='num'><span class='cap $cls'>$($_.UsedPct)%</span></td></tr>"
    }) -join "`n"
    if (-not $matrixRows) { $matrixRows = "<tr><td colspan='7'>No compute vCPU quota data returned.</td></tr>" }

    @"
$cards
 <div class='note cap-warn'><b>Read this first.</b> "Ready" means the target SKU is offered to
 your subscription and you have vCPU headroom for the wave. It does <b>not</b> guarantee live
 datacenter capacity at deploy time. In capacity-constrained regions (for example Canada),
 confirm the wave with the Azure capacity team before committing. This view is read-only.</div>

 <h2>Can I land my modernization? (by region)</h2>
 <div class='legend'>Grouped by region, then target family. "vCPUs needed" is the whole wave
 (VMs &times; target vCPUs). A <span class='cap bad'>red</span> verdict is a blocker to resolve
 before that wave, and "Request quota (+N cores)" is the exact increase to file.</div>
$regionSections

 <h2>Region capacity - vCPU quota by family</h2>
 <div class='legend'>Headroom in every region you use today, compute families only. Answers
 "what can I actually deploy here" independent of modernization. "Needed now" is what this
 migration would consume from that family.</div>
 <table>
  <thead><tr><th>Region</th><th>VM family</th><th>Used</th><th>Limit</th><th>Free</th><th>Needed now</th><th>Used %</th></tr></thead>
  <tbody>
  $matrixRows
  </tbody>
 </table>
"@
}

function Get-CapacityCss {
    # Small additive style block for capacity chips. Kept here so the module is
    # self-contained and does not touch the shared Get-ReportCss in common.ps1.
    @"
<style>
 .cap{display:inline-block;border-radius:4px;padding:1px 7px;font-size:12px;font-weight:600}
 .cap.ok{background:#dff6dd;color:#107c10}
 .cap.warn{background:#fff4ce;color:#805600}
 .cap.bad{background:#fde7e9;color:#a4262c}
 .cap.unk{background:#edebe9;color:#605e5c}
 .cap-d{font-size:11px;color:#605e5c;margin-top:2px}
 .cap-warn{border-left-color:#a4262c !important;background:#fff5f5 !important}
 .cap-region{font-weight:600;font-size:15px;margin:20px 0 6px;color:#323130;border-left:3px solid #0078d4;padding-left:8px}
 .cap-num-bad{color:#a4262c}
 td.num{text-align:right;font-variant-numeric:tabular-nums}
</style>
"@
}

function New-CapacityHtmlReport {
    # Standalone capacity page (its own file). Reuses the shared CSS plus the capacity
    # chip styles. Two sections: target availability, and the region quota matrix.
    param(
        [object[]] $TargetCapacity,
        [object[]] $QuotaMatrix,
        [string]   $Path,
        [object]   $Account,
        [string[]] $Regions
    )

    $gen  = (Get-Date).ToString('u')
    $css  = Get-ReportCss
    $cap  = Get-CapacityCss
    $body = Get-CapacityBodyHtml -TargetCapacity $TargetCapacity -QuotaMatrix $QuotaMatrix
    $meta = if ($Account) {
        "Generated $gen &nbsp;|&nbsp; Tenant $($Account.tenantId) &nbsp;|&nbsp; Regions: $($Regions -join ', ') &nbsp;|&nbsp; Read-only, no changes were made"
    } else {
        "Generated $gen &nbsp;|&nbsp; Regions: $($Regions -join ', ') &nbsp;|&nbsp; Read-only, no changes were made"
    }

    $html = @"
<!doctype html><html><head><meta charset='utf-8'>
<title>Azure VM Modernization - Capacity &amp; Quota</title>
$css
$cap</head><body>
<header>
 <h1>Azure VM Modernization - Capacity &amp; Quota</h1>
 <p>$meta</p>
</header>
<div class='wrap'>
$body
</div></body></html>
"@

    $html | Out-File -FilePath $Path -Encoding utf8
}
