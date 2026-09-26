# Small drawing pieces. Each returns strings no wider than asked.

function Format-MbcProgressBar {
    # A smooth bar at eighth-cell resolution in Unicode; '#' and '.' in ASCII. Exactly $Width wide.
    [CmdletBinding()]
    [OutputType([string])]
    param([double] $Done, [double] $Total, [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    if ($Width -le 0) { return '' }
    $ratio = if ($Total -le 0) { 0.0 } else { [Math]::Min(1.0, [Math]::Max(0.0, $Done / $Total)) }
    $eighths = [int][Math]::Floor($ratio * $Width * 8)
    $full = [int][Math]::Floor($eighths / 8)
    $part = $eighths % 8
    $filled = $Glyphs.Bar[8] * $full
    $partial = if ($full -lt $Width -and $part -gt 0 -and $Glyphs.Bar[$part]) { $Glyphs.Bar[$part] } else { '' }
    $track = $Glyphs.Track * ($Width - $full - $partial.Length)
    return (Format-MbcStyle ($filled + $partial) 'accent' $Color) + (Format-MbcStyle $track 'dim' $Color)
}

function Get-MbcSpinnerFrame {
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Tick, [Parameter(Mandatory)][hashtable] $Glyphs)
    return $Glyphs.Spinner[[Math]::Abs($Tick) % $Glyphs.Spinner.Count]
}

function Format-MbcBox {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $Title,
        [string] $RightTitle,
        [AllowEmptyCollection()][string[]] $Lines = @(),
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][hashtable] $Glyphs,
        [bool] $Color
    )
    $inner = $Width - 4
    $t = Limit-MbcText $Title ([Math]::Max(1, $Width - 8)) $Glyphs.Ellipsis
    $right = if ($RightTitle) { " $RightTitle $($Glyphs.H)$($Glyphs.TR)" } else { "$($Glyphs.H)$($Glyphs.TR)" }
    if ($Width - 4 - $t.Length - $right.Length -lt 1) { $right = "$($Glyphs.H)$($Glyphs.TR)" }
    $fill = [Math]::Max(0, $Width - 4 - $t.Length - $right.Length)
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add((Format-MbcStyle "$($Glyphs.TL)$($Glyphs.H) " 'dim' $Color) + (Format-MbcStyle $t 'title' $Color) + ' ' +
        (Format-MbcStyle ($Glyphs.H * $fill) 'dim' $Color) + (Format-MbcStyle $right 'dim' $Color))
    foreach ($line in $Lines) {
        $body = if ((Measure-MbcWidth $line) -gt $inner) { Limit-MbcText (Remove-MbcAnsi $line) $inner $Glyphs.Ellipsis } else { $line }
        $out.Add((Format-MbcStyle "$($Glyphs.V) " 'dim' $Color) + (Format-MbcPad $body $inner) + (Format-MbcStyle " $($Glyphs.V)" 'dim' $Color))
    }
    $out.Add((Format-MbcStyle ($Glyphs.BL + ($Glyphs.H * ($Width - 2)) + $Glyphs.BR) 'dim' $Color))
    return , $out.ToArray()
}

function Format-MbcTitleBar {
    # One line: the tool and screen on the left, context on the right, a rule between.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Left, [AllowEmptyString()][string] $Right = '', [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    $l = Limit-MbcText $Left ([Math]::Max(10, $Width - 4)) $Glyphs.Ellipsis
    $roomRight = $Width - $l.Length - 6
    $r = if ($Right -and $roomRight -ge 8) { Limit-MbcText $Right $roomRight $Glyphs.Ellipsis } else { '' }
    $fill = [Math]::Max(1, $Width - 2 - $l.Length - 1 - $(if ($r) { $r.Length + 2 } else { 0 }))
    $line = ' ' + (Format-MbcStyle $l 'title' $Color) + ' ' + (Format-MbcStyle ($Glyphs.H * $fill) 'dim' $Color)
    if ($r) { $line += ' ' + (Format-MbcStyle $r 'dim' $Color) }
    return $line
}

function Format-MbcMenu {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object[]] $Items,
        [int] $Selected,
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][hashtable] $Glyphs,
        [bool] $Color
    )
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $key = [string]$Items[$i].Key
        $label = Limit-MbcText (ConvertTo-MbcGlyphText $Items[$i].Label $Glyphs) ([Math]::Max(4, $Width - 10 - $key.Length)) $Glyphs.Ellipsis
        if ($i -eq $Selected) {
            $left = "  $(Format-MbcStyle $Glyphs.Pointer 'accent' $Color) $(Format-MbcStyle $label 'bold' $Color)"
        }
        else { $left = "    $label" }
        $out.Add((Format-MbcPad $left ($Width - 2 - $key.Length)) + (Format-MbcStyle $key 'dim' $Color))
    }
    return , $out.ToArray()
}

function Format-MbcFooter {
    # Key hints, dropped from the end until they fit.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Keys, [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    $pairs = @($Keys | ForEach-Object { , @((ConvertTo-MbcGlyphText $_[0] $Glyphs), (ConvertTo-MbcGlyphText $_[1] $Glyphs)) })
    for ($n = $pairs.Count; $n -ge 1; $n--) {
        $chosen = @($pairs[0..($n - 1)])
        $plain = '  ' + (($chosen | ForEach-Object { "$($_[0]) $($_[1])" }) -join '   ')
        if ($plain.Length -le $Width) {
            return '  ' + (($chosen | ForEach-Object { (Format-MbcStyle $_[0] 'accent' $Color) + ' ' + (Format-MbcStyle $_[1] 'dim' $Color) }) -join '   ')
        }
    }
    return ''
}
