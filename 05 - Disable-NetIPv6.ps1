$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = if ((Split-Path $ScriptDir -Leaf) -eq "Tests") { Split-Path $ScriptDir -Parent } else { $ScriptDir }

$LogFile     = Join-Path $BaseDir "Logs" "$ScriptName.log"
$ConfigFile  = Join-Path $BaseDir "Variables" "$ScriptName.json"
$GlobalFile  = Join-Path $BaseDir "Variables" "_Global.json"
$CredFile    = Join-Path $BaseDir "Credentials" "credential.xml"
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
    
    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

# 2. Main Execution Block wrapped in Try/Catch
try {
    Write-Log "Initializing script execution." -Start

    if (-not (Test-Path $ConfigFile)) { 
        throw "FATAL: Config missing at $ConfigFile." 
    }
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $Config = $GlobalConfig
    foreach ($prop in $LocalConfig.psobject.Properties) { $Config.$($prop.Name) = $prop.Value }
    
    if (-not (Test-Path $CredFile)) { 
        throw "FATAL: Credential XML missing at $CredFile." 
    }
    try { 
        $SvcCreds = Import-Clixml -Path $CredFile 
    } catch { 
        throw "ERROR: Credential import failed. Ensure script is run by the user who created the XML." 
    }

    # Idempotent Logic
    $RequiresReboot = $false
    $Binding = Get-NetAdapterBinding -InterfaceAlias $Config.InterfaceAlias -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue

    if ($Binding.Enabled) {
        Write-Log "IPv6 is enabled on $($Config.InterfaceAlias). Disabling now." "INFO"
        Disable-NetAdapterBinding -InterfaceAlias $Config.InterfaceAlias -ComponentID ms_tcpip6 -ErrorAction Stop
        $RequiresReboot = $true
    } else {
        Write-Log "IPv6 is already disabled on $($Config.InterfaceAlias). No action taken." "INFO"
    }

    # =====================================================================
    # Specific Event Alert: IPv6 Disabled Visibility
    # =====================================================================
    if ($RequiresReboot) {
        Write-Log "Network bindings changed. Triggering MKMailMessage alert for visibility." "INFO"
        
        try {
            $appPassword = $Config.EmailAppPassword 
            $emailFrom   = $Config.EmailFrom
            $emailTo     = $Config.EmailTo
            $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
            $credential  = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)

            Import-Module PoshMailKit -ErrorAction Stop
            Send-MKMailMessage -To $emailTo `
                               -From $emailFrom `
                               -Subject "[$Environment] NETWORK CHANGE: IPv6 Disabled" `
                               -Body "Script $ScriptName disabled IPv6. A reboot may be beneficial to flush network cache." `
                               -SmtpServer "smtp.gmail.com" `
                               -Port 587 `
                               -UseSsl `
                               -Credential $credential
            
            Write-Log "Visibility alert email sent successfully." "INFO"
        } catch {
            # Downgraded to WARNING so it doesn't trigger a secondary failure email
            Write-Log "Failed to send MKMailMessage visibility alert. $($_.Exception.Message)" "WARNING"
        }
    }

} catch {
    # Catch any terminating errors and log them
    Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"

} finally {
    # =====================================================================
    # Post-Flight: Log Scanning & Error Alerting (PoshMailKit)
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