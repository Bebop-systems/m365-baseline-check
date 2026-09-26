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
