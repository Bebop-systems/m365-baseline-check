function Protect-Baseline {
    <#
    .SYNOPSIS
        Validates a baseline and seals it with a SHA-256 digest of its canonical form.
    .DESCRIPTION
        Refuses to reseal changed content under the version that was sealed, so every real change is a
        new version. Prints the line to record wherever your baselines are catalogued.
    .EXAMPLE
        Protect-Baseline ./baselines/core-tenant.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, Position = 0)][string] $Path)

    $b = Read-MbcBaseline -Path $Path
    if ($b.SealState -eq 'Sealed') {
        Write-Information ('Already sealed, and unchanged since: {0} · v{1} · {2}.' -f $b.Name, $b.Version, $b.Fingerprint) -InformationAction Continue
        return (Get-MbcBaselineIdentity -Baseline $b)
    }
    if ($b.SealState -eq 'Modified' -and $b.Version -le $b.SealedVersion) {
        throw ('Content has changed since v{0} was sealed. Raise the version above {0} before sealing.' -f $b.SealedVersion)
    }

    $sealed = [ordered]@{}
    foreach ($k in $b.Document.Keys) { if ($k -ne 'seal') { $sealed[$k] = $b.Document[$k] } }
    $sealed['seal'] = [ordered]@{ algorithm = 'SHA-256'; digest = $b.Digest; sealedVersion = $b.Version }

    if ($PSCmdlet.ShouldProcess($b.Path, "Seal $($b.Name) v$($b.Version)")) {
        [System.IO.File]::WriteAllText($b.Path, (ConvertTo-MbcPrettyJson -Value $sealed), [System.Text.UTF8Encoding]::new($false))
        Write-Information ('Sealed. {0} is v{1}; its fingerprint is {2}. Record it wherever you keep these:' -f $b.Name, $b.Version, $b.Fingerprint) -InformationAction Continue
        Write-Information ('  {0} · v{1} · SHA-256 {2}' -f $b.Name, $b.Version, $b.Digest) -InformationAction Continue
    }
    return (Get-MbcBaselineIdentity -Baseline (Read-MbcBaseline -Path $b.Path))
}
