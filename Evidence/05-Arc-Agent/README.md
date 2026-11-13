# Azure Arc Hybrid Infrastructure & Telemetry Pipeline Validation

## Executive Summary
This directory contains end-to-end evidence validating the onboarding, telemetry collection, and operational management of on-premises virtualized infrastructure (`DC01` and `ENTRA-SYNC01`) inside the Azure Arc control plane. It demonstrates how local Active Directory and identity synchronization servers stream heartbeats and security audit events to a centralized Log Analytics Workspace (`law-hybrid-logs`) via the Azure Monitor Agent (AMA), including an operational runbook for hypervisor state recovery.

---

## 1. Test Metadata
* **Primary Infrastructure Node:** `DC01` (10.0.2.4) — Primary Domain Controller
* **Sync Infrastructure Node:** `ENTRA-SYNC01` (10.0.2.5) — Entra Connect Sync Engine
* **Target Workspace:** `law-hybrid-logs`
* **Resource Group:** `rg-hybrid-arc` (`westus2`)
* **Data Collection Rule:** `dcr-windows-event-logs`
* **Onboarding Method:** Service Principal (`sp-arc-onboarding`)
* **Control Agent:** Azure Connected Machine Agent (`azcmagent` v1.66.03466.3076)
* **Telemetry Extension:** Azure Monitor Windows Agent (`AzureMonitorWindowsAgent` v1.44.0.0)

---

## 2. Evidence Chain of Custody

| Step | Source System | Evidence File / Artifact | Key Findings |
|---|---|---|---|
| **01. Local Arc Agent Status** | `DC01, ENTRA-SYNC01` | [azcmagent-status-show](./azcmagent-status-show.txt) | Executed `azcmagent.exe show`; confirmed `Agent Status: Connected` and core services (`himds`, `ExtensionService`) running. |
| **02. Extension Pipeline Check** | `DC01, ENTRA-SYNC01` | [azcmagent-extension-list](./azcmagent-extension-list.txt) | Executed `azcmagent.exe` extension check; verified `AzureMonitorWindowsAgent` extension in `State: ENABLED`. |
| **03. Connected Machines Verification** | Azure | [arc-connected-machines](./arc-connected-machines.txt) | Executed `az connectedmachine list` query; confirmed both `DC01` and `ENTRA-SYNC01` connected to Azure. |
| **04. Heartbeat Ingestion Verification** | Log Analytics | [kql-heartbeat-telemetry](./kql-heartbeat-telemetry.csv) | Executed `Heartbeat` KQL query; confirmed lockstep health signals and Arizona MST timestamps across `DC01` and `ENTRA-SYNC01`. |

---

## 3. Deep-Dive Analysis: Arc Control Plane & Telemetry Engine

### Local Arc Agent Services
On-premises Windows servers run the Azure Connected Machine Agent framework to project local identities into Azure Resource Manager (ARM):
* **`himds` (Azure Hybrid Instance Metadata Service):** Handles Azure Managed Identity token issuance and metadata exchange via IMDS (`http://localhost:40342/metadata/identity/oauth2/token`).
* **`ExtensionService`:** Dynamically installs, configures, and monitors Azure extensions (such as AMA) running on the local host.

### Azure Monitor Agent (AMA) Pipeline Architecture
Telemetry ingestion relies on a decoupled extension model governed by Azure Data Collection Rules (DCRs):
1. **Control Plane Binding:** The server is linked to `dcr-windows-event-logs` via Azure Resource Manager associations.
2. **Local Engine Execution:** `ExtensionService` manages worker processes (`MonAgentCore.exe` / `MonAgentManager.exe`) inside `C:\Packages\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent\`.
3. **Buffer & Transport:** Health metrics and Event Logs are staged in local SQLite buffer tables (`C:\Resources\Directory\AMADataStore\Tables\`) before being encrypted and shipped outbound over HTTPS (TCP 443) to `law-hybrid-logs.ods.opinsights.azure.com`.

### Multi-Node Heartbeat Query
```kusto
Heartbeat
| where Computer contains "DC01" or Computer contains "ENTRA-SYNC"
| summarize LastHeartbeat = max(_TimeReceived) by Computer, OSType, OSName, ComputerIP, Category
| extend LocalTime_MST = datetime_utc_to_local(LastHeartbeat, 'US/Arizona')
| project Computer, LocalTime_MST, OSType, OSName, ComputerIP, Category
| sort by Computer asc
```

---

## 4. Operational Considerations & Hypervisor Recovery Runbook

### Hypervisor Pause/Resume Edge Case
When virtual machines undergo hypervisor state shifts (e.g., VirtualBox/Hyper-V pause/resume or snapshot restore), socket invalidation and stale DNS caching (`lookup gbl.his.arc.azure.com: no such host`) can prevent `MonAgentCore.exe` from completing TLS handshakes to Azure, even while `azcmagent` reports `Connected`.

### Remediation Protocol
If `Heartbeat` or `Event` telemetry halts following host power state changes, execute the following recovery sequence on the affected node:

1. **Flush Stale Resolver Caches:**
   ```powershell
   Clear-DnsClientCache
   ```
2. **Purge Local Stale Buffer Tables:**
   ```powershell
   Stop-Service -Name "ExtensionService" -Force
   Remove-Item -Path "C:\Resources\Directory\AMADataStore\Tables\*" -Recurse -Force -ErrorAction SilentlyContinue
   ```
3. **Re-Bind Extension Engine:**
   ```powershell
   Start-Service -Name "ExtensionService"
   ```
