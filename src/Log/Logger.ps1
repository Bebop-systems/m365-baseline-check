# The run log: JSON lines, one file per run, verbose on purpose. Secrets never reach it (invariant 6): a
# field of our own with a secret-looking name is refused outright, and inside tenant data (actual and
# expected values, parameters) a secret-looking key has its value replaced before anything is written.
$script:MbcSecretKeyFragments = @('token', 'authorization', 'secret', 'password', 'passphrase', 'credential', 'teamkey', 'cookie')
$script:MbcLogValueLimit = 2048

function Test-MbcSecretName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string] $Name)
    return ($Name -ieq 'key' -or (Test-MbcContainsAny -Text $Name -Fragments $script:MbcSecretKeyFragments))
}

function Assert-MbcLogSafe {
    # Our own field names: a secret-looking one is a bug in this tool, so it stops the write.
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary] $Data)
    if ($null -eq $Data) { return }
    foreach ($k in $Data.Keys) {
        if (Test-MbcSecretName -Name ([string]$k)) { throw "A value named '$k' looks like a secret, and secrets are never logged." }
    }
}

function Protect-MbcLogValue {
    # A copy of tenant data with the value under any secret-looking key replaced. Never throws.
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object] $Value)
    if (Test-MbcIsDictionary $Value) {
        $copy = [ordered]@{}
        foreach ($k in $Value.Keys) {
            $copy[[string]$k] = if (Test-MbcSecretName -Name ([string]$k)) { '[withheld]' } else { Protect-MbcLogValue -Value $Value[$k] }
        }
        return $copy
    }
    if (Test-MbcIsList $Value) { return , @($Value | ForEach-Object { Protect-MbcLogValue -Value $_ }) }
    return $Value
}

function Limit-MbcLogValue {
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object] $Value)
    $text = ConvertTo-MbcCanonicalJson -Value $Value
    if ($text.Length -le $script:MbcLogValueLimit) { return , $Value }
    return [ordered]@{ truncated = $true; length = $text.Length; preview = $text.Substring(0, 512) }
}

function New-MbcRunLog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $RunId,
        # The baseline's full digest, written into every line so any line on its own says what it belongs to.
        [AllowEmptyString()][string] $Digest = ''
    )
    $path = Join-Path $Directory "run-$RunId.jsonl"
    New-MbcPrivateFile -Path $path
    $fingerprint = if ($Digest.Length -ge 12) { $Digest.Substring(0, 12) } else { $Digest }
    return [pscustomobject]@{ PSTypeName = 'Mbc.Log'; Path = $path; RunId = $RunId; Digest = $Digest; Fingerprint = $fingerprint; State = @{ Seq = 0 } }
}

function Write-MbcLog {
    [CmdletBinding()]
    param(
        [AllowNull()] $Log,
        [Parameter(Mandatory)][string] $EventName,
        [System.Collections.IDictionary] $Data = @{}
    )
    if ($null -eq $Log) { return }
    Assert-MbcLogSafe -Data $Data
    $Log.State.Seq++
    $entry = [ordered]@{
        ts          = [datetime]::UtcNow.ToString('o', [cultureinfo]::InvariantCulture)
        run         = $Log.RunId
        baseline    = $Log.Digest
        fingerprint = $Log.Fingerprint
        seq         = $Log.State.Seq
        event       = $EventName
    }
    foreach ($k in $Data.Keys) { $entry[[string]$k] = Limit-MbcLogValue -Value (Protect-MbcLogValue -Value $Data[$k]) }
    $line = ConvertTo-MbcCanonicalJson -Value $entry
    [System.IO.File]::AppendAllText($Log.Path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Verbose $line
}
