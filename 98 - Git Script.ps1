<#
.SYNOPSIS
    Downloads and extracts Portable Git for Windows silently to a specific directory.
#>

# Requires -RunAsAdministrator

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.ps1$',''
if (-not $ScriptName) { $ScriptName = "98_Git_Install" } # Fallback if run unsaved in ISE/VSCode

$LogFile        = "C:\Scripts\Logs\$ScriptName.log"
$configFilePath = "C:\Scripts\Variables\98 - Git.json"
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
    Write-Log "Initializing script execution." -Start

    # Load Configuration
    if (-not (Test-Path $configFilePath)) {
        throw "Configuration file not found at $configFilePath."
    }
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $ConfigHash = @{}
    foreach ($prop in $GlobalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    foreach ($prop in $LocalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    $config = [PSCustomObject]$ConfigHash
    $InstallDir = $config.InstallDir
    $DownloadDir = $config.DownloadDir

    # Fetch Latest Release Info
    Write-Log "Fetching latest Git release info from GitHub API..." "INFO"
    $apiUrl = "https://api.github.com/repos/git-for-windows/git/releases/latest"
    $release = Invoke-RestMethod -Uri $apiUrl
    $asset = $release.assets | Where-Object { $_.name -match "^PortableGit-.*-64-bit\.7z\.exe$" } | Select-Object -First 1
    $installerPath = Join-Path -Path $DownloadDir -ChildPath $asset.name

    # Download
    if (-not (Test-Path $DownloadDir)) { New-Item -Path $DownloadDir -ItemType Directory -Force | Out-Null }
    
    if (-not (Test-Path $installerPath)) {
        Write-Log "[DOWNLOAD] Downloading $($asset.name)..." "INFO"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath
    } else {
        Write-Log "[DOWNLOAD] Installer $($asset.name) already exists locally. Skipping download." "INFO"
    }

    # Forced Silent Extraction
    Write-Log "[UPDATE] Extracting silently to $InstallDir..." "INFO"

    if (-not (Test-Path $InstallDir)) {
        New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    }

    # We use Resolve-Path to ensure we have a full, absolute Windows path.
    $fullPath = (Resolve-Path $InstallDir).Path.TrimEnd('\')
    $argList = "-y", "-o$fullPath"

    $process = Start-Process -FilePath $installerPath -ArgumentList $argList -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -ne 0) {
        throw "Extraction failed with exit code $($process.ExitCode)."
    }

    # Environment & PATH Update
    $gitCmdPath = Join-Path -Path $InstallDir -ChildPath "cmd"
    $gitExePath = Join-Path -Path $gitCmdPath -ChildPath "git.exe"

    $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    if ($machinePath -notlike "*$gitCmdPath*") {
        Write-Log "Updating System PATH environment variable..." "INFO"
        $newPath = "$machinePath;$gitCmdPath"
        [Environment]::SetEnvironmentVariable('Path', $newPath, [EnvironmentVariableTarget]::Machine)
        $env:Path = $newPath # Update current session
    }

    # Non-Interactive Validation
    Write-Log "[VERIFY] Checking installation..." "INFO"
    Start-Sleep -Seconds 2 # Small delay to let the file system catch up

    if (Test-Path $gitExePath) {
        $version = & $gitExePath --version
        Write-Log "[SUCCESS] Git found at: $gitExePath" "INFO"
        Write-Log "[INFO] $version" "INFO"
    } else {
        throw "Extraction reported success, but git.exe is missing from $gitExePath. Check if antivirus blocked the extraction."
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
                # IMPORTANT: Ensure your 98 - Git.json contains these email fields!
                $appPassword = $config.EmailAppPassword 
                $emailFrom   = $config.EmailFrom
                $emailTo     = $config.EmailTo

                if (-not $appPassword -or -not $emailFrom -or -not $emailTo) {
                    throw "Email configuration missing from JSON config."
                }

                $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
                
                $emailBody = "The following errors were detected in the Git Installation run:`n`n" + ($errorLines -join "`n")
                
                Import-Module PoshMailKit -ErrorAction Stop
                Send-MKMailMessage -To $emailTo `
                                   -From $emailFrom `
                                   -Subject "Script Alert: Git Installation Errors Detected" `
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