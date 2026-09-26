@{
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        # The module is PowerShell-7-only, and the file-writing constraint here is UTF-8 without BOM.
        'PSUseBOMForUnicodeEncodedFile',
        # Several plan function names deliberately name collections (plural nouns).
        'PSUseSingularNouns',
        # Private New-/Set-/Update- functions construct values or update in-memory UI state only.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
