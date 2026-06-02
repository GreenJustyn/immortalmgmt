### META MASTER RUNNER SCRIPT ###
## Dynamically runs all scripts in the Custom/ directory sequentially ##

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$configFilePath = Join-Path (Join-Path $BaseDir "Variables") "00 - Master.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"

# Logging helper
Function Write-Log {
    Param(
        [Parameter(Mandatory=$true, Position=0)][string]$Message,
        [Parameter(Position=1)][ValidateSet("INFO", "WARNING", "ERROR", "CRITICAL")][string]$Level = "INFO",
        [switch]$Start, 
        [switch]$End
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Environment = "#{ENVIRONMENT}#"
    
    if ($Start) { "( --- START [$Timestamp] $ScriptName --- )" | Out-File -FilePath $LogFile -Append }
    "[$Timestamp] [$Level] [$Environment] $Message" | Out-File -FilePath $LogFile -Append
    
    if ($Level -eq "ERROR" -or $Level -eq "CRITICAL") { Write-Host "[$Level] $Message" -ForegroundColor Red }
    elseif ($Level -eq "WARNING") { Write-Host "[$Level] $Message" -ForegroundColor Yellow }
    else { Write-Host "[$Level] $Message" -ForegroundColor Gray }

    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

Write-Log "Initializing Meta Master runner." -Start

$CustomDir = Join-Path $ScriptDir "Custom"
if (-not (Test-Path $CustomDir)) {
    Write-Log "Custom subdirectory not found at $CustomDir. Creating..." "WARNING"
    New-Item -Path $CustomDir -ItemType Directory -Force | Out-Null
}

# Scan and filter out placeholders or non-scripts
$CustomScripts = Get-ChildItem -Path $CustomDir -Filter "*.ps1" -File | Sort-Object Name

if ($CustomScripts.Count -eq 0) {
    Write-Log "No custom actions found inside $CustomDir. Master execution complete." "INFO"
    Write-Log "Execution completed successfully." -End
    exit 0
}

Write-Log "Found $($CustomScripts.Count) custom action(s) to run sequentially." "INFO"
$failedCount = 0

foreach ($script in $CustomScripts) {
    Write-Log "--------------------------------------------------" "INFO"
    Write-Log "Executing Custom Script: $($script.Name)..." "INFO"
    
    try {
        # Execute the script dynamically in the framework context
        $scriptExitCode = 0
        & $script.FullName
        
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Custom Script '$($script.Name)' returned non-zero exit code: $LASTEXITCODE" "ERROR"
            $failedCount++
        } else {
            Write-Log "Custom Script '$($script.Name)' executed successfully." "INFO"
        }
    } catch {
        Write-Log "Custom Script '$($script.Name)' threw a terminating error: $($_.Exception.Message)" "CRITICAL"
        $failedCount++
    }
}

Write-Log "--------------------------------------------------" "INFO"
if ($failedCount -gt 0) {
    Write-Log "Meta Master finished with $failedCount failed script(s)." "ERROR"
    exit 1
} else {
    Write-Log "All custom scripts executed successfully." "INFO"
    Write-Log "Meta Master execution completed." -End
}