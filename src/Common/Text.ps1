# Text for people: styles, widths, truncation and wrapping, shared by the text report and the TUI. Pure
# functions over strings, with no regular expressions. Widths count characters; every glyph used here is
# one cell wide.

$script:MbcEsc = [char]27
$script:MbcAnsi = @{
    ok      = "$([char]27)[32m"
    bad     = "$([char]27)[31m"
    warn    = "$([char]27)[33m"
    dim     = "$([char]27)[90m"
    accent  = "$([char]27)[36m"
    bold    = "$([char]27)[1m"
    reverse = "$([char]27)[7m"
    title   = "$([char]27)[1;36m"
}
$script:MbcAnsiReset = "$([char]27)[0m"

function Get-MbcGlyphs {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][bool] $Unicode)
    if ($Unicode) {
        return @{
            Unicode = $true; Pass = '✓'; Fail = '✗'; Error = '?'; Pointer = '▸'; Ellipsis = '…'; Dot = '·'; Arrow = '→'; Seal = '✓'
            H = '─'; V = '│'; TL = '╭'; TR = '╮'; BL = '╰'; BR = '╯'; Track = '─'; Cursor = '▏'; Bullet = '•'; Collapsed = '▸'; Expanded = '▾'
            Spinner = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
            Bar = @('', '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█')
        }
    }
    return @{
        Unicode = $false; Pass = '+'; Fail = 'x'; Error = '?'; Pointer = '>'; Ellipsis = '~'; Dot = '-'; Arrow = '->'; Seal = 'ok'
        H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'; Track = '.'; Cursor = '_'; Bullet = '*'; Collapsed = '>'; Expanded = 'v'
        Spinner = @('|', '/', '-', '\')
        Bar = @('', '', '', '', '', '', '', '', '#')
    }
}

function ConvertTo-MbcGlyphText {
    # Labels are written with Unicode punctuation; ASCII mode swaps each for a plain equivalent.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text, [Parameter(Position = 1)][hashtable] $Glyphs)
    if ($null -eq $Text) { return '' }
    if ($Glyphs.Unicode) { return $Text }
    $out = $Text.Replace('↑↓', 'Up/Dn').Replace('↑', 'Up').Replace('↓', 'Dn').Replace('…', '...').Replace('·', '-').Replace('→', '->').Replace('›', '>')
    # By code point: PowerShell reads typographic quotes in source as quotes.
    foreach ($pair in @(@(0x2018, "'"), @(0x2019, "'"), @(0x201C, '"'), @(0x201D, '"'), @(0x2013, '-'), @(0x2014, '-'), @(0x2022, '*'))) {
        $out = $out.Replace([string][char]$pair[0], $pair[1])
    }
    $sb = [System.Text.StringBuilder]::new($out.Length)
    foreach ($ch in $out.ToCharArray()) { if ([int]$ch -lt 128) { [void]$sb.Append($ch) } else { [void]$sb.Append('?') } }
    return $sb.ToString()
}

function Format-MbcStyle {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text,
        [Parameter(Position = 1)][string] $Style,
        [Parameter(Position = 2)][bool] $Color
    )
    if (-not $Color -or [string]::IsNullOrEmpty($Text) -or -not $script:MbcAnsi.ContainsKey([string]$Style)) { return [string]$Text }
    return "$($script:MbcAnsi[$Style])$Text$($script:MbcAnsiReset)"
}

function Remove-MbcAnsi {
    # Drops CSI sequences: ESC, '[', parameters, then one final letter.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text)
    if ([string]::IsNullOrEmpty($Text) -or $Text.IndexOf($script:MbcEsc) -lt 0) { return [string]$Text }
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $i = 0
    while ($i -lt $Text.Length) {
        if ($Text[$i] -eq $script:MbcEsc -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -ceq '[') {
            $i += 2
            while ($i -lt $Text.Length -and -not (Test-MbcAsciiLetter $Text[$i])) { $i++ }
            $i++
            continue
        }
        [void]$sb.Append($Text[$i])
        $i++
    }
    return $sb.ToString()
}

function Measure-MbcWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return (Remove-MbcAnsi $Text).Length
}

function Limit-MbcText {
    # Plain text cut to a width, ending with an ellipsis when cut.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text,
        [Parameter(Position = 1)][int] $Width,
        [Parameter(Position = 2)][string] $Ellipsis = '…'
    )
    $t = [string]$Text
    if ($Width -le 0) { return '' }
    if ($t.Length -le $Width) { return $t }
    if ($Width -le $Ellipsis.Length) { return $t.Substring(0, $Width) }
    return $t.Substring(0, $Width - $Ellipsis.Length) + $Ellipsis
}

function Format-MbcPad {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string] $Text,
        [Parameter(Position = 1)][int] $Width,
        [switch] $Right
    )
    $t = [string]$Text
    $gap = $Width - (Measure-MbcWidth $t)
    if ($gap -le 0) { return $t }
    if ($Right) { return (' ' * $gap) + $t }
    return $t + (' ' * $gap)
}

function Split-MbcWrapped {
    # Word-wraps plain text to a width. A word longer than the width is cut with an ellipsis.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyString()][AllowNull()][string] $Text, [int] $Width, [string] $Ellipsis = '…')
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($word in ([string]$Text).Split([char[]]@(' ', "`t", "`n", "`r"), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if ($word.Length -gt $Width) { $word = Limit-MbcText $word $Width $Ellipsis }
        if ($current.Length -eq 0) { $current = $word }
        elseif ($current.Length + 1 + $word.Length -le $Width) { $current += " $word" }
        else { $lines.Add($current); $current = $word }
    }
    if ($current.Length -gt 0) { $lines.Add($current) }
    if ($lines.Count -eq 0) { $lines.Add('') }
    return , $lines.ToArray()
}

function Join-MbcColumns {
    # Left text and right text on one line of exactly $Width, or just the left when they can't both fit.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Left, [AllowEmptyString()][string] $Right, [int] $Width)
    $gap = $Width - (Measure-MbcWidth $Left) - (Measure-MbcWidth $Right)
    if ($gap -lt 1) { return $Left }
    return $Left + (' ' * $gap) + $Right
}

function Format-MbcRunTime {
    # An ISO 8601 timestamp as people read it: 2026-09-26 14:12 UTC. Anything unparseable comes back as is.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string] $Iso)
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Iso, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) + ' UTC'
    }
    return [string]$Iso
}

function Test-MbcUnicodeOutput {
    # Whether plain output may use Unicode glyphs: a UTF-8 console, and M365BC_ASCII not set.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($env:M365BC_ASCII) { return $false }
    try { return ([Console]::OutputEncoding.CodePage -eq 65001) } catch { return $false }
}

function Get-MbcPlainWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $width = 100
    try { if (-not [Console]::IsOutputRedirected -and [Console]::WindowWidth -gt 0) { $width = [Console]::WindowWidth - 1 } } catch { $width = 100 }
    return [Math]::Max(60, [Math]::Min(120, $width))
}
