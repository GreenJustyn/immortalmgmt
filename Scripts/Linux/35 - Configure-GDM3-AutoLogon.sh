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

ENABLE_AUTOLOGON=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('EnableAutoLogon', False))" "$CONFIG_JSON")
TARGET_USER=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('TargetUser', ''))" "$CONFIG_JSON")

write_log "Loaded Configuration Variables:" "INFO"
write_log "  EnableAutoLogon = $ENABLE_AUTOLOGON" "INFO"
write_log "  TargetUser = $TARGET_USER" "INFO"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    write_log "This script must be run as root to configure system logon settings." "CRITICAL"
    exit 1
fi

# Target GDM3 config
GDM_CONFIG="/etc/gdm3/custom.conf"

if [ ! -f "$GDM_CONFIG" ]; then
    write_log "GDM3 configuration file not found at $GDM_CONFIG. Skipping AutoLogon configuration." "WARNING"
    write_log "If you are using a different Display Manager (e.g., LightDM), please configure it manually." "INFO"
    exit 0
fi

write_log "GDM3 detected. Enforcing AutoLogon state..." "INFO"

python3 -c '
import sys
import os
import json

gdm_config = sys.argv[1]
enable_str = sys.argv[2]
user = sys.argv[3]

enable = enable_str.lower() == "true"

try:
    with open(gdm_config, "r") as f:
        lines = f.readlines()
except Exception as e:
    print(f"CRITICAL: Failed to read config: {e}")
    sys.exit(1)

new_lines = []
in_daemon = False
daemon_found = False
auto_enable_found = False
auto_user_found = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[daemon]"):
        in_daemon = True
        daemon_found = True
        new_lines.append(line)
        continue
    elif stripped.startswith("[") and in_daemon:
        # Exiting daemon section, add missing lines if enabling
        if enable:
            if not auto_enable_found:
                new_lines.append("AutomaticLoginEnable=true\n")
            if not auto_user_found:
                new_lines.append(f"AutomaticLogin={user}\n")
        in_daemon = False
        new_lines.append(line)
        continue

    if in_daemon:
        if "AutomaticLoginEnable" in stripped:
            auto_enable_found = True
            if enable:
                new_lines.append("AutomaticLoginEnable=true\n")
            else:
                new_lines.append("AutomaticLoginEnable=false\n")
        elif "AutomaticLogin" in stripped and "AutomaticLoginEnable" not in stripped:
            auto_user_found = True
            if enable:
                new_lines.append(f"AutomaticLogin={user}\n")
            else:
                new_lines.append(f"#AutomaticLogin={user}\n")
        else:
            new_lines.append(line)
    else:
        new_lines.append(line)

# If we finished the file and were still in daemon section or file ended without another section
if in_daemon and enable:
    if not auto_enable_found:
        new_lines.append("AutomaticLoginEnable=true\n")
    if not auto_user_found:
        new_lines.append(f"AutomaticLogin={user}\n")

# If [daemon] section was never found, add it at the end (unlikely but possible)
if not daemon_found and enable:
    new_lines.append("\n[daemon]\n")
    new_lines.append("AutomaticLoginEnable=true\n")
    new_lines.append(f"AutomaticLogin={user}\n")

try:
    with open(gdm_config, "w") as f:
        f.writelines(new_lines)
    print("INFO: GDM3 config updated successfully.")
except Exception as e:
    print(f"CRITICAL: Failed to write config: {e}")
    sys.exit(1)
' "$GDM_CONFIG" "$ENABLE_AUTOLOGON" "$TARGET_USER"

if [ $? -eq 0 ]; then
    write_log "AutoLogon state enforced successfully." "INFO"
else
    write_log "Failed to enforce AutoLogon state." "ERROR"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
