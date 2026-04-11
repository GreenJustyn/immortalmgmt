$ScriptName  = $MyInvocation.MyCommand.Name -replace '\.tests\.ps1$','' -replace '\.ps1$',''
$ScriptDir   = $PSScriptRoot
# Logic: <base dir> is two levels up from where the script runs
$BaseDir     = Split-Path (Split-Path $ScriptDir -Parent) -Parent

$LogFile     = Join-Path (Join-Path $BaseDir "Logs") "$ScriptName.log"
$ConfigFile  = Join-Path (Join-Path $BaseDir "Variables") "$ScriptName.json"
$GlobalFile  = Join-Path (Join-Path $BaseDir "Variables") "_Global.json"
$CredFile    = Join-Path (Join-Path $BaseDir "Credentials") "git-credential.xml"
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
    
    if ($Level -match "ERROR|CRITICAL") { Write-Host "[$Level] $Message" -ForegroundColor Red }
    elseif ($Level -eq "WARNING") { Write-Host "[$Level] $Message" -ForegroundColor Yellow }
    else { Write-Host "[$Level] $Message" -ForegroundColor Gray }

    if ($End) { "( --- END [$Timestamp] $ScriptName --- )`r`n" | Out-File -FilePath $LogFile -Append }
}

try {
    Write-Log "Initializing script execution." -Start

    # 1. Configuration Loading
    if (-not (Test-Path $ConfigFile)) { throw "FATAL: Config missing at $ConfigFile." }
    $GlobalConfig = Get-Content -Path $GlobalFile | ConvertFrom-Json
    $LocalConfig = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $ConfigHash = @{}
    foreach ($prop in $GlobalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    foreach ($prop in $LocalConfig.psobject.Properties) { $ConfigHash[$prop.Name] = $prop.Value }
    $Config = [PSCustomObject]$ConfigHash

    # 2. Git Environment Check
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "FATAL: Git is not installed." }
    $SecureToken = Import-Clixml -Path $CredFile
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
    $Token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

    $RepoPath = $Config.LocalRepoPath # Usually <BaseDir>\Git\<RepoName>
    $Branch   = $Config.Branch
    $RepoUrl  = $Config.RepoUrl
    $AuthUrl  = $RepoUrl -replace "https://", "https://$Token@"

    # 3. Pull / Trigger Logic
    if (-not (Test-Path "$RepoPath\.git")) {
        Write-Log "Cloning repository..." "INFO"
        git -c credential.helper='' clone -b $Branch $AuthUrl $RepoPath 2>&1
    }

    Set-Location -Path $RepoPath
    git -c credential.helper='' fetch $AuthUrl $Branch | Out-Null

    $LOCAL  = (git rev-parse HEAD).Trim()
    $REMOTE = (git rev-parse FETCH_HEAD).Trim()

    if ($LOCAL -eq $REMOTE) {
        Write-Log "Local and Remote match ($LOCAL). Exiting." "INFO"
        return # Terminate script early as requested
    }

    # 4. Sync Staging Folder
    Write-Log "Updates detected. Syncing staging folder..." "INFO"
    git -c credential.helper='' reset --hard FETCH_HEAD 2>&1

    # 5. File Replication to Operating Folders
    # Defined per your requirements using <BaseDir>
    $SyncMap = @{
        "Credentials" = Join-Path $BaseDir "Credentials"
        "Functions"   = Join-Path $BaseDir "Functions"
        "Scripts"     = Join-Path $BaseDir "Scripts"
        "Tests"       = Join-Path $BaseDir "Tests"
        "Variables"   = Join-Path $BaseDir "Variables"
    }

    foreach ($Folder in $SyncMap.Keys) {
        $Source = Join-Path $RepoPath $Folder
        $Dest   = $SyncMap[$Folder]

        if (Test-Path $Source) {
            Write-Log "Syncing $Folder..." "INFO"
            if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
            
            # /E = Subfolders, /XO = Skip older, /PURGE = Delete if not in source (optional - remove if you want to keep local-only files)
            robocopy $Source $Dest *.* /E /XO /NDL /NFL /NJH /NJS
            if ($LASTEXITCODE -ge 8) { Write-Log "Robocopy for $Folder failed with code $LASTEXITCODE" "ERROR" }
        }
    }

    Write-Log "Deployment routines completed successfully." "INFO"

} catch {
    Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"
} finally {
    # ... [Keep your existing Post-Flight Log Scanning and Email logic here] ...
    Set-Location -Path "C:\"
    Write-Log "Script execution completed." -End
}