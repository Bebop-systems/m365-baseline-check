# How results are protected on the machine that runs the tool: private permissions, no cloud-synced
# output without an explicit choice, and a reminder about old plaintext. docs/handling-results.md is the
# guide for people; this file is what the tool enforces. Pure string and file-system calls only.

$script:MbcStaleDays = 30

function Set-MbcPrivateMode {
    <#
    .SYNOPSIS
        On macOS and Linux, makes a file readable and writable by its owner alone (600), or a folder
        usable by its owner alone (700). On Windows the user profile is already private to its owner,
        so this does nothing there.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [switch] $Directory)
    if ($IsWindows) { return }
    $mode = if ($Directory) { [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute' } else { [System.IO.UnixFileMode]'UserRead, UserWrite' }
    try { [System.IO.File]::SetUnixFileMode($Path, $mode) }
    catch { Write-Verbose "Couldn't restrict permissions on ${Path}: $($_.Exception.Message)" }
}

function New-MbcPrivateFile {
    <#
    .SYNOPSIS
        Writes a file holding UTF-8 text without a BOM, replacing any file there. On macOS and Linux a
        new file is created 600, so it is never readable by anyone else, even for a moment; a replaced
        one is set to 600.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [AllowEmptyString()][string] $Text = '')
    $existed = [System.IO.File]::Exists($Path)
    $options = [System.IO.FileStreamOptions]::new()
    $options.Mode = [System.IO.FileMode]::Create
    $options.Access = [System.IO.FileAccess]::Write
    if (-not $IsWindows) { $options.UnixCreateMode = [System.IO.UnixFileMode]'UserRead, UserWrite' }
    $stream = [System.IO.FileStream]::new($Path, $options)
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    if ($existed) { Set-MbcPrivateMode -Path $Path }
}

function Resolve-MbcRealPath {
    # A full path with every symbolic link along it followed, as far as the path exists.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($part in $full.Substring($root.Length).Split([char[]]@('/', '\'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        # Links are followed only while the path exists; the rest is appended as written.
        if (-not (Test-Path -LiteralPath $current)) { continue }
        $item = Get-Item -LiteralPath $current -Force
        if ($item.LinkTarget) {
            $target = $item.ResolveLinkTarget($true)
            if ($target) { $current = $target.FullName }
        }
    }
    return $current
}

function Get-MbcSyncedRoots {
    # Folders that synchronise to the cloud, as { Name; Path }, for the operating system this runs on.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string] $HomePath = $HOME)
    $roots = [System.Collections.Generic.List[object]]::new()
    $add = { param($name, $path) if ($path) { $roots.Add([pscustomobject]@{ Name = $name; Path = $path }) } }
    foreach ($v in 'OneDriveCommercial', 'OneDriveConsumer', 'OneDrive') { & $add 'OneDrive' ([Environment]::GetEnvironmentVariable($v)) }
    & $add 'iCloud Drive' (Join-Path $HomePath 'Library/Mobile Documents')
    # macOS File Provider: every OneDrive, Dropbox, Google Drive and Box folder lives under CloudStorage.
    $cloud = Join-Path $HomePath 'Library/CloudStorage'
    if (Test-Path -LiteralPath $cloud -PathType Container) {
        foreach ($d in (Get-ChildItem -LiteralPath $cloud -Directory -ErrorAction SilentlyContinue)) {
            $name = if ($d.Name.StartsWith('OneDrive', [StringComparison]::OrdinalIgnoreCase)) { 'OneDrive' }
            elseif ($d.Name.StartsWith('GoogleDrive', [StringComparison]::OrdinalIgnoreCase)) { 'Google Drive' }
            elseif ($d.Name.StartsWith('Dropbox', [StringComparison]::OrdinalIgnoreCase)) { 'Dropbox' }
            elseif ($d.Name.StartsWith('Box', [StringComparison]::OrdinalIgnoreCase)) { 'Box' }
            else { $d.Name }
            & $add $name $d.FullName
        }
        & $add 'cloud storage' $cloud
    }
    # iCloud's "Desktop & Documents Folders": when on, iCloud Drive holds Desktop and Documents folders.
    foreach ($folder in 'Desktop', 'Documents') {
        if (Test-Path -LiteralPath (Join-Path $HomePath "Library/Mobile Documents/com~apple~CloudDocs/$folder") -PathType Container) {
            & $add "iCloud Drive ($folder)" (Join-Path $HomePath $folder)
        }
    }
    foreach ($pair in @(@('Dropbox', 'Dropbox'), @('Google Drive', 'Google Drive'), @('Google Drive', 'My Drive'), @('Box', 'Box'), @('iCloud Drive', 'iCloudDrive'))) {
        $p = Join-Path $HomePath $pair[1]
        if (Test-Path -LiteralPath $p -PathType Container) { & $add $pair[0] $p }
    }
    # OneDrive's older layout, before macOS File Provider: ~/OneDrive, ~/OneDrive - Contoso.
    if (Test-Path -LiteralPath $HomePath -PathType Container) {
        foreach ($d in (Get-ChildItem -LiteralPath $HomePath -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
            # Exactly 'OneDrive' or 'OneDrive - Org'; 'OneDriveOld-archive' is someone's own folder.
            if ($d.Name -eq 'OneDrive' -or $d.Name.StartsWith('OneDrive - ', [StringComparison]::OrdinalIgnoreCase)) { & $add 'OneDrive' $d.FullName }
        }
    }
    # Google Drive for desktop mounts a drive of its own on macOS.
    if (Test-Path -LiteralPath '/Volumes/GoogleDrive' -PathType Container) { & $add 'Google Drive' '/Volumes/GoogleDrive' }
    return , $roots.ToArray()
}

function Get-MbcSyncedLocation {
    <#
    .SYNOPSIS
        The name of the cloud service a path synchronises to, such as 'OneDrive' or 'iCloud Drive', or
        $null when it isn't in a folder known to synchronise.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path, [object[]] $Roots = (Get-MbcSyncedRoots))
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $norm = { param($p) $p.TrimEnd('/', '\') + $sep }
    # Both as written and with links followed: ~/work may be a link into ~/Library/CloudStorage.
    $paths = @((& $norm ([System.IO.Path]::GetFullPath($Path))), (& $norm (Resolve-MbcRealPath -Path $Path)))
    foreach ($r in $Roots) {
        $rootForms = @((& $norm ([System.IO.Path]::GetFullPath($r.Path))), (& $norm (Resolve-MbcRealPath -Path $r.Path)))
        foreach ($full in $paths) {
            foreach ($root in $rootForms) {
                # Case-insensitive: the default file systems on Windows and macOS are.
                if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $r.Name }
            }
        }
    }
    return $null
}

function Get-MbcStalePlaintext {
    # Plaintext logs and results older than the retention reminder, as file paths. Never deletes.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string] $OutputRoot, [int] $Days = $script:MbcStaleDays)
    $cutoff = [datetime]::UtcNow.AddDays(-$Days)
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in @(@('logs', '*.jsonl'), @('results', '*.json'), @('results', '*.csv'), @('results', 'report-*.txt'))) {
        $dir = Join-Path $OutputRoot $pair[0]
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter $pair[1] -File -ErrorAction SilentlyContinue)) {
            if ($f.LastWriteTimeUtc -lt $cutoff) { $found.Add($f.FullName) }
        }
    }
    return , $found.ToArray()
}

function Get-MbcStaleNote {
    # One line for a person, or '' when there is nothing to say.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $OutputRoot)
    $stale = Get-MbcStalePlaintext -OutputRoot $OutputRoot
    if ($stale.Count -eq 0) { return '' }
    return ('{0} plaintext log or result file{1} older than {2} days {3} still in {4}. They hold tenant configuration: delete them when you no longer need them.' -f
        $stale.Count, $(if ($stale.Count -eq 1) { '' } else { 's' }), $script:MbcStaleDays, $(if ($stale.Count -eq 1) { 'is' } else { 'are' }), $OutputRoot)
}

function Get-MbcSyncedRefusal {
    # Why output can't go to a synced folder, and what to do: the text of the refusal, or '' when fine.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $OutputRoot, [switch] $Allowed)
    $service = Get-MbcSyncedLocation -Path $OutputRoot
    if (-not $service -or $Allowed) { return '' }
    return ("The output folder, $OutputRoot, synchronises to $service. Run logs are written in plaintext as a run goes, and they hold tenant configuration, " +
        'so they would be copied to the cloud. Choose a folder that stays on this machine (-OutputRoot, or the M365BC_HOME environment variable), ' +
        'or pass -AllowSyncedOutput if your policy allows it. docs/handling-results.md explains.')
}

function Get-MbcPlaintextLogNote {
    # What to tell a person about a run log that stays in plaintext on disk.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Path)
    if ($Path.Count -eq 0) { return '' }
    if ($Path.Count -eq 1) {
        return "The run log stays in plaintext at $($Path[0]). It holds tenant configuration: keep it on this machine, and delete it when you no longer need it (docs/handling-results.md)."
    }
    $folder = Split-Path -Parent $Path[0]
    return "This session's $($Path.Count) run logs stay in plaintext in $folder. They hold tenant configuration: keep them on this machine, and delete them when you no longer need them (docs/handling-results.md)."
}
