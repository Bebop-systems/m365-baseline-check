BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Keys' {
        It 'turns console keys into named keys and characters' {
            (ConvertTo-MbcKey -KeyInfo ([ConsoleKeyInfo]::new([char]0, [ConsoleKey]::UpArrow, $false, $false, $false))).Name | Should -Be 'UpArrow'
            $j = ConvertTo-MbcKey -KeyInfo ([ConsoleKeyInfo]::new([char]'j', [ConsoleKey]::J, $false, $false, $false))
            $j.Name | Should -Be 'Char'
            $j.Char | Should -Be ([char]'j')
            (ConvertTo-MbcKey -KeyInfo ([ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true))).Name | Should -Be 'CtrlC'
        }
    }

    Describe 'A scripted session through the real loop' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            $script:Bodies = @{
                '/policies/authorizationPolicy'        = ConvertFrom-MbcJson -Json '{"defaultUserRolePermissions":{"allowedToCreateApps":true}}'
                '/identity/conditionalAccess/policies' = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/conditionalAccessPolicies.json')))
            }
            $invData = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'inventory/tenant.json')))
            $script:Seams = @{
                Fetch      = {
                    param($Item, $OnTick, $OnWait)
                    if ($script:Bodies.ContainsKey($Item.Request)) { return (New-MbcFetchResult -Ok $true -Body $script:Bodies[$Item.Request] -Status 200) }
                    New-MbcFetchResult -Ok $false -Cause 'not connected' -Detail "There's no exo session."
                }
                Connection = [pscustomobject]@{
                    TenantId = '00000000-0000-4000-8000-000000000001'; TenantName = 'Example Ltd'; Domain = 'example.com'; Account = 'operator@example.com'
                    Sessions = [ordered]@{}; Failed = [ordered]@{ exo = 'User canceled authentication.' }; Disclosure = @('Read-only by construction: GET-only Graph, Get- cmdlets only.')
                }
                Inventory  = {
                    param($OnProgress)
                    $get = {
                        param($Request)
                        $q = $Request.IndexOf('?')
                        $path = if ($q -ge 0) { $Request.Substring(0, $q) } else { $Request }
                        if ($invData.Contains($path)) { return (New-MbcFetchResult -Ok $true -Body $invData[$path] -Status 200) }
                        New-MbcFetchResult -Ok $false -Status 404 -Cause 'not found'
                    }
                    ConvertTo-MbcAppInventory -Data (Get-MbcAppInventoryData -Get $get -TenantId '00000000-0000-4000-8000-000000000001' -OnProgress $OnProgress) -TenantId '00000000-0000-4000-8000-000000000001'
                }
            }
            function script:K([string] $Spec) {
                # 'r' is a character; '<Enter>' and friends are named keys.
                if ($Spec.StartsWith('<')) { return [pscustomobject]@{ Name = $Spec.Trim('<', '>'); Char = $null } }
                [pscustomobject]@{ Name = 'Char'; Char = [char]$Spec }
            }
            function script:Start-Session([string[]] $Keys, [switch] $NoBaseline) {
                $script:MbcKeyQueue = [System.Collections.Generic.Queue[object]]::new()
                foreach ($k in $Keys) {
                    if ($k.StartsWith('<') -or $k.Length -eq 1) { $script:MbcKeyQueue.Enqueue((K $k)) }
                    else { foreach ($ch in $k.ToCharArray()) { $script:MbcKeyQueue.Enqueue((K ([string]$ch))) } }
                }
                $state = New-MbcTuiState -OutputRoot (Get-MbcOutputRoot -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))))
                $state.Seams = $script:Seams
                $state.AllowUnsealed = $true
                if (-not $NoBaseline) { Set-MbcTuiBaseline -State $state -Path (Join-Path $script:Fx 'baseline-minimal.json') }
                try { Invoke-MbcTuiLoop -State $state }
                finally { $script:MbcKeyQueue = $null }
                return $state
            }
        }
        BeforeEach {
            $script:Frames = [System.Collections.Generic.List[string]]::new()
            Mock Get-MbcTerminalCapability { New-MbcCapability -Width 100 -Height 30 -Unicode $true -Interactive $true }
            Mock Write-MbcFrame { $script:Frames.Add(($Lines -join "`n")) }
            $script:MbcSessionKey = $null
        }
        AfterEach { $script:MbcSessionKey = $null }

        It 'runs, streams results, lands on grouped results, and quits after confirming' {
            $s = Start-Session @('r', 'q', 'y', '<Enter>')
            $s.Quit | Should -BeTrue
            $s.View.Counts.Fail | Should -Be 1
            $s.View.Counts.Error | Should -Be 1
            @($script:Frames | Where-Object { $_ -like '*Checking Fixture baseline v1 against Example Ltd*' }).Count | Should -BeGreaterThan 1
            @($script:Frames | Where-Object { $_ -like '*M365 Baseline Check · Results*' } | Select-Object -First 1) | Should -BeLike '*Done. 1 met, 1 not, 1 unverifiable. x exports it.*'
            @($script:Frames | Where-Object { $_ -like "*results haven't been exported*" }).Count | Should -BeGreaterThan 0
        }

        It 'stays when the quit is not confirmed' {
            $s = Start-Session @('r', 'q', '<Enter>')
            # The queue runs dry after this, which reads as Ctrl+C: a second quit prompt, then out.
            @($script:Frames | Where-Object { $_ -like '*Still here. x exports the results.*' }).Count | Should -BeGreaterThan 0
        }

        It 'refuses to run without a baseline, and says why' {
            $s = Start-Session @('r', '<Escape>') -NoBaseline
            @($script:Frames | Where-Object { $_ -like '*Choose a baseline first: press b.*' }).Count | Should -BeGreaterThan 0
            $s.View | Should -BeNullOrEmpty
        }

        It 'abandons a run on Esc, between requests, and keeps nothing' {
            $s = Start-Session @('r', '<Escape>', '<Escape>')
            $s.View | Should -BeNullOrEmpty
            @($script:Frames | Where-Object { $_ -like '*Abandoned. Nothing from that run was kept*' }).Count | Should -BeGreaterThan 0
        }

        It 'shows the app inventory and an app''s consents' {
            Start-Session @('r', 'i', '<Enter>', '<Escape>', '<Escape>', 'q', 'y', '<Enter>') | Out-Null
            @($script:Frames | Where-Object { $_ -like '*M365 Baseline Check · App inventory*' } | Select-Object -Last 1) | Should -BeLike '*Example Scheduler*Example Software Ltd*'
            @($script:Frames | Where-Object { $_ -like '*M365 Baseline Check · App*Delegated, admin consent for all users*' }).Count | Should -BeGreaterThan 0
        }

        It 'exports locked with a typed key, then opens the locked file again with the session key' {
            $key = New-MbcTeamKeyText
            $s = Start-Session @('r', 'x', $key, '<Enter>', '<Escape>', 'o', '<Enter>', 'q')
            $results = Join-Path $s.OutputRoot 'results'
            @(Get-ChildItem $results -Filter '*.locked').Count | Should -Be 1
            @(Get-ChildItem $results -Filter 'summary-*.md').Count | Should -Be 1
            @($script:Frames | Where-Object { $_ -like '*Team key, to lock the export*' } | Select-Object -Last 1) | Should -Not -BeLike "*$($key.Substring(12))*" -Because 'a masked prompt never shows the key'
            $s.ViewFromFile | Should -BeTrue
            $s.Quit | Should -BeTrue -Because 'a result opened from a file needs no export before quitting'
        }

        It 'refuses a mistyped key at export and writes nothing' {
            $s = Start-Session @('r', 'x', 'mbc-key:1:nope', '<Enter>', 'q', 'y', '<Enter>')
            @(Get-ChildItem (Join-Path $s.OutputRoot 'results')).Count | Should -Be 0
            @($script:Frames | Where-Object { $_ -like "*isn't a team key*" }).Count | Should -BeGreaterThan 0
        }

        It 'shows a new team key once, on a panel' {
            Start-Session @('s', 'n', '<Enter>', '<Escape>', 'q') | Out-Null
            @($script:Frames | Where-Object { $_ -like '*New team key*mbc-key:1:*password manager*' }).Count | Should -BeGreaterThan 0
        }

        It 'filters results by text through the prompt' {
            $s = Start-Session @('r', '/', 'conditional', '<Enter>', 'a', 'q', 'y', '<Enter>')
            $s.Search | Should -Be 'conditional'
        }
    }

    Describe 'Start-BaselineCheck outside an interactive console' {
        BeforeEach { Mock Get-MbcTerminalCapability { New-MbcCapability -Interactive $false } }
        It 'runs in plain mode when given a baseline' {
            Mock Invoke-BaselineCheck { 'plain run' }
            Start-BaselineCheck -Baseline 'x.json' -WarningAction SilentlyContinue | Should -Be 'plain run'
        }
        It 'explains itself when there is nothing to run' {
            { Start-BaselineCheck } | Should -Throw "*can't host the interactive view*"
        }
    }
}
