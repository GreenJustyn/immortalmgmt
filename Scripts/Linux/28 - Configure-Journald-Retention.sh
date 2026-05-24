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
write_log "Note: On Linux, log retention is managed by journald (systemd-journald)." "INFO"

# Load Config using the Hiera helper
CONFIG_JSON=$(python3 "$BASE_DIR/Functions/get_script_config.py" "$SCRIPT_NAME")
if [ $? -ne 0 ] || [ -z "$CONFIG_JSON" ]; then
    write_log "FATAL: Failed to resolve configuration via get_script_config.py." "CRITICAL"
    exit 1
fi

MAX_SIZE_KB=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('MaximumSizeKB', 524288))" "$CONFIG_JSON")

# Convert KB to MB for journald (e.g., 524288 KB = 512 MB)
MAX_SIZE_MB=$((MAX_SIZE_KB / 1024))

write_log "Loaded Configuration Variables:" "INFO"
write_log "  MaximumSizeKB = $MAX_SIZE_KB" "INFO"
write_log "  Mapped to SystemMaxUse = ${MAX_SIZE_MB}M" "INFO"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    write_log "This script must be run as root to configure journald." "CRITICAL"
    exit 1
fi

JOURNAL_CONF="/etc/systemd/journald.conf"

if [ ! -f "$JOURNAL_CONF" ]; then
    write_log "Journald configuration file not found at $JOURNAL_CONF." "ERROR"
    exit 1
fi

write_log "Checking journald configuration for drift..." "INFO"

DRIFT_DETECTED=$(python3 -c '
import sys

journal_conf = sys.argv[1]
max_size_mb = sys.argv[2]

try:
    with open(journal_conf, "r") as f:
        lines = f.readlines()
except Exception as e:
    print(f"ERROR: Failed to read journald.conf: {e}")
    sys.exit(1)

new_lines = []
in_journal = False
max_use_set = False
drift = False

target_line = f"SystemMaxUse={max_size_mb}M\n"

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if stripped.lower() == "[journal]":
            in_journal = True
        else:
            in_journal = False

    if in_journal:
        if stripped.startswith("SystemMaxUse="):
            if stripped != target_line.strip():
                line = target_line
                drift = True
            max_use_set = True
        elif stripped.startswith("#SystemMaxUse="):
            line = target_line
            drift = True
            max_use_set = True

    new_lines.append(line)

# If we passed the journal section and didnt find/set it, add it
if not max_use_set:
    for i, line in enumerate(new_lines):
        if line.strip().lower() == "[journal]":
            new_lines.insert(i + 1, target_line)
            drift = True
            break

if drift:
    try:
        with open(journal_conf, "w") as f:
            f.writelines(new_lines)
        print("drift_corrected")
    except Exception as e:
        print(f"ERROR: Failed to write journald.conf: {e}")
        sys.exit(1)
else:
    print("no_drift")
' "$JOURNAL_CONF" "$MAX_SIZE_MB")

if [[ "$DRIFT_DETECTED" == *"ERROR"* ]]; then
    write_log "Failed to check/update journald config: $DRIFT_DETECTED" "ERROR"
elif [ "$DRIFT_DETECTED" == "drift_corrected" ]; then
    write_log "journald.conf updated to match desired state." "INFO"
    
    write_log "Restarting systemd-journald service to apply changes." "INFO"
    systemctl restart systemd-journald
    
    write_log "journald service restarted successfully." "INFO"
else
    write_log "journald configuration already matches desired state. No action taken." "INFO"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
