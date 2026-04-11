$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$ConfigFile  = Join-Path (Join-Path $BaseDir "Variables") "$ScriptName.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$CredFile    = Join-Path (Join-Path $BaseDir "Credentials") "credential.xml"
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

# --- NEW FEATURE: Disk Scanner Function ---
Function Get-TopLargestFiles {
    Param(
        [Parameter(Mandatory=$true)][string]$DriveLetter
    )
    $DrivePath = "$($DriveLetter):\"
    Write-Log "Initiating deep scan on $DrivePath for the top 5 largest files. This may take a moment..." "INFO"
    
    # Scans the drive, ignores access errors, sorts by size, grabs top 5.
    $TopFiles = Get-ChildItem -Path $DrivePath -File -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending |
        Select-Object -First 5 |
        Select-Object DirectoryName, Name, @{Name="SizeMB";Expression={[math]::Round($_.Length / 1MB, 2)}}
        
    return $TopFiles
}
# ------------------------------------------

# --- NEW FEATURE: Auto-Remediate Temp Files ---
Function Clear-WindowsTemp {
    Param(
        [Parameter(Mandatory=$true)][string]$DriveLetter
    )
    $OSDrive = $env:SystemDrive.Substring(0,1)
    
    # Only execute if the low-space drive is actually the OS drive
    if ($DriveLetter -eq $OSDrive) {
        Write-Log "Auto-Remediation: Attempting to clear Windows temporary files on the OS Drive ($DriveLetter:)..." "WARNING"
        
        $TempPaths = @(
            "$env:windir\Temp\*",
            "$env:TEMP\*"
        )
        
        $InitialSpace = (Get-Volume -DriveLetter $DriveLetter).SizeRemaining
        
        foreach ($Path in $TempPaths) {
            # Silently delete files; running processes will hold locks on some, which we safely skip
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | 
                Where-Object { -not $_.PSIsContainer } | 
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        
        $FinalSpace = (Get-Volume -DriveLetter $DriveLetter).SizeRemaining
        $FreedMB = [math]::Round(($FinalSpace - $InitialSpace) / 1MB, 2)
        
        if ($FreedMB -gt 0) {
            Write-Log "Successfully freed $FreedMB MB by clearing temporary files." "INFO"
        } else {
            Write-Log "Temp file cleanup completed, but no significant space was freed (files may be actively in use)." "INFO"
        }
    }
}
# ----------------------------------------------

# 2. Main Execution Block wrapped in Try/Catch
try {
    Write-Log "Initializing script execution." -Start

    # Config Check
    if (-not (Test-Path $ConfigFile)) { 
        throw "FATAL: Config missing at $ConfigFile." 
    }
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $ConfigHash = @{}
    foreach ($prop in $GlobalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    foreach ($prop in $LocalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    $Config = [PSCustomObject]$ConfigHash
    Write-Log "Loaded Configuration Variables:" "INFO"
    foreach ($prop in $Config.psobject.Properties) {
        if ($prop.Name -match "Password|Token") {
            Write-Log "  $($prop.Name) = ********" "INFO"
        } else {
            Write-Log "  $($prop.Name) = $($prop.Value)" "INFO"
        }
    }

    # Operational Logic
    Write-Log "Compiling System Health data..." "INFO"

    $OS = Get-CimInstance Win32_OperatingSystem
    $Uptime = (Get-Date) - $OS.LastBootUpTime
    $Disks = Get-Volume | Where-Object DriveType -eq 'Fixed' | Select-Object DriveLetter, @{N='FreeGB';E={[math]::Round($_.SizeRemaining/1GB,2)}}, @{N='TotalGB';E={[math]::Round($_.Size/1GB,2)}}, @{N='FreePct';E={[math]::Round(($_.SizeRemaining/$_.Size)*100,2)}}

    $HtmlHead = "<style>body{font-family: Arial;} table{border-collapse: collapse; width: 50%;} th, td{border: 1px solid #ddd; padding: 8px;} th{background-color: #f2f2f2;}</style>"
    $HtmlBody = "<h2>[$Environment] System Health Report - $env:COMPUTERNAME</h2>"
    $HtmlBody += "<p><strong>Uptime:</strong> $($Uptime.Days) Days, $($Uptime.Hours) Hours</p>"
    $HtmlBody += "<h3>Disk Space</h3>"
    $HtmlBody += ($Disks | ConvertTo-Html -Fragment)

    foreach ($Disk in $Disks) {
        if ($Disk.FreePct -lt $Config.DiskWarningThresholdPercent) {
            Write-Log "Disk $($Disk.DriveLetter) has less than $($Config.DiskWarningThresholdPercent)% free space ($($Disk.FreePct)% remaining)." "ERROR"
            
            # --- NEW FEATURE TRIGGER: Auto-Remediate if under 15% ---
            if ($Disk.FreePct -lt 15) {
                Clear-WindowsTemp -DriveLetter $Disk.DriveLetter
            }
            # --------------------------------------------------------

            # --- PREVIOUS FEATURE TRIGGER: Scan and Log Results ---
            $TopItems = Get-TopLargestFiles -DriveLetter $Disk.DriveLetter
            if ($TopItems) {
                Write-Log "Top 5 largest space consumers on Drive $($Disk.DriveLetter):" "ERROR"
                $Rank = 1
                foreach ($Item in $TopItems) {
                    Write-Log "  $Rank. $($Item.DirectoryName)\$($Item.Name) ($($Item.SizeMB) MB)" "ERROR"
                    $Rank++
                }
            } else {
                Write-Log "Could not retrieve largest files for Drive $($Disk.DriveLetter). Ensure script is running as Administrator." "WARNING"
            }
            # -------------------------------------------------
        }
    }

    try {
        ConvertTo-Html -Head $HtmlHead -Body $HtmlBody | Out-File -FilePath $Config.ReportPath -Force -ErrorAction Stop
        Write-Log "HTML Health Report successfully exported to $($Config.ReportPath)." "INFO"
    } catch {
        throw "Failed to generate HTML report. $($_.Exception.Message)"
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
                
                $emailBody = "The following errors/alerts were detected in the $ScriptName run:`n`n" + ($errorLines -join "`n")
                
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