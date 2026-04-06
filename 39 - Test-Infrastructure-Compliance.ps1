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
    
    # Optional console output for manual runs
    if ($Level -eq "ERROR" -or $Level -eq "CRITICAL") { Write-Host "[$Level] $Message" -ForegroundColor Red }
    elseif ($Level -eq "WARNING") { Write-Host "[$Level] $Message" -ForegroundColor Yellow }
    else { Write-Host "[$Level] $Message" -ForegroundColor Gray }

    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

# 2. Main Execution Block wrapped in Try/Catch
try {
    Write-Log "Initializing script execution." -Start

    # Config Check
    if (-not (Test-Path $ConfigFile)) { 
        throw "FATAL: Config missing at $ConfigFile." 
    }
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $Config = [PSCustomObject]@{}
    foreach ($prop in $GlobalConfig.psobject.Properties) { $Config | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value }
    foreach ($prop in $LocalConfig.psobject.Properties) {
        if ($Config.psobject.Properties.Name -contains $prop.Name) { $Config.$($prop.Name) = $prop.Value }
        else { $Config | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value }
    }

    # Operational Logic: Ensure Pester is installed
    if (-not (Get-Module -ListAvailable -Name Pester)) {
        throw "FATAL: Pester module not installed. Cannot run compliance checks."
    }

    if (Test-Path $Config.PesterTestsPath) {
        Write-Log "Executing Pester infrastructure tests against $($Config.ScriptsDirectory)..." "INFO"
        
        # Pass variables into the Pester script scope using a hashtable for Pester 5+
        $PesterData = @{
            ScriptsDir = $Config.ScriptsDirectory
            ConfigDir  = $Config.ConfigDirectory
            EnvName    = $Environment
        }

        try {
            # Create a Pester 5 configuration object to handle parameters and output formatting
            $PesterConfig = [PesterConfiguration]::Default
            $PesterConfig.Run.Path = $Config.PesterTestsPath
            $PesterConfig.Run.Container = New-PesterContainer -Path $Config.PesterTestsPath -Data $PesterData
            $PesterConfig.TestResult.Enabled = $true
            $PesterConfig.TestResult.OutputPath = $Config.OutputFile
            $PesterConfig.TestResult.OutputFormat = "NUnitXml"
            $PesterConfig.Output.Verbosity = "Detailed"

            Invoke-Pester -Configuration $PesterConfig -ErrorAction Stop
            
            Write-Log "Pester tests completed. Results saved to $($Config.OutputFile)." "INFO"
        } catch {
            Write-Log "Pester tests failed or threw an exception. Review $($Config.OutputFile). $($_.Exception.Message)" "ERROR"
        }
    } else {
        Write-Log "No Pester test file found at $($Config.PesterTestsPath)." "WARNING"
    }

} catch {
    # Catch any terminating errors and log them
    Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"

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