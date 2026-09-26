# The TUI as pure functions: a state hashtable, a key map, navigation that changes the state and names
# any effect for the runtime to carry out, and Format-MbcFrame, which draws the whole screen as strings.

$script:MbcBuildMenu = @(
    [pscustomobject]@{ Label = 'Draft a baseline from a preset, reading this tenant…'; Key = 'd'; Action = 'captureDraft' }
    [pscustomobject]@{ Label = 'Seal a baseline, once you have reviewed it…'; Key = 's'; Action = 'sealFile' }
    [pscustomobject]@{ Label = 'Generate a team key, for locking exports'; Key = 'n'; Action = 'newKey' }
    [pscustomobject]@{ Label = 'Back'; Key = 'Esc'; Action = 'back' }
)

$script:MbcBuildGuide = @(
    'A preset says what to check. A baseline is a preset plus the values you expect, sealed.',
    '',
    '1. Start from a preset: copy presets/example-tenant-hygiene.json into ~/M365BaselineCheck/presets/ and edit it. CLAUDE.md explains every field.',
    '2. Draft a baseline: reads this tenant and writes what it finds as the expected values.',
    '3. Review the draft, change any value you do not want to keep, then seal it. Only sealed baselines run.',
    '',
    'Keep your own presets and baselines in ~/M365BaselineCheck or a private repository, never in this public one.'
)

$script:MbcScreenKeys = @{
    home      = @(@('↑↓', 'move'), @('Enter', 'select'), @('r', 'run'), @('b', 'baseline'), @('?', 'help'), @('q', 'quit'))
    build     = @(@('↑↓', 'move'), @('Enter', 'select'), @('Esc', 'back'), @('?', 'help'))
    run       = @(, @('Esc', 'abandon, after the current request'))
    results   = @(@('↑↓', 'move'), @('Enter', 'open'), @('f', 'not met'), @('e', 'unverifiable'), @('a', 'all'), @('/', 'filter'), @('i', 'apps'), @('x', 'export'), @('Esc', 'back'), @('?', 'help'))
    detail    = @(@('↑↓', 'previous/next'), @('PgUp/PgDn', 'scroll'), @('Esc', 'back'), @('?', 'help'))
    apps      = @(@('↑↓', 'move'), @('Enter', 'open'), @('/', 'filter'), @('x', 'export'), @('Esc', 'back'), @('?', 'help'))
    appDetail = @(@('↑↓', 'previous/next'), @('PgUp/PgDn', 'scroll'), @('Esc', 'back'), @('?', 'help'))
    chooser   = @(@('↑↓', 'move'), @('Enter', 'open'), @('p', 'type a path'), @('Esc', 'back'))
    prompt    = @(@('Enter', 'confirm'), @('Esc', 'cancel'))
    panel     = @(@('Enter', 'done'), @('Esc', 'back'))
}

$script:MbcKeyHelp = @{
    '↑↓'        = 'Move the selection. j and k work too.'
    'Enter'     = 'Choose, open the selected row, or expand and collapse an area.'
    'Esc'       = 'Go back. Backspace works too.'
    'r'         = 'Run the checks against the signed-in tenant.'
    'b'         = 'Choose a baseline.'
    'f'         = 'Show only checks not met. Press again for the default view.'
    'e'         = 'Show only checks that couldn''t be verified. Press again for the default view.'
    'a'         = 'Show every check. Press again for the default view.'
    '/'         = 'Filter by text in the ID, setting or location.'
    'i'         = 'The app inventory from this run.'
    'x'         = 'Export: one locked bundle plus a plain summary.'
    'p'         = 'Type a path instead of choosing from the list.'
    'PgUp/PgDn' = 'Scroll a page. Home and End jump to either end.'
    'q'         = 'Quit.'
    '?'         = 'This help.'
}

$script:MbcScreenTitles = @{ build = 'Make a baseline'; run = 'Running'; results = 'Results'; detail = 'Check'; apps = 'App inventory'; appDetail = 'App' }

function New-MbcTuiState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string] $OutputRoot)
    return @{
        Screen = 'home'; MenuIndex = 0; BuildIndex = 0; Help = $false; Quit = $false
        Message = ''; MessageStyle = 'dim'; Flourish = 0; Tick = 0
        Connection = $null; Baseline = $null; AllowUnsealed = $false; ExpectedFingerprint = $null; OutputRoot = $OutputRoot
        IncludeInventory = $true
        View = $null; ViewSource = ''; ViewFromFile = $false; Exported = $false
        Live = $null
        ResultIndex = 0; ResultOffset = 0; Filter = 'attention'; Search = ''; Expanded = @{}; DetailScroll = 0; Detail = $null
        AppIndex = 0; AppOffset = 0; AppSearch = ''; AppScroll = 0; AppDetail = $null
        Files = @(); ChooserIndex = 0; ChooserTitle = ''; ChooserPurpose = $null
        Prompt = $null; Panel = $null; PanelReturn = 'home'
        # Test and demo seams: Fetch, Connection and Inventory, used instead of signing in and reading.
        Seams = @{}; LastPromptKey = $null
    }
}

function Get-MbcHomeMenu {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable] $State)
    $inventory = if ($State.IncludeInventory) { 'on' } else { 'off' }
    return , @(
        [pscustomobject]@{ Label = 'Run checks'; Key = 'r'; Action = 'run' }
        [pscustomobject]@{ Label = 'Choose a baseline…'; Key = 'b'; Action = 'chooseBaseline' }
        [pscustomobject]@{ Label = 'Last results'; Key = 'l'; Action = 'lastResults' }
        [pscustomobject]@{ Label = 'App inventory'; Key = 'i'; Action = 'apps' }
        [pscustomobject]@{ Label = 'Open a locked result…'; Key = 'o'; Action = 'openLocked' }
        [pscustomobject]@{ Label = 'Make a baseline: draft, seal, team key…'; Key = 's'; Action = 'build' }
        [pscustomobject]@{ Label = 'Sign in / switch account'; Key = 'c'; Action = 'signIn' }
        [pscustomobject]@{ Label = "Read the app inventory with each run: $inventory"; Key = 't'; Action = 'toggleInventory' }
        [pscustomobject]@{ Label = 'Quit'; Key = 'q'; Action = 'quit' }
    )
}

function Resolve-MbcKeyAction {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Key)
    if ($State.Help) { return 'closeHelp' }
    $ch = if ($null -ne $Key.Char) { [string]$Key.Char } else { '' }
    if ($ch -ceq '?') { return 'help' }
    switch ($Key.Name) {
        'UpArrow' { return 'up' }
        'DownArrow' { return 'down' }
        'Enter' { return 'select' }
        'Escape' { return 'back' }
        'Backspace' { return 'back' }
        'PageUp' { return 'pageUp' }
        'PageDown' { return 'pageDown' }
        'Home' { return 'first' }
        'End' { return 'last' }
    }
    if ($Key.Name -ne 'Char') { return 'none' }
    if ($ch -ceq 'j') { return 'down' }
    if ($ch -ceq 'k') { return 'up' }
    switch ($State.Screen) {
        'home' {
            $item = (Get-MbcHomeMenu -State $State) | Where-Object { $_.Key -ceq $ch } | Select-Object -First 1
            if ($item) { return $item.Action }
            return 'none'
        }
        'build' {
            $item = $script:MbcBuildMenu | Where-Object { $_.Key -ceq $ch } | Select-Object -First 1
            if ($item) { return $item.Action }
            if ($ch -ceq 'q') { return 'back' }
            return 'none'
        }
        'results' {
            switch -CaseSensitive ($ch) {
                'f' { return 'filterFail' }
                'e' { return 'filterError' }
                'a' { return 'filterAll' }
                '/' { return 'search' }
                'x' { return 'export' }
                'i' { return 'apps' }
                'r' { return 'run' }
                'b' { return 'chooseBaseline' }
                'q' { return 'quit' }
            }
            return 'none'
        }
        'apps' {
            switch -CaseSensitive ($ch) {
                '/' { return 'search' }
                'x' { return 'export' }
                'q' { return 'quit' }
            }
            return 'none'
        }
        { $_ -in 'detail', 'appDetail' } { if ($ch -ceq 'q') { return 'quit' }; return 'none' }
        'chooser' {
            if ($ch -ceq 'p') { return 'enterPath' }
            if ($ch -ceq 'q') { return 'back' }
            return 'none'
        }
        'panel' { if ($ch -ceq 'q') { return 'back' }; return 'none' }
    }
    return 'none'
}

function Get-MbcHeaderHeight {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][hashtable] $State)
    if ($State.Screen -eq 'home') { return 5 }
    return 3
}

function Get-MbcBodyHeight {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap)
    return [Math]::Max(3, $Cap.Height - (Get-MbcHeaderHeight -State $State) - 2)
}

function Get-MbcTuiRows {
    # The results screen's rows for the current filter, search and expanded areas.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable] $State)
    if (-not $State.View) { return , @() }
    return , (Get-MbcResultRows -Results @($State.View.Results) -Filter $State.Filter -Search $State.Search -Expanded ([string[]]@($State.Expanded.Keys)))
}

function Get-MbcTuiApps {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable] $State)
    if (-not $State.View) { return , @() }
    $apps = @($State.View.Inventory.ThirdParty) + @($State.View.Inventory.Own)
    if ($State.AppSearch) { $apps = @($apps | Where-Object { Test-MbcContainsAny -Text "$($_.DisplayName) $($_.Publisher)" -Fragments @($State.AppSearch) }) }
    return , @($apps)
}

function Get-MbcListPage {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap)
    # Results and apps both spend three lines on a summary, a note and a gap (apps: plus a header).
    $reserved = if ($State.Screen -in 'apps', 'appDetail') { 4 } else { 3 }
    return [Math]::Max(1, (Get-MbcBodyHeight -State $State -Cap $Cap) - $reserved)
}

function Step-MbcIndex {
    [CmdletBinding()]
    [OutputType([int])]
    param([int] $Index, [int] $Count, [Parameter(Mandatory)][string] $Action, [int] $Page = 10, [switch] $Wrap)
    if ($Count -le 0) { return 0 }
    $last = $Count - 1
    $next = switch ($Action) {
        'up' { if ($Wrap -and $Index -le 0) { $last } else { $Index - 1 } }
        'down' { if ($Wrap -and $Index -ge $last) { 0 } else { $Index + 1 } }
        'pageUp' { $Index - $Page }
        'pageDown' { $Index + $Page }
        'first' { 0 }
        'last' { $last }
        default { $Index }
    }
    return [Math]::Min($last, [Math]::Max(0, $next))
}

function Get-MbcScrolledOffset {
    [CmdletBinding()]
    [OutputType([int])]
    param([int] $Index, [int] $Offset, [int] $Page)
    if ($Index -lt $Offset) { return $Index }
    if ($Index -ge $Offset + $Page) { return ($Index - $Page + 1) }
    return [Math]::Max(0, $Offset)
}

function Set-MbcTuiMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][AllowEmptyString()][string] $Text, [string] $Style = 'dim')
    $State.Message = $Text
    $State.MessageStyle = $Style
}

function Open-MbcTuiResults {
    # Shows a result view on the results screen, from the top, in the default filter.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)
    $State.Filter = 'attention'; $State.Search = ''; $State.Expanded = @{}
    $State.ResultIndex = 0; $State.ResultOffset = 0; $State.AppIndex = 0; $State.AppOffset = 0; $State.AppSearch = ''
    $State.Screen = 'results'
}

function Invoke-MbcTuiNavigation {
    <#
    .SYNOPSIS
        Applies an action to the state. Returns the name of an effect the runtime must carry out (sign-in,
        running, files, prompts), or $null when the action was handled here.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Action, [Parameter(Mandatory)] $Cap)
    if ($Action -eq 'none') { return $null }
    if ($Action -eq 'help') { $State.Help = $true; return $null }
    if ($Action -eq 'closeHelp') { $State.Help = $false; return $null }
    if ($Action -eq 'quit') { return 'quit' }
    $moves = 'up', 'down', 'first', 'last', 'pageUp', 'pageDown'
    $page = Get-MbcListPage -State $State -Cap $Cap

    # Shared, whichever screen asked.
    switch ($Action) {
        'toggleInventory' {
            $State.IncludeInventory = -not $State.IncludeInventory
            Set-MbcTuiMessage -State $State -Text $(if ($State.IncludeInventory) { 'The app inventory will be read with each run.' } else { 'The app inventory will be left out of runs.' })
            return $null
        }
        'lastResults' {
            if ($State.View) { $State.Screen = 'results' }
            else { Set-MbcTuiMessage -State $State -Text 'No results yet. Press r to run the checks, or o to open a locked result.' -Style 'warn' }
            return $null
        }
        'apps' {
            if (-not $State.View) { Set-MbcTuiMessage -State $State -Text 'No inventory yet: it is read with every run. Press r to run the checks.' -Style 'warn' }
            else { $State.Screen = 'apps' }
            return $null
        }
        'build' { $State.BuildIndex = 0; $State.Screen = 'build'; return $null }
    }

    switch ($State.Screen) {
        'home' {
            $menu = Get-MbcHomeMenu -State $State
            if ($Action -in $moves) { $State.MenuIndex = Step-MbcIndex -Index $State.MenuIndex -Count $menu.Count -Action $Action -Wrap; return $null }
            if ($Action -eq 'select') { return (Invoke-MbcTuiNavigation -State $State -Action $menu[$State.MenuIndex].Action -Cap $Cap) }
            if ($Action -eq 'back') { return $null }
            return $Action
        }
        'build' {
            if ($Action -in $moves) { $State.BuildIndex = Step-MbcIndex -Index $State.BuildIndex -Count $script:MbcBuildMenu.Count -Action $Action -Wrap; return $null }
            $chosen = if ($Action -eq 'select') { $script:MbcBuildMenu[$State.BuildIndex].Action } else { $Action }
            if ($chosen -eq 'back') { $State.Screen = 'home'; return $null }
            return $chosen
        }
        'results' {
            $rows = Get-MbcTuiRows -State $State
            switch ($Action) {
                { $_ -in $moves } { $State.ResultIndex = Step-MbcIndex -Index $State.ResultIndex -Count $rows.Count -Action $Action -Page $page }
                'filterFail' { $State.Filter = if ($State.Filter -eq 'fail') { 'attention' } else { 'fail' }; $State.ResultIndex = 0; $State.ResultOffset = 0 }
                'filterError' { $State.Filter = if ($State.Filter -eq 'error') { 'attention' } else { 'error' }; $State.ResultIndex = 0; $State.ResultOffset = 0 }
                'filterAll' { $State.Filter = if ($State.Filter -eq 'all') { 'attention' } else { 'all' }; $State.ResultIndex = 0; $State.ResultOffset = 0 }
                'select' {
                    if ($rows.Count -eq 0) { return $null }
                    $row = $rows[[Math]::Min($State.ResultIndex, $rows.Count - 1)]
                    if ($row.Kind -eq 'heading') {
                        if ($State.Expanded.ContainsKey($row.Group.Area)) { $State.Expanded.Remove($row.Group.Area) } else { $State.Expanded[$row.Group.Area] = $true }
                    }
                    else { $State.Detail = $row.Result; $State.DetailScroll = 0; $State.Screen = 'detail' }
                }
                'back' { $State.Screen = 'home' }
                default { return $Action }
            }
            $State.ResultOffset = Get-MbcScrolledOffset -Index $State.ResultIndex -Offset $State.ResultOffset -Page $page
            return $null
        }
        'detail' {
            if ($Action -in 'up', 'down') {
                $rows = Get-MbcTuiRows -State $State
                $i = $State.ResultIndex
                do { $i = if ($Action -eq 'up') { $i - 1 } else { $i + 1 } } while ($i -ge 0 -and $i -lt $rows.Count -and $rows[$i].Kind -ne 'result')
                if ($i -ge 0 -and $i -lt $rows.Count) {
                    $State.ResultIndex = $i
                    $State.ResultOffset = Get-MbcScrolledOffset -Index $i -Offset $State.ResultOffset -Page $page
                    $State.Detail = $rows[$i].Result
                    $State.DetailScroll = 0
                }
                return $null
            }
            if ($Action -in 'pageUp', 'pageDown', 'first', 'last') {
                $State.DetailScroll = switch ($Action) { 'pageUp' { [Math]::Max(0, $State.DetailScroll - $page) } 'pageDown' { $State.DetailScroll + $page } 'first' { 0 } 'last' { 9999 } }
                return $null
            }
            if ($Action -in 'back', 'select') { $State.Screen = 'results' }
            return $null
        }
        'apps' {
            $apps = Get-MbcTuiApps -State $State
            switch ($Action) {
                { $_ -in $moves } { $State.AppIndex = Step-MbcIndex -Index $State.AppIndex -Count $apps.Count -Action $Action -Page $page }
                'select' { if ($apps.Count -gt 0) { $State.AppDetail = $apps[[Math]::Min($State.AppIndex, $apps.Count - 1)]; $State.AppScroll = 0; $State.Screen = 'appDetail' } }
                'back' { $State.Screen = 'results' }
                default { return $Action }
            }
            $State.AppOffset = Get-MbcScrolledOffset -Index $State.AppIndex -Offset $State.AppOffset -Page $page
            return $null
        }
        'appDetail' {
            if ($Action -in 'up', 'down') {
                $apps = Get-MbcTuiApps -State $State
                $State.AppIndex = Step-MbcIndex -Index $State.AppIndex -Count $apps.Count -Action $Action
                $State.AppOffset = Get-MbcScrolledOffset -Index $State.AppIndex -Offset $State.AppOffset -Page $page
                if ($apps.Count -gt 0) { $State.AppDetail = $apps[$State.AppIndex]; $State.AppScroll = 0 }
                return $null
            }
            if ($Action -in 'pageUp', 'pageDown', 'first', 'last') {
                $State.AppScroll = switch ($Action) { 'pageUp' { [Math]::Max(0, $State.AppScroll - $page) } 'pageDown' { $State.AppScroll + $page } 'first' { 0 } 'last' { 9999 } }
                return $null
            }
            if ($Action -in 'back', 'select') { $State.Screen = 'apps' }
            return $null
        }
        'chooser' {
            if ($Action -in $moves) { $State.ChooserIndex = Step-MbcIndex -Index $State.ChooserIndex -Count @($State.Files).Count -Action $Action -Page $page; return $null }
            if ($Action -eq 'select') { if (@($State.Files).Count -gt 0) { return 'choose' } else { return 'enterPath' } }
            if ($Action -eq 'back') { $State.Screen = 'home'; return $null }
            return $Action
        }
        'panel' {
            if ($Action -in 'select', 'back') { $State.Panel = $null; $State.Screen = $State.PanelReturn }
            return $null
        }
    }
    return $null
}

function Get-MbcSealNote {
    # The baseline's seal state for the header, with the brief flourish after a sealed baseline is chosen.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    $b = $State.Baseline
    if (-not $b) { return (Format-MbcStyle 'choose one with b' 'dim' $Color) }
    if ($b.SealState -eq 'Modified') { return (Format-MbcStyle "edited since v$($b.SealedVersion) was sealed" 'warn' $Color) }
    if ($b.SealState -ne 'Sealed') { return (Format-MbcStyle 'not sealed' 'warn' $Color) }
    $text = "sealed $($Glyphs.Seal)"
    if ($State.Flourish -gt 0) {
        # Reveal left to right, then settle: cosmetic, and nothing waits on it.
        $shown = [Math]::Min($text.Length, [Math]::Max(1, $text.Length - $State.Flourish + 1))
        return (Format-MbcStyle ($text.Substring(0, $shown).PadRight($text.Length)) 'title' $Color)
    }
    return (Format-MbcStyle $text 'ok' $Color)
}

function Format-MbcHomeHeader {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs)
    $c = $Cap.Color
    $inner = $Cap.Width - 4
    $e = $Glyphs.Ellipsis
    $field = {
        param($label, $text, $note, $style)
        $room = [Math]::Max(8, $inner - 10 - (Measure-MbcWidth $note) - 2)
        Join-MbcColumns ((Format-MbcStyle (Format-MbcPad $label 10) 'dim' $c) + (Format-MbcStyle (Limit-MbcText (ConvertTo-MbcGlyphText $text $Glyphs) $room $e) $style $c)) $note $inner
    }
    $conn = $State.Connection
    if ($conn) {
        $tenant = (@($conn.TenantName, $conn.Domain) | Where-Object { $_ }) -join " $($Glyphs.Dot) "
        $line1 = & $field 'Tenant' $tenant ((Format-MbcStyle "$($Glyphs.Signed) " 'ok' $c) + (Format-MbcStyle (Limit-MbcText $conn.Account ([int]($inner / 3)) $e) 'bold' $c)) 'title'
        $names = @('Graph') + @($conn.Sessions.Keys | ForEach-Object { $script:MbcSourceNames[$_] })
        $failed = @($conn.Failed.Keys | ForEach-Object { $script:MbcSourceNames[$_] })
        $note = if ($failed.Count) { Format-MbcStyle "$($failed -join ', ') not connected" 'warn' $c } else { Format-MbcStyle 'read-only by construction' 'dim' $c }
        $line2 = & $field 'Sessions' ($names -join " $($Glyphs.Dot) ") $note
    }
    else {
        $line1 = & $field 'Tenant' "$($Glyphs.Unsigned) not signed in" (Format-MbcStyle 'r signs in, or c' 'dim' $c) 'warn'
        $line2 = & $field 'Sessions' 'none' ''
    }
    $b = $State.Baseline
    $identity = if ($b) { '{0} {1} v{2} {1} {3}' -f $b.Name, $Glyphs.Dot, $b.Version, $b.Fingerprint } else { 'none chosen' }
    $line3 = & $field 'Baseline' $identity (Get-MbcSealNote -State $State -Glyphs $Glyphs -Color $c)
    return (Format-MbcBox -Title 'M365 Baseline Check' -RightTitle "v$($script:MbcToolVersion)" -Lines @($line1, $line2, $line3) -Width $Cap.Width -Glyphs $Glyphs -Color $c)
}

function Format-MbcScreenHeader {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs)
    if ($State.Screen -eq 'home') { return (Format-MbcHomeHeader -State $State -Cap $Cap -Glyphs $Glyphs) }
    $title = switch ($State.Screen) {
        'chooser' { $State.ChooserTitle }
        'prompt' { $State.Prompt.Title }
        'panel' { $State.Panel.Title }
        default { $script:MbcScreenTitles[$State.Screen] }
    }
    $b = if ($State.Screen -in 'results', 'detail', 'apps', 'appDetail' -and $State.View) { $State.View.Baseline } else { $State.Baseline }
    $right = if ($b) {
        '{0} v{1} {2} {3}{4}' -f $b.Name, $b.Version, $Glyphs.Dot, $b.Fingerprint, $(if ($b.SealState -ne 'Sealed') { " $($Glyphs.Dot) UNSEALED" } else { '' })
    }
    else { '' }
    $bar = Format-MbcTitleBar -Left (ConvertTo-MbcGlyphText "M365 Baseline Check $($Glyphs.Dot) $title" $Glyphs) -Right (ConvertTo-MbcGlyphText $right $Glyphs) -Width $Cap.Width -Glyphs $Glyphs -Color $Cap.Color
    return , @($bar, (Format-MbcIdentityLine -State $State -Cap $Cap -Glyphs $Glyphs), '')
}

function Format-MbcIdentityLine {
    # Who the tool is signed in as, on every screen: the tenant, the account, and the sessions open.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs)
    $c = $Cap.Color
    $conn = $State.Connection
    if (-not $conn) { return ' ' + (Format-MbcStyle "$($Glyphs.Unsigned) Not signed in" 'warn' $c) }
    $tenant = (@($conn.TenantName, $conn.Domain) | Where-Object { $_ }) -join " $($Glyphs.Dot) "
    $sessions = @('Graph') + @($conn.Sessions.Keys | ForEach-Object { $script:MbcSourceNames[$_] })
    $failed = @($conn.Failed.Keys | ForEach-Object { $script:MbcSourceNames[$_] })
    $failedTail = if ($failed.Count) { ConvertTo-MbcGlyphText "  $($Glyphs.Fail) $($failed -join ', ') not connected" $Glyphs } else { '' }
    $fullTail = (ConvertTo-MbcGlyphText "  $($Glyphs.Dot) $($sessions -join ', ')" $Glyphs) + $failedTail
    $room = [Math]::Max(10, $Cap.Width - 4)
    $plain = ConvertTo-MbcGlyphText "$tenant  as $($conn.Account)" $Glyphs
    # What fails matters more than what worked: the list of open sessions goes first when space is short.
    $tail = if ($plain.Length + $fullTail.Length -le $room) { $fullTail } else { $failedTail }
    $head = Limit-MbcText $plain ([Math]::Max(16, $room - $tail.Length)) $Glyphs.Ellipsis
    $rest = Limit-MbcText $tail ([Math]::Max(0, $room - $head.Length)) $Glyphs.Ellipsis
    return ' ' + (Format-MbcStyle $Glyphs.Signed 'ok' $c) + ' ' + (Format-MbcStyle $head 'title' $c) + (Format-MbcStyle $rest $(if ($failed.Count) { 'warn' } else { 'dim' }) $c)
}

function Format-MbcRunBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs, [int] $Height)
    $live = $State.Live
    $c = $Cap.Color
    $out = [System.Collections.Generic.List[string]]::new()
    $target = if ($State.Connection -and $State.Connection.TenantName) { " against $($State.Connection.TenantName)" } else { '' }
    $b = $State.Baseline
    $out.Add('  ' + (ConvertTo-MbcGlyphText "Checking $($b.Name) v$($b.Version)$target" $Glyphs))
    $out.Add('')
    $barWidth = [Math]::Min(40, [Math]::Max(10, [int]($Cap.Width * 0.35)))
    $bar = Format-MbcProgressBar -Done $live.Done -Total ([Math]::Max(1, $live.Total)) -Width $barWidth -Glyphs $Glyphs -Color $c
    $count = if ($live.Phase -eq 'inventory') { 'app inventory' } else { "$($live.Done) of $($live.Total)" }
    $out.Add("  $bar  $count")
    $spinner = Format-MbcStyle (Get-MbcSpinnerFrame -Tick $State.Tick -Glyphs $Glyphs) 'accent' $c
    $label = if ($live.Waiting -gt 0) { Format-MbcStyle "Graph asked for a pause: waiting $($live.Waiting) s" 'warn' $c } else { Format-MbcStyle (Limit-MbcText (ConvertTo-MbcGlyphText $live.Label $Glyphs) ($Cap.Width - 6) $Glyphs.Ellipsis) 'dim' $c }
    $out.Add("  $spinner $label")
    $out.Add('')
    $room = [Math]::Max(0, $Height - $out.Count)
    $lines = @($live.Lines)
    for ($i = [Math]::Max(0, $lines.Count - $room); $i -lt $lines.Count; $i++) {
        $out.Add((Format-MbcResultRow -Result $lines[$i] -Width $Cap.Width -Glyphs $Glyphs -Color $c))
    }
    return , $out.ToArray()
}

function Format-MbcResultsBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs, [int] $Height)
    $c = $Cap.Color
    if (-not $State.View) { return , @('  No results yet. Press r to run the checks.') }
    $counts = $State.View.Counts
    $filterName = switch ($State.Filter) { 'fail' { 'not met' } 'error' { 'unverifiable' } 'all' { 'every check' } default { 'needs attention' } }
    $showing = "Showing: $filterName" + $(if ($State.Search) { ", matching '$($State.Search)'" } else { '' })
    $out = [System.Collections.Generic.List[string]]::new()
    $source = if ($State.ViewFromFile) { "from $($State.ViewSource)" } else { 'this run' }
    $out.Add((Join-MbcColumns ('  ' + (Format-MbcCountsText -Counts $counts -Color $c) + (Format-MbcStyle "   $($Glyphs.Dot) $source" 'dim' $c)) (Format-MbcStyle (ConvertTo-MbcGlyphText $showing $Glyphs) 'dim' $c) $Cap.Width))
    $note = if ($counts.Fail + $counts.Error -eq 0 -and $State.Filter -eq 'attention' -and -not $State.Search) { 'Everything was met. Enter on an area lists its checks; a lists them all.' }
    elseif (-not $State.View.Sealed) { 'This result does not match its own seal. Treat it as untrustworthy.' }
    else { '' }
    if ($note) { $out.Add('  ' + (Format-MbcStyle $note $(if ($State.View.Sealed) { 'dim' } else { 'bad' }) $c)) }
    $out.Add('')
    $rows = Get-MbcTuiRows -State $State
    if ($rows.Count -eq 0) { $out.Add('  Nothing matches. Press a to show every check, or / to change the filter.'); return , $out.ToArray() }
    $page = [Math]::Max(1, $Height - $out.Count)
    $selected = [Math]::Min($State.ResultIndex, $rows.Count - 1)
    $offset = Get-MbcScrolledOffset -Index $selected -Offset $State.ResultOffset -Page $page
    for ($i = $offset; $i -lt [Math]::Min($rows.Count, $offset + $page); $i++) {
        $out.Add((Format-MbcRowLine -Row $rows[$i] -Width $Cap.Width -Glyphs $Glyphs -Color $c -Selected:($i -eq $selected) -Marker))
    }
    return , $out.ToArray()
}

function Format-MbcScrolled {
    # A window of lines with a dim marker when there is more above or below.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines, [int] $Scroll, [int] $Height, [Parameter(Mandatory)][hashtable] $Glyphs, [bool] $Color)
    $max = [Math]::Max(0, $Lines.Count - $Height)
    $start = [Math]::Min([Math]::Max(0, $Scroll), $max)
    $window = @($Lines | Select-Object -Skip $start -First $Height)
    if ($start + $Height -lt $Lines.Count -and $window.Count -gt 0) {
        $window[-1] = '  ' + (Format-MbcStyle "$($Glyphs.Ellipsis) more below: PgDn" 'dim' $Color)
    }
    return , [string[]]$window
}

function Format-MbcAppsBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs, [int] $Height)
    $c = $Cap.Color
    $out = [System.Collections.Generic.List[string]]::new()
    $inventory = $State.View.Inventory
    $notes = Format-MbcInventoryNote -Inventory $inventory -Glyphs $Glyphs
    $out.Add('  ' + (ConvertTo-MbcGlyphText $notes[0] $Glyphs))
    $extra = @($notes | Select-Object -Skip 1)
    if ($extra.Count) { $out.Add('  ' + (Format-MbcStyle (ConvertTo-MbcGlyphText ($extra -join '  ') $Glyphs) 'warn' $c)) }
    if ($State.AppSearch) { $out.Add('  ' + (Format-MbcStyle "Matching '$($State.AppSearch)'" 'dim' $c)) }
    $out.Add('')
    $apps = Get-MbcTuiApps -State $State
    if (-not $inventory.Collected) { $out.Add('  Turn it on from the home screen with t, then run again.'); return , $out.ToArray() }
    if ($apps.Count -eq 0) { $out.Add($(if ($State.AppSearch) { '  Nothing matches.' } else { '  No third-party apps or own registrations.' })); return , $out.ToArray() }
    $out.Add((Format-MbcAppsHeader -Width $Cap.Width -Color $c))
    $page = [Math]::Max(1, $Height - $out.Count)
    $selected = [Math]::Min($State.AppIndex, $apps.Count - 1)
    $offset = Get-MbcScrolledOffset -Index $selected -Offset $State.AppOffset -Page $page
    for ($i = $offset; $i -lt [Math]::Min($apps.Count, $offset + $page); $i++) {
        $out.Add((Format-MbcAppRow -App $apps[$i] -Width $Cap.Width -Glyphs $Glyphs -Color $c -Selected:($i -eq $selected)))
    }
    return , $out.ToArray()
}

function Format-MbcChooserBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs, [int] $Height)
    $out = [System.Collections.Generic.List[string]]::new()
    $files = @($State.Files)
    if ($files.Count -eq 0) {
        $out.Add('  Nothing found in the usual places. Press p to type a path.')
        return , $out.ToArray()
    }
    $page = [Math]::Max(1, $Height - 2)
    $offset = Get-MbcScrolledOffset -Index $State.ChooserIndex -Offset 0 -Page $page
    $items = @($files | ForEach-Object { [pscustomobject]@{ Label = [System.IO.Path]::GetFileName($_); Key = ''; Action = 'choose' } })
    $shown = @($items | Select-Object -Skip $offset -First $page)
    foreach ($line in (Format-MbcMenu -Items $shown -Selected ($State.ChooserIndex - $offset) -Width $Cap.Width -Glyphs $Glyphs -Color $Cap.Color)) { $out.Add($line) }
    $out.Add('')
    $out.Add('  ' + (Format-MbcStyle (Limit-MbcText (ConvertTo-MbcGlyphText $files[$State.ChooserIndex] $Glyphs) ($Cap.Width - 4) $Glyphs.Ellipsis) 'dim' $Cap.Color))
    return , $out.ToArray()
}

function Format-MbcPromptBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs)
    $p = $State.Prompt
    $value = [string]$p.Value
    $shown = if ($p.Mask) { ($(if ($Glyphs.Unicode) { '•' } else { '*' })) * $value.Length } else { ConvertTo-MbcGlyphText $value $Glyphs }
    $room = $Cap.Width - 8
    if ($shown.Length -gt $room) { $shown = $shown.Substring($shown.Length - $room) }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Split-MbcWrapped -Text (ConvertTo-MbcGlyphText $p.Label $Glyphs) -Width ($Cap.Width - 4) -Ellipsis $Glyphs.Ellipsis)) { $out.Add("  $l") }
    $out.Add('')
    $out.Add("  $(Format-MbcStyle '>' 'accent' $Cap.Color) $shown$(Format-MbcStyle $Glyphs.Cursor 'accent' $Cap.Color)")
    return , $out.ToArray()
}

function Format-MbcHelpOverlay {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs)
    $keys = $script:MbcScreenKeys[$State.Screen]
    if (-not $keys) { $keys = $script:MbcScreenKeys['home'] }
    $width = [Math]::Min($Cap.Width - 2, 76)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $keys) {
        $desc = if ($script:MbcKeyHelp.ContainsKey($k[0])) { $script:MbcKeyHelp[$k[0]] } else { $k[1] }
        $keyText = Format-MbcPad (ConvertTo-MbcGlyphText $k[0] $Glyphs) 11
        $first = $true
        foreach ($piece in (Split-MbcWrapped -Text (ConvertTo-MbcGlyphText $desc $Glyphs) -Width ($width - 16) -Ellipsis $Glyphs.Ellipsis)) {
            $lines.Add($(if ($first) { (Format-MbcStyle $keyText 'accent' $Cap.Color) + $piece } else { (' ' * 11) + $piece }))
            $first = $false
        }
    }
    if ($State.Screen -eq 'home') { $lines.Add(''); $lines.Add('Each menu item''s letter works from the home screen.') }
    $lines.Add('')
    $lines.Add((Format-MbcStyle 'Any key closes this.' 'dim' $Cap.Color))
    $box = Format-MbcBox -Title 'Keys on this screen' -Lines $lines.ToArray() -Width $width -Glyphs $Glyphs -Color $Cap.Color
    return , [string[]]@($box | ForEach-Object { " $_" })
}

function Get-MbcScreenBody {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap, [Parameter(Mandatory)][hashtable] $Glyphs, [int] $Height)
    $c = $Cap.Color
    switch ($State.Screen) {
        'home' {
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add('')
            foreach ($l in (Format-MbcMenu -Items (Get-MbcHomeMenu -State $State) -Selected $State.MenuIndex -Width $Cap.Width -Glyphs $Glyphs -Color $c)) { $lines.Add($l) }
            $lines.Add('')
            if ($State.View) {
                $source = if ($State.ViewFromFile) { "from $($State.ViewSource)" } else { 'this run' }
                $lines.Add('  ' + (Format-MbcStyle 'Last results  ' 'dim' $c) + (Format-MbcCountsText -Counts $State.View.Counts -Color $c) + (Format-MbcStyle "   $($Glyphs.Dot) $source$(if (-not $State.Exported) { ', not exported yet' })" 'dim' $c))
            }
            elseif (-not $State.Connection) {
                $lines.Add('  ' + (Format-MbcStyle 'Running signs you in first. Every session is read-only by construction.' 'dim' $c))
            }
            return , $lines.ToArray()
        }
        'build' {
            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($g in $script:MbcBuildGuide) {
                $indent = if ($g.Length -gt 1 -and (Test-MbcAsciiDigit $g[0])) { '     ' } else { '  ' }
                $first = $true
                foreach ($w in (Split-MbcWrapped -Text (ConvertTo-MbcGlyphText $g $Glyphs) -Width ($Cap.Width - 7) -Ellipsis $Glyphs.Ellipsis)) {
                    $lines.Add($(if ($first) { '  ' } else { $indent }) + (Format-MbcStyle $w 'dim' $c))
                    $first = $false
                }
            }
            $lines.Add('')
            foreach ($l in (Format-MbcMenu -Items $script:MbcBuildMenu -Selected $State.BuildIndex -Width $Cap.Width -Glyphs $Glyphs -Color $c)) { $lines.Add($l) }
            return , $lines.ToArray()
        }
        'run' { return (Format-MbcRunBody -State $State -Cap $Cap -Glyphs $Glyphs -Height $Height) }
        'results' { return (Format-MbcResultsBody -State $State -Cap $Cap -Glyphs $Glyphs -Height $Height) }
        'detail' {
            if (-not $State.Detail) { return , @('  Nothing selected.') }
            $lines = Format-MbcDetailLines -Result $State.Detail -Width $Cap.Width -Glyphs $Glyphs -Color $c -RunId $State.View.RunId
            return (Format-MbcScrolled -Lines $lines -Scroll $State.DetailScroll -Height $Height -Glyphs $Glyphs -Color $c)
        }
        'apps' { return (Format-MbcAppsBody -State $State -Cap $Cap -Glyphs $Glyphs -Height $Height) }
        'appDetail' {
            if (-not $State.AppDetail) { return , @('  Nothing selected.') }
            $lines = Format-MbcAppDetailLines -App $State.AppDetail -Width $Cap.Width -Glyphs $Glyphs -Color $c
            return (Format-MbcScrolled -Lines $lines -Scroll $State.AppScroll -Height $Height -Glyphs $Glyphs -Color $c)
        }
        'chooser' { return (Format-MbcChooserBody -State $State -Cap $Cap -Glyphs $Glyphs -Height $Height) }
        'prompt' { return (Format-MbcPromptBody -State $State -Cap $Cap -Glyphs $Glyphs) }
        'panel' {
            # Long lines wrap under their own indent, so nothing on a panel is cut off.
            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($raw in @($State.Panel.Lines)) {
                $text = ConvertTo-MbcGlyphText ([string]$raw) $Glyphs
                $indent = $text.Length - $text.TrimStart(' ').Length
                if ($text.Length -le $Cap.Width -or $indent -ge $Cap.Width - 10) { $lines.Add($text); continue }
                $first = $true
                foreach ($w in (Split-MbcWrapped -Text $text.TrimStart(' ') -Width ($Cap.Width - $indent - 2) -Ellipsis $Glyphs.Ellipsis)) {
                    $lines.Add((' ' * $(if ($first) { $indent } else { $indent + 2 })) + $w)
                    $first = $false
                }
            }
            return , $lines.ToArray()
        }
    }
    return , @('')
}

function Format-MbcFrame {
    <#
    .SYNOPSIS
        The whole screen: exactly Cap.Height lines, none wider than Cap.Width. Header, body, a message
        line, and the footer with the keys for this screen.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)] $Cap)
    $g = Get-MbcGlyphs -Unicode $Cap.Unicode
    [string[]] $header = Format-MbcScreenHeader -State $State -Cap $Cap -Glyphs $g
    $keys = $script:MbcScreenKeys[$State.Screen]
    if (-not $keys) { $keys = $script:MbcScreenKeys['home'] }
    if ($State.Help) { $keys = @(, @('Any key', 'closes this')) }
    $footer = Format-MbcFooter -Keys $keys -Width $Cap.Width -Glyphs $g -Color $Cap.Color
    $message = if ($State.Message) { '  ' + (Format-MbcStyle (Limit-MbcText (ConvertTo-MbcGlyphText $State.Message $g) ($Cap.Width - 4) $g.Ellipsis) $State.MessageStyle $Cap.Color) } else { '' }
    $bodyHeight = [Math]::Max(1, $Cap.Height - $header.Count - 2)
    $body = if ($State.Help) { Format-MbcHelpOverlay -State $State -Cap $Cap -Glyphs $g } else { Get-MbcScreenBody -State $State -Cap $Cap -Glyphs $g -Height $bodyHeight }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($h in $header) { $lines.Add($h) }
    $shown = @($body | Select-Object -First $bodyHeight)
    foreach ($b in $shown) {
        $text = [string]$b
        # Anything still too wide is cut plainly rather than allowed to wrap.
        if ((Measure-MbcWidth $text) -gt $Cap.Width) { $text = Limit-MbcText (Remove-MbcAnsi $text) $Cap.Width $g.Ellipsis }
        if (-not $Cap.Unicode) { $text = ConvertTo-MbcGlyphText $text $g }
        $lines.Add($text)
    }
    for ($i = $shown.Count; $i -lt $bodyHeight; $i++) { $lines.Add('') }
    $lines.Add($message)
    $lines.Add($footer)
    while ($lines.Count -gt $Cap.Height) { $lines.RemoveAt($header.Count) }
    return , $lines.ToArray()
}
