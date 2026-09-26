function ConvertFrom-MbcJson {
    <#
    .SYNOPSIS
        Parses JSON strictly: ordered dictionaries, whole numbers only unless -AllowFloat, no duplicate keys.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Json,
        [switch] $AllowFloat
    )
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 64
    try {
        $doc = [System.Text.Json.JsonDocument]::Parse($Json, $options)
    }
    catch {
        $inner = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        throw "Not valid JSON: $inner"
    }
    try {
        return , (ConvertFrom-MbcJsonElement -Element $doc.RootElement -Path '$' -AllowFloat:$AllowFloat)
    }
    finally {
        $doc.Dispose()
    }
}

function ConvertFrom-MbcJsonElement {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)][string] $Path,
        [switch] $AllowFloat
    )
    switch ($Element.ValueKind) {
        'Object' {
            $map = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                if ($map.Contains($property.Name)) {
                    $existing = @($map.Keys) | Where-Object { $_ -ieq $property.Name } | Select-Object -First 1
                    if ($existing -cne $property.Name) {
                        throw "Keys '$existing' and '$($property.Name)' at $Path differ only in letter case; baselines and responses may not hold both."
                    }
                    throw "Duplicate key '$($property.Name)' at $Path."
                }
                $map[$property.Name] = ConvertFrom-MbcJsonElement -Element $property.Value -Path "$Path.$($property.Name)" -AllowFloat:$AllowFloat
            }
            return $map
        }
        'Array' {
            $list = [System.Collections.Generic.List[object]]::new()
            $i = 0
            foreach ($item in $Element.EnumerateArray()) {
                $list.Add((ConvertFrom-MbcJsonElement -Element $item -Path "$Path[$i]" -AllowFloat:$AllowFloat))
                $i++
            }
            return , $list.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            $whole = 0L
            if ($Element.TryGetInt64([ref]$whole)) { return $whole }
            if ($AllowFloat) { return $Element.GetDouble() }
            throw "Only whole numbers are allowed; found $($Element.GetRawText()) at $Path."
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
    }
    throw "Unsupported JSON value at $Path."
}

function ConvertTo-MbcJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $sb = [System.Text.StringBuilder]::new($Text.Length + 2)
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 0x22) { [void]$sb.Append('\"') }
        elseif ($code -eq 0x5C) { [void]$sb.Append('\\') }
        elseif ($code -eq 0x08) { [void]$sb.Append('\b') }
        elseif ($code -eq 0x0C) { [void]$sb.Append('\f') }
        elseif ($code -eq 0x0A) { [void]$sb.Append('\n') }
        elseif ($code -eq 0x0D) { [void]$sb.Append('\r') }
        elseif ($code -eq 0x09) { [void]$sb.Append('\t') }
        elseif ($code -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-MbcObjectMember {
    # A dictionary or PSCustomObject as an ordered list of name/value pairs.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][object] $Value)
    $pairs = [System.Collections.Generic.List[object]]::new()
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) {
            if ($k -isnot [string]) { throw "Object keys must be strings; found a $($k.GetType().Name)." }
            $pairs.Add([pscustomobject]@{ Name = $k; Value = $Value[$k] })
        }
    }
    else {
        foreach ($p in $Value.PSObject.Properties) { $pairs.Add([pscustomobject]@{ Name = $p.Name; Value = $p.Value }) }
    }
    return , $pairs.ToArray()
}

function Add-MbcCanonical {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder] $Builder,
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Path
    )
    if ($null -eq $Value) { [void]$Builder.Append('null'); return }
    if ($Value -is [bool]) { [void]$Builder.Append($(if ($Value) { 'true' } else { 'false' })); return }
    if ($Value -is [string]) { [void]$Builder.Append((ConvertTo-MbcJsonString -Text $Value)); return }
    if (Test-MbcIsWholeNumberType $Value) { [void]$Builder.Append($Value.ToString([cultureinfo]::InvariantCulture)); return }
    if ($Value -is [double] -or $Value -is [single]) {
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { throw "Cannot canonicalise NaN or infinity at $Path." }
        [void]$Builder.Append(([double]$Value).ToString('R', [cultureinfo]::InvariantCulture)); return
    }
    if ($Value -is [decimal]) { [void]$Builder.Append($Value.ToString([cultureinfo]::InvariantCulture)); return }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = Get-MbcObjectMember -Value $Value
        $names = [string[]]@($pairs | ForEach-Object { $_.Name })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        [void]$Builder.Append('{')
        $first = $true
        foreach ($name in $names) {
            if (-not $first) { [void]$Builder.Append(',') }
            $first = $false
            $item = $pairs | Where-Object { $_.Name -ceq $name } | Select-Object -First 1
            [void]$Builder.Append((ConvertTo-MbcJsonString -Text $name)).Append(':')
            Add-MbcCanonical -Builder $Builder -Value $item.Value -Path "$Path.$name"
        }
        [void]$Builder.Append('}')
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        [void]$Builder.Append('[')
        $first = $true
        $i = 0
        foreach ($item in $Value) {
            if (-not $first) { [void]$Builder.Append(',') }
            $first = $false
            Add-MbcCanonical -Builder $Builder -Value $item -Path "$Path[$i]"
            $i++
        }
        [void]$Builder.Append(']')
        return
    }
    throw "Cannot canonicalise a value of type $($Value.GetType().FullName) at $Path."
}

function ConvertTo-MbcCanonicalJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    $sb = [System.Text.StringBuilder]::new()
    Add-MbcCanonical -Builder $sb -Value $Value -Path '$'
    return $sb.ToString()
}

function Add-MbcPretty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder] $Builder,
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][int] $Indent
    )
    $pad = '  ' * $Indent
    $inner = '  ' * ($Indent + 1)
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = Get-MbcObjectMember -Value $Value
        if ($pairs.Count -eq 0) { [void]$Builder.Append('{}'); return }
        [void]$Builder.Append("{`n")
        for ($i = 0; $i -lt $pairs.Count; $i++) {
            [void]$Builder.Append($inner).Append((ConvertTo-MbcJsonString -Text $pairs[$i].Name)).Append(': ')
            Add-MbcPretty -Builder $Builder -Value $pairs[$i].Value -Indent ($Indent + 1)
            if ($i -lt $pairs.Count - 1) { [void]$Builder.Append(',') }
            [void]$Builder.Append("`n")
        }
        [void]$Builder.Append($pad).Append('}')
        return
    }
    if ($Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { [void]$Builder.Append('[]'); return }
        [void]$Builder.Append("[`n")
        for ($i = 0; $i -lt $items.Count; $i++) {
            [void]$Builder.Append($inner)
            Add-MbcPretty -Builder $Builder -Value $items[$i] -Indent ($Indent + 1)
            if ($i -lt $items.Count - 1) { [void]$Builder.Append(',') }
            [void]$Builder.Append("`n")
        }
        [void]$Builder.Append($pad).Append(']')
        return
    }
    Add-MbcCanonical -Builder $Builder -Value $Value -Path '$'
}

function ConvertTo-MbcPrettyJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][object] $Value)
    $sb = [System.Text.StringBuilder]::new()
    Add-MbcPretty -Builder $sb -Value $Value -Indent 0
    [void]$sb.Append("`n")
    return $sb.ToString()
}

function Get-MbcSha256Hex {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Text')][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][byte[]] $Bytes
    )
    $data = if ($PSCmdlet.ParameterSetName -eq 'Text') { [System.Text.UTF8Encoding]::new($false).GetBytes($Text) } else { $Bytes }
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant()
}
