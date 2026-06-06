# Logic: <base dir> is two levels up from where the script runs

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

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

            # 2. Git Environment Check & Automated Portable Git Installation
            Write-Log "Verifying Git installation..." "INFO"
            
            $gitInstalled = $false
            $gitExePath = ""
            
            # Check if Git is in system PATH
            if (Get-Command git -ErrorAction SilentlyContinue) {
                $gitInstalled = $true
                $gitExePath = (Get-Command git).Source
            } else {
                # Resolve expected installation directory from Config or defaults
                $installDir = $Config.InstallDir
                if ([string]::IsNullOrWhiteSpace($installDir)) { $installDir = "C:\Scripts\Installs\Git" }
                $downloadDir = $Config.DownloadDir
                if ([string]::IsNullOrWhiteSpace($downloadDir)) { $downloadDir = "C:\Scripts\Temp\Downloads" }
                
                $gitCmdPath = Join-Path $installDir "cmd"
                $expectedGitExe = Join-Path $gitCmdPath "git.exe"
                
                if (Test-Path $expectedGitExe) {
                    Write-Log "Git found in expected installation folder but is missing from system PATH. Restoring PATH environment..." "WARNING"
                    
                    $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
                    if ($machinePath -notlike "*$gitCmdPath*") {
                        $newPath = "$machinePath;$gitCmdPath"
                        [Environment]::SetEnvironmentVariable('Path', $newPath, [EnvironmentVariableTarget]::Machine)
                        $env:Path = $newPath # Update current session
                    }
                    
                    if (Get-Command git -ErrorAction SilentlyContinue) {
                        $gitInstalled = $true
                        $gitExePath = $expectedGitExe
                        Write-Log "System PATH successfully restored." "INFO"
                    }
                }
                
                if (-not $gitInstalled) {
                    Write-Log "Git is not installed on this server. Triggering automated Portable Git deployment..." "WARNING"
                    
                    try {
                        # Fetch Latest Release Info from GitHub API
                        Write-Log "Fetching latest Portable Git release info from GitHub API..." "INFO"
                        $apiUrl = "https://api.github.com/repos/git-for-windows/git/releases/latest"
                        $release = Invoke-RestMethod -Uri $apiUrl
                        $asset = $release.assets | Where-Object { $_.name -match "^PortableGit-.*-64-bit\.7z\.exe$" } | Select-Object -First 1
                        
                        if (-not $asset) {
                            throw "Could not find a valid 64-bit Portable Git asset in the latest GitHub release."
                        }
                        
                        $installerPath = Join-Path $downloadDir $asset.name
                        
                        # Download
                        if (-not (Test-Path $downloadDir)) { New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null }
                        
                        if (-not (Test-Path $installerPath)) {
                            Write-Log "[DOWNLOAD] Downloading $($asset.name)..." "INFO"
                            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath
                        } else {
                            Write-Log "[DOWNLOAD] Installer $($asset.name) already exists locally. Skipping download." "INFO"
                        }
                        
                        # Forced Silent Extraction
                        Write-Log "[UPDATE] Extracting silently to $installDir..." "INFO"
                        if (-not (Test-Path $installDir)) {
                            New-Item -Path $installDir -ItemType Directory -Force | Out-Null
                        }
                        
                        $fullPath = (Resolve-Path $installDir).Path.TrimEnd('\')
                        $argList = "-y", "-o$fullPath"
                        
                        $process = Start-Process -FilePath $installerPath -ArgumentList $argList -Wait -PassThru -NoNewWindow
                        
                        if ($process.ExitCode -ne 0) {
                            throw "Extraction failed with exit code $($process.ExitCode)."
                        }
                        
                        # Environment & PATH Update
                        $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
                        if ($machinePath -notlike "*$gitCmdPath*") {
                            $newPath = "$machinePath;$gitCmdPath"
                            [Environment]::SetEnvironmentVariable('Path', $newPath, [EnvironmentVariableTarget]::Machine)
                            $env:Path = $newPath # Update current session
                        }
                        
                        Start-Sleep -Seconds 2 # Small delay for file system
                        
                        if (Test-Path $expectedGitExe) {
                            $gitInstalled = $true
                            $gitExePath = $expectedGitExe
                            $version = & $gitExePath --version
                            Write-Log "[SUCCESS] Portable Git successfully deployed: $version" "INFO"
                        } else {
                            throw "Extraction reported success, but git.exe is missing from $expectedGitExe."
                        }
                    } catch {
                        throw "Failed to deploy Portable Git: $($_.Exception.Message)"
                    }
                }
            }

            $RepoPath = $Config.LocalRepoPath # Usually <BaseDir>\Git\<RepoName>
            $Branch   = $Config.Branch
            $RepoUrl  = $Config.RepoUrl
            $AuthUrl  = $RepoUrl

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