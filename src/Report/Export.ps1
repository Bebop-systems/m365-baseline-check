# The CSV parts of an export, and the export itself (Export-MbcRunFiles, with locking, is further down).

function Format-MbcCellValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if (Test-MbcIsNumber $Value) { return (ConvertTo-MbcCanonicalJson -Value $Value) }
    $text = if ($Value -is [string]) { $Value } else { ConvertTo-MbcCanonicalJson -Value $Value }
    # A spreadsheet runs a cell that starts with one of these as a formula. A leading quote stops it.
    if ($text.Length -gt 0 -and '=+-@'.IndexOf($text[0]) -ge 0 -or ($text.Length -gt 0 -and ($text[0] -eq "`t" -or $text[0] -eq "`r"))) { return "'$text" }
    return $text
}

function Format-MbcRequestText {
    # A request the way an administrator would type it: GET v1.0 /path, or Get-X -Identity 'Default'.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Source,
        [AllowEmptyString()][string] $ApiVersion = '',
        [Parameter(Mandatory)][string] $Request,
        [AllowNull()][System.Collections.IDictionary] $Parameters
    )
    if ($Source -eq 'graph') { return "GET $ApiVersion $Request" }
    $sb = [System.Text.StringBuilder]::new($Request)
    if ($Parameters) {
        foreach ($k in $Parameters.Keys) {
            $v = $Parameters[$k]
            if ($v -is [bool]) { [void]$sb.Append(" -${k}:`$$($v.ToString().ToLowerInvariant())") }
            elseif (Test-MbcIsNumber $v) { [void]$sb.Append(" -$k $v") }
            else { [void]$sb.Append(" -$k '$(([string]$v).Replace("'", "''"))'") }
        }
    }
    return $sb.ToString()
}

function ConvertTo-MbcCsvText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows, [Parameter(Mandatory)][string[]] $Columns)
    if ($Rows.Count -eq 0) { return ((($Columns | ForEach-Object { "`"$_`"" }) -join ',') + "`n") }
    return ((@($Rows) | Select-Object -Property $Columns | ConvertTo-Csv -NoTypeInformation -UseQuotes AsNeeded) -join "`n") + "`n"
}

function ConvertTo-MbcResultCsv {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    $b = $Document['baseline']
    $rows = foreach ($r in @($Document['results'])) {
        [pscustomobject][ordered]@{
            Id              = Format-MbcCellValue $r['id']
            Area            = Get-MbcAreaName -Area ([string]$r['area'])
            Title           = Format-MbcCellValue $r['title']
            Location        = Format-MbcCellValue ([string]$r['location'])
            Verdict         = $script:MbcVerdictWords[[string]$r['verdict']]
            Severity        = [string]$r['severity']
            Expected        = Format-MbcCellValue $r['expected']
            Actual          = if ($r['hasActual']) { Format-MbcCellValue $r['actual'] } else { '' }
            Source          = [string]$r['source']
            Request         = Format-MbcCellValue (Format-MbcRequestText -Source ([string]$r['source']) -ApiVersion ([string]$r['apiVersion']) -Request ([string]$r['request']) -Parameters $r['parameters'])
            Cause           = [string]$r['cause']
            Baseline        = Format-MbcCellValue $b['name']
            BaselineVersion = [string]$b['version']
            Fingerprint     = [string]$b['fingerprint']
            RunUtc          = [string]$Document['run']['startedUtc']
        }
    }
    return (ConvertTo-MbcCsvText -Rows @($rows) -Columns @('Id', 'Area', 'Title', 'Location', 'Verdict', 'Severity', 'Expected', 'Actual', 'Source', 'Request', 'Cause', 'Baseline', 'BaselineVersion', 'Fingerprint', 'RunUtc'))
}

function ConvertTo-MbcAppsCsv {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    $inventory = ConvertFrom-MbcInventoryDocument -Document $Document['inventory']
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($app in @($inventory.ThirdParty) + @($inventory.Own)) {
        $base = [ordered]@{
            App       = Format-MbcCellValue $app.DisplayName
            Publisher = Format-MbcCellValue $app.Publisher
            Verified  = if ($app.Verified) { 'yes' } else { 'no' }
            AppId     = $app.AppId
            Kind      = if ($app.Kind -eq 'own') { 'own registration' } else { 'third-party' }
        }
        $permissions = @(
            foreach ($d in $app.Delegated) { [ordered]@{ PermissionType = "delegated-$($d.Type)"; Resource = $d.Resource; Permissions = ($d.Scopes -join ' '); Users = if ($d.Type -eq 'user') { [string]$d.Users } else { '' } } }
            foreach ($a in $app.Application) { [ordered]@{ PermissionType = 'application'; Resource = $a.Resource; Permissions = ($a.Roles -join ' '); Users = '' } }
        )
        if ($permissions.Count -eq 0) { $permissions = @([ordered]@{ PermissionType = ''; Resource = ''; Permissions = ''; Users = '' }) }
        foreach ($p in $permissions) {
            $row = [ordered]@{}
            foreach ($k in $base.Keys) { $row[$k] = $base[$k] }
            $row['PermissionType'] = $p.PermissionType
            $row['Resource'] = Format-MbcCellValue ([string]$p.Resource)
            $row['Permissions'] = Format-MbcCellValue ([string]$p.Permissions)
            $row['Users'] = $p.Users
            $rows.Add([pscustomobject]$row)
        }
    }
    return (ConvertTo-MbcCsvText -Rows $rows.ToArray() -Columns @('App', 'Publisher', 'Verified', 'AppId', 'Kind', 'PermissionType', 'Resource', 'Permissions', 'Users'))
}
