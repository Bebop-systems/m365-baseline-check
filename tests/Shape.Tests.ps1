BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Read-scope shape' {
        It '<Scope> is a read scope: <Read>' -ForEach @(
            @{ Scope = 'Policy.Read.All'; Read = $true }
            @{ Scope = 'User.ReadBasic.All'; Read = $true }
            @{ Scope = 'Policy.Read.ConditionalAccess'; Read = $true }
            @{ Scope = 'openid'; Read = $true }
            @{ Scope = 'offline_access'; Read = $true }
            @{ Scope = 'Directory.ReadWrite.All'; Read = $false }
            @{ Scope = 'Mail.Send'; Read = $false }
            @{ Scope = 'Directory.AccessAsUser.All'; Read = $false }
            @{ Scope = 'Sites.FullControl.All'; Read = $false }
            @{ Scope = 'Policy.Read.Write.All'; Read = $false }
            @{ Scope = 'Read'; Read = $false }
            @{ Scope = 'AdministrativeUnit.Read.All'; Read = $true }
            @{ Scope = 'RoleManagement.Read.Directory'; Read = $true }
            @{ Scope = 'DeviceManagementConfiguration.Read.All'; Read = $true }
            @{ Scope = 'Policy.Read.PermissionGrant'; Read = $true }
            @{ Scope = 'Calendars.Read.Shared'; Read = $true }
            @{ Scope = 'Mail.ReadBasic'; Read = $true }
            @{ Scope = 'eDiscovery.Read.All'; Read = $true }
            @{ Scope = 'AuditLogsQuery-Exchange.Read.All'; Read = $true }
            @{ Scope = 'PrivilegedAccess.Read.AzureAD'; Read = $true }
            @{ Scope = 'User.Read'; Read = $true }
            @{ Scope = 'Chat.ReadBasic'; Read = $true }
            @{ Scope = 'Foo.Read.WriteAll'; Read = $false }
            @{ Scope = 'Foo.Read.AllWrite'; Read = $false }
            @{ Scope = 'User.Read.ReadWrite'; Read = $false }
            @{ Scope = 'Foo.Read.FullControl'; Read = $false }
            @{ Scope = 'Foo.Read.AccessAsUser'; Read = $false }
            @{ Scope = 'Mail.Read.SendAs'; Read = $false }
            @{ Scope = 'Foo.Read.ManageAll'; Read = $false }
            @{ Scope = 'Foo.Read.Write'; Read = $false }
            @{ Scope = 'Foo.ReadWrite.All'; Read = $false }
            @{ Scope = 'Foo.Read.All.Write'; Read = $false }
            @{ Scope = '.Read.All'; Read = $false }
            @{ Scope = 'Foo.Read.'; Read = $false }
            @{ Scope = 'Foo.Bar.Read.All'; Read = $false }
            @{ Scope = ' Policy.Read.All'; Read = $false }
            @{ Scope = 'Policy.Read.All '; Read = $false }
            @{ Scope = 'OPENID'; Read = $false }
        ) {
            Test-MbcReadScope -Scope $Scope | Should -Be $Read
        }
    }

    Describe 'Declared endpoints' {
        It 'matches the path itself, a child path, or the path with a query' {
            Test-MbcRequestDeclared -Request '/directoryRoles' -Endpoints @('/directoryRoles') | Should -BeTrue
            Test-MbcRequestDeclared -Request '/directoryRoles/abc/members' -Endpoints @('/directoryRoles') | Should -BeTrue
            Test-MbcRequestDeclared -Request '/directoryRoles?$expand=members' -Endpoints @('/directoryRoles') | Should -BeTrue
        }
        It 'does not match a path that merely starts with the same letters' {
            Test-MbcRequestDeclared -Request '/directoryRolesTemplates' -Endpoints @('/directoryRoles') | Should -BeFalse
        }
    }

    Describe 'Preset and baseline validation' {
        BeforeAll {
            $script:Fixtures = Join-Path $script:ModuleRoot 'tests/fixtures'
            function script:Get-Fixture([string] $Name) {
                ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fixtures $Name)))
            }
        }
        It 'accepts the fixture preset and baseline' {
            @(Test-MbcPresetShape -Preset (Get-Fixture 'preset-minimal.json')) | Should -BeNullOrEmpty
            @(Test-MbcBaselineShape -Baseline (Get-Fixture 'baseline-minimal.json')) | Should -BeNullOrEmpty
        }
        It 'names an unknown member' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['colour'] = 'blue'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match "unknown member 'colour'"
        }
        It 'returns a single problem as a one-element array' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['colour'] = 'blue'
            $result = Test-MbcPresetShape -Preset $p
            $result.GetType().IsArray | Should -BeTrue
            $result.Count | Should -Be 1
        }
        It 'requires exactly one of select and extractor' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['extractor'] = 'extractors/x.ps1'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'exactly one of select or extractor'
        }
        It 'rejects a duplicate check id' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][1]['id'] = 'ORG-001'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'ORG-001.*more than once'
        }
        It 'rejects a request outside the declared endpoints' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['request'] = '/users'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'not under a declared endpoint'
        }
        It 'rejects a request that is encoded path traversal' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['request'] = '/policies/authorizationPolicy/%2e%2e/%2e%2e/users'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'request must be a Graph path starting with'
        }
        It 'rejects an endpoint that is just a slash' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['endpoints'] = @('/')
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match "endpoint '/' must be a Graph path"
        }
        It 'rejects a scope that is not a read scope' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['scopes'] = @('Policy.ReadWrite.ConditionalAccess')
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'not a read scope'
        }
        It 'rejects an unreadable select' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['select'] = 'a..b'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match "Can't read select"
        }
        It 'requires an expected value for every check that needs one' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['expected'].Remove('CA-001')
            (Test-MbcBaselineShape -Baseline $b) -join "`n" | Should -Match 'CA-001.*no expected value'
        }
        It 'rejects an expected value for a check that does not exist' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['expected']['NOPE-1'] = 1L
            (Test-MbcBaselineShape -Baseline $b) -join "`n" | Should -Match 'NOPE-1.*no such check'
        }
        It 'rejects an expected value given for an exists check' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['preset']['checks'][1]['operator'] = 'exists'
            (Test-MbcBaselineShape -Baseline $b) -join "`n" | Should -Match 'CA-001.*exists takes no expected value'
        }
        It 'checks the expected value fits the operator' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['expected']['CA-001'] = 'many'
            (Test-MbcBaselineShape -Baseline $b) -join "`n" | Should -Match 'CA-001.*whole number'
        }
        It 'does not throw when a check has no operator' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['preset']['checks'][1].Remove('operator')
            { Test-MbcBaselineShape -Baseline $b } | Should -Not -Throw
            (Test-MbcBaselineShape -Baseline $b) -join "`n" | Should -Match 'operator must be one of'
        }
        It 'validates a seal block' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['seal'] = [ordered]@{ algorithm = 'MD5'; digest = 'abc'; sealedVersion = 0; extra = 'x' }
            $text = (Test-MbcBaselineShape -Baseline $b) -join "`n"
            $text | Should -Match 'SHA-256'
            $text | Should -Match '64 lowercase hex'
            $text | Should -Match "unknown member 'extra'"
            $text | Should -Match 'sealedVersion must be a whole number of 1 or more'
        }
    }
}
