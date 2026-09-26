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
        It 'requires select' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0].Remove('select')
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'select must be text'
        }
        It 'refuses the old extractor member' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['extractor'] = 'extractors/x.ps1'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match "unknown member 'extractor'"
        }
        It 'requires an area, from the fixed list' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0].Remove('area')
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'area must be one of entra, exchange, intune, purview, defender, admin'
            $p['checks'][0]['area'] = 'sharepoint'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'area must be one of'
        }
        It 'accepts location and labels, and checks their types' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['location'] = 'Identity > Users > User settings'
            $p['checks'][0]['labels'] = [ordered]@{ 'true' = 'Yes'; 'false' = 'No' }
            @(Test-MbcPresetShape -Preset $p) | Should -BeNullOrEmpty
            $p['checks'][0]['location'] = 5L
            $p['checks'][0]['labels'] = [ordered]@{ 'true' = 1L }
            $text = (Test-MbcPresetShape -Preset $p) -join "`n"
            $text | Should -Match 'location must be text'
            $text | Should -Match 'labels must map value text to display text'
        }
        It 'accepts a declared cmdlet check with scalar parameters' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][2]['parameters'] = [ordered]@{ Identity = 'Default'; ResultSize = 10L; Force = $true }
            @(Test-MbcPresetShape -Preset $p) | Should -BeNullOrEmpty
        }
        It 'refuses a cmdlet that does not start with Get-' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][2]['request'] = 'Set-OrganizationConfig'
            $p['cmdlets']['exo'] = @('Set-OrganizationConfig')
            $text = (Test-MbcPresetShape -Preset $p) -join "`n"
            $text | Should -Match "cmdlets.exo: 'Set-OrganizationConfig' must be a Get- cmdlet"
            $text | Should -Match 'request must be a Get- cmdlet name'
        }
        It 'refuses a cmdlet name with anything but letters and digits after Get-' {
            Test-MbcCmdletName -Name 'Get-OrganizationConfig' | Should -BeTrue
            Test-MbcCmdletName -Name 'get-organizationconfig' | Should -BeTrue
            foreach ($bad in 'Get-', 'Get-*', 'Get-Org;Set-Org', 'Get-Org Config', 'Microsoft.Exchange\Get-Org', 'Get-Org-Config', 'GetOrg', '') {
                Test-MbcCmdletName -Name $bad | Should -BeFalse -Because "'$bad' is not a plain Get- name"
            }
        }
        It 'refuses a cmdlet check whose cmdlet is not declared under its source' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][2]['source'] = 'compliance'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match "'Get-OrganizationConfig' is not declared under cmdlets.compliance"
        }
        It 'refuses parameters on a Graph check, and non-scalar parameter values' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['parameters'] = [ordered]@{ Identity = 'x' }
            $p['checks'][2]['parameters'] = [ordered]@{ Identity = @('a', 'b') }
            $text = (Test-MbcPresetShape -Preset $p) -join "`n"
            $text | Should -Match 'check ORG-001: parameters are for cmdlet sources only'
            $text | Should -Match 'check EXO-001: parameter Identity must be text, true or false, or a whole number'
        }
        It 'refuses apiVersion on a cmdlet check, and an unknown source' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][2]['apiVersion'] = 'beta'
            $p['checks'][1]['source'] = 'sharepoint'
            $text = (Test-MbcPresetShape -Preset $p) -join "`n"
            $text | Should -Match 'apiVersion is for Graph checks only'
            $text | Should -Match 'source must be graph, exo or compliance'
        }
        It 'refuses cmdlets keyed by anything but exo or compliance' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['cmdlets']['graph'] = @('Get-Thing')
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match "cmdlets: unknown source 'graph'"
        }
        It 'allows empty endpoints and scopes when no check uses Graph' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'] = @($p['checks'][2])
            $p['endpoints'] = @()
            $p['scopes'] = @()
            @(Test-MbcPresetShape -Preset $p) | Should -BeNullOrEmpty
        }
        It 'still requires a Graph check to be under a declared endpoint when endpoints are empty' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['endpoints'] = @()
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'not under a declared endpoint'
        }
        It 'decodes a declared endpoint before its own traversal check' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['endpoints'] = @('/policies/%2e%2e/users')
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match "endpoint '/policies/%2e%2e/users' must be a Graph path"
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
