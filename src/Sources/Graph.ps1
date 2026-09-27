$script:MbcGraphHost = 'graph.microsoft.com'
$script:MbcMaxPages = 200
$script:MbcMaxRetries = 3
$script:MbcMaxWaitSeconds = 30

function Invoke-MbcGraphTransport {
    <#
    .SYNOPSIS
        The only code in this module that talks to Microsoft Graph. The method is a literal GET and
        nothing can change it: no caller passes a method, because there is no parameter to pass one
        through. tests/ReadOnly.Tests.ps1 holds this.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Uri)
    $status = 0
    $headers = $null
    $body = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Json -SkipHttpErrorCheck -StatusCodeVariable 'status' -ResponseHeadersVariable 'headers' -ErrorAction Stop
    $retryAfter = $null
    if ($headers) {
        foreach ($name in @($headers.Keys)) {
            if ($name -ieq 'Retry-After') { $retryAfter = [string](@($headers[$name])[0]) }
        }
    }
    return [pscustomobject]@{ Status = [int]$status; Body = [string]$body; RetryAfter = $retryAfter }
}

function Wait-MbcSeconds {
    # Sleeps in 100 ms slices, calling OnTick after each, so a spinner keeps turning through a wait.
    [CmdletBinding()]
    param([Parameter(Mandatory)][double] $Seconds, [scriptblock] $OnTick)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $limit = [long]($Seconds * 1000)
    while ($clock.ElapsedMilliseconds -lt $limit) {
        Start-Sleep -Milliseconds ([Math]::Max(1, [Math]::Min(100, $limit - $clock.ElapsedMilliseconds)))
        if ($OnTick) { & $OnTick }
    }
}

function Get-MbcStatusCause {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int] $Status)
    if ($Status -ge 200 -and $Status -lt 300) { return $null }
    if ($Status -eq 400) { return 'request rejected' }
    if ($Status -in 401, 403) { return 'permission missing' }
    if ($Status -eq 404) { return 'not found' }
    if ($Status -eq 429) { return 'throttled' }
    return 'service error'
}

function Get-MbcRetryDelay {
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()][string] $RetryAfter, [Parameter(Mandatory)][int] $Attempt)
    $seconds = 0
    if ($RetryAfter -and [int]::TryParse($RetryAfter, [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$seconds)) {
        return [Math]::Min([Math]::Max(1, $seconds), $script:MbcMaxWaitSeconds)
    }
    return [Math]::Min([int][Math]::Pow(2, $Attempt), $script:MbcMaxWaitSeconds)
}

function Get-MbcPropertyNames {
    # The top-level property names of a response, or of its first value item, for the log. No values.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object] $Body)
    if (-not (Test-MbcIsDictionary $Body)) { return , @() }
    $target = $Body
    if ($Body.Contains('value') -and (Test-MbcIsList $Body['value'])) {
        $first = @($Body['value']) | Select-Object -First 1
        $target = if (Test-MbcIsDictionary $first) { $first } else { [ordered]@{} }
    }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $target.Keys) {
        $v = $target[$k]
        if ($null -eq $v) { $names.Add("$k=null") }
        elseif (Test-MbcIsDictionary $v) {
            if ($v.Count -eq 0) { $names.Add("$k={}") }
            foreach ($sub in $v.Keys) { $names.Add("$k.$sub$(if ($null -eq $v[$sub]) { '=null' })") }
        }
        else { $names.Add([string]$k) }
        if ($names.Count -ge 80) { break }
    }
    return , $names.ToArray()
}

function Test-MbcGraphNextLink {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Link)
    $parsed = $null
    if (-not [uri]::TryCreate($Link, [UriKind]::Absolute, [ref]$parsed)) { return $false }
    return ($parsed.Scheme -ceq 'https' -and $parsed.Host -ieq $script:MbcGraphHost)
}

function Invoke-MbcGraphGet {
    <#
    .SYNOPSIS
        GETs a Graph path, following pages and waiting out throttling. Returns a fetch result; never
        throws for a failed request. There is no method parameter.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('v1.0', 'beta')][string] $ApiVersion,
        [Parameter(Mandatory)][string] $Request,
        # param($Uri) -> { Status; Body; RetryAfter }. Tests inject one; by default it is the transport.
        [scriptblock] $Transport,
        # param($Seconds, $OnTick). By default, Wait-MbcSeconds.
        [scriptblock] $Sleep,
        # Called after each page and through throttling waits, for a spinner. Cosmetic only.
        [scriptblock] $OnTick,
        # Called with the seconds about to be waited, then with 0 when the wait is over.
        [scriptblock] $OnWait,
        [ValidateRange(1, 1000)][int] $MaxPages = $script:MbcMaxPages,
        [AllowNull()] $Log
    )
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $logEntry = { param($data) Write-MbcLog -Log $Log -EventName 'request' -Data $data }
    if (-not (Test-MbcGraphPathText $Request)) {
        & $logEntry ([ordered]@{ source = 'graph'; request = $Request; cause = 'request rejected' })
        return (New-MbcFetchResult -Ok $false -Cause 'request rejected' -Detail "'$Request' isn't a Graph path.")
    }

    $uri = "https://$($script:MbcGraphHost)/$ApiVersion$Request"
    $root = $null
    $values = $null
    $pageCount = 0
    $waited = 0
    $fail = {
        param($cause, $detail, $status)
        & $logEntry ([ordered]@{ source = 'graph'; apiVersion = $ApiVersion; request = $Request; status = $status; cause = $cause; detail = $detail; pages = $pageCount; waitedSeconds = $waited; durationMs = $clock.ElapsedMilliseconds })
        New-MbcFetchResult -Ok $false -Status $status -Cause $cause -Detail $detail -Pages $pageCount
    }
    while ($uri) {
        $pageCount++
        if ($pageCount -gt $MaxPages) { return (& $fail 'too many pages' "Stopped after $MaxPages pages." 200) }
        $attempt = 0
        while ($true) {
            try {
                $response = if ($Transport) { & $Transport $uri } else { Invoke-MbcGraphTransport -Uri $uri }
            }
            catch {
                $message = $_.Exception.Message
                $cause = if (Test-MbcContainsAny -Text $message -Fragments @('Connect-MgGraph', 'Authentication needed', 'not connected')) { 'not connected' } else { 'service error' }
                return (& $fail $cause "$($_.Exception.GetType().Name): $message" 0)
            }
            if ($response.Status -in 429, 503, 504 -and $attempt -lt $script:MbcMaxRetries) {
                $attempt++
                $wait = Get-MbcRetryDelay -RetryAfter $response.RetryAfter -Attempt $attempt
                $waited += $wait
                Write-MbcLog -Log $Log -EventName 'throttled' -Data ([ordered]@{ source = 'graph'; request = $Request; status = $response.Status; waitSeconds = $wait; attempt = $attempt })
                if ($OnWait) { & $OnWait $wait }
                if ($Sleep) { & $Sleep $wait $OnTick } else { Wait-MbcSeconds -Seconds $wait -OnTick $OnTick }
                if ($OnWait) { & $OnWait 0 }
                continue
            }
            break
        }
        $cause = Get-MbcStatusCause -Status $response.Status
        if ($cause) { return (& $fail $cause "HTTP $($response.Status)" $response.Status) }
        try { $page = ConvertFrom-MbcJson -Json ([string]$response.Body) -AllowFloat }
        catch { return (& $fail 'malformed response' $_.Exception.Message $response.Status) }
        if (-not (Test-MbcIsDictionary $page)) { return (& $fail 'malformed response' 'The response is not a JSON object.' $response.Status) }

        if ($null -eq $root) { $root = $page }
        if ($page.Contains('value') -and (Test-MbcIsList $page['value'])) {
            if ($null -eq $values) { $values = [System.Collections.Generic.List[object]]::new() }
            foreach ($v in $page['value']) { $values.Add($v) }
        }
        $next = if ($page.Contains('@odata.nextLink')) { [string]$page['@odata.nextLink'] } else { $null }
        if ($next -and -not (Test-MbcGraphNextLink -Link $next)) {
            return (& $fail 'malformed response' 'A nextLink pointed somewhere other than Graph.' $response.Status)
        }
        if ($OnTick) { & $OnTick }
        $uri = $next
    }
    if ($null -ne $values) {
        $root['value'] = $values.ToArray()
        if ($root.Contains('@odata.nextLink')) { $root.Remove('@odata.nextLink') }
    }
    # Property names only, never values: enough to see why a select path found nothing.
    & $logEntry ([ordered]@{ source = 'graph'; apiVersion = $ApiVersion; request = $Request; status = 200; pages = $pageCount; waitedSeconds = $waited; durationMs = $clock.ElapsedMilliseconds; properties = Get-MbcPropertyNames -Body $root })
    return (New-MbcFetchResult -Ok $true -Body $root -Status 200 -Pages $pageCount)
}
