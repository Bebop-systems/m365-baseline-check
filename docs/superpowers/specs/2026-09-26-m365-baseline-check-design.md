# M365 Baseline Check: design

**Status:** revision 2, approved in conversation on 2026-09-26. It replaces revision 1, and all
remaining implementation follows this revision. Revision 1's plan was built through its Task 6; the
remaining work is planned in [`../plans/2026-09-26-m365-baseline-check-rev2.md`](../plans/2026-09-26-m365-baseline-check-rev2.md).

**What changed in revision 2:**
- **Sources:** checks can read Exchange Online and Security & Compliance PowerShell as well as Graph (§6).
- **Sign-in:** it discloses what was granted, and no longer refuses (§6.3).
- **Extractors:** removed.
- **Politeness:** PowerShell that is polite under endpoint security becomes an invariant.
- **Data:** kept close to its source.
- **Reports:** familiar to administrators and grouped by admin centre (§10).
- **App inventory:** third-party and tenant-owned applications are listed with their consents (§8).
- **Exports:** a text report is added.

## 1. Purpose

A small, read-only PowerShell 7 tool that checks a Microsoft 365 tenant's configuration against an
expected baseline. It covers what administrators otherwise click through in the **Entra, Exchange,
Intune, Purview, Defender and Microsoft 365 admin centres**. It runs from a terminal interface (TUI)
or non-interactively. The point is quick, precise audits in PowerShell instead of walking through
admin-centre GUIs.

The tool is a public engine. Organisation-specific presets and baselines are **not** part of this
repository. They are authored in a private copy, usually by a Claude session under a person's
direction, and distributed however a team shares files.

### What success looks like
- Anyone on a team can confirm, from any result they hold, **exactly which baseline version** it was
  checked against.
- A baseline that has been changed without being resealed is refused, and visibly so.
- **Results read like the admin centres they came from.** They are grouped and named the way an
  administrator who lives in those portals expects, and they show only what was checked.
- A run gives a concise answer on screen and leaves an exhaustive log behind.
- Results can be filed encrypted at rest and reopened with one team key.
- A redacted summary can be handed to an AI assistant to update documentation, without exposing tenant
  identifiers.
- Third-party applications and their consents are listed with every run.
- Another Claude session can add presets from `CLAUDE.md` alone, as data.

### Non-goals
- No browser UI and no HTML report.
- No compliance mapping, no scores or percentages, no pricing.
- No remediation and no writes to any tenant.
- No server component and no telemetry.
- No third-party modules beyond `Microsoft.Graph.Authentication` and `ExchangeOnlineManagement`.
- No custom code per check. Checks are data only.

**Stated limit.** Some admin-centre and Defender portal settings have no supported API. Checks cover
what Graph and the Exchange Online and Security & Compliance PowerShell sessions expose, not every
switch in every portal. `CLAUDE.md` says so where presets are authored.

## 2. Invariants

These are not preferences. A change that seems to need breaking one is the wrong change.

1. **Read-only, enforced by this tool's code.**
   - The Graph client has exactly one call site, and it passes the literal `-Method GET`.
   - Cmdlet sources run only `Get-` cmdlets that the preset declares, resolved from that source's own
     session module, with plain scalar parameters (§6.2).
   - Requested Graph scopes are read scopes only.

   The signed-in account is expected to be able to write. The tool's safety never depends on the
   account being unable to.
2. **Error never becomes Pass.** A check that could not be completed is `Error`, reported and
   counted. There is no code path from a failed collection to `Pass`.
3. **Seal before use.** Only a sealed, unmodified baseline runs, unless `-AllowUnsealed` is given
   for authoring, in which case every output is stamped `UNSEALED`.
4. **Nothing identifying in this repository.** No internal presets or baselines, and no real tenant
   IDs, domains, names or emails. A test enforces it (§11).
5. **Collect, then evaluate.** Collection does I/O and makes no judgements. Selection and comparison
   are pure functions with no I/O, so every check is testable offline.
6. **Secrets are never written.** No tokens, no authorization headers and no team key, in any log,
   result or file.
7. **Polite PowerShell.** The tool runs on machines with endpoint detection, among a lot of other
   PowerShell, and should look like what it is: a plain module reading configuration.
   - `src/` never uses `Invoke-Expression`, `[scriptblock]::Create`, `Add-Type`, `Start-Process`,
     child PowerShell processes, `-EncodedCommand`, `Start-Job` or `Start-ThreadJob`,
     `[powershell]::Create()` or any other extra runspace, reflection over non-public members, or
     `System.Reflection.Emit`.
   - It downloads nothing and writes only under its output folder.
   - It changes no execution policy, registry value or persistent environment setting.
   - A test scans `src/` for these, using plain string matching.
8. **Data stays close to its source.**
   - Graph JSON is used as returned.
   - Cmdlet output is flattened once, to one level (§6.2), so a check reads what `Format-List` would
     show.
   - Nothing else reshapes, copies or enriches collected data.
9. **Plain string handling over regular expressions.** Regular expressions appear only where they
   are clearly the best tool: in the `matches` operator, which has a time limit, and in tests.
   Validation and parsing use string methods and character loops.

## 3. Nouns

| Noun | Is | Sensitive? |
|---|---|---|
| **Preset** | *What* to read and *how*: sources, declared requests, and checks with no expected values | No; examples ship here |
| **Baseline** | A preset's checks **plus expected values, sealed** into one self-contained file | Possibly; kept privately |
| **Source** | Where a check reads from: `graph`, `exo` (Exchange Online) or `compliance` (Security & Compliance) | No |
| **Area** | The admin centre a check belongs to, for grouping and wording: `entra`, `exchange`, `intune`, `purview`, `defender` or `admin` | No |
| **Result** | The outcome of one run against one baseline, including the app inventory, sealed | Yes: contains tenant values |
| **App inventory** | Third-party enterprise apps and the tenant's own app registrations, each with the consents granted to it | Yes |
| **Report** | The text rendering of a result, laid out like the TUI's results screen | Yes |
| **Locked result** | A result bundle encrypted with the team key | Protected at rest |
| **Summary** | A redacted Markdown digest, safe to paste into an AI session | No tenant identifiers by construction |
| **Team key** | 256 random bits shared through a team password manager | Secret |

## 4. Layout

Revision 1 already built the files marked ✓.

```
M365BaselineCheck.psd1 / .psm1         ✓ loader
src/
  Common/     Sentinel.ps1 Values.ps1 Causes.ps1                ✓
              Paths.ps1                output folder, run IDs
  Baseline/   Canonical.ps1 Shape.ps1 Baseline.ps1              ✓ (Shape gains sources, §5.1)
              Capture.ps1              draft a baseline from a reference tenant
  Checks/     PathQuery.ps1 Operators.ps1                       ✓
              Engine.ps1               plan → collect → select → compare
  Sources/    Scope.ps1                read-scope shape          ✓ (currently src/Graph/Scope.ps1; move it)
              Graph.ps1                GET-only Graph client; paging; throttling
              Cmdlet.ps1               Get-only cmdlet client for exo and compliance; flattening
              Connect.ps1              sign-in to the sources a preset uses; disclosure (§6.3)
  Inventory/  Apps.ps1                 app inventory collection (I/O) and shaping (pure)
  Log/        Logger.ps1               JSON-lines run log
  Report/     Export.ps1               result JSON (sealed) + CSV + apps CSV
              Text.ps1                 the text report (§10.4)
              Summary.ps1              redacted Markdown
              Lock.ps1                 team-key encryption (§9)
  Tui/        Screen.ps1 Widgets.ps1 Screens.ps1 Runtime.ps1
  Public/     Protect-Baseline.ps1 Test-Baseline.ps1            ✓
              Start-BaselineCheck, Invoke-BaselineCheck, New-BaselineCapture, New-ResultKey, Unlock-Result
presets/      example-*.json           generic, widely published settings only
schemas/      preset.schema.json baseline.schema.json result.schema.json
tests/        Pester; offline; synthetic fixtures under tests/fixtures/
CLAUDE.md     guide for a Claude session customising the tool
```

**Public commands:**
- `Start-BaselineCheck`: the TUI.
- `Invoke-BaselineCheck`: a non-interactive run in plain output.
- `New-BaselineCapture`: draft a baseline from a preset and a reference tenant.
- `Protect-Baseline`: validate and seal.
- `Test-Baseline`: verify a seal and print the baseline's identity.
- `New-ResultKey`: generate a team key.
- `Unlock-Result`: decrypt a locked result to memory, or to disk on request.

## 5. Baselines

### 5.1 Shape

```json
{
  "schemaVersion": 1,
  "name": "Core tenant",
  "version": 3,
  "description": "…",
  "preset": {
    "name": "…",
    "scopes": ["Policy.Read.All"],
    "endpoints": ["/policies/authorizationPolicy"],
    "cmdlets": { "exo": ["Get-OrganizationConfig"], "compliance": ["Get-DlpCompliancePolicy"] },
    "checks": [ … ]
  },
  "expected": { "CA-001": "enabled", "EXO-003": false },
  "seal": { "algorithm": "SHA-256", "digest": "<64 hex>", "sealedVersion": 3 }
}
```

- **`scopes`** lists the Graph scopes to request. Each must be a read scope. `Test-MbcReadScope`, built,
  keeps its accept and reject table; its implementation moves off regular expressions (invariant 9).
- **`endpoints`** lists the Graph paths checks may request, as now.
- **`cmdlets`** is optional. It is an object keyed by source (`exo`, `compliance`), and each value is
  a list of cmdlet names. Every name must start with `Get-`, which is checked with a string method.
- A preset that uses no Graph check may leave `endpoints` empty. `scopes` may then be empty too,
  **except** that the app inventory's scopes (§8) are always added at sign-in.

Values in `expected` are restricted to JSON strings, booleans, integers, null, arrays and objects of
those. **No floating-point numbers**, so canonicalisation never depends on number formatting.

### 5.2 Identity

The **fingerprint** is the first 12 hex characters of the digest. It appears in:
- the TUI header, the console summary and every log line;
- every CSV row and the JSON result;
- the text report's header and the summary's front matter;
- a locked result's readable header.

Full digests appear in the log, the JSON result, the text report and the summary.

### 5.3 Canonical form and the seal

The digest is SHA-256 over the UTF-8 bytes of the canonical JSON of the whole document **minus the
`seal` member**. Canonical form means:
- object keys sorted by ordinal string comparison;
- array order preserved;
- no insignificant whitespace;
- strings with minimal JSON escaping;
- integers in plain decimal.

Reformatting or reordering keys leaves the digest unchanged, and any change of content changes it.
This is built.

### 5.4 Sealing rules (`Protect-Baseline`, built)
1. The baseline is validated. Every check ID in `expected` must exist in `preset.checks`, and every
   check must have an expected value unless its operator is `exists` or `absent`.
2. If the file already carries a seal:
   - **Digest matches:** report *already sealed* and exit.
   - **Digest differs:** require `version > seal.sealedVersion`, or refuse.
3. Write the seal, and print the line to record wherever baselines are catalogued:
   `Core tenant · v4 · SHA-256 <full digest>`.

### 5.5 Loading rules (built)
- **Every load recomputes the digest.**
- **Missing or mismatched seal:** refuse, unless `-AllowUnsealed` is given.
- **`-ExpectedFingerprint <12+ hex>`:** refuse on mismatch before any network call.

### 5.6 Stated limit

A seal proves **integrity, not authorship**. Anyone who can edit a baseline can reseal it. Someone who
deletes the seal can also reseal changed content under the same version number. **The proof of which
version was used is the full digest recorded in the team's catalogue**, compared with the digest in
the result. The docs must never claim that the seal alone proves it.

## 6. Sources and sign-in

### 6.1 Graph (`graph`, the default source)
- `Invoke-MgGraphRequest -Method GET` is called from exactly one function, an ordinary function (no
  script text). The client has no method parameter, and tests inject a replacement transport.
- It handles paging (`@odata.nextLink`, capped), and throttling with `Retry-After` and a capped
  backoff.
- Requests must fall under a declared endpoint. They are URL-decoded before the `..` and endpoint
  checks, which is built in `Shape.ps1`.
- `apiVersion` is `v1.0` or `beta`. Beta is shown in results.

### 6.2 Cmdlet sources (`exo`, `compliance`)
- `exo` connects with `Connect-ExchangeOnline`; `compliance` connects with `Connect-IPPSSession`. Both come from
  `ExchangeOnlineManagement` 3.x, and the tool checks that the module is present only when a preset uses a
  cmdlet source.
- **A check's `request` is a cmdlet name**, with optional `"parameters"`: an object of scalar values
  (string, boolean or integer), for example `{ "Identity": "Default" }`.
- **Before a cmdlet runs, all of these must hold. Otherwise it is `Error`, and nothing runs:**
  - the name starts with `Get-`;
  - it is declared under that source in `preset.cmdlets`;
  - it resolves to a command **from the module that source's connection created**, recorded at
    connect time from `Get-ConnectionInformation`;
  - every parameter name exists on that command;
  - every value is a scalar.
- The cmdlet runs through its `CommandInfo` (`& $command @parameters -ErrorAction Stop`), never
  through a string. Each distinct cmdlet-and-parameters pair runs once per run.
- **Output shape.** The objects a cmdlet returns always become `{ "value": [ … ] }`, even when there is
  one object or none, so select paths don't depend on how many a tenant has:
  `value[0].AuditDisabled`, `value[?Name=='Default'].Enabled`.
- **Flattening, once, one level.** Each object becomes an ordered map of its properties, in property
  order:
  - `$null`, strings, booleans and integers are kept;
  - floating-point numbers are kept;
  - enums become their names;
  - dates become ISO 8601 UTC strings;
  - GUIDs and time spans become strings;
  - an enumerable (other than a string) becomes a list whose items are flattened as scalars, with
    anything complex shown as its `ToString()`;
  - a dictionary becomes a map of scalars;
  - any other object becomes its `ToString()`.

  This is what `Format-List` shows, and no more.
- **Module coexistence.** `ExchangeOnlineManagement` and `Microsoft.Graph.Authentication` have a
  history of assembly conflicts that depend on load order. The first client task finds a working
  order and version floor on a real machine, and the tool imports in that order. `CLAUDE.md` records
  the result.

### 6.3 Sign-in and disclosure
- The tool signs in **only to the sources the preset uses**, plus Graph for the app inventory:
  - Graph: interactive and delegated, via `Connect-MgGraph -Scopes <preset scopes + inventory
    scopes> -NoWelcome`.
  - `exo` and `compliance`: with the Graph account as the `-UserPrincipalName` hint, to avoid a
    second account picker.
- **No refusal on privilege.** Operators sign in with administrative accounts that can write. There
  is no role allowlist and no refusal over granted write scopes.
- **Disclosure.** The sign-in line and the log record:
  - the account and the tenant;
  - the directory roles, read transitively;
  - the granted Graph scopes, with write scopes marked;
  - the sessions connected;
  - the line *"Read-only by construction: GET-only Graph, Get- cmdlets only."*

  Revision 1's assertion design, with read-only role allowlists and failing closed, is withdrawn.
  Only its read-scope shape check (`Scope.ps1`) remains, and it governs what a *preset may request*.
- **Switching account** disconnects every session the tool opened.

## 7. Checks

### 7.1 Shape

```json
{ "id": "EXO-003", "title": "Mailbox auditing on by default",
  "area": "exchange", "location": "Settings › Mail flow",
  "source": "exo", "request": "Get-OrganizationConfig",
  "select": "value[0].AuditDisabled",
  "operator": "equals", "severity": "high",
  "labels": { "false": "On", "true": "Off" },
  "why": "Mailbox audit records are how access to a mailbox is reconstructed afterwards." }
```

Required members:
- `id`;
- `title`, which uses the portal's own wording for the setting;
- `area`;
- `request`;
- `select`;
- `operator`;
- `severity`: `high`, `medium`, `low` or `info`.

Optional members:
- `source`: `graph`, the default, or `exo` or `compliance`.
- `parameters`: cmdlet sources only; scalar values.
- `apiVersion`: `v1.0`, the default, or `beta`. Graph only.
- `location`: the portal breadcrumb where an administrator finds the setting, in the portal's words.
- `labels`: display text for scalar values, keyed by their canonical JSON text (`"true"`,
  `"\"enabled\""`, `"3"`), so values read the way the portal shows them. It affects display only,
  never comparison.
- `caseSensitive`: `true` or `false`.
- `why`: one sentence.

### 7.2 The select language (built)

```
select   := path | 'length(' path ')'
path     := step ('.' step)*
step     := name ( '[*]' | '[' int ']' | '[?' name op literal ']' )?
op       := '==' | '!='
literal  := 'string' | integer | true | false | null
```

A path that resolves to nothing yields the sentinel **NotFound**, which the engine turns into an
`Error` ("setting not found"), except for the `absent` and `exists` operators.

The parser currently uses regular expressions. Under invariant 9 it becomes a hand-written scanner,
with its existing tests unchanged and passing.

### 7.3 Operators (built)

| Operator | Passes when |
|---|---|
| `equals` / `notEquals` | equality: scalars directly; lists and objects structurally, with the same case rule |
| `in` | the actual scalar is one of the expected list |
| `contains` | the actual list contains the expected scalar |
| `setEquals` | the same members, ignoring order and duplicates |
| `subsetOf` | every actual member is in the expected list |
| `countAtLeast` / `countAtMost` | the length of the actual list, compared with an integer |
| `matches` | the actual string matches the expected regular expression, anchored by the author (1 s limit) |
| `exists` / `absent` | the path resolves / does not resolve |

String comparisons are ordinal and case-insensitive unless `caseSensitive` is true. A type mismatch is
an `Error`, never a `Fail`.

### 7.4 Run flow and outcomes
1. **Plan.** List the distinct requests, one per source, request and parameters (or API version).
2. **Collect.** Each distinct request is fetched **once**. Then the app inventory is collected (§8).
3. **Select**, then **compare**, for each check. Both steps are pure.
4. **Outcomes:** **Pass**; **Fail**, with the actual and expected values; or **Error**, with a cause.

**Causes, the closed vocabulary.** `Causes.ps1` is updated to exactly this list:
- permission missing
- not found
- throttled
- service error
- malformed response
- request rejected
- too many pages
- setting not found
- baseline expects a list
- baseline expects a single value
- invalid pattern
- pattern too slow
- request not declared
- not connected
- cmdlet not available
- cmdlet failed
- not collected

`endpoint not declared` becomes `request not declared`, which covers both kinds. `extractor failed`
and `extractor not allowed` are removed.

A collection failure makes every check that depends on that request an `Error` with the same cause.

## 8. The app inventory

It is collected on every run from Graph. It is facts, not checks: it has no verdicts and does not
affect counts. Its scopes, `Application.Read.All` and `Directory.Read.All`, are always added to the
Graph sign-in. `-SkipAppInventory`, or a toggle on the TUI home screen, leaves it out.

**Reads**, all `GET`:
- `/servicePrincipals`, with `$select` limited to `id`, `appId`, `displayName`,
  `appOwnerOrganizationId`, `publisherName`, `verifiedPublisher`, `servicePrincipalType`,
  `accountEnabled`, `tags` and `appRoleAssignmentRequired`;
- `/applications`, with `$select` limited to `id`, `appId`, `displayName`, `signInAudience`,
  `createdDateTime`, `publisherDomain` and `verifiedPublisher`;
- `/oauth2PermissionGrants`: delegated consents;
- `/servicePrincipals/{id}/appRoleAssignments`, for listed apps only: application permissions;
- `/servicePrincipals/{resourceId}`, with `$select` limited to `displayName`, `appRoles` and
  `oauth2PermissionScopes`: once per distinct resource, to turn permission IDs into names.

**Listed:**
- **Third-party enterprise apps.** A service principal whose `appOwnerOrganizationId` is neither this
  tenant nor a Microsoft first-party tenant. Microsoft's first-party tenant IDs are a short,
  documented list in code, and scrub-allowlisted.
- **This tenant's own app registrations.** Every `/applications` entry.
- **Microsoft first-party apps are not listed.** They are counted.

**For each listed app:**
- display name, publisher, verified-publisher status, app ID, enabled status, and whether assignment
  is required;
- **delegated consents:**
  - admin consent for all users: the resource and its scope names;
  - user consent: the resource, the scope names, and the number of users who consented;
- **application permissions:** the resource and the app-role names.

Individual consenting users are counted, not named.

**Collection failure.** Each inventory read that fails puts a cause on the inventory ("Couldn't read
consents: permission missing"). It never drops the inventory silently.

**Not in this revision.** Evaluating the inventory against an approved-apps list in a baseline is a
natural later addition.

## 9. Locking results (design unchanged; not yet built)

**Team key.** `New-ResultKey` produces 32 random bytes, shown once as
`mbc-key:1:<keyId>:<base64url(32 bytes)>`. The `keyId` is the first 8 hex characters of SHA-256
over the key bytes. The key is kept in **one entry in the team's password manager**, named with its
key ID.

**The locked file** is `result-<UTC run time>.locked`: a JSON envelope with a neutral filename.

```json
{ "format": "m365bc-locked", "version": 1, "keyId": "3f2a9c1e",
  "header": { "baseline": { "name": "…", "version": 3, "fingerprint": "a1b2c3d4e5f6" },
              "runUtc": "…", "tool": "0.1.0" },
  "salt": "<16 bytes b64>", "nonce": "<12 bytes b64>", "tag": "<16 bytes b64>",
  "ciphertext": "<b64 of the bundle>" }
```

- **The bundle** is a JSON object containing `result.json`, `result.csv`, `apps.csv`, `report.txt`
  and `summary.md`, each as text.
- **Per-file key:** HKDF-SHA256 over the team key, with the file's random salt and the info string
  `m365bc-result-v1`.
- **Encryption:** AES-256-GCM with a random nonce.
- **Associated data:** the canonical JSON of `format`, `version`, `keyId` and `header`.
- **Validation:** structure first, then cryptography. Every primitive comes from the .NET platform.

**Unlocking** is done with `Unlock-Result`, or from the TUI's *Open a locked result*:
- The key goes into masked input and is held in memory for the session only.
- The result opens in the results viewer. Writing plaintext to disk is a separate, explicit choice,
  and writes every part of the bundle.
- A wrong key or an altered file gets one refusal, never partial output.

**Rotation:** a new key has a new ID, and every file names the ID it needs.

**Stated limit:** everyone holding the key can read every result locked with it.

## 10. Presentation

### 10.1 Principle

**Familiar, then efficient.** Someone who spends their day in the admin centres should recognise
what they see immediately:
- the admin centres' names and order;
- the portal's words for each setting (`title`);
- where to find it (`location`);
- values as the portal shows them (`labels`).

Efficiency comes from showing **only what was checked**, and by default only what needs attention.
Raw JSON appears only in the detail view and the files.

### 10.2 The TUI

**Screens:**
- **Home:** a header with tenant, connected sessions and baseline identity, then the menu, with the
  app-inventory toggle.
- **Run:** a live progress bar, a spinner on the in-flight request, and results streaming in.
- **Results:** checks grouped by area, in this fixed order: Entra, Exchange, Intune, Purview,
  Defender, Microsoft 365 admin.
  - Each group heading carries its counts, for example `Exchange  9 met · 2 not · 1 unverifiable`.
  - **By default only Not met and Unverifiable rows show.** Each met group collapses to its heading.
  - A row is: verdict word and symbol, `title`, and for Not met, `actual → expected` rendered
    through `labels`.
- **Detail:** location, expected against actual, source and request, why, and the log reference.
- **Apps:** the app inventory as a table of name, publisher, verified status and consent summary,
  with the full consents in its own detail view.
- **Choose baseline**, **Build or seal a baseline**, **Open a locked result**, **Sign in / switch
  account**.

**Verdict words:** *Met*, *Not met*, *Unverifiable*, each shown with a symbol and a colour.

**Keys:**

| Key | Does |
|---|---|
| `↑` `↓` / `j` `k` | move |
| `Enter` | select or drill in |
| `Esc` / `Backspace` | back |
| `q` | quit |
| `?` | a help overlay listing every key on the current screen |
| `r` | run |
| `b` | choose baseline |
| `l` | last results |
| `o` | open a locked result |
| `i` | the app inventory |
| `f` / `e` / `a` | not met / unverifiable / all (the default shows not met and unverifiable) |
| `/` | filter by text |
| `x` | export (locked by default) |
| `Home` / `End` / `PgUp` / `PgDn` | move by page |

A footer always shows the keys available on the current screen.

**Flair:**
- a Braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`);
- a smooth block progress bar with eighth-cell resolution;
- a brief *sealed ✓* flourish on the header.

There is no background runspace (invariant 7). The spinner and the bar advance between requests and
pages, and keep animating through throttling waits, which sleep in short slices. During a single
long request the request line stays current but the spinner holds still. Every animation is
cosmetic, and nothing waits on it.

### 10.3 Discipline
- **Every verdict is a word plus a symbol plus a colour**, so it reads correctly in greyscale.
- It adapts to the window width, truncating with `…`, and redraws on resize.
- It honours `NO_COLOR`.
- **It falls back to plain line output** when output is redirected, the host is non-interactive,
  virtual terminal support is missing, or the console can't render the glyphs, in which case ASCII
  equivalents are used. `Invoke-BaselineCheck` always uses plain output.
- **Output goes through `[Console]`, never `Write-Host`.** It is rendered by pure functions that
  return strings, so every screen and the text report can be unit-tested.

### 10.4 Exports

`x` in the TUI, or `-Export` on `Invoke-BaselineCheck`, writes to the output folder (by default
`$HOME/M365BaselineCheck/results/`).

By default that is **one locked bundle** (§9) plus **`summary.md` in plain text**. `-NoLock` writes
the parts unencrypted instead.

- **`report.txt`**, the TUI's results screen as text. The same pure renderer produces it at a fixed
  width of 100 columns, with no colour. It holds:
  - a header with the baseline name, version, fingerprint and full digest, the tenant display name,
    the run time and the disclosure line;
  - the grouped results, all rows (not only the attention rows), each met group listed compactly;
  - a detail block for every Not met and Unverifiable check: location, expected, actual, request
    and why;
  - the app inventory, in the same layout as the Apps screen, with consents listed.
- **`result.json`**, sealed by the canonical-digest method: run metadata, every check with its
  actual and expected values, the disclosure, and the full app inventory.
- **`result.csv`**, one row per check: ID, area, title, location, verdict, severity, expected,
  actual, source, request, cause. Every row also carries the baseline's name, version and
  fingerprint, and the run time.
- **`apps.csv`**, one row per app and permission: app, publisher, verified, app ID, kind (third-party
  or own registration), permission type (delegated-admin, delegated-user or application), resource,
  permission names, and user count.
- **`summary.md`**, for an AI session that maps results onto internal documentation of verified
  baselines:
  - **Front matter:** the baseline's name, version, fingerprint and **full digest**; the run date;
    counts per area.
  - **Checks:** a table per area of check ID, title, location, status and severity. Status is *Met*,
    *Not met* or *Couldn't verify: \<cause\>*. Check IDs and the digest are the keys documentation
    maps onto.
  - **Third-party apps:** name, publisher, verified status, and permission names by type, with the
    user count for user consents.
  - **The tenant's own registrations:** a count only. Their names can identify an organisation.
  - **Redaction by construction.** It is built from baseline text, verdicts, the cause vocabulary,
    third-party app names, publishers and permission names. It **never** contains tenant IDs, app
    IDs, object IDs, domains, user principal names, own-registration names or actual values.
  - `-LockSummary` exists for baselines whose own wording is sensitive.

### 10.5 Voice

The readers are technical people with a background in writing and technology, who enjoy a
well-chosen word but are at work.
- Be precise, brief and dry.
- Occasional wit is fine; exclamation marks, cuteness and filler are not.

Examples:
- *"Sealed. The baseline is now v4; its fingerprint is 9f8e7d6c5b4a. Record it wherever you keep
  these."*
- *"This baseline has been edited since v3 was sealed. Raise the version and seal it again, or run
  with -AllowUnsealed while you work on it."*
- *"27 met, 3 not, 1 unverifiable. The unverifiable one wants AuditLog.Read.All."*

## 11. Logging, testing and hygiene

**The log** (verbose, for later) is JSON lines, one file per run, in the output folder. It records:
- **Identity:** the tool version, the run ID, and the baseline's name, version and full digest, the
  last on every line.
- **Sign-in:** the full disclosure (§6.3).
- **Every request:** the source, the request and parameters, the status or exception type, the
  duration, the pages, and throttling waits.
- **Every check:** the selected value (truncated beyond 2 KB), the operator, the expected value, the
  verdict and the cause.
- **The inventory:** counts per category and any read failures.

`-Verbose` mirrors the log to the console.

**Pester, entirely offline**, against synthetic fixtures: Graph JSON and flattened cmdlet output, with
cmdlet sources tested through an injected command runner. It covers:
- operators and the path query;
- the engine's outcome rules, including that a collection error has no path to `Pass`;
- canonicalisation, sealing and the version rule;
- the cmdlet guard: a non-`Get-` name, an undeclared name, a name from the wrong module, an unknown
  parameter and a non-scalar value are each refused **without running anything**;
- flattening;
- inventory classification: third-party, own, and first-party counted;
- lock and unlock;
- rendering, with snapshots at two widths, in plain mode, and `report.txt`.

**Polite-PowerShell test.** It fails if `src/` contains any construct listed in invariant 7.

**Read-only test.** It fails if:
- `Invoke-MgGraphRequest` appears outside the one transport function;
- that call lacks the literal `-Method GET`;
- any cmdlet is invoked other than through the guarded runner.

**Redaction test.** A fixture tenant is seeded with sentinel values: a fake tenant GUID, a fake
domain, a fake user principal name, a fake policy name, a fake own-registration name and fake app
IDs. The test fails if any of them appears in a summary.

**Scrub gate.** A test fails if any tracked file contains:
- a GUID, email address, domain or `*.onmicrosoft.com` name outside a small allowlist of example
  values and documented Microsoft well-known IDs;
- any baseline or result file outside `presets/` and `tests/fixtures/`.

**Local gate before each commit:** `pwsh -NoProfile -File tools/Invoke-Gate.ps1`, which runs Pester
and PSScriptAnalyzer with the settings file. Commits are small and atomic.

**CI:** one workflow, on `pull_request` and `workflow_dispatch` only, on Windows and Linux. Pushes
happen at milestones.

## 12. `CLAUDE.md` for customisation

It carries:
- the invariants and nouns;
- how to add a preset, with a worked example on generic, widely published settings in several
  areas, using at least one Graph check and one `exo` check;
- the sources, the declared `endpoints` and `cmdlets`, and the output shape of cmdlet sources;
- the select grammar and operator table, including that objects and lists compare structurally with
  the same case rule;
- `area`, `location` and `labels`, and why they matter (§10.1);
- capture → edit → seal, and the stated limit of the seal (§5.6);
- the voice guide;
- the gate commands and the module load order (§6.2);
- the stated coverage limit (§1);
- **where internal presets and baselines must live:** a private copy, never this repository.

## 13. Attribution and licence

- **The one attribution the repository makes: Claude wrote the code.**
  - The README says the code was written by Claude (Anthropic's model), under human direction.
  - Every commit carries exactly one trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`.
- **Nothing else identifies anyone.** Commits are authored with a GitHub noreply address. No person,
  organisation, client, tenant or originating project is named anywhere.
- **Licence:** Apache-2.0.

## 14. Delivery

1. **Core** (built): canonical JSON, seal and verify, the select language, operators, validation.
2. **Realign:** remove extractor residue, move string handling off regular expressions, and extend
   validation for sources, areas, labels and `cmdlets`.
3. **Engine and sources:** the engine against fixtures, then the Graph client, the cmdlet client
   with flattening, sign-in and disclosure, and the app inventory.
4. **Outputs:** the log, the result JSON and CSVs, the text report, the summary, and lock and unlock.
5. **Capture**, for all sources.
6. **TUI:** screens, keys, progress and fallback.
7. **Handover:** `CLAUDE.md`, an example preset and baseline, the scrub gate, CI and the README. Then
   the **first push**.

A live check against a real tenant happens only when the owner asks for it.
