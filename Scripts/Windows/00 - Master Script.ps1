### META MASTER RUNNER SCRIPT ###
## Dynamically runs all scripts in the Custom/ directory sequentially ##

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.ps1$',''
if (-not $ScriptName -or $ScriptName -eq "") { $ScriptName = "00_Master" } 
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$Environment = "#{ENVIRONMENT}#"

# Logging helper
Function Write-Log {
    Param(
        [Parameter(Mandatory=$true, Position=0)][string]$Message,
        [Parameter(Position=1)][ValidateSet("INFO", "WARNING", "ERROR", "CRITICAL")][string]$Level = "INFO",
        [switch]$Start, 
        [switch]$End
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    if ($Start) { "( --- START [$Timestamp] $ScriptName --- )" | Out-File -FilePath $LogFile -Append }
    "[$Timestamp] [$Level] [$Environment] $Message" | Out-File -FilePath $LogFile -Append
    
    if ($Level -eq "ERROR" -or $Level -eq "CRITICAL") { Write-Host "[$Level] $Message" -ForegroundColor Red }
    elseif ($Level -eq "WARNING") { Write-Host "[$Level] $Message" -ForegroundColor Yellow }
    else { Write-Host "[$Level] $Message" -ForegroundColor Gray }

    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

$scriptStartTime = Get-Date
Write-Log "Initializing Meta Master runner." -Start

# Load configuration using the Hiera helper (Inherits Global Email variables)
$Config = . (Join-Path $BaseDir "Functions\Get-ScriptConfig.ps1") -ScriptName $ScriptName

$scriptExitCode = 0
$failedCount = 0

try {
    $CustomDir = Join-Path $ScriptDir "Custom"
    if (-not (Test-Path $CustomDir)) {
        Write-Log "Custom subdirectory not found at $CustomDir. Creating..." "WARNING"
        New-Item -Path $CustomDir -ItemType Directory -Force | Out-Null
    }

    # Scan and filter out placeholders or non-scripts
    $CustomScripts = @()
    if (Test-Path $CustomDir) {
        $CustomScripts = Get-ChildItem -Path $CustomDir -Filter "*.ps1" -File | Sort-Object Name
    }

    if (-not $CustomScripts -or $CustomScripts.Count -eq 0) {
        Write-Log "No custom actions found inside $CustomDir. Master execution complete." "INFO"
        Write-Log "Execution completed successfully." -End
        $global:LASTEXITCODE = 0
        return
    }

    Write-Log "Found $($CustomScripts.Count) custom action(s) to run sequentially." "INFO"

    foreach ($script in $CustomScripts) {
        Write-Log "--------------------------------------------------" "INFO"
        Write-Log "Executing Custom Script: $($script.Name)..." "INFO"
        
        try {
            # Clear exit codes BEFORE invoking the child script to avoid cross-script leaks
            $global:LASTEXITCODE = 0
            $LASTEXITCODE = 0

            # Execute the script dynamically in the framework context
            & $script.FullName

            # Evaluate BOTH framework global exit code and native OS exit code
            $childExitCode = 0
            if ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) {
                $childExitCode = $global:LASTEXITCODE
            } elseif ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                $childExitCode = $LASTEXITCODE
            }

            if ($childExitCode -ne 0) {
                Write-Log "Custom Script '$($script.Name)' returned failure status (Code: $childExitCode)." "ERROR"
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
        $scriptExitCode = 1
    } else {
        Write-Log "All custom scripts executed successfully." "INFO"
    }

} catch {
    Write-Log "Meta Master encountered a terminating error: $($_.Exception.Message)" "CRITICAL"
    $scriptExitCode = 1
} finally {
    # =====================================================================
    # Post-Flight: Log Scanning & Email Alerting (PoshMailKit)
    # =====================================================================
    if (Test-Path $LogFile) {
        Write-Log "Scanning $LogFile for errors since script start ($($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss')))..." "INFO"
        
        $errorLines = @()
        $logContents = Get-Content -Path $LogFile
        
        foreach ($line in $logContents) {
            if ($line -match "^\[(.*?)\] \[(.*?)\] \[(.*?)\] (.*)") {
                $logDateStr = $matches[1]
                $logLevel   = $matches[2]
                try {
                    $logDate = [datetime]::ParseExact($logDateStr, "yyyy-MM-dd HH:mm:ss", $null)
                    if ($logDate -ge $scriptStartTime -and ($logLevel -eq "ERROR" -or $logLevel -eq "CRITICAL")) {
                        $errorLines += $line
                    }
                } catch {}
            }
        }    
        
        if ($errorLines.Count -gt 0) {
            Write-Log "$($errorLines.Count) error(s) found. Attempting to send email alert..." "INFO"
            
            try {
                $appPassword = $Config.EmailAppPassword 
                $emailFrom   = $Config.EmailFrom
                $emailTo     = $Config.EmailTo

                if (-not $appPassword -or -not $emailFrom -or -not $emailTo) {
                    throw "Email configuration missing from JSON config."
                }

                if (-not (Get-Module -ListAvailable -Name PoshMailKit)) {
                    Write-Log "PoshMailKit module is not installed. Attempting installation..." "WARNING"
                    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
                    }
                    Install-Module -Name PoshMailKit -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
                } else {
                    Write-Log "PoshMailKit module is installed. Checking for updates..." "INFO"
                    Update-Module -Name PoshMailKit -Force -ErrorAction SilentlyContinue
                }

                $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
                
                $emailBody = "The following errors were detected in the $ScriptName run:`n`n" + ($errorLines -join "`n")
                
                Import-Module PoshMailKit -ErrorAction Stop
                Send-MKMailMessage -To $emailTo `
                                   -From $emailFrom `
                                   -Subject "Script Alert: $ScriptName Errors Detected" `
                                   -Body $emailBody `
                                   -SmtpServer "smtp.gmail.com" `
                                   -Port 587 `
                                   -UseSsl `
                                   -Credential $credential
                
                Write-Log "Error alert email sent successfully." "INFO"
            } catch {
                Write-Log "Failed to send email alert: $($_.Exception.Message)" "WARNING"
            }
        } else {
            Write-Log "No errors found during this run." "INFO"
        }
    } else {
        Write-Log "Log file not found at $LogFile. Cannot scan for errors." "WARNING"
    }

    Write-Log "Meta Master execution completed." -End
}

# Propagate True Exit Code safely to parent without hard-terminating the session
if ($failedCount -gt 0 -or $scriptExitCode -ne 0) {
    $global:LASTEXITCODE = 1
    return
} else {
    $global:LASTEXITCODE = 0
    return
}
