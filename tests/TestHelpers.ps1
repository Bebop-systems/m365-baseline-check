# Shared by tests that need a whole run: dot-source inside InModuleScope. Test code only.

function New-TestView {
    <#
    .SYNOPSIS
        The fixture baseline run against synthetic responses laced with sentinel values, with the fixture
        inventory, as a result view. ORG-001 is Not met, CA-001 Met, EXO-001 Unverifiable.
    #>
    param([switch] $Unsealed, [switch] $SkipInventory)
    $fx = Join-Path $script:ModuleRoot 'tests/fixtures'
    $baseline = Read-MbcBaseline -Path (Join-Path $fx 'baseline-minimal.json')
    if (-not $Unsealed) { $baseline.SealState = 'Sealed' }
    $bodies = @{
        '/policies/authorizationPolicy'        = ConvertFrom-MbcJson -Json '{"defaultUserRolePermissions":{"allowedToCreateApps":true}}'
        '/identity/conditionalAccess/policies' = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $fx 'graph/sentinel-policies.json')))
    }
    $fetch = {
        param($Item)
        if ($bodies.ContainsKey($Item.Request)) { return (New-MbcFetchResult -Ok $true -Body $bodies[$Item.Request] -Status 200) }
        New-MbcFetchResult -Ok $false -Cause 'not connected' -Detail "There's no exo session."
    }
    $tenant = '00000000-0000-4000-8000-000000000001'
    $invData = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $fx 'inventory/tenant.json')))
    $get = {
        param($Request)
        $q = $Request.IndexOf('?')
        $path = if ($q -ge 0) { $Request.Substring(0, $q) } else { $Request }
        if ($invData.Contains($path)) { return (New-MbcFetchResult -Ok $true -Body $invData[$path] -Status 200) }
        New-MbcFetchResult -Ok $false -Status 404 -Cause 'not found'
    }
    $inventory = if ($SkipInventory) { New-MbcSkippedInventory } else { ConvertTo-MbcAppInventory -Data (Get-MbcAppInventoryData -Get $get -TenantId $tenant) -TenantId $tenant }
    $run = Invoke-MbcRun -Baseline $baseline -Fetch $fetch -RunId '20260926T141200Z-abc123'
    $run.Inventory = $inventory
    $connection = [pscustomobject]@{
        TenantId = $tenant; TenantName = 'SENTINEL-TENANT-NAME'; Domain = 'sentinel-domain.example.com'; Account = 'sentinel.user@example.com'
        Disclosure = @('Signed in as sentinel.user@example.com to SENTINEL-TENANT-NAME (00000000-0000-4000-8000-000000000001).', 'Read-only by construction: GET-only Graph, Get- cmdlets only.')
    }
    return (ConvertFrom-MbcResultDocument -Document (New-MbcResultDocument -Run $run -Baseline $baseline -Connection $connection))
}
