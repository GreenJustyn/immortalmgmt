#!/bin/bash

# Script Name
SCRIPT_NAME=$(basename "$0" .sh)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

LOG_FILE="$BASE_DIR/Logs/$SCRIPT_NAME.log"
CONFIG_FILE="$BASE_DIR/Variables/$SCRIPT_NAME.json"
GLOBAL_FILE="$BASE_DIR/Variables/_Global.json"

ENVIRONMENT="#{ENVIRONMENT}#"

# Logging function
write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    echo "[$timestamp] [$level] [$ENVIRONMENT] $message" >> "$LOG_FILE"
    
    # Console output
    if [[ "$level" == "ERROR" || "$level" == "CRITICAL" ]]; then
        echo -e "\e[31m[$level] $message\e[0m"
    elif [[ "$level" == "WARNING" ]]; then
        echo -e "\e[33m[$level] $message\e[0m"
    else
        echo "[$level] $message"
    fi
}

# Trap errors
trap 'write_log "Script encountered a terminating error on line $LINENO" "CRITICAL"; post_flight' ERR

post_flight() {
    if [ -f "$LOG_FILE" ]; then
        write_log "Scanning $LOG_FILE for errors in the last 5 minutes..." "INFO"
        
        python3 -c '
import sys
import datetime
import json
import smtplib
from email.mime.text import MIMEText

log_file = sys.argv[1]
config_json_str = sys.argv[2]
script_name = sys.argv[3]

try:
    config = json.loads(config_json_str)
except Exception:
    config = {}

email_to = config.get("EmailTo")
email_from = config.get("EmailFrom")
app_password = config.get("EmailAppPassword")

if not all([email_to, email_from, app_password]):
    print("WARNING: Email alerting is not configured in _Global.json.")
    sys.exit(0)

threshold = datetime.datetime.now() - datetime.timedelta(minutes=5)
errors = []

try:
    with open(log_file, "r") as f:
        for line in f:
            if "[ERROR]" in line or "[CRITICAL]" in line:
                parts = line.split("] ")
                if len(parts) > 0:
                    date_str = parts[0][1:]
                    try:
                        log_date = datetime.datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S")
                        if log_date >= threshold:
                            errors.append(line)
                    except:
                        pass
except Exception as e:
    print(f"WARNING: Failed to read log: {e}")
    sys.exit(0)

if errors:
    print(f"INFO: Found {len(errors)} errors. Sending email...")
    body = f"The following errors/alerts were detected in the {script_name} run:\n\n" + "".join(errors)
    msg = MIMEText(body)
    msg["Subject"] = f"Script Alert: {script_name} Errors Detected"
    msg["From"] = email_from
    msg["To"] = email_to
    
    try:
        server = smtplib.SMTP("smtp.gmail.com", 587)
        server.starttls()
        server.login(email_from, app_password)
        server.send_message(msg)
        server.quit()
        print("INFO: Email sent successfully.")
    except Exception as e:
        print(f"CRITICAL: Failed to send email: {e}")
' "$LOG_FILE" "$CONFIG_JSON" "$SCRIPT_NAME"
        
    else
        write_log "Log file not found at $LOG_FILE. Cannot scan for errors." "WARNING"
    fi
}

write_log "Initializing script execution." "INFO"

# Load Config using the Hiera helper
CONFIG_JSON=$(python3 "$BASE_DIR/Functions/get_script_config.py" "$SCRIPT_NAME")
if [ $? -ne 0 ] || [ -z "$CONFIG_JSON" ]; then
    write_log "FATAL: Failed to resolve configuration via get_script_config.py." "CRITICAL"
    exit 1
fi

MODULES=$(python3 -c "import json, sys; print(' '.join(json.loads(sys.argv[1]).get('ModulesToInstall', [])))" "$CONFIG_JSON")

write_log "Loaded Configuration Variables:" "INFO"
write_log "  ModulesToInstall = $MODULES" "INFO"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    write_log "This script must be run as root to install modules globally." "CRITICAL"
    exit 1
fi

# Check if pwsh exists
if command -v pwsh &> /dev/null; then
    write_log "PowerShell (pwsh) detected. Installing modules." "INFO"
    
    for module in $MODULES; do
        write_log "Checking module: $module" "INFO"
        
        # Check if installed
        IS_INSTALLED=$(pwsh -Command "Get-Module -ListAvailable -Name '$module' -ErrorAction SilentlyContinue")
        
        if [ -z "$IS_INSTALLED" ]; then
            write_log "Module '$module' is missing. Installing from PSGallery." "INFO"
            
            # Note: PSWindowsUpdate is Windows specific and will likely fail to run on Linux
            if [ "$module" == "PSWindowsUpdate" ]; then
                write_log "Warning: PSWindowsUpdate is Windows-specific and may not function on Linux." "WARNING"
            fi
            
            pwsh -Command "Install-Module -Name '$module' -Force -Scope AllUsers -ErrorAction Stop"
            
            if [ $? -eq 0 ]; then
                write_log "Successfully installed module: $module" "INFO"
            else
                write_log "Failed to install module: $module" "ERROR"
            fi
        else
            write_log "Module '$module' is already installed." "INFO"
        fi
    done
else
    write_log "PowerShell (pwsh) not detected. Skipping installation of PowerShell modules." "INFO"
    write_log "Note: For Bash environment, email is handled by Python and package management by native tools." "INFO"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
