# The TUI's console loop and its effects. No background runspace: the spinner and bar move between
# requests and pages and through throttling waits, and hold still during one long request.

$script:MbcLastFrame = $null
$script:MbcSavedTreatControlC = $false
# Tests set this to a queue of keys; Read-MbcKey then reads from it instead of the console.
$script:MbcKeyQueue = $null
$script:MbcDrainedReads = 0

function Write-MbcConsole {
    # Every byte the TUI draws goes through here, to the console's own writer, never Write-Host.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [switch] $Line)
    if ($Line) { $Text += [Environment]::NewLine }
    [Console]::Out.Write($Text)
    [Console]::Out.Flush()
}

function Enter-MbcScreen {
    [CmdletBinding()]
    param()
    $script:MbcLastFrame = $null
    try { $script:MbcSavedTreatControlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { Write-Verbose 'No console input to configure.' }
    Write-MbcConsole -Text ("$([char]27)[?1049h$([char]27)[?25l")
}

function Exit-MbcScreen {
    [CmdletBinding()]
    param()
    Write-MbcConsole -Text ("$([char]27)[0m$([char]27)[?25h$([char]27)[?1049l")
    try { [Console]::TreatControlCAsInput = $script:MbcSavedTreatControlC } catch { Write-Verbose 'No console input to restore.' }
    $script:MbcLastFrame = $null
}

function Write-MbcFrame {
    # One write per frame, and none when nothing changed.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("$([char]27)[H")
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        [void]$sb.Append($Lines[$i]).Append("$([char]27)[0m$([char]27)[K")
        if ($i -lt $Lines.Count - 1) { [void]$sb.Append("`n") }
    }
    [void]$sb.Append("$([char]27)[J")
    $text = $sb.ToString()
    if ($text -ceq $script:MbcLastFrame) { return }
    $script:MbcLastFrame = $text
    Write-MbcConsole -Text ($text)
}

function ConvertTo-MbcKey {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.ConsoleKeyInfo] $KeyInfo)
    if ($KeyInfo.Key -eq [ConsoleKey]::C -and ($KeyInfo.Modifiers -band [ConsoleModifiers]::Control)) { return [pscustomobject]@{ Name = 'CtrlC'; Char = $null } }
    $named = 'UpArrow', 'DownArrow', 'Enter', 'Escape', 'Backspace', 'PageUp', 'PageDown', 'Home', 'End', 'Tab'
    $name = [string]$KeyInfo.Key
    if ($name -in $named) { return [pscustomobject]@{ Name = $name; Char = $null } }
    if ($KeyInfo.KeyChar -eq [char]0 -or [char]::IsControl($KeyInfo.KeyChar)) { return [pscustomobject]@{ Name = 'Other'; Char = $null } }
    return [pscustomobject]@{ Name = 'Char'; Char = $KeyInfo.KeyChar }
}

function Read-MbcKey {
    # The next key; 'Resize' when the window changes; 'Tick' after -TimeoutMs with no key.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int] $TimeoutMs = 0)
    if ($null -ne $script:MbcKeyQueue) {
        if ($script:MbcKeyQueue.Count -gt 0) { $script:MbcDrainedReads = 0; return $script:MbcKeyQueue.Dequeue() }
        # A drained queue reads as Ctrl+C, a few times, and then refuses: a scripted session never hangs.
        $script:MbcDrainedReads++
        if ($script:MbcDrainedReads -gt 5) { throw 'The scripted keys ran out.' }
        return [pscustomobject]@{ Name = 'CtrlC'; Char = $null }
    }
    $width = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ([Console]::KeyAvailable) { return (ConvertTo-MbcKey -KeyInfo ([Console]::ReadKey($true))) }
        if ([Console]::WindowWidth -ne $width -or [Console]::WindowHeight -ne $height) { return [pscustomobject]@{ Name = 'Resize'; Char = $null } }
        if ($TimeoutMs -gt 0 -and $clock.ElapsedMilliseconds -ge $TimeoutMs) { return [pscustomobject]@{ Name = 'Tick'; Char = $null } }
        Start-Sleep -Milliseconds 25
    }
}

function Test-MbcAbandonKey {
    # During a run: has the operator pressed Esc or Ctrl+C? Reads only what is already waiting.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($null -ne $script:MbcKeyQueue) {
        if ($script:MbcKeyQueue.Count -gt 0 -and $script:MbcKeyQueue.Peek().Name -in 'Escape', 'CtrlC') { [void]$script:MbcKeyQueue.Dequeue(); return $true }
        return $false
    }
    try {
        while ([Console]::KeyAvailable) {
            $k = ConvertTo-MbcKey -KeyInfo ([Console]::ReadKey($true))
            if ($k.Name -in 'Escape', 'CtrlC') { return $true }
        }
    }
    catch { return $false }
    return $false
}

function Update-MbcTuiView {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)
    Write-MbcFrame -Lines (Format-MbcFrame -State $State -Cap (Get-MbcTerminalCapability))
}

function Read-MbcLine {
    <#
    .SYNOPSIS
        A one-line prompt drawn inside the TUI. Returns the text, or $null on Esc. A masked prompt
        shows dots, and the text stays in memory only.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Title, [Parameter(Mandatory)][string] $Label, [switch] $Mask, [string] $Initial = '')
    $returnTo = $State.Screen
    $State.LastPromptKey = $null
    $State.Prompt = @{ Title = $Title; Label = $Label; Mask = [bool]$Mask; Value = $Initial }
    $State.Screen = 'prompt'
    try {
        while ($true) {
            Update-MbcTuiView -State $State
            $key = Read-MbcKey
            switch ($key.Name) {
                'Enter' { return [string]$State.Prompt.Value }
                'Escape' { return $null }
                'CtrlC' { $State.LastPromptKey = 'CtrlC'; return $null }
                'Backspace' { if ($State.Prompt.Value.Length -gt 0) { $State.Prompt.Value = $State.Prompt.Value.Substring(0, $State.Prompt.Value.Length - 1) } }
                'Char' { $State.Prompt.Value += [string]$key.Char }
            }
        }
    }
    finally {
        $State.Prompt = $null
        $State.Screen = $returnTo
    }
}

function Invoke-MbcTuiOutside {
    # Leaves the alternate screen for anything that talks to the operator itself (browser sign-in,
    # a draft capture's messages), then comes back.
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock] $Action, [switch] $Pause)
    if ($null -ne $script:MbcKeyQueue) { & $Action; return }
    Exit-MbcScreen
    try { & $Action }
    finally {
        if ($Pause) { Write-MbcConsole -Text ("`nPress Enter to go back. "); [void][Console]::ReadLine() }
        Enter-MbcScreen
    }
}

function Set-MbcTuiBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Path)
    try {
        $b = Read-MbcBaseline -Path $Path
        $State.Baseline = $b
        switch ($b.SealState) {
            'Sealed' {
                $State.Flourish = 9
                Set-MbcTuiMessage -State $State -Text ('Chose {0} v{1}, fingerprint {2}. Sealed and unchanged.' -f $b.Name, $b.Version, $b.Fingerprint) -Style 'ok'
            }
            'Unsealed' {
                $hint = if ($State.AllowUnsealed) { 'It will run, stamped UNSEALED.' } else { 'Seal it before running (s, then Seal), or start with -AllowUnsealed.' }
                Set-MbcTuiMessage -State $State -Text "Chose $($b.Name) v$($b.Version). It isn't sealed. $hint" -Style 'warn'
            }
            default {
                Set-MbcTuiMessage -State $State -Text ('This baseline has been edited since v{0} was sealed. Raise the version and seal it again, or start with -AllowUnsealed.' -f $b.SealedVersion) -Style 'warn'
            }
        }
    }
    catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad' }
}

function Invoke-MbcTuiSignIn {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [switch] $Switch, [System.Collections.IDictionary] $ForPreset)
    $switchAccount = [bool]$Switch
    if ($State.Seams.Connection) {
        $State.Connection = $State.Seams.Connection
        Set-MbcTuiMessage -State $State -Text "Signed in to $($State.Connection.TenantName) as $($State.Connection.Account)." -Style 'ok'
        return
    }
    $preset = if ($ForPreset) { $ForPreset } elseif ($State.Baseline) { $State.Baseline.Document['preset'] } else { [ordered]@{ scopes = @(); checks = @() } }
    # A holder, because the block below runs in its own scope.
    $outcome = @{ Connection = $null; Failure = $null }
    Invoke-MbcTuiOutside -Action {
        try {
            if ($switchAccount -and $State.Connection) { [void](Invoke-MbcDisconnectAll); $State.Connection = $null }
            $plan = Get-MbcSignInPlan -Preset $preset
            Write-MbcConsole -Line -Text ''
            Write-MbcConsole -Line -Text $(if ($plan.Count -gt 1) { 'Signing in, one after another. Choose the same account each time.' } else { 'Signing in:' })
            for ($i = 0; $i -lt $plan.Count; $i++) { Write-MbcConsole -Line -Text "  $($i + 1). $($plan[$i])" }
            Write-MbcConsole -Line -Text 'Every session is read-only by construction. The view comes back when sign-in is done.'
            Write-MbcConsole -Line -Text ''
            $outcome.Connection = Connect-MbcSources -Preset $preset
        }
        catch { $outcome.Failure = $_.Exception.Message }
    }
    if ($outcome.Failure) { Set-MbcTuiMessage -State $State -Text "Sign-in didn't complete: $($outcome.Failure)" -Style 'bad'; return }
    $connection = $outcome.Connection
    $State.Connection = $connection
    $failed = @($connection.Failed.Keys)
    if ($failed.Count) { Set-MbcTuiMessage -State $State -Text "Signed in to $($connection.TenantName). Not connected: $(@($failed | ForEach-Object { $script:MbcSourceNames[$_] }) -join ', '); those checks will say so." -Style 'warn' }
    else { Set-MbcTuiMessage -State $State -Text "Signed in to $($connection.TenantName) as $($connection.Account)." -Style 'ok' }
}

function Invoke-MbcTuiRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)
    if (-not $State.Baseline) { Set-MbcTuiMessage -State $State -Text 'Choose a baseline first: press b.' -Style 'warn'; return }
    try { Assert-MbcBaselineUsable -Baseline $State.Baseline -AllowUnsealed:$State.AllowUnsealed -ExpectedFingerprint $State.ExpectedFingerprint }
    catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad'; return }
    if (-not $State.Connection) { Invoke-MbcTuiSignIn -State $State }
    elseif (-not $State.Seams.Connection -and -not (Test-MbcConnectionCovers -Connection $State.Connection -Preset $State.Baseline.Document['preset'])) {
        Invoke-MbcTuiSignIn -State $State -Switch
    }
    if (-not $State.Connection) { return }

    $b = $State.Baseline
    $preset = $b.Document['preset']
    $connection = $State.Connection
    $runId = New-MbcRunId
    $log = New-MbcRunLog -Directory (Join-Path $State.OutputRoot 'logs') -RunId $runId -Digest $b.Digest
    # Plaintext until a locked export carries it away; quitting says what is left.
    $State.PlaintextLogs.Add($log.Path)
    Write-MbcLog -Log $log -EventName 'run.start' -Data ([ordered]@{ tool = $script:MbcToolVersion; mode = 'tui'; baselineName = $b.Name; baselineVersion = $b.Version; sealState = $b.SealState })
    if ($connection.PSObject.Properties['Disclosure']) { Write-MbcLog -Log $log -EventName 'disclosure' -Data @{ lines = @($connection.Disclosure) } }

    $live = @{ Done = 0; Total = (Get-MbcRequestPlan -Preset $preset).Count; Label = 'Starting'; Phase = 'checks'; Waiting = 0; Lines = [System.Collections.Generic.List[object]]::new() }
    $State.Live = $live
    $State.Screen = 'run'
    Set-MbcTuiMessage -State $State -Text ''
    Update-MbcTuiView -State $State

    $redraw = { $State.Tick++; Update-MbcTuiView -State $State }
    $onWait = { param($Seconds) $live.Waiting = $Seconds; & $redraw }
    [scriptblock]$seamFetch = $State.Seams.Fetch
    $fetch = if ($seamFetch) { { param($Item) & $seamFetch $Item $redraw $onWait } }
    else { { param($Item) Invoke-MbcSourceFetch -Item $Item -Preset $preset -Connection $connection -Log $log -OnTick $redraw -OnWait $onWait } }
    $onProgress = {
        param($e)
        if (Test-MbcAbandonKey) { throw 'Run abandoned.' }
        if ($e.Phase -eq 'start') {
            $live.Label = Format-MbcRequestText -Source $e.Item.Source -ApiVersion $e.Item.ApiVersion -Request $e.Item.Request -Parameters $e.Item.Parameters
        }
        elseif ($e.Phase -eq 'done') { $live.Done = $e.Index }
        elseif ($e.Phase -eq 'inventory') { $live.Phase = 'inventory'; $live.Done = $live.Total; $live.Label = "Reading the app inventory: $($e.Label)" }
        & $redraw
    }
    $onResult = { param($r) $live.Lines.Add($r); Write-MbcCheckLog -Log $log -Result $r; & $redraw }
    $inventory = if (-not $State.IncludeInventory) { { param($OnProgress) $null = $OnProgress; New-MbcSkippedInventory } }
    elseif ($State.Seams.Inventory) { $State.Seams.Inventory }
    else {
        $tenantId = [string]$connection.TenantId
        { param($OnProgress) Invoke-MbcInventory -TenantId $tenantId -Log $log -OnProgress $OnProgress -OnTick $redraw }
    }

    try {
        $run = Invoke-MbcRun -Baseline $b -Fetch $fetch -OnProgress $onProgress -OnResult $onResult -RunId $runId -Inventory $inventory
        $document = New-MbcResultDocument -Run $run -Baseline $b -Connection $connection
        Write-MbcLog -Log $log -EventName 'run.end' -Data ([ordered]@{ pass = $run.Counts.Pass; fail = $run.Counts.Fail; error = $run.Counts.Error; resultDigest = $document['seal']['digest'] })
        $State.View = ConvertFrom-MbcResultDocument -Document $document
        $State.ViewSource = 'this run'
        $State.ViewFromFile = $false
        $State.Exported = $false
        $State.LockedAs = $null
        $State.RunLogPath = $log.Path
        Open-MbcTuiResults -State $State
        $c = $run.Counts
        $tail = if ($c.Fail + $c.Error -eq 0) { 'Nothing needs attention.' } else { 'x exports it.' }
        Set-MbcTuiMessage -State $State -Text ('Done. {0} met, {1} not, {2} unverifiable. {3}' -f $c.Pass, $c.Fail, $c.Error, $tail) -Style $(if ($c.Fail + $c.Error -eq 0) { 'ok' } else { 'dim' })
    }
    catch {
        $State.Screen = 'home'
        if ($_.Exception.Message -eq 'Run abandoned.') {
            Write-MbcLog -Log $log -EventName 'run.abandoned' -Data @{}
            Set-MbcTuiMessage -State $State -Text 'Abandoned. Nothing from that run was kept; the log has what happened.' -Style 'warn'
        }
        else {
            Write-MbcLog -Log $log -EventName 'run.failed' -Data @{ detail = $_.Exception.Message }
            Set-MbcTuiMessage -State $State -Text "The run stopped: $($_.Exception.Message)" -Style 'bad'
        }
    }
    finally { $State.Live = $null }
}

function Test-MbcLooksLikeBaseline {
    # Offered in the chooser only if it parses and carries both a preset and expected values.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)
    try {
        $doc = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText($Path))
        return ((Test-MbcIsDictionary $doc) -and $doc.Contains('preset') -and $doc.Contains('expected'))
    }
    catch { return $false }
}

function Get-MbcBaselineCandidates {
    # Baselines in the usual places: the output folder's baselines/, the current folder, and the examples.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State)
    $dirs = @((Join-Path $State.OutputRoot 'baselines'), (Get-Location).ProviderPath, (Join-Path $script:ModuleRoot 'presets'))
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter '*.json' -File)) {
            if (-not $found.Contains($f.FullName) -and (Test-MbcLooksLikeBaseline -Path $f.FullName)) { $found.Add($f.FullName) }
        }
    }
    return , $found.ToArray()
}

function Test-MbcLooksLikePreset {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)
    try {
        $doc = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText($Path))
        return ((Test-MbcIsDictionary $doc) -and $doc.Contains('checks') -and -not $doc.Contains('expected'))
    }
    catch { return $false }
}

function Get-MbcPresetCandidates {
    # Presets in the usual places: the output folder's presets/, the current folder, and the examples.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State)
    $dirs = @((Join-Path $State.OutputRoot 'presets'), (Get-Location).ProviderPath, (Join-Path $script:ModuleRoot 'presets'))
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter '*.json' -File)) {
            if (-not $found.Contains($f.FullName) -and (Test-MbcLooksLikePreset -Path $f.FullName)) { $found.Add($f.FullName) }
        }
    }
    return , $found.ToArray()
}

function Invoke-MbcTuiDraft {
    <#
    .SYNOPSIS
        Drafts a baseline from a preset by reading the signed-in tenant, with the view's own sign-in
        (signing in first if it doesn't cover the preset), writes it where the operator says, and makes
        the draft the chosen baseline so the next step, sealing, is one key away.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $PresetPath)
    try { $preset = Read-MbcPreset -Path $PresetPath }
    catch { $State.Screen = 'build'; Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad'; return }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PresetPath)
    $suggested = Join-Path (Join-Path $State.OutputRoot 'baselines') "$stem.baseline.json"
    $output = Read-MbcLine -State $State -Title 'Draft a baseline' -Label 'Where to write the draft. It reads this tenant and writes what it finds as the expected values; nothing is sealed yet. Enter keeps the suggestion.' -Initial $suggested
    if (-not $output) { $State.Screen = 'build'; return }
    if (Test-Path -LiteralPath $output -PathType Container) { $output = Join-Path $output "$stem.baseline.json" }
    if (Test-Path -LiteralPath $output) {
        $answer = Read-MbcLine -State $State -Title 'Draft a baseline' -Label "$output already exists. Replace it? Type yes to replace."
        if ($answer -cne 'yes') { Set-MbcTuiMessage -State $State -Text 'Nothing written.'; $State.Screen = 'build'; return }
    }
    if (-not $State.Seams.Connection -and (-not $State.Connection -or -not (Test-MbcConnectionCovers -Connection $State.Connection -Preset $preset))) {
        Invoke-MbcTuiSignIn -State $State -Switch -ForPreset $preset
        if (-not $State.Connection) { $State.Screen = 'build'; return }
    }
    if ($State.Seams.Connection -and -not $State.Connection) { $State.Connection = $State.Seams.Connection }
    $connection = $State.Connection
    [scriptblock]$seamFetch = $State.Seams.Fetch
    $draftFetch = if ($seamFetch) { { param($Item) & $seamFetch $Item $null $null } } else { { param($Item) Invoke-MbcSourceFetch -Item $Item -Preset $preset -Connection $connection } }
    $State.Screen = 'build'
    Set-MbcTuiMessage -State $State -Text "Reading this tenant for $([System.IO.Path]::GetFileName($PresetPath))."
    Update-MbcTuiView -State $State
    try {
        $collected = Invoke-MbcCollection -Plan (Get-MbcRequestPlan -Preset $preset) -Fetch $draftFetch
        $draft = New-MbcBaselineDraft -Preset $preset -Collected $collected -Name ([string]$preset['name']) -Version 1
        $folder = Split-Path -Parent ([System.IO.Path]::GetFullPath($output))
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        Write-MbcFileAtomic -Path $output -Text (ConvertTo-MbcPrettyJson -Value $draft.Document)
    }
    catch { Set-MbcTuiMessage -State $State -Text "The draft stopped: $($_.Exception.Message)" -Style 'bad'; return }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in @('', "  Drafted $($draft.Document['expected'].Count) expected value(s) into:", "  $output", '')) { $lines.Add($l) }
    if ($draft.Notes.Count) {
        # Grouped by reason, so twenty unreadable checks are one line, not twenty.
        $lines.Add("  Left for you to fill in by hand, $($draft.Notes.Count) check$(if ($draft.Notes.Count -ne 1) { 's' }):")
        $groups = [ordered]@{}
        foreach ($n in $draft.Notes) {
            $cut = $n.IndexOf(': ')
            $id = $n.Substring(0, $cut)
            $why = $n.Substring($cut + 2)
            if (-not $groups.Contains($why)) { $groups[$why] = [System.Collections.Generic.List[string]]::new() }
            $groups[$why].Add($id)
        }
        foreach ($why in $groups.Keys) { $lines.Add("    - $why`: $($groups[$why] -join ', ')") }
        $lines.Add('')
        $lines.Add('  Next: open the file, add an expected value for each of those, change any you don''t want to')
        $lines.Add('  keep, then seal it with "Seal a baseline" on this screen. It can''t run until it is sealed.')
    }
    else {
        $lines.Add('  Next: open the file and change any expected value you don''t want to keep, then seal it')
        $lines.Add('  with "Seal a baseline" on this screen. The draft is the chosen baseline now; runs wait for the seal.')
        Set-MbcTuiBaseline -State $State -Path $output
    }
    Set-MbcTuiMessage -State $State -Text ''
    $State.Panel = @{ Title = 'Draft written'; Lines = $lines.ToArray() }
    $State.PanelReturn = 'build'
    $State.Screen = 'panel'
}

function Show-MbcTuiChooser {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Title, [Parameter(Mandatory)][string] $Purpose, [AllowEmptyCollection()][string[]] $Files = @())
    $State.Files = @($Files)
    $State.ChooserIndex = 0
    $State.ChooserTitle = $Title
    $State.ChooserPurpose = $Purpose
    $State.Screen = 'chooser'
}

function Open-MbcTuiLocked {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Path)
    try { $keyId = (Read-MbcLockedFile -Path $Path)['keyId'] }
    catch { $State.Screen = 'home'; Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad'; return }
    $keyText = $script:MbcSessionKey
    # A key held from earlier is used only for files locked with it; any other file asks for its own.
    if ($keyText -and $keyText.Trim().Split(':')[2] -cne $keyId) { $keyText = $null }
    if (-not $keyText) {
        $keyText = Read-MbcLine -State $State -Title 'Open a locked result' -Label "Team key $keyId. It stays in memory for this session only." -Mask
        if (-not $keyText) { $State.Screen = 'home'; return }
    }
    try {
        $opened = Open-MbcLockedResult -Path $Path -KeyText $keyText
        $script:MbcSessionKey = $keyText
        $State.View = $opened.View
        $State.ViewSource = [System.IO.Path]::GetFileName($Path)
        $State.ViewFromFile = $true
        $State.Exported = $true
        $State.RunLogPath = $null
        Open-MbcTuiResults -State $State
        Set-MbcTuiMessage -State $State -Text "Opened $($State.ViewSource) with key $($opened.KeyId). It is in memory only." -Style 'ok'
    }
    catch {
        $State.Screen = 'home'
        Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad'
    }
}

function Invoke-MbcTuiExport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)
    if (-not $State.View) { Set-MbcTuiMessage -State $State -Text 'Nothing to export yet: run the checks first.' -Style 'warn'; return }
    $results = Join-Path $State.OutputRoot 'results'
    if ($State.ViewFromFile) {
        $answer = Read-MbcLine -State $State -Title 'Write as plaintext' -Label "This result is already filed, locked. Write its five result parts as plaintext into $results (its run log stays inside the locked file)? The parts hold tenant configuration: keep them on this machine, share them only through an access-controlled location, and delete them when done (docs/handling-results.md). Type yes to confirm."
        if ($answer -cne 'yes') { Set-MbcTuiMessage -State $State -Text 'Nothing written.'; return }
        try {
            $files = Export-MbcRunFiles -Document $State.View.Document -Directory $results -NoLock
            Set-MbcTuiMessage -State $State -Text "Written as plaintext: $(Split-Path -Leaf $files.Report) and four more, in $results. File them accordingly." -Style 'warn'
        }
        catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad' }
        return
    }
    if ($State.LockedAs) {
        Set-MbcTuiMessage -State $State -Text "Already exported, locked, as $(Split-Path -Leaf $State.LockedAs). Nothing written." -Style 'warn'
        return
    }
    $keyText = $script:MbcSessionKey
    $noLock = $false
    if (-not $keyText) {
        $entered = Read-MbcLine -State $State -Title 'Export' -Label 'Team key, to lock the export. Leave it empty to write plaintext instead.' -Mask
        if ($null -eq $entered) { Set-MbcTuiMessage -State $State -Text 'Not exported.'; return }
        if ($entered) {
            try { [void](ConvertFrom-MbcTeamKeyText -Text $entered) }
            catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad'; return }
            $keyText = $entered
            $script:MbcSessionKey = $entered
        }
        else {
            $confirm = Read-MbcLine -State $State -Title 'Export' -Label 'Write all five parts as plaintext, unencrypted? They hold tenant configuration: keep them on this machine, share them only through an access-controlled location, and delete them when done (docs/handling-results.md). The run log stays in plaintext too. Type yes to confirm.'
            if ($confirm -cne 'yes') { Set-MbcTuiMessage -State $State -Text 'Not exported.'; return }
            $noLock = $true
        }
    }
    try {
        $logPath = if ($noLock) { '' } else { [string]$State.RunLogPath }
        $files = Export-MbcRunFiles -Document $State.View.Document -Directory $results -KeyText $keyText -NoLock:$noLock -LogPath $logPath
        $State.Exported = $true
        $State.LockedAs = $files.Locked
        $names = @($files.Locked, $files.Summary | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ }) -join ' and '
        if ($noLock) { $names = 'five plaintext parts' }
        # One status line: what matters first, the long folder path last.
        $text = "Exported $names to $results."
        if ($files.LogLocked) {
            [void]$State.PlaintextLogs.Remove($logPath)
            $State.RunLogPath = $null
            $text = "Exported, run log locked inside and its plaintext deleted: $names, in $results."
        }
        Set-MbcTuiMessage -State $State -Text $text -Style 'ok'
    }
    catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad' }
}

function Invoke-MbcTuiEffect {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [Parameter(Mandatory)][string] $Effect)
    switch ($Effect) {
        'quit' {
            if ($State.View -and -not $State.ViewFromFile -and -not $State.Exported) {
                $answer = Read-MbcLine -State $State -Title 'Quit' -Label "This run's results haven't been exported, and they go when you quit. Quit anyway? Type y to quit."
                # Ctrl+C at this prompt means it: quit without asking again.
                if ($answer -notin 'y', 'yes' -and $State.LastPromptKey -ne 'CtrlC') { Set-MbcTuiMessage -State $State -Text 'Still here. x exports the results.'; return }
            }
            $State.Quit = $true
        }
        'run' { Invoke-MbcTuiRun -State $State }
        'signIn' { Invoke-MbcTuiSignIn -State $State -Switch }
        'chooseBaseline' { Show-MbcTuiChooser -State $State -Title 'Choose a baseline' -Purpose 'baseline' -Files (Get-MbcBaselineCandidates -State $State) }
        'openLocked' {
            $files = @(Get-ChildItem -LiteralPath (Join-Path $State.OutputRoot 'results') -Filter '*.locked' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object FullName)
            Show-MbcTuiChooser -State $State -Title 'Open a locked result' -Purpose 'locked' -Files $files
        }
        { $_ -in 'choose', 'enterPath' } {
            $path = if ($Effect -eq 'choose') { @($State.Files)[$State.ChooserIndex] } else { Read-MbcLine -State $State -Title $State.ChooserTitle -Label 'Path to the file' }
            if (-not $path) { return }
            if (Test-Path -LiteralPath $path -PathType Container) {
                $kind = switch ($State.ChooserPurpose) { 'locked' { 'a .locked result' } 'preset' { 'a preset (.json)' } default { 'a baseline (.json)' } }
                Set-MbcTuiMessage -State $State -Text "That is a folder. Choose a file: $kind." -Style 'warn'
                return
            }
            switch ($State.ChooserPurpose) {
                'baseline' { Set-MbcTuiBaseline -State $State -Path $path; $State.Screen = 'home' }
                'preset' { Invoke-MbcTuiDraft -State $State -PresetPath $path }
                default { Open-MbcTuiLocked -State $State -Path $path }
            }
        }
        'sealFile' {
            $initial = if ($State.Baseline) { $State.Baseline.Path } else { '' }
            $path = Read-MbcLine -State $State -Title 'Seal a baseline' -Label 'Path to the baseline to seal' -Initial $initial
            if (-not $path) { return }
            try {
                $id = Protect-Baseline -Path $path -InformationAction SilentlyContinue
                Set-MbcTuiMessage -State $State -Text ('Sealed. {0} is v{1}; its fingerprint is {2}. Record it wherever you keep these.' -f $id.Name, $id.Version, $id.Fingerprint) -Style 'ok'
                $State.Panel = @{ Title = 'Sealed'; Lines = @('', "  $($id.Name) is v$($id.Version); its fingerprint is $($id.Fingerprint).", '', '  Record this line wherever your team catalogues baselines:', '', "  $($id.Record)", '', '  The seal proves the file is unchanged. The recorded digest is what proves which version was used.') }
                $State.PanelReturn = 'build'
                $State.Screen = 'panel'
                if ($State.Baseline -and $State.Baseline.Path -eq $id.Path) { Set-MbcTuiBaseline -State $State -Path $id.Path }
            }
            catch { Set-MbcTuiMessage -State $State -Text $_.Exception.Message -Style 'bad' }
        }
        'captureDraft' { Show-MbcTuiChooser -State $State -Title 'Draft a baseline: choose a preset' -Purpose 'preset' -Files (Get-MbcPresetCandidates -State $State) }
        'newKey' {
            $text = New-MbcTeamKeyText
            $id = $text.Split(':')[2]
            $State.Panel = @{ Title = 'New team key'; Lines = @(
                    '', '  Your new team key:', '', "  $text", '',
                    '  Store it in one entry in your team''s password manager, named',
                    "  'M365 Baseline Check · results key $id'.", '',
                    '  It won''t be shown again, and nothing has been saved to disk.'
                )
            }
            $State.PanelReturn = 'build'
            $State.Screen = 'panel'
        }
        'export' { Invoke-MbcTuiExport -State $State }
        'search' {
            if ($State.Screen -eq 'apps') {
                $text = Read-MbcLine -State $State -Title 'Filter' -Label 'Show apps whose name or publisher contains' -Initial $State.AppSearch
                if ($null -ne $text) { $State.AppSearch = $text; $State.AppIndex = 0; $State.AppOffset = 0 }
            }
            else {
                $text = Read-MbcLine -State $State -Title 'Filter' -Label 'Show checks whose ID, setting or location contains' -Initial $State.Search
                if ($null -ne $text) { $State.Search = $text; $State.ResultIndex = 0; $State.ResultOffset = 0 }
            }
        }
    }
}

function Invoke-MbcTuiLoop {
    # The loop itself: draw, read a key, act. Animations tick only while there is one to show.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)
    while (-not $State.Quit) {
        $cap = Get-MbcTerminalCapability
        Write-MbcFrame -Lines (Format-MbcFrame -State $State -Cap $cap)
        $key = Read-MbcKey -TimeoutMs $(if ($State.Flourish -gt 0) { 70 } else { 0 })
        if ($key.Name -eq 'Tick') { if ($State.Flourish -gt 0) { $State.Flourish-- }; continue }
        if ($key.Name -in 'Resize', 'Other') { continue }
        $State.Flourish = 0
        if ($key.Name -eq 'CtrlC') { Invoke-MbcTuiEffect -State $State -Effect 'quit'; continue }
        $action = Resolve-MbcKeyAction -State $State -Key $key
        if ($action -eq 'none') { continue }
        if ($action -notin 'up', 'down', 'pageUp', 'pageDown', 'first', 'last', 'help', 'closeHelp') { Set-MbcTuiMessage -State $State -Text '' }
        $effect = Invoke-MbcTuiNavigation -State $State -Action $action -Cap $cap
        if ($effect) { Invoke-MbcTuiEffect -State $State -Effect $effect }
    }
}
