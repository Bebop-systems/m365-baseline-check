# The select language (spec 7.2), read by a small hand-written scanner.
#   select   := path | 'length(' path ')'
#   path     := step ('.' step)*
#   step     := name ( '[*]' | '[' int ']' | '[?' name op literal ']' )?
#   name     := "quoted text" | [A-Za-z_@$][A-Za-z0-9_@$-]*
#   op       := '==' | '!='
#   literal  := 'string' ('' escapes a quote) | integer | true | false | null

function New-MbcSelectError {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Select, [string] $Reason)
    return "Can't read select '$Select': $Reason."
}

function Skip-MbcSpace {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [Parameter(Mandatory)][int] $Pos)
    while ($Pos -lt $Text.Length -and [char]::IsWhiteSpace($Text[$Pos])) { $Pos++ }
    return $Pos
}

function Read-MbcSelectName {
    # A name at $Pos, as { Name; Next }, or $null when there isn't one.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [Parameter(Mandatory)][int] $Pos)
    if ($Pos -ge $Text.Length) { return $null }
    if ($Text[$Pos] -ceq '"') {
        $close = $Text.IndexOf('"', $Pos + 1)
        if ($close -le $Pos + 1) { return $null }
        return [pscustomobject]@{ Name = $Text.Substring($Pos + 1, $close - $Pos - 1); Next = $close + 1 }
    }
    $first = $Text[$Pos]
    if (-not ((Test-MbcAsciiLetter $first) -or '_@$'.IndexOf($first) -ge 0)) { return $null }
    $end = $Pos + 1
    while ($end -lt $Text.Length -and ((Test-MbcAsciiAlnum $Text[$end]) -or '_@$-'.IndexOf($Text[$end]) -ge 0)) { $end++ }
    return [pscustomobject]@{ Name = $Text.Substring($Pos, $end - $Pos); Next = $end }
}

function Read-MbcSelectInteger {
    # An optionally negative run of ASCII digits at $Pos, as { Value; Next }, or $null.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [Parameter(Mandatory)][int] $Pos)
    $end = $Pos
    if ($end -lt $Text.Length -and $Text[$end] -ceq '-') { $end++ }
    $digitsFrom = $end
    while ($end -lt $Text.Length -and (Test-MbcAsciiDigit $Text[$end])) { $end++ }
    if ($end -eq $digitsFrom) { return $null }
    $value = 0L
    if (-not [long]::TryParse($Text.Substring($Pos, $end - $Pos), [System.Globalization.NumberStyles]::AllowLeadingSign, [cultureinfo]::InvariantCulture, [ref]$value)) { return $null }
    return [pscustomobject]@{ Value = $value; Next = $end }
}

function Read-MbcSelectLiteral {
    # A literal at $Pos, as { Value; Next }, or $null.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [Parameter(Mandatory)][int] $Pos)
    if ($Pos -ge $Text.Length) { return $null }
    if ($Text[$Pos] -ceq "'") {
        $sb = [System.Text.StringBuilder]::new()
        $i = $Pos + 1
        while ($i -lt $Text.Length) {
            if ($Text[$i] -ceq "'") {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -ceq "'") { [void]$sb.Append("'"); $i += 2; continue }
                return [pscustomobject]@{ Value = $sb.ToString(); Next = $i + 1 }
            }
            [void]$sb.Append($Text[$i])
            $i++
        }
        return $null
    }
    $number = Read-MbcSelectInteger -Text $Text -Pos $Pos
    if ($number) { return $number }
    foreach ($word in @(@('true', $true), @('false', $false), @('null', $null))) {
        if ([string]::CompareOrdinal($Text, $Pos, $word[0], 0, $word[0].Length) -eq 0) {
            return [pscustomobject]@{ Value = $word[1]; Next = $Pos + $word[0].Length }
        }
    }
    return $null
}

function Read-MbcSelectBracket {
    # The bracket at $Pos filled into $Step; returns the position after it, or -1 if it can't be read.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string] $Text, [Parameter(Mandatory)][int] $Pos, [Parameter(Mandatory)][System.Collections.IDictionary] $Step)
    $i = $Pos + 1
    if ($i -lt $Text.Length -and $Text[$i] -ceq '*') {
        if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -ceq ']') { $Step.Kind = 'all'; return ($i + 2) }
        return -1
    }
    if ($i -lt $Text.Length -and $Text[$i] -ceq '?') {
        $i = Skip-MbcSpace -Text $Text -Pos ($i + 1)
        $name = Read-MbcSelectName -Text $Text -Pos $i
        if (-not $name) { return -1 }
        $i = Skip-MbcSpace -Text $Text -Pos $name.Next
        if ($i + 1 -ge $Text.Length) { return -1 }
        $op = $Text.Substring($i, 2)
        if ($op -cne '==' -and $op -cne '!=') { return -1 }
        $i = Skip-MbcSpace -Text $Text -Pos ($i + 2)
        $literal = Read-MbcSelectLiteral -Text $Text -Pos $i
        if (-not $literal) { return -1 }
        $i = Skip-MbcSpace -Text $Text -Pos $literal.Next
        if ($i -ge $Text.Length -or $Text[$i] -cne ']') { return -1 }
        $Step.Kind = 'filter'
        $Step.Field = $name.Name
        $Step.Op = $op
        $Step.Literal = $literal.Value
        return ($i + 1)
    }
    $index = Read-MbcSelectInteger -Text $Text -Pos $i
    if (-not $index -or $index.Next -ge $Text.Length -or $Text[$index.Next] -cne ']') { return -1 }
    if ($index.Value -lt [int]::MinValue -or $index.Value -gt [int]::MaxValue) { return -1 }
    $Step.Kind = 'index'
    $Step.Index = [int]$index.Value
    return ($index.Next + 1)
}

function ConvertTo-MbcPathQuery {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string] $Select)
    $text = $Select.Trim()
    $isLength = $false
    if ($text.StartsWith('length(', [StringComparison]::OrdinalIgnoreCase) -and $text.EndsWith(')')) {
        $isLength = $true
        $text = $text.Substring(7, $text.Length - 8).Trim()
    }
    if ($text.Length -eq 0) { throw (New-MbcSelectError $Select 'it is empty') }

    $steps = [System.Collections.Generic.List[object]]::new()
    $pos = 0
    while ($true) {
        $name = Read-MbcSelectName -Text $text -Pos $pos
        if (-not $name) { throw (New-MbcSelectError $Select "expected a property name at position $($pos + 1)") }
        $step = [ordered]@{ Name = $name.Name; Kind = 'plain'; Index = $null; Field = $null; Op = $null; Literal = $null }
        $pos = $name.Next
        if ($pos -lt $text.Length -and $text[$pos] -ceq '[') {
            $after = Read-MbcSelectBracket -Text $text -Pos $pos -Step $step
            if ($after -lt 0) { throw (New-MbcSelectError $Select "can't make sense of the bracket at position $($pos + 1)") }
            $pos = $after
        }
        $steps.Add([pscustomobject]$step)
        if ($pos -ge $text.Length) { break }
        if ($text[$pos] -cne '.') { throw (New-MbcSelectError $Select "unexpected '$($text[$pos])' at position $($pos + 1)") }
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
