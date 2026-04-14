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
    "[$Timestamp] [$Level] [$Environment] $Message" | Out-File -FilePath $LogFile -Append -Force
    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append -Force }
}

Write-Log "Initializing script execution: BIOS Inventory Validation." -Start

# Load Config Safely
if (Test-Path $ConfigFile) {
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $ConfigHash = @{}
    foreach ($prop in $GlobalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    foreach ($prop in $LocalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    $Config = [PSCustomObject]$ConfigHash
}

# =====================================================================
# Admin Prerequisite Gate
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ ERROR: Administrative privileges required to query local WMI classes." "CRITICAL"
    }
}

# =====================================================================
# BIOS Validation Block
# =====================================================================
try {
    if ($IsLinux) {
        $model = (sudo dmidecode -s system-product-name)
        if ("$model" -eq "") { Write-Log "No Linux DMIDECODE details." "WARNING"; exit 0 }
        
        $version = (sudo dmidecode -s bios-version)
        $releaseDate = (sudo dmidecode -s bios-release-date)
        $manufacturer = (sudo dmidecode -s system-manufacturer)
    } else {
        $details = Get-CimInstance -ClassName Win32_BIOS
        $model = $details.Name.Trim()
        $version = $details.Version.Trim()
        $serial = $details.SerialNumber.Trim()
        $manufacturer = $details.Manufacturer.Trim()
    }

    if ($model -eq "To be filled by O.E.M.") { $model = "N/A" }
    if ($version -eq "To be filled by O.E.M.") { $version = "N/A" }
    if ("$releaseDate" -ne "") { $releaseDate = " of $releaseDate" }
    if ("$serial" -eq "") { $serial = "N/A" }
    if ($serial -eq "To be filled by O.E.M.") { $serial = "N/A" }

    Write-Log "✅ BIOS model $model, version $($version)$($releaseDate), S/N $serial by $manufacturer" "INFO"
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
