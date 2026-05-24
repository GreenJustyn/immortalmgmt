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

SHARE_NAME=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('ShareName', ''))" "$CONFIG_JSON")
SHARE_PATH=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('SharePath', ''))" "$CONFIG_JSON")
DESCRIPTION=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('Description', ''))" "$CONFIG_JSON")

# Map Windows path to Linux if needed
if [[ "$SHARE_PATH" =~ ^[a-zA-Z]:\\ ]]; then
    NEW_PATH=$(echo "$SHARE_PATH" | sed 's/^[a-zA-Z]:\\/\//' | tr '\\' '/')
    write_log "Mapping Windows path $SHARE_PATH to Linux path $NEW_PATH" "INFO"
    SHARE_PATH="$NEW_PATH"
fi

write_log "Loaded Configuration Variables:" "INFO"
write_log "  ShareName = $SHARE_NAME" "INFO"
write_log "  SharePath = $SHARE_PATH" "INFO"
write_log "  Description = $DESCRIPTION" "INFO"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    write_log "This script must be run as root to configure Samba." "CRITICAL"
    exit 1
fi

if [ ! -d "$SHARE_PATH" ]; then
    write_log "Share path $SHARE_PATH does not exist. Creating directory." "INFO"
    mkdir -p "$SHARE_PATH"
fi

SMB_CONF="/etc/samba/smb.conf"

if [ ! -f "$SMB_CONF" ]; then
    write_log "Samba configuration file not found at $SMB_CONF. Samba may not be installed." "WARNING"
    write_log "Skipping share creation. Please install Samba first." "INFO"
    exit 0
fi

# Check if share already exists in smb.conf
if grep -q "^\[$SHARE_NAME\]" "$SMB_CONF"; then
    write_log "Share [$SHARE_NAME] already exists in $SMB_CONF. No action taken." "INFO"
else
    write_log "Share [$SHARE_NAME] not found. Adding to $SMB_CONF." "INFO"
    
    # Append share configuration
    cat >> "$SMB_CONF" <<EOF

[$SHARE_NAME]
   path = $SHARE_PATH
   browseable = no
   read only = no
   guest ok = no
   valid users = @sudo
   comment = $DESCRIPTION
EOF

    write_log "Share configuration appended to $SMB_CONF." "INFO"
    
    # Reload Samba
    if systemctl is-active --quiet smbd; then
        write_log "Reloading Samba service." "INFO"
        systemctl reload smbd
    else
        write_log "Samba service is not active. Please start it manually." "WARNING"
    fi
fi

write_log "Script execution completed successfully." "INFO"
post_flight
