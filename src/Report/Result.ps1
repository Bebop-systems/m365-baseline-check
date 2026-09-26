# The result document: everything a run found, sealed by the same canonical-digest method as baselines.
# A view (Mbc.ResultView) is what every renderer reads, whether the run is live or reopened from a file.

$script:MbcAreaNames = [ordered]@{ entra = 'Entra'; exchange = 'Exchange'; intune = 'Intune'; purview = 'Purview'; defender = 'Defender'; admin = 'Microsoft 365 admin' }
$script:MbcVerdictWords = @{ Pass = 'Met'; Fail = 'Not met'; Error = 'Unverifiable' }

function Get-MbcAreaName {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Area)
    if ($script:MbcAreaNames.Contains($Area)) { return $script:MbcAreaNames[$Area] }
    return $Area
}

function ConvertTo-MbcInventoryDocument {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()] $Inventory)
    if ($null -eq $Inventory) { $Inventory = New-MbcSkippedInventory }
    $app = {
        param($a)
        [ordered]@{
            kind               = $a.Kind
            displayName        = $a.DisplayName
            publisher          = $a.Publisher
            verified           = [bool]$a.Verified
            appId              = $a.AppId
            enabled            = $a.Enabled
            assignmentRequired = $a.AssignmentRequired
            delegated          = @($a.Delegated | ForEach-Object { [ordered]@{ type = $_.Type; resource = $_.Resource; scopes = @($_.Scopes); users = [long]$_.Users } })
            application        = @($a.Application | ForEach-Object { [ordered]@{ resource = $_.Resource; roles = @($_.Roles) } })
        }
    }
    return [ordered]@{
        collected       = [bool]$Inventory.Collected
        firstPartyCount = [long]$Inventory.FirstPartyCount
        otherCount      = [long]$Inventory.OtherCount
        failures        = @($Inventory.Failures)
        thirdParty      = @($Inventory.ThirdParty | ForEach-Object { & $app $_ })
        own             = @($Inventory.Own | ForEach-Object { & $app $_ })
    }
}

function ConvertFrom-MbcInventoryDocument {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][System.Collections.IDictionary] $Document)
    if ($null -eq $Document) { return (New-MbcSkippedInventory) }
    $app = {
        param($a)
        [pscustomobject]@{
            PSTypeName         = 'Mbc.InventoryApp'
            Kind               = [string]$a['kind']
            DisplayName        = [string]$a['displayName']
            Publisher          = [string]$a['publisher']
            Verified           = [bool]$a['verified']
            AppId              = [string]$a['appId']
            Enabled            = $a['enabled']
            AssignmentRequired = $a['assignmentRequired']
            Delegated          = @($a['delegated'] | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Type = [string]$_['type']; Resource = [string]$_['resource']; Scopes = [string[]]@($_['scopes']); Users = [int]$_['users'] } })
            Application        = @($a['application'] | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Resource = [string]$_['resource']; Roles = [string[]]@($_['roles']) } })
        }
    }
    return [pscustomobject]@{
        PSTypeName      = 'Mbc.Inventory'
        Collected       = [bool]$Document['collected']
        ThirdParty      = @($Document['thirdParty'] | Where-Object { $_ } | ForEach-Object { & $app $_ })
        Own             = @($Document['own'] | Where-Object { $_ } | ForEach-Object { & $app $_ })
        FirstPartyCount = [int]$Document['firstPartyCount']
        OtherCount      = [int]$Document['otherCount']
        Failures        = [string[]]@($Document['failures'] | Where-Object { $_ })
    }
}

function New-MbcResultDocument {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] $Baseline,
        [AllowNull()] $Connection
    )
    $results = foreach ($r in $Run.Results) {
        [ordered]@{
            id         = $r.Id
            title      = $r.Title
            area       = $r.Area
            location   = $r.Location
            severity   = $r.Severity
            verdict    = $r.Verdict
            cause      = $r.Cause
            detail     = $r.Detail
            source     = $r.Source
            request    = $r.Request
            parameters = $r.Parameters
            apiVersion = $r.ApiVersion
            operator   = $r.Operator
            expected   = $r.Expected
            hasActual  = $r.HasActual
            actual     = $r.Actual
            labels     = $r.Labels
            why        = $r.Why
        }
    }
    $doc = [ordered]@{
        schemaVersion = 1L
        kind          = 'm365bc-result'
        tool          = [ordered]@{ version = $script:MbcToolVersion }
        run           = [ordered]@{
            id          = $Run.RunId
            startedUtc  = $Run.StartedUtc.ToString('o', [cultureinfo]::InvariantCulture)
            finishedUtc = $Run.FinishedUtc.ToString('o', [cultureinfo]::InvariantCulture)
        }
        tenant        = [ordered]@{
            id      = if ($Connection) { [string]$Connection.TenantId } else { '' }
            name    = if ($Connection) { [string]$Connection.TenantName } else { '' }
            domain  = if ($Connection) { [string]$Connection.Domain } else { '' }
            account = if ($Connection) { [string]$Connection.Account } else { '' }
        }
        disclosure    = if ($Connection) { @($Connection.Disclosure) } else { @() }
        baseline      = [ordered]@{ name = $Baseline.Name; version = $Baseline.Version; fingerprint = $Baseline.Fingerprint; digest = $Baseline.Digest; sealState = $Baseline.SealState }
        counts        = [ordered]@{ pass = [long]$Run.Counts.Pass; fail = [long]$Run.Counts.Fail; error = [long]$Run.Counts.Error; total = [long]$Run.Counts.Total }
        results       = @($results)
        inventory     = ConvertTo-MbcInventoryDocument -Inventory $Run.Inventory
    }
    $doc['seal'] = [ordered]@{ algorithm = 'SHA-256'; digest = (Get-MbcDocumentDigest -Document $doc) }
    return $doc
}

function Test-MbcResultSeal {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    if (-not ($Document.Contains('seal') -and (Test-MbcIsDictionary $Document['seal']))) { return $false }
    return ([string]$Document['seal']['digest'] -ceq (Get-MbcDocumentDigest -Document $Document))
}

function ConvertFrom-MbcResultDocument {
    <#
    .SYNOPSIS
        The view every renderer reads: results shaped as the engine makes them, the inventory, the
        tenant, the disclosure and the baseline identity.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    $results = @(foreach ($r in @($Document['results'])) {
            $parameters = [ordered]@{}
            if (Test-MbcIsDictionary $r['parameters']) { foreach ($k in $r['parameters'].Keys) { $parameters[$k] = $r['parameters'][$k] } }
            [pscustomobject]@{
                PSTypeName = 'Mbc.CheckResult'
                Id         = [string]$r['id']
                Title      = [string]$r['title']
                Area       = [string]$r['area']
                Location   = [string]$r['location']
                Severity   = [string]$r['severity']
                Why        = [string]$r['why']
                Source     = [string]$r['source']
                Request    = [string]$r['request']
                Parameters = $parameters
                ApiVersion = [string]$r['apiVersion']
                Operator   = [string]$r['operator']
                Expected   = $r['expected']
                Actual     = $r['actual']
                HasActual  = [bool]$r['hasActual']
                Verdict    = [string]$r['verdict']
                Cause      = $r['cause']
                Detail     = $r['detail']
                Labels     = if (Test-MbcIsDictionary $r['labels']) { $r['labels'] } else { [ordered]@{} }
            }
        })
    $b = $Document['baseline']
    $t = $Document['tenant']
    return [pscustomobject]@{
        PSTypeName = 'Mbc.ResultView'
        RunId      = [string]$Document['run']['id']
        StartedUtc = [string]$Document['run']['startedUtc']
        Tool       = [string]$Document['tool']['version']
        Tenant     = [pscustomobject]@{ Id = [string]$t['id']; Name = [string]$t['name']; Domain = [string]$t['domain']; Account = [string]$t['account'] }
        Disclosure = [string[]]@($Document['disclosure'] | Where-Object { $_ })
        Baseline   = [pscustomobject]@{ Name = [string]$b['name']; Version = [long]$b['version']; Fingerprint = [string]$b['fingerprint']; Digest = [string]$b['digest']; SealState = [string]$b['sealState'] }
        Results    = $results
        Counts     = Get-MbcCounts -Results $results
        Inventory  = ConvertFrom-MbcInventoryDocument -Document $Document['inventory']
        Sealed     = Test-MbcResultSeal -Document $Document
        Document   = $Document
    }
}
