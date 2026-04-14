param(
    [string]$Drive = "C"
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

Write-Log "Initializing file volume inspection on Drive [$Drive]" -Start

# =====================================================================
# Admin Privilege Check
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ ERROR: Administrative credentials strictly required to run system Repair-Volume scans." "CRITICAL"
    }
}

# =====================================================================
# Storage Scan Pipeline
# =====================================================================
try {
    # Note: Repair-Volume strictly executes over elevated context
    Write-Log "Evaluating volume integrity parameters..." "INFO"
    $Result = Repair-Volume -DriveLetter $Drive -Scan -ErrorAction Stop
    
    if ($Result -ne "NoErrorsFound") { 
        Write-Log "Repair-Volume reported underlying errors on volume [$Drive]" "CRITICAL"
    } else {
        Write-Log "✅ File system on drive $Drive is clean." "INFO"
    }
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

# =====================================================================
# Post-Flight Reporting
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
        Write-Log "$($errorLines.Count) total storage anomalies found." "WARNING"
    }
}

Write-Log "Scanning completion valid." "INFO" -End
