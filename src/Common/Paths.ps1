function Get-MbcOutputRoot {
    <#
    .SYNOPSIS
        The folder the tool writes under: -Root, else $env:M365BC_HOME, else ~/M365BaselineCheck. It
        creates logs/, results/, presets/ and baselines/ inside it. Nothing is written anywhere else.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Root)
    $base = if ($Root) { $Root } elseif ($env:M365BC_HOME) { $env:M365BC_HOME } else { Join-Path $HOME 'M365BaselineCheck' }
    foreach ($sub in 'logs', 'results', 'presets', 'baselines') {
        $path = Join-Path $base $sub
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    return (Resolve-Path -LiteralPath $base).ProviderPath
}

function New-MbcRunId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return ('{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [cultureinfo]::InvariantCulture), [guid]::NewGuid().ToString('N').Substring(0, 6))
}

function Get-MbcRunStamp {
    # The time part of a run ID: 20260926T141200Z.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $RunId)
    $dash = $RunId.IndexOf('-')
    if ($dash -lt 0) { return $RunId }
    return $RunId.Substring(0, $dash)
}

function Write-MbcFileAtomic {
    <#
    .SYNOPSIS
        Writes UTF-8 text without a BOM to a temporary file beside the target, then moves it into place,
        so a reader never sees half a file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $full = [System.IO.Path]::GetFullPath($Path)
    $temp = '{0}.{1}.tmp' -f $full, [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [System.IO.File]::WriteAllText($temp, $Text, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temp, $full, $true)
    }
    finally {
        if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
    }
}
