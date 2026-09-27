# Handling results

What a run writes, how sensitive each part is, and how to keep it. The guidance follows common
practice for confidential business information and maps each rule to the SOC 2 Trust Services
Criteria it supports, so an organisation audited under SOC 2 can point to it.

**What this is not.** SOC 2 is an audit of an organisation's controls, and a Type 2 report covers
whether those controls operated over a period. A tool can't make anyone compliant. It can make the
right handling the easy default, and this page says what that handling is.

## How sensitive is it?

Moderate. A result is **confidential security configuration** about one tenant:

- which settings meet the baseline and which don't: a map of weak spots;
- the tenant's ID, name and default domain; the signing-in account and its directory roles; the Graph
  permissions granted;
- the third-party apps and the tenant's own app registrations, with their consents and grant IDs.

It holds **no credentials** (no tokens, passwords or keys), **no end-user content** (no mail, files or
chats) and **no end-user identities** (people who consented to an app are counted, not named). Nothing
in it lets anyone sign in. Together, though, it is a good reconnaissance sheet for an attacker, so
treat it like any internal security assessment.

| What | Where | Classification | At rest |
|---|---|---|---|
| Team key | the team's password manager | **Secret** | never on disk by this tool |
| Locked bundle, `result-<time>.locked` | `results/` | Confidential, **encrypted** | AES-256-GCM |
| `result.json`, `result.csv`, `apps.csv`, `report.txt` | inside the bundle; plaintext only with `-NoLock` or when unlocked to disk | **Confidential** | plaintext |
| Run log, `run-<time>.jsonl` | `logs/`, moved into the bundle when you export locked | **Confidential** | plaintext until then |
| `summary.md` | `results/` | **Internal** | plaintext, redacted by construction |
| Baselines and presets | `baselines/`, `presets/`, or your team's repository | **Internal** | plaintext: expected values, no tenant identity |

## The rules

**1. Keep the key and the data apart.** *(CC6.1, C1.1)*
The team key lives in one entry in the team's password manager, named with its key ID. Never save it
in a file, a note, a ticket or a chat, and never beside the bundles it opens. Rotate it when someone
who held it leaves: a new key has a new ID, and old bundles still name the key they need.

**2. Export locked.** *(CC6.1, C1.1)*
The default export is one encrypted bundle plus the redacted summary. Choose plaintext (`-NoLock`,
or an empty key in the view) only for a reason, and treat what it writes as confidential. A locked
bundle can be stored anywhere your policy allows encrypted files, including shared or cloud storage,
because it is useless without the key.

**3. Keep plaintext on an encrypted disk, out of synced folders.** *(CC6.1, CC6.7)*
Plaintext results and run logs belong only on a disk encrypted at rest, and never in a folder that
synchronises to the cloud, where copies multiply beyond your control.

- **macOS:** FileVault must be on. Check with `fdesetup status` (no admin needed) or System Settings ›
  Privacy & Security › FileVault. Synced locations to avoid: iCloud Drive
  (`~/Library/Mobile Documents/`), and `~/Desktop` and `~/Documents` when "Desktop & Documents Folders"
  is on in iCloud Drive settings; OneDrive, Dropbox, Google Drive and Box (under `~/Library/CloudStorage/`).
- **Windows:** BitLocker or Device Encryption must be on. Check with Settings › Privacy & security ›
  Device encryption, or `manage-bde -status` from an elevated prompt. Synced locations to avoid:
  OneDrive (including Desktop and Documents when OneDrive backs them up), Dropbox, Google Drive, Box.

The default output folder, `~/M365BaselineCheck`, is in neither kind of synced location. On macOS and
Linux the tool creates it readable by you alone (700), keeps `logs/`, `results/`, `presets/` and
`baselines/` at 700, and creates every file it writes at 600. A folder that already existed keeps its
mode, as do files written by an older version; `chmod 700 ~/M365BaselineCheck` and
`chmod 600 ~/M365BaselineCheck/*/*` tighten them.
If you point `M365BC_HOME` or `-OutputRoot` at a synced folder, the tool refuses to start, because the
run log is written in plaintext while a run goes. Choose a local folder instead; pass
`-AllowSyncedOutput` only if your policy explicitly allows confidential plaintext in that service.
To keep locked bundles in shared storage, copy them there after the export.

**4. Share the summary, not the result.** *(C1.1, CC6.7)*
`summary.md` is built so it can go to an AI assistant or into documentation: no tenant IDs, domains,
account names, own-registration names or actual values. Share results themselves only as locked
bundles, and share the key only through the password manager.

**5. Delete what you no longer need.** *(C1.2, CC6.5)*
Delete plaintext results and run logs when the work they support is done; 30 days is a sensible
ceiling unless your policy says otherwise. Keep locked bundles as long as your records policy requires,
and destroy them by deleting the key once none of them is needed. On an encrypted disk, ordinary
deletion is enough for this kind of data; for retired disks, follow your media sanitisation procedure
(NIST SP 800-88). The tool tells you when old plaintext logs are still in its folder; it never deletes
them for you.

**6. Remove what the sign-in left in the tenant.** *(CC6.2, CC6.3)*
Signing in to Graph can leave a delegated permission grant on Microsoft Graph Command Line Tools. The
tool shows it, with its ID, when you quit. If it was granted for this work, remove it:
[removing-consent.md](removing-consent.md).

## What the tool does for you

- Reads only: GET-only Graph, declared `Get-` cmdlets, read scopes (invariant 1).
- Closes every session on quit, on account switch and at the end of a plain run or capture; keeps
  Graph's token cache in the process only (see *Session hygiene* in CLAUDE.md).
- Never writes a token, an authorization header or the team key to any file.
- Exports locked by default, and moves the run log into the bundle when it does: the plaintext copy
  is deleted once the bundle is written. `Unlock-Result -OutputDirectory` gives it back as
  `run-<time>.jsonl`.
- Says where a run log stays in plaintext when it wasn't locked away (no export, or a plaintext one).
- Makes its output folders and files private to you on macOS and Linux.
- Refuses an output folder in iCloud Drive, OneDrive, Dropbox, Google Drive or Box unless told
  otherwise.
- Refuses to unlock plaintext into a synced folder, and never replaces a locked bundle.
- Tells you when plaintext logs or results older than 30 days remain: at the end of a plain run, and
  when the view opens and closes. It never deletes them for you.

## Checking a Mac before the first run

1. `fdesetup status` says `FileVault is On.`
2. `echo $HOME/M365BaselineCheck` is not under `~/Library/Mobile Documents` or
   `~/Library/CloudStorage`, and `~/Documents` isn't synced by iCloud if you chose a folder there.
3. After a run, `ls -la ~/M365BaselineCheck ~/M365BaselineCheck/logs` shows `drwx------` on the
   folders and `-rw-------` on the files. If the folder predates this version, tighten it first
   (see rule 3).
4. The team key is in the password manager, not in a note or the clipboard history.

## Reference

- SOC 2: AICPA Trust Services Criteria (2017, revised points of focus 2022): CC6.1 logical access and
  encryption, CC6.2–CC6.3 access provisioning and removal, CC6.5 disposal, CC6.7 transmission and
  movement of information, C1.1 identifying and maintaining confidential information, C1.2 disposing of it.
- CIS Controls v8, Control 3 (Data Protection): 3.1 data management, 3.6 encrypt data on end-user
  devices, 3.11 encrypt sensitive data at rest, 3.4 data retention.
- NIST SP 800-88 Rev. 1, Guidelines for Media Sanitization.
