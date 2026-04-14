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

Write-Log "Initializing duration timing logic..." -Start

# =====================================================================
# Execution Status
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ ERROR: Admin rights strictly advised when mapping CIM boots alongside restart flags." "CRITICAL"
    }
}

# =====================================================================
# Subroutines
# =====================================================================
function TimeSpanAsString([TimeSpan]$uptime) {
    [int]$days = $uptime.Days
    [int]$hours = $days * 24 + $uptime.Hours
    if ($days -gt 2) {
        return "$days days"
    } elseif ($hours -gt 1) {
        return "$hours hours"
    } else {
        return "$($uptime.Minutes)min"
    }
}

function Test-RegistryValue { 
    param(
        [parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]$Path, 
        [parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]$Value
    )
    try {
        $null = Get-ItemProperty -Path $Path -Name $Value -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# =====================================================================
# Status Loop
# =====================================================================
try {
    [system.threading.thread]::currentthread.currentculture = [system.globalization.cultureinfo]"en-US"
    if ($IsLinux) {
        $lastBootTime = (Get-Uptime -since)
        $uptime = (Get-Uptime)
    } else {
        $lastBootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime 
        $uptime = New-TimeSpan -Start $lastBootTime -End (Get-Date)
    }
    
    $status = "INFO"
    $pending = ""
    
    if ($IsLinux) {
        if (Test-Path "/var/run/reboot-required") {
            $status = "WARNING"
            $pending = "with pending reboot (found /var/run/reboot-required)"
        }
    } else {
        $reason = ""
        if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
            $reason += ", ...\Auto Update\RebootRequired"
        }
        if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting") {
            $reason += ", ...\Auto Update\PostRebootReporting"
        }
        if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
            $reason += ", ...\Component Based Servicing\RebootPending"
        }
        if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentRebootAttempts") {
            $reason += ", ...\ServerManager\CurrentRebootAttempts"
        }
        if (Test-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing" -Value "RebootInProgress") {
            $reason += ", ...\CurrentVersion\Component Based Servicing with 'RebootInProgress'"
        }
        if (Test-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing" -Value "PackagesPending") {
            $reason += ", '...\CurrentVersion\Component Based Servicing' with 'PackagesPending'"
        }
        if (Test-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Value "PendingFileRenameOperations2") {
            $reason += ", '...\CurrentControlSet\Control\Session Manager' with 'PendingFileRenameOperations2'"
        }
        if (Test-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Value "DVDRebootSignal") {
            $reason += ", '...\Windows\CurrentVersion\RunOnce' with 'DVDRebootSignal'"
        }
        if (Test-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon" -Value "JoinDomain") {
            $reason += ", '...\CurrentControlSet\Services\Netlogon' with 'JoinDomain'"
        }
        if (Test-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon" -Value "AvoidSpnSet") {
            $reason += ", '...\CurrentControlSet\Services\Netlogon' with 'AvoidSpnSet'"
        }
        if ($reason -ne "") {
            $status = "WARNING"
            $pending = "with pending reboot (registry has $($reason.substring(2)))"
        }
    }
    
    Write-Log "$(hostname) is up for $(TimeSpanAsString $uptime) since $($lastBootTime.ToShortDateString()) $pending" $status
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

# =====================================================================
# Post-Flight: Log Scanning & Email Alerting (PoshMailKit)
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
            $emailBody = "Trigger Warning recorded on $ScriptName:`n`n" + ($errorLines -join "`n")
            
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

Write-Log "Routine Check finished successfully." "INFO" -End
