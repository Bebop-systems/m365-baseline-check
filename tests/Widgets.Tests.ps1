BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Progress and spinner' {
        BeforeAll {
            $script:U = Get-MbcGlyphs -Unicode $true
            $script:A = Get-MbcGlyphs -Unicode $false
        }
        It 'is always exactly as wide as asked' -ForEach @(
            @{ Done = 0; Total = 10 }, @{ Done = 3; Total = 10 }, @{ Done = 10; Total = 10 }, @{ Done = 5; Total = 0 }, @{ Done = 2.5; Total = 7 }
        ) {
            Measure-MbcWidth (Format-MbcProgressBar -Done $Done -Total $Total -Width 20 -Glyphs $script:U -Color $true) | Should -Be 20
            Measure-MbcWidth (Format-MbcProgressBar -Done $Done -Total $Total -Width 20 -Glyphs $script:A -Color $false) | Should -Be 20
        }
        It 'fills completely at the end, and uses a partial cell on the way' {
            Format-MbcProgressBar -Done 10 -Total 10 -Width 8 -Glyphs $script:U -Color $false | Should -BeExactly ('█' * 8)
            (Format-MbcProgressBar -Done 1 -Total 16 -Width 8 -Glyphs $script:U -Color $false)[0] | Should -BeExactly '▌'
            Format-MbcProgressBar -Done 1 -Total 2 -Width 8 -Glyphs $script:A -Color $false | Should -BeExactly '####....'
        }
        It 'turns the spinner through its frames' {
            Get-MbcSpinnerFrame -Tick 0 -Glyphs $script:U | Should -Be '⠋'
            Get-MbcSpinnerFrame -Tick 10 -Glyphs $script:U | Should -Be '⠋'
            Get-MbcSpinnerFrame -Tick 1 -Glyphs $script:A | Should -Be '/'
        }
    }

    Describe 'Box, bar, menu and footer' {
        BeforeAll { $script:U = Get-MbcGlyphs -Unicode $true }
        It 'draws a box whose every line is exactly the width' {
            $lines = Format-MbcBox -Title 'M365 Baseline Check' -RightTitle 'v0.1.0' -Lines @('Tenant    example.com', ('x' * 200)) -Width 60 -Glyphs $script:U -Color $true
            $lines.Count | Should -Be 4
            foreach ($l in $lines) { Measure-MbcWidth $l | Should -Be 60 }
            $lines[0] | Should -BeLike '*M365 Baseline Check*v0.1.0*'
        }
        It 'draws a title bar within the width' {
            foreach ($w in 40, 80) {
                Measure-MbcWidth (Format-MbcTitleBar -Left 'M365 Baseline Check · Results' -Right 'Core tenant v3 · a1b2c3d4e5f6' -Width $w -Glyphs $script:U -Color $true) | Should -BeLessOrEqual $w
            }
        }
        It 'marks the selected menu item and shows each hotkey' {
            $items = @([pscustomobject]@{ Label = 'Run checks'; Key = 'r'; Action = 'run' }, [pscustomobject]@{ Label = 'Quit'; Key = 'q'; Action = 'quit' })
            $lines = Format-MbcMenu -Items $items -Selected 1 -Width 40 -Glyphs $script:U -Color $false
            $lines[1] | Should -BeLike '*▸ Quit*'
            $lines[0] | Should -BeLike '*r'
            foreach ($l in $lines) { Measure-MbcWidth $l | Should -BeLessOrEqual 40 }
        }
        It 'drops footer hints from the end rather than overflowing' {
            $keys = @(@('↑↓', 'move'), @('Enter', 'select'), @('r', 'run'), @('q', 'quit'))
            $narrow = Format-MbcFooter -Keys $keys -Width 24 -Glyphs $script:U -Color $false
            Measure-MbcWidth $narrow | Should -BeLessOrEqual 24
            $narrow | Should -BeLike '*move*'
            $narrow | Should -Not -BeLike '*quit*'
        }
        It 'uses ASCII arrows when Unicode is off' {
            Format-MbcFooter -Keys @(, @('↑↓', 'move')) -Width 40 -Glyphs (Get-MbcGlyphs -Unicode $false) -Color $false | Should -BeLike '*Up/Dn move*'
        }
    }

    Describe 'Terminal capability' {
        It 'keeps a sensible minimum size' {
            $c = New-MbcCapability -Width 10 -Height 3
            $c.Width | Should -Be 40
            $c.Height | Should -Be 12
        }
        It 'honours NO_COLOR and M365BC_ASCII' {
            $saved = $env:NO_COLOR, $env:M365BC_ASCII
            try {
                $env:NO_COLOR = '1'; $env:M365BC_ASCII = '1'
                $c = Get-MbcTerminalCapability
                $c.Color | Should -BeFalse
                $c.Unicode | Should -BeFalse
            }
            finally { $env:NO_COLOR = $saved[0]; $env:M365BC_ASCII = $saved[1] }
        }
    }
}
