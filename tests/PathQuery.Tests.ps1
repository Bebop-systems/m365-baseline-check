BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Scalar equality' {
        It 'compares strings case-insensitively unless asked' {
            Test-MbcScalarEqual -Left 'Enabled' -Right 'enabled' -CaseSensitive $false | Should -BeTrue
            Test-MbcScalarEqual -Left 'Enabled' -Right 'enabled' -CaseSensitive $true | Should -BeFalse
        }
        It 'never coerces between types' {
            Test-MbcScalarEqual -Left '1' -Right 1L -CaseSensitive $false | Should -BeFalse
            Test-MbcScalarEqual -Left $true -Right 'true' -CaseSensitive $false | Should -BeFalse
        }
        It 'treats null as equal only to null' {
            Test-MbcScalarEqual -Left $null -Right $null -CaseSensitive $false | Should -BeTrue
            Test-MbcScalarEqual -Left $null -Right '' -CaseSensitive $false | Should -BeFalse
        }
        It 'compares whole numbers and doubles numerically' {
            Test-MbcScalarEqual -Left 2L -Right 2.0 -CaseSensitive $false | Should -BeTrue
        }
    }

    Describe 'Parsing select' {
        It 'parses dotted names, [*], an index and a filter' {
            $q = ConvertTo-MbcPathQuery -Select "value[?state=='enabled'].conditions.users.includeUsers[*]"
            $q.Steps.Count | Should -Be 4
            $q.Steps[0].Kind | Should -Be 'filter'
            $q.Steps[0].Field | Should -Be 'state'
            $q.Steps[0].Literal | Should -Be 'enabled'
            $q.Steps[3].Kind | Should -Be 'all'
        }
        It 'accepts quoted names for keys with dots in them' {
            $q = ConvertTo-MbcPathQuery -Select 'value[0]."@odata.type"'
            $q.Steps[1].Name | Should -Be '@odata.type'
            $q.Steps[0].Index | Should -Be 0
        }
        It 'parses length()' {
            (ConvertTo-MbcPathQuery -Select 'length(value[*])').Length | Should -BeTrue
        }
        It 'parses integer, boolean and null literals' {
            (ConvertTo-MbcPathQuery -Select 'v[?n==3]').Steps[0].Literal | Should -Be 3
            (ConvertTo-MbcPathQuery -Select 'v[?b!=true]').Steps[0].Literal | Should -BeTrue
            (ConvertTo-MbcPathQuery -Select 'v[?x==null]').Steps[0].Literal | Should -BeNullOrEmpty
            (ConvertTo-MbcPathQuery -Select "v[?s=='it''s']").Steps[0].Literal | Should -Be "it's"
        }
        It 'explains what is wrong with a bad select' {
            { ConvertTo-MbcPathQuery -Select '' } | Should -Throw "*it is empty*"
            { ConvertTo-MbcPathQuery -Select 'a.' } | Should -Throw "*ends with a dot*"
            { ConvertTo-MbcPathQuery -Select 'a[x]' } | Should -Throw "*bracket at position*"
            { ConvertTo-MbcPathQuery -Select 'a b' } | Should -Throw "*unexpected*"
        }
    }

    Describe 'Evaluating select' {
        BeforeAll {
            $script:Doc = ConvertFrom-MbcJson -Json @'
{ "value": [
    { "displayName": "Block legacy", "state": "enabled",  "conditions": { "users": { "includeUsers": ["All"] } } },
    { "displayName": "Report only",  "state": "enabledForReportingButNotEnforced", "conditions": { "users": { "includeUsers": ["a","b"] } } },
    { "displayName": "Off",          "state": "disabled" }
  ],
  "flag": false,
  "@odata.context": "x" }
'@
        }
        It 'reads a plain property' {
            Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery 'flag') -Document $script:Doc | Should -BeFalse
        }
        It 'projects with [*] and flattens nested projections' {
            $v = Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery 'value[*].conditions.users.includeUsers[*]') -Document $script:Doc
            ($v -join ',') | Should -Be 'All,a,b'
        }
        It 'filters case-insensitively by default' {
            $v = Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery "value[?state=='ENABLED'].displayName") -Document $script:Doc
            $v.Count | Should -Be 1
            $v[0] | Should -Be 'Block legacy'
        }
        It 'filters case-sensitively when asked' {
            $v = Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery "value[?state=='ENABLED'].displayName") -Document $script:Doc -CaseSensitive
            $v.GetType().IsArray | Should -BeTrue
            $v.Count | Should -Be 0
        }
        It 'returns an empty list, not NotFound, when a projection matches nothing' {
            $v = Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery "value[?state=='gone'].displayName") -Document $script:Doc
            Test-MbcNotFound $v | Should -BeFalse
            $v.Count | Should -Be 0
        }
        It 'returns NotFound for a missing property outside a projection' {
            $v = Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery 'nope.deeper') -Document $script:Doc
            Test-MbcNotFound $v | Should -BeTrue
        }
        It 'indexes, including from the end' {
            Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery 'value[-1].displayName') -Document $script:Doc | Should -Be 'Off'
        }
        It 'reads a quoted key' {
            Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery '"@odata.context"') -Document $script:Doc | Should -Be 'x'
        }
        It 'counts with length()' {
            Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery 'length(value[*])') -Document $script:Doc | Should -Be 3
        }
        It 'refuses length() of a single value' {
            { Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery 'length(flag)') -Document $script:Doc } | Should -Throw '*needs a list*'
        }
        It 'returns a single-element list intact' {
            $v = Invoke-MbcPathQuery -Query (ConvertTo-MbcPathQuery 'value[0].conditions.users.includeUsers') -Document $script:Doc
            $v.GetType().IsArray | Should -BeTrue
            $v.Count | Should -Be 1
        }
    }
}
