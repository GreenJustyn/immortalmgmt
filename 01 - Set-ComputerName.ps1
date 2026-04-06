$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = if ((Split-Path $ScriptDir -Leaf) -eq "Tests") { Split-Path $ScriptDir -Parent } else { $ScriptDir }

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$ConfigFile  = Join-Path (Join-Path $BaseDir "Variables") "$ScriptName.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$CredFile    = Join-Path (Join-Path $BaseDir "Credentials") "credential.xml"
$Environment = "#{ENVIRONMENT}#" # GitOps Placeholder

# Unified and updated logging function
Function Write-Log {
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Message,
        
        [Parameter(Position=1)]
        [ValidateSet("INFO", "WARNING", "ERROR", "CRITICAL")]
        [string]$Level = "INFO",
        
        [switch]$Start, 
        [switch]$End
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    if ($Start) { "( --- START [$Timestamp] $ScriptName --- )" | Out-File -FilePath $LogFile -Append }
    
    # Format matches the regex parser: [Date] [LEVEL] Message
    "[$Timestamp] [$Level] [$Environment] $Message" | Out-File -FilePath $LogFile -Append
    
    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

Write-Log "Initializing script execution." -Start

# Load Config
if (-not (Test-Path $ConfigFile)) { Write-Log "FATAL: Config file missing." "CRITICAL" -End; exit }
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $ConfigHash = @{}
    foreach ($prop in $GlobalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    foreach ($prop in $LocalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    $Config = [PSCustomObject]$ConfigHash
    Write-Log "Loaded Configuration Variables:" "INFO"
    foreach ($prop in $Config.psobject.Properties) {
        if ($prop.Name -match "Password|Token") {
            Write-Log "  $($prop.Name) = ********" "INFO"
        } else {
            Write-Log "  $($prop.Name) = $($prop.Value)" "INFO"
        }
    }

# Hostname Idempotent Logic
$CurrentName = $env:COMPUTERNAME
$DesiredName = $Config.DesiredHostName
$RequiresReboot = $false

if ($CurrentName -ine $DesiredName) {
    Write-Log "Hostname mismatch. Current: $CurrentName. Changing to: $DesiredName" "INFO"
    Rename-Computer -NewName $DesiredName -Force
    $RequiresReboot = $true
} else {
    Write-Log "Hostname is already set to $DesiredName. No action taken." "INFO"
}

# =====================================================================
# Post-Flight: Log Scanning & Email Alerting (PoshMailKit)
# =====================================================================

if (Test-Path $LogFile) {
    Write-Log "Scanning $LogFile for errors in the last 5 minutes..." "INFO"
    
    $timeThreshold = (Get-Date).AddMinutes(-5)
    $errorLines = @()
    $logContents = Get-Content -Path $LogFile
    
    foreach ($line in $logContents) {
        # Updated Regex to account for the [Environment] tag: [Date] [Level] [Env] Message
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
        
        # Ensure these exist in your $Config file or pull from $GlobalCreds
        $appPassword = $Config.EmailAppPassword 
        $emailFrom   = $Config.EmailFrom
        $emailTo     = $Config.EmailTo

        $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
        
        $emailBody = "The following errors were detected in the $ScriptName run:`n`n" + ($errorLines -join "`n")
        
        try {
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
            Write-Log "Failed to send email alert: $($_.Exception.Message)" "CRITICAL"
        }
    } else {
        Write-Log "No errors found in the last 5 minutes." "INFO"
    }
} else {
    Write-Log "Log file not found at $LogFile. Cannot scan for errors." "WARNING"
}

# Handle Reboot
if ($RequiresReboot) {
    Write-Log "Reboot flag is true. Restarting computer..." "INFO" -End
    Restart-Computer -Force
} else {
    Write-Log "Script execution completed successfully." "INFO" -End
}