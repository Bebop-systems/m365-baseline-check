# OpenID Connect scopes that every delegated token carries. None of them can change anything in a tenant.
$script:MbcIdentityScopes = @('openid', 'profile', 'offline_access', 'email')

function Test-MbcReadScope {
    <#
    .SYNOPSIS
        True when a scope is recognisably a read: Resource.Read or Resource.ReadBasic, with qualifiers,
        and no write verb anywhere. A scope that is not recognisably a read is treated as a write.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Scope)
    if ($Scope -in $script:MbcIdentityScopes) { return $true }
    $parts = [string[]]($Scope -split '\.')
    if ($parts.Count -lt 2) { return $false }
    $readAt = [array]::FindIndex($parts, [Predicate[string]] { param($p) $p -ceq 'Read' -or $p -ceq 'ReadBasic' })
    if ($readAt -lt 1) { return $false }
    # Whole-segment match, not substring: a write verb occupies one full dot-separated part in every
    # real Graph scope. A substring test would misfire on a resource or qualifier that merely contains
    # one of these words, such as the qualifier 'ConditionalAccess' or the resource 'AdministrativeUnit'.
    $writeVerbs = @('write', 'send', 'manage', 'create', 'delete', 'update', 'invite', 'execute', 'admin', 'full', 'access')
    foreach ($p in $parts) {
        if ($p.ToLowerInvariant() -in $writeVerbs) { return $false }
    }
    return $true
}
