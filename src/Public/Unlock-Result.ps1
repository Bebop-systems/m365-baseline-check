function Unlock-Result {
    <#
    .SYNOPSIS
        Opens a locked result with the team key. It opens to memory; plaintext is written to disk only
        with -OutputDirectory, and then every part is written, with the run log when the bundle carries
        one (run-<stamp>.jsonl).
    .EXAMPLE
        Unlock-Result ./results/result-20260926T141200Z.locked
    .EXAMPLE
        Unlock-Result ./results/result-20260926T141200Z.locked -OutputDirectory ./unlocked
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string] $Path,
        [securestring] $Key,
        [string] $OutputDirectory,
        [switch] $AllowSyncedOutput
    )
    # Messages show unless the caller chose otherwise.
    if (-not $PSBoundParameters.ContainsKey('InformationAction')) { $InformationPreference = 'Continue' }
    if ($OutputDirectory -and -not $AllowSyncedOutput) {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
        $service = Get-MbcSyncedLocation -Path $full
        if ($service) { throw "$OutputDirectory synchronises to $service, so the plaintext would be copied to the cloud. Choose a folder that stays on this machine, or pass -AllowSyncedOutput if your policy allows it. docs/handling-results.md explains." }
    }
    $envelope = Read-MbcLockedFile -Path $Path
    $keyText = if ($Key) { ConvertFrom-MbcSecureKey -Key $Key }
    elseif ($script:MbcSessionKey) { $script:MbcSessionKey }
    else { ConvertFrom-MbcSecureKey -Key (Read-Host -AsSecureString -Prompt "Team key $($envelope['keyId'])") }

    $opened = Open-MbcLockedResult -Path $Path -KeyText $keyText
    if ($OutputDirectory -and $PSCmdlet.ShouldProcess($OutputDirectory, 'Write the unlocked result as plaintext')) {
        if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
        $stamp = Get-MbcRunStamp -RunId $opened.View.RunId
        foreach ($name in $opened.Files.Keys) {
            Write-MbcFileAtomic -Path (Join-Path $OutputDirectory (Get-MbcBundleFileName -Part $name -Stamp $stamp)) -Text $opened.Files[$name]
        }
        Write-Information "Unlocked into $OutputDirectory. Those files are plaintext and confidential: keep them on this machine and delete them when done (docs/handling-results.md)."
    }
    return $opened
}
