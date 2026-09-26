BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The example preset and baseline' {
        BeforeAll {
            $script:PresetPath = Join-Path $script:ModuleRoot 'presets/example-tenant-hygiene.json'
            $script:BaselinePath = Join-Path $script:ModuleRoot 'presets/example-tenant-hygiene.baseline.json'
            $script:Preset = Read-MbcPreset -Path $script:PresetPath
            $script:Baseline = Read-MbcBaseline -Path $script:BaselinePath
        }
        It 'is a valid preset' {
            Test-MbcPresetShape -Preset $script:Preset | Should -BeNullOrEmpty
        }
        It 'ships a sealed baseline, unchanged since it was sealed' {
            $script:Baseline.SealState | Should -Be 'Sealed'
        }
        It 'uses exactly the example preset in its baseline' {
            ConvertTo-MbcCanonicalJson $script:Baseline.Document['preset'] | Should -BeExactly (ConvertTo-MbcCanonicalJson $script:Preset)
        }
        It 'covers several admin centres, with Graph and Exchange checks alike' {
            @($script:Preset['checks'] | ForEach-Object { $_['area'] } | Sort-Object -Unique).Count | Should -BeGreaterOrEqual 3
            @($script:Preset['checks'] | Where-Object { (Get-MbcCheckSource -Check $_) -eq 'graph' }).Count | Should -BeGreaterThan 0
            @($script:Preset['checks'] | Where-Object { (Get-MbcCheckSource -Check $_) -eq 'exo' }).Count | Should -BeGreaterThan 0
        }
        It 'asks only for read scopes' {
            foreach ($s in (Get-MbcSignInScopes -Preset $script:Preset)) { Test-MbcReadScope -Scope $s | Should -BeTrue }
        }
        It 'gives every check the portal''s wording and a reason' {
            foreach ($c in $script:Preset['checks']) {
                $c['why'] | Should -Not -BeNullOrEmpty -Because "$($c['id']) says why it matters"
            }
        }
    }
}
