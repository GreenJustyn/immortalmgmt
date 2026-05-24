<#
    .SYNOPSIS
    Pester 5 Compliance Test for Evergreen Windows Server Infrastructure.
    Expects $ScriptsDir and $ConfigDir to be passed via New-PesterContainer.
#>

$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = if ((Split-Path $ScriptDir -Leaf) -eq "Tests") { Split-Path $ScriptDir -Parent } else { $ScriptDir }

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
    
    if ($Start) { "( --- START [$Timestamp] Pester Run: $ScriptName --- )" | Out-File -FilePath $LogFile -Append }
    
    "[$Timestamp] [$Level] [$Environment] $Message" | Out-File -FilePath $LogFile -Append
    
    # Optional console output for manual runs
    if ($Level -eq "ERROR" -or $Level -eq "CRITICAL") { Write-Host "[$Level] $Message" -ForegroundColor Red }
    elseif ($Level -eq "WARNING") { Write-Host "[$Level] $Message" -ForegroundColor Yellow }
    else { Write-Host "[$Level] $Message" -ForegroundColor Gray }

    if ($End) { "( --- END [$Timestamp] Pester Run: $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

# =====================================================================
# PESTER 5 DISCOVERY REQUIREMENT
# Variables used in a Describe/It -ForEach loop MUST be defined at 
# the root level (not in BeforeAll) so Discovery can evaluate them.
# =====================================================================
if (-not $ScriptsDir) { $ScriptsDir = Join-Path $BaseDir "Scripts\Windows" }
# Updated default to match your new standard variables folder
if (-not $ConfigDir) { $ConfigDir = Join-Path $BaseDir "Variables" } 

# Gather all PS1 files in the root scripts directory
$TargetScripts = Get-ChildItem -Path $ScriptsDir -Filter "*.ps1" -File

BeforeAll {
    Write-Log "Initializing Pester compliance tests execution." -Start

    # Config Check
    if (-not (Test-Path $ConfigFile)) { 
        Write-Log "FATAL: Config missing at $ConfigFile." "CRITICAL"
        throw "FATAL: Config missing at $ConfigFile." 
    }
    # Scoped to script so AfterAll can read the email settings later
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $ConfigHash = @{}
    foreach ($prop in $GlobalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    foreach ($prop in $LocalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    $Script:Config = [PSCustomObject]$ConfigHash
    Write-Log "Loaded Configuration Variables:" "INFO"
    foreach ($prop in $Script:Config.psobject.Properties) {
        if ($prop.Name -match "Password|Token") {
            Write-Log "  $($prop.Name) = ********" "INFO"
        } else {
            Write-Log "  $($prop.Name) = $($prop.Value)" "INFO"
        }
    }
}

Describe "Infrastructure Automation Codebase Integrity" {
    
    Context "Script Static Code Analysis" {
        It "Should have valid PowerShell syntax for <_.Name>" -ForEach $TargetScripts {
            $ScriptFile = $_.FullName
            $ParseErrors = $null
            $Tokens = $null
            
            # Use the PowerShell Parser to check syntax without running the code
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $ScriptFile, 
                [ref]$Tokens, 
                [ref]$ParseErrors
            )
            
            # Explicitly log the failure so the post-flight scanner catches it
            if ($ParseErrors.Count -gt 0) {
                $ErrMsgs = $ParseErrors | ForEach-Object { $_.Message }
                Write-Log "Syntax error found in $($_.Name). Details: $($ErrMsgs -join '; ')" "ERROR"
            }

            $ParseErrors.Count | Should -Be 0
        }
    }

    Context "Configuration Management Compliance" {
        It "Should have a matching JSON configuration file for <_.Name>" -ForEach $TargetScripts {
            $BaseName = $_.BaseName
            $ExpectedJsonPath = Join-Path -Path $ConfigDir -ChildPath "$BaseName.json"
            
            if (-not (Test-Path $ExpectedJsonPath)) {
                Write-Log "Missing JSON config file for $($_.Name)." "WARNING"
            }

            $ExpectedJsonPath | Should -Exist
        }

        It "Should contain valid JSON data in <_.Name>.json" -ForEach $TargetScripts {
            $BaseName = $_.BaseName
            $JsonPath = Join-Path -Path $ConfigDir -ChildPath "$BaseName.json"
            
            if (Test-Path $JsonPath) {
                $IsValid = $true
                try {
                    $null = Get-Content -Path $JsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    $IsValid = $false
                    # Explicitly log the error so the scanner picks it up and emails you!
                    Write-Log "Invalid JSON detected in $BaseName.json: $($_.Exception.Message)" "ERROR"
                }
                $IsValid | Should -Be $true
            }
        }
    }
}

Describe "Core Evergreen Infrastructure State" {
    
    Context "Critical Management Services" {
        It "Should have WinRM service running for PSRemoting" {
            $Service = Get-Service -Name WinRM
            
            if ($Service.Status -ne 'Running') {
                Write-Log "Compliance Failure: WinRM Service is not running." "ERROR"
            }
            
            $Service.Status | Should -Be 'Running'
        }
    }

    Context "Logging and Telemetry" {
        It "Should have the 'MasterRunner' Custom EventLog Source registered" {
            $SourceExists = [System.Diagnostics.EventLog]::SourceExists("MasterRunner")
            
            if (-not $SourceExists) { 
                Write-Log "Compliance Failure: EventLog Source 'MasterRunner' missing." "ERROR" 
            }
            
            $SourceExists | Should -Be $true
        }

        It "Should have the Master Logs directory present" {
            $expectedLogsDir = Join-Path $BaseDir "Logs"
            if (-not (Test-Path $expectedLogsDir)) { 
                Write-Log "Compliance Failure: Directory $expectedLogsDir missing." "ERROR" 
            }
            $expectedLogsDir | Should -Exist
        }
    }

    Context "Security and Identity" {
        It "Should have the Break-Glass local administrator account" {
            # Read account name from config file if available, otherwise fallback
            $Config30Path = Join-Path $ConfigDir "30 - New-LocalAdminAccount.json"
            $AccountName = "LabBreakGlass"
            if (Test-Path $Config30Path) {
                $Config30 = Get-Content -Path $Config30Path | ConvertFrom-Json
                $AccountName = $Config30.AccountName
            }
            
            $User = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
            
            if (-not $User -or $User.Enabled -ne $true) {
                Write-Log "Compliance Failure: $AccountName account is missing or disabled." "CRITICAL"
            }
            
            $User | Should -Not -BeNullOrEmpty
            
            if ($User) {
                $User.Enabled | Should -Be $true
            }
        }
    }
}

AfterAll {
    # =====================================================================
    # 3. Post-Flight: Log Scanning & Email Alerting (PoshMailKit)
    # =====================================================================
    if (Test-Path $LogFile) {
        Write-Log "Scanning $LogFile for compliance failures in the last 5 minutes..." "INFO"
        
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
            Write-Log "$($errorLines.Count) compliance failure(s) found. Attempting to send email alert..." "INFO"
            
            try {
                # Ensure these are populated in your JSON config
                $appPassword = $Script:Config.EmailAppPassword 
                $emailFrom   = $Script:Config.EmailFrom
                $emailTo     = $Script:Config.EmailTo

                if (-not $appPassword -or -not $emailFrom -or -not $emailTo) {
                    throw "Email configuration missing from JSON config."
                }

                $secPassword = ConvertTo-SecureString $appPassword -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential ($emailFrom, $secPassword)
                
                $emailBody = "The following compliance failures were detected during the Pester run ($ScriptName):`n`n" + ($errorLines -join "`n")
                
                Import-Module PoshMailKit -ErrorAction Stop
                Send-MKMailMessage -To $emailTo `
                                   -From $emailFrom `
                                   -Subject "Compliance Alert: $ScriptName Test Failures" `
                                   -Body $emailBody `
                                   -SmtpServer "smtp.gmail.com" `
                                   -Port 587 `
                                   -UseSsl `
                                   -Credential $credential
                
                Write-Log "Compliance alert email sent successfully." "INFO"
            } catch {
                Write-Log "Failed to send email alert: $($_.Exception.Message)" "WARNING"
            }
        } else {
            Write-Log "All tests passed. No compliance failures found." "INFO"
        }
    } else {
        Write-Log "Log file not found at $LogFile. Cannot scan for errors." "WARNING"
    }

    Write-Log "Pester script execution completed." -End
}