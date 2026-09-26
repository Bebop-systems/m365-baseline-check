BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The result document and its CSVs' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            $script:Baseline = Read-MbcBaseline -Path (Join-Path $script:Fx 'baseline-minimal.json')
            $script:Bodies = @{
                '/policies/authorizationPolicy' = ConvertFrom-MbcJson -Json '{"defaultUserRolePermissions":{"allowedToCreateApps":true}}'
                'Get-OrganizationConfig'        = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'cmdlet/organizationConfig.json')))
            }
            $script:Fetch = {
                param($Item)
                if ($script:Bodies.ContainsKey($Item.Request)) { return (New-MbcFetchResult -Ok $true -Body $script:Bodies[$Item.Request] -Status 200) }
                New-MbcFetchResult -Ok $false -Status 403 -Cause 'permission missing' -Detail 'HTTP 403'
            }
            $invData = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'inventory/tenant.json')))
            $get = {
                param($Request)
                $q = $Request.IndexOf('?')
                $path = if ($q -ge 0) { $Request.Substring(0, $q) } else { $Request }
                if ($invData.Contains($path)) { return (New-MbcFetchResult -Ok $true -Body $invData[$path] -Status 200) }
                New-MbcFetchResult -Ok $false -Status 404 -Cause 'not found'
            }
            $script:Inventory = ConvertTo-MbcAppInventory -Data (Get-MbcAppInventoryData -Get $get -TenantId '00000000-0000-4000-8000-000000000001') -TenantId '00000000-0000-4000-8000-000000000001'
            $script:Run = Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:Fetch -Inventory { param($p) $script:Inventory }
            $script:Connection = [pscustomobject]@{
                TenantId = '00000000-0000-4000-8000-000000000001'; TenantName = 'Example Ltd'; Domain = 'example.com'; Account = 'operator@example.com'
                Disclosure = @('Signed in as operator@example.com to Example Ltd.', 'Read-only by construction: GET-only Graph, Get- cmdlets only.')
            }
            $script:Doc = New-MbcResultDocument -Run $script:Run -Baseline $script:Baseline -Connection $script:Connection
        }

        It 'seals the result so it can be verified untouched later' {
            Test-MbcResultSeal -Document $script:Doc | Should -BeTrue
            $copy = ConvertFrom-MbcJson -Json (ConvertTo-MbcPrettyJson $script:Doc) -AllowFloat
            Test-MbcResultSeal -Document $copy | Should -BeTrue
            $copy['counts']['pass'] = 99
            Test-MbcResultSeal -Document $copy | Should -BeFalse
        }

        It 'records the baseline identity, the tenant, the disclosure and the counts' {
            $script:Doc['baseline']['fingerprint'] | Should -Be $script:Baseline.Fingerprint
            $script:Doc['baseline']['digest'] | Should -Be $script:Baseline.Digest
            $script:Doc['tenant']['name'] | Should -Be 'Example Ltd'
            $script:Doc['disclosure'][-1] | Should -Be 'Read-only by construction: GET-only Graph, Get- cmdlets only.'
            "$($script:Doc['counts']['pass']) $($script:Doc['counts']['fail']) $($script:Doc['counts']['error'])" | Should -Be '1 1 1'
        }

        It 'records each check with area, location, source and labels' {
            $org = $script:Doc['results'] | Where-Object { $_['id'] -eq 'ORG-001' }
            $org['area'] | Should -Be 'entra'
            $org['verdict'] | Should -Be 'Fail'
            $org['actual'] | Should -BeTrue
            $org['labels']['true'] | Should -Be 'Yes'
            ($script:Doc['results'] | Where-Object { $_['id'] -eq 'EXO-001' })['source'] | Should -Be 'exo'
        }

        It 'carries the full app inventory' {
            $script:Doc['inventory']['collected'] | Should -BeTrue
            @($script:Doc['inventory']['thirdParty']).Count | Should -Be 2
            $script:Doc['inventory']['firstPartyCount'] | Should -Be 2
        }

        It 'comes back as the same view it was made from' {
            $view = ConvertFrom-MbcResultDocument -Document (ConvertFrom-MbcJson -Json (ConvertTo-MbcPrettyJson $script:Doc) -AllowFloat)
            $view.Results.Count | Should -Be 3
            $view.Results[0].Labels['true'] | Should -Be 'Yes'
            $view.Counts.Fail | Should -Be 1
            $view.Baseline.Fingerprint | Should -Be $script:Baseline.Fingerprint
            $view.Inventory.ThirdParty[0].Delegated[0].Scopes -join ',' | Should -Be 'Mail.Read,User.Read'
            $view.Tenant.Name | Should -Be 'Example Ltd'
            $view.Sealed | Should -BeTrue
        }

        It 'writes one CSV row per check, each carrying the baseline identity and run time' {
            $rows = @((ConvertTo-MbcResultCsv -Document $script:Doc) | ConvertFrom-Csv)
            $rows.Count | Should -Be 3
            foreach ($r in $rows) {
                $r.Fingerprint | Should -Be $script:Baseline.Fingerprint
                $r.BaselineVersion | Should -Be '1'
                $r.RunUtc | Should -Be $script:Doc['run']['startedUtc']
            }
            $org = $rows | Where-Object Id -eq 'ORG-001'
            $org.Verdict | Should -Be 'Not met'
            $org.Area | Should -Be 'Entra'
            $org.Request | Should -Be 'GET v1.0 /policies/authorizationPolicy'
            ($rows | Where-Object Id -eq 'CA-001').Cause | Should -Be 'permission missing'
            ($rows | Where-Object Id -eq 'EXO-001').Request | Should -Be 'Get-OrganizationConfig'
        }

        It 'writes one apps row per app and permission' {
            $rows = @((ConvertTo-MbcAppsCsv -Document $script:Doc) | ConvertFrom-Csv)
            $scheduler = @($rows | Where-Object App -eq 'Example Scheduler')
            @($scheduler | ForEach-Object PermissionType) -join ',' | Should -Be 'delegated-admin,application'
            ($scheduler | Where-Object PermissionType -eq 'application').Permissions | Should -Be 'unresolved permission User.Read.All'
            ($rows | Where-Object App -eq 'Sample Notes').Users | Should -Be '2'
            ($rows | Where-Object App -eq 'SENTINEL-OWN-APP-TWO').Kind | Should -Be 'own registration'
            ($rows | Where-Object App -eq 'SENTINEL-OWN-APP-TWO').PermissionType | Should -Be ''
        }

        It 'neutralises a value that a spreadsheet would run as a formula' {
            Format-MbcCellValue -Value '=HYPERLINK("x")' | Should -BeExactly "'=HYPERLINK(`"x`")"
            Format-MbcCellValue -Value '@SUM(1)' | Should -BeExactly "'@SUM(1)"
            Format-MbcCellValue -Value @('a', 'b') | Should -BeExactly '["a","b"]'
            Format-MbcCellValue -Value $false | Should -BeExactly 'false'
            Format-MbcCellValue -Value (-3) | Should -BeExactly '-3'
        }

        It 'describes a request the way an administrator would type it' {
            Format-MbcRequestText -Source 'exo' -Request 'Get-OrganizationConfig' -Parameters ([ordered]@{ Identity = "O'Brien"; Force = $true; Size = 5L }) |
                Should -BeExactly "Get-OrganizationConfig -Identity 'O''Brien' -Force:`$true -Size 5"
            Format-MbcRequestText -Source 'graph' -ApiVersion 'beta' -Request '/x' | Should -BeExactly 'GET beta /x'
        }
    }
}
