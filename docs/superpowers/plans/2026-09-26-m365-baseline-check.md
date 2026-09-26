# M365 Baseline Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a small, read-only PowerShell 7 module that checks a Microsoft 365 tenant against a sealed baseline, from a plain-PowerShell TUI or non-interactively. It writes verbose logs, concise sealed results, optional team-key encryption, and a redacted summary.

**Architecture:** There are five stages:
- a pure **baseline** layer: canonical JSON, validation, seal;
- a pure **check engine**: select language, operators, extractors, evaluation;
- a thin **Graph** layer: a GET-only client and a fail-closed read-only assertion;
- **outputs**: log, result document, CSV, summary, lock;
- a **TUI** built from pure string renderers driven by a small loop.

I/O is injected, via `-Fetch` and `-Invoke` script blocks, so everything but the runtime loop is tested offline.

**Tech Stack:**
- **Runtime:** PowerShell 7.4+ on .NET 8, using `System.Text.Json`, `AesGcm`, `HKDF` and `SHA256`. `Microsoft.Graph.Authentication` 2.x is loaded at run time only.
- **Tests and lint:** Pester 5.5+ (also runs on 6.x) and PSScriptAnalyzer.

**Spec:** `docs/superpowers/specs/2026-09-26-m365-baseline-check-design.md`. Read it before starting any task.

**Deviations from the spec, decided while planning:**
- **Validation is in code, not JSON Schema.** `schemas/` is not shipped. The code gives clearer messages and doesn't depend on `Test-Json`'s schema engine version; `CLAUDE.md` documents the format instead.
- **Two extra folders:** `src/Common/` for shared helpers, and `src/Public/` for the seven public commands.
- **Presets declare an `endpoints` list.** The spec's "declared endpoints" (§6) needs a home, and this is it.
- **No `NOTICE` file.** Attribution lives in the README only, per spec §13.

## Global Constraints

- **Language and strictness:** PowerShell **7.4+**. The module file has `#Requires -Version 7.4`, `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`.
- **Dependencies:** the only runtime dependency is `Microsoft.Graph.Authentication` (2.x). It is **not** in `RequiredModules`: it's checked when signing in. Tests need no Graph module at all.
- **No `Write-Host`.**
  - The TUI writes through `[Console]::Write`.
  - Plain mode uses `Write-Information -InformationAction Continue` for human lines.
  - Return values are objects.
- **Files:** UTF-8 **without BOM**, **LF** line endings, enforced by `.gitattributes`. Files are written with `[System.IO.File]::WriteAllText($p, $text, [System.Text.UTF8Encoding]::new($false))`.
- **Function names:**
  - Private functions are `Verb-Mbc<Noun>`, with approved verbs.
  - Public functions are exactly: `Start-BaselineCheck`, `Invoke-BaselineCheck`, `New-BaselineCapture`, `Protect-Baseline`, `Test-Baseline`, `New-ResultKey`, `Unlock-Result`.
- **Read-only:** Graph is only ever called through `Invoke-MbcGraphGet`, which has no method parameter. There is no `Invoke-RestMethod` or `Invoke-WebRequest` anywhere in `src/`.
- **Error never becomes Pass.** A failed collection, a missing value or a type mismatch is an `Error`, never a `Pass` or a silent drop.
- **Error causes** come only from `$script:MbcCauses`, defined in Task 4.
- **Nothing identifying in the repository:**
  - GUIDs are synthetic, following `00000000-0000-4000-8000-0000000000NN`, or Microsoft well-known role IDs listed in the scrub allowlist.
  - Domains are `example.com` or `example.onmicrosoft.com`.
  - There are no people's or organisations' names.
- **Commits:**
  - Small and atomic, **after the local gate passes**.
  - The author comes from the repo-local git config, which is already set.
  - Every message ends with exactly `Co-Authored-By: Claude <noreply@anthropic.com>`, and has **no** other trailer.
  - **Never push:** the controller pushes at the end.
- **Local gate:** `pwsh -NoProfile -File tools/Invoke-Gate.ps1` runs every test plus the analyser on `./src` and `./tools`. It must print `0 failed` and `0 finding(s)` before any commit.
- **Voice** for user-facing strings (spec §10): precise, brief, dry; occasional wit; no exclamation marks, no filler, no "Success!". Example: *"Sealed. The baseline is now v4; its fingerprint is 9f8e7d6c5b4a. Record it wherever you keep these."*
- **Array returns:** a function that may return a list returns it with `return ,$value`. A single-element or empty array must not unroll.
- **Test pattern:** each test file imports the module in `BeforeDiscovery`, then wraps its `Describe` blocks in `InModuleScope M365BaselineCheck { ... }` so private functions are callable. Fixture paths are built from `$script:ModuleRoot`, never from `$PSScriptRoot` inside `InModuleScope`.

---

## File map

| File | Responsibility |
|---|---|
| `M365BaselineCheck.psd1` / `.psm1` | Manifest; loader dot-sources `src/<dir>/*.ps1` in a fixed order |
| `src/Common/Values.ps1` | Type predicates, scalar equality |
| `src/Common/Sentinel.ps1` | the `NotFound` sentinel |
| `src/Common/Causes.ps1` | the closed list of Error causes |
| `src/Common/Paths.ps1` | output root, run IDs |
| `src/Common/Background.ps1` | run a script in a background runspace while ticking a callback |
| `src/Baseline/Canonical.ps1` | strict JSON parse, canonical JSON, pretty JSON, SHA-256 |
| `src/Baseline/Shape.ps1` | preset / check / baseline validation |
| `src/Baseline/Baseline.ps1` | read, digest, usability assertion, identity |
| `src/Baseline/Capture.ps1` | derive expected values from a tenant |
| `src/Checks/PathQuery.ps1` | the select language |
| `src/Checks/Operators.ps1` | comparisons |
| `src/Checks/Extractor.ps1` | extractor purity check and invocation |
| `src/Checks/Engine.ps1` | request plan, collection, evaluation, counts |
| `src/Graph/Scope.ps1` | read-scope shape predicate |
| `src/Graph/GraphClient.ps1` | GET-only client with paging and throttling |
| `src/Graph/Connect.ps1` | planes, role allowlist, read-only decision, sign-in |
| `src/Log/Logger.ps1` | JSON-lines run log |
| `src/Report/Result.ps1` | result document and its seal |
| `src/Report/Export.ps1` | CSV, file writing |
| `src/Report/Summary.ps1` | redacted Markdown |
| `src/Report/Lock.ps1` | team key, lock, unlock |
| `src/Report/Plain.ps1` | plain-mode line formatting |
| `src/Tui/Terminal.ps1` | capabilities, glyphs, styles, width helpers |
| `src/Tui/Widgets.ps1` | box, menu, table, progress bar, spinner, footer |
| `src/Tui/Screens.ps1` | state, key map, screen renderers |
| `src/Tui/Runtime.ps1` | alternate screen, key reading, line editor, action dispatch |
| `src/Public/*.ps1` | the seven public commands |
| `presets/`, `extractors/` | public examples |
| `tests/*.Tests.ps1`, `tests/fixtures/` | offline tests |
| `tools/Invoke-Gate.ps1` | the local gate |
| `CLAUDE.md`, `README.md`, `.github/workflows/ci.yml` | handover |

---

### Task 1: Repository scaffold, module loader, and the local gate

**Files:**
- Create: `.gitattributes`, `.gitignore`, `LICENSE`, `README.md`, `PSScriptAnalyzerSettings.psd1`
- Create: `M365BaselineCheck.psd1`, `M365BaselineCheck.psm1`
- Create: `tools/Invoke-Gate.ps1`
- Test: `tests/Module.Tests.ps1`

**Interfaces:**
- Produces: `$script:ModuleRoot` (the module folder) and `$script:MbcToolVersion` (a string such as `'0.1.0'`), both available to every private function. The loader order is `Common, Baseline, Checks, Graph, Log, Report, Tui, Public`.

- [ ] **Step 1: Write `.gitattributes` and `.gitignore`**

`.gitattributes`:
```
* text=auto eol=lf
```

`.gitignore`:
```
testResults.xml
*.locked
/out/
# Internal presets and baselines never live in this repository. See CLAUDE.md.
/baselines/
```

- [ ] **Step 2: Fetch the licence text**

Run:
```powershell
Invoke-WebRequest -Uri 'https://www.apache.org/licenses/LICENSE-2.0.txt' -OutFile LICENSE
$t = [System.IO.File]::ReadAllText("$PWD/LICENSE").Replace("`r`n", "`n")
[System.IO.File]::WriteAllText("$PWD/LICENSE", $t, [System.Text.UTF8Encoding]::new($false))
```
Expected: `LICENSE` begins with `Apache License` and `Version 2.0, January 2004`.

- [ ] **Step 3: Write a first `README.md`** (Task 19 replaces it)

```markdown
# M365 Baseline Check

Read-only checks of a Microsoft 365 tenant against a sealed baseline, from a terminal UI.

Under construction. The code in this repository was written by Claude (Anthropic), under human direction.
```

- [ ] **Step 4: Write the failing module test** in `tests/Module.Tests.ps1`

```powershell
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Manifest = Join-Path $script:Root 'M365BaselineCheck.psd1'
}

Describe 'The module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:Manifest -ErrorAction Stop } | Should -Not -Throw
    }

    It 'imports cleanly' {
        { Import-Module $script:Manifest -Force -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports nothing beyond the declared public commands' {
        Import-Module $script:Manifest -Force
        $declared = (Import-PowerShellDataFile $script:Manifest).FunctionsToExport
        $exported = @((Get-Module M365BaselineCheck).ExportedFunctions.Keys)
        @($exported | Where-Object { $_ -notin $declared }) | Should -BeNullOrEmpty
    }

    It 'requires nothing at import time beyond PowerShell itself' {
        (Import-PowerShellDataFile $script:Manifest).ContainsKey('RequiredModules') | Should -BeFalse
    }

    It 'knows its own version' {
        Import-Module $script:Manifest -Force
        $v = & (Get-Module M365BaselineCheck) { $script:MbcToolVersion }
        $v | Should -Be (Import-PowerShellDataFile $script:Manifest).ModuleVersion
    }
}
```

- [ ] **Step 5: Run it to verify it fails**

Run: `Invoke-Pester ./tests/Module.Tests.ps1 -Output Detailed`
Expected: FAIL. The manifest doesn't exist.

- [ ] **Step 6: Write the manifest** `M365BaselineCheck.psd1`

Generate a GUID once with `[guid]::NewGuid()` and paste it in. Task 19's scrub test allowlists the manifest's own GUID automatically.

```powershell
@{
    RootModule           = 'M365BaselineCheck.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'PASTE-THE-GENERATED-GUID-HERE'
    Author               = 'Claude (Anthropic), under human direction'
    Copyright            = 'Licensed under the Apache License, Version 2.0.'
    Description          = 'Read-only Microsoft 365 configuration checks against sealed baselines, from a terminal UI.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Start-BaselineCheck', 'Invoke-BaselineCheck', 'New-BaselineCapture',
        'Protect-Baseline', 'Test-Baseline', 'New-ResultKey', 'Unlock-Result'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Microsoft365', 'Graph', 'Baseline', 'Audit', 'ReadOnly')
            LicenseUri = 'https://www.apache.org/licenses/LICENSE-2.0'
        }
    }
}
```

The GUID line is the one value you generate and replace; everything else is literal.

- [ ] **Step 7: Write the loader** `M365BaselineCheck.psm1`

```powershell
#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot
$script:MbcToolVersion = [string](Import-PowerShellDataFile (Join-Path $PSScriptRoot 'M365BaselineCheck.psd1')).ModuleVersion

# A fixed order, so a file's module-level variables exist before anything that reads them at load time.
foreach ($dir in 'Common', 'Baseline', 'Checks', 'Graph', 'Log', 'Report', 'Tui', 'Public') {
    $path = Join-Path $PSScriptRoot (Join-Path 'src' $dir)
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File | Sort-Object Name) {
        . $file.FullName
    }
}
```

- [ ] **Step 8: Write the analyser settings** `PSScriptAnalyzerSettings.psd1`

```powershell
@{
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true
}
```

- [ ] **Step 9: Write the gate** `tools/Invoke-Gate.ps1`

```powershell
#Requires -Version 7.4
<#
.SYNOPSIS
    The local gate: every test, then the analyser over ./src and ./tools. Run it before every commit.
#>
[CmdletBinding()]
param([switch] $SkipAnalyzer)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge [version]'5.5.0' } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester 5.5 or later is needed: Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser' }
Import-Module $pester.Path -Force

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $root 'tests'
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
$result = Invoke-Pester -Configuration $config
$failed = $result.FailedCount + $result.FailedBlocksCount + $result.FailedContainersCount

$findings = @()
if (-not $SkipAnalyzer) {
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        throw 'PSScriptAnalyzer is needed: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    }
    Import-Module PSScriptAnalyzer -Force
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    # Two invocations on purpose: -Path takes one string, and a comma list analyses nothing, silently.
    foreach ($dir in 'src', 'tools') {
        $findings += @(Invoke-ScriptAnalyzer -Path (Join-Path $root $dir) -Recurse -Settings $settings)
    }
    # Canary: a clean result only means something if the analyser can find a problem at all.
    $canary = @(Invoke-ScriptAnalyzer -ScriptDefinition 'function Get-Canary { Write-Host "x" }' -Settings $settings)
    if ($canary.Count -eq 0) { throw 'The analyser found nothing in a deliberately bad script, so its clean result cannot be trusted.' }
}

if ($findings.Count) { $findings | Format-Table -AutoSize | Out-String | Write-Output }
Write-Output ('Tests: {0} passed, {1} failed, {2} skipped. Analyser: {3} finding(s).' -f
    $result.PassedCount, $failed, $result.SkippedCount, $findings.Count)
if ($failed -gt 0 -or $findings.Count -gt 0) { exit 1 }
```

- [ ] **Step 10: Run the gate**

Run: `pwsh -NoProfile -File tools/Invoke-Gate.ps1`
Expected: `Tests: 5 passed, 0 failed, 0 skipped. Analyser: 0 finding(s).`

- [ ] **Step 11: Commit**

```bash
git add .gitattributes .gitignore LICENSE README.md PSScriptAnalyzerSettings.psd1 M365BaselineCheck.psd1 M365BaselineCheck.psm1 tools/Invoke-Gate.ps1 tests/Module.Tests.ps1
git commit -m "chore: module scaffold, loader and the local gate" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Strict JSON, canonical JSON and SHA-256

**Files:**
- Create: `src/Baseline/Canonical.ps1`
- Test: `tests/Canonical.Tests.ps1`

**Interfaces:**
- Produces:
  - `ConvertFrom-MbcJson -Json <string> [-AllowFloat]` → ordered dictionaries (`[ordered]`), `object[]`, `string`, `long`, `double` (only with `-AllowFloat`), `bool` or `$null`. It throws on invalid JSON, duplicate keys, and non-whole numbers (without `-AllowFloat`).
  - `ConvertTo-MbcCanonicalJson -Value <object>` → string: keys sorted ordinally, no whitespace, minimal escaping. It accepts `IDictionary`, `PSCustomObject`, lists and scalars.
  - `ConvertTo-MbcPrettyJson -Value <object>` → a string with 2-space indent, insertion order kept, and a trailing `\n`.
  - `ConvertTo-MbcJsonString -Text <string>` → a quoted, escaped JSON string.
  - `Get-MbcSha256Hex -Text <string>` → 64 lowercase hex characters over UTF-8.
  - `Get-MbcSha256Hex -Bytes <byte[]>`, the same over raw bytes.

- [ ] **Step 1: Write the failing tests** in `tests/Canonical.Tests.ps1`

```powershell
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Canonical.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'ConvertFrom-MbcJson' is not recognized`.

- [ ] **Step 3: Implement** `src/Baseline/Canonical.ps1`

```powershell
function ConvertFrom-MbcJson {
    <#
    .SYNOPSIS
        Parses JSON strictly: ordered dictionaries, whole numbers only unless -AllowFloat, no duplicate keys.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Json,
        [switch] $AllowFloat
    )
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 64
    try {
        $doc = [System.Text.Json.JsonDocument]::Parse($Json, $options)
    }
    catch {
        $inner = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        throw "Not valid JSON: $inner"
    }
    try {
        return , (ConvertFrom-MbcJsonElement -Element $doc.RootElement -Path '$' -AllowFloat:$AllowFloat)
    }
    finally {
        $doc.Dispose()
    }
}

function ConvertFrom-MbcJsonElement {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)][string] $Path,
        [switch] $AllowFloat
    )
    switch ($Element.ValueKind) {
        'Object' {
            $map = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                if ($map.Contains($property.Name)) { throw "Duplicate key '$($property.Name)' at $Path." }
                $map[$property.Name] = ConvertFrom-MbcJsonElement -Element $property.Value -Path "$Path.$($property.Name)" -AllowFloat:$AllowFloat
            }
            return $map
        }
        'Array' {
            $list = [System.Collections.Generic.List[object]]::new()
            $i = 0
            foreach ($item in $Element.EnumerateArray()) {
                $list.Add((ConvertFrom-MbcJsonElement -Element $item -Path "$Path[$i]" -AllowFloat:$AllowFloat))
                $i++
            }
            return , $list.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            $whole = 0L
            if ($Element.TryGetInt64([ref]$whole)) { return $whole }
            if ($AllowFloat) { return $Element.GetDouble() }
            throw "Only whole numbers are allowed; found $($Element.GetRawText()) at $Path."
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
    }
    throw "Unsupported JSON value at $Path."
}

function ConvertTo-MbcJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $sb = [System.Text.StringBuilder]::new($Text.Length + 2)
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 0x22) { [void]$sb.Append('\"') }
        elseif ($code -eq 0x5C) { [void]$sb.Append('\\') }
        elseif ($code -eq 0x08) { [void]$sb.Append('\b') }
        elseif ($code -eq 0x0C) { [void]$sb.Append('\f') }
        elseif ($code -eq 0x0A) { [void]$sb.Append('\n') }
        elseif ($code -eq 0x0D) { [void]$sb.Append('\r') }
        elseif ($code -eq 0x09) { [void]$sb.Append('\t') }
        elseif ($code -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Test-MbcIsWholeNumberType {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int] -or $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64])
}

function Get-MbcObjectMember {
    # A dictionary or PSCustomObject as an ordered list of name/value pairs.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][object] $Value)
    $pairs = [System.Collections.Generic.List[object]]::new()
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) {
            if ($k -isnot [string]) { throw "Object keys must be strings; found a $($k.GetType().Name)." }
            $pairs.Add([pscustomobject]@{ Name = $k; Value = $Value[$k] })
        }
    }
    else {
        foreach ($p in $Value.PSObject.Properties) { $pairs.Add([pscustomobject]@{ Name = $p.Name; Value = $p.Value }) }
    }
    return , $pairs.ToArray()
}

function Add-MbcCanonical {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder] $Builder,
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Path
    )
    if ($null -eq $Value) { [void]$Builder.Append('null'); return }
    if ($Value -is [bool]) { [void]$Builder.Append($(if ($Value) { 'true' } else { 'false' })); return }
    if ($Value -is [string]) { [void]$Builder.Append((ConvertTo-MbcJsonString -Text $Value)); return }
    if (Test-MbcIsWholeNumberType $Value) { [void]$Builder.Append($Value.ToString([cultureinfo]::InvariantCulture)); return }
    if ($Value -is [double] -or $Value -is [single]) {
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { throw "Cannot canonicalise NaN or infinity at $Path." }
        [void]$Builder.Append(([double]$Value).ToString('R', [cultureinfo]::InvariantCulture)); return
    }
    if ($Value -is [decimal]) { [void]$Builder.Append($Value.ToString([cultureinfo]::InvariantCulture)); return }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = Get-MbcObjectMember -Value $Value
        $names = [string[]]@($pairs | ForEach-Object { $_.Name })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        [void]$Builder.Append('{')
        $first = $true
        foreach ($name in $names) {
            if (-not $first) { [void]$Builder.Append(',') }
            $first = $false
            $item = $pairs | Where-Object { $_.Name -ceq $name } | Select-Object -First 1
            [void]$Builder.Append((ConvertTo-MbcJsonString -Text $name)).Append(':')
            Add-MbcCanonical -Builder $Builder -Value $item.Value -Path "$Path.$name"
        }
        [void]$Builder.Append('}')
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        [void]$Builder.Append('[')
        $first = $true
        $i = 0
        foreach ($item in $Value) {
            if (-not $first) { [void]$Builder.Append(',') }
            $first = $false
            Add-MbcCanonical -Builder $Builder -Value $item -Path "$Path[$i]"
            $i++
        }
        [void]$Builder.Append(']')
        return
    }
    throw "Cannot canonicalise a value of type $($Value.GetType().FullName) at $Path."
}

function ConvertTo-MbcCanonicalJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    $sb = [System.Text.StringBuilder]::new()
    Add-MbcCanonical -Builder $sb -Value $Value -Path '$'
    return $sb.ToString()
}

function Add-MbcPretty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder] $Builder,
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][int] $Indent
    )
    $pad = '  ' * $Indent
    $inner = '  ' * ($Indent + 1)
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = Get-MbcObjectMember -Value $Value
        if ($pairs.Count -eq 0) { [void]$Builder.Append('{}'); return }
        [void]$Builder.Append("{`n")
        for ($i = 0; $i -lt $pairs.Count; $i++) {
            [void]$Builder.Append($inner).Append((ConvertTo-MbcJsonString -Text $pairs[$i].Name)).Append(': ')
            Add-MbcPretty -Builder $Builder -Value $pairs[$i].Value -Indent ($Indent + 1)
            if ($i -lt $pairs.Count - 1) { [void]$Builder.Append(',') }
            [void]$Builder.Append("`n")
        }
        [void]$Builder.Append($pad).Append('}')
        return
    }
    if ($Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { [void]$Builder.Append('[]'); return }
        [void]$Builder.Append("[`n")
        for ($i = 0; $i -lt $items.Count; $i++) {
            [void]$Builder.Append($inner)
            Add-MbcPretty -Builder $Builder -Value $items[$i] -Indent ($Indent + 1)
            if ($i -lt $items.Count - 1) { [void]$Builder.Append(',') }
            [void]$Builder.Append("`n")
        }
        [void]$Builder.Append($pad).Append(']')
        return
    }
    Add-MbcCanonical -Builder $Builder -Value $Value -Path '$'
}

function ConvertTo-MbcPrettyJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    $sb = [System.Text.StringBuilder]::new()
    Add-MbcPretty -Builder $sb -Value $Value -Indent 0
    [void]$sb.Append("`n")
    return $sb.ToString()
}

function Get-MbcSha256Hex {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Text')][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][byte[]] $Bytes
    )
    $data = if ($PSCmdlet.ParameterSetName -eq 'Text') { [System.Text.UTF8Encoding]::new($false).GetBytes($Text) } else { $Bytes }
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Canonical.Tests.ps1 -Output Detailed`
Expected: PASS, 17 tests.

- [ ] **Step 5: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Baseline/Canonical.ps1 tests/Canonical.Tests.ps1
git commit -m "feat: strict JSON, canonical JSON and SHA-256" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Value helpers and the select language

**Files:**
- Create: `src/Common/Sentinel.ps1`, `src/Common/Values.ps1`, `src/Checks/PathQuery.ps1`
- Test: `tests/PathQuery.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertFrom-MbcJson` (Task 2).
- Produces:
  - `$script:MbcNotFound` (a unique sentinel object) and `Test-MbcNotFound -Value` → bool.
  - `Test-MbcIsList`, `Test-MbcIsDictionary`, `Test-MbcIsNumber`, `Test-MbcIsWholeNumber` and `Test-MbcIsScalar`, each `-Value` → bool.
  - `Test-MbcScalarEqual -Left -Right -CaseSensitive <bool>` → bool.
  - `ConvertTo-MbcPathQuery -Select <string>` → a `Mbc.PathQuery` object `{ Select; Length (bool); Steps[] }`. It throws `"Can't read select '…': <reason>."`.
  - `Invoke-MbcPathQuery -Query -Document [-CaseSensitive]` → the value, or `$script:MbcNotFound`. It throws `"length() needs a list…"` when `length()` meets a single value.

- [ ] **Step 1: Write the failing tests** in `tests/PathQuery.Tests.ps1`

```powershell
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/PathQuery.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Test-MbcScalarEqual' is not recognized`.

- [ ] **Step 3: Implement** `src/Common/Sentinel.ps1`

```powershell
# One object, compared by reference: "this path resolved to nothing". Never equal to null or an empty list.
$script:MbcNotFound = [pscustomobject]@{ PSTypeName = 'Mbc.NotFound' }

function Test-MbcNotFound {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    return [object]::ReferenceEquals($Value, $script:MbcNotFound)
}
```

- [ ] **Step 4: Implement** `src/Common/Values.ps1`

```powershell
function Test-MbcIsDictionary {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    return ($Value -is [System.Collections.IDictionary])
}

function Test-MbcIsList {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    return ($Value -is [System.Collections.IList] -and $Value -isnot [string])
}

function Test-MbcIsNumber {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    return ((Test-MbcIsWholeNumberType $Value) -or $Value -is [double] -or $Value -is [single] -or $Value -is [decimal])
}

function Test-MbcIsWholeNumber {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    return (Test-MbcIsWholeNumberType $Value)
}

function Test-MbcIsScalar {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    return ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or (Test-MbcIsNumber $Value))
}

function Test-MbcScalarEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowNull()][object] $Left,
        [Parameter(Position = 1)][AllowNull()][object] $Right,
        [Parameter(Position = 2)][bool] $CaseSensitive = $false
    )
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    if ($Left -is [string] -and $Right -is [string]) {
        $comparison = if ($CaseSensitive) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
        return [string]::Equals($Left, $Right, $comparison)
    }
    if ($Left -is [bool] -and $Right -is [bool]) { return ($Left -eq $Right) }
    if ((Test-MbcIsNumber $Left) -and (Test-MbcIsNumber $Right)) {
        if ((Test-MbcIsWholeNumber $Left) -and (Test-MbcIsWholeNumber $Right)) { return ([long]$Left -eq [long]$Right) }
        return ([double]$Left -eq [double]$Right)
    }
    return $false
}
```

- [ ] **Step 5: Implement** `src/Checks/PathQuery.ps1`

```powershell
$script:MbcSelectName = '(?:"(?<qn>[^"]+)"|(?<n>[A-Za-z_@$][A-Za-z0-9_@$\-]*))'
$script:MbcSelectLiteral = "(?<lit>'(?:[^']|'')*'|-?\d+|true|false|null)"

function New-MbcSelectError {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Select, [string] $Reason)
    return "Can't read select '$Select': $Reason."
}

function ConvertFrom-MbcSelectLiteral {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string] $Text)
    if ($Text.StartsWith("'")) { return $Text.Substring(1, $Text.Length - 2).Replace("''", "'") }
    if ($Text -match '^-?\d+$') { return [long]$Text }
    if ($Text -eq 'true') { return $true }
    if ($Text -eq 'false') { return $false }
    if ($Text -eq 'null') { return $null }
    throw "Unrecognised literal $Text."
}

function Get-MbcMatchedName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Text.RegularExpressions.Match] $Match)
    if ($Match.Groups['qn'].Success) { return $Match.Groups['qn'].Value }
    return $Match.Groups['n'].Value
}

function ConvertTo-MbcPathQuery {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string] $Select)
    $text = $Select.Trim()
    $isLength = $false
    if ($text -match '^length\(\s*(?<inner>.*?)\s*\)$') {
        $isLength = $true
        $text = $Matches['inner']
    }
    if ($text.Length -eq 0) { throw (New-MbcSelectError $Select 'it is empty') }

    $steps = [System.Collections.Generic.List[object]]::new()
    $pos = 0
    while ($true) {
        $m = [regex]::Match($text.Substring($pos), "^$($script:MbcSelectName)")
        if (-not $m.Success) { throw (New-MbcSelectError $Select "expected a property name at position $($pos + 1)") }
        $step = [ordered]@{ Name = (Get-MbcMatchedName $m); Kind = 'plain'; Index = $null; Field = $null; Op = $null; Literal = $null }
        $pos += $m.Length
        if ($pos -lt $text.Length -and $text[$pos] -eq '[') {
            $rest = $text.Substring($pos)
            $all = [regex]::Match($rest, '^\[\*\]')
            $index = [regex]::Match($rest, '^\[(?<i>-?\d+)\]')
            $filter = [regex]::Match($rest, "^\[\?\s*$($script:MbcSelectName)\s*(?<op>==|!=)\s*$($script:MbcSelectLiteral)\s*\]")
            if ($all.Success) {
                $step.Kind = 'all'
                $pos += $all.Length
            }
            elseif ($index.Success) {
                $step.Kind = 'index'
                $step.Index = [int]$index.Groups['i'].Value
                $pos += $index.Length
            }
            elseif ($filter.Success) {
                $step.Kind = 'filter'
                $step.Field = Get-MbcMatchedName $filter
                $step.Op = $filter.Groups['op'].Value
                $step.Literal = ConvertFrom-MbcSelectLiteral $filter.Groups['lit'].Value
                $pos += $filter.Length
            }
            else {
                throw (New-MbcSelectError $Select "can't make sense of the bracket at position $($pos + 1)")
            }
        }
        $steps.Add([pscustomobject]$step)
        if ($pos -ge $text.Length) { break }
        if ($text[$pos] -ne '.') { throw (New-MbcSelectError $Select "unexpected '$($text[$pos])' at position $($pos + 1)") }
        $pos++
        if ($pos -ge $text.Length) { throw (New-MbcSelectError $Select 'it ends with a dot') }
    }
    return [pscustomobject]@{ PSTypeName = 'Mbc.PathQuery'; Select = $Select; Length = $isLength; Steps = $steps.ToArray() }
}

function Get-MbcProperty {
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)
    if ((Test-MbcIsDictionary $Object) -and $Object.Contains($Name)) { return , $Object[$Name] }
    return $script:MbcNotFound
}

function Test-MbcFilterMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Element, [Parameter(Mandatory)] $Step, [bool] $CaseSensitive)
    $value = Get-MbcProperty -Object $Element -Name $Step.Field
    if (Test-MbcNotFound $value) { $value = $null }
    $equal = Test-MbcScalarEqual -Left $value -Right $Step.Literal -CaseSensitive $CaseSensitive
    if ($Step.Op -eq '==') { return $equal }
    return (-not $equal)
}

function Invoke-MbcPathQuery {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] $Query,
        [AllowNull()][object] $Document,
        [switch] $CaseSensitive
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $items.Add($Document)
    $multi = $false
    foreach ($step in $Query.Steps) {
        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $items) {
            $value = Get-MbcProperty -Object $item -Name $step.Name
            $missing = Test-MbcNotFound $value
            if (-not $missing -and $step.Kind -ne 'plain' -and -not (Test-MbcIsList $value)) { $missing = $true }
            if ($missing) {
                if ($multi) { continue }
                return $script:MbcNotFound
            }
            if ($step.Kind -eq 'plain') {
                $next.Add($value)
            }
            elseif ($step.Kind -eq 'index') {
                $i = if ($step.Index -lt 0) { $value.Count + $step.Index } else { $step.Index }
                if ($i -lt 0 -or $i -ge $value.Count) {
                    if ($multi) { continue }
                    return $script:MbcNotFound
                }
                $next.Add($value[$i])
            }
            elseif ($step.Kind -eq 'all') {
                foreach ($element in $value) { $next.Add($element) }
            }
            else {
                foreach ($element in $value) {
                    if (Test-MbcFilterMatch -Element $element -Step $step -CaseSensitive ([bool]$CaseSensitive)) { $next.Add($element) }
                }
            }
        }
        $items = $next
        if ($step.Kind -in 'all', 'filter') { $multi = $true }
    }

    $result = if ($multi) { , $items.ToArray() } else { , $items[0] }
    if (-not $Query.Length) { return , $result }
    if (-not (Test-MbcIsList $result)) { throw "length() needs a list, and '$($Query.Select)' is a single value." }
    return [long]$result.Count
}
```

The `$result = if (...) { , $x } else { , $y }` form keeps arrays intact through the assignment.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/PathQuery.Tests.ps1 -Output Detailed`
Expected: PASS, 20 tests.

- [ ] **Step 7: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Common/Sentinel.ps1 src/Common/Values.ps1 src/Checks/PathQuery.ps1 tests/PathQuery.Tests.ps1
git commit -m "feat: value helpers and the select language" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Error causes and operators

**Files:**
- Create: `src/Common/Causes.ps1`, `src/Checks/Operators.ps1`
- Test: `tests/Operators.Tests.ps1`

**Interfaces:**
- Consumes: `Test-MbcNotFound`, `Test-MbcIsList`, `Test-MbcIsScalar`, `Test-MbcScalarEqual` (Task 3), and `ConvertTo-MbcCanonicalJson` (Task 2).
- Produces:
  - `$script:MbcCauses`, a `string[]`: the closed vocabulary of Error causes.
  - `$script:MbcOperators`, a `string[]`.
  - `Compare-MbcValue -Actual -Operator -Expected [-CaseSensitive]` → `[pscustomobject]@{ Verdict = 'Pass'|'Fail'|'Error'; Cause = <string or $null> }`.

- [ ] **Step 1: Write the failing tests** in `tests/Operators.Tests.ps1`

```powershell
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Operators.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Compare-MbcValue' is not recognized`.

- [ ] **Step 3: Implement** `src/Common/Causes.ps1`

```powershell
# The closed vocabulary of reasons a check could not be completed. Summaries and exports only ever use these.
$script:MbcCauses = @(
    'permission missing',
    'not found',
    'throttled',
    'service error',
    'malformed response',
    'request rejected',
    'too many pages',
    'setting not found',
    'extractor failed',
    'extractor not allowed',
    'baseline expects a list',
    'baseline expects a single value',
    'invalid pattern',
    'pattern too slow',
    'endpoint not declared',
    'not collected'
)
```

- [ ] **Step 4: Implement** `src/Checks/Operators.ps1`

```powershell
$script:MbcOperators = @(
    'equals', 'notEquals', 'in', 'contains', 'setEquals', 'subsetOf',
    'countAtLeast', 'countAtMost', 'matches', 'exists', 'absent'
)

function New-MbcComparison {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Error')][string] $Verdict, [AllowNull()][string] $Cause)
    return [pscustomobject]@{ Verdict = $Verdict; Cause = $Cause }
}

function Test-MbcMemberEqual {
    # Scalars compare by value (honouring case); anything complex compares by canonical JSON.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Left, [AllowNull()][object] $Right, [bool] $CaseSensitive)
    if ((Test-MbcIsScalar $Left) -and (Test-MbcIsScalar $Right)) {
        return (Test-MbcScalarEqual -Left $Left -Right $Right -CaseSensitive $CaseSensitive)
    }
    if ((Test-MbcIsScalar $Left) -or (Test-MbcIsScalar $Right)) { return $false }
    return ((ConvertTo-MbcCanonicalJson $Left) -ceq (ConvertTo-MbcCanonicalJson $Right))
}

function Test-MbcSubset {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Items, [AllowNull()][object] $Of, [bool] $CaseSensitive)
    foreach ($item in @($Items)) {
        $found = $false
        foreach ($candidate in @($Of)) {
            if (Test-MbcMemberEqual -Left $item -Right $candidate -CaseSensitive $CaseSensitive) { $found = $true; break }
        }
        if (-not $found) { return $false }
    }
    return $true
}

function Compare-MbcValue {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][object] $Actual,
        [Parameter(Mandatory)][string] $Operator,
        [AllowNull()][object] $Expected,
        [switch] $CaseSensitive
    )
    $cs = [bool]$CaseSensitive
    $pass = New-MbcComparison -Verdict 'Pass' -Cause $null
    $fail = New-MbcComparison -Verdict 'Fail' -Cause $null
    $wantList = New-MbcComparison -Verdict 'Error' -Cause 'baseline expects a list'
    $wantScalar = New-MbcComparison -Verdict 'Error' -Cause 'baseline expects a single value'

    if ($Operator -eq 'exists') { if (Test-MbcNotFound $Actual) { return $fail } else { return $pass } }
    if ($Operator -eq 'absent') { if (Test-MbcNotFound $Actual) { return $pass } else { return $fail } }
    if (Test-MbcNotFound $Actual) { return (New-MbcComparison -Verdict 'Error' -Cause 'setting not found') }

    if ($Operator -in 'equals', 'notEquals') {
        $actualScalar = Test-MbcIsScalar $Actual
        $expectedScalar = Test-MbcIsScalar $Expected
        if ($actualScalar -ne $expectedScalar) { if ($expectedScalar) { return $wantScalar } else { return $wantList } }
        $equal = Test-MbcMemberEqual -Left $Actual -Right $Expected -CaseSensitive $cs
        if (($Operator -eq 'equals') -eq $equal) { return $pass }
        return $fail
    }
    if ($Operator -eq 'in') {
        if (-not (Test-MbcIsScalar $Actual)) { return $wantScalar }
        foreach ($e in @($Expected)) { if (Test-MbcScalarEqual -Left $Actual -Right $e -CaseSensitive $cs) { return $pass } }
        return $fail
    }
    if ($Operator -eq 'contains') {
        if (-not (Test-MbcIsList $Actual)) { return $wantList }
        foreach ($a in $Actual) { if (Test-MbcMemberEqual -Left $a -Right $Expected -CaseSensitive $cs) { return $pass } }
        return $fail
    }
    if ($Operator -eq 'setEquals') {
        if (-not (Test-MbcIsList $Actual)) { return $wantList }
        if ((Test-MbcSubset -Items $Actual -Of $Expected -CaseSensitive $cs) -and (Test-MbcSubset -Items $Expected -Of $Actual -CaseSensitive $cs)) { return $pass }
        return $fail
    }
    if ($Operator -eq 'subsetOf') {
        if (-not (Test-MbcIsList $Actual)) { return $wantList }
        if (Test-MbcSubset -Items $Actual -Of $Expected -CaseSensitive $cs) { return $pass }
        return $fail
    }
    if ($Operator -in 'countAtLeast', 'countAtMost') {
        if (-not (Test-MbcIsList $Actual)) { return $wantList }
        $ok = if ($Operator -eq 'countAtLeast') { $Actual.Count -ge [long]$Expected } else { $Actual.Count -le [long]$Expected }
        if ($ok) { return $pass }
        return $fail
    }
    if ($Operator -eq 'matches') {
        if ($Actual -isnot [string]) { return $wantScalar }
        $options = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        if (-not $cs) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
        try { $regex = [regex]::new([string]$Expected, $options, [TimeSpan]::FromSeconds(1)) }
        catch { return (New-MbcComparison -Verdict 'Error' -Cause 'invalid pattern') }
        try {
            if ($regex.IsMatch($Actual)) { return $pass }
            return $fail
        }
        catch {
            # IsMatch can only fail by timing out; a typed catch would depend on PowerShell unwrapping it.
            return (New-MbcComparison -Verdict 'Error' -Cause 'pattern too slow')
        }
    }
    throw "Unknown operator '$Operator'."
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Operators.Tests.ps1 -Output Detailed`
Expected: PASS: 14 table rows, plus 9 NotFound rows, plus 5 other tests.

- [ ] **Step 6: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Common/Causes.ps1 src/Checks/Operators.ps1 tests/Operators.Tests.ps1
git commit -m "feat: operators, and a closed vocabulary of error causes" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Read-scope shape and preset/baseline validation

**Files:**
- Create: `src/Graph/Scope.ps1`, `src/Baseline/Shape.ps1`
- Create: `tests/fixtures/preset-minimal.json`, `tests/fixtures/baseline-minimal.json`
- Test: `tests/Shape.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-MbcPathQuery` (Task 3), `$script:MbcOperators` (Task 4), and the value helpers (Task 3).
- Produces:
  - `Test-MbcReadScope -Scope <string>` → bool.
  - `Test-MbcPresetShape -Preset <object> [-Where <string>]` → `string[]` of problems. An empty result means valid.
  - `Test-MbcBaselineShape -Baseline <object>` → `string[]` of problems.
  - `$script:MbcSeverities`.
  - `Get-MbcCheckApiVersion -Check` → `'v1.0'` or `'beta'`.
  - `Test-MbcRequestDeclared -Request <string> -Endpoints <string[]>` → bool.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/preset-minimal.json`:
```json
{
  "schemaVersion": 1,
  "name": "Fixture preset",
  "description": "Two checks against synthetic responses.",
  "scopes": ["Policy.Read.All"],
  "endpoints": ["/policies/authorizationPolicy", "/identity/conditionalAccess/policies"],
  "checks": [
    {
      "id": "ORG-001",
      "title": "Users cannot register applications",
      "request": "/policies/authorizationPolicy",
      "select": "defaultUserRolePermissions.allowedToCreateApps",
      "operator": "equals",
      "severity": "medium",
      "why": "Registering an application is an administrative decision."
    },
    {
      "id": "CA-001",
      "title": "At least one Conditional Access policy is enabled",
      "request": "/identity/conditionalAccess/policies",
      "select": "value[?state=='enabled'].displayName",
      "operator": "countAtLeast",
      "severity": "high"
    }
  ]
}
```

`tests/fixtures/baseline-minimal.json` is unsealed on purpose; tests seal copies of it in `$TestDrive`. Its `preset` member is **exactly** the preset above without `description`, followed by `"expected": { "ORG-001": false, "CA-001": 1 }`:
```json
{
  "schemaVersion": 1,
  "name": "Fixture baseline",
  "version": 1,
  "preset": {
    "schemaVersion": 1,
    "name": "Fixture preset",
    "scopes": ["Policy.Read.All"],
    "endpoints": ["/policies/authorizationPolicy", "/identity/conditionalAccess/policies"],
    "checks": [
      {
        "id": "ORG-001",
        "title": "Users cannot register applications",
        "request": "/policies/authorizationPolicy",
        "select": "defaultUserRolePermissions.allowedToCreateApps",
        "operator": "equals",
        "severity": "medium",
        "why": "Registering an application is an administrative decision."
      },
      {
        "id": "CA-001",
        "title": "At least one Conditional Access policy is enabled",
        "request": "/identity/conditionalAccess/policies",
        "select": "value[?state=='enabled'].displayName",
        "operator": "countAtLeast",
        "severity": "high"
      }
    ]
  },
  "expected": { "ORG-001": false, "CA-001": 1 }
}
```

- [ ] **Step 2: Write the failing tests** in `tests/Shape.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Read-scope shape' {
        It '<Scope> is a read scope: <Read>' -ForEach @(
            @{ Scope = 'Policy.Read.All'; Read = $true }
            @{ Scope = 'User.ReadBasic.All'; Read = $true }
            @{ Scope = 'Policy.Read.ConditionalAccess'; Read = $true }
            @{ Scope = 'openid'; Read = $true }
            @{ Scope = 'offline_access'; Read = $true }
            @{ Scope = 'Directory.ReadWrite.All'; Read = $false }
            @{ Scope = 'Mail.Send'; Read = $false }
            @{ Scope = 'Directory.AccessAsUser.All'; Read = $false }
            @{ Scope = 'Sites.FullControl.All'; Read = $false }
            @{ Scope = 'Policy.Read.Write.All'; Read = $false }
            @{ Scope = 'Read'; Read = $false }
        ) {
            Test-MbcReadScope -Scope $Scope | Should -Be $Read
        }
    }

    Describe 'Declared endpoints' {
        It 'matches the path itself, a child path, or the path with a query' {
            Test-MbcRequestDeclared -Request '/directoryRoles' -Endpoints @('/directoryRoles') | Should -BeTrue
            Test-MbcRequestDeclared -Request '/directoryRoles/abc/members' -Endpoints @('/directoryRoles') | Should -BeTrue
            Test-MbcRequestDeclared -Request '/directoryRoles?$expand=members' -Endpoints @('/directoryRoles') | Should -BeTrue
        }
        It 'does not match a path that merely starts with the same letters' {
            Test-MbcRequestDeclared -Request '/directoryRolesTemplates' -Endpoints @('/directoryRoles') | Should -BeFalse
        }
    }

    Describe 'Preset and baseline validation' {
        BeforeAll {
            $script:Fixtures = Join-Path $script:ModuleRoot 'tests/fixtures'
            function script:Get-Fixture([string] $Name) {
                ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fixtures $Name)))
            }
        }
        It 'accepts the fixture preset and baseline' {
            @(Test-MbcPresetShape -Preset (Get-Fixture 'preset-minimal.json')) | Should -BeNullOrEmpty
            @(Test-MbcBaselineShape -Baseline (Get-Fixture 'baseline-minimal.json')) | Should -BeNullOrEmpty
        }
        It 'names an unknown member' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['colour'] = 'blue'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match "unknown member 'colour'"
        }
        It 'requires exactly one of select and extractor' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['extractor'] = 'extractors/x.ps1'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'exactly one of select or extractor'
        }
        It 'rejects a duplicate check id' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][1]['id'] = 'ORG-001'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'ORG-001.*more than once'
        }
        It 'rejects a request outside the declared endpoints' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['request'] = '/users'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'not under a declared endpoint'
        }
        It 'rejects a scope that is not a read scope' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['scopes'] = @('Policy.ReadWrite.ConditionalAccess')
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match 'not a read scope'
        }
        It 'rejects an unreadable select' {
            $p = Get-Fixture 'preset-minimal.json'
            $p['checks'][0]['select'] = 'a..b'
            (Test-MbcPresetShape -Preset $p) -join "`n" | Should -Match "Can't read select"
        }
        It 'requires an expected value for every check that needs one' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['expected'].Remove('CA-001')
            (Test-MbcBaselineShape -Baseline $b) -join "`n" | Should -Match 'CA-001.*no expected value'
        }
        It 'rejects an expected value for a check that does not exist' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['expected']['NOPE-1'] = 1L
            (Test-MbcBaselineShape -Baseline $b) -join "`n" | Should -Match 'NOPE-1.*no such check'
        }
        It 'checks the expected value fits the operator' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['expected']['CA-001'] = 'many'
            (Test-MbcBaselineShape -Baseline $b) -join "`n" | Should -Match 'CA-001.*whole number'
        }
        It 'validates a seal block' {
            $b = Get-Fixture 'baseline-minimal.json'
            $b['seal'] = [ordered]@{ algorithm = 'MD5'; digest = 'abc'; sealedVersion = 1L }
            $text = (Test-MbcBaselineShape -Baseline $b) -join "`n"
            $text | Should -Match 'SHA-256'
            $text | Should -Match '64 lowercase hex'
        }
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Shape.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Test-MbcReadScope' is not recognized`.

- [ ] **Step 4: Implement** `src/Graph/Scope.ps1`

```powershell
# OpenID Connect scopes that every delegated token carries. None of them can change anything in a tenant.
$script:MbcIdentityScopes = @('openid', 'profile', 'offline_access', 'email')

function Test-MbcReadScope {
    <#
    .SYNOPSIS
        True when a scope is recognisably a read: Resource.Read or Resource.ReadBasic, with qualifiers,
        and no write verb anywhere. A scope that is not recognisably a read is treated as a write.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Scope)
    if ($Scope -in $script:MbcIdentityScopes) { return $true }
    $parts = [string[]]($Scope -split '\.')
    if ($parts.Count -lt 2) { return $false }
    $readAt = [array]::FindIndex($parts, [Predicate[string]] { param($p) $p -ceq 'Read' -or $p -ceq 'ReadBasic' })
    if ($readAt -lt 1) { return $false }
    foreach ($p in $parts) {
        if ($p -match '(?i)write|send|manage|create|delete|update|invite|execute|admin|full|access') { return $false }
    }
    return $true
}
```

- [ ] **Step 5: Implement** `src/Baseline/Shape.ps1`

```powershell
$script:MbcSeverities = @('high', 'medium', 'low', 'info')
$script:MbcCheckMembers = @('id', 'title', 'request', 'select', 'extractor', 'operator', 'severity', 'why', 'caseSensitive', 'apiVersion')
$script:MbcPresetMembers = @('schemaVersion', 'name', 'description', 'scopes', 'endpoints', 'checks')
$script:MbcBaselineMembers = @('schemaVersion', 'name', 'version', 'description', 'preset', 'expected', 'seal')
$script:MbcSealMembers = @('algorithm', 'digest', 'sealedVersion')

function Get-MbcCheckApiVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check)
    if ($Check.Contains('apiVersion')) { return [string]$Check['apiVersion'] }
    return 'v1.0'
}

function Test-MbcRequestDeclared {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Request, [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Endpoints)
    $path = ($Request -split '\?', 2)[0]
    foreach ($endpoint in $Endpoints) {
        $e = $endpoint.TrimEnd('/')
        if ($path -ieq $e -or $path.StartsWith("$e/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-MbcNonEmptyString {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Value)
    return ($Value -is [string] -and $Value.Trim().Length -gt 0)
}

function Add-MbcUnknownMemberProblem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Object,
        [Parameter(Mandatory)][string[]] $Allowed,
        [Parameter(Mandatory)][string] $Where,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Problems
    )
    foreach ($k in $Object.Keys) {
        if ($k -notin $Allowed) { $Problems.Add("${Where}: unknown member '$k'") }
    }
}

function Test-MbcCheckShape {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object] $Check, [Parameter(Mandatory)][string] $Where, [AllowEmptyCollection()][string[]] $Endpoints = @())
    $p = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-MbcIsDictionary $Check)) { $p.Add("${Where}: a check must be an object"); return , $p.ToArray() }
    Add-MbcUnknownMemberProblem -Object $Check -Allowed $script:MbcCheckMembers -Where $Where -Problems $p

    $id = $Check['id']
    if (-not ($id -is [string] -and $id -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')) {
        $p.Add("${Where}: id must be 1 to 64 letters, digits, dots, dashes or underscores")
    }
    if (-not ((Test-MbcNonEmptyString $Check['title']) -and $Check['title'].Length -le 200)) {
        $p.Add("${Where}: title must be text of 1 to 200 characters")
    }
    $request = $Check['request']
    if (-not ($request -is [string] -and $request -match '^/' -and $request -notmatch '://|\.\.|\s')) {
        $p.Add("${Where}: request must be a Graph path starting with '/', like /policies/authorizationPolicy")
    }
    elseif ($Endpoints.Count -gt 0 -and -not (Test-MbcRequestDeclared -Request $request -Endpoints $Endpoints)) {
        $p.Add("${Where}: request '$request' is not under a declared endpoint")
    }

    $hasSelect = $Check.Contains('select')
    $hasExtractor = $Check.Contains('extractor')
    if ($hasSelect -eq $hasExtractor) {
        $p.Add("${Where}: give exactly one of select or extractor")
    }
    elseif ($hasSelect) {
        if (-not (Test-MbcNonEmptyString $Check['select'])) { $p.Add("${Where}: select must be text") }
        else {
            try { [void](ConvertTo-MbcPathQuery -Select $Check['select']) }
            catch { $p.Add("${Where}: $($_.Exception.Message)") }
        }
    }
    elseif (-not ($Check['extractor'] -is [string] -and $Check['extractor'] -match '^extractors/[A-Za-z0-9._-]+\.ps1$')) {
        $p.Add("${Where}: extractor must name a file like extractors/AUTH-009.ps1")
    }

    if ($Check['operator'] -notin $script:MbcOperators) {
        $p.Add("${Where}: operator must be one of $($script:MbcOperators -join ', ')")
    }
    if ($Check['severity'] -notin $script:MbcSeverities) {
        $p.Add("${Where}: severity must be one of $($script:MbcSeverities -join ', ')")
    }
    if ($Check.Contains('why') -and -not ($Check['why'] -is [string])) { $p.Add("${Where}: why must be text") }
    if ($Check.Contains('caseSensitive') -and -not ($Check['caseSensitive'] -is [bool])) { $p.Add("${Where}: caseSensitive must be true or false") }
    if ($Check.Contains('apiVersion') -and $Check['apiVersion'] -notin 'v1.0', 'beta') { $p.Add("${Where}: apiVersion must be v1.0 or beta") }
    return , $p.ToArray()
}

function Test-MbcPresetShape {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object] $Preset, [string] $Where = 'preset')
    $p = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-MbcIsDictionary $Preset)) { $p.Add("${Where}: must be an object"); return , $p.ToArray() }
    Add-MbcUnknownMemberProblem -Object $Preset -Allowed $script:MbcPresetMembers -Where $Where -Problems $p

    if (-not ((Test-MbcIsWholeNumber $Preset['schemaVersion']) -and $Preset['schemaVersion'] -eq 1)) { $p.Add("${Where}: schemaVersion must be 1") }
    if (-not (Test-MbcNonEmptyString $Preset['name'])) { $p.Add("${Where}: name must be text") }
    if ($Preset.Contains('description') -and -not ($Preset['description'] -is [string])) { $p.Add("${Where}: description must be text") }

    $scopes = $Preset['scopes']
    if (-not ((Test-MbcIsList $scopes) -and $scopes.Count -gt 0)) { $p.Add("${Where}: scopes must be a non-empty list") }
    else {
        foreach ($s in $scopes) {
            if (-not (Test-MbcNonEmptyString $s)) { $p.Add("${Where}: every scope must be text") }
            elseif (-not (Test-MbcReadScope -Scope $s)) { $p.Add("${Where}: '$s' is not a read scope, and this tool only reads") }
        }
    }

    $endpoints = [System.Collections.Generic.List[string]]::new()
    if (-not ((Test-MbcIsList $Preset['endpoints']) -and $Preset['endpoints'].Count -gt 0)) { $p.Add("${Where}: endpoints must be a non-empty list") }
    else {
        foreach ($e in $Preset['endpoints']) {
            if ($e -is [string] -and $e -match '^/[^\s?]*$' -and $e -notmatch '\.\.') { $endpoints.Add($e) }
            else { $p.Add("${Where}: endpoint '$e' must be a Graph path starting with '/', with no query string") }
        }
    }

    $checks = $Preset['checks']
    if (-not ((Test-MbcIsList $checks) -and $checks.Count -gt 0)) { $p.Add("${Where}: checks must be a non-empty list") }
    else {
        $seen = @{}
        for ($i = 0; $i -lt $checks.Count; $i++) {
            $hasId = (Test-MbcIsDictionary $checks[$i]) -and $checks[$i]['id'] -is [string]
            $label = if ($hasId) { "check $($checks[$i]['id'])" } else { "check #$($i + 1)" }
            foreach ($problem in (Test-MbcCheckShape -Check $checks[$i] -Where $label -Endpoints $endpoints.ToArray())) { $p.Add($problem) }
            if ($hasId) {
                $key = $checks[$i]['id'].ToLowerInvariant()
                if ($seen.ContainsKey($key)) { $p.Add("check $($checks[$i]['id']): this id is used more than once") }
                $seen[$key] = $true
            }
        }
    }
    return , $p.ToArray()
}

function Get-MbcExpectedMisfit {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Operator, [AllowNull()][object] $Value)
    if ($Operator -in 'in', 'setEquals', 'subsetOf') {
        if (-not (Test-MbcIsList $Value)) { return 'expects a list' }
    }
    elseif ($Operator -in 'countAtLeast', 'countAtMost') {
        if (-not ((Test-MbcIsWholeNumber $Value) -and $Value -ge 0)) { return 'expects a whole number of zero or more' }
    }
    elseif ($Operator -eq 'contains') {
        if (-not (Test-MbcIsScalar $Value)) { return 'expects a single value' }
    }
    elseif ($Operator -eq 'matches') {
        if ($Value -isnot [string]) { return 'expects a regular expression as text' }
        try { [void][regex]::new($Value) } catch { return 'has an invalid regular expression' }
    }
    return $null
}

function Test-MbcBaselineShape {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object] $Baseline)
    $p = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-MbcIsDictionary $Baseline)) { $p.Add('baseline: must be an object'); return , $p.ToArray() }
    Add-MbcUnknownMemberProblem -Object $Baseline -Allowed $script:MbcBaselineMembers -Where 'baseline' -Problems $p

    if (-not ((Test-MbcIsWholeNumber $Baseline['schemaVersion']) -and $Baseline['schemaVersion'] -eq 1)) { $p.Add('baseline: schemaVersion must be 1') }
    if (-not (Test-MbcNonEmptyString $Baseline['name'])) { $p.Add('baseline: name must be text') }
    if (-not ((Test-MbcIsWholeNumber $Baseline['version']) -and $Baseline['version'] -ge 1)) { $p.Add('baseline: version must be a whole number of 1 or more') }
    if ($Baseline.Contains('description') -and -not ($Baseline['description'] -is [string])) { $p.Add('baseline: description must be text') }

    foreach ($problem in (Test-MbcPresetShape -Preset $Baseline['preset'] -Where 'preset')) { $p.Add($problem) }

    $expected = $Baseline['expected']
    $preset = $Baseline['preset']
    if (-not (Test-MbcIsDictionary $expected)) { $p.Add('baseline: expected must be an object of check id to value') }
    elseif ((Test-MbcIsDictionary $preset) -and (Test-MbcIsList $preset['checks'])) {
        $checksById = @{}
        foreach ($c in $preset['checks']) { if ((Test-MbcIsDictionary $c) -and $c['id'] -is [string]) { $checksById[$c['id']] = $c } }
        foreach ($k in $expected.Keys) { if (-not $checksById.ContainsKey($k)) { $p.Add("expected ${k}: there is no such check in the preset") } }
        foreach ($id in $checksById.Keys) {
            $check = $checksById[$id]
            if ($check['operator'] -in 'exists', 'absent') { continue }
            if (-not $expected.Contains($id)) { $p.Add("check ${id}: has no expected value"); continue }
            $misfit = Get-MbcExpectedMisfit -Operator ([string]$check['operator']) -Value $expected[$id]
            if ($misfit) { $p.Add("check ${id}: $($check['operator']) $misfit") }
        }
    }

    if ($Baseline.Contains('seal')) {
        $seal = $Baseline['seal']
        if (-not (Test-MbcIsDictionary $seal)) { $p.Add('seal: must be an object') }
        else {
            Add-MbcUnknownMemberProblem -Object $seal -Allowed $script:MbcSealMembers -Where 'seal' -Problems $p
            if ($seal['algorithm'] -cne 'SHA-256') { $p.Add('seal: algorithm must be SHA-256') }
            if (-not ($seal['digest'] -is [string] -and $seal['digest'] -cmatch '^[0-9a-f]{64}$')) { $p.Add('seal: digest must be 64 lowercase hex characters') }
            if (-not ((Test-MbcIsWholeNumber $seal['sealedVersion']) -and $seal['sealedVersion'] -ge 1)) { $p.Add('seal: sealedVersion must be a whole number of 1 or more') }
        }
    }
    return , $p.ToArray()
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Shape.Tests.ps1 -Output Detailed`
Expected: PASS: 11 scope rows, plus 2 endpoint tests, plus 11 validation tests.

- [ ] **Step 7: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Graph/Scope.ps1 src/Baseline/Shape.ps1 tests/fixtures/preset-minimal.json tests/fixtures/baseline-minimal.json tests/Shape.Tests.ps1
git commit -m "feat: preset and baseline validation, and the read-scope shape" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Sealing, verifying, and the `Protect-Baseline` / `Test-Baseline` commands

**Files:**
- Create: `src/Baseline/Baseline.ps1`, `src/Public/Protect-Baseline.ps1`, `src/Public/Test-Baseline.ps1`
- Test: `tests/Baseline.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertFrom-MbcJson`, `ConvertTo-MbcCanonicalJson`, `ConvertTo-MbcPrettyJson`, `Get-MbcSha256Hex` (Task 2), and `Test-MbcBaselineShape` (Task 5).
- Produces:
  - `Get-MbcDocumentDigest -Document <IDictionary>` → 64 hex characters, over everything except `seal`.
  - `Read-MbcBaseline -Path` → a `Mbc.Baseline` object: `{ Path; Document; Name; Version; Digest; Fingerprint; SealState ('Sealed'|'Unsealed'|'Modified'); SealedVersion }`.
  - `Assert-MbcBaselineUsable -Baseline [-AllowUnsealed] [-ExpectedFingerprint <string>]`, which throws with a voice-guide message.
  - `Get-MbcBaselineIdentity -Baseline` → `{ Name; Version; Fingerprint; Digest; SealState; Path; Record }`, where `Record` is `"<name> · v<version> · SHA-256 <digest>"`.
  - `Protect-Baseline -Path` and `Test-Baseline -Path`, both public.

- [ ] **Step 1: Write the failing tests** in `tests/Baseline.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Sealing and verifying a baseline' {
        BeforeEach {
            $script:Path = Join-Path $TestDrive 'b.json'
            Copy-Item (Join-Path $script:ModuleRoot 'tests/fixtures/baseline-minimal.json') $script:Path -Force
        }

        It 'reads an unsealed baseline as Unsealed and refuses to use it' {
            $b = Read-MbcBaseline -Path $script:Path
            $b.SealState | Should -Be 'Unsealed'
            { Assert-MbcBaselineUsable -Baseline $b } | Should -Throw '*never been sealed*'
            { Assert-MbcBaselineUsable -Baseline $b -AllowUnsealed } | Should -Not -Throw
        }

        It 'seals, and the result reads as Sealed with a 12-character fingerprint' {
            $id = Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue
            $id.SealState | Should -Be 'Sealed'
            $id.Fingerprint | Should -Match '^[0-9a-f]{12}$'
            $id.Record | Should -BeExactly "Fixture baseline · v1 · SHA-256 $($id.Digest)"
            (Read-MbcBaseline -Path $script:Path).SealState | Should -Be 'Sealed'
        }

        It 'writes UTF-8 without a BOM, with LF line endings' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $bytes = [System.IO.File]::ReadAllBytes($script:Path)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
            ($bytes -contains [byte]13) | Should -BeFalse
        }

        It 'stays Sealed when only formatting or key order changes' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $doc = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText($script:Path))
            $reordered = [ordered]@{}
            foreach ($k in (@($doc.Keys) | Sort-Object -Descending)) { $reordered[$k] = $doc[$k] }
            [System.IO.File]::WriteAllText($script:Path, (ConvertTo-MbcCanonicalJson $reordered))
            (Read-MbcBaseline -Path $script:Path).SealState | Should -Be 'Sealed'
        }

        It 'reads an edited baseline as Modified, and refuses it' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $text = [System.IO.File]::ReadAllText($script:Path).Replace('"CA-001": 1', '"CA-001": 2')
            [System.IO.File]::WriteAllText($script:Path, $text)
            $b = Read-MbcBaseline -Path $script:Path
            $b.SealState | Should -Be 'Modified'
            { Assert-MbcBaselineUsable -Baseline $b } | Should -Throw '*edited since v1 was sealed*'
        }

        It 'refuses to reseal changed content under the same version, and reseals after a bump' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $text = [System.IO.File]::ReadAllText($script:Path).Replace('"CA-001": 1', '"CA-001": 2')
            [System.IO.File]::WriteAllText($script:Path, $text)
            { Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue } | Should -Throw '*Raise the version above 1*'
            [System.IO.File]::WriteAllText($script:Path, $text.Replace('"version": 1', '"version": 2'))
            (Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue).Version | Should -Be 2
        }

        It 'reports an unchanged, sealed baseline as already sealed and leaves it alone' {
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            $before = [System.IO.File]::ReadAllText($script:Path)
            Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue | Out-Null
            [System.IO.File]::ReadAllText($script:Path) | Should -BeExactly $before
        }

        It 'checks an expected fingerprint' {
            $id = Protect-Baseline -Path $script:Path -InformationAction SilentlyContinue
            $b = Read-MbcBaseline -Path $script:Path
            { Assert-MbcBaselineUsable -Baseline $b -ExpectedFingerprint $id.Fingerprint } | Should -Not -Throw
            { Assert-MbcBaselineUsable -Baseline $b -ExpectedFingerprint '000000000000' } | Should -Throw '*Fingerprint mismatch*'
            { Assert-MbcBaselineUsable -Baseline $b -ExpectedFingerprint 'xyz' } | Should -Throw '*at least 12 hex*'
        }

        It 'explains an invalid baseline instead of reading it' {
            [System.IO.File]::WriteAllText($script:Path, '{"schemaVersion":1}')
            { Read-MbcBaseline -Path $script:Path } | Should -Throw "*isn't a valid baseline*"
        }

        It 'Test-Baseline reports identity without changing anything' {
            $before = [System.IO.File]::ReadAllText($script:Path)
            $r = Test-Baseline -Path $script:Path -InformationAction SilentlyContinue
            $r.SealState | Should -Be 'Unsealed'
            [System.IO.File]::ReadAllText($script:Path) | Should -BeExactly $before
        }
    }
}
```

The fixture is pretty-printed with `"CA-001": 1` and `"version": 1` written exactly like that. The string replacements above depend on it, so keep the fixture's formatting as given in Task 5.

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Baseline.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Read-MbcBaseline' is not recognized`.

- [ ] **Step 3: Implement** `src/Baseline/Baseline.ps1`

```powershell
function Get-MbcDocumentDigest {
    <#
    .SYNOPSIS
        SHA-256 of the canonical JSON of a document without its seal. Formatting and key order do not
        change it; content does.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    $copy = [ordered]@{}
    foreach ($k in $Document.Keys) { if ($k -ne 'seal') { $copy[$k] = $Document[$k] } }
    return (Get-MbcSha256Hex -Text (ConvertTo-MbcCanonicalJson -Value $copy))
}

function Read-MbcBaseline {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "There's no baseline at '$Path'." }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $doc = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8))
    if (-not (Test-MbcIsDictionary $doc)) { throw "'$Path' isn't a baseline: the top level must be an object." }
    $problems = @(Test-MbcBaselineShape -Baseline $doc)
    if ($problems.Count -gt 0) { throw ("'{0}' isn't a valid baseline:`n  - {1}" -f $Path, ($problems -join "`n  - ")) }

    $digest = Get-MbcDocumentDigest -Document $doc
    $seal = if ($doc.Contains('seal')) { $doc['seal'] } else { $null }
    $state = if ($null -eq $seal) { 'Unsealed' } elseif ($seal['digest'] -ceq $digest) { 'Sealed' } else { 'Modified' }
    return [pscustomobject]@{
        PSTypeName    = 'Mbc.Baseline'
        Path          = $full
        Document      = $doc
        Name          = [string]$doc['name']
        Version       = [long]$doc['version']
        Digest        = $digest
        Fingerprint   = $digest.Substring(0, 12)
        SealState     = $state
        SealedVersion = if ($null -ne $seal) { [long]$seal['sealedVersion'] } else { $null }
    }
}

function Assert-MbcBaselineUsable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Baseline,
        [switch] $AllowUnsealed,
        [string] $ExpectedFingerprint
    )
    if ($ExpectedFingerprint) {
        $want = $ExpectedFingerprint.Trim().ToLowerInvariant()
        if ($want -notmatch '^[0-9a-f]{12,64}$') { throw "-ExpectedFingerprint should be at least 12 hex characters; '$ExpectedFingerprint' isn't." }
        if (-not $Baseline.Digest.StartsWith($want)) {
            throw ('Fingerprint mismatch: you expected {0}, but this file is {1}. It may be an older or newer copy than the one you catalogued.' -f $want.Substring(0, 12), $Baseline.Fingerprint)
        }
    }
    if ($Baseline.SealState -eq 'Sealed' -or $AllowUnsealed) { return }
    if ($Baseline.SealState -eq 'Unsealed') {
        throw 'This baseline has never been sealed. Seal it with Protect-Baseline, or run with -AllowUnsealed while you work on it.'
    }
    throw ('This baseline has been edited since v{0} was sealed. Raise the version and seal it again, or run with -AllowUnsealed while you work on it.' -f $Baseline.SealedVersion)
}

function Get-MbcBaselineIdentity {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Baseline)
    return [pscustomobject]@{
        PSTypeName  = 'Mbc.BaselineIdentity'
        Name        = $Baseline.Name
        Version     = $Baseline.Version
        Fingerprint = $Baseline.Fingerprint
        Digest      = $Baseline.Digest
        SealState   = $Baseline.SealState
        Path        = $Baseline.Path
        Record      = '{0} · v{1} · SHA-256 {2}' -f $Baseline.Name, $Baseline.Version, $Baseline.Digest
    }
}
```

- [ ] **Step 4: Implement** `src/Public/Protect-Baseline.ps1`

```powershell
function Protect-Baseline {
    <#
    .SYNOPSIS
        Validates a baseline and seals it with a SHA-256 digest of its canonical form.
    .DESCRIPTION
        Refuses to reseal changed content under the version that was sealed, so every real change is a
        new version. Prints the line to record wherever your baselines are catalogued.
    .EXAMPLE
        Protect-Baseline ./baselines/core-tenant.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, Position = 0)][string] $Path)

    $b = Read-MbcBaseline -Path $Path
    if ($b.SealState -eq 'Sealed') {
        Write-Information ('Already sealed, and unchanged since: {0} · v{1} · {2}.' -f $b.Name, $b.Version, $b.Fingerprint) -InformationAction Continue
        return (Get-MbcBaselineIdentity -Baseline $b)
    }
    if ($b.SealState -eq 'Modified' -and $b.Version -le $b.SealedVersion) {
        throw ('Content has changed since v{0} was sealed. Raise the version above {0} before sealing.' -f $b.SealedVersion)
    }

    $sealed = [ordered]@{}
    foreach ($k in $b.Document.Keys) { if ($k -ne 'seal') { $sealed[$k] = $b.Document[$k] } }
    $sealed['seal'] = [ordered]@{ algorithm = 'SHA-256'; digest = $b.Digest; sealedVersion = $b.Version }

    if ($PSCmdlet.ShouldProcess($b.Path, "Seal $($b.Name) v$($b.Version)")) {
        [System.IO.File]::WriteAllText($b.Path, (ConvertTo-MbcPrettyJson -Value $sealed), [System.Text.UTF8Encoding]::new($false))
        Write-Information ('Sealed. {0} is v{1}; its fingerprint is {2}. Record it wherever you keep these:' -f $b.Name, $b.Version, $b.Fingerprint) -InformationAction Continue
        Write-Information ('  {0} · v{1} · SHA-256 {2}' -f $b.Name, $b.Version, $b.Digest) -InformationAction Continue
    }
    return (Get-MbcBaselineIdentity -Baseline (Read-MbcBaseline -Path $b.Path))
}
```

- [ ] **Step 5: Implement** `src/Public/Test-Baseline.ps1`

```powershell
function Test-Baseline {
    <#
    .SYNOPSIS
        Verifies a baseline's seal and prints its identity. Changes nothing.
    .EXAMPLE
        Test-Baseline ./baselines/core-tenant.json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, Position = 0)][string] $Path)
    $b = Read-MbcBaseline -Path $Path
    $state = switch ($b.SealState) {
        'Sealed' { 'sealed, and unchanged since' }
        'Unsealed' { 'not sealed' }
        'Modified' { "edited since v$($b.SealedVersion) was sealed" }
    }
    Write-Information ('{0} · v{1} · {2} · {3}' -f $b.Name, $b.Version, $b.Fingerprint, $state) -InformationAction Continue
    return (Get-MbcBaselineIdentity -Baseline $b)
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Baseline.Tests.ps1 -Output Detailed`
Expected: PASS, 10 tests.

- [ ] **Step 7: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Baseline/Baseline.ps1 src/Public/Protect-Baseline.ps1 src/Public/Test-Baseline.ps1 tests/Baseline.Tests.ps1
git commit -m "feat: seal and verify baselines; Protect-Baseline and Test-Baseline" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Extractors: a purity check, then invocation

**Files:**
- Create: `src/Checks/Extractor.ps1`
- Create: `tests/fixtures/extractors/pure.ps1`, `tests/fixtures/extractors/impure.ps1`
- Test: `tests/Extractor.Tests.ps1`

**Interfaces:**
- Consumes: `$script:ModuleRoot` (Task 1).
- Produces:
  - `Test-MbcExtractorPurity -Path <string>` → `string[]` of problems. Empty means allowed.
  - `Invoke-MbcExtractor -RelativePath <string> -Response <object> [-Root <string>]` → `{ Ok; Value; Cause; Detail }`.
    - `-Root` defaults to `$script:ModuleRoot`.
    - Causes: `'extractor not allowed'`, `'extractor failed'`.
    - `Value` may be `$script:MbcNotFound` if the extractor returns it. Extractors normally return a value.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/extractors/pure.ps1`:
```powershell
param($Response)
# True when any enabled policy in the response blocks access for everyone.
$blocking = @($Response['value'] | Where-Object {
        $gc = $_['grantControls']
        $_['state'] -eq 'enabled' -and $gc -and (@($gc['builtInControls']) -contains 'block')
    })
return ($blocking.Count -gt 0)
```

`tests/fixtures/extractors/impure.ps1`:
```powershell
param($Response)
$null = Invoke-RestMethod -Uri 'https://example.com/'
[System.IO.File]::ReadAllText('x')
& $Response
return $true
```

- [ ] **Step 2: Write the failing tests** in `tests/Extractor.Tests.ps1`

```powershell
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
            $problems | Should -Match "Invoke-RestMethod"
            $problems | Should -Match 'System.IO.File'
            $problems | Should -Match 'computed name'
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
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Extractor.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Test-MbcExtractorPurity' is not recognized`.

- [ ] **Step 4: Implement** `src/Checks/Extractor.ps1`

```powershell
# What an extractor may call. Deliberately small: filtering and shaping the response it is given, nothing else.
$script:MbcExtractorCommands = @('Where-Object', 'ForEach-Object', 'Select-Object', 'Sort-Object', 'Group-Object', 'Measure-Object', 'Write-Output')
$script:MbcExtractorTypes = @('string', 'int', 'long', 'bool', 'array', 'hashtable', 'ordered', 'object', 'object[]', 'string[]',
    'math', 'regex', 'pscustomobject', 'System.StringComparison', 'System.StringComparer')
$script:MbcExtractorMethods = '^(Invoke|InvokeReturnAsIs|GetNewClosure|Create|Start|Load|LoadFrom|LoadFile|GetType|InvokeMember|CreateInstance)$'

function Test-MbcExtractorPurity {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string] $Path)
    $problems = [System.Collections.Generic.List[string]]::new()
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) { $problems.Add("doesn't parse: $($e.Message)") }

    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $line = $c.Extent.StartLineNumber
        $name = $c.GetCommandName()
        if ($null -eq $name) { $problems.Add("line ${line}: calls something by a computed name"); continue }
        if ($name -notin $script:MbcExtractorCommands) { $problems.Add("line ${line}: '$name' isn't on the list of commands an extractor may use") }
    }
    foreach ($t in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -or $n -is [System.Management.Automation.Language.TypeConstraintAst] }, $true)) {
        $typeName = $t.TypeName.FullName
        if ($typeName -notin $script:MbcExtractorTypes) { $problems.Add("line $($t.Extent.StartLineNumber): uses the type [$typeName]") }
    }
    foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $member = $m.Member.Extent.Text.Trim("'", '"')
        if ($member -match $script:MbcExtractorMethods) { $problems.Add("line $($m.Extent.StartLineNumber): calls .$member()") }
    }
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        if ($v.VariablePath.UserPath -in 'ExecutionContext', 'Host') { $problems.Add("line $($v.Extent.StartLineNumber): uses `$$($v.VariablePath.UserPath)") }
    }
    return , $problems.ToArray()
}

function Invoke-MbcExtractor {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [AllowNull()][object] $Response,
        [string] $Root = $script:ModuleRoot
    )
    $full = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor not allowed'; Detail = "There's no extractor at $RelativePath." }
    }
    $problems = @(Test-MbcExtractorPurity -Path $full)
    if ($problems.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor not allowed'; Detail = ($problems -join '; ') }
    }
    try {
        $block = [scriptblock]::Create([System.IO.File]::ReadAllText($full))
        $out = @(& $block -Response $Response)
        $value = if ($out.Count -eq 0) { $null } elseif ($out.Count -eq 1) { , $out[0] } else { , $out }
        return [pscustomobject]@{ Ok = $true; Value = $value; Cause = $null; Detail = $null }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor failed'; Detail = $_.Exception.Message }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Extractor.Tests.ps1 -Output Detailed`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the gate, then commit**

The analyser runs over `./src` and `./tools` only, so the deliberately impure fixture under `tests/` doesn't trip it.

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Checks/Extractor.ps1 tests/fixtures/extractors tests/Extractor.Tests.ps1
git commit -m "feat: extractors, refused unless they are provably pure" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: The check engine: plan, collect, evaluate

**Files:**
- Create: `src/Checks/Engine.ps1`, `src/Common/Paths.ps1`
- Create: `tests/fixtures/graph/authorizationPolicy.json`, `tests/fixtures/graph/conditionalAccessPolicies.json`
- Test: `tests/Engine.Tests.ps1`

**Interfaces:**
- Consumes: `Get-MbcCheckApiVersion`, `Test-MbcRequestDeclared` (Task 5); `ConvertTo-MbcPathQuery`, `Invoke-MbcPathQuery`, `Test-MbcNotFound` (Task 3); `Compare-MbcValue` (Task 4); `Invoke-MbcExtractor` (Task 7); and `Read-MbcBaseline` (Task 6) for tests.
- Produces:
  - **The fetch contract:** a script block `param([string] $ApiVersion, [string] $Request)` returning `[pscustomobject]@{ Ok = [bool]; Body = <parsed JSON>; Status = [int]; Cause = <string or $null>; Detail = <string or $null> }`.
  - `New-MbcFetchResult -Ok -Body -Status -Cause -Detail -Pages` → that object. Task 10's client uses it too.
  - `Get-MbcRequestPlan -Preset <IDictionary>` → `object[]` of `{ Key; ApiVersion; Request }`, deduplicated and in check order, excluding undeclared requests.
  - `Invoke-MbcCollection -Plan -Fetch [-OnProgress]` → a `hashtable` of key to fetch result. `OnProgress` receives `{ Phase ('start'|'done'); Index; Total; Request; Ok }`.
  - `Invoke-MbcEvaluation -Preset -Expected -Collected [-OnResult] [-ExtractorRoot]` → `object[]` of `Mbc.CheckResult`: `{ Id; Title; Severity; Why; Request; ApiVersion; Operator; Expected; Actual; HasActual; Verdict; Cause; Detail }`.
  - `Get-MbcCounts -Results` → `{ Pass; Fail; Error; Total }`.
  - `Invoke-MbcRun -Baseline -Fetch [-OnProgress] [-OnResult]` → `Mbc.Run { RunId; StartedUtc; FinishedUtc; Results; Counts }`. It uses `New-MbcRunId`, from `src/Common/Paths.ps1`, which this task creates in Step 4b.

- [ ] **Step 1: Write the Graph fixtures** (synthetic)

`tests/fixtures/graph/authorizationPolicy.json`:
```json
{
  "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#policies/authorizationPolicy/$entity",
  "id": "authorizationPolicy",
  "allowInvitesFrom": "adminsAndGuestInviters",
  "guestUserRoleId": "2af84b1e-32c8-42b7-82bc-daa82404023b",
  "defaultUserRolePermissions": {
    "allowedToCreateApps": false,
    "allowedToCreateSecurityGroups": false
  }
}
```

`tests/fixtures/graph/conditionalAccessPolicies.json`:
```json
{
  "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#identity/conditionalAccess/policies",
  "value": [
    { "id": "00000000-0000-4000-8000-000000000011", "displayName": "Block legacy authentication", "state": "enabled",
      "conditions": { "clientAppTypes": ["exchangeActiveSync", "other"], "users": { "includeUsers": ["All"] } },
      "grantControls": { "builtInControls": ["block"] } },
    { "id": "00000000-0000-4000-8000-000000000012", "displayName": "Require MFA for admins", "state": "enabledForReportingButNotEnforced",
      "conditions": { "clientAppTypes": ["all"], "users": { "includeUsers": ["None"] } },
      "grantControls": { "builtInControls": ["mfa"] } }
  ]
}
```

- [ ] **Step 2: Write the failing tests** in `tests/Engine.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The engine' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            $script:Baseline = Read-MbcBaseline -Path (Join-Path $script:Fx 'baseline-minimal.json')
            $script:Bodies = @{
                '/policies/authorizationPolicy'       = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/authorizationPolicy.json')))
                '/identity/conditionalAccess/policies' = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/conditionalAccessPolicies.json')))
            }
            $script:Calls = [System.Collections.Generic.List[string]]::new()
            $script:GoodFetch = {
                param($ApiVersion, $Request)
                $script:Calls.Add("$ApiVersion $Request")
                New-MbcFetchResult -Ok $true -Body $script:Bodies[$Request] -Status 200
            }
        }
        BeforeEach { $script:Calls.Clear() }

        It 'plans each distinct request once, in check order' {
            $plan = Get-MbcRequestPlan -Preset $script:Baseline.Document['preset']
            @($plan | ForEach-Object Request) -join ',' | Should -Be '/policies/authorizationPolicy,/identity/conditionalAccess/policies'
        }

        It 'fetches each request once even when several checks share it' {
            $preset = $script:Baseline.Document['preset']
            $extra = [ordered]@{}
            foreach ($k in $preset['checks'][0].Keys) { $extra[$k] = $preset['checks'][0][$k] }
            $extra['id'] = 'ORG-002'
            $shared = [ordered]@{}
            foreach ($k in $preset.Keys) { $shared[$k] = $preset[$k] }
            $shared['checks'] = @($preset['checks'][0], $extra, $preset['checks'][1])
            $plan = Get-MbcRequestPlan -Preset $shared
            Invoke-MbcCollection -Plan $plan -Fetch $script:GoodFetch | Out-Null
            $script:Calls.Count | Should -Be 2
        }

        It 'passes both fixture checks against the fixture responses' {
            $run = Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:GoodFetch
            @($run.Results | ForEach-Object Verdict) -join ',' | Should -Be 'Pass,Pass'
            $run.Counts.Pass | Should -Be 2
            $run.Counts.Total | Should -Be 2
        }

        It 'records the actual value on a Fail' {
            # No GetNewClosure() here: a closure is bound to a fresh dynamic module and cannot see this
            # module's private functions. A plain block defined inside InModuleScope can.
            $fetch = {
                param($ApiVersion, $Request)
                $body = $script:Bodies[$Request]
                if ($Request -eq '/policies/authorizationPolicy') {
                    $body = ConvertFrom-MbcJson -Json '{"defaultUserRolePermissions":{"allowedToCreateApps":true}}'
                }
                New-MbcFetchResult -Ok $true -Body $body -Status 200
            }
            $r = (Invoke-MbcRun -Baseline $script:Baseline -Fetch $fetch).Results | Where-Object Id -eq 'ORG-001'
            $r.Verdict | Should -Be 'Fail'
            $r.Actual | Should -BeTrue
            $r.HasActual | Should -BeTrue
        }

        It 'never lets a failed collection become a Pass, whatever the operator' {
            $failing = { param($ApiVersion, $Request) New-MbcFetchResult -Ok $false -Status 403 -Cause 'permission missing' -Detail 'HTTP 403' }
            $run = Invoke-MbcRun -Baseline $script:Baseline -Fetch $failing
            foreach ($r in $run.Results) {
                $r.Verdict | Should -Be 'Error'
                $r.Cause | Should -Be 'permission missing'
                $r.HasActual | Should -BeFalse
            }
            $run.Counts.Error | Should -Be 2
            $run.Counts.Pass | Should -Be 0
        }

        It 'reports a missing setting as an Error' {
            $empty = { param($ApiVersion, $Request) New-MbcFetchResult -Ok $true -Body ([ordered]@{}) -Status 200 }
            $r = (Invoke-MbcRun -Baseline $script:Baseline -Fetch $empty).Results | Where-Object Id -eq 'ORG-001'
            $r.Verdict | Should -Be 'Error'
            $r.Cause | Should -Be 'setting not found'
        }

        It 'reports progress for each request' {
            $events = [System.Collections.Generic.List[object]]::new()
            Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:GoodFetch -OnProgress { param($e) $events.Add($e) } | Out-Null
            @($events | Where-Object Phase -eq 'done').Count | Should -Be 2
            ($events | Select-Object -Last 1).Total | Should -Be 2
        }

        It 'streams each result as it is decided' {
            $seen = [System.Collections.Generic.List[string]]::new()
            Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:GoodFetch -OnResult { param($r) $seen.Add($r.Id) } | Out-Null
            $seen -join ',' | Should -Be 'ORG-001,CA-001'
        }
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Engine.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'New-MbcFetchResult' is not recognized`.

- [ ] **Step 4: Implement** `src/Checks/Engine.ps1`

```powershell
function New-MbcFetchResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool] $Ok,
        [AllowNull()][object] $Body,
        [int] $Status = 0,
        [AllowNull()][string] $Cause,
        [AllowNull()][string] $Detail,
        [int] $Pages = 0
    )
    return [pscustomobject]@{ PSTypeName = 'Mbc.FetchResult'; Ok = $Ok; Body = $Body; Status = $Status; Cause = $Cause; Detail = $Detail; Pages = $Pages }
}

function Get-MbcRequestKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $ApiVersion, [Parameter(Mandatory)][string] $Request)
    return "$ApiVersion|$Request"
}

function Get-MbcRequestPlan {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Preset)
    $endpoints = [string[]]@($Preset['endpoints'])
    $seen = [ordered]@{}
    foreach ($check in $Preset['checks']) {
        $request = [string]$check['request']
        if (-not (Test-MbcRequestDeclared -Request $request -Endpoints $endpoints)) { continue }
        $api = Get-MbcCheckApiVersion -Check $check
        $key = Get-MbcRequestKey -ApiVersion $api -Request $request
        if (-not $seen.Contains($key)) { $seen[$key] = [pscustomobject]@{ Key = $key; ApiVersion = $api; Request = $request } }
    }
    return , @($seen.Values)
}

function Invoke-MbcCollection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Plan,
        [Parameter(Mandatory)][scriptblock] $Fetch,
        [scriptblock] $OnProgress
    )
    $collected = @{}
    $i = 0
    foreach ($item in $Plan) {
        $i++
        if ($OnProgress) { & $OnProgress ([pscustomobject]@{ Phase = 'start'; Index = $i; Total = $Plan.Count; Request = $item.Request; Ok = $null }) }
        $result = & $Fetch $item.ApiVersion $item.Request
        $collected[$item.Key] = $result
        if ($OnProgress) { & $OnProgress ([pscustomobject]@{ Phase = 'done'; Index = $i; Total = $Plan.Count; Request = $item.Request; Ok = [bool]$result.Ok }) }
    }
    return $collected
}

function Get-MbcExtractedValue {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Check,
        [AllowNull()][object] $Body,
        [bool] $CaseSensitive,
        [string] $ExtractorRoot = $script:ModuleRoot
    )
    if ($Check.Contains('extractor')) {
        return (Invoke-MbcExtractor -RelativePath ([string]$Check['extractor']) -Response $Body -Root $ExtractorRoot)
    }
    try {
        $query = ConvertTo-MbcPathQuery -Select ([string]$Check['select'])
        $value = Invoke-MbcPathQuery -Query $query -Document $Body -CaseSensitive:$CaseSensitive
        return [pscustomobject]@{ Ok = $true; Value = $value; Cause = $null; Detail = $null }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'baseline expects a list'; Detail = $_.Exception.Message }
    }
}

function Invoke-MbcEvaluation {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Preset,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][hashtable] $Collected,
        [scriptblock] $OnResult,
        [string] $ExtractorRoot = $script:ModuleRoot
    )
    $endpoints = [string[]]@($Preset['endpoints'])
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($check in $Preset['checks']) {
        $id = [string]$check['id']
        $api = Get-MbcCheckApiVersion -Check $check
        $request = [string]$check['request']
        $expectedValue = if ($Expected.Contains($id)) { $Expected[$id] } else { $null }
        $cs = $check.Contains('caseSensitive') -and [bool]$check['caseSensitive']
        $actual = $script:MbcNotFound
        $verdict = 'Error'
        $cause = $null
        $detail = $null

        if (-not (Test-MbcRequestDeclared -Request $request -Endpoints $endpoints)) {
            $cause = 'endpoint not declared'
        }
        else {
            $got = $Collected[(Get-MbcRequestKey -ApiVersion $api -Request $request)]
            if ($null -eq $got) { $cause = 'not collected' }
            elseif (-not $got.Ok) { $cause = $got.Cause; $detail = $got.Detail }
            else {
                $x = Get-MbcExtractedValue -Check $check -Body $got.Body -CaseSensitive $cs -ExtractorRoot $ExtractorRoot
                if (-not $x.Ok) { $cause = $x.Cause; $detail = $x.Detail }
                else {
                    $actual = $x.Value
                    $comparison = Compare-MbcValue -Actual $actual -Operator ([string]$check['operator']) -Expected $expectedValue -CaseSensitive:$cs
                    $verdict = $comparison.Verdict
                    $cause = $comparison.Cause
                }
            }
        }
        if ($verdict -eq 'Error' -and -not $cause) { $cause = 'not collected' }

        $hasActual = -not (Test-MbcNotFound $actual)
        $result = [pscustomobject]@{
            PSTypeName = 'Mbc.CheckResult'
            Id         = $id
            Title      = [string]$check['title']
            Severity   = [string]$check['severity']
            Why        = if ($check.Contains('why')) { [string]$check['why'] } else { '' }
            Request    = $request
            ApiVersion = $api
            Operator   = [string]$check['operator']
            Expected   = $expectedValue
            Actual     = if ($hasActual) { $actual } else { $null }
            HasActual  = $hasActual
            Verdict    = $verdict
            Cause      = $cause
            Detail     = $detail
        }
        $results.Add($result)
        if ($OnResult) { & $OnResult $result }
    }
    return , $results.ToArray()
}

function Get-MbcCounts {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Results)
    return [pscustomobject]@{
        Pass  = @($Results | Where-Object Verdict -eq 'Pass').Count
        Fail  = @($Results | Where-Object Verdict -eq 'Fail').Count
        Error = @($Results | Where-Object Verdict -eq 'Error').Count
        Total = $Results.Count
    }
}

function Invoke-MbcRun {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Baseline,
        [Parameter(Mandatory)][scriptblock] $Fetch,
        [scriptblock] $OnProgress,
        [scriptblock] $OnResult,
        [string] $RunId = (New-MbcRunId)
    )
    $preset = $Baseline.Document['preset']
    $started = [datetime]::UtcNow
    $plan = Get-MbcRequestPlan -Preset $preset
    $collected = Invoke-MbcCollection -Plan $plan -Fetch $Fetch -OnProgress $OnProgress
    $results = Invoke-MbcEvaluation -Preset $preset -Expected $Baseline.Document['expected'] -Collected $collected -OnResult $OnResult
    return [pscustomobject]@{
        PSTypeName  = 'Mbc.Run'
        RunId       = $RunId
        StartedUtc  = $started
        FinishedUtc = [datetime]::UtcNow
        Results     = $results
        Counts      = (Get-MbcCounts -Results $results)
    }
}
```

- [ ] **Step 4b: Implement** `src/Common/Paths.ps1`, which `Invoke-MbcRun` needs for `New-MbcRunId`. Task 9 tests it.

```powershell
function Get-MbcOutputRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Root)
    $base = if ($Root) { $Root } elseif ($env:M365BC_HOME) { $env:M365BC_HOME } else { Join-Path $HOME 'M365BaselineCheck' }
    foreach ($sub in 'logs', 'results') {
        $path = Join-Path $base $sub
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    return (Resolve-Path -LiteralPath $base).ProviderPath
}

function New-MbcRunId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return ('{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N').Substring(0, 6))
}

function Get-MbcRunStamp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $RunId)
    return ($RunId -split '-', 2)[0]
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Engine.Tests.ps1 -Output Detailed`
Expected: PASS, 8 tests.

- [ ] **Step 6: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Checks/Engine.ps1 src/Common/Paths.ps1 tests/fixtures/graph tests/Engine.Tests.ps1
git commit -m "feat: the check engine; a failed collection can only ever be an Error" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Output paths, run IDs and the run log

**Files:**
- Create: `src/Log/Logger.ps1`
- Uses: `src/Common/Paths.ps1` (created in Task 8)
- Test: `tests/Logger.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-MbcCanonicalJson` (Task 2).
- Produces:
  - `Get-MbcOutputRoot [-Root <string>]` → a path, creating `logs/` and `results/`. The default is `$env:M365BC_HOME`, otherwise `$HOME/M365BaselineCheck`.
  - `New-MbcRunId` → for example `'20260926T141200Z-3fa9c1'`.
  - `Get-MbcRunStamp -RunId` → `'20260926T141200Z'`.
  - `New-MbcRunLog -Directory -RunId [-Baseline <fingerprint>]` → `Mbc.Log { Path; RunId; Baseline; State (a hashtable with a Seq counter) }`. Every line carries `baseline`.
  - `Write-MbcLog -Log -Event <string> [-Data <hashtable>]`. A `$null` log is a no-op.
  - `Assert-MbcLogSafe -Data`, which throws on a secret-like key.

- [ ] **Step 1: Write the failing tests** in `tests/Logger.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Output root and run IDs' {
        It 'creates logs and results under the root it is given' {
            $root = Get-MbcOutputRoot -Root (Join-Path $TestDrive 'out')
            Test-Path (Join-Path $root 'logs') | Should -BeTrue
            Test-Path (Join-Path $root 'results') | Should -BeTrue
        }
        It 'makes run IDs that sort by time and carry a stamp' {
            $id = New-MbcRunId
            $id | Should -Match '^\d{8}T\d{6}Z-[0-9a-f]{6}$'
            Get-MbcRunStamp -RunId $id | Should -Match '^\d{8}T\d{6}Z$'
        }
    }

    Describe 'The run log' {
        BeforeEach {
            $script:Log = New-MbcRunLog -Directory $TestDrive -RunId '20260101T000000Z-abcdef' -Baseline 'a1b2c3d4e5f6'
        }
        It 'writes one canonical JSON object per line, numbered' {
            Write-MbcLog -Log $script:Log -Event 'run.start' -Data @{ baseline = 'x' }
            Write-MbcLog -Log $script:Log -Event 'check' -Data @{ id = 'CA-001'; verdict = 'Pass' }
            $lines = [System.IO.File]::ReadAllLines($script:Log.Path)
            $lines.Count | Should -Be 2
            (ConvertFrom-MbcJson -Json $lines[1])['seq'] | Should -Be 2
            (ConvertFrom-MbcJson -Json $lines[1])['event'] | Should -Be 'check'
            (ConvertFrom-MbcJson -Json $lines[1])['baseline'] | Should -Be 'a1b2c3d4e5f6' -Because 'every line says which baseline it belongs to'
        }
        It 'truncates a large value and says so' {
            Write-MbcLog -Log $script:Log -Event 'check' -Data @{ actual = ('x' * 5000) }
            $entry = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllLines($script:Log.Path)[0])
            $entry['actual']['truncated'] | Should -BeTrue
            $entry['actual']['length'] | Should -BeGreaterThan 5000
        }
        It 'refuses to write anything shaped like a secret' {
            { Write-MbcLog -Log $script:Log -Event 'x' -Data @{ accessToken = 'abc' } } | Should -Throw '*never logged*'
            { Write-MbcLog -Log $script:Log -Event 'x' -Data @{ nested = @{ Authorization = 'Bearer' } } } | Should -Throw '*never logged*'
        }
        It 'does nothing when there is no log' {
            { Write-MbcLog -Log $null -Event 'x' } | Should -Not -Throw
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Logger.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Get-MbcOutputRoot' is not recognized`.

- [ ] **Step 3: Confirm** `src/Common/Paths.ps1` is already in place from Task 8 (Step 4b). Nothing to add: this task's first test block exercises it.

- [ ] **Step 4: Implement** `src/Log/Logger.ps1`

```powershell
$script:MbcSecretKeyPattern = '(?i)(token|authorization|secret|password|passphrase|credential|^key$|teamkey|cookie)'
$script:MbcLogValueLimit = 2048

function Assert-MbcLogSafe {
    [CmdletBinding()]
    param([AllowNull()][object] $Data)
    if (Test-MbcIsDictionary $Data) {
        foreach ($k in $Data.Keys) {
            if ([string]$k -match $script:MbcSecretKeyPattern) { throw "A value named '$k' looks like a secret, and secrets are never logged." }
            Assert-MbcLogSafe -Data $Data[$k]
        }
    }
    elseif (Test-MbcIsList $Data) {
        foreach ($item in $Data) { Assert-MbcLogSafe -Data $item }
    }
}

function Limit-MbcLogValue {
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object] $Value)
    $text = ConvertTo-MbcCanonicalJson -Value $Value
    if ($text.Length -le $script:MbcLogValueLimit) { return , $Value }
    return [ordered]@{ truncated = $true; length = $text.Length; preview = $text.Substring(0, 512) }
}

function New-MbcRunLog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $RunId,
        # The baseline's fingerprint, written into every line so any line on its own says what it belongs to.
        [string] $Baseline = ''
    )
    $path = Join-Path $Directory "run-$RunId.jsonl"
    [System.IO.File]::WriteAllText($path, '', [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ PSTypeName = 'Mbc.Log'; Path = $path; RunId = $RunId; Baseline = $Baseline; State = @{ Seq = 0 } }
}

function Write-MbcLog {
    [CmdletBinding()]
    param(
        [AllowNull()] $Log,
        [Parameter(Mandatory)][string] $Event,
        [hashtable] $Data = @{}
    )
    if ($null -eq $Log) { return }
    Assert-MbcLogSafe -Data $Data
    $Log.State.Seq++
    $entry = [ordered]@{ ts = [datetime]::UtcNow.ToString('o'); run = $Log.RunId; baseline = $Log.Baseline; seq = $Log.State.Seq; event = $Event }
    foreach ($k in $Data.Keys) { $entry[$k] = Limit-MbcLogValue -Value $Data[$k] }
    $line = ConvertTo-MbcCanonicalJson -Value $entry
    [System.IO.File]::AppendAllText($Log.Path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Verbose $line
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Logger.Tests.ps1 -Output Detailed`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Log/Logger.ps1 tests/Logger.Tests.ps1
git commit -m "feat: output paths, run IDs, and a run log that refuses secrets" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: The GET-only Graph client, and background execution

**Files:**
- Create: `src/Graph/GraphClient.ps1`, `src/Common/Background.ps1`
- Test: `tests/GraphClient.Tests.ps1`, `tests/ReadOnly.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertFrom-MbcJson` (Task 2), `New-MbcFetchResult` (Task 8), and `Write-MbcLog` (Task 9).
- Produces:
  - `$script:MbcGraphTransportText`: the **only** code that calls `Invoke-MgGraphRequest`, written as script text so it can also run in a background runspace. Contract: `param([string] $Uri)` → `{ Status; Body (string); RetryAfter (string or $null) }`.
  - `Invoke-MbcGraphGet -ApiVersion -Request [-Invoke <scriptblock>] [-Sleep <scriptblock>] [-Log]` → a fetch result (Task 8's contract). `-Invoke` takes `param($Uri)` and defaults to running the transport text in-process.
  - `Invoke-MbcInBackground -ScriptText <string> [-ArgumentList <object[]>] [-OnTick <scriptblock>] [-TickMs <int>]` → the script's single output. It throws if the script failed.
  - `New-MbcBackgroundInvoke -OnTick <scriptblock>` → an `-Invoke` script block that runs the transport in a background runspace while ticking, for the TUI's spinner.

- [ ] **Step 1: Check what the installed Graph module offers**

Run:
```powershell
Get-Module -ListAvailable Microsoft.Graph.Authentication | Select-Object -First 1 Version
(Get-Command Invoke-MgGraphRequest).Parameters.Keys -join ', '
```
Expected: the version is 2.x, and the parameter list includes `SkipHttpErrorCheck`, `StatusCodeVariable` and `ResponseHeadersVariable`.

If any of the three is missing, record it in your report. Then write the transport text to catch the thrown `Microsoft.Graph.PowerShell.Authentication.Helpers.HttpResponseException` instead, reading `.Response.StatusCode` and the `Retry-After` header from it, with the same output shape.

- [ ] **Step 2: Write the failing tests** in `tests/GraphClient.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The GET-only Graph client' {
        BeforeAll {
            $script:NoSleep = { param($Seconds) $null = $Seconds }
        }

        It 'builds the URI from the API version and path, and parses the body' {
            $seen = [System.Collections.Generic.List[string]]::new()
            $invoke = { param($Uri) $seen.Add($Uri); [pscustomobject]@{ Status = 200; Body = '{"a":1.5}'; RetryAfter = $null } }.GetNewClosure()
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/policies/authorizationPolicy' -Invoke $invoke
            $seen[0] | Should -Be 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy'
            $r.Ok | Should -BeTrue
            $r.Body['a'] | Should -Be 1.5
        }

        It 'follows nextLink and joins the pages into one value list' {
            $pages = @{
                'https://graph.microsoft.com/v1.0/things'        = '{"value":[{"n":1}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/things?$skiptoken=2"}'
                'https://graph.microsoft.com/v1.0/things?$skiptoken=2' = '{"value":[{"n":2}]}'
            }
            $invoke = { param($Uri) [pscustomobject]@{ Status = 200; Body = $pages[$Uri]; RetryAfter = $null } }.GetNewClosure()
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/things' -Invoke $invoke
            $r.Body['value'].Count | Should -Be 2
            $r.Body.Contains('@odata.nextLink') | Should -BeFalse
            $r.Pages | Should -Be 2
        }

        It 'refuses a nextLink that points anywhere but Graph' {
            $invoke = { param($Uri) [pscustomobject]@{ Status = 200; Body = '{"value":[],"@odata.nextLink":"https://example.com/steal"}'; RetryAfter = $null } }
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/things' -Invoke $invoke
            $r.Ok | Should -BeFalse
            $r.Cause | Should -Be 'malformed response'
        }

        It 'waits and retries on 429, honouring Retry-After' {
            $state = @{ n = 0 }
            $waits = [System.Collections.Generic.List[int]]::new()
            $invoke = {
                param($Uri)
                $state.n++
                if ($state.n -lt 3) { [pscustomobject]@{ Status = 429; Body = ''; RetryAfter = '2' } }
                else { [pscustomobject]@{ Status = 200; Body = '{}'; RetryAfter = $null } }
            }.GetNewClosure()
            $sleep = { param($Seconds) $waits.Add($Seconds) }.GetNewClosure()
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Invoke $invoke -Sleep $sleep
            $r.Ok | Should -BeTrue
            ($waits -join ',') | Should -Be '2,2'
        }

        It 'gives up after three retries and calls it throttled' {
            $invoke = { param($Uri) [pscustomobject]@{ Status = 429; Body = ''; RetryAfter = '1' } }
            $r = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Invoke $invoke -Sleep $script:NoSleep
            $r.Cause | Should -Be 'throttled'
        }

        It 'maps <Status> to <Cause>' -ForEach @(
            @{ Status = 401; Cause = 'permission missing' }
            @{ Status = 403; Cause = 'permission missing' }
            @{ Status = 404; Cause = 'not found' }
            @{ Status = 400; Cause = 'request rejected' }
            @{ Status = 500; Cause = 'service error' }
        ) {
            $s = $Status
            $invoke = { param($Uri) [pscustomobject]@{ Status = $s; Body = '{}'; RetryAfter = $null } }.GetNewClosure()
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Invoke $invoke -Sleep $script:NoSleep).Cause | Should -Be $Cause
        }

        It 'calls an unparseable body a malformed response' {
            $invoke = { param($Uri) [pscustomobject]@{ Status = 200; Body = '<html>'; RetryAfter = $null } }
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/x' -Invoke $invoke).Cause | Should -Be 'malformed response'
        }

        It 'rejects anything that is not a plain Graph path' {
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request 'https://example.com/x' -Invoke { throw 'must not be called' }).Cause | Should -Be 'request rejected'
            (Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/a/../b' -Invoke { throw 'must not be called' }).Cause | Should -Be 'request rejected'
        }
    }

    Describe 'Background execution' {
        It 'returns the script''s output and ticks while it waits' {
            $ticks = @{ n = 0 }
            $out = Invoke-MbcInBackground -ScriptText 'param($x) Start-Sleep -Milliseconds 400; "got $x"' -ArgumentList @('it') -TickMs 50 -OnTick { param($t) $ticks.n++ }.GetNewClosure()
            $out | Should -Be 'got it'
            $ticks.n | Should -BeGreaterThan 2
        }
        It 'surfaces a failure in the background script' {
            { Invoke-MbcInBackground -ScriptText 'throw "boom"' } | Should -Throw '*boom*'
        }
    }
}
```

- [ ] **Step 3: Write the failing read-only guard** in `tests/ReadOnly.Tests.ps1`

```powershell
Describe 'Nothing in src/ can write to Graph' {
    BeforeAll {
        $script:Src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
        $script:Files = @(Get-ChildItem -LiteralPath $script:Src -Recurse -Filter '*.ps1' -File)
        $script:Text = ($script:Files | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
    }
    It 'has source files to check' {
        $script:Files.Count | Should -BeGreaterThan 5
    }
    It 'calls Invoke-MgGraphRequest at least once, and only ever with -Method GET' {
        $calls = [regex]::Matches($script:Text, 'Invoke-MgGraphRequest[^\r\n]*')
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) { $c.Value | Should -Match '-Method GET\b' }
    }
    It 'never uses another HTTP client' {
        $script:Text | Should -Not -Match 'Invoke-RestMethod|Invoke-WebRequest|HttpClient|WebClient|HttpWebRequest'
    }
    It 'never names a write method anywhere' {
        $script:Text | Should -Not -Match '-Method\s+[''"]?(POST|PUT|PATCH|DELETE)'
    }
}
```

- [ ] **Step 4: Run both to verify they fail**

Run: `Invoke-Pester ./tests/GraphClient.Tests.ps1, ./tests/ReadOnly.Tests.ps1 -Output Detailed`
Expected: FAIL. `Invoke-MbcGraphGet` is not recognized, and the read-only guard finds zero `Invoke-MgGraphRequest` calls.

- [ ] **Step 5: Implement** `src/Common/Background.ps1`

```powershell
function Invoke-MbcInBackground {
    <#
    .SYNOPSIS
        Runs script text in a separate runspace and calls OnTick on this thread until it finishes, so a
        spinner can turn while a network call blocks. The text must be self-contained: a script block
        from this runspace would be marshalled back here and deadlock.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string] $ScriptText,
        [object[]] $ArgumentList = @(),
        [scriptblock] $OnTick,
        [ValidateRange(10, 1000)][int] $TickMs = 80
    )
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript($ScriptText)
        foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()
        $tick = 0
        while (-not $handle.AsyncWaitHandle.WaitOne($TickMs)) {
            if ($OnTick) { & $OnTick $tick }
            $tick++
        }
        $output = $ps.EndInvoke($handle)
        if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
        if ($output.Count -eq 0) { return $null }
        return , $output[0]
    }
    finally {
        $ps.Dispose()
    }
}
```

- [ ] **Step 6: Implement** `src/Graph/GraphClient.ps1`

```powershell
$script:MbcGraphHost = 'graph.microsoft.com'
$script:MbcMaxPages = 200
$script:MbcMaxRetries = 3
$script:MbcMaxWaitSeconds = 30

# THE ONLY CODE IN THIS MODULE THAT TALKS TO MICROSOFT GRAPH. The method is a literal GET, and nothing
# can change it: Invoke-MbcGraphGet has no method parameter. tests/ReadOnly.Tests.ps1 holds this.
$script:MbcGraphTransportText = @'
param([string] $Uri)
$status = 0
$headers = $null
$body = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Json -SkipHttpErrorCheck -StatusCodeVariable 'status' -ResponseHeadersVariable 'headers' -ErrorAction Stop
$retryAfter = $null
if ($headers) {
    foreach ($name in @($headers.Keys)) {
        if ($name -ieq 'Retry-After') { $retryAfter = [string](@($headers[$name])[0]) }
    }
}
[pscustomobject]@{ Status = [int]$status; Body = [string]$body; RetryAfter = $retryAfter }
'@

function Get-MbcStatusCause {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int] $Status)
    if ($Status -ge 200 -and $Status -lt 300) { return $null }
    if ($Status -eq 400) { return 'request rejected' }
    if ($Status -in 401, 403) { return 'permission missing' }
    if ($Status -eq 404) { return 'not found' }
    if ($Status -eq 429) { return 'throttled' }
    return 'service error'
}

function Get-MbcRetryDelay {
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()][string] $RetryAfter, [Parameter(Mandatory)][int] $Attempt)
    $seconds = 0
    if ($RetryAfter -and [int]::TryParse($RetryAfter, [ref]$seconds)) {
        return [Math]::Min([Math]::Max(1, $seconds), $script:MbcMaxWaitSeconds)
    }
    return [Math]::Min([int][Math]::Pow(2, $Attempt), $script:MbcMaxWaitSeconds)
}

function Invoke-MbcGraphGet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('v1.0', 'beta')][string] $ApiVersion,
        [Parameter(Mandatory)][string] $Request,
        [scriptblock] $Invoke,
        [scriptblock] $Sleep = { param([int] $Seconds) Start-Sleep -Seconds $Seconds },
        [AllowNull()] $Log
    )
    if ($Request -notmatch '^/' -or $Request -match '://|\.\.|\s') {
        return (New-MbcFetchResult -Ok $false -Cause 'request rejected' -Detail "'$Request' isn't a Graph path.")
    }
    if (-not $Invoke) { $Invoke = [scriptblock]::Create($script:MbcGraphTransportText) }

    $uri = "https://$($script:MbcGraphHost)/$ApiVersion$Request"
    $root = $null
    $values = $null
    $pages = 0
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($uri) {
        $pages++
        if ($pages -gt $script:MbcMaxPages) { return (New-MbcFetchResult -Ok $false -Cause 'too many pages' -Detail "Stopped after $($script:MbcMaxPages) pages.") }
        $attempt = 0
        while ($true) {
            try { $response = & $Invoke $uri }
            catch { return (New-MbcFetchResult -Ok $false -Cause 'service error' -Detail $_.Exception.Message) }
            if ($response.Status -in 429, 503, 504 -and $attempt -lt $script:MbcMaxRetries) {
                $attempt++
                $wait = Get-MbcRetryDelay -RetryAfter $response.RetryAfter -Attempt $attempt
                Write-MbcLog -Log $Log -Event 'graph.throttled' -Data @{ path = $Request; status = $response.Status; waitSeconds = $wait; attempt = $attempt }
                & $Sleep $wait
                continue
            }
            break
        }
        $cause = Get-MbcStatusCause -Status $response.Status
        if ($cause) {
            Write-MbcLog -Log $Log -Event 'graph.get' -Data @{ path = $Request; status = $response.Status; cause = $cause; durationMs = $clock.ElapsedMilliseconds }
            return (New-MbcFetchResult -Ok $false -Status $response.Status -Cause $cause -Detail "HTTP $($response.Status)")
        }
        try { $page = ConvertFrom-MbcJson -Json ([string]$response.Body) -AllowFloat }
        catch { return (New-MbcFetchResult -Ok $false -Status $response.Status -Cause 'malformed response' -Detail $_.Exception.Message) }
        if (-not (Test-MbcIsDictionary $page)) { return (New-MbcFetchResult -Ok $false -Status $response.Status -Cause 'malformed response' -Detail 'The response is not a JSON object.') }

        if ($null -eq $root) { $root = $page }
        if ($page.Contains('value') -and (Test-MbcIsList $page['value'])) {
            if ($null -eq $values) { $values = [System.Collections.Generic.List[object]]::new() }
            foreach ($v in $page['value']) { $values.Add($v) }
        }
        $next = if ($page.Contains('@odata.nextLink')) { [string]$page['@odata.nextLink'] } else { $null }
        if ($next) {
            $nextUri = $null
            if (-not [uri]::TryCreate($next, [UriKind]::Absolute, [ref]$nextUri) -or $nextUri.Scheme -ne 'https' -or $nextUri.Host -ne $script:MbcGraphHost) {
                return (New-MbcFetchResult -Ok $false -Status $response.Status -Cause 'malformed response' -Detail 'A nextLink pointed somewhere other than Graph.')
            }
        }
        $uri = $next
    }
    if ($null -ne $values) {
        $root['value'] = $values.ToArray()
        if ($root.Contains('@odata.nextLink')) { $root.Remove('@odata.nextLink') }
    }
    Write-MbcLog -Log $Log -Event 'graph.get' -Data @{ path = $Request; status = 200; pages = $pages; durationMs = $clock.ElapsedMilliseconds }
    return (New-MbcFetchResult -Ok $true -Body $root -Status 200 -Pages $pages)
}

function New-MbcBackgroundInvoke {
    <#
    .SYNOPSIS
        An -Invoke for Invoke-MbcGraphGet that runs the transport in a background runspace, calling
        OnTick meanwhile. The Graph SDK keeps its sign-in in process-wide state, so the runspace sees it.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param([scriptblock] $OnTick)
    $text = $script:MbcGraphTransportText
    # GetNewClosure() binds the block to a fresh dynamic module, where this module's private functions
    # don't resolve by name. A captured CommandInfo keeps its own module binding, so call through it.
    $runner = Get-Command Invoke-MbcInBackground
    return {
        param($Uri)
        & $runner -ScriptText $text -ArgumentList @($Uri) -OnTick $OnTick
    }.GetNewClosure()
}
```

- [ ] **Step 7: Run both to verify they pass**

Run: `Invoke-Pester ./tests/GraphClient.Tests.ps1, ./tests/ReadOnly.Tests.ps1 -Output Detailed`
Expected: PASS: 13 client tests, 2 background tests and 4 guard tests.

- [ ] **Step 8: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Graph/GraphClient.ps1 src/Common/Background.ps1 tests/GraphClient.Tests.ps1 tests/ReadOnly.Tests.ps1
git commit -m "feat: a Graph client that can only GET, with paging and throttling" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: The read-only assertion and sign-in

**Files:**
- Create: `src/Graph/Connect.ps1`
- Test: `tests/Connect.Tests.ps1`

**Interfaces:**
- Consumes: `Test-MbcReadScope` (Task 5), `Invoke-MbcGraphGet` (Task 10), and `Write-MbcLog` (Task 9).
- Produces:
  - `Get-MbcScopePlane -Scope` → `'directory'` or `'data'`. An unlisted family counts as `data`, which fails closed.
  - `$script:MbcReadOnlyRoles`: an ordered map of role template ID to display name.
  - `Test-MbcReadOnlyGrant -GrantedScopes <string[]> -Roles <object[] or $null>` → `{ Ok; Reasons[]; WriteScopes[] }`. Each role object has `RoleTemplateId` and `DisplayName`, and `$null` means the roles couldn't be read.
  - Thin wrappers that tests mock: `Test-MbcGraphModule`, `Invoke-MbcConnectMgGraph -Scopes`, `Get-MbcMgContext`, `Invoke-MbcDisconnectMgGraph`.
  - `Connect-MbcGraph -Scopes <string[]> [-Log] [-Invoke <scriptblock>]` → `Mbc.Connection { Account; TenantId; Domain; Scopes; Roles; ReadOnly }`. It throws on any failure and signs out again after a failed assertion.

**A note on comments:** don't write the Graph SDK request cmdlet's name in a comment here. `tests/ReadOnly.Tests.ps1` requires every line naming it to carry `-Method GET`.

- [ ] **Step 1: Verify the role template IDs against Microsoft's documentation**

Open *Microsoft Entra built-in roles* (learn.microsoft.com, "permissions reference"). Confirm these template IDs exactly:

| Role | Template ID |
|---|---|
| Global Reader | `f2ef992c-3afb-46b9-b7cf-a126ee74c451` |
| Security Reader | `5d6b6bb7-de71-4623-b4af-96380a352509` |
| Reports Reader | `4a5d8f65-41da-4de4-8968-e035b65339cf` |
| Directory Readers | `88d8e3e3-8f55-4a1e-953a-9b9898b8876b` |
| Message Center Reader | `790c1fb9-7f7d-4f88-86a1-ef1f95c05c1b` |
| Usage Summary Reports Reader | `75934031-6c7e-415a-99d7-48dbd49e875e` |
| Global Administrator (tests only) | `62e90394-69f5-4237-9190-012177145e10` |

If any differs, use Microsoft's value and say so in your report. Task 19 copies these into the scrub allowlist.

- [ ] **Step 2: Write the failing tests** in `tests/Connect.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The read-only decision' {
        BeforeAll {
            $script:GlobalReader = [pscustomobject]@{ RoleTemplateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'; DisplayName = 'Global Reader' }
            $script:GlobalAdmin = [pscustomobject]@{ RoleTemplateId = '62e90394-69f5-4237-9190-012177145e10'; DisplayName = 'Global Administrator' }
        }
        It 'accepts a token that carries only read scopes, without needing roles' {
            (Test-MbcReadOnlyGrant -GrantedScopes @('Policy.Read.All', 'openid', 'profile') -Roles $null).Ok | Should -BeTrue
        }
        It 'refuses a data-plane write whatever the roles' {
            $r = Test-MbcReadOnlyGrant -GrantedScopes @('Policy.Read.All', 'Mail.Send') -Roles @($script:GlobalReader)
            $r.Ok | Should -BeFalse
            ($r.Reasons -join ' ') | Should -Match 'Mail.Send'
        }
        It 'tolerates a directory write when every role is read-only' {
            (Test-MbcReadOnlyGrant -GrantedScopes @('Directory.ReadWrite.All') -Roles @($script:GlobalReader)).Ok | Should -BeTrue
        }
        It 'refuses a directory write when a role can make changes, and names the role' {
            $r = Test-MbcReadOnlyGrant -GrantedScopes @('Directory.ReadWrite.All') -Roles @($script:GlobalReader, $script:GlobalAdmin)
            $r.Ok | Should -BeFalse
            ($r.Reasons -join ' ') | Should -Match 'Global Administrator'
        }
        It 'fails closed when roles could not be read' {
            (Test-MbcReadOnlyGrant -GrantedScopes @('Directory.ReadWrite.All') -Roles $null).Ok | Should -BeFalse
        }
        It 'fails closed when the account holds no read-only role at all' {
            (Test-MbcReadOnlyGrant -GrantedScopes @('Directory.ReadWrite.All') -Roles @()).Ok | Should -BeFalse
        }
        It 'treats an unknown resource family as data plane' {
            Get-MbcScopePlane -Scope 'Unheardof.ReadWrite.All' | Should -Be 'data'
            Get-MbcScopePlane -Scope 'Policy.ReadWrite.All' | Should -Be 'directory'
        }
    }

    Describe 'Signing in' {
        BeforeEach {
            Mock Test-MbcGraphModule { $true }
            Mock Invoke-MbcConnectMgGraph { }
            Mock Invoke-MbcDisconnectMgGraph { }
            Mock Get-MbcMgContext {
                [pscustomobject]@{ Account = 'operator@example.com'; TenantId = '00000000-0000-4000-8000-000000000001'; Scopes = @('Policy.Read.All', 'openid') }
            }
        }
        It 'refuses to start without the Graph module, and says how to install it' {
            Mock Test-MbcGraphModule { $false }
            { Connect-MbcGraph -Scopes @('Policy.Read.All') } | Should -Throw '*Install-Module Microsoft.Graph.Authentication*'
        }
        It 'will not even request a scope that is not a read scope' {
            { Connect-MbcGraph -Scopes @('Policy.ReadWrite.All') } | Should -Throw "*isn't a read scope*"
            Should -Invoke Invoke-MbcConnectMgGraph -Times 0 -Exactly
        }
        It 'returns the connection for a read-only token' {
            $c = Connect-MbcGraph -Scopes @('Policy.Read.All')
            $c.ReadOnly | Should -BeTrue
            $c.Domain | Should -Be 'example.com'
            $c.TenantId | Should -Be '00000000-0000-4000-8000-000000000001'
        }
        It 'reads roles when the token carries a write scope, and accepts read-only roles' {
            Mock Get-MbcMgContext {
                [pscustomobject]@{ Account = 'operator@example.com'; TenantId = '00000000-0000-4000-8000-000000000001'; Scopes = @('Policy.Read.All', 'Directory.ReadWrite.All') }
            }
            $invoke = { param($Uri) [pscustomobject]@{ Status = 200; Body = '{"value":[{"roleTemplateId":"f2ef992c-3afb-46b9-b7cf-a126ee74c451","displayName":"Global Reader"}]}'; RetryAfter = $null } }
            (Connect-MbcGraph -Scopes @('Policy.Read.All') -Invoke $invoke).ReadOnly | Should -BeTrue
        }
        It 'signs out again and explains why when a write-capable role is present' {
            Mock Get-MbcMgContext {
                [pscustomobject]@{ Account = 'operator@example.com'; TenantId = '00000000-0000-4000-8000-000000000001'; Scopes = @('Directory.ReadWrite.All') }
            }
            $invoke = { param($Uri) [pscustomobject]@{ Status = 200; Body = '{"value":[{"roleTemplateId":"62e90394-69f5-4237-9190-012177145e10","displayName":"Global Administrator"}]}'; RetryAfter = $null } }
            { Connect-MbcGraph -Scopes @('Policy.Read.All') -Invoke $invoke } | Should -Throw '*this tool only reads*'
            Should -Invoke Invoke-MbcDisconnectMgGraph -Times 1 -Exactly
        }
        It 'fails closed when the role read itself is refused' {
            Mock Get-MbcMgContext {
                [pscustomobject]@{ Account = 'operator@example.com'; TenantId = '00000000-0000-4000-8000-000000000001'; Scopes = @('Directory.ReadWrite.All') }
            }
            $invoke = { param($Uri) [pscustomobject]@{ Status = 403; Body = '{}'; RetryAfter = $null } }
            { Connect-MbcGraph -Scopes @('Policy.Read.All') -Invoke $invoke } | Should -Throw "*couldn't be read*"
        }
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Connect.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Test-MbcReadOnlyGrant' is not recognized`.

- [ ] **Step 4: Implement** `src/Graph/Connect.ps1`

```powershell
# Resource families whose write scopes act on directory objects, which a read-only directory role makes
# inert. Anything not listed is treated as data plane (mail, files, chats), where no role helps.
$script:MbcDirectoryPlane = @(
    'Directory', 'Policy', 'User', 'Group', 'GroupMember', 'Application', 'AppRoleAssignment', 'RoleManagement',
    'AuditLog', 'Reports', 'Organization', 'Domain', 'IdentityRiskEvent', 'IdentityRiskyUser', 'IdentityProvider',
    'Device', 'AdministrativeUnit', 'UserAuthenticationMethod', 'Agreement', 'AccessReview', 'EntitlementManagement',
    'CrossTenantInformation', 'OnPremDirectorySynchronization', 'SecurityEvents', 'SecurityActions',
    'DeviceManagementConfiguration', 'DeviceManagementManagedDevices', 'DeviceManagementServiceConfig',
    'DeviceManagementRBAC', 'DeviceManagementApps'
)

# Directory roles that can read everything they can see and change nothing. By template ID, which is the
# same in every tenant. A role not on this list is treated as able to make changes.
$script:MbcReadOnlyRoles = [ordered]@{
    'f2ef992c-3afb-46b9-b7cf-a126ee74c451' = 'Global Reader'
    '5d6b6bb7-de71-4623-b4af-96380a352509' = 'Security Reader'
    '4a5d8f65-41da-4de4-8968-e035b65339cf' = 'Reports Reader'
    '88d8e3e3-8f55-4a1e-953a-9b9898b8876b' = 'Directory Readers'
    '790c1fb9-7f7d-4f88-86a1-ef1f95c05c1b' = 'Message Center Reader'
    '75934031-6c7e-415a-99d7-48dbd49e875e' = 'Usage Summary Reports Reader'
}

function Get-MbcScopePlane {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Scope)
    $family = ($Scope -split '\.')[0]
    if ($family -in $script:MbcDirectoryPlane) { return 'directory' }
    return 'data'
}

function Test-MbcReadOnlyGrant {
    <#
    .SYNOPSIS
        Decides whether a token can change anything. A delegated token carries every scope consented to
        the client application, so this tests what the token can do, not only what was requested.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $GrantedScopes,
        [AllowNull()][object[]] $Roles
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    $writes = @($GrantedScopes | Where-Object { -not (Test-MbcReadScope -Scope $_) })
    if ($writes.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Reasons = @(); WriteScopes = @() } }

    foreach ($s in @($writes | Where-Object { (Get-MbcScopePlane -Scope $_) -eq 'data' })) {
        $reasons.Add("$s can act on mail, files or chats, whatever your directory roles are.")
    }
    $directoryWrites = @($writes | Where-Object { (Get-MbcScopePlane -Scope $_) -eq 'directory' })
    if ($directoryWrites.Count -gt 0) {
        $list = $directoryWrites -join ', '
        if ($null -eq $Roles) {
            $reasons.Add("Your token carries $list, and your directory roles couldn't be read to show they're harmless.")
        }
        elseif (@($Roles).Count -eq 0) {
            $reasons.Add("Your token carries $list, and you hold no read-only directory role that would make them harmless.")
        }
        else {
            foreach ($role in $Roles) {
                if (-not $script:MbcReadOnlyRoles.Contains([string]$role.RoleTemplateId)) {
                    $reasons.Add("You hold '$($role.DisplayName)', which can make changes, and your token carries $list.")
                }
            }
        }
    }
    return [pscustomobject]@{ Ok = ($reasons.Count -eq 0); Reasons = $reasons.ToArray(); WriteScopes = $writes }
}

function Test-MbcGraphModule {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool](Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)
}

function Invoke-MbcConnectMgGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Scopes)
    Connect-MgGraph -Scopes $Scopes -NoWelcome -ErrorAction Stop | Out-Null
}

function Get-MbcMgContext {
    [CmdletBinding()]
    param()
    return (Get-MgContext)
}

function Invoke-MbcDisconnectMgGraph {
    [CmdletBinding()]
    param()
    try { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
    catch { Write-Verbose "Sign-out: $($_.Exception.Message)" }
}

function Connect-MbcGraph {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]] $Scopes,
        [AllowNull()] $Log,
        [scriptblock] $Invoke
    )
    if (-not (Test-MbcGraphModule)) {
        throw "Microsoft.Graph.Authentication isn't installed. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser, then try again."
    }
    $notRead = @($Scopes | Where-Object { -not (Test-MbcReadScope -Scope $_) })
    if ($notRead.Count -gt 0) { throw "This baseline asks for $($notRead -join ', '), which isn't a read scope. The tool won't request it." }

    Invoke-MbcConnectMgGraph -Scopes $Scopes
    $context = Get-MbcMgContext
    if ($null -eq $context) { throw 'Sign-in did not complete.' }
    $granted = [string[]]@($context.Scopes)

    $roles = $null
    $decision = Test-MbcReadOnlyGrant -GrantedScopes $granted -Roles @()
    if (-not $decision.Ok) {
        $read = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=roleTemplateId,displayName' -Invoke $Invoke -Log $Log
        if ($read.Ok) {
            $roles = @($read.Body['value'] | ForEach-Object { [pscustomobject]@{ RoleTemplateId = [string]$_['roleTemplateId']; DisplayName = [string]$_['displayName'] } })
        }
        $decision = Test-MbcReadOnlyGrant -GrantedScopes $granted -Roles $roles
    }

    $account = [string]$context.Account
    Write-MbcLog -Log $Log -Event 'signin' -Data @{
        account  = $account
        tenant   = [string]$context.TenantId
        scopes   = $granted
        roles    = @($roles | ForEach-Object { $_.DisplayName })
        readOnly = $decision.Ok
        reasons  = $decision.Reasons
    }
    if (-not $decision.Ok) {
        Invoke-MbcDisconnectMgGraph
        throw ("Signed out again: this session could change things, and this tool only reads.`n  - " + ($decision.Reasons -join "`n  - "))
    }
    return [pscustomobject]@{
        PSTypeName = 'Mbc.Connection'
        Account    = $account
        TenantId   = [string]$context.TenantId
        Domain     = if ($account -match '@') { ($account -split '@')[-1] } else { '' }
        Scopes     = $granted
        Roles      = $roles
        ReadOnly   = $true
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Connect.Tests.ps1 -Output Detailed`
Expected: PASS: 7 decision tests and 6 sign-in tests.

- [ ] **Step 6: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Graph/Connect.ps1 tests/Connect.Tests.ps1
git commit -m "feat: sign-in with a read-only assertion that fails closed" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: Drafting a baseline from a reference tenant

**Files:**
- Create: `src/Baseline/Capture.ps1`, `src/Public/New-BaselineCapture.ps1`
- Test: `tests/Capture.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertFrom-MbcJson`, `ConvertTo-MbcPrettyJson` (Task 2); `Test-MbcPresetShape` (Task 5); `Get-MbcRequestPlan`, `Invoke-MbcCollection`, `Get-MbcExtractedValue` (Task 8); `Connect-MbcGraph` (Task 11); and `Invoke-MbcGraphGet` (Task 10).
- Produces:
  - `Read-MbcPreset -Path` → a preset `IDictionary`. It throws a list of problems if the preset is invalid.
  - `Get-MbcCapturedExpected -Check -Actual` → `{ Include (bool); Value; Note (string or $null) }`.
  - `New-MbcBaselineDraft -Preset -Collected -Name -Version` → `{ Document; Notes (string[]) }`.
  - `New-BaselineCapture -PresetPath -OutputPath [-Name] [-Version] [-Force]`, public, with a hidden `-Fetch` test seam.

- [ ] **Step 1: Write the failing tests** in `tests/Capture.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Capturing expected values' {
        It 'uses the actual value for equals, a count for countAtLeast, and a list for in' {
            (Get-MbcCapturedExpected -Check ([ordered]@{ operator = 'equals' }) -Actual $false).Value | Should -BeFalse
            (Get-MbcCapturedExpected -Check ([ordered]@{ operator = 'countAtLeast' }) -Actual @('a', 'b')).Value | Should -Be 2
            $in = (Get-MbcCapturedExpected -Check ([ordered]@{ operator = 'in' }) -Actual 'none').Value
            $in.GetType().IsArray | Should -BeTrue
            $in[0] | Should -Be 'none'
        }
        It 'declines to guess for matches, contains and notEquals' {
            foreach ($op in 'matches', 'contains', 'notEquals') {
                $r = Get-MbcCapturedExpected -Check ([ordered]@{ operator = $op }) -Actual 'x'
                $r.Include | Should -BeFalse
                $r.Note | Should -Match 'by hand'
            }
        }
        It 'needs no expected value for exists and absent' {
            $r = Get-MbcCapturedExpected -Check ([ordered]@{ operator = 'exists' }) -Actual 'x'
            $r.Include | Should -BeFalse
            $r.Note | Should -BeNullOrEmpty
        }
    }

    Describe 'New-BaselineCapture' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            $script:Bodies = @{
                '/policies/authorizationPolicy'       = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/authorizationPolicy.json')))
                '/identity/conditionalAccess/policies' = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/conditionalAccessPolicies.json')))
            }
            $script:Fetch = { param($ApiVersion, $Request) New-MbcFetchResult -Ok $true -Body $script:Bodies[$Request] -Status 200 }
        }
        It 'writes a draft that validates as a baseline once sealed' {
            $out = Join-Path $TestDrive 'draft.json'
            New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath $out -Name 'Drafted' -Fetch $script:Fetch -InformationAction SilentlyContinue
            $b = Read-MbcBaseline -Path $out
            $b.Name | Should -Be 'Drafted'
            $b.SealState | Should -Be 'Unsealed'
            $b.Document['expected']['ORG-001'] | Should -BeFalse
            $b.Document['expected']['CA-001'] | Should -Be 1
        }
        It 'leaves out what it could not read, and says so' {
            $out = Join-Path $TestDrive 'partial.json'
            $half = {
                param($ApiVersion, $Request)
                if ($Request -eq '/policies/authorizationPolicy') { return (New-MbcFetchResult -Ok $false -Status 403 -Cause 'permission missing') }
                New-MbcFetchResult -Ok $true -Body $script:Bodies[$Request] -Status 200
            }
            $info = New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath $out -Fetch $half 6>&1
            ($info -join "`n") | Should -Match 'ORG-001.*permission missing'
            $doc = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText($out))
            $doc['expected'].Contains('ORG-001') | Should -BeFalse
        }
        It 'will not overwrite a file unless told to' {
            $out = Join-Path $TestDrive 'exists.json'
            Set-Content -LiteralPath $out -Value '{}'
            { New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath $out -Fetch $script:Fetch } | Should -Throw '*already exists*'
            { New-BaselineCapture -PresetPath (Join-Path $script:Fx 'preset-minimal.json') -OutputPath $out -Fetch $script:Fetch -Force -InformationAction SilentlyContinue } | Should -Not -Throw
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Capture.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Get-MbcCapturedExpected' is not recognized`.

- [ ] **Step 3: Implement** `src/Baseline/Capture.ps1`

```powershell
function Read-MbcPreset {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "There's no preset at '$Path'." }
    $preset = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [System.Text.Encoding]::UTF8))
    $problems = @(Test-MbcPresetShape -Preset $preset)
    if ($problems.Count -gt 0) { throw ("'{0}' isn't a valid preset:`n  - {1}" -f $Path, ($problems -join "`n  - ")) }
    return $preset
}

function Get-MbcCapturedExpected {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check, [AllowNull()][object] $Actual)
    $include = { param($v) [pscustomobject]@{ Include = $true; Value = $v; Note = $null } }
    $skip = { param($note) [pscustomobject]@{ Include = $false; Value = $null; Note = $note } }
    switch ([string]$Check['operator']) {
        'equals' { return (& $include $Actual) }
        { $_ -in 'setEquals', 'subsetOf' } {
            if (Test-MbcIsList $Actual) { return (& $include $Actual) }
            return (& $skip 'expected a list and found a single value; write it by hand')
        }
        'in' {
            # @($Actual) as the argument: a one-element list. (, @(...)) would nest it and write [["x"]].
            if (Test-MbcIsScalar $Actual) { return (& $include @($Actual)) }
            return (& $skip 'expected a single value and found a list; write it by hand')
        }
        { $_ -in 'countAtLeast', 'countAtMost' } {
            if (Test-MbcIsList $Actual) { return (& $include ([long]$Actual.Count)) }
            return (& $skip 'expected a list to count; write it by hand')
        }
        { $_ -in 'exists', 'absent' } { return (& $skip $null) }
        default { return (& $skip "a value for $($Check['operator']) can't be read off one tenant; write it by hand") }
    }
}

function New-MbcBaselineDraft {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Preset,
        [Parameter(Mandatory)][hashtable] $Collected,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][long] $Version
    )
    $expected = [ordered]@{}
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($check in $Preset['checks']) {
        $id = [string]$check['id']
        $got = $Collected[(Get-MbcRequestKey -ApiVersion (Get-MbcCheckApiVersion -Check $check) -Request ([string]$check['request']))]
        if ($null -eq $got -or -not $got.Ok) {
            $cause = if ($got) { $got.Cause } else { 'not collected' }
            $notes.Add("${id}: couldn't be read ($cause); fill it in by hand")
            continue
        }
        $x = Get-MbcExtractedValue -Check $check -Body $got.Body -CaseSensitive ($check.Contains('caseSensitive') -and [bool]$check['caseSensitive'])
        if (-not $x.Ok -or (Test-MbcNotFound $x.Value)) {
            $why = if ($x.Ok) { 'setting not found' } else { $x.Cause }
            $notes.Add("${id}: couldn't be read ($why); fill it in by hand")
            continue
        }
        $captured = Get-MbcCapturedExpected -Check $check -Actual $x.Value
        if ($captured.Include) { $expected[$id] = $captured.Value }
        elseif ($captured.Note) { $notes.Add("${id}: $($captured.Note)") }
    }
    $document = [ordered]@{ schemaVersion = 1L; name = $Name; version = $Version; preset = $Preset; expected = $expected }
    return [pscustomobject]@{ Document = $document; Notes = $notes.ToArray() }
}
```

- [ ] **Step 4: Implement** `src/Public/New-BaselineCapture.ps1`

```powershell
function New-BaselineCapture {
    <#
    .SYNOPSIS
        Drafts a baseline from a preset by reading a reference tenant. The draft is unsealed: review it,
        then seal it with Protect-Baseline.
    .EXAMPLE
        New-BaselineCapture -PresetPath ./presets/example-entra-hygiene.json -OutputPath ./baselines/draft.json -Name 'Core tenant'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $PresetPath,
        [Parameter(Mandatory)][string] $OutputPath,
        [string] $Name,
        [ValidateRange(1, [int]::MaxValue)][int] $Version = 1,
        [switch] $Force,
        [Parameter(DontShow)][scriptblock] $Fetch
    )
    $preset = Read-MbcPreset -Path $PresetPath
    if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) { throw "'$OutputPath' already exists. Use -Force to replace it." }
    if (-not $Name) { $Name = [string]$preset['name'] }
    if (-not $Fetch) {
        [void](Connect-MbcGraph -Scopes ([string[]]@($preset['scopes'])))
        $Fetch = { param($ApiVersion, $Request) Invoke-MbcGraphGet -ApiVersion $ApiVersion -Request $Request }
    }
    $collected = Invoke-MbcCollection -Plan (Get-MbcRequestPlan -Preset $preset) -Fetch $Fetch
    $draft = New-MbcBaselineDraft -Preset $preset -Collected $collected -Name $Name -Version $Version

    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write a draft baseline')) {
        [System.IO.File]::WriteAllText($OutputPath, (ConvertTo-MbcPrettyJson -Value $draft.Document), [System.Text.UTF8Encoding]::new($false))
        $count = $draft.Document['expected'].Count
        Write-Information ("Drafted $count expected value(s) from this tenant into $OutputPath.") -InformationAction Continue
        foreach ($note in $draft.Notes) { Write-Information "  - $note" -InformationAction Continue }
        Write-Information 'Review it, then seal it with Protect-Baseline.' -InformationAction Continue
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Capture.Tests.ps1 -Output Detailed`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Baseline/Capture.ps1 src/Public/New-BaselineCapture.ps1 tests/Capture.Tests.ps1
git commit -m "feat: draft a baseline from a reference tenant" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 13: The result document, CSV, and the redacted summary

**Files:**
- Create: `src/Report/Result.ps1`, `src/Report/Export.ps1`, `src/Report/Summary.ps1`
- Create: `tests/fixtures/graph/sentinel-policies.json`
- Test: `tests/Report.Tests.ps1`

**Interfaces:**
- Consumes: `Get-MbcDocumentDigest`, `ConvertTo-MbcCanonicalJson`, `ConvertTo-MbcPrettyJson` (Tasks 2 and 6); `Mbc.Run` (Task 8); `Mbc.Baseline` (Task 6); `$script:MbcCauses` (Task 4); and `Get-MbcRunStamp` (Task 9).
- Produces:
  - `New-MbcResultDocument -Run -Baseline [-Connection]` → an ordered, **sealed** result document.
  - `Test-MbcResultSeal -Document` → bool.
  - `ConvertTo-MbcResultCsv -Document` → CSV text, with LF and a trailing newline.
  - `Format-MbcCellValue -Value` → a string, neutralising spreadsheet formulas.
  - `Get-MbcSummaryVerdict -Document` → `object[]` of `{ Id; Verdict; Cause }`. **This is the only thing the summary may read from the result.**
  - `ConvertTo-MbcSummaryMarkdown -Baseline -Verdicts -RunUtc -SealState` → Markdown text.
  - `Export-MbcRunFiles -Document -Baseline -Directory` → `{ Json; Csv; Summary; Locked }` paths. Task 14 adds locking.

- [ ] **Step 1: Write the sentinel fixture** `tests/fixtures/graph/sentinel-policies.json`

Every string here is a sentinel that must **never** reach a summary.

```json
{
  "value": [
    { "id": "00000000-0000-4000-8000-0000000000aa", "displayName": "SENTINEL-POLICY-NAME", "state": "enabled",
      "conditions": { "users": { "includeUsers": ["sentinel.user@example.com"] } } }
  ]
}
```

- [ ] **Step 2: Write the failing tests** in `tests/Report.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Results, CSV and summary' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            $script:Baseline = Read-MbcBaseline -Path (Join-Path $script:Fx 'baseline-minimal.json')
            $script:Sentinel = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/sentinel-policies.json')))
            $script:Fetch = {
                param($ApiVersion, $Request)
                if ($Request -eq '/identity/conditionalAccess/policies') { return (New-MbcFetchResult -Ok $true -Body $script:Sentinel -Status 200) }
                New-MbcFetchResult -Ok $false -Status 403 -Cause 'permission missing' -Detail 'HTTP 403'
            }
            $script:Run = Invoke-MbcRun -Baseline $script:Baseline -Fetch $script:Fetch
            $script:Connection = [pscustomobject]@{ TenantId = '00000000-0000-4000-8000-0000000000bb'; Account = 'sentinel.operator@example.com' }
            $script:Doc = New-MbcResultDocument -Run $script:Run -Baseline $script:Baseline -Connection $script:Connection
        }

        It 'seals the result so it can be verified untouched later' {
            Test-MbcResultSeal -Document $script:Doc | Should -BeTrue
            $copy = ConvertFrom-MbcJson -Json (ConvertTo-MbcPrettyJson $script:Doc) -AllowFloat
            $copy['counts']['pass'] = 99
            Test-MbcResultSeal -Document $copy | Should -BeFalse
        }

        It 'records the baseline identity and the counts' {
            $script:Doc['baseline']['fingerprint'] | Should -Be $script:Baseline.Fingerprint
            $script:Doc['baseline']['digest'] | Should -Be $script:Baseline.Digest
            $script:Doc['counts']['error'] | Should -Be 1
            $script:Doc['counts']['total'] | Should -Be 2
        }

        It 'writes one CSV row per check, each carrying the baseline identity' {
            $rows = @((ConvertTo-MbcResultCsv -Document $script:Doc) -split "`n" | Where-Object { $_ } | ConvertFrom-Csv)
            $rows.Count | Should -Be 2
            foreach ($r in $rows) { $r.Fingerprint | Should -Be $script:Baseline.Fingerprint }
            ($rows | Where-Object Id -eq 'ORG-001').Cause | Should -Be 'permission missing'
        }

        It 'neutralises a value that a spreadsheet would run as a formula' {
            Format-MbcCellValue -Value '=HYPERLINK("x")' | Should -BeExactly "'=HYPERLINK(`"x`")"
            Format-MbcCellValue -Value @('a', 'b') | Should -BeExactly '["a","b"]'
            Format-MbcCellValue -Value $false | Should -BeExactly 'false'
        }

        It 'writes a summary that names the baseline and uses only the fixed vocabulary' {
            $md = ConvertTo-MbcSummaryMarkdown -Baseline $script:Baseline -Verdicts (Get-MbcSummaryVerdict -Document $script:Doc) -RunUtc $script:Doc['run']['startedUtc'] -SealState $script:Baseline.SealState
            $md | Should -Match ([regex]::Escape($script:Baseline.Fingerprint))
            $md | Should -Match "Couldn't verify: permission missing"
            $md | Should -Match '\| CA-001 \|'
        }

        It 'never lets tenant data into the summary' {
            $md = ConvertTo-MbcSummaryMarkdown -Baseline $script:Baseline -Verdicts (Get-MbcSummaryVerdict -Document $script:Doc) -RunUtc $script:Doc['run']['startedUtc'] -SealState $script:Baseline.SealState
            foreach ($sentinel in 'SENTINEL-POLICY-NAME', 'sentinel.user@example.com', 'sentinel.operator@example.com',
                '00000000-0000-4000-8000-0000000000aa', '00000000-0000-4000-8000-0000000000bb') {
                $md | Should -Not -Match ([regex]::Escape($sentinel))
            }
        }

        It 'marks an unsealed baseline in the summary' {
            $md = ConvertTo-MbcSummaryMarkdown -Baseline $script:Baseline -Verdicts @() -RunUtc 'x' -SealState 'Unsealed'
            $md | Should -Match 'UNSEALED'
        }

        It 'exports JSON, CSV and summary files named by the run time' {
            $files = Export-MbcRunFiles -Document $script:Doc -Baseline $script:Baseline -Directory $TestDrive
            Split-Path -Leaf $files.Json | Should -Match '^result-\d{8}T\d{6}Z\.json$'
            Split-Path -Leaf $files.Summary | Should -Match '^summary-\d{8}T\d{6}Z\.md$'
            Test-Path $files.Csv | Should -BeTrue
            $again = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText($files.Json)) -AllowFloat
            Test-MbcResultSeal -Document $again | Should -BeTrue
        }
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Report.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'New-MbcResultDocument' is not recognized`.

- [ ] **Step 4: Implement** `src/Report/Result.ps1`

```powershell
function New-MbcResultDocument {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] $Baseline,
        [AllowNull()] $Connection
    )
    $results = foreach ($r in $Run.Results) {
        [ordered]@{
            id         = $r.Id
            title      = $r.Title
            severity   = $r.Severity
            verdict    = $r.Verdict
            cause      = $r.Cause
            detail     = $r.Detail
            operator   = $r.Operator
            expected   = $r.Expected
            hasActual  = $r.HasActual
            actual     = $r.Actual
            request    = $r.Request
            apiVersion = $r.ApiVersion
        }
    }
    $doc = [ordered]@{
        schemaVersion = 1L
        kind          = 'm365bc-result'
        tool          = [ordered]@{ version = $script:MbcToolVersion }
        run           = [ordered]@{ id = $Run.RunId; startedUtc = $Run.StartedUtc.ToString('o'); finishedUtc = $Run.FinishedUtc.ToString('o') }
        tenant        = [ordered]@{
            id      = if ($Connection) { [string]$Connection.TenantId } else { '' }
            account = if ($Connection) { [string]$Connection.Account } else { '' }
        }
        baseline      = [ordered]@{ name = $Baseline.Name; version = $Baseline.Version; fingerprint = $Baseline.Fingerprint; digest = $Baseline.Digest; sealState = $Baseline.SealState }
        counts        = [ordered]@{ pass = [long]$Run.Counts.Pass; fail = [long]$Run.Counts.Fail; error = [long]$Run.Counts.Error; total = [long]$Run.Counts.Total }
        results       = @($results)
    }
    $doc['seal'] = [ordered]@{ algorithm = 'SHA-256'; digest = (Get-MbcDocumentDigest -Document $doc) }
    return $doc
}

function Test-MbcResultSeal {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    if (-not ($Document.Contains('seal') -and (Test-MbcIsDictionary $Document['seal']))) { return $false }
    return ([string]$Document['seal']['digest'] -ceq (Get-MbcDocumentDigest -Document $Document))
}
```

- [ ] **Step 5: Implement** `src/Report/Export.ps1`

```powershell
function Format-MbcCellValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object] $Value)
    $text = if ($null -eq $Value) { 'null' }
    elseif ($Value -is [string]) { $Value }
    elseif ($Value -is [bool]) { if ($Value) { 'true' } else { 'false' } }
    elseif (Test-MbcIsNumber $Value) { ConvertTo-MbcCanonicalJson -Value $Value }
    else { ConvertTo-MbcCanonicalJson -Value $Value }
    # A spreadsheet runs a cell that starts with one of these as a formula. A leading quote stops it.
    if ($text.Length -gt 0 -and $text[0] -in '=', '+', '-', '@', "`t", "`r") { return "'$text" }
    return $text
}

function ConvertTo-MbcResultCsv {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    $rows = foreach ($r in $Document['results']) {
        [pscustomobject][ordered]@{
            RunUtc          = $Document['run']['startedUtc']
            Tenant          = $Document['tenant']['id']
            Baseline        = Format-MbcCellValue $Document['baseline']['name']
            BaselineVersion = $Document['baseline']['version']
            Fingerprint     = $Document['baseline']['fingerprint']
            BaselineSeal    = $Document['baseline']['sealState']
            Id              = $r['id']
            Title           = Format-MbcCellValue $r['title']
            Severity        = $r['severity']
            Verdict         = $r['verdict']
            Cause           = $r['cause']
            Expected        = Format-MbcCellValue $r['expected']
            Actual          = if ($r['hasActual']) { Format-MbcCellValue $r['actual'] } else { '' }
            Request         = $r['request']
        }
    }
    return ((@($rows) | ConvertTo-Csv -NoTypeInformation -UseQuotes AsNeeded) -join "`n") + "`n"
}

function Export-MbcRunFiles {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] $Baseline,
        [Parameter(Mandatory)][string] $Directory
    )
    $stamp = Get-MbcRunStamp -RunId ([string]$Document['run']['id'])
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $json = Join-Path $Directory "result-$stamp.json"
    $csv = Join-Path $Directory "result-$stamp.csv"
    $summary = Join-Path $Directory "summary-$stamp.md"
    $markdown = ConvertTo-MbcSummaryMarkdown -Baseline $Baseline -Verdicts (Get-MbcSummaryVerdict -Document $Document) -RunUtc ([string]$Document['run']['startedUtc']) -SealState $Baseline.SealState
    [System.IO.File]::WriteAllText($json, (ConvertTo-MbcPrettyJson -Value $Document), $utf8)
    [System.IO.File]::WriteAllText($csv, (ConvertTo-MbcResultCsv -Document $Document), $utf8)
    [System.IO.File]::WriteAllText($summary, $markdown, $utf8)
    return [pscustomobject]@{ Json = $json; Csv = $csv; Summary = $summary; Locked = $null }
}
```

- [ ] **Step 6: Implement** `src/Report/Summary.ps1`

```powershell
function Get-MbcSummaryVerdict {
    <#
    .SYNOPSIS
        The only things a summary may take from a result: the check id, the verdict and the cause.
        Everything else in a summary comes from the baseline. This is what keeps tenant data out.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    $list = foreach ($r in $Document['results']) {
        $cause = [string]$r['cause']
        if ($r['verdict'] -eq 'Error' -and $cause -notin $script:MbcCauses) { $cause = 'unknown cause' }
        [pscustomobject]@{ Id = [string]$r['id']; Verdict = [string]$r['verdict']; Cause = $cause }
    }
    return , @($list)
}

function ConvertTo-MbcMarkdownCell {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Text)
    return $Text.Replace('\', '\\').Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function ConvertTo-MbcSummaryMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Baseline,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Verdicts,
        [Parameter(Mandatory)][string] $RunUtc,
        [Parameter(Mandatory)][string] $SealState
    )
    $checks = @{}
    foreach ($c in $Baseline.Document['preset']['checks']) { $checks[[string]$c['id']] = $c }
    $met = @($Verdicts | Where-Object Verdict -eq 'Pass').Count
    $notMet = @($Verdicts | Where-Object Verdict -eq 'Fail').Count
    $unverified = @($Verdicts | Where-Object Verdict -eq 'Error').Count
    $seal = if ($SealState -eq 'Sealed') { '' } else { ' · UNSEALED' }
    $identity = '{0} · v{1} · {2}{3}' -f $Baseline.Name, $Baseline.Version, $Baseline.Fingerprint, $seal

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("---`n")
    [void]$sb.Append("baseline: `"$($identity.Replace('"', '\"'))`"`n")
    [void]$sb.Append("run: `"$RunUtc`"`n")
    [void]$sb.Append("counts: { met: $met, notMet: $notMet, unverified: $unverified }`n")
    [void]$sb.Append("---`n`n")
    [void]$sb.Append("| ID | Setting | Status | Severity |`n|---|---|---|---|`n")
    $order = @{ Fail = 0; Error = 1; Pass = 2 }
    foreach ($v in ($Verdicts | Sort-Object { $order[$_.Verdict] }, Id)) {
        $check = $checks[$v.Id]
        $title = if ($check) { [string]$check['title'] } else { $v.Id }
        $severity = if ($check) { [string]$check['severity'] } else { '' }
        $status = switch ($v.Verdict) { 'Pass' { 'Met' } 'Fail' { 'Not met' } default { "Couldn't verify: $($v.Cause)" } }
        [void]$sb.Append("| $(ConvertTo-MbcMarkdownCell $v.Id) | $(ConvertTo-MbcMarkdownCell $title) | $status | $severity |`n")
    }
    [void]$sb.Append("`nChecked against **$(ConvertTo-MbcMarkdownCell $Baseline.Name)** v$($Baseline.Version), fingerprint ``$($Baseline.Fingerprint)``. Tenant values are left out of this summary by design.`n")
    return $sb.ToString()
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Report.Tests.ps1 -Output Detailed`
Expected: PASS, 8 tests.

- [ ] **Step 8: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Report/Result.ps1 src/Report/Export.ps1 src/Report/Summary.ps1 tests/fixtures/graph/sentinel-policies.json tests/Report.Tests.ps1
git commit -m "feat: sealed results, CSV, and a summary with no tenant data by construction" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 14: The team key: lock and unlock

**Files:**
- Create: `src/Report/Lock.ps1`, `src/Public/New-ResultKey.ps1`, `src/Public/Unlock-Result.ps1`
- Modify: `src/Report/Export.ps1`, so `Export-MbcRunFiles` gains `-KeyText` and `-LockSummary`
- Test: `tests/Lock.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-MbcCanonicalJson`, `ConvertTo-MbcPrettyJson`, `ConvertFrom-MbcJson`, `Get-MbcSha256Hex` (Task 2); `Test-MbcResultSeal` (Task 13); and `Get-MbcRunStamp` (Task 9).
- Produces:
  - `New-MbcTeamKeyText` → `'mbc-key:1:<8 hex>:<43 base64url>'`.
  - `ConvertFrom-MbcTeamKeyText -Text` → `{ KeyId; Bytes }`. It throws on a bad format or a mismatched ID.
  - `Protect-MbcPayload -KeyBytes -Header <IDictionary> -PayloadText` → the envelope (ordered).
  - `Unprotect-MbcPayload -Envelope -KeyBytes` → the payload text. It throws with voice-guide messages.
  - `Read-MbcLockedFile -Path` → the envelope, structure-checked.
  - `Open-MbcLockedResult -Path -KeyText` → `Mbc.UnlockedResult { KeyId; Header; Result; Csv; Summary }`, in memory. It throws if the inner seal fails.
  - `$script:MbcSessionKey`: a key text held for the TUI session, `$null` by default.
  - `Export-MbcRunFiles … [-KeyText <string>] [-LockSummary]`: with a key, it writes `result-<stamp>.locked` and **no** plaintext JSON or CSV. The summary stays plaintext unless `-LockSummary`.
  - Public: `New-ResultKey`, and `Unlock-Result -Path [-Key <securestring>] [-OutputDirectory]`.

- [ ] **Step 1: Write the failing tests** in `tests/Lock.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Team keys' {
        It 'makes keys that parse back to 32 bytes with a matching ID' {
            $text = New-MbcTeamKeyText
            $text | Should -Match '^mbc-key:1:[0-9a-f]{8}:[A-Za-z0-9_-]{43}$'
            $k = ConvertFrom-MbcTeamKeyText -Text $text
            $k.Bytes.Length | Should -Be 32
            $text | Should -Match $k.KeyId
        }
        It 'notices a mistyped key' {
            $text = New-MbcTeamKeyText
            $broken = $text.Substring(0, $text.Length - 1) + $(if ($text[-1] -eq 'A') { 'B' } else { 'A' })
            { ConvertFrom-MbcTeamKeyText -Text $broken } | Should -Throw '*mistyped*'
            { ConvertFrom-MbcTeamKeyText -Text 'hello' } | Should -Throw "*isn't a team key*"
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
            Set-Content -LiteralPath $path -Value '{"format":"m365bc-locked","version":1}' -Encoding utf8NoBOM
            { Read-MbcLockedFile -Path $path } | Should -Throw "*isn't a locked result*"
        }
    }

    Describe 'Exporting locked, and Unlock-Result' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            $script:Baseline = Read-MbcBaseline -Path (Join-Path $script:Fx 'baseline-minimal.json')
            $fetch = { param($ApiVersion, $Request) New-MbcFetchResult -Ok $false -Status 403 -Cause 'permission missing' }
            $script:Doc = New-MbcResultDocument -Run (Invoke-MbcRun -Baseline $script:Baseline -Fetch $fetch) -Baseline $script:Baseline -Connection $null
            $script:KeyText = New-MbcTeamKeyText
        }
        It 'writes a .locked file and no plaintext result' {
            $dir = Join-Path $TestDrive 'locked'
            New-Item -ItemType Directory -Path $dir | Out-Null
            $files = Export-MbcRunFiles -Document $script:Doc -Baseline $script:Baseline -Directory $dir -KeyText $script:KeyText
            Split-Path -Leaf $files.Locked | Should -Match '^result-\d{8}T\d{6}Z\.locked$'
            @(Get-ChildItem $dir -Filter '*.json').Count | Should -Be 0
            @(Get-ChildItem $dir -Filter '*.csv').Count | Should -Be 0
            Test-Path $files.Summary | Should -BeTrue
        }
        It 'can lock the summary too' {
            $dir = Join-Path $TestDrive 'all-locked'
            New-Item -ItemType Directory -Path $dir | Out-Null
            $files = Export-MbcRunFiles -Document $script:Doc -Baseline $script:Baseline -Directory $dir -KeyText $script:KeyText -LockSummary
            $files.Summary | Should -BeNullOrEmpty
            @(Get-ChildItem $dir -Filter '*.md').Count | Should -Be 0
        }
        It 'unlocks to memory, and writes plaintext only when asked' {
            $dir = Join-Path $TestDrive 'unlock'
            New-Item -ItemType Directory -Path $dir | Out-Null
            $files = Export-MbcRunFiles -Document $script:Doc -Baseline $script:Baseline -Directory $dir -KeyText $script:KeyText
            $secure = ConvertTo-SecureString -String $script:KeyText -AsPlainText -Force
            $opened = Unlock-Result -Path $files.Locked -Key $secure
            Test-MbcResultSeal -Document $opened.Result | Should -BeTrue
            $opened.Csv | Should -Match 'ORG-001'
            @(Get-ChildItem $dir -Filter '*.json').Count | Should -Be 0
            $out = Join-Path $TestDrive 'plain'
            New-Item -ItemType Directory -Path $out | Out-Null
            Unlock-Result -Path $files.Locked -Key $secure -OutputDirectory $out | Out-Null
            @(Get-ChildItem $out -Filter '*.json').Count | Should -Be 1
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Lock.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'New-MbcTeamKeyText' is not recognized`.

- [ ] **Step 3: Implement** `src/Report/Lock.ps1`

```powershell
$script:MbcSessionKey = $null
$script:MbcLockedMembers = @('format', 'version', 'keyId', 'header', 'salt', 'nonce', 'tag', 'ciphertext')

function ConvertTo-MbcBase64Url {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]] $Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-MbcBase64Url {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][string] $Text)
    $s = $Text.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) {
        2 { $s += '==' }
        3 { $s += '=' }
        1 { throw 'Not valid base64url.' }
    }
    return , [Convert]::FromBase64String($s)
}

function Get-MbcKeyId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]] $KeyBytes)
    return (Get-MbcSha256Hex -Bytes $KeyBytes).Substring(0, 8)
}

function New-MbcTeamKeyText {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $key = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
    return 'mbc-key:1:{0}:{1}' -f (Get-MbcKeyId -KeyBytes $key), (ConvertTo-MbcBase64Url -Bytes $key)
}

function ConvertFrom-MbcTeamKeyText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Text)
    $t = $Text.Trim()
    if ($t -notmatch '^mbc-key:1:(?<id>[0-9a-f]{8}):(?<k>[A-Za-z0-9_-]{43})$') {
        throw "That isn't a team key. It should look like mbc-key:1:<8 hex characters>:<43 characters>."
    }
    $id = $Matches['id']
    $bytes = ConvertFrom-MbcBase64Url -Text $Matches['k']
    if ($bytes.Length -ne 32 -or (Get-MbcKeyId -KeyBytes $bytes) -ne $id) {
        throw "That key's ID doesn't match its contents; it was probably mistyped or cut short."
    }
    return [pscustomobject]@{ KeyId = $id; Bytes = $bytes }
}

function Get-MbcLockedAad {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][string] $KeyId, [Parameter(Mandatory)][System.Collections.IDictionary] $Header)
    $aad = [ordered]@{ format = 'm365bc-locked'; version = 1L; keyId = $KeyId; header = $Header }
    return , [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MbcCanonicalJson -Value $aad))
}

function Get-MbcFileKey {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][byte[]] $KeyBytes, [Parameter(Mandatory)][byte[]] $Salt)
    $info = [System.Text.Encoding]::UTF8.GetBytes('m365bc-result-v1')
    return , [System.Security.Cryptography.HKDF]::DeriveKey([System.Security.Cryptography.HashAlgorithmName]::SHA256, $KeyBytes, 32, $Salt, $info)
}

function Protect-MbcPayload {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][byte[]] $KeyBytes,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Header,
        [Parameter(Mandatory)][string] $PayloadText
    )
    $keyId = Get-MbcKeyId -KeyBytes $KeyBytes
    # Our own copy: the header is authenticated as it is now, and a caller editing theirs later must not
    # change what this envelope says.
    $Header = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson -Value $Header)
    $salt = [byte[]]::new(16)
    $nonce = [byte[]]::new(12)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($salt)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
    $plain = [System.Text.UTF8Encoding]::new($false).GetBytes($PayloadText)
    $cipher = [byte[]]::new($plain.Length)
    $tag = [byte[]]::new(16)
    $fileKey = Get-MbcFileKey -KeyBytes $KeyBytes -Salt $salt
    $aes = [System.Security.Cryptography.AesGcm]::new($fileKey, 16)
    try { $aes.Encrypt($nonce, $plain, $cipher, $tag, (Get-MbcLockedAad -KeyId $keyId -Header $Header)) }
    finally { $aes.Dispose(); [Array]::Clear($fileKey, 0, $fileKey.Length) }
    return [ordered]@{
        format     = 'm365bc-locked'
        version    = 1L
        keyId      = $keyId
        header     = $Header
        salt       = [Convert]::ToBase64String($salt)
        nonce      = [Convert]::ToBase64String($nonce)
        tag        = [Convert]::ToBase64String($tag)
        ciphertext = [Convert]::ToBase64String($cipher)
    }
}

function Test-MbcLockedShape {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object] $Envelope)
    if (-not (Test-MbcIsDictionary $Envelope)) { return 'the top level is not an object' }
    foreach ($m in $script:MbcLockedMembers) { if (-not $Envelope.Contains($m)) { return "it has no '$m'" } }
    foreach ($k in $Envelope.Keys) { if ($k -notin $script:MbcLockedMembers) { return "it has an unexpected member '$k'" } }
    if ($Envelope['format'] -cne 'm365bc-locked' -or $Envelope['version'] -ne 1L) { return 'its format or version is not one this tool writes' }
    if (-not ($Envelope['keyId'] -is [string] -and $Envelope['keyId'] -cmatch '^[0-9a-f]{8}$')) { return 'its key ID is malformed' }
    if (-not (Test-MbcIsDictionary $Envelope['header'])) { return 'its header is not an object' }
    foreach ($pair in @(@('salt', 16), @('nonce', 12), @('tag', 16))) {
        try { $b = [Convert]::FromBase64String([string]$Envelope[$pair[0]]) } catch { return "its $($pair[0]) is not base64" }
        if ($b.Length -ne $pair[1]) { return "its $($pair[0]) is the wrong length" }
    }
    try { [void][Convert]::FromBase64String([string]$Envelope['ciphertext']) } catch { return 'its ciphertext is not base64' }
    return $null
}

function Read-MbcLockedFile {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "There's no file at '$Path'." }
    try { $envelope = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)) }
    catch { throw "'$Path' isn't a locked result: it isn't valid JSON." }
    $problem = Test-MbcLockedShape -Envelope $envelope
    if ($problem) { throw "'$Path' isn't a locked result: $problem." }
    return $envelope
}

function Unprotect-MbcPayload {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Envelope, [Parameter(Mandatory)][byte[]] $KeyBytes)
    $problem = Test-MbcLockedShape -Envelope $Envelope
    if ($problem) { throw "This isn't a locked result: $problem." }
    $givenId = Get-MbcKeyId -KeyBytes $KeyBytes
    if ($givenId -ne $Envelope['keyId']) { throw "This file needs key $($Envelope['keyId']); the key you gave is $givenId." }
    $salt = [Convert]::FromBase64String($Envelope['salt'])
    $nonce = [Convert]::FromBase64String($Envelope['nonce'])
    $tag = [Convert]::FromBase64String($Envelope['tag'])
    $cipher = [Convert]::FromBase64String($Envelope['ciphertext'])
    $plain = [byte[]]::new($cipher.Length)
    $fileKey = Get-MbcFileKey -KeyBytes $KeyBytes -Salt $salt
    $aes = [System.Security.Cryptography.AesGcm]::new($fileKey, 16)
    # A plain catch, not a typed one: PowerShell wraps .NET method exceptions, and any failure to decrypt
    # with the right key means the same thing to the reader.
    try { $aes.Decrypt($nonce, $cipher, $tag, $plain, (Get-MbcLockedAad -KeyId $Envelope['keyId'] -Header $Envelope['header'])) }
    catch {
        throw "The key is right, but the file won't open: it has been altered or damaged since it was locked."
    }
    finally { $aes.Dispose(); [Array]::Clear($fileKey, 0, $fileKey.Length) }
    return [System.Text.UTF8Encoding]::new($false).GetString($plain)
}

function Open-MbcLockedResult {
    <#
    .SYNOPSIS
        Opens a locked result with a team key given as text, to memory. Shared by Unlock-Result and
        the TUI, so neither needs to turn text back into a SecureString.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $KeyText)
    $envelope = Read-MbcLockedFile -Path $Path
    $parsed = ConvertFrom-MbcTeamKeyText -Text $KeyText
    $payload = ConvertFrom-MbcJson -Json (Unprotect-MbcPayload -Envelope $envelope -KeyBytes $parsed.Bytes) -AllowFloat
    if (-not (Test-MbcResultSeal -Document $payload['result'])) {
        throw 'The file opened, but the result inside does not match its own seal. Treat it as untrustworthy.'
    }
    return [pscustomobject]@{
        PSTypeName = 'Mbc.UnlockedResult'
        KeyId      = $envelope['keyId']
        Header     = $envelope['header']
        Result     = $payload['result']
        Csv        = [string]$payload['csv']
        Summary    = [string]$payload['summary']
    }
}

function ConvertFrom-MbcSecureKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][securestring] $Key)
    return [System.Net.NetworkCredential]::new('', $Key).Password
}
```

- [ ] **Step 4: Extend** `Export-MbcRunFiles` in `src/Report/Export.ps1`

Replace the whole function with this version:

```powershell
function Export-MbcRunFiles {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] $Baseline,
        [Parameter(Mandatory)][string] $Directory,
        [string] $KeyText,
        [switch] $LockSummary
    )
    $stamp = Get-MbcRunStamp -RunId ([string]$Document['run']['id'])
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $csvText = ConvertTo-MbcResultCsv -Document $Document
    $markdown = ConvertTo-MbcSummaryMarkdown -Baseline $Baseline -Verdicts (Get-MbcSummaryVerdict -Document $Document) -RunUtc ([string]$Document['run']['startedUtc']) -SealState $Baseline.SealState
    $files = [pscustomobject]@{ Json = $null; Csv = $null; Summary = $null; Locked = $null }

    if ($KeyText) {
        $key = ConvertFrom-MbcTeamKeyText -Text $KeyText
        $header = [ordered]@{
            baseline = [ordered]@{ name = $Baseline.Name; version = $Baseline.Version; fingerprint = $Baseline.Fingerprint }
            runUtc   = [string]$Document['run']['startedUtc']
            tool     = $script:MbcToolVersion
        }
        $payload = ConvertTo-MbcCanonicalJson -Value ([ordered]@{ result = $Document; csv = $csvText; summary = $markdown })
        $files.Locked = Join-Path $Directory "result-$stamp.locked"
        [System.IO.File]::WriteAllText($files.Locked, (ConvertTo-MbcPrettyJson -Value (Protect-MbcPayload -KeyBytes $key.Bytes -Header $header -PayloadText $payload)), $utf8)
    }
    else {
        $files.Json = Join-Path $Directory "result-$stamp.json"
        $files.Csv = Join-Path $Directory "result-$stamp.csv"
        [System.IO.File]::WriteAllText($files.Json, (ConvertTo-MbcPrettyJson -Value $Document), $utf8)
        [System.IO.File]::WriteAllText($files.Csv, $csvText, $utf8)
    }
    if (-not ($KeyText -and $LockSummary)) {
        $files.Summary = Join-Path $Directory "summary-$stamp.md"
        [System.IO.File]::WriteAllText($files.Summary, $markdown, $utf8)
    }
    return $files
}
```

- [ ] **Step 5: Implement** `src/Public/New-ResultKey.ps1`

```powershell
function New-ResultKey {
    <#
    .SYNOPSIS
        Generates a team key for locking results. Shown once; nothing is written to disk.
    .EXAMPLE
        New-ResultKey
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Generates text; changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $text = New-MbcTeamKeyText
    $id = ($text -split ':')[2]
    Write-Information "Store this in one entry in your team's password manager, named 'M365 Baseline Check · results key $id'." -InformationAction Continue
    Write-Information "It won't be shown again, and nothing has been saved to disk." -InformationAction Continue
    return $text
}
```

- [ ] **Step 6: Implement** `src/Public/Unlock-Result.ps1`

```powershell
function Unlock-Result {
    <#
    .SYNOPSIS
        Opens a locked result with the team key. It opens to memory; plaintext is written to disk only
        with -OutputDirectory.
    .EXAMPLE
        Unlock-Result ./results/result-20260926T141200Z.locked
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string] $Path,
        [securestring] $Key,
        [string] $OutputDirectory
    )
    $envelope = Read-MbcLockedFile -Path $Path
    $keyText = if ($Key) { ConvertFrom-MbcSecureKey -Key $Key }
    elseif ($script:MbcSessionKey) { $script:MbcSessionKey }
    else { ConvertFrom-MbcSecureKey -Key (Read-Host -AsSecureString -Prompt "Team key $($envelope['keyId'])") }

    $opened = Open-MbcLockedResult -Path $Path -KeyText $keyText
    if ($OutputDirectory -and $PSCmdlet.ShouldProcess($OutputDirectory, 'Write the unlocked result as plaintext')) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $stamp = $base -replace '^result-', ''
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $OutputDirectory "$base.json"), (ConvertTo-MbcPrettyJson -Value $opened.Result), $utf8)
        [System.IO.File]::WriteAllText((Join-Path $OutputDirectory "$base.csv"), $opened.Csv, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $OutputDirectory "summary-$stamp.md"), $opened.Summary, $utf8)
        Write-Information "Unlocked into $OutputDirectory. Those files are plaintext; file them accordingly." -InformationAction Continue
    }
    return $opened
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Lock.Tests.ps1, ./tests/Report.Tests.ps1 -Output Detailed`
Expected: PASS: 10 lock tests, and the 8 report tests still green.

- [ ] **Step 8: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Report/Lock.ps1 src/Report/Export.ps1 src/Public/New-ResultKey.ps1 src/Public/Unlock-Result.ps1 tests/Lock.Tests.ps1
git commit -m "feat: lock results with a team key; unlock to memory" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 15: Plain output and `Invoke-BaselineCheck`

**Files:**
- Create: `src/Report/Plain.ps1`, `src/Public/Invoke-BaselineCheck.ps1`
- Test: `tests/InvokeBaselineCheck.Tests.ps1`

**Interfaces:**
- Consumes: everything from Tasks 6 to 14.
- Produces:
  - `Format-MbcShortValue -Value [-Width]` → compact JSON, truncated with `…`.
  - `Format-MbcPlainResultLine -Result` → one line, for example `FAIL   ORG-001   Users cannot register applications: expected false · got true`.
  - `Format-MbcPlainSummary -Counts -Baseline` → for example `1 met, 0 not, 1 unverifiable. Fixture baseline v1 · 1a2b3c4d5e6f.`
  - `Invoke-BaselineCheck -Baseline <path> [-AllowUnsealed] [-ExpectedFingerprint] [-OutputRoot] [-Lock] [-Key <securestring>] [-LockSummary] [-NoExport]`, public, with hidden `-Fetch` and `-Connection` test seams. It returns `{ Counts; Results; Files; Baseline (identity); LogPath }`.

- [ ] **Step 1: Write the failing tests** in `tests/InvokeBaselineCheck.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Invoke-BaselineCheck' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures'
            $script:Bodies = @{
                '/policies/authorizationPolicy'       = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/authorizationPolicy.json')))
                '/identity/conditionalAccess/policies' = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx 'graph/conditionalAccessPolicies.json')))
            }
            $script:Fetches = @{ n = 0 }
            $script:Fetch = { param($ApiVersion, $Request) $script:Fetches.n++; New-MbcFetchResult -Ok $true -Body $script:Bodies[$Request] -Status 200 }
            $script:Conn = [pscustomobject]@{ TenantId = '00000000-0000-4000-8000-000000000001'; Account = 'operator@example.com' }
        }
        BeforeEach {
            $script:Fetches.n = 0
            $script:Sealed = Join-Path $TestDrive "sealed-$([guid]::NewGuid().ToString('N')).json"
            Copy-Item (Join-Path $script:Fx 'baseline-minimal.json') $script:Sealed
            Protect-Baseline -Path $script:Sealed -InformationAction SilentlyContinue | Out-Null
            $script:Out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        }

        It 'runs, writes a log and the three exports, and returns the counts' {
            $r = Invoke-BaselineCheck -Baseline $script:Sealed -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn -InformationAction SilentlyContinue
            $r.Counts.Pass | Should -Be 2
            Test-Path $r.Files.Json | Should -BeTrue
            Test-Path $r.Files.Summary | Should -BeTrue
            Test-Path $r.LogPath | Should -BeTrue
            (Get-Content $r.LogPath) -join "`n" | Should -Match '"event":"check"'
        }

        It 'prints one line per check and a one-line summary' {
            $lines = Invoke-BaselineCheck -Baseline $script:Sealed -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn 6>&1 |
                Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }
            ($lines | Where-Object { $_ -match '^PASS\s+ORG-001' }).Count | Should -Be 1
            ($lines | Where-Object { $_ -match '^2 met, 0 not, 0 unverifiable\.' }).Count | Should -Be 1
        }

        It 'checks an expected fingerprint before fetching anything' {
            { Invoke-BaselineCheck -Baseline $script:Sealed -ExpectedFingerprint '000000000000' -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn } | Should -Throw '*Fingerprint mismatch*'
            $script:Fetches.n | Should -Be 0
        }

        It 'refuses an unsealed baseline, and stamps UNSEALED when allowed' {
            $raw = Join-Path $TestDrive 'raw.json'
            Copy-Item (Join-Path $script:Fx 'baseline-minimal.json') $raw -Force
            { Invoke-BaselineCheck -Baseline $raw -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn } | Should -Throw '*never been sealed*'
            $r = Invoke-BaselineCheck -Baseline $raw -AllowUnsealed -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn -InformationAction SilentlyContinue
            [System.IO.File]::ReadAllText($r.Files.Summary) | Should -Match 'UNSEALED'
        }

        It 'locks the export when given a key' {
            $key = ConvertTo-SecureString -String (New-MbcTeamKeyText) -AsPlainText -Force
            $r = Invoke-BaselineCheck -Baseline $script:Sealed -Lock -Key $key -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn -InformationAction SilentlyContinue
            $r.Files.Locked | Should -Match '\.locked$'
            $r.Files.Json | Should -BeNullOrEmpty
        }

        It 'writes no export with -NoExport' {
            $r = Invoke-BaselineCheck -Baseline $script:Sealed -NoExport -OutputRoot $script:Out -Fetch $script:Fetch -Connection $script:Conn -InformationAction SilentlyContinue
            $r.Files | Should -BeNullOrEmpty
            @(Get-ChildItem (Join-Path $script:Out 'results')).Count | Should -Be 0
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/InvokeBaselineCheck.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Invoke-BaselineCheck' is not recognized`.

- [ ] **Step 3: Implement** `src/Report/Plain.ps1`

```powershell
function Format-MbcShortValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object] $Value, [int] $Width = 60)
    $text = ConvertTo-MbcCanonicalJson -Value $Value
    if ($text.Length -le $Width) { return $text }
    return $text.Substring(0, $Width - 1) + '…'
}

function Format-MbcPlainResultLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Result)
    $word = switch ($Result.Verdict) { 'Pass' { 'PASS' } 'Fail' { 'FAIL' } default { 'ERROR' } }
    $line = '{0,-6} {1,-10} {2}' -f $word, $Result.Id, $Result.Title
    if ($Result.Verdict -eq 'Fail') {
        $got = if ($Result.HasActual) { Format-MbcShortValue -Value $Result.Actual } else { 'nothing' }
        $line += ': expected {0} · got {1}' -f (Format-MbcShortValue -Value $Result.Expected), $got
    }
    elseif ($Result.Verdict -eq 'Error') {
        $line += ": $($Result.Cause)"
        if ($Result.Detail) { $line += " ($($Result.Detail))" }
    }
    return $line
}

function Format-MbcPlainSummary {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Counts, [Parameter(Mandatory)] $Baseline)
    $seal = if ($Baseline.SealState -eq 'Sealed') { '' } else { ' UNSEALED.' }
    return '{0} met, {1} not, {2} unverifiable. {3} v{4} · {5}.{6}' -f $Counts.Pass, $Counts.Fail, $Counts.Error, $Baseline.Name, $Baseline.Version, $Baseline.Fingerprint, $seal
}
```

- [ ] **Step 4: Implement** `src/Public/Invoke-BaselineCheck.ps1`

```powershell
function Invoke-BaselineCheck {
    <#
    .SYNOPSIS
        Checks the signed-in tenant against a sealed baseline, without the interactive view.
    .DESCRIPTION
        Refuses an unsealed or edited baseline unless -AllowUnsealed. Writes a verbose run log, then a
        sealed JSON result, a CSV and a redacted summary; with -Lock, the result is encrypted with the
        team key and no plaintext result is written.
    .EXAMPLE
        Invoke-BaselineCheck ./baselines/core-tenant.json -ExpectedFingerprint a1b2c3d4e5f6 -Lock
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string] $Baseline,
        [switch] $AllowUnsealed,
        [string] $ExpectedFingerprint,
        [string] $OutputRoot,
        [switch] $Lock,
        [securestring] $Key,
        [switch] $LockSummary,
        [switch] $NoExport,
        [Parameter(DontShow)][scriptblock] $Fetch,
        [Parameter(DontShow)] $Connection
    )
    $b = Read-MbcBaseline -Path $Baseline
    Assert-MbcBaselineUsable -Baseline $b -AllowUnsealed:$AllowUnsealed -ExpectedFingerprint $ExpectedFingerprint

    $keyText = $null
    if ($Lock) {
        $secure = if ($Key) { $Key } else { Read-Host -AsSecureString -Prompt 'Team key' }
        $keyText = ConvertFrom-MbcSecureKey -Key $secure
        [void](ConvertFrom-MbcTeamKeyText -Text $keyText)
    }

    $root = Get-MbcOutputRoot -Root $OutputRoot
    $runId = New-MbcRunId
    $log = New-MbcRunLog -Directory (Join-Path $root 'logs') -RunId $runId -Baseline $b.Fingerprint
    Write-MbcLog -Log $log -Event 'run.start' -Data @{
        tool     = $script:MbcToolVersion
        baseline = [ordered]@{ name = $b.Name; version = $b.Version; digest = $b.Digest; sealState = $b.SealState }
    }

    if (-not $Fetch) {
        $Connection = Connect-MbcGraph -Scopes ([string[]]@($b.Document['preset']['scopes'])) -Log $log
        # $log is found by dynamic scope when the engine invokes this block from inside this call.
        $Fetch = { param($ApiVersion, $Request) Invoke-MbcGraphGet -ApiVersion $ApiVersion -Request $Request -Log $log }
    }

    $onResult = {
        param($r)
        Write-MbcLog -Log $log -Event 'check' -Data @{
            id = $r.Id; verdict = $r.Verdict; cause = $r.Cause; operator = $r.Operator
            expected = $r.Expected; actual = $r.Actual; hasActual = $r.HasActual
        }
        Write-Information (Format-MbcPlainResultLine -Result $r) -InformationAction Continue
    }
    $run = Invoke-MbcRun -Baseline $b -Fetch $Fetch -OnResult $onResult -RunId $runId
    $doc = New-MbcResultDocument -Run $run -Baseline $b -Connection $Connection

    $files = $null
    if (-not $NoExport) {
        $files = Export-MbcRunFiles -Document $doc -Baseline $b -Directory (Join-Path $root 'results') -KeyText $keyText -LockSummary:$LockSummary
    }
    Write-MbcLog -Log $log -Event 'run.end' -Data @{ pass = $run.Counts.Pass; fail = $run.Counts.Fail; error = $run.Counts.Error; resultDigest = $doc['seal']['digest'] }
    Write-Information (Format-MbcPlainSummary -Counts $run.Counts -Baseline $b) -InformationAction Continue
    if ($files) {
        $written = @($files.Locked, $files.Json, $files.Csv, $files.Summary | Where-Object { $_ }) -join ', '
        Write-Information "Written: $written" -InformationAction Continue
    }
    return [pscustomobject]@{
        PSTypeName = 'Mbc.RunSummary'
        Counts     = $run.Counts
        Results    = $run.Results
        Files      = $files
        Baseline   = (Get-MbcBaselineIdentity -Baseline $b)
        LogPath    = $log.Path
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/InvokeBaselineCheck.Tests.ps1 -Output Detailed`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Report/Plain.ps1 src/Public/Invoke-BaselineCheck.ps1 tests/InvokeBaselineCheck.Tests.ps1
git commit -m "feat: Invoke-BaselineCheck, the whole run in plain output" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 16: TUI primitives: capabilities, glyphs, styles and widgets

**Files:**
- Create: `src/Tui/Terminal.ps1`, `src/Tui/Widgets.ps1`
- Test: `tests/Widgets.Tests.ps1`

**Interfaces:**
- Produces:
  - `New-MbcCapability [-Width] [-Height] [-Color] [-Unicode] [-Interactive]` → `Mbc.Capability`. Used by tests and fallbacks.
  - `Get-MbcTerminalCapability` → the same shape, measured from the real console. It honours `NO_COLOR` and `M365BC_ASCII`.
  - `Get-MbcGlyphs -Unicode <bool>` → a hashtable: `Pass Fail Error Pointer Ellipsis Dot H V TL TR BL BR Seal Track Cursor Spinner[] Bar[9] Unicode`.
  - `Format-MbcStyle -Text -Style -Color` (styles: `ok bad warn dim accent bold reverse`), `Measure-MbcWidth -Text` (display width, ANSI stripped), `Limit-MbcText -Text -Width [-Ellipsis]`, and `Format-MbcPad -Text -Width [-Right]`.
  - `Format-MbcProgressBar -Done -Total -Width -Glyphs -Color` → a string exactly `Width` cells wide, at eighth-cell resolution in Unicode.
  - `Get-MbcSpinnerFrame -Tick -Glyphs` → one character.
  - `Format-MbcVerdictTag -Verdict -Glyphs -Color` → a 7-cell tag: `✓ PASS `, `✗ FAIL ` or `! ERROR`.
  - `Format-MbcBox -Title -RightTitle -Lines -Width -Glyphs -Color` → `string[]` (top border, one line each, bottom border).
  - `Format-MbcMenu -Items -Selected -Width -Glyphs -Color` → `string[]`. Items are `{ Label; Key; Action }`.
  - `Format-MbcTable -Columns -Rows -Width -Height -Selected -Offset -Glyphs -Color` → `string[]`.
    - Columns: `{ Name; Width }`, where `Width 0` is the one flexible column.
    - Rows: `{ Cells = @(@{ Text; Style }, ...) }`.
  - `Format-MbcFooter -Keys <@(@(key,label),...)> -Width -Glyphs -Color` → one line. Pairs are dropped from the end until it fits.

- [ ] **Step 1: Write the failing tests** in `tests/Widgets.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Styles and widths' {
        It 'adds colour only when asked, and measures width without escape codes' {
            Format-MbcStyle -Text 'x' -Style 'ok' -Color $false | Should -BeExactly 'x'
            $styled = Format-MbcStyle -Text 'hello' -Style 'ok' -Color $true
            $styled | Should -Not -BeExactly 'hello'
            Measure-MbcWidth -Text $styled | Should -Be 5
        }
        It 'truncates with an ellipsis and pads to a width' {
            Limit-MbcText -Text 'abcdefgh' -Width 5 | Should -BeExactly 'abcd…'
            Limit-MbcText -Text 'abc' -Width 5 | Should -BeExactly 'abc'
            Format-MbcPad -Text 'ab' -Width 4 | Should -BeExactly 'ab  '
            Format-MbcPad -Text 'ab' -Width 4 -Right | Should -BeExactly '  ab'
        }
    }

    Describe 'Progress and spinner' {
        BeforeAll {
            $script:U = Get-MbcGlyphs -Unicode $true
            $script:A = Get-MbcGlyphs -Unicode $false
        }
        It 'is always exactly as wide as asked' -ForEach @(
            @{ Done = 0; Total = 10 }, @{ Done = 3; Total = 10 }, @{ Done = 10; Total = 10 }, @{ Done = 5; Total = 0 }
        ) {
            Measure-MbcWidth (Format-MbcProgressBar -Done $Done -Total $Total -Width 20 -Glyphs $script:U -Color $false) | Should -Be 20
            Measure-MbcWidth (Format-MbcProgressBar -Done $Done -Total $Total -Width 20 -Glyphs $script:A -Color $false) | Should -Be 20
        }
        It 'fills completely at the end, and uses a partial cell on the way' {
            (Format-MbcProgressBar -Done 10 -Total 10 -Width 8 -Glyphs $script:U -Color $false) | Should -BeExactly ('█' * 8)
            (Format-MbcProgressBar -Done 1 -Total 16 -Width 8 -Glyphs $script:U -Color $false)[0] | Should -BeExactly '▌'
        }
        It 'turns the spinner through its frames' {
            Get-MbcSpinnerFrame -Tick 0 -Glyphs $script:U | Should -Be '⠋'
            Get-MbcSpinnerFrame -Tick 10 -Glyphs $script:U | Should -Be '⠋'
            Get-MbcSpinnerFrame -Tick 1 -Glyphs $script:A | Should -Be '/'
        }
        It 'always says the verdict in words, seven cells wide' -ForEach @(@{ V = 'Pass'; W = 'PASS' }, @{ V = 'Fail'; W = 'FAIL' }, @{ V = 'Error'; W = 'ERROR' }) {
            $tag = Format-MbcVerdictTag -Verdict $V -Glyphs $script:A -Color $false
            $tag | Should -Match $W
            Measure-MbcWidth $tag | Should -Be 7
        }
    }

    Describe 'Box, menu, table and footer' {
        BeforeAll { $script:U = Get-MbcGlyphs -Unicode $true }
        It 'draws a box whose every line is exactly the width' {
            $lines = Format-MbcBox -Title 'M365 Baseline Check' -RightTitle 'v0.1.0' -Lines @('Tenant    example.com', 'Baseline  none chosen') -Width 60 -Glyphs $script:U -Color $false
            $lines.Count | Should -Be 4
            foreach ($l in $lines) { Measure-MbcWidth $l | Should -Be 60 }
            $lines[0] | Should -Match 'M365 Baseline Check'
            $lines[0] | Should -Match 'v0.1.0'
        }
        It 'marks the selected menu item and shows each hotkey' {
            $items = @([pscustomobject]@{ Label = 'Run checks'; Key = 'r'; Action = 'run' }, [pscustomobject]@{ Label = 'Quit'; Key = 'q'; Action = 'quit' })
            $lines = Format-MbcMenu -Items $items -Selected 1 -Width 40 -Glyphs $script:U -Color $false
            $lines[1] | Should -Match '▸ Quit'
            $lines[0] | Should -Match 'r\s*$'
            foreach ($l in $lines) { Measure-MbcWidth $l | Should -BeLessOrEqual 40 }
        }
        It 'lays out a table within the width, truncating the flexible column' {
            $cols = @([pscustomobject]@{ Name = 'ID'; Width = 8 }, [pscustomobject]@{ Name = 'Setting'; Width = 0 })
            $rows = @([pscustomobject]@{ Cells = @(@{ Text = 'CA-001'; Style = 'none' }, @{ Text = ('A very long setting title ' * 5); Style = 'none' }) })
            $lines = Format-MbcTable -Columns $cols -Rows $rows -Width 50 -Height 5 -Selected 0 -Offset 0 -Glyphs $script:U -Color $false
            foreach ($l in $lines) { Measure-MbcWidth $l | Should -BeLessOrEqual 50 }
            $lines[1] | Should -Match '…'
        }
        It 'drops footer hints from the end rather than overflowing' {
            $keys = @(@('↑↓', 'move'), @('Enter', 'select'), @('r', 'run'), @('q', 'quit'))
            Measure-MbcWidth (Format-MbcFooter -Keys $keys -Width 200 -Glyphs $script:U -Color $false) | Should -BeLessOrEqual 200
            $narrow = Format-MbcFooter -Keys $keys -Width 24 -Glyphs $script:U -Color $false
            Measure-MbcWidth $narrow | Should -BeLessOrEqual 24
            $narrow | Should -Match 'move'
            $narrow | Should -Not -Match 'quit'
        }
        It 'uses ASCII arrows when Unicode is off' {
            $a = Get-MbcGlyphs -Unicode $false
            Format-MbcFooter -Keys @(@('↑↓', 'move')) -Width 40 -Glyphs $a -Color $false | Should -Match 'Up/Dn'
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Widgets.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'Format-MbcStyle' is not recognized`.

- [ ] **Step 3: Implement** `src/Tui/Terminal.ps1`

```powershell
$script:MbcAnsi = @{
    ok      = "`e[32m"
    bad     = "`e[31m"
    warn    = "`e[33m"
    dim     = "`e[2m"
    accent  = "`e[36m"
    bold    = "`e[1m"
    reverse = "`e[7m"
}
$script:MbcAnsiReset = "`e[0m"
$script:MbcAnsiPattern = "`e\[[0-9;?]*[A-Za-z]"

function New-MbcCapability {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int] $Width = 80, [int] $Height = 24, [bool] $Color = $false, [bool] $Unicode = $true, [bool] $Interactive = $false)
    return [pscustomobject]@{
        PSTypeName  = 'Mbc.Capability'
        Width       = [Math]::Max(40, $Width)
        Height      = [Math]::Max(12, $Height)
        Color       = $Color
        Unicode     = $Unicode
        Interactive = $Interactive
    }
}

function Get-MbcTerminalCapability {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $redirected = [Console]::IsOutputRedirected -or [Console]::IsInputRedirected
    $vt = $false
    try { $vt = [bool]$Host.UI.SupportsVirtualTerminal } catch { $vt = $false }
    $width = 80
    $height = 24
    try { $width = [Console]::WindowWidth; $height = [Console]::WindowHeight } catch { Write-Verbose 'No console window; using 80x24.' }
    $interactive = (-not $redirected) -and $vt -and ($Host.Name -eq 'ConsoleHost')
    $unicode = ([Console]::OutputEncoding.CodePage -eq 65001) -and -not $env:M365BC_ASCII
    return (New-MbcCapability -Width $width -Height $height -Color ($interactive -and -not $env:NO_COLOR) -Unicode $unicode -Interactive $interactive)
}

function Get-MbcGlyphs {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][bool] $Unicode)
    if ($Unicode) {
        return @{
            Unicode = $true; Pass = '✓'; Fail = '✗'; Error = '!'; Pointer = '▸'; Ellipsis = '…'; Dot = '·'; Seal = '✓'
            H = '─'; V = '│'; TL = '╭'; TR = '╮'; BL = '╰'; BR = '╯'; Track = '─'; Cursor = '▏'
            Spinner = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
            Bar = @('', '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█')
        }
    }
    return @{
        Unicode = $false; Pass = '+'; Fail = 'x'; Error = '!'; Pointer = '>'; Ellipsis = '~'; Dot = '-'; Seal = 'ok'
        H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'; Track = '.'; Cursor = '_'
        Spinner = @('|', '/', '-', '\')
        Bar = @('', '', '', '', '', '', '', '', '#')
    }
}

function Format-MbcStyle {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text,
        [Parameter(Position = 1)][string] $Style,
        [Parameter(Position = 2)][bool] $Color
    )
    if (-not $Color -or [string]::IsNullOrEmpty($Text) -or -not $script:MbcAnsi.ContainsKey($Style)) { return [string]$Text }
    return "$($script:MbcAnsi[$Style])$Text$($script:MbcAnsiReset)"
}

function Measure-MbcWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return ([regex]::Replace($Text, $script:MbcAnsiPattern, '')).Length
}

function Limit-MbcText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text,
        [Parameter(Position = 1)][int] $Width,
        [Parameter(Position = 2)][string] $Ellipsis = '…'
    )
    $t = [string]$Text
    if ($Width -le 0) { return '' }
    if ($t.Length -le $Width) { return $t }
    if ($Width -le $Ellipsis.Length) { return $t.Substring(0, $Width) }
    return $t.Substring(0, $Width - $Ellipsis.Length) + $Ellipsis
}

function Format-MbcPad {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text,
        [Parameter(Position = 1)][int] $Width,
        [switch] $Right
    )
    $t = [string]$Text
    $gap = $Width - (Measure-MbcWidth $t)
    if ($gap -le 0) { return $t }
    if ($Right) { return (' ' * $gap) + $t }
    return $t + (' ' * $gap)
}

function ConvertTo-MbcGlyphText {
    # Menu labels and key hints are written with Unicode arrows and ellipses; ASCII mode swaps them.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string] $Text, [Parameter(Position = 1)][hashtable] $Glyphs)
    if ($Glyphs.Unicode) { return $Text }
    return $Text.Replace('↑↓', 'Up/Dn').Replace('↑', 'Up').Replace('↓', 'Dn').Replace('…', '...').Replace('·', '-')
}
```

- [ ] **Step 4: Implement** `src/Tui/Widgets.ps1`

```powershell
function Format-MbcProgressBar {
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Done, [int] $Total, [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    if ($Width -le 0) { return '' }
    $ratio = if ($Total -le 0) { 0.0 } else { [Math]::Min(1.0, [Math]::Max(0.0, $Done / [double]$Total)) }
    $eighths = [int][Math]::Floor($ratio * $Width * 8)
    $full = [int][Math]::Floor($eighths / 8)
    $part = $eighths % 8
    $filled = $Glyphs.Bar[8] * $full
    $partial = if ($full -lt $Width -and $part -gt 0) { $Glyphs.Bar[$part] } else { '' }
    $used = $full + $partial.Length
    $track = $Glyphs.Track * ($Width - $used)
    return (Format-MbcStyle ($filled + $partial) 'accent' $Color) + (Format-MbcStyle $track 'dim' $Color)
}

function Get-MbcSpinnerFrame {
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Tick, [Parameter(Mandatory)][hashtable] $Glyphs)
    return $Glyphs.Spinner[[Math]::Abs($Tick) % $Glyphs.Spinner.Count]
}

function Format-MbcVerdictTag {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Verdict, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    switch ($Verdict) {
        'Pass' { return (Format-MbcStyle ('{0} PASS ' -f $Glyphs.Pass) 'ok' $Color) }
        'Fail' { return (Format-MbcStyle ('{0} FAIL ' -f $Glyphs.Fail) 'bad' $Color) }
        default { return (Format-MbcStyle ('{0} ERROR' -f $Glyphs.Error) 'warn' $Color) }
    }
}

function Format-MbcBox {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $Title,
        [string] $RightTitle,
        [AllowEmptyCollection()][string[]] $Lines = @(),
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][hashtable] $Glyphs,
        [bool] $Color
    )
    $inner = $Width - 4
    $t = Limit-MbcText $Title ([Math]::Max(1, $Width - 8)) $Glyphs.Ellipsis
    $left = "$($Glyphs.TL)$($Glyphs.H) $t "
    $right = if ($RightTitle) { " $RightTitle $($Glyphs.H)$($Glyphs.TR)" } else { "$($Glyphs.H)$($Glyphs.TR)" }
    if ($Width - $left.Length - $right.Length -lt 1) { $right = "$($Glyphs.H)$($Glyphs.TR)" }
    $fill = [Math]::Max(0, $Width - $left.Length - $right.Length)
    $out = [System.Collections.Generic.List[string]]::new()
    $top = (Format-MbcStyle "$($Glyphs.TL)$($Glyphs.H) " 'dim' $Color) + (Format-MbcStyle $t 'bold' $Color) + ' ' +
        (Format-MbcStyle ($Glyphs.H * $fill) 'dim' $Color) + (Format-MbcStyle $right 'dim' $Color)
    $out.Add($top)
    foreach ($line in $Lines) {
        $out.Add((Format-MbcStyle "$($Glyphs.V) " 'dim' $Color) + (Format-MbcPad $line $inner) + (Format-MbcStyle " $($Glyphs.V)" 'dim' $Color))
    }
    $out.Add((Format-MbcStyle ($Glyphs.BL + ($Glyphs.H * ($Width - 2)) + $Glyphs.BR) 'dim' $Color))
    return , $out.ToArray()
}

function Format-MbcMenu {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object[]] $Items,
        [int] $Selected,
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][hashtable] $Glyphs,
        [bool] $Color
    )
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $label = Limit-MbcText (ConvertTo-MbcGlyphText $Items[$i].Label $Glyphs) ($Width - 10) $Glyphs.Ellipsis
        $key = [string]$Items[$i].Key
        $pointer = if ($i -eq $Selected) { $Glyphs.Pointer } else { ' ' }
        $text = if ($i -eq $Selected) { Format-MbcStyle $label 'bold' $Color } else { $label }
        $left = "  $(Format-MbcStyle $pointer 'accent' $Color) $text"
        $out.Add((Format-MbcPad $left ($Width - 2 - $key.Length)) + (Format-MbcStyle $key 'dim' $Color))
    }
    return , $out.ToArray()
}

function Format-MbcTable {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object[]] $Columns,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows,
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][int] $Height,
        [int] $Selected = -1,
        [int] $Offset = 0,
        [Parameter(Mandatory)][hashtable] $Glyphs,
        [bool] $Color
    )
    $gap = 2
    $fixed = ($Columns | Where-Object { $_.Width -gt 0 } | Measure-Object -Property Width -Sum).Sum
    $flex = [Math]::Max(8, $Width - 2 - $fixed - ($gap * ($Columns.Count - 1)))
    $widths = @($Columns | ForEach-Object { if ($_.Width -gt 0) { $_.Width } else { $flex } })

    $out = [System.Collections.Generic.List[string]]::new()
    $header = for ($c = 0; $c -lt $Columns.Count; $c++) { Format-MbcPad (Limit-MbcText $Columns[$c].Name $widths[$c] $Glyphs.Ellipsis) $widths[$c] }
    $out.Add('  ' + (Format-MbcStyle (($header -join (' ' * $gap)).TrimEnd()) 'dim' $Color))

    $visible = [Math]::Max(0, $Height - 1)
    for ($r = $Offset; $r -lt [Math]::Min($Rows.Count, $Offset + $visible); $r++) {
        $cells = for ($c = 0; $c -lt $Columns.Count; $c++) {
            $cell = $Rows[$r].Cells[$c]
            $plain = Format-MbcPad (Limit-MbcText ([string]$cell.Text) $widths[$c] $Glyphs.Ellipsis) $widths[$c]
            if ($r -eq $Selected) { $plain } else { Format-MbcStyle $plain ([string]$cell.Style) $Color }
        }
        $line = ($cells -join (' ' * $gap)).TrimEnd()
        if ($r -eq $Selected) { $line = Format-MbcStyle (Format-MbcPad $line ($Width - 2)) 'reverse' $Color }
        $out.Add('  ' + $line)
    }
    return , $out.ToArray()
}

function Format-MbcFooter {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object[]] $Keys, [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    $pairs = @($Keys | ForEach-Object { , @((ConvertTo-MbcGlyphText $_[0] $Glyphs), $_[1]) })
    for ($n = $pairs.Count; $n -ge 1; $n--) {
        $plain = '  ' + ((@($pairs[0..($n - 1)]) | ForEach-Object { "$($_[0]) $($_[1])" }) -join '   ')
        if ($plain.Length -le $Width) {
            return '  ' + ((@($pairs[0..($n - 1)]) | ForEach-Object { (Format-MbcStyle $_[0] 'accent' $Color) + ' ' + (Format-MbcStyle $_[1] 'dim' $Color) }) -join '   ')
        }
    }
    return ''
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Widgets.Tests.ps1 -Output Detailed`
Expected: PASS: 2 style tests, 4 bar rows plus 2 progress tests plus 3 verdict rows, and 5 layout tests.

- [ ] **Step 6: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Tui/Terminal.ps1 src/Tui/Widgets.ps1 tests/Widgets.Tests.ps1
git commit -m "feat: TUI primitives: styles, glyphs, progress bar, spinner, box, menu, table, footer" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 17: TUI screens, key map and navigation (pure), plus snapshots

**Files:**
- Create: `src/Tui/Screens.ps1`, `tools/Export-TuiSnapshots.ps1`
- Create: `docs/tui-snapshots/*.txt` (generated by the tool)
- Test: `tests/Screens.Tests.ps1`

**Interfaces:**
- Consumes: Task 16's widgets; `Mbc.Baseline` (Task 6); `Mbc.CheckResult` and `Get-MbcCounts` (Task 8); `Format-MbcShortValue` (Task 15); and `$script:MbcToolVersion` (Task 1).
- Produces:
  - `New-MbcTuiState [-OutputRoot <string>]` → a `hashtable`. Keys:
    - navigation: `Screen`, `MenuIndex`, `SubIndex`, `Help`, `Quit`, `Message`, `MessageStyle`;
    - context: `Connection`, `Baseline`, `AllowUnsealed`, `ExpectedFingerprint`, `OutputRoot`;
    - runs: `Run` (a hashtable `{ Results; Counts; Document; Baseline; FromFile; Source }`) and `Live` (a hashtable `{ Done; Total; Request; Tick; Lines }`);
    - results: `ResultIndex`, `ResultOffset`, `Filter` (`'all'|'fail'|'error'`), `Search`, `Detail`;
    - choosers and panels: `Files`, `ChooserIndex`, `ChooserPurpose`, `ChooserTitle`, `Panel`, `PanelReturn`, `Prompt`.
  - `$script:MbcHomeMenu` and `$script:MbcBuildMenu`, arrays of `{ Label; Key; Action }`.
  - `$script:MbcScreenKeys`, a hashtable of screen to `@(@(key, label), ...)`.
  - `Resolve-MbcKeyAction -State -Key` → an action string. `Key` is `{ Name ('UpArrow'|'DownArrow'|'Enter'|'Escape'|'Backspace'|'PageUp'|'PageDown'|'Home'|'End'|'Char'|'Other'); Char }`.
  - `Invoke-MbcTuiNavigation -State -Action -Cap` → an effect string for the runtime, or `$null` when handled in place. Effects: `run chooseBaseline lastResults openLocked build signIn quit sealFile captureDraft newKey export search choose enterPath`.
  - `Get-MbcVisibleResults -Results -Filter -Search` → sorted `object[]`: Fail, then Error, then Pass; then severity high to info; then ID.
  - `Format-MbcFrame -State -Cap` → `string[]` of exactly `Cap.Height` lines, each no wider than `Cap.Width`.

- [ ] **Step 1: Write the failing tests** in `tests/Screens.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Key map and navigation' {
        BeforeEach { $script:S = New-MbcTuiState }
        It 'maps keys to actions on the home screen' {
            Resolve-MbcKeyAction -State $script:S -Key ([pscustomobject]@{ Name = 'DownArrow'; Char = $null }) | Should -Be 'down'
            Resolve-MbcKeyAction -State $script:S -Key ([pscustomobject]@{ Name = 'Char'; Char = [char]'j' }) | Should -Be 'down'
            Resolve-MbcKeyAction -State $script:S -Key ([pscustomobject]@{ Name = 'Char'; Char = [char]'r' }) | Should -Be 'run'
            Resolve-MbcKeyAction -State $script:S -Key ([pscustomobject]@{ Name = 'Char'; Char = [char]'?' }) | Should -Be 'help'
            Resolve-MbcKeyAction -State $script:S -Key ([pscustomobject]@{ Name = 'Char'; Char = [char]'q' }) | Should -Be 'quit'
        }
        It 'closes the help overlay on any key' {
            $script:S.Help = $true
            Resolve-MbcKeyAction -State $script:S -Key ([pscustomobject]@{ Name = 'Char'; Char = [char]'x' }) | Should -Be 'closeHelp'
        }
        It 'moves through the home menu, wrapping, and turns Enter into the item''s effect' {
            Invoke-MbcTuiNavigation -State $script:S -Action 'up' -Cap (New-MbcCapability) | Should -BeNullOrEmpty
            $script:S.MenuIndex | Should -Be ($script:MbcHomeMenu.Count - 1)
            Invoke-MbcTuiNavigation -State $script:S -Action 'select' -Cap (New-MbcCapability) | Should -Be 'quit'
        }
        It 'maps results keys to filters and effects' {
            $script:S.Screen = 'results'
            Resolve-MbcKeyAction -State $script:S -Key ([pscustomobject]@{ Name = 'Char'; Char = [char]'f' }) | Should -Be 'filterFail'
            Resolve-MbcKeyAction -State $script:S -Key ([pscustomobject]@{ Name = 'Char'; Char = [char]'x' }) | Should -Be 'export'
            Resolve-MbcKeyAction -State $script:S -Key ([pscustomobject]@{ Name = 'Char'; Char = [char]'/' }) | Should -Be 'search'
        }
    }

    Describe 'Result ordering' {
        It 'puts failures first, then errors, then passes, by severity then id' {
            $mk = { param($id, $v, $s) [pscustomobject]@{ Id = $id; Verdict = $v; Severity = $s; Title = $id } }
            $rs = @((& $mk 'B' 'Pass' 'high'), (& $mk 'C' 'Error' 'low'), (& $mk 'A' 'Fail' 'low'), (& $mk 'D' 'Fail' 'high'))
            (Get-MbcVisibleResults -Results $rs -Filter 'all' -Search '' | ForEach-Object Id) -join ',' | Should -Be 'D,A,C,B'
            (Get-MbcVisibleResults -Results $rs -Filter 'error' -Search '' | ForEach-Object Id) -join ',' | Should -Be 'C'
            (Get-MbcVisibleResults -Results $rs -Filter 'all' -Search 'd' | ForEach-Object Id) -join ',' | Should -Be 'D'
        }
    }

    Describe 'Frames' {
        BeforeAll {
            $script:B = Read-MbcBaseline -Path (Join-Path $script:ModuleRoot 'tests/fixtures/baseline-minimal.json')
            $script:Results = @(
                [pscustomobject]@{ Id = 'ORG-001'; Title = 'Users cannot register applications'; Severity = 'medium'; Why = 'Because.'; Request = '/policies/authorizationPolicy'; ApiVersion = 'v1.0'; Operator = 'equals'; Expected = $false; Actual = $true; HasActual = $true; Verdict = 'Fail'; Cause = $null; Detail = $null }
                [pscustomobject]@{ Id = 'CA-001'; Title = 'At least one Conditional Access policy is enabled'; Severity = 'high'; Why = ''; Request = '/identity/conditionalAccess/policies'; ApiVersion = 'v1.0'; Operator = 'countAtLeast'; Expected = 1L; Actual = $null; HasActual = $false; Verdict = 'Error'; Cause = 'permission missing'; Detail = 'HTTP 403' }
            )
        }
        It 'fills the screen exactly, at <W>x<H>, Unicode <U>' -ForEach @(
            @{ W = 60; H = 20; U = $true }, @{ W = 120; H = 40; U = $true }, @{ W = 60; H = 20; U = $false }
        ) {
            $cap = New-MbcCapability -Width $W -Height $H -Unicode $U
            foreach ($screen in 'home', 'build', 'results', 'detail', 'run', 'panel', 'chooser') {
                $s = New-MbcTuiState
                $s.Baseline = $script:B
                $s.Screen = $screen
                $s.Run = @{ Results = $script:Results; Counts = (Get-MbcCounts -Results $script:Results); Document = $null; Baseline = $script:B; FromFile = $false; Source = 'this run' }
                $s.Live = @{ Done = 1; Total = 2; Request = '/policies/authorizationPolicy'; Tick = 3; Lines = [System.Collections.Generic.List[object]]::new() }
                $s.Detail = $script:Results[0]
                $s.Panel = @('', '  A panel line.')
                $s.Files = @('first.json', 'second.json')
                $frame = Format-MbcFrame -State $s -Cap $cap
                $frame.Count | Should -Be $H -Because "$screen fills the screen"
                foreach ($line in $frame) { Measure-MbcWidth $line | Should -BeLessOrEqual $W -Because "$screen fits the width" }
            }
        }
        It 'shows the baseline identity in the header' {
            $s = New-MbcTuiState
            $s.Baseline = $script:B
            (Format-MbcFrame -State $s -Cap (New-MbcCapability)) -join "`n" | Should -Match ([regex]::Escape($script:B.Fingerprint))
        }
        It 'summarises results in words and lists failures first' {
            $s = New-MbcTuiState
            $s.Screen = 'results'
            $s.Run = @{ Results = $script:Results; Counts = (Get-MbcCounts -Results $script:Results); Document = $null; Baseline = $script:B; FromFile = $false; Source = 'this run' }
            $text = (Format-MbcFrame -State $s -Cap (New-MbcCapability -Width 100 -Height 24)) -join "`n"
            $text | Should -Match '0 met, 1 not, 1 unverifiable'
            $text.IndexOf('ORG-001') | Should -BeLessThan $text.IndexOf('CA-001')
        }
        It 'shows expected and actual on the detail screen' {
            $s = New-MbcTuiState
            $s.Screen = 'detail'
            $s.Detail = $script:Results[0]
            $text = (Format-MbcFrame -State $s -Cap (New-MbcCapability -Width 100 -Height 24)) -join "`n"
            $text | Should -Match 'Expected\s+false'
            $text | Should -Match 'Actual\s+true'
        }
        It 'always shows the keys for the current screen in the footer' {
            $s = New-MbcTuiState
            (Format-MbcFrame -State $s -Cap (New-MbcCapability -Width 100))[-1] | Should -Match 'quit'
        }
        It 'draws the help overlay listing this screen''s keys' {
            $s = New-MbcTuiState
            $s.Help = $true
            (Format-MbcFrame -State $s -Cap (New-MbcCapability -Width 100 -Height 30)) -join "`n" | Should -Match 'Keys on this screen'
        }
        It 'uses no non-ASCII characters in ASCII mode' {
            $s = New-MbcTuiState
            $s.Baseline = $script:B
            $text = (Format-MbcFrame -State $s -Cap (New-MbcCapability -Unicode $false)) -join "`n"
            $text | Should -Not -Match '[^\x00-\x7F]'
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Screens.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'New-MbcTuiState' is not recognized`.

- [ ] **Step 3: Implement** `src/Tui/Screens.ps1`

```powershell
$script:MbcHomeMenu = @(
    [pscustomobject]@{ Label = 'Run checks'; Key = 'r'; Action = 'run' }
    [pscustomobject]@{ Label = 'Choose a baseline…'; Key = 'b'; Action = 'chooseBaseline' }
    [pscustomobject]@{ Label = 'View last results'; Key = 'l'; Action = 'lastResults' }
    [pscustomobject]@{ Label = 'Open a locked result…'; Key = 'o'; Action = 'openLocked' }
    [pscustomobject]@{ Label = 'Build or seal a baseline…'; Key = 's'; Action = 'build' }
    [pscustomobject]@{ Label = 'Sign in / switch account'; Key = 'i'; Action = 'signIn' }
    [pscustomobject]@{ Label = 'Quit'; Key = 'q'; Action = 'quit' }
)

$script:MbcBuildMenu = @(
    [pscustomobject]@{ Label = 'Seal a baseline file…'; Key = 's'; Action = 'sealFile' }
    [pscustomobject]@{ Label = 'Draft a baseline from this tenant…'; Key = 'd'; Action = 'captureDraft' }
    [pscustomobject]@{ Label = 'Generate a team key'; Key = 'n'; Action = 'newKey' }
    [pscustomobject]@{ Label = 'Back'; Key = 'Esc'; Action = 'back' }
)

$script:MbcScreenKeys = @{
    home    = @(@('↑↓', 'move'), @('Enter', 'select'), @('r', 'run'), @('b', 'baseline'), @('?', 'help'), @('q', 'quit'))
    build   = @(@('↑↓', 'move'), @('Enter', 'select'), @('Esc', 'back'), @('?', 'help'))
    run     = @(@('Ctrl+C', 'abandon the run'))
    results = @(@('↑↓', 'move'), @('Enter', 'detail'), @('f', 'failures'), @('e', 'errors'), @('a', 'all'), @('/', 'filter'), @('x', 'export'), @('Esc', 'back'))
    detail  = @(@('↑↓', 'previous/next'), @('Esc', 'back'), @('q', 'quit'))
    chooser = @(@('↑↓', 'move'), @('Enter', 'open'), @('p', 'type a path'), @('Esc', 'back'))
    panel   = @(@('Enter', 'done'))
    prompt  = @(@('Enter', 'confirm'), @('Esc', 'cancel'))
}

$script:MbcKeyHelp = @{
    '↑↓'     = 'Move the selection (j and k work too)'
    'Enter'  = 'Choose, or open the selected row'
    'Esc'    = 'Go back'
    'r'      = 'Run the checks against the signed-in tenant'
    'b'      = 'Choose a baseline'
    'f'      = 'Show only failures'
    'e'      = 'Show only checks that could not be verified'
    'a'      = 'Show everything'
    '/'      = 'Filter by text'
    'x'      = 'Export the result (locked, if you give the team key)'
    'p'      = 'Type a path instead of choosing from the list'
    'q'      = 'Quit'
    '?'      = 'This help'
    'Ctrl+C' = 'Abandon the run'
}

$script:MbcSeverityRank = @{ high = 0; medium = 1; low = 2; info = 3 }
$script:MbcVerdictRank = @{ Fail = 0; Error = 1; Pass = 2 }

function New-MbcTuiState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string] $OutputRoot)
    return @{
        Screen = 'home'; MenuIndex = 0; SubIndex = 0; Help = $false; Quit = $false
        Message = ''; MessageStyle = 'dim'
        Connection = $null; Baseline = $null; AllowUnsealed = $false; ExpectedFingerprint = $null; OutputRoot = $OutputRoot
        Run = $null; Live = $null
        ResultIndex = 0; ResultOffset = 0; Filter = 'all'; Search = ''; Detail = $null
        Files = @(); ChooserIndex = 0; ChooserPurpose = $null; ChooserTitle = ''
        Panel = $null; PanelReturn = 'home'; Prompt = $null
    }
}

function Resolve-MbcKeyAction {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Key)
    if ($State.Help) { return 'closeHelp' }
    $ch = if ($null -ne $Key.Char) { [string]$Key.Char } else { '' }
    if ($ch -eq '?') { return 'help' }
    switch ($Key.Name) {
        'UpArrow' { return 'up' }
        'DownArrow' { return 'down' }
        'Enter' { return 'select' }
        'Escape' { return 'back' }
        'Backspace' { return 'back' }
        'PageUp' { return 'pageUp' }
        'PageDown' { return 'pageDown' }
        'Home' { return 'first' }
        'End' { return 'last' }
    }
    if ($Key.Name -ne 'Char') { return 'none' }
    if ($ch -ceq 'j') { return 'down' }
    if ($ch -ceq 'k') { return 'up' }
    $screen = $State.Screen
    if ($screen -eq 'home') {
        $item = $script:MbcHomeMenu | Where-Object { $_.Key -ceq $ch } | Select-Object -First 1
        if ($item) { return $item.Action }
        return 'none'
    }
    if ($screen -eq 'build') {
        $item = $script:MbcBuildMenu | Where-Object { $_.Key -ceq $ch } | Select-Object -First 1
        if ($item) { return $item.Action }
        if ($ch -ceq 'q') { return 'back' }
        return 'none'
    }
    if ($screen -eq 'results') {
        switch -CaseSensitive ($ch) {
            'f' { return 'filterFail' }
            'e' { return 'filterError' }
            'a' { return 'filterAll' }
            '/' { return 'search' }
            'x' { return 'export' }
            'r' { return 'run' }
            'q' { return 'quit' }
        }
        return 'none'
    }
    if ($screen -eq 'detail') { if ($ch -ceq 'q') { return 'quit' }; return 'none' }
    if ($screen -eq 'chooser') {
        if ($ch -ceq 'p') { return 'enterPath' }
        if ($ch -ceq 'q') { return 'back' }
        return 'none'
    }
    if ($screen -eq 'panel' -and $ch -ceq 'q') { return 'back' }
    return 'none'
}

function Get-MbcVisibleResults {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()][object[]] $Results = @(), [string] $Filter = 'all', [AllowEmptyString()][string] $Search = '')
    $list = @($Results)
    if ($Filter -eq 'fail') { $list = @($list | Where-Object Verdict -eq 'Fail') }
    elseif ($Filter -eq 'error') { $list = @($list | Where-Object Verdict -eq 'Error') }
    if ($Search) { $list = @($list | Where-Object { $_.Id -like "*$Search*" -or $_.Title -like "*$Search*" }) }
    $sorted = $list | Sort-Object { $script:MbcVerdictRank[[string]$_.Verdict] }, { $script:MbcSeverityRank[[string]$_.Severity] }, Id
    return , @($sorted)
}

function Get-MbcResultsPageSize {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] $Cap)
    return [Math]::Max(3, $Cap.Height - 4 - 2 - 5)
}

function Step-MbcMenuIndex {
    [CmdletBinding()]
    [OutputType([int])]
    param([int] $Index, [int] $Count, [string] $Action)
    if ($Count -le 0) { return 0 }
    if ($Action -eq 'up') { return (($Index - 1 + $Count) % $Count) }
    if ($Action -eq 'down') { return (($Index + 1) % $Count) }
    if ($Action -eq 'first') { return 0 }
    if ($Action -eq 'last') { return ($Count - 1) }
    return $Index
}

function Invoke-MbcTuiNavigation {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Action, [Parameter(Mandatory)] $Cap)
    if ($Action -eq 'help') { $State.Help = $true; return $null }
    if ($Action -eq 'closeHelp') { $State.Help = $false; return $null }
    if ($Action -eq 'quit') { return 'quit' }
    $moves = 'up', 'down', 'first', 'last', 'pageUp', 'pageDown'

    switch ($State.Screen) {
        'home' {
            if ($Action -in $moves) { $State.MenuIndex = Step-MbcMenuIndex $State.MenuIndex $script:MbcHomeMenu.Count $Action; return $null }
            if ($Action -eq 'select') { return $script:MbcHomeMenu[$State.MenuIndex].Action }
            if ($Action -eq 'back') { return $null }
            return $Action
        }
        'build' {
            if ($Action -in $moves) { $State.SubIndex = Step-MbcMenuIndex $State.SubIndex $script:MbcBuildMenu.Count $Action; return $null }
            $chosen = if ($Action -eq 'select') { $script:MbcBuildMenu[$State.SubIndex].Action } else { $Action }
            if ($chosen -eq 'back') { $State.Screen = 'home'; return $null }
            return $chosen
        }
        'results' {
            $all = if ($State.Run) { @($State.Run.Results) } else { @() }
            $visible = Get-MbcVisibleResults -Results $all -Filter $State.Filter -Search $State.Search
            $page = Get-MbcResultsPageSize -Cap $Cap
            $last = [Math]::Max(0, $visible.Count - 1)
            switch ($Action) {
                'up' { $State.ResultIndex = [Math]::Max(0, $State.ResultIndex - 1) }
                'down' { $State.ResultIndex = [Math]::Min($last, $State.ResultIndex + 1) }
                'pageUp' { $State.ResultIndex = [Math]::Max(0, $State.ResultIndex - $page) }
                'pageDown' { $State.ResultIndex = [Math]::Min($last, $State.ResultIndex + $page) }
                'first' { $State.ResultIndex = 0 }
                'last' { $State.ResultIndex = $last }
                'filterFail' { $State.Filter = 'fail'; $State.ResultIndex = 0 }
                'filterError' { $State.Filter = 'error'; $State.ResultIndex = 0 }
                'filterAll' { $State.Filter = 'all'; $State.Search = ''; $State.ResultIndex = 0 }
                'select' { if ($visible.Count -gt 0) { $State.Detail = $visible[$State.ResultIndex]; $State.Screen = 'detail' } }
                'back' { $State.Screen = 'home' }
                default { return $Action }
            }
            if ($State.ResultIndex -lt $State.ResultOffset) { $State.ResultOffset = $State.ResultIndex }
            if ($State.ResultIndex -ge $State.ResultOffset + $page) { $State.ResultOffset = $State.ResultIndex - $page + 1 }
            return $null
        }
        'detail' {
            $all = if ($State.Run) { @($State.Run.Results) } else { @() }
            $visible = Get-MbcVisibleResults -Results $all -Filter $State.Filter -Search $State.Search
            if ($Action -in 'up', 'down' -and $visible.Count -gt 0) {
                $delta = if ($Action -eq 'up') { -1 } else { 1 }
                $State.ResultIndex = [Math]::Min([Math]::Max(0, $State.ResultIndex + $delta), $visible.Count - 1)
                $State.Detail = $visible[$State.ResultIndex]
                return $null
            }
            if ($Action -in 'back', 'select') { $State.Screen = 'results' }
            return $null
        }
        'chooser' {
            if ($Action -in $moves) { $State.ChooserIndex = Step-MbcMenuIndex $State.ChooserIndex @($State.Files).Count $Action; return $null }
            if ($Action -eq 'select') { if (@($State.Files).Count -gt 0) { return 'choose' } else { return 'enterPath' } }
            if ($Action -eq 'back') { $State.Screen = 'home'; return $null }
            return $Action
        }
        'panel' {
            if ($Action -in 'select', 'back') { $State.Panel = $null; $State.Screen = $State.PanelReturn }
            return $null
        }
    }
    return $null
}

function Join-MbcColumns {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Left, [AllowEmptyString()][string] $Right, [int] $Width)
    $gap = $Width - (Measure-MbcWidth $Left) - (Measure-MbcWidth $Right)
    if ($gap -lt 1) { return $Left }
    return $Left + (' ' * $gap) + $Right
}

function Format-MbcHeader {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs)
    $c = $Cap.Color
    $inner = $Cap.Width - 4
    $tenant = if ($State.Connection) { [string]$State.Connection.Domain } else { 'not signed in' }
    $tenantNote = if ($State.Connection) { Format-MbcStyle "read-only verified $($Glyphs.Seal)" 'ok' $c } else { Format-MbcStyle 'sign in with i' 'dim' $c }
    $b = $State.Baseline
    $baselineText = if ($b) { '{0} {1} v{2} {1} {3}' -f $b.Name, $Glyphs.Dot, $b.Version, $b.Fingerprint } else { 'none chosen' }
    $baselineNote = if (-not $b) { Format-MbcStyle 'choose with b' 'dim' $c }
    elseif ($b.SealState -eq 'Sealed') { Format-MbcStyle "sealed $($Glyphs.Seal)" 'ok' $c }
    elseif ($b.SealState -eq 'Modified') { Format-MbcStyle "edited since v$($b.SealedVersion)" 'warn' $c }
    else { Format-MbcStyle 'not sealed' 'warn' $c }
    $room = { param($note) [Math]::Max(8, $inner - 10 - (Measure-MbcWidth $note) - 2) }
    $line1 = Join-MbcColumns ('Tenant    ' + (Limit-MbcText $tenant (& $room $tenantNote) $Glyphs.Ellipsis)) $tenantNote $inner
    $line2 = Join-MbcColumns ('Baseline  ' + (Limit-MbcText $baselineText (& $room $baselineNote) $Glyphs.Ellipsis)) $baselineNote $inner
    return (Format-MbcBox -Title 'M365 Baseline Check' -RightTitle "v$($script:MbcToolVersion)" -Lines @($line1, $line2) -Width $Cap.Width -Glyphs $Glyphs -Color $c)
}

function Format-MbcResultLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    $tag = Format-MbcVerdictTag -Verdict $Result.Verdict -Glyphs $Glyphs -Color $Color
    $id = Format-MbcPad (Limit-MbcText $Result.Id 10 $Glyphs.Ellipsis) 10
    $room = [Math]::Max(10, $Width - 2 - 7 - 2 - 10 - 2)
    $note = if ($Result.Verdict -eq 'Fail') {
        $got = if ($Result.HasActual) { Format-MbcShortValue -Value $Result.Actual -Width 30 } else { 'nothing' }
        'expected {0} {1} got {2}' -f (Format-MbcShortValue -Value $Result.Expected -Width 30), $Glyphs.Dot, $got
    }
    elseif ($Result.Verdict -eq 'Error') { [string]$Result.Cause }
    else { '' }
    $note = ConvertTo-MbcGlyphText $note $Glyphs
    if ($note) {
        $titleRoom = [Math]::Max(8, [int]($room * 0.55))
        $title = Limit-MbcText $Result.Title $titleRoom $Glyphs.Ellipsis
        $noteText = Limit-MbcText $note ($room - $title.Length - 2) $Glyphs.Ellipsis
        return "  $tag  $id  $title  $(Format-MbcStyle $noteText 'dim' $Color)"
    }
    return "  $tag  $id  $(Limit-MbcText $Result.Title $room $Glyphs.Ellipsis)"
}

function Format-MbcRunBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs, [int] $Height)
    $live = $State.Live
    $c = $Cap.Color
    $count = 'Checking {0} / {1}' -f $live.Done, $live.Total
    $barWidth = [Math]::Max(10, [int]($Cap.Width * 0.3))
    $bar = Format-MbcProgressBar -Done $live.Done -Total $live.Total -Width $barWidth -Glyphs $Glyphs -Color $c
    $spinner = Format-MbcStyle (Get-MbcSpinnerFrame -Tick $live.Tick -Glyphs $Glyphs) 'accent' $c
    $requestRoom = $Cap.Width - 2 - $count.Length - 2 - $barWidth - 2 - 2
    $request = Format-MbcStyle (Limit-MbcText ([string]$live.Request) $requestRoom $Glyphs.Ellipsis) 'dim' $c
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add('')
    $out.Add("  $count  $bar  $spinner $request")
    $out.Add('')
    $room = [Math]::Max(0, $Height - 3)
    $lines = @($live.Lines)
    $start = [Math]::Max(0, $lines.Count - $room)
    for ($i = $start; $i -lt $lines.Count; $i++) { $out.Add((Format-MbcResultLine -Result $lines[$i] -Width $Cap.Width -Glyphs $Glyphs -Color $c)) }
    return , $out.ToArray()
}

function Format-MbcResultsBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs, [int] $Height)
    $c = $Cap.Color
    if (-not $State.Run) { return , @('', '  No results yet. Press r to run the checks.') }
    $counts = $State.Run.Counts
    $summary = '  ' + (Format-MbcStyle "$($counts.Pass) met" 'ok' $c) + ', ' + (Format-MbcStyle "$($counts.Fail) not" 'bad' $c) + ', ' +
        (Format-MbcStyle "$($counts.Error) unverifiable" 'warn' $c) + (Format-MbcStyle "   from $($State.Run.Source)" 'dim' $c)
    $filterName = switch ($State.Filter) { 'fail' { 'failures' } 'error' { 'unverifiable' } default { 'everything' } }
    $showing = "  Showing $filterName" + $(if ($State.Search) { " matching '$($State.Search)'" } else { '' })
    $visible = Get-MbcVisibleResults -Results @($State.Run.Results) -Filter $State.Filter -Search $State.Search
    $columns = @(
        [pscustomobject]@{ Name = ''; Width = 7 }
        [pscustomobject]@{ Name = 'ID'; Width = 10 }
        [pscustomobject]@{ Name = 'Severity'; Width = 8 }
        [pscustomobject]@{ Name = 'Setting'; Width = 0 }
    )
    $rows = foreach ($r in $visible) {
        $style = switch ($r.Verdict) { 'Pass' { 'ok' } 'Fail' { 'bad' } default { 'warn' } }
        $tagText = switch ($r.Verdict) { 'Pass' { "$($Glyphs.Pass) PASS" } 'Fail' { "$($Glyphs.Fail) FAIL" } default { "$($Glyphs.Error) ERROR" } }
        [pscustomobject]@{ Cells = @(@{ Text = $tagText; Style = $style }, @{ Text = $r.Id; Style = 'none' }, @{ Text = $r.Severity; Style = 'dim' }, @{ Text = $r.Title; Style = 'none' }) }
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add('')
    $out.Add($summary)
    $out.Add((Format-MbcStyle $showing 'dim' $c))
    $out.Add('')
    if ($visible.Count -eq 0) { $out.Add('  Nothing matches. Press a to show everything.') }
    else {
        foreach ($line in (Format-MbcTable -Columns $columns -Rows @($rows) -Width $Cap.Width -Height ([Math]::Max(2, $Height - 4)) -Selected $State.ResultIndex -Offset $State.ResultOffset -Glyphs $Glyphs -Color $c)) { $out.Add($line) }
    }
    return , $out.ToArray()
}

function Split-MbcWrapped {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyString()][string] $Text, [int] $Width)
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($word in ($Text -split '\s+' | Where-Object { $_ })) {
        if ($word.Length -gt $Width) { $word = Limit-MbcText $word $Width }
        if ($current.Length -eq 0) { $current = $word }
        elseif ($current.Length + 1 + $word.Length -le $Width) { $current += " $word" }
        else { $lines.Add($current); $current = $word }
    }
    if ($current.Length -gt 0) { $lines.Add($current) }
    if ($lines.Count -eq 0) { $lines.Add('') }
    return , $lines.ToArray()
}

function Format-MbcDetailBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs, [int] $Height)
    $r = $State.Detail
    $c = $Cap.Color
    if (-not $r) { return , @('', '  Nothing selected.') }
    $valueWidth = $Cap.Width - 14
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add('')
    $out.Add("  $(Format-MbcVerdictTag -Verdict $r.Verdict -Glyphs $Glyphs -Color $c)  $(Format-MbcStyle $r.Id 'bold' $c)  $(Limit-MbcText $r.Title ($Cap.Width - 24) $Glyphs.Ellipsis)")
    $out.Add('')
    $field = {
        param($label, $text)
        $first = $true
        foreach ($piece in (Split-MbcWrapped -Text (ConvertTo-MbcGlyphText ([string]$text) $Glyphs) -Width $valueWidth)) {
            $prefix = if ($first) { Format-MbcStyle (Format-MbcPad $label 10) 'dim' $c } else { ' ' * 10 }
            $out.Add("  $prefix$piece")
            $first = $false
        }
    }
    if ($r.Why) { & $field 'Why' $r.Why }
    & $field 'Request' "GET $($r.ApiVersion) $($r.Request)"
    & $field 'Operator' $r.Operator
    & $field 'Expected' (Format-MbcShortValue -Value $r.Expected -Width 400)
    & $field 'Actual' $(if ($r.HasActual) { Format-MbcShortValue -Value $r.Actual -Width 400 } else { 'nothing was read' })
    if ($r.Verdict -eq 'Error') { & $field 'Cause' ("$($r.Cause)" + $(if ($r.Detail) { " ($($r.Detail))" } else { '' })) }
    return , $out.ToArray()
}

function Format-MbcChooserBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs)
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add('')
    $out.Add("  $(Format-MbcStyle $State.ChooserTitle 'bold' $Cap.Color)")
    $out.Add('')
    $files = @($State.Files)
    if ($files.Count -eq 0) { $out.Add('  Nothing here yet. Press p to type a path.') }
    else {
        $items = @($files | ForEach-Object { [pscustomobject]@{ Label = (Split-Path -Leaf $_); Key = ''; Action = 'choose' } })
        foreach ($line in (Format-MbcMenu -Items $items -Selected $State.ChooserIndex -Width $Cap.Width -Glyphs $Glyphs -Color $Cap.Color)) { $out.Add($line) }
    }
    return , $out.ToArray()
}

function Format-MbcPromptBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs)
    $p = $State.Prompt
    $shown = if ($p.Mask) { '•' * $p.Value.Length } else { $p.Value }
    if (-not $Glyphs.Unicode) { $shown = $shown.Replace('•', '*') }
    $shown = if ($shown.Length -gt $Cap.Width - 8) { $shown.Substring($shown.Length - ($Cap.Width - 8)) } else { $shown }
    return , @('', "  $(Format-MbcStyle $p.Title 'bold' $Cap.Color)", '', "  $(Limit-MbcText $p.Label ($Cap.Width - 4) $Glyphs.Ellipsis)", '', "  > $shown$(Format-MbcStyle $Glyphs.Cursor 'accent' $Cap.Color)")
}

function Format-MbcHelpOverlay {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs)
    $keys = $script:MbcScreenKeys[$State.Screen]
    if (-not $keys) { $keys = $script:MbcScreenKeys['home'] }
    $lines = foreach ($k in $keys) {
        $desc = if ($script:MbcKeyHelp.ContainsKey($k[0])) { $script:MbcKeyHelp[$k[0]] } else { $k[1] }
        (Format-MbcPad (ConvertTo-MbcGlyphText $k[0] $Glyphs) 8) + (Limit-MbcText $desc ($Cap.Width - 16) $Glyphs.Ellipsis)
    }
    $box = Format-MbcBox -Title 'Keys on this screen' -Lines @($lines) -Width ([Math]::Min($Cap.Width - 2, 72)) -Glyphs $Glyphs -Color $Cap.Color
    return , (@('') + @($box | ForEach-Object { "  $_" }))
}

function Get-MbcScreenBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs, [int] $Height)
    switch ($State.Screen) {
        'home' { return , (@('') + (Format-MbcMenu -Items $script:MbcHomeMenu -Selected $State.MenuIndex -Width $Cap.Width -Glyphs $Glyphs -Color $Cap.Color)) }
        'build' { return , (@('', "  $(Format-MbcStyle 'Build or seal a baseline' 'bold' $Cap.Color)", '') + (Format-MbcMenu -Items $script:MbcBuildMenu -Selected $State.SubIndex -Width $Cap.Width -Glyphs $Glyphs -Color $Cap.Color)) }
        'run' { return (Format-MbcRunBody -State $State -Cap $Cap -Glyphs $Glyphs -Height $Height) }
        'results' { return (Format-MbcResultsBody -State $State -Cap $Cap -Glyphs $Glyphs -Height $Height) }
        'detail' { return (Format-MbcDetailBody -State $State -Cap $Cap -Glyphs $Glyphs -Height $Height) }
        'chooser' { return (Format-MbcChooserBody -State $State -Cap $Cap -Glyphs $Glyphs) }
        'panel' { return , @($State.Panel) }
        'prompt' { return (Format-MbcPromptBody -State $State -Cap $Cap -Glyphs $Glyphs) }
    }
    return , @('')
}

function Format-MbcFrame {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap)
    $g = Get-MbcGlyphs -Unicode $Cap.Unicode
    $header = @(Format-MbcHeader -State $State -Cap $Cap -Glyphs $g)
    $keys = $script:MbcScreenKeys[$State.Screen]
    if (-not $keys) { $keys = $script:MbcScreenKeys['home'] }
    $footer = Format-MbcFooter -Keys $keys -Width $Cap.Width -Glyphs $g -Color $Cap.Color
    $message = if ($State.Message) { '  ' + (Format-MbcStyle (Limit-MbcText (ConvertTo-MbcGlyphText $State.Message $g) ($Cap.Width - 4) $g.Ellipsis) $State.MessageStyle $Cap.Color) } else { '' }
    $bodyHeight = [Math]::Max(1, $Cap.Height - $header.Count - 2)
    $body = if ($State.Help) { Format-MbcHelpOverlay -State $State -Cap $Cap -Glyphs $g } else { Get-MbcScreenBody -State $State -Cap $Cap -Glyphs $g -Height $bodyHeight }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($h in $header) { $lines.Add($h) }
    $shown = @($body | Select-Object -First $bodyHeight)
    foreach ($b in $shown) {
        # Anything a body produced that is still too wide is cut plainly rather than allowed to wrap.
        if ((Measure-MbcWidth $b) -gt $Cap.Width) { $b = Limit-MbcText ([regex]::Replace($b, $script:MbcAnsiPattern, '')) $Cap.Width $g.Ellipsis }
        $lines.Add($b)
    }
    for ($i = $shown.Count; $i -lt $bodyHeight; $i++) { $lines.Add('') }
    $lines.Add($message)
    $lines.Add($footer)
    while ($lines.Count -gt $Cap.Height) { $lines.RemoveAt($header.Count) }
    return , $lines.ToArray()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Screens.Tests.ps1 -Output Detailed`
Expected: PASS: 4 navigation tests, 1 ordering test, 3 fill rows and 6 frame tests.

- [ ] **Step 5: Write the snapshot tool** `tools/Export-TuiSnapshots.ps1`

```powershell
#Requires -Version 7.4
<#
.SYNOPSIS
    Renders each TUI screen to plain text under docs/tui-snapshots, for review without a console.
#>
[CmdletBinding()]
param([int] $Width = 80, [int] $Height = 24)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'M365BaselineCheck.psd1') -Force
$out = Join-Path $root 'docs/tui-snapshots'
New-Item -ItemType Directory -Path $out -Force | Out-Null

& (Get-Module M365BaselineCheck) {
    param($Out, $Width, $Height, $Root)
    $baseline = Read-MbcBaseline -Path (Join-Path $Root 'tests/fixtures/baseline-minimal.json')
    $results = @(
        [pscustomobject]@{ Id = 'ORG-001'; Title = 'Users cannot register applications'; Severity = 'medium'; Why = 'Registering an application is an administrative decision.'; Request = '/policies/authorizationPolicy'; ApiVersion = 'v1.0'; Operator = 'equals'; Expected = $false; Actual = $true; HasActual = $true; Verdict = 'Fail'; Cause = $null; Detail = $null }
        [pscustomobject]@{ Id = 'CA-001'; Title = 'At least one Conditional Access policy is enabled'; Severity = 'high'; Why = ''; Request = '/identity/conditionalAccess/policies'; ApiVersion = 'v1.0'; Operator = 'countAtLeast'; Expected = 1L; Actual = @('Block legacy authentication'); HasActual = $true; Verdict = 'Pass'; Cause = $null; Detail = $null }
        [pscustomobject]@{ Id = 'AUD-002'; Title = 'Audit log retention'; Severity = 'medium'; Why = ''; Request = '/security/auditLog'; ApiVersion = 'v1.0'; Operator = 'equals'; Expected = 'x'; Actual = $null; HasActual = $false; Verdict = 'Error'; Cause = 'permission missing'; Detail = 'HTTP 403' }
    )
    $connection = [pscustomobject]@{ Domain = 'example.onmicrosoft.com' }
    $scenes = [ordered]@{
        home    = { param($s) }
        help    = { param($s) $s.Help = $true }
        run     = { param($s) $s.Screen = 'run'; $s.Live = @{ Done = 1; Total = 2; Request = '/identity/conditionalAccess/policies'; Tick = 4; Lines = [System.Collections.Generic.List[object]]::new(@($results[0])) } }
        results = { param($s) $s.Screen = 'results' }
        detail  = { param($s) $s.Screen = 'detail'; $s.Detail = $results[0] }
        build   = { param($s) $s.Screen = 'build' }
    }
    foreach ($unicode in $true, $false) {
        foreach ($name in $scenes.Keys) {
            $state = New-MbcTuiState
            $state.Baseline = $baseline
            $state.Connection = $connection
            $state.Run = @{ Results = $results; Counts = (Get-MbcCounts -Results $results); Document = $null; Baseline = $baseline; FromFile = $false; Source = 'this run' }
            & $scenes[$name] $state
            $frame = Format-MbcFrame -State $state -Cap (New-MbcCapability -Width $Width -Height $Height -Unicode $unicode)
            $file = Join-Path $Out ('{0}-{1}.txt' -f $name, $(if ($unicode) { 'unicode' } else { 'ascii' }))
            [System.IO.File]::WriteAllText($file, (($frame -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
        }
    }
} $out $Width $Height $root
Write-Output "Snapshots written to $out"
```

- [ ] **Step 6: Generate the snapshots, and read them yourself**

Run: `pwsh -NoProfile -File tools/Export-TuiSnapshots.ps1`
Expected: 12 files in `docs/tui-snapshots/`.

Open `home-unicode.txt`, `results-unicode.txt` and `detail-unicode.txt`, and check them against the spec's mock-ups (§10): header box, menu with the pointer and hotkeys, summary line, failures first, and the footer. Fix anything that reads badly, then regenerate.

- [ ] **Step 7: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Tui/Screens.ps1 tools/Export-TuiSnapshots.ps1 docs/tui-snapshots tests/Screens.Tests.ps1
git commit -m "feat: TUI screens, key map and navigation as pure functions, with snapshots" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 18: The TUI runtime and `Start-BaselineCheck`

**Files:**
- Create: `src/Tui/Runtime.ps1`, `src/Public/Start-BaselineCheck.ps1`
- Modify: `src/Report/Result.ps1`, adding `ConvertFrom-MbcResultDocument`
- Test: `tests/Runtime.Tests.ps1`

**Interfaces:**
- Consumes: everything above, including `Open-MbcLockedResult` (Task 14), `New-MbcBackgroundInvoke` (Task 10) and `Connect-MbcGraph` (Task 11).
- Produces:
  - `ConvertFrom-MbcResultDocument -Document` → `{ Results (Mbc.CheckResult-shaped); Counts }`.
  - `ConvertTo-MbcKey -KeyInfo <ConsoleKeyInfo>` → `{ Name; Char }`.
  - `Read-MbcKey [-TimeoutMs]`, `Enter-MbcScreen`, `Exit-MbcScreen` and `Write-MbcFrame -Lines`. These are console I/O and are not unit-tested.
  - `Read-MbcLine -State -Title -Label [-Mask]` → the text, or `$null` on Esc.
  - `Invoke-MbcTuiEffect -State -Effect`, which dispatches the effects from Task 17.
  - `Start-BaselineCheck [-Baseline] [-OutputRoot] [-AllowUnsealed] [-ExpectedFingerprint]`, public.

- [ ] **Step 1: Write the failing tests** in `tests/Runtime.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Keys and documents' {
        It 'turns console keys into named keys and characters' {
            (ConvertTo-MbcKey -KeyInfo ([ConsoleKeyInfo]::new([char]0, [ConsoleKey]::UpArrow, $false, $false, $false))).Name | Should -Be 'UpArrow'
            $j = ConvertTo-MbcKey -KeyInfo ([ConsoleKeyInfo]::new([char]'j', [ConsoleKey]::J, $false, $false, $false))
            $j.Name | Should -Be 'Char'
            $j.Char | Should -Be ([char]'j')
        }
        It 'rebuilds result rows from a result document' {
            $b = Read-MbcBaseline -Path (Join-Path $script:ModuleRoot 'tests/fixtures/baseline-minimal.json')
            $fetch = { param($ApiVersion, $Request) New-MbcFetchResult -Ok $false -Status 403 -Cause 'permission missing' }
            $doc = New-MbcResultDocument -Run (Invoke-MbcRun -Baseline $b -Fetch $fetch) -Baseline $b -Connection $null
            $back = ConvertFrom-MbcResultDocument -Document $doc
            $back.Results.Count | Should -Be 2
            $back.Results[0].Verdict | Should -Be 'Error'
            $back.Counts.Error | Should -Be 2
        }
    }

    Describe 'Effects' {
        BeforeEach {
            Mock Write-MbcFrame { }
            Mock Enter-MbcScreen { }
            Mock Exit-MbcScreen { }
            $script:S = New-MbcTuiState -OutputRoot $TestDrive
        }
        It 'asks for a baseline before running' {
            Invoke-MbcTuiEffect -State $script:S -Effect 'run'
            $script:S.Message | Should -Match 'Choose a baseline first'
            $script:S.Screen | Should -Be 'home'
        }
        It 'says there are no results yet' {
            Invoke-MbcTuiEffect -State $script:S -Effect 'lastResults'
            $script:S.Message | Should -Match 'No results yet'
        }
        It 'shows a new team key once, on a panel' {
            Invoke-MbcTuiEffect -State $script:S -Effect 'newKey'
            $script:S.Screen | Should -Be 'panel'
            ($script:S.Panel -join "`n") | Should -Match 'mbc-key:1:[0-9a-f]{8}:'
        }
        It 'will not re-export a result that was opened from a file' {
            $script:S.Run = @{ Results = @(); Counts = $null; Document = @{}; Baseline = $null; FromFile = $true; Source = 'x.locked' }
            Invoke-MbcTuiEffect -State $script:S -Effect 'export'
            $script:S.Message | Should -Match 'already filed'
        }
        It 'exports locked with the session key' {
            Mock Export-MbcRunFiles { [pscustomobject]@{ Json = $null; Csv = $null; Summary = 'summary-x.md'; Locked = 'result-x.locked' } }
            $script:MbcSessionKey = New-MbcTeamKeyText
            try {
                $script:S.Run = @{ Results = @(); Counts = $null; Document = @{}; Baseline = [pscustomobject]@{ Name = 'B' }; FromFile = $false; Source = 'this run' }
                Invoke-MbcTuiEffect -State $script:S -Effect 'export'
                Should -Invoke Export-MbcRunFiles -Times 1 -Exactly -ParameterFilter { $KeyText -eq $script:MbcSessionKey }
                $script:S.Message | Should -Match 'result-x.locked'
            }
            finally { $script:MbcSessionKey = $null }
        }
        It 'quits' {
            Invoke-MbcTuiEffect -State $script:S -Effect 'quit'
            $script:S.Quit | Should -BeTrue
        }
    }

    Describe 'Start-BaselineCheck outside an interactive console' {
        BeforeEach { Mock Get-MbcTerminalCapability { New-MbcCapability -Interactive $false } }
        It 'runs in plain mode when given a baseline' {
            Mock Invoke-BaselineCheck { 'plain run' }
            Start-BaselineCheck -Baseline 'x.json' -WarningAction SilentlyContinue | Should -Be 'plain run'
        }
        It 'explains itself when there is nothing to run' {
            { Start-BaselineCheck } | Should -Throw "*can't host the interactive view*"
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester ./tests/Runtime.Tests.ps1 -Output Detailed`
Expected: FAIL with `The term 'ConvertTo-MbcKey' is not recognized`.

- [ ] **Step 3: Add `ConvertFrom-MbcResultDocument`** to `src/Report/Result.ps1`

```powershell
function ConvertFrom-MbcResultDocument {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    $results = foreach ($r in $Document['results']) {
        [pscustomobject]@{
            PSTypeName = 'Mbc.CheckResult'
            Id = [string]$r['id']; Title = [string]$r['title']; Severity = [string]$r['severity']; Why = ''
            Request = [string]$r['request']; ApiVersion = [string]$r['apiVersion']; Operator = [string]$r['operator']
            Expected = $r['expected']; Actual = $r['actual']; HasActual = [bool]$r['hasActual']
            Verdict = [string]$r['verdict']; Cause = $r['cause']; Detail = $r['detail']
        }
    }
    $results = @($results)
    return [pscustomobject]@{ Results = $results; Counts = (Get-MbcCounts -Results $results) }
}
```

- [ ] **Step 4: Implement** `src/Tui/Runtime.ps1`

```powershell
function Enter-MbcScreen {
    [CmdletBinding()]
    param()
    [Console]::Write("`e[?1049h`e[?25l")
}

function Exit-MbcScreen {
    [CmdletBinding()]
    param()
    [Console]::Write("`e[0m`e[?25h`e[?1049l")
}

function Write-MbcFrame {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Lines)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("`e[H")
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        [void]$sb.Append($Lines[$i]).Append("`e[0m`e[K")
        if ($i -lt $Lines.Count - 1) { [void]$sb.Append("`n") }
    }
    [void]$sb.Append("`e[J")
    [Console]::Write($sb.ToString())
}

function ConvertTo-MbcKey {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.ConsoleKeyInfo] $KeyInfo)
    $named = 'UpArrow', 'DownArrow', 'Enter', 'Escape', 'Backspace', 'PageUp', 'PageDown', 'Home', 'End', 'Tab'
    $name = [string]$KeyInfo.Key
    if ($name -in $named) { return [pscustomobject]@{ Name = $name; Char = $null } }
    if ($KeyInfo.KeyChar -eq [char]0 -or [char]::IsControl($KeyInfo.KeyChar)) { return [pscustomobject]@{ Name = 'Other'; Char = $null } }
    return [pscustomobject]@{ Name = 'Char'; Char = $KeyInfo.KeyChar }
}

function Read-MbcKey {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int] $TimeoutMs = 0)
    $width = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ([Console]::KeyAvailable) { return (ConvertTo-MbcKey -KeyInfo ([Console]::ReadKey($true))) }
        if ([Console]::WindowWidth -ne $width -or [Console]::WindowHeight -ne $height) { return [pscustomobject]@{ Name = 'Resize'; Char = $null } }
        if ($TimeoutMs -gt 0 -and $clock.ElapsedMilliseconds -ge $TimeoutMs) { return [pscustomobject]@{ Name = 'Tick'; Char = $null } }
        Start-Sleep -Milliseconds 30
    }
}

function Update-MbcTuiView {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)
    Write-MbcFrame -Lines (Format-MbcFrame -State $State -Cap (Get-MbcTerminalCapability))
}

function Set-MbcTuiMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][AllowEmptyString()][string] $Text, [string] $Style = 'dim')
    $State.Message = $Text
    $State.MessageStyle = $Style
}

function Read-MbcLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Title, [Parameter(Mandatory)][string] $Label, [switch] $Mask, [string] $Initial = '')
    $returnTo = $State.Screen
    $State.Prompt = @{ Title = $Title; Label = $Label; Mask = [bool]$Mask; Value = $Initial }
    $State.Screen = 'prompt'
    try {
        while ($true) {
            Update-MbcTuiView -State $State
            $key = Read-MbcKey
            if ($key.Name -eq 'Enter') { return [string]$State.Prompt.Value }
            if ($key.Name -eq 'Escape') { return $null }
            if ($key.Name -eq 'Backspace' -and $State.Prompt.Value.Length -gt 0) { $State.Prompt.Value = $State.Prompt.Value.Substring(0, $State.Prompt.Value.Length - 1) }
            if ($key.Name -eq 'Char') { $State.Prompt.Value += [string]$key.Char }
        }
    }
    finally {
        $State.Prompt = $null
        $State.Screen = $returnTo
    }
}

function Invoke-MbcTuiOutside {
    # Leaves the alternate screen for anything that talks to the operator itself (browser sign-in, a draft
    # capture's messages), then comes back.
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock] $Action, [switch] $Pause)
    Exit-MbcScreen
    try { & $Action }
    finally {
        if ($Pause) { [Console]::Write("`nPress Enter to return. "); [void][Console]::ReadLine() }
        Enter-MbcScreen
    }
}

function Set-MbcTuiBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Path)
    try {
        $State.Baseline = Read-MbcBaseline -Path $Path
        $b = $State.Baseline
        $note = switch ($b.SealState) { 'Sealed' { 'sealed' } 'Unsealed' { 'not sealed' } default { "edited since v$($b.SealedVersion) was sealed" } }
        Set-MbcTuiMessage -State $State -Text ('Chose {0} v{1} · {2}, {3}.' -f $b.Name, $b.Version, $b.Fingerprint, $note) -Style $(if ($b.SealState -eq 'Sealed') { 'ok' } else { 'warn' })
    }
    catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad' }
}

function Invoke-MbcTuiSignIn {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)
    if (-not $State.Baseline) { Set-MbcTuiMessage -State $State -Text 'Choose a baseline first: sign-in asks for exactly the scopes it needs.' -Style 'warn'; return }
    $scopes = [string[]]@($State.Baseline.Document['preset']['scopes'])
    $script:MbcTuiSignInError = $null
    Invoke-MbcTuiOutside -Action {
        try { $script:MbcTuiConnection = Connect-MbcGraph -Scopes $scopes }
        catch { $script:MbcTuiSignInError = $_.Exception.Message; $script:MbcTuiConnection = $null }
    }
    if ($script:MbcTuiSignInError) { Set-MbcTuiMessage -State $State -Text $script:MbcTuiSignInError -Style 'bad'; return }
    $State.Connection = $script:MbcTuiConnection
    Set-MbcTuiMessage -State $State -Text "Signed in to $($State.Connection.Domain), read-only." -Style 'ok'
}

function Update-MbcTuiRunFrame {
    [CmdletBinding()]
    param()
    $s = $script:MbcTuiState
    $s.Live.Tick++
    Update-MbcTuiView -State $s
}

function Invoke-MbcTuiRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)
    if (-not $State.Baseline) { Set-MbcTuiMessage -State $State -Text 'Choose a baseline first: press b.' -Style 'warn'; return }
    try { Assert-MbcBaselineUsable -Baseline $State.Baseline -AllowUnsealed:$State.AllowUnsealed -ExpectedFingerprint $State.ExpectedFingerprint }
    catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad'; return }
    if (-not $State.Connection) { Invoke-MbcTuiSignIn -State $State }
    if (-not $State.Connection) { return }

    $b = $State.Baseline
    $runId = New-MbcRunId
    $script:MbcTuiState = $State
    $script:MbcTuiLog = New-MbcRunLog -Directory (Join-Path $State.OutputRoot 'logs') -RunId $runId -Baseline $b.Fingerprint
    Write-MbcLog -Log $script:MbcTuiLog -Event 'run.start' -Data @{ tool = $script:MbcToolVersion; baseline = [ordered]@{ name = $b.Name; version = $b.Version; digest = $b.Digest; sealState = $b.SealState } }
    # The spinner turns while a request blocks by running each request in a background runspace. The
    # Graph SDK keeps its sign-in in process-wide state, which that runspace should see; if it turns out
    # not to, fall back to calling in-process (the spinner then advances between requests only), and
    # say so in the log.
    $script:MbcTuiBackground = New-MbcBackgroundInvoke -OnTick { param($t) Update-MbcTuiRunFrame }
    $script:MbcTuiBackgroundBroken = $false
    $script:MbcTuiInvoke = {
        param($Uri)
        if (-not $script:MbcTuiBackgroundBroken) {
            try { return (& $script:MbcTuiBackground $Uri) }
            catch {
                if ($_.Exception.Message -notmatch 'Connect-MgGraph|Authentication needed|not connected|No application') { throw }
                $script:MbcTuiBackgroundBroken = $true
                Write-MbcLog -Log $script:MbcTuiLog -Event 'tui.background-fallback' -Data @{ reason = $_.Exception.Message }
            }
        }
        & ([scriptblock]::Create($script:MbcGraphTransportText)) $Uri
    }
    $State.Live = @{ Done = 0; Total = @(Get-MbcRequestPlan -Preset $b.Document['preset']).Count; Request = ''; Tick = 0; Lines = [System.Collections.Generic.List[object]]::new() }
    $State.Screen = 'run'
    Set-MbcTuiMessage -State $State -Text '' -Style 'dim'
    Update-MbcTuiView -State $State

    $fetch = { param($ApiVersion, $Request) Invoke-MbcGraphGet -ApiVersion $ApiVersion -Request $Request -Invoke $script:MbcTuiInvoke -Log $script:MbcTuiLog }
    $onProgress = {
        param($e)
        if ($e.Phase -eq 'start') { $script:MbcTuiState.Live.Request = $e.Request } else { $script:MbcTuiState.Live.Done = $e.Index }
        Update-MbcTuiRunFrame
    }
    $onResult = {
        param($r)
        $script:MbcTuiState.Live.Lines.Add($r)
        Write-MbcLog -Log $script:MbcTuiLog -Event 'check' -Data @{ id = $r.Id; verdict = $r.Verdict; cause = $r.Cause; operator = $r.Operator; expected = $r.Expected; actual = $r.Actual; hasActual = $r.HasActual }
        Update-MbcTuiRunFrame
    }
    try {
        $run = Invoke-MbcRun -Baseline $b -Fetch $fetch -OnProgress $onProgress -OnResult $onResult -RunId $runId
        $doc = New-MbcResultDocument -Run $run -Baseline $b -Connection $State.Connection
        Write-MbcLog -Log $script:MbcTuiLog -Event 'run.end' -Data @{ pass = $run.Counts.Pass; fail = $run.Counts.Fail; error = $run.Counts.Error; resultDigest = $doc['seal']['digest'] }
        $State.Run = @{ Results = $run.Results; Counts = $run.Counts; Document = $doc; Baseline = $b; FromFile = $false; Source = 'this run' }
        $State.Filter = 'all'; $State.Search = ''; $State.ResultIndex = 0; $State.ResultOffset = 0
        $State.Screen = 'results'
        Set-MbcTuiMessage -State $State -Text ('Done. {0} met, {1} not, {2} unverifiable. Press x to export.' -f $run.Counts.Pass, $run.Counts.Fail, $run.Counts.Error) -Style 'ok'
    }
    catch {
        $State.Screen = 'home'
        Set-MbcTuiMessage -State $State -Text "The run stopped: $($_.Exception.Message)" -Style 'bad'
    }
}

function Test-MbcLooksLikeBaseline {
    # Offered in the chooser only if it parses and carries both a preset and expected values. A preset,
    # a result or any unrelated JSON in the folder is left out rather than failing on selection.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)
    try {
        $doc = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText($Path))
        return ((Test-MbcIsDictionary $doc) -and $doc.Contains('preset') -and $doc.Contains('expected'))
    }
    catch { return $false }
}

function Show-MbcTuiChooser {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Title, [Parameter(Mandatory)][string] $Purpose, [AllowEmptyCollection()][string[]] $Files = @())
    $State.Files = @($Files)
    $State.ChooserIndex = 0
    $State.ChooserTitle = $Title
    $State.ChooserPurpose = $Purpose
    $State.Screen = 'chooser'
}

function Open-MbcTuiLocked {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Path)
    $keyText = $script:MbcSessionKey
    if (-not $keyText) {
        $keyText = Read-MbcLine -State $State -Title 'Open a locked result' -Label 'Team key (it stays in memory for this session only)' -Mask
        if (-not $keyText) { return }
    }
    try {
        $opened = Open-MbcLockedResult -Path $Path -KeyText $keyText
        $script:MbcSessionKey = $keyText
        $rows = ConvertFrom-MbcResultDocument -Document $opened.Result
        $State.Run = @{ Results = $rows.Results; Counts = $rows.Counts; Document = $opened.Result; Baseline = $null; FromFile = $true; Source = (Split-Path -Leaf $Path) }
        $State.Filter = 'all'; $State.Search = ''; $State.ResultIndex = 0; $State.ResultOffset = 0
        $State.Screen = 'results'
        Set-MbcTuiMessage -State $State -Text "Opened $(Split-Path -Leaf $Path) with key $($opened.KeyId). It stays in memory." -Style 'ok'
    }
    catch {
        $State.Screen = 'home'
        Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad'
    }
}

function Invoke-MbcTuiExport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)
    if (-not $State.Run) { Set-MbcTuiMessage -State $State -Text 'Nothing to export yet: run the checks first.' -Style 'warn'; return }
    if ($State.Run.FromFile) { Set-MbcTuiMessage -State $State -Text 'This result came from a file, so it is already filed.' -Style 'dim'; return }
    $keyText = $script:MbcSessionKey
    if (-not $keyText) {
        $entered = Read-MbcLine -State $State -Title 'Export' -Label 'Team key, to lock it. Leave it empty to write plaintext.' -Mask
        if ($null -eq $entered) { return }
        if ($entered) {
            try { [void](ConvertFrom-MbcTeamKeyText -Text $entered) }
            catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad'; return }
            $keyText = $entered
            $script:MbcSessionKey = $entered
        }
        else {
            $confirm = Read-MbcLine -State $State -Title 'Export' -Label 'Write the result as plaintext? Type yes to confirm.'
            if ($confirm -ne 'yes') { Set-MbcTuiMessage -State $State -Text 'Not exported.' -Style 'dim'; return }
        }
    }
    try {
        $files = Export-MbcRunFiles -Document $State.Run.Document -Baseline $State.Run.Baseline -Directory (Join-Path $State.OutputRoot 'results') -KeyText $keyText
        $names = @($files.Locked, $files.Json, $files.Csv, $files.Summary | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
        Set-MbcTuiMessage -State $State -Text "Exported: $names" -Style 'ok'
    }
    catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad' }
}

function Invoke-MbcTuiEffect {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Effect)
    switch ($Effect) {
        'quit' { $State.Quit = $true }
        'run' { Invoke-MbcTuiRun -State $State }
        'signIn' { Invoke-MbcTuiSignIn -State $State }
        'lastResults' {
            if ($State.Run) { $State.Screen = 'results' }
            else { Set-MbcTuiMessage -State $State -Text 'No results yet: press r to run the checks.' -Style 'warn' }
        }
        'build' { $State.SubIndex = 0; $State.Screen = 'build' }
        'chooseBaseline' {
            $dirs = @((Join-Path $State.OutputRoot 'baselines'), (Get-Location).Path, (Join-Path $script:ModuleRoot 'presets'))
            $files = @($dirs | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter '*.json' -File } |
                    Where-Object { Test-MbcLooksLikeBaseline -Path $_.FullName } | ForEach-Object FullName | Select-Object -Unique)
            Show-MbcTuiChooser -State $State -Title 'Choose a baseline' -Purpose 'baseline' -Files $files
        }
        'openLocked' {
            $files = @(Get-ChildItem -LiteralPath (Join-Path $State.OutputRoot 'results') -Filter '*.locked' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object FullName)
            Show-MbcTuiChooser -State $State -Title 'Open a locked result' -Purpose 'locked' -Files $files
        }
        'choose' {
            $path = @($State.Files)[$State.ChooserIndex]
            if ($State.ChooserPurpose -eq 'baseline') { Set-MbcTuiBaseline -State $State -Path $path; $State.Screen = 'home' }
            else { Open-MbcTuiLocked -State $State -Path $path }
        }
        'enterPath' {
            $path = Read-MbcLine -State $State -Title $State.ChooserTitle -Label 'Path to the file'
            if (-not $path) { return }
            if ($State.ChooserPurpose -eq 'baseline') { Set-MbcTuiBaseline -State $State -Path $path; $State.Screen = 'home' }
            else { Open-MbcTuiLocked -State $State -Path $path }
        }
        'sealFile' {
            $initial = if ($State.Baseline) { $State.Baseline.Path } else { '' }
            $path = Read-MbcLine -State $State -Title 'Seal a baseline' -Label 'Path to the baseline' -Initial $initial
            if (-not $path) { return }
            try {
                $id = Protect-Baseline -Path $path -InformationAction SilentlyContinue
                Set-MbcTuiMessage -State $State -Text ('Sealed. {0} is v{1}; its fingerprint is {2}. Record it wherever you keep these.' -f $id.Name, $id.Version, $id.Fingerprint) -Style 'ok'
                if ($State.Baseline -and $State.Baseline.Path -eq $id.Path) { $State.Baseline = Read-MbcBaseline -Path $id.Path }
            }
            catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad' }
        }
        'captureDraft' {
            $preset = Read-MbcLine -State $State -Title 'Draft a baseline' -Label 'Path to the preset'
            if (-not $preset) { return }
            $output = Read-MbcLine -State $State -Title 'Draft a baseline' -Label 'Where to write the draft'
            if (-not $output) { return }
            Invoke-MbcTuiOutside -Pause -Action {
                try { New-BaselineCapture -PresetPath $preset -OutputPath $output }
                catch { [Console]::WriteLine($_.Exception.Message) }
            }
        }
        'newKey' {
            $text = New-MbcTeamKeyText
            $id = ($text -split ':')[2]
            $State.Panel = @(
                '', '  Your new team key:', '', "  $text", '',
                "  Store it in one entry in your team's password manager, named",
                "  'M365 Baseline Check · results key $id'.", '',
                "  It won't be shown again, and nothing has been saved to disk."
            )
            $State.PanelReturn = 'build'
            $State.Screen = 'panel'
        }
        'export' { Invoke-MbcTuiExport -State $State }
        'search' {
            $text = Read-MbcLine -State $State -Title 'Filter' -Label 'Show checks whose ID or setting contains' -Initial $State.Search
            if ($null -ne $text) { $State.Search = $text; $State.ResultIndex = 0; $State.ResultOffset = 0 }
        }
    }
}
```


- [ ] **Step 5: Implement** `src/Public/Start-BaselineCheck.ps1`

```powershell
function Start-BaselineCheck {
    <#
    .SYNOPSIS
        The interactive view: choose a baseline, sign in read-only, run, read the results, export.
    .DESCRIPTION
        Falls back to plain output (Invoke-BaselineCheck) when the console cannot host the view.
        Set M365BC_ASCII=1 for ASCII-only drawing, or NO_COLOR=1 for no colour.
    .EXAMPLE
        Start-BaselineCheck -Baseline ./baselines/core-tenant.json
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts an interactive session; changes nothing by itself.')]
    [CmdletBinding()]
    param(
        [string] $Baseline,
        [string] $OutputRoot,
        [switch] $AllowUnsealed,
        [string] $ExpectedFingerprint
    )
    $cap = Get-MbcTerminalCapability
    if (-not $cap.Interactive) {
        if (-not $Baseline) {
            throw "This console can't host the interactive view: its output is redirected, or it doesn't support terminal sequences. Run Invoke-BaselineCheck -Baseline <path> instead."
        }
        Write-Warning "This console can't host the interactive view, so this runs in plain output instead."
        return (Invoke-BaselineCheck -Baseline $Baseline -OutputRoot $OutputRoot -AllowUnsealed:$AllowUnsealed -ExpectedFingerprint $ExpectedFingerprint)
    }

    $state = New-MbcTuiState -OutputRoot (Get-MbcOutputRoot -Root $OutputRoot)
    $state.AllowUnsealed = [bool]$AllowUnsealed
    $state.ExpectedFingerprint = $ExpectedFingerprint
    if ($Baseline) { Set-MbcTuiBaseline -State $state -Path $Baseline }

    $savedEncoding = [Console]::OutputEncoding
    try {
        if (-not $env:M365BC_ASCII) { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) }
        Enter-MbcScreen
        while (-not $state.Quit) {
            $cap = Get-MbcTerminalCapability
            Write-MbcFrame -Lines (Format-MbcFrame -State $state -Cap $cap)
            $key = Read-MbcKey
            if ($key.Name -in 'Resize', 'Tick', 'Other') { continue }
            $action = Resolve-MbcKeyAction -State $state -Key $key
            if ($action -eq 'none') { continue }
            $effect = Invoke-MbcTuiNavigation -State $state -Action $action -Cap $cap
            if ($effect) { Invoke-MbcTuiEffect -State $state -Effect $effect }
        }
    }
    finally {
        Exit-MbcScreen
        [Console]::OutputEncoding = $savedEncoding
        $script:MbcSessionKey = $null
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `Invoke-Pester ./tests/Runtime.Tests.ps1 -Output Detailed`
Expected: PASS: 2 key and document tests, 6 effect tests and 2 fallback tests.

- [ ] **Step 7: Run the gate, then commit**

```bash
pwsh -NoProfile -File tools/Invoke-Gate.ps1
git add src/Tui/Runtime.ps1 src/Public/Start-BaselineCheck.ps1 src/Report/Result.ps1 tests/Runtime.Tests.ps1
git commit -m "feat: Start-BaselineCheck, the interactive view" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

The TUI loop itself can only be exercised in a real console. The owner will do that; don't claim it works without having seen it.

---

### Task 19: Handover: an example preset, the scrub gate, `CLAUDE.md`, README and CI

**Files:**
- Create: `presets/example-entra-hygiene.json`, `presets/example-entra-hygiene.baseline.json`, `extractors/example-legacy-auth-blocked.ps1`
- Create: `tests/fixtures/graph/roleAssignments.json`, `tests/fixtures/graph/securityDefaults.json`
- Create: `tests/Examples.Tests.ps1`, `tests/Scrub.Tests.ps1`, `tests/scrub-allowlist.json`
- Create: `CLAUDE.md`, `.github/workflows/ci.yml`
- Modify: `README.md` (replace it whole), `tests/Module.Tests.ps1` (one test added)

**Interfaces:**
- Consumes: everything.
- Produces: a repository another Claude session can extend from `CLAUDE.md` alone, and a gate that stops identifying data from being committed.

- [ ] **Step 1: Write the example preset** `presets/example-entra-hygiene.json`

It uses only generic, widely published Entra hygiene settings, as a pattern to copy.

```json
{
  "schemaVersion": 1,
  "name": "Example: Entra hygiene",
  "description": "A worked example of a preset. Generic, widely published settings only; copy it to start your own.",
  "scopes": ["Policy.Read.All", "RoleManagement.Read.Directory"],
  "endpoints": [
    "/policies/authorizationPolicy",
    "/policies/identitySecurityDefaultsEnforcementPolicy",
    "/identity/conditionalAccess/policies",
    "/roleManagement/directory/roleAssignments"
  ],
  "checks": [
    {
      "id": "ORG-001",
      "title": "Users cannot register applications",
      "request": "/policies/authorizationPolicy",
      "select": "defaultUserRolePermissions.allowedToCreateApps",
      "operator": "equals",
      "severity": "medium",
      "why": "Registering an application grants it a foothold in the directory; that is an administrative decision."
    },
    {
      "id": "ORG-002",
      "title": "Users cannot create security groups",
      "request": "/policies/authorizationPolicy",
      "select": "defaultUserRolePermissions.allowedToCreateSecurityGroups",
      "operator": "equals",
      "severity": "low",
      "why": "Security groups grant access; creating them belongs with administrators."
    },
    {
      "id": "GST-001",
      "title": "Guest invitations are limited",
      "request": "/policies/authorizationPolicy",
      "select": "allowInvitesFrom",
      "operator": "in",
      "severity": "medium",
      "why": "Anyone who can invite a guest can widen who sees the directory."
    },
    {
      "id": "GST-002",
      "title": "Guests have restricted directory access",
      "request": "/policies/authorizationPolicy",
      "select": "guestUserRoleId",
      "operator": "equals",
      "severity": "medium",
      "why": "The most restrictive guest role limits what a guest can enumerate."
    },
    {
      "id": "CA-001",
      "title": "At least one Conditional Access policy is enforced",
      "request": "/identity/conditionalAccess/policies",
      "select": "value[?state=='enabled'].displayName",
      "operator": "countAtLeast",
      "severity": "high",
      "why": "Report-only policies enforce nothing."
    },
    {
      "id": "CA-002",
      "title": "Legacy authentication is blocked for everyone",
      "request": "/identity/conditionalAccess/policies",
      "extractor": "extractors/example-legacy-auth-blocked.ps1",
      "operator": "equals",
      "severity": "high",
      "why": "Legacy protocols cannot do multifactor authentication, so they are the usual way around it."
    },
    {
      "id": "ADM-001",
      "title": "At least two Global Administrators",
      "request": "/roleManagement/directory/roleAssignments?$filter=roleDefinitionId%20eq%20%2762e90394-69f5-4237-9190-012177145e10%27",
      "select": "value[*].principalId",
      "operator": "countAtLeast",
      "severity": "medium",
      "why": "One administrator is one lost phone away from a locked-out tenant."
    },
    {
      "id": "ADM-002",
      "title": "No more than four Global Administrators",
      "request": "/roleManagement/directory/roleAssignments?$filter=roleDefinitionId%20eq%20%2762e90394-69f5-4237-9190-012177145e10%27",
      "select": "value[*].principalId",
      "operator": "countAtMost",
      "severity": "high",
      "why": "Every Global Administrator is a way to own the whole tenant."
    },
    {
      "id": "AUTH-001",
      "title": "Security defaults are off, because Conditional Access is in use",
      "request": "/policies/identitySecurityDefaultsEnforcementPolicy",
      "select": "isEnabled",
      "operator": "equals",
      "severity": "low",
      "why": "Security defaults and Conditional Access are mutually exclusive; this preset assumes the latter."
    }
  ]
}
```

ADM-001 and ADM-002 share one request on purpose. It shows that a request is fetched once, however many checks read it.

- [ ] **Step 2: Write the example extractor** `extractors/example-legacy-auth-blocked.ps1`

```powershell
param($Response)
# True when an enabled Conditional Access policy blocks the legacy client types for all users.
# An example of an extractor: a check whose logic the select language cannot express in one path.
$blocking = @($Response['value'] | Where-Object {
        $conditions = $_['conditions']
        $grant = $_['grantControls']
        $_['state'] -eq 'enabled' -and $conditions -and $grant -and
        (@($conditions['clientAppTypes']) -contains 'exchangeActiveSync') -and
        (@($conditions['clientAppTypes']) -contains 'other') -and
        (@($conditions['users']['includeUsers']) -contains 'All') -and
        (@($grant['builtInControls']) -contains 'block')
    })
return ($blocking.Count -gt 0)
```

- [ ] **Step 3: Write the synthetic fixtures**

`tests/fixtures/graph/roleAssignments.json`:
```json
{ "value": [
  { "id": "a1", "principalId": "00000000-0000-4000-8000-000000000021", "roleDefinitionId": "62e90394-69f5-4237-9190-012177145e10" },
  { "id": "a2", "principalId": "00000000-0000-4000-8000-000000000022", "roleDefinitionId": "62e90394-69f5-4237-9190-012177145e10" },
  { "id": "a3", "principalId": "00000000-0000-4000-8000-000000000023", "roleDefinitionId": "62e90394-69f5-4237-9190-012177145e10" }
] }
```

`tests/fixtures/graph/securityDefaults.json`:
```json
{ "id": "00000000000000000000000000000000", "isEnabled": false }
```

- [ ] **Step 4: Create the example baseline**, then seal it

Copy the preset into a baseline document. Its `expected` values are:

```json
{
  "ORG-001": false,
  "ORG-002": false,
  "GST-001": ["adminsAndGuestInviters", "none"],
  "GST-002": "2af84b1e-32c8-42b7-82bc-daa82404023b",
  "CA-001": 1,
  "CA-002": true,
  "ADM-001": 2,
  "ADM-002": 4,
  "AUTH-001": false
}
```

Run this from the repository root. It builds `presets/example-entra-hygiene.baseline.json` from the preset, adds the expected values, and seals it:

```powershell
Import-Module ./M365BaselineCheck.psd1 -Force
& (Get-Module M365BaselineCheck) {
    $preset = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText("$PWD/presets/example-entra-hygiene.json"))
    $expected = ConvertFrom-MbcJson -Json '{"ORG-001":false,"ORG-002":false,"GST-001":["adminsAndGuestInviters","none"],"GST-002":"2af84b1e-32c8-42b7-82bc-daa82404023b","CA-001":1,"CA-002":true,"ADM-001":2,"ADM-002":4,"AUTH-001":false}'
    $doc = [ordered]@{ schemaVersion = 1L; name = 'Example: Entra hygiene'; version = 1L; description = 'The example preset with example expected values. Not a recommendation for any particular tenant.'; preset = $preset; expected = $expected }
    [System.IO.File]::WriteAllText("$PWD/presets/example-entra-hygiene.baseline.json", (ConvertTo-MbcPrettyJson -Value $doc), [System.Text.UTF8Encoding]::new($false))
}
Protect-Baseline ./presets/example-entra-hygiene.baseline.json
```

Expected: `Sealed. Example: Entra hygiene is v1; its fingerprint is <12 hex>.`

- [ ] **Step 5: Write the example tests** `tests/Examples.Tests.ps1`

```powershell
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The shipped examples' {
        BeforeAll {
            $script:Fx = Join-Path $script:ModuleRoot 'tests/fixtures/graph'
            $script:Read = { param($n) ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:Fx $n))) -AllowFloat }
        }
        It 'has a valid example preset' {
            { Read-MbcPreset -Path (Join-Path $script:ModuleRoot 'presets/example-entra-hygiene.json') } | Should -Not -Throw
        }
        It 'has a sealed, unmodified example baseline' {
            (Read-MbcBaseline -Path (Join-Path $script:ModuleRoot 'presets/example-entra-hygiene.baseline.json')).SealState | Should -Be 'Sealed'
        }
        It 'passes every example check against the synthetic tenant, end to end' {
            $bodies = @{}
            $bodies['/policies/authorizationPolicy'] = & $script:Read 'authorizationPolicy.json'
            $bodies['/policies/identitySecurityDefaultsEnforcementPolicy'] = & $script:Read 'securityDefaults.json'
            $bodies['/identity/conditionalAccess/policies'] = & $script:Read 'conditionalAccessPolicies.json'
            $bodies['/roleManagement/directory/roleAssignments?$filter=roleDefinitionId%20eq%20%2762e90394-69f5-4237-9190-012177145e10%27'] = & $script:Read 'roleAssignments.json'
            $script:ExampleBodies = $bodies
            $fetch = { param($ApiVersion, $Request) New-MbcFetchResult -Ok $true -Body $script:ExampleBodies[$Request] -Status 200 }
            $b = Read-MbcBaseline -Path (Join-Path $script:ModuleRoot 'presets/example-entra-hygiene.baseline.json')
            $run = Invoke-MbcRun -Baseline $b -Fetch $fetch
            @($run.Results | Where-Object Verdict -ne 'Pass' | ForEach-Object { "$($_.Id): $($_.Verdict) $($_.Cause)" }) | Should -BeNullOrEmpty
            $run.Counts.Total | Should -Be 9
        }
        It 'ships only extractors that pass the purity check' {
            $extractors = @(Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot 'extractors') -Filter '*.ps1' -File)
            $extractors.Count | Should -BeGreaterThan 0
            foreach ($e in $extractors) { @(Test-MbcExtractorPurity -Path $e.FullName) | Should -BeNullOrEmpty -Because $e.Name }
        }
    }

    Describe 'CLAUDE.md keeps up with the code' {
        BeforeAll { $script:Guide = [System.IO.File]::ReadAllText((Join-Path $script:ModuleRoot 'CLAUDE.md')) }
        It 'documents every operator' {
            foreach ($op in $script:MbcOperators) { $script:Guide | Should -Match "``$op``" -Because $op }
        }
        It 'documents every error cause' {
            foreach ($cause in $script:MbcCauses) { $script:Guide | Should -Match ([regex]::Escape($cause)) -Because $cause }
        }
        It 'documents the select grammar' {
            $script:Guide | Should -Match 'length\('
            $script:Guide | Should -Match '\[\?'
        }
    }

    Describe 'README' {
        It 'says who wrote the code' {
            [System.IO.File]::ReadAllText((Join-Path $script:ModuleRoot 'README.md')) | Should -Match 'written by Claude \(Anthropic\)'
        }
    }
}
```

- [ ] **Step 6: Write the scrub allowlist** `tests/scrub-allowlist.json`

```json
{
  "guids": [
    "f2ef992c-3afb-46b9-b7cf-a126ee74c451",
    "5d6b6bb7-de71-4623-b4af-96380a352509",
    "4a5d8f65-41da-4de4-8968-e035b65339cf",
    "88d8e3e3-8f55-4a1e-953a-9b9898b8876b",
    "790c1fb9-7f7d-4f88-86a1-ef1f95c05c1b",
    "75934031-6c7e-415a-99d7-48dbd49e875e",
    "62e90394-69f5-4237-9190-012177145e10",
    "2af84b1e-32c8-42b7-82bc-daa82404023b",
    "10dae51f-b6af-4016-8d66-8c2a99b929b3",
    "a0b1b346-4d3e-4e8b-98f8-753987be4970"
  ],
  "guidPatterns": ["^00000000-0000-4000-8000-[0-9a-f]{12}$"],
  "emailDomains": ["example.com", "example.org", "example.net"],
  "emails": ["noreply@anthropic.com"],
  "tenantDomains": ["example.onmicrosoft.com"],
  "hosts": ["graph.microsoft.com", "learn.microsoft.com", "www.apache.org", "apache.org", "example.com", "www.powershellgallery.com", "github.com"]
}
```

The first seven GUIDs are Microsoft's built-in role template IDs, verified in Task 11. The last three are Microsoft's well-known guest role IDs; the example preset uses the most restrictive of them.

- [ ] **Step 7: Write the scrub test** `tests/Scrub.Tests.ps1`

```powershell
Describe 'Nothing identifying is tracked in this public repository' {
    BeforeAll {
        $script:Root = Split-Path -Parent $PSScriptRoot
        $script:Allow = [System.IO.File]::ReadAllText((Join-Path $script:Root 'tests/scrub-allowlist.json')) | ConvertFrom-Json
        $script:ManifestGuid = [string](Import-PowerShellDataFile (Join-Path $script:Root 'M365BaselineCheck.psd1')).GUID
        $script:Tracked = @(git -C $script:Root ls-files) | Where-Object { $_ -and $_ -notmatch '\.(png|jpg|ico|zip)$' }
        $script:Texts = @{}
        foreach ($f in $script:Tracked) { $script:Texts[$f] = [System.IO.File]::ReadAllText((Join-Path $script:Root $f)) }
        function script:Find-Offender([string] $Pattern, [scriptblock] $IsAllowed) {
            $found = [System.Collections.Generic.List[string]]::new()
            foreach ($f in $script:Texts.Keys) {
                foreach ($m in [regex]::Matches($script:Texts[$f], $Pattern)) {
                    if (-not (& $IsAllowed $m.Value)) { $found.Add("$f -> $($m.Value)") }
                }
            }
            return , $found.ToArray()
        }
    }

    It 'has files to scan' {
        $script:Tracked.Count | Should -BeGreaterThan 20
    }

    It 'contains no GUID outside the allowlist' {
        $offenders = Find-Offender '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b' {
            param($v)
            $g = $v.ToLowerInvariant()
            ($g -in $script:Allow.guids) -or ($g -eq $script:ManifestGuid.ToLowerInvariant()) -or
            (@($script:Allow.guidPatterns | Where-Object { $g -match $_ }).Count -gt 0)
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'contains no email address outside the allowlist' {
        $offenders = Find-Offender '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' {
            param($v)
            ($v -in $script:Allow.emails) -or (($v -split '@')[-1].ToLowerInvariant() -in $script:Allow.emailDomains)
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'names no tenant domain other than an example one' {
        $offenders = Find-Offender '[A-Za-z0-9-]+\.onmicrosoft\.com' { param($v) $v.ToLowerInvariant() -in $script:Allow.tenantDomains }
        $offenders | Should -BeNullOrEmpty
    }

    It 'links to no host outside the allowlist' {
        $offenders = Find-Offender 'https?://[A-Za-z0-9.-]+' {
            param($v)
            ($v -replace '^https?://', '').ToLowerInvariant() -in $script:Allow.hosts
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'tracks no baseline, result or locked file outside the example folders' {
        @($script:Tracked | Where-Object { $_ -like '*.locked' }) | Should -BeNullOrEmpty
        $misplaced = foreach ($f in ($script:Tracked | Where-Object { $_ -like '*.json' })) {
            $t = $script:Texts[$f]
            $isBaseline = $t -match '"expected"\s*:' -and $t -match '"preset"\s*:'
            $isResult = $t -match '"kind"\s*:\s*"m365bc-result"'
            if (($isBaseline -or $isResult) -and $f -notlike 'presets/*' -and $f -notlike 'tests/fixtures/*') { $f }
        }
        @($misplaced) | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 8: Run the scrub test, and look at what it finds**

Run: `Invoke-Pester ./tests/Scrub.Tests.ps1 -Output Detailed`
Expected: PASS.

If anything is flagged, **decide what it is before touching the allowlist.** A real identifier is removed from the file. Only a genuinely public, generic value (a Microsoft well-known ID, a documentation host) is added to the allowlist, with a reason in your report.

- [ ] **Step 9: Write `CLAUDE.md`**

```markdown
# CLAUDE.md: customising M365 Baseline Check

You are probably here to add presets, baselines or extractors for an organisation. Read this whole file first. It is short on purpose.

## What this is

A read-only PowerShell 7 module that checks a Microsoft 365 tenant against a **sealed baseline**, from a terminal UI (`Start-BaselineCheck`) or plainly (`Invoke-BaselineCheck`). It writes an exhaustive local log, a concise sealed result, optionally encrypted with a team key, and a redacted summary that is safe to hand to an AI assistant.

## Invariants: not preferences

1. **Read-only, at three layers.** Presets may only declare read scopes. The granted token is checked at sign-in, failing closed on anything unrecognised. The Graph client can only `GET`. Never add a write scope, a write method, or another HTTP client. If a check seems to need write access, it is the wrong check.
2. **Error never becomes Pass.** A check that couldn't be completed is an `Error` with a cause, and it is reported and counted. Don't write code that turns a failure into a pass or drops it.
3. **Seal before use.** Only a sealed, unmodified baseline runs, unless `-AllowUnsealed` is given while authoring, in which case every output says `UNSEALED`.
4. **Nothing identifying in this public repository.** See *Where internal things live*.
5. **Collect, then evaluate.** Collection does I/O and makes no judgements. Extraction and comparison are pure, with no network, so every check is testable offline.
6. **Secrets are never written.** No tokens, no authorization headers, no team key, in any log, result or file.

## Where internal things live, and where they must not

**This repository is public.** Organisation-specific presets, baselines, extractors, team keys and results never go in it. Keep them in a **private copy**: a private fork or a private repository. In a private copy, remove the `/baselines/` line from `.gitignore` and keep them under `baselines/`.

`tests/Scrub.Tests.ps1` fails on GUIDs, email addresses, tenant domains, links, and baseline or result files outside the example folders. It **cannot** see a policy name, a group name or a client's name: those are just words. Before any commit here, ask whether the change is generic. If it isn't, it belongs in the private copy.

## Nouns

| Noun | Is |
|---|---|
| Preset | *What* to read and *how*: checks without expected values. Examples live in `presets/`. |
| Baseline | A preset **plus expected values, sealed** into one file. Its fingerprint (the first 12 hex characters of its SHA-256) identifies it. |
| Result | One run against one baseline, sealed. Contains tenant values. |
| Locked result | A result encrypted with the team key: `result-<UTC time>.locked`. |
| Summary | Redacted Markdown: check ID, setting, Met / Not met / Couldn't verify, severity. No tenant data. |
| Team key | `mbc-key:1:<id>:<secret>`, from `New-ResultKey`. Kept in one entry in the team's password manager. |

## Adding a preset

1. Copy `presets/example-entra-hygiene.json` into your private copy.
2. **Scopes:** list the read permissions your endpoints need, from each Graph API's *Permissions* table on learn.microsoft.com. Prefer the least privileged one. Only read scopes validate: `Resource.Read.*` or `Resource.ReadBasic.*`.
3. **Endpoints:** list every Graph path your checks request, without query strings. A check's `request` must be one of them, a child of one, or one with a query string.
4. **Checks:** one object per setting. See the fields below.
5. **Draft expected values** from a tenant you consider correct: `New-BaselineCapture -PresetPath <preset> -OutputPath <draft> -Name '<name>'`. It lists anything it couldn't read or can't guess.
6. **Review** the draft. Expected values are decisions, not observations: change them to what should be true.
7. **Seal** it: `Protect-Baseline <draft>`. Record the printed line (`name · vN · SHA-256 …`) wherever your team catalogues baselines.
8. **Add synthetic fixtures and a test** (see *Testing*) if you wrote an extractor or anything non-trivial.

### Check fields

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | 1 to 64 letters, digits, `.`, `-`, `_`. Unique within the preset. |
| `title` | yes | A noun phrase naming the setting, e.g. "Users cannot register applications". Up to 200 characters. |
| `request` | yes | A Graph path starting with `/`. Encode spaces as `%20` and quotes as `%27` in query strings. |
| `select` | one of | A path into the response (see below). |
| `extractor` | one of | `extractors/<name>.ps1`, for logic `select` can't express. |
| `operator` | yes | See *Operators*. |
| `severity` | yes | `high`, `medium`, `low` or `info`. |
| `why` | no | One sentence on why it matters, shown in the detail view. |
| `caseSensitive` | no | `true` to compare strings exactly. The default is case-insensitive. |
| `apiVersion` | no | `v1.0` (the default) or `beta`. |

## The select language

Small on purpose. The whole grammar:

    select   := path | 'length(' path ')'
    path     := step ('.' step)*
    step     := name ( '[*]' | '[' int ']' | '[?' name op literal ']' )?
    name     := identifier | "quoted name"     (quote names containing dots, like "@odata.type")
    op       := '==' | '!='
    literal  := 'string' | integer | true | false | null

Examples:
- `defaultUserRolePermissions.allowedToCreateApps` reads one value.
- `value[*].displayName` is every item's display name, as a list.
- `value[?state=='enabled'].displayName` is the same, filtered.
- `value[0].id` is the first item's ID; `[-1]` is the last.
- `length(value[*])` is the number of items.

A path that resolves to nothing is **NotFound**. That is an `Error` ("setting not found") for every operator except `exists` and `absent`. A projection (`[*]` or a filter) that matches nothing is an empty list, not NotFound.

## Operators

| Operator | Passes when | Expected value |
|---|---|---|
| `equals` | actual equals expected (objects and lists compare exactly) | any |
| `notEquals` | actual differs from expected | any |
| `in` | the actual single value is one of the list | a list |
| `contains` | the actual list contains the value | a single value |
| `setEquals` | the same members, ignoring order and duplicates | a list |
| `subsetOf` | every actual member is in the list | a list |
| `countAtLeast` | the actual list has at least N items | a whole number |
| `countAtMost` | the actual list has at most N items | a whole number |
| `matches` | the actual text matches the regular expression (anchor it yourself) | text |
| `exists` | the path resolves (even to null) | none |
| `absent` | the path does not resolve | none |

A mismatch of kinds, such as a count on a single value, is an `Error`, not a `Fail`: it means the baseline is wrong, not the tenant. Numbers must be whole numbers. Baselines reject decimals, so fingerprints are stable across machines.

## Extractors

A script in `extractors/` that receives the parsed response as `$Response` (ordered dictionaries and arrays) and returns a value.

    param($Response)
    $blocking = @($Response['value'] | Where-Object { $_['state'] -eq 'enabled' })
    return ($blocking.Count -gt 0)

- **It must be pure.** It may only use `Where-Object`, `ForEach-Object`, `Select-Object`, `Sort-Object`, `Group-Object`, `Measure-Object` and `Write-Output`, plus basic types (`[string]`, `[int]`, `[long]`, `[bool]`, `[array]`, `[hashtable]`, `[math]`, `[regex]`…). Anything else, or anything called by a computed name, is refused before it runs (`extractor not allowed`).
- Return a list with `return ,$list`, so a one-item list stays a list.
- Guard against missing members (`$x -and $x['y']`): the module runs under strict mode.

## Error causes

When a check can't be completed, its cause is one of these, and only these:

`permission missing` · `not found` · `throttled` · `service error` · `malformed response` · `request rejected` · `too many pages` · `setting not found` · `extractor failed` · `extractor not allowed` · `baseline expects a list` · `baseline expects a single value` · `invalid pattern` · `pattern too slow` · `endpoint not declared` · `not collected`

`permission missing` almost always means the preset's scopes don't cover that endpoint.

## Proving which baseline was used

Every result, CSV row, summary and locked-file header carries the baseline's name, version and fingerprint, and the JSON result carries its full digest. Teams keep baselines wherever they share files and catalogue them by that fingerprint. `Invoke-BaselineCheck -ExpectedFingerprint <12 hex>` refuses to run against any other file.

`Protect-Baseline` refuses to reseal changed content under the same version, so every real change is a new version.

## Voice, for anything a person reads

Readers are technical, literate, and at work. Be precise, brief and dry. Occasional wit is fine; exclamation marks, cuteness and filler are not.

- Good: "Sealed. The baseline is now v4; its fingerprint is 9f8e7d6c5b4a. Record it wherever you keep these."
- Good: "27 met, 3 not, 1 unverifiable."
- Not: "Success!!", "Oops, something went wrong", "Great job!"

Titles name the setting ("Guest invitations are limited"), never the verdict.

## Testing

    pwsh -NoProfile -File tools/Invoke-Gate.ps1

It runs every Pester test, then PSScriptAnalyzer over `src/` and `tools/`. It must say `0 failed` and `0 finding(s)` before any commit.

- Tests are **offline**. Graph responses are synthetic fixtures under `tests/fixtures/graph/`. Invent them: never paste a real tenant's response.
- To test a new preset end to end, copy the pattern in `tests/Examples.Tests.ps1`: map each request to a fixture, run `Invoke-MbcRun`, and assert every check passes. Then change one fixture value and see that check fail.
- `tools/Export-TuiSnapshots.ps1` renders the TUI to text under `docs/tui-snapshots/`, for reviewing layout without a console.

## Don't

- Add a write scope, a non-GET request, or any HTTP client other than the one in `src/Graph/GraphClient.ps1`.
- Log, export or summarise a value no check asked for.
- Add a runtime dependency. `Microsoft.Graph.Authentication` is the only one.
- Put an organisation's names, IDs or baselines in this repository.
```

- [ ] **Step 10: Replace `README.md`**

```markdown
# M365 Baseline Check

Read-only checks of a Microsoft 365 tenant against a **sealed baseline**, from a terminal UI or a single command. Quick, precise audits in PowerShell, instead of a tour of admin-centre GUIs.

The code in this repository was written by Claude (Anthropic), under human direction.

## What it does

- Reads tenant configuration through Microsoft Graph. **Only reads**: write scopes are refused at sign-in, and the client can only `GET`.
- Compares each setting with a baseline: a preset of checks plus expected values, sealed with SHA-256, so any change is obvious and every result says which version it was checked against.
- Logs everything to a local file; reports concisely.
- Exports a sealed JSON result and a CSV, optionally **encrypted with a team key**, plus a redacted summary that is safe to hand to an AI assistant.

## Requirements

- PowerShell 7.4 or later, on Windows, macOS or Linux.
- `Microsoft.Graph.Authentication`: `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`.
- An account that can read the settings your baseline checks. Global Reader covers most.

## Quick start

    git clone <this repository>
    cd m365-baseline-check
    Import-Module ./M365BaselineCheck.psd1

    Start-BaselineCheck -Baseline ./presets/example-entra-hygiene.baseline.json

Or without the interactive view:

    Invoke-BaselineCheck ./presets/example-entra-hygiene.baseline.json -ExpectedFingerprint <12 hex>

### Keys

| Key | Does |
|---|---|
| ↑ ↓ or j k | move |
| Enter | select, or open a result's detail |
| Esc | back |
| r | run the checks |
| b | choose a baseline |
| l | last results |
| o | open a locked result |
| f / e / a | show failures / errors / everything |
| / | filter by text |
| x | export (locked, if you give the team key) |
| ? | help for the current screen |
| q | quit |

The keys available on each screen are always shown at the bottom.

## Baselines

1. Start from a preset: `presets/example-entra-hygiene.json` is a worked example.
2. Draft expected values from a tenant you consider correct: `New-BaselineCapture -PresetPath <preset> -OutputPath <draft> -Name '<name>'`.
3. Review and edit the draft. Expected values are decisions.
4. Seal it: `Protect-Baseline <draft>`. Note the fingerprint it prints.

`Test-Baseline <file>` shows a baseline's identity and whether it has changed since it was sealed. An edited baseline refuses to run until it is resealed under a higher version.

## Results

Results go to `~/M365BaselineCheck/results/`, and logs to `~/M365BaselineCheck/logs/`. Set `M365BC_HOME` to change that.

- `result-<UTC time>.json` and `.csv`: sealed, and they contain tenant values.
- `result-<UTC time>.locked`: the same, encrypted with the team key (`-Lock`, or `x` in the TUI). No plaintext result is written.
- `summary-<UTC time>.md`: check, status and severity only; no tenant data.

Generate a team key once with `New-ResultKey`, and keep it in one entry in your team's password manager. Open a locked result with `Unlock-Result <file>`, or `o` in the TUI.

## Environment

| Variable | Effect |
|---|---|
| `M365BC_HOME` | where results and logs go |
| `M365BC_ASCII` | draw with ASCII only |
| `NO_COLOR` | no colour |

## Customising

Read [`CLAUDE.md`](CLAUDE.md). It covers presets, the select language, operators, extractors and testing, and it is written to be handed to a Claude session. Keep organisation-specific presets and baselines in a private copy, never in this repository.

## Development

    pwsh -NoProfile -File tools/Invoke-Gate.ps1        # tests and analyser
    pwsh -NoProfile -File tools/Export-TuiSnapshots.ps1 # TUI screens as text, in docs/tui-snapshots/

## Licence

Apache License 2.0. See [LICENSE](LICENSE).
```

- [ ] **Step 11: Add the final module test** to `tests/Module.Tests.ps1`

Add this `It` inside the existing `Describe 'The module'`:

```powershell
    It 'exports every declared public command' {
        Import-Module $script:Manifest -Force
        $declared = (Import-PowerShellDataFile $script:Manifest).FunctionsToExport
        $exported = @((Get-Module M365BaselineCheck).ExportedFunctions.Keys)
        foreach ($name in $declared) { $exported | Should -Contain $name }
    }
```

- [ ] **Step 12: Write the CI workflow** `.github/workflows/ci.yml`

```yaml
name: CI

# Pull requests and manual runs only: nothing runs on every push.
on:
  pull_request:
  workflow_dispatch:

jobs:
  gate:
    strategy:
      fail-fast: false
      matrix:
        os: [windows-latest, ubuntu-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Install test tools
        shell: pwsh
        run: |
          Set-PSRepository PSGallery -InstallationPolicy Trusted
          Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser
          Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
      - name: Gate
        shell: pwsh
        run: ./tools/Invoke-Gate.ps1
```

- [ ] **Step 13: Run the whole gate, and the snapshots once more**

```bash
pwsh -NoProfile -File tools/Export-TuiSnapshots.ps1
pwsh -NoProfile -File tools/Invoke-Gate.ps1
```
Expected: `0 failed`, `0 finding(s)`, and the snapshots unchanged or improved.

- [ ] **Step 14: Commit**

```bash
git add presets extractors tests CLAUDE.md README.md .github docs/tui-snapshots
git commit -m "docs: the example preset, the scrub gate, CLAUDE.md, README and CI" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

**Do not push.** The controller creates the public repository and pushes once, after a final review.

---

## After the plan: the controller's checklist

1. Whole-branch review against the spec, with mutations re-run.
2. Line endings and BOM checked by bytes; a secret scan over the full history (`git log -p`).
3. Create the target public repository (named in the controller's notes, not here), and push `main` once.
4. Hand the owner:
   - the TUI to try in a real console (Windows Terminal, and macOS Terminal when available);
   - the note that the background-runspace spinner is plausible but unmeasured against a live Graph sign-in, with the fallback that keeps it working if it isn't.
