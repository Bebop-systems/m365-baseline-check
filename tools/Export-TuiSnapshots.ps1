#Requires -Version 7.4
<#
.SYNOPSIS
    Renders each TUI screen, from a run against the synthetic demo tenant, as plain text under
    docs/tui-snapshots, with an example report.txt and summary.md. For reviewing the look without a console.
#>
[CmdletBinding()]
param([int] $Width = 100, [int] $Height = 32)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'M365BaselineCheck.psd1') -Force
$out = Join-Path $root 'docs/tui-snapshots'
New-Item -ItemType Directory -Path $out -Force | Out-Null

try {
    & (Get-Module M365BaselineCheck) {
        param($Root, $Out, $Width, $Height)
        . (Join-Path $Root 'tools/DemoTenant.ps1')
        $seams = Initialize-MbcDemoTenant -Root $Root -Fast
        $baseline = Read-MbcBaseline -Path $seams.Baseline
        $demoFetch = $seams.Fetch
        $run = Invoke-MbcRun -Baseline $baseline -Fetch { param($Item) & $demoFetch $Item $null $null } -Inventory $seams.Inventory -RunId '20260926T141200Z-d3m0aa'
        $document = New-MbcResultDocument -Run $run -Baseline $baseline -Connection $seams.Connection
        $view = ConvertFrom-MbcResultDocument -Document $document
        $utf8 = [System.Text.UTF8Encoding]::new($false)

        $new = {
            $s = New-MbcTuiState -OutputRoot $Root
            $s.Baseline = $baseline
            $s.Connection = $seams.Connection
            $s.View = $view
            $s.ViewSource = 'this run'
            $s
        }
        $rows = { param($s) Get-MbcTuiRows -State $s }
        $scenes = [ordered]@{
            '01-home-signed-out'   = { param($s) $s.Connection = $null; $s.View = $null; $s.Message = 'Chose Example tenant hygiene v1, fingerprint 166cee0ba798. Sealed and unchanged.'; $s.MessageStyle = 'ok' }
            '02-home'              = { param($s) $s.MenuIndex = 0 }
            '03-run'               = { param($s)
                $s.Screen = 'run'; $s.Tick = 3
                $s.Live = @{ Done = 9; Total = 14; Label = "Get-MalwareFilterPolicy -Identity 'Default'"; Phase = 'checks'; Waiting = 0; Lines = [System.Collections.Generic.List[object]]::new(@($view.Results | Select-Object -First 12)) }
            }
            '04-run-throttled'     = { param($s)
                $s.Screen = 'run'; $s.Tick = 6
                $s.Live = @{ Done = 3; Total = 14; Label = 'GET v1.0 /identity/conditionalAccess/policies'; Phase = 'checks'; Waiting = 2; Lines = [System.Collections.Generic.List[object]]::new(@($view.Results | Select-Object -First 5)) }
            }
            '05-results'           = { param($s) Open-MbcTuiResults -State $s; $s.Message = 'Done. 13 met, 5 not, 2 unverifiable. x exports it.' }
            '06-results-selected'  = { param($s) Open-MbcTuiResults -State $s; $s.ResultIndex = 2 }
            '07-results-expanded'  = { param($s) Open-MbcTuiResults -State $s; $s.Expanded['exchange'] = $true; $s.ResultIndex = @(& $rows $s | ForEach-Object { $_.Group.Area }).IndexOf('exchange') }
            '08-results-all'       = { param($s) Open-MbcTuiResults -State $s; $s.Filter = 'all' }
            '09-detail-not-met'    = { param($s) Open-MbcTuiResults -State $s; $s.Screen = 'detail'; $s.Detail = $view.Results | Where-Object Id -eq 'ENTRA-004' }
            '10-detail-unverified' = { param($s) Open-MbcTuiResults -State $s; $s.Screen = 'detail'; $s.Detail = $view.Results | Where-Object Id -eq 'PUR-002' }
            '11-apps'              = { param($s) Open-MbcTuiResults -State $s; $s.Screen = 'apps'; $s.AppIndex = 1 }
            '12-app-detail'        = { param($s) Open-MbcTuiResults -State $s; $s.Screen = 'appDetail'; $s.AppDetail = $view.Inventory.ThirdParty | Where-Object DisplayName -eq 'Handy PDF Signer' }
            '13-help-results'      = { param($s) Open-MbcTuiResults -State $s; $s.Help = $true }
            '14-choose-baseline'   = { param($s) $s.Screen = 'chooser'; $s.ChooserTitle = 'Choose a baseline'; $s.Files = @('~/M365BaselineCheck/baselines/core-tenant.json', '~/M365BaselineCheck/baselines/core-tenant-v4-draft.json', 'presets/example-tenant-hygiene.baseline.json') }
            '15-export-prompt'     = { param($s) $s.Screen = 'prompt'; $s.Prompt = @{ Title = 'Export'; Label = 'Team key, to lock the export. Leave it empty to write plaintext instead.'; Mask = $true; Value = 'mbc-key:1:3f2a9c1e:abcdefgh' } }
            '16-build'             = { param($s) $s.Screen = 'build' }
        }
        $cap = New-MbcCapability -Width $Width -Height $Height -Unicode $true
        foreach ($name in $scenes.Keys) {
            $s = & $new
            & $scenes[$name] $s
            $frame = @((Format-MbcFrame -State $s -Cap $cap) | ForEach-Object { (Remove-MbcAnsi $_).TrimEnd() })
            [System.IO.File]::WriteAllText((Join-Path $Out "$name.txt"), (($frame -join "`n") + "`n"), $utf8)
        }
        # The same results screen in ASCII, and narrow.
        $s = & $new; Open-MbcTuiResults -State $s
        $frame = @((Format-MbcFrame -State $s -Cap (New-MbcCapability -Width 72 -Height 24 -Unicode $false)) | ForEach-Object { (Remove-MbcAnsi $_).TrimEnd() })
        [System.IO.File]::WriteAllText((Join-Path $Out '17-results-ascii-72.txt'), (($frame -join "`n") + "`n"), $utf8)
        $s = & $new
        $frame = @((Format-MbcFrame -State $s -Cap (New-MbcCapability -Width 50 -Height 20 -Unicode $true)) | ForEach-Object { (Remove-MbcAnsi $_).TrimEnd() })
        [System.IO.File]::WriteAllText((Join-Path $Out '18-home-50.txt'), (($frame -join "`n") + "`n"), $utf8)

        [System.IO.File]::WriteAllText((Join-Path $Out 'example-report.txt'), (ConvertTo-MbcTextReport -View $view), $utf8)
        [System.IO.File]::WriteAllText((Join-Path $Out 'example-summary.md'), (ConvertTo-MbcSummaryMarkdown -View $view), $utf8)
    } $root $out $Width $Height
}
finally {
    Remove-Module tmpEXO_demo -Force -ErrorAction SilentlyContinue
}
Write-Output "Snapshots written to $out"
