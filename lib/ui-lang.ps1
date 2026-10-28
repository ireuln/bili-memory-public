#requires -version 5.1
<#
  Merge optional UI language packs into the loaded config.

  config.json may contain:
      "UiLanguage": "zh-CN"   (default, labels already in config)
      "UiLanguage": "en-US"   (loads lang\en-US.json)

  A language pack only overrides display labels (Tray / Share / Drafts.shareLabel).
  Data paths and file names are never translated by a pack, so existing archives
  keep working.
#>
function Merge-UiLanguage {
    param($Cfg, [string]$Root)

    if (-not $Cfg) { return $Cfg }
    $lang = [string]$Cfg.UiLanguage
    if (-not $lang) { return $Cfg }

    $file = Join-Path (Join-Path $Root 'lang') ($lang + '.json')
    if (-not (Test-Path $file)) { return $Cfg }

    $pack = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($section in @('Tray', 'Share', 'Drafts')) {
        $sp = $pack.PSObject.Properties[$section]
        if (-not $sp) { continue }
        if (-not $Cfg.PSObject.Properties[$section]) {
            $Cfg | Add-Member -NotePropertyName $section -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        foreach ($p in $sp.Value.PSObject.Properties) {
            $Cfg.$section | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    }
    return $Cfg
}
