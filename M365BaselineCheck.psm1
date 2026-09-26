#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot
$script:MbcToolVersion = [string](Import-PowerShellDataFile (Join-Path $PSScriptRoot 'M365BaselineCheck.psd1')).ModuleVersion

# A fixed order, so a file's module-level variables exist before anything that reads them at load time.
foreach ($dir in 'Common', 'Baseline', 'Checks', 'Graph', 'Log', 'Report', 'Tui', 'Public') {
    $path = Join-Path $PSScriptRoot (Join-Path 'src' $dir)
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File | Sort-Object Name) {
        . $file.FullName
    }
}
