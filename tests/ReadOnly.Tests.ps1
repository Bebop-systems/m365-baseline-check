Describe 'Read-only by construction (invariant 1)' {
    BeforeAll {
        $script:Src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
        $script:Files = @(Get-ChildItem -LiteralPath $script:Src -Recurse -Filter '*.ps1' -File)
        $script:Lines = foreach ($f in $script:Files) {
            $n = 0
            foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
                $n++
                [pscustomobject]@{ File = $f.Name; Number = $n; Text = $line }
            }
        }
    }

    It 'names the Graph request cmdlet exactly once, with the literal -Method GET' {
        $hits = @($script:Lines | Where-Object { $_.Text.IndexOf('Invoke-MgGraphRequest', [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        $hits.Count | Should -Be 1
        $hits[0].File | Should -Be 'Graph.ps1'
        $hits[0].Text | Should -BeLike '*Invoke-MgGraphRequest -Method GET *'
    }

    It 'makes that call from inside the one transport function' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:Src 'Sources/Graph.ps1'))
        $start = $text.IndexOf('function Invoke-MbcGraphTransport')
        $start | Should -BeGreaterOrEqual 0
        $next = $text.IndexOf("`nfunction ", $start + 10)
        if ($next -lt 0) { $next = $text.Length }
        $text.IndexOf('Invoke-MgGraphRequest') | Should -BeGreaterThan $start
        $text.IndexOf('Invoke-MgGraphRequest') | Should -BeLessThan $next
    }

    It 'runs a cmdlet from a variable in exactly one place: the guarded runner' {
        # A splatted call of a command held in a variable: '& $x @y'.
        $calls = @($script:Lines | Where-Object {
                $t = $_.Text
                $amp = $t.IndexOf('& $')
                $amp -ge 0 -and $t.IndexOf(' @', $amp) -gt $amp -and $t.IndexOf(' @(', $amp) -ne $t.IndexOf(' @', $amp)
            })
        $calls.Count | Should -Be 1
        $calls[0].File | Should -Be 'Cmdlet.ps1'
        $calls[0].Text | Should -BeLike '*& $Command @Parameters -ErrorAction Stop*'
    }

    It 'never uses another HTTP client' {
        foreach ($c in 'Invoke-RestMethod', 'Invoke-WebRequest', 'HttpClient', 'WebClient', 'HttpWebRequest') {
            @($script:Lines | Where-Object { $_.Text.IndexOf($c, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) | Should -BeNullOrEmpty -Because "$c must not appear"
        }
    }

    It 'never names a write method anywhere' {
        foreach ($m in 'POST', 'PUT', 'PATCH', 'DELETE') {
            @($script:Lines | Where-Object { $_.Text.IndexOf("-Method $m", [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.Text.IndexOf("-Method '$m'", [StringComparison]::OrdinalIgnoreCase) -ge 0 }) |
                Should -BeNullOrEmpty -Because "-Method $m must not appear"
        }
    }
}
