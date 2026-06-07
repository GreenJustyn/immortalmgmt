# Local Host Credentials Directory

This directory is an essential component of the **ImmortalMgmt Security Architecture**, designed to store secure local and remote credentials for the automation framework.

## Why this folder is necessary
To support fully unattended background tasks (running under the low-privilege `svc_immortalmgmt` service account), the framework uses a secure, decentralized **AES-256 symmetric key model** to decrypt passwords dynamically at runtime (e.g., mail server app passwords, service accounts, and remote Plex replication keys). These files (specifically `*.key` and `*.enc` pairs) are stored in this folder.

## Why this folder is empty in the repository
1. **Security & Secrets Exposure Prevention:**
   Committing active credentials, passwords, or encryption keys to a public (or private) Git repository is a critical security vulnerability. This folder must remain strictly clean of any active secret assets.
2. **Automated On-The-Fly Provisioning:**
   All required credentials are automatically generated and secured during the initial host setup:
   * **Installation Phase:** The [install.ps1](file:///Users/justyngreen/Repos/Justyn/immortalmgmt/install.ps1) setup script prompts for the required service account and SSH replication passwords, generates a cryptographically strong 32-byte key, encrypts the secrets, and saves them locally.
   * **Self-Healing Bootstrapping:** If any required keys are missing at runtime, the bootstrap and manager scripts automatically trigger automated setup/provisioning routines.
3. **Local Machine Binding:**
   The generated symmetric keys and Access Control Lists (ACLs) are cryptographically bound to the local server environment, making them unique and non-portable between different host instances.

## Repository Ignorance Policy
The repository's [.gitignore](file:///Users/justyngreen/Repos/Justyn/immortalmgmt/.gitignore) is strictly configured to block the tracking of all credential files:
* `*.key` — AES Symmetric Keys (Do NOT commit)
* `*.enc` — Encrypted Secrets (Do NOT commit)
* `*.xml` / `*.pwd` — Legacy credentials and temporary plain-text vectors (Do NOT commit)

The only file tracked in this folder is this documentation file (`Credential.md`), ensuring that the folder structure is created on target nodes during initial git clones.
