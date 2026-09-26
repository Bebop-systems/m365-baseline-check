# The app inventory (spec 8): facts, not checks. Collection is I/O through a Get block; shaping is pure.

# Microsoft's first-party application tenants, documented by Microsoft: Microsoft Services, and Microsoft.
$script:MbcMicrosoftTenants = @('f8cdef31-a31e-4b4a-93e4-5f571e91255a', '72f988bf-86f1-41af-91ab-2d7cd011db47')
$script:MbcInventoryRequests = [ordered]@{
    ServicePrincipals = '/servicePrincipals?$select=id,appId,displayName,appOwnerOrganizationId,publisherName,verifiedPublisher,servicePrincipalType,accountEnabled,tags,appRoleAssignmentRequired&$top=999'
    Applications      = '/applications?$select=id,appId,displayName,signInAudience,createdDateTime,publisherDomain,verifiedPublisher&$top=999'
    Grants            = '/oauth2PermissionGrants?$top=999'
}

function Get-MbcInventoryKind {
    # 'first-party', 'own', 'third-party' or 'other' for one service principal.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $ServicePrincipal, [Parameter(Mandatory)][string] $TenantId)
    $type = [string]$ServicePrincipal['servicePrincipalType']
    $owner = [string]$ServicePrincipal['appOwnerOrganizationId']
    if ($type -and $type -ne 'Application') { return 'other' }
    if ([string]::IsNullOrEmpty($owner)) { return 'other' }
    if ($owner -in $script:MbcMicrosoftTenants) { return 'first-party' }
    if ($owner -ieq $TenantId) { return 'own' }
    return 'third-party'
}

function Get-MbcAppInventoryData {
    <#
    .SYNOPSIS
        Reads what the inventory needs, all GET, through -Get: param($Request) -> fetch result. A failed
        read is recorded as a failure with its cause, and the rest carries on.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][scriptblock] $Get,
        [Parameter(Mandatory)][string] $TenantId,
        [scriptblock] $OnProgress
    )
    $failures = [System.Collections.Generic.List[string]]::new()
    $progress = $OnProgress
    $step = { param($label) if ($progress) { & $progress ([pscustomobject]@{ Phase = 'inventory'; Label = $label }) } }
    $read = {
        param($request, $what)
        & $step $what
        $r = & $Get $request
        if ($r.Ok) { return , @($r.Body['value']) }
        $failures.Add("Couldn't read ${what}: $($r.Cause)")
        return $null
    }

    $sps = & $read $script:MbcInventoryRequests.ServicePrincipals 'enterprise apps'
    $apps = & $read $script:MbcInventoryRequests.Applications 'app registrations'
    $grants = & $read $script:MbcInventoryRequests.Grants 'consents'

    # Application permissions, for listed apps only.
    $assignments = @{}
    $assignmentFailed = $false
    foreach ($sp in @($sps)) {
        if ($null -eq $sp) { continue }
        $kind = Get-MbcInventoryKind -ServicePrincipal $sp -TenantId $TenantId
        if ($kind -notin 'third-party', 'own') { continue }
        & $step "permissions of $($sp['displayName'])"
        $r = & $Get "/servicePrincipals/$($sp['id'])/appRoleAssignments"
        if ($r.Ok) { $assignments[[string]$sp['id']] = @($r.Body['value']) }
        elseif (-not $assignmentFailed) { $assignmentFailed = $true; $failures.Add("Couldn't read application permissions: $($r.Cause)") }
    }

    # Each resource once, to turn permission IDs into names.
    $listedIds = @{}
    foreach ($sp in @($sps)) {
        if ($null -ne $sp -and (Get-MbcInventoryKind -ServicePrincipal $sp -TenantId $TenantId) -in 'third-party', 'own') { $listedIds[[string]$sp['id']] = $true }
    }
    $resourceIds = [System.Collections.Generic.List[string]]::new()
    foreach ($g in @($grants)) {
        if ($null -ne $g -and $listedIds.ContainsKey([string]$g['clientId']) -and -not $resourceIds.Contains([string]$g['resourceId'])) { $resourceIds.Add([string]$g['resourceId']) }
    }
    foreach ($list in $assignments.Values) {
        foreach ($a in $list) { if (-not $resourceIds.Contains([string]$a['resourceId'])) { $resourceIds.Add([string]$a['resourceId']) } }
    }
    $resources = @{}
    $resourceFailed = $false
    foreach ($id in $resourceIds) {
        & $step 'permission names'
        $r = & $Get "/servicePrincipals/${id}?`$select=id,displayName,appRoles,oauth2PermissionScopes"
        if ($r.Ok) { $resources[$id] = $r.Body }
        elseif (-not $resourceFailed) { $resourceFailed = $true; $failures.Add("Couldn't read permission names: $($r.Cause)") }
    }

    return [pscustomobject]@{
        PSTypeName        = 'Mbc.InventoryData'
        ServicePrincipals = $sps
        Applications      = $apps
        Grants            = $grants
        Assignments       = $assignments
        Resources         = $resources
        Failures          = $failures.ToArray()
    }
}

function Split-MbcScopeText {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyString()][string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return , @() }
    return , [string[]]@($Text.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries))
}

function Get-MbcSortedUnique {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]] $Items = @())
    $set = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $Items) { if ($i) { [void]$set.Add($i) } }
    return , [string[]]@($set)
}

function Get-MbcResourceName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $Resources, [AllowEmptyString()][string] $Id, [AllowEmptyString()][string] $Fallback = '')
    if ($Resources.ContainsKey($Id) -and $Resources[$Id]['displayName']) { return [string]$Resources[$Id]['displayName'] }
    if ($Fallback) { return $Fallback }
    return 'unresolved resource'
}

function New-MbcInventoryApp {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Kind,
        [AllowNull()][System.Collections.IDictionary] $ServicePrincipal,
        [AllowNull()][System.Collections.IDictionary] $Application,
        [Parameter(Mandatory)] $Data
    )
    $source = if ($ServicePrincipal) { $ServicePrincipal } else { $Application }
    $verified = $source['verifiedPublisher']
    $isVerified = (Test-MbcIsDictionary $verified) -and -not [string]::IsNullOrEmpty([string]$verified['verifiedPublisherId'])
    $publisher = if ($isVerified -and $verified['displayName']) { [string]$verified['displayName'] }
    elseif ($ServicePrincipal -and $ServicePrincipal['publisherName']) { [string]$ServicePrincipal['publisherName'] }
    elseif ($Application -and $Application['publisherDomain']) { [string]$Application['publisherDomain'] }
    else { '' }

    $delegatedList = [System.Collections.Generic.List[object]]::new()
    $appPermList = [System.Collections.Generic.List[object]]::new()
    if ($ServicePrincipal) {
        $spId = [string]$ServicePrincipal['id']
        $groups = [ordered]@{}
        foreach ($g in @($Data.Grants)) {
            if ($null -eq $g -or [string]$g['clientId'] -ne $spId) { continue }
            $type = if ([string]$g['consentType'] -eq 'AllPrincipals') { 'admin' } else { 'user' }
            $key = "$type|$($g['resourceId'])"
            if (-not $groups.Contains($key)) { $groups[$key] = @{ Type = $type; ResourceId = [string]$g['resourceId']; Scopes = [System.Collections.Generic.List[string]]::new(); Users = @{} } }
            foreach ($s in (Split-MbcScopeText -Text ([string]$g['scope']))) { $groups[$key].Scopes.Add($s) }
            if ($type -eq 'user' -and $g['principalId']) { $groups[$key].Users[[string]$g['principalId']] = $true }
        }
        foreach ($grp in $groups.Values) {
            $delegatedList.Add([pscustomobject]@{
                    Type     = $grp.Type
                    Resource = Get-MbcResourceName -Resources $Data.Resources -Id $grp.ResourceId
                    Scopes   = Get-MbcSortedUnique -Items $grp.Scopes.ToArray()
                    Users    = if ($grp.Type -eq 'user') { $grp.Users.Count } else { 0 }
                })
        }
        $byResource = [ordered]@{}
        $assigned = if ($Data.Assignments.ContainsKey($spId)) { $Data.Assignments[$spId] } else { @() }
        foreach ($a in $assigned) {
            $rid = [string]$a['resourceId']
            if (-not $byResource.Contains($rid)) { $byResource[$rid] = @{ Fallback = [string]$a['resourceDisplayName']; Roles = [System.Collections.Generic.List[string]]::new() } }
            $name = 'unresolved permission'
            if ($Data.Resources.ContainsKey($rid)) {
                foreach ($role in @($Data.Resources[$rid]['appRoles'])) { if ((Test-MbcIsDictionary $role) -and [string]$role['id'] -eq [string]$a['appRoleId']) { $name = [string]$role['value'] } }
            }
            $byResource[$rid].Roles.Add($name)
        }
        foreach ($rid in $byResource.Keys) {
            $appPermList.Add([pscustomobject]@{
                    Resource = Get-MbcResourceName -Resources $Data.Resources -Id $rid -Fallback $byResource[$rid].Fallback
                    Roles    = Get-MbcSortedUnique -Items $byResource[$rid].Roles.ToArray()
                })
        }
    }

    return [pscustomobject]@{
        PSTypeName         = 'Mbc.InventoryApp'
        Kind               = $Kind
        DisplayName        = [string]$source['displayName']
        Publisher          = $publisher
        Verified           = $isVerified
        AppId              = [string]$source['appId']
        Enabled            = if ($ServicePrincipal) { [bool]$ServicePrincipal['accountEnabled'] } else { $null }
        AssignmentRequired = if ($ServicePrincipal) { [bool]$ServicePrincipal['appRoleAssignmentRequired'] } else { $null }
        Delegated          = $delegatedList.ToArray()
        Application        = $appPermList.ToArray()
    }
}

function ConvertTo-MbcAppInventory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Data, [Parameter(Mandatory)][string] $TenantId)
    $third = [System.Collections.Generic.List[object]]::new()
    $own = [System.Collections.Generic.List[object]]::new()
    $firstParty = 0
    $other = 0
    $ownSps = @{}
    foreach ($sp in @($Data.ServicePrincipals)) {
        if ($null -eq $sp) { continue }
        switch (Get-MbcInventoryKind -ServicePrincipal $sp -TenantId $TenantId) {
            'first-party' { $firstParty++ }
            'other' { $other++ }
            'own' { $ownSps[[string]$sp['appId']] = $sp }
            'third-party' { $third.Add((New-MbcInventoryApp -Kind 'third-party' -ServicePrincipal $sp -Application $null -Data $Data)) }
        }
    }
    foreach ($app in @($Data.Applications)) {
        if ($null -eq $app) { continue }
        $sp = if ($ownSps.ContainsKey([string]$app['appId'])) { $ownSps[[string]$app['appId']] } else { $null }
        $own.Add((New-MbcInventoryApp -Kind 'own' -ServicePrincipal $sp -Application $app -Data $Data))
    }
    return [pscustomobject]@{
        PSTypeName      = 'Mbc.Inventory'
        Collected       = $true
        ThirdParty      = @($third | Sort-Object DisplayName)
        Own             = @($own | Sort-Object DisplayName)
        FirstPartyCount = $firstParty
        OtherCount      = $other
        Failures        = @($Data.Failures)
    }
}

function New-MbcSkippedInventory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return [pscustomobject]@{ PSTypeName = 'Mbc.Inventory'; Collected = $false; ThirdParty = @(); Own = @(); FirstPartyCount = 0; OtherCount = 0; Failures = @() }
}
