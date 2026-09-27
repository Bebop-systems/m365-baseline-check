# The results as people read them: grouped by admin centre, in the portal's words, values through labels.
# One set of pure renderers draws the TUI's screens and report.txt (spec 10.2, 10.4).

$script:MbcVerdictStyles = @{ Pass = 'ok'; Fail = 'bad'; Error = 'warn' }
$script:MbcTagWidth = 14

function Format-MbcDisplayValue {
    # A value as the portal would show it: through the check's labels when one matches, else plainly.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object] $Value, [AllowNull()][System.Collections.IDictionary] $Labels)
    if (Test-MbcIsScalar $Value) {
        $key = ConvertTo-MbcCanonicalJson -Value $Value
        if ($Labels -and $Labels.Contains($key)) { return [string]$Labels[$key] }
        if ($null -eq $Value) { return 'not set' }
        if ($Value -is [string]) { if ($Value.Length -eq 0) { return '(empty)' } else { return $Value } }
        return $key
    }
    if (Test-MbcIsList $Value) {
        if ($Value.Count -eq 0) { return 'none' }
        return (@($Value | ForEach-Object { Format-MbcDisplayValue -Value $_ -Labels $Labels }) -join ', ')
    }
    return (ConvertTo-MbcCanonicalJson -Value $Value)
}

function Format-MbcExpectedText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Result)
    $e = Format-MbcDisplayValue -Value $Result.Expected -Labels $Result.Labels
    switch ($Result.Operator) {
        'notEquals' { return "anything but $e" }
        'in' { return "one of $e" }
        'contains' { return "includes $e" }
        'setEquals' { return "exactly $e" }
        'subsetOf' { return "only $e" }
        'countAtLeast' { return "at least $e" }
        'countAtMost' { return "at most $e" }
        'matches' { return "matches $e" }
        'exists' { return 'present' }
        'absent' { return 'absent' }
    }
    return $e
}

function Format-MbcActualText {
    # -Short gives the count alone for the count operators, for the one-line comparison.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Result, [switch] $Short)
    if ($Result.Operator -in 'exists', 'absent') { if ($Result.HasActual) { return 'present' } else { return 'absent' } }
    if (-not $Result.HasActual) { if ($Result.Verdict -eq 'Error' -and $Result.Cause -ne 'setting not found') { return 'not read' } else { return 'nothing' } }
    if ($Result.Operator -in 'countAtLeast', 'countAtMost' -and (Test-MbcIsList $Result.Actual)) {
        $n = $Result.Actual.Count
        if ($Short -or $n -eq 0) { return [string]$n }
        return "$n ($(Format-MbcDisplayValue -Value $Result.Actual -Labels $Result.Labels))"
    }
    return (Format-MbcDisplayValue -Value $Result.Actual -Labels $Result.Labels)
}

function Format-MbcComparisonText {
    # actual → expected, the note on a Not met row.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)][hashtable] $Glyphs)
    return ('{0} {1} {2}' -f (Format-MbcActualText -Result $Result -Short), $Glyphs.Arrow, (Format-MbcExpectedText -Result $Result))
}

function Get-MbcAreaGroups {
    # Results grouped by area, in the admin centres' fixed order, then any other area by name.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Results)
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $script:MbcAreaNames.Keys) { $order.Add($a) }
    foreach ($r in $Results) { if (-not $order.Contains($r.Area)) { $order.Add($r.Area) } }
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($area in $order) {
        $members = @($Results | Where-Object { $_.Area -eq $area })
        if ($members.Count -eq 0) { continue }
        $counts = Get-MbcCounts -Results $members
        $groups.Add([pscustomobject]@{ Area = $area; Name = (Get-MbcAreaName -Area $area); Results = $members; Met = $counts.Pass; NotMet = $counts.Fail; Unverifiable = $counts.Error })
    }
    return , $groups.ToArray()
}

function Test-MbcResultMatches {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Result, [AllowEmptyString()][string] $Filter = 'attention', [AllowEmptyString()][string] $Search = '')
    $ok = switch ($Filter) {
        'fail' { $Result.Verdict -eq 'Fail' }
        'error' { $Result.Verdict -eq 'Error' }
        'all' { $true }
        default { $Result.Verdict -ne 'Pass' }
    }
    if (-not $ok) { return $false }
    if ($Search) { return (Test-MbcContainsAny -Text "$($Result.Id) $($Result.Title) $($Result.Location)" -Fragments @($Search)) }
    return $true
}

function Get-MbcResultRows {
    <#
    .SYNOPSIS
        The rows of the results screen, in order: a heading per area, then that area's rows that pass
        the filter. In the default attention filter, an area with nothing to attend to shows as its
        heading alone. The other filters leave out areas with no matching rows. An expanded area shows
        all of its rows, whatever the filter.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Results,
        [AllowEmptyString()][string] $Filter = 'attention',
        [AllowEmptyString()][string] $Search = '',
        [AllowEmptyCollection()][string[]] $Expanded = @()
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($g in (Get-MbcAreaGroups -Results $Results)) {
        $open = $g.Area -in $Expanded
        $shownFilter = if ($open) { 'all' } else { $Filter }
        $shown = @($g.Results | Where-Object { Test-MbcResultMatches -Result $_ -Filter $shownFilter -Search $Search })
        if ($shown.Count -eq 0 -and -not $open -and ($Filter -ne 'attention' -or $Search)) { continue }
        $rows.Add([pscustomobject]@{ Kind = 'heading'; Group = $g; Result = $null; Collapsed = ($shown.Count -eq 0) })
        foreach ($r in $shown) { $rows.Add([pscustomobject]@{ Kind = 'result'; Group = $g; Result = $r; Collapsed = $false }) }
    }
    return , $rows.ToArray()
}

function Format-MbcVerdictTag {
    # Word plus symbol, padded to one width, coloured: readable in greyscale.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Verdict, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color, [int] $Width = $script:MbcTagWidth)
    $symbol = switch ($Verdict) { 'Pass' { $Glyphs.Pass } 'Fail' { $Glyphs.Fail } default { $Glyphs.Error } }
    $text = Format-MbcPad "$symbol $($script:MbcVerdictWords[$Verdict])" $Width
    return (Format-MbcStyle $text $script:MbcVerdictStyles[$Verdict] $Color)
}

function Format-MbcGroupHeading {
    # Exchange  9 met · 2 not · 1 unverifiable
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Group,
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][hashtable] $Glyphs,
        [bool] $Color,
        [AllowNull()] $Collapsed,
        [switch] $Selected
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((Format-MbcStyle "$($Group.Met) met" 'ok' ($Color -and -not $Selected)))
    if ($Group.NotMet -gt 0) { $parts.Add((Format-MbcStyle "$($Group.NotMet) not" 'bad' ($Color -and -not $Selected))) }
    if ($Group.Unverifiable -gt 0) { $parts.Add((Format-MbcStyle "$($Group.Unverifiable) unverifiable" 'warn' ($Color -and -not $Selected))) }
    $marker = if ($null -eq $Collapsed) { '' } elseif ($Collapsed) { "$($Glyphs.Collapsed) " } else { "$($Glyphs.Expanded) " }
    $name = Limit-MbcText $Group.Name ([Math]::Max(4, $Width - 40)) $Glyphs.Ellipsis
    $line = "  $marker" + (Format-MbcStyle $name 'title' ($Color -and -not $Selected)) + '  ' + ($parts -join " $($Glyphs.Dot) ")
    if ($Selected) { return (Format-MbcSelected -Text (Limit-MbcText (Remove-MbcAnsi $line) $Width $Glyphs.Ellipsis) -Width $Width -Glyphs $Glyphs -Color $Color) }
    return $line
}

function Format-MbcSelected {
    # A selected row: a pointer in the first column, which reads without colour, plus reverse video.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    $plain = if ($Text.Length -gt 0) { $Glyphs.Pointer + $Text.Substring(1) } else { $Glyphs.Pointer }
    return (Format-MbcStyle (Format-MbcPad $plain $Width) 'reverse' $Color)
}

function Format-MbcResultRow {
    # ✗ Not met      Users can register applications            Yes → No
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][hashtable] $Glyphs,
        [bool] $Color,
        [switch] $Selected
    )
    $indent = 4
    $rest = [Math]::Max(10, $Width - $indent - $script:MbcTagWidth - 2)
    $actual = ''
    $expected = ''
    $note = switch ($Result.Verdict) {
        'Fail' {
            $actual = ConvertTo-MbcGlyphText (Format-MbcActualText -Result $Result -Short) $Glyphs
            $expected = ConvertTo-MbcGlyphText (Format-MbcExpectedText -Result $Result) $Glyphs
            "$actual $($Glyphs.Arrow) $expected"
        }
        'Error' { ConvertTo-MbcGlyphText ([string]$Result.Cause) $Glyphs }
        default { '' }
    }
    $title = ConvertTo-MbcGlyphText $Result.Title $Glyphs
    if ($note) {
        # The title keeps what it needs when there is room; otherwise the two share it, the title at most half.
        $titleWidth = $rest - $note.Length - 2
        if ($titleWidth -lt $title.Length) { $titleWidth = [Math]::Max([Math]::Min($title.Length, [int][Math]::Floor($rest * 0.5)), $titleWidth) }
        $titleWidth = [Math]::Min([Math]::Max(6, $titleWidth), [Math]::Max(6, $rest - 12))
        $noteWidth = [Math]::Max(0, $rest - $titleWidth - 2)
        $plainTitle = Format-MbcPad (Limit-MbcText $title $titleWidth $Glyphs.Ellipsis) $titleWidth
        if ($note.Length -le $noteWidth -or $Result.Verdict -ne 'Fail') { $plainNote = Limit-MbcText $note $noteWidth $Glyphs.Ellipsis }
        else {
            # Too long for its column: cut each side in proportion, so the row still reads actual → expected.
            $arrow = " $($Glyphs.Arrow) "
            $room = [Math]::Max(2, $noteWidth - $arrow.Length)
            $actualWidth = [Math]::Min($actual.Length, [Math]::Max([int][Math]::Floor($room / 2), $room - $expected.Length))
            $plainNote = (Limit-MbcText $actual $actualWidth $Glyphs.Ellipsis) + $arrow + (Limit-MbcText $expected ($room - $actualWidth) $Glyphs.Ellipsis)
        }
        $plainNote = Format-MbcPad $plainNote $noteWidth -Right
    }
    else {
        $plainTitle = Limit-MbcText $title $rest $Glyphs.Ellipsis
        $plainNote = ''
    }
    if ($Selected) {
        $tagPlain = Remove-MbcAnsi (Format-MbcVerdictTag -Verdict $Result.Verdict -Glyphs $Glyphs -Color $false)
        $line = (' ' * $indent) + $tagPlain + '  ' + $plainTitle + $(if ($plainNote) { "  $plainNote" } else { '' })
        return (Format-MbcSelected -Text $line -Width $Width -Glyphs $Glyphs -Color $Color)
    }
    $noteStyle = if ($Result.Verdict -eq 'Error') { 'dim' } else { '' }
    $line = (' ' * $indent) + (Format-MbcVerdictTag -Verdict $Result.Verdict -Glyphs $Glyphs -Color $Color) + '  ' + $plainTitle
    if ($plainNote) { $line += '  ' + (Format-MbcStyle $plainNote $noteStyle $Color) }
    return $line
}

function Format-MbcRowLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Row, [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color, [switch] $Selected, [switch] $Marker)
    if ($Row.Kind -eq 'heading') {
        $collapsed = if ($Marker) { $Row.Collapsed } else { $null }
        return (Format-MbcGroupHeading -Group $Row.Group -Width $Width -Glyphs $Glyphs -Color $Color -Collapsed $collapsed -Selected:$Selected)
    }
    return (Format-MbcResultRow -Result $Row.Result -Width $Width -Glyphs $Glyphs -Color $Color -Selected:$Selected)
}

function Format-MbcField {
    # A labelled field, wrapped under its label: 'Expected   No'.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $Label,
        [AllowEmptyString()][AllowNull()][string] $Text,
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][hashtable] $Glyphs,
        [bool] $Color,
        [int] $Indent = 2,
        [int] $LabelWidth = 11
    )
    $out = [System.Collections.Generic.List[string]]::new()
    $first = $true
    foreach ($piece in (Split-MbcWrapped -Text (ConvertTo-MbcGlyphText $Text $Glyphs) -Width ([Math]::Max(10, $Width - $Indent - $LabelWidth)) -Ellipsis $Glyphs.Ellipsis)) {
        $prefix = if ($first) { Format-MbcStyle (Format-MbcPad $Label $LabelWidth) 'dim' $Color } else { ' ' * $LabelWidth }
        $out.Add((' ' * $Indent) + $prefix + $piece)
        $first = $false
    }
    return , $out.ToArray()
}

$script:MbcCauseAdvice = @{
    'permission missing'              = 'The account, or the scopes it was granted, cannot read this. The sign-in line shows what was granted.'
    'not found'                       = 'The service says this object does not exist in this tenant.'
    'throttled'                       = 'The service kept asking for pauses. Run again in a few minutes.'
    'service error'                   = 'The service failed to answer. Run again; if it persists, the log has the details.'
    'malformed response'              = 'The answer was not what the service documents. The log has it.'
    'request rejected'                = 'The request itself was refused. The preset may be using a path or parameter the service does not accept.'
    'too many pages'                  = 'The answer ran past the page limit. Narrow the request in the preset.'
    'setting not found'               = 'The path found nothing in the answer: the setting may not exist in this tenant, or the preset''s path is wrong.'
    'baseline expects a list'         = 'The baseline expects a list here and found a single value; the baseline needs correcting.'
    'baseline expects a single value' = 'The baseline expects a single value here and found a list; the baseline needs correcting.'
    'invalid pattern'                 = 'The baseline''s regular expression does not compile.'
    'pattern too slow'                = 'The baseline''s regular expression took longer than a second.'
    'request not declared'            = 'The preset does not declare this request, so it was not sent. Declare it and seal again.'
    'not connected'                   = 'This source''s session did not connect. Sign in again and rerun.'
    'cmdlet not available'            = 'The session has no such cmdlet. The account may lack the role that provides it.'
    'cmdlet failed'                   = 'The cmdlet stopped with an error. The log has it.'
    'not collected'                   = 'Nothing was read for this check. The log has what happened.'
}

function Get-MbcCauseAdvice {
    # One sentence on what to do about a cause, for the detail view and the report.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Cause)
    if ($script:MbcCauseAdvice.ContainsKey($Cause)) { return $script:MbcCauseAdvice[$Cause] }
    return 'The log has the details.'
}

function Format-MbcDetailLines {
    # Everything about one check: where it lives, expected against actual, what was read, and why.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][hashtable] $Glyphs,
        [bool] $Color,
        [AllowEmptyString()][string] $RunId = ''
    )
    $out = [System.Collections.Generic.List[string]]::new()
    $head = '  ' + (Format-MbcVerdictTag -Verdict $Result.Verdict -Glyphs $Glyphs -Color $Color -Width 0) + '  ' +
        (Format-MbcStyle $Result.Id 'bold' $Color) + (Format-MbcStyle "  $($Result.Severity) severity $($Glyphs.Dot) $(Get-MbcAreaName -Area $Result.Area)" 'dim' $Color)
    $out.Add($head)
    foreach ($line in (Split-MbcWrapped -Text (ConvertTo-MbcGlyphText $Result.Title $Glyphs) -Width ($Width - 4) -Ellipsis $Glyphs.Ellipsis)) { $out.Add('  ' + (Format-MbcStyle $line 'bold' $Color)) }
    $out.Add('')
    $add = { param($label, $text) foreach ($l in (Format-MbcField -Label $label -Text $text -Width $Width -Glyphs $Glyphs -Color $Color)) { $out.Add($l) } }
    if ($Result.Location) { & $add 'Where' $Result.Location }
    & $add 'Expected' (Format-MbcExpectedText -Result $Result)
    & $add 'Actual' (Format-MbcActualText -Result $Result)
    if ($Result.Verdict -eq 'Error') {
        & $add 'Cause' ("$($Result.Cause)" + $(if ($Result.Detail) { " ($($Result.Detail))" } else { '' }))
        & $add 'Next' (Get-MbcCauseAdvice -Cause ([string]$Result.Cause))
    }
    & $add 'Read' (Format-MbcRequestText -Source $Result.Source -ApiVersion $Result.ApiVersion -Request $Result.Request -Parameters $Result.Parameters)
    if ($Result.Select) { & $add 'Path' $Result.Select }
    & $add 'Compared' $Result.Operator
    $sourceName = if ($script:MbcSourceNames.Contains($Result.Source)) { $script:MbcSourceNames[$Result.Source] } else { $Result.Source }
    if ($Result.Source -eq 'graph' -and $Result.ApiVersion -eq 'beta') { $sourceName += ' (beta)' }
    & $add 'Source' $sourceName
    if ($Result.Why) { & $add 'Why' $Result.Why }
    if ($RunId) { & $add 'Log' "run-$RunId.jsonl, check $($Result.Id)" }
    return , $out.ToArray()
}

function Get-MbcConsentSummary {
    # 2 admin · 3 user (2 people) · 1 app, counting permission names.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)][hashtable] $Glyphs)
    $admin = 0; $user = 0; $people = 0; $appPerms = 0
    foreach ($d in @($App.Delegated)) {
        if ($d.Type -eq 'admin') { $admin += @($d.Scopes).Count } else { $user += @($d.Scopes).Count }
    }
    foreach ($a in @($App.Application)) { $appPerms += @($a.Roles).Count }
    $people = [int]$App.UserConsentCount
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($admin) { $parts.Add("$admin admin") }
    if ($user) { $parts.Add("$user user ($people $(if ($people -eq 1) { 'person' } else { 'people' }))") }
    if ($appPerms) { $parts.Add("$appPerms app") }
    if ($parts.Count -eq 0) { return 'no consents' }
    return ($parts -join " $($Glyphs.Dot) ")
}

function Get-MbcAppsColumns {
    [CmdletBinding()]
    [OutputType([int[]])]
    param([Parameter(Mandatory)][int] $Width)
    # Name (flexible), publisher, verified, consents; separated by two spaces, indented by four.
    $verified = 8
    $consents = [Math]::Min(34, [Math]::Max(12, [int]($Width * 0.3)))
    $publisher = [Math]::Min(26, [Math]::Max(8, [int]($Width * 0.2)))
    $name = [Math]::Max(8, $Width - 4 - $publisher - $verified - $consents - 6)
    return , @($name, $publisher, $verified, $consents)
}

function Format-MbcAppsHeader {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int] $Width, [bool] $Color)
    $c = Get-MbcAppsColumns -Width $Width
    $text = '    ' + (Format-MbcPad 'App' $c[0]) + '  ' + (Format-MbcPad 'Publisher' $c[1]) + '  ' + (Format-MbcPad 'Verified' $c[2]) + '  ' + 'Consents'
    return (Format-MbcStyle $text.TrimEnd() 'dim' $Color)
}

function Format-MbcAppRow {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color, [switch] $Selected)
    $c = Get-MbcAppsColumns -Width $Width
    $e = $Glyphs.Ellipsis
    $verified = if ($App.Verified) { "$($Glyphs.Pass) yes" } else { 'no' }
    $name = ConvertTo-MbcGlyphText $App.DisplayName $Glyphs
    # The marker survives truncation: the name is cut, never the word that says whose app it is.
    $nameCell = if ($App.Kind -eq 'own') { (Limit-MbcText $name ([Math]::Max(2, $c[0] - 6)) $e) + ' (own)' } else { Limit-MbcText $name $c[0] $e }
    $cells = @(
        (Format-MbcPad $nameCell $c[0]),
        (Format-MbcPad (Limit-MbcText (ConvertTo-MbcGlyphText $App.Publisher $Glyphs) $c[1] $e) $c[1]),
        (Format-MbcPad $verified $c[2]),
        (Limit-MbcText (Get-MbcConsentSummary -App $App -Glyphs $Glyphs) $c[3] $e)
    )
    $plain = '    ' + ($cells -join '  ')
    if ($Selected) { return (Format-MbcSelected -Text $plain -Width $Width -Glyphs $Glyphs -Color $Color) }
    $cells[2] = Format-MbcStyle $cells[2] $(if ($App.Verified) { 'ok' } else { 'dim' }) $Color
    return ('    ' + ($cells -join '  '))
}

function Format-MbcInventoryNote {
    # One line on what the inventory left out and what it couldn't read.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Inventory, [Parameter(Mandatory)][hashtable] $Glyphs)
    if (-not $Inventory.Collected) { return , @('The app inventory was left out of this run.') }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('{0} third-party, {1} own registration{2}. Not listed: {3} Microsoft app{4}, {5} other service principal{6}.' -f
            @($Inventory.ThirdParty).Count, @($Inventory.Own).Count, $(if (@($Inventory.Own).Count -eq 1) { '' } else { 's' }),
            $Inventory.FirstPartyCount, $(if ($Inventory.FirstPartyCount -eq 1) { '' } else { 's' }),
            $Inventory.OtherCount, $(if ($Inventory.OtherCount -eq 1) { '' } else { 's' })))
    foreach ($f in @($Inventory.Failures)) { $lines.Add("$($Glyphs.Error) $f") }
    return , $lines.ToArray()
}

function Format-MbcAppDetailLines {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)][int] $Width, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add('  ' + (Format-MbcStyle (Limit-MbcText (ConvertTo-MbcGlyphText $App.DisplayName $Glyphs) ($Width - 4) $Glyphs.Ellipsis) 'bold' $Color))
    $out.Add('')
    $add = { param($label, $text) foreach ($l in (Format-MbcField -Label $label -Text $text -Width $Width -Glyphs $Glyphs -Color $Color)) { $out.Add($l) } }
    & $add 'Kind' $(if ($App.Kind -eq 'own') { 'Registered in this tenant' } else { 'Third-party enterprise app' })
    & $add 'Publisher' ("$($App.Publisher)" + $(if ($App.Verified) { ' (verified publisher)' } else { ' (not verified)' }))
    & $add 'App ID' $App.AppId
    $status = if ($null -eq $App.Enabled) { 'No enterprise app in this tenant' } else {
        (@($(if ($App.Enabled) { 'Enabled for sign-in' } else { 'Disabled for sign-in' }),
                $(if ($App.AssignmentRequired) { 'assignment required' } else { 'assignment not required' })) -join " $($Glyphs.Dot) ")
    }
    & $add 'Status' $status
    $sections = @(
        @('Delegated, admin consent for all users', @($App.Delegated | Where-Object Type -eq 'admin')),
        @('Delegated, user consent', @($App.Delegated | Where-Object Type -eq 'user')),
        @('Application permissions', @($App.Application))
    )
    $any = $false
    foreach ($s in $sections) {
        if ($s[1].Count -eq 0) { continue }
        $any = $true
        $out.Add('')
        $out.Add('  ' + (Format-MbcStyle $s[0] 'accent' $Color))
        foreach ($p in $s[1]) {
            $names = if ($p.PSObject.Properties['Scopes']) { $p.Scopes } else { $p.Roles }
            $text = ($names -join ', ') + $(if ($p.PSObject.Properties['Users'] -and $p.Type -eq 'user') { " ($($p.Users) $(if ($p.Users -eq 1) { 'user' } else { 'users' }))" } else { '' })
            foreach ($l in (Format-MbcField -Label (Limit-MbcText $p.Resource 20 $Glyphs.Ellipsis) -Text $text -Width $Width -Glyphs $Glyphs -Color $false -Indent 4 -LabelWidth 22)) { $out.Add($l) }
        }
    }
    if (-not $any) { $out.Add(''); $out.Add('  No consents or application permissions.') }
    return , $out.ToArray()
}

function Format-MbcCountsText {
    # 27 met, 3 not, 1 unverifiable.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Counts, [bool] $Color)
    return ('{0}, {1}, {2}' -f (Format-MbcStyle "$($Counts.Pass) met" 'ok' $Color), (Format-MbcStyle "$($Counts.Fail) not" 'bad' $Color), (Format-MbcStyle "$($Counts.Error) unverifiable" 'warn' $Color))
}

function ConvertTo-MbcTextReport {
    <#
    .SYNOPSIS
        report.txt: the results screen as plain text, at a fixed width, every row shown, then a detail
        block for everything that needs attention, then the app inventory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $View, [int] $Width = 100)
    $g = Get-MbcGlyphs -Unicode $true
    $out = [System.Collections.Generic.List[string]]::new()
    $rule = $g.H * $Width
    $b = $View.Baseline
    $out.Add((Join-MbcColumns 'M365 Baseline Check report' "tool v$($View.Tool)" $Width))
    $out.Add($rule)
    $add = { param($label, $text) foreach ($l in (Format-MbcField -Label $label -Text $text -Width $Width -Glyphs $g -Color $false -Indent 0)) { $out.Add($l) } }
    & $add 'Baseline' ('{0} {1} v{2} {1} {3}{4}' -f $b.Name, $g.Dot, $b.Version, $b.Fingerprint, $(if ($b.SealState -ne 'Sealed') { '   UNSEALED' } else { '' }))
    & $add 'Digest' "SHA-256 $($b.Digest)"
    $tenant = if ($View.Tenant.Name) { "$($View.Tenant.Name)" + $(if ($View.Tenant.Domain) { " ($($View.Tenant.Domain))" } else { '' }) } elseif ($View.Tenant.Domain) { $View.Tenant.Domain } else { 'not recorded' }
    & $add 'Tenant' $tenant
    & $add 'Run' "$(Format-MbcRunTime $View.StartedUtc) $($g.Dot) run $($View.RunId)"
    foreach ($d in $View.Disclosure) { & $add 'Sign-in' $d }
    foreach ($l in (Format-MbcConsentAdvice -Consent $View.Consent)) { & $add 'Consent' $l }
    if (-not $View.Sealed) { & $add 'Warning' 'This result does not match its own seal.' }
    $out.Add('')
    $out.Add("Results   $(Format-MbcCountsText -Counts $View.Counts -Color $false)")
    $out.Add('')
    foreach ($row in (Get-MbcResultRows -Results $View.Results -Filter 'all')) {
        if ($row.Kind -eq 'heading' -and $out[-1] -ne '') { $out.Add('') }
        $out.Add((Format-MbcRowLine -Row $row -Width $Width -Glyphs $g -Color $false))
    }
    $attention = @($View.Results | Where-Object Verdict -ne 'Pass')
    if ($attention.Count -gt 0) {
        $out.Add('')
        $out.Add($rule)
        $out.Add('Needs attention')
        foreach ($r in $attention) {
            $out.Add('')
            foreach ($l in (Format-MbcDetailLines -Result $r -Width $Width -Glyphs $g -Color $false -RunId $View.RunId)) { $out.Add($l) }
        }
    }
    $out.Add('')
    $out.Add($rule)
    $out.Add('App inventory')
    foreach ($l in (Format-MbcInventoryNote -Inventory $View.Inventory -Glyphs $g)) { $out.Add("  $l") }
    $apps = @($View.Inventory.ThirdParty) + @($View.Inventory.Own)
    if ($apps.Count -gt 0) {
        $out.Add('')
        $out.Add((Format-MbcAppsHeader -Width $Width -Color $false))
        foreach ($a in $apps) { $out.Add((Format-MbcAppRow -App $a -Width $Width -Glyphs $g -Color $false)) }
        foreach ($a in $apps) {
            $out.Add('')
            foreach ($l in (Format-MbcAppDetailLines -App $a -Width $Width -Glyphs $g -Color $false)) { $out.Add($l) }
        }
    }
    $lines = @($out | ForEach-Object { if ((Measure-MbcWidth $_) -gt $Width) { Limit-MbcText (Remove-MbcAnsi $_) $Width $g.Ellipsis } else { $_.TrimEnd() } })
    return (($lines -join "`n") + "`n")
}
