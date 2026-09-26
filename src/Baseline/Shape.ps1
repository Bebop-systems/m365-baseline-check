$script:MbcSeverities = @('high', 'medium', 'low', 'info')
$script:MbcCheckMembers = @('id', 'title', 'request', 'select', 'extractor', 'operator', 'severity', 'why', 'caseSensitive', 'apiVersion')
$script:MbcPresetMembers = @('schemaVersion', 'name', 'description', 'scopes', 'endpoints', 'checks')
$script:MbcBaselineMembers = @('schemaVersion', 'name', 'version', 'description', 'preset', 'expected', 'seal')
$script:MbcSealMembers = @('algorithm', 'digest', 'sealedVersion')

function Get-MbcCheckApiVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Check)
    if ($Check.Contains('apiVersion')) { return [string]$Check['apiVersion'] }
    return 'v1.0'
}

function Test-MbcRequestDeclared {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Request, [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Endpoints)
    $path = ($Request -split '\?', 2)[0]
    foreach ($endpoint in $Endpoints) {
        $e = $endpoint.TrimEnd('/')
        if ($path -ieq $e -or $path.StartsWith("$e/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
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
    param([AllowNull()][object] $Check, [Parameter(Mandatory)][string] $Where, [AllowEmptyCollection()][string[]] $Endpoints = @())
    $p = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-MbcIsDictionary $Check)) { $p.Add("${Where}: a check must be an object"); return , $p.ToArray() }
    Add-MbcUnknownMemberProblem -Object $Check -Allowed $script:MbcCheckMembers -Where $Where -Problems $p

    $id = $Check['id']
    if (-not ($id -is [string] -and $id -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')) {
        $p.Add("${Where}: id must be 1 to 64 letters, digits, dots, dashes or underscores")
    }
    if (-not ((Test-MbcNonEmptyString $Check['title']) -and $Check['title'].Length -le 200)) {
        $p.Add("${Where}: title must be text of 1 to 200 characters")
    }
    $request = $Check['request']
    # '%' itself is never refused here: a request may legitimately carry an encoded literal, such as
    # %20 or %27, inside a path segment. What must be refused is traversal, including encoded traversal
    # (%2e%2e), so the '..' test runs against the decoded path rather than the raw one.
    if (-not ($request -is [string] -and $request -match '^/' -and $request -notmatch '://|\s')) {
        $p.Add("${Where}: request must be a Graph path starting with '/', like /policies/authorizationPolicy")
    }
    else {
        $decodedRequest = [uri]::UnescapeDataString($request)
        if ($decodedRequest -match '\.\.') {
            $p.Add("${Where}: request must be a Graph path starting with '/', like /policies/authorizationPolicy")
        }
        elseif ($Endpoints.Count -gt 0 -and -not (Test-MbcRequestDeclared -Request $decodedRequest -Endpoints $Endpoints)) {
            $p.Add("${Where}: request '$request' is not under a declared endpoint")
        }
    }

    $hasSelect = $Check.Contains('select')
    $hasExtractor = $Check.Contains('extractor')
    if ($hasSelect -eq $hasExtractor) {
        $p.Add("${Where}: give exactly one of select or extractor")
    }
    elseif ($hasSelect) {
        if (-not (Test-MbcNonEmptyString $Check['select'])) { $p.Add("${Where}: select must be text") }
        else {
            try { [void](ConvertTo-MbcPathQuery -Select $Check['select']) }
            catch { $p.Add("${Where}: $($_.Exception.Message)") }
        }
    }
    elseif (-not ($Check['extractor'] -is [string] -and $Check['extractor'] -match '^extractors/[A-Za-z0-9._-]+\.ps1$')) {
        $p.Add("${Where}: extractor must name a file like extractors/AUTH-009.ps1")
    }

    if ($Check['operator'] -notin $script:MbcOperators) {
        $p.Add("${Where}: operator must be one of $($script:MbcOperators -join ', ')")
    }
    if ($Check['severity'] -notin $script:MbcSeverities) {
        $p.Add("${Where}: severity must be one of $($script:MbcSeverities -join ', ')")
    }
    if ($Check.Contains('why') -and -not ($Check['why'] -is [string])) { $p.Add("${Where}: why must be text") }
    if ($Check.Contains('caseSensitive') -and -not ($Check['caseSensitive'] -is [bool])) { $p.Add("${Where}: caseSensitive must be true or false") }
    if ($Check.Contains('apiVersion') -and $Check['apiVersion'] -notin 'v1.0', 'beta') { $p.Add("${Where}: apiVersion must be v1.0 or beta") }
    return , $p.ToArray()
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
    if (-not ((Test-MbcIsList $scopes) -and $scopes.Count -gt 0)) { $p.Add("${Where}: scopes must be a non-empty list") }
    else {
        foreach ($s in $scopes) {
            if (-not (Test-MbcNonEmptyString $s)) { $p.Add("${Where}: every scope must be text") }
            elseif (-not (Test-MbcReadScope -Scope $s)) { $p.Add("${Where}: '$s' is not a read scope, and this tool only reads") }
        }
    }

    $endpoints = [System.Collections.Generic.List[string]]::new()
    if (-not ((Test-MbcIsList $Preset['endpoints']) -and $Preset['endpoints'].Count -gt 0)) { $p.Add("${Where}: endpoints must be a non-empty list") }
    else {
        foreach ($e in $Preset['endpoints']) {
            if ($e -is [string] -and $e -match '^/[^\s?/][^\s?]*$' -and $e -notmatch '\.\.') { $endpoints.Add($e) }
            else { $p.Add("${Where}: endpoint '$e' must be a Graph path starting with '/', with no query string") }
        }
    }

    $checks = $Preset['checks']
    if (-not ((Test-MbcIsList $checks) -and $checks.Count -gt 0)) { $p.Add("${Where}: checks must be a non-empty list") }
    else {
        $seen = @{}
        for ($i = 0; $i -lt $checks.Count; $i++) {
            $hasId = (Test-MbcIsDictionary $checks[$i]) -and $checks[$i]['id'] -is [string]
            $label = if ($hasId) { "check $($checks[$i]['id'])" } else { "check #$($i + 1)" }
            foreach ($problem in (Test-MbcCheckShape -Check $checks[$i] -Where $label -Endpoints $endpoints.ToArray())) { $p.Add($problem) }
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
        try { [void][regex]::new($Value) } catch { return 'has an invalid regular expression' }
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
            # parameter, which PowerShell refuses to bind — so skip rather than let that throw.
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
            if (-not ($seal['digest'] -is [string] -and $seal['digest'] -cmatch '^[0-9a-f]{64}$')) { $p.Add('seal: digest must be 64 lowercase hex characters') }
            if (-not ((Test-MbcIsWholeNumber $seal['sealedVersion']) -and $seal['sealedVersion'] -ge 1)) { $p.Add('seal: sealedVersion must be a whole number of 1 or more') }
        }
    }
    return , $p.ToArray()
}
