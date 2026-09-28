BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    BeforeAll {
        . (Join-Path $script:ModuleRoot 'tests/TestHelpers.ps1')
        $script:View = New-TestView
        $script:U = Get-MbcGlyphs -Unicode $true
        $script:A = Get-MbcGlyphs -Unicode $false
    }

    Describe 'Text helpers' {
        It 'adds colour only when asked, and measures width without escape codes' {
            Format-MbcStyle -Text 'x' -Style 'ok' -Color $false | Should -BeExactly 'x'
            $styled = Format-MbcStyle -Text 'hello' -Style 'ok' -Color $true
            $styled | Should -Not -BeExactly 'hello'
            Measure-MbcWidth -Text $styled | Should -Be 5
            Remove-MbcAnsi $styled | Should -BeExactly 'hello'
        }
        It 'truncates with an ellipsis, pads, and wraps' {
            Limit-MbcText -Text 'abcdefgh' -Width 5 | Should -BeExactly 'abcd…'
            Limit-MbcText -Text 'abc' -Width 5 | Should -BeExactly 'abc'
            Format-MbcPad -Text 'ab' -Width 4 | Should -BeExactly 'ab  '
            Format-MbcPad -Text 'ab' -Width 4 -Right | Should -BeExactly '  ab'
            (Split-MbcWrapped -Text 'one two three four' -Width 9) -join '|' | Should -Be 'one two|three|four'
            (Split-MbcWrapped -Text 'at /a/very/long/path.json now' -Width 8) -join '|' | Should -Be 'at|/a/very…|now'
            (Split-MbcWrapped -Text 'at /a/very/long/path.json now' -Width 8 -BreakLong) -join '|' | Should -Be 'at|/a/very/|long/pat|h.json|now'
        }
        It 'turns Unicode punctuation into ASCII in ASCII mode, and leaves nothing above 127' {
            ConvertTo-MbcGlyphText 'Identity › Users → x … ↑↓ ✓' $script:A | Should -BeExactly 'Identity > Users -> x ... Up/Dn ?'
        }
    }

    Describe 'Values the way the portal shows them' {
        It 'uses a label when one matches the canonical JSON of the value' {
            Format-MbcDisplayValue -Value $true -Labels ([ordered]@{ 'true' = 'Yes' }) | Should -Be 'Yes'
            Format-MbcDisplayValue -Value 'enabled' -Labels ([ordered]@{ '"enabled"' = 'On' }) | Should -Be 'On'
            Format-MbcDisplayValue -Value 3L -Labels ([ordered]@{ '3' = 'Three' }) | Should -Be 'Three'
        }
        It 'shows unlabelled values plainly' {
            Format-MbcDisplayValue -Value 'enabled' -Labels $null | Should -Be 'enabled'
            Format-MbcDisplayValue -Value $null -Labels $null | Should -Be 'not set'
            Format-MbcDisplayValue -Value @() -Labels $null | Should -Be 'none'
            Format-MbcDisplayValue -Value @('a', 'b') -Labels $null | Should -Be 'a, b'
        }
        It 'phrases a comparison as actual, then expected' {
            $r = $script:View.Results | Where-Object Id -eq 'ORG-001'
            Format-MbcComparisonText -Result $r -Glyphs $script:U | Should -Be 'Yes → No'
            $count = [pscustomobject]@{ Operator = 'countAtLeast'; Expected = 3L; Actual = @('a'); HasActual = $true; Labels = $null }
            Format-MbcComparisonText -Result $count -Glyphs $script:U | Should -Be '1 → at least 3'
        }
    }

    Describe 'Grouping by admin centre' {
        It 'groups in the fixed order with counts' {
            $groups = Get-MbcAreaGroups -Results $script:View.Results
            @($groups | ForEach-Object Name) -join ',' | Should -Be 'Entra,Exchange'
            "$($groups[0].Met) $($groups[0].NotMet) $($groups[0].Unverifiable)" | Should -Be '1 1 0'
        }
        It 'shows only what needs attention by default, with met areas collapsed to their heading' {
            $allMet = @($script:View.Results | ForEach-Object { $c = $_.PSObject.Copy(); $c })
            ($allMet | Where-Object Id -eq 'EXO-001').Verdict = 'Pass'
            ($allMet | Where-Object Id -eq 'ORG-001').Verdict = 'Pass'
            $rows = Get-MbcResultRows -Results $allMet -Filter 'attention'
            @($rows | ForEach-Object Kind) -join ',' | Should -Be 'heading,heading'
            $rows[0].Collapsed | Should -BeTrue
            $rows = Get-MbcResultRows -Results $script:View.Results -Filter 'attention'
            @($rows | ForEach-Object { if ($_.Result) { $_.Result.Id } else { $_.Group.Area } }) -join ',' | Should -Be 'entra,ORG-001,exchange,EXO-001'
        }
        It 'filters to not met, unverifiable or everything, and by text' {
            @((Get-MbcResultRows -Results $script:View.Results -Filter 'fail' ) | Where-Object Result | ForEach-Object { $_.Result.Id }) -join ',' | Should -Be 'ORG-001'
            @((Get-MbcResultRows -Results $script:View.Results -Filter 'error' ) | Where-Object Result | ForEach-Object { $_.Result.Id }) -join ',' | Should -Be 'EXO-001'
            @((Get-MbcResultRows -Results $script:View.Results -Filter 'all' ) | Where-Object Result).Count | Should -Be 3
            @((Get-MbcResultRows -Results $script:View.Results -Filter 'all' -Search 'conditional' ) | Where-Object Result | ForEach-Object { $_.Result.Id }) -join ',' | Should -Be 'CA-001'
        }
        It 'writes a heading with its counts, and rows with word, symbol and comparison' {
            $g = (Get-MbcAreaGroups -Results $script:View.Results)[0]
            Format-MbcGroupHeading -Group $g -Width 80 -Glyphs $script:U -Color $false | Should -BeExactly '  Entra  1 met · 1 not'
            $row = Format-MbcResultRow -Result ($script:View.Results | Where-Object Id -eq 'ORG-001') -Width 80 -Glyphs $script:U -Color $false
            $row | Should -BeLike '    ✗ Not met*Users can register applications*Yes → No'
            $row = Format-MbcResultRow -Result ($script:View.Results | Where-Object Id -eq 'EXO-001') -Width 80 -Glyphs $script:A -Color $false
            $row | Should -BeLike '    ? Unverifiable*not connected'
        }
        It 'never draws a row wider than asked, even at 40 columns with a long title' {
            $long = ($script:View.Results | Where-Object Id -eq 'ORG-001').PSObject.Copy()
            $long.Title = 'A very long setting title that goes on and on well past any sensible width ' * 3
            foreach ($w in 40, 60, 100) {
                Measure-MbcWidth (Format-MbcResultRow -Result $long -Width $w -Glyphs $script:U -Color $true) | Should -BeLessOrEqual $w
                Measure-MbcWidth (Format-MbcResultRow -Result $long -Width $w -Glyphs $script:U -Color $true -Selected) | Should -BeLessOrEqual $w
            }
        }
    }

    Describe 'report.txt' {
        BeforeAll { $script:Report = ConvertTo-MbcTextReport -View $script:View }
        It 'is never wider than 100 columns, and uses no colour' {
            foreach ($l in $script:Report.Split("`n")) { $l.Length | Should -BeLessOrEqual 100 }
            $script:Report.IndexOf([char]27) | Should -Be -1
        }
        It 'carries the identity, the digest, the tenant and the disclosure' {
            $script:Report | Should -BeLike "*$($script:View.Baseline.Fingerprint)*"
            $script:Report | Should -BeLike "*SHA-256 $($script:View.Baseline.Digest)*"
            $script:Report | Should -BeLike '*SENTINEL-TENANT-NAME (sentinel-domain.example.com)*'
            $script:Report | Should -BeLike '*Read-only by construction: GET-only Graph, Get- cmdlets only.*'
        }
        It 'lists every check, grouped, then details what needs attention' {
            $script:Report.IndexOf('Entra') | Should -BeLessThan $script:Report.IndexOf('Exchange')
            $script:Report | Should -BeLike '*✓ Met*At least one Conditional Access policy is on*'
            $script:Report | Should -BeLike '*Needs attention*ORG-001*Expected   No*Actual     Yes*'
            $script:Report | Should -BeLike '*EXO-001*Cause      not connected*'
            $script:Report | Should -BeLike '*Read       Get-OrganizationConfig*'
        }
        It 'keeps the consent removal command whole and indented, so it copies as one command' {
            $v = New-TestView
            $v | Add-Member -NotePropertyName Consent -NotePropertyValue ([pscustomobject]@{
                    ClientAppId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'; ClientName = 'Microsoft Graph Command Line Tools'; ServicePrincipalId = 'sp1'; Cause = $null
                    Grants = @([pscustomobject]@{ Id = 'grant1'; Type = 'admin'; Scopes = @('User.Read'); WriteScopes = @() })
                }) -Force
            $lines = (ConvertTo-MbcTextReport -View $v).Split("`n")
            $at = [array]::IndexOf($lines, '      Remove-MgOauth2PermissionGrant `')
            $at | Should -BeGreaterThan 0
            $lines[$at + 1] | Should -BeExactly "          -OAuth2PermissionGrantId 'grant1'"
        }

        It 'includes the app inventory with consents' {
            $script:Report | Should -BeLike '*App inventory*2 third-party, 2 own registrations. Not listed: 2 Microsoft apps, 1 other service principal.*'
            $script:Report | Should -BeLike '*Example Scheduler*Delegated, admin consent for all users*Mail.Read, User.Read*'
            $script:Report | Should -BeLike '*Notes.Read, User.Read (2 users)*'
        }
    }

    Describe 'summary.md' {
        BeforeAll { $script:Summary = ConvertTo-MbcSummaryMarkdown -View $script:View }
        It 'opens with front matter: identity, full digest, run date and counts per area' {
            $script:Summary | Should -BeLike "---*fingerprint: $($script:View.Baseline.Fingerprint)*digest: $($script:View.Baseline.Digest)*run: 2026-*entra: { met: 1, notMet: 1, unverifiable: 0 }*exchange: { met: 0, notMet: 0, unverifiable: 1 }*---*"
        }
        It 'tables each area by check ID, with status in words' {
            $script:Summary | Should -BeLike '*## Entra*| ORG-001 | Users can register applications | Identity › Users › User settings | Not met | medium |*'
            $script:Summary | Should -BeLike "*| EXO-001 | Mailbox auditing on by default |  | Couldn't verify: not connected | high |*"
        }
        It 'lists third-party apps with permission names, and counts own registrations only' {
            $script:Summary | Should -BeLike '*| Example Scheduler | Example Software Ltd | yes | Mail.Read, User.Read |  | unresolved permission, User.Read.All |*'
            $script:Summary | Should -BeLike '*| Sample Notes | Sample Apps | no |  | Notes.Read, User.Read (2 users) |  |*'
            $script:Summary | Should -BeLike '*2 app registrations. Their names are left out*'
        }
        It 'never contains a tenant identifier, account, domain, own-registration name, app ID or actual value' {
            foreach ($sentinel in @(
                    '00000000-0000-4000-8000-000000000001', 'SENTINEL-TENANT-NAME', 'sentinel-domain', 'sentinel.user@example.com',
                    'SENTINEL-POLICY-NAME', 'SENTINEL-OWN-APP', '00000000-0000-4000-8000-0000000000c3', '00000000-0000-4000-8000-0000000000b1',
                    '00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000aa'
                )) {
                $script:Summary.IndexOf($sentinel, [StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$sentinel' is tenant data"
            }
        }
        It 'marks an unsealed baseline' {
            ConvertTo-MbcSummaryMarkdown -View (New-TestView -Unsealed) | Should -BeLike '*sealed: false*UNSEALED*'
        }
        It 'says when the inventory was left out' {
            ConvertTo-MbcSummaryMarkdown -View (New-TestView -SkipInventory) | Should -BeLike '*The app inventory was left out of this run.*'
        }
    }
}
