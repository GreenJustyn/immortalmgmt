# 1. Native Write-Log Function with Severity Levels

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$ConfigFile  = Join-Path (Join-Path $BaseDir "Variables") "$ScriptName.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$CredFolder  = Join-Path $BaseDir "Credentials"
$KeyFile     = Join-Path $CredFolder "svc_immortalmgmt.key"
$EncFile     = Join-Path $CredFolder "svc_immortalmgmt.enc"
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
        # Credential Check & Interactive Generation
        $DecryptionSuccess = $false
        if ((Test-Path $KeyFile) -and (Test-Path $EncFile)) {
            try {
                $Key = [Convert]::FromBase64String((Get-Content -Path $KeyFile -Raw).Trim())
                $EncryptedText = (Get-Content -Path $EncFile -Raw).Trim()
                $SecurePassword = ConvertTo-SecureString $EncryptedText -Key $Key
                $DecryptionSuccess = $true
            } catch {
                Write-Log "Existing symmetric credentials could not be decrypted. Removing files to recreate..." "WARNING"
                Remove-Item -Path $KeyFile, $EncFile -Force -ErrorAction SilentlyContinue
            }
        }

        if (-not $DecryptionSuccess) { 
            if ([Environment]::UserInteractive) {
                Write-Log "Credential files missing or invalid. Prompting to create them..." "WARNING"
                Write-Host ""
                Write-Host "--------------------------------------------------" -ForegroundColor Yellow
                Write-Host "CREATING DEDICATED SERVICE ACCOUNT CREDENTIALS" -ForegroundColor Yellow
                Write-Host "--------------------------------------------------" -ForegroundColor Yellow
                $PasswordInput = Read-Host -AsSecureString "Enter secure password for local user '$($Config.AccountName)'"
                
                # Generate key file
                $KeyBytes = New-Object Byte[] 32
                [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
                $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
                if (-not (Test-Path $CredFolder)) { New-Item -Path $CredFolder -ItemType Directory -Force | Out-Null }
                $KeyBase64 | Out-File -FilePath $KeyFile -Encoding utf8 -Force
                
                # Encrypt password
                $EncryptedText = ConvertFrom-SecureString $PasswordInput -Key $KeyBytes
                $EncryptedText | Out-File -FilePath $EncFile -Encoding utf8 -Force
                
                $SecurePassword = $PasswordInput
                $DecryptionSuccess = $true
                Write-Log "Successfully created encrypted key and credential files." "INFO"
            } else {
                throw "FATAL: Credentials missing or invalid and session is non-interactive."
            }
        }

        # Secure the key and enc files with ACLs (only SYSTEM, Administrators, and svc_immortalmgmt have access)
        try {
            $Acls = @($KeyFile, $EncFile)
            foreach ($file in $Acls) {
                if (Test-Path $file) {
                    $Acl = Get-Acl -Path $file
                    $Acl.SetAccessRuleProtection($true, $false)
                    $Rules = @(
                        [System.Security.AccessControl.FileSystemAccessRule]::new("SYSTEM", "FullControl", "Allow"),
                        [System.Security.AccessControl.FileSystemAccessRule]::new("Administrators", "FullControl", "Allow"),
                        [System.Security.AccessControl.FileSystemAccessRule]::new($Config.AccountName, "ReadAndExecute", "Allow")
                    )
                    # Clear existing rules
                    $Acl.Access | ForEach-Object { $Acl.RemoveAccessRule($_) } | Out-Null
                    foreach ($Rule in $Rules) { $Acl.AddAccessRule($Rule) }
                    Set-Acl -Path $file -AclObject $Acl -ErrorAction Stop
                }
            }
            Write-Log "Credential key files ACL security hardened." "INFO"
        } catch {
            Write-Log "Warning: Failed to set strict ACLs on credential files: $($_.Exception.Message)" "WARNING"
        }

            # Idempotent Logic
            $UserExists = Get-LocalUser -Name $Config.AccountName -ErrorAction SilentlyContinue

            if (-not $UserExists) {
                Write-Log "Local account '$($Config.AccountName)' does not exist. Creating..." "INFO"
                New-LocalUser -Name $Config.AccountName -Password $SecurePassword -Description $Config.AccountDescription -PasswordNeverExpires -ErrorAction Stop | Out-Null

                Write-Log "Adding '$($Config.AccountName)' to '$($Config.GroupName)' group." "INFO"
                Add-LocalGroupMember -Group $Config.GroupName -Member $Config.AccountName -ErrorAction Stop

                Write-Log "Local Administrator account created and permissioned successfully." "INFO"
            } else {
                Write-Log "Local account '$($Config.AccountName)' already exists. Ensuring password and group membership are enforced." "INFO"
                Set-LocalUser -Name $Config.AccountName -Password $SecurePassword -ErrorAction Stop

                $GroupMembers = Get-LocalGroupMember -Group $Config.GroupName | Select-Object -ExpandProperty Name
                $FullAccountString = "$env:COMPUTERNAME\$($Config.AccountName)"

                if ($GroupMembers -notcontains $FullAccountString -and $GroupMembers -notcontains $Config.AccountName) {
                    Write-Log "Account is missing from '$($Config.GroupName)'. Re-adding..." "WARNING"
                    # Upgraded to Stop so failures are caught and emailed
                    Add-LocalGroupMember -Group $Config.GroupName -Member $Config.AccountName -ErrorAction Stop
                }
                Write-Log "Account exists. State enforcement complete." "INFO"
            }

            # Hardening Permissions for the framework repository
            Write-Log "Hardening file and folder permissions on the repository at '$BaseDir'..." "INFO"
            $Acl = Get-Acl -Path $BaseDir
            
            # Disable inheritance and copy existing rules as inherited ones are removed
            $Acl.SetAccessRuleProtection($true, $false)
            
            # Clear all explicit rules to start clean
            $Acl.Access | ForEach-Object { $Acl.RemoveAccessRule($_) } | Out-Null
            
            # Define strict permissions: only SYSTEM, Administrators, and svc_immortalmgmt have access
            $Rules = @(
                [System.Security.AccessControl.FileSystemAccessRule]::new("SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"),
                [System.Security.AccessControl.FileSystemAccessRule]::new("Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"),
                [System.Security.AccessControl.FileSystemAccessRule]::new($Config.AccountName, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            )
            
            foreach ($Rule in $Rules) {
                $Acl.AddAccessRule($Rule)
            }
            
            Set-Acl -Path $BaseDir -AclObject $Acl -ErrorAction Stop
            Write-Log "Directory permissions hardened successfully. Only SYSTEM, Administrators, and '$($Config.AccountName)' are allowed." "INFO"
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