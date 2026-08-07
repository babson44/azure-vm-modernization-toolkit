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
        [string[]] $Args,
        [int]      $MaxAttempts = 4,
        [switch]   $AllowEmpty
    )
    $attempt = 0
    while ($true) {
        $attempt++
        $raw  = az @Args 2>&1
        $exit = $LASTEXITCODE
        if ($exit -eq 0) {
            $text = ($raw | Out-String).Trim()
            if (-not $text) { if ($AllowEmpty) { return @() } else { $text = '[]' } }
            try { return ($text | ConvertFrom-Json) } catch { }
        }
        if ($attempt -ge $MaxAttempts) {
            $err = ($raw | Out-String).Trim()
            throw "Azure read command failed after $MaxAttempts attempts (az $($Args -join ' ')). Last error: $err"
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
        $skus = Invoke-AzJson -Args @('vm','list-skus','--location',$region,'--resource-type','virtualMachines','-o','json') -AllowEmpty
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
        $usage = Invoke-AzJson -Args @('vm','list-usage','--location',$region,'-o','json') -AllowEmpty
        $byFamily = @{}
        foreach ($u in @($usage)) {
            $key = if ($u.name -and $u.name.value) { $u.name.value } else { [string]$u.name }
            if (-not $key) { continue }
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
        region SKU map and usage map. One row per unique (Target, Region) pair among
        the modernization candidates, with a plain-language verdict.
    #>
    param(
        [object[]]  $Rows,
        [hashtable] $SkuMap,
        [hashtable] $UsageMap
    )

    $pairs = $Rows |
        Where-Object { $_.Track -notin @('NONE') -and $_.Target -and $_.Location } |
        Group-Object { "{0}|{1}" -f $_.Target, $_.Location.ToLower() }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in $pairs) {
        $first  = $p.Group[0]
        $target = $first.Target
        $region = $first.Location.ToLower()
        $count  = $p.Group.Count

        $availability = 'Unknown'
        $availDetail  = ''
        $quota        = 'Unknown'
        $quotaDetail  = ''
        $family       = ''

        $regionSkus = $SkuMap[$region]
        if (-not $regionSkus) {
            $availDetail = 'Region not scanned.'
        }
        elseif (-not $regionSkus.ContainsKey($target)) {
            $availability = 'Not offered'
            $availDetail  = 'Target size is not offered in this region.'
        }
        else {
            $info   = $regionSkus[$target]
            $family = $info.Family
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

            # Quota only meaningful when the size is at least offered.
            if ($availability -ne 'Restricted' -and $availability -ne 'Not offered') {
                $regionUsage = $UsageMap[$region]
                if ($regionUsage -and $family -and $regionUsage.ContainsKey($family)) {
                    $u = $regionUsage[$family]
                    $free = $u.Limit - $u.Current
                    $need = if ($info.VCpus -gt 0) { $info.VCpus } else { 0 }
                    if ($need -gt 0 -and $free -lt $need) {
                        $quota       = 'Shortfall'
                        $quotaDetail = "Need $need vCPU, only $free free of $($u.Limit) in family '$($u.LocalName)'."
                    }
                    else {
                        $quota       = 'OK'
                        $quotaDetail = "$free of $($u.Limit) vCPU free in family '$($u.LocalName)'."
                    }
                }
                else {
                    $quotaDetail = 'No usage figure returned for this family.'
                }
            }
        }

        $out.Add([pscustomobject]@{
            Target        = $target
            Region        = $region
            Family        = $family
            VmCount       = $count
            Availability  = $availability
            AvailDetail   = $availDetail
            Quota         = $quota
            QuotaDetail   = $quotaDetail
        })
    }
    return @($out | Sort-Object Region, Target)
}

function Get-RegionQuotaMatrix {
    <#
        The standalone "what can I deploy here" view: for each scanned region, the vCPU
        families with the most headroom. Useful even when nobody is modernizing - it is
        the capacity question sellers and customers ask on its own.
    #>
    param([hashtable] $UsageMap)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($region in ($UsageMap.Keys | Sort-Object)) {
        foreach ($fam in $UsageMap[$region].Keys) {
            $u = $UsageMap[$region][$fam]
            if ($u.Limit -le 0) { continue }
            $free = $u.Limit - $u.Current
            $rows.Add([pscustomobject]@{
                Region    = $region
                Family    = $u.LocalName
                Used      = $u.Current
                Limit     = $u.Limit
                Free      = $free
                UsedPct   = [math]::Round(($u.Current / $u.Limit) * 100, 0)
            })
        }
    }
    return @($rows | Sort-Object Region, @{Expression='Free';Descending=$true})
}

function Get-CapacityBodyHtml {
    <#
        Renders the capacity view: the standing caution note, a target-availability
        table (tied to the modernization plan), and the region/family quota matrix.
        Reuses the shared report CSS classes from common.ps1.
    #>
    param(
        [object[]] $TargetCapacity,
        [object[]] $QuotaMatrix
    )

    $chip = {
        param($state)
        switch -Wildcard ($state) {
            'Available'          { "<span class='cap ok'>Available</span>" }
            'Available*'         { "<span class='cap warn'>$state</span>" }
            'OK'                 { "<span class='cap ok'>OK</span>" }
            'Restricted'         { "<span class='cap bad'>Restricted</span>" }
            'Not offered'        { "<span class='cap bad'>Not offered</span>" }
            'Shortfall'          { "<span class='cap bad'>Shortfall</span>" }
            default              { "<span class='cap unk'>$state</span>" }
        }
    }

    $targetRows = (@($TargetCapacity) | ForEach-Object {
        $a = & $chip $_.Availability
        $q = & $chip $_.Quota
        "<tr><td class='mono'>$($_.Target)</td><td class='mono'>$($_.Region)</td><td>$($_.VmCount)</td><td>$a<div class='cap-d'>$($_.AvailDetail)</div></td><td>$q<div class='cap-d'>$($_.QuotaDetail)</div></td></tr>"
    }) -join "`n"
    if (-not $targetRows) { $targetRows = "<tr><td colspan='5'>No modernization candidates to check.</td></tr>" }

    $matrixRows = (@($QuotaMatrix) | ForEach-Object {
        $cls = if ($_.UsedPct -ge 90) { 'bad' } elseif ($_.UsedPct -ge 70) { 'warn' } else { 'ok' }
        "<tr><td class='mono'>$($_.Region)</td><td>$($_.Family)</td><td class='num'>$($_.Used)</td><td class='num'>$($_.Limit)</td><td class='num'><b>$($_.Free)</b></td><td class='num'><span class='cap $cls'>$($_.UsedPct)%</span></td></tr>"
    }) -join "`n"
    if (-not $matrixRows) { $matrixRows = "<tr><td colspan='6'>No usage data returned.</td></tr>" }

    @"
 <div class='note cap-warn'><b>Read this first.</b> "Available" and "quota OK" mean the SKU is
 offered to your subscription and you have vCPU headroom. They do <b>not</b> guarantee live
 datacenter capacity at deploy time. In capacity-constrained regions (for example Canada),
 confirm a migration wave with the Azure capacity team before committing. This view is read-only.</div>

 <h2>Recommended targets - availability &amp; quota</h2>
 <div class='legend'>One row per recommended target size in each region where you have candidates.
 A <span class='cap bad'>red</span> chip is a blocker to resolve before that wave.</div>
 <table>
  <thead><tr><th>Target size</th><th>Region</th><th>VMs</th><th>Availability</th><th>Quota</th></tr></thead>
  <tbody>
  $targetRows
  </tbody>
 </table>

 <h2>Region capacity - vCPU quota by family</h2>
 <div class='legend'>Headroom in every region you use today. Answers "what can I actually deploy here"
 independent of modernization.</div>
 <table>
  <thead><tr><th>Region</th><th>VM family</th><th>Used</th><th>Limit</th><th>Free</th><th>Used %</th></tr></thead>
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
