# How a planned request reaches its source in a real run, and how the inventory is read. Both are thin:
# the guards live in the clients.

function Invoke-MbcSourceFetch {
    # One plan item to the client for its source. The Fetch block of a real run calls this.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Preset,
        [AllowNull()] $Connection,
        [AllowNull()] $Log,
        [scriptblock] $OnTick
    )
    if ($Item.Source -eq 'graph') {
        return (Invoke-MbcGraphGet -ApiVersion $Item.ApiVersion -Request $Item.Request -OnTick $OnTick -Log $Log)
    }
    $sessions = if ($Connection -and $Connection.Sessions) { $Connection.Sessions } else { [ordered]@{} }
    return (Invoke-MbcCmdletGet -Item $Item -Preset $Preset -Sessions $sessions -Log $Log)
}

function Invoke-MbcInventory {
    # The app inventory of the signed-in tenant, read through the GET-only Graph client.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $TenantId,
        [AllowNull()] $Log,
        [scriptblock] $OnProgress,
        [scriptblock] $OnTick
    )
    $runLog = $Log
    $tick = $OnTick
    $get = { param($Request) Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request $Request -OnTick $tick -Log $runLog }
    $inventory = ConvertTo-MbcAppInventory -Data (Get-MbcAppInventoryData -Get $get -TenantId $TenantId -OnProgress $OnProgress) -TenantId $TenantId
    Write-MbcLog -Log $Log -EventName 'inventory' -Data ([ordered]@{
            thirdParty = @($inventory.ThirdParty).Count; own = @($inventory.Own).Count
            firstParty = $inventory.FirstPartyCount; other = $inventory.OtherCount; failures = @($inventory.Failures)
        })
    return $inventory
}

function Write-MbcCheckLog {
    [CmdletBinding()]
    param([AllowNull()] $Log, [Parameter(Mandatory)] $Result)
    Write-MbcLog -Log $Log -EventName 'check' -Data ([ordered]@{
            id = $Result.Id; area = $Result.Area; source = $Result.Source; request = $Result.Request; parameters = $Result.Parameters
            select = $Result.Select; operator = $Result.Operator; expected = $Result.Expected; hasActual = $Result.HasActual
            actual = $Result.Actual; verdict = $Result.Verdict; cause = $Result.Cause; detail = $Result.Detail
        })
}
