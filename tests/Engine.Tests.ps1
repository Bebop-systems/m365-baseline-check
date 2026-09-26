BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The engine' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            function script:Read-Fixture([string] $Name) { ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx $Name))) -AllowFloat }
            $script:Baseline = Read-MbcBaseline -Path (Join-Path $script:Fx 'baseline-minimal.json')
            $script:Bodies = @{
                '/policies/authorizationPolicy'        = Read-Fixture 'graph/authorizationPolicy.json'
                '/identity/conditionalAccess/policies' = Read-Fixture 'graph/conditionalAccessPolicies.json'
                'Get-OrganizationConfig'               = Read-Fixture 'cmdlet/organizationConfig.json'
            }
            $script:Calls = [System.Collections.Generic.List[string]]::new()
            $script:GoodFetch = {
                param($Item)
                $script:Calls.Add($Item.Key)
                New-MbcFetchResult -Ok $true -Body $script:Bodies[$Item.Request] -Status 200
            }
            function script:Copy-Preset {
                ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $script:Baseline.Document['preset'])
            }
        }
        BeforeEach { $script:Calls.Clear() }

        It 'plans each distinct request once, in check order, with its source' {
            $plan = Get-MbcRequestPlan -Preset $script:Baseline.Document['preset']
            @($plan | ForEach-Object Request) -join ',' | Should -Be '/policies/authorizationPolicy,/identity/conditionalAccess/policies,Get-OrganizationConfig'
            @($plan | ForEach-Object Source) -join ',' | Should -Be 'graph,graph,exo'
            $plan[2].Key | Should -Be 'exo|get-organizationconfig|{}'
        }

        It 'keys cmdlet requests by parameters too' {
            $preset = Copy-Preset
            $a = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $preset['checks'][2])
            $a['id'] = 'EXO-002'
            $a['parameters'] = [ordered]@{ Identity = 'Default' }
            $b = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $a)
            $b['id'] = 'EXO-003'
            $preset['checks'] = @($preset['checks'][2], $a, $b)
            $plan = Get-MbcRequestPlan -Preset $preset
            $plan.Count | Should -Be 2
            $plan[1].Parameters['Identity'] | Should -Be 'Default'
            $plan[1].Key | Should -Be 'exo|get-organizationconfig|{"Identity":"Default"}'
        }

        It 'fetches each request once even when several checks share it' {
            $preset = Copy-Preset
            $extra = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $preset['checks'][0])
            $extra['id'] = 'ORG-002'
            $preset['checks'] = @($preset['checks'][0], $extra, $preset['checks'][1])
            Invoke-MbcCollection -Plan (Get-MbcRequestPlan -Preset $preset) -Fetch $script:GoodFetch | Out-Null
            $script:Calls.Count | Should -Be 2
        }

        It 'passes every fixture check against the fixture responses, Graph and cmdlet alike' {
            $run = Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:GoodFetch
            @($run.Results | ForEach-Object { "$($_.Id)=$($_.Verdict)" }) -join ',' | Should -Be 'ORG-001=Pass,CA-001=Pass,EXO-001=Pass'
            $run.Counts.Pass | Should -Be 3
            $run.Counts.Total | Should -Be 3
        }

        It 'carries area, location, source and labels onto each result' {
            $r = (Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:GoodFetch).Results
            $r[0].Area | Should -Be 'entra'
            $r[0].Location | Should -Be 'Identity › Users › User settings'
            $r[0].Labels['false'] | Should -Be 'No'
            $r[2].Source | Should -Be 'exo'
            $r[2].Request | Should -Be 'Get-OrganizationConfig'
            $r[2].Location | Should -Be ''
        }

        It 'records the actual value on a Fail' {
            $fetch = {
                param($Item)
                $body = $script:Bodies[$Item.Request]
                if ($Item.Request -eq '/policies/authorizationPolicy') {
                    $body = ConvertFrom-MbcJson -Json '{"defaultUserRolePermissions":{"allowedToCreateApps":true}}'
                }
                New-MbcFetchResult -Ok $true -Body $body -Status 200
            }
            $r = (Invoke-MbcRun -Baseline $script:Baseline -Fetch $fetch).Results | Where-Object Id -eq 'ORG-001'
            $r.Verdict | Should -Be 'Fail'
            $r.Actual | Should -BeTrue
            $r.HasActual | Should -BeTrue
        }

        It 'never lets a failed collection become a Pass, whatever the operator' {
            $failing = { param($Item) New-MbcFetchResult -Ok $false -Status 403 -Cause 'permission missing' -Detail 'HTTP 403' }
            foreach ($op in $script:MbcOperators) {
                $preset = Copy-Preset
                $preset['checks'] = @($preset['checks'][0])
                $preset['checks'][0]['operator'] = $op
                $run = Invoke-MbcRun -Baseline ([pscustomobject]@{ Document = [ordered]@{ preset = $preset; expected = [ordered]@{ 'ORG-001' = @('x') } } }) -Fetch $failing
                $run.Results[0].Verdict | Should -Be 'Error' -Because "$op must not pass on a failed collection"
                $run.Results[0].Cause | Should -Be 'permission missing'
                $run.Results[0].HasActual | Should -BeFalse
            }
        }

        It 'reports a missing setting as an Error' {
            $empty = { param($Item) New-MbcFetchResult -Ok $true -Body ([ordered]@{}) -Status 200 }
            $r = (Invoke-MbcRun -Baseline $script:Baseline -Fetch $empty).Results | Where-Object Id -eq 'ORG-001'
            $r.Verdict | Should -Be 'Error'
            $r.Cause | Should -Be 'setting not found'
        }

        It 'treats a cmdlet that returned nothing as an empty value list' {
            $none = { param($Item) New-MbcFetchResult -Ok $true -Body ([ordered]@{ value = @() }) -Status 200 }
            $r = (Invoke-MbcRun -Baseline $script:Baseline -Fetch $none).Results | Where-Object Id -eq 'EXO-001'
            $r.Verdict | Should -Be 'Error'
            $r.Cause | Should -Be 'setting not found'
        }

        It 'refuses a check whose request is not declared, without fetching it' {
            $preset = Copy-Preset
            $preset['checks'][0]['request'] = '/users'
            $run = Invoke-MbcRun -Baseline ([pscustomobject]@{ Document = [ordered]@{ preset = $preset; expected = $script:Baseline.Document['expected'] } }) -Fetch $script:GoodFetch
            $r = $run.Results | Where-Object Id -eq 'ORG-001'
            $r.Verdict | Should -Be 'Error'
            $r.Cause | Should -Be 'request not declared'
            $script:Calls | Should -Not -Contain 'graph|v1.0|/users'
        }

        It 'reports progress for each request' {
            $events = [System.Collections.Generic.List[object]]::new()
            Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:GoodFetch -OnProgress { param($e) $events.Add($e) } | Out-Null
            @($events | Where-Object Phase -eq 'done').Count | Should -Be 3
            ($events | Where-Object Phase -eq 'done' | Select-Object -Last 1).Total | Should -Be 3
            ($events | Select-Object -First 1).Item.Request | Should -Be '/policies/authorizationPolicy'
        }

        It 'streams each result as soon as its request is in, and returns them in check order' {
            $seen = [System.Collections.Generic.List[string]]::new()
            $run = Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:GoodFetch -OnResult { param($r) $seen.Add($r.Id) }
            $seen -join ',' | Should -Be 'ORG-001,CA-001,EXO-001'
            @($run.Results | ForEach-Object Id) -join ',' | Should -Be 'ORG-001,CA-001,EXO-001'
        }

        It 'collects the inventory after the checks, when asked' {
            $order = [System.Collections.Generic.List[string]]::new()
            $fetch = { param($Item) $order.Add($Item.Request); New-MbcFetchResult -Ok $true -Body $script:Bodies[$Item.Request] -Status 200 }
            $run = Invoke-MbcRun -Baseline $script:Baseline -Fetch $fetch -Inventory { param($OnProgress) $order.Add('inventory'); 'the inventory' }
            $order[-1] | Should -Be 'inventory'
            $run.Inventory | Should -Be 'the inventory'
            (Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:GoodFetch).Inventory | Should -BeNullOrEmpty
        }

        It 'keeps empty and one-item lists as lists, in expected and actual values alike' {
            $preset = Copy-Preset
            $preset['checks'] = @($preset['checks'][1])
            $preset['checks'][0]['operator'] = 'equals'
            $one = { param($Item) New-MbcFetchResult -Ok $true -Body (ConvertFrom-MbcJson -Json '{"value":[{"state":"enabled","displayName":"Only"}]}') -Status 200 }
            $none = { param($Item) New-MbcFetchResult -Ok $true -Body (ConvertFrom-MbcJson -Json '{"value":[]}') -Status 200 }
            $b = [pscustomobject]@{ Document = [ordered]@{ preset = $preset; expected = [ordered]@{ 'CA-001' = @('Only') } } }
            $r = (Invoke-MbcRun -Baseline $b -Fetch $one).Results[0]
            $r.Verdict | Should -Be 'Pass' -Because 'a one-item list equals a one-item list'
            , $r.Actual | Should -BeOfType [object[]]
            , $r.Expected | Should -BeOfType [object[]]
            $r = (Invoke-MbcRun -Baseline $b -Fetch $none).Results[0]
            $r.Verdict | Should -Be 'Fail'
            , $r.Actual | Should -BeOfType [object[]]
            $r.Actual.Count | Should -Be 0
        }

        It 'counts verdicts' {
            $c = Get-MbcCounts -Results @([pscustomobject]@{ Verdict = 'Pass' }, [pscustomobject]@{ Verdict = 'Error' }, [pscustomobject]@{ Verdict = 'Error' })
            "$($c.Pass) $($c.Fail) $($c.Error) $($c.Total)" | Should -Be '1 0 2 3'
        }
    }

    Describe 'Output root and run IDs' {
        It 'creates logs and results under the root it is given' {
            $root = Get-MbcOutputRoot -Root (Join-Path $TestDrive 'out')
            Test-Path (Join-Path $root 'logs') | Should -BeTrue
            Test-Path (Join-Path $root 'results') | Should -BeTrue
        }
        It 'makes run IDs that sort by time and carry a stamp' {
            $id = New-MbcRunId
            $id | Should -Match '^\d{8}T\d{6}Z-[0-9a-f]{6}$'
            Get-MbcRunStamp -RunId $id | Should -Match '^\d{8}T\d{6}Z$'
        }
    }
}
