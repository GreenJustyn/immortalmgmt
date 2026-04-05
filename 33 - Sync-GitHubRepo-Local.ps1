$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.ps1$',''
$LogFile     = "C:\Scripts\Logs\$ScriptName.log"
$ConfigFile  = "C:\Scripts\Variables\$ScriptName.json"
$CredFile    = "C:\Scripts\Credentials\git-credential.xml"
$Environment = "#{ENVIRONMENT}#"

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
    
    # Optional console output for manual runs
    if ($Level -eq "ERROR" -or $Level -eq "CRITICAL") { Write-Host "[$Level] $Message" -ForegroundColor Red }
    elseif ($Level -eq "WARNING") { Write-Host "[$Level] $Message" -ForegroundColor Yellow }
    else { Write-Host "[$Level] $Message" -ForegroundColor Gray }

    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

# 2. Main Execution Block wrapped in Try/Catch
try {
    Write-Log "Initializing script execution." -Start

    # Config Check
    if (-not (Test-Path $ConfigFile)) { 
        throw "FATAL: Config missing at $ConfigFile." 
    }
    $Config = Get-Content -Path $ConfigFile | ConvertFrom-Json

    # Operational Logic
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "FATAL: Git is not installed on the system."
    }

    # Load GitHub PAT (Uses the single-value SecureString method)
    if (-not (Test-Path $CredFile)) {
        throw "FATAL: GitHub credential file missing at $CredFile."
    }
    $SecureToken = Import-Clixml -Path $CredFile
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
    $Token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

    $RepoPath = $Config.LocalRepoPath
    $Branch = $Config.Branch
    $RepoUrl = $Config.RepoUrl

    # Construct authenticated URL
    $AuthUrl = $RepoUrl -replace "https://", "https://$Token@"

    # Ensure staging parent directory exists
    $StagingParent = Split-Path $RepoPath
    if (-not (Test-Path $StagingParent)) {
        New-Item -ItemType Directory -Path $StagingParent -Force | Out-Null
    }

    if (-not (Test-Path "$RepoPath\.git")) {
        Write-Log "Local repository not found in staging folder. Cloning..." "INFO"
        # Disable credential helper to avoid prompts
        git -c credential.helper='' clone -b $Branch $AuthUrl $RepoPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone repository."
        }
    }

    Set-Location -Path $RepoPath

    # Fetch to check for updates using the authenticated URL
    Write-Log "Fetching from remote..." "INFO"
    $FetchOutput = git -c credential.helper='' fetch $AuthUrl $Branch 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch from remote. Output: $($FetchOutput -join ' ')"
    }

    $LOCAL = (git rev-parse HEAD).Trim()
    $REMOTE = (git rev-parse FETCH_HEAD).Trim()

    $Updated = $false

    if ($LOCAL -eq $REMOTE) {
        Write-Log "Local files are up to date with remote. No copy required." "INFO"
    } else {
        # Using reset --hard instead of pull to guarantee the staging folder forces a match with remote, avoiding merge conflict hangs
        Write-Log "Remote repo is more up to date. Syncing staging folder..." "INFO"
        $GitOutput = git -c credential.helper='' reset --hard FETCH_HEAD 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Git reset failed. Output: $($GitOutput -join ' ')"
        }
        Write-Log "Git Output: $($GitOutput -join ' ')" "INFO"
        $Updated = $true
    }

    if ($Updated) {
        # Validate files (Ensures the sync didn't pull an empty repo before copying)
        if (-not (Test-Path "$RepoPath\000 - Bootstrap Script.ps1")) {
            throw "Validation failed: Critical bootstrap script missing after sync."
        }
        Write-Log "Staged files validated successfully." "INFO"

        # Define Destinations
        $DestScripts     = "C:\Scripts"
        $DestVariables   = "C:\Scripts\Variables"
        $DestTests       = "C:\Scripts\Tests"
        $DestCredentials = "C:\Scripts\Credentials"

        # Ensure destination directories exist
        if (-not (Test-Path $DestScripts)) { New-Item -ItemType Directory -Path $DestScripts -Force | Out-Null }
        if (-not (Test-Path $DestVariables)) { New-Item -ItemType Directory -Path $DestVariables -Force | Out-Null }
        if (-not (Test-Path $DestTests)) { New-Item -ItemType Directory -Path $DestTests -Force | Out-Null }
        if (-not (Test-Path $DestCredentials)) { New-Item -ItemType Directory -Path $DestCredentials -Force | Out-Null }

        # =====================================================================
        # File Replication (Robocopy)
        # /XO skips copying older files (replaces only newer/updated).
        # /E copies subdirectories (needed for tests/variables).
        # Target files NOT in the source are left completely intact.
        # =====================================================================

        # 1. Copy PS scripts from root staging directory to C:\Scripts
        Write-Log "Deploying updated Root Scripts..." "INFO"
        $RoboScripts = robocopy $RepoPath $DestScripts *.ps1 /XO /NDL /NFL /NJH /NJS
        if ($LASTEXITCODE -ge 8) { Write-Log "Robocopy for scripts failed (Code: $LASTEXITCODE)" "ERROR" } 

        # 2. Copy variables
        Write-Log "Deploying updated Variables..." "INFO"
        $RoboVars = robocopy "$RepoPath\Variables" $DestVariables *.* /E /XO /NDL /NFL /NJH /NJS
        if ($LASTEXITCODE -ge 8) { Write-Log "Robocopy for variables failed (Code: $LASTEXITCODE)" "ERROR" } 

        # 3. Copy tests
        Write-Log "Deploying updated Tests..." "INFO"
        $RoboTests = robocopy "$RepoPath\Tests" $DestTests *.* /E /XO /NDL /NFL /NJH /NJS
        if ($LASTEXITCODE -ge 8) { Write-Log "Robocopy for tests failed (Code: $LASTEXITCODE)" "ERROR" } 

        # 4. Copy credentials
        Write-Log "Deploying updated Credentials..." "INFO"
        $RoboCreds = robocopy "$RepoPath\Credentials" $DestCredentials *.* /E /XO /NDL /NFL /NJH /NJS
        if ($LASTEXITCODE -ge 8) { Write-Log "Robocopy for credentials failed (Code: $LASTEXITCODE)" "ERROR" } 

        Write-Log "Deployment routines completed." "INFO"

        # Success Notification
        if ($Config.EmailAppPassword -and $Config.EmailFrom -and $Config.EmailTo) {
            Write-Log "Sending success notification..." "INFO"
            
            $secPassword = ConvertTo-SecureString $Config.EmailAppPassword -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential ($Config.EmailFrom, $secPassword)
            
            $emailBody = "Sync completed successfully. The Git repository was updated and newer files were deployed."
            
            try {
                Import-Module PoshMailKit -ErrorAction Stop
                Send-MKMailMessage -To $Config.EmailTo `
                                   -From $Config.EmailFrom `
                                   -Subject "Script Success: $ScriptName Completed" `
                                   -Body $emailBody `
                                   -SmtpServer "smtp.gmail.com" `
                                   -Port 587 `
                                   -UseSsl `
                                   -Credential $credential
                Write-Log "Success notification sent." "INFO"
            } catch {
                Write-Log "Failed to send success notification: $($_.Exception.Message)" "WARNING"
            }
        }
    }

} catch {
    # Catch any terminating errors and log them
    Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"

} finally {
    # =====================================================================
    # 3. Post-Flight: Log Scanning & Email Alerting (PoshMailKit)
    # =====================================================================
    if (Test-Path $LogFile) {
        Write-Log "Scanning $LogFile for errors in the last 5 minutes..." "INFO"
        
        $timeThreshold = (Get-Date).AddMinutes(-5)
        $errorLines = @()
        $logContents = Get-Content -Path $LogFile
        
        foreach ($line in $logContents) {
            # Parse [Date] [Level] [Environment] Message
            if ($line -match "^\[(.*?)\] \[(.*?)\] \[(.*?)\] (.*)") {
                $logDateStr = $matches[1]
                $logLevel   = $matches[2]
                
                $logDate = [datetime]::ParseExact($logDateStr, "yyyy-MM-dd HH:mm:ss", $null)
                
                if ($logDate -ge $timeThreshold -and ($logLevel -eq "ERROR" -or $logLevel -eq "CRITICAL")) {
                    $errorLines += $line
                }
            }
        }    
        
        if ($errorLines.Count -gt 0) {
            Write-Log "$($errorLines.Count) error(s) found. Attempting to send email alert..." "INFO"
            
            try {
                # Ensure these are populated in your JSON config
                $appPassword = $Config.EmailAppPassword 
                $emailFrom   = $Config.EmailFrom
                $emailTo     = $Config.EmailTo

                if (-not $appPassword -or -not $emailFrom -or -not $emailTo) {
                    throw "Email configuration missing from JSON config."
                }

                $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
                
                $emailBody = "The following errors were detected in the $ScriptName run:`n`n" + ($errorLines -join "`n")
                
                Import-Module PoshMailKit -ErrorAction Stop
                Send-MKMailMessage -To $Config.EmailTo `
                                   -From $Config.EmailFrom `
                                   -Subject "Script Alert: $ScriptName Errors Detected" `
                                   -Body $emailBody `
                                   -SmtpServer "smtp.gmail.com" `
                                   -Port 587 `
                                   -UseSsl `
                                   -Credential $credential
                
                Write-Log "Error alert email sent successfully." "INFO"
            } catch {
                Write-Log "Failed to send email alert: $($_.Exception.Message)" "WARNING"
            }
        } else {
            Write-Log "No errors found in the last 5 minutes." "INFO"
        }
    } else {
        Write-Log "Log file not found at $LogFile. Cannot scan for errors." "WARNING"
    }

    # Ensure we return to the starting directory so we don't lock the Git folder
    Set-Location -Path "C:\"

    Write-Log "Script execution completed." -End
}