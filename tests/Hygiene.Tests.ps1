BeforeDiscovery {
    $script:SrcFiles = @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') -Recurse -Filter '*.ps1' -File |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    function script:Find-Construct([string] $Text, [string[]] $Constructs) {
        foreach ($c in $Constructs) {
            if ($Text.IndexOf($c, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $c }
        }
    }
}

Describe 'Polite PowerShell (invariant 7)' {
    It 'has source files to check' {
        @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') -Recurse -Filter '*.ps1' -File).Count | Should -BeGreaterThan 5
    }

    It '<Name> uses nothing that looks like evasion, spawning or downloading' -ForEach $script:SrcFiles {
        $text = [System.IO.File]::ReadAllText($Path)
        $found = @(Find-Construct -Text $text -Constructs @(
                'Invoke-Expression', '[scriptblock]::Create', 'ScriptBlock]::Create', 'Add-Type', 'Start-Process',
                'EncodedCommand', 'Start-Job', 'Start-ThreadJob', '[powershell]::Create', 'PowerShell]::Create',
                'RunspaceFactory', 'RunspacePool', 'System.Reflection.Emit', 'BindingFlags', 'NonPublic',
                'powershell.exe', 'pwsh.exe', 'Invoke-Command', 'New-PSSession', 'Set-ExecutionPolicy',
                'HKLM:', 'HKCU:', 'Registry::', 'SetEnvironmentVariable', 'Invoke-WebRequest', 'Invoke-RestMethod',
                'Start-BitsTransfer', 'DownloadString', 'DownloadFile', 'Net.WebClient', 'HttpClient'
            ))
        $found | Should -BeNullOrEmpty
    }
}

Describe 'Plain string handling (invariant 9)' {
    It '<Name> uses no regular expressions' -ForEach $script:SrcFiles {
        $text = [System.IO.File]::ReadAllText($Path)
        $constructs = @('-match', '-notmatch', '-cmatch', '-imatch', '-cnotmatch', '-inotmatch', '-replace', '-creplace',
            '-ireplace', '-split', '-csplit', '-isplit', '-regex', 'Select-String')
        # The matches operator is the one place a regular expression is the right tool (spec 7.3).
        if ($Name -ne 'Operators.ps1') { $constructs += @('[regex]', 'RegularExpressions') }
        @(Find-Construct -Text $text -Constructs $constructs) | Should -BeNullOrEmpty
    }
}
