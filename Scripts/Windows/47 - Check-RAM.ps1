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

Write-Log "Initializing physical memory checks..." -Start

# =====================================================================
# Core Admin
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ ERROR: Reading internal RAM diagnostic parameters requires privileged access modes." "CRITICAL"
    }
}

# =====================================================================
# Memory Format Helpers
# =====================================================================
function GetRAMType { 
    param([int]$Type)
    switch($Type) {
        2 { return "DRAM" }
        5 { return "EDO RAM" }
        6 { return "EDRAM" }
        7 { return "VRAM" }
        8 { return "SRAM" }
        10 { return "ROM" }
        11 { return "Flash" }
        12 { return "EEPROM" }
        13 { return "FEPROM" }
        14 { return "EPROM" }
        15 { return "CDRAM" }
        16 { return "3DRAM" }
        17 { return "SDRAM" }
        18 { return "SGRAM" }
        19 { return "RDRAM" }
        20 { return "DDR RAM" }
        21 { return "DDR2 RAM" }
        22 { return "DDR2 FB-DIMM" }
        24 { return "DDR3 RAM" }
        26 { return "DDR4 RAM" }
        27 { return "DDR5 RAM" }
        28 { return "DDR6 RAM" }
        29 { return "DDR7 RAM" }
        default { return "RAM" }
    }
}

function Bytes2String { 
    param([int64]$Bytes)
    if ($Bytes -lt 1024) { return "$Bytes bytes" }
    $Bytes /= 1024
    if ($Bytes -lt 1024) { return "$($Bytes)KB" }
    $Bytes /= 1024
    if ($Bytes -lt 1024) { return "$($Bytes)MB" }
    $Bytes /= 1024
    if ($Bytes -lt 1024) { return "$($Bytes)GB" }
    $Bytes /= 1024
    if ($Bytes -lt 1024) { return "$($Bytes)TB" }
    $Bytes /= 1024
    if ($Bytes -lt 1024) { return "$($Bytes)PB" }
    $Bytes /= 1024
    if ($Bytes -lt 1024) { return "$($Bytes)EB" }
}

# =====================================================================
# Routine
# =====================================================================
try {
    if ($IsLinux) {
        Write-Log "Linux memory parsing omitted." "WARNING"
    } else {
        $Banks = Get-WmiObject -Class Win32_PhysicalMemory
        foreach ($Bank in $Banks) {
            $Capacity = Bytes2String($Bank.Capacity)
            $Type = GetRAMType $Bank.SMBIOSMemoryType
            $Speed = $Bank.Speed
            [float]$Voltage = $Bank.ConfiguredVoltage / 1000.0
            $Manufacturer = $Bank.Manufacturer
            $Location = "$($Bank.BankLabel)/$($Bank.DeviceLocator)"
            Write-Log "✅ $Capacity $Type at $($Speed)MHz,$($Voltage)V in $Location by $Manufacturer" "INFO"
        }
    }
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

Write-Log "Memory routine validation ended." "INFO" -End
