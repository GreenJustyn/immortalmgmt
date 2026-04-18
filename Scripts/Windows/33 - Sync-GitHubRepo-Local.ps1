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
    $null = git -c credential.helper='' fetch --quiet $AuthUrl $Branch 2>&1

    $LOCAL  = (git rev-parse HEAD).Trim()
    $REMOTE = (git rev-parse FETCH_HEAD).Trim()

    Write-Log "Local: $LOCAL, Remote: $REMOTE" "INFO"
    Write-Log "Syncing staging folder to remote state..." "INFO"
    git -c credential.helper='' reset --hard FETCH_HEAD 2>&1

    # 5. File Replication to Operating Folders
    Write-Log "Syncing all files from staging to base directory..." "INFO"
    robocopy $RepoPath $BaseDir *.* /E /XD .git Git /NDL /NFL /NJH /NJS
    if ($LASTEXITCODE -ge 8) { Write-Log "Robocopy failed with code $LASTEXITCODE" "ERROR" }

    Write-Log "Deployment routines completed successfully." "INFO"

} catch {
    Write-Log "Script encountered a terminating error: $($_.Exception.Message)" "CRITICAL"
} finally {
    # ... [Keep your existing Post-Flight Log Scanning and Email logic here] ...
    Set-Location -Path "C:\"
    Write-Log "Script execution completed." -End
}