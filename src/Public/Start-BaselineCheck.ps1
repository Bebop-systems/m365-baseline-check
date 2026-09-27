function Start-BaselineCheck {
    <#
    .SYNOPSIS
        The interactive view: choose a baseline, sign in, run, read the results by admin centre, look
        through the app inventory, export.
    .DESCRIPTION
        Falls back to plain output (Invoke-BaselineCheck) when the console can't host the view: output
        redirected, no virtual terminal support, or not a console host. Set M365BC_ASCII=1 for
        ASCII-only drawing, or NO_COLOR=1 for no colour. Press ? on any screen for its keys. Refuses an
        output folder that synchronises to the cloud unless -AllowSyncedOutput; a locked export carries
        the run log inside it. docs/handling-results.md covers storing results.
    .EXAMPLE
        Start-BaselineCheck
    .EXAMPLE
        Start-BaselineCheck -Baseline ./baselines/core-tenant.json -ExpectedFingerprint a1b2c3d4e5f6
    #>
    [CmdletBinding()]
    param(
        [string] $Baseline,
        [string] $OutputRoot,
        [switch] $AllowUnsealed,
        [string] $ExpectedFingerprint,
        [switch] $SkipAppInventory,
        [switch] $AllowSyncedOutput,
        [Parameter(DontShow)][scriptblock] $Fetch,
        [Parameter(DontShow)] $Connection,
        [Parameter(DontShow)][scriptblock] $Inventory
    )
    $cap = Get-MbcTerminalCapability
    if (-not $cap.Interactive) {
        if (-not $Baseline) {
            throw "This console can't host the interactive view: its output is redirected, or it doesn't support terminal sequences. Run Invoke-BaselineCheck -Baseline <path> instead."
        }
        Write-Warning "This console can't host the interactive view, so this runs in plain output instead."
        return (Invoke-BaselineCheck -Baseline $Baseline -OutputRoot $OutputRoot -AllowUnsealed:$AllowUnsealed -ExpectedFingerprint $ExpectedFingerprint -SkipAppInventory:$SkipAppInventory -AllowSyncedOutput:$AllowSyncedOutput -Fetch $Fetch -Connection $Connection -Inventory $Inventory)
    }
    # Before anything is written: run logs are plaintext while a run goes, so they mustn't land in a synced folder.
    $refusal = Get-MbcSyncedRefusal -OutputRoot (Resolve-MbcOutputBase -Root $OutputRoot) -Allowed:$AllowSyncedOutput
    if ($refusal) { throw $refusal }

    $state = New-MbcTuiState -OutputRoot (Get-MbcOutputRoot -Root $OutputRoot)
    $state.AllowUnsealed = [bool]$AllowUnsealed
    $state.ExpectedFingerprint = $ExpectedFingerprint
    $state.IncludeInventory = -not $SkipAppInventory
    $state.Seams = @{ Fetch = $Fetch; Connection = $Connection; Inventory = $Inventory }
    $stale = Get-MbcStaleNote -OutputRoot $state.OutputRoot
    if ($stale) { Set-MbcTuiMessage -State $state -Text $stale -Style 'warn' }
    if ($Baseline) { Set-MbcTuiBaseline -State $state -Path $Baseline }

    $savedEncoding = [Console]::OutputEncoding
    try {
        if (-not $env:M365BC_ASCII) { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) }
        Enter-MbcScreen
        Invoke-MbcTuiLoop -State $state
    }
    finally {
        Exit-MbcScreen
        [Console]::OutputEncoding = $savedEncoding
        $script:MbcSessionKey = $null
        # Leave nothing signed in behind: every session the view opened is closed on the way out.
        if ($state.Connection -and -not $Connection) {
            $consent = if ($state.Connection.PSObject.Properties['Consent']) { $state.Connection.Consent } else { $null }
            $closed = Invoke-MbcDisconnectAll
            $message = if (@($closed).Count) { "Signed out of $(@($closed) -join ', '). The team key, if one was given, is forgotten." } else { 'Nothing was left signed in.' }
            Write-Information $message -InformationAction Continue
            $consentLines = Format-MbcConsentAdvice -Consent $consent
            $brokerLines = Get-MbcBrokerAdvice -Account ([string]$state.Connection.Account)
            $advice = [string[]]@($consentLines) + [string[]]@($brokerLines)
            if ($advice.Count) { Write-Information '' -InformationAction Continue; foreach ($a in $advice) { Write-Information $a -InformationAction Continue } }
        }
        # Said once the view is gone, so it stays on screen.
        $plain = [string[]]@($state.PlaintextLogs | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($plain.Count) { Write-Information (Get-MbcPlaintextLogNote -Path $plain) -InformationAction Continue }
        if ($stale) { Write-Information $stale -InformationAction Continue }
    }
}
