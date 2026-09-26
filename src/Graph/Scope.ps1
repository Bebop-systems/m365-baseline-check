# OpenID Connect scopes that every delegated token carries. None of them can change anything in a tenant.
$script:MbcIdentityScopes = @('openid', 'profile', 'offline_access', 'email')

function Test-MbcReadScope {
    <#
    .SYNOPSIS
        True when a scope has the strict shape of a read: a resource, then Read or ReadBasic in
        second position, then at most one qualifier segment, and nothing else. A write word is
        refused in the resource ('write' anywhere in it) and a broader set of write words is
        refused in the qualifier. Anything that does not match this shape is treated as a write:
        fail closed, never open.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Scope)
    if ($Scope -cin $script:MbcIdentityScopes) { return $true }
    if (-not ($Scope -cmatch '^(?<res>[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z][A-Za-z0-9]*)*)\.(?:Read|ReadBasic)(?:\.(?<qual>[A-Z][A-Za-z0-9]*))?$')) { return $false }
    if ($Matches['res'] -match '(?i)write') { return $false }
    if ($Matches['qual'] -and $Matches['qual'] -match '(?i)write|send|manage|create|delete|update|invite|execute|full|asuser|impersonat') { return $false }
    return $true
}
