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

Write-Log "Initializing Operating System status audit..." -Start

# =====================================================================
# Admin Check
# =====================================================================
if (-not $IsLinux) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = (New-Object Security.Principal.WindowsPrincipal $user)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "⚠️ CRITICAL: Elevated execution mode required to extract Product Keys and installation metadata." "CRITICAL"
    }
}

# =====================================================================
# Core Logic
# =====================================================================
try {
    if ($IsLinux) {
        $name = $PSVersionTable.OS
        $kernel = (uname --kernel-release)
        $architecture = (uname --machine)
        Write-Log "✅ $name (Linux kernel $kernel on $architecture)" "INFO"
    } else {
        $OS = Get-WmiObject -class Win32_OperatingSystem
        $Name = $OS.Caption -Replace "Microsoft Windows","Windows"
        $Arch = $OS.OSArchitecture
        $Version = $OS.Version

        [system.threading.thread]::currentthread.currentculture = [system.globalization.cultureinfo]"en-US"
        $OSDetails = Get-CimInstance Win32_OperatingSystem
        $BuildNo = $OSDetails.BuildNumber
        $Serial = $OSDetails.SerialNumber
        $InstallDate = $OSDetails.InstallDate

        $ProductKey = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" -Name BackupProductKeyDefault).BackupProductKeyDefault
        Write-Log "✅ $Name $Arch since $($InstallDate.ToShortDateString()) (v$Version, S/N $Serial, P/K $ProductKey)" "INFO"
    } 
} catch {
    Write-Log "⚠️ ERROR: $($Error[0]) (script line $($_.InvocationInfo.ScriptLineNumber))" "CRITICAL"
}

# Post Check
if (Test-Path $LogFile) {
    Write-Log "Data scan checks clear." "INFO"
}
Write-Log "OS complete." "INFO" -End
