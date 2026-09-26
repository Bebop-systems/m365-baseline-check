@{
    RootModule           = 'M365BaselineCheck.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'd78f3c36-d409-45d9-8d87-358c2307d62d'
    Author               = 'Claude (Anthropic), under human direction'
    Copyright            = 'Licensed under the Apache License, Version 2.0.'
    Description          = 'Read-only Microsoft 365 configuration checks against sealed baselines, from a terminal UI.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Start-BaselineCheck', 'Invoke-BaselineCheck', 'New-BaselineCapture',
        'Protect-Baseline', 'Test-Baseline', 'New-ResultKey', 'Unlock-Result'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Microsoft365', 'Graph', 'Baseline', 'Audit', 'ReadOnly')
            LicenseUri = 'https://www.apache.org/licenses/LICENSE-2.0'
        }
    }
}
