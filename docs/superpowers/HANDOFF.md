# Handoff: where the build stands

This is for the Claude session that picks up implementation. Read it, then the spec. Delete this file
in the final handover commit, before the first push.

## Read in this order

1. **[Spec, revision 2](specs/2026-09-26-m365-baseline-check-design.md).** It is the authority. §14 is
   the delivery order.
2. **This file.** What exists, what is reusable, and the rules of the repository.
3. **[Revision 1's plan](plans/2026-09-26-m365-baseline-check.md).** Read it **as raw material only**.
   Tasks 1–6 are built. Task 7 (extractors) was built, then reverted. Tasks 8–19 predate revision 2:
   parts are reusable, as mapped below, but none of them should be executed as written.

**Next action:** write a new plan with `superpowers:writing-plans` for spec §14 steps 2–7, starting
from the branch as it is. Execute it with `superpowers:subagent-driven-development`, one task at a
time with review, the way Tasks 1–6 were done.

## Branch state

- The branch is `build/v0.1.0`, cut from `main`, which holds only the spec and the revision-1 plan.
- Nothing is pushed, and there is no remote yet. The owner says where and when to push; the first
  push is at the handover milestone.
- The gate is green: `pwsh -NoProfile -File tools/Invoke-Gate.ps1` gives **141 passed, 0 failed, 0
  analyser findings**.

| Commit(s) | What |
|---|---|
| `5c465fe` `baa5d04` | Scaffold: manifest and loader, `tools/Invoke-Gate.ps1`, `PSScriptAnalyzerSettings.psd1`, `.gitattributes` (LF), `.gitignore`, LICENSE, README stub, `tests/Module.Tests.ps1` |
| `30ece1f` `8db4c73` | `src/Baseline/Canonical.ps1`: strict JSON parsing into ordered dictionaries, canonical JSON, pretty JSON, SHA-256. Keys that differ only in letter case are refused, by design. |
| `01fb3d2` | `src/Common/Sentinel.ps1` (`$script:MbcNotFound`), `src/Common/Values.ps1` (type tests, scalar equality), `src/Checks/PathQuery.ps1` (the select language) |
| `1896a60` `8bdd570` | `src/Common/Causes.ps1`, `src/Checks/Operators.ps1`. Lists and objects compare structurally, with the case rule. |
| `cb46664` `c0e3708` | `src/Graph/Scope.ps1` (`Test-MbcReadScope`, strict read-scope shape), `src/Baseline/Shape.ps1` (preset and baseline validation), fixtures `tests/fixtures/preset-minimal.json` and `baseline-minimal.json` |
| `d49e7bc` | `src/Baseline/Baseline.ps1` (`Get-MbcDocumentDigest`, `Read-MbcBaseline`, `Assert-MbcBaselineUsable`, `Get-MbcBaselineIdentity`), public `Protect-Baseline` and `Test-Baseline` |
| `b3fcf9a` `8d83fc7` `fdd6c46` | Extractors built, hardened, then **reverted** in `fdd6c46`. Nothing of them remains except the residue listed below. |

## The first task: realign (spec §14 step 2)

This is known work, and small enough for one task:
- **Remove extractor residue.**
  - In `Shape.ps1`, drop the `extractor` member, the exactly-one-of-select-or-extractor rule and the
    extractor path check. `select` becomes required.
  - Update the tests in `tests/Shape.Tests.ps1` to match.
- **Causes.** Set `Causes.ps1` to exactly spec §7.4's list: remove the two extractor causes, rename
  `endpoint not declared` to `request not declared`, and add `not connected`, `cmdlet not available`
  and `cmdlet failed`. Update `tests/Operators.Tests.ps1` if it pins the list.
- **Validation for revision 2** (spec §5.1 and §7.1):
  - `area` is required;
  - `location`, `labels`, `source` and `parameters` are optional;
  - `preset.cmdlets` is keyed by source, and each name starts with `Get-`;
  - a cmdlet-source check must be declared under its source, and a Graph check under `endpoints`;
  - `endpoints` may be empty when no check uses Graph;
  - the fixtures gain `area`.
- **Move `src/Graph/Scope.ps1` to `src/Sources/Scope.ps1`** with `git mv`, and check the loader
  still picks it up.
- **Regular expressions to string handling** (invariant 9). Every existing test must still pass
  unchanged, and the scope accept/reject table in `tests/Shape.Tests.ps1` especially. Sites:
  - `Shape.ps1`: the id check, the request check, `..` detection, the endpoint check, the seal digest
    hex check, and `-split '\?'` in `Test-MbcRequestDeclared`;
  - `Scope.ps1`: the strict shape. Split on `.` and test the segments, keeping exactly the same
    accept/reject behaviour;
  - `PathQuery.ps1`: the tokenizer becomes a character scanner. Integer detection uses a character
    loop or `[long]::TryParse` with invariant culture;
  - `Operators.ps1` keeps its regex for the `matches` operator, which is the allowed exception.
- **Politeness test.** Add a test that scans `src/` for invariant 7's constructs, using `-like` or
  `IndexOf`.

## Reusing revision 1's plan, task by task

| Rev-1 task | Status under revision 2 |
|---|---|
| 8. Engine | **Rework.** Plan and collect are keyed by source, request and parameters. Remove the extractor branch and `-ExtractorRoot`. The outcome rules and `New-MbcFetchResult` carry over. |
| 9. Paths, run IDs, log | **Mostly reusable.** `New-MbcRunLog -Baseline` puts the fingerprint on every line. Log sources and parameters too. |
| 10. Graph client and background | **Rework.** The transport becomes an ordinary function, the only caller of `Invoke-MgGraphRequest -Method GET`. **Drop** `Background.ps1`, `Invoke-MbcInBackground` and `New-MbcBackgroundInvoke`. Paging and throttling carry over; throttling waits sleep in short slices, with an optional tick callback. |
| (new) Cmdlet client | **New.** Spec §6.2: the guard, the `CommandInfo` invocation, `{ value: [...] }`, flattening, and the connection-module lookup. Settle module coexistence first (§6.2). |
| 11. Read-only assertion and sign-in | **Rework.** Sign-in to the sources in use; disclosure, not refusal. **No role allowlist.** |
| (new) App inventory | **New.** Spec §8. |
| 12. Capture | **Extend** to cmdlet sources. |
| 13. Result, CSV, summary | **Extend:** `area`, `location`, `labels`, the inventory in `result.json`, `apps.csv`, `report.txt`, and the summary per §10.4. |
| 14. Team key, lock | **Reusable.** The ciphertext becomes the bundle (§9). |
| 15. Plain output, `Invoke-BaselineCheck` | **Reusable, with grouping by area.** |
| 16–18. TUI | **Rework the results screen** (grouped, attention by default), **add the Apps screen and `i`**, and remove every background-runspace path and the fallback logic that depended on it. |
| 19. Handover | **Rework.** The example preset has checks in several areas, including an `exo` check, and no extractors. `CLAUDE.md` follows spec §12. |

## Repository rules

- **Public repository.** Nothing identifying, anywhere: code, comments, fixtures, docs or commit
  messages. GUIDs are synthetic (`00000000-0000-4000-8000-0000000000NN`) or documented Microsoft
  well-known IDs. Domains are `example.com` or `example.onmicrosoft.com`. Never name the owner, their
  organisation, their clients, their internal tools or any originating project. Say "the team's
  password manager" and "the team's knowledge base".
- **Commits.** The author is already set in the repository's local git config; don't change it. Each
  message ends with exactly one trailer, `Co-Authored-By: Claude <noreply@anthropic.com>`, and no
  other trailer: no session links. Commits are small, and the gate is green before each one. Scan the
  staged diff for secrets and identifying strings before committing.
- **Pushes.** None until the owner says. CI minutes matter, so test locally.
- **Files.** UTF-8 without BOM, and LF. Write with
  `[IO.File]::WriteAllText($p, $t, [Text.UTF8Encoding]::new($false))`. Check for a BOM or CR by
  reading bytes.
- **PowerShell traps met so far.**
  - A function that may return a list uses `return ,$x`. Never wrap such a call in `@(...)` at an
    assignment or `.Count`, because it double-wraps. Plain `=` never unwraps a leading comma.
  - `.GetNewClosure()` loses module scope, so don't use it on a block that calls a private function.
  - `[ordered]` dictionaries are case-insensitive.
  - .NET exceptions arrive wrapped, so use plain `catch` blocks.
  - `{ $x = … } | Should -Not -Throw` does not leak `$x` out of the block.
  - `$Event` is an automatic variable, so the logger parameter is `-EventName`.
- **Analyser settings** exclude exactly `PSUseBOMForUnicodeEncodedFile`, `PSUseSingularNouns` and
  `PSUseShouldProcessForStateChangingFunctions`. Fix every other finding minimally, and never
  suppress one.

## Carried-over review notes

These are minors parked for the whole-branch review. Fold in any that the work touches:
- `tools/Invoke-Gate.ps1` rebuilds its findings array on each addition.
- Tests import the module repeatedly.
- `Canonical.ps1` has an O(n²) key lookup and uses the `'R'` format for doubles.
- `Values.ps1` depends on `Canonical.ps1`, which is the wrong direction.
- `Operators.ps1`: unguarded `[long]` casts in `countAt*`.
- `Shape.ps1`: declared endpoints aren't URL-decoded before their own `..` check.
- `Baseline.ps1`: `-ExpectedFingerprint` should use `StartsWith(…, Ordinal)`.
- `Protect-Baseline` should write atomically: a temporary file, then a move.
- `tests/Baseline.Tests.ps1` lacks:
  - a malformed-`seal` read;
  - a nested key reorder;
  - `Test-Baseline` on a sealed file.
