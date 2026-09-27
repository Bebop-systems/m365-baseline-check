# The client modules this tool runs inside, pinned. They hold an administrator's token while they run,
# so only release versions inside a tested range are loaded, and on Windows only when the files that
# load first carry a valid Microsoft signature: the manifest, the root module and the assemblies it
# imports (Files, below; a missing one means an untested layout). The rest of the module folder isn't
# checked: it holds third-party and reference assemblies that aren't Microsoft-signed. The module is
# imported from the manifest that was checked. The signer check is by name (subject and issuer), so a
# machine whose own trusted CA mints a "Microsoft" certificate can defeat it; such a machine is already
# lost. Raising a range means a live run on the new version first; CLAUDE.md, "Module load order".

$script:MbcDependencies = [ordered]@{
    'Microsoft.Graph.Authentication' = [pscustomobject]@{
        Minimum = [version]'2.38.1'; Below = [version]'3.0'; Tested = [version]'2.38.1'; PowerShell = [version]'7.4'
        Files = @('Microsoft.Graph.Authentication.psd1', 'Microsoft.Graph.Authentication.psm1', 'Microsoft.Graph.Authentication.dll', 'Microsoft.Graph.Authentication.Core.dll')
    }
    # 3.10.0's release notes: "the minimum required version of PowerShell 7 is now 7.6".
    'ExchangeOnlineManagement'       = [pscustomobject]@{
        Minimum = [version]'3.10.0'; Below = [version]'4.0'; Tested = [version]'3.10.0'; PowerShell = [version]'7.6'
        Files = @('ExchangeOnlineManagement.psd1', 'netCore/ExchangeOnlineManagement.psm1', 'netCore/Microsoft.Exchange.Management.RestApiClient.dll', 'netCore/Microsoft.Exchange.Management.ExoPowershellGalleryModule.dll')
    }
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

function Test-MbcSignatureCheckable {
    # Get-AuthenticodeSignature exists on Windows only.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]$IsWindows
}

function Get-MbcModuleSignature {
    # The Authenticode signature on a file as { Status; Message; Signer; Issuer }. Windows only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $cert = $sig.SignerCertificate
    return [pscustomobject]@{
        Status = [string]$sig.Status; Message = [string]$sig.StatusMessage
        Signer = if ($cert) { [string]$cert.Subject } else { '' }; Issuer = if ($cert) { [string]$cert.Issuer } else { '' }
    }
}

function Test-MbcMicrosoftSignature {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Signature)
    return ($Signature.Status -eq 'Valid' -and
        $Signature.Signer.StartsWith('CN=Microsoft Corporation,', [StringComparison]::Ordinal) -and
        $Signature.Issuer.StartsWith('CN=Microsoft Code Signing PCA', [StringComparison]::Ordinal))
}

function Get-MbcPrerelease {
    # A module's prerelease label ('preview1'), or '' for a release. [version] drops the label.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Module)
    if (-not $Module.PSObject.Properties['PrivateData'] -or $Module.PrivateData -isnot [System.Collections.IDictionary]) { return '' }
    $psData = $Module.PrivateData['PSData']
    if ($psData -isnot [System.Collections.IDictionary]) { return '' }
    return [string]$psData['Prerelease']
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
    $inRange = { param($m) $m.Version -ge $range.Minimum -and $m.Version -lt $range.Below -and -not (Get-MbcPrerelease -Module $m) }
    if ($PSVersionTable.PSVersion -lt $range.PowerShell) {
        throw "$Name $($range.Minimum) needs PowerShell $($range.PowerShell) or later, and this is $($PSVersionTable.PSVersion). Update PowerShell to use checks that need it."
    }

    $loaded = Get-MbcLoadedModule -Name $Name
    if ($loaded) {
        if (-not (& $inRange $loaded)) {
            $label = "$($loaded.Version)$(if (Get-MbcPrerelease -Module $loaded) { "-$(Get-MbcPrerelease -Module $loaded)" })"
            throw "$Name $label is already loaded in this PowerShell session, and this tool runs only with release versions $rangeText. A profile usually loads it: start pwsh -NoProfile. If that version is what's installed, $(Get-MbcInstallHint -Name $Name)."
        }
        $chosen = $loaded
    }
    else {
        $installed = Get-MbcInstalledModules -Name $Name
        $chosen = $installed | Where-Object { & $inRange $_ } | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $chosen) {
            $found = if ($installed.Count) { "Installed: $(@($installed | ForEach-Object { [string]$_.Version } | Sort-Object -Unique) -join ', ')." } else { "It isn't installed." }
            throw "This tool runs with release versions of $Name $rangeText. $found $(Get-MbcInstallHint -Name $Name)."
        }
    }

    $checkable = Test-MbcSignatureCheckable
    foreach ($f in $range.Files) {
        $path = Join-Path $chosen.ModuleBase $f
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$Name $($chosen.Version) in $($chosen.ModuleBase) has no $f, so its layout isn't the one this tool was tested with. Reinstall it: $(Get-MbcInstallHint -Name $Name) -Force."
        }
        if (-not $checkable) { continue }
        $sig = Get-MbcModuleSignature -Path $path
        if (-not (Test-MbcMicrosoftSignature -Signature $sig)) {
            $why = if ($sig.Status -eq 'Valid') { "signed by $($sig.Signer), issued by $($sig.Issuer)" } else { "signature $($sig.Status): $($sig.Message)" }
            throw "$Name $($chosen.Version): $f isn't validly signed by Microsoft ($why). The module holds an administrator's token while it runs, so it isn't loaded. If this machine is offline, the signature may not be verifiable; connect and try again. Otherwise reinstall it: $(Get-MbcInstallHint -Name $Name) -Force."
        }
    }
    $signature = if ($checkable) { 'Microsoft' } else { 'unchecked' }
    return [pscustomobject]@{
        Name          = $Name
        Version       = $chosen.Version
        Manifest      = Join-Path $chosen.ModuleBase "$Name.psd1"
        AlreadyLoaded = [bool]$loaded
        Signature     = $signature
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
    $signed = if (@($Loaded | Where-Object Signature -eq 'unchecked').Count) { "signatures can't be checked on this platform" } else { 'manifest, root module and core assemblies validly signed by Microsoft' }
    return "Client modules: $(@($names) -join ', '); $signed."
}
