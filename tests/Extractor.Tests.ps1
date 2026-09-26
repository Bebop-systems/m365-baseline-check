BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Extractor purity' {
        It 'allows a pure extractor' {
            @(Test-MbcExtractorPurity -Path (Join-Path $script:ModuleRoot 'tests/fixtures/extractors/pure.ps1')) | Should -BeNullOrEmpty
        }
        It 'names every impure thing in an impure one' {
            $problems = (Test-MbcExtractorPurity -Path (Join-Path $script:ModuleRoot 'tests/fixtures/extractors/impure.ps1')) -join "`n"
            $problems | Should -Match 'Invoke-RestMethod'
            $problems | Should -Match 'System.IO.File'
            $problems | Should -Match 'computed name'
        }
    }

    Describe 'Extractor purity: adversarial constructs (R14 review)' {
        BeforeDiscovery {
            # Each row is a full script body, not a fragment: several of these constructs (using,
            # #requires, an attribute before param) have their own placement rules, so building
            # them by string-mangling a shared template would be more fragile than just writing
            # each one out. Written into $TestDrive, never shipped as repository fixtures.
            #
            # This is BeforeDiscovery, not BeforeAll: -ForEach below is resolved at discovery
            # time, before any BeforeAll in the file has run.
            $AdversarialFixtures = @(
                @{ Name = 'ExecutionContext method invocation'; Body = "param(`$Response)`n`$ExecutionContext.InvokeCommand.InvokeScript('1')" }
                @{ Name = 'global-qualified ExecutionContext'; Body = "param(`$Response)`n`$global:ExecutionContext.InvokeCommand.InvokeScript('1')" }
                @{ Name = 'brace-qualified global ExecutionContext'; Body = "param(`$Response)`n`${global:ExecutionContext}" }
                @{ Name = 'CmdletBinding attribute reading PSCmdlet'; Body = "[CmdletBinding()]param(`$Response)`n`$PSCmdlet" }
                @{ Name = 'static call via an -as cast'; Body = "param(`$Response)`n('System.IO.File' -as 'type')::ReadAllText('x')" }
                @{ Name = 'computed member name via a variable'; Body = "param(`$Response)`n`$n = 'GetType'`n`$Response.`$n()" }
                @{ Name = 'ForEach-Object -MemberName'; Body = "param(`$Response)`n`$Response | ForEach-Object -MemberName GetType" }
                @{ Name = 'ForEach-Object with a bare method name'; Body = "param(`$Response)`n`$Response | ForEach-Object GetType" }
                @{ Name = 'both sides of a static call computed'; Body = "param(`$Response)`n`$t::`$m()" }
                @{ Name = 'redirection to a file'; Body = "param(`$Response)`n'x' > out.txt" }
                @{ Name = 'drive-qualified variable'; Body = "param(`$Response)`n`${C:\x.txt}" }
                @{ Name = 'a using statement'; Body = "using module ./x.psm1`nparam(`$Response)`n`$Response" }
                @{ Name = 'a #requires statement'; Body = "#requires -Modules Foo`nparam(`$Response)`n`$Response" }
                @{ Name = 'an environment variable'; Body = "param(`$Response)`n`$env:USERNAME" }
                @{ Name = 'a global assignment'; Body = "param(`$Response)`n`$global:x = 1" }
                @{ Name = 'an attribute naming a non-attribute type'; Body = "[System.IO.File()]param(`$Response)" }
                @{ Name = 'a class definition'; Body = 'class X {}' }
            )
        }
        It 'refuses <Name>' -ForEach $AdversarialFixtures {
            $dir = Join-Path $TestDrive 'adversarial'
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            $path = Join-Path $dir ([guid]::NewGuid().ToString() + '.ps1')
            Set-Content -LiteralPath $path -Value $Body -Encoding utf8NoBOM
            (Test-MbcExtractorPurity -Path $path) | Should -Not -BeNullOrEmpty
        }
    }

    Describe 'Running an extractor' {
        BeforeAll {
            $script:Response = ConvertFrom-MbcJson -Json '{"value":[{"state":"enabled","grantControls":{"builtInControls":["block"]}}]}'
            $script:FixtureRoot = Join-Path $script:ModuleRoot 'tests/fixtures'
        }
        It 'returns the value of a pure extractor' {
            $r = Invoke-MbcExtractor -RelativePath 'extractors/pure.ps1' -Response $script:Response -Root $script:FixtureRoot
            $r.Ok | Should -BeTrue
            $r.Value | Should -BeTrue
        }
        It 'refuses an impure extractor without running it' {
            $r = Invoke-MbcExtractor -RelativePath 'extractors/impure.ps1' -Response $script:Response -Root $script:FixtureRoot
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'extractor not allowed'
        }
        It 'reports a missing extractor as not allowed' {
            (Invoke-MbcExtractor -RelativePath 'extractors/nope.ps1' -Response $script:Response -Root $script:FixtureRoot).Cause | Should -Be 'extractor not allowed'
        }
        It 'reports an extractor that throws as failed' {
            $dir = Join-Path $TestDrive 'extractors'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'boom.ps1') -Value "param(`$Response)`nthrow 'nope'" -Encoding utf8NoBOM
            $r = Invoke-MbcExtractor -RelativePath 'extractors/boom.ps1' -Response $script:Response -Root $TestDrive
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'extractor failed'
        }
    }

    Describe 'Sandbox: the runtime layer on its own (review Important 5)' {
        # These call Invoke-MbcSandboxedScript directly, bypassing the static purity check
        # entirely, to prove layer 2 is the real boundary rather than relying on layer 1 alone.
        It 'refuses a direct file read, and nothing reaches the file system' {
            $r = Invoke-MbcSandboxedScript -Text "param(`$Response) [System.IO.File]::ReadAllText('C:\Windows\win.ini')" -Argument $null
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'extractor failed'
        }
        It 'refuses $ExecutionContext method invocation' {
            $r = Invoke-MbcSandboxedScript -Text "param(`$Response) `$ExecutionContext.InvokeCommand.InvokeScript('1+1')" -Argument $null
            $r.Ok | Should -BeFalse
        }
        It 'refuses an unrecognised command' {
            $r = Invoke-MbcSandboxedScript -Text 'Get-ChildItem' -Argument $null
            $r.Ok | Should -BeFalse
        }
        It 'a redirection never reaches the file system' {
            $marker = Join-Path $TestDrive 'sandbox-marker.txt'
            $r = Invoke-MbcSandboxedScript -Text "param(`$Response) 'x' > '$marker'" -Argument $null
            $r.Ok | Should -BeFalse
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
        It 'leaves the module''s own function and variable state untouched' {
            $beforeFunction = (Get-Item Function:\Test-MbcExtractorPurity).ScriptBlock.ToString()
            $beforeCommands = @($script:MbcExtractorCommands)
            Invoke-MbcSandboxedScript -Text '${function:Test-MbcExtractorPurity} = { return ,@() }' -Argument $null | Out-Null
            Invoke-MbcSandboxedScript -Text "`$script:MbcExtractorCommands = @('x')" -Argument $null | Out-Null
            (Get-Item Function:\Test-MbcExtractorPurity).ScriptBlock.ToString() | Should -Be $beforeFunction
            @($script:MbcExtractorCommands) | Should -Be $beforeCommands
        }
    }

    Describe 'Sandbox: output shape (review Important 4)' {
        It 'no output gives extractor failed' {
            $r = Invoke-MbcSandboxedScript -Text 'param($Response) $x = 5' -Argument $null
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'extractor failed'
            $r.Detail | Should -Be 'returned nothing'
        }
        It 'an explicit return $null gives Ok with a null value' {
            $r = Invoke-MbcSandboxedScript -Text 'param($Response) return $null' -Argument $null
            $r.Ok | Should -BeTrue
            $r.Value | Should -BeNullOrEmpty
        }
        It 'return ,@(''a'') stays a 1-element list' {
            $r = Invoke-MbcSandboxedScript -Text "param(`$Response) return ,@('a')" -Argument $null
            $r.Ok | Should -BeTrue
            , $r.Value | Should -Not -BeNullOrEmpty
            @($r.Value).Count | Should -Be 1
            @($r.Value)[0] | Should -Be 'a'
        }
        It 'return ,@() stays an empty list' {
            $r = Invoke-MbcSandboxedScript -Text 'param($Response) return ,@()' -Argument $null
            $r.Ok | Should -BeTrue
            @($r.Value).Count | Should -Be 0
        }
        It 'two outputs give a list' {
            $r = Invoke-MbcSandboxedScript -Text "param(`$Response) Write-Output 1`nWrite-Output 2" -Argument $null
            $r.Ok | Should -BeTrue
            @($r.Value).Count | Should -Be 2
            @($r.Value) | Should -Be @(1, 2)
        }
        It 'a returned script block gives extractor failed' {
            $r = Invoke-MbcSandboxedScript -Text 'param($Response) return { 1 + 1 }' -Argument $null
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'extractor failed'
            $r.Detail | Should -Be 'returned code, not data'
        }
        It 'the timeout case gives extractor failed' {
            $r = Invoke-MbcSandboxedScript -Text 'param($Response) while ($true) { }' -Argument $null
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'extractor failed'
            $r.Detail | Should -Be 'took longer than 5 s'
        }
        It 'an undefined variable gives extractor failed (strict mode)' {
            $r = Invoke-MbcSandboxedScript -Text 'param($Response) $undefinedVar + 1' -Argument $null
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'extractor failed'
        }
    }

    Describe 'Containment of -RelativePath (review Important 3)' {
        BeforeAll {
            $script:FixtureRoot = Join-Path $script:ModuleRoot 'tests/fixtures'
        }
        It 'refuses a parent-directory escape before extractors/' {
            (Invoke-MbcExtractor -RelativePath '../outside.ps1' -Response $null -Root $script:FixtureRoot).Cause | Should -Be 'extractor not allowed'
        }
        It 'refuses a parent-directory escape inside extractors/' {
            (Invoke-MbcExtractor -RelativePath 'extractors/../x.ps1' -Response $null -Root $script:FixtureRoot).Cause | Should -Be 'extractor not allowed'
        }
        It 'refuses a non-.ps1 file' {
            (Invoke-MbcExtractor -RelativePath 'extractors/x.txt' -Response $null -Root $script:FixtureRoot).Cause | Should -Be 'extractor not allowed'
        }
        It 'refuses an absolute path' {
            $absolute = if ($IsWindows) { 'C:/Windows/win.ini' } else { '/etc/passwd' }
            (Invoke-MbcExtractor -RelativePath $absolute -Response $null -Root $script:FixtureRoot).Cause | Should -Be 'extractor not allowed'
        }
        It 'refuses a symlinked extractor, where this platform and account can create one' {
            $dir = Join-Path $TestDrive 'extractors'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $real = Join-Path $TestDrive 'real.ps1'
            Set-Content -LiteralPath $real -Value "param(`$Response)`nreturn `$true" -Encoding utf8NoBOM
            $link = Join-Path $dir 'linked.ps1'
            try {
                New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null
            }
            catch {
                Set-ItResult -Skipped -Because "can't create a symlink here without elevation: $($_.Exception.Message)"
                return
            }
            (Invoke-MbcExtractor -RelativePath 'extractors/linked.ps1' -Response $null -Root $TestDrive).Cause | Should -Be 'extractor not allowed'
        }
    }
}
