# Identity Security, RBAC & Administrative Boundary Controls

## 1. Executive Summary & Enterprise Tiering Strategy
This architecture adheres to the **Microsoft Enterprise Access Model**, maintaining strict plane separation between Tier-0 (Control Plane), Tier-1 (Workload Plane), and Tier-2 (User Plane).

* **`DC01` (Tier-0 Control Plane):** Authoritative root of identity. Direct administrative logins are prohibited except via hardened Jump Hosts/PAWs.
* **`ENTRA-SYNC01` (Tier-0 Boundary Host):** Because the sync engine processes credential replication, it is classified as a Tier-0 asset. To limit the Domain Controller attack surface, it is installed as a standalone member server rather than directly on `DC01`.

---

## 2. Least-Privilege Active Directory Service Account (`svc-entrasync`)

The synchronization engine uses a dedicated service account (`svc-entrasync`) with explicit, property-scoped access rights. Permanent Enterprise Admin or Domain Admin assignments are forbidden.

### Granular Active Directory Delegation Matrix
| Permission / Right | Applied Scope | Architectural Purpose |
| :--- | :--- | :--- |
| **`DS-Replication-Get-Changes`** | Domain Root (`DC=hybrid,DC=lan`) | Allows Directory Replication Service (DRS) calls to read password hashes for PHS. |
| **`DS-Replication-Get-Changes-All`** | Domain Root (`DC=hybrid,DC=lan`) | Required to read filtered/protected password hash attributes. |
| **`Read/Write all properties`** | `OU=Users,OU=Synced_Objects` | Staging metadata and bidirectional attribute synchronization. |
| **`Write Property: mS-DS-ConsistencyGuid`** | `OU=Users,OU=Synced_Objects` | Sets the immutable source anchor binding on-premises AD objects to Entra ID objects. |
| **`Reset Password` / `Write pwdLastSet`** | `OU=Users,OU=Synced_Objects` | Enables cloud-initiated SSPR password writeback to local Active Directory. |

### ACL Provisioning Script ([Deploy-EntraSyncIdentityBaseline.ps1](../Scripts/Deploy-EntraSyncIdentityBaseline.ps1))
```cmd
:: Delegate Source Anchor (ConsistencyGUID) Permissions to sync service account
dsacls "OU=Users,OU=Synced_Objects,DC=hybrid,DC=lan" /I:S /G "hybrid.lan\svc-entrasync:WP;mS-DS-ConsistencyGuid;user"

:: Grant Password Writeback and Reset Rights for SSPR
dsacls "OU=Users,OU=Synced_Objects,DC=hybrid,DC=lan" /I:S /G "hybrid.lan\svc-entrasync:CA;Reset Password;user"
dsacls "OU=Users,OU=Synced_Objects,DC=hybrid,DC=lan" /I:S /G "hybrid.lan\svc-entrasync:WP;pwdLastSet;user"
```

---

## 3. Privileged Access Management & Cloud Governance

### A. Just-In-Time (JIT) Elevation via PIM for Groups
Standing access for cloud and resource administration is eliminated. Administrative accounts operate with zero default privileges and must elevate via Privileged Identity Management (PIM):
* **Target Security Group:** `SecOps-Audit-Admins`
* **Role Mappings:** Entra ID `Global Reader` + Azure Subscription `Reader`
* **Activation Guardrails:** Maximum window of **2 hours**, mandatory justification ticket (e.g., `CHG-9942`), and manual multi-party approval.
* **Automated Revocation:** The PIM service automatically purges the user from the role-assignable security group at the expiration timestamp.

### B. Conditional Access with Authentication Strength
The policy `CA-Require-MFA-Azure-Management` intercepts all attempts to access Azure Management portals and APIs:
* **Target Users:** Members of `SecOps-Audit-Admins`
* **Target Resources:** `Microsoft Admin Portals` (Azure Portal, Cloud Shell, Azure CLI/PowerShell)
* **Grant Controls:** Enforces modern **Authentication Strength** (FIDO2 or Microsoft Authenticator MFA).
* **Emergency Exclusion:** An isolated, cloud-only break-glass account (`breakglass-admin@*.onmicrosoft.com`) is excluded to prevent tenant lockout during cloud MFA identity outages.

---

## 4. Audit Logging & SIEM Event Ingestion

Security event logging is enabled across local servers and ingested into Microsoft Sentinel via the Azure Monitor Agent (AMA):

| Event ID | Event Source | Description & SIEM Detection Target |
| :--- | :--- | :--- |
| **`4724`** | Windows Security (`DC01`) | An attempt was made to reset an account's password (identifies SSPR writeback executions). |
| **`4725`** | Windows Security (`DC01`) | An account was disabled (tracks on-premises deprovisioning events). |
| **`4728` / `4732`** | Windows Security (`DC01`) | A member was added to a security-enabled group (detects privilege escalation attacks). |
| **`4662`** | Windows Security (`DC01`) | An operation was performed on an AD object (tracks DRS replication read operations). |
