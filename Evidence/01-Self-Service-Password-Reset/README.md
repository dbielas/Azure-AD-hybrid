# Self-Service Password Reset (SSPR) & Password Writeback Validation

## Executive Summary
This directory contains end-to-end evidence validating Self-Service Password Reset (SSPR) with Password Writeback from Microsoft Entra ID to on-premises Active Directory (`DC01`) via Entra Connect (`ENTRA-SYNC01`).

---

## 1. Test Metadata
* **Target Account:** `amercer` / `amercer@hybrid.lan` (`Alex Mercer`) $\rightarrow$ `amercer@davidbielascomcast.onmicrosoft.com`
* **Tracking ID:** `e9654057-f2df-452c-8f69-132a882798d9`
* **Sync Server:** `ENTRA-SYNC01`
* **Domain Controller:** `DC01`

---

## 2. Evidence Chain of Custody

| Step | Source System | Evidence File / Artifact | Key Findings |
|---|---|---|---|
| **1. Trigger** | Entra ID Portal | [SSPR_Audit](./SSPR_Audit.jpg) / [entra-audit-log](./entra-audit-log.csv) | Status: `Success` (`OnPremisesPasswordWriteBackSuccess`) |
| **2. Handshake** | `ENTRA-SYNC01` | [sync-server-events](./sync-server-events.txt) | Event ID `31001` (`PasswordResetRequestStart`) at `10:21:09 AM` |
| **3. Execution** | `ENTRA-SYNC01` | [sync-server-events](./sync-server-events.txt) | Event ID `31002` (`PasswordResetSuccess`) at `10:21:09 AM` |
| **4. Finality** | `DC01` | [dc01-pwdlastset-proof](./dc01-pwdlastset-proof.txt) | `pwdLastSet` updated to `10:28:19 AM`; triggers Security Event ID `4724` (`svc-entrasync`). |

---

## 3. Deep-Dive Analysis: Hardening & Clock Drift

### Least-Privilege Delegation (`LDAP 8344` Remediation)
During initial setup, an LDAP `8344` (`INSUFFICIENT_ACCESS_RIGHTS`) error was encountered due to overly restrictive security flags. 
* The sync service account (`svc-entrasync`) was removed from the **Protected Users** group (which blocked NTLM/Kerberos Delegation and DRS replication calls).
* Least-privilege permissions were applied to `OU=Users,OU=Synced_Objects` via `AdSyncConfig` targeting `pwdLastSet`, `lockoutTime`, and `ResetPassword`.

### Clock Skew Analysis
A **7-minute, 10-second timestamp variance** was isolated between `ENTRA-SYNC01` (`10:21:09 AM`) and `DC01` (`10:28:19 AM`).
* **Root Cause:** Hypervisor integration services induced forward clock drift on `DC01`.
* **Technical Note:** Under healthy, synchronized conditions, this delta is `< 2 seconds`. 
* **Remediation:** Disabled Hyper-V time synchronization and bound `DC01` to an external authoritative NTP stratum (`time.windows.com`).

## 4. Artifacts

* 📄 **Entra Audit Log:** [`entra-audit-log.csv`](./entra-audit-log.csv)
* 📄 **Sync Agent Events:** [`sync-server-events.txt`](./sync-server-events.txt)
* 📄 **Active Directory Output:** [`dc01-pwdlastset-proof.txt`](./dc01-pwdlastset-proof.txt)

### Visual Evidence

#### Entra ID Audit Log Confirmation
![entra-audit-log](./SSPR_Audit.jpg)

#### Entra User License Confirmation
![SSPR_License](./SSPR_License.jpg)
