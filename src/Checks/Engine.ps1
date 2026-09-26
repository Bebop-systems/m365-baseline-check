# Plan, collect, select, compare (spec 7.4). Collection is the only step that does I/O, and it does it
# through a Fetch block the caller supplies: param($Item) -> New-MbcFetchResult. Everything after is pure.

function New-MbcFetchResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool] $Ok,
        [AllowNull()][object] $Body,
        [int] $Status = 0,
        [AllowNull()][string] $Cause,
        [AllowNull()][string] $Detail,
        [int] $Pages = 0
    )
    return [pscustomobject]@{ PSTypeName = 'Mbc.FetchResult'; Ok = $Ok; Body = $Body; Status = $Status; Cause = $Cause; Detail = $Detail; Pages = $Pages }
}

function Get-MbcRequestKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Source,
        [AllowEmptyString()][string] $ApiVersion = '',
        [Parameter(Mandatory)][string] $Request,
        [System.Collections.IDictionary] $Parameters = [ordered]@{}
    )
    if ($Source -eq 'graph') { return "graph|$ApiVersion|$Request" }
    return '{0}|{1}|{2}' -f $Source, $Request.ToLowerInvariant(), (ConvertTo-MbcCanonicalJson -Value $Parameters)
}

function Get-MbcPlanItem {
    # The request a check needs, as a plan item. Pure; says nothing about whether it is declared.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check)
    $source = Get-MbcCheckSource -Check $Check
    $request = [string]$Check['request']
    $api = if ($source -eq 'graph') { Get-MbcCheckApiVersion -Check $Check } else { '' }
    $parameters = Get-MbcCheckParameters -Check $Check
    return [pscustomobject]@{
        PSTypeName = 'Mbc.PlanItem'
        Key        = Get-MbcRequestKey -Source $source -ApiVersion $api -Request $request -Parameters $parameters
        Source     = $source
        ApiVersion = $api
        Request    = $request
        Parameters = $parameters
    }
}

function Test-MbcCheckRequestDeclared {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check, [Parameter(Mandatory)][System.Collections.IDictionary] $Preset)
    $source = Get-MbcCheckSource -Check $Check
    $request = [string]$Check['request']
    if ($source -eq 'graph') {
        if (-not (Test-MbcGraphPathText $request)) { return $false }
        return (Test-MbcRequestDeclared -Request ([uri]::UnescapeDataString($request)) -Endpoints ([string[]]@($Preset['endpoints'])))
    }
    if ($source -notin $script:MbcCmdletSources) { return $false }
    $cmdlets = if ($Preset.Contains('cmdlets')) { $Preset['cmdlets'] } else { $null }
    return ((Test-MbcCmdletName -Name $request) -and (Test-MbcCmdletDeclared -Name $request -Source $source -Cmdlets $cmdlets))
}

function Get-MbcRequestPlan {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Preset)
    $seen = [ordered]@{}
    foreach ($check in $Preset['checks']) {
        if (-not (Test-MbcCheckRequestDeclared -Check $check -Preset $Preset)) { continue }
        $item = Get-MbcPlanItem -Check $check
        if (-not $seen.Contains($item.Key)) { $seen[$item.Key] = $item }
    }
    return , @($seen.Values)
}

function Invoke-MbcFetchOne {
    # One fetch, with progress either side. A Fetch that throws is a service error, never a pass.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)][scriptblock] $Fetch,
        [int] $Index,
        [int] $Total,
        [scriptblock] $OnProgress
    )
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ Phase = 'start'; Index = $Index; Total = $Total; Item = $Item; Ok = $null }) }
    try { $result = & $Fetch $Item }
    catch { $result = New-MbcFetchResult -Ok $false -Cause 'service error' -Detail $_.Exception.Message }
    if ($null -eq $result) { $result = New-MbcFetchResult -Ok $false -Cause 'not collected' -Detail 'The fetch returned nothing.' }
    if ($OnProgress) { & $OnProgress ([pscustomobject]@{ Phase = 'done'; Index = $Index; Total = $Total; Item = $Item; Ok = [bool]$result.Ok }) }
    return $result
}

function Invoke-MbcCollection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Plan,
        [Parameter(Mandatory)][scriptblock] $Fetch,
        [scriptblock] $OnProgress
    )
    $collected = @{}
    for ($i = 0; $i -lt $Plan.Count; $i++) {
        $collected[$Plan[$i].Key] = Invoke-MbcFetchOne -Item $Plan[$i] -Fetch $Fetch -Index ($i + 1) -Total $Plan.Count -OnProgress $OnProgress
    }
    return $collected
}

function Get-MbcSelectedValue {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check, [AllowNull()][object] $Body, [bool] $CaseSensitive)
    try {
        $query = ConvertTo-MbcPathQuery -Select ([string]$Check['select'])
        $value = Invoke-MbcPathQuery -Query $query -Document $Body -CaseSensitive:$CaseSensitive
        return [pscustomobject]@{ Ok = $true; Value = $value; Cause = $null; Detail = $null }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Cause = 'baseline expects a list'; Detail = $_.Exception.Message }
    }
}

function Get-MbcCheckResult {
    # Select and compare for one check, given what was collected for it (or $null). Pure.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Check,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Preset,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [AllowNull()] $Got
    )
    $id = [string]$Check['id']
    $item = Get-MbcPlanItem -Check $Check
    $expectedValue = if ($Expected.Contains($id)) { $Expected[$id] } else { $null }
    $cs = $Check.Contains('caseSensitive') -and [bool]$Check['caseSensitive']
    $actual = $script:MbcNotFound
    $verdict = 'Error'
    $cause = $null
    $detail = $null

    if (-not (Test-MbcCheckRequestDeclared -Check $Check -Preset $Preset)) { $cause = 'request not declared' }
    elseif ($null -eq $Got) { $cause = 'not collected' }
    elseif (-not $Got.Ok) { $cause = $Got.Cause; $detail = $Got.Detail }
    else {
        $selected = Get-MbcSelectedValue -Check $Check -Body $Got.Body -CaseSensitive $cs
        if (-not $selected.Ok) { $cause = $selected.Cause; $detail = $selected.Detail }
        else {
            $actual = $selected.Value
            $comparison = Compare-MbcValue -Actual $actual -Operator ([string]$Check['operator']) -Expected $expectedValue -CaseSensitive:$cs
            $verdict = $comparison.Verdict
            $cause = $comparison.Cause
        }
    }
    # Error never becomes Pass, and never goes without a cause from the closed vocabulary.
    if ($verdict -eq 'Error' -and $cause -notin $script:MbcCauses) {
        if ($cause) { $detail = (@($cause, $detail) | Where-Object { $_ }) -join ': ' }
        $cause = 'not collected'
    }

    $hasActual = -not (Test-MbcNotFound $actual)
    return [pscustomobject]@{
        PSTypeName = 'Mbc.CheckResult'
        Id         = $id
        Title      = [string]$Check['title']
        Area       = [string]$Check['area']
        Location   = if ($Check.Contains('location')) { [string]$Check['location'] } else { '' }
        Severity   = [string]$Check['severity']
        Why        = if ($Check.Contains('why')) { [string]$Check['why'] } else { '' }
        Source     = $item.Source
        Request    = $item.Request
        Parameters = $item.Parameters
        ApiVersion = $item.ApiVersion
        Select     = [string]$Check['select']
        Operator   = [string]$Check['operator']
        Expected   = $expectedValue
        Actual     = if ($hasActual) { $actual } else { $null }
        HasActual  = $hasActual
        Verdict    = $verdict
        Cause      = $cause
        Detail     = $detail
        Labels     = if ($Check.Contains('labels')) { $Check['labels'] } else { [ordered]@{} }
    }
}

function Invoke-MbcEvaluation {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Preset,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][hashtable] $Collected,
        [scriptblock] $OnResult
    )
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($check in $Preset['checks']) {
        $key = (Get-MbcPlanItem -Check $check).Key
        $got = if ($Collected.ContainsKey($key)) { $Collected[$key] } else { $null }
        $result = Get-MbcCheckResult -Check $check -Preset $Preset -Expected $Expected -Got $got
        $results.Add($result)
        if ($OnResult) { & $OnResult $result }
    }
    return , $results.ToArray()
}

function Get-MbcCounts {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Results)
    $counts = [pscustomobject]@{ Pass = 0; Fail = 0; Error = 0; Total = $Results.Count }
    foreach ($r in $Results) {
        switch ([string]$r.Verdict) { 'Pass' { $counts.Pass++ } 'Fail' { $counts.Fail++ } default { $counts.Error++ } }
    }
    return $counts
}

function Invoke-MbcRun {
    <#
    .SYNOPSIS
        One run: each distinct request fetched once, each check decided as soon as its request is in,
        then the app inventory. Results come back in check order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Baseline,
        [Parameter(Mandatory)][scriptblock] $Fetch,
        [scriptblock] $OnProgress,
        [scriptblock] $OnResult,
        [string] $RunId = (New-MbcRunId),
        # param($OnProgress) -> the inventory. Called after every check is decided.
        [scriptblock] $Inventory
    )
    $preset = $Baseline.Document['preset']
    $expected = $Baseline.Document['expected']
    $started = [datetime]::UtcNow
    $checks = @($preset['checks'])
    $byId = @{}
    $streamTo = $OnResult
    $emit = {
        param($check, $got)
        $result = Get-MbcCheckResult -Check $check -Preset $preset -Expected $expected -Got $got
        $byId[[string]$check['id']] = $result
        if ($streamTo) { & $streamTo $result }
    }

    foreach ($check in $checks) {
        if (-not (Test-MbcCheckRequestDeclared -Check $check -Preset $preset)) { & $emit $check $null }
    }
    $plan = Get-MbcRequestPlan -Preset $preset
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $got = Invoke-MbcFetchOne -Item $plan[$i] -Fetch $Fetch -Index ($i + 1) -Total $plan.Count -OnProgress $OnProgress
        foreach ($check in $checks) {
            if ($byId.ContainsKey([string]$check['id'])) { continue }
            if ((Get-MbcPlanItem -Check $check).Key -eq $plan[$i].Key) { & $emit $check $got }
        }
    }

    $inventoryResult = $null
    if ($Inventory) { $inventoryResult = & $Inventory $OnProgress }
    $results = @($checks | ForEach-Object { $byId[[string]$_['id']] })
    return [pscustomobject]@{
        PSTypeName  = 'Mbc.Run'
        RunId       = $RunId
        StartedUtc  = $started
        FinishedUtc = [datetime]::UtcNow
        Results     = $results
        Counts      = (Get-MbcCounts -Results $results)
        Inventory   = $inventoryResult
    }
}
