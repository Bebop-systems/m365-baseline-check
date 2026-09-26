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
