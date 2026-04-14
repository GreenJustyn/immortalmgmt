$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$ConfigFile  = Join-Path (Join-Path $BaseDir "Variables") "$ScriptName.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$CredFile    = Join-Path (Join-Path $BaseDir "Credentials") "credential.xml"
$Environment = "#{ENVIRONMENT}#" # GitOps Placeholder

Function Write-Log {
    Param(
        [Parameter(Mandatory=$true, Position=0)] [string]$Message,
        [Parameter(Position=1)] [ValidateSet("INFO", "WARNING", "ERROR", "CRITICAL")] [string]$Level = "INFO",
        [switch]$Start, [switch]$End
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if ($Start) { "( --- START [$Timestamp] $ScriptName --- )" | Out-File -FilePath $LogFile -Append -Force }
    "[$Timestamp] [$Level] [$Environment] $Message" | Out-File -FilePath $LogFile -Append -Force
    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append -Force }
}

Write-Log "Initializing absolute Recycle Bin deletion sequence..." -Start

# =====================================================================
# Role Authorization
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ WARNING: Purging global system bins securely operates optimally over Administrator states." "WARNING"
    }
}

# =====================================================================
# Purge Routine
# =====================================================================
try {
    Write-Log "Triggering unconfirmed Clear-RecycleBin pipeline." "INFO"
    Clear-RecycleBin -Confirm:$false -ErrorAction Stop
    if ($lastExitCode -and $lastExitCode -ne 0) { throw "Underlying clear operation failed on bin nodes." }

    Write-Log "✅ Global trash bin partitions cleared cleanly." "INFO"
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

# =====================================================================
# Post-Flight Mail Alerts
# =====================================================================
if (Test-Path $LogFile) {
    Write-Log "Scanning $LogFile for automated exceptions..." "INFO"
    $timeThreshold = (Get-Date).AddMinutes(-5)
    $errorLines = @()
    $logContents = Get-Content -Path $LogFile
    
    foreach ($line in $logContents) {
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
        Write-Log "$($errorLines.Count) error(s) tracked. Alerting via MK..." "WARNING"
        if ($Config -and $Config.EmailFrom) {
            $appPassword = $Config.EmailAppPassword 
            $emailFrom   = $Config.EmailFrom
            $emailTo     = $Config.EmailTo

            $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
            $emailBody = "Trigger Warning recorded on ${ScriptName}:`n`n" + ($errorLines -join "`n")
            
            try {
                Import-Module PoshMailKit -ErrorAction SilentlyContinue
                Send-MKMailMessage -To $emailTo -From $emailFrom -Subject "Alert: Script Event Failure" -Body $emailBody -SmtpServer "smtp.gmail.com" -Port 587 -UseSsl -Credential $credential
                Write-Log "Audit alert successfully forwarded." "INFO"
            } catch {
                Write-Log "SMTP transport drop: $($_.Exception.Message)" "WARNING"
            }
        }
    }
}

Write-Log "Maintenance cycle complete." "INFO" -End
