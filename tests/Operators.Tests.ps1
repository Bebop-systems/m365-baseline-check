BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Operators' {
        It '<Operator> on <Label> gives <Verdict>' -ForEach @(
            @{ Operator = 'equals';       Label = 'equal strings';           Actual = 'enabled';             Expected = 'Enabled';            Verdict = 'Pass' }
            @{ Operator = 'equals';       Label = 'different strings';       Actual = 'disabled';            Expected = 'enabled';            Verdict = 'Fail' }
            @{ Operator = 'equals';       Label = 'equal objects';           Actual = ([ordered]@{ a = 1 }); Expected = ([ordered]@{ a = 1 }); Verdict = 'Pass' }
            @{ Operator = 'notEquals';    Label = 'different booleans';      Actual = $true;                 Expected = $false;               Verdict = 'Pass' }
            @{ Operator = 'in';           Label = 'a listed value';          Actual = 'none';                Expected = @('none', 'admins');  Verdict = 'Pass' }
            @{ Operator = 'in';           Label = 'an unlisted value';       Actual = 'everyone';            Expected = @('none', 'admins');  Verdict = 'Fail' }
            @{ Operator = 'contains';     Label = 'a present member';        Actual = @('a', 'b');           Expected = 'b';                  Verdict = 'Pass' }
            @{ Operator = 'setEquals';    Label = 'same members, reordered'; Actual = @('b', 'a', 'a');      Expected = @('a', 'b');          Verdict = 'Pass' }
            @{ Operator = 'setEquals';    Label = 'an extra member';         Actual = @('a', 'b', 'sms');    Expected = @('a', 'b');          Verdict = 'Fail' }
            @{ Operator = 'subsetOf';     Label = 'a subset';                Actual = @('a');                Expected = @('a', 'b');          Verdict = 'Pass' }
            @{ Operator = 'subsetOf';     Label = 'an empty list';           Actual = @();                   Expected = @('a');               Verdict = 'Pass' }
            @{ Operator = 'countAtLeast'; Label = 'enough';                  Actual = @(1, 2);               Expected = 2L;                   Verdict = 'Pass' }
            @{ Operator = 'countAtMost';  Label = 'too many';                Actual = @(1, 2, 3);            Expected = 2L;                   Verdict = 'Fail' }
            @{ Operator = 'matches';      Label = 'a matching string';       Actual = 'Example-Admin';       Expected = '^example-';          Verdict = 'Pass' }
        ) {
            (Compare-MbcValue -Actual $Actual -Operator $Operator -Expected $Expected).Verdict | Should -Be $Verdict
        }

        It 'honours caseSensitive' {
            (Compare-MbcValue -Actual 'Enabled' -Operator 'equals' -Expected 'enabled' -CaseSensitive).Verdict | Should -Be 'Fail'
        }

        It 'compares objects with the same case rule as text' {
            $actual = [ordered]@{ state = 'Enabled' }
            $expected = [ordered]@{ state = 'enabled' }
            (Compare-MbcValue -Actual $actual -Operator 'equals' -Expected $expected).Verdict | Should -Be 'Pass'
            (Compare-MbcValue -Actual $actual -Operator 'equals' -Expected $expected -CaseSensitive).Verdict | Should -Be 'Fail'
        }

        It 'finds an object in a list case-insensitively by default' {
            $actual = @(([ordered]@{ id = 1; name = 'Admin' }), ([ordered]@{ id = 2; name = 'User' }))
            (Compare-MbcValue -Actual $actual -Operator 'contains' -Expected ([ordered]@{ id = 1; name = 'admin' })).Verdict | Should -Be 'Pass'
        }

        It 'ignores order when comparing sets of objects' {
            $actual = @(([ordered]@{ id = 1; name = 'Admin' }), ([ordered]@{ id = 2; name = 'User' }))
            $expected = @(([ordered]@{ id = 2; name = 'user' }), ([ordered]@{ id = 1; name = 'admin' }))
            (Compare-MbcValue -Actual $actual -Operator 'setEquals' -Expected $expected).Verdict | Should -Be 'Pass'
        }

        It 'reports the type-mismatch cause for equals in each direction' {
            (Compare-MbcValue -Actual 'x' -Operator 'equals' -Expected @('x')).Cause | Should -Be 'baseline expects a list'
            (Compare-MbcValue -Actual @('x') -Operator 'equals' -Expected 'x').Cause | Should -Be 'baseline expects a single value'
        }

        It 'treats exists and absent as questions about NotFound' {
            (Compare-MbcValue -Actual $script:MbcNotFound -Operator 'exists' -Expected $null).Verdict | Should -Be 'Fail'
            (Compare-MbcValue -Actual $null -Operator 'exists' -Expected $null).Verdict | Should -Be 'Pass'
            (Compare-MbcValue -Actual $script:MbcNotFound -Operator 'absent' -Expected $null).Verdict | Should -Be 'Pass'
            (Compare-MbcValue -Actual 'x' -Operator 'absent' -Expected $null).Verdict | Should -Be 'Fail'
        }

        It 'turns NotFound into an Error for <Operator>' -ForEach @(
            @{ Operator = 'equals' }, @{ Operator = 'notEquals' }, @{ Operator = 'in' }, @{ Operator = 'contains' },
            @{ Operator = 'setEquals' }, @{ Operator = 'subsetOf' }, @{ Operator = 'countAtLeast' },
            @{ Operator = 'countAtMost' }, @{ Operator = 'matches' }
        ) {
            $r = Compare-MbcValue -Actual $script:MbcNotFound -Operator $Operator -Expected @('x')
            $r.Verdict | Should -Be 'Error'
            $r.Cause | Should -Be 'setting not found'
        }

        It 'makes a type mismatch an Error, never a Fail' {
            $r = Compare-MbcValue -Actual 'x' -Operator 'countAtLeast' -Expected 1L
            $r.Verdict | Should -Be 'Error'
            $r.Cause | Should -Be 'baseline expects a list'
            (Compare-MbcValue -Actual @('x') -Operator 'in' -Expected @('x')).Cause | Should -Be 'baseline expects a single value'
        }

        It 'reports an invalid pattern as an Error' {
            (Compare-MbcValue -Actual 'x' -Operator 'matches' -Expected '(').Cause | Should -Be 'invalid pattern'
        }

        It 'only ever uses causes from the closed vocabulary' {
            $samples = @(
                (Compare-MbcValue -Actual $script:MbcNotFound -Operator 'equals' -Expected 1L),
                (Compare-MbcValue -Actual 'x' -Operator 'countAtLeast' -Expected 1L),
                (Compare-MbcValue -Actual @('x') -Operator 'equals' -Expected 'x'),
                (Compare-MbcValue -Actual 'x' -Operator 'matches' -Expected '(')
            )
            foreach ($s in $samples) { $script:MbcCauses | Should -Contain $s.Cause }
        }
    }
}
