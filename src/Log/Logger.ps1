# The run log: JSON lines, one file per run, verbose on purpose. Secrets are refused by key name before
# anything is written (invariant 6).
$script:MbcSecretKeyFragments = @('token', 'authorization', 'secret', 'password', 'passphrase', 'credential', 'teamkey', 'cookie')
$script:MbcLogValueLimit = 2048

function Assert-MbcLogSafe {
    [CmdletBinding()]
    param([AllowNull()][object] $Data)
    if (Test-MbcIsDictionary $Data) {
        foreach ($k in $Data.Keys) {
            $name = [string]$k
            if ($name -ieq 'key' -or (Test-MbcContainsAny -Text $name -Fragments $script:MbcSecretKeyFragments)) {
                throw "A value named '$name' looks like a secret, and secrets are never logged."
            }
            Assert-MbcLogSafe -Data $Data[$k]
        }
    }
    elseif (Test-MbcIsList $Data) {
        foreach ($item in $Data) { Assert-MbcLogSafe -Data $item }
    }
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
    [System.IO.File]::WriteAllText($path, '', [System.Text.UTF8Encoding]::new($false))
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
    foreach ($k in $Data.Keys) { $entry[[string]$k] = Limit-MbcLogValue -Value $Data[$k] }
    $line = ConvertTo-MbcCanonicalJson -Value $entry
    [System.IO.File]::AppendAllText($Log.Path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Verbose $line
}
