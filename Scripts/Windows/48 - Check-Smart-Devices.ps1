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

Write-Log "Initializing SMART controller integrity audit..." -Start

# =====================================================================
# Admin Guard
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ CRITICAL: Inspecting smartctl device handlers mandates privileged accounts." "CRITICAL"
    }
}

# =====================================================================
# Storage Formatter
# =====================================================================
function Bytes2String([int64]$bytes) {
    if ($bytes -lt 1000) { return "$bytes bytes" }
    $bytes /= 1000
    if ($bytes -lt 1000) { return "$($bytes)KB" }
    $bytes /= 1000
    if ($bytes -lt 1000) { return "$($bytes)MB" }
    $bytes /= 1000
    if ($bytes -lt 1000) { return "$($bytes)GB" }
    $bytes /= 1000
    if ($bytes -lt 1000) { return "$($bytes)TB" }
    $bytes /= 1000
    if ($bytes -lt 1000) { return "$($bytes)PB" }
    $bytes /= 1000
    if ($bytes -lt 1000) { return "$($bytes)EB" }
}

# =====================================================================
# Sub-system Routine
# =====================================================================
try {
    $result = (smartctl --version 2>&1)
    if ($lastExitCode -ne 0) { throw "Cannot execute 'smartctl'. Ensure smartmontools are natively referenced in PATH." }

    if ($IsLinux) {
        $devices = $(sudo smartctl --scan-open)
    } else {
        $devices = $(smartctl --scan-open)
    }

    foreach($device in $devices) {
        $array = $device.split(" ")
        $dev = $array[0]
        if ("$dev" -eq "#" -or "$dev" -eq "") {
            continue
        } elseif ($IsLinux) {
            $details = (sudo smartctl --all --json $dev) | ConvertFrom-Json
            $null = (sudo smartctl --test=conveyance $dev)
        } else {
            $details = (smartctl --all --json $dev) | ConvertFrom-Json
            $null = (smartctl --test=conveyance $dev)
        }
        
        $status = "INFO"
        $modelName = $details.model_name
        $protocol = $details.device.protocol
        if ($bytes -gt 0) {
            $capacity = "$(Bytes2String $bytes) "
        } else {
            $capacity = ""
        }
        
        $infos = ""
        if ($details.temperature.current -gt 50) {
            $infos = "$($details.temperature.current)°C TOO HOT"
            $status = "CRITICAL"
        } elseif ($details.temperature.current -lt 0) {
            $infos = "$($details.temperature.current)°C TOO COLD"
            $status = "WARNING"
        } else {
            $infos = "$($details.temperature.current)°C"
        }
        
        if ($details.power_on_time.hours -gt 87600) { 
            $infos += ", $($details.power_on_time.hours)h (!)"
            $status = "WARNING"
        } else {
            $infos += ", $($details.power_on_time.hours)h"
        }
        if ($details.power_cycle_count -gt 100000) { 
            $infos += ", $($details.power_cycle_count)x on/off (!)"
            $status = "WARNING"
        } else {
            $infos += ", $($details.power_cycle_count)x on/off"
        }
        if ($details.nvme_smart_health_information_log.host_reads) {
            $infos += ", $(Bytes2String ($details.nvme_smart_health_information_log.data_units_read * 512 * 1000)) read"
            $infos += ", $(Bytes2String ($details.nvme_smart_health_information_log.data_units_written * 512 * 1000)) written"
        }
        $infos += ", v$($details.firmware_version)"
        
        if ($details.smart_status.passed) {
            $infos += ", test passed"
        } else {
            $infos += ", test FAILED"
            $status = "CRITICAL"
        }
        Write-Log "$capacity$modelName via $protocol ($infos)" $status
    }
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

Write-Log "Smart sensor checks finalized." "INFO" -End
