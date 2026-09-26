BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Extractor purity' {
        It 'allows a pure extractor' {
            @(Test-MbcExtractorPurity -Path (Join-Path $script:ModuleRoot 'tests/fixtures/extractors/pure.ps1')) | Should -BeNullOrEmpty
        }
        It 'names every impure thing in an impure one' {
            $problems = (Test-MbcExtractorPurity -Path (Join-Path $script:ModuleRoot 'tests/fixtures/extractors/impure.ps1')) -join "`n"
            $problems | Should -Match 'Invoke-RestMethod'
            $problems | Should -Match 'System.IO.File'
            $problems | Should -Match 'computed name'
        }
    }

    Describe 'Running an extractor' {
        BeforeAll {
            $script:Response = ConvertFrom-MbcJson -Json '{"value":[{"state":"enabled","grantControls":{"builtInControls":["block"]}}]}'
            $script:FixtureRoot = Join-Path $script:ModuleRoot 'tests/fixtures'
        }
        It 'returns the value of a pure extractor' {
            $r = Invoke-MbcExtractor -RelativePath 'extractors/pure.ps1' -Response $script:Response -Root $script:FixtureRoot
            $r.Ok | Should -BeTrue
            $r.Value | Should -BeTrue
        }
        It 'refuses an impure extractor without running it' {
            $r = Invoke-MbcExtractor -RelativePath 'extractors/impure.ps1' -Response $script:Response -Root $script:FixtureRoot
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'extractor not allowed'
        }
        It 'reports a missing extractor as not allowed' {
            (Invoke-MbcExtractor -RelativePath 'extractors/nope.ps1' -Response $script:Response -Root $script:FixtureRoot).Cause | Should -Be 'extractor not allowed'
        }
        It 'reports an extractor that throws as failed' {
            $dir = Join-Path $TestDrive 'extractors'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'boom.ps1') -Value "param(`$Response)`nthrow 'nope'" -Encoding utf8NoBOM
            $r = Invoke-MbcExtractor -RelativePath 'extractors/boom.ps1' -Response $script:Response -Root $TestDrive
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'extractor failed'
        }
    }
}
