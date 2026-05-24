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
        # Operational Logic: Ensure Pester 5 is installed and loaded
            $Pester5 = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 }
            if (-not $Pester5) {
                Write-Log "Pester version 5 or higher not found. Attempting to install from PSGallery..." "INFO"
                try {
                    # -SkipPublisherCheck is needed because built-in Pester is signed by MS, new is signed by Pester team
                    Install-Module -Name Pester -Force -SkipPublisherCheck -Scope AllUsers -ErrorAction Stop
                    Write-Log "Pester installed successfully." "INFO"
                    # Refresh list
                    $Pester5 = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 }
                } catch {
                    throw "FATAL: Failed to install Pester. Please run script 14 or install it manually. Error: $($_.Exception.Message)"
                }
            }

            # Explicitly import the version 5+ module to avoid using the built-in Pester 3.x
            Import-Module Pester -RequiredVersion $Pester5[0].Version -ErrorAction Stop

            if (Test-Path $Config.PesterTestsPath) {
                Write-Log "Executing Pester infrastructure tests against $($Config.ScriptsDirectory)..." "INFO"

                # Pass variables into the Pester script scope using a hashtable for Pester 5+
                $PesterData = @{
                    ScriptsDir = $Config.ScriptsDirectory
                    ConfigDir  = $Config.ConfigDirectory
                    EnvName    = $Environment
                }

                try {
                    # Create a Pester 5 configuration object to handle parameters and output formatting
                    $PesterConfig = [PesterConfiguration]::Default
                    $PesterConfig.Run.Path = $Config.PesterTestsPath
                    $PesterConfig.Run.Container = New-PesterContainer -Path $Config.PesterTestsPath -Data $PesterData
                    $PesterConfig.TestResult.Enabled = $true
                    $PesterConfig.TestResult.OutputPath = $Config.OutputFile
                    $PesterConfig.TestResult.OutputFormat = "NUnitXml"
                    $PesterConfig.Output.Verbosity = "Detailed"

                    Invoke-Pester -Configuration $PesterConfig -ErrorAction Stop

                    Write-Log "Pester tests completed. Results saved to $($Config.OutputFile)." "INFO"
                } catch {
                    Write-Log "Pester tests failed or threw an exception. Review $($Config.OutputFile). $($_.Exception.Message)" "ERROR"
                }
            } else {
                Write-Log "No Pester test file found at $($Config.PesterTestsPath)." "WARNING"
            }
    } catch {
        Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"
        $scriptExitCode = 1
    } finally {
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