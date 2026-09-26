# summary.md: a digest safe to paste into an AI session (spec 10.4). Redaction is by construction: the
# Markdown is built only from Get-MbcSummarySource, which copies baseline text, verdicts, causes from
# the closed vocabulary, and third-party app names, publishers and permission names. Nothing else from
# the tenant can reach it: no IDs, domains, account names, own-registration names or actual values.

function Get-MbcSummarySource {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $View)
    $checks = @(foreach ($r in $View.Results) {
            $cause = [string]$r.Cause
            if ($r.Verdict -eq 'Error' -and $cause -notin $script:MbcCauses) { $cause = 'unknown cause' }
            [pscustomobject]@{ Id = $r.Id; Title = $r.Title; Area = $r.Area; Location = $r.Location; Severity = $r.Severity; Verdict = $r.Verdict; Cause = $cause }
        })
    $apps = @(foreach ($a in @($View.Inventory.ThirdParty)) {
            [pscustomobject]@{
                Name        = $a.DisplayName
                Publisher   = $a.Publisher
                Verified    = [bool]$a.Verified
                Admin       = [string[]]@($a.Delegated | Where-Object Type -eq 'admin' | ForEach-Object { $_.Scopes })
                User        = [string[]]@($a.Delegated | Where-Object Type -eq 'user' | ForEach-Object { $_.Scopes })
                Users       = [int](@($a.Delegated | Where-Object Type -eq 'user' | ForEach-Object { [int]$_.Users } | Measure-Object -Maximum).Maximum)
                Application = [string[]]@($a.Application | ForEach-Object { $_.Roles })
            }
        })
    $failures = @($View.Inventory.Failures | Where-Object { $_.StartsWith("Couldn't read ") })
    return [pscustomobject]@{
        Baseline           = [pscustomobject]@{ Name = $View.Baseline.Name; Version = $View.Baseline.Version; Fingerprint = $View.Baseline.Fingerprint; Digest = $View.Baseline.Digest; Sealed = ($View.Baseline.SealState -eq 'Sealed') }
        RunDate            = if ([string]$View.StartedUtc -and ([string]$View.StartedUtc).Length -ge 10) { ([string]$View.StartedUtc).Substring(0, 10) } else { '' }
        Checks             = $checks
        InventoryCollected = [bool]$View.Inventory.Collected
        ThirdParty         = $apps
        OwnCount           = @($View.Inventory.Own).Count
        InventoryFailures  = $failures
    }
}

function ConvertTo-MbcMarkdownCell {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string] $Text)
    return ([string]$Text).Replace('\', '\\').Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function ConvertTo-MbcYamlString {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string] $Text)
    return '"' + ([string]$Text).Replace('\', '\\').Replace('"', '\"').Replace("`n", ' ') + '"'
}

function ConvertTo-MbcSummaryMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $View)
    $s = Get-MbcSummarySource -View $View
    $groups = Get-MbcAreaGroups -Results $s.Checks
    $sb = [System.Text.StringBuilder]::new()
    $line = { param($text) [void]$sb.Append($text).Append("`n") }

    & $line '---'
    & $line "baseline: $(ConvertTo-MbcYamlString $s.Baseline.Name)"
    & $line "version: $($s.Baseline.Version)"
    & $line "fingerprint: $($s.Baseline.Fingerprint)"
    & $line "digest: $($s.Baseline.Digest)"
    & $line "sealed: $(if ($s.Baseline.Sealed) { 'true' } else { 'false' })"
    & $line "run: $($s.RunDate)"
    & $line 'counts:'
    foreach ($g in $groups) { & $line "  $($g.Area): { met: $($g.Met), notMet: $($g.NotMet), unverifiable: $($g.Unverifiable) }" }
    & $line '---'
    & $line ''
    & $line "# $(ConvertTo-MbcMarkdownCell $s.Baseline.Name) v$($s.Baseline.Version)"
    & $line ''
    $seal = if ($s.Baseline.Sealed) { '' } else { ' **UNSEALED**: the baseline was not sealed when this ran.' }
    & $line "Checked against fingerprint ``$($s.Baseline.Fingerprint)``, digest ``$($s.Baseline.Digest)``.$seal Tenant values are left out of this summary by design."
    foreach ($g in $groups) {
        & $line ''
        & $line "## $($g.Name)"
        & $line ''
        & $line '| ID | Setting | Location | Status | Severity |'
        & $line '|---|---|---|---|---|'
        foreach ($c in $g.Results) {
            $status = switch ($c.Verdict) { 'Pass' { 'Met' } 'Fail' { 'Not met' } default { "Couldn't verify: $($c.Cause)" } }
            & $line "| $(ConvertTo-MbcMarkdownCell $c.Id) | $(ConvertTo-MbcMarkdownCell $c.Title) | $(ConvertTo-MbcMarkdownCell $c.Location) | $status | $($c.Severity) |"
        }
    }
    & $line ''
    & $line '## Third-party apps'
    & $line ''
    if (-not $s.InventoryCollected) { & $line 'The app inventory was left out of this run.' }
    elseif ($s.ThirdParty.Count -eq 0) { & $line 'None.' }
    else {
        & $line '| App | Publisher | Verified | Delegated, admin consent | Delegated, user consent | Application |'
        & $line '|---|---|---|---|---|---|'
        foreach ($a in $s.ThirdParty) {
            $user = if ($a.User.Count) { (($a.User | Sort-Object -Unique) -join ', ') + " ($($a.Users) $(if ($a.Users -eq 1) { 'user' } else { 'users' }))" } else { '' }
            & $line ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f (ConvertTo-MbcMarkdownCell $a.Name), (ConvertTo-MbcMarkdownCell $a.Publisher), $(if ($a.Verified) { 'yes' } else { 'no' }),
                (ConvertTo-MbcMarkdownCell (($a.Admin | Sort-Object -Unique) -join ', ')), (ConvertTo-MbcMarkdownCell $user), (ConvertTo-MbcMarkdownCell (($a.Application | Sort-Object -Unique) -join ', ')))
        }
    }
    if ($s.InventoryCollected) {
        & $line ''
        & $line '## This tenant''s own registrations'
        & $line ''
        & $line "$($s.OwnCount) app registration$(if ($s.OwnCount -eq 1) { '' } else { 's' }). Their names are left out: they can identify an organisation."
        foreach ($f in $s.InventoryFailures) { & $line ''; & $line "Note: $(ConvertTo-MbcMarkdownCell $f)." }
    }
    return $sb.ToString()
}
