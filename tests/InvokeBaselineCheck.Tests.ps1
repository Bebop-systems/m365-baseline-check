BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Invoke-BaselineCheck' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            $script:Bodies = @{
                '/policies/authorizationPolicy'        = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/authorizationPolicy.json')))
                '/identity/conditionalAccess/policies' = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/conditionalAccessPolicies.json')))
                'Get-OrganizationConfig'               = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'cmdlet/organizationConfig.json')))
            }
            $script:Fetches = @{ n = 0 }
            $script:Fetch = { param($Item) $script:Fetches.n++; New-MbcFetchResult -Ok $true -Body $script:Bodies[$Item.Request] -Status 200 }
            $script:Conn = [pscustomobject]@{
                TenantId = '00000000-0000-4000-8000-000000000001'; TenantName = 'Example Ltd'; Domain = 'example.com'; Account = 'operator@example.com'
                Sessions = [ordered]@{ exo = 'tmpEXO_x' }; Disclosure = @('Read-only by construction: GET-only Graph, Get- cmdlets only.')
            }
            $script:Inv = { param($OnProgress) [pscustomobject]@{ PSTypeName = 'Mbc.Inventory'; Collected = $true; ThirdParty = @(); Own = @(); FirstPartyCount = 7; OtherCount = 0; Failures = @() } }
            function script:Invoke-Test([hashtable] $Extra = @{}) {
                $common = @{ OutputRoot = $script:Out; Fetch = $script:Fetch; Connection = $script:Conn; Inventory = $script:Inv; InformationAction = 'SilentlyContinue' }
                foreach ($k in $Extra.Keys) { $common[$k] = $Extra[$k] }
                Invoke-BaselineCheck @common
            }
        }
        BeforeEach {
            $script:Fetches.n = 0
            $script:Sealed = Join-Path $TestDrive "sealed-$([guid]::NewGuid().ToString('N')).json"
            Copy-Item (Join-Path $script:Fx 'baseline-minimal.json') $script:Sealed
            Protect-Baseline -Path $script:Sealed -InformationAction SilentlyContinue | Out-Null
            $script:Out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        }

        It 'runs every check, writes a log, and returns the counts and inventory' {
            $r = Invoke-Test @{ Baseline = $script:Sealed }
            $r.Counts.Pass | Should -Be 3
            $r.Inventory.FirstPartyCount | Should -Be 7
            Test-Path $r.LogPath | Should -BeTrue
            $log = [System.IO.File]::ReadAllText($r.LogPath)
            $log | Should -BeLike '*"event":"check"*'
            $log | Should -BeLike '*"event":"run.end"*'
            $r.Files | Should -BeNullOrEmpty
            @(Get-ChildItem (Join-Path $script:Out 'results')).Count | Should -Be 0
        }

        It 'prints results grouped by admin centre, then a one-line summary' {
            $lines = @(Invoke-BaselineCheck -Baseline $script:Sealed -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn -Inventory $script:Inv 6>&1 |
                    Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            $text = $lines -join "`n"
            $text.IndexOf('Entra  2 met') | Should -BeGreaterOrEqual 0
            $text.IndexOf('Entra') | Should -BeLessThan $text.IndexOf('Exchange  1 met')
            @($lines | Where-Object { $_ -eq '3 met, 0 not, 0 unverifiable.' }).Count | Should -Be 1
            $text | Should -BeLike '*Read-only by construction*'
        }

        It 'checks an expected fingerprint before fetching anything' {
            { Invoke-Test @{ Baseline = $script:Sealed; ExpectedFingerprint = '000000000000' } } | Should -Throw '*Fingerprint mismatch*'
            $script:Fetches.n | Should -Be 0
        }

        It 'refuses an unsealed baseline, and stamps UNSEALED when allowed' {
            $raw = Join-Path $TestDrive 'raw.json'
            Copy-Item (Join-Path $script:Fx 'baseline-minimal.json') $raw -Force
            { Invoke-Test @{ Baseline = $raw } } | Should -Throw '*never been sealed*'
            $r = Invoke-Test @{ Baseline = $raw; AllowUnsealed = $true; Export = $true; NoLock = $true }
            [System.IO.File]::ReadAllText($r.Files.Summary) | Should -BeLike '*UNSEALED*'
        }

        It 'exports one locked bundle and a summary with -Export and a key' {
            $key = ConvertTo-SecureString -String (New-MbcTeamKeyText) -AsPlainText -Force
            $r = Invoke-Test @{ Baseline = $script:Sealed; Export = $true; Key = $key }
            $r.Files.Locked | Should -BeLike '*.locked'
            $r.Files.Json | Should -BeNullOrEmpty
            @(Get-ChildItem (Join-Path $script:Out 'results')).Count | Should -Be 2
        }

        It 'moves the finished log into the locked bundle and leaves no plaintext log behind' {
            $keyText = New-MbcTeamKeyText
            $key = ConvertTo-SecureString -String $keyText -AsPlainText -Force
            $lines = @(Invoke-BaselineCheck -Baseline $script:Sealed -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn -Inventory $script:Inv -Export -Key $key 6>&1 |
                    Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            @(Get-ChildItem (Join-Path $script:Out 'logs') -File).Count | Should -Be 0
            ($lines -join "`n") | Should -BeLike '*Log: inside result-*.locked, and the plaintext copy is deleted.*'
            $locked = @(Get-ChildItem (Join-Path $script:Out 'results') -Filter '*.locked')[0].FullName
            $log = (Open-MbcLockedResult -Path $locked -KeyText $keyText).Files['run.jsonl']
            $log | Should -BeLike '*"event":"run.end"*' -Because 'the log is finished before it is locked away'
        }

        It 'says where the log stays when it is not locked away' {
            $lines = @(Invoke-BaselineCheck -Baseline $script:Sealed -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn -Inventory $script:Inv 6>&1 |
                    Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            ($lines -join "`n") | Should -BeLike '*The run log stays in plaintext at *docs/handling-results.md*'
        }

        It 'says where the log stays when the run stops, then stops with the reason' {
            Mock Connect-MbcSources { throw 'Sign-in was cancelled.' }
            $said = [System.Collections.Generic.List[string]]::new()
            { Invoke-BaselineCheck -Baseline $script:Sealed -OutputRoot $script:Out -Inventory $script:Inv 6>&1 |
                    ForEach-Object { if ($_ -is [System.Management.Automation.InformationRecord]) { $said.Add([string]$_.MessageData) } } } | Should -Throw '*Sign-in was cancelled.*'
            ($said -join "`n") | Should -BeLike '*The run log stays in plaintext at *'
        }

        It 'returns no log path once the log is locked away' {
            $key = ConvertTo-SecureString -String (New-MbcTeamKeyText) -AsPlainText -Force
            $r = Invoke-Test @{ Baseline = $script:Sealed; Export = $true; Key = $key }
            $r.LogLocked | Should -BeTrue
            $r.LogPath | Should -BeNullOrEmpty
        }

        It 'refuses an output folder that synchronises to the cloud before writing or fetching anything, unless allowed' {
            $saved = $env:OneDrive
            $env:OneDrive = Join-Path $TestDrive "OneDrive-$([guid]::NewGuid().ToString('N'))"
            try {
                $synced = Join-Path $env:OneDrive 'M365BaselineCheck'
                { Invoke-Test @{ Baseline = $script:Sealed; OutputRoot = $synced } } | Should -Throw '*synchronises to OneDrive*'
                $script:Fetches.n | Should -Be 0
                Test-Path $synced | Should -BeFalse
                (Invoke-Test @{ Baseline = $script:Sealed; OutputRoot = $synced; AllowSyncedOutput = $true }).Counts.Pass | Should -Be 3
            }
            finally { $env:OneDrive = $saved }
        }

        It 'refuses a malformed key before running anything' {
            $bad = ConvertTo-SecureString -String 'not a key' -AsPlainText -Force
            { Invoke-Test @{ Baseline = $script:Sealed; Export = $true; Key = $bad } } | Should -Throw "*isn't a team key*"
            $script:Fetches.n | Should -Be 0
        }

        It 'leaves the inventory out with -SkipAppInventory' {
            (Invoke-Test @{ Baseline = $script:Sealed; SkipAppInventory = $true }).Inventory.Collected | Should -BeFalse
        }
    }
}
