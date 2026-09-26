BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The run log' {
        BeforeEach {
            $script:Digest = 'a1b2c3d4e5f6' + ('0' * 52)
            $script:Log = New-MbcRunLog -Directory $TestDrive -RunId '20260101T000000Z-abcdef' -Digest $script:Digest
        }
        It 'writes one canonical JSON object per line, numbered, each naming the baseline' {
            Write-MbcLog -Log $script:Log -EventName 'run.start' -Data @{ tool = '0.1.0' }
            Write-MbcLog -Log $script:Log -EventName 'check' -Data @{ id = 'CA-001'; verdict = 'Pass' }
            $lines = [System.IO.File]::ReadAllLines($script:Log.Path)
            $lines.Count | Should -Be 2
            $second = ConvertFrom-MbcJson -Json $lines[1]
            $second['seq'] | Should -Be 2
            $second['event'] | Should -Be 'check'
            $second['baseline'] | Should -Be $script:Digest -Because 'every line carries the full digest'
            $second['fingerprint'] | Should -Be 'a1b2c3d4e5f6'
        }
        It 'records the source and parameters of a request' {
            Write-MbcLog -Log $script:Log -EventName 'request' -Data @{ source = 'exo'; request = 'Get-OrganizationConfig'; parameters = [ordered]@{ Identity = 'Default' } }
            $entry = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllLines($script:Log.Path)[0])
            $entry['source'] | Should -Be 'exo'
            $entry['parameters']['Identity'] | Should -Be 'Default'
        }
        It 'truncates a large value and says so' {
            Write-MbcLog -Log $script:Log -EventName 'check' -Data @{ actual = ('x' * 5000) }
            $entry = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllLines($script:Log.Path)[0])
            $entry['actual']['truncated'] | Should -BeTrue
            $entry['actual']['length'] | Should -BeGreaterThan 5000
        }
        It 'refuses a field of its own that is named like a secret' {
            { Write-MbcLog -Log $script:Log -EventName 'x' -Data @{ accessToken = 'abc' } } | Should -Throw '*never logged*'
            { Write-MbcLog -Log $script:Log -EventName 'x' -Data @{ keyId = '3f2a9c1e' } } | Should -Not -Throw
        }
        It 'withholds secret-looking values inside tenant data, without stopping the run' {
            $actual = @([ordered]@{ displayName = 'Deploy'; secretText = 'abc123' }, [ordered]@{ key = 'AAAA'; value = 'x' })
            { Write-MbcLog -Log $script:Log -EventName 'check' -Data @{ actual = $actual; parameters = @{ Authorization = 'Bearer y' } } } | Should -Not -Throw
            $text = [System.IO.File]::ReadAllText($script:Log.Path)
            $text | Should -Not -BeLike '*abc123*'
            $text | Should -Not -BeLike '*AAAA*'
            $text | Should -Not -BeLike '*Bearer*'
            $text | Should -BeLike '*"displayName":"Deploy"*'
            $text | Should -BeLike '*"secretText":"`[withheld`]"*'
        }
        It 'does nothing when there is no log' {
            { Write-MbcLog -Log $null -EventName 'x' } | Should -Not -Throw
        }
    }
}
