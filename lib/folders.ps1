#requires -version 5.1
<#
  Folder weight: how much attention a favourites folder deserves.

  Why not a hard-coded folder name list: the default config used to ship with
  one personal folder name in LowPriorityFolders, which is meaningless for
  anyone else and mildly identifying. Weight rules are generic:

    "FolderWeight": [
      { "match": "*",     "weight": 1 },   // everything is normal
      { "match": "misc",  "weight": 0 },   // skip by default (was LowPriorityFolders)
      { "match": "core",  "weight": 3 }    // refresh first, fullest detail
    ]

  Rules are evaluated in order and the LAST match wins, so put the specific
  ones after the wildcard. Weight meanings:

    0  never collected unless -IncludeLow / -Force
    1  normal (default)
    2  refreshed before weight 1 when the run is capped
    3  refreshed first, and first in the enrich queue

  Legacy key still honoured: LowPriorityFolders entries mean weight 0, but only
  when no FolderWeight rule matched that folder.
#>

function Get-FolderWeight {
    [CmdletBinding()]
    param($Cfg, [string]$Name)

    if (-not $Cfg) { return 1 }

    $matched = $false
    $w = 1

    if ($Cfg.PSObject.Properties['FolderWeight'] -and $Cfg.FolderWeight) {
        foreach ($rule in @($Cfg.FolderWeight)) {
            if (-not $rule) { continue }
            $m = [string]$rule.match
            if (-not $m) { continue }
            if ($Name -like ('*' + $m + '*')) {
                $w = [int]$rule.weight
                $matched = $true
            }
        }
    }

    if (-not $matched -and $Cfg.PSObject.Properties['LowPriorityFolders'] -and $Cfg.LowPriorityFolders) {
        foreach ($pat in @($Cfg.LowPriorityFolders)) {
            if ($pat -and $Name -like ('*' + [string]$pat + '*')) { $w = 0; break }
        }
    }

    if ($w -lt 0) { $w = 0 }
    if ($w -gt 3) { $w = 3 }
    return $w
}

<#
  Folder plan: the settings page writes an explicit ordered list
  (config.json -> FavFolderPlan) of { name, level } entries. The list carries
  both the collection order and the per-folder level:

    full   collect on the incremental and the weekly full run (default)
    daily  collect only on the incremental run
    skip   never collect

  A folder that is not listed falls back to the FolderWeight rule (weight 0
  means skip), so older configs keep working.
#>
function Get-FavPlanEntry {
    param($Cfg, [string]$Name)
    if (-not $Cfg -or -not $Cfg.PSObject.Properties['FavFolderPlan'] -or -not $Cfg.FavFolderPlan) { return $null }
    foreach ($e in @($Cfg.FavFolderPlan)) {
        if ($e -and ([string]$e.name) -eq $Name) { return $e }
    }
    return $null
}

function Get-FavPlanLevel {
    param($Cfg, [string]$Name)
    $e = Get-FavPlanEntry -Cfg $Cfg -Name $Name
    if ($e) {
        $lv = [string]$e.level
        if ($lv -in @('full', 'daily', 'skip')) { return $lv }
        return 'full'
    }
    # An explicit plan is authoritative: directories the plan does not mention
    # (a folder created after the last save) default to full. The legacy weight
    # rule only applies when there is no plan at all, otherwise LowPriorityFolders
    # patterns like "friends" would silently skip every "friends*" folder.
    if ($Cfg -and $Cfg.PSObject.Properties['FavFolderPlan'] -and $Cfg.FavFolderPlan) { return 'full' }
    $w = Get-FolderWeight -Cfg $Cfg -Name $Name
    if ($w -le 0) { return 'skip' }
    return 'full'
}

function Get-FavPlanRank {
    param($Cfg, [string]$Name)
    if (-not $Cfg -or -not $Cfg.PSObject.Properties['FavFolderPlan'] -or -not $Cfg.FavFolderPlan) { return -1 }
    $i = 0
    foreach ($e in @($Cfg.FavFolderPlan)) {
        if ($e -and ([string]$e.name) -eq $Name) { return $i }
        $i++
    }
    return -1
}
