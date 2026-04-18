# PowerShell Commander Launcher
# This script launches the PowerShell Commander GUI application

$ScriptDir = $PSScriptRoot
$PyScript = Join-Path $ScriptDir "powershell_commander.py"
$ReqFile = Join-Path $ScriptDir "requirements.txt"

Function Test-GenuinePython {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { return $false }
    
    # Check if it's the Windows Store stub (which just opens the store)
    if ($python.Path -match "WindowsApps") {
        return $false
    }
    
    # Verify it actually runs and returns a version
    try {
        $version = & $python.Path --version 2>&1
        if ($version -match "Python") {
            return $true
        }
    } catch {
        return $false
    }
    return $false
}

$pythonCmd = ""

# Check if genuine Python is available
if (Test-GenuinePython) {
    $pythonCmd = (Get-Command python).Path
} else {
    # Check if already installed in user context (Python 3.11)
    $UserPython = "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
    if (Test-Path $UserPython) {
        Write-Host "Using Python found in user profile: $UserPython" -ForegroundColor Cyan
        $pythonCmd = $UserPython
    } else {
        Write-Host "Genuine Python not found. Downloading installer for user-context installation..." -ForegroundColor Cyan
        
        $InstallerUrl = "https://www.python.org/ftp/python/3.11.8/python-3.11.8-amd64.exe"
        $InstallerFile = Join-Path $ScriptDir "python_installer.exe"
        
        try {
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerFile -ErrorAction Stop
            
            Write-Host "Installing Python (silent, user context)..." -ForegroundColor Cyan
            $process = Start-Process -FilePath $InstallerFile -ArgumentList "/quiet InstallAllUsers=0 PrependPath=1" -Wait -PassThru
            
            if ($process.ExitCode -ne 0) {
                throw "Installer failed with exit code $($process.ExitCode)"
            }
            
            Remove-Item $InstallerFile -ErrorAction SilentlyContinue
            
            $pythonCmd = $UserPython
            # Update path for current session
            $env:Path = "$env:LOCALAPPDATA\Programs\Python\Python311;$env:LOCALAPPDATA\Programs\Python\Python311\Scripts;$env:Path"
            
            Write-Host "Python installed successfully in user context." -ForegroundColor Green
        } catch {
            Write-Host "Failed to install Python: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Please install Python manually from https://www.python.org/downloads/" -ForegroundColor Yellow
            Pause
            Exit
        }
    }
}

# Check if customtkinter is installed
$hasCustomTkinter = & $pythonCmd -c "import customtkinter" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing required dependencies..." -ForegroundColor Cyan
    if (Test-Path $ReqFile) {
        & $pythonCmd -m pip install -r $ReqFile
    } else {
        & $pythonCmd -m pip install customtkinter
    }
}

# Launch the application
Write-Host "Starting PowerShell Commander..." -ForegroundColor Green
$pythonwCmd = Join-Path (Split-Path $pythonCmd) "pythonw.exe"
if (Test-Path $pythonwCmd) {
    Start-Process $pythonwCmd -ArgumentList "`"$PyScript`"" -WorkingDirectory $ScriptDir
} else {
    Start-Process $pythonCmd -ArgumentList "`"$PyScript`"" -WorkingDirectory $ScriptDir
}
