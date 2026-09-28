BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psd1') -Force
}

InModuleScope M365BaselineCheck {
    Describe 'Synced folders' {
        BeforeAll {
            # A home folder shaped like a Mac's, with every kind of synced folder in it.
            $script:FakeHome = Join-Path $TestDrive 'home'
            foreach ($d in @('Library/CloudStorage/OneDrive-Contoso', 'Library/CloudStorage/GoogleDrive-someone', 'Library/Mobile Documents/com~apple~CloudDocs/Documents', 'Dropbox', 'Local')) {
                New-Item -ItemType Directory -Path (Join-Path $script:FakeHome $d) -Force | Out-Null
            }
            $script:Roots = Get-MbcSyncedRoots -HomePath $script:FakeHome
        }
        It 'finds OneDrive, Google Drive and iCloud Drive on a Mac, and Documents when iCloud holds it' {
            $names = @($script:Roots | ForEach-Object Name)
            $names | Should -Contain 'OneDrive'
            $names | Should -Contain 'Google Drive'
            $names | Should -Contain 'iCloud Drive'
            $names | Should -Contain 'iCloud Drive (Documents)'
            $names | Should -Contain 'Dropbox'
        }
        It 'names the service a path synchronises to, whatever its case' {
            Get-MbcSyncedLocation -Path (Join-Path $script:FakeHome 'Library/CloudStorage/OneDrive-Contoso/work/M365BaselineCheck') -Roots $script:Roots | Should -Be 'OneDrive'
            Get-MbcSyncedLocation -Path (Join-Path $script:FakeHome 'DOCUMENTS/M365BaselineCheck') -Roots $script:Roots | Should -Be 'iCloud Drive (Documents)'
            Get-MbcSyncedLocation -Path (Join-Path $script:FakeHome 'Dropbox') -Roots $script:Roots | Should -Be 'Dropbox'
        }
        It 'leaves a local folder alone, including one whose name only starts like a synced one' {
            Get-MbcSyncedLocation -Path (Join-Path $script:FakeHome 'Local/M365BaselineCheck') -Roots $script:Roots | Should -BeNullOrEmpty
            Get-MbcSyncedLocation -Path (Join-Path $script:FakeHome 'Dropbox-archive') -Roots $script:Roots | Should -BeNullOrEmpty
            Get-MbcSyncedLocation -Path (Join-Path $script:FakeHome 'M365BaselineCheck') -Roots $script:Roots | Should -BeNullOrEmpty
        }
        It 'finds OneDrive''s older layout in the home folder' {
            $h = Join-Path $TestDrive 'home-old'
            New-Item -ItemType Directory -Path (Join-Path $h 'OneDrive - Contoso') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $h 'OneDriveOld-archive') -Force | Out-Null
            $roots = Get-MbcSyncedRoots -HomePath $h
            Get-MbcSyncedLocation -Path (Join-Path $h 'OneDrive - Contoso/M365BaselineCheck') -Roots $roots | Should -Be 'OneDrive'
            # The environment variables can name a real OneDrive elsewhere; only this home's folders matter here.
            @($roots | Where-Object { $_.Path -like "*OneDriveOld-archive*" }).Count | Should -Be 0
        }
        It 'follows a link into a synced folder' -Skip:$IsWindows {
            $link = Join-Path $script:FakeHome 'work'
            New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $script:FakeHome 'Library/CloudStorage/OneDrive-Contoso') | Out-Null
            Get-MbcSyncedLocation -Path (Join-Path $link 'M365BaselineCheck') -Roots $script:Roots | Should -Be 'OneDrive'
        }
        It 'refuses a synced output folder with what to do instead, unless allowed' {
            $saved = $env:OneDrive
            $env:OneDrive = Join-Path $TestDrive 'OneDrive'
            try {
                $text = Get-MbcSyncedRefusal -OutputRoot (Join-Path $env:OneDrive 'M365BaselineCheck')
                $text | Should -BeLike '*synchronises to OneDrive*-OutputRoot*M365BC_HOME*-AllowSyncedOutput*docs/handling-results.md*'
                Get-MbcSyncedRefusal -OutputRoot (Join-Path $env:OneDrive 'M365BaselineCheck') -Allowed | Should -BeExactly ''
                Get-MbcSyncedRefusal -OutputRoot (Join-Path $TestDrive 'local') | Should -BeExactly ''
            }
            finally { $env:OneDrive = $saved }
        }
    }

    Describe 'Paths as PowerShell means them' {
        It 'reads ~ as home and a relative path from the current location' {
            Resolve-MbcFullPath -Path '~/M365BaselineCheck/x.json' | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $HOME 'M365BaselineCheck/x.json')))
            Push-Location $TestDrive
            try { Resolve-MbcFullPath -Path 'sub/x.json' | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'sub/x.json'))) }
            finally { Pop-Location }
        }
        It 'refuses a path on a drive that isn''t the file system, before writing anything' {
            { Resolve-MbcFullPath -Path 'Env:\mbc-probe.json' } | Should -Throw "*isn't a file-system path*Environment*"
            { Write-MbcFileAtomic -Path 'Env:\mbc-probe.json' -Text 'x' } | Should -Throw "*isn't a file-system path*"
            Push-Location 'Env:\'
            try { { Resolve-MbcFullPath -Path 'relative.json' } | Should -Throw "*isn't a file-system path*" }
            finally { Pop-Location }
            Test-Path (Join-Path (Get-Location).ProviderPath 'mbc-probe.json') | Should -BeFalse
        }
        It 'writes a relative path under the current location, never a literal folder' {
            Push-Location $TestDrive
            try { Write-MbcFileAtomic -Path 'written.txt' -Text 'x' }
            finally { Pop-Location }
            Test-Path (Join-Path $TestDrive 'written.txt') | Should -BeTrue
        }
    }

    Describe 'Old plaintext' {
        It 'points out plaintext logs and results older than 30 days, and never deletes them' {
            $root = Get-MbcOutputRoot -Root (Join-Path $TestDrive 'stale')
            $old = @((Join-Path $root 'logs/run-1.jsonl'), (Join-Path $root 'results/result-1.json'), (Join-Path $root 'results/report-1.txt'))
            $keep = @((Join-Path $root 'logs/run-2.jsonl'), (Join-Path $root 'results/result-1.locked'), (Join-Path $root 'results/summary-1.md'))
            foreach ($f in $old + $keep) { [System.IO.File]::WriteAllText($f, 'x') }
            foreach ($f in $old + $keep[1..2]) { [System.IO.File]::SetLastWriteTimeUtc($f, [datetime]::UtcNow.AddDays(-45)) }
            $stale = Get-MbcStalePlaintext -OutputRoot $root
            @($stale | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object) -join ',' | Should -Be 'report-1.txt,result-1.json,run-1.jsonl'
            Get-MbcStaleNote -OutputRoot $root | Should -BeLike '3 plaintext log or result files older than 30 days are still in *delete them when you no longer need them.'
            foreach ($f in $old) { Test-Path $f | Should -BeTrue }
        }
        It 'says nothing when there is nothing old' {
            Get-MbcStaleNote -OutputRoot (Get-MbcOutputRoot -Root (Join-Path $TestDrive 'fresh')) | Should -BeExactly ''
        }
        It 'says where plaintext logs stay, for one or several' {
            Get-MbcPlaintextLogNote -Path @('/x/logs/run-1.jsonl') | Should -BeLike 'The run log stays in plaintext at /x/logs/run-1.jsonl.*delete it when*'
            Get-MbcPlaintextLogNote -Path @('/x/logs/run-1.jsonl', '/x/logs/run-2.jsonl') | Should -BeLike "This session's 2 run logs stay in plaintext in *logs.*delete them when*"
            Get-MbcPlaintextLogNote -Path @() | Should -BeExactly ''
        }
    }

    Describe 'Private files on macOS and Linux' -Skip:$IsWindows {
        It 'makes the output folders 700 and what it writes 600' {
            $root = Get-MbcOutputRoot -Root (Join-Path $TestDrive 'private')
            $dirMode = [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute'
            $fileMode = [System.IO.UnixFileMode]'UserRead, UserWrite'
            [System.IO.File]::GetUnixFileMode($root) | Should -Be $dirMode
            foreach ($sub in 'logs', 'results', 'presets', 'baselines') { [System.IO.File]::GetUnixFileMode((Join-Path $root $sub)) | Should -Be $dirMode }
            $file = Join-Path $root 'results/x.txt'
            Write-MbcFileAtomic -Path $file -Text 'x'
            [System.IO.File]::GetUnixFileMode($file) | Should -Be $fileMode
            $log = New-MbcRunLog -Directory (Join-Path $root 'logs') -RunId (New-MbcRunId) -Digest ('0' * 64)
            [System.IO.File]::GetUnixFileMode($log.Path) | Should -Be $fileMode
        }
        It 'leaves the mode of a folder it did not create' {
            $mine = Join-Path $TestDrive 'existing'
            New-Item -ItemType Directory -Path $mine | Out-Null
            $before = [System.IO.File]::GetUnixFileMode($mine)
            Get-MbcOutputRoot -Root $mine | Out-Null
            [System.IO.File]::GetUnixFileMode($mine) | Should -Be $before
        }
    }
}
