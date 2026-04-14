param(
    [string]$MAC = ""
)

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$ConfigFile  = Join-Path (Join-Path $BaseDir "Variables") "$ScriptName.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$CredFile    = Join-Path (Join-Path $BaseDir "Credentials") "credential.xml"
$Environment = "#{ENVIRONMENT}#" # GitOps Placeholder

# Unified logging function
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

Write-Log "Initializing script execution: MAC Header Pattern Validations." -Start

# =====================================================================
# Admin Gate Validation
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ WARNING: Running checks without Elevated roles. Regex parsing permitted." "WARNING"
    }
}

# =====================================================================
# Action Validation
# =====================================================================
function IsMACAddressValid { 
    param([string]$macToCheck)
    $RegEx = "^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})|([0-9A-Fa-f]{2}){6}$"
    return ($macToCheck -match $RegEx)
}

try {
    if ($MAC -eq "") {
        Write-Log "Empty MAC provided for validation parameters." "WARNING"
    } elseif (IsMACAddressValid $MAC) {
        Write-Log "✅ MAC address $MAC is verified valid under pattern constraints." "INFO"
    } else {
        Write-Log "Invalid MAC format parsed: [$MAC]" "ERROR"
    }
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

# =====================================================================
# Alert Reporting
# =====================================================================
if (Test-Path $LogFile) {
    $timeThreshold = (Get-Date).AddMinutes(-5)
    $errorLines = @()
    foreach ($line in (Get-Content -Path $LogFile)) {
        if ($line -match "^\[(.*?)\] \[(.*?)\] \[(.*?)\] (.*)") {
            $logLevel = $matches[2]
            if ($logLevel -eq "ERROR" -or $logLevel -eq "CRITICAL") {
                $errorLines += $line
            }
        }
    }    
    if ($errorLines.Count -gt 0) {
        Write-Log "Network strings error counts matched." "WARNING"
    }
}

Write-Log "MAC check protocol resolved." "INFO" -End
