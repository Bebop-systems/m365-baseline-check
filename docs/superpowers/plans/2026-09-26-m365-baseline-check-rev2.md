# M365 Baseline Check, revision 2: implementation plan

> **For agentic workers:** executed inline with superpowers:executing-plans, at the owner's request
> (one session, no fan-out). Steps use checkbox (`- [ ]`) syntax for tracking. Each task is TDD: write
> the tests named, see them fail, implement, see them pass, run the gate, commit.

**Goal:** take the branch from "core built" to a tool the owner can demo: engine and sources, outputs,
capture, the TUI, and the handover files (spec §14 steps 2–7).

**Architecture:** collect, then evaluate. Collection goes through two guarded clients (GET-only Graph,
Get-only cmdlets); evaluation, rendering and export are pure functions over plain data. The TUI is a
pure `Format-MbcFrame` over a state hashtable plus a thin console loop; `report.txt` comes from the
same renderer.

**Tech Stack:** PowerShell 7.4+, Pester 5.5+, PSScriptAnalyzer; runtime modules
`Microsoft.Graph.Authentication` 2.x and `ExchangeOnlineManagement` 3.x, both optional at import.

**Spec:** [`../specs/2026-09-26-m365-baseline-check-design.md`](../specs/2026-09-26-m365-baseline-check-design.md), revision 2.
Raw material: [revision 1's plan](2026-09-26-m365-baseline-check.md), Tasks 8–18.

**On detail.** This plan pins names, signatures, decisions and test cases. It does not repeat code that
revision 1's plan already spells out where that code carries over; the task says which block to start
from and what changes.

## Global Constraints

- PowerShell 7.4 floor; module imports with no third-party module present.
- Only `Microsoft.Graph.Authentication` and `ExchangeOnlineManagement` beyond PowerShell itself.
- Files: UTF-8 without BOM, LF. Write with `[IO.File]::WriteAllText($p, $t, [Text.UTF8Encoding]::new($false))`.
- Invariant 7: `src/` never uses `Invoke-Expression`, `[scriptblock]::Create`, `Add-Type`, `Start-Process`,
  child PowerShell, `-EncodedCommand`, `Start-Job`, `Start-ThreadJob`, `[powershell]::Create()`, other
  runspaces, non-public reflection, `System.Reflection.Emit`.
- Invariant 9: no regular expressions in `src/` except the `matches` operator. That includes `-match`,
  `-replace`, `-split` (regex-based) and `[regex]`. `-like` and string methods are fine.
- Nothing identifying: synthetic GUIDs `00000000-0000-4000-8000-0000000000NN`, `example.com`,
  `example.onmicrosoft.com`, documented Microsoft IDs only.
- Commit trailer: exactly `Co-Authored-By: Claude <noreply@anthropic.com>` (spec §13). Gate green first.
- Output goes through `[Console]` in the TUI, never `Write-Host`. Voice: precise, brief, dry (§10.5).

## Review Focus

1. **A cmdlet source whose session isn't connected** (preset uses `exo`, sign-in to EXO failed or the
   module is missing): every `exo` check is `Error` / `not connected`; Graph checks still run. Test in Task 5.
2. **A tenant with zero objects for a cmdlet** (`Get-X` returns nothing): body is `{ "value": [] }`,
   `value[0].Foo` is `setting not found`, `length(value)` is 0. Test in Task 5.
3. **A narrow terminal (40 columns) and a very long title / label / app name:** every frame line fits,
   truncated with `…`. Test in Task 14.
4. **An inventory read that fails part-way** (grants 403, apps fine): inventory carries
   "Couldn't read consents: permission missing" and still lists apps. Test in Task 7.
5. **A throttled request in the TUI:** the wait sleeps in slices and calls the tick callback, so the
   spinner moves; a `Retry-After` of 120 is capped. Test in Task 4.

---

## File map (new or changed)

```
src/Common/Paths.ps1        output root, run IDs, stamps
src/Common/Text.ps1         width, pad, limit, style, wrap: shared by report and TUI (no regex)
src/Baseline/Shape.ps1      rev-2 validation                                  (changed)
src/Baseline/Capture.ps1    draft a baseline, all sources
src/Checks/PathQuery.ps1    hand-written scanner                              (changed)
src/Checks/Engine.ps1       plan / collect / evaluate, keyed by source
src/Sources/Scope.ps1       moved from src/Graph; no regex                    (moved)
src/Sources/Graph.ps1       transport function, GET client, paging, throttling
src/Sources/Cmdlet.ps1      guard, runner, flattening, session modules
src/Sources/Connect.ps1     sign-in and disclosure
src/Inventory/Apps.ps1      inventory reads (I/O) and shaping (pure)
src/Log/Logger.ps1          JSON lines
src/Report/Result.ps1       sealed result document
src/Report/Export.ps1       result.csv, apps.csv, export orchestration
src/Report/Text.ps1         grouped results renderer; report.txt
src/Report/Summary.ps1      redacted markdown
src/Report/Lock.ps1         team key, bundle encryption
src/Tui/Terminal.ps1 Widgets.ps1 Screens.ps1 Runtime.ps1
src/Public/*.ps1            Invoke-BaselineCheck, Start-BaselineCheck, New-BaselineCapture, New-ResultKey, Unlock-Result
tools/Export-TuiSnapshots.ps1  tools/Start-Demo.ps1
presets/example-*.json      CLAUDE.md  .github/workflows/ci.yml
```

## Shared data shapes

- **Plan item** `Mbc.PlanItem`: `{ Key; Source ('graph'|'exo'|'compliance'); ApiVersion; Request; Parameters (ordered, may be empty) }`.
  Key: `graph|<apiVersion>|<request>` or `<source>|<cmdlet lower>|<canonical JSON of parameters>`.
- **Fetch result** `Mbc.FetchResult`: `{ Ok; Body; Status; Cause; Detail; Pages }` (rev-1, unchanged).
- **Fetch** script block: `param($Item)` → fetch result. Tests inject; production composes Graph and cmdlet clients.
- **Check result** `Mbc.CheckResult`: `{ Id; Title; Area; Location; Severity; Why; Source; Request; Parameters; ApiVersion; Operator; Expected; Actual; HasActual; Verdict ('Pass'|'Fail'|'Error'); Cause; Detail; Labels }`.
- **Areas**, fixed order: `entra` Entra, `exchange` Exchange, `intune` Intune, `purview` Purview, `defender` Defender, `admin` Microsoft 365 admin.
- **Verdict words:** Pass → *Met* (✓), Fail → *Not met* (✗), Error → *Unverifiable* (?). ASCII: `+`, `x`, `?`.
- **Connection** `Mbc.Connection`: `{ Account; TenantId; TenantName; Scopes; WriteScopes; Roles; Sessions (ordered: source → module name); Failed (ordered: source → message); Disclosure (string[]) }`.
- **Inventory** `Mbc.Inventory`: `{ Collected (bool); ThirdParty (app[]); Own (app[]); FirstPartyCount; Failures (string[]) }`;
  app: `{ Kind ('third-party'|'own'); DisplayName; Publisher; Verified; AppId; Enabled; AssignmentRequired; Delegated ({ Type ('admin'|'user'); Resource; Scopes[]; Users }[]); Application ({ Resource; Roles[] }[]) }`.

---

### Task 1: Realign (spec §14 step 2)

**Files:** `src/Baseline/Shape.ps1`, `src/Common/Causes.ps1`, `src/Checks/PathQuery.ps1`,
`git mv src/Graph/Scope.ps1 src/Sources/Scope.ps1`, `M365BaselineCheck.psm1` (loader dirs),
`src/Baseline/Baseline.ps1` (fingerprint hex check, `StartsWith` ordinal), fixtures, tests
`tests/Shape.Tests.ps1`, `tests/Operators.Tests.ps1`, new `tests/Hygiene.Tests.ps1`.

- [ ] Tests first:
  - Shape: drop the extractor test; add: `area` required and one of the six; `location` text;
    `labels` an object of string → string; `source` one of three; `parameters` only with a cmdlet
    source, scalar values only; cmdlet request must start `Get-` and be declared under its source in
    `preset.cmdlets`; Graph request must be under `endpoints`; `endpoints` may be empty when no Graph
    check; `cmdlets` keyed only by `exo`/`compliance`, each name `Get-`; `apiVersion` refused on a
    cmdlet check; `scopes` may be empty.
  - Causes: exactly §7.4's seventeen, in order.
  - Hygiene: (a) politeness — `src/` contains none of invariant 7's constructs (`IndexOf`, ordinal
    ignore-case); (b) no regex in `src/` outside `Operators.ps1`: none of `-match`, `-notmatch`,
    `-cmatch`, `-imatch`, `-replace`, `-creplace`, `-split`, `[regex]`, `Select-String`,
    `RegularExpressions` (Operators.ps1 may use `[regex]::new` and `RegularExpressions`).
- [ ] Implement: string-method rewrites (id charset loop, request checks, `..` via `Contains`,
  endpoint check, seal hex loop, `IndexOf('?')`); `Scope.ps1` split on `.` with the same accept/reject
  table; `PathQuery.ps1` character scanner (names: `[A-Za-z_@$][A-Za-z0-9_@$-]*` or `"quoted"`;
  brackets `[*]`, `[int]`, `[?name op literal]`; `length( … )`), integers via `[long]::TryParse` with
  invariant culture after a digit-only check. Loader order: `Common Baseline Checks Sources Inventory Log Report Tui Public`.
- [ ] Fold in: `-ExpectedFingerprint` uses `StartsWith(…, Ordinal)`; Protect-Baseline writes to a
  temp file then moves; the three missing Baseline tests (malformed seal, nested reorder, Test-Baseline sealed).
- [ ] Gate, commit `refactor: realign validation with revision 2, and drop regular expressions`.

### Task 2: Engine, keyed by source; paths

**Files:** `src/Checks/Engine.ps1`, `src/Common/Paths.ps1`, fixtures `tests/fixtures/graph/*.json`,
`tests/fixtures/cmdlet/*.json`, fixture preset/baseline gain an `exo` check; `tests/Engine.Tests.ps1`.

Interfaces (produces): `New-MbcFetchResult`, `Get-MbcRequestKey -Source -ApiVersion -Request -Parameters`,
`Get-MbcRequestPlan -Preset` → `Mbc.PlanItem[]` (dedup, check order, undeclared excluded),
`Invoke-MbcCollection -Plan -Fetch [-OnProgress]` → hashtable key → fetch result (progress
`{ Phase; Index; Total; Item }`), `Invoke-MbcEvaluation -Preset -Expected -Collected [-OnResult]`,
`Get-MbcCounts`, `Invoke-MbcRun -Baseline -Fetch [-OnProgress] [-OnResult] [-RunId] [-Inventory <scriptblock>]`
→ `Mbc.Run { RunId; StartedUtc; FinishedUtc; Results; Counts; Inventory }`.
`Get-MbcOutputRoot`, `New-MbcRunId`, `Get-MbcRunStamp` (string methods, no `-split`).

- [ ] Tests (rev-1 Task 8 set, adapted): plan dedups by source+request+parameters (same cmdlet,
  different parameters → two items; same → one); fetch once; fixture checks pass; Fail records actual;
  failed collection never Pass for any operator; missing setting; progress and streaming; an undeclared
  request is `Error` / `request not declared`; a cmdlet check reads `value[0].X` from a cmdlet body.
- [ ] Implement from rev-1 Task 8 code, keyed as above. Gate, commit.

### Task 3: Run log

Rev-1 Task 9 with: every line carries `baseline` (full digest, per §11) and `fingerprint`; the secret
key test uses a list of lowercase fragments and `Contains` (no regex); logs sources and parameters.
Tests: rev-1's four plus "a line records source and parameters". Commit.

### Task 4: Graph client

**Files:** `src/Sources/Graph.ps1`, `tests/Graph.Tests.ps1`, `tests/ReadOnly.Tests.ps1`.

- `Invoke-MbcGraphTransport -Uri` → `{ Status; Body (string); RetryAfter }`. **The only** caller of
  `Invoke-MgGraphRequest`, with the literal `-Method GET`, `-OutputType Json -SkipHttpErrorCheck
  -StatusCodeVariable -ResponseHeadersVariable`.
- `Invoke-MbcGraphGet -ApiVersion -Request [-Transport <scriptblock param($Uri)>] [-OnWait <scriptblock param($Seconds,$Elapsed)>] [-Log]`.
  No method parameter. Paging capped at 200 pages; nextLink must be https on graph.microsoft.com.
  429/503/504 retried up to 3 times, `Retry-After` honoured and capped at 30 s, otherwise 2^n.
- `Wait-MbcSeconds -Seconds [-OnTick]`: sleeps in 100 ms slices, calling `OnTick` each slice.
- Tests: rev-1 Task 10's client set (minus background), plus: waits call OnTick repeatedly; a 120 s
  `Retry-After` waits 30; request validation uses string methods.
- ReadOnly test: `Invoke-MgGraphRequest` appears exactly once in `src/`, on a line with `-Method GET`,
  inside `Invoke-MbcGraphTransport`; no `Invoke-RestMethod|Invoke-WebRequest|HttpClient|WebClient`;
  no write method names; the only `@Parameters` splat invocation of a command object is in
  `Invoke-MbcCmdletRunner` (added in Task 5, test skips until then — no: Task 5 adds the assertion).

### Task 5: Cmdlet client and flattening

**Files:** `src/Sources/Cmdlet.ps1`, `tests/Cmdlet.Tests.ps1`, ReadOnly test extended.

- `ConvertTo-MbcFlatValue -Value` (scalar rules of §6.2), `ConvertTo-MbcFlatObject -InputObject` →
  ordered map, `ConvertTo-MbcCmdletBody -Output` → `[ordered]@{ value = @(...) }`.
- `Test-MbcCmdletName -Name` → Get- prefix plus `Verb-Noun` letters/digits only.
- `Invoke-MbcCmdletRunner -Command <CommandInfo> -Parameters <hashtable>`: `& $Command @Parameters -ErrorAction Stop`.
  The only place a cmdlet runs.
- `Invoke-MbcCmdletGet -Item -Preset -Sessions [-Runner <scriptblock param($Command,$Parameters)>] [-Log]`:
  guard (name; declared under source; `Sessions[source]` present else `not connected`; resolves by
  `Get-Command -Name -Module <session module> -CommandType Function,Cmdlet` to exactly one, else
  `cmdlet not available`; parameter names exist; values scalar) → run → flatten. A throw is
  `cmdlet failed`, with the exception's type and message in Detail; access-denied wording maps to
  `permission missing`.
- Tests: flattening of each kind (null, string, bool, int, double, enum, date → ISO UTC, guid, timespan,
  list with a complex item → ToString, hashtable, other object → ToString); zero / one / many
  objects → `value` list; the guard refuses non-Get, undeclared, wrong module, unknown parameter,
  non-scalar value — **and the runner is never called**; not connected; success path using a real
  function in a test-made module (`New-Module` in the test file only).

### Task 6: Sign-in and disclosure

**Files:** `src/Sources/Connect.ps1`, `tests/Connect.Tests.ps1`.

- Thin wrappers (mocked in tests): `Test-MbcModuleAvailable -Name`, `Import-MbcSourceModules -Sources`
  (load order from the coexistence probe), `Invoke-MbcConnectMgGraph -Scopes`, `Get-MbcMgContext`,
  `Invoke-MbcConnectExchange -Source -UserPrincipalName`, `Get-MbcExchangeConnections`,
  `Invoke-MbcDisconnectAll`.
- `Get-MbcSignInScopes -Preset` → preset scopes ∪ `Application.Read.All`, `Directory.Read.All`, `User.Read`; refuses non-read.
- `Get-MbcPresetSources -Preset` → distinct cmdlet sources used by checks.
- `Get-MbcSessionModuleName -Connection` → module leaf name from `ModuleName` (may be a path).
- `Connect-MbcSources -Preset [-Log] [-Transport]` → `Mbc.Connection`. Graph first; roles via
  `/me/transitiveMemberOf/microsoft.graph.directoryRole`; tenant name via `/organization`; then each
  cmdlet source with the Graph account as UPN; a failed cmdlet source is recorded, not fatal.
- `Format-MbcDisclosure -Connection` → lines incl. "Read-only by construction: GET-only Graph, Get- cmdlets only."
- **Coexistence probe** (manual, recorded in CLAUDE.md): import both modules in each order in a fresh
  pwsh and force MSAL initialisation; pick the order that doesn't raise a type-load error.
- Tests: scopes union and refusal; write scopes marked in disclosure, never refused; exo connect uses
  the Graph UPN; a failed exo connect is recorded and the run continues; roles unreadable → "roles
  couldn't be read" in disclosure; module missing only matters when a cmdlet source is used.

### Task 7: App inventory

**Files:** `src/Inventory/Apps.ps1`, fixtures `tests/fixtures/inventory/*.json`, `tests/Inventory.Tests.ps1`.

- `$script:MbcMicrosoftTenants`: `f8cdef31-a31e-4b4a-93e4-5f571e91255a` (Microsoft Services),
  `72f988bf-86f1-41af-91ab-2d7cd011db47` (Microsoft). Both documented; scrub-allowlisted.
- `Get-MbcAppInventoryData -Get <scriptblock param($Request)> ` → raw `{ ServicePrincipals; Applications; Grants; Assignments (hashtable spId → list); Resources (hashtable id → sp); Failures }` (I/O).
- `ConvertTo-MbcAppInventory -Data -TenantId` → `Mbc.Inventory` (pure).
- Tests: classification (third-party, own, first-party counted, not listed); admin vs user consent,
  user count distinct principals; application permissions resolved to role names; unknown role ID
  shown as the ID; partial failure keeps the rest and records the cause wording.

### Task 8: Result document and CSVs

`src/Report/Result.ps1`, `src/Report/Export.ps1` (CSV parts). Rev-1 Task 13 result doc extended with
area, location, labels, source, parameters, disclosure, inventory; `Test-MbcResultSeal`;
`ConvertTo-MbcResultCsv` (§10.4 columns + identity + run time); `ConvertTo-MbcAppsCsv`;
`Format-MbcCellValue` (formula neutralising); `ConvertFrom-MbcResultDocument` (rows + inventory back).
Tests: seal verifies and breaks on edit; identity; CSV rows; apps CSV one row per app × permission,
apps without permissions get one row; formula neutralising; round trip.

### Task 9: Text report and summary

`src/Common/Text.ps1`, `src/Report/Text.ps1`, `src/Report/Summary.ps1`.
- Text helpers (no regex): `Format-MbcStyle`, `Measure-MbcWidth` (skips `ESC [ … letter`), `Limit-MbcText`,
  `Format-MbcPad`, `Split-MbcWrapped`, `Remove-MbcAnsi`.
- `Format-MbcDisplayValue -Value -Labels` → label for a scalar by its canonical JSON, else short JSON.
- `Get-MbcAreaGroups -Results` → ordered groups `{ Area; Name; Results; Met; NotMet; Unverifiable }`.
- `Format-MbcResultRow -Result -Width -Glyphs -Color` → `✗ Not met  Title   actual → expected`.
- `Format-MbcGroupHeading -Group -Width -Glyphs -Color` → `Exchange  9 met · 2 not · 1 unverifiable`.
- `Format-MbcAppsTable -Inventory -Width -Glyphs -Color` → lines.
- `ConvertTo-MbcTextReport -Document -Width 100` → header, grouped all rows, detail blocks, inventory.
- `ConvertTo-MbcSummaryMarkdown -Document -Baseline` → §10.4, built only via `Get-MbcSummarySource`
  (check IDs, verdicts, causes, baseline text, third-party names/publishers/permissions, own count).
- Tests: report at width 100 never wider; contains digest, disclosure line, every check ID, detail
  for Not met; summary front matter with full digest and per-area counts; **redaction**: seeded
  sentinels (tenant GUID, domain, UPN, policy name, own-registration name, app IDs) absent.

### Task 10: Lock, unlock, export

`src/Report/Lock.ps1` (rev-1 Task 14, bundle payload `{ "result.json", "result.csv", "apps.csv", "report.txt", "summary.md" }`,
key text parsed with string methods), `Export-MbcRunFiles -Document -Baseline -Directory [-KeyText] [-NoLock] [-LockSummary]`,
`New-ResultKey`, `Unlock-Result -Path [-Key] [-OutputDirectory]`, `Open-MbcLockedResult`.
Tests: rev-1 lock set; export default refuses without a key; `-NoLock` writes five parts; locked
writes `.locked` + `summary.md` only; `-LockSummary` writes only `.locked`; unlock to memory and to disk.

### Task 11: `Invoke-BaselineCheck`

Rev-1 Task 15, reworked: plain output grouped by area (headings with counts, every row, then the
one-line summary in the voice of §10.5), `-Export` (locked unless `-NoLock`), `-SkipAppInventory`,
hidden `-Fetch`, `-Connection`, `-InventoryData` seams. Tests: rev-1 set adapted, plus grouping order
and inventory in the result.

### Task 12: Capture, all sources

Rev-1 Task 12 over the new plan items; cmdlet checks captured the same way; `New-BaselineCapture`
signs in via `Connect-MbcSources`. Tests: rev-1 set plus an `exo` check captured.

### Task 13: TUI primitives

`src/Tui/Terminal.ps1` (capability, glyphs incl. ASCII, no regex), `src/Tui/Widgets.ps1` (progress bar
eighth cells, spinner, box, menu, table, footer, verdict tag with words). Rev-1 Task 16 tests, adapted
to Met / Not met / Unverifiable.

### Task 14: TUI screens

`src/Tui/Screens.ps1`: state, key map (§10.2 keys), navigation, frames for home (header with tenant,
sessions, baseline, sealed flourish; menu with inventory toggle), run, results (grouped, attention by
default, met groups collapsed; `f`/`e`/`a`), detail, apps, app detail, chooser, prompt, panel, help.
`tools/Export-TuiSnapshots.ps1` writes `docs/tui-snapshots/`. Tests: rev-1 Task 17 set adapted, plus
grouping, default filter, apps screen, 40-column fit.

### Task 15: TUI runtime, `Start-BaselineCheck`, demo

`src/Tui/Runtime.ps1` (no runspaces: progress and throttling ticks redraw), `Start-BaselineCheck`
with hidden `-Fetch`, `-Connection`, `-InventoryData` seams; plain fallback. `tools/Start-Demo.ps1`
runs the TUI against a synthetic tenant from `tests/fixtures/demo/`, with small delays so the spinner
and bar are visible. Tests: rev-1 Task 18 effect set adapted.

### Task 16: Handover

Example preset and sealed baseline in `presets/` (Graph checks in entra, `exo` checks in exchange,
admin/intune/defender where Graph exposes a generic setting); `tests/Examples.Tests.ps1` (they
validate, the baseline is sealed, checks span ≥ 3 areas); `tests/Scrub.Tests.ps1` + allowlist;
`CLAUDE.md` per §12; README; `.github/workflows/ci.yml` (pull_request, workflow_dispatch; Windows,
Linux). No push.
