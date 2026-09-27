# M365 Baseline Check

Read-only checks of a Microsoft 365 tenant's configuration against a sealed baseline, from a terminal UI
or in plain output. It covers what administrators otherwise click through in the Entra, Exchange, Intune,
Purview, Defender and Microsoft 365 admin centres, and reports it grouped and worded the way those
portals are.

The code in this repository was written by Claude (Anthropic's model), under human direction.

## What it does

- Reads Microsoft Graph (GET only) and the Exchange Online and Security & Compliance PowerShell sessions
  (declared `Get-` cmdlets only). It never writes to a tenant, whatever the signed-in account can do.
- Compares what it reads with a **sealed baseline**: a preset of checks plus expected values, with a
  SHA-256 digest over its canonical form. An edited, unresealed baseline is refused.
- Shows only what needs attention by default: *Not met* and *Unverifiable*, grouped by admin centre.
- Lists third-party enterprise apps and the tenant's own registrations, with their consents.
- Leaves a verbose JSON-lines log of every run, and exports one encrypted bundle (report, result JSON,
  CSVs) plus a redacted `summary.md` that is safe to hand to an AI assistant.

## Requirements

- PowerShell 7.4 or later, on macOS, Windows or Linux. On a Mac: `brew install powershell`, then
  `pwsh` in Terminal or iTerm2.
- `Microsoft.Graph.Authentication` 2.38.1 or later below 3.0, and `ExchangeOnlineManagement` 3.10.0
  or later below 4.0 when a baseline uses Exchange Online or Security & Compliance checks. Those are
  the tested ranges: the tool loads nothing outside them, and on Windows nothing without Microsoft's
  valid signature, because these modules hold an administrator's token while they run. The sign-in
  disclosure names the versions used, and marks any newer than tested.

```powershell
Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1 -Scope CurrentUser
Install-Module ExchangeOnlineManagement -RequiredVersion 3.10.0 -Scope CurrentUser
```

## Try it without a tenant

```powershell
pwsh -NoProfile -File tools/Start-Demo.ps1
```

This runs the interactive view against a synthetic tenant through the real clients. Nothing leaves the
machine. Press `r` to run and `?` on any screen for its keys.

## Quick start

```powershell
# In a fresh PowerShell, or add -Force: Import-Module keeps a version it already loaded.
Import-Module ./M365BaselineCheck.psd1 -Force

# The interactive view.
Start-BaselineCheck -Baseline ./presets/example-tenant-hygiene.baseline.json

# The same run in plain output, exporting a locked bundle.
Invoke-BaselineCheck ./presets/example-tenant-hygiene.baseline.json -Export
```

Sign-in opens a browser or account picker, for Graph and then each Exchange session the baseline uses.
The sign-in line discloses the account, its directory roles, the granted scopes (write scopes marked)
and the sessions connected, and ends with *Read-only by construction: GET-only Graph, Get- cmdlets only.*

## Make your own baseline

Two kinds of file:

- A **preset** says *what* to check: which settings, where to read them, how to compare. No values.
- A **baseline** is a preset plus the values you *expect*, sealed so any later edit shows.

The tool keeps your files in `~/M365BaselineCheck/` (it creates `presets/` and `baselines/` there).
They belong to your organisation: keep them there, or in a private repository your team shares. Never
put them in this public repository; a test here refuses them.

1. **Start from a preset.** Copy `presets/example-tenant-hygiene.json` into
   `~/M365BaselineCheck/presets/`, rename it, and remove, change or add checks. [`CLAUDE.md`](CLAUDE.md)
   explains every field, and a Claude session can write checks for you from it.
2. **Draft the baseline.** In the view: `s` (Make a baseline), then *Draft a baseline from a preset*.
   Pick your preset; it signs in, reads the tenant, and writes what it finds as the expected values
   into `~/M365BaselineCheck/baselines/`. Anything it couldn't read is listed for you to fill in.
3. **Review and seal.** Open the draft, change any expected value you don't want to keep, then *Seal a
   baseline* on the same screen. Sealing prints a line to record wherever your team catalogues
   baselines. `b` on the home screen then offers it.

The same, without the view:

```powershell
New-BaselineCapture -PresetPath ~/M365BaselineCheck/presets/core.json -OutputPath ~/M365BaselineCheck/baselines/core.json -Name 'Core tenant'
Protect-Baseline ~/M365BaselineCheck/baselines/core.json    # validate and seal; prints the line to record
Test-Baseline ~/M365BaselineCheck/baselines/core.json       # identity and seal state
```

A seal proves a file hasn't changed since it was sealed, not who sealed it. Changing a sealed baseline
means raising its `version` and sealing again. The full digest recorded in your catalogue, compared
with the digest in a result, is what proves which version a run used.

## Sign-in and sessions

- A run signs in only to what the baseline uses: Graph always (the account picker), then a browser
  sign-in for Exchange Online and for Security & Compliance when checks need them. The view lists the
  sign-ins before the first one. Choose the same account each time.
- Sessions left open in the PowerShell process are closed before signing in, so nothing is reused.
- The Graph token cache is kept in the process only, never on disk.
- Quitting the view, switching account, and the end of a plain run or capture sign out of everything.

## Results

Exports go to `~/M365BaselineCheck/results/` (or `-OutputRoot`, or `$env:M365BC_HOME`):

- `result-<time>.locked`: `result.json`, `result.csv`, `apps.csv`, `report.txt` and `summary.md`,
  encrypted with the team key (AES-256-GCM, HKDF-SHA256 per file).
- `summary-<time>.md` in plain text, unless `-LockSummary`.
- `-NoLock` writes the five parts unencrypted instead.

```powershell
New-ResultKey                                   # once per team; keep it in the password manager
Unlock-Result ./results/result-<time>.locked    # to memory; -OutputDirectory to write plaintext
```

Each run writes a JSON-lines log to `~/M365BaselineCheck/logs/` as it goes. A locked export moves it
into the bundle and deletes the plaintext copy; otherwise the tool says where it stays.

### Handling results

Results are confidential: a map of one tenant's weak spots, though no credentials or end-user content.
[docs/handling-results.md](docs/handling-results.md) is the guide, mapped to SOC 2. In short:

- Export locked, and keep the team key only in the password manager.
- Plaintext only on an encrypted disk (FileVault on a Mac, BitLocker on Windows), never in a synced
  folder. The tool refuses an output folder in iCloud Drive, OneDrive, Dropbox, Google Drive or Box
  unless you pass `-AllowSyncedOutput`.
- Share `summary.md`, which is redacted by construction, rather than the result itself.
- Delete plaintext when the work is done; the tool points out anything older than 30 days.
- On macOS and Linux the tool's folders and files are readable by you alone.

## Environment

- `NO_COLOR=1`: no colour. The selection and every verdict still read without it.
- `M365BC_ASCII=1`: ASCII drawing, for consoles that can't show the glyphs.
- `M365BC_HOME`: the output folder. It must stay out of synced folders (see *Handling results*).

When the console can't host the interactive view (output redirected, no virtual terminal),
`Start-BaselineCheck` falls back to plain output.

## Customising

[`CLAUDE.md`](CLAUDE.md) explains presets, sources, the select language, operators and labels, for a
person or a Claude session adding checks.

Some admin-centre settings have no supported API; checks cover what Graph and the Exchange Online and
Security & Compliance sessions expose.

## Development

```powershell
pwsh -NoProfile -File tools/Invoke-Gate.ps1          # every test, offline, and the analyser
pwsh -NoProfile -File tools/Export-TuiSnapshots.ps1  # every screen as text, in docs/tui-snapshots
```

### Releases and verifying

A tag `v<ModuleVersion>` runs `.github/workflows/release.yml`: the gate, then
`tools/Build-Release.ps1`, which zips only the module's tracked files and writes `SHA256SUMS.txt`. CI
attests the zip's build provenance, and the release carries both files. Before using a release:

```powershell
(Get-FileHash ./M365BaselineCheck-<version>.zip -Algorithm SHA256).Hash   # matches SHA256SUMS.txt
gh attestation verify ./M365BaselineCheck-<version>.zip --repo <owner>/m365-baseline-check
```

The attestation proves the zip was built by this repository's workflow from the tagged commit.
Authenticode signing happens in the same workflow once the repository has the secrets
`SIGNING_CERT_PFX_BASE64` (the code-signing certificate as base64 PFX) and `SIGNING_CERT_PASSWORD`.
Every `.ps1`, `.psm1` and `.psd1` is then signed with SHA-256 and a timestamp; check one with
`Get-AuthenticodeSignature ./M365BaselineCheck/M365BaselineCheck.psd1`. Until then releases are
unsigned and marked as pre-releases while the version is 0.x.

### Testing on a Mac

CI runs the tests on Windows and Linux; a Mac run by hand covers the rest. In Terminal or iTerm2:

1. `fdesetup status` says FileVault is on.
2. `pwsh -NoProfile -File tools/Invoke-Gate.ps1` passes, including the permission tests Windows skips.
3. `pwsh -NoProfile -File tools/Start-Demo.ps1`: the glyphs, colours and keys look right; resizing
   redraws.
4. A live run against a test tenant: Graph opens the browser (there's no Windows account picker on a
   Mac), Exchange Online opens it again, and quitting signs out of both.
5. `ls -la ~/M365BaselineCheck ~/M365BaselineCheck/logs` shows `drwx------` and `-rw-------`.
6. `Start-BaselineCheck -OutputRoot ~/Library/Mobile\ Documents/x` is refused, and so is a folder
   under `~/Library/CloudStorage/` if OneDrive or Google Drive is installed.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
