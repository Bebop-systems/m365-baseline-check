# The scrub gate (spec 11): nothing identifying in any tracked file. Regular expressions are fine in tests.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Allow = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'scrub-allowlist.json') | ConvertFrom-Json
    Push-Location $script:Root
    try { $script:Tracked = @(git ls-files) + @(git ls-files --others --exclude-standard) }
    finally { Pop-Location }
    $script:Texts = foreach ($f in $script:Tracked) {
        $full = Join-Path $script:Root $f
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        [pscustomobject]@{ Path = $f; Text = [System.IO.File]::ReadAllText($full) }
    }
    function script:Find-Unallowed([string] $Pattern, [string[]] $Allowed, [string[]] $AllowedSuffixes = @(), [string[]] $AllowedPrefixes = @()) {
        foreach ($t in $script:Texts) {
            foreach ($m in [regex]::Matches($t.Text, $Pattern)) {
                $v = $m.Value.ToLowerInvariant()
                if ($v -in $Allowed) { continue }
                if (@($AllowedSuffixes | Where-Object { $v.EndsWith($_) }).Count) { continue }
                if (@($AllowedPrefixes | Where-Object { $v.StartsWith($_) }).Count) { continue }
                "$($t.Path): $($m.Value)"
            }
        }
    }
}

Describe 'The scrub gate' {
    It 'has files to check' {
        $script:Texts.Count | Should -BeGreaterThan 20
    }

    It 'holds no GUID beyond synthetic ones and documented Microsoft IDs' {
        $hits = @(Find-Unallowed -Pattern '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' -Allowed $script:Allow.guids -AllowedPrefixes @('00000000-0000-4000-8000-'))
        $hits | Should -BeNullOrEmpty
    }

    It 'holds no email address beyond example ones' {
        $hits = @(Find-Unallowed -Pattern '(?i)\b[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)+\b' -Allowed $script:Allow.emails -AllowedSuffixes @('@example.com', '@example.onmicrosoft.com'))
        $hits | Should -BeNullOrEmpty
    }

    It 'holds no onmicrosoft.com tenant name beyond the example' {
        $hits = @(Find-Unallowed -Pattern '(?i)\b[a-z0-9-]+\.onmicrosoft\.com\b' -Allowed @('example.onmicrosoft.com'))
        $hits | Should -BeNullOrEmpty
    }

    It 'links to no host beyond Microsoft''s documented ones, the licence and examples' {
        $hits = @(Find-Unallowed -Pattern '(?i)https?://[a-z0-9.-]+' -Allowed $script:Allow.hosts)
        $hits | Should -BeNullOrEmpty
    }

    It 'names no domain beyond the allowlist in prose or data' {
        # Bare domains in the common public suffixes; code identifiers such as Microsoft.Graph don't end in these.
        $hits = @(Find-Unallowed -Pattern '(?i)\b[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|net|org|io|co\.uk|uk|au|nz|ca|de|fr)\b' -Allowed $script:Allow.domains -AllowedSuffixes @('.example.com'))
        $hits | Should -BeNullOrEmpty
    }

    It 'keeps baselines and results inside presets/ and tests/fixtures/ only' {
        $misplaced = foreach ($t in $script:Texts) {
            if ($t.Path.StartsWith('presets/') -or $t.Path.StartsWith('tests/fixtures/')) { continue }
            if ($t.Path.EndsWith('.locked')) { $t.Path; continue }
            if (-not $t.Path.EndsWith('.json')) { continue }
            $isBaseline = $t.Text.Contains('"expected"') -and $t.Text.Contains('"preset"')
            $isResult = $t.Text.Contains('"m365bc-result"')
            if ($isBaseline -or $isResult) { $t.Path }
        }
        @($misplaced) | Should -BeNullOrEmpty
    }
}
