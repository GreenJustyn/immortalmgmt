### MASTER SCRIPT ###
## Media Manager Updates and Move with MNamer and WSL ##

$ScriptName     = $MyInvocation.MyCommand.Name -replace '\.ps1$',''
$ScriptDir      = $PSScriptRoot
$BaseDir        = Split-Path (Split-Path (Split-Path $ScriptDir -Parent) -Parent) -Parent

# --- Logging & Initial Settings ---
$LogFile        = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$logFilePath    = $LogFile
$masterLogPath  = $LogFile
$CredFile       = Join-Path (Join-Path $BaseDir "Credentials") "svc_immortalmgmt.xml"
$LockFile       = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.lock"

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

function Invoke-WslCommandAsRoot {
    param ([string]$command)
    $winTempFile = [System.IO.Path]::GetTempFileName() + ".sh"
    $lfCmd = $command.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText($winTempFile, $lfCmd)
    $wslTempPath = ConvertTo-WslPath $winTempFile
    $output = wsl.exe -u root sh $wslTempPath 2>&1
    $exitCode = $LASTEXITCODE
    Remove-Item $winTempFile -Force -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = $exitCode
    return $output
}

# =====================================================================
# Main Execution Framework
# =====================================================================
Rotate-Log
$scriptStartTime = Get-Date
Write-Log "#################### --------- Start of script -- $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss')) --------- ####################"

$LockAcquired = $false
$scriptErrorCount = 0

try {
    # ---------------------------------------------------------------------
    # Step 0: Atomic OS Mutex Lock Acquisition
    # ---------------------------------------------------------------------
    try {
        $LockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $LockAcquired = $true
        $Writer = New-Object System.IO.StreamWriter($LockStream)
        $Writer.WriteLine($PID)
        $Writer.Flush()
    } catch {
        # Check if Stale Lock
        $StaleLock = $false
        if (Test-Path $LockFile) {
            try {
                $LockContent = (Get-Content $LockFile -Raw).Trim()
                if ($LockContent -match '(\d+)') {
                    $OwnerPid = [int]$matches[1]
                    $OwnerProcess = Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue
                    if (-not $OwnerProcess) {
                        $StaleLock = $true
                        Write-Log "Stale lock detected: PID $OwnerPid is no longer running." "WARNING"
                    } elseif ($OwnerProcess.ProcessName -notmatch "powershell|pwsh") {
                        $StaleLock = $true
                        Write-Log "Stale lock detected: PID $OwnerPid is running but is not PowerShell ($($OwnerProcess.ProcessName))." "WARNING"
                    }
                } else {
                    $StaleLock = $true
                    Write-Log "Stale lock detected: Lock file is empty or corrupted." "WARNING"
                }
            } catch {
                # Fallback to time check if PID parsing fails
                $LockTime = (Get-Item $LockFile).LastWriteTime
                if ($LockTime -lt (Get-Date).AddHours(-4)) {
                    $StaleLock = $true
                    Write-Log "Stale lock detected by timestamp ($LockTime is older than 4 hours)." "WARNING"
                }
            }

            if ($StaleLock) {
                Write-Log "Overriding and removing stale lock file..." "WARNING"
                Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
                try {
                    $LockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    $LockAcquired = $true
                    $Writer = New-Object System.IO.StreamWriter($LockStream)
                    $Writer.WriteLine($PID)
                    $Writer.Flush()
                    Write-Log "Stale lock successfully overridden." "INFO"
                } catch {
                    throw "Failed to acquire lock after removing stale file: $($_.Exception.Message)"
                }
            } else {
                Write-Log "Another instance of $ScriptName is currently running (Lock created at $((Get-Item $LockFile).LastWriteTime)). Exiting gracefully to prevent schedule clash." "INFO"
                $global:LASTEXITCODE = 0
                return
            }
        } else {
            throw "Failed to acquire OS lock: $($_.Exception.Message)"
        }
    }

    # ---------------------------------------------------------------------
    # Step 1: Configuration & Just-In-Time Credential Extraction
    # ---------------------------------------------------------------------
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

    # --- Settings ---
    $emailTo             = $config.emailTo
    $emailFrom           = $config.emailFrom
    $appPassword         = $config.EmailAppPassword

    # Validate that WSL is enabled
    if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
        Write-Log "WSL is not enabled on this system. Enabling WSL and installing Ubuntu..." "WARNING"
        try {
            $process = Start-Process -FilePath "wsl.exe" -ArgumentList "--install", "--no-launch", "-d", "Ubuntu" -NoNewWindow -PassThru -Wait
            if ($process.ExitCode -ne 0) {
                dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
                dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
                throw "WSL feature enabled via DISM, but wsl.exe was not found. A system reboot is required."
            }
            Write-Log "WSL has been enabled and Ubuntu installation triggered. A reboot may be required." "INFO"
        } catch {
            throw "Failed to enable WSL automatically: $($_.Exception.Message)"
        }
    }

    # Validate default Linux distro
    $null = & wsl.exe true 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "WSL is enabled, but no default Linux distribution (Ubuntu) is installed. Triggering installation..." "WARNING"
        try {
            $process = Start-Process -FilePath "wsl.exe" -ArgumentList "--install", "-d", "Ubuntu", "--no-launch" -NoNewWindow -PassThru -Wait
            $null = & wsl.exe true 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "Ubuntu installation completed but WSL is still not executing commands. A reboot is likely required."
            }
            Write-Log "Ubuntu Linux distribution has been successfully installed." "INFO"
        } catch {
            throw "Failed to install Ubuntu distribution: $($_.Exception.Message)"
        }
    }

    # Load/Migrate Credentials
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
                
                $KeyBytes = New-Object Byte[] 32
                [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
                $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
                if (-not (Test-Path $CredFolder)) { New-Item -Path $CredFolder -ItemType Directory -Force | Out-Null }
                $KeyBase64 | Out-File -FilePath $stuffKeyFile -Encoding utf8 -Force
                
                $EncryptedText = ConvertFrom-SecureString $secureString -Key $KeyBytes
                $EncryptedText | Out-File -FilePath $stuffEncFile -Encoding utf8 -Force
                
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
                Write-Log "Successfully migrated legacy DPAPI stuff.xml to symmetric key encryption." "INFO"
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
            
            $KeyBytes = New-Object Byte[] 32
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
            $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
            if (-not (Test-Path $CredFolder)) { New-Item -Path $CredFolder -ItemType Directory -Force | Out-Null }
            $KeyBase64 | Out-File -FilePath $stuffKeyFile -Encoding utf8 -Force
            
            $EncryptedText = ConvertFrom-SecureString $PasswordInput -Key $KeyBytes
            $EncryptedText | Out-File -FilePath $stuffEncFile -Encoding utf8 -Force
            
            $plainPassword = [System.Net.NetworkCredential]::new("", $PasswordInput).Password
            $DecryptionSuccess = $true
            
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
            throw "Failed to decrypt SSH credentials and session is non-interactive. Ensure $stuffKeyFile and $stuffEncFile exist."
        }
    }

    # Step 1.5: Validate and Provision WSL Prerequisites
    Write-Log "Verifying WSL prerequisite packages (pipx, sshpass, mnamer)..." "INFO"

    $null = Invoke-WslCommandAsRoot "command -v pipx"
    $wslPipxInstalled = ($LASTEXITCODE -eq 0)

    $null = Invoke-WslCommandAsRoot "command -v sshpass"
    $wslSshpassInstalled = ($LASTEXITCODE -eq 0)

    $null = Invoke-WslCommandAsRoot "command -v mnamer"
    $wslMnamerInstalled = ($LASTEXITCODE -eq 0)

    if (-not $wslPipxInstalled -or -not $wslSshpassInstalled -or -not $wslMnamerInstalled) {
        Write-Log "WSL is missing one or more required prerequisites. Initiating provisioning..." "WARNING"
        try {
            if (-not $wslPipxInstalled -or -not $wslSshpassInstalled) {
                Write-Log "Installing system packages (pipx, sshpass) via apt-get..." "INFO"
                $aptOutput = Invoke-WslCommandAsRoot "apt-get update && apt-get install -y pipx sshpass python3"
                if ($LASTEXITCODE -ne 0) { throw "Apt installation failed. Output: $aptOutput" }
                Write-Log "System packages successfully installed." "INFO"
            }

            Write-Log "Installing/Upgrading mnamer via pipx..." "INFO"
            $pipxOutput = Invoke-WslCommandAsRoot "(pipx install mnamer || pipx upgrade mnamer) && ln -sf /root/.local/bin/mnamer /usr/local/bin/mnamer"
            if ($LASTEXITCODE -ne 0) { throw "Pipx installation of mnamer failed. Output: $pipxOutput" }
            Write-Log "mnamer successfully provisioned." "INFO"
        } catch {
            throw "Failed to provision WSL prerequisites: $($_.Exception.Message)"
        }
    } else {
        Write-Log "All WSL prerequisites (pipx, sshpass, mnamer) are verified." "INFO"
    }

    # ---------------------------------------------------------------------
    # Step 2: Starting Single-Pass mnamer Run
    # ---------------------------------------------------------------------
    Write-Log "Starting Single-Pass mnamer Run (Default Distro)..."
    $wslSource = ConvertTo-WslPath $winSourcePath
    $wslTv     = ConvertTo-WslPath $winTvPath
    $wslMovies = ConvertTo-WslPath $winMoviesPath

    $epFormat = "{series}/Season {season:02}/{series} S{season:02}E{episode:02} - {title} ({date}).{extension}"
    Write-Log "Processing source: $wslSource"

    $mnamerCommand = "mnamer --no-overwrite --episode-directory '$wslTv' --episode-format '$epFormat' --movie-directory '$wslMovies' -vrb '$wslSource'"

    try {
        $output = Invoke-WslCommandAsRoot $mnamerCommand
        if ($LASTEXITCODE -eq 0) {
            $meaningfulOutput = $output | Where-Object { $_ -match "Processing|Moving|Renaming" -and $_ -notmatch "0 files processed" }
            if ($meaningfulOutput) {
                Write-Log "Activity Detected:`n$($meaningfulOutput -join "`n")"
            } else {
                Write-Log "No new media processed by mnamer."
            }
        } else {
            Write-Log "mnamer error code: $LASTEXITCODE" "WARNING"
            Write-Log "Output: $($output -join "`n")" "WARNING"
        }
    }
    catch {
        Write-Log "WSL mnamer Execution Error: $($_.Exception.Message)" "CRITICAL"
        $scriptErrorCount++
    }

    # ---------------------------------------------------------------------
    # Step 3: Replication Script for Plex (Verify-Then-Sync-Then-Delete)
    # ---------------------------------------------------------------------
    Write-Log "Starting Local to Plex Transfer (Default Distro)..."

    $syncJobsLocalToPlex = @(
        @{ Name = "Movies"; WinSource = $winMoviesPath; WslSource = (ConvertTo-WslPath $winMoviesPath) + "/"; Dest = "${remoteUser}@${remoteHost}:${remoteMoviesDest}" },
        @{ Name = "TV"; WinSource = $winTvPath; WslSource = (ConvertTo-WslPath $winTvPath) + "/"; Dest = "${remoteUser}@${remoteHost}:${remoteTvDest}" }
    )

    foreach ($job in $syncJobsLocalToPlex) {
        if (-not (Test-Path $job.WinSource)) {
            Write-Log "Source path $($job.WinSource) does not exist. Skipping." "WARNING"
            continue
        }
        
        # 1. Snapshot file list BEFORE transfer
        $filesToTransfer = Get-ChildItem -Path $job.WinSource -File -Recurse
        if ($filesToTransfer.Count -eq 0) {
            Write-Log "No files found in [$($job.Name)]. Skipping."
            continue
        }

        Write-Log "Processing [$($job.Name)] ($($filesToTransfer.Count) files found)..."
        
        # 2. Transfer WITHOUT deleting, and Sync Remote Cache immediately
        $rsyncFlags = "-avz --itemize-changes --timeout=60"
        $sshOptions = "-o StrictHostKeyChecking=no -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=30"
        
        $wslCommand = "sshpass -e rsync $rsyncFlags -e 'ssh $sshOptions' '$($job.WslSource)' '$($job.Dest)' && sshpass -e ssh $sshOptions ${remoteUser}@${remoteHost} sync"
        
        try {
            $tempOut = New-TemporaryFile
            $tempErr = New-TemporaryFile
            
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = "cmd.exe"
            $processStartInfo.Arguments = "/c wsl.exe -u root $wslCommand > `"$($tempOut.FullName)`" 2> `"$($tempErr.FullName)`""
            $processStartInfo.UseShellExecute = $false
            $processStartInfo.CreateNoWindow = $true
            $processStartInfo.EnvironmentVariables["SSHPASS"] = $plainPassword
            $processStartInfo.EnvironmentVariables["WSLENV"]  = "SSHPASS/u"

            $process = [System.Diagnostics.Process]::Start($processStartInfo)
            $process.WaitForExit()
            
            $stdout = Get-Content $tempOut.FullName -Raw
            $stderr = Get-Content $tempErr.FullName -Raw

            if ($process.ExitCode -eq 0) {
                $changes = $stdout -split "`n" | Where-Object { $_ -notmatch "sending incremental file list|sent .* bytes|total size is" -and $_.Trim() -ne "" }
                if ($changes) {
                    Write-Log "[$($job.Name)] Transfer & Sync Success:`n$($changes -join "`n")"
                }
                
                # 3. Safe Cleanup of verified files only
                Write-Log "[$($job.Name)] proceeding to safe source file cleanup..."
                foreach ($file in $filesToTransfer) {
                    Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
                }
                
                Write-Log "[$($job.Name)] cleaning up empty folders..."
                Get-ChildItem -Path $job.WinSource -Directory -Recurse | 
                    Where-Object { (Get-ChildItem -Path $_.FullName -File -Recurse).Count -eq 0 } | 
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    
            } else {
                Write-Log "rsync/sync error for [$($job.Name)]. Exit code: $($process.ExitCode)" "ERROR"
                Write-Log "StdOut: $stdout" "ERROR"
                Write-Log "StdErr: $stderr" "ERROR"
                $scriptErrorCount++
            }
            
            Remove-Item $tempOut -Force
            Remove-Item $tempErr -Force
        }
        catch {
            Write-Log "Execution error for [$($job.Name)]: $($_.Exception.Message)" "CRITICAL"
            $scriptErrorCount++
        }
    }

    # ---------------------------------------------------------------------
    # Step 4: Replication for JellyFin Server
    # ---------------------------------------------------------------------
    Write-Log "Starting Plex -> Jellyfin Mirror Job (Default Distro)..."

    $syncJobsPlexToJellyfin = @(
        @{ Name = "Movies"; SourcePath = $sourceMoviesPath; DestPath = "${destUser}@${destHost}:${destMoviesPath}" },
        @{ Name = "TV"; SourcePath = $sourceTvPath; DestPath = "${destUser}@${destHost}:${destTvPath}" }
    )

    foreach ($job in $syncJobsPlexToJellyfin) {
        Write-Log "Mirroring [$($job.Name)] from Plex to Jellyfin..."
        
        $remoteRsyncFlags = "-avz --delete --itemize-changes --timeout=60"
        $remoteSshOptions = "-o StrictHostKeyChecking=no -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=30"
        
        $plexToJellyRsyncCmd = "rsync $remoteRsyncFlags -e 'ssh $remoteSshOptions' '$($job.SourcePath)' '$($job.DestPath)'"
        $jellySyncCmd        = "ssh $remoteSshOptions ${destUser}@${destHost} sync"
        
        # Chain Rsync AND Sync remotely on the target destination
        $remoteChainedCmd = "$plexToJellyRsyncCmd && $jellySyncCmd"
        
        $wslCommand = "sshpass -e ssh $remoteSshOptions ${sourceUser}@${sourceHost} ""$remoteChainedCmd"""

        try {
            $tempOut = New-TemporaryFile
            $tempErr = New-TemporaryFile
            
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = "cmd.exe"
            $processStartInfo.Arguments = "/c wsl.exe -u root $wslCommand > `"$($tempOut.FullName)`" 2> `"$($tempErr.FullName)`""
            $processStartInfo.UseShellExecute = $false
            $processStartInfo.CreateNoWindow = $true
            $processStartInfo.EnvironmentVariables["SSHPASS"] = $plainPassword
            $processStartInfo.EnvironmentVariables["WSLENV"]  = "SSHPASS/u"

            $process = [System.Diagnostics.Process]::Start($processStartInfo)
            $process.WaitForExit()

            $stdout = Get-Content $tempOut.FullName -Raw
            $stderr = Get-Content $tempErr.FullName -Raw

            if ($process.ExitCode -eq 0) {
                $changes = $stdout -split "`n" | Where-Object { $_ -notmatch "sending incremental file list|sent .* bytes|total size is" -and $_.Trim() -ne "" }
                if ($changes) {
                    Write-Log "[$($job.Name)] Mirror & Sync Processed. Itemized Changes:`n$($changes -join "`n")"
                } else {
                    Write-Log "[$($job.Name)] Mirror & Sync Complete. Folders are perfectly identical."
                }
            } else {
                Write-Log "Mirror failed for [$($job.Name)]. Exit code: $($process.ExitCode)" "ERROR"
                Write-Log "StdOut: $stdout" "ERROR"
                Write-Log "StdErr: $stderr" "ERROR"
                $scriptErrorCount++
            }
            
            Remove-Item $tempOut -Force
            Remove-Item $tempErr -Force
        }
        catch {
            Write-Log "Execution error for [$($job.Name)]: $($_.Exception.Message)" "CRITICAL"
            $scriptErrorCount++
        }
    }
    
} catch {
    Write-Log "Terminating exception during script execution: $($_.Exception.Message)" "CRITICAL"
    $scriptErrorCount++
} finally {
    # =====================================================================
    # Security Cleanup & Post-Flight Alerting
    # =====================================================================
    
    # 1. Reset / Shutdown WSL instances to release locked files and process handles
    if (Get-Command "wsl.exe" -ErrorAction SilentlyContinue) {
        Write-Log "Shutting down WSL instances to release system handles..." "INFO"
        try {
            & wsl.exe --shutdown
        } catch {
            Write-Log "Warning: Failed to execute wsl --shutdown: $($_.Exception.Message)" "WARNING"
        }
    }
    
    # 2. Release OS Mutex Lock File
    if ($LockAcquired) {
        try {
            $Writer.Close()
            $LockStream.Close()
            Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
            Write-Log "OS Mutex Lock successfully released." "INFO"
        } catch {
            Write-Log "Warning: Failed to safely release Lock File: $($_.Exception.Message)" "WARNING"
        }
    }

    Write-Log "Replication runs complete. Proceeding to alert check."

    # 3. PoshMailKit Error Scanning (Scanning since $scriptStartTime)
    if (Test-Path $masterLogPath) {
        Write-Log "Scanning $masterLogPath for errors since script start ($($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss')))..."
        
        $errorLines = @()
        $logContents = Get-Content -Path $masterLogPath
        
        foreach ($line in $logContents) {
            if ($line -match "^\[(.*?)\] \[(.*?)\] (.*)") {
                $logDateStr = $matches[1]
                $logLevel   = $matches[2]
                try {
                    $logDate = [datetime]::ParseExact($logDateStr, "yyyy-MM-dd HH:mm:ss", $null)
                    if ($logDate -ge $scriptStartTime -and ($logLevel -eq "ERROR" -or $logLevel -eq "CRITICAL")) {
                        $errorLines += $line
                    }
                } catch {}
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
            Write-Log "No errors found during this run."
        }
    } else {
        Write-Log "Master log file not found at $masterLogPath. Cannot scan for errors." "WARNING"
    }

    Write-Log "#################### --------- End of script -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --------- ####################"

    # 4. Propagate True Exit Code safely to Master Script without terminating it
    if ($scriptErrorCount -gt 0) {
        $global:LASTEXITCODE = 1
        return
    } else {
        $global:LASTEXITCODE = 0
        return
    }
}
