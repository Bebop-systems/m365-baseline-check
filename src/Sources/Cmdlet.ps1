# The Get-only cmdlet client for the exo and compliance sources (spec 6.2). A cmdlet runs only when every
# guard holds, and only through Invoke-MbcCmdletRunner. Its output is flattened once, to one level.

$script:MbcPermissionWords = @("isn't authorized", 'is not authorized', 'not authorised', 'access denied', 'access is denied', 'unauthorized', 'insufficient permission', 'does not have permission', "doesn't have permission")
$script:MbcNotFoundWords = @("couldn't be found", 'could not be found', "couldn't find", 'was not found')

function ConvertTo-MbcFlatScalar {
    # A value that must end up scalar: kept if it already is one, else its text.
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $null }
    $original = $Value
    $Value = $Value.PSObject.BaseObject
    if ($Value -is [string] -or $Value -is [bool] -or (Test-MbcIsNumber $Value)) { return $Value }
    if ($Value -is [char]) { return [string]$Value }
    if ($Value -is [enum]) { return $Value.ToString() }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture) }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('o', [cultureinfo]::InvariantCulture) }
    if ($Value -is [timespan]) { return $Value.ToString('c', [cultureinfo]::InvariantCulture) }
    if ($Value -is [guid]) { return $Value.ToString() }
    # PowerShells own conversion to text, which is what Format-List shows.
    return [string]$original
}

function ConvertTo-MbcFlatValue {
    # One property's value: a scalar, a list of scalars, or a map of scalars. Nothing deeper.
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $null }
    $inner = $Value.PSObject.BaseObject
    if ($inner -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($k in $inner.Keys) { $map[[string]$k] = ConvertTo-MbcFlatScalar -Value $inner[$k] }
        return $map
    }
    if ($inner -is [System.Collections.IEnumerable] -and $inner -isnot [string]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $inner) { $list.Add((ConvertTo-MbcFlatScalar -Value $item)) }
        return , $list.ToArray()
    }
    return (ConvertTo-MbcFlatScalar -Value $inner)
}

function ConvertTo-MbcFlatObject {
    # One object as an ordered map of its properties, in property order: what Format-List would show.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][object] $InputObject)
    $map = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $value = $null
        try { $value = $property.Value } catch { $value = $null }
        $map[$property.Name] = ConvertTo-MbcFlatValue -Value $value
    }
    return $map
}

function ConvertTo-MbcCmdletBody {
    <#
    .SYNOPSIS
        A cmdlet's output as { "value": [ ... ] }, whatever the count, so select paths never depend on
        how many objects a tenant has.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]] $Output)
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($o in @($Output)) {
        if ($null -eq $o) { continue }
        $base = $o.PSObject.BaseObject
        if ($base -is [System.Collections.IDictionary]) { $items.Add((ConvertTo-MbcFlatValue -Value $base)) }
        elseif ($base -is [string] -or $base -is [bool] -or $base -is [enum] -or $base -is [datetime] -or (Test-MbcIsNumber $base)) {
            $items.Add((ConvertTo-MbcFlatScalar -Value $base))
        }
        else { $items.Add((ConvertTo-MbcFlatObject -InputObject $o)) }
    }
    return [ordered]@{ value = $items.ToArray() }
}

function Invoke-MbcCmdletRunner {
    <#
    .SYNOPSIS
        The one place a cmdlet runs: through its CommandInfo, never through text. Callers pass only a
        command that Invoke-MbcCmdletGet has already resolved and checked.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Management.Automation.CommandInfo] $Command, [Parameter(Mandatory)][hashtable] $Parameters)
    $ProgressPreference = 'SilentlyContinue'
    # Warnings are discarded by redirecting the stream, not by -WarningAction: Exchange Online's cmdlets
    # pass their bound parameters on to the service, and Get-OrganizationConfig fails server-side when
    # it receives one it doesn't expect. A redirection never reaches the cmdlet. (A global $WarningPreference
    # of Stop or Inquire still applies inside the cmdlet's module; that is the operator's own setting.)
    return , @(& $Command @Parameters -ErrorAction Stop 3>$null)
}

function Resolve-MbcSessionCommand {
    # The command by that name exported by exactly that module, or $null.
    [CmdletBinding()]
    [OutputType([System.Management.Automation.CommandInfo])]
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Module)
    $found = @(Get-Command -Name $Name -Module $Module -CommandType Function, Cmdlet -ErrorAction SilentlyContinue |
            Where-Object { $_.ModuleName -ieq $Module -and $_.Name -ieq $Name })
    if ($found.Count -ne 1) { return $null }
    return $found[0]
}

function Invoke-MbcCmdletGet {
    <#
    .SYNOPSIS
        Runs one planned cmdlet request, if and only if every guard holds, and returns a fetch result.
        Never throws for a failed request.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Preset,
        # Source name to the module its connection created.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary] $Sessions,
        # param($Command, $Parameters) -> objects. Tests inject one; by default, Invoke-MbcCmdletRunner.
        [scriptblock] $Runner,
        [AllowNull()] $Log
    )
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $failure = $null
    $source = [string]$Item.Source
    $name = [string]$Item.Request
    $parameters = if ($Item.Parameters) { $Item.Parameters } else { [ordered]@{} }
    $runLog = $Log
    $finish = {
        param($cause, $detail, $body, $count)
        $names = if ($body) { Get-MbcPropertyNames -Body $body } else { @() }
        Write-MbcLog -Log $runLog -EventName 'request' -Data ([ordered]@{
                source = $source; request = $name; parameters = $parameters; cause = $cause; detail = $detail
                objects = $count; properties = $names; durationMs = $clock.ElapsedMilliseconds
            })
        if ($cause) { New-MbcFetchResult -Ok $false -Cause $cause -Detail $detail }
        else { New-MbcFetchResult -Ok $true -Body $body -Status 200 -Pages 1 }
    }

    if (-not (Test-MbcCmdletName -Name $name)) { return (& $finish 'request rejected' "'$name' isn't a plain Get- cmdlet name." $null 0) }
    $cmdlets = if ($Preset.Contains('cmdlets')) { $Preset['cmdlets'] } else { $null }
    if (-not (Test-MbcCmdletDeclared -Name $name -Source $source -Cmdlets $cmdlets)) {
        return (& $finish 'request not declared' "$name isn't declared under cmdlets.$source." $null 0)
    }
    if (-not $Sessions.Contains($source) -or -not $Sessions[$source]) {
        return (& $finish 'not connected' "There's no $source session." $null 0)
    }
    $module = [string]$Sessions[$source]
    $command = Resolve-MbcSessionCommand -Name $name -Module $module
    if ($null -eq $command) { return (& $finish 'cmdlet not available' "$name isn't in the $source session's module." $null 0) }

    $splat = @{}
    foreach ($p in $parameters.Keys) {
        if (-not $command.Parameters.ContainsKey([string]$p)) { return (& $finish 'request rejected' "$name has no parameter -$p." $null 0) }
        $value = $parameters[$p]
        if (-not ($value -is [string] -or $value -is [bool] -or (Test-MbcIsWholeNumber $value))) {
            return (& $finish 'request rejected' "-$p must be text, true or false, or a whole number." $null 0)
        }
        $splat[[string]$p] = $value
    }

    $attempt = 0
    while ($true) {
        try {
            $output = if ($Runner) { & $Runner $command $splat } else { Invoke-MbcCmdletRunner -Command $command -Parameters $splat }
            break
        }
        catch {
            # "A server side error has occurred ... Please try again after some time": twice more, then give up.
            if ($attempt -lt 2 -and (Test-MbcContainsAny -Text $_.Exception.Message -Fragments @('try again', 'server side error'))) {
                $attempt++
                Write-MbcLog -Log $runLog -EventName 'retry' -Data ([ordered]@{ source = $source; request = $name; attempt = $attempt; detail = $_.Exception.Message })
                Wait-MbcSeconds -Seconds (2 * $attempt)
                continue
            }
            $failure = $_
            break
        }
    }
    if ($failure) {
        $message = $failure.Exception.Message
        $cause = if (Test-MbcContainsAny -Text $message -Fragments $script:MbcPermissionWords) { 'permission missing' }
        elseif (Test-MbcContainsAny -Text $message -Fragments $script:MbcNotFoundWords) { 'not found' }
        else { 'cmdlet failed' }
        return (& $finish $cause "$($failure.Exception.GetType().Name): $message" $null 0)
    }
    $body = ConvertTo-MbcCmdletBody -Output @($output)
    return (& $finish $null $null $body $body['value'].Count)
}
