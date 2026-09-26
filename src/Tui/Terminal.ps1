# What the console can do, measured once per frame. Everything else in the TUI is pure over this.

function New-MbcCapability {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int] $Width = 80, [int] $Height = 24, [bool] $Color = $false, [bool] $Unicode = $true, [bool] $Interactive = $false)
    return [pscustomobject]@{
        PSTypeName  = 'Mbc.Capability'
        Width       = [Math]::Max(40, $Width)
        Height      = [Math]::Max(12, $Height)
        Color       = $Color
        Unicode     = $Unicode
        Interactive = $Interactive
    }
}

function Get-MbcTerminalCapability {
    <#
    .SYNOPSIS
        The console as it is now. Interactive only with a real console host, virtual terminal support and
        nothing redirected. Honours NO_COLOR, and M365BC_ASCII for consoles that can't draw the glyphs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $redirected = $true
    try { $redirected = [Console]::IsOutputRedirected -or [Console]::IsInputRedirected } catch { $redirected = $true }
    $vt = $false
    try { $vt = [bool]$Host.UI.SupportsVirtualTerminal } catch { $vt = $false }
    $width = 80
    $height = 24
    try { $width = [Console]::WindowWidth; $height = [Console]::WindowHeight } catch { Write-Verbose 'No console window; using 80x24.' }
    $interactive = (-not $redirected) -and $vt -and ($Host.Name -eq 'ConsoleHost')
    $unicode = (Test-MbcUnicodeOutput)
    # One column spare: writing the last column of a line can wrap the cursor on some consoles.
    return (New-MbcCapability -Width ($width - 1) -Height $height -Color ($interactive -and -not $env:NO_COLOR) -Unicode $unicode -Interactive $interactive)
}
