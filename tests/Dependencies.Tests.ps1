BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Pinned client modules' {
        BeforeAll {
            function script:New-FakeModule([string] $Version) { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication'; Version = [version]$Version; ModuleBase = Join-Path $TestDrive "g/$Version" } }
        }
        BeforeEach {
            Mock Get-MbcLoadedModule { $null }
            Mock Get-MbcModuleSignature { [pscustomobject]@{ Status = 'Valid'; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } }
        }
        It 'chooses the highest installed version inside the tested range, from its own manifest' {
            Mock Get-MbcInstalledModules { , @((New-FakeModule '2.30.0'), (New-FakeModule '2.38.1'), (New-FakeModule '2.40.0'), (New-FakeModule '3.0.0')) }
            $d = Resolve-MbcDependency -Name 'Microsoft.Graph.Authentication'
            $d.Version | Should -Be ([version]'2.40.0')
            $d.Manifest | Should -BeLike '*2.40.0*Microsoft.Graph.Authentication.psd1'
            $d.NewerThanTest | Should -BeTrue
            $d.Signature | Should -Be 'Microsoft'
        }
        It 'refuses when only versions outside the range are installed, and says which to install' {
            Mock Get-MbcInstalledModules { , @((New-FakeModule '2.30.0'), (New-FakeModule '3.1.0')) }
            { Resolve-MbcDependency -Name 'Microsoft.Graph.Authentication' } | Should -Throw '*2.38.1 or later, below 3.0*Installed: 2.30.0, 3.1.0.*Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1 -Scope CurrentUser*'
        }
        It 'refuses a version outside the range that is already loaded in the session' {
            Mock Get-MbcLoadedModule { New-FakeModule '2.20.0' }
            { Resolve-MbcDependency -Name 'Microsoft.Graph.Authentication' } | Should -Throw '*2.20.0 is already loaded*Start a fresh pwsh*'
        }
        It 'uses a version inside the range that is already loaded, without importing it again' {
            Mock Get-MbcLoadedModule { New-FakeModule '2.38.1' }
            (Resolve-MbcDependency -Name 'Microsoft.Graph.Authentication').AlreadyLoaded | Should -BeTrue
        }
        It 'refuses a module whose signature is not valid, or not Microsoft''s' {
            Mock Get-MbcInstalledModules { , @(New-FakeModule '2.38.1') }
            Mock Get-MbcModuleSignature { [pscustomobject]@{ Status = 'HashMismatch'; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' } }
            { Resolve-MbcDependency -Name 'Microsoft.Graph.Authentication' } | Should -Throw "*isn't validly signed by Microsoft (signature: HashMismatch)*isn't loaded*"
            Mock Get-MbcModuleSignature { [pscustomobject]@{ Status = 'Valid'; Signer = 'CN=Someone Else' } }
            { Resolve-MbcDependency -Name 'Microsoft.Graph.Authentication' } | Should -Throw "*isn't validly signed by Microsoft*"
        }
        It 'loads where signatures cannot be checked, and says so' {
            Mock Get-MbcInstalledModules { , @(New-FakeModule '2.38.1') }
            Mock Get-MbcModuleSignature { $null }
            $d = Resolve-MbcDependency -Name 'Microsoft.Graph.Authentication'
            $d.Signature | Should -Be 'unchecked'
            Format-MbcDependencyLine -Loaded @($d) | Should -Be "Client modules: Microsoft.Graph.Authentication 2.38.1; signatures can't be checked on this platform."
        }
        It 'discloses the versions used, marking one newer than tested' {
            $g = [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication'; Version = [version]'2.38.1'; Signature = 'Microsoft'; NewerThanTest = $false }
            $e = [pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.11.0'; Signature = 'Microsoft'; NewerThanTest = $true }
            Format-MbcDependencyLine -Loaded @($g, $e) | Should -Be 'Client modules: Microsoft.Graph.Authentication 2.38.1, ExchangeOnlineManagement 3.11.0 (newer than the tested 3.10.0); each validly signed by Microsoft.'
            Format-MbcDependencyLine -Loaded @() | Should -BeExactly ''
        }
        It 'checks the real installed modules the same way, where they are installed' {
            foreach ($name in $script:MbcDependencies.Keys) {
                if (-not (Get-Module -ListAvailable -Name $name)) { continue }
                # Whatever is installed here either resolves or is refused with an install hint; nothing else.
                try { (Resolve-MbcDependency -Name $name).Name | Should -Be $name }
                catch { $_.Exception.Message | Should -BeLike '*Install-Module*' }
            }
        }
    }
}
