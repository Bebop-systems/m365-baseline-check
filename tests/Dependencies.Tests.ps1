BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Pinned client modules' {
        BeforeAll {
            $script:GraphName = 'Microsoft.Graph.Authentication'
            $script:MsSig = [pscustomobject]@{ Status = 'Valid'; Message = ''; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' }
            # A module folder with the files the pin checks, and an optional prerelease label.
            function script:New-FakeModule([string] $Version, [string] $Prerelease = '', [switch] $Missing) {
                $base = Join-Path $TestDrive "g/$Version$Prerelease"
                New-Item -ItemType Directory -Path $base -Force | Out-Null
                foreach ($f in $script:MbcDependencies[$script:GraphName].Files) { if (-not $Missing -or $f -notlike '*.Core.dll') { [System.IO.File]::WriteAllText((Join-Path $base $f), 'x') } }
                [pscustomobject]@{ Name = $script:GraphName; Version = [version]$Version; ModuleBase = $base; PrivateData = @{ PSData = @{ Prerelease = $Prerelease } } }
            }
        }
        BeforeEach {
            Mock Get-MbcLoadedModule { $null }
            Mock Test-MbcSignatureCheckable { $true }
            Mock Get-MbcModuleSignature { $script:MsSig }
        }
        It 'chooses the highest installed release inside the tested range, from its own manifest' {
            Mock Get-MbcInstalledModules { , @((New-FakeModule '2.30.0'), (New-FakeModule '2.38.1'), (New-FakeModule '2.40.0'), (New-FakeModule '2.41.0' 'preview1'), (New-FakeModule '3.0.0')) }
            $d = Resolve-MbcDependency -Name $script:GraphName
            $d.Version | Should -Be ([version]'2.40.0') -Because 'a preview is never chosen'
            $d.Manifest | Should -BeLike '*2.40.0*Microsoft.Graph.Authentication.psd1'
            $d.NewerThanTest | Should -BeTrue
            $d.Signature | Should -Be 'Microsoft'
            Should -Invoke Get-MbcModuleSignature -Times 4 -Exactly -Because 'the manifest, root module and both assemblies are checked'
        }
        It 'refuses when only versions outside the range are installed, and says which to install' {
            Mock Get-MbcInstalledModules { , @((New-FakeModule '2.30.0'), (New-FakeModule '3.1.0')) }
            { Resolve-MbcDependency -Name $script:GraphName } | Should -Throw '*2.38.1 or later, below 3.0*Installed: 2.30.0, 3.1.0.*Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1 -Scope CurrentUser*'
        }
        It 'refuses a version outside the range, or a preview, already loaded in the session, and suggests -NoProfile' {
            Mock Get-MbcLoadedModule { New-FakeModule '2.20.0' }
            { Resolve-MbcDependency -Name $script:GraphName } | Should -Throw '*2.20.0 is already loaded*pwsh -NoProfile*'
            Mock Get-MbcLoadedModule { New-FakeModule '2.39.0' 'preview2' }
            { Resolve-MbcDependency -Name $script:GraphName } | Should -Throw '*2.39.0-preview2 is already loaded*'
        }
        It 'uses a version inside the range that is already loaded, without importing it again' {
            Mock Get-MbcLoadedModule { New-FakeModule '2.38.1' }
            (Resolve-MbcDependency -Name $script:GraphName).AlreadyLoaded | Should -BeTrue
        }
        It 'refuses a module whose checked files are not all validly signed by Microsoft' {
            Mock Get-MbcInstalledModules { , @(New-FakeModule '2.38.1') }
            Mock Get-MbcModuleSignature { if ($Path -like '*.Core.dll') { [pscustomobject]@{ Status = 'HashMismatch'; Message = 'The hash does not match.'; Signer = ''; Issuer = '' } } else { $script:MsSig } }
            { Resolve-MbcDependency -Name $script:GraphName } | Should -Throw "*Microsoft.Graph.Authentication.Core.dll isn't validly signed by Microsoft (signature HashMismatch: The hash does not match.)*isn't loaded*"
            Mock Get-MbcModuleSignature { [pscustomobject]@{ Status = 'Valid'; Message = ''; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation'; Issuer = 'CN=Contoso Enterprise CA' } }
            { Resolve-MbcDependency -Name $script:GraphName } | Should -Throw '*issued by CN=Contoso Enterprise CA*'
        }
        It 'refuses a module whose layout is not the tested one' {
            Mock Get-MbcInstalledModules { , @(New-FakeModule '2.38.2' -Missing) }
            { Resolve-MbcDependency -Name $script:GraphName } | Should -Throw '*has no Microsoft.Graph.Authentication.Core.dll*'
        }
        It 'refuses on a PowerShell older than the module needs' {
            $saved = $script:MbcDependencies[$script:GraphName].PowerShell
            $script:MbcDependencies[$script:GraphName].PowerShell = [version]'99.0'
            try { { Resolve-MbcDependency -Name $script:GraphName } | Should -Throw '*needs PowerShell 99.0 or later*' }
            finally { $script:MbcDependencies[$script:GraphName].PowerShell = $saved }
        }
        It 'loads where signatures cannot be checked, and says so' {
            Mock Test-MbcSignatureCheckable { $false }
            Mock Get-MbcInstalledModules { , @(New-FakeModule '2.38.1') }
            $d = Resolve-MbcDependency -Name $script:GraphName
            $d.Signature | Should -Be 'unchecked'
            Should -Invoke Get-MbcModuleSignature -Times 0 -Exactly
            Format-MbcDependencyLine -Loaded @($d) | Should -Be "Client modules: Microsoft.Graph.Authentication 2.38.1; signatures can't be checked on this platform."
        }
        It 'discloses the versions used, marking one newer than tested' {
            $g = [pscustomobject]@{ Name = $script:GraphName; Version = [version]'2.38.1'; Signature = 'Microsoft'; NewerThanTest = $false }
            $e = [pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.11.0'; Signature = 'Microsoft'; NewerThanTest = $true }
            Format-MbcDependencyLine -Loaded @($g, $e) | Should -Be 'Client modules: Microsoft.Graph.Authentication 2.38.1, ExchangeOnlineManagement 3.11.0 (newer than the tested 3.10.0); manifest, root module and core assemblies validly signed by Microsoft.'
            Format-MbcDependencyLine -Loaded @() | Should -BeExactly ''
        }
    }

    Describe 'The real installed client modules' {
        It 'resolve, or are refused with what to do, and nothing else' {
            foreach ($name in $script:MbcDependencies.Keys) {
                if (-not (Get-Module -ListAvailable -Name $name)) { continue }
                try { (Resolve-MbcDependency -Name $name).Name | Should -Be $name }
                catch { ($_.Exception.Message -like '*Install-Module*' -or $_.Exception.Message -like '*Update PowerShell*') | Should -BeTrue -Because $_.Exception.Message }
            }
        }
    }
}
