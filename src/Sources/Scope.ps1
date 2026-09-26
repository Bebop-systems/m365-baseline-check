# OpenID Connect scopes that every delegated token carries. None of them can change anything in a tenant.
$script:MbcIdentityScopes = @('openid', 'profile', 'offline_access', 'email')
$script:MbcQualifierWriteWords = @('write', 'send', 'manage', 'create', 'delete', 'update', 'invite', 'execute', 'full', 'asuser', 'impersonat')

function Test-MbcScopeResource {
    # Letters and digits, starting with a letter, in dash-separated parts: AuditLogsQuery-Exchange.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    if ($Text.Length -eq 0) { return $false }
    foreach ($part in $Text.Split('-')) {
        if ($part.Length -eq 0 -or -not (Test-MbcAsciiLetter $part[0])) { return $false }
        if (-not (Test-MbcAllChars -Text $part -Letters -Digits)) { return $false }
    }
    return $true
}

function Test-MbcReadScope {
    <#
    .SYNOPSIS
        True when a scope has the strict shape of a read: a resource, then Read or ReadBasic in
        second position, then at most one qualifier segment, and nothing else. A write word is
        refused in the resource ('write' anywhere in it) and a broader set of write words is
        refused in the qualifier. Anything that does not have this shape is treated as a write:
        fail closed, never open.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Scope)
    if ($Scope -cin $script:MbcIdentityScopes) { return $true }
    $segments = $Scope.Split('.')
    if ($segments.Count -lt 2 -or $segments.Count -gt 3) { return $false }
    if (-not (Test-MbcScopeResource -Text $segments[0])) { return $false }
    if ($segments[1] -cne 'Read' -and $segments[1] -cne 'ReadBasic') { return $false }
    if ($segments[0].IndexOf('write', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
    if ($segments.Count -eq 3) {
        $qualifier = $segments[2]
        if ($qualifier.Length -eq 0 -or -not (Test-MbcAsciiUpper $qualifier[0])) { return $false }
        if (-not (Test-MbcAllChars -Text $qualifier -Letters -Digits)) { return $false }
        if (Test-MbcContainsAny -Text $qualifier -Fragments $script:MbcQualifierWriteWords) { return $false }
    }
    return $true
}
