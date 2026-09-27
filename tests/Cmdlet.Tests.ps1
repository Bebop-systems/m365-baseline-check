BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

BeforeAll {
    # Two stand-ins for the temporary modules an Exchange connection creates. Test code only.
    New-Module -Name 'tmpEXO_mbctest' -ScriptBlock {
        function Get-OrganizationConfig { [CmdletBinding()] param([string] $Identity) [pscustomobject]@{ Name = 'example.onmicrosoft.com'; AuditDisabled = $false; Identity = $Identity } }
        function Get-Nothing { [CmdletBinding()] param() }
        function Get-Many { [CmdletBinding()] param() foreach ($n in 1..3) { [pscustomobject]@{ N = $n } } }
        function Get-Denied { [CmdletBinding()] param() throw "The user isn't authorized to run this cmdlet." }
        function Get-Broken { [CmdletBinding()] param() throw [System.InvalidOperationException]::new('The service is unavailable.') }
        function Get-BoundKeys { [CmdletBinding()] param() Write-Warning 'noise from the service'; [pscustomobject]@{ Bound = (@($PSBoundParameters.Keys) -join ',') } }
        Export-ModuleMember -Function *
    } | Import-Module -Global -Force
    New-Module -Name 'tmpOther_mbctest' -ScriptBlock {
        function Get-Elsewhere { [CmdletBinding()] param() 'x' }
        Export-ModuleMember -Function *
    } | Import-Module -Global -Force
}

AfterAll {
    Remove-Module tmpEXO_mbctest, tmpOther_mbctest -Force -ErrorAction SilentlyContinue
}

InModuleScope M365BaselineCheck {
    Describe 'Flattening, once, one level' {
        It 'keeps null, strings, booleans, integers and doubles' {
            ConvertTo-MbcFlatValue -Value $null | Should -BeNullOrEmpty
            ConvertTo-MbcFlatValue -Value 'x' | Should -BeExactly 'x'
            ConvertTo-MbcFlatValue -Value $true | Should -BeTrue
            (ConvertTo-MbcFlatValue -Value 42).GetType().Name | Should -Be 'Int32'
            ConvertTo-MbcFlatValue -Value 1.5 | Should -Be 1.5
        }
        It 'turns enums into names, and dates into ISO 8601 UTC' {
            ConvertTo-MbcFlatValue -Value ([System.DayOfWeek]::Monday) | Should -BeExactly 'Monday'
            ConvertTo-MbcFlatValue -Value ([datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)) | Should -BeExactly '2026-01-02T03:04:05.0000000Z'
            ConvertTo-MbcFlatValue -Value ([datetimeoffset]::new(2026, 1, 2, 5, 4, 5, [TimeSpan]::FromHours(2))) | Should -BeExactly '2026-01-02T03:04:05.0000000Z'
        }
        It 'turns GUIDs and time spans into text' {
            ConvertTo-MbcFlatValue -Value ([guid]'00000000-0000-4000-8000-000000000001') | Should -BeExactly '00000000-0000-4000-8000-000000000001'
            ConvertTo-MbcFlatValue -Value ([TimeSpan]::FromMinutes(90)) | Should -BeExactly '01:30:00'
        }
        It 'turns a list into a list of scalars, showing anything complex as text' {
            $v = ConvertTo-MbcFlatValue -Value @('a', 2, [pscustomobject]@{ x = 1 })
            $v.GetType().IsArray | Should -BeTrue
            $v[0] | Should -Be 'a'
            $v[1] | Should -Be 2
            $v[2] | Should -BeExactly '@{x=1}'
        }
        It 'turns a dictionary into a map of scalars' {
            $v = ConvertTo-MbcFlatValue -Value ([ordered]@{ a = 1; b = [System.DayOfWeek]::Friday })
            $v['a'] | Should -Be 1
            $v['b'] | Should -BeExactly 'Friday'
        }
        It 'shows any other object as its text' {
            ConvertTo-MbcFlatValue -Value ([version]'1.2.3') | Should -BeExactly '1.2.3'
        }
        It 'flattens an object into an ordered map, in property order' {
            $flat = ConvertTo-MbcFlatObject -InputObject ([pscustomobject]@{ Zeta = 1; Alpha = @('x'); When = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc) })
            @($flat.Keys) -join ',' | Should -Be 'Zeta,Alpha,When'
            $flat['Alpha'][0] | Should -Be 'x'
            $flat['When'] | Should -Be '2026-01-01T00:00:00.0000000Z'
        }
        It 'always wraps output as a value list, for none, one or many objects' {
            (ConvertTo-MbcCmdletBody -Output @())['value'].Count | Should -Be 0
            (ConvertTo-MbcCmdletBody -Output @([pscustomobject]@{ A = 1 }))['value'].Count | Should -Be 1
            (ConvertTo-MbcCmdletBody -Output @(1..3 | ForEach-Object { [pscustomobject]@{ N = $_ } }))['value'].Count | Should -Be 3
            (ConvertTo-MbcCmdletBody -Output @())['value'].GetType().IsArray | Should -BeTrue
        }
        It 'survives canonical JSON, so it can go into a sealed result' {
            $body = ConvertTo-MbcCmdletBody -Output @([pscustomobject]@{ A = [System.DayOfWeek]::Monday; B = @(1, 'x'); C = $null })
            ConvertTo-MbcCanonicalJson $body | Should -BeExactly '{"value":[{"A":"Monday","B":[1,"x"],"C":null}]}'
        }
    }

    Describe 'The cmdlet guard' {
        BeforeAll {
            $script:Preset = [ordered]@{ cmdlets = [ordered]@{ exo = @('Get-OrganizationConfig', 'Get-Nothing', 'Get-Many', 'Get-Denied', 'Get-Broken', 'Get-Elsewhere', 'Get-BoundKeys', 'Set-Thing') } }
            $script:Sessions = [ordered]@{ exo = 'tmpEXO_mbctest' }
            $script:Ran = [System.Collections.Generic.List[string]]::new()
            $script:CountingRunner = { param($Command, $Parameters) $script:Ran.Add($Command.Name); Invoke-MbcCmdletRunner -Command $Command -Parameters $Parameters }
            function script:New-Item2([string] $Name, [System.Collections.IDictionary] $Parameters = [ordered]@{}, [string] $Source = 'exo') {
                [pscustomobject]@{ Key = 'k'; Source = $Source; ApiVersion = ''; Request = $Name; Parameters = $Parameters }
            }
            function script:Get-Via($Item, $Sessions = $script:Sessions) {
                Invoke-MbcCmdletGet -Item $Item -Preset $script:Preset -Sessions $Sessions -Runner $script:CountingRunner
            }
        }
        BeforeEach { $script:Ran.Clear() }

        It 'runs a declared Get- cmdlet from the session module and wraps what it returns' {
            $r = Get-Via (New-Item2 'Get-OrganizationConfig' ([ordered]@{ Identity = 'Default' }))
            $r.Ok | Should -BeTrue
            $r.Body['value'][0]['AuditDisabled'] | Should -BeFalse
            $r.Body['value'][0]['Identity'] | Should -Be 'Default'
            $script:Ran -join ',' | Should -Be 'Get-OrganizationConfig'
        }

        It 'returns an empty value list when the cmdlet returns nothing' {
            $r = Get-Via (New-Item2 'Get-Nothing')
            $r.Ok | Should -BeTrue
            $r.Body['value'].Count | Should -Be 0
        }

        It 'refuses <Why>, and runs nothing' -ForEach @(
            @{ Why = 'a name that is not Get-'; Name = 'Set-Thing'; Parameters = @{}; Cause = 'request rejected' }
            @{ Why = 'an undeclared cmdlet'; Name = 'Get-Mailbox'; Parameters = @{}; Cause = 'request not declared' }
            @{ Why = 'a cmdlet from another module'; Name = 'Get-Elsewhere'; Parameters = @{}; Cause = 'cmdlet not available' }
            @{ Why = 'an unknown parameter'; Name = 'Get-OrganizationConfig'; Parameters = @{ Force = $true }; Cause = 'request rejected' }
            @{ Why = 'a non-scalar value'; Name = 'Get-OrganizationConfig'; Parameters = @{ Identity = @('a', 'b') }; Cause = 'request rejected' }
        ) {
            $map = [ordered]@{}
            foreach ($k in $Parameters.Keys) { $map[$k] = $Parameters[$k] }
            $r = Get-Via (New-Item2 $Name $map)
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be $Cause
            $script:Ran.Count | Should -Be 0 -Because 'nothing runs unless every guard holds'
        }

        It 'says not connected when the source has no session, and runs nothing' {
            $r = Get-Via (New-Item2 'Get-OrganizationConfig') ([ordered]@{})
            $r.Cause | Should -Be 'not connected'
            $script:Ran.Count | Should -Be 0
        }

        It 'turns an authorisation failure into permission missing' {
            (Get-Via (New-Item2 'Get-Denied')).Cause | Should -Be 'permission missing'
        }

        It 'turns any other failure into cmdlet failed, naming the exception' {
            $r = Get-Via (New-Item2 'Get-Broken')
            $r.Cause | Should -Be 'cmdlet failed'
            $r.Detail | Should -BeLike '*The service is unavailable.*'
        }

        It 'passes the cmdlet no parameter it did not ask for, and keeps its warnings out of the console' {
            $all = @(Invoke-MbcCmdletGet -Item (New-Item2 'Get-BoundKeys') -Preset $script:Preset -Sessions $script:Sessions 3>&1)
            $r = $all | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
            $r.Ok | Should -BeTrue
            $r.Body['value'][0]['Bound'] | Should -Not -BeLike '*WarningAction*' -Because 'Exchange Online forwards bound parameters to the service'
            @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0 -Because 'a warning would write over the TUI'
        }

        It 'logs the source, the cmdlet and its parameters' {
            $log = New-MbcRunLog -Directory $TestDrive -RunId '20260101T000000Z-cmd001'
            Invoke-MbcCmdletGet -Item (New-Item2 'Get-Many') -Preset $script:Preset -Sessions $script:Sessions -Log $log | Out-Null
            $entry = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllLines($log.Path)[0])
            $entry['source'] | Should -Be 'exo'
            $entry['request'] | Should -Be 'Get-Many'
            $entry['objects'] | Should -Be 3
        }
    }
}
