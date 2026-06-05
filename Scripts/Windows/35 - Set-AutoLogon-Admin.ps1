# 1. Native Write-Log Function with Severity Levels

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$ConfigFile  = Join-Path (Join-Path $BaseDir "Variables") "$ScriptName.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$CredFile    = Join-Path (Join-Path $BaseDir "Credentials") "credential.xml"
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

Write-Log "Initializing script execution." -Start

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

    try {
        # Load password from secure Credentials/credential.key and credential.enc if available, else migrate legacy credential.xml
        $CredFolder       = Join-Path $BaseDir "Credentials"
        $symKeyFile       = Join-Path $CredFolder "credential.key"
        $symEncFile       = Join-Path $CredFolder "credential.enc"

        $DecryptionSuccess = $false

        if ((Test-Path $symKeyFile) -and (Test-Path $symEncFile)) {
            try {
                $Key = [Convert]::FromBase64String((Get-Content -Path $symKeyFile -Raw).Trim())
                $EncryptedText = (Get-Content -Path $symEncFile -Raw).Trim()
                $SecurePassword = ConvertTo-SecureString $EncryptedText -Key $Key
                $DecryptionSuccess = $true
            } catch {
                Write-Log "Failed to decrypt symmetric credentials: $($_.Exception.Message)" "WARNING"
            }
        }

        if (-not $DecryptionSuccess) {
            if (Test-Path $CredFile) {
                try {
                    $SvcCreds = Import-Clixml -Path $CredFile
                    if ($SvcCreds -is [System.Management.Automation.PSCredential]) {
                        $SecurePassword = $SvcCreds.Password
                    } else {
                        $SecurePassword = $SvcCreds # Assume it is the SecureString itself
                    }
                    
                    # Migrate to symmetric files on the fly
                    $KeyBytes = New-Object Byte[] 32
                    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
                    $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
                    $KeyBase64 | Out-File -FilePath $symKeyFile -Encoding utf8 -Force
                    
                    $EncryptedText = ConvertFrom-SecureString $SecurePassword -Key $KeyBytes
                    $EncryptedText | Out-File -FilePath $symEncFile -Encoding utf8 -Force
                    
                    # Set strict ACL permissions
                    try {
                        $Acls = @($symKeyFile, $symEncFile)
                        foreach ($file in $Acls) {
                            $Acl = Get-Acl -Path $file
                            $Acl.SetAccessRuleProtection($true, $false)
                            $Rules = @(
                                [System.Security.AccessControl.FileSystemAccessRule]::new("SYSTEM", "FullControl", "Allow"),
                                [System.Security.AccessControl.FileSystemAccessRule]::new("Administrators", "FullControl", "Allow"),
                                [System.Security.AccessControl.FileSystemAccessRule]::new("svc_immortalmgmt", "ReadAndExecute", "Allow")
                            )
                            $Acl.Access | ForEach-Object { $Acl.RemoveAccessRule($_) } | Out-Null
                            foreach ($Rule in $Rules) { $Acl.AddAccessRule($Rule) }
                            Set-Acl -Path $file -AclObject $Acl -ErrorAction Stop
                        }
                    } catch {
                        Write-Log "Warning: Failed to set strict ACLs on symmetric credential files: $($_.Exception.Message)" "WARNING"
                    }
                    
                    $DecryptionSuccess = $true
                    Write-Log "Successfully migrated legacy DPAPI credential.xml to symmetric key encryption on-the-fly." "INFO"
                } catch {
                    Write-Log "Failed to decrypt legacy XML credential file: $($_.Exception.Message)" "WARNING"
                }
            }
        }

        if (-not $DecryptionSuccess) {
            if ([Environment]::UserInteractive) {
                Write-Log "Symmetric credential files missing or invalid. Prompting to create them..." "WARNING"
                Write-Host ""
                Write-Host "--------------------------------------------------" -ForegroundColor Yellow
                Write-Host "CREATING LOCAL ADMINISTRATOR CREDENTIALS (CREDENTIAL)" -ForegroundColor Yellow
                Write-Host "--------------------------------------------------" -ForegroundColor Yellow
                $PasswordInput = Read-Host -AsSecureString "Enter password for autologon admin user"
                
                # Generate key file
                $KeyBytes = New-Object Byte[] 32
                [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
                $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
                if (-not (Test-Path $CredFolder)) { New-Item -Path $CredFolder -ItemType Directory -Force | Out-Null }
                $KeyBase64 | Out-File -FilePath $symKeyFile -Encoding utf8 -Force
                
                # Encrypt password
                $EncryptedText = ConvertFrom-SecureString $PasswordInput -Key $KeyBytes
                $EncryptedText | Out-File -FilePath $symEncFile -Encoding utf8 -Force
                
                $SecurePassword = $PasswordInput
                $DecryptionSuccess = $true
                
                # Set ACLs
                try {
                    $Acls = @($symKeyFile, $symEncFile)
                    foreach ($file in $Acls) {
                        $Acl = Get-Acl -Path $file
                        $Acl.SetAccessRuleProtection($true, $false)
                        $Rules = @(
                            [System.Security.AccessControl.FileSystemAccessRule]::new("SYSTEM", "FullControl", "Allow"),
                            [System.Security.AccessControl.FileSystemAccessRule]::new("Administrators", "FullControl", "Allow"),
                            [System.Security.AccessControl.FileSystemAccessRule]::new("svc_immortalmgmt", "ReadAndExecute", "Allow")
                        )
                        $Acl.Access | ForEach-Object { $Acl.RemoveAccessRule($_) } | Out-Null
                        foreach ($Rule in $Rules) { $Acl.AddAccessRule($Rule) }
                        Set-Acl -Path $file -AclObject $Acl -ErrorAction Stop
                    }
                } catch {
                    Write-Log "Warning: Failed to set strict ACLs on symmetric credential files: $($_.Exception.Message)" "WARNING"
                }
                
                Write-Log "Successfully created symmetric credentials." "INFO"
            } else {
                throw "FATAL: Symmetric credential files missing or invalid and session is non-interactive."
            }
        }

        try {
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
            $PlainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        } finally {
            if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
        }

            # Idempotent Logic
            $WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

            $CurrentAutoAdmin = (Get-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon" -ErrorAction SilentlyContinue).AutoAdminLogon
            $TargetVal = if ($Config.EnableAutoLogon) { "1" } else { "0" }

            if ($CurrentAutoAdmin -ne $TargetVal) {
                Write-Log "AutoLogon state drift. Enforcing EnableAutoLogon: $($Config.EnableAutoLogon)" "INFO"

                Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon" -Value $TargetVal -Force -ErrorAction Stop
                Set-ItemProperty -Path $WinlogonPath -Name "DefaultUserName" -Value $Config.TargetUser -Force -ErrorAction Stop
                Set-ItemProperty -Path $WinlogonPath -Name "DefaultDomainName" -Value $Config.Domain -Force -ErrorAction Stop

                if ($Config.EnableAutoLogon) {
                    Set-ItemProperty -Path $WinlogonPath -Name "DefaultPassword" -Value $PlainPass -Force -ErrorAction Stop
                    Write-Log "AutoLogon configured securely." "INFO"
                } else {
                    Remove-ItemProperty -Path $WinlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
                    Write-Log "AutoLogon disabled and credentials scrubbed." "INFO"
                }
            } else {
                Write-Log "AutoLogon configuration is already correct. No action taken." "INFO"
            }
    } catch {
        Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"
        $scriptExitCode = 1
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