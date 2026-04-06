$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = if ((Split-Path $ScriptDir -Leaf) -eq "Tests") { Split-Path $ScriptDir -Parent } else { $ScriptDir }

$LogFile     = Join-Path $BaseDir "Logs" "$ScriptName.log"
$ConfigFile  = Join-Path $BaseDir "Variables" "$ScriptName.json"
$GlobalFile  = Join-Path $BaseDir "Variables" "_Global.json"
$CredFile    = Join-Path $BaseDir "Credentials" "credential.xml"
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
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $Config = $GlobalConfig
    foreach ($prop in $LocalConfig.psobject.Properties) { $Config.$($prop.Name) = $prop.Value }

    # Credential Check (included if your downstream logic requires it)
    if (-not (Test-Path $CredFile)) { 
        throw "FATAL: Credential XML missing at $CredFile." 
    }
    try { 
        $SvcCreds = Import-Clixml -Path $CredFile 
    } catch { 
        throw "ERROR: Credential import failed. Ensure script is run by the user who created the XML." 
    }

    # Idempotent Logic
    if (-not (Test-Path $Config.SharePath)) {
        Write-Log "Share path $($Config.SharePath) does not exist. Creating directory." "INFO"
        # Set ErrorAction to Stop so folder creation failures trigger the alert
        New-Item -Path $Config.SharePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $ExistingShare = Get-SmbShare -Name $Config.ShareName -ErrorAction SilentlyContinue

    if (-not $ExistingShare) {
        Write-Log "SMB Share '$($Config.ShareName)' does not exist. Creating now." "INFO"
        
        # Requires Administrator privileges
        New-SmbShare -Name $Config.ShareName -Path $Config.SharePath -Description $Config.Description -FullAccess $Config.FullAccessAccount -ErrorAction Stop | Out-Null
        
        Write-Log "SMB Share created successfully." "INFO"
    } else {
        Write-Log "SMB Share '$($Config.ShareName)' already exists at $($ExistingShare.Path). No action taken." "INFO"
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
                Send-MKMailMessage -To $emailTo `
                                   -From $emailFrom `
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

    Write-Log "Script execution completed." -End
}