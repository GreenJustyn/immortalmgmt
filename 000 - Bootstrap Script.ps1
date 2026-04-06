# Requires -RunAsAdministrator

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.ps1$',''
if (-not $ScriptName) { $ScriptName = "000_Bootstrap" } # Fallback if run unsaved in ISE/VSCode

$ScriptDir   = $PSScriptRoot
$BaseDir     = if ((Split-Path $ScriptDir -Leaf) -eq "Tests") { Split-Path $ScriptDir -Parent } else { $ScriptDir }

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$configFilePath = Join-Path (Join-Path $BaseDir "Variables") "000 - Bootstrap.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$credFilePath   = Join-Path (Join-Path $BaseDir "Credentials") "bootstrap.xml"
$taskUser       = "Administrator" # Change to "DOMAIN\Administrator" or ".\Administrator" if needed
$Environment    = "#{ENVIRONMENT}#" # GitOps Placeholder

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
    Write-Log "Initializing Bootstrap script execution." -Start

    # Load and decrypt the password from the XML file
    if (-not (Test-Path $credFilePath)) {
        throw "Encrypted credential file not found at $credFilePath."
    }

    try {
        $secureString = Import-Clixml -Path $credFilePath
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
        $taskPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    } catch {
        throw "Failed to decrypt the password. Ensure this script is running as the same user that created the XML file."
    } finally {
        if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
    }

    # Load and parse the external JSON config
    if (-not (Test-Path $configFilePath)) {
        throw "Configuration file not found at $configFilePath."
    }

    try {
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $ConfigHash = @{}
    foreach ($prop in $GlobalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    foreach ($prop in $LocalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    $config = [PSCustomObject]$ConfigHash
    Write-Log "Loaded Configuration Variables:" "INFO"
    foreach ($prop in $config.psobject.Properties) {
        if ($prop.Name -match "Password|Token") {
            Write-Log "  $($prop.Name) = ********" "INFO"
        } else {
            Write-Log "  $($prop.Name) = $($prop.Value)" "INFO"
        }
    }
        $ScriptFolder = $config.ScriptFolder
        $TaskPath = $config.TaskPath
        
        $manifestSettings = @{}
        if ($null -ne $config.ScriptsConfig) {
            foreach ($task in $config.ScriptsConfig) {
                $manifestSettings[$task.ScriptName] = $task
            }
        }
        Write-Log "Successfully loaded configuration from $configFilePath." "INFO"
    } catch {
        throw "Failed to parse $configFilePath. Please ensure it is valid JSON."
    }

    # Verify target script folder exists
    if (-not (Test-Path $ScriptFolder)) {
        throw "The script folder $ScriptFolder defined in config does not exist."
    }

    $scripts = Get-ChildItem -Path $ScriptFolder -Filter "*.ps1" -File
    $baseIntervalMinutes = 2
    $incrementOffset = 0

    foreach ($script in $scripts) {
        $taskName = "AutoRun_$($script.BaseName)"

        # Strict check: If task exists, skip it entirely
        $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $TaskPath -ErrorAction SilentlyContinue

        if ($existingTask) {
            Write-Log "Task '$taskName' already exists. Skipping." "INFO"
            continue
        }

        # Determine Timer Settings
        $isCustom = $manifestSettings.ContainsKey($script.Name)
        $startOffset = 5 
        
        if ($isCustom) {
            $customConfig = $manifestSettings[$script.Name]
            $intervalMinutes = $customConfig.IntervalMinutes
            
            if ($null -ne $customConfig.StartOffsetMinutes) { 
                $startOffset = $customConfig.StartOffsetMinutes 
            }
        } else {
            $intervalMinutes = $baseIntervalMinutes + $incrementOffset
            $incrementOffset += 5 
        }

        $description = "Auto-generated task. IntervalMins: $intervalMinutes"

        # Create Task
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($script.FullName)`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($startOffset) -RepetitionInterval (New-TimeSpan -Minutes $intervalMinutes)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Password -RunLevel Highest

        $task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description $description
        
        Register-ScheduledTask -TaskName $taskName -TaskPath $TaskPath -InputObject $task -User $taskUser -Password $taskPassword -Force | Out-Null

        if ($isCustom) {
            Write-Log "Task: '$taskName' (Config) scheduled every $intervalMinutes minutes as $taskUser." "INFO"
        } else {
            Write-Log "Task: '$taskName' (Default) scheduled every $intervalMinutes minutes as $taskUser." "INFO"
        }
    }

} catch {
    # Any "throw" command above will land here as a CRITICAL error
    Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"

} finally {
    # =====================================================================
    # Post-Flight: Log Scanning & Email Alerting (PoshMailKit)
    # =====================================================================
    if (Test-Path $LogFile) {
        Write-Log "Scanning $LogFile for errors in the last 5 minutes..." "INFO"
        
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
            Write-Log "$($errorLines.Count) error(s) found. Attempting to send email alert..." "INFO"
            
            try {
                # IMPORTANT: Ensure your 000 - Bootstrap.json contains these email fields!
                $appPassword = $config.EmailAppPassword 
                $emailFrom   = $config.EmailFrom
                $emailTo     = $config.EmailTo

                if (-not $appPassword -or -not $emailFrom -or -not $emailTo) {
                    throw "Email configuration missing from JSON config."
                }

                $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
                
                $emailBody = "The following errors were detected in the Bootstrap run:`n`n" + ($errorLines -join "`n")
                
                Import-Module PoshMailKit -ErrorAction Stop
                Send-MKMailMessage -To $emailTo `
                                   -From $emailFrom `
                                   -Subject "Script Alert: Bootstrap Errors Detected" `
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

    Write-Log "Bootstrap script execution completed." -End
}