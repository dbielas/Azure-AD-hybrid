# Password Hash Synchronization (PHS) Validation

## Executive Summary
This directory contains end-to-end evidence validating Password Hash Synchronization (PHS) from on-premises Active Directory (`DC01`) to Microsoft Entra ID via Entra Connect (`ENTRA-SYNC01`).

---

## 1. Test Metadata
* **Target Account:** `amercer` / `amercer@hybrid.lan` (`Alex Mercer`) $\rightarrow$ `amercer@davidbielascomcast.onmicrosoft.com`
* **Service Principal:** `ConnectSyncProvisioning_ENTRA-SYNC01_e72762af8e46`
* **Sync Server:** `ENTRA-SYNC01`
* **Domain Controller:** `DC01`

---

## 2. Evidence Chain of Custody

| Step | Source System | Evidence File / Artifact | Key Findings |
|---|---|---|---|
| **1. Tenant Feature Baseline** | Microsoft Entra Admin Center | [entra-phs-status](./PHS_Entra.jpg) | Confirmed `Password Hash Sync: Enabled` and `Sync status: Enabled` under Provision from Active Directory. |
| **2. Local Password Mutation** | `DC01` | [dc01-phs-reset](./dc01-phs-reset.txt) | `Set-ADAccountPassword` executed at `10:45:00 AM`; `pwdLastSet` updated. |
| **3. Sync Engine Harvest** | `ENTRA-SYNC01` | [sync-diagnostics](./sync-diagnostics.jpg) | `Invoke-ADSyncDiagnostics` returned `Success` across local sync boundaries and RPC replication endpoints. |
| **4. Cloud Ingestion Audit** | Entra ID Portal | [entra-audit-log](./entra-audit-log.csv) | Status: `Success` (`Update user` modifying `PasswordProfile`) ingested at `10:46:12 AM` (~72s cycle) by `ConnectSyncProvisioning_ENTRA-SYNC01_*`. |

---

## 3. Deep-Dive Analysis: Security & Pipeline Mechanics

### Cryptographic Handling & Transport
When an on-premises password change occurs on `DC01`, the raw password hash is extracted via the `DSGetNCChanges` API (Directory Replication Services):
* The MD4-based NT hash is re-hashed using **HMAC-SHA256** with a per-batch generated cryptographic key before leaving local host memory.
* High-frequency sync passes occur on a **2-minute background interval**, operating independently of standard 30-minute delta attribute sync cycles.
* Transmitted securely over outbound **TLS 1.2+ / HTTPS (Port 443)** directly to the Microsoft Entra identity endpoint.

### Role & Identity Context (`ConnectSyncProvisioning`)
Unlike manual administrative password resets or end-user cloud SSPR operations, inbound PHS writes do not generate interactive user logs:
* Changes are processed automatically under the service principal identity: **`ConnectSyncProvisioning_ENTRA-SYNC01_*`**.
* In the Entra Audit Logs, the event registers under **Service:** `Core Directory` with **Activity:** `Update user` (modified property: `PasswordProfile`).
* Validates that background credential synchronization operates seamlessly without requiring administrative delegation or manual password resets in the cloud portal.

---

## 4. Artifacts

* 📄 **Active Directory Output:** [`dc01-phs-reset.txt`](./dc01-phs-reset.txt)
* 📄 **Entra Audit Log:** [`entra-audit-log.csv`](./entra-audit-log.csv)
* 🖼️ **Tenant Feature Baseline:** [`PHS_Entra.jpg`](./PHS_Entra.jpg)
* 🖼️ **Sync Engine Diagnostics:** [`sync-diagnostics.jpg`](./sync-diagnostics.jpg)
