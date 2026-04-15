# 🚀 ImmortalMgmt: Multi-System Infrastructure Bootstrapping Guide

This enterprise-grade deployment document defines the exact methodology for provisioning the **ImmortalMgmt** GitOps engine onto any fresh Windows Server 2025 target system—designed to scale seamlessly across a fleet of hundreds or thousands of servers.

---

## 📋 1. Pre-Flight Requirements

Before initiating the bootstrap sequence, verify the target node meets these parameters:

1. 🖥️ **Operating System**: Windows Server 2025 (Standard or Datacenter).
2. 🔑 **Privileges**: Execution must happen inside a fully elevated Administrator session.
3. 🛡️ **Execution Policy**: Open an elevated PowerShell prompt and allow script execution:
   ```powershell
   Set-ExecutionPolicy RemoteSigned -Force
   ```
4. 📦 **Dependencies**: Git for Windows must be installed and globally available in the system `PATH`.

---

## 🛠️ 2. Fleet-Ready Deployment Sequence

### 📂 Step 1: Establish the Core Path Hierarchy
The automation framework operates on absolute pathing rooted at `C:\Scripts`. Create the initial directory structures:

```powershell
New-Item -ItemType Directory -Path "C:\Scripts\Variables" -Force
```

---

### 🏷️ Step 2: Provision Node Identity (The Hiera Target)
Because the codebase is 100% uniform across all systems, each server relies on a small local identity file to know which hierarchical configurations to pull. 

Create `_NodeIdentity.json` on the target server:

```powershell
$Identity = @{
    Org = "DefaultOrg"
    Env = "Production"
}
$Identity | ConvertTo-Json | Set-Content -Path "C:\Scripts\Variables\_NodeIdentity.json" -Encoding utf8NoBOM
```

---

### 📥 Step 3: Retrieve the Source Automation Framework
Clone the repository down from version control directly into the operational directory:

```powershell
git clone https://github.com/GreenJustyn/immortalmgmt.git C:\Scripts
```

---

### 🖥️ Step 4: Initialize Host Variables (OOB Configuration)
Before registering automation tasks, initialize host-specific variables automatically:

```powershell
Set-Location "C:\Scripts"
& '.\install.ps1'
```

---

### 🔐 Step 5: Secure Local Credentials for Automation
The automation framework utilizes encrypted XML credentials bound specifically to the user executing the tasks to prevent plain-text credential leaks.

Generate your GitHub Sync token and the local administrative credentials:

```powershell
# 1. Create the local Administrator credentials (for automated task registration)
Get-Credential -UserName "Administrator" -Message "Enter local Administrator password" | Export-Clixml -Path "C:\Scripts\Credentials\bootstrap.xml"

# 2. Create the headless Git synchronization credentials (for pulling updates silently)
Get-Credential -UserName "git" -Message "Paste your GitHub Personal Access Token as the password" | Export-Clixml -Path "C:\Scripts\Credentials\git-credential.xml"
```

---

### ⚡ Step 6: Execute the Bootstrap Engine
With the configurations and identities staged, run the core bootstrapping engine. This script will discover operational automation scripts inside the `Scripts\Windows` directory and permanently register them inside the Windows Task Scheduler.

```powershell
Set-Location "C:\Scripts\Scripts\Windows"
& '.\000 - Bootstrap Script.ps1'
```

---

## 🎉 Post-Flight Verification

Once the bootstrap engine completes:
1. 🕒 Open **Task Scheduler** (`taskschd.msc`) and confirm the `\ImmortalMgmt\` folder is populated with scheduled execution items.
2. 🧪 Run the standard compliance checker to ensure the framework is perfectly seated:
   ```powershell
   & '.\39 - Test-Infrastructure-Compliance.ps1'
   ```
