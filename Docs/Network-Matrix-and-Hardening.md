# Network Architecture, Egress Matrix & Protocol Hardening

## 1. Overview & Hybrid Topology
The hybrid network infrastructure connects an on-premises Tier-0 management plane to Microsoft Azure via an encrypted route-based IPsec Site-to-Site VPN. 

All cross-boundary traffic is forced through a centralized Next-Generation Firewall (Azure Firewall Standard) deployed in the Hub VNet (`10.3.0.0/16`). Spoke workloads operate in dedicated subnets without public IP addresses, enforcing complete Layer-4 and Layer-7 inspection.

### Subnet & IP Allocation Map
| Hostname / Subnet | Network / IP | Component Role | Routing & Security Baseline |
| :--- | :--- | :--- | :--- |
| **`DC01`** | `10.0.2.4/24` | Primary Domain Controller & DNS | Hyper-V/VirtualBox on-premises Tier-0 node. Bound to RRAS tunnel. |
| **`ENTRA-SYNC01`** | `10.0.2.5/24` | Dedicated Entra Connect Sync Engine | Isolated member server; outbound TLS 1.2+ to Entra ID endpoints. |
| **`Azure-S2S-VPN`** | `169.254.0.26` | Point-to-Point Tunnel Interface | Route-based IPsec Virtual Tunnel Interface (VTI). |
| **`GatewaySubnet`** | `10.3.0.0/24` | Azure Virtual Network Gateway (VNG) | Custom UDR: `10.2.0.0/16` -> `10.3.1.4` (Azure Firewall). |
| **`AzureFirewallSubnet`** | `10.3.1.0/24` | Azure Firewall Standard (`10.3.1.4`) | Centralized stateful packet inspection & L7 SNI proxy. |
| **`Spoke2-Workload`** | `10.2.0.0/24` | Spoke Workload Subnet (`vm-test`: `10.2.0.4`) | Custom UDR: `0.0.0.0/0` and `10.0.2.0/24` -> `10.3.1.4`. |

---

## 2. Firewall Traffic & Egress Rules Matrix

### A. Stateful Active Directory Network Rules (`RC-Active-Directory-Sync`)
Traffic collection configured on Azure Firewall to permit directory synchronization and domain-join operations across the IPsec tunnel:

| Rule Name | Protocol | Source IP | Destination IP | Destination Ports | Architectural Justification |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`AD-DNS`** | UDP / TCP | `10.2.0.0/16` | `10.0.2.4` | `53` | Cross-premises DNS resolution for `hybrid.lan`. |
| **`AD-Kerberos`** | TCP / UDP | `10.2.0.0/16` | `10.0.2.4` | `88` | Kerberos user/computer authentication and ticket granting. |
| **`AD-RPC-EPM`** | TCP | `10.2.0.0/16` | `10.0.2.4` | `135` | RPC Endpoint Mapper for replication and DCOM services. |
| **`AD-LDAP`** | TCP / UDP | `10.2.0.0/16` | `10.0.2.4` | `389` | Directory querying and object binds. |
| **`AD-SMB`** | TCP | `10.2.0.0/16` | `10.0.2.4` | `445` | SYSVOL access and Group Policy object transport. |
| **`AD-LDAPS`** | TCP | `10.2.0.0/16` | `10.0.2.4` | `636` | Secure LDAP transport over TLS. |

### B. Outbound Cloud Egress Filtering (`RC-Application-Egress`)
Enforced at the Azure Firewall using Server Name Indication (SNI) inspection to block unauthorized egress while permitting required service endpoints:

| Rule Name | Target FQDNs | Protocols / Ports | Target Subnets | Policy Action |
| :--- | :--- | :--- | :--- | :--- |
| **`Allow-Approved-Web`** | `*.google.com`, `*.microsoft.com` | HTTPS: `443`, HTTP: `80` | `10.2.0.0/16` | **Allow** |
| **`Deny-Unapproved-Egress`** | `*reddit.com*`, `*facebook.com*`, `*x.com*` | All Protocols / Ports | `10.2.0.0/16` | **Deny (Implicit Baseline)** |

---

## 3. Host Protocol & Transport Layer Security (TLS) Hardening

Both `DC01` and `ENTRA-SYNC01` are hardened in compliance with the CIS Benchmark for Windows Server, disabling legacy cryptographic protocols and enforcing TLS 1.2+ for all Microsoft Authentication Library (MSAL) operations.

### Schannel Cryptographic Baseline ([Deploy-Transport-Hardening.ps1](../Scripts/Deploy-Transport-Hardening.ps1))
```powershell
# Disable Insecure Protocols (SSL 2.0, SSL 3.0, TLS 1.0, TLS 1.1)
$InsecureProtocols = @("SSL 2.0", "SSL 3.0", "TLS 1.0", "TLS 1.1")
foreach ($Proto in$InsecureProtocols) {
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$Proto\Server" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$Proto\Server" -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$Proto\Server" -Name "DisabledByDefault" -Value 1 -PropertyType DWord -Force | Out-Null
}

# Explicitly Enable TLS 1.2 & TLS 1.3
$SecureProtocols = @("TLS 1.2", "TLS 1.3")
foreach ($Proto in$SecureProtocols) {
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$Proto\Client" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$Proto\Client" -Name "Enabled" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$Proto\Client" -Name "DisabledByDefault" -Value 0 -PropertyType DWord -Force | Out-Null
}

# Enforce .NET Framework Strong Cryptography (v4.0.30319 & v2.0.50727)
$NetKeys = @(
    "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
)
foreach ($Key in$NetKeys) {
    New-ItemProperty -Path $Key -Name "SchUseStrongCrypto" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $Key -Name "SystemDefaultTlsVersions" -Value 1 -PropertyType DWord -Force | Out-Null
}
```

---

## 4. Verification & Validation Commands

```powershell
# 1. Test Layer-4 Socket Reachability across IPsec Tunnel from Spoke
nc -zv 10.0.2.4 53
nc -zv 10.0.2.4 88
nc -zv 10.0.2.4 389
nc -zv 10.0.2.4 445

# 2. Test Local Host Schannel Configuration
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" -Name "Enabled"
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" -Name "SchUseStrongCrypto"
```
