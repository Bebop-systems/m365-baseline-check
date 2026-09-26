BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Manifest = Join-Path $script:Root 'M365BaselineCheck.psd1'
}

Describe 'The module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:Manifest -ErrorAction Stop } | Should -Not -Throw
    }

    It 'imports cleanly' {
        { Import-Module $script:Manifest -Force -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports nothing beyond the declared public commands' {
        Import-Module $script:Manifest -Force
        $declared = (Import-PowerShellDataFile $script:Manifest).FunctionsToExport
        $exported = @((Get-Module M365BaselineCheck).ExportedFunctions.Keys)
        @($exported | Where-Object { $_ -notin $declared }) | Should -BeNullOrEmpty
    }

    It 'requires nothing at import time beyond PowerShell itself' {
        (Import-PowerShellDataFile $script:Manifest).ContainsKey('RequiredModules') | Should -BeFalse
    }

    It 'knows its own version' {
        Import-Module $script:Manifest -Force
        $v = & (Get-Module M365BaselineCheck) { $script:MbcToolVersion }
        $v | Should -Be (Import-PowerShellDataFile $script:Manifest).ModuleVersion
    }
}
