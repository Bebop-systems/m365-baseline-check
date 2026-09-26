#Requires -Version 7.4
<#
.SYNOPSIS
    The local gate: every test, then the analyser over ./src and ./tools. Run it before every commit.
#>
[CmdletBinding()]
param([switch] $SkipAnalyzer)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge [version]'5.5.0' } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester 5.5 or later is needed: Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser' }
Import-Module $pester.Path -Force

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $root 'tests'
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
$result = Invoke-Pester -Configuration $config
$failed = $result.FailedCount + $result.FailedBlocksCount + $result.FailedContainersCount

$findings = @()
if (-not $SkipAnalyzer) {
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        throw 'PSScriptAnalyzer is needed: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    }
    Import-Module PSScriptAnalyzer -Force
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    # Two invocations on purpose: -Path takes one string, and a comma list analyses nothing, silently.
    foreach ($dir in 'src', 'tools') {
        $findings += @(Invoke-ScriptAnalyzer -Path (Join-Path $root $dir) -Recurse -Settings $settings)
    }
    # Canary: a clean result only means something if the analyser can find a problem at all.
    $canary = @(Invoke-ScriptAnalyzer -ScriptDefinition 'function Get-Canary { Write-Host "x" }' -Settings $settings)
    if ($canary.Count -eq 0) { throw 'The analyser found nothing in a deliberately bad script, so its clean result cannot be trusted.' }
}

if ($findings.Count) { $findings | Format-Table -AutoSize | Out-String | Write-Output }
Write-Output ('Tests: {0} passed, {1} failed, {2} skipped. Analyser: {3} finding(s).' -f
    $result.PassedCount, $failed, $result.SkippedCount, $findings.Count)
if ($failed -gt 0 -or $findings.Count -gt 0) { exit 1 }
