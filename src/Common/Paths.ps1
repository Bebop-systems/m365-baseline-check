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
