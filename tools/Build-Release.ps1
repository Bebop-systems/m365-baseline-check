<#
.SYNOPSIS
    Builds a release: the module folder, zipped, with SHA-256 checksums. Signs every script file first
    when given a code-signing certificate.
.DESCRIPTION
    Stages only what the module needs to run and be understood (the manifest, src/, the example
    presets, the licence and the operator docs) into out/release/M365BaselineCheck, then writes
    out/release/M365BaselineCheck-<version>.zip and out/release/SHA256SUMS.txt.

    With -Certificate, every .ps1, .psm1 and .psd1 in the staged copy is Authenticode-signed with
    SHA-256 and a timestamp, and each signature is checked before the zip is made. Without it the
    release is unsigned; the checksums and the build attestation from CI still identify it.

    -Tag, when given (as CI does), must equal v<ModuleVersion>.
.EXAMPLE
    pwsh -NoProfile -File tools/Build-Release.ps1
.EXAMPLE
    pwsh -NoProfile -File tools/Build-Release.ps1 -Certificate (Get-Item Cert:\CurrentUser\My\<thumbprint>)
#>
[CmdletBinding()]
param(
    [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
    [string] $TimestampServer = 'http://timestamp.digicert.com',
    [string] $Tag
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = [string](Import-PowerShellDataFile (Join-Path $root 'M365BaselineCheck.psd1')).ModuleVersion
if ($Tag -and $Tag -cne "v$version") { throw "The tag $Tag doesn't match the manifest's version, $version. Raise ModuleVersion or fix the tag." }

$out = Join-Path $root 'out/release'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
$stage = Join-Path $out 'M365BaselineCheck'
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# Only tracked files, so nothing local (a baseline, a result, a scratch file) can slip into a release.
$include = @('M365BaselineCheck.psd1', 'M365BaselineCheck.psm1', 'LICENSE', 'README.md', 'CLAUDE.md', 'src/', 'presets/', 'docs/handling-results.md', 'docs/removing-consent.md')
Push-Location $root
try { $tracked = @(git ls-files) }
finally { Pop-Location }
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) { throw 'git ls-files failed; build from a clone of the repository.' }
$files = @($tracked | Where-Object { $f = $_; @($include | Where-Object { $f -eq $_ -or ($_.EndsWith('/') -and $f.StartsWith($_)) }).Count })
foreach ($f in $files) {
    $target = Join-Path $stage $f
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $f) -Destination $target
}

if ($Certificate) {
    if (-not $Certificate.HasPrivateKey) { throw 'The certificate has no private key, so it cannot sign.' }
    $scripts = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')
    $signing = @{ Certificate = $Certificate; HashAlgorithm = 'SHA256' }
    # The timestamp keeps a signature valid after the certificate expires.
    if ($TimestampServer) { $signing.TimestampServer = $TimestampServer }
    foreach ($s in $scripts) {
        $r = Set-AuthenticodeSignature -FilePath $s.FullName @signing
        if ($r.Status -ne 'Valid') { throw "Signing $($s.Name) gave $($r.Status): $($r.StatusMessage)" }
    }
    Write-Information "Signed $($scripts.Count) files as $($Certificate.Subject)." -InformationAction Continue
}
else {
    Write-Information 'No certificate given: the release is unsigned.' -InformationAction Continue
}

$zip = Join-Path $out "M365BaselineCheck-$version.zip"
Compress-Archive -Path $stage -DestinationPath $zip
$sums = foreach ($f in @($zip)) { '{0}  {1}' -f (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path -Leaf $f) }
[System.IO.File]::WriteAllText((Join-Path $out 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Information "Built $zip ($($files.Count) files)." -InformationAction Continue
$sums | ForEach-Object { Write-Information $_ -InformationAction Continue }
