# Drafting a baseline from a preset and a reference tenant. The draft is unsealed, for a person to review.

function Read-MbcPreset {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "There's no preset at '$Path'." }
    $preset = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [System.Text.Encoding]::UTF8))
    $problems = Test-MbcPresetShape -Preset $preset
    if ($problems.Count -gt 0) { throw ("'{0}' isn't a valid preset:`n  - {1}" -f $Path, ($problems -join "`n  - ")) }
    return $preset
}

function Get-MbcCapturedExpected {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check, [AllowNull()][object] $Actual)
    $include = { param($v) [pscustomobject]@{ Include = $true; Value = $v; Note = $null } }
    $skip = { param($note) [pscustomobject]@{ Include = $false; Value = $null; Note = $note } }
    switch ([string]$Check['operator']) {
        'equals' { return (& $include $Actual) }
        { $_ -in 'setEquals', 'subsetOf' } {
            if (Test-MbcIsList $Actual) { return (& $include $Actual) }
            return (& $skip 'expected a list and found a single value; write it by hand')
        }
        'in' {
            # @($Actual) as the argument: a one-element list. (, @(...)) would nest it and write [["x"]].
            if (Test-MbcIsScalar $Actual) { return (& $include @($Actual)) }
            return (& $skip 'expected a single value and found a list; write it by hand')
        }
        { $_ -in 'countAtLeast', 'countAtMost' } {
            if (Test-MbcIsList $Actual) { return (& $include ([long]$Actual.Count)) }
            return (& $skip 'expected a list to count; write it by hand')
        }
        { $_ -in 'exists', 'absent' } { return (& $skip $null) }
        default { return (& $skip "a value for $($Check['operator']) can't be read off one tenant; write it by hand") }
    }
}

function New-MbcBaselineDraft {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Preset,
        [Parameter(Mandatory)][hashtable] $Collected,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][long] $Version
    )
    $expected = [ordered]@{}
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($check in $Preset['checks']) {
        $id = [string]$check['id']
        $key = (Get-MbcPlanItem -Check $check).Key
        $got = if ($Collected.ContainsKey($key)) { $Collected[$key] } else { $null }
        if ($null -eq $got -or -not $got.Ok) {
            $cause = if ($got) { $got.Cause } else { 'not collected' }
            $notes.Add("${id}: couldn't be read ($cause); fill it in by hand")
            continue
        }
        $selected = Get-MbcSelectedValue -Check $check -Body $got.Body -CaseSensitive ($check.Contains('caseSensitive') -and [bool]$check['caseSensitive'])
        if (-not $selected.Ok -or ((Test-MbcNotFound $selected.Value) -and $check['operator'] -notin 'exists', 'absent')) {
            $why = if ($selected.Ok) { 'setting not found' } else { $selected.Cause }
            $notes.Add("${id}: couldn't be read ($why); fill it in by hand")
            continue
        }
        $captured = Get-MbcCapturedExpected -Check $check -Actual $selected.Value
        if ($captured.Include) { $expected[$id] = $captured.Value }
        elseif ($captured.Note) { $notes.Add("${id}: $($captured.Note)") }
    }
    $document = [ordered]@{ schemaVersion = 1L; name = $Name; version = $Version; preset = $Preset; expected = $expected }
    return [pscustomobject]@{ Document = $document; Notes = $notes.ToArray() }
}
