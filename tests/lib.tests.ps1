#requires -version 5.1
<#
  Behaviour tests for the pure helpers in lib\. Pester 3.x syntax on purpose:
  Windows ships Pester 3.4, so the tests run on a clean machine without any
  install. No network, no writes, no scheduled tasks.
#>

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\detail.ps1')
. (Join-Path $root 'lib\folders.ps1')

# ---------------------------------------------------------------- detail.ps1

$detailFixture = [pscustomobject]@{
    View = [pscustomobject]@{
        bvid      = 'BV1fixture'
        title     = 'fixture title'
        desc      = 'fixture desc'
        pubdate   = 1700000000
        tname     = ''
        tname_v2  = 'anime'
        tid       = 1
        tid_v2    = 1002
        owner     = [pscustomobject]@{ name = 'fixture up'; mid = 42; face = 'http://example/face.jpg' }
        dimension = [pscustomobject]@{ width = 1920; height = 1080; rotate = 0 }
        stat      = [pscustomobject]@{ view = 10; danmaku = 2; reply = 3; like = 4; coin = 5; favorite = 6; share = 7 }
    }
    Tags = @(
        [pscustomobject]@{ tag_name = 'anime'; tag_type = '' }
        [pscustomobject]@{ tag_name = 'anime'; tag_type = '' }
        [pscustomobject]@{ tag_name = 'bgm song'; tag_type = 'bgm'; music_id = 'mid-1' }
    )
}

Describe 'Convert-DetailRecord' {
    It 'returns null for an unusable payload' {
        (Convert-DetailRecord -Data $null) | Should BeNullOrEmpty
        (Convert-DetailRecord -Data ([pscustomobject]@{ NoView = 1 })) | Should BeNullOrEmpty
    }

    It 'deduplicates tags and keeps the bgm tag' {
        $r = Convert-DetailRecord -Data $detailFixture
        @($r.tags).Count | Should Be 2
        $r.tags[0] | Should Be 'anime'
        $r.song | Should Be 'bgm song'
        $r.music_id | Should Be 'mid-1'
    }

    It 'falls back from tname to tname_v2 and keeps both tids' {
        $r = Convert-DetailRecord -Data $detailFixture
        $r.tname | Should Be 'anime'
        $r.tid | Should Be 1
        $r.tid_v2 | Should Be 1002
    }

    It 'keeps the video identity and counters' {
        $r = Convert-DetailRecord -Data $detailFixture
        $r.bvid | Should Be 'BV1fixture'
        $r.owner | Should Be 'fixture up'
        $r.owner_mid | Should Be 42
        $r.width | Should Be 1920
        $r.view | Should Be 10
        $r.share | Should Be 7
    }

    It 'uses the positional bvid when View.bvid is empty' {
        $data = [pscustomobject]@{
            View = [pscustomobject]@{ bvid = ''; title = 'x'; stat = [pscustomobject]@{} }
            Tags = @()
        }
        $r = Convert-DetailRecord -Data $data -Bvid 'BV1passed'
        $r.bvid | Should Be 'BV1passed'
        @($r.tags).Count | Should Be 0
    }
}

# --------------------------------------------------------------- folders.ps1

function New-Cfg {
    param($Plan = $null, $Weights = $null, $Low = $null)
    $c = [pscustomobject]@{}
    if ($null -ne $Plan) { $c | Add-Member -NotePropertyName FavFolderPlan -NotePropertyValue $Plan -Force }
    if ($null -ne $Weights) { $c | Add-Member -NotePropertyName FolderWeight -NotePropertyValue $Weights -Force }
    if ($null -ne $Low) { $c | Add-Member -NotePropertyName LowPriorityFolders -NotePropertyValue $Low -Force }
    return $c
}

Describe 'Favorite folder plan' {
    It 'honours an explicit plan level' {
        $cfg = New-Cfg -Plan @(
            [pscustomobject]@{ name = 'mw'; level = 'skip' },
            [pscustomobject]@{ name = 'core'; level = 'daily' }
        )
        (Get-FavPlanLevel -Cfg $cfg -Name 'mw') | Should Be 'skip'
        (Get-FavPlanLevel -Cfg $cfg -Name 'core') | Should Be 'daily'
    }

    It 'defaults unlisted folders to full when a plan exists' {
        $cfg = New-Cfg -Plan @([pscustomobject]@{ name = 'mw'; level = 'skip' })
        (Get-FavPlanLevel -Cfg $cfg -Name 'brand new') | Should Be 'full'
    }

    It 'falls back to full for an unknown level value' {
        $cfg = New-Cfg -Plan @([pscustomobject]@{ name = 'x'; level = 'bogus' })
        (Get-FavPlanLevel -Cfg $cfg -Name 'x') | Should Be 'full'
    }

    It 'orders folders by plan position' {
        $cfg = New-Cfg -Plan @(
            [pscustomobject]@{ name = 'a'; level = 'full' },
            [pscustomobject]@{ name = 'b'; level = 'full' }
        )
        (Get-FavPlanRank -Cfg $cfg -Name 'a') | Should Be 0
        (Get-FavPlanRank -Cfg $cfg -Name 'b') | Should Be 1
        (Get-FavPlanRank -Cfg $cfg -Name 'z') | Should Be -1
    }

    It 'applies legacy weight rules only when no plan exists' {
        $weights = @(
            [pscustomobject]@{ match = '*'; weight = 1 },
            [pscustomobject]@{ match = 'core'; weight = 3 }
        )
        # No FolderWeight at all: the legacy LowPriorityFolders list applies.
        $legacy = New-Cfg -Low @('friends')
        (Get-FavPlanLevel -Cfg $legacy -Name 'friends5') | Should Be 'skip'
        (Get-FavPlanLevel -Cfg $legacy -Name 'core') | Should Be 'full'

        # A wildcard FolderWeight rule matches everything, so per the documented
        # precedence the legacy list is not consulted for that folder.
        $weighted = New-Cfg -Weights $weights -Low @('friends')
        (Get-FavPlanLevel -Cfg $weighted -Name 'friends5') | Should Be 'full'
        (Get-FolderWeight -Cfg $weighted -Name 'core') | Should Be 3

        # With an explicit plan the legacy list must not silently skip folders.
        $planned = New-Cfg -Plan @([pscustomobject]@{ name = 'mw'; level = 'full' }) -Low @('friends')
        (Get-FavPlanLevel -Cfg $planned -Name 'friends5') | Should Be 'full'
    }

    It 'treats a missing config as normal weight' {
        (Get-FavPlanLevel -Cfg $null -Name 'x') | Should Be 'full'
        (Get-FolderWeight -Cfg $null -Name 'x') | Should Be 1
    }
}
