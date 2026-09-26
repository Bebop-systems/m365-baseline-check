$script:MbcSeverities = @('high', 'medium', 'low', 'info')
$script:MbcAreas = @('entra', 'exchange', 'intune', 'purview', 'defender', 'admin')
$script:MbcSources = @('graph', 'exo', 'compliance')
$script:MbcCmdletSources = @('exo', 'compliance')
$script:MbcCheckMembers = @(
    'id', 'title', 'area', 'location', 'source', 'request', 'parameters', 'select', 'operator', 'severity',
    'labels', 'why', 'caseSensitive', 'apiVersion'
)
$script:MbcPresetMembers = @('schemaVersion', 'name', 'description', 'scopes', 'endpoints', 'cmdlets', 'checks')
$script:MbcBaselineMembers = @('schemaVersion', 'name', 'version', 'description', 'preset', 'expected', 'seal')
$script:MbcSealMembers = @('algorithm', 'digest', 'sealedVersion')

function Get-MbcCheckApiVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check)
    if ($Check.Contains('apiVersion')) { return [string]$Check['apiVersion'] }
    return 'v1.0'
}

function Get-MbcCheckSource {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check)
    if ($Check.Contains('source')) { return [string]$Check['source'] }
    return 'graph'
}

function Get-MbcCheckParameters {
    # A check's cmdlet parameters as an ordered map; empty when it has none.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check)
    $map = [ordered]@{}
    if ($Check.Contains('parameters') -and (Test-MbcIsDictionary $Check['parameters'])) {
        foreach ($k in $Check['parameters'].Keys) { $map[[string]$k] = $Check['parameters'][$k] }
    }
    return $map
}

function Test-MbcCmdletName {
    <#
    .SYNOPSIS
        True for a plain Get- cmdlet name: 'Get-', then letters and digits only. No wildcards, module
        qualifiers, spaces or second verbs can pass.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string] $Name)
    if ([string]::IsNullOrEmpty($Name) -or -not $Name.StartsWith('Get-', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return (Test-MbcAllChars -Text $Name.Substring(4) -Letters -Digits)
}

function Test-MbcCmdletDeclared {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Source, [AllowNull()][object] $Cmdlets)
    if (-not (Test-MbcIsDictionary $Cmdlets) -or -not $Cmdlets.Contains($Source) -or -not (Test-MbcIsList $Cmdlets[$Source])) { return $false }
    foreach ($declared in $Cmdlets[$Source]) {
        if ($declared -is [string] -and [string]::Equals($declared, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-MbcRequestDeclared {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Request, [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Endpoints)
    $query = $Request.IndexOf('?')
    $path = if ($query -ge 0) { $Request.Substring(0, $query) } else { $Request }
    foreach ($endpoint in $Endpoints) {
        $e = $endpoint.TrimEnd('/')
        if ($path -ieq $e -or $path.StartsWith("$e/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-MbcGraphPathText {
    # A Graph path: starts with '/', no scheme, no whitespace, and no '..' once decoded.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Text)
    if ($Text -isnot [string] -or -not $Text.StartsWith('/') -or $Text.Contains('://') -or (Test-MbcHasWhiteSpace $Text)) { return $false }
    return (-not ([uri]::UnescapeDataString($Text)).Contains('..'))
}

function Test-MbcCheckIdText {
    # 1 to 64 letters, digits, dots, dashes or underscores, starting with a letter or digit.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Text)
    if ($Text -isnot [string] -or $Text.Length -lt 1 -or $Text.Length -gt 64) { return $false }
    return ((Test-MbcAsciiAlnum $Text[0]) -and (Test-MbcAllChars -Text $Text -Letters -Digits -Also '._-'))
}

function Test-MbcNonEmptyString {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Value)
    return ($Value -is [string] -and $Value.Trim().Length -gt 0)
}

function Add-MbcUnknownMemberProblem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Object,
        [Parameter(Mandatory)][string[]] $Allowed,
        [Parameter(Mandatory)][string] $Where,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Problems
    )
    foreach ($k in $Object.Keys) {
        if ($k -notin $Allowed) { $Problems.Add("${Where}: unknown member '$k'") }
    }
}

function Test-MbcCheckShape {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][object] $Check,
        [Parameter(Mandatory)][string] $Where,
        [AllowEmptyCollection()][string[]] $Endpoints = @(),
        [AllowNull()][object] $Cmdlets
    )
    $p = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-MbcIsDictionary $Check)) { $p.Add("${Where}: a check must be an object"); return , $p.ToArray() }
    Add-MbcUnknownMemberProblem -Object $Check -Allowed $script:MbcCheckMembers -Where $Where -Problems $p

    if (-not (Test-MbcCheckIdText $Check['id'])) {
        $p.Add("${Where}: id must be 1 to 64 letters, digits, dots, dashes or underscores")
    }
    if (-not ((Test-MbcNonEmptyString $Check['title']) -and $Check['title'].Length -le 200)) {
        $p.Add("${Where}: title must be text of 1 to 200 characters")
    }
    if ($Check['area'] -notin $script:MbcAreas) { $p.Add("${Where}: area must be one of $($script:MbcAreas -join ', ')") }
    if ($Check.Contains('location') -and -not ((Test-MbcNonEmptyString $Check['location']) -and $Check['location'].Length -le 200)) {
        $p.Add("${Where}: location must be text of 1 to 200 characters")
    }

    $source = 'graph'
    if ($Check.Contains('source')) {
        if ($Check['source'] -cin $script:MbcSources) { $source = $Check['source'] }
        else { $p.Add("${Where}: source must be graph, exo or compliance"); $source = $null }
    }

    $request = $Check['request']
    if ($source -eq 'graph') {
        # '%' itself is never refused: a request may legitimately carry an encoded literal, such as %20
        # or %27, inside a path segment. Traversal is refused, including encoded traversal (%2e%2e),
        # because the '..' test runs against the decoded path.
        if (-not (Test-MbcGraphPathText $request)) {
            $p.Add("${Where}: request must be a Graph path starting with '/', like /policies/authorizationPolicy")
        }
        elseif (-not (Test-MbcRequestDeclared -Request ([uri]::UnescapeDataString($request)) -Endpoints $Endpoints)) {
            $p.Add("${Where}: request '$request' is not under a declared endpoint")
        }
        if ($Check.Contains('parameters')) { $p.Add("${Where}: parameters are for cmdlet sources only") }
        if ($Check.Contains('apiVersion') -and $Check['apiVersion'] -cnotin 'v1.0', 'beta') { $p.Add("${Where}: apiVersion must be v1.0 or beta") }
    }
    elseif ($null -ne $source) {
        if (-not (Test-MbcCmdletName -Name ([string]$request))) {
            $p.Add("${Where}: request must be a Get- cmdlet name, like Get-OrganizationConfig")
        }
        elseif (-not (Test-MbcCmdletDeclared -Name $request -Source $source -Cmdlets $Cmdlets)) {
            $p.Add("${Where}: '$request' is not declared under cmdlets.$source")
        }
        if ($Check.Contains('apiVersion')) { $p.Add("${Where}: apiVersion is for Graph checks only") }
        if ($Check.Contains('parameters')) {
            $parameters = $Check['parameters']
            if (-not (Test-MbcIsDictionary $parameters)) { $p.Add("${Where}: parameters must be an object of name to value") }
            else {
                foreach ($name in $parameters.Keys) {
                    if (-not (Test-MbcAllChars -Text ([string]$name) -Letters -Digits)) { $p.Add("${Where}: parameter name '$name' must be letters and digits") }
                    $value = $parameters[$name]
                    if (-not ($value -is [string] -or $value -is [bool] -or (Test-MbcIsWholeNumber $value))) {
                        $p.Add("${Where}: parameter $name must be text, true or false, or a whole number")
                    }
                }
            }
        }
    }

    if (-not (Test-MbcNonEmptyString $Check['select'])) { $p.Add("${Where}: select must be text") }
    else {
        try { [void](ConvertTo-MbcPathQuery -Select $Check['select']) }
        catch { $p.Add("${Where}: $($_.Exception.Message)") }
    }

    if ($Check['operator'] -notin $script:MbcOperators) {
        $p.Add("${Where}: operator must be one of $($script:MbcOperators -join ', ')")
    }
    if ($Check['severity'] -notin $script:MbcSeverities) {
        $p.Add("${Where}: severity must be one of $($script:MbcSeverities -join ', ')")
    }
    if ($Check.Contains('labels')) {
        $labels = $Check['labels']
        $ok = Test-MbcIsDictionary $labels
        if ($ok) { foreach ($k in $labels.Keys) { if (-not (Test-MbcNonEmptyString $labels[$k])) { $ok = $false } } }
        if (-not $ok) { $p.Add("${Where}: labels must map value text to display text, like { `"true`": `"On`" }") }
    }
    if ($Check.Contains('why') -and -not ($Check['why'] -is [string])) { $p.Add("${Where}: why must be text") }
    if ($Check.Contains('caseSensitive') -and -not ($Check['caseSensitive'] -is [bool])) { $p.Add("${Where}: caseSensitive must be true or false") }
    return , $p.ToArray()
}

function Test-MbcEndpointText {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Text)
    if ($Text -isnot [string] -or $Text.Length -lt 2 -or $Text[0] -cne '/' -or $Text[1] -ceq '/') { return $false }
    if ($Text.Contains('?') -or (Test-MbcHasWhiteSpace $Text)) { return $false }
    return (-not ([uri]::UnescapeDataString($Text)).Contains('..'))
}

function Test-MbcPresetShape {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object] $Preset, [string] $Where = 'preset')
    $p = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-MbcIsDictionary $Preset)) { $p.Add("${Where}: must be an object"); return , $p.ToArray() }
    Add-MbcUnknownMemberProblem -Object $Preset -Allowed $script:MbcPresetMembers -Where $Where -Problems $p

    if (-not ((Test-MbcIsWholeNumber $Preset['schemaVersion']) -and $Preset['schemaVersion'] -eq 1)) { $p.Add("${Where}: schemaVersion must be 1") }
    if (-not (Test-MbcNonEmptyString $Preset['name'])) { $p.Add("${Where}: name must be text") }
    if ($Preset.Contains('description') -and -not ($Preset['description'] -is [string])) { $p.Add("${Where}: description must be text") }

    $scopes = $Preset['scopes']
    if (-not (Test-MbcIsList $scopes)) { $p.Add("${Where}: scopes must be a list, which may be empty") }
    else {
        foreach ($s in $scopes) {
            if (-not (Test-MbcNonEmptyString $s)) { $p.Add("${Where}: every scope must be text") }
            elseif (-not (Test-MbcReadScope -Scope $s)) { $p.Add("${Where}: '$s' is not a read scope, and this tool only reads") }
        }
    }

    $endpoints = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-MbcIsList $Preset['endpoints'])) { $p.Add("${Where}: endpoints must be a list, which may be empty") }
    else {
        foreach ($e in $Preset['endpoints']) {
            if (Test-MbcEndpointText $e) { $endpoints.Add($e) }
            else { $p.Add("${Where}: endpoint '$e' must be a Graph path starting with '/', with no query string") }
        }
    }

    $cmdlets = $null
    if ($Preset.Contains('cmdlets')) {
        $cmdlets = $Preset['cmdlets']
        if (-not (Test-MbcIsDictionary $cmdlets)) { $p.Add("${Where}: cmdlets must be an object keyed by source (exo, compliance)") }
        else {
            foreach ($source in $cmdlets.Keys) {
                if ($source -cnotin $script:MbcCmdletSources) { $p.Add("cmdlets: unknown source '$source'; use exo or compliance"); continue }
                if (-not (Test-MbcIsList $cmdlets[$source])) { $p.Add("cmdlets.${source}: must be a list of cmdlet names"); continue }
                foreach ($name in $cmdlets[$source]) {
                    if (-not (Test-MbcCmdletName -Name ([string]$name))) { $p.Add("cmdlets.${source}: '$name' must be a Get- cmdlet") }
                }
            }
        }
    }

    $checks = $Preset['checks']
    if (-not ((Test-MbcIsList $checks) -and $checks.Count -gt 0)) { $p.Add("${Where}: checks must be a non-empty list") }
    else {
        $seen = @{}
        for ($i = 0; $i -lt $checks.Count; $i++) {
            $hasId = (Test-MbcIsDictionary $checks[$i]) -and $checks[$i]['id'] -is [string]
            $label = if ($hasId) { "check $($checks[$i]['id'])" } else { "check #$($i + 1)" }
            foreach ($problem in (Test-MbcCheckShape -Check $checks[$i] -Where $label -Endpoints $endpoints.ToArray() -Cmdlets $cmdlets)) { $p.Add($problem) }
            if ($hasId) {
                $key = $checks[$i]['id'].ToLowerInvariant()
                if ($seen.ContainsKey($key)) { $p.Add("check $($checks[$i]['id']): this id is used more than once") }
                $seen[$key] = $true
            }
        }
    }
    return , $p.ToArray()
}

function Get-MbcExpectedMisfit {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Operator, [AllowNull()][object] $Value)
    if ($Operator -in 'in', 'setEquals', 'subsetOf') {
        if (-not (Test-MbcIsList $Value)) { return 'expects a list' }
    }
    elseif ($Operator -in 'countAtLeast', 'countAtMost') {
        if (-not ((Test-MbcIsWholeNumber $Value) -and $Value -ge 0)) { return 'expects a whole number of zero or more' }
    }
    elseif ($Operator -eq 'contains') {
        if (-not (Test-MbcIsScalar $Value)) { return 'expects a single value' }
    }
    elseif ($Operator -eq 'matches') {
        if ($Value -isnot [string]) { return 'expects a regular expression as text' }
        # The operator itself is the one place a pattern is compiled, so ask it.
        if ((Compare-MbcValue -Actual '' -Operator 'matches' -Expected $Value).Cause -eq 'invalid pattern') { return 'has an invalid regular expression' }
    }
    return $null
}

function Test-MbcBaselineShape {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object] $Baseline)
    $p = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-MbcIsDictionary $Baseline)) { $p.Add('baseline: must be an object'); return , $p.ToArray() }
    Add-MbcUnknownMemberProblem -Object $Baseline -Allowed $script:MbcBaselineMembers -Where 'baseline' -Problems $p

    if (-not ((Test-MbcIsWholeNumber $Baseline['schemaVersion']) -and $Baseline['schemaVersion'] -eq 1)) { $p.Add('baseline: schemaVersion must be 1') }
    if (-not (Test-MbcNonEmptyString $Baseline['name'])) { $p.Add('baseline: name must be text') }
    if (-not ((Test-MbcIsWholeNumber $Baseline['version']) -and $Baseline['version'] -ge 1)) { $p.Add('baseline: version must be a whole number of 1 or more') }
    if ($Baseline.Contains('description') -and -not ($Baseline['description'] -is [string])) { $p.Add('baseline: description must be text') }

    foreach ($problem in (Test-MbcPresetShape -Preset $Baseline['preset'] -Where 'preset')) { $p.Add($problem) }

    $expected = $Baseline['expected']
    $preset = $Baseline['preset']
    if (-not (Test-MbcIsDictionary $expected)) { $p.Add('baseline: expected must be an object of check id to value') }
    elseif ((Test-MbcIsDictionary $preset) -and (Test-MbcIsList $preset['checks'])) {
        $checksById = @{}
        foreach ($c in $preset['checks']) { if ((Test-MbcIsDictionary $c) -and $c['id'] -is [string]) { $checksById[$c['id']] = $c } }
        foreach ($k in $expected.Keys) { if (-not $checksById.ContainsKey($k)) { $p.Add("expected ${k}: there is no such check in the preset") } }
        foreach ($id in $checksById.Keys) {
            $check = $checksById[$id]
            if ($check['operator'] -in 'exists', 'absent') {
                if ($expected.Contains($id)) { $p.Add("check ${id}: $($check['operator']) takes no expected value") }
                continue
            }
            if (-not $expected.Contains($id)) { $p.Add("check ${id}: has no expected value"); continue }
            # A missing or invalid operator is already reported by Test-MbcPresetShape above. Casting it
            # to [string] for Get-MbcExpectedMisfit would pass an empty string to a mandatory [string]
            # parameter, which PowerShell refuses to bind, so skip rather than let that throw.
            if ($check['operator'] -notin $script:MbcOperators) { continue }
            $misfit = Get-MbcExpectedMisfit -Operator ([string]$check['operator']) -Value $expected[$id]
            if ($misfit) { $p.Add("check ${id}: $($check['operator']) $misfit") }
        }
    }

    if ($Baseline.Contains('seal')) {
        $seal = $Baseline['seal']
        if (-not (Test-MbcIsDictionary $seal)) { $p.Add('seal: must be an object') }
        else {
            Add-MbcUnknownMemberProblem -Object $seal -Allowed $script:MbcSealMembers -Where 'seal' -Problems $p
            if ($seal['algorithm'] -cne 'SHA-256') { $p.Add('seal: algorithm must be SHA-256') }
            if (-not (Test-MbcLowerHex -Text $seal['digest'] -MinLength 64 -MaxLength 64)) { $p.Add('seal: digest must be 64 lowercase hex characters') }
            if (-not ((Test-MbcIsWholeNumber $seal['sealedVersion']) -and $seal['sealedVersion'] -ge 1)) { $p.Add('seal: sealedVersion must be a whole number of 1 or more') }
        }
    }
    return , $p.ToArray()
}
