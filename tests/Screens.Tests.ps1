BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    BeforeAll {
        . (Join-Path $script:ModuleRoot 'tests/TestHelpers.ps1')
        $script:View = New-TestView
        $script:B = Read-MbcBaseline -Path (Join-Path $script:ModuleRoot 'tests/fixtures/baseline-minimal.json')
        $script:B.SealState = 'Sealed'
        $script:Conn = [pscustomobject]@{
            TenantId = '00000000-0000-4000-8000-000000000001'; TenantName = 'Example Ltd'; Domain = 'example.com'; Account = 'operator@example.com'
            Sessions = [ordered]@{ exo = 'tmpEXO_x' }; Failed = [ordered]@{}; Disclosure = @()
        }
        function script:Key([string] $Name, [string] $Char) { [pscustomobject]@{ Name = $Name; Char = $(if ($Char) { [char]$Char } else { $null }) } }
        function script:New-State([string] $Screen = 'home') {
            $s = New-MbcTuiState
            $s.Baseline = $script:B
            $s.Connection = $script:Conn
            $s.View = $script:View
            $s.Screen = $Screen
            $s
        }
        $script:Cap = New-MbcCapability -Width 100 -Height 30 -Unicode $true
    }

    Describe 'Keys' {
        It 'maps keys to actions on the home screen' {
            $s = New-MbcTuiState
            Resolve-MbcKeyAction -State $s -Key (Key 'DownArrow') | Should -Be 'down'
            Resolve-MbcKeyAction -State $s -Key (Key 'Char' 'j') | Should -Be 'down'
            Resolve-MbcKeyAction -State $s -Key (Key 'Char' 'r') | Should -Be 'run'
            Resolve-MbcKeyAction -State $s -Key (Key 'Char' 'i') | Should -Be 'apps'
            Resolve-MbcKeyAction -State $s -Key (Key 'Char' '?') | Should -Be 'help'
            Resolve-MbcKeyAction -State $s -Key (Key 'Char' 'q') | Should -Be 'quit'
            Resolve-MbcKeyAction -State $s -Key (Key 'Char' 'R') | Should -Be 'none'
        }
        It 'closes the help overlay on any key' {
            $s = New-MbcTuiState
            $s.Help = $true
            Resolve-MbcKeyAction -State $s -Key (Key 'Char' 'x') | Should -Be 'closeHelp'
        }
        It 'maps the results keys of the spec' {
            $s = New-State 'results'
            foreach ($pair in @(@('f', 'filterFail'), @('e', 'filterError'), @('a', 'filterAll'), @('/', 'search'), @('x', 'export'), @('i', 'apps'), @('r', 'run'), @('b', 'chooseBaseline'))) {
                Resolve-MbcKeyAction -State $s -Key (Key 'Char' $pair[0]) | Should -Be $pair[1]
            }
            Resolve-MbcKeyAction -State $s -Key (Key 'PageDown') | Should -Be 'pageDown'
            Resolve-MbcKeyAction -State $s -Key (Key 'Home') | Should -Be 'first'
        }
    }

    Describe 'Navigation' {
        It 'moves through the home menu, wrapping, and turns Enter into the item''s effect' {
            $s = New-MbcTuiState
            Invoke-MbcTuiNavigation -State $s -Action 'up' -Cap $script:Cap | Should -BeNullOrEmpty
            $s.MenuIndex | Should -Be ((Get-MbcHomeMenu -State $s).Count - 1)
            Invoke-MbcTuiNavigation -State $s -Action 'select' -Cap $script:Cap | Should -Be 'quit'
            $s.MenuIndex = 0
            Invoke-MbcTuiNavigation -State $s -Action 'select' -Cap $script:Cap | Should -Be 'run'
        }
        It 'toggles the app inventory from the home screen' {
            $s = New-MbcTuiState
            Invoke-MbcTuiNavigation -State $s -Action 'toggleInventory' -Cap $script:Cap | Should -BeNullOrEmpty
            $s.IncludeInventory | Should -BeFalse
            ((Get-MbcHomeMenu -State $s) | Where-Object Action -eq 'toggleInventory').Label | Should -BeLike '*: off'
        }
        It 'says there are no results or inventory yet, rather than showing an empty screen' {
            $s = New-MbcTuiState
            Invoke-MbcTuiNavigation -State $s -Action 'lastResults' -Cap $script:Cap | Out-Null
            $s.Message | Should -BeLike 'No results yet*'
            Invoke-MbcTuiNavigation -State $s -Action 'apps' -Cap $script:Cap | Out-Null
            $s.Message | Should -BeLike 'No inventory yet*'
            $s.Screen | Should -Be 'home'
        }
        It 'expands and collapses an area with Enter on its heading' {
            $s = New-State 'results'
            (Get-MbcTuiRows -State $s).Count | Should -Be 4
            Invoke-MbcTuiNavigation -State $s -Action 'select' -Cap $script:Cap | Out-Null
            $s.Expanded.ContainsKey('entra') | Should -BeTrue
            @((Get-MbcTuiRows -State $s) | Where-Object { $_.Result -and $_.Group.Area -eq 'entra' }).Count | Should -Be 2
            Invoke-MbcTuiNavigation -State $s -Action 'select' -Cap $script:Cap | Out-Null
            $s.Expanded.ContainsKey('entra') | Should -BeFalse
        }
        It 'opens a check with Enter, and steps to the next check, skipping headings' {
            $s = New-State 'results'
            Invoke-MbcTuiNavigation -State $s -Action 'down' -Cap $script:Cap | Out-Null
            Invoke-MbcTuiNavigation -State $s -Action 'select' -Cap $script:Cap | Out-Null
            $s.Screen | Should -Be 'detail'
            $s.Detail.Id | Should -Be 'ORG-001'
            Invoke-MbcTuiNavigation -State $s -Action 'down' -Cap $script:Cap | Out-Null
            $s.Detail.Id | Should -Be 'EXO-001'
            Invoke-MbcTuiNavigation -State $s -Action 'back' -Cap $script:Cap | Out-Null
            $s.Screen | Should -Be 'results'
        }
        It 'switches filters, and a second press returns to the default' {
            $s = New-State 'results'
            Invoke-MbcTuiNavigation -State $s -Action 'filterFail' -Cap $script:Cap | Out-Null
            $s.Filter | Should -Be 'fail'
            Invoke-MbcTuiNavigation -State $s -Action 'filterFail' -Cap $script:Cap | Out-Null
            $s.Filter | Should -Be 'attention'
        }
        It 'passes effects it cannot handle to the runtime' {
            $s = New-State 'results'
            Invoke-MbcTuiNavigation -State $s -Action 'export' -Cap $script:Cap | Should -Be 'export'
            Invoke-MbcTuiNavigation -State $s -Action 'search' -Cap $script:Cap | Should -Be 'search'
        }
        It 'opens the apps screen and an app' {
            $s = New-State 'results'
            Invoke-MbcTuiNavigation -State $s -Action 'apps' -Cap $script:Cap | Out-Null
            $s.Screen | Should -Be 'apps'
            Invoke-MbcTuiNavigation -State $s -Action 'select' -Cap $script:Cap | Out-Null
            $s.Screen | Should -Be 'appDetail'
            $s.AppDetail.DisplayName | Should -Be 'Example Scheduler'
        }
    }

    Describe 'Frames' {
        BeforeAll {
            function script:Get-AllScreenStates {
                foreach ($screen in 'home', 'build', 'run', 'results', 'detail', 'apps', 'appDetail', 'chooser', 'prompt', 'panel') {
                    $s = New-State $screen
                    $s.Live = @{ Done = 1; Total = 3; Label = 'GET v1.0 /identity/conditionalAccess/policies'; Phase = 'checks'; Waiting = 0; Lines = [System.Collections.Generic.List[object]]::new(@($script:View.Results)) }
                    $s.Detail = $script:View.Results[0]
                    $s.AppDetail = $script:View.Inventory.ThirdParty[0]
                    $s.Panel = @{ Title = 'A panel'; Lines = @('', '  A panel line.') }
                    $s.Prompt = @{ Title = 'Filter'; Label = 'Show checks whose ID, setting or location contains'; Mask = $false; Value = 'mfa' }
                    $s.Files = @('C:\baselines\first.json', 'C:\baselines\second.json')
                    $s.ChooserTitle = 'Choose a baseline'
                    $s.Message = 'A message that is long enough to need cutting at narrow widths, which it will be.'
                    $s
                }
            }
        }
        It 'fills the screen exactly and never overflows, at <W>x<H>, Unicode <U>, colour <C>' -ForEach @(
            @{ W = 40; H = 12; U = $true; C = $true }, @{ W = 60; H = 20; U = $true; C = $false }, @{ W = 120; H = 40; U = $true; C = $true }, @{ W = 60; H = 20; U = $false; C = $false }
        ) {
            $cap = New-MbcCapability -Width $W -Height $H -Unicode $U -Color $C
            foreach ($s in (Get-AllScreenStates)) {
                foreach ($help in $false, $true) {
                    $s.Help = $help
                    $frame = Format-MbcFrame -State $s -Cap $cap
                    $frame.Count | Should -Be $H -Because "$($s.Screen) (help $help) fills the screen"
                    foreach ($line in $frame) { Measure-MbcWidth $line | Should -BeLessOrEqual $W -Because "$($s.Screen) (help $help) fits the width" }
                }
            }
        }
        It 'uses no characters above ASCII in ASCII mode' {
            $cap = New-MbcCapability -Width 80 -Height 24 -Unicode $false
            foreach ($s in (Get-AllScreenStates)) {
                $text = Remove-MbcAnsi ((Format-MbcFrame -State $s -Cap $cap) -join "`n")
                foreach ($ch in $text.ToCharArray()) { [int]$ch | Should -BeLessThan 128 -Because "$($s.Screen) must be plain ASCII" }
            }
        }
        It 'shows tenant, sessions and baseline identity in the home header' {
            $text = (Format-MbcFrame -State (New-State 'home') -Cap $script:Cap) -join "`n"
            $text | Should -BeLike '*Example Ltd · example.com*'
            $text | Should -BeLike '*Graph · Exchange Online*'
            $text | Should -BeLike "*$($script:B.Fingerprint)*sealed ✓*"
        }
        It 'groups results with counts, shows only what needs attention, and collapses met areas' {
            $text = (Format-MbcFrame -State (New-State 'results') -Cap $script:Cap) -join "`n"
            $text | Should -BeLike '*1 met, 1 not, 1 unverifiable*Showing: needs attention*'
            $text | Should -BeLike '*▿ Entra  1 met · 1 not*✗ Not met*Users can register applications*Yes → No*'
            $text | Should -BeLike '*? Unverifiable*Mailbox auditing on by default*not connected*'
            $text | Should -Not -BeLike '*At least one Conditional Access policy is on*'
        }
        It 'shows where, expected, actual, what was read and why on the detail screen' {
            $s = New-State 'detail'
            $s.Detail = $script:View.Results[0]
            $text = (Format-MbcFrame -State $s -Cap $script:Cap) -join "`n"
            $text | Should -BeLike '*Where      Identity › Users › User settings*Expected   No*Actual     Yes*Read       GET v1.0 /policies/authorizationPolicy*Why*'
        }
        It 'lists apps with publisher, verification and a consent summary' {
            $text = (Format-MbcFrame -State (New-State 'apps') -Cap $script:Cap) -join "`n"
            $text | Should -BeLike '*Example Scheduler*Example Software Ltd*✓ yes*2 admin · 2 app*'
            $text | Should -BeLike '*Sample Notes*2 user (2 people)*'
        }
        It 'shows the spinner, the bar and the request on the run screen' {
            $s = New-State 'run'
            $s.Live = @{ Done = 1; Total = 3; Label = 'GET v1.0 /identity/conditionalAccess/policies'; Phase = 'checks'; Waiting = 0; Lines = [System.Collections.Generic.List[object]]::new() }
            $text = (Format-MbcFrame -State $s -Cap $script:Cap) -join "`n"
            $text | Should -BeLike '*Checking Fixture baseline v1 against Example Ltd*1 of 3*⠋ GET v1.0 /identity/conditionalAccess/policies*'
            $s.Live.Waiting = 12
            (Format-MbcFrame -State $s -Cap $script:Cap) -join "`n" | Should -BeLike '*Graph asked for a pause: waiting 12 s*'
        }
        It 'always shows the keys for the current screen in the footer' {
            (Format-MbcFrame -State (New-MbcTuiState) -Cap $script:Cap)[-1] | Should -BeLike '*q quit*'
            (Format-MbcFrame -State (New-State 'results') -Cap $script:Cap)[-1] | Should -BeLike '*f not met*'
        }
        It 'draws the help overlay listing this screen''s keys' {
            $s = New-State 'results'
            $s.Help = $true
            (Format-MbcFrame -State $s -Cap $script:Cap) -join "`n" | Should -BeLike '*Keys on this screen*Show only checks not met*'
        }
        It 'shows the selection without colour, as NO_COLOR asks' {
            $s = New-State 'results'
            $s.ResultIndex = 1
            $frame = Format-MbcFrame -State $s -Cap (New-MbcCapability -Width 100 -Height 30 -Unicode $true -Color $false)
            @($frame | Where-Object { $_.StartsWith('▸') }).Count | Should -Be 1
            ($frame | Where-Object { $_.StartsWith('▸') }) | Should -BeLike '*Users can register applications*'
        }
        It 'gives advice for every cause in the vocabulary' {
            foreach ($cause in $script:MbcCauses) { $script:MbcCauseAdvice.ContainsKey($cause) | Should -BeTrue -Because "'$cause' needs advice" }
        }
        It 'reveals the sealed flourish, then settles' {
            $s = New-State 'home'
            $s.Flourish = 8
            (Get-MbcSealNote -State $s -Glyphs (Get-MbcGlyphs -Unicode $true) -Color $false).Trim() | Should -Be 's'
            $s.Flourish = 0
            Get-MbcSealNote -State $s -Glyphs (Get-MbcGlyphs -Unicode $true) -Color $false | Should -Be 'sealed ✓'
        }
    }
}
