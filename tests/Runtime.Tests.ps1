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
            @($script:Frames | Where-Object { $_ -like '*Choose a baseline first: b. To make your own, s.*' }).Count | Should -BeGreaterThan 0
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
            @(Get-ChildItem (Join-Path $s.OutputRoot 'logs') -File).Count | Should -Be 0 -Because 'the locked export carried the run log away'
            $s.PlaintextLogs.Count | Should -Be 0
            @($script:Frames | Where-Object { $_ -like '*Exported, run log locked inside and its plaintext deleted: result-*' }).Count | Should -BeGreaterThan 0
        }

        It 'exports a run locked once: a second x replaces nothing and the log stays in the bundle' {
            $key = New-MbcTeamKeyText
            $s = Start-Session @('r', 'x', $key, '<Enter>', 'x', 'q')
            $locked = @(Get-ChildItem (Join-Path $s.OutputRoot 'results') -Filter '*.locked')
            $locked.Count | Should -Be 1
            (Open-MbcLockedResult -Path $locked[0].FullName -KeyText $key).Files['run.jsonl'] | Should -BeLike '*"event":"run.end"*'
            @($script:Frames | Where-Object { $_ -like '*Already exported, locked, as result-*Nothing written.*' }).Count | Should -BeGreaterThan 0
        }

        It 'keeps the run log, and counts it, when the export is plaintext' {
            $s = Start-Session @('r', 'x', '<Enter>', 'yes', '<Enter>', 'q')
            @(Get-ChildItem (Join-Path $s.OutputRoot 'logs') -File).Count | Should -Be 1
            $s.PlaintextLogs.Count | Should -Be 1
            @($script:Frames | Where-Object { $_ -like '*Write all five parts as plaintext*docs/handling-results.md*' }).Count | Should -BeGreaterThan 0
        }

        It 'counts the requests it will make, so the bar moves in steps' {
            Start-Session @('r', 'q', 'y', '<Enter>') | Out-Null
            @($script:Frames | Where-Object { $_ -like '*1 of 3*' }).Count | Should -BeGreaterThan 0
            @($script:Frames | Where-Object { $_ -like '* of 1*' }).Count | Should -Be 0
        }

        It 'asks for the right key when a held key belongs to another file' {
            $keyA = New-MbcTeamKeyText
            $keyB = New-MbcTeamKeyText
            $first = Start-Session @('r', 'x', $keyB, '<Enter>', 'q')
            $locked = @(Get-ChildItem (Join-Path $first.OutputRoot 'results') -Filter '*.locked')[0].FullName
            $script:MbcSessionKey = $keyA
            $script:MbcKeyQueue = [System.Collections.Generic.Queue[object]]::new()
            foreach ($ch in $keyB.ToCharArray()) { $script:MbcKeyQueue.Enqueue((K ([string]$ch))) }
            $script:MbcKeyQueue.Enqueue((K '<Enter>'))
            $state = New-MbcTuiState -OutputRoot $first.OutputRoot
            try { Open-MbcTuiLocked -State $state -Path $locked }
            finally { $script:MbcKeyQueue = $null }
            $state.ViewFromFile | Should -BeTrue
            $script:MbcSessionKey | Should -Be $keyB
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

        It 'drafts a baseline from a chosen preset, suggests where to put it, and chooses the draft' {
            $s = Start-Session @('s', 'd', '<Enter>', '<Enter>', '<Escape>', '<Escape>', 'q') -NoBaseline
            $draft = Join-Path $s.OutputRoot 'baselines/example-tenant-hygiene.baseline.json'
            Test-Path $draft | Should -BeTrue
            # This seam reads few of the example's requests, so most values are left to fill in by hand:
            # the incomplete draft is written, listed by reason, and not chosen, since it can't run.
            $s.Baseline | Should -BeNullOrEmpty
            $panel = @($script:Frames | Where-Object { $_ -like '*Draft written*' })[-1]
            $panel | Should -BeLike '*Left for you to fill in by hand, * checks:*not connected*EXO-001*PUR-002*'
            $panel | Should -BeLike '*s seals it. Sealing names anything still missing.*'
        }

        It 'offers the new draft for sealing, and lists everything still missing when it can''t be sealed' {
            $s = Start-Session @('s', 'd', '<Enter>', '<Enter>', '<Escape>', 's', '<Enter>', '<Escape>', '<Escape>', 'q') -NoBaseline
            $draft = Join-Path $s.OutputRoot 'baselines/example-tenant-hygiene.baseline.json'
            @($script:Frames | Where-Object { $_ -like '*Seal a baseline*The baseline to seal*' } | Select-Object -First 1) | Should -BeLike "*$([System.IO.Path]::GetFileName($draft))*" -Because 'the draft just written is suggested'
            $panel = @($script:Frames | Where-Object { $_ -like '*Not sealed*' })[-1]
            $panel | Should -BeLike '*Fix these in the file, then seal it again*has no expected value*'
            $s.LastDraft | Should -Be $draft -Because 'an unsealed draft stays the one to offer'
        }

        It 'seals the suggested draft and makes it the chosen baseline' {
            $state = New-MbcTuiState -OutputRoot (Get-MbcOutputRoot -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))))
            $state.Seams = $script:Seams
            Set-MbcTuiBaseline -State $state -Path (Join-Path $script:Fx 'baseline-minimal.json')
            $draft = Join-Path $state.OutputRoot 'baselines/minimal-draft.json'
            Copy-Item (Join-Path $script:Fx 'baseline-minimal.json') $draft
            $state.LastDraft = $draft
            $script:MbcKeyQueue = [System.Collections.Generic.Queue[object]]::new()
            $script:MbcKeyQueue.Enqueue((K '<Enter>'))
            try { Invoke-MbcTuiEffect -State $state -Effect 'sealFile' }
            finally { $script:MbcKeyQueue = $null }
            $state.Baseline.Path | Should -Be ([System.IO.Path]::GetFullPath($draft))
            $state.Baseline.SealState | Should -Be 'Sealed'
            $state.LastDraft | Should -BeNullOrEmpty
            $state.Message | Should -BeLike '*is the chosen baseline: r runs it.*'
        }

        It 'copies the example preset under a name, for editing, and refuses to overwrite' {
            # Clears the suggested name, my-tenant, before typing another.
            $clear = @('<Backspace>') * 'my-tenant'.Length
            $s = Start-Session (@('s', 'p') + $clear + @('core-tenant', '<Enter>', '<Escape>', 'p') + $clear + @('core-tenant', '<Enter>', 'q')) -NoBaseline
            $copy = Join-Path $s.OutputRoot 'presets/core-tenant.json'
            Test-Path $copy | Should -BeTrue
            $preset = Read-MbcPreset -Path $copy
            $preset['name'] | Should -Be 'core-tenant'
            $preset['checks'].Count | Should -Be (Read-MbcPreset -Path (Join-Path $script:ModuleRoot 'presets/example-tenant-hygiene.json'))['checks'].Count
            # The panel wraps a long path rather than cutting it; joined back, the whole path is there.
            $panel = @($script:Frames | Where-Object { $_ -like '*Preset copied*lists it first*' })[-1]
            ($panel -replace '\n\s+', '') | Should -BeLike "*$copy*"
            @($script:Frames | Where-Object { $_ -like "*There's a preset called core-tenant already*" }).Count | Should -BeGreaterThan 0
            (Get-MbcPresetCandidates -State $s)[0] | Should -Be $copy -Because 'your own presets are offered first'
            Start-Session (@('s', 'p') + $clear + @('my tenant!', '<Enter>', 'q')) -NoBaseline | Out-Null
            @($script:Frames | Where-Object { $_ -like "*won't do as a file name*" }).Count | Should -BeGreaterThan 0
        }

        It 'names a preset that is not valid JSON, and where, instead of hiding it' {
            $root = Get-MbcOutputRoot -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            [System.IO.File]::WriteAllText((Join-Path $root 'presets/broken.json'), "{`n  `"name`": `"x`",`n}")
            [System.IO.File]::WriteAllText((Join-Path $root 'presets/fine.json'), '{}')
            Get-MbcUnreadableNote -Folder (Join-Path $root 'presets') | Should -BeLike "*can't be read as JSON: broken.json near line *comma after the last entry*"
            Get-MbcUnreadableNote -Folder (Join-Path $root 'baselines') | Should -BeExactly ''
        }

        It 'marks each chooser row with where the file lives' {
            $state = New-MbcTuiState -OutputRoot (Get-MbcOutputRoot -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))))
            $state.ChooserPurpose = 'baseline'
            Get-MbcChooserPlace -State $state -Path (Join-Path $state.OutputRoot 'baselines/a.json') | Should -Be 'yours'
            Get-MbcChooserPlace -State $state -Path (Join-Path $script:ModuleRoot 'presets/example-tenant-hygiene.baseline.json') | Should -Be 'example'
            $state.ChooserPurpose = 'locked'
            Get-MbcChooserPlace -State $state -Path (Join-Path $state.OutputRoot 'results/r.locked') | Should -BeExactly ''
        }

        It 'says so when a folder is given where a file is wanted' {
            Start-Session @('b', 'p', $TestDrive, '<Enter>', '<Escape>', 'q') -NoBaseline | Out-Null
            @($script:Frames | Where-Object { $_ -like '*That is a folder. Choose a file: a baseline (.json).*' }).Count | Should -BeGreaterThan 0
        }

        It 'filters results by text through the prompt' {
            $s = Start-Session @('r', '/', 'conditional', '<Enter>', 'a', 'q', 'y', '<Enter>')
            $s.Search | Should -Be 'conditional'
        }
    }

    Describe 'Leaving nothing signed in' {
        BeforeEach {
            Mock Get-MbcTerminalCapability { New-MbcCapability -Width 100 -Height 30 -Interactive $true }
            Mock Enter-MbcScreen { }
            Mock Exit-MbcScreen { }
            Mock Invoke-MbcDisconnectAll { , @('Graph', 'Exchange Online') }
        }
        It 'signs out of everything when the view closes after signing in, then says what to remove' {
            Mock Invoke-MbcTuiLoop {
                $State.Connection = [pscustomobject]@{
                    Account = 'operator@example.com'
                    Consent = [pscustomobject]@{ ClientAppId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'; ClientName = 'Microsoft Graph Command Line Tools'; ServicePrincipalId = 'sp1'; Cause = $null
                        Grants = @([pscustomobject]@{ Id = 'grant1'; Type = 'admin'; Scopes = @('User.Read'); WriteScopes = @() }) }
                }
            }
            $saved = $script:MbcBrokerSignOutSkipped
            $script:MbcBrokerSignOutSkipped = $true
            try { $said = (Start-BaselineCheck -OutputRoot (Join-Path $TestDrive 'q1') 6>&1 | ForEach-Object { [string]$_ }) -join "`n" }
            finally { $script:MbcBrokerSignOutSkipped = $saved }
            Should -Invoke Invoke-MbcDisconnectAll -Times 1 -Exactly
            $said | Should -BeLike '*Signed out of Graph, Exchange Online.*'
            $said | Should -BeLike "*-OAuth2PermissionGrantId 'grant1'*"
            if ($IsWindows) { $said | Should -BeLike '*Accounts used by other apps*' }
            else { $said | Should -Not -BeLike '*Accounts used by other apps*' -Because 'the Windows advice is for Windows' }
            $said.Contains('System.String[]') | Should -BeFalse
            $said.Contains('System.Object[]') | Should -BeFalse
        }
        It 'touches nothing when it never signed in' {
            Mock Invoke-MbcTuiLoop { }
            Start-BaselineCheck -OutputRoot (Join-Path $TestDrive 'q2') 6>$null
            Should -Invoke Invoke-MbcDisconnectAll -Times 0 -Exactly
        }
        It 'says, once the view is gone, where this session''s plaintext run logs stay' {
            Mock Invoke-MbcTuiLoop {
                $p = Join-Path $State.OutputRoot 'logs/run-1.jsonl'
                [System.IO.File]::WriteAllText($p, 'x')
                $State.PlaintextLogs.Add($p)
            }
            $said = (Start-BaselineCheck -OutputRoot (Join-Path $TestDrive 'q3') 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
            $said | Should -BeLike '*The run log stays in plaintext at *run-1.jsonl*'
        }
        It 'refuses an output folder that synchronises to the cloud before drawing anything' {
            Mock Invoke-MbcTuiLoop { }
            $saved = $env:OneDrive
            $env:OneDrive = Join-Path $TestDrive 'OneDrive-tui'
            try {
                { Start-BaselineCheck -OutputRoot (Join-Path $env:OneDrive 'M365BaselineCheck') } | Should -Throw '*synchronises to OneDrive*'
                Should -Invoke Enter-MbcScreen -Times 0 -Exactly
                Test-Path $env:OneDrive | Should -BeFalse
            }
            finally { $env:OneDrive = $saved }
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
