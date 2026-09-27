function New-BaselineCapture {
    <#
    .SYNOPSIS
        Drafts a baseline from a preset by reading a reference tenant. The draft is unsealed: review it,
        then seal it with Protect-Baseline.
    .DESCRIPTION
        Signs in to the sources the preset uses, reads each request once, and writes the values it finds
        as the expected values. Anything it can't read, or can't decide from one tenant, is left out and
        listed so you can fill it in by hand.
    .EXAMPLE
        New-BaselineCapture -PresetPath ./presets/example-tenant-hygiene.json -OutputPath ./baselines/draft.json -Name 'Core tenant'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $PresetPath,
        [Parameter(Mandatory)][string] $OutputPath,
        [string] $Name,
        [ValidateRange(1, [int]::MaxValue)][int] $Version = 1,
        [switch] $Force,
        [Parameter(DontShow)][scriptblock] $Fetch
    )
    # Messages show unless the caller chose otherwise.
    if (-not $PSBoundParameters.ContainsKey('InformationAction')) { $InformationPreference = 'Continue' }
    $preset = Read-MbcPreset -Path $PresetPath
    if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) { throw "'$OutputPath' already exists. Use -Force to replace it." }
    if (-not $Name) { $Name = [string]$preset['name'] }
    $connection = $null
    if (-not $Fetch) {
        $plan = Get-MbcSignInPlan -Preset $preset
        Write-Information "Signing in, one after another. Choose the same account each time."
        foreach ($l in $plan) { Write-Information "  $l" }
        $connection = Connect-MbcSources -Preset $preset
        foreach ($d in $connection.Disclosure) { Write-Information $d }
        $Fetch = { param($Item) Invoke-MbcSourceFetch -Item $Item -Preset $preset -Connection $connection }
    }
    try { $collected = Invoke-MbcCollection -Plan (Get-MbcRequestPlan -Preset $preset) -Fetch $Fetch }
    finally {
        if ($connection) {
            $closed = Invoke-MbcDisconnectAll
            if (@($closed).Count) { Write-Information "Signed out of $(@($closed) -join ', ')." }
        }
    }
    $draft = New-MbcBaselineDraft -Preset $preset -Collected $collected -Name $Name -Version $Version

    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write a draft baseline')) {
        Write-MbcFileAtomic -Path $OutputPath -Text (ConvertTo-MbcPrettyJson -Value $draft.Document)
        Write-Information "Drafted $($draft.Document['expected'].Count) expected value(s) from this tenant into $OutputPath."
        foreach ($note in $draft.Notes) { Write-Information "  - $note" }
        Write-Information 'Review it, then seal it with Protect-Baseline.'
    }
}
