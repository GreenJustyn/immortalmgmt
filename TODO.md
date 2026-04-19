# Post-Migration Assessment and Tasks

This document outlines the assessment of running the management scripts on clean, fresh installations of Windows Server 2025 and Ubuntu Server, along with the necessary setup steps.

## Scenario 1: Windows Server 2025 (Clean Install)

**Objective**: Run `install.ps1` and bootstrap via `curl` on a fresh machine as local Administrator without pre-installing dependencies.

### Assessment Results
- **Execution Policy**: By default, Windows Server restricts script execution. You must bypass this when running the command.
- **Dependencies**: `install.ps1` requires internet access to download `NuGet` and `PoshMailKit` from the PowerShell Gallery.
- **Python**: Not required for Windows scripts.

### Step-by-Step Procedure
1. Log in as local **Administrator**.
2. Open PowerShell.
3. Execute the install script bypassing execution policy (Internet access required):
   ```powershell
   Invoke-WebRequest -Uri "https://.../install.ps1" -OutFile "install.ps1"
   .\install.ps1 -ExecutionPolicy Bypass
   ```
   *(Or pipe directly if using raw content URL)*.
4. Run the bootstrap script to schedule tasks.

---

## Scenario 2: Ubuntu Server (Clean Install)

**Objective**: Run Linux scripts on a fresh Ubuntu Server without pre-installing dependencies.

### Assessment Results
- **Core Dependencies**: Python 3 and Cron are pre-installed on standard Ubuntu Server images.
- **System Tools**: Specific scripts require tools not present by default (e.g., `smartctl`).

### Tasks Completed
- [x] Added auto-installation check for `smartmontools` in `48 - Check-Smart-Devices.sh` using `apt-get`.

### Step-by-Step Procedure
1. Log in to the server.
2. Clone the repository or download the scripts.
3. Run `install.sh` to initialize node identity.
4. Run `000 - Bootstrap Script.sh` to schedule tasks via Crontab.
5. Scripts requiring special tools (like `48`) will now attempt to install them automatically on first run if executed as root.
