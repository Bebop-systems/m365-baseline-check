# M365 Baseline Check: design

**Status:** approved in conversation on 2026-09-26; this document is for final review before an
implementation plan is written.

## 1. Purpose

A small, read-only PowerShell 7 tool that checks a Microsoft 365 tenant's configuration against an
expected baseline. It runs from a terminal interface (TUI) or non-interactively. The point is quick,
precise audits in PowerShell instead of walking through admin-centre GUIs.

The tool is a public engine. Organisation-specific presets and baselines are **not** part of this
repository. They are authored in a private copy (usually by a Claude session under a person's
direction) and distributed however a team shares files.

### What success looks like
- Anyone on a team can confirm, from any result they hold, **exactly which baseline version** it was
  checked against.
- A baseline that has been changed without being resealed is refused, and visibly so.
- A run gives a concise answer on screen and leaves an exhaustive log behind.
- Results can be filed encrypted at rest and reopened with one team key.
- A redacted summary can be handed to an AI assistant to update documentation, without exposing
  tenant data.
- Another Claude session can add presets from `CLAUDE.md` alone, mostly as data.

### Non-goals
No browser UI, no HTML report, no compliance mapping, no scores or percentages, no pricing, no
remediation, no writes to any tenant, no server component, no telemetry, and no third-party modules
beyond `Microsoft.Graph.Authentication`.

## 2. Invariants

These are not preferences. A change that seems to need breaking one is the wrong change.

1. **Read-only, at three layers.** The requested scopes are read scopes only. The granted scopes and
   directory roles are asserted at sign-in, failing closed on anything unrecognised. The Graph client
   accepts `GET` only.
2. **Error never becomes Pass.** A check that could not be completed is `Error`, reported and
   counted. There is no code path from a failed collection to `Pass`.
3. **Seal before use.** Only a sealed, unmodified baseline runs, unless `-AllowUnsealed` is given
   for authoring, in which case every output is stamped `UNSEALED`.
4. **Nothing identifying in this repository.** No internal presets or baselines, no real tenant IDs,
   domains, names or emails. A test enforces it (§11).
5. **Collect, then evaluate.** Collection does I/O and makes no judgements. Extraction and comparison
   are pure functions with no network access, so every check is testable offline.
6. **Secrets are never written.** No tokens, no authorization headers, no team key, in any log,
   result or file.

## 3. Nouns

| Noun | Is | Sensitive? |
|---|---|---|
| **Preset** | *What* to read and *how*: a list of checks with no expected values | No; examples ship here |
| **Baseline** | A preset's checks **plus expected values, sealed** into one self-contained file | Possibly; kept privately |
| **Result** | The outcome of one run against one baseline, sealed | Yes: contains tenant values |
| **Locked result** | A result encrypted with the team key | Protected at rest |
| **Summary** | A redacted Markdown digest of a result, safe to paste into an AI session | No tenant data by construction |
| **Team key** | 256 random bits shared through a team password manager | Secret |

## 4. Layout

```
M365BaselineCheck.psd1 / .psm1
src/
  Graph/      GraphClient.ps1   GET-only; paging; throttling retry with Retry-After
              Connect.ps1       sign-in, read-only assertion (§6)
  Baseline/   Canonical.ps1     canonical JSON (§5.3)
              Baseline.ps1      load, verify, seal
              Capture.ps1       draft a baseline from a reference tenant
  Checks/     Engine.ps1        collect → extract → compare
              PathQuery.ps1     the select language (§7.2)
              Operators.ps1     comparisons (§7.3)
  Tui/        Screen.ps1        alternate screen, key reading, fallback detection
              Widgets.ps1       menu, table, detail pane, progress bar, spinner
              Screens.ps1       home, run, results, detail, baseline, open-locked
  Log/        Logger.ps1        JSON-lines run log
  Report/     Export.ps1        CSV + JSON (sealed)
              Summary.ps1       redacted Markdown
              Lock.ps1          team-key encryption (§9)
presets/      example-*.json    generic, widely published settings only
extractors/   *.ps1             optional pure extractors for checks data cannot express
schemas/      preset.schema.json  baseline.schema.json  result.schema.json
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
  "preset": { "name": "…", "scopes": ["Policy.Read.All"], "checks": [ … ] },
  "expected": { "CA-001": "enabled", "AUTH-004": ["fido2", "microsoftAuthenticator"] },
  "seal": { "algorithm": "SHA-256", "digest": "<64 hex>", "sealedVersion": 3 }
}
```

Values in `expected` are restricted to JSON strings, booleans, integers, null, arrays and objects of
those. **No floating-point numbers**, so canonicalisation never depends on number formatting.

### 5.2 Identity

The **fingerprint** is the first 12 hex characters of the digest. It appears in:
- the TUI header, the console summary and every log line's context;
- every CSV row and JSON result;
- the summary's front matter;
- a locked result's readable header.

Full digests appear in the log and the JSON result.

### 5.3 Canonical form and the seal

The digest is SHA-256 over the UTF-8 bytes of the canonical JSON of the whole document **minus the
`seal` member**. Canonical form means:
- object keys sorted by ordinal string comparison;
- array order preserved;
- no insignificant whitespace;
- strings with minimal JSON escaping;
- integers in plain decimal.

Reformatting or reordering keys therefore leaves the digest unchanged, and any change of content
changes it.

### 5.4 Sealing rules (`Protect-Baseline`)
1. Validate against `baseline.schema.json`. Every check ID in `expected` must exist in
   `preset.checks`, and every check must have an expected value unless its operator is `exists` or
   `absent`.
2. If the file already carries a seal:
   - **Digest matches:** no change. Report *already sealed* and exit.
   - **Digest differs:** the content changed. Require `version > seal.sealedVersion`, or refuse with
     *"Content has changed since v3 was sealed. Raise the version before sealing."*
3. Write the seal, and print the line to record wherever baselines are catalogued:
   `Core tenant · v4 · SHA-256 <full digest>`.

### 5.5 Loading rules
- **Every load recomputes the digest.**
- **Missing or mismatched seal:** refuse, unless `-AllowUnsealed` is given.
- **`-ExpectedFingerprint <12+ hex>`:** refuse on mismatch before any network call.

### 5.6 Stated limit

A seal proves **integrity, not authorship**. Anyone who can edit a baseline can reseal it. Who is
allowed to change baselines is governed by where they are kept.

## 6. Connecting read-only

- **Sign-in:** delegated and interactive, via `Connect-MgGraph`, requesting exactly the scopes the
  baseline's preset declares.
- **Assertion:** after sign-in, the granted scopes are checked against the read shape
  (`Resource.Read[.Qualifier]` or `Resource.ReadBasic`, with no write verb in any qualifier). A write
  scope is tolerated only when every directory role the account holds, read transitively, is on a
  read-only role allowlist. **Unknown roles or undeterminable roles fail closed.** Data-plane write
  scopes such as `Mail.Send` fail regardless of roles.
- **Endpoints:** checks may only request paths under the preset's declared endpoints. A request
  outside them is an `Error`, never an attempt.
- **Why:** a delegated token carries every scope consented to the client application, so the
  assertion tests what the token can *do*, not only what was requested.

## 7. Checks

### 7.1 Shape

```json
{ "id": "AUTH-004", "title": "Allowed MFA methods",
  "request": "/policies/authenticationMethodsPolicy",
  "select": "authenticationMethodConfigurations[?state=='enabled'].id",
  "operator": "setEquals", "severity": "high",
  "why": "Only phishing-resistant and app-based methods should be enabled." }
```

Optional members:
- `"extractor": "extractors/<id>.ps1"`, in place of `select`;
- `"caseSensitive": true`;
- `"apiVersion": "beta"`. The default is `v1.0`, and beta use is shown in results.

Severity is one of `high`, `medium`, `low` or `info`.

### 7.2 The select language

This is deliberately small, and the whole grammar is documented in `CLAUDE.md`:

```
select   := path | 'length(' path ')'
path     := step ('.' step)*
step     := name ( '[*]' | '[' int ']' | '[?' name op literal ']' )?
op       := '==' | '!='
literal  := 'string' | integer | true | false | null
```

A path that resolves to nothing yields the sentinel **NotFound**, which the engine turns into an
`Error` ("setting not found"), except for the `absent` and `exists` operators.

An **extractor** is a script that receives the parsed response and returns a value. It must be pure.
A test parses every extractor and fails on network, file-system or process commands, from a closed
allowlist of permitted commands.

### 7.3 Operators

| Operator | Passes when |
|---|---|
| `equals` / `notEquals` | scalar equality |
| `in` | the actual scalar is one of the expected list |
| `contains` | the actual list contains the expected scalar |
| `setEquals` | the same members, ignoring order and duplicates |
| `subsetOf` | every actual member is in the expected list |
| `countAtLeast` / `countAtMost` | the length of the actual list, compared with an integer |
| `matches` | the actual string matches the expected regex (anchored by the author, not implicitly) |
| `exists` / `absent` | the path resolves / does not resolve |

String comparisons are ordinal and case-insensitive unless `caseSensitive` is true. A type mismatch,
such as `countAtLeast` on a scalar, is an `Error` ("baseline expects a list"), never a `Fail`.

### 7.4 Run flow and outcomes
1. **Collect.** Each distinct request is fetched **once**, whatever number of checks use it.
2. **Extract**, then **compare**, for each check. Both steps are pure.
3. **Outcomes:**
   - **Pass**
   - **Fail**, with the actual and expected values
   - **Error**, with a cause from a fixed vocabulary: *permission missing* (401/403), *not found*
     (404), *throttled* (429 after retries), *service error* (5xx), *malformed response*, *setting
     not found*, *extractor failed*, *baseline expects a list*, *endpoint not declared*

A collection failure makes every check depending on that request an `Error` with the same cause.

## 8. Logging and reporting

**The log** (verbose, for later) is JSON lines, one file per run, in the output folder. It records:
- **Identity:** the tool version, run ID, and baseline name, version and full digest.
- **Sign-in:** account, tenant, granted scopes, roles, and the assertion verdict with reasons.
- **Every request:** path, status, duration, pages, and throttling waits.
- **Every check:** the extracted value (truncated beyond 2 KB), operator, expected value, verdict and
  cause.

`-Verbose` mirrors it to the console.

**Exports** (concise, for now) go to the output folder, by default
`$HOME/M365BaselineCheck/results/`:
- **CSV:** one row per check, with ID, title, verdict, severity, expected, actual and request. Every
  row also carries the baseline's name, version and fingerprint, the tenant and the run time.
- **JSON:** the same, plus run metadata, **sealed** by the same canonical-digest method (§5.3), so a
  result can be verified untouched later.
- **Summary** (Markdown, redacted): YAML front matter with baseline identity, run time and counts,
  then a table of ID, setting, status and severity. Status is one of *Met*, *Not met* or *Couldn't
  verify: \<cause\>*. **It is built only from baseline text, verdicts and the fixed cause
  vocabulary.** It never reads response data, tenant identifiers, names or actual values, so it is
  safe to give an AI session whose surrounding context already identifies the client. It is not
  encrypted by default. It does contain the baseline's own wording, and a `-LockSummary` option
  exists for baselines whose titles are sensitive.

## 9. Locking results

**Team key.** `New-ResultKey` produces 32 random bytes, shown once as:

```
mbc-key:1:<keyId>:<base64url(32 bytes)>
```

The `keyId` is the first 8 hex characters of SHA-256 over the key bytes. It identifies the key
without revealing it. The key is kept in **one entry in the team's password manager**, named with
its key ID.

**The locked file** is `result-<UTC run time>.locked`, a JSON envelope. The filename is neutral: no
tenant or client name.

```json
{ "format": "m365bc-locked", "version": 1, "keyId": "3f2a9c1e",
  "header": { "baseline": { "name": "…", "version": 3, "fingerprint": "a1b2c3d4e5f6" },
              "runUtc": "…", "tool": "0.1.0" },
  "salt": "<16 bytes b64>", "nonce": "<12 bytes b64>", "tag": "<16 bytes b64>",
  "ciphertext": "<b64 of the JSON result + CSV + summary>" }
```

- **Per-file key:** HKDF-SHA256 over the team key, with the file's random salt and the info string
  `m365bc-result-v1`.
- **Encryption:** AES-256-GCM with a random nonce.
- **Associated data:** the canonical JSON of `format`, `version`, `keyId` and `header`. The readable
  header therefore cannot be altered unnoticed, and it shows *which baseline and which key* without
  unlocking.
- **Validation order:** the structure is checked first, before any cryptographic work. Every
  primitive comes from the .NET platform, and nothing is hand-rolled. A random 256-bit key needs no
  password stretching, so HKDF is used in place of a password-based KDF.

**Unlocking** is done with `Unlock-Result`, or from the TUI's *Open a locked result*:
- The key is pasted into masked input and held in memory for the session only, never written to
  disk.
- The result opens in the results viewer. Writing plaintext to disk is a separate, explicit choice.
- A wrong key or an altered file gets one refusal, never partial output.

**Rotation.** A new key gets a new ID, and every file names the ID it needs.

**Stated limit.** Everyone holding the key can read every result locked with it. That is the trade
for a single shared entry, sized for a team of a handful of people.

## 10. The TUI

**Screens:**
- **Home:** a header showing tenant, read-only status and baseline identity, then the menu.
- **Run:** a live progress bar, a spinner on the in-flight request, and results streaming in.
- **Results:** summary line, then a table with Fail and Error rows first.
- **Detail:** expected versus actual, request, why, and the log reference.
- **Choose baseline**, **Build or seal a baseline**, **Open a locked result**, **Sign in / switch
  account**.

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
| `f` / `e` / `a` | failures / errors / all |
| `/` | filter by text |
| `x` | export (lock by default) |
| `Home` / `End` / `PgUp` / `PgDn` | move by page |

A footer always shows the keys available on the current screen.

**Flair that costs nothing:**
- a Braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) on in-flight requests;
- a smooth block progress bar with eighth-cell resolution;
- a brief *sealed ✓* flourish on the header.

Every animation is purely cosmetic: rendering is decoupled from the engine, and nothing waits on it.

**Discipline:**
- **Every verdict is a word plus a symbol plus a colour**, so it reads correctly in greyscale.
- It adapts to the window width, truncating with `…`, and redraws on resize.
- It honours `NO_COLOR`.
- **It falls back to plain line output** when output is redirected, the host is non-interactive,
  virtual terminal support is missing, or the console encoding can't render the glyphs (ASCII
  equivalents are used then). `Invoke-BaselineCheck` always uses plain output.
- **Output goes through `[Console]`/`$Host.UI`, never `Write-Host`.** It is rendered by pure
  functions that return strings, so screens are unit-testable.

**Voice.** The readers are technical people with a background in writing and technology, who enjoy a
well-chosen word but are at work.
- Be precise, brief and dry.
- Occasional wit is fine; exclamation marks, cuteness and filler are not.
- Examples:
  - *"Sealed. The baseline is now v4; its fingerprint is 9f8e7d6c5b4a. Record it wherever you keep
    these."*
  - *"This baseline has been edited since v3 was sealed. Raise the version and seal it again, or
    run with -AllowUnsealed while you work on it."*
  - *"27 met, 3 not, 1 unverifiable. The unverifiable one wants AuditLog.Read.All."*

## 11. Testing and hygiene

**Pester, entirely offline**, against **synthetic** Graph fixtures in `tests/fixtures/`. It covers:
- operators and the path query, including grammar errors;
- the engine's outcome rules, including no path from a collection error to `Pass`;
- canonicalisation stability, seal and verify, and the version-bump rule;
- capture, against a mocked client;
- the read-only assertion's decision tables;
- lock and unlock round trips, a wrong key, and header tampering;
- extractor purity;
- TUI rendering as pure string output, with snapshot rows at two widths and in plain mode.

**Redaction test.** A fixture tenant seeded with sentinel values: a fake tenant GUID, a fake domain,
a fake user principal name and a fake policy name. The test fails if any of them appears in a summary.

**Scrub gate.** A test fails if any tracked file contains:
- a GUID, email address, domain or `*.onmicrosoft.com` name outside a small allowlist of obvious
  example values;
- any baseline or result file outside `presets/` and `tests/fixtures/`.

**Local gate before each commit:** `Invoke-Pester -CI` and `Invoke-ScriptAnalyzer` with the
settings file, run separately on `./src` and `./tools`. Commits are small and atomic.

**CI:** one workflow, on `pull_request` and `workflow_dispatch` only, on Windows and Linux. The
repository is public, so standard runners do not draw on any private-repository minute cap. Pushes
happen at milestones.

## 12. `CLAUDE.md` for customisation

It carries:
- the invariants (§2);
- the nouns (§3);
- how to add a preset, with a worked example on generic, widely published settings;
- the select grammar and operator table;
- how to write an extractor;
- capture → edit → seal;
- the voice guide (§10);
- the gate commands;
- **where internal presets and baselines must live:** a private copy, never this repository.

## 13. Attribution and licence

- **The one attribution the repository makes: Claude wrote the code.**
  - The README says the code was written by Claude (Anthropic's model), under human direction.
  - Every commit carries a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer.
- **Nothing else identifies anyone.** Commits are authored with a GitHub noreply address. No person,
  organisation, client, tenant or originating project is named anywhere: not in code, docs,
  fixtures, commit messages or examples.
- **Licence:** Apache-2.0.

## 14. Delivery

1. **Core:** canonical JSON, baseline seal and verify, the select language, operators, the engine
   against fixtures.
2. **Graph:** GET-only client, connect and read-only assertion, capture.
3. **TUI:** screens, keys, progress, fallback.
4. **Outputs:** log, CSV and JSON (sealed), redacted summary, lock and unlock.
5. **Handover:** `CLAUDE.md`, an example preset and baseline, the scrub gate, CI, README. Then the
   **first push**, when the public repository is created.

A live check against a real tenant happens only when the owner asks for it.
