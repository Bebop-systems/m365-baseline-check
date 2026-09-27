BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Sign-in scopes and sources' {
        BeforeAll {
            $script:Preset = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:ModuleRoot 'tests/fixtures/preset-minimal.json')))
        }
        It 'asks for the preset scopes plus the inventory and profile scopes, once each' {
            $s = Get-MbcSignInScopes -Preset $script:Preset
            $s -join ',' | Should -Be 'Policy.Read.All,Application.Read.All,Directory.Read.All,User.Read'
        }
        It 'will not request a scope that is not a read scope' {
            $p = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $script:Preset)
            $p['scopes'] = @('Policy.ReadWrite.All')
            { Get-MbcSignInScopes -Preset $p } | Should -Throw "*isn't a read scope*"
        }
        It 'lists the cmdlet sources the checks use' {
            (Get-MbcPresetSources -Preset $script:Preset) -join ',' | Should -Be 'exo'
        }
        It 'says which sign-ins are coming, and that Security & Compliance usually reuses Exchange''s' {
            $both = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:ModuleRoot 'presets/example-tenant-hygiene.json')))
            $plan = Get-MbcSignInPlan -Preset $both
            $plan.Count | Should -Be 3
            $plan[2] | Should -BeLike '*usually reuses the Exchange Online sign-in*'
        }
        It 'connects Exchange Online before Security & Compliance, whatever order the checks are in' {
            $p = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:ModuleRoot 'presets/example-tenant-hygiene.json')))
            $p['checks'] = @(@($p['checks']) | Where-Object { $_['source'] -eq 'compliance' }) + @(@($p['checks']) | Where-Object { $_['source'] -eq 'exo' })
            (Get-MbcPresetSources -Preset $p) -join ',' | Should -Be 'exo,compliance'
            $plan = Get-MbcSignInPlan -Preset $p
            $plan[1] | Should -BeLike 'Exchange Online: a browser window.'
            $plan[2] | Should -BeLike '*usually reuses the Exchange Online sign-in*'
        }
        It 'tells the operator what Windows may remember when the broker clean-up could not run' -Skip:(-not $IsWindows) {
            $saved = $script:MbcBrokerSignOutSkipped
            try {
                $script:MbcBrokerSignOutSkipped = $true
                (Get-MbcBrokerAdvice -Account 'operator@example.com') -join ' ' | Should -BeLike '*may still remember operator@example.com*Accounts used by other apps*'
                $script:MbcBrokerSignOutSkipped = $false
                (Get-MbcBrokerAdvice -Account 'operator@example.com').Count | Should -Be 0
            }
            finally { $script:MbcBrokerSignOutSkipped = $saved }
        }
        It 'reads a session module name from a name or a path' {
            Get-MbcSessionModuleName -ModuleName 'tmpEXO_abc123' | Should -Be 'tmpEXO_abc123'
            Get-MbcSessionModuleName -ModuleName 'C:\Temp\tmpEXO_abc123\tmpEXO_abc123.psm1' | Should -Be 'tmpEXO_abc123'
            Get-MbcSessionModuleName -ModuleName '/tmp/tmpEXO_abc123' | Should -Be 'tmpEXO_abc123'
        }
    }

    Describe 'Connecting and disclosing' {
        BeforeAll {
            $script:Preset = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:ModuleRoot 'tests/fixtures/preset-minimal.json')))
            $script:Transport = {
                param($Uri)
                if ($Uri -like '*transitiveMemberOf*') { return [pscustomobject]@{ Status = 200; Body = '{"value":[{"displayName":"Global Administrator","roleTemplateId":"62e90394-69f5-4237-9190-012177145e10"}]}'; RetryAfter = $null } }
                if ($Uri -like '*/organization*') { return [pscustomobject]@{ Status = 200; Body = '{"value":[{"displayName":"Example Ltd","verifiedDomains":[{"name":"example.com","isDefault":true}]}]}'; RetryAfter = $null } }
                [pscustomobject]@{ Status = 404; Body = '{}'; RetryAfter = $null }
            }
        }
        BeforeEach {
            Mock Test-MbcModuleAvailable { $true }
            Mock Import-MbcSourceModule { }
            Mock Invoke-MbcConnectMgGraph { }
            Mock Get-MbcMgContext {
                [pscustomobject]@{ Account = 'operator@example.com'; TenantId = '00000000-0000-4000-8000-000000000001'; Scopes = @('Policy.Read.All', 'Directory.ReadWrite.All', 'openid') }
            }
            Mock Invoke-MbcConnectExchange { }
            Mock Get-MbcExchangeConnections {
                @([pscustomobject]@{ State = 'Connected'; IsEopSession = $false; ConnectionUri = 'https://outlook.office365.com'; ModuleName = 'C:\Temp\tmpEXO_abc123\tmpEXO_abc123.psm1'; UserPrincipalName = 'operator@example.com' })
            }
        }

        It 'signs in to Graph, then to each cmdlet source with the Graph account as the hint' {
            $c = Connect-MbcSources -Preset $script:Preset -Transport $script:Transport
            Should -Invoke Invoke-MbcConnectMgGraph -Times 1 -Exactly
            Should -Invoke Invoke-MbcConnectExchange -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'exo' -and $UserPrincipalName -eq 'operator@example.com' -and ($CommandName -join ',') -eq 'Get-OrganizationConfig'
            }
            $c.Sessions['exo'] | Should -Be 'tmpEXO_abc123'
            $c.TenantName | Should -Be 'Example Ltd'
            $c.Domain | Should -Be 'example.com'
        }

        It 'discloses roles, scopes with writes marked, sessions and the read-only line, and refuses nothing' {
            $c = Connect-MbcSources -Preset $script:Preset -Transport $script:Transport
            $text = $c.Disclosure -join "`n"
            $text | Should -BeLike '*operator@example.com*'
            $text | Should -BeLike '*Global Administrator*'
            $text | Should -BeLike '*Directory.ReadWrite.All (write)*'
            $text | Should -BeLike '*Exchange Online*'
            $text | Should -BeLike '*Read-only by construction: GET-only Graph, Get- cmdlets only.*'
            $c.WriteScopes -join ',' | Should -Be 'Directory.ReadWrite.All'
        }

        It 'records a cmdlet source that failed to connect, and carries on' {
            Mock Invoke-MbcConnectExchange { throw 'User canceled authentication.' }
            $c = Connect-MbcSources -Preset $script:Preset -Transport $script:Transport
            $c.Sessions.Contains('exo') | Should -BeFalse
            $c.Failed['exo'] | Should -BeLike '*canceled*'
            ($c.Disclosure -join "`n") | Should -BeLike '*Exchange Online: not connected*'
        }

        It 'records a missing Exchange module only when a cmdlet source needs it' {
            Mock Test-MbcModuleAvailable { $Name -ne 'ExchangeOnlineManagement' }
            $c = Connect-MbcSources -Preset $script:Preset -Transport $script:Transport
            $c.Failed['exo'] | Should -BeLike '*Install-Module ExchangeOnlineManagement*'
            Should -Invoke Invoke-MbcConnectExchange -Times 0 -Exactly
            $graphOnly = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $script:Preset)
            $graphOnly['checks'] = @($graphOnly['checks'][0])
            (Connect-MbcSources -Preset $graphOnly -Transport $script:Transport).Failed.Count | Should -Be 0
        }

        It 'says so when roles could not be read' {
            $noRoles = { param($Uri) [pscustomobject]@{ Status = 403; Body = '{}'; RetryAfter = $null } }
            $c = Connect-MbcSources -Preset $script:Preset -Transport $noRoles
            $c.Roles | Should -BeNullOrEmpty
            ($c.Disclosure -join "`n") | Should -BeLike "*Directory roles: couldn't be read (permission missing)*"
        }

        It 'refuses to start without the Graph module, and says how to install it' {
            Mock Test-MbcModuleAvailable { $false }
            { Connect-MbcSources -Preset $script:Preset -Transport $script:Transport } | Should -Throw '*Install-Module Microsoft.Graph.Authentication*'
        }

        It 'reads the consent the signing-in app holds, and says how to remove it' {
            Mock Get-MbcMgContext {
                [pscustomobject]@{ Account = 'operator@example.com'; TenantId = '00000000-0000-4000-8000-000000000001'; ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'; Scopes = @('Policy.Read.All', 'Directory.ReadWrite.All') }
            }
            $consentTransport = {
                param($Uri)
                if ($Uri -like '*servicePrincipals[?]*appId*') { return [pscustomobject]@{ Status = 200; Body = '{"value":[{"id":"00000000-0000-4000-8000-0000000000c1","appId":"14d82eec-204b-4c2f-b7e8-296a70dab67e","displayName":"Microsoft Graph Command Line Tools"}]}'; RetryAfter = $null } }
                if ($Uri -like '*/me[?]*') { return [pscustomobject]@{ Status = 200; Body = '{"id":"00000000-0000-4000-8000-0000000000e9"}'; RetryAfter = $null } }
                if ($Uri -like '*oauth2PermissionGrants[?]*') {
                    return [pscustomobject]@{ Status = 200; RetryAfter = $null; Body = '{"value":[
                        {"id":"grant-admin","consentType":"AllPrincipals","principalId":null,"scope":"Policy.Read.All Directory.ReadWrite.All"},
                        {"id":"grant-mine","consentType":"Principal","principalId":"00000000-0000-4000-8000-0000000000e9","scope":"User.Read"},
                        {"id":"grant-other","consentType":"Principal","principalId":"00000000-0000-4000-8000-0000000000e8","scope":"Mail.Read"}]}' }
                }
                & $script:Transport $Uri
            }
            $c = Connect-MbcSources -Preset $script:Preset -Transport $consentTransport
            @($c.Consent.Grants | ForEach-Object Id) -join ',' | Should -Be 'grant-admin,grant-mine' -Because 'another user''s own consent is theirs, not this sign-in''s'
            $c.Consent.Grants[0].WriteScopes -join ',' | Should -Be 'Directory.ReadWrite.All'
            $advice = (Format-MbcConsentAdvice -Consent $c.Consent) -join "`n"
            $advice | Should -BeLike '*Microsoft Graph Command Line Tools, app ID 14d82eec-204b-4c2f-b7e8-296a70dab67e*'
            $advice | Should -BeLike '*Admin consent for all users: 2 permissions, 1 of them write. Grant ID grant-admin.*'
            $advice.Contains("Remove-MgOauth2PermissionGrant ``") | Should -BeTrue
            $advice.Contains("-OAuth2PermissionGrantId 'grant-mine'") | Should -BeTrue
            ($c.Disclosure -join "`n") | Should -BeLike '*Signed in through Microsoft Graph Command Line Tools; consent it holds here: 2 permissions for all users.*'
        }

        It 'says when there is no consent to remove, and when it could not be read' {
            Format-MbcConsentAdvice -Consent ([pscustomobject]@{ ClientAppId = 'x'; ClientName = 'App'; ServicePrincipalId = 'y'; Grants = @(); Cause = $null }) | Select-Object -Last 1 | Should -BeLike '*Nothing to remove.*'
            Format-MbcConsentAdvice -Consent ([pscustomobject]@{ ClientAppId = 'x'; ClientName = ''; ServicePrincipalId = ''; Grants = @(); Cause = 'permission missing' }) | Select-Object -Last 1 | Should -BeLike "*couldn't be read (permission missing)*"
        }

        It 'closes any sessions left open before it signs in, and says so' {
            Mock Invoke-MbcDisconnectAll { , @('Graph') }
            $c = Connect-MbcSources -Preset $script:Preset -Transport $script:Transport
            Should -Invoke Invoke-MbcDisconnectAll -Times 1 -Exactly
            ($c.Disclosure -join "`n") | Should -BeLike '*Closed sessions already open before signing in: Graph.*'
        }

        It 'leaves nothing signed in when sign-in stops part-way' {
            Mock Invoke-MbcDisconnectAll { , @() }
            Mock Get-MbcMgContext { $null }
            { Connect-MbcSources -Preset $script:Preset -Transport $script:Transport } | Should -Throw '*did not complete*'
            Should -Invoke Invoke-MbcDisconnectAll -Times 2 -Exactly -Because 'once to start clean, once to clean up'
        }

        It 'keeps the Graph token cache in this process only, and Exchange off the Windows broker' {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:ModuleRoot 'src/Sources/Connect.ps1'))
            $text | Should -BeLike '*Connect-MgGraph -Scopes $Scopes -ContextScope Process*'
            $text | Should -BeLike '*Connect-ExchangeOnline * -DisableWAM*'
            $text | Should -BeLike '*Connect-IPPSSession * -DisableWAM*'
        }

        It 'refuses an Exchange session in another tenant than the Graph sign-in' {
            Mock Get-MbcExchangeConnections {
                @([pscustomobject]@{ State = 'Connected'; IsEopSession = $false; ConnectionUri = 'https://outlook.office365.com'; ModuleName = 'tmpEXO_other'; TenantID = '00000000-0000-4000-8000-0000000000ff' })
            }
            $c = Connect-MbcSources -Preset $script:Preset -Transport $script:Transport
            $c.Sessions.Contains('exo') | Should -BeFalse
            $c.Failed['exo'] | Should -BeLike '*another account*'
        }

        It 'says whether a sign-in covers a preset''s scopes and sources' {
            $c = Connect-MbcSources -Preset $script:Preset -Transport $script:Transport
            $c.Scopes = @('Policy.Read.All', 'Application.Read.All', 'Directory.Read.All', 'User.Read')
            Test-MbcConnectionCovers -Connection $c -Preset $script:Preset | Should -BeTrue
            $more = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $script:Preset)
            $more['scopes'] = @('Policy.Read.All', 'AuditLog.Read.All')
            Test-MbcConnectionCovers -Connection $c -Preset $more | Should -BeFalse
            $compliance = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $script:Preset)
            $compliance['cmdlets'] = [ordered]@{ compliance = @('Get-DlpCompliancePolicy') }
            $compliance['checks'][2]['source'] = 'compliance'
            $compliance['checks'][2]['request'] = 'Get-DlpCompliancePolicy'
            Test-MbcConnectionCovers -Connection $c -Preset $compliance | Should -BeFalse
        }

        It 'picks the compliance session, not the Exchange one, for the compliance source' {
            $p = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $script:Preset)
            $p['cmdlets'] = [ordered]@{ compliance = @('Get-DlpCompliancePolicy') }
            $p['checks'][2]['source'] = 'compliance'
            $p['checks'][2]['request'] = 'Get-DlpCompliancePolicy'
            Mock Get-MbcExchangeConnections {
                @(
                    [pscustomobject]@{ State = 'Connected'; IsEopSession = $false; ConnectionUri = 'https://outlook.office365.com'; ModuleName = 'tmpEXO_one'; UserPrincipalName = 'operator@example.com' }
                    [pscustomobject]@{ State = 'Connected'; IsEopSession = $true; ConnectionUri = 'https://ps.compliance.protection.outlook.com'; ModuleName = 'tmpEXO_two'; UserPrincipalName = 'operator@example.com' }
                )
            }
            (Connect-MbcSources -Preset $p -Transport $script:Transport).Sessions['compliance'] | Should -Be 'tmpEXO_two'
        }
    }

    Describe "Signing out" {
        BeforeAll {
            # Stand-ins where the Graph module is not installed (CI), so the calls can be mocked.
            $script:MadeStandIns = @()
            if (-not (Get-Command -Name Disconnect-MgGraph -ErrorAction SilentlyContinue)) { function global:Disconnect-MgGraph { param([switch] $SignOutFromBroker) }; $script:MadeStandIns += 'Disconnect-MgGraph' }
            if (-not (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue)) { function global:Get-MgContext { }; $script:MadeStandIns += 'Get-MgContext' }
        }
        AfterAll {
            foreach ($f in $script:MadeStandIns) { Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue }
        }
        It "logs that no broker sign-out was needed when there was no Graph session" {
            Mock Get-Module { [pscustomobject]@{ Name = $Name } }
            Mock Get-MgContext { $null }
            $log = New-MbcRunLog -Directory $TestDrive -RunId "20260101T000000Z-so0003"
            (Invoke-MbcDisconnectAll -Log $log).Count | Should -Be 0
            [System.IO.File]::ReadAllText($log.Path) | Should -BeLike '*"brokerSignOut":"not needed: no Graph session"*'
            (Get-MbcBrokerAdvice -Account 'operator@example.com').Count | Should -Be 0
        }
        BeforeEach {
            $script:ContextCalls = 0
            $script:BrokerFlags = [System.Collections.Generic.List[bool]]::new()
            Mock Get-MgContext { $script:ContextCalls++; if ($script:ContextCalls -eq 1) { [pscustomobject]@{ Account = "operator@example.com" } } }
            Mock Disconnect-MgGraph { $script:BrokerFlags.Add([bool]$SignOutFromBroker) }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq "Get-ConnectionInformation" }
        }
        It "skips the broker sign-out when Exchange Online is loaded, and logs that it did" {
            Mock Get-Module { [pscustomobject]@{ Name = $Name } }
            $log = New-MbcRunLog -Directory $TestDrive -RunId "20260101T000000Z-so0001"
            (Invoke-MbcDisconnectAll -Log $log) -join "," | Should -Be "Graph"
            $script:BrokerFlags -join "," | Should -Be "False"
            [System.IO.File]::ReadAllText($log.Path) | Should -BeLike "*brokerSignOut*skipped*"
        }
        It "signs out of the broker too when Exchange Online is not loaded" {
            Mock Get-Module { if ($Name -eq "Microsoft.Graph.Authentication") { [pscustomobject]@{ Name = $Name } } }
            (Invoke-MbcDisconnectAll) -join "," | Should -Be "Graph"
            $script:BrokerFlags -join "," | Should -Be "True"
        }
    }
}