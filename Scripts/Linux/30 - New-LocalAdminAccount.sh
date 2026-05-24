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

ACCOUNT_NAME=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('AccountName', ''))" "$CONFIG_JSON")
ACCOUNT_DESC=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('AccountDescription', ''))" "$CONFIG_JSON")
GROUP_NAME=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('GroupName', 'sudo'))" "$CONFIG_JSON")

# Fallback password from config if not in credential.xml
PASSWORD=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('Password', ''))" "$CONFIG_JSON")

write_log "Loaded Configuration Variables:" "INFO"
write_log "  AccountName = $ACCOUNT_NAME" "INFO"
write_log "  AccountDescription = $ACCOUNT_DESC" "INFO"
write_log "  GroupName = $GROUP_NAME" "INFO"

if [ -z "$ACCOUNT_NAME" ]; then
    write_log "FATAL: AccountName not specified in config." "CRITICAL"
    exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    write_log "This script must be run as root to create users." "CRITICAL"
    exit 1
fi

# Determine admin group (sudo or wheel)
ADMIN_GROUP="sudo"
if ! getent group sudo &>/dev/null; then
    if getent group wheel &>/dev/null; then
        ADMIN_GROUP="wheel"
    else
        write_log "Neither 'sudo' nor 'wheel' group found. Defaulting to 'sudo'." "WARNING"
    fi
fi

write_log "Using admin group: $ADMIN_GROUP" "INFO"

# Idempotent Logic
if ! id -u "$ACCOUNT_NAME" &>/dev/null; then
    write_log "Account '$ACCOUNT_NAME' does not exist. Creating..." "INFO"
    
    useradd -m -c "$ACCOUNT_DESC" "$ACCOUNT_NAME"
    
    if [ -n "$PASSWORD" ]; then
        echo "$ACCOUNT_NAME:$PASSWORD" | chpasswd
        write_log "Password set for '$ACCOUNT_NAME'." "INFO"
    else
        write_log "WARNING: No password provided in config for '$ACCOUNT_NAME'. Account created without password." "WARNING"
    fi
    
    usermod -aG "$ADMIN_GROUP" "$ACCOUNT_NAME"
    write_log "Added '$ACCOUNT_NAME' to '$ADMIN_GROUP' group." "INFO"
    
    write_log "Local Administrator account created successfully." "INFO"
else
    write_log "Account '$ACCOUNT_NAME' already exists. Enforcing state..." "INFO"
    
    if [ -n "$PASSWORD" ]; then
        echo "$ACCOUNT_NAME:$PASSWORD" | chpasswd
        write_log "Password updated for '$ACCOUNT_NAME'." "INFO"
    fi
    
    # Check group membership
    if ! id -nG "$ACCOUNT_NAME" | grep -qw "$ADMIN_GROUP"; then
        write_log "Account is missing from '$ADMIN_GROUP'. Re-adding..." "WARNING"
        usermod -aG "$ADMIN_GROUP" "$ACCOUNT_NAME"
    else
        write_log "Account is already in '$ADMIN_GROUP' group." "INFO"
    fi
    
    write_log "Account state enforcement complete." "INFO"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
