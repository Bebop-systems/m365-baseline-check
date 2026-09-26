$script:MbcOperators = @(
    'equals', 'notEquals', 'in', 'contains', 'setEquals', 'subsetOf',
    'countAtLeast', 'countAtMost', 'matches', 'exists', 'absent'
)

function New-MbcComparison {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Error')][string] $Verdict, [AllowNull()][string] $Cause)
    return [pscustomobject]@{ Verdict = $Verdict; Cause = $Cause }
}

function Test-MbcMemberEqual {
    # Structural equality, recursive, honouring the same case rule at every scalar it reaches.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Left, [AllowNull()][object] $Right, [bool] $CaseSensitive)
    if ((Test-MbcIsScalar $Left) -and (Test-MbcIsScalar $Right)) {
        return (Test-MbcScalarEqual -Left $Left -Right $Right -CaseSensitive $CaseSensitive)
    }
    if ((Test-MbcIsScalar $Left) -or (Test-MbcIsScalar $Right)) { return $false }
    if ((Test-MbcIsList $Left) -and (Test-MbcIsList $Right)) {
        if ($Left.Count -ne $Right.Count) { return $false }
        for ($i = 0; $i -lt $Left.Count; $i++) {
            if (-not (Test-MbcMemberEqual -Left $Left[$i] -Right $Right[$i] -CaseSensitive $CaseSensitive)) { return $false }
        }
        return $true
    }
    if ((Test-MbcIsList $Left) -or (Test-MbcIsList $Right)) { return $false }
    if ((Test-MbcIsDictionary $Left) -and (Test-MbcIsDictionary $Right)) {
        if ($Left.Count -ne $Right.Count) { return $false }
        # Keys are case-insensitive dictionaries already, so .Contains() needs no case handling here.
        foreach ($key in $Left.Keys) {
            if (-not $Right.Contains($key)) { return $false }
            if (-not (Test-MbcMemberEqual -Left $Left[$key] -Right $Right[$key] -CaseSensitive $CaseSensitive)) { return $false }
        }
        return $true
    }
    return $false
}

function Test-MbcSubset {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Items, [AllowNull()][object] $Of, [bool] $CaseSensitive)
    foreach ($item in @($Items)) {
        $found = $false
        foreach ($candidate in @($Of)) {
            if (Test-MbcMemberEqual -Left $item -Right $candidate -CaseSensitive $CaseSensitive) { $found = $true; break }
        }
        if (-not $found) { return $false }
    }
    return $true
}

function Compare-MbcValue {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][object] $Actual,
        [Parameter(Mandatory)][string] $Operator,
        [AllowNull()][object] $Expected,
        [switch] $CaseSensitive
    )
    $cs = [bool]$CaseSensitive
    $pass = New-MbcComparison -Verdict 'Pass' -Cause $null
    $fail = New-MbcComparison -Verdict 'Fail' -Cause $null
    $wantList = New-MbcComparison -Verdict 'Error' -Cause 'baseline expects a list'
    $wantScalar = New-MbcComparison -Verdict 'Error' -Cause 'baseline expects a single value'

    if ($Operator -eq 'exists') { if (Test-MbcNotFound $Actual) { return $fail } else { return $pass } }
    if ($Operator -eq 'absent') { if (Test-MbcNotFound $Actual) { return $pass } else { return $fail } }
    if (Test-MbcNotFound $Actual) { return (New-MbcComparison -Verdict 'Error' -Cause 'setting not found') }

    if ($Operator -in 'equals', 'notEquals') {
        $actualScalar = Test-MbcIsScalar $Actual
        $expectedScalar = Test-MbcIsScalar $Expected
        if ($actualScalar -ne $expectedScalar) { if ($expectedScalar) { return $wantScalar } else { return $wantList } }
        $equal = Test-MbcMemberEqual -Left $Actual -Right $Expected -CaseSensitive $cs
        if (($Operator -eq 'equals') -eq $equal) { return $pass }
        return $fail
    }
    if ($Operator -eq 'in') {
        if (-not (Test-MbcIsScalar $Actual)) { return $wantScalar }
        foreach ($e in @($Expected)) { if (Test-MbcScalarEqual -Left $Actual -Right $e -CaseSensitive $cs) { return $pass } }
        return $fail
    }
    if ($Operator -eq 'contains') {
        if (-not (Test-MbcIsList $Actual)) { return $wantList }
        foreach ($a in $Actual) { if (Test-MbcMemberEqual -Left $a -Right $Expected -CaseSensitive $cs) { return $pass } }
        return $fail
    }
    if ($Operator -eq 'setEquals') {
        if (-not (Test-MbcIsList $Actual)) { return $wantList }
        if ((Test-MbcSubset -Items $Actual -Of $Expected -CaseSensitive $cs) -and (Test-MbcSubset -Items $Expected -Of $Actual -CaseSensitive $cs)) { return $pass }
        return $fail
    }
    if ($Operator -eq 'subsetOf') {
        if (-not (Test-MbcIsList $Actual)) { return $wantList }
        if (Test-MbcSubset -Items $Actual -Of $Expected -CaseSensitive $cs) { return $pass }
        return $fail
    }
    if ($Operator -in 'countAtLeast', 'countAtMost') {
        if (-not (Test-MbcIsList $Actual)) { return $wantList }
        $ok = if ($Operator -eq 'countAtLeast') { $Actual.Count -ge [long]$Expected } else { $Actual.Count -le [long]$Expected }
        if ($ok) { return $pass }
        return $fail
    }
    if ($Operator -eq 'matches') {
        if ($Actual -isnot [string]) { return $wantScalar }
        $options = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        if (-not $cs) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
        try { $regex = [regex]::new([string]$Expected, $options, [TimeSpan]::FromSeconds(1)) }
        catch { return (New-MbcComparison -Verdict 'Error' -Cause 'invalid pattern') }
        try {
            if ($regex.IsMatch($Actual)) { return $pass }
            return $fail
        }
        catch {
            # IsMatch can only fail by timing out; a typed catch would depend on PowerShell unwrapping it.
            return (New-MbcComparison -Verdict 'Error' -Cause 'pattern too slow')
        }
    }
    throw "Unknown operator '$Operator'."
}
