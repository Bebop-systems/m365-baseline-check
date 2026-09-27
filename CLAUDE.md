# CLAUDE.md: working on M365 Baseline Check

This is a read-only PowerShell 7 tool that checks a Microsoft 365 tenant's configuration against a sealed
baseline. It runs from a terminal UI (`Start-BaselineCheck`) or in plain output (`Invoke-BaselineCheck`).
Most work you'll be asked to do is **adding presets and baselines, as data**. The engine rarely needs to
change, and a change that seems to need breaking an invariant is the wrong change.

The design is in [`docs/superpowers/specs/2026-09-26-m365-baseline-check-design.md`](docs/superpowers/specs/2026-09-26-m365-baseline-check-design.md).

## Where internal presets and baselines live

**Never in this repository.** This repository is public. Organisation-specific presets and baselines
live outside it: in `~/M365BaselineCheck/presets/` and `~/M365BaselineCheck/baselines/` (the tool
creates both, and its choosers look there), or in a private repository the team shares. They travel
however the team shares files. `baselines/` is ignored by git here so a stray copy can't be committed.
The scrub gate (`tests/Scrub.Tests.ps1`) fails on any baseline or result outside `presets/` and
`tests/fixtures/`, and on any GUID, email address or domain that isn't a synthetic example or a
documented Microsoft ID.

## Invariants

1. **Read-only, by this tool's code.** The Graph client has one call site with the literal `-Method GET`.
   Cmdlet sources run only declared `Get-` cmdlets, resolved from their own session's module, with scalar
   parameters. Scopes requested are read scopes. The signed-in account is expected to be able to write;
   safety never depends on it being unable to.
2. **Error never becomes Pass.** A check that couldn't be completed is Unverifiable, with a cause.
3. **Seal before use.** Only a sealed, unmodified baseline runs, unless `-AllowUnsealed`, which stamps
   every output UNSEALED.
4. **Nothing identifying here.** See above.
5. **Collect, then evaluate.** Collection does I/O; selection and comparison are pure.
6. **Secrets are never written**: no tokens, headers or team keys in any log, result or file.
7. **Polite PowerShell.** `src/` never uses `Invoke-Expression`, `[scriptblock]::Create`, `Add-Type`,
   `Start-Process`, child PowerShell, `Start-Job`, extra runspaces, non-public reflection or
   `Reflection.Emit`. It downloads nothing and writes only under its output folder.
8. **Data stays close to its source.** Graph JSON as returned; cmdlet output flattened once, to one level.
9. **Plain string handling.** No regular expressions in `src/` except the `matches` operator.

`tests/Hygiene.Tests.ps1` and `tests/ReadOnly.Tests.ps1` hold 1, 7 and 9.

## Nouns

- **Preset**: what to read and how. Sources, declared requests, checks, no expected values.
- **Baseline**: a preset plus expected values, sealed into one file.
- **Source**: `graph` (default), `exo` (Exchange Online) or `compliance` (Security & Compliance).
- **Area**: the admin centre a check belongs to: `entra`, `exchange`, `intune`, `purview`, `defender`, `admin`.
- **Result**: one run against one baseline, including the app inventory, sealed.
- **Team key**: 256 random bits, kept in one entry in the team's password manager, for locking results.

## Adding a preset

A preset is JSON. Copy `presets/example-tenant-hygiene.json` and change it. The worked example below
has one Graph check and one Exchange Online check.

```json
{
  "schemaVersion": 1,
  "name": "Core tenant",
  "scopes": ["Policy.Read.All"],
  "endpoints": ["/policies/authorizationPolicy"],
  "cmdlets": { "exo": ["Get-OrganizationConfig"] },
  "checks": [
    {
      "id": "ENTRA-001", "title": "Users can register applications", "area": "entra",
      "location": "Identity › Users › User settings",
      "request": "/policies/authorizationPolicy", "select": "defaultUserRolePermissions.allowedToCreateApps",
      "operator": "equals", "severity": "medium", "labels": { "true": "Yes", "false": "No" },
      "why": "Registering an application is an administrative decision."
    },
    {
      "id": "EXO-001", "title": "Mailbox auditing on by default", "area": "exchange",
      "source": "exo", "request": "Get-OrganizationConfig", "select": "value[0].AuditDisabled",
      "operator": "equals", "severity": "high", "labels": { "false": "On", "true": "Off" },
      "why": "Mailbox audit records are how access to a mailbox is reconstructed afterwards."
    }
  ]
}
```

Check members. Required: `id`, `title`, `area`, `request`, `select`, `operator`, `severity`
(`high`, `medium`, `low` or `info`). Optional: `source`, `parameters` (cmdlet sources only; string,
boolean or whole-number values), `apiVersion` (`v1.0` or `beta`, Graph only), `location`, `labels`,
`caseSensitive`, `why`.

### Sources and what they return

- **Graph.** `request` is a path such as `/policies/authorizationPolicy`, optionally with a query
  string. It must fall under a path in `endpoints`. Paging is followed and joined into one `value` list.
  Add every Graph permission the checks need to `scopes`; each must be a read scope
  (`Resource.Read.All`, `Resource.ReadBasic.All`, `Resource.Read.<Qualifier>`). The app inventory's
  scopes (`Application.Read.All`, `Directory.Read.All`) and `User.Read` are always added at sign-in.
- **Exchange Online (`exo`) and Security & Compliance (`compliance`).** `request` is a `Get-` cmdlet
  name, declared under its source in `cmdlets`. The session is created with only the declared cmdlets
  loaded. Output is always `{ "value": [ ... ] }`, even for one object or none, and each object is
  flattened once: strings, booleans and numbers kept; enums as names; dates as ISO 8601 UTC; lists as
  lists of scalars; anything else as its text. That is what `Format-List` shows, so to find a property
  name, run the cmdlet yourself and look at `Format-List` output. Select with `value[0].Property`, or
  `value[?Name=='Default'].Property`.

### The select language

```
select   := path | 'length(' path ')'
path     := step ('.' step)*
step     := name ( '[*]' | '[' int ']' | '[?' name op literal ']' )?
op       := '==' | '!='
literal  := 'string' | integer | true | false | null
```

Names are letters, digits, `_`, `@`, `$` and `-`, or `"quoted"` for keys with dots, like
`value[0]."@odata.type"`. `[*]` and filters produce lists. A path that resolves to nothing is *setting
not found*, which is Unverifiable, except for `exists` and `absent`.

### Operators

| Operator | Passes when |
|---|---|
| `equals` / `notEquals` | equal: scalars directly; lists and objects structurally, with the same case rule |
| `in` | the actual scalar is one of the expected list |
| `contains` | the actual list contains the expected value |
| `setEquals` | the same members, ignoring order and duplicates |
| `subsetOf` | every actual member is in the expected list |
| `countAtLeast` / `countAtMost` | the length of the actual list, against a whole number |
| `matches` | the actual string matches the expected regular expression, anchored by you (1 s limit) |
| `exists` / `absent` | the path resolves / does not resolve (no expected value) |

String comparison is ordinal and case-insensitive unless `caseSensitive` is true. A type mismatch is
Unverifiable, never Not met. Expected values may not be floating-point numbers.

### `area`, `location` and `labels`: why they matter

Results are read by people who live in the admin centres, so they must look familiar.

- `title` is the portal's own wording for the setting, not a paraphrase.
- `area` groups the check under its admin centre, shown in the portals' order.
- `location` is the breadcrumb where an administrator finds the setting, in the portal's words, joined
  with ` › `. Leave it out for settings with no portal home (PowerShell-only).
- `labels` shows values the way the portal does. Keys are the value's canonical JSON text: `"true"`,
  `"3"`, and for strings the quoted form, `"\"enabled\""`. Labels change display only, never comparison.

## Capture, edit, seal

1. `New-BaselineCapture -PresetPath <preset> -OutputPath <draft> -Name '<name>'` signs in, reads a
   reference tenant and writes an unsealed draft. It lists what it couldn't read or decide.
2. Edit the draft's `expected` values by hand where needed.
3. `Protect-Baseline <draft>` validates and seals, and prints the line to record in the team's catalogue:
   `Name · vN · SHA-256 <digest>`. Changed content can't be resealed under the same version.
4. `Test-Baseline <file>` shows a baseline's identity and seal state.

**The seal proves integrity, not authorship.** Anyone who can edit a baseline can reseal it. The proof
of which version was used is the full digest recorded in the team's catalogue, compared with the digest
in the result. Never write that the seal alone proves it.

## Stated coverage limit

Some admin-centre and Defender portal settings have no supported API. Checks cover what Graph and the
Exchange Online and Security & Compliance PowerShell sessions expose, not every switch in every portal.
Say so when a requested setting can't be read.

## Voice, for anything a person reads

The readers are technical, well read, and at work. Be precise, brief and dry. Occasional wit is fine;
exclamation marks, cuteness and filler are not.

- *"Sealed. The baseline is now v4; its fingerprint is 9f8e7d6c5b4a. Record it wherever you keep these."*
- *"This baseline has been edited since v3 was sealed. Raise the version and seal it again, or run with
  -AllowUnsealed while you work on it."*

## Module load order

`Microsoft.Graph.Authentication` is imported and signed in to first, then `ExchangeOnlineManagement`.
Graph 2.x loads its own MSAL build in a separate context; importing it first lets Exchange Online's
different MSAL build load beside it. Probed on Graph 2.38.1 and ExchangeOnlineManagement 3.10.0 by
forcing MSAL initialisation in each order in a fresh process: both orders loaded without type-load
errors, and Graph-first showed both builds loaded side by side. The floors are Graph 2.x and Exchange
Online Management 3.x.

First live run: Graph signed in through the Windows broker (WAM), but Exchange Online's broker sign-in
failed with `NullReferenceException` in MSAL's `RuntimeBroker..ctor` (no parent window). Exchange Online
and Security & Compliance therefore connect with `-DisableWAM`, a browser sign-in. Whether that works
end to end still wants a second live run; record the result here.

## Session hygiene

Credentials and sessions are treated as hazardous. `Connect-MbcSources` closes any Graph and Exchange
sessions already open in the process before signing in, and closes everything again if sign-in fails
part-way. Graph connects with `-ContextScope Process`, so its token cache never reaches disk.
`Invoke-MbcDisconnectAll` (Exchange, then Graph; Graph with `-SignOutFromBroker` unless Exchange
Online's module is loaded, where that always fails, so the operator is told what Windows may remember
instead) runs when the view quits,
on account switch, and at the end of `Invoke-BaselineCheck` and `New-BaselineCapture`. Keep it that
way: no new path may sign in without a matching sign-out.

## Gates

- Before every commit: `pwsh -NoProfile -File tools/Invoke-Gate.ps1`. Pester (entirely offline) and
  PSScriptAnalyzer with the repository's settings. Fix findings; never suppress one.
- `pwsh -NoProfile -File tools/Start-Demo.ps1` runs the TUI against a synthetic tenant, nothing online.
- `pwsh -NoProfile -File tools/Export-TuiSnapshots.ps1` renders every screen to `docs/tui-snapshots/`.
- Files are UTF-8 without a BOM, with LF line endings.

## PowerShell traps met here

- A function that returns a list uses `return , $x`. Don't wrap such a call in `@(...)`: it double-wraps.
  Piping its result pipes the whole list as one object; parenthesise the call to unroll it.
- Variable names are case-insensitive, so a local `$application` is the parameter `$Application`.
- A script block passed to an engine function sees the engine's variables first (dynamic scope). Name
  captured variables distinctively; never `$Fetch` inside something passed as `-Fetch`.
- `.GetNewClosure()` loses module scope, so a closure can't call the module's private functions.
- `-like` treats `?` and `*` as wildcards; `StartsWith` doesn't.
- Typographic quotes in source are string delimiters to PowerShell; write them by code point.
