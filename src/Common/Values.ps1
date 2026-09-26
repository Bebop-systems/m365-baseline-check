function Test-MbcIsWholeNumberType {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int] -or $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64])
}

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

# Character classes by code point. PowerShell's -eq on characters ignores case, so these never use it.
function Test-MbcAsciiLetter {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][char] $Char)
    $n = [int]$Char
    return (($n -ge 65 -and $n -le 90) -or ($n -ge 97 -and $n -le 122))
}

function Test-MbcAsciiUpper {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][char] $Char)
    $n = [int]$Char
    return ($n -ge 65 -and $n -le 90)
}

function Test-MbcAsciiDigit {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][char] $Char)
    $n = [int]$Char
    return ($n -ge 48 -and $n -le 57)
}

function Test-MbcAsciiAlnum {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][char] $Char)
    return ((Test-MbcAsciiLetter $Char) -or (Test-MbcAsciiDigit $Char))
}

function Test-MbcAllChars {
    <#
    .SYNOPSIS
        True when every character of a non-empty string is in a set of allowed ASCII characters: letters
        and digits when asked, plus any characters listed in -Also.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [switch] $Letters,
        [switch] $Digits,
        [string] $Also = ''
    )
    if ($Text.Length -eq 0) { return $false }
    foreach ($ch in $Text.ToCharArray()) {
        if ($Letters -and (Test-MbcAsciiLetter $ch)) { continue }
        if ($Digits -and (Test-MbcAsciiDigit $ch)) { continue }
        if ($Also.IndexOf($ch) -ge 0) { continue }
        return $false
    }
    return $true
}

function Test-MbcLowerHex {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Text, [int] $MinLength = 1, [int] $MaxLength = [int]::MaxValue)
    if ($Text -isnot [string] -or $Text.Length -lt $MinLength -or $Text.Length -gt $MaxLength) { return $false }
    return (Test-MbcAllChars -Text $Text -Digits -Also 'abcdef')
}

function Test-MbcHasWhiteSpace {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    foreach ($ch in $Text.ToCharArray()) { if ([char]::IsWhiteSpace($ch)) { return $true } }
    return $false
}

function Test-MbcContainsAny {
    # Case-insensitive, ordinal: does the text contain any of these fragments?
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [Parameter(Mandatory)][string[]] $Fragments)
    foreach ($f in $Fragments) { if ($Text.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    return $false
}
