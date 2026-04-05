# Technical Deployment & Bootstrapping Guide
## For Windows Server 2025 Management Server

This guide provides step-by-step instructions for deploying the **ImmortalMgmt** automation framework onto a fresh Windows Server 2025 management server.

---

## 📋 Prerequisites

Before beginning the deployment, ensure the following requirements are met on the target server:

1.  **Operating System**: Windows Server 2025 (Standard or Datacenter).
2.  **Execution Policy**: Must allow running scripts. Run `Set-ExecutionPolicy RemoteSigned` in an elevated prompt.
3.  **Permissions**: Full Administrator rights are required.
4.  **Git**: Git for Windows must be installed and available in the system `PATH`.
5.  **Internet Connectivity**: Required for downloading packages (via Chocolatey) and syncing with GitHub.

---

## 🛠️ Step-by-Step Deployment

### Step 1: Initialize the Directory Structure

The framework is hardcoded to expect its files in a specific directory structure on the `C:` drive.

1.  Open an elevated PowerShell prompt.
2.  Create the base directory:
    ```powershell
    New-Item -ItemType Directory -Path "C:\Scripts" -Force
    ```

### Step 2: Clone the Repository

Clone the repository into the `C:\Scripts` directory.

```powershell
Set-Location -Path "C:\"
git clone https://github.com/GreenJustyn/immortalmgmt.git C:\Scripts
```

### Step 3: Configure Variables

The scripts rely on external JSON files for configuration. You must create these files in the `C:\Scripts\Variables\` directory.

1.  Navigate to `C:\Scripts\Variables`.
2.  You will find template files or you can create new ones named after the scripts (e.g., `000 - Bootstrap Script.json`).
3.  Ensure at least the **Bootstrap** and **Sync** configs are populated.

Example for `000 - Bootstrap Script.json`:
```json
{
    "ScriptFolder": "C:\\Scripts",
    "TaskPath": "\\ImmortalMgmt\\",
    "EmailFrom": "alerts@yourdomain.com",
    "EmailTo": "admin@yourdomain.com",
    "EmailAppPassword": "your-secure-app-password"
}
```

### Step 4: Setup Credentials

Some scripts require encrypted credentials. The framework uses Windows DPAPI to secure these in XML files.

#### GitHub Token (Required for Sync Script)
Follow the instructions in `C:\Scripts\Credentials\01 Github-Token-Setup.md` to generate the `git-credential.xml` file.

#### Bootstrap Credential (Required for Task Scheduling)
The bootstrap script needs credentials to register scheduled tasks that run as a specific user (e.g., Administrator).

Run the following to create the bootstrap credential:
```powershell
$Credential = Get-Credential
$Credential.Password | Export-Clixml -Path "C:\Scripts\Credentials\bootstrap.xml"
```
*Note: Run this command as the same user account that will execute the scheduled tasks.*

### Step 5: Run the Bootstrap Script

The bootstrap script will scan the `C:\Scripts` folder for all `.ps1` files and register them as Windows Scheduled Tasks under the `\ImmortalMgmt\` folder in Task Scheduler.

1.  Open an elevated PowerShell prompt.
2.  Execute the script:
    ```powershell
    Set-Location -Path "C:\Scripts"
    .\"000 - Bootstrap Script.ps1"
    ```
3.  Check the output for any errors. The script will log its actions to `C:\Scripts\Logs\000_Bootstrap.log`.

---

## 🔍 Verification

After running the bootstrap script, verify the deployment:

1.  **Task Scheduler**: Open `taskschd.msc` and verify that a folder named `ImmortalMgmt` exists under the Task Scheduler Library. You should see tasks for all the scripts (e.g., `AutoRun_01 - Set-ComputerName`).
2.  **Logs**: Check `C:\Scripts\Logs` for successful execution logs.
3.  **Compliance Tests**: Run the Pester tests to ensure the environment is compliant:
    ```powershell
    Invoke-Pester -Path "C:\Scripts\Tests\39 - InfraTests.ps1"
    ```

---

## ⚠️ Troubleshooting

- **Missing Modules**: If scripts fail due to missing modules (like `PoshMailKit`), ensure script `14 - Install-PowerShellModule-Library.ps1` runs or install it manually: `Install-Module PoshMailKit`.
- **Git Errors**: If the sync script fails, ensure `git-credential.xml` was created by the same user running the task.
