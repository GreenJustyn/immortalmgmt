$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

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
    
    if ($Start) { "( --- START [$Timestamp] $ScriptName --- )" | Out-File -FilePath $LogFile -Append -Force }
    
    # Format matches the regex parser: [Date] [LEVEL] Message
    "[$Timestamp] [$Level] [$Environment] $Message" | Out-File -FilePath $LogFile -Append -Force
    
    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append -Force }
}

Write-Log "Initializing script execution: Admin Privilege Check." -Start

# Load Config Safely (Optional for simple checks, but template standard)
if (Test-Path $ConfigFile) {
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $ConfigHash = @{}
    foreach ($prop in $GlobalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    foreach ($prop in $LocalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    $Config = [PSCustomObject]$ConfigHash
}

# =====================================================================
# Core Privilege Validation Block
# =====================================================================
try {
    $currentUser = [System.Environment]::UserName
    
    if ($IsLinux) {
        Write-Log "Platform is Linux. Standard Windows Principal validations bypassed." "INFO"
    } else {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = (New-Object Security.Principal.WindowsPrincipal $user)
        
        if ($principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
            Write-Log "✅ Yes, $currentUser has admin rights." "INFO"
        } elseif ($principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Guest)) {
            Write-Log "⚠️ No, $currentUser has guest rights only." "WARNING"
        } else {
            Write-Log "⚠️ No, $currentUser has normal user rights only." "ERROR"
        }
    }  
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
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
        Write-Log "$($errorLines.Count) error(s) found. Action necessary." "WARNING"
        
        # Check if config loaded for mailing
        if ($Config -and $Config.EmailFrom) {
            Write-Log "Attempting to send email alert..." "INFO"
            $appPassword = $Config.EmailAppPassword 
            $emailFrom   = $Config.EmailFrom
            $emailTo     = $Config.EmailTo

            $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
            
            $emailBody = "Privilege Alert: Non-Admin State detected in $ScriptName run:`n`n" + ($errorLines -join "`n")
            
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
        }
    } else {
        Write-Log "Privileges cleared perfectly. No errors found." "INFO"
    }
}

Write-Log "Privilege check finalized." "INFO" -End
