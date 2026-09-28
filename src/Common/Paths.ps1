function Resolve-MbcFullPath {
    # A path as PowerShell means it: ~ is home, and a relative path is relative to the current location,
    # not the process's working folder. .NET's GetFullPath knows neither.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Resolve-MbcOutputBase {
    # The full path of the folder the tool would write under, without creating anything.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Root)
    $base = if ($Root) { $Root } elseif ($env:M365BC_HOME) { $env:M365BC_HOME } else { Join-Path $HOME 'M365BaselineCheck' }
    return (Resolve-MbcFullPath -Path $base)
}

function Get-MbcOutputRoot {
    <#
    .SYNOPSIS
        The folder the tool writes under: -Root, else $env:M365BC_HOME, else ~/M365BaselineCheck. It
        creates logs/, results/, presets/ and baselines/ inside it. Nothing is written anywhere else. On
        macOS and Linux those folders, and the folder itself when the tool creates it, are private to
        their owner (700).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Root)
    $base = Resolve-MbcOutputBase -Root $Root
    if (-not (Test-Path -LiteralPath $base)) {
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        Set-MbcPrivateMode -Path $base -Directory
    }
    foreach ($sub in 'logs', 'results', 'presets', 'baselines') {
        $path = Join-Path $base $sub
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        Set-MbcPrivateMode -Path $path -Directory
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
    $full = Resolve-MbcFullPath -Path $Path
    $temp = '{0}.{1}.tmp' -f $full, [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        # Private from the moment it exists (600 on macOS and Linux), and the move keeps the mode.
        New-MbcPrivateFile -Path $temp -Text $Text
        [System.IO.File]::Move($temp, $full, $true)
    }
    finally {
        if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
    }
}
