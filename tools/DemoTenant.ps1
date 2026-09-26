# A synthetic tenant for the demo and the TUI snapshots. Dot-source this inside the module's scope:
#   & (Get-Module M365BaselineCheck) { param($Root) . (Join-Path $Root 'tools/DemoTenant.ps1'); ... } $root
# Nothing here talks to Microsoft. Graph answers come from tests/fixtures/demo/tenant.json through the real
# GET-only client; Exchange Online answers come from a stand-in module through the real guarded cmdlet client.

function Import-MbcDemoCmdletModule {
    # A stand-in for the temporary module an Exchange Online connection creates. Only Get- functions.
    New-Module -Name 'tmpEXO_demo' -ScriptBlock {
        function Get-OrganizationConfig { [CmdletBinding()] param([string] $Identity) $null = $Identity; [pscustomobject]@{ Name = 'example.onmicrosoft.com'; AuditDisabled = $false; OAuth2ClientProfileEnabled = $true; IsDehydrated = $false; WhenChanged = [datetime]::new(2026, 3, 4, 10, 15, 0, [DateTimeKind]::Utc) } }
        function Get-TransportConfig { [CmdletBinding()] param([string] $Identity) $null = $Identity; [pscustomobject]@{ SmtpClientAuthenticationDisabled = $false; MaxSendSize = '35 MB (36,700,160 bytes)'; ExternalDelayDsnEnabled = $true } }
        function Get-ExternalInOutlook { [CmdletBinding()] param([string] $Identity) $null = $Identity; [pscustomobject]@{ Identity = 'example'; Enabled = $true; AllowList = @() } }
        function Get-AdminAuditLogConfig { [CmdletBinding()] param([string] $Identity) $null = $Identity; [pscustomobject]@{ UnifiedAuditLogIngestionEnabled = $true; AdminAuditLogEnabled = $true } }
        function Get-MalwareFilterPolicy { [CmdletBinding()] param([string] $Identity) $null = $Identity; [pscustomobject]@{ Name = 'Default'; EnableFileFilter = $true; ZapEnabled = $true; FileTypes = @('ace', 'ani', 'app', 'exe', 'jar') } }
        function Get-AntiPhishPolicy { [CmdletBinding()] param([string] $Identity) $null = $Identity; [pscustomobject]@{ Name = 'Office365 AntiPhish Default'; EnableMailboxIntelligence = $true; EnableSpoofIntelligence = $true } }
        function Get-HostedOutboundSpamFilterPolicy { [CmdletBinding()] param([string] $Identity) $null = $Identity; [pscustomobject]@{ Name = 'Default'; AutoForwardingMode = 'Automatic'; RecipientLimitPerDay = 0 } }
        Export-ModuleMember -Function *
    } | Import-Module -Global -Force
}

function Initialize-MbcDemoTenant {
    <#
    .SYNOPSIS
        Sets up the synthetic tenant and returns the seams Start-BaselineCheck takes: Fetch, Connection,
        Inventory, and the path of the example baseline.
    #>
    param([Parameter(Mandatory)][string] $Root, [switch] $Fast)
    Import-MbcDemoCmdletModule
    $raw = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $Root 'tests/fixtures/demo/tenant.json')))
    # Every response as JSON text, so the transport needs nothing from the module and can be a closure.
    $pages = @{}
    foreach ($path in $raw['graph'].Keys) {
        $entry = $raw['graph'][$path]
        if ($entry.Contains('status')) { $pages[$path] = @{ Status = [int]$entry['status']; Pages = @('{}'); Throttle = 0 } }
        elseif ($entry.Contains('pages')) { $pages[$path] = @{ Status = 200; Pages = @($entry['pages'] | ForEach-Object { ConvertTo-MbcCanonicalJson $_ }); Throttle = [int]$entry['throttleOnce'] } }
        else { $pages[$path] = @{ Status = 200; Pages = @(ConvertTo-MbcCanonicalJson $entry); Throttle = 0 } }
    }
    $transport = {
        param($Uri)
        $u = [uri]$Uri
        $entry = $pages[$u.AbsolutePath.Substring(5)]
        if ($null -eq $entry) { return [pscustomobject]@{ Status = 404; Body = '{}'; RetryAfter = $null } }
        if ($entry.Throttle -gt 0) {
            $wait = $entry.Throttle
            $entry.Throttle = 0
            return [pscustomobject]@{ Status = 429; Body = '{}'; RetryAfter = [string]$wait }
        }
        $index = if ($u.Query.IndexOf('skiptoken=demo2') -ge 0) { 1 } else { 0 }
        [pscustomobject]@{ Status = $entry.Status; Body = $entry.Pages[$index]; RetryAfter = $null }
    }.GetNewClosure()
    $baselinePath = Join-Path $Root 'presets/example-tenant-hygiene.baseline.json'
    $connection = [pscustomobject]@{
        PSTypeName = 'Mbc.Connection'; Account = 'admin@example.com'; TenantId = '00000000-0000-4000-8000-000000000001'
        TenantName = 'Example Ltd'; Domain = 'example.com'
        Scopes = @('Application.Read.All', 'Directory.Read.All', 'Policy.Read.All', 'User.Read', 'Directory.ReadWrite.All'); WriteScopes = @('Directory.ReadWrite.All')
        Roles = @('Global Administrator'); RolesCause = $null
        Sessions = [ordered]@{ exo = 'tmpEXO_demo' }; Failed = [ordered]@{ compliance = 'User canceled authentication.' }; Disclosure = @()
    }
    $connection.Disclosure = Format-MbcDisclosure -Connection $connection
    # Module scope, so the seams below find it whenever and wherever they are called.
    $script:MbcDemo = @{
        Delay      = if ($Fast) { 0.0 } else { 0.45 }
        Transport  = $transport
        Preset     = (Read-MbcBaseline -Path $baselinePath).Document['preset']
        Connection = $connection
    }
    return @{
        Baseline   = $baselinePath
        Connection = $connection
        Fetch      = {
            param($Item, $OnTick, $OnWait)
            $demo = $script:MbcDemo
            if ($demo.Delay -gt 0) { Wait-MbcSeconds -Seconds ($demo.Delay * (0.6 + (Get-Random -Maximum 0.8))) -OnTick $OnTick }
            if ($Item.Source -eq 'graph') { return (Invoke-MbcGraphGet -ApiVersion $Item.ApiVersion -Request $Item.Request -Transport $demo.Transport -OnTick $OnTick -OnWait $OnWait) }
            Invoke-MbcCmdletGet -Item $Item -Preset $demo.Preset -Sessions $demo.Connection.Sessions
        }
        Inventory  = {
            param($OnProgress)
            $get = {
                param($Request)
                if ($script:MbcDemo.Delay -gt 0) { Start-Sleep -Milliseconds 120 }
                Invoke-MbcGraphGet -ApiVersion 'v1.0' -Request $Request -Transport $script:MbcDemo.Transport
            }
            $tenant = $script:MbcDemo.Connection.TenantId
            ConvertTo-MbcAppInventory -Data (Get-MbcAppInventoryData -Get $get -TenantId $tenant -OnProgress $OnProgress) -TenantId $tenant
        }
    }
}
