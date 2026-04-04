<#
    .SYNOPSIS
    Pester 5 Compliance Test for Evergreen Windows Server Infrastructure.
    Expects $ScriptsDir and $ConfigDir to be passed via New-PesterContainer.
#>

BeforeAll {
    # Fallback paths for manual testing if variables aren't injected via the wrapper
    if (-not $ScriptsDir) { $ScriptsDir = "C:\Scripts" }
    if (-not $ConfigDir) { $ConfigDir = "C:\Scripts\Config" }

    # Gather all PS1 files in the root scripts directory (ignoring subfolders like \Tests or \Logs)
    $TargetScripts = Get-ChildItem -Path $ScriptsDir -Filter "*.ps1" -File
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
            
            $ParseErrors.Count | Should -Be 0
        }
    }

    Context "Configuration Management Compliance" {
        It "Should have a matching JSON configuration file for <_.Name>" -ForEach $TargetScripts {
            $BaseName = $_.BaseName
            $ExpectedJsonPath = Join-Path -Path $ConfigDir -ChildPath "$BaseName.json"
            
            $ExpectedJsonPath | Should -FileExist
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
            $Service.Status | Should -Be 'Running'
        }
    }

    Context "Logging and Telemetry" {
        It "Should have the 'MasterAutomation' Custom EventLog Source registered" {
            $SourceExists = [System.Diagnostics.EventLog]::SourceExists("MasterRunner")
            $SourceExists | Should -Be $true
        }

        It "Should have the Master Logs directory present" {
            "C:\Scripts\Logs" | Should -PathExist
        }
    }

    Context "Security and Identity" {
        It "Should have the Break-Glass local administrator account" {
            # Checks for the account created in Script #31
            $User = Get-LocalUser -Name "LabBreakGlass" -ErrorAction SilentlyContinue
            $User | Should -Not -BeNullOrEmpty
            
            if ($User) {
                $User.Enabled | Should -Be $true
            }
        }
    }
}