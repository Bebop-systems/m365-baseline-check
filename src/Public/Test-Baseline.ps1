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
    # Messages show unless the caller chose otherwise.
    if (-not $PSBoundParameters.ContainsKey('InformationAction')) { $InformationPreference = 'Continue' }
    $b = Read-MbcBaseline -Path $Path
    $state = switch ($b.SealState) {
        'Sealed' { 'sealed, and unchanged since' }
        'Unsealed' { 'not sealed' }
        'Modified' { "edited since v$($b.SealedVersion) was sealed" }
    }
    Write-Information ('{0} · v{1} · {2} · {3}' -f $b.Name, $b.Version, $b.Fingerprint, $state)
    return (Get-MbcBaselineIdentity -Baseline $b)
}
