# Locking results with the team key (spec 9): HKDF-SHA256 per file, AES-256-GCM, the readable header as
# associated data. Every primitive comes from .NET. Structure is checked before any cryptography.

$script:MbcSessionKey = $null
$script:MbcLockedMembers = @('format', 'version', 'keyId', 'header', 'salt', 'nonce', 'tag', 'ciphertext')
$script:MbcBundleParts = @('result.json', 'result.csv', 'apps.csv', 'report.txt', 'summary.md')

function ConvertTo-MbcBase64Url {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]] $Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-MbcBase64Url {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][string] $Text)
    $s = $Text.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) {
        2 { $s += '==' }
        3 { $s += '=' }
        1 { throw 'Not valid base64url.' }
    }
    return , [Convert]::FromBase64String($s)
}

function Get-MbcKeyId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]] $KeyBytes)
    return (Get-MbcSha256Hex -Bytes $KeyBytes).Substring(0, 8)
}

function New-MbcTeamKeyText {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $key = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
    return 'mbc-key:1:{0}:{1}' -f (Get-MbcKeyId -KeyBytes $key), (ConvertTo-MbcBase64Url -Bytes $key)
}

function ConvertFrom-MbcTeamKeyText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Text)
    $parts = $Text.Trim().Split(':')
    $shaped = $parts.Count -eq 4 -and $parts[0] -ceq 'mbc-key' -and $parts[1] -ceq '1' -and
        (Test-MbcLowerHex -Text $parts[2] -MinLength 8 -MaxLength 8) -and $parts[3].Length -eq 43 -and
        (Test-MbcAllChars -Text $parts[3] -Letters -Digits -Also '_-')
    if (-not $shaped) { throw "That isn't a team key. It should look like mbc-key:1:<8 hex characters>:<43 characters>." }
    $bytes = ConvertFrom-MbcBase64Url -Text $parts[3]
    if ($bytes.Length -ne 32 -or (Get-MbcKeyId -KeyBytes $bytes) -cne $parts[2]) {
        throw "That key's ID doesn't match its contents; it was probably mistyped or cut short."
    }
    return [pscustomobject]@{ KeyId = $parts[2]; Bytes = $bytes }
}

function Get-MbcLockedAad {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][string] $KeyId, [Parameter(Mandatory)][System.Collections.IDictionary] $Header)
    $aad = [ordered]@{ format = 'm365bc-locked'; version = 1L; keyId = $KeyId; header = $Header }
    return , [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MbcCanonicalJson -Value $aad))
}

function Get-MbcFileKey {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][byte[]] $KeyBytes, [Parameter(Mandatory)][byte[]] $Salt)
    $info = [System.Text.Encoding]::UTF8.GetBytes('m365bc-result-v1')
    return , [System.Security.Cryptography.HKDF]::DeriveKey([System.Security.Cryptography.HashAlgorithmName]::SHA256, $KeyBytes, 32, $Salt, $info)
}

function Protect-MbcPayload {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][byte[]] $KeyBytes,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Header,
        [Parameter(Mandatory)][string] $PayloadText
    )
    $keyId = Get-MbcKeyId -KeyBytes $KeyBytes
    # Our own copy: the header is authenticated as it is now, and a caller editing theirs later must not
    # change what this envelope says.
    $Header = ConvertFrom-MbcJson -Json (ConvertTo-MbcCanonicalJson -Value $Header)
    $salt = [byte[]]::new(16)
    $nonce = [byte[]]::new(12)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($salt)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
    $plain = [System.Text.UTF8Encoding]::new($false).GetBytes($PayloadText)
    $cipher = [byte[]]::new($plain.Length)
    $tag = [byte[]]::new(16)
    $fileKey = Get-MbcFileKey -KeyBytes $KeyBytes -Salt $salt
    $aes = [System.Security.Cryptography.AesGcm]::new($fileKey, 16)
    try { $aes.Encrypt($nonce, $plain, $cipher, $tag, (Get-MbcLockedAad -KeyId $keyId -Header $Header)) }
    finally { $aes.Dispose(); [Array]::Clear($fileKey, 0, $fileKey.Length) }
    return [ordered]@{
        format     = 'm365bc-locked'
        version    = 1L
        keyId      = $keyId
        header     = $Header
        salt       = [Convert]::ToBase64String($salt)
        nonce      = [Convert]::ToBase64String($nonce)
        tag        = [Convert]::ToBase64String($tag)
        ciphertext = [Convert]::ToBase64String($cipher)
    }
}

function Test-MbcLockedShape {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object] $Envelope)
    if (-not (Test-MbcIsDictionary $Envelope)) { return 'the top level is not an object' }
    foreach ($m in $script:MbcLockedMembers) { if (-not $Envelope.Contains($m)) { return "it has no '$m'" } }
    foreach ($k in $Envelope.Keys) { if ($k -notin $script:MbcLockedMembers) { return "it has an unexpected member '$k'" } }
    if ($Envelope['format'] -cne 'm365bc-locked' -or $Envelope['version'] -ne 1L) { return 'its format or version is not one this tool writes' }
    if (-not (Test-MbcLowerHex -Text $Envelope['keyId'] -MinLength 8 -MaxLength 8)) { return 'its key ID is malformed' }
    if (-not (Test-MbcIsDictionary $Envelope['header'])) { return 'its header is not an object' }
    foreach ($pair in @(@('salt', 16), @('nonce', 12), @('tag', 16))) {
        try { $b = [Convert]::FromBase64String([string]$Envelope[$pair[0]]) } catch { return "its $($pair[0]) is not base64" }
        if ($b.Length -ne $pair[1]) { return "its $($pair[0]) is the wrong length" }
    }
    try { [void][Convert]::FromBase64String([string]$Envelope['ciphertext']) } catch { return 'its ciphertext is not base64' }
    return $null
}

function Read-MbcLockedFile {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "There's no file at '$Path'." }
    try { $envelope = ConvertFrom-MbcJson -Json ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)) }
    catch { throw "'$Path' isn't a locked result: it isn't valid JSON." }
    $problem = Test-MbcLockedShape -Envelope $envelope
    if ($problem) { throw "'$Path' isn't a locked result: $problem." }
    return $envelope
}

function Unprotect-MbcPayload {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Envelope, [Parameter(Mandatory)][byte[]] $KeyBytes)
    $problem = Test-MbcLockedShape -Envelope $Envelope
    if ($problem) { throw "This isn't a locked result: $problem." }
    $givenId = Get-MbcKeyId -KeyBytes $KeyBytes
    if ($givenId -cne $Envelope['keyId']) { throw "This file needs key $($Envelope['keyId']); the key you gave is $givenId." }
    $salt = [Convert]::FromBase64String($Envelope['salt'])
    $nonce = [Convert]::FromBase64String($Envelope['nonce'])
    $tag = [Convert]::FromBase64String($Envelope['tag'])
    $cipher = [Convert]::FromBase64String($Envelope['ciphertext'])
    $plain = [byte[]]::new($cipher.Length)
    $fileKey = Get-MbcFileKey -KeyBytes $KeyBytes -Salt $salt
    $aes = [System.Security.Cryptography.AesGcm]::new($fileKey, 16)
    # A plain catch, not a typed one: PowerShell wraps .NET method exceptions, and any failure to decrypt
    # with the right key means the same thing to the reader.
    try { $aes.Decrypt($nonce, $cipher, $tag, $plain, (Get-MbcLockedAad -KeyId $Envelope['keyId'] -Header $Envelope['header'])) }
    catch { throw "The key is right, but the file won't open: it has been altered or damaged since it was locked." }
    finally { $aes.Dispose(); [Array]::Clear($fileKey, 0, $fileKey.Length) }
    return [System.Text.UTF8Encoding]::new($false).GetString($plain)
}

function Open-MbcLockedResult {
    <#
    .SYNOPSIS
        Opens a locked result with a team key given as text, to memory. Shared by Unlock-Result and the
        TUI. One refusal for a wrong key or an altered file; never partial output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $KeyText)
    $envelope = Read-MbcLockedFile -Path $Path
    $parsed = ConvertFrom-MbcTeamKeyText -Text $KeyText
    $bundle = ConvertFrom-MbcJson -Json (Unprotect-MbcPayload -Envelope $envelope -KeyBytes $parsed.Bytes)
    $files = [ordered]@{}
    foreach ($name in $script:MbcBundleParts) {
        if (-not ((Test-MbcIsDictionary $bundle) -and $bundle.Contains($name) -and $bundle[$name] -is [string])) { throw "The file opened, but it has no $name inside. Treat it as untrustworthy." }
        $files[$name] = $bundle[$name]
    }
    $document = ConvertFrom-MbcJson -Json $files['result.json'] -AllowFloat
    if (-not (Test-MbcResultSeal -Document $document)) {
        throw 'The file opened, but the result inside does not match its own seal. Treat it as untrustworthy.'
    }
    return [pscustomobject]@{
        PSTypeName = 'Mbc.UnlockedResult'
        KeyId      = $envelope['keyId']
        Header     = $envelope['header']
        Files      = $files
        Document   = $document
        View       = ConvertFrom-MbcResultDocument -Document $document
    }
}

function ConvertFrom-MbcSecureKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][securestring] $Key)
    return [System.Net.NetworkCredential]::new('', $Key).Password
}

function Get-MbcBundle {
    # The five parts of an export, as text, from one result document.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Document)
    $view = ConvertFrom-MbcResultDocument -Document $Document
    return [ordered]@{
        'result.json' = ConvertTo-MbcPrettyJson -Value $Document
        'result.csv'  = ConvertTo-MbcResultCsv -Document $Document
        'apps.csv'    = ConvertTo-MbcAppsCsv -Document $Document
        'report.txt'  = ConvertTo-MbcTextReport -View $view
        'summary.md'  = ConvertTo-MbcSummaryMarkdown -View $view
    }
}

function Get-MbcBundleFileName {
    # result.json -> result-<stamp>.json; the stamp keeps runs apart in one folder.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Part, [Parameter(Mandatory)][string] $Stamp)
    $dot = $Part.LastIndexOf('.')
    return '{0}-{1}{2}' -f $Part.Substring(0, $dot), $Stamp, $Part.Substring($dot)
}

function Export-MbcRunFiles {
    <#
    .SYNOPSIS
        Writes an export: by default one locked bundle plus summary.md in plain text. -NoLock writes the
        five parts unencrypted instead; -LockSummary keeps the summary inside the bundle only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)][string] $Directory,
        [string] $KeyText,
        [switch] $NoLock,
        [switch] $LockSummary
    )
    if (-not $KeyText -and -not $NoLock) { throw 'Exports are locked with the team key. Give the key, or use -NoLock to write plaintext.' }
    $stamp = Get-MbcRunStamp -RunId ([string]$Document['run']['id'])
    $parts = Get-MbcBundle -Document $Document
    $files = [pscustomobject]@{ Locked = $null; Summary = $null; Json = $null; Csv = $null; Apps = $null; Report = $null }
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }

    if ($NoLock) {
        $map = @{ 'result.json' = 'Json'; 'result.csv' = 'Csv'; 'apps.csv' = 'Apps'; 'report.txt' = 'Report'; 'summary.md' = 'Summary' }
        foreach ($name in $parts.Keys) {
            $path = Join-Path $Directory (Get-MbcBundleFileName -Part $name -Stamp $stamp)
            Write-MbcFileAtomic -Path $path -Text $parts[$name]
            $files.($map[$name]) = $path
        }
        return $files
    }

    $key = ConvertFrom-MbcTeamKeyText -Text $KeyText
    $b = $Document['baseline']
    $header = [ordered]@{
        baseline = [ordered]@{ name = [string]$b['name']; version = [long]$b['version']; fingerprint = [string]$b['fingerprint'] }
        runUtc   = [string]$Document['run']['startedUtc']
        tool     = $script:MbcToolVersion
    }
    $envelope = Protect-MbcPayload -KeyBytes $key.Bytes -Header $header -PayloadText (ConvertTo-MbcCanonicalJson -Value $parts)
    $files.Locked = Join-Path $Directory "result-$stamp.locked"
    Write-MbcFileAtomic -Path $files.Locked -Text (ConvertTo-MbcPrettyJson -Value $envelope)
    if (-not $LockSummary) {
        $files.Summary = Join-Path $Directory (Get-MbcBundleFileName -Part 'summary.md' -Stamp $stamp)
        Write-MbcFileAtomic -Path $files.Summary -Text $parts['summary.md']
    }
    return $files
}
