# Development

[`CLAUDE.md`](../CLAUDE.md) is the guide to the code: the invariants, how presets work, and the
PowerShell traps met here. This page covers the tools around it.

## Tests

```powershell
pwsh -NoProfile -File tools/Invoke-Gate.ps1          # every test, offline, and the analyser
pwsh -NoProfile -File tools/Export-TuiSnapshots.ps1  # every screen as text, in docs/tui-snapshots
pwsh -NoProfile -File tools/Start-Demo.ps1           # the view against a made-up tenant
```

The gate runs before every commit and in CI on Windows and Linux. It needs Pester 5.5 or later and
PSScriptAnalyzer:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

The snapshots are the quickest way to review a change to the view's wording or layout: regenerate them
and read the diff. `example-report.txt` and `example-summary.md` change their run time on every
regeneration; leave those out of a commit unless their content changed.

## Releases

1. Raise `ModuleVersion` in `M365BaselineCheck.psd1` and merge.
2. Tag the merge commit `v<ModuleVersion>` and push the tag.

The tag runs `.github/workflows/release.yml`: the gate in a read-only job, then a job that runs
`tools/Build-Release.ps1` (a zip of the module's tracked files and `SHA256SUMS.txt`), attests the zip's
build provenance, and publishes a GitHub release. Versions 0.x are marked as pre-releases. The zip holds
the module and its operator docs; the demo, tests and tools stay in the repository.

**Signing.** Add two repository secrets and every later release is Authenticode-signed, each `.ps1`,
`.psm1` and `.psd1` with SHA-256 and a timestamp:

- `SIGNING_CERT_PFX_BASE64`: the code-signing certificate and its private key, as a base64 PFX.
- `SIGNING_CERT_PASSWORD`: the PFX's password.

Check a signed release with `Get-AuthenticodeSignature ./M365BaselineCheck/M365BaselineCheck.psd1`.
`tools/Build-Release.ps1 -Certificate (Get-Item Cert:\CurrentUser\My\<thumbprint>)` signs a local build
the same way.

Workflow actions are pinned to commit SHAs. Update them deliberately, with the tag each SHA stands for
in the comment beside it.

## Testing on a Mac

CI covers Windows and Linux; a Mac run by hand covers the rest. In Terminal or iTerm2:

1. `fdesetup status` says FileVault is on.
2. `pwsh -NoProfile -File tools/Invoke-Gate.ps1` passes, including the permission tests Windows skips.
3. `pwsh -NoProfile -File tools/Start-Demo.ps1`: the glyphs, colours and keys look right, and resizing
   the window redraws.
4. A live run against a test tenant: Graph opens a browser (there's no account picker on a Mac),
   Exchange Online opens another, and quitting signs out of both.
5. `ls -la ~/M365BaselineCheck ~/M365BaselineCheck/logs` shows `drwx------` and `-rw-------`.
6. `Start-BaselineCheck -OutputRoot ~/Library/Mobile\ Documents/x` is refused, and so is a folder under
   `~/Library/CloudStorage/` if OneDrive or Google Drive is installed.
7. The first run may ask whether the terminal can access iCloud Drive or other apps' data: the
   synced-folder check looks in those folders. Note whether it does.
