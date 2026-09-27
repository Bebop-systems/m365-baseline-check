# Removing the consent a run relied on

M365 Baseline Check only reads. Signing in to Graph with PowerShell, though, goes through Microsoft's
**Microsoft Graph Command Line Tools** app (app ID `14d82eec-204b-4c2f-b7e8-296a70dab67e`), and consenting
to its scopes leaves a *delegated permission grant* on that app in the tenant. The grant outlives the
session: signing out doesn't remove it. If it was granted for this work, remove it when you're done.

**Check first.** Other admins' PowerShell may rely on the same grant. The tool shows the grant it found,
with its ID, in three places: on the *Sign-in details* screen (`g` on the home screen), in `report.txt`
under *Consent*, and in the lines printed after you quit. It shows two kinds:

- **Admin consent for all users** (`AllPrincipals`): granted by an administrator on behalf of everyone.
- **This account's own consent** (`Principal`): granted by the signed-in account for itself only.

## In the portal

Entra admin center › Identity › Applications › Enterprise applications › **Microsoft Graph Command Line
Tools** › Permissions. Review the permissions there, and revoke what shouldn't stay. Deleting the
enterprise app instead (Properties › Delete) removes every grant it holds, and the next person to sign
in with Graph PowerShell consents again.

## In PowerShell

With the `Microsoft.Graph.Identity.SignIns` module, signed in with a scope that can remove grants:

```powershell
Connect-MgGraph -Scopes DelegatedPermissionGrant.ReadWrite.All -ContextScope Process
Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId '<grant ID from the report>'
Disconnect-MgGraph
```

With only `Microsoft.Graph.Authentication` installed:

```powershell
Connect-MgGraph -Scopes DelegatedPermissionGrant.ReadWrite.All -ContextScope Process
Invoke-MgGraphRequest -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants/<grant ID>'
Disconnect-MgGraph
```

Removing the grant needs its own consent to `DelegatedPermissionGrant.ReadWrite.All`, which adds that scope
to the same app's grant. Remove the grant last, as above, and it goes with the rest.

To see what's left afterwards:

```powershell
Connect-MgGraph -Scopes Application.Read.All -ContextScope Process
$sp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '14d82eec-204b-4c2f-b7e8-296a70dab67e'"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($sp.value[0].id)'"
Disconnect-MgGraph
```
