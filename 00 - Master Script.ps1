### MASTER SCRIPT ###
## Media Manager Updates and Move with MNamer and WSL ##

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = if ((Split-Path $ScriptDir -Leaf) -eq "Tests") { Split-Path $ScriptDir -Parent } else { $ScriptDir }

$LogFile     = Join-Path $BaseDir "Logs" "$ScriptName.log"
$configFilePath = Join-Path $BaseDir "Variables" "00 - Master.json"
$GlobalFile  = Join-Path $BaseDir "Variables" "_Global.json"
$CredFile    = Join-Path $BaseDir "Credentials" "credential.xml"
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $config = $GlobalConfig
    foreach ($prop in $LocalConfig.psobject.Properties) { $config.$($prop.Name) = $prop.Value }

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
$logFilePath         = $config.logFilePathRsync
$masterLogPath       = $config.logFilePathRsync
$emailTo             = $config.emailTo
$emailFrom           = $config.emailFrom
$appPassword         = $config.appPassword

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

if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
    Write-Log "WSL is not installed. Exiting." "CRITICAL"
    exit
}

if (-not (Test-Path $winCredFilePath)) {
    Write-Log "Credential XML file not found at $winCredFilePath. Exiting." "CRITICAL"
    exit
}

# 1. Decrypt XML and extract plain password into memory
try {
    $secureString = Import-Clixml -Path $winCredFilePath
    # Safely convert the standalone SecureString back to plain text
    $plainPassword = [System.Net.NetworkCredential]::new("", $secureString).Password
} catch {
    Write-Log "Failed to decrypt XML credential file. Ensure script is run by the user who created it." "CRITICAL"
    exit
}

# 2. Create volatile temp file for WSL to read (will be deleted in finally block)
$tempCredFile = New-TemporaryFile
Set-Content -Path $tempCredFile.FullName -Value $plainPassword -NoNewline
$wslTempCredPath = ConvertTo-WslPath $tempCredFile.FullName

# =====================================================================
# Main Execution Try/Catch Block
# =====================================================================
try {
    # ---------------------------------------------------------------------
    # Step 2: Ensure mnamer is Installed & Updated
    # ---------------------------------------------------------------------
    Write-Log "Starting Single-Pass mnamer Run (Default Distro)..."
    Write-Log "Checking mnamer installation and updates..."

    $updateCmd = "cat '$wslTempCredPath' | sudo -S pip3 install --upgrade mnamer --break-system-packages"
    try {
        $updateOutput = wsl.exe -e sh -c $updateCmd 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ($updateOutput -match "Requirement already satisfied") {
                Write-Log "mnamer is already up to date."
            } else {
                Write-Log "mnamer updated successfully."
            }
        } else {
            Write-Log "Failed to update mnamer. Error output: $updateOutput" "WARNING"
        }
    }
    catch {
        Write-Log "Error executing update command: $($_.Exception.Message)" "CRITICAL"
    }

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

    $sshpassCheck = wsl.exe -e bash -c "command -v sshpass"
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
        
        # Uses dynamically generated $wslTempCredPath
        $wslCommand = "sshpass -f '$wslTempCredPath' rsync -avz --itemize-changes --timeout=60 --remove-source-files -e 'ssh -o StrictHostKeyChecking=no' '$($job.WslSource)' '$($job.Dest)'"
        
        try {
            $tempOut = New-TemporaryFile
            $tempErr = New-TemporaryFile
            
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = "cmd.exe"
            $processStartInfo.Arguments = "/c wsl.exe $wslCommand > `"$($tempOut.FullName)`" 2> `"$($tempErr.FullName)`""
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
        
        # Uses dynamically generated $wslTempCredPath
        $wslCommand = "sshpass -f '$wslTempCredPath' ssh -o StrictHostKeyChecking=no ${sourceUser}@${sourceHost} ""$remoteRsyncCmd"""

        try {
            $tempOut = New-TemporaryFile
            $tempErr = New-TemporaryFile
            
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = "cmd.exe"
            $processStartInfo.Arguments = "/c wsl.exe $wslCommand > `"$($tempOut.FullName)`" 2> `"$($tempErr.FullName)`""
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
    
    # 1. Wipe the temporary plain-text credential file immediately
    if (Test-Path $tempCredFile.FullName) {
        Remove-Item -Path $tempCredFile.FullName -Force -ErrorAction SilentlyContinue
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
            
            $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
            
            $emailBody = "The following errors were detected in the media script run:`n`n" + ($errorLines -join "`n")
            
            try {
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
            Write-Log "No errors found in the last 5 minutes."
        }
    } else {
        Write-Log "Master log file not found at $masterLogPath. Cannot scan for errors." "WARNING"
    }
    Write-Log "#################### --------- End of script -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --------- ####################"
}