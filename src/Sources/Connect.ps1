# Sign-in to the sources a preset uses, plus Graph for the app inventory, and disclosure of what was
# granted (spec 6.3). Nothing here refuses on privilege: safety comes from the clients, not the account.

$script:MbcInventoryScopes = @('Application.Read.All', 'Directory.Read.All')
$script:MbcProfileScopes = @('User.Read')
$script:MbcReadOnlyLine = 'Read-only by construction: GET-only Graph, Get- cmdlets only.'
$script:MbcSourceNames = [ordered]@{ graph = 'Graph'; exo = 'Exchange Online'; compliance = 'Security & Compliance' }
# Graph is imported first. Its dependencies load in their own context, so Exchange Online's later load
# of a different MSAL build sits beside it rather than over it. See CLAUDE.md, "Module load order".
$script:MbcModuleOrder = @('Microsoft.Graph.Authentication', 'ExchangeOnlineManagement')

function Test-MbcModuleAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Name)
    return [bool](Get-Module -ListAvailable -Name $Name)
}

function Import-MbcSourceModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name)
    if (-not (Get-Module -Name $Name)) { Import-Module -Name $Name -ErrorAction Stop -Verbose:$false }
}

function Invoke-MbcConnectMgGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Scopes)
    Connect-MgGraph -Scopes $Scopes -NoWelcome -ErrorAction Stop | Out-Null
}

function Get-MbcMgContext {
    [CmdletBinding()]
    param()
    return (Get-MgContext)
}

function Invoke-MbcConnectExchange {
    # -CommandName loads only the declared cmdlets into the session module: nothing else is there to run.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('exo', 'compliance')][string] $Source,
        [Parameter(Mandatory)][string] $UserPrincipalName,
        [Parameter(Mandatory)][string[]] $CommandName
    )
    if ($Source -eq 'exo') {
        Connect-ExchangeOnline -UserPrincipalName $UserPrincipalName -CommandName $CommandName -ShowBanner:$false -ShowProgress:$false -SkipLoadingCmdletHelp -ErrorAction Stop | Out-Null
    }
    else {
        Connect-IPPSSession -UserPrincipalName $UserPrincipalName -CommandName $CommandName -ShowBanner:$false -ErrorAction Stop | Out-Null
    }
}

function Get-MbcExchangeConnections {
    [CmdletBinding()]
    param()
    if (-not (Get-Command -Name Get-ConnectionInformation -ErrorAction SilentlyContinue)) { return , @() }
    return , @(Get-ConnectionInformation -ErrorAction SilentlyContinue)
}

function Invoke-MbcDisconnectAll {
    # Every session this tool opened. Failures to disconnect are logged, never fatal.
    [CmdletBinding()]
    param([AllowNull()] $Connection, [AllowNull()] $Log)
    if ($Connection -and $Connection.Sessions.Count -gt 0 -and (Get-Command -Name Disconnect-ExchangeOnline -ErrorAction SilentlyContinue)) {
        try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop | Out-Null }
        catch { Write-MbcLog -Log $Log -EventName 'signout' -Data @{ source = 'exo'; detail = $_.Exception.Message } }
    }
    if (Get-Command -Name Disconnect-MgGraph -ErrorAction SilentlyContinue) {
        try { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
        catch { Write-MbcLog -Log $Log -EventName 'signout' -Data @{ source = 'graph'; detail = $_.Exception.Message } }
    }
}

function Get-MbcSignInScopes {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Preset)
    $scopes = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @(@($Preset['scopes']) + $script:MbcInventoryScopes + $script:MbcProfileScopes)) {
        if ([string]::IsNullOrEmpty($s)) { continue }
        if (-not (Test-MbcReadScope -Scope $s)) { throw "This preset asks for $s, which isn't a read scope. The tool won't request it." }
        if (-not ($scopes | Where-Object { $_ -ieq $s })) { $scopes.Add($s) }
    }
    return , $scopes.ToArray()
}

function Get-MbcPresetSources {
    # The cmdlet sources the preset's checks use, in first-use order.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Preset)
    $sources = [System.Collections.Generic.List[string]]::new()
    foreach ($check in @($Preset['checks'])) {
        $source = Get-MbcCheckSource -Check $check
        if ($source -in $script:MbcCmdletSources -and -not $sources.Contains($source)) { $sources.Add($source) }
    }
    return , $sources.ToArray()
}

function Get-MbcSessionModuleName {
    # Get-ConnectionInformation's ModuleName "includes path information"; the module's name is its leaf.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $ModuleName)
    $leaf = $ModuleName.TrimEnd('/', '\')
    $cut = [Math]::Max($leaf.LastIndexOf('/'), $leaf.LastIndexOf('\'))
    if ($cut -ge 0) { $leaf = $leaf.Substring($cut + 1) }
    if ($leaf.EndsWith('.psm1', [StringComparison]::OrdinalIgnoreCase) -or $leaf.EndsWith('.psd1', [StringComparison]::OrdinalIgnoreCase)) {
        $leaf = $leaf.Substring(0, $leaf.Length - 5)
    }
    return $leaf
}

function Find-MbcExchangeSession {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Source, [AllowEmptyCollection()][object[]] $Connections = @())
    $wantCompliance = $Source -eq 'compliance'
    $match = $null
    foreach ($c in $Connections) {
        if ([string]$c.State -ne 'Connected' -or [string]::IsNullOrEmpty([string]$c.ModuleName)) { continue }
        $isCompliance = [bool]$c.IsEopSession -or ([string]$c.ConnectionUri).IndexOf('compliance', [StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($isCompliance -eq $wantCompliance) { $match = $c }
    }
    if ($null -eq $match) { return $null }
    return (Get-MbcSessionModuleName -ModuleName ([string]$match.ModuleName))
}

function Get-MbcDeclaredCmdlets {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Preset, [Parameter(Mandatory)][string] $Source)
    if (-not $Preset.Contains('cmdlets') -or -not (Test-MbcIsDictionary $Preset['cmdlets']) -or -not $Preset['cmdlets'].Contains($Source)) { return , @() }
    return , [string[]]@($Preset['cmdlets'][$Source] | Where-Object { Test-MbcCmdletName -Name ([string]$_) })
}

function Format-MbcDisclosure {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Connection)
    $lines = [System.Collections.Generic.List[string]]::new()
    $tenant = if ($Connection.TenantName) { "$($Connection.TenantName) ($($Connection.TenantId))" } else { [string]$Connection.TenantId }
    $lines.Add("Signed in as $($Connection.Account) to $tenant.")
    if ($null -eq $Connection.Roles) { $lines.Add("Directory roles: couldn't be read ($($Connection.RolesCause)).") }
    elseif (@($Connection.Roles).Count -eq 0) { $lines.Add('Directory roles: none.') }
    else { $lines.Add("Directory roles: $(@($Connection.Roles) -join ', ').") }
    $marked = @($Connection.Scopes | ForEach-Object { if ($_ -in $Connection.WriteScopes) { "$_ (write)" } else { $_ } })
    $lines.Add("Graph scopes granted: $($marked -join ', ').")
    $connected = @('Graph') + @($Connection.Sessions.Keys | ForEach-Object { $script:MbcSourceNames[$_] })
    $lines.Add("Sessions: $($connected -join ', ').")
    foreach ($source in $Connection.Failed.Keys) { $lines.Add("$($script:MbcSourceNames[$source]): not connected ($($Connection.Failed[$source])).") }
    $lines.Add($script:MbcReadOnlyLine)
    return , $lines.ToArray()
}

function Connect-MbcSources {
    <#
    .SYNOPSIS
        Signs in to Graph (always: the inventory needs it), then to each cmdlet source the preset uses,
        with the Graph account as the sign-in hint. A cmdlet source that fails is recorded, not fatal:
        its checks will say "not connected".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Preset,
        [AllowNull()] $Log,
        [scriptblock] $Transport
    )
    $scopes = Get-MbcSignInScopes -Preset $Preset
    if (-not (Test-MbcModuleAvailable -Name 'Microsoft.Graph.Authentication')) {
        throw "Microsoft.Graph.Authentication isn't installed. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser, then try again."
    }
    $sources = Get-MbcPresetSources -Preset $Preset
    Import-MbcSourceModule -Name $script:MbcModuleOrder[0]

    Invoke-MbcConnectMgGraph -Scopes $scopes
    $context = Get-MbcMgContext
    if ($null -eq $context) { throw 'Sign-in did not complete.' }
    $account = [string]$context.Account
    $granted = [string[]]@($context.Scopes)

    $roles = $null
    $rolesCause = $null
    $read = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName,roleTemplateId' -Transport $Transport -Log $Log
    if ($read.Ok) { $roles = @($read.Body['value'] | ForEach-Object { [string]$_['displayName'] } | Sort-Object) }
    else { $rolesCause = $read.Cause }

    $tenantName = ''
    $domain = ''
    $org = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/organization?$select=displayName,verifiedDomains' -Transport $Transport -Log $Log
    if ($org.Ok -and @($org.Body['value']).Count -gt 0) {
        $first = @($org.Body['value'])[0]
        $tenantName = [string]$first['displayName']
        foreach ($d in @($first['verifiedDomains'])) { if ((Test-MbcIsDictionary $d) -and $d['isDefault'] -eq $true) { $domain = [string]$d['name'] } }
    }
    if (-not $domain -and $account.IndexOf('@') -ge 0) { $domain = $account.Substring($account.IndexOf('@') + 1) }

    $sessions = [ordered]@{}
    $failed = [ordered]@{}
    if ($sources.Count -gt 0) {
        if (-not (Test-MbcModuleAvailable -Name 'ExchangeOnlineManagement')) {
            foreach ($s in $sources) { $failed[$s] = "ExchangeOnlineManagement 3.x isn't installed; Install-Module ExchangeOnlineManagement -Scope CurrentUser" }
        }
        else {
            Import-MbcSourceModule -Name $script:MbcModuleOrder[1]
            foreach ($s in $sources) {
                try {
                    Invoke-MbcConnectExchange -Source $s -UserPrincipalName $account -CommandName (Get-MbcDeclaredCmdlets -Preset $Preset -Source $s)
                    $module = Find-MbcExchangeSession -Source $s -Connections (Get-MbcExchangeConnections)
                    if ($module) { $sessions[$s] = $module } else { $failed[$s] = 'connected, but no session module was found' }
                }
                catch { $failed[$s] = $_.Exception.Message.Split([char]10)[0].Trim() }
            }
        }
    }

    $connection = [pscustomobject]@{
        PSTypeName  = 'Mbc.Connection'
        Account     = $account
        TenantId    = [string]$context.TenantId
        TenantName  = $tenantName
        Domain      = $domain
        Scopes      = $granted
        WriteScopes = [string[]]@($granted | Where-Object { -not (Test-MbcReadScope -Scope $_) })
        Roles       = $roles
        RolesCause  = $rolesCause
        Sessions    = $sessions
        Failed      = $failed
        Disclosure  = @()
    }
    $connection.Disclosure = Format-MbcDisclosure -Connection $connection
    Write-MbcLog -Log $Log -EventName 'signin' -Data ([ordered]@{
            account = $account; tenant = $connection.TenantId; tenantName = $tenantName; roles = $roles; rolesCause = $rolesCause
            scopes = $granted; writeScopes = $connection.WriteScopes; sessions = $sessions; failed = $failed; disclosure = $connection.Disclosure
        })
    return $connection
}
