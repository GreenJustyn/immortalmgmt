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

Write-Log "Initializing script execution: CPU Inventory & Thermal Checks." -Start

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
        Write-Log "⚠️ ERROR: Administrative privileges required to query underlying CPU/WMI temperatures." "CRITICAL"
    }
}

# =====================================================================
# Core Functions
# =====================================================================
function GetCPUArchitecture {
    if ("$env:PROCESSOR_ARCHITECTURE" -ne "") { return "$env:PROCESSOR_ARCHITECTURE" }
    if ($IsLinux) {
        $Name = $PSVersionTable.OS
        if ($Name -like "*-generic *") {
            if ([System.Environment]::Is64BitOperatingSystem) { return "x64" } else { return "x86" }
        } elseif ($Name -like "*-raspi *") {
            if ([System.Environment]::Is64BitOperatingSystem) { return "ARM64" } else { return "ARM32" }
        } elseif ([System.Environment]::Is64BitOperatingSystem) { return "64-bit" } else { return "32-bit" }
    }
}

function GetCPUTemperature {
    $temp = 99999.9 # unsupported
    if ($IsLinux) {
        if (Test-Path "/sys/class/thermal/thermal_zone0/temp" -pathType leaf) {
            [int]$IntTemp = Get-Content "/sys/class/thermal/thermal_zone0/temp"
            $temp = [math]::round($IntTemp / 1000.0, 1)
        }
    } else {
        try {
            $objects = Get-WmiObject -Query "SELECT * FROM Win32_PerfFormattedData_Counters_ThermalZoneInformation" -Namespace "root/CIMV2" -ErrorAction SilentlyContinue
            foreach ($object in $objects) {
                $highPrec = $object.HighPrecisionTemperature
                $temp = [math]::round($highPrec / 100.0, 1)
            }
        } catch {
            Write-Log "Failed reading WMI Thermal classes. Skipping sensor metric." "WARNING"
        }
    }
    return $temp
}

# =====================================================================
# Action Trigger
# =====================================================================
try {
    $status = "INFO"
    $arch = GetCPUArchitecture
    if ($IsLinux) {
        $cpuName = "$arch CPU"
        $arch = ""
        $deviceID = ""
        $speed = ""
        $socket = ""
    } else {
        $details = Get-WmiObject -Class Win32_Processor
        $cpuName = $details.Name.trim()
        $arch = "$arch, "
        $deviceID = ", $($details.DeviceID)"
        $speed = ", $($details.MaxClockSpeed)MHz"
        $socket = ", $($details.SocketDesignation) socket"
    }
    $cores = [System.Environment]::ProcessorCount
    $celsius = GetCPUTemperature
    
    if ($celsius -eq 99999.9) {
        $temp = ""
    } elseif ($celsius -gt 80) {
        $temp = ", $($celsius)°C TOO HOT"
        $status = "CRITICAL"
    } elseif ($celsius -gt 50) {
        $temp = ", $($celsius)°C HOT"
        $status = "WARNING"
    } elseif ($celsius -lt 0) {
        $temp = ", $($celsius)°C TOO COLD"
        $status = "WARNING"
    } else {
        $temp = ", $($celsius)°C"
    } 

    Write-Log "$cpuName ($($arch)$cores cores$($temp)$($deviceID)$($speed)$($socket))" $status
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

# =====================================================================
# Post-Flight Alerts
# =====================================================================
if (Test-Path $LogFile) {
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
        Write-Log "$($errorLines.Count) thermal/metric anomaly found. Review status." "WARNING"
    }
}

Write-Log "CPU audit step complete." "INFO" -End
