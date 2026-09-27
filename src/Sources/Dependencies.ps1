# The client modules this tool runs inside, pinned. They hold an administrator's token while they run,
# so only versions inside a tested range are loaded, and on Windows only when Microsoft's signature on
# them is valid. The module is imported from the path that was checked, so what was checked is what
# runs. Raising a range means a live run on the new version first; CLAUDE.md, "Module load order".

$script:MbcDependencies = [ordered]@{
    'Microsoft.Graph.Authentication' = [pscustomobject]@{ Minimum = [version]'2.38.1'; Below = [version]'3.0'; Tested = [version]'2.38.1' }
    'ExchangeOnlineManagement'       = [pscustomobject]@{ Minimum = [version]'3.10.0'; Below = [version]'4.0'; Tested = [version]'3.10.0' }
}
# What this sign-in loaded, by name, for the disclosure.
$script:MbcLoadedDependencies = [ordered]@{}

function Get-MbcInstalledModules {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string] $Name)
    return , @(Get-Module -ListAvailable -Name $Name)
}

function Get-MbcLoadedModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name)
    return (Get-Module -Name $Name | Select-Object -First 1)
}

function Get-MbcModuleSignature {
    # The Authenticode signature on a file as { Status; Signer }, or $null where it can't be checked:
    # Get-AuthenticodeSignature exists on Windows only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    if (-not $IsWindows) { return $null }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $signer = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
    return [pscustomobject]@{ Status = [string]$sig.Status; Signer = $signer }
}

function Get-MbcInstallHint {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Name)
    return "Install-Module $Name -RequiredVersion $($script:MbcDependencies[$Name].Tested) -Scope CurrentUser"
}

function Resolve-MbcDependency {
    <#
    .SYNOPSIS
        The installed version of a client module to load: the highest inside its tested range, validly
        signed by Microsoft where signatures can be checked. Throws with what to do when there is none.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Name)
    $range = $script:MbcDependencies[$Name]
    $rangeText = "$($range.Minimum) or later, below $($range.Below)"
    $inRange = { param($v) $v -ge $range.Minimum -and $v -lt $range.Below }

    $loaded = Get-MbcLoadedModule -Name $Name
    if ($loaded) {
        if (-not (& $inRange $loaded.Version)) {
            throw "$Name $($loaded.Version) is already loaded in this PowerShell session, and this tool runs only with $rangeText. Start a fresh pwsh; if that version is what's installed, $(Get-MbcInstallHint -Name $Name)."
        }
        $chosen = $loaded
    }
    else {
        $installed = Get-MbcInstalledModules -Name $Name
        $chosen = $installed | Where-Object { & $inRange $_.Version } | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $chosen) {
            $found = if ($installed.Count) { "Installed: $(@($installed | ForEach-Object { [string]$_.Version } | Sort-Object -Unique) -join ', ')." } else { "It isn't installed." }
            throw "This tool runs with $Name $rangeText. $found $(Get-MbcInstallHint -Name $Name)."
        }
    }

    $manifest = Join-Path $chosen.ModuleBase "$Name.psd1"
    $sig = Get-MbcModuleSignature -Path $manifest
    if ($sig -and ($sig.Status -ne 'Valid' -or -not $sig.Signer.StartsWith('CN=Microsoft Corporation,', [StringComparison]::Ordinal))) {
        throw "$Name $($chosen.Version) in $($chosen.ModuleBase) isn't validly signed by Microsoft (signature: $($sig.Status)). It holds an administrator's token while it runs, so it isn't loaded. Reinstall it: $(Get-MbcInstallHint -Name $Name) -Force."
    }
    return [pscustomobject]@{
        Name          = $Name
        Version       = $chosen.Version
        Manifest      = $manifest
        AlreadyLoaded = [bool]$loaded
        Signature     = if ($sig) { 'Microsoft' } else { 'unchecked' }
        NewerThanTest = $chosen.Version -gt $range.Tested
    }
}

function Format-MbcDependencyLine {
    # One disclosure line for the loaded client modules, or '' when none were recorded.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Loaded)
    if ($Loaded.Count -eq 0) { return '' }
    $names = foreach ($d in $Loaded) {
        $tested = $script:MbcDependencies[$d.Name].Tested
        if ($d.NewerThanTest) { "$($d.Name) $($d.Version) (newer than the tested $tested)" } else { "$($d.Name) $($d.Version)" }
    }
    $signed = if (@($Loaded | Where-Object Signature -eq 'unchecked').Count) { "signatures can't be checked on this platform" } else { "each validly signed by Microsoft" }
    return "Client modules: $(@($names) -join ', '); $signed."
}
