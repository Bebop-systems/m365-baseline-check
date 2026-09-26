function New-ResultKey {
    <#
    .SYNOPSIS
        Generates a team key for locking results. It is shown once, and nothing is written to disk.
    .DESCRIPTION
        Store the key in one entry in your team's password manager, named with its key ID. Everyone who
        holds it can read every result locked with it; a new key has a new ID, and each locked file names
        the ID it needs.
    .EXAMPLE
        New-ResultKey
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Messages show unless the caller chose otherwise.
    if (-not $PSBoundParameters.ContainsKey('InformationAction')) { $InformationPreference = 'Continue' }
    $text = New-MbcTeamKeyText
    $id = $text.Split(':')[2]
    Write-Information "Store this in one entry in your team's password manager, named 'M365 Baseline Check · results key $id'."
    Write-Information "It won't be shown again, and nothing has been saved to disk."
    return $text
}
