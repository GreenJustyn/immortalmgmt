### MASTER SCRIPT ###
## Media Manager Updates and Move with MNamer and WSL ##

# Read the JSON file content and convert it to a PowerShell object
# Define the path to your JSON config file (Update this to your actual file path)
$configFilePath = "C:\Scripts\Variables\00 - Master.json"
# Import and convert the JSON data
$config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json

# --- Local Windows Paths ---
$winSourcePath       = $config.winSourcePath 
$winTvPath           = $config.winTvPath
$winMoviesPath       = $config.winMoviesPath
$winCredFilePath     = $config.winCredFilePath

# --- Remote Server Config ---
$remoteUser          = $config.remoteUser
$remoteHost          = $config.remoteHost
$remoteMoviesDest    = $config.remoteMoviesDest
$remoteTvDest        = $config.remoteTvDest

# --- WSL Credentials File ---
$wslCredFilePath     = $config.wslCredFilePath

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
# Note: Because your original list had three different log paths for three 
# different scripts, you can pull the specific one you need for this script.
# For example, if this is the rsync script, you would use:
$logFilePath         = $config.logFilePathRsync
$masterLogPath       = $config.logFilePathRsync
$emailTo             = $config.emailTo
$emailFrom           = $config.emailFrom
$appPassword         = $config.appPassword

#### ALL Variables ####
# =====================================================================
# Helper Functions
# =====================================================================
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
## Start of Script ##
Write-Log "#################### --------- Start of script -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --------- ####################"
## -------------- ##
# =====================================================================
# Step 1: Pre-Flight Check
# =====================================================================
Write-Log "Starting Single-Pass mnamer Run (Default Distro)..."

if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
    Write-Log "WSL is not installed. Exiting." "CRITICAL"
    exit
}

# =====================================================================
# Step 2: Ensure mnamer is Installed & Updated
# =====================================================================
Write-Log "Checking mnamer installation and updates..."

$wslCredPath = ConvertTo-WslPath $winCredFilePath

if (-not (Test-Path $winCredFilePath)) {
    Write-Log "Credential file not found at $winCredFilePath. Skipping update check." "WARNING"
} else {
    # Update Command: Uses default distro automatically
    $updateCmd = "cat '$wslCredPath' | sudo -S pip3 install --upgrade mnamer --break-system-packages"

    try {
        # Removed '-d $targetDistroName'. Now runs on the system default.
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
}

# =====================================================================
# Step 3: Main Processing (Single Pass)
# =====================================================================
$wslSource = ConvertTo-WslPath $winSourcePath
$wslTv     = ConvertTo-WslPath $winTvPath
$wslMovies = ConvertTo-WslPath $winMoviesPath

# Define the Episode Format String
$epFormat = "{series}/Season {season:02}/{series} S{season:02}E{episode:02} - {title} ({date}).{extension}"

Write-Log "Processing source: $wslSource"

# Construct command
$mnamerCommand = "mnamer --no-overwrite --episode-directory '$wslTv' --episode-format '$epFormat' --movie-directory '$wslMovies' -vrb '$wslSource'"

try {
    # Removed '-d $targetDistroName'. Now runs on the system default.
    $output = wsl.exe -e sh -c $mnamerCommand 2>&1

    if ($LASTEXITCODE -eq 0) {
        # Filter output to reduce log spam (only show "Processing", "Moving", or "Renaming")
        $meaningfulOutput = $output | Where-Object { $_ -match "Processing|Moving|Renaming" -and $_ -notmatch "0 files processed" }
        
        if ($meaningfulOutput) {
            Write-Log "Activity Detected:`n$($meaningfulOutput -join "`n")"
        } else {
            Write-Log "No new media processed."
        }
    } else {
        # mnamer returns non-zero if it crashes or has a critical error
        Write-Log "mnamer error code: $LASTEXITCODE" "WARNING"
        Write-Log "Output: $($output -join "`n")" "WARNING"
    }
}
catch {
    Write-Log "WSL Execution Error: $($_.Exception.Message)" "CRITICAL"
}

Write-Log "Script complete. Exiting."

### Replication Script for Plex ###
# =====================================================================
# Helper Functions
# =====================================================================
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
# Pre-Flight Checks
# =====================================================================
Write-Log "Starting Single-Pass Replication Run (Default Distro)..."

# 1. Check WSL Executable
if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
    Write-Log "WSL is not installed or wsl.exe is not in the system PATH. Exiting." "CRITICAL"
    exit
}

# 2. Check if sshpass is installed inside the default WSL distro
# We use 'wsl.exe -e' to run in the default instance
$sshpassCheck = wsl.exe -e bash -c "command -v sshpass"
if (-not $sshpassCheck) {
    Write-Log "sshpass is NOT installed in your default WSL distro. Please install it (sudo apt install sshpass)." "CRITICAL"
    exit
}

# =====================================================================
# Setup Transfer Jobs
# =====================================================================
$syncJobs = @(
    @{ 
        Name       = "Movies"
        WinSource  = $winMoviesPath
        WslSource  = (ConvertTo-WslPath $winMoviesPath) + "/"
        Dest       = "${remoteUser}@${remoteHost}:${remoteMoviesDest}" 
    },
    @{ 
        Name       = "TV"
        WinSource  = $winTvPath
        WslSource  = (ConvertTo-WslPath $winTvPath) + "/"
        Dest       = "${remoteUser}@${remoteHost}:${remoteTvDest}" 
    }
)

# =====================================================================
# Main Execution (Single Pass)
# =====================================================================

foreach ($job in $syncJobs) {
    # Check if folder is empty before invoking WSL (Saves resources)
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
    
    # COMMAND CONSTRUCTION:
    # Uses sshpass -f (file) | rsync --remove-source-files (move) | -e ssh
    $wslCommand = "sshpass -f $wslCredFilePath rsync -avz --remove-source-files -e ssh '$($job.WslSource)' '$($job.Dest)'"
    
    try {
        # Execute via cmd.exe invocation
        # NOTE: Removed '-d $targetDistroName'. Runs on system default.
        $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processStartInfo.FileName = "cmd.exe"
        $processStartInfo.Arguments = "/c wsl.exe $wslCommand"
        $processStartInfo.RedirectStandardOutput = $true
        $processStartInfo.RedirectStandardError = $true
        $processStartInfo.UseShellExecute = $false
        $processStartInfo.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::Start($processStartInfo)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -eq 0) {
            # Log the rsync output
            $changes = $stdout -split "`n" | Where-Object { $_ -notmatch "sending incremental file list|sent .* bytes|total size is" -and $_.Trim() -ne "" }
            if ($changes) {
                Write-Log "[$($job.Name)] Transfer Success:`n$($changes -join "`n")"
            }
            
            # --- LOCAL CLEANUP ---
            # Remove empty folders left behind by rsync
            Write-Log "[$($job.Name)] cleaning up empty folders..."
            Get-ChildItem -Path $job.WinSource -Directory -Recurse | 
                Where-Object { (Get-ChildItem -Path $_.FullName -File -Recurse).Count -eq 0 } | 
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                
        } else {
            Write-Log "rsync error for [$($job.Name)]. Exit code: $($process.ExitCode)" "ERROR"
            Write-Log "StdOut: $stdout" "ERROR"
            Write-Log "StdErr: $stderr" "ERROR"
        }
    }
    catch {
        Write-Log "Execution error for [$($job.Name)]: $($_.Exception.Message)" "CRITICAL"
    }
}

Write-Log "Replication run complete. Exiting."

### Replication for JellyFin Server. ###
# =====================================================================
# Helper Functions
# =====================================================================
function Write-Log {
    param ([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    $logDir = Split-Path $logFilePath
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $logFilePath -Value $logEntry
}

# =====================================================================
# Pre-Flight Checks
# =====================================================================
Write-Log "Starting Plex -> Jellyfin Mirror Job (Default Distro)..."

if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
    Write-Log "WSL is not installed. Exiting." "CRITICAL"
    exit
}

# Check for sshpass locally in the default distro
# We run 'wsl -e' to force execution in the default instance
$sshpassCheck = wsl.exe -e bash -c "command -v sshpass"
if (-not $sshpassCheck) {
    Write-Log "sshpass is NOT installed in your default WSL distro. Please install it (sudo apt install sshpass)." "CRITICAL"
    exit
}

# =====================================================================
# Setup Mirror Jobs
# =====================================================================
$syncJobs = @(
    @{ 
        Name       = "Movies"
        SourcePath = $sourceMoviesPath
        DestPath   = "${destUser}@${destHost}:${destMoviesPath}" 
    },
    @{ 
        Name       = "TV"
        SourcePath = $sourceTvPath
        DestPath   = "${destUser}@${destHost}:${destTvPath}" 
    }
)

# =====================================================================
# Main Execution (Remote Controller Mode)
# =====================================================================
foreach ($job in $syncJobs) {
    Write-Log "Mirroring [$($job.Name)] from Plex to Jellyfin..."
    
    # -------------------------------------------------------------------------
    # RSYNC MIRROR COMMAND
    # -a: Archive (recurse, preserve permissions/times/groups)
    # -v: Verbose (for logging)
    # -z: Compress (faster over network)
    # --delete: MIRROR MODE (Deletes files on Jellyfin if they are gone from Plex)
    # -------------------------------------------------------------------------
    $remoteRsyncCmd = "rsync -avz --delete '$($job.SourcePath)' '$($job.DestPath)'"
    
    # Connect to Plex via sshpass and execute the rsync command remotely
    # Note: We now use 'wsl.exe' directly without '-d DistroName'
    $wslCommand = "sshpass -f $wslCredFilePath ssh -o StrictHostKeyChecking=no ${sourceUser}@${sourceHost} ""$remoteRsyncCmd"""

    try {
        $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processStartInfo.FileName = "cmd.exe"
        # /c tells cmd to run the following string and then terminate
        $processStartInfo.Arguments = "/c wsl.exe $wslCommand"
        $processStartInfo.RedirectStandardOutput = $true
        $processStartInfo.RedirectStandardError = $true
        $processStartInfo.UseShellExecute = $false
        $processStartInfo.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::Start($processStartInfo)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -eq 0) {
            # Log changes (filtering out progress spam)
            $changes = $stdout -split "`n" | Where-Object { $_ -notmatch "sending incremental file list|sent .* bytes|total size is" -and $_.Trim() -ne "" }
            if ($changes) {
                Write-Log "[$($job.Name)] Mirror Success. Changes:`n$($changes -join "`n")"
            } else {
                Write-Log "[$($job.Name)] Mirror Complete. Folders are identical."
            }
        } else {
            Write-Log "Mirror failed for [$($job.Name)]. Exit code: $($process.ExitCode)" "ERROR"
            Write-Log "StdOut: $stdout" "ERROR"
            Write-Log "StdErr: $stderr" "ERROR"
        }
    }
    catch {
        Write-Log "Execution error for [$($job.Name)]: $($_.Exception.Message)" "CRITICAL"
    }
}

Write-Log "Replication run complete. Exiting."

## Post Script Alerting and Notification ##

# =====================================================================
# Post-Flight: Log Scanning & Email Alerting (PoshMailKit)
# =====================================================================

if (Test-Path $masterLogPath) {
    Write-Log "Scanning $masterLogPath for errors in the last 5 minutes..."
    
    $timeThreshold = (Get-Date).AddMinutes(-5)
    $errorLines = @()
    
    # Read the log file
    $logContents = Get-Content -Path $masterLogPath
    
    foreach ($line in $logContents) {
        # Match the log pattern: [yyyy-MM-dd HH:mm:ss] [LEVEL] Message
        if ($line -match "^\[(.*?)\] \[(.*?)\] (.*)") {
            $logDateStr = $matches[1]
            $logLevel   = $matches[2]
            
            # Safely parse the date using the exact format from your Write-Log function
            $logDate = [datetime]::ParseExact($logDateStr, "yyyy-MM-dd HH:mm:ss", $null)
            
            # Check if within the last 5 mins AND if the level is ERROR or CRITICAL
            if ($logDate -ge $timeThreshold -and ($logLevel -eq "ERROR" -or $logLevel -eq "CRITICAL")) {
                $errorLines += $line
            }
        }
    }    
    if ($errorLines.Count -gt 0) {
        Write-Log "$($errorLines.Count) error(s) found. Attempting to send email alert..."
        
        # Prepare credentials for PoshMailKit
        $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
        
        $emailBody = "The following errors were detected in the media script run:`n`n" + ($errorLines -join "`n")
        
        try {
            # Ensure PoshMailKit is loaded
            Import-Module PoshMailKit -ErrorAction Stop
            
            # Send the email via Gmail's SMTP servers
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
## End of Script ##