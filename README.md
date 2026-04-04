# ImmortalMgmt

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://microsoft.com/powershell)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**ImmortalMgmt** is a comprehensive, modular automation and configuration management framework built entirely in PowerShell. It is designed to streamline the setup, maintenance, and monitoring of Windows environments (ideal for homelabs, dedicated servers, or workstations).

The project uses a GitOps-ready approach with external JSON configurations, robust logging, and automated failure alerting via email.

---

## 🚀 Key Features

- **Automated Bootstrapping**: Automatically registers all maintenance scripts as Windows Scheduled Tasks with configurable intervals.
- **Idempotent Design**: Scripts are written to check current system state before applying changes, making them safe to run repeatedly.
- **Centralized Configuration**: All scripts read from external JSON files (expected in `C:\Scripts\Variables\`), separating logic from environment-specific data.
- **Robust Logging & Alerting**: Every script maintains detailed logs and can send email alerts (via Gmail SMTP & PoshMailKit) if errors or critical failures are detected.
- **Media Management Pipeline**: Includes a specialized master script that orchestrates media renaming (via `mnamer` in WSL) and secure replication (via `rsync` over SSH).

---

## 📁 Repository Structure

The repository follows a numbered execution order for initial setup, followed by specialized maintenance scripts.

### Core Orchestration
- **`000 - Bootstrap Script.ps1`**: The entry point. Scans the directory for scripts and registers them as Windows Scheduled Tasks.
- **`00 - Master Script.ps1`**: A heavy-duty script for media management. It handles updating `mnamer` in WSL, renaming files, and syncing them between Plex and Jellyfin servers using `rsync`.

### System Configuration & Hardening (01 - 11)
- `01 - Set-ComputerName.ps1`: Renames the computer based on config.
- `02 - Set-StaticIPAddress.ps1`: Configures static IP settings.
- `03 - Add-DomainUser-ToLocalGroup.ps1`: Manages local group memberships.
- `04 - Set-DnsClientServerAddress.ps1`: Sets DNS servers.
- `05 - Disable-NetIPv6.ps1`: Disables IPv6 if required.
- `06 - Set-ExecutionPolicy-Unrestricted.ps1`: Configures PowerShell execution policy.
- `07 - Enable-PSRemoting.ps1`: Enables PowerShell Remoting for management.
- `08 - Set-TimeZone.ps1`: Sets the system time zone.
- `09 - Enable-RemoteDesktop.ps1`: Enables and configures RDP.
- `10 - Set-PowerPlan-HighPerformance.ps1`: Ensures the High Performance power plan is active.
- `11 - Disable-WindowsErrorReporting.ps1`: Disables WER popups.

### Software & Feature Management (12 - 16)
- `12 - Install-NuGetProvider.ps1`: Bootstraps NuGet for package management.
- `13 - Install-Chocolatey-Base.ps1`: Installs the Chocolatey package manager.
- `14 - Install-PowerShellModule-Library.ps1`: Installs required PS modules.
- `15 - Update-ChocolateyPackages.ps1`: Keeps Chocolatey packages up to date.
- `16 - Install-WindowsFeature-HyperV.ps1`: Installs the Hyper-V role.

### Storage & Network Sharing (17 - 20)
- `17 - Initialize-DataDisks.ps1`: Formats and initializes new data disks.
- `18 - Set-DiskQuota.ps1`: Manages disk quotas.
- `19 - New-SmbShare-Admin.ps1`: Creates administrative SMB shares.
- `20 - Set-SmbServerConfiguration.ps1`: Hardens/tunes SMB server settings.

### Maintenance & Monitoring (21 - 39)
- `21 - Clear-TempFiles-System.ps1`: Cleans up system temp files.
- `22 - Install-WindowsUpdate-Scheduled.ps1`: Manages Windows Updates.
- `23 - Set-Service-AutomaticDelayed.ps1`: Optimizes service start types.
- `24 - Update-Help-Local.ps1`: Updates local PowerShell help files.
- `27 - Disable-WindowsSearchIndexing.ps1`: Disables search indexing to save I/O.
- `28 - Set-EventLog-Retention.ps1`: Configures event log sizes and retention.
- `31 - Test-ServiceStatus-Critical.ps1`: Monitors critical services.
- `34 - Export-SystemHealth-Report.ps1`: Generates system health reports.
- `39 - Test-Infrastructure-Compliance.ps1`: Runs compliance checks against desired state.

### Specialized Maintenance
- **`98 - Git Script.ps1`**: Likely handles Git operations or auto-updates for the repo.
- **`99 - Daily Maintenance Clean Up Script.ps1`**: Final cleanup tasks.

---

## 🛠️ Prerequisites

To use this framework effectively, the host system should meet the following requirements:

1. **OS**: Windows 10/11 or Windows Server 2016+.
2. **PowerShell**: Version 5.1 or higher.
3. **Permissions**: Scripts must be run as **Administrator**.
4. **Directory Structure**: The scripts expect to be placed in `C:\Scripts\`.
    - Configuration files: `C:\Scripts\Variables\`
    - Credentials: `C:\Scripts\Credentials\`
    - Logs: `C:\Scripts\Logs\`
5. **WSL (Optional)**: Required only if you intend to run `00 - Master Script.ps1` for media management.

---

## ⚙️ Getting Started

### 1. Initial Setup
Clone this repository to your target machine. It is highly recommended to place it in `C:\Scripts\`.

```powershell
git clone https://github.com/GreenJustyn/immortalmgmt.git C:\Scripts
```

### 2. Configuration
Before running the scripts, you must populate the configuration files in the `Variables` directory. Each script expects a JSON file named after itself (e.g., `01 - Set-ComputerName.ps1` looks for `C:\Scripts\Variables\01 - Set-ComputerName.json`).

Example structure for `01 - Set-ComputerName.json`:
```json
{
    "DesiredHostName": "MY-SERVER-01",
    "EmailAppPassword": "your-gmail-app-password",
    "EmailFrom": "alerts@domain.com",
    "EmailTo": "admin@domain.com"
}
```

### 3. Credential Setup
For scripts requiring credentials (like the Bootstrap script or domain join scripts), save the credentials as encrypted XML files using `Export-Clixml`:

```powershell
$credential = Get-Credential
$credential.Password | Export-Clixml -Path "C:\Scripts\Credentials\bootstrap.xml"
```
*Note: These files can only be decrypted by the same user account on the same machine that created them.*

### 4. Bootstrap the System
To register all scripts as scheduled tasks, run the Bootstrap script in an elevated PowerShell session:

```powershell
cd C:\Scripts
.\"000 - Bootstrap Script.ps1"
```

---

## 📧 Alerting & Dependencies

The scripts use the **PoshMailKit** module to send email notifications. If errors are detected in the logs during execution, an email will be sent via Gmail SMTP.

To ensure this works:
1. Ensure the `PoshMailKit` module is installed (or let script `14` install it).
2. Use a Google App Password if you are using a Gmail account for sending alerts.

---

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
