# Delta Synchronization & Attribute Lifecycle Validation

## Executive Summary
This directory contains end-to-end evidence validating standard Delta Synchronization functionality from on-premises Active Directory (`DC01`) to Microsoft Entra ID via Entra Connect (`ENTRA-SYNC01`). It demonstrates routine attribute lifecycle management and object attribute propagation.

---

## 1. Test Metadata
* **Target Account:** `amercer@davidbielascomcast.onmicrosoft.com`
* **Service Principal:** `ConnectSyncProvisioning_ENTRA-SYNC01_e72762af8e46`
* **Sync Server:** `ENTRA-SYNC01`
* **Domain Controller:** `DC01`
* **Modified Attributes:** `Title` ("Intelligence Analyst"), `Department` ("Cybersecurity")

---

## 2. Evidence Chain of Custody

| Step | Source System | Evidence File / Artifact | Key Findings |
|---|---|---|---|
| **1. Source Update** | `DC01` | [dc01-attribute-update](./dc01-attribute-update.txt) | Executed `Set-ADUser`; updated `Title` and `Department` attributes |
| **2. Delta Engine Trigger** | `ENTRA-SYNC01` | [delta-sync-trigger](./delta-sync-trigger.jpg) | Triggered `Start-ADSyncSyncCycle -PolicyType Delta`; result: `Success` |
| **3. Delta Export Verification** | `ENTRA-SYNC01` | **[Delta-Sync-Attribute-Export](./Delta-Sync-Attribute-Export.jpg)** | **Captured `Connector Space Object Properties` during a Delta Export operation. Confirmed targeted attribute updates (`department`: `IT` $\rightarrow$ `Cybersecurity`, `title`: `Systems Administrator` $\rightarrow$ `Intelligence Analyst`) staged and pushed via verified `mS-DS-ConsistencyGuid` anchor.** |
| **4. Cloud Reflection** | Entra ID Portal | [entra-audit-delta-update](./entra-audit-delta-update.jpg) | Status: `Success` (`Update user`) initiated by `ConnectSyncProvisioning_ENTRA-SYNC01_*` |

---

## 3. Deep-Dive Analysis: Engine Pipeline & Attribute Scoping

### Delta Import & Staging Mechanics
When a Delta Sync cycle runs, Entra Connect queries local AD domain controllers using high-watermark USN (Update Sequence Number) tracking to isolate modified objects rather than performing a full directory read.
* **Connector Space (CS) Staging:** Changes are staged in the local AD Connector Space before evaluating synchronization rules.
* **Metaverse (MV) Transformation:** Attribute mapping rules (e.g., `In from AD - User Common`) translate local Active Directory attributes (`title`, `department`) to their metaverse equivalents (`jobTitle`, `department`).
* **Export Cycle:** Transmitted over TLS 1.2 via the Graph/Provisioning endpoint using the tenant's dedicated service principal (`ConnectSyncProvisioning_*`).

### Scope & Attribute Filtering Checks
During delta evaluations, attributes are validated against the active schema filters configured during Entra Connect setup.
* **Direct Schema Mapping:** Standard organizational fields (`Title` $\rightarrow$ `jobTitle`, `Department` $\rightarrow$ `department`) sync out-of-the-box without custom sync rule overrides.
* **Audit Trail Differential:** Unlike credential operations (`Update PasswordProfile`), general metadata updates write to Entra Audit logs with **Activity:** `Update user` under **Service:** `Core Directory`, populating modified property lists with both old and new string values.

---

## 4. Engineering Notes: Custom Service Account Remediation

### Problem Statement (Error 8344)
During initial deployment, using a pre-provisioned custom AD Connector service account resulted in export failures (`sec-error-insufficient-access-rights` / `8344`) when attempting to stamp the `mS-DS-ConsistencyGuid` attribute onto target user objects during staging.

### Root Cause Analysis
By default, standard object read/write delegation commands do not automatically grant write access to extended schema attributes like `mS-DS-ConsistencyGuid`. Because Entra Connect utilizes this attribute as the immutable source anchor binding the on-premises `ObjectGUID` to the cloud identity, missing write rights block the sync engine's export phase.

### Resolution
Applied property-specific write permissions directly to the target organizational unit (`OU=Users`) targeting descendant `user` objects:

```cmd
dsacls "OU=Users,OU=Synced_Objects,DC=hybrid,DC=lan" /I:S /G "hybrid.lan\svc-entrasync:WP;mS-DS-ConsistencyGuid;user"
```

