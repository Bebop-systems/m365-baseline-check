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
    # Process scope: the token cache lives and dies with this PowerShell process; nothing is kept on disk.
    Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome -ErrorAction Stop | Out-Null
}

function Get-MbcMgContext {
    [CmdletBinding()]
    param()
    return (Get-MgContext)
}

function Invoke-MbcConnectExchange {
    # -CommandName loads only the declared cmdlets into the session module: nothing else is there to run.
    # -DisableWAM: Exchange Online's Windows broker sign-in fails in a plain console with a null parent
    # window (MSAL RuntimeBroker, NullReferenceException), where Graph's works. The browser sign-in doesn't.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('exo', 'compliance')][string] $Source,
        [Parameter(Mandatory)][string] $UserPrincipalName,
        [Parameter(Mandatory)][string[]] $CommandName
    )
    if ($Source -eq 'exo') {
        Connect-ExchangeOnline -UserPrincipalName $UserPrincipalName -CommandName $CommandName -ShowBanner:$false -ShowProgress:$false -DisableWAM -ErrorAction Stop | Out-Null
    }
    else {
        Connect-IPPSSession -UserPrincipalName $UserPrincipalName -CommandName $CommandName -ShowBanner:$false -DisableWAM -ErrorAction Stop | Out-Null
    }
}

function Get-MbcExchangeConnections {
    [CmdletBinding()]
    param()
    if (-not (Get-Command -Name Get-ConnectionInformation -ErrorAction SilentlyContinue)) { return , @() }
    return , @(Get-ConnectionInformation -ErrorAction SilentlyContinue)
}

function Invoke-MbcDisconnectAll {
    <#
    .SYNOPSIS
        Closes every Graph, Exchange Online and Security & Compliance session in this process, whoever
        opened it, and returns the names of what it closed. Graph is also signed out of the Windows
        broker. Never throws: a failure to close is logged and reported.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()] $Log)
    $closed = [System.Collections.Generic.List[string]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    if ((Get-Module -Name ExchangeOnlineManagement) -and (Get-Command -Name Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
        $open = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_ })
        if ($open.Count -gt 0) {
            try {
                Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop | Out-Null
                if (@($open | Where-Object { -not [bool]$_.IsEopSession }).Count) { $closed.Add('Exchange Online') }
                if (@($open | Where-Object { [bool]$_.IsEopSession }).Count) { $closed.Add('Security & Compliance') }
            }
            catch { $problems.Add("Exchange: $($_.Exception.Message)") }
        }
    }
    if ((Get-Module -Name Microsoft.Graph.Authentication) -and (Get-MgContext -ErrorAction SilentlyContinue)) {
        # The broker sign-out can trip over Exchange Online's copy of MSAL once that is loaded (Method not
        # found ... WithBroker). The disconnect still happens; the warning belongs in the log, not the console.
        $brokerWarnings = $null
        try { Disconnect-MgGraph -SignOutFromBroker -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable brokerWarnings | Out-Null }
        catch {
            try { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
            catch { $problems.Add("Graph: $($_.Exception.Message)") }
        }
        foreach ($w in @($brokerWarnings)) { if ($w) { $problems.Add("Graph broker: $w") } }
        if (-not (Get-MgContext -ErrorAction SilentlyContinue)) { $closed.Add('Graph') }
    }
    Write-MbcLog -Log $Log -EventName 'signout' -Data ([ordered]@{ closed = $closed.ToArray(); problems = $problems.ToArray() })
    return , $closed.ToArray()
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
    param([Parameter(Mandatory)][string] $Source, [AllowEmptyCollection()][object[]] $Connections = @(), [string] $TenantId = '')
    $wantCompliance = $Source -eq 'compliance'
    $match = $null
    foreach ($c in $Connections) {
        if ([string]$c.State -ne 'Connected' -or [string]::IsNullOrEmpty([string]$c.ModuleName)) { continue }
        # A session in another tenant would judge that tenant under this one's name.
        if ($TenantId -and $c.PSObject.Properties['TenantID'] -and [string]$c.TenantID -and [string]$c.TenantID -ine $TenantId) { continue }
        $isCompliance = [bool]$c.IsEopSession -or ([string]$c.ConnectionUri).IndexOf('compliance', [StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($isCompliance -eq $wantCompliance) { $match = $c }
    }
    if ($null -eq $match) { return $null }
    return (Get-MbcSessionModuleName -ModuleName ([string]$match.ModuleName))
}

function Get-MbcSignInPlan {
    # What the operator will be asked, in order, before anything is asked: one line per sign-in.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Preset)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Graph: the Windows account picker, or a browser.')
    foreach ($s in (Get-MbcPresetSources -Preset $Preset)) { $lines.Add("$($script:MbcSourceNames[$s]): a browser window.") }
    return , $lines.ToArray()
}

function Get-MbcDeclaredCmdlets {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Preset, [Parameter(Mandatory)][string] $Source)
    if (-not $Preset.Contains('cmdlets') -or -not (Test-MbcIsDictionary $Preset['cmdlets']) -or -not $Preset['cmdlets'].Contains($Source)) { return , @() }
    return , [string[]]@($Preset['cmdlets'][$Source] | Where-Object { Test-MbcCmdletName -Name ([string]$_) })
}

function Get-MbcSignInConsent {
    <#
    .SYNOPSIS
        The delegated permission grants the signing-in app holds in this tenant: for all users (admin
        consent), and the signed-in account's own. PowerShell signs in to Graph through Microsoft's
        "Microsoft Graph Command Line Tools" app, and consenting to scopes leaves these grants behind,
        so the operator is shown them, with their IDs, to remove once the work is done. All GET.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][string] $ClientAppId, [string[]] $Requested = @(), [scriptblock] $Transport, [AllowNull()] $Log)
    $result = [pscustomobject]@{ ClientAppId = $ClientAppId; ClientName = ''; ServicePrincipalId = ''; Grants = @(); Requested = [string[]]@($Requested); Cause = $null }
    if (-not $ClientAppId -or -not (Test-MbcCheckIdText $ClientAppId)) { $result.Cause = 'the signing-in app is unknown'; return $result }
    $graphTransport = $Transport
    $runLog = $Log
    $get = { param($request) Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request $request -Transport $graphTransport -Log $runLog }
    $sp = & $get "/servicePrincipals?`$filter=appId%20eq%20%27$ClientAppId%27&`$select=id,appId,displayName"
    if (-not $sp.Ok) { $result.Cause = $sp.Cause; return $result }
    $first = @($sp.Body['value']) | Select-Object -First 1
    if (-not (Test-MbcIsDictionary $first)) { $result.Cause = 'the app has no enterprise app in this tenant'; return $result }
    $result.ClientName = [string]$first['displayName']
    $result.ServicePrincipalId = [string]$first['id']
    $me = & $get '/me?$select=id'
    $meId = if ($me.Ok) { [string]$me.Body['id'] } else { '' }
    $grants = & $get "/oauth2PermissionGrants?`$filter=clientId%20eq%20%27$($result.ServicePrincipalId)%27"
    if (-not $grants.Ok) { $result.Cause = $grants.Cause; return $result }
    $result.Grants = @(foreach ($g in @($grants.Body['value'])) {
            if (-not (Test-MbcIsDictionary $g)) { continue }
            $admin = [string]$g['consentType'] -eq 'AllPrincipals'
            if (-not $admin -and [string]$g['principalId'] -ne $meId) { continue }
            $scopes = Get-MbcSortedUnique -Items (Split-MbcScopeText -Text ([string]$g['scope']))
            [pscustomobject]@{
                Id          = [string]$g['id']
                Type        = if ($admin) { 'admin' } else { 'user' }
                Scopes      = $scopes
                WriteScopes = [string[]]@($scopes | Where-Object { -not (Test-MbcReadScope -Scope $_) })
            }
        })
    return $result
}

function Format-MbcConsentAdvice {
    <#
    .SYNOPSIS
        Lines for a person: the consent the sign-in relied on, and how to remove it. Advice text only:
        this tool never changes a tenant, and the commands below are for the operator to run, if they
        decide to, once the work is done.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()] $Consent)
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $Consent -or -not $Consent.ClientAppId) { return , $lines.ToArray() }
    $name = if ($Consent.ClientName) { $Consent.ClientName } else { 'The signing-in app' }
    $lines.Add("Graph sign-in went through $name, app ID $($Consent.ClientAppId).")
    if ($Consent.Cause) { $lines.Add("Its consent here couldn't be read ($($Consent.Cause))."); return , $lines.ToArray() }
    if (@($Consent.Grants).Count -eq 0) { $lines.Add('It holds no delegated consent for all users or for this account here. Nothing to remove.'); return , $lines.ToArray() }
    $lines.Add("In this tenant: enterprise app (service principal) $($Consent.ServicePrincipalId).")
    foreach ($g in @($Consent.Grants)) {
        $who = if ($g.Type -eq 'admin') { 'Admin consent for all users' } else { 'This account''s own consent' }
        $writes = @($g.WriteScopes).Count
        $lines.Add("$who`: $(@($g.Scopes).Count) permissions$(if ($writes) { ", $writes of them write" }). Grant ID $($g.Id).")
    }
    $lines.Add('If it was granted for this work, remove it when you are done; other admins'' PowerShell may rely on it.')
    $lines.Add('In the portal: Entra admin center > Enterprise applications > ' + $name + ' > Permissions.')
    $lines.Add('In PowerShell, with Microsoft.Graph.Identity.SignIns and DelegatedPermissionGrant.ReadWrite.All:')
    # One grant per command, split with a backtick so it copies whole at any width.
    foreach ($g in @($Consent.Grants)) {
        $lines.Add('    Remove-MgOauth2PermissionGrant `')
        $lines.Add("        -OAuth2PermissionGrantId '$($g.Id)'")
    }
    $lines.Add('docs/removing-consent.md has the rest, including a version that needs no extra module.')
    return , $lines.ToArray()
}

function Test-MbcConnectionCovers {
    <#
    .SYNOPSIS
        Whether a sign-in can serve a preset: every scope it asks for was granted, and every cmdlet
        source it uses was at least attempted. Otherwise the caller signs in again rather than report
        checks as unverifiable that could have been checked.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Connection, [Parameter(Mandatory)][System.Collections.IDictionary] $Preset)
    $granted = @($Connection.Scopes)
    foreach ($s in (Get-MbcSignInScopes -Preset $Preset)) {
        if (-not ($granted | Where-Object { $_ -ieq $s })) { return $false }
    }
    foreach ($source in (Get-MbcPresetSources -Preset $Preset)) {
        if (-not $Connection.Sessions.Contains($source) -and -not $Connection.Failed.Contains($source)) { return $false }
    }
    return $true
}

function Format-MbcDisclosure {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Connection)
    $lines = [System.Collections.Generic.List[string]]::new()
    $tenant = if ($Connection.TenantName) { "$($Connection.TenantName) ($($Connection.TenantId))" } else { [string]$Connection.TenantId }
    $lines.Add("Signed in as $($Connection.Account) to $tenant.")
    if ($Connection.PSObject.Properties['ClosedFirst'] -and @($Connection.ClosedFirst).Count) { $lines.Add("Closed sessions already open before signing in: $(@($Connection.ClosedFirst) -join ', ').") }
    if ($null -eq $Connection.Roles) { $lines.Add("Directory roles: couldn't be read ($($Connection.RolesCause)).") }
    elseif (@($Connection.Roles).Count -eq 0) { $lines.Add('Directory roles: none.') }
    else { $lines.Add("Directory roles: $(@($Connection.Roles) -join ', ').") }
    $marked = @($Connection.Scopes | ForEach-Object { if ($_ -in $Connection.WriteScopes) { "$_ (write)" } else { $_ } })
    $lines.Add("Graph scopes granted: $($marked -join ', ').")
    $connected = @('Graph') + @($Connection.Sessions.Keys | ForEach-Object { $script:MbcSourceNames[$_] })
    $lines.Add("Sessions: $($connected -join ', ').")
    foreach ($source in $Connection.Failed.Keys) { $lines.Add("$($script:MbcSourceNames[$source]): not connected ($($Connection.Failed[$source])).") }
    if ($Connection.PSObject.Properties['Consent'] -and $Connection.Consent -and $Connection.Consent.ClientName) {
        $admin = @($Connection.Consent.Grants | Where-Object Type -eq 'admin')
        $lines.Add("Signed in through $($Connection.Consent.ClientName); consent it holds here: $(if ($admin.Count) { "$(@($admin[0].Scopes).Count) permissions for all users" } else { 'none for all users' }). Details on the sign-in screen and in the report.")
    }
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
    # Start clean: nothing left open by anyone is reused, and whatever this sign-in opens is all there is.
    $closedFirst = Invoke-MbcDisconnectAll -Log $Log
    try {
        return (Connect-MbcSourcesCore -Preset $Preset -Scopes $scopes -Sources $sources -ClosedFirst $closedFirst -Log $Log -Transport $Transport)
    }
    catch {
        # A sign-in that stops part-way leaves nothing behind.
        [void](Invoke-MbcDisconnectAll -Log $Log)
        throw
    }
}

function Connect-MbcSourcesCore {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Preset,
        [Parameter(Mandatory)][string[]] $Scopes,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Sources,
        [AllowEmptyCollection()][string[]] $ClosedFirst = @(),
        [AllowNull()] $Log,
        [scriptblock] $Transport
    )
    $sources = $Sources
    Invoke-MbcConnectMgGraph -Scopes $Scopes
    $context = Get-MbcMgContext
    if ($null -eq $context) { throw 'Sign-in did not complete.' }
    $account = [string]$context.Account
    $granted = [string[]]@($context.Scopes)

    $roles = $null
    $rolesCause = $null
    $read = Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request '/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName,roleTemplateId' -Transport $Transport -Log $Log
    if ($read.Ok) { $roles = @(@($read.Body['value']) | Where-Object { Test-MbcIsDictionary $_ } | ForEach-Object { [string]$_['displayName'] } | Sort-Object) }
    else { $rolesCause = $read.Cause }

    $clientId = if ($context.PSObject.Properties['ClientId']) { [string]$context.ClientId } else { '' }
    $consent = Get-MbcSignInConsent -ClientAppId $clientId -Requested $Scopes -Transport $Transport -Log $Log
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
                    $module = Find-MbcExchangeSession -Source $s -Connections (Get-MbcExchangeConnections) -TenantId ([string]$context.TenantId)
                    if ($module) { $sessions[$s] = $module } else { $failed[$s] = 'no session in the signed-in tenant; was another account chosen?' }
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
        Consent     = $consent
        Sessions    = $sessions
        Failed      = $failed
        Disclosure  = @()
        ClosedFirst = [string[]]@($ClosedFirst)
    }
    $connection.Disclosure = Format-MbcDisclosure -Connection $connection
    Write-MbcLog -Log $Log -EventName 'signin' -Data ([ordered]@{
            account = $account; tenant = $connection.TenantId; tenantName = $tenantName; roles = $roles; rolesCause = $rolesCause
            scopes = $granted; writeScopes = $connection.WriteScopes; sessions = $sessions; failed = $failed; disclosure = $connection.Disclosure
        })
    return $connection
}
