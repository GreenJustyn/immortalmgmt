# Logic: <base dir> is two levels up from where the script runs

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
        $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
            $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
            $ConfigHash = @{}
            foreach ($prop in $GlobalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
            foreach ($prop in $LocalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
            $Config = [PSCustomObject]$ConfigHash

            # 2. Git Environment Check
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "FATAL: Git is not installed." }
            # Load Git Token from secure symmetric credentials if available, else migrate legacy XML
            $CredFolder       = Join-Path $BaseDir "Credentials"
            $gitKeyFile       = Join-Path $CredFolder "git-credential.key"
            $gitEncFile       = Join-Path $CredFolder "git-credential.enc"
            
            # Paths for legacy migration
            $LegacyGitXml     = Join-Path $CredFolder "git-credential.xml"
            $LegacyCredXml    = Join-Path $CredFolder "credential.xml"

            $DecryptionSuccess = $false

            if ((Test-Path $gitKeyFile) -and (Test-Path $gitEncFile)) {
                try {
                    $Key = [Convert]::FromBase64String((Get-Content -Path $gitKeyFile -Raw).Trim())
                    $EncryptedText = (Get-Content -Path $gitEncFile -Raw).Trim()
                    $SecureToken = ConvertTo-SecureString $EncryptedText -Key $Key
                    $DecryptionSuccess = $true
                } catch {
                    Write-Log "Failed to decrypt symmetric git credentials: $($_.Exception.Message)" "WARNING"
                }
            }

            if (-not $DecryptionSuccess) {
                # Try migrating legacy git-credential.xml first, fallback to credential.xml
                $MigrationSource = $null
                if (Test-Path $LegacyGitXml) {
                    $MigrationSource = $LegacyGitXml
                } elseif (Test-Path $LegacyCredXml) {
                    $MigrationSource = $LegacyCredXml
                }
                
                if ($MigrationSource) {
                    try {
                        $Imported = Import-Clixml -Path $MigrationSource
                        if ($Imported -is [System.Management.Automation.PSCredential]) {
                            $SecureToken = $Imported.Password
                        } else {
                            $SecureToken = $Imported
                        }
                        
                        # Generate symmetric key
                        $KeyBytes = New-Object Byte[] 32
                        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
                        $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
                        $KeyBase64 | Out-File -FilePath $gitKeyFile -Encoding utf8 -Force
                        
                        $EncryptedText = ConvertFrom-SecureString $SecureToken -Key $KeyBytes
                        $EncryptedText | Out-File -FilePath $gitEncFile -Encoding utf8 -Force
                        
                        # Set strict ACL permissions
                        try {
                            $Acls = @($gitKeyFile, $gitEncFile)
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
                            Write-Log "Warning: Failed to set strict ACLs on git credential files: $($_.Exception.Message)" "WARNING"
                        }
                        
                        $DecryptionSuccess = $true
                        Write-Log "Successfully migrated legacy Git XML credentials ($MigrationSource) to symmetric key encryption." "INFO"
                    } catch {
                        Write-Log "Failed to decrypt legacy XML Git credential file: $($_.Exception.Message)" "WARNING"
                    }
                }
            }

            if (-not $DecryptionSuccess) {
                if ([Environment]::UserInteractive) {
                    Write-Log "Symmetric git credential files missing or invalid. Prompting to create them..." "WARNING"
                    Write-Host ""
                    Write-Host "--------------------------------------------------" -ForegroundColor Yellow
                    Write-Host "CREATING GITHUB ACCESS TOKEN CREDENTIALS (GIT)" -ForegroundColor Yellow
                    Write-Host "--------------------------------------------------" -ForegroundColor Yellow
                    $PasswordInput = Read-Host -AsSecureString "Enter your GitHub Personal Access Token"
                    
                    # Generate key file
                    $KeyBytes = New-Object Byte[] 32
                    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($KeyBytes)
                    $KeyBase64 = [Convert]::ToBase64String($KeyBytes)
                    if (-not (Test-Path $CredFolder)) { New-Item -Path $CredFolder -ItemType Directory -Force | Out-Null }
                    $KeyBase64 | Out-File -FilePath $gitKeyFile -Encoding utf8 -Force
                    
                    # Encrypt token
                    $EncryptedText = ConvertFrom-SecureString $PasswordInput -Key $KeyBytes
                    $EncryptedText | Out-File -FilePath $gitEncFile -Encoding utf8 -Force
                    
                    $SecureToken = $PasswordInput
                    $DecryptionSuccess = $true
                    
                    # Set ACLs
                    try {
                        $Acls = @($gitKeyFile, $gitEncFile)
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
                        Write-Log "Warning: Failed to set strict ACLs on git credential files: $($_.Exception.Message)" "WARNING"
                    }
                    
                    Write-Log "Successfully created symmetric git credentials." "INFO"
                } else {
                    throw "FATAL: Symmetric git credentials missing or invalid and session is non-interactive."
                }
            }

            try {
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
                $Token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            } finally {
                if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
            }

            $RepoPath = $Config.LocalRepoPath # Usually <BaseDir>\Git\<RepoName>
            $Branch   = $Config.Branch
            $RepoUrl  = $Config.RepoUrl
            $AuthUrl  = $RepoUrl -replace "https://", "https://$Token@"

            # 3. Pull / Trigger Logic
            if (-not (Test-Path "$RepoPath\.git")) {
                Write-Log "Cloning repository..." "INFO"
                git -c credential.helper='' clone -b $Branch $AuthUrl $RepoPath 2>&1
            }

            Set-Location -Path $RepoPath
            $null = git -c credential.helper='' fetch --quiet $AuthUrl $Branch 2>&1

            $LOCAL  = (git rev-parse HEAD).Trim()
            $REMOTE = (git rev-parse FETCH_HEAD).Trim()

            Write-Log "Local: $LOCAL, Remote: $REMOTE" "INFO"
            Write-Log "Syncing staging folder to remote state..." "INFO"
            git -c credential.helper='' reset --hard FETCH_HEAD 2>&1

            # 5. File Replication to Operating Folders
            Write-Log "Syncing all files from staging to base directory..." "INFO"
            robocopy $RepoPath $BaseDir *.* /E /XD .git Git /NDL /NFL /NJH /NJS
            if ($LASTEXITCODE -ge 8) { Write-Log "Robocopy failed with code $LASTEXITCODE" "ERROR" }

            Write-Log "Deployment routines completed successfully." "INFO"
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