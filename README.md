# ⚡ ImmortalMgmt: Fully Autonomous Automation Engine

**ImmortalMgmt** is a zero-touch, self-healing Infrastructure-as-Code framework designed for multi-tenant fleets running Windows Server 2025 and Linux enterprise distributions.

---

## 🌟 System Features

* 🔄 **Headless GitOps Synchronization**: Tasks pull repository updates silently in the background into a secure staging area before mirroring files into active directories via `robocopy`, ensuring zero lock-file conflicts.
* 🏗️ **5-Layer Hierarchical Configuration (Hiera Model)**: The platform executes the exact same `.ps1` code across all systems while pulling layered JSON variables based on node identity:
  * `Global` $\rightarrow$ `Org` $\rightarrow$ `Environment` $\rightarrow$ `Operating System` $\rightarrow$ `Host`
* 🐧 **Zero-Dependency WSL & Cross-Platform Orchestration**: Automated on-the-fly provisioning of Windows Subsystem for Linux (WSL), Ubuntu, pipx, and Linux package pipelines straight from native `.ps1` code.
* 🛡️ **Robust Verify-Then-Sync-Then-Delete Replication**: Enterprise-grade file transfer orchestration with automatic mutual exclusion OS locking (Mutex protection), bounded timeout KeepAlives, and atomic server cache flushing (`sync`) to guarantee zero data loss during network interruptions or hard server reboots.
* 🧹 **Self-Healing Disk Management**: Automated system health reports actively monitor disk space—triggering a robust 7-day safe-purge of local temporary folders if capacity drops below thresholds.
* 🧪 **Pester 5+ Compliance Validation**: Complete unit testing across networking, dependencies, and script syntax validation before live execution.

---

## 📂 Repository Architecture

The codebase is strictly segmented to protect the execution logic from local configurations:

```text
immortalmgmt/
  ├── Credentials/       # Secure local symmetric credential storage (Ignored in Git)
  ├── Functions/         # Core operational modules (Get-ScriptConfig.ps1)
  ├── Logs/              # Standardized system logging & OS Mutex Locks
  ├── Scripts/           
  │   ├── Linux/         # Future Linux execution routines
  │   └── Windows/       # Over 50 Windows automated operational scripts
  │       └── Custom/    # Sequentially executed custom deployment and processing pipelines
  ├── Tests/             # Pester compliance test scripts
  ├── Variables/         # The layered configuration files (.json)
  ├── install.ps1        # Out-Of-Box host initialization & variable discovery
  ├── powershell_commander.ps1 # PowerShell GUI command center launcher
  └── powershell_commander.py  # GUI Application orchestration logic

```

---

## ⚙️ Understanding the Loader Logic

Every execution script in this engine begins with a single dot-sourced loader line:

```powershell
$Config = . (Join-Path $BaseDir "Functions\Get-ScriptConfig.ps1") -ScriptName $ScriptName
```

This dynamic loader automatically scans the server for its `_NodeIdentity.json` file, merges all 5 layers of configuration overriding lower layers automatically, and returns a unified `$Config` object directly into memory.

---

## 🚀 Operational Quickstart

### Option A: One-Line Guided Setup (Recommended)
To bootstrap and configure a fresh target Windows Server immediately from GitHub (without manually cloning or configuring directories first), open an elevated PowerShell prompt and execute:

```powershell
$temp = Join-Path $env:TEMP "immortalmgmt-setup"; New-Item -ItemType Directory -Force $temp | Out-Null; Invoke-WebRequest -Uri "https://github.com/GreenJustyn/immortalmgmt/archive/refs/heads/main.zip" -OutFile "$temp\repo.zip"; Expand-Archive -Path "$temp\repo.zip" -DestinationPath $temp -Force; & "$temp\immortalmgmt-main\install.ps1"
```

### Option B: Step-by-Step Manual Deployment
For manual deployment, customized node identities, or headless domain setups, follow the step-by-step instructions detailed in [BOOTSTRAP.md](BOOTSTRAP.md).

---
To perform routine compliance scans across your environment:
```powershell
C:\Scripts\Scripts\Windows\39 - Test-Infrastructure-Compliance.ps1
```
