# Requires -RunAsAdministrator

$ScriptName  = "install"
$ScriptDir   = $PSScriptRoot
$BaseDir     = $ScriptDir

$LogsDir     = Join-Path $BaseDir "Logs"
if (-not (Test-Path $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

$LogFile     = Join-Path $LogsDir "$ScriptName.log"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$Environment = "#{ENVIRONMENT}#" # GitOps Placeholder

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
    
    if ($Level -eq "ERROR" -or $Level -eq "CRITICAL") { Write-Host "[$Level] $Message" -ForegroundColor Red }
    elseif ($Level -eq "WARNING") { Write-Host "[$Level] $Message" -ForegroundColor Yellow }
    else { Write-Host "[$Level] $Message" -ForegroundColor Gray }

    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

try {
    Write-Log "Initializing Install script execution." -Start

    # Load Global Config for Email
    if (-not (Test-Path $GlobalFile)) {
        throw "Global configuration file not found at $GlobalFile."
    }
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json

    # =====================================================================
    # Dependency Check: NuGet & PoshMailKit (Non-standard for PS 5.1)
    # =====================================================================
    Write-Log "Performing dependency checks for non-standard modules..." "INFO"

    # Enable TLS 1.2 (Required for PSGallery in older systems/configurations)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # 1. NuGet Provider
    $NuGetProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
    if (-not $NuGetProvider) {
        Write-Log "NuGet provider missing. Installing..." "INFO"
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
            Write-Log "NuGet provider installed successfully." "INFO"
        } catch {
            throw "Failed to install NuGet provider: $($_.Exception.Message)"
        }
    } else {
        Write-Log "NuGet provider is available." "INFO"
    }

    # 2. PoshMailKit Module
    $PoshMailKit = Get-Module -Name PoshMailKit -ListAvailable -ErrorAction SilentlyContinue
    if (-not $PoshMailKit) {
        Write-Log "PoshMailKit module missing. Installing from PSGallery..." "INFO"
        try {
            # Ensure PSGallery is trusted to avoid prompts
            $Repo = Get-PSRepository -Name "PSGallery" -ErrorAction SilentlyContinue
            if ($Repo -and $Repo.InstallationPolicy -ne "Trusted") {
                Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction Stop
            }
            Install-Module -Name PoshMailKit -Force -AllowClobber -Scope AllUsers -ErrorAction Stop | Out-Null
            Write-Log "PoshMailKit module installed successfully." "INFO"
        } catch {
            throw "Failed to install PoshMailKit module: $($_.Exception.Message)"
        }
    } else {
        Write-Log "PoshMailKit module is available." "INFO"
    }


    # Identify Hostname
    $Hostname = $env:COMPUTERNAME
    Write-Log "Identified local hostname: $Hostname" "INFO"

    # Create Hosts folder if it doesn't exist
    $HostsDir = Join-Path (Join-Path $BaseDir "Variables") "Hosts"
    if (-not (Test-Path $HostsDir)) {
        New-Item -Path $HostsDir -ItemType Directory -Force | Out-Null
        Write-Log "Created Hosts directory: $HostsDir" "INFO"
    }

    # Create Host specific folder
    $HostDir = Join-Path $HostsDir $Hostname
    if (-not (Test-Path $HostDir)) {
        New-Item -Path $HostDir -ItemType Directory -Force | Out-Null
        Write-Log "Created Host directory: $HostDir" "INFO"
    } else {
        Write-Log "Host directory already exists: $HostDir" "INFO"
    }

    # Copy files from DefaultHost
    $DefaultHostDir = Join-Path $HostsDir "DefaultHost"
    if (Test-Path $DefaultHostDir) {
        $files = Get-ChildItem -Path $DefaultHostDir
        foreach ($file in $files) {
            $destFile = Join-Path $HostDir $file.Name
            if (-not (Test-Path $destFile)) {
                Copy-Item -Path $file.FullName -Destination $destFile -Force
                Write-Log "Copied $($file.Name) to $HostDir" "INFO"
            } else {
                Write-Log "$($file.Name) already exists in $HostDir. Skipping copy." "INFO"
            }
        }
    } else {
        Write-Log "DefaultHost directory not found at $DefaultHostDir. Cannot copy default files." "WARNING"
    }

    # Populate .keep if needed
    $KeepFile = Join-Path $HostDir ".keep"
    if (-not (Test-Path $KeepFile)) {
        "This folder is for host $Hostname variables." | Out-File -FilePath $KeepFile -Force
        Write-Log "Created .keep file in $HostDir" "INFO"
    }

    # Advanced/Detailed: Gather System Info and create _Host.json
    Write-Log "Gathering system information for $Hostname..." "INFO"
    
    $OSInfo = Get-CimInstance Win32_OperatingSystem
    $CPUInfo = Get-CimInstance Win32_Processor
    $MemInfo = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
    
    $IPAddresses = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }).IPAddress
    $MACAddresses = (Get-NetAdapter | Where-Object Status -eq "Up").MacAddress

    $HostVars = @{
        HostName        = $Hostname
        OSName          = $OSInfo.Caption
        OSVersion       = $OSInfo.Version
        OSArchitecture  = $OSInfo.OSArchitecture
        CPU             = $CPUInfo.Name
        RAM_GB          = [Math]::Round($MemInfo.Sum / 1GB, 2)
        IPAddresses     = $IPAddresses
        MACAddresses    = $MACAddresses
        TimeZone        = (Get-TimeZone).Id
        Domain          = (Get-CimInstance Win32_ComputerSystem).Domain
        InstallDate     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    $HostVarsFile = Join-Path $HostDir "_Host.json"
    $HostVars | ConvertTo-Json -Depth 5 | Out-File -FilePath $HostVarsFile -Force
    Write-Log "Created thorough set of variables in $HostVarsFile" "INFO"

    # Update .gitignore
    $GitIgnoreFile = Join-Path $BaseDir ".gitignore"
    $IgnoreEntry = "Variables/Hosts/$Hostname/"

    if (Test-Path $GitIgnoreFile) {
        $GitIgnoreContent = Get-Content -Path $GitIgnoreFile
        if ($GitIgnoreContent -notcontains $IgnoreEntry) {
            $IgnoreEntry | Out-File -FilePath $GitIgnoreFile -Append
            Write-Log "Added $IgnoreEntry to .gitignore" "INFO"
        } else {
            Write-Log "$IgnoreEntry already present in .gitignore" "INFO"
        }
    } else {
        $IgnoreEntry | Out-File -FilePath $GitIgnoreFile -Force
        Write-Log "Created .gitignore and added $IgnoreEntry" "INFO"
    }

} catch {
    Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"
} finally {
    # Post-Flight: Log Scanning & Email Alerting (PoshMailKit)
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
                $appPassword = $GlobalConfig.EmailAppPassword 
                $emailFrom   = $GlobalConfig.EmailFrom
                $emailTo     = $GlobalConfig.EmailTo

                if (-not $appPassword -or -not $emailFrom -or -not $emailTo) {
                    throw "Email configuration missing from Global config."
                }

                $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
                
                $emailBody = "The following errors were detected in the Install run:`n`n" + ($errorLines -join "`n")
                
                Import-Module PoshMailKit -ErrorAction Stop
                Send-MKMailMessage -To $emailTo `
                                   -From $emailFrom `
                                   -Subject "Script Alert: Install Errors Detected on $Hostname" `
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

    Write-Log "Install script execution completed." -End
}
