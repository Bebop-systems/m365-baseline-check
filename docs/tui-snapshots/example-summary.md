---
baseline: "Example tenant hygiene"
version: 2
fingerprint: dc1e31c4226c
digest: dc1e31c4226c28d08bde60be3eb21704316c0c15f158a3697ae2e2e041078627
sealed: true
run: 2026-09-26
counts:
  entra: { met: 3, notMet: 3, unverifiable: 0 }
  exchange: { met: 3, notMet: 1, unverifiable: 0 }
  intune: { met: 2, notMet: 0, unverifiable: 1 }
  purview: { met: 1, notMet: 0, unverifiable: 1 }
  defender: { met: 3, notMet: 1, unverifiable: 0 }
  admin: { met: 1, notMet: 0, unverifiable: 0 }
---

# Example tenant hygiene v2

Checked against fingerprint `dc1e31c4226c`, digest `dc1e31c4226c28d08bde60be3eb21704316c0c15f158a3697ae2e2e041078627`. Tenant values are left out of this summary by design.

## Entra

| ID | Setting | Location | Status | Severity |
|---|---|---|---|---|
| ENTRA-001 | Users can register applications | Identity › Users › User settings | Not met | medium |
| ENTRA-002 | Users can create security groups | Identity › Groups › All groups › General | Met | low |
| ENTRA-003 | Guest invite restrictions | Identity › External Identities › External collaboration settings | Met | medium |
| ENTRA-004 | Guest user access restrictions | Identity › External Identities › External collaboration settings | Not met | medium |
| ENTRA-005 | Security defaults | Identity › Overview › Properties › Manage security defaults | Met | high |
| ENTRA-006 | Conditional Access policies that are on | Protection › Conditional Access › Policies | Not met | high |

## Exchange

| ID | Setting | Location | Status | Severity |
|---|---|---|---|---|
| EXO-001 | Mailbox auditing on by default |  | Met | high |
| EXO-002 | Modern authentication for Outlook | Settings › Org settings › Services › Modern authentication | Met | high |
| EXO-003 | Turn off SMTP AUTH protocol for your organization | Settings › Mail flow | Not met | medium |
| EXO-004 | External sender identification in Outlook |  | Met | low |

## Intune

| ID | Setting | Location | Status | Severity |
|---|---|---|---|---|
| INTUNE-001 | Mark devices with no compliance policy assigned as | Devices › Compliance › Compliance settings | Met | high |
| INTUNE-002 | Compliance status validity period (days) | Devices › Compliance › Compliance settings | Met | low |
| INTUNE-003 | Device compliance policies | Devices › Compliance › Policies | Couldn't verify: permission missing | medium |

## Purview

| ID | Setting | Location | Status | Severity |
|---|---|---|---|---|
| PUR-001 | Record user and admin activity | Solutions › Audit | Met | high |
| PUR-002 | Data loss prevention policies that are on | Solutions › Data loss prevention › Policies | Couldn't verify: not connected | medium |

## Defender

| ID | Setting | Location | Status | Severity |
|---|---|---|---|---|
| DEF-001 | Enable the common attachments filter | Email & collaboration › Policies & rules › Threat policies › Anti-malware › Default (Default) | Met | medium |
| DEF-002 | Enable zero-hour auto purge for malware | Email & collaboration › Policies & rules › Threat policies › Anti-malware › Default (Default) | Met | medium |
| DEF-003 | Enable mailbox intelligence | Email & collaboration › Policies & rules › Threat policies › Anti-phishing › Office365 AntiPhish Default (Default) | Met | medium |
| DEF-004 | Automatic forwarding rules | Email & collaboration › Policies & rules › Threat policies › Anti-spam › Anti-spam outbound policy (Default) | Not met | high |

## Microsoft 365 admin

| ID | Setting | Location | Status | Severity |
|---|---|---|---|---|
| ADMIN-001 | Days before passwords expire | Settings › Org settings › Security & privacy › Password expiration policy | Met | low |

## Third-party apps

| App | Publisher | Verified | Delegated, admin consent | Delegated, user consent | Application |
|---|---|---|---|---|---|
| Backup Vault Connector | Tailspin Backup | yes |  |  | full_access_as_app, Sites.Read.All |
| Handy PDF Signer | Handy Apps | no |  | Files.ReadWrite.All, User.Read (3 users) |  |
| Northwind Calendar Sync | Northwind Software | yes | Calendars.ReadWrite, offline_access, User.Read |  |  |

## This tenant's own registrations

2 app registrations. Their names are left out: they can identify an organisation.
