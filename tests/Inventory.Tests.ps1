BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'The app inventory' {
        BeforeAll {
            $script:Tenant = '00000000-0000-4000-8000-000000000001'
            $script:Bodies = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Join-Path $script:ModuleRoot 'tests/fixtures/inventory/tenant.json')))
            $script:Requests = [System.Collections.Generic.List[string]]::new()
            $script:Get = {
                param($Request)
                $script:Requests.Add($Request)
                $q = $Request.IndexOf('?')
                $path = if ($q -ge 0) { $Request.Substring(0, $q) } else { $Request }
                if ($script:Bodies.Contains($path)) { return (New-MbcFetchResult -Ok $true -Body $script:Bodies[$path] -Status 200) }
                New-MbcFetchResult -Ok $false -Status 404 -Cause 'not found'
            }
            function script:Get-Inventory([scriptblock] $Get = $script:Get) {
                ConvertTo-MbcAppInventory -Data (Get-MbcAppInventoryData -Get $Get -TenantId $script:Tenant) -TenantId $script:Tenant
            }
        }
        BeforeEach { $script:Requests.Clear() }

        It 'lists third-party apps and own registrations, and counts the rest' {
            $inv = Get-Inventory
            $inv.Collected | Should -BeTrue
            @($inv.ThirdParty | ForEach-Object DisplayName) -join ',' | Should -Be 'Example Scheduler,Sample Notes'
            @($inv.Own | ForEach-Object DisplayName) -join ',' | Should -Be 'SENTINEL-OWN-APP,SENTINEL-OWN-APP-TWO'
            $inv.FirstPartyCount | Should -Be 2
            $inv.OtherCount | Should -Be 1
        }

        It 'reads only the documented fields, with $select' {
            Get-Inventory | Out-Null
            ($script:Requests | Where-Object { $_.StartsWith('/servicePrincipals?') }) | Should -BeLike '*$select=id,appId,displayName,appOwnerOrganizationId,publisherName,verifiedPublisher,servicePrincipalType,accountEnabled,tags,appRoleAssignmentRequired*'
            ($script:Requests | Where-Object { $_.StartsWith('/applications?') }) | Should -BeLike '*$select=id,appId,displayName,signInAudience,createdDateTime,publisherDomain,verifiedPublisher*'
        }

        It 'reads application permissions for listed apps only, and each resource once' {
            Get-Inventory | Out-Null
            @($script:Requests | Where-Object { $_ -like '*/appRoleAssignments' }).Count | Should -Be 3
            @($script:Requests | Where-Object { $_.StartsWith('/servicePrincipals/00000000-0000-4000-8000-0000000000a1?') }).Count | Should -Be 1
            $script:Requests | Should -Not -Contain '/servicePrincipals/00000000-0000-4000-8000-0000000000a2/appRoleAssignments'
        }

        It 'describes publisher, verification, enabled state and assignment' {
            $inv = Get-Inventory
            $scheduler = $inv.ThirdParty | Where-Object DisplayName -eq 'Example Scheduler'
            $scheduler.Publisher | Should -Be 'Example Software Ltd'
            $scheduler.Verified | Should -BeTrue
            $scheduler.AssignmentRequired | Should -BeTrue
            $notes = $inv.ThirdParty | Where-Object DisplayName -eq 'Sample Notes'
            $notes.Verified | Should -BeFalse
            $notes.Enabled | Should -BeFalse
            ($inv.Own | Where-Object DisplayName -eq 'SENTINEL-OWN-APP-TWO').Enabled | Should -BeNullOrEmpty
        }

        It 'separates admin consent from user consent, and counts consenting users' {
            $inv = Get-Inventory
            $admin = ($inv.ThirdParty | Where-Object DisplayName -eq 'Example Scheduler').Delegated
            $admin.Count | Should -Be 1
            $admin[0].Type | Should -Be 'admin'
            $admin[0].Resource | Should -Be 'Microsoft Graph'
            $admin[0].Scopes -join ',' | Should -Be 'Mail.Read,User.Read'
            $user = ($inv.ThirdParty | Where-Object DisplayName -eq 'Sample Notes').Delegated
            $user[0].Type | Should -Be 'user'
            $user[0].Scopes -join ',' | Should -Be 'Notes.Read,User.Read'
            $user[0].Users | Should -Be 2
        }

        It 'names application permissions, and marks one it cannot resolve' {
            $app = (Get-Inventory).ThirdParty | Where-Object DisplayName -eq 'Example Scheduler'
            $app.Application.Count | Should -Be 1
            $app.Application[0].Resource | Should -Be 'Microsoft Graph'
            $app.Application[0].Roles -join ',' | Should -Be 'unresolved permission,User.Read.All'
        }

        It 'keeps what it could read when one read fails, and says which' {
            $partial = {
                param($Request)
                if ($Request -like '/oauth2PermissionGrants*') { return (New-MbcFetchResult -Ok $false -Status 403 -Cause 'permission missing') }
                & $script:Get $Request
            }
            $inv = Get-Inventory -Get $partial
            $inv.ThirdParty.Count | Should -Be 2
            $inv.Failures -join ' | ' | Should -Be "Couldn't read consents: permission missing"
            @(($inv.ThirdParty | Where-Object DisplayName -eq 'Example Scheduler').Delegated).Count | Should -Be 0
        }

        It 'says so when nothing could be read at all' {
            $inv = Get-Inventory -Get { param($Request) New-MbcFetchResult -Ok $false -Status 403 -Cause 'permission missing' }
            $inv.Failures | Should -Contain "Couldn't read enterprise apps: permission missing"
            $inv.Failures | Should -Contain "Couldn't read app registrations: permission missing"
            $inv.ThirdParty.Count | Should -Be 0
        }

        It 'can be left out, and says so' {
            $inv = New-MbcSkippedInventory
            $inv.Collected | Should -BeFalse
            $inv.ThirdParty.Count | Should -Be 0
        }
    }
}
