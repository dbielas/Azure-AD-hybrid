# Enterprise Hybrid Cloud Architecture, Zero-Trust Perimeter & Governance Fabric

* **Status:** Approved / Fully Implemented
* **Date:** August 2026
* **Author:** David Bielas (Lead Infrastructure & Cloud Security Engineering)
* **Scope:** Hybrid Enterprise Architecture (On-Premises Windows Server 2025 Tier-0 / Edge <--> Azure Hub-and-Spoke Transit, SecOps, Governance & BCDR)

---

## 1. Context and Problem Statement

Modern enterprise hybrid transformations fail when cloud adoption introduces fragmented identity silos, uncontrolled edge routing, default-allow egress points, standing administrative privileges, and unverified disaster recovery.

The organization required an end-to-end hybrid landing zone architecture connecting an on-premises Tier-0 Windows Server 2025 infrastructure to Microsoft Entra ID and Azure IaaS workloads. The architecture must enforce Tier-0 control plane isolation, private non-transitive network routing, stateful Layer-4/7 perimeter inspection, unified hybrid threat monitoring, zero standing privileges, policy-as-code landing zone governance, and cryptographic BCDR validation.

---

## 2. Decision Drivers & Architecture Pillars

* **Pillar 1: Tier-0 Control Plane & Identity Lifecycle (AD DS -> Entra ID):** Maintain on-premises Active Directory as authoritative for core identities while enforcing isolated synchronization engines and least-privilege service accounts.
* **Pillar 2: Private Network Transit & Boundary Segmentation:** Secure cross-premises transit via route-based IPsec VPN, eliminating public endpoints on workload subnets.
* **Pillar 3: Centralized Inspection & Zero-Trust Egress:** Force all spoke-to-on-premises and spoke-to-internet traffic through a centralized Next-Generation Firewall (Azure Firewall Standard) via User-Defined Routes (UDRs).
* **Pillar 4: Unified Threat Observability & SecOps Automation:** Bridge on-premises Tier-0 servers with cloud telemetry via Azure Arc and Azure Monitor Agent (AMA), streaming into Microsoft Sentinel for SIEM detection.
* **Pillar 5: Identity Governance & Privileged Access Management:** Eliminate standing administrator access using time-bound Just-In-Time (JIT) Privileged Identity Management (PIM) and MFA-enforced Conditional Access.
* **Pillar 6: Shift-Left Governance (Policy-as-Code):** Enforce preventative landing zone controls at the Azure Resource Manager (ARM) control plane to programmatically block architectural violations.
* **Pillar 7: Workload Resilience & Cryptographic Recovery (BCDR):** Establish cloud-native snapshot management with item-level recovery and hash verification to ensure zero-data-loss recovery targets.

---

## 3. Comprehensive Architectural Topology

```text
[ ON-PREMISES TIER-0 / EDGE ]
  +-- DC01 (Windows Server 2025 AD DS / DNS: 10.0.2.4) [Azure Arc Connected]
  +-- ENTRA-SYNC01 (Dedicated Sync Host: 10.0.2.5) [PHS / SSPR / TLS 1.2+]
  +-- Edge Gateway / RRAS (Tunnel Interface: 169.254.0.26)
         |
    [ Route-Based IPsec S2S VPN Tunnel / IKEv2 ]
         |
[ AZURE HYBRID CLOUD FABRIC ]
  +-- Hub-VNet (10.3.0.0/16)
  |     +-- GatewaySubnet (10.3.0.0/24) -> Azure Virtual Network Gateway (VNG)
  |     +-- AzureFirewallSubnet (10.3.1.0/24) -> Azure Firewall Standard (10.3.1.4)
  |           +-- DefaultNetworkRuleCollectionGroup (AD Sync, ICMP, Admin SSH)
  |           +-- DefaultApplicationRuleCollectionGroup (L7 SNI / FQDN Whitelisting)
  |
  +-- VNet Peering (Gateway Transit & Remote Gateway Enabled)
  |
  +-- Spoke 2 VNet: Spoke2-VNet (10.2.0.0/16)
        +-- Workload-Subnet (10.2.0.0/24)
              +-- vm-test (Linux / Private Workload: 10.2.0.4)
              +-- Route Table (UDR): 0.0.0.0/0 -> Next Hop Virtual Appliance (10.3.1.4)
              +-- Azure Policy Guardrail: Deny attachment of Public IPs
              +-- Recovery Services Vault: App-consistent snapshots & iSCSI recovery
```

---

## 4. Key Architectural Decisions & Implementations

### A. Hybrid Identity Bridge (AD DS -> Microsoft Entra ID)
* **Dedicated Member Server Sync Host (`ENTRA-SYNC01`):** Isolates the sync engine to prevent extending the Domain Controller attack surface.
* **Least-Privilege Pre-Delegated Service Account (`svc-entrasync`):** Explicitly granted `DS-Replication-Get-Changes` and targeted OU write permissions via `AdSyncConfig`, avoiding permanent Enterprise Admin requirements.
* **Password Hash Synchronization (PHS) & SSPR:** Provides maximum auth resilience during WAN outages while enabling secure cloud password writeback (Security Event ID `4724` auditing).
* **Transport Hardening:** Enforced TLS 1.2+ exclusively on sync endpoints, deprecating legacy TLS 1.0/1.1 and insecure ciphers.

### B. Hybrid Transit & Boundary Control (S2S VPN & Azure Firewall)
* **IPsec S2S VPN Tunneling:** Route-based gateway transit binding on-premises routing tables directly to Azure address space (`10.1.0.0/16`, `10.2.0.0/16`) via BGP/APIPA interfaces (`169.254.0.26`).
* **Hub-and-Spoke Traffic Inspection:** All spoke subnets implement a default route (`0.0.0.0/0 -> 10.3.1.4`). Spoke workloads cannot route to the internet or on-premises subnets without traversing the Azure Firewall policy engine.
* **Stateful Network Filtering:** Granular Network Rule Collections restrict inter-subnet and hybrid traffic strictly to validated Active Directory ports (TCP/UDP `53, 88, 135, 389, 445, 636`) and authorized administrative management protocols.
* **Layer-7 Egress FQDN Whitelisting:** Egress web traffic is filtered via Application Rules utilizing Server Name Indication (SNI) parsing. Explicit default-deny drops unauthorized domains (`reddit.com`, `facebook.com`, `x.com`) while allowing authorized business endpoints (`google.com`).

### C. SecOps Telemetry & Threat Monitoring (Azure Arc & Sentinel)
* **Azure Arc Hybrid Infrastructure Management:** Tier-0 on-premises servers onboarded via Azure Arc Connected Machine Agent (`azcmagent`), establishing central control plane visibility.
* **Modern Telemetry Pipeline (AMA):** Replaced legacy MMA with Azure Monitor Agent (AMA) and targeted Data Collection Rules (DCRs) to capture Windows Security Events and system heartbeats.
* **Microsoft Sentinel SIEM Integration:** Deployed scheduled KQL analytics rules to detect simulated privilege escalation events (e.g., unauthorized domain/local group modifications) and trigger incident triage pipelines.

### D. Identity Governance & Zero Standing Privileges (PIM & Conditional Access)
* **Zero Standing Access via JIT PIM:** Privileged roles (e.g., Global Administrator, Privileged Role Administrator) require active, time-bound elevation with administrative approval workflows and automatic revocation.
* **Context-Aware Conditional Access:** Enforced strict multi-factor authentication (MFA) across all Azure Management interfaces, incorporating dedicated break-glass exclusion parameters for disaster recovery.

### E. Cloud Governance & Landing Zone Guardrails (Azure Policy)
* **Preventative Control Plane Enforcement:** Deployed custom Azure Policy (`deny-nic-public-ip.json`) assigned at the workload resource group scope.
* **Deterministic Request Denial:** ARM blocks the provisioning of any Network Interface (NIC) with an attached Public IP (`RequestDisallowedByPolicy`), enforcing zero-direct-internet exposure on spoke workloads and eliminating asymmetric routing bypasses.

### F. Business Continuity & Cryptographic Verification (Azure Backup)
* **Policy-Driven Snapshot Orchestration:** Deployed an Azure Recovery Services Vault (`rsv-hybrid-bcdr`) utilizing Locally Redundant Storage (LRS) to capture application-consistent VM snapshots on isolated spoke subnets.
* **Non-Destructive Item-Level Recovery:** Exposes snapshot blocks via an authenticated, time-bound iSCSI mount session, allowing granular file recovery without system downtime.
* **Cryptographic Verification:** Restored payload integrity is validated via end-to-end SHA-256 hash checks matching the pre-backup baseline.

---

## 5. Architectural Trade-offs & Decision Matrix

| Dimension | Enterprise Implemented Architecture | Traditional / Legacy Pattern |
| :--- | :--- | :--- |
| **Sync Topology** | Dedicated Tier-0 Sync Member Server | Express setup co-located on Primary DC |
| **Identity Privilege** | Scoped ACL service account (`svc-entrasync`) | Permanent Domain / Enterprise Admin |
| **Workload Egress** | Forced 0.0.0.0/0 UDR to Centralized L7 Firewall | Direct Public IP attached to Workload VMs |
| **Inbound Access** | Zero Public IPs; Bastion / S2S VPN only | Direct RDP/SSH exposed to the Internet |
| **SIEM & Logging** | Arc + AMA streaming Event Logs to Sentinel | Disconnected local Windows Event Viewer |
| **Privileged Access** | Just-In-Time (JIT) PIM with MFA & Approval | Permanent standing Global Admin assignments |
| **Policy Enforcement**| Pre-flight ARM API rejection via Azure Policy | Post-incident manual security audits |
| **Disaster Recovery** | Point-in-time iSCSI mount + SHA-256 verification | Full destructive VM redeployment without integrity checks |

---

## 6. Implementation Validation & Evidence Traceability

* **Identity & Directory:**
  * `Evidence/01-Self-Service-Password-Reset/` (SSPR writeback, Event 4724)
  * `Evidence/02-Password-Hash-Synchronization/` (PHS replication & sync diagnostics)
  * `Evidence/03-Delta-Synchronization/` (Attribute schema modification pipelines)
  * `Evidence/04-Account-Deprovisioning/` (Synchronized identity suspension)
* **Hybrid Operations & Monitoring:**
  * `Evidence/05-Arc-Agent/` (Arc agent binding, extension manager, heartbeat telemetry)
  * `Evidence/06-Sentinel/` (AMA ingestion, custom KQL detection, incident triage)
* **Network & Security Boundary:**
  * `Evidence/07-S2S-VPN/` (IPsec transit, AD port netcat testing, cross-boundary SSH)
  * `Evidence/10-HS-Firewall/` (UDR next-hop interception, stateful AD rules, L7 SNI egress allow/deny)
* **Access Control & Governance:**
  * `Evidence/08-Conditional-Access/` (MFA enforcement on Azure Management)
  * `Evidence/09-JIT-PIM/` (Time-bound role activation, approval workflow, auto-revocation)
  * `Evidence/11-Azure-Policy/` (ARM preventative deny on public NIC provisioning, compliance dashboard)
* **Resilience & BCDR:**
  * `Evidence/12-BCDR-Backup/` (RSV deployment, filesystem-consistent snapshots, SHA-256 hash validation)
