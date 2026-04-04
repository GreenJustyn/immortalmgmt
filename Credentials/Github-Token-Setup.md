# GitHub Token Setup for PowerShell

This document explains how to create a GitHub Personal Access Token (PAT) and save it as an encrypted XML file for use in PowerShell scripts.

## Step 1: Create a GitHub Personal Access Token

1.  Log in to your GitHub account.
2.  Go to **Settings** -> **Developer settings** -> **Personal access tokens** -> **Tokens (classic)**.
3.  Click **Generate new token**.
4.  Give the token a descriptive name (e.g., "ImmortalMgmt Sync").
5.  Select the scopes required. For cloning and pulling private repos, you need `repo` scope.
6.  Click **Generate token**.
7.  **Copy the token immediately**. You will not be able to see it again.

## Step 2: Generate the XML File in PowerShell

Run the following PowerShell commands on the machine where the sync script will run, under the user account that will execute the scheduled task.

```powershell
# Paste your token here
$Token = "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Convert the token to a SecureString
$SecureToken = ConvertTo-SecureString $Token -AsPlainText -Force

# Save the SecureString to an XML file
$CredFilePath = "C:\Scripts\Credentials\git-credential.xml"

# Ensure directory exists
if (-not (Test-Path "C:\Scripts\Credentials")) {
    New-Item -ItemType Directory -Path "C:\Scripts\Credentials" -Force | Out-Null
}

$SecureToken | Export-Clixml -Path $CredFilePath
```

**Important Note:** The XML file is encrypted using the Windows Data Protection API (DPAPI). It can only be decrypted by the same user account on the same machine that created it.
