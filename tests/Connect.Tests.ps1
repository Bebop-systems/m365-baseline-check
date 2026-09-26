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
}
