### MASTER SCRIPT ###
## Media Manager Updates and Move with MNamer and WSL ##

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path (Split-Path $ScriptDir -Parent) -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$CredFile    = Join-Path (Join-Path $BaseDir "Credentials") "svc_immortalmgmt.xml"
    $config = . (Join-Path $BaseDir "Functions\Get-ScriptConfig.ps1") -ScriptName "01 - MediaManager"
    Write-Log "Loaded Configuration Variables:" "INFO"
    foreach ($prop in $config.psobject.Properties) {
        if ($prop.Name -match "Password|Token") {
            Write-Log "  $($prop.Name) = ********" "INFO"
        } else {
            Write-Log "  $($prop.Name) = $($prop.Value)" "INFO"
        }
    }

# --- Local Windows Paths ---
$winSourcePath       = $config.winSourcePath 
$winTvPath           = $config.winTvPath
$winMoviesPath       = $config.winMoviesPath
$winCredFilePath     = $config.winCredFilePath # Point this to stuff.xml in JSON

# --- Remote Server Config ---
$remoteUser          = $config.remoteUser
$remoteHost          = $config.remoteHost
$remoteMoviesDest    = $config.remoteMoviesDest
$remoteTvDest        = $config.remoteTvDest

# --- Source Server (Master - Plex) ---
$sourceHost          = $config.sourceHost
$sourceUser          = $config.sourceUser
$sourceMoviesPath    = $config.sourceMoviesPath
$sourceTvPath        = $config.sourceTvPath

# --- Destination Server (Replica - Jellyfin) ---
$destHost            = $config.destHost
$destUser            = $config.destUser
$destMoviesPath      = $config.destMoviesPath
$destTvPath          = $config.destTvPath

# --- Logging & Settings ---
$logFilePath         = $LogFile
$masterLogPath       = $LogFile
$emailTo             = $config.emailTo
$emailFrom           = $config.emailFrom
$appPassword         = $config.EmailAppPassword

# =====================================================================
# Helper Functions
# =====================================================================

function Rotate-Log {
    if (Test-Path $logFilePath) {
        $logFile = Get-Item $logFilePath
        # Check if file size is greater than 128MB (134,217,728 bytes)
        if ($logFile.Length -gt 134217728) {
            $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $rotatedLogPath = $logFilePath -replace "\.log$", "-$timestamp.log"
            Rename-Item -Path $logFilePath -NewName (Split-Path $rotatedLogPath -Leaf)
            Write-Host "Log file exceeded 128MB. Rotated to $rotatedLogPath"
        }
    }
}

function Write-Log {
    param ([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    $logDir = Split-Path $logFilePath
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $logFilePath -Value $logEntry
}

function ConvertTo-WslPath {
    param ([string]$WindowsPath)
    $driveLetter = $WindowsPath.Substring(0, 1).ToLower()
    $pathWithoutDrive = $WindowsPath.Substring(2).Replace('\', '/')
    return "/mnt/$driveLetter$pathWithoutDrive"
}

# =====================================================================
# Initialization & Just-In-Time Credential Extraction
# =====================================================================
Rotate-Log
Write-Log "#################### --------- Start of script -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --------- ####################"

# 1. Validate that WSL is enabled (and command exists)
if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
    Write-Log "WSL is not enabled on this system. Enabling WSL and installing Ubuntu..." "WARNING"
    try {
        # Enable WSL and install Ubuntu (requires elevation)
        $process = Start-Process -FilePath "wsl.exe" -ArgumentList "--install", "--no-launch", "-d", "Ubuntu" -NoNewWindow -PassThru -Wait
        if ($process.ExitCode -ne 0) {
            # Fallback to DISM if wsl --install is not supported/fails
            dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
            dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
            throw "WSL feature enabled via DISM, but wsl.exe was not found. A system reboot is required."
        }
        Write-Log "WSL has been enabled and Ubuntu installation triggered. A reboot may be required." "INFO"
    } catch {
        Write-Log "Failed to enable WSL automatically: $($_.Exception.Message)" "CRITICAL"
        exit 1
    }
}

# 2. Validate there is a default Linux distro and it is functional
$null = & wsl.exe true 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Log "WSL is enabled, but no default Linux distribution (Ubuntu) is installed or functional. Triggering installation..." "WARNING"
    try {
        # Try to install Ubuntu distro
        $process = Start-Process -FilePath "wsl.exe" -ArgumentList "--install", "-d", "Ubuntu", "--no-launch" -NoNewWindow -PassThru -Wait
        # Check if successful
        $null = & wsl.exe true 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Ubuntu installation completed but WSL is still not executing commands. A reboot is likely required."
        }
        Write-Log "Ubuntu Linux distribution has been successfully installed and registered." "INFO"
    } catch {
        Write-Log "Failed to install Ubuntu distribution: $($_.Exception.Message)" "CRITICAL"
        exit 1
    }
}

# Load password from secure Credentials/stuff.key and stuff.enc if available, else migrate legacy stuff.xml
$CredFolder       = Join-Path $BaseDir "Credentials"
$stuffKeyFile     = Join-Path $CredFolder "stuff.key"
$stuffEncFile     = Join-Path $CredFolder "stuff.enc"

$DecryptionSuccess = $false

if ((Test-Path $stuffKeyFile) -and (Test-Path $stuffEncFile)) {
    try {
        $Key = [Convert]::FromBase64String((Get-Content -Path $stuffKeyFile -Raw).Trim())
        $EncryptedText = (Get-Content -Path $stuffEncFile -Raw).Trim()
        $SecureString = ConvertTo-SecureString $EncryptedText -Key $Key
        $plainPassword = [System.Net.NetworkCredential]::new("", $SecureString).Password
        $DecryptionSuccess = $true
    } catch {
        Write-Log "Failed to decrypt symmetric stuff credentials: $($_.Exception.Message)" "WARNING"
    }
}

if (-not $DecryptionSuccess) {
    if (Test-Path $winCredFilePath) {
        try {
            $secureString = Import-Clixml -Path $winCredFilePath
            $plainPassword = [System.Net.NetworkCredential]::new("", $secureString).Password
            
            # Migrate to symmetric files on the fly
            $KeyBytes = New-Object Byte[] 32
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
            $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
            $KeyBase64 | Out-File -FilePath $stuffKeyFile -Encoding utf8 -Force
            
            $EncryptedText = ConvertFrom-SecureString $secureString -Key $KeyBytes
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
            } catch {
                Write-Log "Warning: Failed to set strict ACLs on symmetric stuff files: $($_.Exception.Message)" "WARNING"
            }
            
            $DecryptionSuccess = $true
            Write-Log "Successfully migrated legacy DPAPI stuff.xml to symmetric key encryption on-the-fly." "INFO"
        } catch {
            Write-Log "Failed to decrypt legacy XML credential file: $($_.Exception.Message)" "WARNING"
        }
    }
}

if (-not $DecryptionSuccess) {
    if ([Environment]::UserInteractive) {
        Write-Log "Symmetric credential files missing or invalid. Prompting to create them..." "WARNING"
        Write-Host ""
        Write-Host "--------------------------------------------------" -ForegroundColor Yellow
        Write-Host "CREATING REMOTE HOST SSH CREDENTIALS (STUFF)" -ForegroundColor Yellow
        Write-Host "--------------------------------------------------" -ForegroundColor Yellow
        $PasswordInput = Read-Host -AsSecureString "Enter password for remote SSH host"
        
        # Generate key file
        $KeyBytes = New-Object Byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
        $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
        if (-not (Test-Path $CredFolder)) { New-Item -Path $CredFolder -ItemType Directory -Force | Out-Null }
        $KeyBase64 | Out-File -FilePath $stuffKeyFile -Encoding utf8 -Force
        
        # Encrypt password
        $EncryptedText = ConvertFrom-SecureString $PasswordInput -Key $KeyBytes
        $EncryptedText | Out-File -FilePath $stuffEncFile -Encoding utf8 -Force
        
        $plainPassword = [System.Net.NetworkCredential]::new("", $PasswordInput).Password
        $DecryptionSuccess = $true
        
        # Set ACLs
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
        } catch {
            Write-Log "Warning: Failed to set strict ACLs on symmetric stuff files: $($_.Exception.Message)" "WARNING"
        }
        
        Write-Log "Successfully created symmetric credentials for remote host." "INFO"
    } else {
        Write-Log "Failed to decrypt SSH credentials and session is non-interactive. Ensure C:\Scripts\Credentials\stuff.key and stuff.enc exist." "CRITICAL"
        exit
    }
}

# =====================================================================
# Step 1.5: Validate and Provision WSL Prerequisites (sshpass, pip3, mnamer)
# =====================================================================
Write-Log "Verifying WSL prerequisite packages (pip3, sshpass, mnamer)..." "INFO"

$wslPipCheck = wsl.exe -u root -e sh -c "command -v pip3"
$wslSshpassCheck = wsl.exe -u root -e sh -c "command -v sshpass"
$wslMnamerCheck = wsl.exe -u root -e sh -c "command -v mnamer"

if (-not $wslPipCheck -or -not $wslSshpassCheck -or -not $wslMnamerCheck) {
    Write-Log "WSL is missing one or more required prerequisites. Initiating automated provisioning..." "WARNING"
    try {
        # 1. First ensure system packages (pip3, sshpass, python3) are installed
        if (-not $wslPipCheck -or -not $wslSshpassCheck) {
            Write-Log "Installing system packages (python3-pip, sshpass) via apt-get directly as root..." "INFO"
            $aptCmd = "apt-get update && apt-get install -y python3-pip sshpass python3"
            $aptOutput = $aptCmd | wsl.exe -u root 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Apt installation failed. Output: $aptOutput"
            }
            Write-Log "System packages successfully installed." "INFO"
        }

        # 2. Ensure mnamer is installed via pip3
        Write-Log "Installing/Upgrading mnamer via pip3 directly as root..." "INFO"
        $pipCmd = "pip3 install --upgrade mnamer || pip3 install --upgrade mnamer --break-system-packages"
        $pipOutput = $pipCmd | wsl.exe -u root 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Pip installation of mnamer failed. Output: $pipOutput"
        }
        Write-Log "mnamer successfully provisioned." "INFO"
        
    } catch {
        Write-Log "Failed to provision WSL prerequisites: $($_.Exception.Message)" "CRITICAL"
        exit 1
    }
} else {
    Write-Log "All WSL prerequisites (pip3, sshpass, mnamer) are already installed and verified." "INFO"
}

# =====================================================================
# Main Execution Try/Catch Block
# =====================================================================
try {
    # ---------------------------------------------------------------------
    # Step 2: Starting Single-Pass mnamer Run
    # ---------------------------------------------------------------------
    Write-Log "Starting Single-Pass mnamer Run (Default Distro)..."

    # ---------------------------------------------------------------------
    # Step 3: Main Processing (Single Pass)
    # ---------------------------------------------------------------------
    $wslSource = ConvertTo-WslPath $winSourcePath
    $wslTv     = ConvertTo-WslPath $winTvPath
    $wslMovies = ConvertTo-WslPath $winMoviesPath

    $epFormat = "{series}/Season {season:02}/{series} S{season:02}E{episode:02} - {title} ({date}).{extension}"
    Write-Log "Processing source: $wslSource"

    $mnamerCommand = "mnamer --no-overwrite --episode-directory '$wslTv' --episode-format '$epFormat' --movie-directory '$wslMovies' -vrb '$wslSource'"

    try {
        $output = wsl.exe -e sh -c $mnamerCommand 2>&1
        if ($LASTEXITCODE -eq 0) {
            $meaningfulOutput = $output | Where-Object { $_ -match "Processing|Moving|Renaming" -and $_ -notmatch "0 files processed" }
            if ($meaningfulOutput) {
                Write-Log "Activity Detected:`n$($meaningfulOutput -join "`n")"
            } else {
                Write-Log "No new media processed."
            }
        } else {
            Write-Log "mnamer error code: $LASTEXITCODE" "WARNING"
            Write-Log "Output: $($output -join "`n")" "WARNING"
        }
    }
    catch {
        Write-Log "WSL Execution Error: $($_.Exception.Message)" "CRITICAL"
    }

    # ---------------------------------------------------------------------
    # Replication Script for Plex 
    # ---------------------------------------------------------------------
    Write-Log "Starting Local to Plex Transfer (Default Distro)..."

    $sshpassCheck = wsl.exe -e sh -c "command -v sshpass"
    if (-not $sshpassCheck) {
        Write-Log "sshpass is NOT installed in your default WSL distro. Please install it." "CRITICAL"
        exit
    }

    $syncJobsLocalToPlex = @(
        @{ Name = "Movies"; WinSource = $winMoviesPath; WslSource = (ConvertTo-WslPath $winMoviesPath) + "/"; Dest = "${remoteUser}@${remoteHost}:${remoteMoviesDest}" },
        @{ Name = "TV"; WinSource = $winTvPath; WslSource = (ConvertTo-WslPath $winTvPath) + "/"; Dest = "${remoteUser}@${remoteHost}:${remoteTvDest}" }
    )

    foreach ($job in $syncJobsLocalToPlex) {
        if (-not (Test-Path $job.WinSource)) {
                Write-Log "Source path $($job.WinSource) does not exist. Skipping." "WARNING"
                continue
        }
        
        $fileCount = (Get-ChildItem -Path $job.WinSource -File -Recurse | Measure-Object).Count
        if ($fileCount -eq 0) {
            Write-Log "No files found in [$($job.Name)]. Skipping."
            continue
        }

        Write-Log "Processing [$($job.Name)] ($fileCount files found)..."
        
        # Uses SSHPASS environment variable passed to sshpass -e
        $wslCommand = "SSHPASS='$plainPassword' sshpass -e rsync -avz --itemize-changes --timeout=60 --remove-source-files -e 'ssh -o StrictHostKeyChecking=no' '$($job.WslSource)' '$($job.Dest)'"
        
        try {
            $tempOut = New-TemporaryFile
            $tempErr = New-TemporaryFile
            
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = "cmd.exe"
            $processStartInfo.Arguments = "/c wsl.exe -u root $wslCommand > `"$($tempOut.FullName)`" 2> `"$($tempErr.FullName)`""
            $processStartInfo.UseShellExecute = $false
            $processStartInfo.CreateNoWindow = $true

            $process = [System.Diagnostics.Process]::Start($processStartInfo)
            $process.WaitForExit()
            
            $stdout = Get-Content $tempOut.FullName -Raw
            $stderr = Get-Content $tempErr.FullName -Raw

            if ($process.ExitCode -eq 0) {
                $changes = $stdout -split "`n" | Where-Object { $_ -notmatch "sending incremental file list|sent .* bytes|total size is" -and $_.Trim() -ne "" }
                if ($changes) {
                    Write-Log "[$($job.Name)] Transfer Success:`n$($changes -join "`n")"
                }
                
                Write-Log "[$($job.Name)] cleaning up empty folders..."
                Get-ChildItem -Path $job.WinSource -Directory -Recurse | 
                    Where-Object { (Get-ChildItem -Path $_.FullName -File -Recurse).Count -eq 0 } | 
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    
            } else {
                Write-Log "rsync error for [$($job.Name)]. Exit code: $($process.ExitCode)" "ERROR"
                Write-Log "StdOut: $stdout" "ERROR"
                Write-Log "StdErr: $stderr" "ERROR"
            }
            
            Remove-Item $tempOut -Force
            Remove-Item $tempErr -Force
        }
        catch {
            Write-Log "Execution error for [$($job.Name)]: $($_.Exception.Message)" "CRITICAL"
        }
    }

    # ---------------------------------------------------------------------
    # Replication for JellyFin Server
    # ---------------------------------------------------------------------
    Write-Log "Starting Plex -> Jellyfin Mirror Job (Default Distro)..."

    $syncJobsPlexToJellyfin = @(
        @{ Name = "Movies"; SourcePath = $sourceMoviesPath; DestPath = "${destUser}@${destHost}:${destMoviesPath}" },
        @{ Name = "TV"; SourcePath = $sourceTvPath; DestPath = "${destUser}@${destHost}:${destTvPath}" }
    )

    foreach ($job in $syncJobsPlexToJellyfin) {
        Write-Log "Mirroring [$($job.Name)] from Plex to Jellyfin..."
        
        $remoteRsyncCmd = "rsync -avz --delete --itemize-changes --timeout=60 -e 'ssh -o StrictHostKeyChecking=no' '$($job.SourcePath)' '$($job.DestPath)'"
        
        # Uses SSHPASS environment variable passed to sshpass -e
        $wslCommand = "SSHPASS='$plainPassword' sshpass -e ssh -o StrictHostKeyChecking=no ${sourceUser}@${sourceHost} ""$remoteRsyncCmd"""

        try {
            $tempOut = New-TemporaryFile
            $tempErr = New-TemporaryFile
            
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = "cmd.exe"
            $processStartInfo.Arguments = "/c wsl.exe -u root $wslCommand > `"$($tempOut.FullName)`" 2> `"$($tempErr.FullName)`""
            $processStartInfo.UseShellExecute = $false
            $processStartInfo.CreateNoWindow = $true

            $process = [System.Diagnostics.Process]::Start($processStartInfo)
            $process.WaitForExit()

            $stdout = Get-Content $tempOut.FullName -Raw
            $stderr = Get-Content $tempErr.FullName -Raw

            if ($process.ExitCode -eq 0) {
                $changes = $stdout -split "`n" | Where-Object { $_ -notmatch "sending incremental file list|sent .* bytes|total size is" -and $_.Trim() -ne "" }
                if ($changes) {
                    Write-Log "[$($job.Name)] Mirror Processed. Itemized Changes:`n$($changes -join "`n")"
                } else {
                    Write-Log "[$($job.Name)] Mirror Complete. Folders are perfectly identical."
                }
            } else {
                Write-Log "Mirror failed for [$($job.Name)]. Exit code: $($process.ExitCode)" "ERROR"
                Write-Log "StdOut: $stdout" "ERROR"
                Write-Log "StdErr: $stderr" "ERROR"
            }
            
            Remove-Item $tempOut -Force
            Remove-Item $tempErr -Force
        }
        catch {
            Write-Log "Execution error for [$($job.Name)]: $($_.Exception.Message)" "CRITICAL"
        }
    }
    
} finally {
    # =====================================================================
    # Security Cleanup & Post-Flight Alerting
    # =====================================================================
    
    
    
    # 2. Reset / Shutdown WSL instances to release locked files and process handles
    if (Get-Command "wsl.exe" -ErrorAction SilentlyContinue) {
        Write-Log "Shutting down WSL instances to release system handles..." "INFO"
        try {
            & wsl.exe --shutdown
        } catch {
            Write-Log "Warning: Failed to execute wsl --shutdown: $($_.Exception.Message)" "WARNING"
        }
    }
    
    Write-Log "Replication runs complete. Proceeding to alert check."

    # 2. PoshMailKit Error Scanning
    if (Test-Path $masterLogPath) {
        Write-Log "Scanning $masterLogPath for errors in the last 5 minutes..."
        
        $timeThreshold = (Get-Date).AddMinutes(-5)
        $errorLines = @()
        $logContents = Get-Content -Path $masterLogPath
        
        foreach ($line in $logContents) {
            if ($line -match "^\[(.*?)\] \[(.*?)\] (.*)") {
                $logDateStr = $matches[1]
                $logLevel   = $matches[2]
                $logDate = [datetime]::ParseExact($logDateStr, "yyyy-MM-dd HH:mm:ss", $null)
                
                if ($logDate -ge $timeThreshold -and ($logLevel -eq "ERROR" -or $logLevel -eq "CRITICAL")) {
                    $errorLines += $line
                }
            }
        }    
        
        if ($errorLines.Count -gt 0) {
            Write-Log "$($errorLines.Count) error(s) found. Attempting to send email alert..."
            
            if (-not [string]::IsNullOrWhiteSpace($appPassword)) {
                $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
                
                $emailBody = "The following errors were detected in the media script run:`n`n" + ($errorLines -join "`n")
                
                try {
                    if (-not (Get-Module -ListAvailable -Name PoshMailKit)) {
                        Write-Log "PoshMailKit module is not installed. Attempting installation..." "WARNING"
                        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
                        }
                        Install-Module -Name PoshMailKit -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
                    } else {
                        Write-Log "PoshMailKit module is installed. Checking for updates..." "INFO"
                        Update-Module -Name PoshMailKit -Force -ErrorAction SilentlyContinue
                    }

                    Import-Module PoshMailKit -ErrorAction Stop
                    Send-MKMailMessage -To $emailTo `
                                       -From $emailFrom `
                                       -Subject "Script Alert: Media Manager Errors Detected" `
                                       -Body $emailBody `
                                       -SmtpServer "smtp.gmail.com" `
                                       -Port 587 `
                                       -UseSsl `
                                       -Credential $credential
                    
                    Write-Log "Error alert email sent successfully."
                } catch {
                    Write-Log "Failed to send email alert: $($_.Exception.Message)" "CRITICAL"
                }
            } else {
                Write-Log "Failed to send email alert: EmailAppPassword is null or empty in configuration." "ERROR"
            }
        } else {
            Write-Log "No errors found in the last 5 minutes."
        }
    } else {
        Write-Log "Master log file not found at $masterLogPath. Cannot scan for errors." "WARNING"
    }
    Write-Log "#################### --------- End of script -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --------- ####################"
}
