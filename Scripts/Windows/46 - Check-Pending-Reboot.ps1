$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$ConfigFile  = Join-Path (Join-Path $BaseDir "Variables") "$ScriptName.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$CredFile    = Join-Path (Join-Path $BaseDir "Credentials") "credential.xml"
$Environment = "#{ENVIRONMENT}#" # GitOps Placeholder

Function Write-Log {
    Param(
        [Parameter(Mandatory=$true, Position=0)] [string]$Message,
        [Parameter(Position=1)] [ValidateSet("INFO", "WARNING", "ERROR", "CRITICAL")] [string]$Level = "INFO",
        [switch]$Start, [switch]$End
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if ($Start) { "( --- START [$Timestamp] $ScriptName --- )" | Out-File -FilePath $LogFile -Append -Force }
    "[$Timestamp] [$Level] [$Environment] $Message" | Out-File -FilePath $LogFile -Append -Force
    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append -Force }
}

Write-Log "Initializing pending reboot evaluations..." -Start

# =====================================================================
# Admin Rights
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ ERROR: Querying deep registry configuration paths securely demands elevated privileges." "CRITICAL"
    }
}

# =====================================================================
# Helper Function
# =====================================================================
function Test-RegistryValue { 
    param(
        [parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]$Path, 
        [parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]$Value
    )
    try {
        $null = Get-ItemProperty -Path $Path -Name $Value -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# =====================================================================
# Core Logic
# =====================================================================
try {
    [string]$reply = "✅ No pending reboot."
    $level = "INFO"

    if ($IsLinux) {
        if (Test-Path "/var/run/reboot-required") {
            $reply = "⚠️ Pending reboot (found: /var/run/reboot-required)"
            $level = "WARNING"
        }
    } else {
        $reason = ""
        if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
            $reason += ", ...\Auto Update\RebootRequired"
        }
        if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting") {
            $reason += ", ...\Auto Update\PostRebootReporting"
        }
        if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
            $reason += ", ...\Component Based Servicing\RebootPending"
        }
        if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentRebootAttempts") {
            $reason += ", ...\ServerManager\CurrentRebootAttempts"
        }
        if (Test-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing" -Value "RebootInProgress") {
            $reason += ", ...\CurrentVersion\Component Based Servicing with 'RebootInProgress'"
        }
        if (Test-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing" -Value "PackagesPending") {
            $reason += ", '...\CurrentVersion\Component Based Servicing' with 'PackagesPending'"
        }
        if (Test-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Value "PendingFileRenameOperations2") {
            $reason += ", '...\CurrentControlSet\Control\Session Manager' with 'PendingFileRenameOperations2'"
        }
        if (Test-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Value "DVDRebootSignal") {
            $reason += ", '...\Windows\CurrentVersion\RunOnce' with 'DVDRebootSignal'"
        }
        if (Test-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon" -Value "JoinDomain") {
            $reason += ", '...\CurrentControlSet\Services\Netlogon' with 'JoinDomain'"
        }
        if (Test-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon" -Value "AvoidSpnSet") {
            $reason += ", '...\CurrentControlSet\Services\Netlogon' with 'AvoidSpnSet'"
        }
        if ($reason -ne "") {
            $reply = "⚠️ Pending reboot required (Registry flagged paths: $($reason.substring(2)))"
            $level = "WARNING"
        }
    }
    
    Write-Log $reply $level
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

Write-Log "Reboot check completed." "INFO" -End
