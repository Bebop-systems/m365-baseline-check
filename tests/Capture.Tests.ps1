BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Capturing expected values' {
        It 'uses the actual value for equals, a count for countAtLeast, and a list for in' {
            (Get-MbcCapturedExpected -Check ([ordered]@{ operator = 'equals' }) -Actual $false).Value | Should -BeFalse
            (Get-MbcCapturedExpected -Check ([ordered]@{ operator = 'countAtLeast' }) -Actual @('a', 'b')).Value | Should -Be 2
            $in = (Get-MbcCapturedExpected -Check ([ordered]@{ operator = 'in' }) -Actual 'none').Value
            $in.GetType().IsArray | Should -BeTrue
            $in[0] | Should -Be 'none'
        }
        It 'declines to guess for matches, contains and notEquals' {
            foreach ($op in 'matches', 'contains', 'notEquals') {
                $r = Get-MbcCapturedExpected -Check ([ordered]@{ operator = $op }) -Actual 'x'
                $r.Include | Should -BeFalse
                $r.Note | Should -BeLike '*by hand*'
            }
        }
        It 'needs no expected value for exists and absent' {
            $r = Get-MbcCapturedExpected -Check ([ordered]@{ operator = 'exists' }) -Actual 'x'
            $r.Include | Should -BeFalse
            $r.Note | Should -BeNullOrEmpty
        }
    }

    Describe 'New-BaselineCapture' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            $script:Bodies = @{
                '/policies/authorizationPolicy'        = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/authorizationPolicy.json')))
                '/identity/conditionalAccess/policies' = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/conditionalAccessPolicies.json')))
                'Get-OrganizationConfig'               = ConvertFrom-MbcJson -Json '{"value":[{"AuditDisabled":true}]}'
            }
            $script:Fetch = { param($Item) New-MbcFetchResult -Ok $true -Body $script:Bodies[$Item.Request] -Status 200 }
        }
        It 'writes a draft, Graph and cmdlet values alike, that validates and can be sealed' {
            $out = Join-Path $TestDrive 'draft.json'
            New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath $out -Name 'Drafted' -Fetch $script:Fetch -InformationAction SilentlyContinue
            $b = Read-MbcBaseline -Path $out
            $b.Name | Should -Be 'Drafted'
            $b.SealState | Should -Be 'Unsealed'
            $b.Document['expected']['ORG-001'] | Should -BeFalse
            $b.Document['expected']['CA-001'] | Should -Be 1
            $b.Document['expected']['EXO-001'] | Should -BeTrue
            (Protect-Baseline -Path $out -InformationAction SilentlyContinue).SealState | Should -Be 'Sealed'
        }
        It 'leaves out what it could not read, and says so' {
            $out = Join-Path $TestDrive 'partial.json'
            $half = {
                param($Item)
                if ($Item.Source -eq 'exo') { return (New-MbcFetchResult -Ok $false -Cause 'not connected') }
                New-MbcFetchResult -Ok $true -Body $script:Bodies[$Item.Request] -Status 200
            }
            $info = New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath $out -Fetch $half 6>&1
            ($info -join "`n") | Should -BeLike '*EXO-001*not connected*'
            $doc = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText($out))
            $doc['expected'].Contains('EXO-001') | Should -BeFalse
        }
        It 'writes a relative path where PowerShell means it, and refuses a missing folder before reading anything' {
            $calls = @{ n = 0 }
            $counting = { param($Item) $calls.n++; & $script:Fetch $Item }
            Push-Location $TestDrive
            try {
                New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath 'relative-draft.json' -Fetch $counting -InformationAction SilentlyContinue
                Test-Path (Join-Path $TestDrive 'relative-draft.json') | Should -BeTrue
                $calls.n = 0
                { New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath 'no-such-folder/draft.json' -Fetch $counting } | Should -Throw "*There's no folder*no-such-folder*"
                $calls.n | Should -Be 0 -Because 'a draft that cannot be written must not cost a sign-in and a read'
            }
            finally { Pop-Location }
        }
        It 'will not overwrite a file unless told to' {
            $out = Join-Path $TestDrive 'exists.json'
            [System.IO.File]::WriteAllText($out, '{}')
            { New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath $out -Fetch $script:Fetch } | Should -Throw '*already exists*'
            { New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath $out -Fetch $script:Fetch -Force -InformationAction SilentlyContinue } | Should -Not -Throw
        }
        It 'explains an invalid preset' {
            $bad = Join-Path $TestDrive 'bad-preset.json'
            [System.IO.File]::WriteAllText($bad, '{"schemaVersion":1,"name":"x","scopes":[],"endpoints":[],"checks":[]}')
            { New-BaselineCapture -PresetPath $bad -OutputPath (Join-Path $TestDrive 'x.json') -Fetch $script:Fetch } | Should -Throw "*isn't a valid preset*"
        }
    }
}
