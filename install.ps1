# Requires -RunAsAdministrator

[CmdletBinding()]
Param(
    [string]$InstallPath,
    [string]$EmailTo,
    [string]$EmailFrom,
    [string]$EmailAppPassword,
    [string]$EnvironmentName,
    [SecureString]$ServiceAccountPassword,
    [SecureString]$RemoteSshPassword,
    [switch]$Unattended
)

$ScriptName  = "install"
$ScriptDir   = $PSScriptRoot
$BaseDir     = $ScriptDir

$LogsDir     = Join-Path $BaseDir "Logs"
if (-not (Test-Path $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

$LogFile     = Join-Path $LogsDir "$ScriptName.log"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$Environment = "#{ENVIRONMENT}#" # GitOps Placeholder

# 1. Native Write-Log Function with Severity Levels
Function Write-Log {
    Param(
        [Parameter(Mandatory=$true, Position=0)][string]$Message,
        [Parameter(Position=1)][ValidateSet("INFO", "WARNING", "ERROR", "CRITICAL")][string]$Level = "INFO",
        [switch]$Start, 
        [switch]$End
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    if ($Start) { "( --- START [$Timestamp] $ScriptName --- )" | Out-File -FilePath $LogFile -Append }
    
    "[$Timestamp] [$Level] [$Environment] $Message" | Out-File -FilePath $LogFile -Append
    
    if ($Level -eq "ERROR" -or $Level -eq "CRITICAL") { Write-Host "[$Level] $Message" -ForegroundColor Red }
    elseif ($Level -eq "WARNING") { Write-Host "[$Level] $Message" -ForegroundColor Yellow }
    else { Write-Host "[$Level] $Message" -ForegroundColor Gray }

    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

try {
    Write-Log "Initializing Guided Install wizard." -Start

    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host "      IMMORTALMGMT AUTOMATION FRAMEWORK INSTALLATION WIZARD      " -ForegroundColor Cyan
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host ""

    # =====================================================================
    # Step 1: Installation Directory Setup & File Migration
    # =====================================================================
    Write-Host "[STEP 1] Installation Path Configuration" -ForegroundColor Green
    $DefaultPath = "C:\ImmortalMgmt"
    if ($Unattended) {
        $InstallPath = if ($InstallPath) { $InstallPath } else { $DefaultPath }
    } else {
        if ($InstallPath) {
            $UserInputPath = Read-Host "Enter target installation directory [Default: $InstallPath]"
            $InstallPath = if ([string]::IsNullOrWhiteSpace($UserInputPath)) { $InstallPath } else { $UserInputPath }
        } else {
            $UserInputPath = Read-Host "Enter target installation directory [Default: $DefaultPath]"
            $InstallPath = if ([string]::IsNullOrWhiteSpace($UserInputPath)) { $DefaultPath } else { $UserInputPath }
        }
    }

    Write-Log "Target installation path resolved to: $InstallPath" "INFO"

    if ($InstallPath -ne $BaseDir) {
        Write-Host "Creating directory and copying repository files to $InstallPath..." -ForegroundColor Gray
        if (-not (Test-Path $InstallPath)) {
            New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
        }
        
        # Copy all folders and files except itself recursively
        $ExcludeList = @("install.log")
        Get-ChildItem -Path $BaseDir -Exclude $ExcludeList | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $InstallPath -Recurse -Force
        }
        
        # Re-target variables to the new installation path
        $BaseDir = $InstallPath
        $LogsDir = Join-Path $BaseDir "Logs"
        $LogFile = Join-Path $LogsDir "$ScriptName.log"
        $GlobalFile = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
        Write-Host "Files migrated successfully to $InstallPath." -ForegroundColor Green
    } else {
        Write-Host "Running installation in-place at $BaseDir." -ForegroundColor Green
    }

    # =====================================================================
    # Step 2: Dependency Checks & Installations
    # =====================================================================
    Write-Host ""
    Write-Host "[STEP 2] Performing dependency checks..." -ForegroundColor Green
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # 1. NuGet Provider
    $NuGetProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
    if (-not $NuGetProvider) {
        Write-Log "NuGet provider missing. Installing..." "INFO"
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
            Write-Log "NuGet provider installed successfully." "INFO"
        } catch {
            throw "Failed to install NuGet provider: $($_.Exception.Message)"
        }
    } else {
        Write-Log "NuGet provider is available." "INFO"
    }

    # 2. PoshMailKit Module
    $PoshMailKit = Get-Module -Name PoshMailKit -ListAvailable -ErrorAction SilentlyContinue
    if (-not $PoshMailKit) {
        Write-Log "PoshMailKit module missing. Installing..." "INFO"
        try {
            $Repo = Get-PSRepository -Name "PSGallery" -ErrorAction SilentlyContinue
            if ($Repo -and $Repo.InstallationPolicy -ne "Trusted") {
                Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction Stop
            }
            Install-Module -Name PoshMailKit -Force -AllowClobber -Scope AllUsers -ErrorAction Stop | Out-Null
            Write-Log "PoshMailKit module installed successfully." "INFO"
        } catch {
            throw "Failed to install PoshMailKit module: $($_.Exception.Message)"
        }
    } else {
        Write-Log "PoshMailKit module is available." "INFO"
    }

    # 3. WSL and Default Linux Distribution (Ubuntu)
    $WslInstalled = $false
    $WslDistroInstalled = $false
    
    if (Get-Command "wsl.exe" -ErrorAction SilentlyContinue) {
        $WslInstalled = $true
        # Check if default distro is registered and executing
        $null = & wsl.exe true 2>$null
        if ($LASTEXITCODE -eq 0) {
            $WslDistroInstalled = $true
        }
    }
    
    if (-not $WslDistroInstalled) {
        Write-Log "WSL and/or default Linux distribution is missing." "WARNING"
        $InstallWslInput = $true
        if (-not $Unattended) {
            $PromptWsl = Read-Host "Do you want to install/enable WSL and the default Linux distribution (Ubuntu) now? (Y/N) [Default: Y]"
            if ([string]::IsNullOrWhiteSpace($PromptWsl) -or $PromptWsl.ToUpper().Trim() -ne "Y") {
                $InstallWslInput = $false
            }
        }
        
        if ($InstallWslInput) {
            Write-Log "Installing WSL and default Linux distribution (Ubuntu)..." "INFO"
            try {
                & wsl.exe --install --no-launch -d Ubuntu
                Write-Log "WSL installation command triggered successfully." "INFO"
                Write-Host "-----------------------------------------------------------------" -ForegroundColor Yellow
                Write-Host "IMPORTANT: A system restart may be required to finalize the WSL" -ForegroundColor Yellow
                Write-Host "installation and VM platform features before rsync runs." -ForegroundColor Yellow
                Write-Host "-----------------------------------------------------------------" -ForegroundColor Yellow
            } catch {
                Write-Log "Warning: Failed to install WSL automatically: $($_.Exception.Message)" "WARNING"
                Write-Host "Warning: Automated WSL installation failed. Please install manually using 'wsl --install'." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Log "WSL and default Linux distribution are available." "INFO"
    }

    # =====================================================================
    # Step 3: Global Variables Configuration (Email Details)
    # =====================================================================
    Write-Host ""
    Write-Host "[STEP 3] Global Configuration Setup (Email Alerting)" -ForegroundColor Green
    
    if (-not $Unattended) {
        if ([string]::IsNullOrWhiteSpace($EmailTo) -and [string]::IsNullOrWhiteSpace($EmailFrom)) {
            $ConfigureEmail = Read-Host "Do you want to configure email alerts now? (Y/N) [Default: Y]"
            if ([string]::IsNullOrWhiteSpace($ConfigureEmail) -or $ConfigureEmail.ToUpper().Trim() -eq "Y") {
                $EmailTo = Read-Host "Enter alert recipient email address (EmailTo)"
                $EmailFrom = Read-Host "Enter alert sender email address (EmailFrom)"
                $EmailAppPassword = Read-Host "Enter App-Specific Gmail Password (EmailAppPassword)"
            }
        }
    }

    # Load and update Global configuration
    $GlobalConfig = [ordered]@{
        EmailTo          = $EmailTo
        EmailFrom        = $EmailFrom
        EmailAppPassword = $EmailAppPassword
    }
    
    $GlobalConfig | ConvertTo-Json -Depth 5 | Out-File -FilePath $GlobalFile -Force
    Write-Log "Created / Updated global configuration at $GlobalFile." "INFO"

    # =====================================================================
    # Step 4: Host Specific Setup & System Inventory
    # =====================================================================
    Write-Host ""
    Write-Host "[STEP 4] Host Inventory Setup" -ForegroundColor Green
    $Hostname = $env:COMPUTERNAME
    Write-Log "Identified local hostname: $Hostname" "INFO"

    $HostsDir = Join-Path (Join-Path $BaseDir "Variables") "Hosts"
    if (-not (Test-Path $HostsDir)) {
        New-Item -Path $HostsDir -ItemType Directory -Force | Out-Null
    }

    $HostDir = Join-Path $HostsDir $Hostname
    if (-not (Test-Path $HostDir)) {
        New-Item -Path $HostDir -ItemType Directory -Force | Out-Null
    }

    $DefaultHostDir = Join-Path $HostsDir "DefaultHost"
    if (Test-Path $DefaultHostDir) {
        Get-ChildItem -Path $DefaultHostDir | ForEach-Object {
            $destFile = Join-Path $HostDir $_.Name
            if (-not (Test-Path $destFile)) {
                Copy-Item -Path $_.FullName -Destination $destFile -Force
            }
        }
    }

    $KeepFile = Join-Path $HostDir ".keep"
    if (-not (Test-Path $KeepFile)) {
        "This folder is for host $Hostname variables." | Out-File -FilePath $KeepFile -Force
    }

    Write-Log "Gathering system information for $Hostname..." "INFO"
    $OSInfo = Get-CimInstance Win32_OperatingSystem
    $CPUInfo = Get-CimInstance Win32_Processor
    $MemInfo = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
    
    $IPAddresses = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }).IPAddress
    $MACAddresses = (Get-NetAdapter | Where-Object Status -eq "Up").MacAddress

    $HostVars = @{
        HostName        = $Hostname
        OSName          = $OSInfo.Caption
        OSVersion       = $OSInfo.Version
        OSArchitecture  = $OSInfo.OSArchitecture
        CPU             = $CPUInfo.Name
        RAM_GB          = [Math]::Round($MemInfo.Sum / 1GB, 2)
        IPAddresses     = $IPAddresses
        MACAddresses    = $MACAddresses
        TimeZone        = (Get-TimeZone).Id
        Domain          = (Get-CimInstance Win32_ComputerSystem).Domain
        InstallDate     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    $HostVarsFile = Join-Path $HostDir "_Host.json"
    $HostVars | ConvertTo-Json -Depth 5 | Out-File -FilePath $HostVarsFile -Force
    Write-Log "Created thorough set of host variables in $HostVarsFile" "INFO"

    # Update .gitignore
    $GitIgnoreFile = Join-Path $BaseDir ".gitignore"
    $IgnoreEntry = "Variables/Hosts/$Hostname/"
    if (Test-Path $GitIgnoreFile) {
        $GitIgnoreContent = Get-Content -Path $GitIgnoreFile
        if ($GitIgnoreContent -notcontains $IgnoreEntry) {
            $IgnoreEntry | Out-File -FilePath $GitIgnoreFile -Append
        }
    } else {
        $IgnoreEntry | Out-File -FilePath $GitIgnoreFile -Force
    }

    # =====================================================================
    # Step 5: Environment Placeholder Validation & Customization
    # =====================================================================
    Write-Host ""
    Write-Host "[STEP 5] Environment Variable Validation" -ForegroundColor Green
    
    if ($EnvironmentName) {
        $ResolvedEnv = $EnvironmentName
    } elseif ($Unattended) {
        $ResolvedEnv = "Production"
    } else {
        # Display Environment Choice
        Write-Host "Select framework environment to configure:" -ForegroundColor Gray
        Write-Host "  1) Production"
        Write-Host "  2) Staging"
        Write-Host "  3) Development"
        Write-Host "  4) Custom"
        
        $EnvChoice = Read-Host "Enter choice (1-4) [Default: 1]"
        $ResolvedEnv = switch ($EnvChoice) {
            "1" { "Production" }
            "2" { "Staging" }
            "3" { "Development" }
            "4" { Read-Host "Enter custom environment name" }
            default { "Production" }
        }
    }
    
    if ([string]::IsNullOrWhiteSpace($ResolvedEnv)) { $ResolvedEnv = "Production" }
    $Environment = $ResolvedEnv
    Write-Log "Resolved environment context: $Environment" "INFO"

    # Replace environment placeholder across all script files inside the installation directory
    Write-Host "Enforcing environment context across script files..." -ForegroundColor Gray
    $FilesToScan = Get-ChildItem -Path $BaseDir -Filter "*.ps1" -Recurse -File
    foreach ($file in $FilesToScan) {
        $Content = Get-Content -Path $file.FullName -Raw
        if ($Content -match "#\{ENVIRONMENT\}#") {
            $Content = $Content -replace "#\{ENVIRONMENT\}#", $Environment
            $Content | Out-File -FilePath $file.FullName -Force
            Write-Log "Replaced environment placeholder in: $($file.Name)" "INFO"
        }
    }
    
    # =====================================================================
    # Step 6: Service Account Provisioning & Security Hardening
    # =====================================================================
    Write-Host ""
    Write-Host "[STEP 6] Provisioning Service Account & Hardening Security" -ForegroundColor Green
    
    # Pre-stage the credential file if ServiceAccountPassword parameter is provided
    if ($ServiceAccountPassword) {
        $CredFolder = Join-Path $BaseDir "Credentials"
        $KeyFile = Join-Path $CredFolder "svc_immortalmgmt.key"
        $EncFile = Join-Path $CredFolder "svc_immortalmgmt.enc"
        
        # Generate key file
        $KeyBytes = New-Object Byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
        $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
        if (-not (Test-Path $CredFolder)) { New-Item -Path $CredFolder -ItemType Directory -Force | Out-Null }
        $KeyBase64 | Out-File -FilePath $KeyFile -Encoding utf8 -Force
        
        # Encrypt password
        $EncryptedText = ConvertFrom-SecureString $ServiceAccountPassword -Key $KeyBytes
        $EncryptedText | Out-File -FilePath $EncFile -Encoding utf8 -Force
        
        # Set strict ACL permissions
        try {
            $Acls = @($KeyFile, $EncFile)
            foreach ($file in $Acls) {
                $Acl = Get-Acl -Path $file
                $Acl.SetAccessRuleProtection($true, $false)
                $Rules = @(
                    [System.Security.AccessControl.FileSystemAccessRule]::new("SYSTEM", "FullControl", "Allow"),
                    [System.Security.AccessControl.FileSystemAccessRule]::new("Administrators", "FullControl", "Allow"),
                    [System.Security.AccessControl.FileSystemAccessRule]::new("svc_immortalmgmt", "ReadAndExecute", "Allow")
                )
                $Acl.Access | ForEach-Object { $Acl.RemoveAccessRule($_) } | Out-Null
                foreach ($Rule in $Rules) { $Acl.AddAccessRule($Rule) }
                Set-Acl -Path $file -AclObject $Acl -ErrorAction Stop
            }
        } catch {
            Write-Log "Warning: Failed to set strict ACLs on credential files during unattended pre-stage: $($_.Exception.Message)" "WARNING"
        }
        
        Write-Log "Pre-staged service account symmetric credentials from ServiceAccountPassword parameter." "INFO"
    }

    Write-Host "Executing New-LocalAdminAccount script to create 'svc_immortalmgmt' and lock down repository..." -ForegroundColor Gray
    $AccountScript = Join-Path (Join-Path $BaseDir "Scripts\Windows") "30 - New-LocalAdminAccount.ps1"
    if (Test-Path $AccountScript) {
        $LASTEXITCODE = 0
        & $AccountScript
        if ($LASTEXITCODE -ne 0) {
            throw "Service account setup failed with exit code $LASTEXITCODE. The password may not meet complexity requirements or the account cannot be created."
        }
        Write-Host "Service account created and repository security hardened successfully!" -ForegroundColor Green
    }
    
    # =====================================================================
    # Step 6.5: Remote Host Credentials (for Media Manager)
    # =====================================================================
    Write-Host ""
    Write-Host "[STEP 6.5] Configuring Remote Host SSH Credentials (stuff)" -ForegroundColor Green
    
    $stuffKeyFile = Join-Path $BaseDir "Credentials\stuff.key"
    $stuffEncFile = Join-Path $BaseDir "Credentials\stuff.enc"
    
    $ConfigureSsh = $false
    if ($RemoteSshPassword) {
        $ConfigureSsh = $true
        $SshPwd = $RemoteSshPassword
    } elseif (-not $Unattended) {
        $PromptSsh = Read-Host "Do you want to configure the Remote SSH Host password (stuff) now? (Y/N) [Default: Y]"
        if ([string]::IsNullOrWhiteSpace($PromptSsh) -or $PromptSsh.ToUpper().Trim() -eq "Y") {
            $ConfigureSsh = $true
            $SshPwd = Read-Host -AsSecureString "Enter password for the remote SSH host"
        }
    }
    
    if ($ConfigureSsh) {
        # Generate key file
        $KeyBytes = New-Object Byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
        $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
        
        $CredFolder = Join-Path $BaseDir "Credentials"
        if (-not (Test-Path $CredFolder)) { New-Item -Path $CredFolder -ItemType Directory -Force | Out-Null }
        
        $KeyBase64 | Out-File -FilePath $stuffKeyFile -Encoding utf8 -Force
        $EncryptedText = ConvertFrom-SecureString $SshPwd -Key $KeyBytes
        $EncryptedText | Out-File -FilePath $stuffEncFile -Encoding utf8 -Force
        
        # Set strict ACL permissions
        try {
            $Acls = @($stuffKeyFile, $stuffEncFile)
            foreach ($file in $Acls) {
                $Acl = Get-Acl -Path $file
                $Acl.SetAccessRuleProtection($true, $false)
                $Rules = @(
                    [System.Security.AccessControl.FileSystemAccessRule]::new("SYSTEM", "FullControl", "Allow"),
                    [System.Security.AccessControl.FileSystemAccessRule]::new("Administrators", "FullControl", "Allow"),
                    [System.Security.AccessControl.FileSystemAccessRule]::new("svc_immortalmgmt", "ReadAndExecute", "Allow")
                )
                $Acl.Access | ForEach-Object { $Acl.RemoveAccessRule($_) } | Out-Null
                foreach ($Rule in $Rules) { $Acl.AddAccessRule($Rule) }
                Set-Acl -Path $file -AclObject $Acl -ErrorAction Stop
            }
            Write-Host "Remote SSH credentials configured and ACL security hardened successfully!" -ForegroundColor Green
        } catch {
            Write-Log "Warning: Failed to set strict ACLs on remote SSH credential files: $($_.Exception.Message)" "WARNING"
        }
    }
    
    # =====================================================================
    # Step 7: Dynamic Task Registration (Bootstrapping)
    # =====================================================================
    Write-Host ""
    Write-Host "[STEP 7] Registering Scheduled Tasks (Bootstrapping)" -ForegroundColor Green
    
    $RunBoot = $true
    if (-not $Unattended) {
        $RunBootstrap = Read-Host "Do you want to run the bootstrap script to register scheduled tasks now? (Y/N) [Default: Y]"
        if ([string]::IsNullOrWhiteSpace($RunBootstrap) -or $RunBootstrap.ToUpper().Trim() -ne "Y") {
            $RunBoot = $false
        }
    }
    
    if ($RunBoot) {
        $BootstrapScript = Join-Path (Join-Path $BaseDir "Scripts\Windows") "000 - Bootstrap Script.ps1"
        if (Test-Path $BootstrapScript) {
            try {
                Write-Host "Executing 000 - Bootstrap Script.ps1..." -ForegroundColor Gray
                $CurrentDir = Get-Location
                Set-Location (Split-Path $BootstrapScript)
                & $BootstrapScript
                Set-Location $CurrentDir
                Write-Host "Scheduled tasks registered and bootstrapped successfully!" -ForegroundColor Green
            } catch {
                Write-Log "Warning: Bootstrap script returned an error: $($_.Exception.Message)" "WARNING"
                Write-Host "Warning: Bootstrap execution failed. Please run 'C:\Scripts\Scripts\Windows\000 - Bootstrap Script.ps1' manually." -ForegroundColor Yellow
            }
        } else {
            Write-Log "Bootstrap script not found at $BootstrapScript." "WARNING"
        }
    }
    
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host "      INSTALLATION AND INITIAL CONFIGURATION COMPLETE!          " -ForegroundColor Green
    Write-Host "      Base Directory: $BaseDir" -ForegroundColor Green
    Write-Host "      Active Environment: $Environment" -ForegroundColor Green
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host ""

} catch {
    Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"
    Write-Host "FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Write-Log "Guided Install completed." -End
}
