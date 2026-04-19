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
global_file = sys.argv[2]
script_name = sys.argv[3]

# Load global config for email
try:
    with open(global_file, "r") as f:
        config = json.load(f)
except Exception as e:
    print(f"CRITICAL: Failed to load global config: {e}")
    sys.exit(1)

email_to = config.get("EmailTo")
email_from = config.get("EmailFrom")
app_password = config.get("EmailAppPassword")

if not all([email_to, email_from, app_password]):
    print("WARNING: Email config missing in _Global.json.")
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
    body = f"The following errors were detected in the {script_name} run:\n\n" + "".join(errors)
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
' "$LOG_FILE" "$GLOBAL_FILE" "$SCRIPT_NAME"
        
    else
        write_log "Log file not found at $LOG_FILE. Cannot scan for errors." "WARNING"
    fi
}

write_log "Initializing script execution." "INFO"
write_log "Note: On Linux, this script monitors directory size as a soft quota check." "INFO"

# Load Config
if [ ! -f "$CONFIG_FILE" ]; then
    write_log "FATAL: Config file missing at $CONFIG_FILE." "CRITICAL"
    exit 1
fi

CONFIG_JSON=$(python3 -c '
import json
import sys
try:
    with open(sys.argv[1], "r") as f:
        config = json.load(f)
    print(json.dumps(config))
except Exception as e:
    print("{}")
' "$CONFIG_FILE")

QUOTA_PATH=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('QuotaPath', ''))" "$CONFIG_JSON")
SIZE_LIMIT_GB=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('SizeLimitGB', 0))" "$CONFIG_JSON")
WARNING_PERCENT=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('WarningThresholdPercent', 85))" "$CONFIG_JSON")

# Map Windows path to Linux if needed
if [[ "$QUOTA_PATH" =~ ^[a-zA-Z]:\\ ]]; then
    NEW_PATH=$(echo "$QUOTA_PATH" | sed 's/^[a-zA-Z]:\\/\//' | tr '\\' '/')
    write_log "Mapping Windows path $QUOTA_PATH to Linux path $NEW_PATH" "INFO"
    QUOTA_PATH="$NEW_PATH"
fi

write_log "Loaded Configuration Variables:" "INFO"
write_log "  QuotaPath = $QUOTA_PATH" "INFO"
write_log "  SizeLimitGB = $SIZE_LIMIT_GB" "INFO"
write_log "  WarningThresholdPercent = $WARNING_PERCENT" "INFO"

if [ ! -d "$QUOTA_PATH" ]; then
    write_log "Quota path $QUOTA_PATH does not exist. Creating directory." "INFO"
    mkdir -p "$QUOTA_PATH"
fi

# Calculate limits in bytes
# Bash handles arithmetic up to 64-bit integers, so 5GB fits easily.
LIMIT_BYTES=$((SIZE_LIMIT_GB * 1024 * 1024 * 1024))
WARNING_BYTES=$((LIMIT_BYTES * WARNING_PERCENT / 100))

# Check size
if command -v du &> /dev/null; then
    CURRENT_SIZE=$(du -sb "$QUOTA_PATH" | cut -f1)
    
    write_log "Current size of $QUOTA_PATH: $CURRENT_SIZE bytes." "INFO"
    
    if [ "$CURRENT_SIZE" -ge "$LIMIT_BYTES" ]; then
        write_log "CRITICAL: Directory $QUOTA_PATH exceeds quota limit of $SIZE_LIMIT_GB GB!" "CRITICAL"
    elif [ "$CURRENT_SIZE" -ge "$WARNING_BYTES" ]; then
        write_log "WARNING: Directory $QUOTA_PATH exceeds warning threshold of $WARNING_PERCENT%!" "WARNING"
    else
        write_log "Directory $QUOTA_PATH is within quota limits." "INFO"
    fi
else
    write_log "du command not found. Cannot check directory size." "ERROR"
    exit 1
fi

write_log "Script execution completed successfully." "INFO"
post_flight
