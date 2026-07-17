# Requires -RunAsAdministrator

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
if (-not $ScriptName -or $ScriptName -eq "") { $ScriptName = "000_Bootstrap" } # Fallback if run unsaved in ISE/VSCode
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$configFilePath = Join-Path (Join-Path $BaseDir "Variables") "000 - Bootstrap Script.json"
$CredFolder  = Join-Path $BaseDir "Credentials"
$KeyFile     = Join-Path $CredFolder "svc_immortalmgmt.key"
$EncFile     = Join-Path $CredFolder "svc_immortalmgmt.enc"
$taskUser       = "svc_immortalmgmt"

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$ConfigFile  = Join-Path (Join-Path $BaseDir "Variables") "$ScriptName.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$Environment = "#{ENVIRONMENT}#"

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
Write-Log "Initializing Bootstrap script execution." -Start

# Load configuration using the Hiera helper
$Config = . (Join-Path $BaseDir "Functions\Get-ScriptConfig.ps1") -ScriptName $ScriptName

Write-Log "Loaded Configuration Variables:" "INFO"
foreach ($prop in $Config.psobject.Properties) {
    if ($prop.Name -match "Password|Token") {
        Write-Log "  $($prop.Name) = ********" "INFO"
    } else {
        Write-Log "  $($prop.Name) = $($prop.Value)" "INFO"
    }
}

$scriptExitCode = 0
$scriptErrorCount = 0

try {
    # Just-In-Time Credential Decryption
    $DecryptionSuccess = $false

    if ((Test-Path $KeyFile) -and (Test-Path $EncFile)) {
        try {
            $Key = [Convert]::FromBase64String((Get-Content -Path $KeyFile -Raw).Trim())
            $EncryptedText = (Get-Content -Path $EncFile -Raw).Trim()
            $SecureString = ConvertTo-SecureString $EncryptedText -Key $Key
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
            $taskPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
            $DecryptionSuccess = $true
        } catch {
            Write-Log "Warning: Failed to decrypt pre-staged symmetric credentials: $($_.Exception.Message)" "WARNING"
        }
    }

    if (-not $DecryptionSuccess) {
        if ([Environment]::UserInteractive) {
            Write-Log "Symmetric credentials missing or invalid. Prompting for input..." "WARNING"
            Write-Host ""
            Write-Host "--------------------------------------------------" -ForegroundColor Yellow
            Write-Host "CREATING LOCAL SERVICE ACCOUNT CREDENTIALS" -ForegroundColor Yellow
            Write-Host "--------------------------------------------------" -ForegroundColor Yellow
            $PasswordInput = Read-Host -AsSecureString "Enter secure password for local user '$taskUser'"
            
            # Generate key file
            $KeyBytes = New-Object Byte[] 32
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
            $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
            if (-not (Test-Path $CredFolder)) { New-Item -Path $CredFolder -ItemType Directory -Force | Out-Null }
            $KeyBase64 | Out-File -FilePath $KeyFile -Encoding utf8 -Force
            
            # Encrypt password
            $EncryptedText = ConvertFrom-SecureString $PasswordInput -Key $KeyBytes
            $EncryptedText | Out-File -FilePath $EncFile -Encoding utf8 -Force
            
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PasswordInput)
            $taskPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
            $DecryptionSuccess = $true
            
            # Set ACLs
            try {
                $Acls = @($KeyFile, $EncFile)
                foreach ($file in $Acls) {
                    $Acl = Get-Acl -Path $file
                    $Acl.SetAccessRuleProtection($true, $false)
                    $Rules = @(
                        [System.Security.AccessControl.FileSystemAccessRule]::new("SYSTEM", "FullControl", "Allow"),
                        [System.Security.AccessControl.FileSystemAccessRule]::new("Administrators", "FullControl", "Allow"),
                        [System.Security.AccessControl.FileSystemAccessRule]::new($taskUser, "ReadAndExecute", "Allow")
                    )
                    $Acl.Access | ForEach-Object { $Acl.RemoveAccessRule($_) } | Out-Null
                    foreach ($Rule in $Rules) { $Acl.AddAccessRule($Rule) }
                    Set-Acl -Path $file -AclObject $Acl -ErrorAction Stop
                }
            } catch {
                Write-Log "Warning: Failed to set strict ACLs on credential files: $($_.Exception.Message)" "WARNING"
            }
            
            Write-Log "Successfully recreated symmetric credentials." "INFO"
        } else {
            throw "Failed to decrypt service account password and session is non-interactive."
        }
    }

    try {
        $ScriptFolder = $Config.ScriptFolder
        $TaskPath = $Config.TaskPath

        $manifestSettings = @{}
        if ($null -ne $Config.ScriptsConfig) {
            foreach ($task in $Config.ScriptsConfig) {
                $manifestSettings[$task.ScriptName] = $task
            }
        }
        Write-Log "Successfully loaded configuration from $configFilePath." "INFO"

        # Verify target script folder exists
        $TargetScriptFolder = Join-Path $ScriptFolder "Scripts\Windows"
        if (-not (Test-Path $TargetScriptFolder)) {
            throw "The script folder $TargetScriptFolder does not exist."
        }

        try {
            # Clean up any previously registered install or commander tasks in the new folder
            $oneOffTasks = @("install-immortalmgmt", "powershell_commander-immortalmgmt", "54 - Install-ImmortalMgmt-immortalmgmt", "55 - PowerShell-Commander-immortalmgmt")
            foreach ($oneOffTask in $oneOffTasks) {
                if (Get-ScheduledTask -TaskName $oneOffTask -TaskPath $TaskPath -ErrorAction SilentlyContinue) {
                    Write-Log "Removing one-off interactive task: $oneOffTask from '$TaskPath'" "INFO"
                    Unregister-ScheduledTask -TaskName $oneOffTask -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
        } catch {
            Write-Log "Warning: One-off interactive task cleanup encountered an issue: $($_.Exception.Message)" "WARNING"
        }

        $scripts = Get-ChildItem -Path $TargetScriptFolder -Filter "*.ps1" -File
        $baseIntervalMinutes = 2
        $incrementOffset = 0

        foreach ($script in $scripts) {
            try {
                $isCustom = $manifestSettings.ContainsKey($script.Name)
                $taskNamePrefix = $script.BaseName
                if ($isCustom -and $null -ne $manifestSettings[$script.Name].DisplayName) {
                    $taskNamePrefix = $manifestSettings[$script.Name].DisplayName
                }
                $taskName = "$taskNamePrefix-immortalmgmt"

                # Strict check: If task exists, skip it entirely
                $existingTask = $null
                try {
                    $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $TaskPath -ErrorAction Stop
                } catch {
                    # Task or folder does not exist yet, which is fine
                }

                if ($existingTask) {
                    Write-Log "Task '$taskName' already exists. Skipping." "INFO"
                    continue
                }

                # Determine Timer Settings
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

                if ($null -eq $intervalMinutes -or $intervalMinutes -le 0) {
                    $intervalMinutes = 60
                    Write-Log "Warning: Invalid or missing IntervalMinutes for '$($script.Name)'. Defaulting to 60 minutes." "WARNING"
                }
                if ($null -eq $startOffset -or $startOffset -lt 0) {
                    $startOffset = 5
                }

                $description = "Auto-generated task. IntervalMins: $intervalMinutes"

                # Robust Action Creation (Enforce absolute path for security hardening)
                $execPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
                if (-not (Test-Path $execPath)) { $execPath = "powershell.exe" }
                
                $action = $null
                try {
                    $action = New-ScheduledTaskAction -Execute $execPath -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($script.FullName)`"" -ErrorAction Stop
                } catch {
                    throw "Failed to create ScheduledTaskAction for '$($script.Name)': $($_.Exception.Message)"
                }
                if (-not $action) {
                    throw "New-ScheduledTaskAction returned null/empty for script '$($script.Name)'. Please verify Windows WMI/CIM Scheduled Task provider health."
                }

                # Robust Trigger Creation
                $trigger = $null
                try {
                    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($startOffset) -RepetitionInterval (New-TimeSpan -Minutes $intervalMinutes) -ErrorAction Stop
                } catch {
                    throw "Failed to create ScheduledTaskTrigger for '$($script.Name)': $($_.Exception.Message)"
                }
                if (-not $trigger) {
                    throw "New-ScheduledTaskTrigger returned null for '$($script.Name)'"
                }

                # Robust Settings Creation
                $settings = $null
                try {
                    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden -ErrorAction Stop
                } catch {
                    throw "Failed to create ScheduledTaskSettingsSet for '$($script.Name)': $($_.Exception.Message)"
                }
                if (-not $settings) {
                    throw "New-ScheduledTaskSettingsSet returned null for '$($script.Name)'"
                }

                # Robust Principal Creation
                $principal = $null
                try {
                    $principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Password -RunLevel Highest -ErrorAction Stop
                } catch {
                    throw "Failed to create ScheduledTaskPrincipal for '$($script.Name)': $($_.Exception.Message)"
                }
                if (-not $principal) {
                    throw "New-ScheduledTaskPrincipal returned null for '$($script.Name)'"
                }

                # Assemble & Register Task
                try {
                    $task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description $description -ErrorAction Stop
                    Register-ScheduledTask -TaskName $taskName -TaskPath $TaskPath -InputObject $task -User $taskUser -Password $taskPassword -Force -ErrorAction Stop | Out-Null
                    
                    if ($isCustom) {
                        Write-Log "Task: '$taskName' (Config) scheduled every $intervalMinutes minutes as $taskUser." "INFO"
                    } else {
                        Write-Log "Task: '$taskName' (Default) scheduled every $intervalMinutes minutes as $taskUser." "INFO"
                    }
                } catch {
                    throw "Failed to register Scheduled Task '$taskName': $($_.Exception.Message)"
                }
            } catch {
                # Log the specific inner scheduling failure, and continue to the next script
                Write-Log "Error scheduling script '$($script.Name)': $($_.Exception.Message)" "ERROR"
                $scriptErrorCount++
            }
        }
    } catch {
        Write-Log "Script encountered a terminating error during folder setup or preparation: $($_.Exception.Message)" "CRITICAL"
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

        Write-Log "Script execution completed." -End
    }

    # Propagate True Exit Code safely to parent without hard-terminating the session
    if ($scriptErrorCount -gt 0 -or $scriptExitCode -ne 0) {
        $global:LASTEXITCODE = 1
        return
    } else {
        $global:LASTEXITCODE = 0
        return
    }
} catch {
    Write-Log "Fatal unhandled exception in outer block: $($_.Exception.Message)" "CRITICAL"
    $global:LASTEXITCODE = 1
    return
}
