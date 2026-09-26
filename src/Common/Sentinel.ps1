# One object, compared by reference: "this path resolved to nothing". Never equal to null or an empty list.
$script:MbcNotFound = [pscustomobject]@{ PSTypeName = 'Mbc.NotFound' }

function Test-MbcNotFound {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    return [object]::ReferenceEquals($Value, $script:MbcNotFound)
}
