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
    $problems = Test-MbcExtractorPurity -Path $full
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
