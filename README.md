# ⚡ ImmortalMgmt: Fully Autonomous Automation Engine

**ImmortalMgmt** is a zero-touch, self-healing Infrastructure-as-Code framework designed for multi-tenant fleets running Windows Server 2025 and Linux enterprise distributions.

---

## 🌟 System Features

* 🔄 **Headless GitOps Synchronization**: Tasks pull repository updates silently in the background into a secure staging area before mirroring files into active directories via `robocopy`, ensuring zero lock-file conflicts.
* 🏗️ **5-Layer Hierarchical Configuration (Hiera Model)**: The platform executes the exact same `.ps1` code across all systems while pulling layered JSON variables based on node identity:
  * `Global` $\rightarrow$ `Org` $\rightarrow$ `Environment` $\rightarrow$ `Operating System` $\rightarrow$ `Host`
* 🧹 **Self-Healing Disk Management**: Automated system health reports actively monitor disk space—triggering a robust 7-day safe-purge of local temporary folders if capacity drops below thresholds.
* 🧪 **Pester 5+ Compliance Validation**: Complete unit testing across networking, dependencies, and script syntax validation before live execution.

---

## 📂 Repository Architecture

The codebase is strictly segmented to protect the execution logic from local configurations:

```text
immortalmgmt/
  ├── Credentials/       # Secure local XML credential storage (Ignored in Git)
  ├── Functions/         # Core operational modules (Get-ScriptConfig.ps1)
  ├── Logs/              # Standardized system logging
  ├── Scripts/           
  │   ├── Linux/         # Future Linux execution routines
  │   └── Windows/       # Over 50 Windows automated operational scripts
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

1. For deploying this engine onto a fresh server fleet, read the fully documented setup steps inside [BOOTSTRAP.md](BOOTSTRAP.md).
2. To perform routine compliance scans across your environment:
   ```powershell
   C:\Scripts\Scripts\Windows\39 - Test-Infrastructure-Compliance.ps1
   ```
