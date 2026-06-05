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

try {
    $scriptExitCode = 0

    # Decrypt the task registration password
    $DecryptionSuccess = $false
    if ((Test-Path $KeyFile) -and (Test-Path $EncFile)) {
        try {
            $Key = [Convert]::FromBase64String((Get-Content -Path $KeyFile -Raw).Trim())
            $EncryptedText = (Get-Content -Path $EncFile -Raw).Trim()
            $SecurePassword = ConvertTo-SecureString $EncryptedText -Key $Key
            
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
            $taskPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            $DecryptionSuccess = $true
        } catch {
            Write-Log "Failed to decrypt service account password: $($_.Exception.Message)" "WARNING"
        } finally {
            if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
        }
    }

    if (-not $DecryptionSuccess) {
        if ([Environment]::UserInteractive) {
            Write-Log "Prompting to re-enter service account credentials..." "WARNING"
            Write-Host "--------------------------------------------------" -ForegroundColor Yellow
            Write-Host "RE-CREATING SERVICE ACCOUNT CREDENTIALS" -ForegroundColor Yellow
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
        Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"
        $scriptExitCode = 1
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
            Write-Log "No errors found in the last 5 minutes." "INFO"
        }
    } else {
        Write-Log "Log file not found at $LogFile. Cannot scan for errors." "WARNING"
    }

    Write-Log "Script execution completed." -End
}

if ($scriptExitCode -ne 0) {
    exit $scriptExitCode
}