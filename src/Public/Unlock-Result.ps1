function Unlock-Result {
    <#
    .SYNOPSIS
        Opens a locked result with the team key. It opens to memory; plaintext is written to disk only
        with -OutputDirectory, and then every part is written.
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
        [string] $OutputDirectory
    )
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
        Write-Information "Unlocked into $OutputDirectory. Those files are plaintext; file them accordingly." -InformationAction Continue
    }
    return $opened
}
