function Invoke-BaselineCheck {
    <#
    .SYNOPSIS
        Checks the signed-in tenant against a sealed baseline, in plain output.
    .DESCRIPTION
        Refuses an unsealed or edited baseline unless -AllowUnsealed, and checks -ExpectedFingerprint
        before any network call. Signs in to Graph and to each Exchange source the baseline uses, reads
        everything once, and prints the results grouped by admin centre. Every run leaves a verbose log
        in the output folder. -Export writes one locked bundle (the team key is asked for) plus a plain
        summary.md; add -NoLock for plaintext parts instead.
    .EXAMPLE
        Invoke-BaselineCheck ./baselines/core-tenant.json -ExpectedFingerprint a1b2c3d4e5f6 -Export
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string] $Baseline,
        [switch] $AllowUnsealed,
        [string] $ExpectedFingerprint,
        [string] $OutputRoot,
        [switch] $Export,
        [switch] $NoLock,
        [securestring] $Key,
        [switch] $LockSummary,
        [switch] $SkipAppInventory,
        [Parameter(DontShow)][scriptblock] $Fetch,
        [Parameter(DontShow)] $Connection,
        [Parameter(DontShow)][scriptblock] $Inventory
    )
    # Messages show unless the caller chose otherwise.
    if (-not $PSBoundParameters.ContainsKey('InformationAction')) { $InformationPreference = 'Continue' }
    $b = Read-MbcBaseline -Path $Baseline
    Assert-MbcBaselineUsable -Baseline $b -AllowUnsealed:$AllowUnsealed -ExpectedFingerprint $ExpectedFingerprint
    $preset = $b.Document['preset']

    $keyText = $null
    if ($Export -and -not $NoLock) {
        $secure = if ($Key) { $Key } else { Read-Host -AsSecureString -Prompt 'Team key (to lock the export)' }
        $keyText = ConvertFrom-MbcSecureKey -Key $secure
        [void](ConvertFrom-MbcTeamKeyText -Text $keyText)
    }

    $signedIn = $false
    $root = Get-MbcOutputRoot -Root $OutputRoot
    $runId = New-MbcRunId
    $log = New-MbcRunLog -Directory (Join-Path $root 'logs') -RunId $runId -Digest $b.Digest
    Write-MbcLog -Log $log -EventName 'run.start' -Data ([ordered]@{
            tool = $script:MbcToolVersion; mode = 'plain'
            baselineName = $b.Name; baselineVersion = $b.Version; sealState = $b.SealState
        })
    $say = { param($text) Write-Information $text }
    $unicode = Test-MbcUnicodeOutput
    $g = Get-MbcGlyphs -Unicode $unicode
    $width = Get-MbcPlainWidth

    $seal = if ($b.SealState -eq 'Sealed') { "sealed $($g.Seal)" } else { 'UNSEALED' }
    & $say (ConvertTo-MbcGlyphText ('{0} {1} v{2} {1} {3} {1} {4}' -f $b.Name, $g.Dot, $b.Version, $b.Fingerprint, $seal) $g)

    if (-not $Fetch) {
        $plan = Get-MbcSignInPlan -Preset $preset
        & $say $(if ($plan.Count -gt 1) { 'Signing in, one after another. Choose the same account each time.' } else { 'Signing in:' })
        foreach ($l in $plan) { & $say "  $l" }
        $Connection = Connect-MbcSources -Preset $preset -Log $log
        $signedIn = $true
        $Fetch = { param($Item) Invoke-MbcSourceFetch -Item $Item -Preset $preset -Connection $Connection -Log $log }
    }
    if ($Connection -and $Connection.PSObject.Properties['Disclosure']) {
        Write-MbcLog -Log $log -EventName 'disclosure' -Data @{ lines = @($Connection.Disclosure) }
        foreach ($d in $Connection.Disclosure) { & $say (ConvertTo-MbcGlyphText $d $g) }
    }

    if ($SkipAppInventory) { $Inventory = { param($OnProgress) $null = $OnProgress; New-MbcSkippedInventory } }
    elseif (-not $Inventory) {
        $tenantId = if ($Connection) { [string]$Connection.TenantId } else { '' }
        $Inventory = { param($OnProgress) Invoke-MbcInventory -TenantId $tenantId -Log $log -OnProgress $OnProgress }
    }

    try { $run = Invoke-MbcRun -Baseline $b -Fetch $Fetch -RunId $runId -Inventory $Inventory -OnResult { param($r) Write-MbcCheckLog -Log $log -Result $r } }
    finally {
        # Everything is read; leave nothing signed in behind.
        if ($signedIn) {
            $closed = Invoke-MbcDisconnectAll -Log $log
            if (@($closed).Count) { & $say "Signed out of $(@($closed) -join ', ')." }
            if ($Connection.PSObject.Properties['Consent']) { foreach ($a in (Format-MbcConsentAdvice -Consent $Connection.Consent)) { & $say $a } }
            foreach ($a in (Get-MbcBrokerAdvice -Account ([string]$Connection.Account))) { & $say $a }
        }
    }
    $document = New-MbcResultDocument -Run $run -Baseline $b -Connection $Connection
    $view = ConvertFrom-MbcResultDocument -Document $document

    foreach ($row in (Get-MbcResultRows -Results $view.Results -Filter 'all')) {
        if ($row.Kind -eq 'heading') { & $say '' }
        & $say (Format-MbcRowLine -Row $row -Width $width -Glyphs $g -Color $false)
    }
    & $say ''
    foreach ($line in (Format-MbcInventoryNote -Inventory $view.Inventory -Glyphs $g)) { & $say "App inventory: $line" }

    $files = $null
    if ($Export) {
        $files = Export-MbcRunFiles -Document $document -Directory (Join-Path $root 'results') -KeyText $keyText -NoLock:$NoLock -LockSummary:$LockSummary
    }
    Write-MbcLog -Log $log -EventName 'run.end' -Data ([ordered]@{ pass = $run.Counts.Pass; fail = $run.Counts.Fail; error = $run.Counts.Error; resultDigest = $document['seal']['digest'] })
    & $say ''
    & $say ('{0} met, {1} not, {2} unverifiable.' -f $run.Counts.Pass, $run.Counts.Fail, $run.Counts.Error)
    if ($files) {
        $written = @($files.Locked, $files.Json, $files.Csv, $files.Apps, $files.Report, $files.Summary | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
        & $say "Written to $(Join-Path $root 'results'): $written"
    }
    & $say "Log: $($log.Path)"
    $summary = [pscustomobject]@{
        PSTypeName  = 'Mbc.RunSummary'
        Summary     = '{0} met, {1} not, {2} unverifiable' -f $run.Counts.Pass, $run.Counts.Fail, $run.Counts.Error
        Fingerprint = $b.Fingerprint
        Written     = if ($files) { [string[]]@($files.Locked, $files.Json, $files.Csv, $files.Apps, $files.Report, $files.Summary | Where-Object { $_ }) } else { @() }
        LogPath     = $log.Path
        Counts      = $run.Counts
        Results     = $view.Results
        Inventory   = $view.Inventory
        Files       = $files
        Baseline    = (Get-MbcBaselineIdentity -Baseline $b)
        Document    = $document
    }
    # Shown compactly at the prompt; everything else is still on the object.
    $display = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('Summary', 'Fingerprint', 'Written', 'LogPath'))
    $summary | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@($display))
    return $summary
}
