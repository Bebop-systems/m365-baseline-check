# M365 Baseline Check

Checks a Microsoft 365 tenant's configuration against a baseline your team has agreed and sealed, from a
terminal UI or in plain output. It reads what administrators otherwise click through in the Entra,
Exchange, Intune, Purview, Defender and Microsoft 365 admin centres, and reports it grouped and worded
the way those portals are. It only reads: it never changes a tenant, whatever the signed-in account can do.

The code in this repository was written by Claude (Anthropic's model), under human direction.

**Contents:** [Get started](#get-started) · [Make your own baseline](#make-your-own-baseline) ·
[Sign-in and sessions](#sign-in-and-sessions) · [Results](#results) ·
[Troubleshooting](#troubleshooting) · [Reference](#reference)

## What it does

- Reads Microsoft Graph (GET only) and the Exchange Online and Security & Compliance PowerShell sessions
  (declared `Get-` cmdlets only).
- Compares what it reads with a **baseline**: a list of checks plus the values you expect, sealed so
  that any later edit shows. An edited baseline is refused until it is sealed again.
- Shows what needs attention first, *Not met* and *Unverifiable*, grouped by admin centre, with the
  portal location of each setting that has one.
- Lists the tenant's third-party apps and its own app registrations, with their permissions.
- Exports one encrypted file with the full results, plus a redacted `summary.md` that is safe to share.

## Get started

### 1. Install PowerShell and the Microsoft modules

PowerShell 7.6 or later. (7.4 is enough for Graph-only checks; Exchange Online Management 3.10.0 needs
7.6.) Check with `pwsh --version`.

| | |
|---|---|
| macOS | `brew install --cask powershell`, then run `pwsh` in Terminal or iTerm2 |
| Windows | `winget install Microsoft.PowerShell`, then run `pwsh` |
| Linux | [Microsoft's instructions](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux) |

Then, in `pwsh`, the two Microsoft modules it signs in with, at the tested versions:

```powershell
Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1 -Scope CurrentUser
Install-Module ExchangeOnlineManagement -RequiredVersion 3.10.0 -Scope CurrentUser
```

The tool loads only versions it has been tested with; [Reference](#client-module-versions) explains why.

### 2. Get the tool

Either download the latest release zip from this repository's *Releases* page and extract it, or clone
the repository:

```powershell
git clone https://github.com/<owner>/m365-baseline-check.git
cd m365-baseline-check
```

A release can be checked before use; see [Verifying a release](#verifying-a-release).

### 3. Try it without a tenant

From the tool's folder:

```powershell
pwsh -NoProfile -File tools/Start-Demo.ps1
```

This runs the interactive view against a made-up tenant through the real code. Nothing leaves the
machine. Press `r` to run, `Enter` to open a result, `?` on any screen for its keys, and `q` to quit.
(The demo, like the tests, is in the repository, not the release zip.)

### 4. Run it against your tenant

Start a fresh PowerShell in the tool's folder, load the module and open the view:

```powershell
cd path/to/m365-baseline-check      # the folder with M365BaselineCheck.psd1
pwsh -NoProfile
Import-Module ./M365BaselineCheck.psd1
Start-BaselineCheck
```

1. **Choose a baseline.** Press `b` and choose `example-tenant-hygiene.baseline.json`. It is sealed
   and ready to run. Its expected values are generic examples, so expect a fair number of *Not met*:
   the point is to see the tool work. [Make your own baseline](#make-your-own-baseline) is next.
2. **Run.** Press `r`. The view lists the sign-ins it needs, then leaves the screen for them: Graph
   first (the Windows account picker, or a browser), then a browser for Exchange Online. Choose the
   same account each time. Security & Compliance usually reuses the Exchange Online sign-in. Use an
   account that can read every setting the baseline checks; the live runs so far used a Global
   Administrator. Anything the account can't read shows as *Unverifiable*, with the reason, never as met.
3. **Read the results.** They open showing only what needs attention. `Enter` opens a check: what was
   expected, what the tenant has, and where the setting lives. `a` shows every check, `/` filters, and
   `i` shows the app inventory.
4. **Export**, if you want to keep them: `x`. Exports are locked with a *team key*: make one once with
   `s`, then *Generate a team key*, and keep it in your team's password manager.
   [Results](#results) has the details.
5. **Quit** with `q`. Quitting signs out of everything. It then prints any Graph consent the sign-in
   left in the tenant, with the command to remove it: see [docs/removing-consent.md](docs/removing-consent.md).

The same run in plain output, for a script or a log:

```powershell
Invoke-BaselineCheck ./presets/example-tenant-hygiene.baseline.json -Export
```

## Make your own baseline

Two kinds of file, both JSON:

| | What it holds | Example in this repository |
|---|---|---|
| **Preset** | *What* to check: each setting, where to read it, how to compare. No values. | `presets/example-tenant-hygiene.json` |
| **Baseline** | A preset plus the values you *expect*, sealed. This is what a run uses. | `presets/example-tenant-hygiene.baseline.json` |

You rarely write a baseline by hand. The tool **drafts** one by reading a tenant you consider right,
you **review** the draft, and you **seal** it. Your files live in `~/M365BaselineCheck/presets/` and
`~/M365BaselineCheck/baselines/`, which the tool creates and offers in its lists. They describe your
organisation, so keep them there or in a private repository; never in this public one.

### In the view

Press `s` on the home screen (*Make a baseline*). Then:

1. **Choose your checks (optional).** *Copy the example preset* puts a copy, under a name you give, in
   `~/M365BaselineCheck/presets/`. Open it in an editor and delete the checks you don't want, change
   any, or add your own. [`CLAUDE.md`](CLAUDE.md), *Adding a preset*, explains every field, and a Claude
   session can write checks for you from it. To try the process first, skip this step: the example
   preset can be drafted from directly.
2. **Draft.** *Draft a baseline from a preset* lists your presets first, then the example. Choose one
   and confirm where to write the draft (the suggestion is in `~/M365BaselineCheck/baselines/`). The
   tool signs in, reads the tenant, and writes what it finds as the expected values. A panel then lists
   any check it couldn't fill in, and why.
3. **Review.** Open the draft in an editor (below). Add a value for each check the panel listed, and
   change any value you don't want to keep: the draft records what the tenant has *now*, which is not
   always what it should have.
4. **Seal.** Back in the view, *Seal a baseline* suggests the draft you just made; press `Enter`. If
   anything is still missing, it says what, and nothing is sealed. Once sealed, it is the chosen
   baseline, and `r` runs it. Sealing shows a line to record wherever your team catalogues baselines.

### What a draft looks like

A draft is the preset, copied in whole under `"preset"`, followed by `"expected"`: one entry per check,
by its ID. A check the tool couldn't read is simply missing from `"expected"`:

```json
  "expected": {
    "ENTRA-001": false,
    "ENTRA-003": ["adminsAndGuestInviters", "none"],
    "EXO-001": false,
    "EXO-004": 3
  }
```

To fill one in, add a line in the same form. What a value looks like depends on the check's `operator`,
which you'll find on that check under `"preset"` › `"checks"`:

| Operator | Expected value | Example |
|---|---|---|
| `equals`, `notEquals` | the value itself | `false`, `"enabled"`, `3` |
| `in` | a list of acceptable values | `["adminsAndGuestInviters", "none"]` |
| `contains` | one value the setting's list must include | `"Default"` |
| `setEquals`, `subsetOf` | a list | `["a", "b"]` |
| `countAtLeast`, `countAtMost` | a whole number | `1` |
| `matches` | a regular expression, anchored by you | `"^https://"` |
| `exists`, `absent` | no entry at all | |

To drop a check, delete it from `"checks"` inside `"preset"` and from `"expected"`. Keep `"version"` as
it is for a first seal.

### Changing a baseline later

Edit it, raise `"version"`, and seal it again. A sealed baseline that has been edited is refused until
then, and it can't be resealed under the same version. The seal proves the file hasn't changed since
it was sealed, not who sealed it: the line you recorded, compared with the digest in a result, is what
proves which version a run used.

### Without the view

```powershell
Copy-Item ./presets/example-tenant-hygiene.json ~/M365BaselineCheck/presets/core-tenant.json   # then edit it
New-BaselineCapture -PresetPath ~/M365BaselineCheck/presets/core-tenant.json -OutputPath ~/M365BaselineCheck/baselines/core-tenant.json
Protect-Baseline ~/M365BaselineCheck/baselines/core-tenant.json   # seal; prints the line to record
Test-Baseline ~/M365BaselineCheck/baselines/core-tenant.json      # name, version and seal state
Start-BaselineCheck -Baseline ~/M365BaselineCheck/baselines/core-tenant.json
```

## Sign-in and sessions

- A run signs in only to what the baseline uses: Graph always, then Exchange Online and Security &
  Compliance when its checks need them. The view lists the sign-ins before the first one.
- The sign-in panel (`g` on the home screen) shows the account, its directory roles, the Graph
  permissions granted (write permissions marked), the sessions connected and the module versions used.
- Sessions already open in the PowerShell process are closed before signing in, so nothing is reused,
  and Graph's token cache stays in memory, never on disk.
- Quitting the view, switching account (`c`), and the end of a plain run or a capture sign out of
  everything.

## Results

A run's results stay in memory until you export them. `x` on the results writes, to
`~/M365BaselineCheck/results/`:

- `result-<time>.locked`: everything, encrypted with the team key: the report, `result.json`, CSVs of
  the checks and the apps, `summary.md`, and the run's log.
- `summary-<time>.md`, in plain text: counts and verdicts by admin centre, with nothing that identifies
  the tenant. It is built to be shared, with a colleague or an AI assistant.

The **team key** is one line, `mbc-key:1:…`. Make it once (`s`, then *Generate a team key*, or
`New-ResultKey`) and keep it in one entry in your team's password manager; the tool never saves it.
Anyone with the key can open an export: `o` in the view, or:

```powershell
Unlock-Result ~/M365BaselineCheck/results/result-<time>.locked                              # to memory
Unlock-Result ~/M365BaselineCheck/results/result-<time>.locked -OutputDirectory ./unlocked  # plaintext files
```

Leave the key empty at the export prompt, or use `-NoLock`, to write the parts as plaintext instead.

### Handling results

Results are confidential: no credentials or end-user content, but a map of one tenant's weak spots.
[docs/handling-results.md](docs/handling-results.md) is the guide, mapped to SOC 2. In short:

- Export locked, and keep the team key only in the password manager.
- Keep plaintext only on an encrypted disk (FileVault on a Mac, BitLocker on Windows), never in a
  synced folder. The tool refuses to write to iCloud Drive, OneDrive, Dropbox, Google Drive or Box
  unless you pass `-AllowSyncedOutput`.
- Share `summary.md` rather than the results themselves.
- Delete plaintext when the work is done; the tool points out anything older than 30 days.

## Troubleshooting

**The view behaves as it did before an update.** `Import-Module` keeps a version already loaded in the
same session. Start a fresh `pwsh`, or use `Import-Module ./M365BaselineCheck.psd1 -Force`.

**I was asked to sign in more than once.** Expected: Graph, then Exchange Online, each its own sign-in.
Choose the same account each time; the tool checks that the sessions are in the same tenant.

**"There's no preset at …" or "That is a folder".** A preset or baseline is a file. In a list, `p` lets
you type a path; give the file's path, not its folder's.

**"Not sealed" with a list of checks.** The draft is missing expected values. Add them, as in
[What a draft looks like](#what-a-draft-looks-like), then seal again.

**"This tool runs with … 2.38.1 or later" or "… needs PowerShell 7.6".** Install the version it names,
with the `Install-Module` line it prints, or update PowerShell. If another version is already loaded,
usually by a profile, start `pwsh -NoProfile`.

**A check is *Unverifiable*.** Open it for the cause. The common ones:

- *permission missing*: the account lacks a role or scope for that setting.
- *setting not found*: often a setting that has never been saved. Intune, for one, returns nothing until
  its settings are saved in the portal once.
- *cmdlet failed*, with a server-side error: the service refused. The tool retries twice; some cmdlets,
  such as `Get-ExternalInOutlook`, fail in some tenants even when run by hand.

**Windows still remembers the account after quitting.** The quit message says where to remove it:
Settings › Accounts › Email & accounts › Accounts used by other apps.

**"The output folder … synchronises to OneDrive".** Results mustn't land in a synced folder. Use the
default folder, or point `-OutputRoot` or `M365BC_HOME` at one that stays on this machine.

## Reference

### Client module versions

`Microsoft.Graph.Authentication` 2.38.1 up to 3.0, and `ExchangeOnlineManagement` 3.10.0 up to 4.0
(which needs PowerShell 7.6): the tested ranges, release versions only. These modules hold an
administrator's token while they run, so the tool loads nothing outside them. On Windows it also requires
Microsoft's valid signature on each one's manifest, root module and core assemblies; macOS and Linux
can't check signatures. The sign-in panel names the versions used, and marks any newer than tested.

### Commands

| Command | What it does |
|---|---|
| `Start-BaselineCheck` | The interactive view. `-Baseline` preselects one. |
| `Invoke-BaselineCheck` | A run in plain output. `-Export` writes a locked export. |
| `New-BaselineCapture` | Drafts a baseline from a preset by reading a tenant. |
| `Protect-Baseline` | Validates and seals a baseline. |
| `Test-Baseline` | Shows a baseline's name, version and seal state. |
| `New-ResultKey` | Makes a team key. |
| `Unlock-Result` | Opens a locked export. |

`Get-Help <command> -Full` has each one's parameters.

### Environment

- `M365BC_HOME`: the output folder, instead of `~/M365BaselineCheck`. It must stay out of synced folders.
- `NO_COLOR=1`: no colour. Selections and verdicts still read without it.
- `M365BC_ASCII=1`: ASCII drawing, for consoles that can't show the glyphs.

When the console can't host the view (output redirected, no terminal support), `Start-BaselineCheck`
falls back to plain output.

### Coverage

Some admin-centre settings have no supported API. Checks cover what Graph and the Exchange Online and
Security & Compliance sessions expose, not every switch in every portal.

### Verifying a release

Each release carries `SHA256SUMS.txt` and a build attestation proving the zip was built by this
repository's workflow from the tagged commit:

```powershell
(Get-FileHash ./M365BaselineCheck-<version>.zip -Algorithm SHA256).Hash   # compare with SHA256SUMS.txt
gh attestation verify ./M365BaselineCheck-<version>.zip --repo <owner>/m365-baseline-check
```

Releases aren't Authenticode-signed yet. On Windows with the RemoteSigned policy, unblock the files after
extracting: `Get-ChildItem -Recurse ./M365BaselineCheck | Unblock-File`.

### Development

[`CLAUDE.md`](CLAUDE.md) is the guide to the code, the invariants and adding checks.
[docs/development.md](docs/development.md) covers the tests, releases and testing on a Mac.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
