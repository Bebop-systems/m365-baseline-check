BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The GET-only Graph client' {
        BeforeAll {
            $script:NoSleep = { param($Seconds, $OnTick) $null = $Seconds, $OnTick }
            function script:New-Response([int] $Status, [string] $Body, [string] $RetryAfter) {
                [pscustomobject]@{ Status = $Status; Body = $Body; RetryAfter = $RetryAfter }
            }
        }

        It 'builds the URI from the API version and path, and parses the body' {
            $seen = [System.Collections.Generic.List[string]]::new()
            $transport = { param($Uri) $seen.Add($Uri); New-Response 200 '{"a":1.5}' $null }
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/policies/authorizationPolicy' -Transport $transport
            $seen[0] | Should -Be 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy'
            $r.Ok | Should -BeTrue
            $r.Body['a'] | Should -Be 1.5
        }

        It 'follows nextLink and joins the pages into one value list' {
            $pages = @{
                'https://graph.microsoft.com/beta/things'                 = '{"value":[{"n":1}],"@odata.nextLink":"https://graph.microsoft.com/beta/things?$skiptoken=2"}'
                'https://graph.microsoft.com/beta/things?$skiptoken=2' = '{"value":[{"n":2}]}'
            }
            $transport = { param($Uri) New-Response 200 $pages[$Uri] $null }
            $r = Invoke-MbcGraphGet -ApiVersion 'beta' -Request '/things' -Transport $transport
            $r.Body['value'].Count | Should -Be 2
            $r.Body.Contains('@odata.nextLink') | Should -BeFalse
            $r.Pages | Should -Be 2
        }

        It 'reports each page to the tick callback, so a spinner can move between pages' {
            $pages = @{
                'https://graph.microsoft.com/v1.0/things'                 = '{"value":[],"@odata.nextLink":"https://graph.microsoft.com/v1.0/things?$skiptoken=2"}'
                'https://graph.microsoft.com/v1.0/things?$skiptoken=2' = '{"value":[]}'
            }
            $ticks = @{ n = 0 }
            $transport = { param($Uri) New-Response 200 $pages[$Uri] $null }
            Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/things' -Transport $transport -OnTick { $ticks.n++ } | Out-Null
            $ticks.n | Should -BeGreaterOrEqual 2
        }

        It 'stops at the page cap and says so' {
            $transport = { param($Uri) New-Response 200 '{"value":[1],"@odata.nextLink":"https://graph.microsoft.com/v1.0/x?$skiptoken=n"}' $null }
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Transport $transport -MaxPages 3
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'too many pages'
        }

        It 'refuses a nextLink that points anywhere but Graph' {
            $transport = { param($Uri) New-Response 200 '{"value":[],"@odata.nextLink":"https://example.com/steal"}' $null }
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/things' -Transport $transport
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'malformed response'
        }

        It 'waits and retries on 429, honouring Retry-After' {
            $state = @{ n = 0 }
            $waits = [System.Collections.Generic.List[int]]::new()
            $transport = {
                param($Uri)
                $state.n++
                if ($state.n -lt 3) { New-Response 429 '' '2' } else { New-Response 200 '{}' $null }
            }
            $sleep = { param($Seconds, $OnTick) $waits.Add($Seconds) }
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Transport $transport -Sleep $sleep
            $r.Ok | Should -BeTrue
            ($waits -join ',') | Should -Be '2,2'
        }

        It 'caps a long Retry-After at 30 seconds' {
            $state = @{ n = 0 }
            $waits = [System.Collections.Generic.List[int]]::new()
            $transport = { param($Uri) $state.n++; if ($state.n -eq 1) { New-Response 429 '' '120' } else { New-Response 200 '{}' $null } }
            Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Transport $transport -Sleep { param($Seconds, $OnTick) $waits.Add($Seconds) } | Out-Null
            $waits[0] | Should -Be 30
        }

        It 'gives up after three retries and calls it throttled' {
            $transport = { param($Uri) New-Response 429 '' '1' }
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Transport $transport -Sleep $script:NoSleep
            $r.Cause | Should -Be 'throttled'
        }

        It 'maps <Status> to <Cause>' -ForEach @(
            @{ Status = 401; Cause = 'permission missing' }
            @{ Status = 403; Cause = 'permission missing' }
            @{ Status = 404; Cause = 'not found' }
            @{ Status = 400; Cause = 'request rejected' }
            @{ Status = 500; Cause = 'service error' }
        ) {
            $s = $Status
            $transport = { param($Uri) New-Response $s '{}' $null }
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Transport $transport -Sleep $script:NoSleep).Cause | Should -Be $Cause
        }

        It 'calls an unparseable body a malformed response' {
            $transport = { param($Uri) New-Response 200 '<html>' $null }
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Transport $transport).Cause | Should -Be 'malformed response'
        }

        It 'calls a missing sign-in not connected' {
            $transport = { param($Uri) throw 'Authentication needed. Please call Connect-MgGraph.' }
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Transport $transport).Cause | Should -Be 'not connected'
        }

        It 'rejects anything that is not a plain Graph path, without sending it' {
            $never = { param($Uri) throw 'must not be called' }
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request 'https://example.com/x' -Transport $never).Cause | Should -Be 'request rejected'
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/a/../b' -Transport $never).Cause | Should -Be 'request rejected'
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/a/%2e%2e/b' -Transport $never).Cause | Should -Be 'request rejected'
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/a b' -Transport $never).Cause | Should -Be 'request rejected'
        }

        It 'logs the request with its source, status and pages' {
            $log = New-MbcRunLog -Directory $TestDrive -RunId '20260101T000000Z-graph1'
            Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Transport { param($Uri) New-Response 200 '{}' $null } -Log $log | Out-Null
            $entry = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllLines($log.Path)[0])
            $entry['event'] | Should -Be 'request'
            $entry['source'] | Should -Be 'graph'
            $entry['status'] | Should -Be 200
            $entry['pages'] | Should -Be 1
            $entry.Contains('properties') | Should -BeTrue
        }
    }

    Describe 'Waiting in slices' {
        It 'sleeps in short slices and ticks through the wait' {
            $ticks = @{ n = 0 }
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            Wait-MbcSeconds -Seconds 0.35 -OnTick { $ticks.n++ }
            $clock.ElapsedMilliseconds | Should -BeGreaterOrEqual 300
            $ticks.n | Should -BeGreaterOrEqual 3
        }
    }
}
