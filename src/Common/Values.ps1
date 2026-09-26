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
