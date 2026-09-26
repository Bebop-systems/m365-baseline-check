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

- PowerShell 7.4 or later.
- `Microsoft.Graph.Authentication` 2.x. `ExchangeOnlineManagement` 3.x when a baseline uses Exchange
  Online or Security & Compliance checks.

```powershell
Install-Module Microsoft.Graph.Authentication, ExchangeOnlineManagement -Scope CurrentUser
```

## Try it without a tenant

```powershell
pwsh -NoProfile -File tools/Start-Demo.ps1
```

This runs the interactive view against a synthetic tenant through the real clients. Nothing leaves the
machine. Press `r` to run and `?` on any screen for its keys.

## Quick start

```powershell
Import-Module ./M365BaselineCheck.psd1

# The interactive view.
Start-BaselineCheck -Baseline ./presets/example-tenant-hygiene.baseline.json

# The same run in plain output, exporting a locked bundle.
Invoke-BaselineCheck ./presets/example-tenant-hygiene.baseline.json -Export
```

Sign-in opens a browser or account picker, for Graph and then each Exchange session the baseline uses.
The sign-in line discloses the account, its directory roles, the granted scopes (write scopes marked)
and the sessions connected, and ends with *Read-only by construction: GET-only Graph, Get- cmdlets only.*

## Baselines

```powershell
New-BaselineCapture -PresetPath ./presets/example-tenant-hygiene.json -OutputPath ./baselines/core.json -Name 'Core tenant'
Protect-Baseline ./baselines/core.json      # validate and seal; prints the line to record
Test-Baseline ./baselines/core.json         # identity and seal state
```

A seal proves a file hasn't changed since it was sealed, not who sealed it. Record the full digest
wherever the team catalogues baselines; that record, compared with the digest in a result, is what
proves which version a run used. Keep organisation-specific presets and baselines in a private copy,
never in this repository.

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

Logs are in `~/M365BaselineCheck/logs/`, one JSON-lines file per run.

## Environment

- `NO_COLOR=1`: no colour. The selection and every verdict still read without it.
- `M365BC_ASCII=1`: ASCII drawing, for consoles that can't show the glyphs.
- `M365BC_HOME`: the output folder.

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

## Licence

Apache-2.0. See [LICENSE](LICENSE).
