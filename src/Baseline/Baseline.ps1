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
    $problems = Test-MbcBaselineShape -Baseline $doc
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
