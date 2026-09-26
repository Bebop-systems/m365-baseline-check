BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Strict JSON parsing' {
        It 'keeps key order and returns ordered dictionaries' {
            $v = ConvertFrom-MbcJson -Json '{"b":1,"a":2}'
            $v | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
            @($v.Keys) -join ',' | Should -Be 'b,a'
        }
        It 'returns whole numbers as Int64' {
            (ConvertFrom-MbcJson -Json '{"n":42}')['n'] | Should -BeOfType [long]
        }
        It 'rejects a fractional number unless floats are allowed' {
            { ConvertFrom-MbcJson -Json '{"n":1.5}' } | Should -Throw '*whole numbers*'
            (ConvertFrom-MbcJson -Json '{"n":1.5}' -AllowFloat)['n'] | Should -Be 1.5
        }
        It 'rejects duplicate keys' {
            { ConvertFrom-MbcJson -Json '{"a":1,"a":2}' } | Should -Throw '*Duplicate key*'
        }
        It 'rejects keys that differ only in letter case' {
            { ConvertFrom-MbcJson -Json '{"a":1,"A":2}' } | Should -Throw '*differ only in letter case*'
        }
        It 'rejects invalid JSON with a readable message' {
            { ConvertFrom-MbcJson -Json '{"a":' } | Should -Throw '*Not valid JSON*'
        }
        It 'returns arrays intact, including empty and single-element ones' {
            $one = ConvertFrom-MbcJson -Json '[7]'
            $one.GetType().IsArray | Should -BeTrue
            $one.Count | Should -Be 1
            $none = ConvertFrom-MbcJson -Json '[]'
            $none.GetType().IsArray | Should -BeTrue
            $none.Count | Should -Be 0
        }
        It 'returns null for a JSON null' {
            ConvertFrom-MbcJson -Json 'null' | Should -BeNullOrEmpty
        }
    }

    Describe 'Canonical JSON' {
        It 'sorts keys at every depth and drops whitespace' {
            $v = ConvertFrom-MbcJson -Json '{ "b": { "d": 1, "c": [true, null, "x"] }, "a": 0 }'
            ConvertTo-MbcCanonicalJson -Value $v | Should -BeExactly '{"a":0,"b":{"c":[true,null,"x"],"d":1}}'
        }
        It 'gives the same text for the same content however it was written' {
            $one = ConvertFrom-MbcJson -Json '{"a":1,"b":[1,2]}'
            $two = ConvertFrom-MbcJson -Json "{`n  `"b`": [1, 2],`n  `"a`": 1`n}"
            (ConvertTo-MbcCanonicalJson $one) | Should -BeExactly (ConvertTo-MbcCanonicalJson $two)
        }
        It 'escapes only what JSON requires, and keeps non-ASCII text literal' {
            ConvertTo-MbcCanonicalJson -Value "a`"b\c`n`t$([char]1)é·" | Should -BeExactly '"a\"b\\c\n\t\u0001é·"'
        }
        It 'accepts PSCustomObject and sorts its properties' {
            ConvertTo-MbcCanonicalJson -Value ([pscustomobject]@{ z = 1; y = 'q' }) | Should -BeExactly '{"y":"q","z":1}'
        }
        It 'refuses a type it cannot represent' {
            { ConvertTo-MbcCanonicalJson -Value ([datetime]::UtcNow) } | Should -Throw '*Cannot canonicalise*'
        }
        It 'formats doubles invariantly and refuses NaN' {
            ConvertTo-MbcCanonicalJson -Value 1.5 | Should -BeExactly '1.5'
            { ConvertTo-MbcCanonicalJson -Value ([double]::NaN) } | Should -Throw
        }
    }

    Describe 'Pretty JSON' {
        It 'keeps insertion order, indents by two, and ends with a newline' {
            $v = [ordered]@{ b = 1; a = @('x', 'y'); c = [ordered]@{} }
            ConvertTo-MbcPrettyJson -Value $v | Should -BeExactly "{`n  `"b`": 1,`n  `"a`": [`n    `"x`",`n    `"y`"`n  ],`n  `"c`": {}`n}`n"
        }
        It 'round-trips through the strict parser to the same canonical form' {
            $v = ConvertFrom-MbcJson -Json '{"k":[1,{"z":null,"y":false}],"s":"t"}'
            $again = ConvertFrom-MbcJson -Json (ConvertTo-MbcPrettyJson -Value $v)
            (ConvertTo-MbcCanonicalJson $again) | Should -BeExactly (ConvertTo-MbcCanonicalJson $v)
        }
    }

    Describe 'SHA-256' {
        It 'matches the published test vector for "abc"' {
            Get-MbcSha256Hex -Text 'abc' | Should -BeExactly 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        }
        It 'hashes raw bytes the same way' {
            Get-MbcSha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes('abc')) | Should -BeExactly 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        }
    }
}
