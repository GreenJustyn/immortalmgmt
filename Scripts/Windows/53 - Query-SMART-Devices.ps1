param(
    [string]$Directory = ""
)

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

Write-Log "Initializing SMART Telemetry logging..." -Start

# =====================================================================
# Admin Credentials Enforcement
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ CRITICAL: Elevated privilege execution required to communicate directly with SMART controllers." "CRITICAL"
    }
}

# =====================================================================
# Sub-Routines
# =====================================================================
function CheckIfInstalled {
    try {
        $null = Invoke-Expression "smartctl --version" -ErrorAction Stop
    } catch {
        Write-Log "smartctl not recognized as internal cmdlet. Ensure smartmontools is correctly path-mapped." "CRITICAL"
        throw "smartctl missing"
    }
}

# =====================================================================
# Main Execution Pipeline
# =====================================================================
try {
    if ($Directory -eq "") {
        $Directory = $ScriptDir
    }

    Write-Log "(1) Verifying 'smartctl' package status..." "INFO"
    CheckIfInstalled

    Write-Log "(2) Activating hardware scanner..." "INFO"
    # Parse available drives
    $Devices = $(smartctl --scan-open)

    [int]$DevNo = 1
    foreach($Device in $Devices) {
        $cleanDevice = $Device.split(" ")[0]
        if ($cleanDevice -match "^#" -or $cleanDevice -eq "") { continue }

        Write-Log "(3) Querying target: $cleanDevice..." "INFO"
        $Time = (Get-Date)
        $Filename = Join-Path $Directory "SMART-dev$($DevNo)-$($Time.Year)-$($Time.Month)-$($Time.Day).json"
        Write-Log "(4) Offloading to file: $Filename..." "INFO"

        # Explicit JSON pull
        $Cmd = "smartctl --all --json " + $cleanDevice
        Invoke-Expression $Cmd | Out-File -FilePath $Filename -Force -Encoding utf8
        $DevNo++
    }

    Write-Log "✅ S.M.A.R.T payload dumps captured." "INFO"
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

# =====================================================================
# Post-Flight Monitoring
# =====================================================================
if (Test-Path $LogFile) {
    Write-Log "Scanning $LogFile for deployment triggers..." "INFO"
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
        Write-Log "$($errorLines.Count) pipeline fault recorded. Alerting endpoints..." "WARNING"
        if ($Config -and $Config.EmailFrom) {
            $appPassword = $Config.EmailAppPassword 
            $emailFrom   = $Config.EmailFrom
            $emailTo     = $Config.EmailTo

            $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
            $emailBody = "Trigger Warning recorded on ${ScriptName}:`n`n" + ($errorLines -join "`n")
            
            try {
                Import-Module PoshMailKit -ErrorAction SilentlyContinue
                Send-MKMailMessage -To $emailTo -From $emailFrom -Subject "Alert: Automation Interruption" -Body $emailBody -SmtpServer "smtp.gmail.com" -Port 587 -UseSsl -Credential $credential
                Write-Log "Audit failure dispatched." "INFO"
            } catch {
                Write-Log "Failed dispatch sequence." "WARNING"
            }
        }
    }
}

Write-Log "Routine Check finished successfully." "INFO" -End
