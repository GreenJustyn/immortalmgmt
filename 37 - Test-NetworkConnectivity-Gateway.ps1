$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.ps1$',''
$LogFile     = "C:\Scripts\Logs\$ScriptName.log"
$ConfigFile  = "C:\Scripts\Variables\$ScriptName.json"
$CredFile    = "C:\Scripts\Credentials\credential.xml"
$Environment = "#{ENVIRONMENT}#"

# 1. Native Write-Log Function with Severity Levels
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
    
    # Optional console output for manual runs
    if ($Level -eq "ERROR" -or $Level -eq "CRITICAL") { Write-Host "[$Level] $Message" -ForegroundColor Red }
    elseif ($Level -eq "WARNING") { Write-Host "[$Level] $Message" -ForegroundColor Yellow }
    else { Write-Host "[$Level] $Message" -ForegroundColor Gray }

    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

# Variable to preserve custom exit codes for orchestrators like MoM
$scriptExitCode = 0

# 2. Main Execution Block wrapped in Try/Catch
try {
    Write-Log "Initializing script execution." -Start

    # Config Check
    if (-not (Test-Path $ConfigFile)) { 
        throw "FATAL: Config missing at $ConfigFile." 
    }
    $GlobalFile = "C:\Scripts\Variables\_Global.json"
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $Config = $GlobalConfig
    foreach ($prop in $LocalConfig.psobject.Properties) { $Config.$($prop.Name) = $prop.Value }

    # Operational Logic
    Write-Log "Testing connectivity to Gateway: $($Config.GatewayIP)" "INFO"
    
    $PingResult = Test-Connection -ComputerName $Config.GatewayIP -Count $Config.PingCount -ErrorAction SilentlyContinue
    
    # Cast to array to ensure .Count works even if only 1 ping is returned
    $SuccessCount = @($PingResult | Where-Object { $_.Status -eq 'Success' }).Count
    $SuccessRate = ($SuccessCount / $Config.PingCount) * 100

    if ($SuccessRate -ge $Config.RequiredSuccessRate) {
        Write-Log "Network check passed. Success rate: $SuccessRate%." "INFO"
    } else {
        # Using throw instead of exit 1 ensures the catch & finally blocks execute
        throw "Network check failed. Success rate: $SuccessRate%. Gateway unreachable."
    }

} catch {
    # Catch any terminating errors and log them
    Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"
    $scriptExitCode = 1 # Flag script to fail after emailing

} finally {
    # =====================================================================
    # 3. Post-Flight: Log Scanning & Email Alerting (PoshMailKit)
    # =====================================================================
    if (Test-Path $LogFile) {
        Write-Log "Scanning $LogFile for errors in the last 5 minutes..." "INFO"
        
        $timeThreshold = (Get-Date).AddMinutes(-5)
        $errorLines = @()
        $logContents = Get-Content -Path $LogFile
        
        foreach ($line in $logContents) {
            # Parse [Date] [Level] [Environment] Message
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
            Write-Log "$($errorLines.Count) error(s) found. Attempting to send email alert..." "INFO"
            
            try {
                # Ensure these are populated in your JSON config
                $appPassword = $Config.EmailAppPassword 
                $emailFrom   = $Config.EmailFrom
                $emailTo     = $Config.EmailTo

                if (-not $appPassword -or -not $emailFrom -or -not $emailTo) {
                    throw "Email configuration missing from JSON config."
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
            Write-Log "No errors found in the last 5 minutes." "INFO"
        }
    } else {
        Write-Log "Log file not found at $LogFile. Cannot scan for errors." "WARNING"
    }

    Write-Log "Script execution completed." -End
}

# Preserve the exit code behavior for MoM or other downstream orchestrators
if ($scriptExitCode -ne 0) {
    exit $scriptExitCode
}