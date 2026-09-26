#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the interactive view against a synthetic tenant, so you can try it without signing in anywhere.
.DESCRIPTION
    Nothing here talks to Microsoft. Graph answers come from tests/fixtures/demo/tenant.json through the
    real GET-only client (paging and one throttled request included), and Exchange Online cmdlets come from
    a small stand-in module run through the real guarded cmdlet client. Security & Compliance shows as not
    connected, so its check is unverifiable. Exports and logs go to a temporary folder.

    It runs the example baseline in presets/, and prints a throwaway team key first, for trying export
    and "Open a locked result".
.EXAMPLE
    pwsh -NoProfile -File tools/Start-Demo.ps1
.EXAMPLE
    pwsh -NoProfile -File tools/Start-Demo.ps1 -Fast -Ascii
#>
[CmdletBinding()]
param(
    # No simulated network delay.
    [switch] $Fast,
    # ASCII drawing, as for consoles that can't show the glyphs.
    [switch] $Ascii,
    [switch] $NoColor,
    [string] $OutputRoot = (Join-Path ([System.IO.Path]::GetTempPath()) 'M365BaselineCheck-demo')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'M365BaselineCheck.psd1') -Force
if ($Ascii) { $env:M365BC_ASCII = '1' }
if ($NoColor) { $env:NO_COLOR = '1' }

$keyText = & (Get-Module M365BaselineCheck) { New-MbcTeamKeyText }
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Write-Output ''
Write-Output 'M365 Baseline Check: a demo against a synthetic tenant. Nothing leaves this machine.'
Write-Output ''
Write-Output 'A throwaway team key, for trying x (export) and o (open a locked result):'
Write-Output "  $keyText"
Write-Output ''
Write-Output "Exports and logs go to $OutputRoot."
Write-Output 'Press r to run, ? for the keys on any screen, q to quit.'
Write-Output ''
if (-not [Console]::IsInputRedirected) { [void](Read-Host 'Press Enter to start') }

try {
    & (Get-Module M365BaselineCheck) {
        param($Root, $OutputRoot, $Fast)
        . (Join-Path $Root 'tools/DemoTenant.ps1')
        $seams = Initialize-MbcDemoTenant -Root $Root -Fast:$Fast
        Start-BaselineCheck -Baseline $seams.Baseline -OutputRoot $OutputRoot -Fetch $seams.Fetch -Connection $seams.Connection -Inventory $seams.Inventory
    } $root $OutputRoot $Fast
}
finally {
    Remove-Module tmpEXO_demo -Force -ErrorAction SilentlyContinue
}
