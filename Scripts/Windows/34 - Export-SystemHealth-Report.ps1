if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

if ($ScriptDir -match "Scripts.Windows$") {
} else {
}


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

            # --- NEW FEATURE: Purge User Temp Files (7-Day Valve Flag) ---
            $UserTempDir = "$env:USERPROFILE\AppData\Local\Temp"
            if (Test-Path $UserTempDir) {
                $CutoffDate = (Get-Date).AddDays(-7)

                # Valve Check: Does the folder contain any files older than 7 days?
                $AgedItems = Get-ChildItem -Path $UserTempDir -Recurse -Force -ErrorAction SilentlyContinue | 
                    Where-Object { $_.LastWriteTime -lt $CutoffDate }

                if ($AgedItems) {
                    Write-Log "Valve Flag Triggered: Content older than 7 days detected in $UserTempDir. Purging aged files..." "INFO"
                    $AgedItems | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                    Write-Log "Aged temporary user files successfully purged." "INFO"
                } else {
                    Write-Log "Valve Flag Safe: All contents in $UserTempDir are less than 7 days old. Skipping purge." "INFO"
                }
            }
            # -------------------------------------------------------------
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
                    Update-Module -Name PoshMailKit -Force -Scope CurrentUser -ErrorAction SilentlyContinue
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