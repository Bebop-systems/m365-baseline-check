BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    BeforeAll {
        . (Join-Path $script:ModuleRoot 'tests/TestHelpers.ps1')
    }

    Describe 'Team keys' {
        It 'makes keys that parse back to 32 bytes with a matching ID' {
            $text = New-MbcTeamKeyText
            $text | Should -Match '^mbc-key:1:[0-9a-f]{8}:[A-Za-z0-9_-]{43}$'
            $k = ConvertFrom-MbcTeamKeyText -Text $text
            $k.Bytes.Length | Should -Be 32
            $text | Should -BeLike "mbc-key:1:$($k.KeyId):*"
        }
        It 'notices a mistyped key, and a key that is not one' {
            $text = New-MbcTeamKeyText
            $broken = $text.Substring(0, $text.Length - 1) + $(if ($text[-1] -ceq 'A') { 'B' } else { 'A' })
            { ConvertFrom-MbcTeamKeyText -Text $broken } | Should -Throw '*mistyped*'
            { ConvertFrom-MbcTeamKeyText -Text 'hello' } | Should -Throw "*isn't a team key*"
            { ConvertFrom-MbcTeamKeyText -Text 'mbc-key:1:ABCDEF12:' } | Should -Throw "*isn't a team key*"
        }
        It 'tolerates surrounding whitespace, as pasted from a password manager' {
            $text = New-MbcTeamKeyText
            (ConvertFrom-MbcTeamKeyText -Text "  $text`n").Bytes.Length | Should -Be 32
        }
    }

    Describe 'Locking and unlocking' {
        BeforeAll {
            $script:Key = ConvertFrom-MbcTeamKeyText -Text (New-MbcTeamKeyText)
            $script:Header = [ordered]@{ baseline = [ordered]@{ name = 'B'; version = 3L; fingerprint = 'a1b2c3d4e5f6' }; runUtc = '2026-01-01T00:00:00Z'; tool = '0.1.0' }
        }
        It 'round-trips the payload' {
            $env = Protect-MbcPayload -KeyBytes $script:Key.Bytes -Header $script:Header -PayloadText 'secret payload'
            Unprotect-MbcPayload -Envelope $env -KeyBytes $script:Key.Bytes | Should -BeExactly 'secret payload'
        }
        It 'says which key a file needs when given another' {
            $env = Protect-MbcPayload -KeyBytes $script:Key.Bytes -Header $script:Header -PayloadText 'x'
            $other = ConvertFrom-MbcTeamKeyText -Text (New-MbcTeamKeyText)
            { Unprotect-MbcPayload -Envelope $env -KeyBytes $other.Bytes } | Should -Throw "*needs key $($script:Key.KeyId)*"
        }
        It 'refuses a file whose readable header was altered' {
            $env = Protect-MbcPayload -KeyBytes $script:Key.Bytes -Header $script:Header -PayloadText 'x'
            $env['header']['baseline']['fingerprint'] = 'ffffffffffff'
            { Unprotect-MbcPayload -Envelope $env -KeyBytes $script:Key.Bytes } | Should -Throw '*altered or damaged*'
        }
        It 'refuses a file whose ciphertext was altered' {
            $env = Protect-MbcPayload -KeyBytes $script:Key.Bytes -Header $script:Header -PayloadText 'xyzxyzxyz'
            $bytes = [Convert]::FromBase64String($env['ciphertext'])
            $bytes[0] = $bytes[0] -bxor 1
            $env['ciphertext'] = [Convert]::ToBase64String($bytes)
            { Unprotect-MbcPayload -Envelope $env -KeyBytes $script:Key.Bytes } | Should -Throw '*altered or damaged*'
        }
        It 'checks the structure before doing any cryptography' {
            $path = Join-Path $TestDrive 'bad.locked'
            [System.IO.File]::WriteAllText($path, '{"format":"m365bc-locked","version":1}')
            { Read-MbcLockedFile -Path $path } | Should -Throw "*isn't a locked result*"
        }
    }

    Describe 'Exporting, and Unlock-Result' {
        BeforeAll {
            $script:View = New-TestView
            $script:Doc = $script:View.Document
            $script:KeyText = New-MbcTeamKeyText
            function script:New-Dir([string] $Name) { $d = Join-Path $TestDrive $Name; New-Item -ItemType Directory -Path $d | Out-Null; $d }
        }
        It 'refuses to export without a key unless told to write plaintext' {
            { Export-MbcRunFiles -Document $script:Doc -Directory (New-Dir 'nokey') } | Should -Throw '*-NoLock*'
        }
        It 'writes one locked bundle and a plaintext summary by default' {
            $dir = New-Dir 'locked'
            $files = Export-MbcRunFiles -Document $script:Doc -Directory $dir -KeyText $script:KeyText
            Split-Path -Leaf $files.Locked | Should -Be 'result-20260926T141200Z.locked'
            Split-Path -Leaf $files.Summary | Should -Be 'summary-20260926T141200Z.md'
            @(Get-ChildItem $dir -File | ForEach-Object Name | Sort-Object) -join ',' | Should -Be 'result-20260926T141200Z.locked,summary-20260926T141200Z.md'
        }
        It 'keeps a readable header that names the baseline and the key, and nothing from the tenant' {
            $dir = New-Dir 'header'
            $files = Export-MbcRunFiles -Document $script:Doc -Directory $dir -KeyText $script:KeyText
            $env = Read-MbcLockedFile -Path $files.Locked
            $env['header']['baseline']['fingerprint'] | Should -Be $script:View.Baseline.Fingerprint
            $env['keyId'] | Should -Be (ConvertFrom-MbcTeamKeyText -Text $script:KeyText).KeyId
            [System.IO.File]::ReadAllText($files.Locked).IndexOf('SENTINEL') | Should -Be -1
        }
        It 'can lock the summary too' {
            $dir = New-Dir 'all-locked'
            $files = Export-MbcRunFiles -Document $script:Doc -Directory $dir -KeyText $script:KeyText -LockSummary
            $files.Summary | Should -BeNullOrEmpty
            @(Get-ChildItem $dir -File).Count | Should -Be 1
        }
        It 'writes the five parts in plaintext with -NoLock' {
            $dir = New-Dir 'plain'
            Export-MbcRunFiles -Document $script:Doc -Directory $dir -NoLock | Out-Null
            @(Get-ChildItem $dir -File | ForEach-Object Name | Sort-Object) -join ',' |
                Should -Be 'apps-20260926T141200Z.csv,report-20260926T141200Z.txt,result-20260926T141200Z.csv,result-20260926T141200Z.json,summary-20260926T141200Z.md'
            $again = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $dir 'result-20260926T141200Z.json'))) -AllowFloat
            Test-MbcResultSeal -Document $again | Should -BeTrue
        }
        It 'unlocks to memory, with every part, and writes plaintext only when asked' {
            $dir = New-Dir 'unlock'
            $files = Export-MbcRunFiles -Document $script:Doc -Directory $dir -KeyText $script:KeyText
            $secure = ConvertTo-SecureString -String $script:KeyText -AsPlainText -Force
            $opened = Unlock-Result -Path $files.Locked -Key $secure
            @($opened.Files.Keys) -join ',' | Should -Be 'result.json,result.csv,apps.csv,report.txt,summary.md'
            $opened.View.Results.Count | Should -Be 3
            $opened.Files['report.txt'] | Should -BeLike '*Needs attention*'
            @(Get-ChildItem $dir -Filter '*.json').Count | Should -Be 0
            $out = New-Dir 'unlocked-plain'
            Unlock-Result -Path $files.Locked -Key $secure -OutputDirectory $out -InformationAction SilentlyContinue | Out-Null
            @(Get-ChildItem $out -File).Count | Should -Be 5
        }
        It 'refuses a bundle whose result no longer matches its own seal' {
            $key = ConvertFrom-MbcTeamKeyText -Text $script:KeyText
            $tampered = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson $script:Doc) -AllowFloat
            $tampered['counts']['pass'] = 42L
            $parts = [ordered]@{ 'result.json' = (ConvertTo-MbcPrettyJson $tampered); 'result.csv' = ''; 'apps.csv' = ''; 'report.txt' = ''; 'summary.md' = '' }
            $env = Protect-MbcPayload -KeyBytes $key.Bytes -Header ([ordered]@{ tool = '0.1.0' }) -PayloadText (ConvertTo-MbcCanonicalJson $parts)
            $path = Join-Path $TestDrive 'tampered.locked'
            [System.IO.File]::WriteAllText($path, (ConvertTo-MbcPrettyJson $env))
            { Open-MbcLockedResult -Path $path -KeyText $script:KeyText } | Should -Throw '*does not match its own seal*'
        }
    }
}
