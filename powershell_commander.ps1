# PowerShell Commander Launcher
# This script launches the PowerShell Commander GUI application

$ScriptDir = $PSScriptRoot
$PyScript = Join-Path $ScriptDir "powershell_commander.py"
$ReqFile = Join-Path $ScriptDir "requirements.txt"

# Check if Python is available
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "Python not found. Please install Python 3.8 or higher." -ForegroundColor Red
    Write-Host "Download from: https://www.python.org/downloads/" -ForegroundColor Yellow
    Pause
    Exit
}

# Check if customtkinter is installed
$hasCustomTkinter = python -c "import customtkinter" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing required dependencies..." -ForegroundColor Cyan
    if (Test-Path $ReqFile) {
        pip install -r $ReqFile
    } else {
        pip install customtkinter
    }
}

# Launch the application
Write-Host "Starting PowerShell Commander..." -ForegroundColor Green
if (Get-Command pythonw -ErrorAction SilentlyContinue) {
    Start-Process pythonw -ArgumentList "`"$PyScript`"" -WorkingDirectory $ScriptDir
} else {
    Start-Process python -ArgumentList "`"$PyScript`"" -WorkingDirectory $ScriptDir
}
