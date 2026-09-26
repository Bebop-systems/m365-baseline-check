BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Sealing and verifying a baseline' {
        BeforeEach {
            $script:Path = Join-Path $TestDrive 'b.json'
            Copy-Item (Join-Path $script:ModuleRoot 'tests/fixtures/baseline-minimal.json') $script:Path -Force
        }

        It 'reads an unsealed baseline as Unsealed and refuses to use it' {
            $b = Read-MbcBaseline -Path $script:Path
            $b.SealState | Should -Be 'Unsealed'
            { Assert-MbcBaselineUsable -Baseline $b } | Should -Throw '*never been sealed*'
            { Assert-MbcBaselineUsable -Baseline $b -AllowUnsealed } | Should -Not -Throw
        }

        It 'seals, and the result reads as Sealed with a 12-character fingerprint' {
            $id = Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue
            $id.SealState | Should -Be 'Sealed'
            $id.Fingerprint | Should -Match '^[0-9a-f]{12}$'
            $id.Record | Should -BeExactly "Fixture baseline · v1 · SHA-256 $($id.Digest)"
            (Read-MbcBaseline -Path $script:Path).SealState | Should -Be 'Sealed'
        }

        It 'writes UTF-8 without a BOM, with LF line endings' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $bytes = [System.IO.File]::ReadAllBytes($script:Path)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
            ($bytes -contains [byte]13) | Should -BeFalse
        }

        It 'stays Sealed when only formatting or key order changes' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $doc = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText($script:Path))
            $reordered = [ordered]@{}
            foreach ($k in (@($doc.Keys) | Sort-Object -Descending)) { $reordered[$k] = $doc[$k] }
            [System.IO.File]::WriteAllText($script:Path, (ConvertTo-MbcCanonicalJson $reordered))
            (Read-MbcBaseline -Path $script:Path).SealState | Should -Be 'Sealed'
        }

        It 'reads an edited baseline as Modified, and refuses it' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $text = [System.IO.File]::ReadAllText($script:Path).Replace('"CA-001": 1', '"CA-001": 2')
            [System.IO.File]::WriteAllText($script:Path, $text)
            $b = Read-MbcBaseline -Path $script:Path
            $b.SealState | Should -Be 'Modified'
            { Assert-MbcBaselineUsable -Baseline $b } | Should -Throw '*edited since v1 was sealed*'
        }

        It 'refuses to reseal changed content under the same version, and reseals after a bump' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $text = [System.IO.File]::ReadAllText($script:Path).Replace('"CA-001": 1', '"CA-001": 2')
            [System.IO.File]::WriteAllText($script:Path, $text)
            { Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue } | Should -Throw '*Raise the version above 1*'
            [System.IO.File]::WriteAllText($script:Path, $text.Replace('"version": 1', '"version": 2'))
            (Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue).Version | Should -Be 2
        }

        It 'reports an unchanged, sealed baseline as already sealed and leaves it alone' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $before = [System.IO.File]::ReadAllText($script:Path)
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            [System.IO.File]::ReadAllText($script:Path) | Should -BeExactly $before
        }

        It 'checks an expected fingerprint' {
            $id = Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue
            $b = Read-MbcBaseline -Path $script:Path
            { Assert-MbcBaselineUsable -Baseline $b -ExpectedFingerprint $id.Fingerprint } | Should -Not -Throw
            { Assert-MbcBaselineUsable -Baseline $b -ExpectedFingerprint '000000000000' } | Should -Throw '*Fingerprint mismatch*'
            { Assert-MbcBaselineUsable -Baseline $b -ExpectedFingerprint 'xyz' } | Should -Throw '*at least 12 hex*'
        }

        It 'explains an invalid baseline instead of reading it' {
            [System.IO.File]::WriteAllText($script:Path, '{"schemaVersion":1}')
            { Read-MbcBaseline -Path $script:Path } | Should -Throw "*isn't a valid baseline*"
        }

        It 'Test-Baseline reports identity without changing anything' {
            $before = [System.IO.File]::ReadAllText($script:Path)
            $r = Test-Baseline -Path $script:Path -InformationAction SilentlyContinue
            $r.SealState | Should -Be 'Unsealed'
            [System.IO.File]::ReadAllText($script:Path) | Should -BeExactly $before
        }
    }
}
