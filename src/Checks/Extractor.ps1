# What an extractor may call. Deliberately small: filtering and shaping the response it is given, nothing else.
# 'math' was removed deliberately: constrained language already refuses its methods at runtime, and
# keeping it out of the static allowlist too means an extractor that tries it is refused early, with a
# line number, rather than only ever failing inside the sandbox.
$script:MbcExtractorCommands = @('Where-Object', 'ForEach-Object', 'Select-Object', 'Sort-Object', 'Group-Object', 'Measure-Object', 'Write-Output')
$script:MbcExtractorTypes = @('string', 'int', 'long', 'bool', 'array', 'hashtable', 'ordered', 'object', 'object[]', 'string[]',
    'regex', 'pscustomobject', 'System.StringComparison', 'System.StringComparer')
$script:MbcExtractorMethods = '^(Invoke|InvokeReturnAsIs|GetNewClosure|Create|Start|Load|LoadFrom|LoadFile|GetType|InvokeMember|CreateInstance)$'
# Case-insensitive by construction: every name here is compared in lower case against the variable's
# own UserPath, which -in/-eq already compare case-insensitively, but the list itself is normalised too
# so the intent reads clearly at the call site.
$script:MbcExtractorForbiddenVariables = @('executioncontext', 'host', 'pscmdlet', 'myinvocation', 'psscriptroot', 'pscommandpath', 'executionpolicy', 'psboundparameters')
$script:MbcExtractorPathPattern = '^extractors/[A-Za-z0-9._-]+\.ps1$'
$script:MbcExtractorTimeout = [TimeSpan]::FromSeconds(5)

# Pure AST walk: no I/O, no execution. Layer 1 of the two-layer defence (R14) — fails early, with a
# line number and a plain-language reason. Layer 2 (Invoke-MbcSandboxedScript, below) is the real
# boundary: this layer exists so a common mistake is refused before anything runs at all.
function Get-MbcExtractorProblems {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Ast,
        [Parameter(Mandatory)][AllowEmptyCollection()] $ParseErrors
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $ParseErrors) { $problems.Add("doesn't parse: $($e.Message)") }
    if ($Ast.ScriptRequirements) { $problems.Add('uses a #requires statement') }

    foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $line = $c.Extent.StartLineNumber
        $name = $c.GetCommandName()
        if ($null -eq $name) { $problems.Add("line ${line}: calls something by a computed name"); continue }
        if ($name -notin $script:MbcExtractorCommands) {
            $problems.Add("line ${line}: '$name' isn't on the list of commands an extractor may use")
            continue
        }
        if ($name -in 'Where-Object', 'ForEach-Object') {
            for ($i = 1; $i -lt $c.CommandElements.Count; $i++) {
                $el = $c.CommandElements[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($el.ParameterName -notin 'FilterScript', 'Process') {
                        $problems.Add("line $($el.Extent.StartLineNumber): '$name' takes no '-$($el.ParameterName)'")
                    }
                }
                elseif ($el -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $problems.Add("line $($el.Extent.StartLineNumber): '$name' takes a script block, not '$($el.Extent.Text)'")
                }
            }
        }
    }

    foreach ($t in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -or $n -is [System.Management.Automation.Language.TypeConstraintAst] }, $true)) {
        $typeName = $t.TypeName.FullName
        if ($typeName -notin $script:MbcExtractorTypes) { $problems.Add("line $($t.Extent.StartLineNumber): uses the type [$typeName]") }
    }

    foreach ($a in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AttributeAst] }, $true)) {
        $problems.Add("line $($a.Extent.StartLineNumber): uses the attribute $($a.Extent.Text)")
    }

    foreach ($m in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)) {
        $line = $m.Extent.StartLineNumber
        if ($m.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $problems.Add("line ${line}: calls or reads something by a computed member name")
        }
        elseif ($m -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            $member = $m.Member.Extent.Text.Trim("'", '"')
            if ($member -match $script:MbcExtractorMethods) { $problems.Add("line ${line}: calls .$member()") }
        }
        if ($m.Static -and $m.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) {
            $problems.Add("line ${line}: a static member access must name a fixed type, not an expression")
        }
    }

    foreach ($b in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        $op = $b.Operator
        if ($op -eq [System.Management.Automation.Language.TokenKind]::As -or
            $op -eq [System.Management.Automation.Language.TokenKind]::Is -or
            $op -eq [System.Management.Automation.Language.TokenKind]::IsNot) {
            if ($b.Right -isnot [System.Management.Automation.Language.TypeExpressionAst]) {
                $problems.Add("line $($b.Extent.StartLineNumber): '$op' must name a fixed type, not an expression")
            }
        }
    }

    foreach ($v in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $path = $v.VariablePath
        $line = $v.Extent.StartLineNumber
        if (-not $path.IsUnqualified) { $problems.Add("line ${line}: uses a scoped or drive-qualified variable, `$$($path.UserPath)") }
        if ($path.UserPath.ToLowerInvariant() -in $script:MbcExtractorForbiddenVariables) { $problems.Add("line ${line}: uses `$$($path.UserPath)") }
    }

    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.UsingStatementAst] }, $true)) {
        $problems.Add("line $($n.Extent.StartLineNumber): uses a using statement")
    }
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FileRedirectionAst] }, $true)) {
        $problems.Add("line $($n.Extent.StartLineNumber): redirects to a file")
    }
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)) {
        $problems.Add("line $($n.Extent.StartLineNumber): defines a type")
    }

    return , $problems.ToArray()
}

function Test-MbcExtractorPurity {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string] $Path)
    try {
        $text = [System.IO.File]::ReadAllText($Path)
    }
    catch {
        return , @("doesn't parse: $($_.Exception.Message)")
    }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    $problems = Get-MbcExtractorProblems -Ast $ast -ParseErrors $errors
    return , $problems
}

# Layer 2, the real boundary: an empty session state (no providers, no modules, no functions),
# constrained language, and only the handful of cmdlets an extractor is allowed to call. One
# runspace per call, disposed with the caller's PowerShell instances in the same 'finally'.
function New-MbcSandboxRunspace {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.Runspace])]
    param()
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::Create()
    $iss.LanguageMode = [System.Management.Automation.PSLanguageMode]::ConstrainedLanguage
    foreach ($name in ($script:MbcExtractorCommands + 'Set-StrictMode')) {
        $cmd = Get-Command -Name $name -CommandType Cmdlet
        $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateCmdletEntry]::new($name, $cmd.ImplementingType, $null))
    }
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    return $rs
}

# PowerShell script code already presents each pipeline item as its adapted, unwrapped .NET value:
# .GetType() reports the real type (int, hashtable, PSCustomObject, ...), never
# System.Management.Automation.PSObject itself. This only does something on the one case that can
# still arrive as a bare PSObject shell with nothing underneath.
function ConvertFrom-MbcSandboxItem {
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object] $Item)
    if ($Item -is [System.Management.Automation.PSObject] -and $Item.GetType() -eq [System.Management.Automation.PSObject]) {
        $base = $Item.BaseObject
        if ($base -isnot [System.Management.Automation.PSCustomObject]) { return , $base }
    }
    return , $Item
}

function Test-MbcContainsScriptBlock {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Value)
    if ($Value -is [scriptblock]) { return $true }
    if (Test-MbcIsList $Value) {
        foreach ($element in $Value) { if ($element -is [scriptblock]) { return $true } }
    }
    return $false
}

function Invoke-MbcSandboxedScript {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Text,
        [AllowNull()][object] $Argument
    )
    $rs = $null
    $preamble = $null
    $ps = $null
    try {
        $rs = New-MbcSandboxRunspace

        # The preamble is fixed, trusted text, run to completion on its own PowerShell instance
        # first. Its effect (strict mode, stop-on-error) lives in the runspace's own session
        # state and is inherited by the extractor's own instance below, since both share $rs.
        #
        # This is deliberately NOT one PowerShell instance with two AddStatement() statements:
        # that shape reproducibly crashes the process (an unhandled NullReferenceException /
        # InvalidCastException inside PowerShell.BatchInvocationWorkItem) whenever the SECOND
        # statement hangs and is stopped via Stop() after the timeout below — verified against
        # this runtime. Two separate PowerShell instances on the same runspace give the identical
        # effect (param(...) is still the first and only statement of the extractor's own script)
        # without that crash.
        $preamble = [System.Management.Automation.PowerShell]::Create()
        $preamble.Runspace = $rs
        [void]$preamble.AddScript("Set-StrictMode -Version Latest`n`$ErrorActionPreference = 'Stop'")
        [void]$preamble.Invoke()

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($Text).AddArgument($Argument)

        $async = $ps.BeginInvoke()
        $completed = $async.AsyncWaitHandle.WaitOne($script:MbcExtractorTimeout)
        if (-not $completed) {
            $ps.Stop()
            # EndInvoke() on a stopped pipeline throws "The pipeline has been stopped." — expected
            # here, and already fully described by the cause and detail below, so there's nothing
            # further to report.
            try { [void]$ps.EndInvoke($async) } catch { $null = $_ }
            return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor failed'; Detail = 'took longer than 5 s' }
        }
        $out = $ps.EndInvoke($async)

        if ($ps.HadErrors -or $ps.Streams.Error.Count -gt 0) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor failed'; Detail = $ps.Streams.Error[0].ToString() }
        }

        if ($out.Count -eq 0) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor failed'; Detail = 'returned nothing' }
        }
        if ($out.Count -eq 1) {
            $value = ConvertFrom-MbcSandboxItem -Item $out[0]
        }
        else {
            $list = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $out.Count; $i++) { $list.Add((ConvertFrom-MbcSandboxItem -Item $out[$i])) }
            # Plain assignment, not return/output: a leading comma here would build a 1-element
            # array wrapping this array, and nothing downstream would ever enumerate it back off,
            # unlike the same trick used on a return statement elsewhere in this file.
            $value = $list.ToArray()
        }

        if (Test-MbcContainsScriptBlock -Value $value) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor failed'; Detail = 'returned code, not data' }
        }
        return [pscustomobject]@{ Ok = $true; Value = $value; Cause = $null; Detail = $null }
    }
    catch {
        # This is also where a thrown extractor error surfaces: EndInvoke() rethrows a script's
        # terminating error (including a non-terminating one turned terminating by the preamble's
        # $ErrorActionPreference = 'Stop') as a MethodInvocationException, rather than leaving it
        # in $ps.Streams.Error for the check above to see.
        $detail = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor failed'; Detail = $detail }
    }
    finally {
        if ($ps) { $ps.Dispose() }
        if ($preamble) { $preamble.Dispose() }
        if ($rs) { $rs.Dispose() }
    }
}

function Invoke-MbcExtractor {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [AllowNull()][object] $Response,
        [string] $Root = $script:ModuleRoot
    )
    # Path resolution and the purity check both sit inside this one try: an unreadable file, a
    # missing drive, or any other unexpected failure on the way to a decision is a refusal, never
    # an exception escaping this function (R14).
    try {
        if ($RelativePath -notmatch $script:MbcExtractorPathPattern) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor not allowed'; Detail = "extractor path must look like extractors/NAME.ps1, not '$RelativePath'" }
        }

        $extractorsRoot = [System.IO.Path]::GetFullPath((Join-Path $Root 'extractors'))
        $full = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
        $boundary = $extractorsRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($boundary, [System.StringComparison]::Ordinal)) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor not allowed'; Detail = "extractor path escapes extractors/: '$RelativePath'" }
        }

        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor not allowed'; Detail = "there's no extractor at $RelativePath" }
        }

        $fileItem = Get-Item -LiteralPath $full -Force
        if ($fileItem.LinkType -or ($fileItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor not allowed'; Detail = "extractor is a reparse point: $RelativePath" }
        }
        if (Test-Path -LiteralPath $extractorsRoot) {
            $dirItem = Get-Item -LiteralPath $extractorsRoot -Force
            if ($dirItem.LinkType -or ($dirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor not allowed'; Detail = 'the extractors directory is a reparse point' }
            }
        }

        # Parsed once: this same text is what Invoke-MbcSandboxedScript below goes on to run, so
        # there is no gap between what was checked and what runs.
        $text = [System.IO.File]::ReadAllText($full)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        $problems = Get-MbcExtractorProblems -Ast $ast -ParseErrors $errors
        if ($problems.Count -gt 0) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor not allowed'; Detail = ($problems -join '; ') }
        }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'extractor not allowed'; Detail = $_.Exception.Message }
    }

    return Invoke-MbcSandboxedScript -Text $text -Argument $Response
}
