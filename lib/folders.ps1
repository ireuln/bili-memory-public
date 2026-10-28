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
