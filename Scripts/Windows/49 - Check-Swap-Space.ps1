param(
    [int]$MinLevel = 10
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

Write-Log "Evaluating logical paging usage levels..." -Start

# =====================================================================
# Privilege Gates
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ CRITICAL: Local paging capacity scans necessitate administrative authorization." "CRITICAL"
    }
}

# =====================================================================
# Capacity Formatting
# =====================================================================
function MB2String { 
    param([int64]$bytes)
    if ($bytes -lt 1024) { return "$($bytes)MB" }
    $bytes /= 1024
    if ($bytes -lt 1024) { return "$($bytes)GB" }
    $bytes /= 1024
    if ($bytes -lt 1024) { return "$($bytes)TB" }
    $bytes /= 1024
    if ($bytes -lt 1024) { return "$($bytes)PB" }
    $bytes /= 1024
    if ($bytes -lt 1024) { return "$($bytes)EB" }
}

# =====================================================================
# Diagnostic Flow
# =====================================================================
try {
    if ($IsLinux -or $IsMacOS) {
        $Result = $(free --mega | grep Swap:)
        [int64]$total = $Result.subString(5,15)
        [int64]$used = $Result.substring(20,13)
        [int64]$free = $Result.substring(32,11)
    } else {
        $items = Get-WmiObject -class "Win32_PageFileUsage" -namespace "root\CIMV2" -computername localhost 
        [int64]$total = [int64]$used = 0
        foreach ($item in $items) { 
            $total += $item.AllocatedBaseSize
            $used += $item.CurrentUsage
        }
        [int64]$free = ($total - $used)
    }
    
    $status = "INFO"
    $msg = ""
    
    if ($total -eq 0) {
        $msg = "⚠️ No swap space configured."
        $status = "WARNING"
    } elseif ($free -eq 0) {
        $msg = "⚠️ Swap space of $(MB2String $total) is fully saturated!"
        $status = "CRITICAL"
    } elseif ($free -lt $MinLevel) {
        $msg = "⚠️ Swap space has only $(MB2String $free) of $(MB2String $total) left!"
        $status = "WARNING"
    } elseif ($used -lt 3) {
        $msg = "✅ Swap space has $(MB2String $total) explicitly available."
    } else {
        [int64]$percent = ($used * 100) / $total
        $msg = "✅ Swap space actively consuming $percent% of $(MB2String $total) ($(MB2String $free) available)"
    }
    
    Write-Log $msg $status
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

Write-Log "Paging metrics analyzed." "INFO" -End
